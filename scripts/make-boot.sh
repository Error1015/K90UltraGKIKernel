#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# 把某个刷机包里的内核，按原厂 boot.img 的格式精确写回去，产出可直接刷的 boot.img。
#
#   bash scripts/make-boot.sh <zip 或 Image> <原厂 boot.img> [-o 输出路径]
#
# 用途：绕开 AnyKernel3 / magiskboot 的重打包，彻底排除"打包环节把镜像搞坏"这个变量。
# 只改 header 里的 kernel_size，其余字节原样保留（含 os_version / cmdline / 对齐方式）。
#
# 刷入（推荐先临时启动，不写分区）：
#   fastboot boot boot-k90-custom.img
# 确认能开机后再：
#   fastboot flash boot boot-k90-custom.img
# ---------------------------------------------------------------------------
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/lib.sh"
set +e

src="${1:-}"
stock="${2:-}"
[ -n "$src" ] && [ -n "$stock" ] || die "用法: bash scripts/make-boot.sh <zip 或 Image> <原厂 boot.img> [-o 输出]"
[ -f "$src" ] || die "文件不存在: $src"
[ -f "$stock" ] || die "文件不存在: $stock"

out="$(cd "$SCRIPT_DIR/.." && pwd)/boot-k90-custom.img"
if [ "${3:-}" = "-o" ] && [ -n "${4:-}" ]; then out="$4"; fi

PY_BIN="$(command -v python3 || command -v python || true)"
[ -n "$PY_BIN" ] || die "需要 python3 或 python"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp" 2>/dev/null || true' EXIT

case "$src" in
  *.zip)
    command -v unzip >/dev/null 2>&1 || die "需要 unzip"
    info "解包 $(basename "$src") 取 Image"
    unzip -q "$src" -d "$tmp"
    image="$tmp/Image"
    ;;
  *)
    image="$src"
    ;;
esac
[ -f "$image" ] || die "找不到 Image"

log "按原厂格式重打包"
"$PY_BIN" "$SCRIPT_DIR/py/repack_boot.py" "$stock" "$image" -o "$out"
rc=$?
[ "$rc" -eq 0 ] || die "重打包失败"

echo
log "产物"
info "$(ls -l "$out" | awk '{print $5" 字节"}')  $out"
echo
info "先临时启动（不写分区，重启即恢复）："
info "  fastboot boot \"$out\""
info "确认能进系统后再正式刷入："
info "  fastboot flash boot \"$out\""
exit 0
