#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# 编译阶段：Kleaf(Bazel) 构建 → 取出 Image 与最终 .config → 校验关键配置
# ---------------------------------------------------------------------------
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
source "$SCRIPT_DIR/lib.sh"

PAGE_SIZE="${PAGE_SIZE:-4k}"
ROOT_MANAGER="${ROOT_MANAGER:-none}"
SUSFS_ON="${SUSFS:-false}"

cd "$KROOT"

# LTO：官方 GKI release 走 thin。--config=fast 自己会把 LTO 关成 none，
# 所以 --lto 必须排在 --config=fast **之后**才能覆盖它。
LTO="${LTO:-thin}"
ARGS=(--config=fast)
case "$LTO" in
  thin|full) ARGS+=(--lto="$LTO") ;;
  none)      ARGS+=(--lto=none) ;;
  *)         die "不支持的 LTO: $LTO（可选 thin / full / none）" ;;
esac
case "$PAGE_SIZE" in
  4k)   ;;
  16k)  ARGS+=(--page_size=16k) ;;
  *)    die "不支持的页大小: $PAGE_SIZE（仅支持 4k / 16k）" ;;
esac

export KBUILD_BUILD_USER="${KBUILD_BUILD_USER:-k90builder}"
export KBUILD_BUILD_HOST="${KBUILD_BUILD_HOST:-github-actions}"

log "开始编译: tools/bazel build ${ARGS[*]} //common:kernel_aarch64/Image"
info "内存信息:"; free -h || true
info "磁盘信息:"; df -h "$KROOT" || true

# 不做失败重试：编译错误需要人看日志，重试只会浪费时间
tools/bazel build "${ARGS[@]}" //common:kernel_aarch64/Image

# ---------------------------------------------------------------------------
# 产物收集
# ---------------------------------------------------------------------------
IMAGE="bazel-bin/common/kernel_aarch64/Image"
[ -f "$IMAGE" ] || die "构建结束但找不到 ${IMAGE}"
cp "$IMAGE" "$OUT/Image"
info "Image: $(du -h "$OUT/Image" | cut -f1)"

CONFIG_FILE=""
for candidate in \
  "bazel-bin/common/kernel_aarch64_config/out_dir/.config" \
  "bazel-bin/common/kernel_aarch64_config/.config"; do
  if [ -f "$candidate" ]; then CONFIG_FILE="$candidate"; break; fi
done
if [ -z "$CONFIG_FILE" ]; then
  CONFIG_FILE="$(find bazel-bin/common -maxdepth 5 -name '.config' -type f 2>/dev/null | head -n1 || true)"
fi
[ -n "$CONFIG_FILE" ] || die "找不到生成的 .config，无法校验配置"
cp "$CONFIG_FILE" "$OUT/kernel.config"
log "配置来自: $CONFIG_FILE"

# ---------------------------------------------------------------------------
# 校验：宁可构建失败，也不要产出"看起来能用"的包
# ---------------------------------------------------------------------------
fail=0
check_on() {
  local sym="$1"
  if grep -qx "CONFIG_${sym}=y" "$OUT/kernel.config"; then
    info "OK  CONFIG_${sym}=y"
  else
    warn "缺少 CONFIG_${sym}=y"
    fail=1
  fi
}
check_off() {
  local sym="$1"
  if grep -qx "CONFIG_${sym}=n" "$OUT/kernel.config" || grep -qx "# CONFIG_${sym} is not set" "$OUT/kernel.config"; then
    info "OK  CONFIG_${sym} 未启用"
  else
    warn "CONFIG_${sym} 仍处于启用状态"
    fail=1
  fi
}

if [ "$ROOT_MANAGER" != "none" ]; then
  check_on KSU
  if is_true "$SUSFS_ON"; then
    check_on KSU_SUSFS
    # SUSFS 的字符串会留在 .rodata，数量为 0 说明编译阶段被裁掉了
    info "Image 中 susfs 字符串数量: $(grep -ac susfs "$OUT/Image" || true)"
  fi
fi
is_true "${NOMOUNT:-false}"     && check_on NOMOUNT
is_true "${BBG:-false}"         && check_on BBG
is_true "${NTSYNC:-false}"      && check_on NTSYNC
is_true "${BPF:-false}"         && check_on DEBUG_INFO_BTF

if [ "$PAGE_SIZE" = "16k" ]; then
  check_on ARM64_16K_PAGES
  check_off ARM64_4K_PAGES
else
  check_on ARM64_4K_PAGES
  check_off ARM64_16K_PAGES
fi

if [ "$fail" -ne 0 ]; then
  warn "配置校验未全部通过，最后 60 行 KSU/SUSFS 相关配置："
  grep -E 'CONFIG_(KSU|NOMOUNT|BBG|NTSYNC|DEBUG_INFO_BTF|ARM64_.*PAGES)' "$OUT/kernel.config" | head -60 || true
  die "配置校验失败，终止打包（避免产出不可用的内核）"
fi

# 记录真实内核版本号，打包与 Release 说明都要用
KERNEL_RELEASE="$(grep -a -o -m1 'Linux version [^ ]*' "$OUT/Image" | awk '{print $3}' || true)"
[ -n "$KERNEL_RELEASE" ] || KERNEL_RELEASE="unknown"
info "内核 release 字符串: $KERNEL_RELEASE"
echo "$KERNEL_RELEASE" > "$OUT/kernel-release.txt"
echo "KERNEL_RELEASE=${KERNEL_RELEASE}" >> "${GITHUB_ENV:-/dev/null}"

# ---------------------------------------------------------------------------
# 与出厂配置做 ABI 对齐检查（有 config/device/gki_defconfig 时才做）
# ---------------------------------------------------------------------------
DEVICE_CFG="$WS/config/device/gki_defconfig"
if [ -s "$DEVICE_CFG" ]; then
  log "与出厂配置比对 ABI 敏感项"
  if ! python3 "$WS/scripts/py/check_config_parity.py" "$OUT/kernel.config" "$DEVICE_CFG" --strict; then
    die "ABI 敏感项与出厂不一致，终止打包（厂商模块会全部加载失败）"
  fi
else
  warn "没有 config/device/gki_defconfig，跳过出厂 ABI 比对"
  warn "建议先跑 scripts/get-device-config.sh 把出厂配置取回来"
fi

log "编译完成"
