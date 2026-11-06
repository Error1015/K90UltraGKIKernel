#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# 把手机**出厂内核**的配置取回来，存成 config/device/gki_defconfig
#
#   bash scripts/get-device-config.sh
#
# 用途：构建时用 config_mode=device，内核配置与出厂完全一致，只有 root / 功能开关
# 是叠加的。这样"配置差异导致卡标"这个变量就被彻底消掉了。
#
# 只读操作：仅从手机读 /proc/config.gz，不改动任何分区。
# ---------------------------------------------------------------------------
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/lib.sh"
set +e

command -v adb >/dev/null 2>&1 || die "找不到 adb，请先把 platform-tools 加进 PATH"
adb get-state >/dev/null 2>&1 || die "没有检测到设备（adb devices 为空，或未授权 USB 调试）"

DEST_DIR="$SCRIPT_DIR/../config/device"
DEST="$DEST_DIR/gki_defconfig"
mkdir -p "$DEST_DIR"

TMPD="$(mktemp -d)"
trap 'rm -rf "$TMPD"' EXIT

log "从设备读取 /proc/config.gz"
RAW="$TMPD/config.gz"

# 普通应用也能读；读不到再试 root
adb exec-out "cat /proc/config.gz" > "$RAW" 2>/dev/null
if [ ! -s "$RAW" ] || ! gzip -t "$RAW" 2>/dev/null; then
  warn "直接读取失败，尝试 root"
  adb shell "su -c 'dd if=/proc/config.gz bs=1M 2>/dev/null'" > "$RAW" 2>/dev/null
fi
[ -s "$RAW" ] && gzip -t "$RAW" 2>/dev/null || die "读不到 /proc/config.gz（内核未开 CONFIG_IKCONFIG_PROC，或权限不足）"

python3 - "$RAW" "$DEST" <<'PY'
import gzip, sys, pathlib

raw, dest = sys.argv[1], sys.argv[2]
cfg = gzip.open(raw, "rb").read().decode("utf-8", "replace")
lines = cfg.splitlines()

# .config 里这些是构建环境产物，塞进 defconfig 没意义
DROP_PREFIX = (
    "CONFIG_CC_VERSION_TEXT", "CONFIG_GCC_VERSION", "CONFIG_CC_IS_",
    "CONFIG_CLANG_VERSION", "CONFIG_LD_VERSION", "CONFIG_AS_VERSION",
    "CONFIG_PAHOLE_VERSION", "CONFIG_RUSTC_VERSION", "CONFIG_CC_HAS_",
    "CONFIG_LOCALVERSION_AUTO",
)
keep, dropped = [], 0
for line in lines:
    key = line.split("=", 1)[0].replace("# ", "").replace(" is not set", "")
    if key.startswith(DROP_PREFIX):
        dropped += 1
        continue
    keep.append(line)

pathlib.Path(dest).write_text("\n".join(keep) + "\n", encoding="utf-8")
print(f"    写入 {dest}")
print(f"    保留 {len(keep)} 行，丢弃 {dropped} 行构建环境项")
PY

[ -s "$DEST" ] || die "写入失败"

grep -q '^CONFIG_ARM64=y' "$DEST" || die "取到的文件不像 arm64 内核配置，已中止"

log "出厂配置关键项"
show() {
  local pat="$1" label="$2"
  local val
  val="$(grep -m1 -E "$pat" "$DEST" || true)"
  info "${label}: ${val:-（未出现）}"
}
show '^CONFIG_LOCALVERSION='      "LOCALVERSION "
show '^CONFIG_ARM64_(4K|16K)_PAGES=y' "页大小       "
show '^CONFIG_MODVERSIONS='       "MODVERSIONS  "
show '^CONFIG_MODULE_SIG='        "MODULE_SIG   "
show '^CONFIG_CFI_CLANG='         "CFI_CLANG    "
show '^CONFIG_LTO_CLANG_THIN=|^CONFIG_LTO_NONE=|^CONFIG_LTO_CLANG=' "LTO          "
show '^CONFIG_TRIM_UNUSED_KSYMS=' "TRIM_KSYMS   "
show '^CONFIG_KALLSYMS_ALL='      "KALLSYMS_ALL "
show '^CONFIG_OVERLAY_FS='        "OVERLAY_FS   "
show '^CONFIG_MODULE_SIG_PROTECT=' "SIG_PROTECT  "

echo
log "下一步"
info "1) 提交这份配置：git add config/device/gki_defconfig && git commit"
info "2) 构建时 config_mode 选 device（可与 preset=vanilla 组合，先验证基础内核）"
info "   也可以在 overlay 模式下对比：diff <(sort config/device/gki_defconfig) <(sort 你的产物配置)"
