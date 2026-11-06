#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# 打包阶段：AnyKernel3 刷机包 + 构建说明
# ---------------------------------------------------------------------------
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
source "$SCRIPT_DIR/lib.sh"

ANYKERNEL3_REPO="${ANYKERNEL3_REPO:-https://github.com/WildKernels/AnyKernel3.git}"
ANYKERNEL3_BRANCH="${ANYKERNEL3_BRANCH:-gki-2.0}"
BRAND="${BRAND:-K90Ultra}"
PAGE_SIZE="${PAGE_SIZE:-4k}"
PRESET="${PRESET:-safe}"
ROOT_MANAGER="${ROOT_MANAGER:-none}"
SUSFS_ON="${SUSFS:-false}"

KERNEL_RELEASE="$(cat "$OUT/kernel-release.txt" 2>/dev/null || echo unknown)"

[ -f "$OUT/Image" ] || die "缺少 $OUT/Image，编译阶段没有产出？"

log "准备 AnyKernel3"
AK3="$WS/AnyKernel3"
rm -rf "$AK3"
retry 3 git clone --depth=1 -b "$ANYKERNEL3_BRANCH" "$ANYKERNEL3_REPO" "$AK3"
rm -rf "$AK3/.git"

cp "$OUT/Image" "$AK3/Image"

# 尽量把内核名写进 anykernel.sh（不同分支字段名可能不同，找不到就跳过）
if [ -f "$AK3/anykernel.sh" ]; then
  if grep -q '^kernel\.string=' "$AK3/anykernel.sh"; then
    sed -i "s|^kernel\.string=.*|kernel.string=${BRAND} GKI (${ROOT_MANAGER})|" "$AK3/anykernel.sh"
  fi
  if grep -q '^do\.modules=' "$AK3/anykernel.sh"; then
    # 只替换 boot 分区里的内核，不碰 vendor_boot / vendor_dlkm
    sed -i 's|^do\.modules=.*|do.modules=0|' "$AK3/anykernel.sh"
  fi
  info "anykernel.sh 已按 GKI 场景微调"
fi

# ---------------------------------------------------------------------------
# 文件名
# ---------------------------------------------------------------------------
ROOT_LABEL="$ROOT_MANAGER"
[ "$ROOT_LABEL" = "none" ] && ROOT_LABEL="noroot"
SUSFS_LABEL="nosusfs"
is_true "$SUSFS_ON" && SUSFS_LABEL="susfs"
DATE_TAG="$(date -u +%Y%m%d-%H%M)"

ZIP_NAME="${BRAND}-GKI-${KERNEL_RELEASE}-${ROOT_LABEL}-${SUSFS_LABEL}-${PRESET}-${PAGE_SIZE}-${DATE_TAG}.zip"
ZIP_PATH="$OUT/$ZIP_NAME"

log "打包刷机包: $ZIP_NAME"
( cd "$AK3" && zip -r9 "$ZIP_PATH" . -x '*.git*' > /dev/null )
info "$(du -h "$ZIP_PATH" | cut -f1)"

echo "ZIP_PATH=${ZIP_PATH}" >> "${GITHUB_ENV:-/dev/null}"
echo "ZIP_NAME=${ZIP_NAME}" >> "${GITHUB_ENV:-/dev/null}"
echo "RELEASE_TAG=${BRAND,,}-${ROOT_LABEL}-${PRESET}-${KERNEL_RELEASE}-${DATE_TAG}" >> "${GITHUB_ENV:-/dev/null}"

# ---------------------------------------------------------------------------
# 构建说明（同时作为 Release 正文）
# ---------------------------------------------------------------------------
INFO="$OUT/build-info.md"
{
  echo "## ${BRAND} GKI 内核构建结果"
  echo
  echo "| 项目 | 值 |"
  echo "| --- | --- |"
  echo "| 设备 | Redmi K90 Ultra (warsaw / SM8750) |"
  echo "| 内核版本 | ${KERNEL_RELEASE} |"
  echo "| 页大小 | ${PAGE_SIZE} |"
  echo "| 构建预设 | ${PRESET} |"
  echo "| Root 管理器 | ${ROOT_MANAGER} |"
  echo "| Root commit | ${ROOT_COMMIT:-未知} |"
  echo "| SUSFS | $([ "$SUSFS_LABEL" = susfs ] && echo "启用 (${SUSFS_COMMIT:-未知})" || echo "未启用") |"
  echo "| NoMount | ${NOMOUNT:-false}${NOMOUNT_COMMIT:+ (${NOMOUNT_COMMIT})} |"
  echo "| Baseband Guard | ${BBG:-false} |"
  echo "| DroidSpaces-OSS | ${DROIDSPACES:-false}${DROIDSPACES_COMMIT:+ (${DROIDSPACES_COMMIT})} |"
  echo "| Networking (BBRv3) | ${NETWORKING:-false}${BBRV3_APPLIED:+ (BBRv3=${BBRV3_APPLIED})} |"
  echo "| NTSync | ${NTSYNC:-false} |"
  echo "| Ptrace Fix | ${PTRACE_FIX:-false} |"
  echo "| Unicode Fix | ${UNICODE_FIX:-false} |"
  echo "| BTF/eBPF/FUSE-BPF | ${BPF:-false} |"
  echo "| 源码分支 | ${MANIFEST_BRANCH:-未知} |"
  echo "| 构建时间 (UTC) | $(date -u '+%Y-%m-%d %H:%M') |"
  echo
  echo "### 刷入方式"
  echo
  echo '```'
  echo "# 1) 备份当前 boot 分区（变砖可救）"
  echo "adb shell su -c 'dd if=/dev/block/by-name/boot of=/sdcard/stock_boot.img'"
  echo
  echo "# 2) 用 KernelSU/管理器的『刷入』或 recovery 刷入本 zip，也可用 fastboot："
  echo "#    注意：fastboot 需要先把 zip 里的 Image 通过 mkbootimg 处理，推荐直接用管理器刷 AnyKernel3。"
  echo '```'
  echo
  echo "刷入后安装**对应版本**的管理器 APK：KernelSU / KernelSU-Next / BakaSU / SukiSU-Ultra / KowSU。"
  echo "启用 SUSFS 时还需要装 [susfs4ksu-module](https://github.com/sidex15/susfs4ksu-module) 才能使用全部隐藏功能。"
} > "$INFO"

log "构建说明: $INFO"
