#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# 一条命令回答："我们这个包和手机出厂的 ABI 到底差在哪？"
#
#   bash scripts/check-abi.sh <zip 或 Image> [出厂配置路径]
#
# 默认拿 config/device/gki_defconfig 当出厂配置（先跑 get-device-config.sh 生成）。
# 不构建、不刷机、不改手机。
# ---------------------------------------------------------------------------
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/lib.sh"
set +e

target="${1:-}"
[ -n "$target" ] || die "用法: bash scripts/check-abi.sh <zip 或 Image> [出厂配置路径]"
[ -f "$target" ] || die "文件不存在: $target"

stock="${2:-$WS/config/device/gki_defconfig}"
if [ ! -s "$stock" ]; then
  warn "找不到出厂配置: $stock"
  info "先生成：bash scripts/get-device-config.sh"
  exit 2
fi

PY_BIN="$(command -v python3 || command -v python || true)"
[ -n "$PY_BIN" ] || die "需要 python3 或 python"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp" 2>/dev/null || true' EXIT

case "$target" in
  *.zip)
    command -v unzip >/dev/null 2>&1 || die "需要 unzip"
    info "解包 $(basename "$target")"
    unzip -q "$target" -d "$tmp"
    image="$tmp/Image"
    ;;
  *)
    image="$target"
    ;;
esac
[ -f "$image" ] || die "找不到 Image（zip 结构不对？）"

log "导出包内 .config"
"$PY_BIN" "$SCRIPT_DIR/py/inspect_image.py" "$image" --dump-config "$tmp/ours.config" >/dev/null
[ -s "$tmp/ours.config" ] || die "导出 .config 失败"

log "与出厂配置比对 ABI 敏感项"
"$PY_BIN" "$SCRIPT_DIR/py/check_config_parity.py" "$tmp/ours.config" "$stock" --strict
rc=$?

echo
if [ "$rc" -eq 0 ]; then
  info "结论：这个包的 ABI 与出厂一致，厂商模块可以加载。"
  info "如果它还是起不来，问题不在 config —— 别再重编了，直接查引导链/刷写。"
else
  warn "结论：ABI 敏感项与出厂不一致，厂商模块必然加载失败 -> 卡 logo。"
  warn "修法：config_mode=device 重新构建（用出厂配置当 defconfig）。"
fi
exit "$rc"
