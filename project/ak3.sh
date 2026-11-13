#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# 把已经打好的完整 boot.img 封成 AnyKernel3 的 zip
#
# 包内不装内核、不做重打包 —— AK3 只负责在设备上把整分区镜像 dd 进 boot。
# 原因见 ak3/anykernel.sh 头部：这台机器 boot 分区里有 vbmeta blob 和 AVB footer，
# "只换内核再 repack" 一定会把它们弄坏，结果就是卡 logo。
#
# 用法: project/ak3.sh <boot.img> <输出.zip> [kernel.string] [device]
# ---------------------------------------------------------------------------
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BOOT_IMG="${1:-}"
OUT_ZIP="${2:-}"
KSTRING="${3:-K90 Ultra (warsaw) GKI}"
DEVICE="${4:-warsaw}"
DEVICE_ALT="${DEVICE_ALT:-}"

[ -n "$BOOT_IMG" ] || die "用法: project/ak3.sh <boot.img> <输出.zip> [kernel.string] [device]"
[ -n "$OUT_ZIP" ]  || die "用法: project/ak3.sh <boot.img> <输出.zip> [kernel.string] [device]"
[ -f "$BOOT_IMG" ] || die "找不到 $BOOT_IMG"

# 输出路径立刻转成绝对路径。
# 打包时要在临时目录里 cd（zip 必须从内容根目录压），相对路径一 cd 就失效，
# 表现为 zip 报 "zip I/O error: No such file or directory"。
mkdir -p "$(dirname "$OUT_ZIP")"
OUT_ZIP="$(cd "$(dirname "$OUT_ZIP")" && pwd)/$(basename "$OUT_ZIP")"
BOOT_IMG="$(cd "$(dirname "$BOOT_IMG")" && pwd)/$(basename "$BOOT_IMG")"

IMGSZ=$(stat -c %s "$BOOT_IMG")

# 整分区镜像必须和 boot 分区等长，否则设备上 dd 会留下旧尾部
if [ -f "$WS/firmware/boot-template.json" ]; then
  PART=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["partition_size"])' \
         "$WS/firmware/boot-template.json")
  if [ "$IMGSZ" != "$PART" ]; then
    warn "镜像大小 $IMGSZ 与分区大小 $PART 不一致，设备上会先清零整区再写入"
  else
    info "镜像大小 : $IMGSZ（= 分区大小）"
  fi
fi

# ---------------------------------------------------------------------------
log "取 AnyKernel3 骨架"
# ---------------------------------------------------------------------------
TPL="$WS/.ak3-template"
[ -f "$TPL/tools/ak3-core.sh" ] || {
  rm -rf "$TPL"
  retry 3 git clone --depth 1 https://github.com/osm0sis/AnyKernel3 "$TPL" \
    || die "clone AnyKernel3 失败"
}
if [ -d "$TPL/.git" ]; then
  info "骨架 : $(git -C "$TPL" rev-parse --short HEAD 2>/dev/null || echo 未知)"
else
  info "骨架 : 已缓存的本地副本"
fi

# ---------------------------------------------------------------------------
log "组装 zip"
# ---------------------------------------------------------------------------
BUILD=$(mktemp -d)
trap 'rm -rf "$BUILD"' EXIT

cp -a "$TPL/META-INF" "$BUILD/"
cp -a "$TPL/tools"    "$BUILD/"
[ -f "$TPL/LICENSE" ] && cp -a "$TPL/LICENSE" "$BUILD/"

# update-binary / busybox 必须是可执行
chmod -R 755 "$BUILD/META-INF/com/google/android/update-binary" 2>/dev/null || true
chmod 755 "$BUILD/tools/"* 2>/dev/null || true

cp "$BOOT_IMG" "$BUILD/boot.img"

esc() { printf '%s' "$1" | sed -e 's/[\/&]/\\&/g'; }
sed -e "s/@KERNEL_STRING@/$(esc "$KSTRING")/g" \
    -e "s/@DEVICE@/$(esc "$DEVICE")/g" \
    -e "s/@DEVICE_ALT@/$(esc "$DEVICE_ALT")/g" \
    "$WS/ak3/anykernel.sh" > "$BUILD/anykernel.sh"
chmod 755 "$BUILD/anykernel.sh"

# 版本信息，AK3 会在安装界面打印
{
  echo "kernel : $KSTRING"
  echo "image  : $(basename "$BOOT_IMG") ($IMGSZ 字节)"
  echo "built  : $(date -u '+%Y-%m-%d %H:%M UTC')"
} > "$BUILD/version"

rm -f "$OUT_ZIP"
pack_zip() {
  local dir="$1" out="$2"
  if command -v zip >/dev/null 2>&1; then
    ( cd "$dir" && zip -r9 -q "$out" . )
  else
    # 本机（Windows/精简环境）常常没有 zip，用 python 的 zipfile 兜底。
    # z.write 会保留 st_mode，update-binary / busybox 的执行位不会丢。
    warn "没有 zip 命令，改用 python3 zipfile"
    python3 - "$dir" "$out" <<'PY'
import os, sys, zipfile
root, out = sys.argv[1], sys.argv[2]
with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as z:
    for dp, dns, fns in os.walk(root):
        dns.sort(); fns.sort()
        for d in dns:
            rel = os.path.relpath(os.path.join(dp, d), root).replace("\\", "/") + "/"
            zi = zipfile.ZipInfo(rel)
            zi.external_attr = (0o40755 << 16) | 0x10
            z.writestr(zi, b"")
        for f in fns:
            p = os.path.join(dp, f)
            z.write(p, os.path.relpath(p, root).replace("\\", "/"))
PY
  fi
}
pack_zip "$BUILD" "$OUT_ZIP" || die "打包 zip 失败"
[ -s "$OUT_ZIP" ] || die "打包后 zip 不存在或为空：$OUT_ZIP"

ZIPSZ=$(stat -c %s "$OUT_ZIP")
info "生成 : $OUT_ZIP（$ZIPSZ 字节）"

# ---------------------------------------------------------------------------
log "包内容自检"
# ---------------------------------------------------------------------------
unzip -l "$OUT_ZIP" | grep -E 'anykernel\.sh|boot\.img|update-binary|ak3-core\.sh' | sed 's/^/    /'
for need in anykernel.sh boot.img META-INF/com/google/android/update-binary tools/ak3-core.sh; do
  unzip -l "$OUT_ZIP" | grep -q " $need$" || die "zip 里缺 $need"
done
info "[OK] 四个必需项都在"

# 占位符必须替换干净，否则设备上会打印出 @KERNEL_STRING@
if unzip -p "$OUT_ZIP" anykernel.sh | grep -q '@[A-Z_]*@'; then
  die "anykernel.sh 里还有没替换的占位符"
fi
info "[OK] 占位符已全部替换"

# boot.img 必须是原样的那个镜像
TMP=$(mktemp)
unzip -p "$OUT_ZIP" boot.img > "$TMP"
if [ "$(stat -c %s "$TMP")" = "$IMGSZ" ] && cmp -s "$TMP" "$BOOT_IMG"; then
  info "[OK] 包内 boot.img 与产物逐字节一致"
else
  rm -f "$TMP"; die "包内 boot.img 与产物不一致"
fi
rm -f "$TMP"

log "完成"
