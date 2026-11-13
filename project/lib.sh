#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# 公共函数库（K90 Ultra / warsaw / SM8750 / 6.6 GKI）
# 所有脚本通过 `source project/lib.sh` 引入。
#
# 与旧流水线的区别：不再依赖 Kleaf/Bazel，直接用 Kbuild（make）构建 common，
# 因为这条路径与本机型已真机验证过的构建方式一致。
# ---------------------------------------------------------------------------
set -euo pipefail

WS="${GITHUB_WORKSPACE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

# ---------------------------------------------------------------------------
# 机型 / 内核基准（唯一真源）。用普通赋值，覆盖外部同名环境变量 —— 故意锁死，
# 免得 CI 上一次手滑填错版本，编出一个 KMI 和手机对不上的内核。
# ---------------------------------------------------------------------------
DEVICE_ENV="$WS/project/device.env"
if [ ! -f "$DEVICE_ENV" ]; then
  printf '\033[1;31m[x] 缺少 %s（机型/内核基准）\033[0m\n' "$DEVICE_ENV" >&2
  exit 1
fi
# shellcheck disable=SC1090
. "$DEVICE_ENV"

KROOT="$WS/kernel"        # repo sync 出来的 kernel_platform 根
COMMON="$KROOT/common"    # GKI 通用内核源码（真正的内核树）
OUT="$WS/out"             # O= 构建目录
DIST="$WS/dist"           # 产物目录

mkdir -p "$OUT" "$DIST"

log()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '\033[1;33m[!] %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31m[x] %s\033[0m\n' "$*" >&2; exit 1; }

is_true() {
  case "${1:-}" in
    1|true|TRUE|True|yes|on) return 0 ;;
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
    warn "第 $i 次失败，10 秒后重试: $*"
    sleep 10
    i=$((i + 1))
  done
}

# ---------------------------------------------------------------------------
# 补丁
# ---------------------------------------------------------------------------
cleanup_rejects() {
  find "$1" \( -name '*.rej' -o -name '*.orig' \) -delete 2>/dev/null || true
}

collect_rejects() {
  local dest="$WS/patch-rejects"
  local found
  found="$(find "$KROOT" -name '*.rej' 2>/dev/null | head -200 || true)"
  [ -n "$found" ] || return 0
  mkdir -p "$dest"
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    cp "$f" "$dest/$(printf '%s' "${f#$WS/}" | tr '/' '_')" 2>/dev/null || true
  done <<< "$found"
  warn "已收集 reject 到 patch-rejects/"
}

# apply_patch <目标目录> <补丁> [标签]
# 先 fuzz=0 精确应用；失败退到 -F3；仍失败则收集 .rej 并中断构建。
# 绝不"带病继续编译"——产出一个缺功能的包比构建失败更糟。
apply_patch() {
  local dir="$1" patch_file="$2" label="${3:-$(basename "$2")}"
  local log_file="$OUT/patch.log"

  [ -s "$patch_file" ] || die "补丁文件不存在或为空: $patch_file"

  if ( cd "$dir" && patch -p1 --dry-run -N -F0 --batch < "$patch_file" ) > "$log_file" 2>&1; then
    ( cd "$dir" && patch -p1 -N -F0 --batch < "$patch_file" ) | sed 's/^/    /'
    log "补丁已应用: $label"
    return 0
  fi

  warn "精确应用失败，改用 fuzz=3 重试: $label"
  if ( cd "$dir" && patch -p1 --dry-run -N -F3 --batch < "$patch_file" ) > "$log_file" 2>&1; then
    ( cd "$dir" && patch -p1 -N -F3 --batch < "$patch_file" ) | sed 's/^/    /'
    log "补丁已应用（fuzz=3）: $label"
    return 0
  fi

  sed 's/^/    /' "$log_file" || true
  ( cd "$dir" && patch -p1 -N -F3 --batch < "$patch_file" ) > "$log_file" 2>&1 || true
  collect_rejects
  die "补丁无法应用: $label（reject 见上方输出 / patch-rejects 工件）"
}

# apply_patch_optional <目标目录> <补丁> [标签]：失败只告警，不中断构建
apply_patch_optional() {
  local dir="$1" patch_file="$2" label="${3:-$(basename "$2")}"
  [ -s "$patch_file" ] || { warn "补丁不存在，跳过: $patch_file"; return 1; }
  if ( cd "$dir" && patch -p1 --dry-run -N -F0 --batch < "$patch_file" ) > /dev/null 2>&1; then
    ( cd "$dir" && patch -p1 -N -F0 --batch < "$patch_file" ) | sed 's/^/    /'
    log "补丁已应用: $label"
    return 0
  fi
  if ( cd "$dir" && patch -p1 --dry-run -N -F3 --batch < "$patch_file" ) > /dev/null 2>&1; then
    ( cd "$dir" && patch -p1 -N -F3 --batch < "$patch_file" ) | sed 's/^/    /'
    log "补丁已应用（fuzz=3）: $label"
    return 0
  fi
  warn "补丁跳过（不适用当前源码）: $label"
  return 1
}

# 上游项目用 "curl setup.sh | bash" 的方式安装自己的内核模块（NoMount / BBG）
# run_remote_setup <url> <工作目录> [参数...]
run_remote_setup() {
  local url="$1" workdir="$2"
  shift 2
  local dest="$OUT/$(basename "$url" .sh)-setup.sh"
  retry 5 curl -fsSL --retry 5 --retry-delay 3 "$url" -o "$dest"
  [ -s "$dest" ] || die "下载失败: $url"
  info "执行 $(basename "$url") (cwd=$workdir${*:+, args=$*})"
  ( cd "$workdir" && bash "$dest" "$@" )
}

# ---------------------------------------------------------------------------
# 内核配置：直接写 $OUT/.config，最终由 make olddefconfig 收敛
# ---------------------------------------------------------------------------
_kc() { ( cd "$COMMON" && bash scripts/config --file "$OUT/.config" "$@" ); }

# set_cfg CONFIG_X value   value: y / m / n / 其他（当字符串）
set_cfg() {
  local name="${1#CONFIG_}"
  local value="$2"
  [ -f "$OUT/.config" ] || die "找不到 $OUT/.config"
  case "$value" in
    y) _kc --enable "$name" ;;
    m) _kc --module "$name" ;;
    n) _kc --disable "$name" ;;
    *) _kc --set-str "$name" "$(printf '%s' "$value" | sed -e 's/^"//' -e 's/"$//')" ;;
  esac
  info "CONFIG_${name}=${value}"
}

