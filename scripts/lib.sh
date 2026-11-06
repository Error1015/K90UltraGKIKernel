#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# 公共函数库：日志、重试、内核配置写入、补丁应用
# 所有脚本通过 `source scripts/lib.sh` 引入
# ---------------------------------------------------------------------------
set -euo pipefail

WS="${GITHUB_WORKSPACE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
KROOT="$WS/kernel"          # repo sync 出来的 kernel_platform 根目录
COMMON="$KROOT/common"      # GKI 通用内核源码
OUT="$WS/out"
DEFCONFIG_REL="arch/arm64/configs/gki_defconfig"

# 目标平台固定值：Redmi K90 Ultra / warsaw / SM8750，内核 6.6
ANDROID_VERSION="android15"
KERNEL_VERSION="6.6"

mkdir -p "$OUT"

log()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '\033[1;33m[!] %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31m[x] %s\033[0m\n' "$*" >&2; exit 1; }

is_true() {
  case "${1:-}" in
    1|true|TRUE|yes|on) return 0 ;;
    *) return 1 ;;
  esac
}

# retry <次数> <命令...>
retry() {
  local n="$1"; shift
  local i=1
  until "$@"; do
    if [ "$i" -ge "$n" ]; then
      warn "重试 $n 次仍失败: $*"
      return 1
    fi
    warn "第 $i 次失败，5 秒后重试: $*"
    sleep 5
    i=$((i + 1))
  done
}

# ---------------------------------------------------------------------------
# 内核配置：全部写进 gki_defconfig，Kleaf 构建时由 make gki_defconfig 生效
# ---------------------------------------------------------------------------

# kc <scripts/config 参数...>，例如 kc --enable FOO / kc --set-str BAR bbr
kc() {
  ( cd "$COMMON" && bash scripts/config --file "$DEFCONFIG_REL" "$@" )
}

# set_cfg CONFIG_NAME value
# value 取值：y / m / n / 其他（当作字符串）
set_cfg() {
  local name="${1#CONFIG_}"
  local value="$2"
  local def="$COMMON/$DEFCONFIG_REL"

  [ -f "$def" ] || die "找不到 $def（内核源码是否已同步？）"

  case "$value" in
    y) kc --enable "$name" ;;
    m) kc --module "$name" ;;
    n) kc --disable "$name" ;;
    *) kc --set-str "$name" "$(printf '%s' "$value" | sed -e 's/^"//' -e 's/"$//')" ;;
  esac

  # 立即回读校验：静默失败会让"看起来已经开启"的功能其实没进内核
  case "$value" in
    y|m) grep -qE "^CONFIG_${name}=${value}\$" "$def" \
           || die "配置未写入: CONFIG_${name}=${value}" ;;
    n)   grep -qE "^(# CONFIG_${name} is not set|CONFIG_${name}=n)\$" "$def" \
           || die "配置未关闭: CONFIG_${name}=n" ;;
    *)   grep -qE "^CONFIG_${name}=" "$def" \
           || die "配置未写入: CONFIG_${name}=${value}" ;;
  esac
  info "CONFIG_${name}=${value}"
}

# apply_config_file <文件>：逐行 set_cfg，忽略空行与 # 注释
apply_config_file() {
  local file="$1"
  local line key value
  [ -f "$file" ] || { warn "配置片段不存在，跳过: $file"; return 0; }
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    line="$(printf '%s' "$line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    case "$line" in
      ''|'#'*) continue ;;
    esac
    key="${line%%=*}"
    value="${line#*=}"
    [ "$key" = "$line" ] && value="y"
    set_cfg "$key" "$value"
  done < "$file"
}

# ---------------------------------------------------------------------------
# 补丁
# ---------------------------------------------------------------------------

cleanup_rejects() {
  find "$COMMON" -name '*.rej' -delete 2>/dev/null || true
  find "$COMMON" -name '*.orig' -delete 2>/dev/null || true
}

collect_rejects() {
  local dest="$WS/patch-rejects"
  local found
  found="$(find "$COMMON" "$KROOT" -name '*.rej' 2>/dev/null | head -200 || true)"
  if [ -n "$found" ]; then
    mkdir -p "$dest"
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      cp "$f" "$dest/$(printf '%s' "${f#$WS/}" | tr '/' '_')" 2>/dev/null || true
    done <<< "$found"
    warn "已收集 $(printf '%s\n' "$found" | wc -l) 个 reject 文件到 patch-rejects/"
  fi
}

# apply_patch_file <补丁> [标签]
# 先 dry-run 精确应用（fuzz=0）；失败且允许 fuzz 时用 -F3 重试；
# 仍失败则收集 .rej 并退出，绝不"带病继续编译"。
apply_patch_file() {
  local patch_file="$1"
  local label="${2:-$(basename "$1")}"
  local log_file="$OUT/patch.log"

  [ -s "$patch_file" ] || die "补丁文件不存在或为空: $patch_file"

  if ( cd "$COMMON" && patch -p1 --dry-run -N -F0 --batch < "$patch_file" ) > "$log_file" 2>&1; then
    ( cd "$COMMON" && patch -p1 -N -F0 --batch < "$patch_file" ) | sed 's/^/    /'
    log "补丁已应用: $label"
    return 0
  fi

  if is_true "${ALLOW_PATCH_FUZZ:-true}"; then
    warn "精确应用失败，改用 fuzz=3 重试: $label"
    if ( cd "$COMMON" && patch -p1 --dry-run -N -F3 --batch < "$patch_file" ) > "$log_file" 2>&1; then
      ( cd "$COMMON" && patch -p1 -N -F3 --batch < "$patch_file" ) | sed 's/^/    /'
      log "补丁已应用（fuzz=3）: $label"
      return 0
    fi
  fi

  sed 's/^/    /' "$log_file" || true
  ( cd "$COMMON" && patch -p1 -N -F3 --batch < "$patch_file" ) > "$log_file" 2>&1 || true
  collect_rejects
  die "补丁无法应用: $label（详见上方输出与 patch-rejects 工件）"
}

# apply_patch_optional <补丁> [标签]：失败只告警，不中断构建
apply_patch_optional() {
  local patch_file="$1"
  local label="${2:-$(basename "$1")}"
  if ( cd "$COMMON" && patch -p1 --dry-run -N -F0 --batch < "$patch_file" ) > /dev/null 2>&1; then
    ( cd "$COMMON" && patch -p1 -N -F0 --batch < "$patch_file" ) | sed 's/^/    /'
    log "补丁已应用: $label"
    return 0
  fi
  if ( cd "$COMMON" && patch -p1 --dry-run -N -F3 --batch < "$patch_file" ) > /dev/null 2>&1; then
    ( cd "$COMMON" && patch -p1 -N -F3 --batch < "$patch_file" ) | sed 's/^/    /'
    log "补丁已应用（fuzz=3）: $label"
    return 0
  fi
  warn "补丁跳过（不适用当前源码）: $label"
  return 1
}

# 下载并执行远端 setup.sh（NoMount / Baseband Guard 都提供这种安装方式）
# run_remote_setup <url> <workdir> [传给 setup.sh 的参数...]
run_remote_setup() {
  local url="$1"
  local workdir="$2"
  shift 2
  local dest="$OUT/$(basename "$url" .sh)-runner.sh"
  retry 5 curl -fsSL --retry 5 --retry-delay 3 "$url" -o "$dest"
  [ -s "$dest" ] || die "下载失败: $url"
  chmod +x "$dest"
  info "执行 $(basename "$url") (cwd=$workdir, args=$*)"
  ( cd "$workdir" && bash "$dest" "$@" )
}
