#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# 刷机前 / 刷机后自检：只读，不改手机任何东西
#
#   bash scripts/check-device.sh
#
# 主要回答三个问题：
#   1. 现在跑的是不是内置 KSU 的内核（GKI 模式）？
#   2. init_boot 里是不是还留着 LKM 塞进去的 kernelsu.ko？（卡 Logo 头号原因）
#   3. 页大小 / KMI / 安全补丁级别，和要刷的包对不对得上？
# ---------------------------------------------------------------------------
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"
set +e   # lib.sh 开了 errexit；本脚本要容忍单条 adb 命令失败

command -v adb >/dev/null 2>&1 || die "找不到 adb，请先把 platform-tools 加进 PATH"

if ! adb get-state >/dev/null 2>&1; then
  die "没有检测到设备（adb devices 为空，或未授权 USB 调试）"
fi

sh_get() { adb shell "$1" 2>/dev/null | tr -d '\r' | tr -d '\n'; }
# 需要 root 的命令，失败时返回空串
sh_root() { adb shell "su -c '$1'" 2>/dev/null | tr -d '\r' | tr -d '\n'; }

log "设备信息"
DEVICE="$(sh_get 'getprop ro.product.device')"
MODEL="$(sh_get 'getprop ro.product.model')"
SLOT="$(sh_get 'getprop ro.boot.slot_suffix')"
RELEASE="$(sh_get 'uname -r')"
PAGESIZE="$(sh_get 'getconf PAGESIZE')"
SPL="$(sh_get 'getprop ro.build.version.security_patch')"
BUILD_ID="$(sh_get 'getprop ro.build.display.id')"

info "机型          : ${MODEL:-?} (${DEVICE:-?})"
info "当前槽位      : ${SLOT:-A-only}"
info "内核版本      : ${RELEASE:-?}"
info "页大小        : ${PAGESIZE:-?}  $([ "${PAGESIZE:-0}" = "4096" ] && echo '(4K，与默认构建一致)' || echo '(注意：构建时 page_size 要与它一致)')"
info "安全补丁      : ${SPL:-?}"
info "版本号        : ${BUILD_ID:-?}"

KMI="$(printf '%s' "$RELEASE" | awk -F'-' '{split($1,a,"."); if (a[2] != "") printf "%s.%s-%s-%s\n", a[1], a[2], $2, $3}')"
info "KMI           : ${KMI:-?}  （sublevel 不算 KMI；构建时 manifest_branch 要与它同代）"

# ---------------------------------------------------------------------------
log "Root 状态"
MOD_CNT="$(sh_get 'grep -c "^kernelsu" /proc/modules 2>/dev/null')"
[ -z "$MOD_CNT" ] && MOD_CNT=0
SYS_MOD="$(sh_get 'ls -d /sys/module/kernelsu 2>/dev/null')"
VERDICT="unknown"
if [ "$MOD_CNT" -gt 0 ] 2>/dev/null; then
  VERDICT="lkm"
elif [ -n "$SYS_MOD" ]; then
  VERDICT="gki"
fi

case "$VERDICT" in
  lkm) info "KernelSU      : 以 **LKM 模块**方式运行（/proc/modules 里有 kernelsu）" ;;
  gki) info "KernelSU      : 已内置进内核（/sys/module/kernelsu 存在，且不在 /proc/modules）" ;;
  *)   info "KernelSU      : 未检测到（未 root，或管理器与本内核不匹配）" ;;
esac

# ---------------------------------------------------------------------------
log "init_boot 是否被 LKM 改过（卡 Logo 头号原因）"
INITBOOT_HIT=""
if [ "$VERDICT" = "lkm" ] || [ -n "$(sh_root 'ls /data/adb/ksu 2>/dev/null')" ]; then
  INITBOOT_HIT="$(sh_root 'grep -ac kernelsu /dev/block/by-name/init_boot 2>/dev/null')"
fi

if [ -n "$INITBOOT_HIT" ] && [ "$INITBOOT_HIT" != "0" ] 2>/dev/null; then
  warn "init_boot 里发现 kernelsu 字样（${INITBOOT_HIT} 处）—— 这份 init_boot 被 LKM 改过"
  warn "直接刷 GKI 内核包（KSU 内置）会与它冲突，表现就是卡 Logo"
  echo
  echo "  先恢复基座，再刷内核包："
  echo "    fastboot flash boot      stock_boot.img"
  echo "    fastboot flash init_boot stock_init_boot.img"
  echo "  或者在管理器首页 ->「卸载」->「恢复原厂镜像」"
elif [ "$VERDICT" = "lkm" ]; then
  warn "内核以 LKM 运行，但读不到 init_boot（可能没 root 权限）"
  warn "请在管理器首页确认「工作模式」，若是 LKM 就要先恢复原厂 boot + init_boot"
else
  info "init_boot        未见 LKM 残留（或无法读取）"
fi

# ---------------------------------------------------------------------------
echo
log "结论"
if [ "$VERDICT" = "lkm" ]; then
  echo
  warn "当前是 LKM 模式：可以刷，但**必须先恢复原厂 boot + init_boot**。"
  warn "LKM 只改 ramdisk（init_boot），本仓库的包只换 boot 里的内核，"
  warn "两份 KSU 会打架 —— 这就是上次卡 Logo 的原因。"
elif [ "$PAGESIZE" = "4096" ]; then
  echo
  info "基座看起来是干净的，且页大小为 4K —— 可以直接刷本仓库的包（page_size=4k）。"
else
  echo
  warn "页大小是 ${PAGESIZE:-未知}，与默认的 4K 构建不一致，构建时请相应调整 page_size。"
fi

echo
info "刷完后复跑本脚本，预期看到："
info "  内核版本 -> 6.6.x-android15-8-4k（不再是出厂版本）"
info "  KernelSU -> 已内置进内核"
info "  init_boot -> 未见 LKM 残留"