# apply_fragment <片段文件>
apply_fragment() {
  local file="$1" line key value
  [ -f "$file" ] || { warn "配置片段不存在，跳过: $file"; return 0; }
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    line="$(printf '%s' "$line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    case "$line" in ''|'#'*) continue ;; esac
    key="${line%%=*}"
    value="${line#*=}"
    [ "$key" = "$line" ] && value="y"
    set_cfg "$key" "$value"
  done < "$file"
}

# require_cfg <CONFIG_X> [期望值=y]
# 在 make olddefconfig 之后回读：Kconfig 依赖不满足时符号会被静默丢掉，
# 因此必须校验"最终 .config"而不是"我们写进去的片段"。
require_cfg() {
  local name="${1#CONFIG_}" want="${2:-y}" file="${3:-$OUT/.config}"
  case "$want" in
    n) grep -qE "^(# CONFIG_${name} is not set|CONFIG_${name}=n)\$" "$file" \
         || die "期望 CONFIG_${name}=n 但配置不是（依赖被拉起？）" ;;
    y|m) grep -qE "^CONFIG_${name}=${want}\$" "$file" \
         || die "期望 CONFIG_${name}=${want} 但最终配置里没有（Kconfig 依赖不满足）" ;;
    *)   # 字符串值：scripts/config --set-str 写出来带引号，比较前先剥掉
         local got
         got="$(sed -n "s/^CONFIG_${name}=//p" "$file" | head -1)"
         got="${got%\"}"; got="${got#\"}"
         [ "$got" = "$want" ] \
           || die "期望 CONFIG_${name}=\"${want}\"，实际为 \"${got:-未设置}\"" ;;
  esac
  info "[OK] CONFIG_${name}=${want}"
}

# 与 require_cfg 的区别：符号在该 root 的 Kconfig 里压根不存在时不算错。
# Kconfig 不认识的符号会被 olddefconfig 整个丢掉，最终 .config 里连
# "# CONFIG_X is not set" 都不会留 —— 两种情况必须分开对待：
#   · 存在但没生效 → 硬失败（依赖不满足 / 被别的符号顶掉）
#   · 压根不存在   → 提示后跳过（该 root 没这个能力，比如 BakaSU 没有
#                    KSU_SUSFS_PRIORITY_UID_FILTER）
expect_cfg() {
  local name="${1#CONFIG_}" want="${2:-y}" file="${3:-$OUT/.config}"
  if grep -qE "^(CONFIG_${name}=|# CONFIG_${name} is not set)" "$file"; then
    require_cfg "$name" "$want" "$file"
  else
    warn "CONFIG_${name} 在该 root 的 Kconfig 里不存在，跳过（对应功能不可用）"
  fi
}
