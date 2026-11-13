### AnyKernel3 Ramdisk Mod Script
## warsaw (Redmi K90 Ultra / SM8750) 专用
##
## 与常见 AK3 的区别：这台机器的 boot 分区不是「内核 + ramdisk」两段式，而是
##
##   [0,4096)   boot header v4（ramdisk_size=0）
##   [4096,...] 内核 Image
##   页对齐处    vbmeta blob（AVB0 hash footer）
##   末尾 64 字节 AVB footer（original_image_size / vbmeta_offset / vbmeta_size）
##
## 所以不能用 dump_boot + write_boot 那套「只换内核再重打包」的流程 ——
## magiskboot 重打包出来的镜像里没有那块 vbmeta，也没有 footer，写回去就是卡 logo。
##
## 这里直接写整个分区镜像：镜像由 CI 侧 pack.py 生成（vbmeta 已重定位、footer 已重写、
## 总长与分区一致），设备上只做 dd，不做任何重打包。

### AnyKernel setup
properties() { '
kernel.string=@KERNEL_STRING@
do.devicecheck=1
do.modules=0
do.systemless=0
do.cleanup=1
do.cleanuponabort=0
device.name1=@DEVICE@
device.name2=@DEVICE_ALT@
supported.versions=
supported.patchlevels=
supported.vendorpatchlevels=
'; } # end properties

# boot shell variables
BLOCK=boot;
IS_SLOT_DEVICE=auto;      # 非 A/B 机型解析不到 slot，行为不变
RAMDISK_COMPRESSION=auto;
PATCH_VBMETA_FLAG=auto;

# import functions/variables and setup patching - see for reference (DO NOT REMOVE)
. tools/ak3-core.sh;

## boot install
# 故意不调用 dump_boot / write_boot：见文件头的说明。
IMG=$AKHOME/boot.img;

[ -f "$IMG" ] || abort " " "boot.img 缺失，包是残的。";
[ "$BLOCK" ] || abort " " "找不到 boot 分区，无法刷入。";

IMG_SIZE=$(wc -c < "$IMG");
PART_SIZE=$(blockdev --getsize64 "$BLOCK" 2>/dev/null);
if [ "$PART_SIZE" ] && [ "$PART_SIZE" -gt 0 ]; then
  ui_print " " "分区 $BLOCK：$PART_SIZE 字节";
  ui_print " " "镜像：$IMG_SIZE 字节";
  [ "$IMG_SIZE" -le "$PART_SIZE" ] || abort " " "镜像比分区大，停止刷入。";
else
  PART_SIZE=0;
  ui_print " " "读不到分区大小（$BLOCK），继续但跳过尺寸校验";
fi

# 先把当前 boot 备份一份，刷坏了还能 fastboot 刷回来。
# 注意 $DIR 是 update-binary 里的普通变量、不会传给子进程（只有 OUTFD/ZIPFILE 导出过），
# 所以这里自己挑一个可写目录。
BKDIR=${DIR:-};
[ -n "$BKDIR" ] && [ -d "$BKDIR" ] && [ -w "$BKDIR" ] || BKDIR=/sdcard;
[ -d "$BKDIR" ] && [ -w "$BKDIR" ] || BKDIR=/tmp;
BK="$BKDIR/boot-backup-$(date +%Y%m%d-%H%M%S).img";
if dd if="$BLOCK" of="$BK" bs=1048576 2>/dev/null; then
  ui_print " " "已备份当前 boot 分区 → $BK";
else
  ui_print " " "备份失败（$BK 不可写），继续";
  rm -f "$BK";
  BK="（无）";
fi

blockdev --setrw "$BLOCK" 2>/dev/null;

# 镜像通常等于分区大小，直接覆盖；比分区小时先把整区清零，避免尾部残留旧 vbmeta/footer
if [ "$PART_SIZE" -gt 0 ] && [ "$IMG_SIZE" -lt "$PART_SIZE" ]; then
  dd if=/dev/zero of="$BLOCK" bs=1048576 2>/dev/null || true;
fi

ui_print " " "写入镜像…";
dd if="$IMG" of="$BLOCK" bs=1048576 conv=fsync 2>/dev/null;
if [ $? != 0 ]; then
  abort " " "写入失败。原分区备份：$BK";
fi
sync;

# 回读前 1MB 比对（含 header 与内核开头），确认真的写进去了
A=$(dd if="$IMG" bs=1048576 count=1 2>/dev/null | md5sum | cut -d' ' -f1);
B=$(dd if="$BLOCK" bs=1048576 count=1 2>/dev/null | md5sum | cut -d' ' -f1);
if [ "$A" = "$B" ]; then
  ui_print " " "回读校验通过";
else
  abort " " "回读不一致（$A != $B）。原分区备份：$BK";
fi

ui_print " " "完成。若首次启动卡 logo，请先回刷原厂 init_boot。";
## end boot install
