#!/usr/bin/env python3
"""用原厂 boot.img 当模板，把内核换成我们的 Image，产出结构完全一致的 boot.img。

用法：
    repack_boot.py <原厂 boot.img> <我们的 Image> -o <输出 boot.img>

为什么不走 magiskboot / AnyKernel3：
    这台机器的原厂 boot.img 是 header v4、ramdisk_size=0、os_version=0 的纯内核镜像，
    结构极简。任何第三方重打包工具都可能悄悄改动 header 字段。这里只做最少的事：
    第一页头部改 kernel_size，后面紧跟我们的 Image，按 4096 对齐 —— 别的字节一个不动。
"""
import struct
import sys

BOOT_MAGIC = b"ANDROID!"
PAGE = 4096


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        return 2
    stock_path, image_path = sys.argv[1], sys.argv[2]
    out_path = "boot-new.img"
    if "-o" in sys.argv:
        out_path = sys.argv[sys.argv.index("-o") + 1]

    with open(stock_path, "rb") as fh:
        header = bytearray(fh.read(PAGE))
    with open(image_path, "rb") as fh:
        image = fh.read()

    if header[:8] != BOOT_MAGIC:
        raise SystemExit("原厂 boot.img magic 不对")
    header_version = struct.unpack_from("<I", header, 40)[0]
    if header_version < 3:
        raise SystemExit(f"只支持 header v3/v4，当前 v{header_version}")
    old_kernel = struct.unpack_from("<I", header, 8)[0]
    ramdisk = struct.unpack_from("<I", header, 12)[0]
    os_version = struct.unpack_from("<I", header, 16)[0]

    print(f"    原厂: header_version=v{header_version}, kernel={old_kernel} 字节, "
          f"ramdisk={ramdisk} 字节, os_version={os_version:#x}")
    if ramdisk:
        raise SystemExit("原厂 boot.img 里带 ramdisk，本脚本不负责处理，请改用 AnyKernel3")

    # 只改 kernel_size，其余 header 字段原样保留
    struct.pack_into("<I", header, 8, len(image))

    pad = (-len(image)) % PAGE
    with open(out_path, "wb") as fh:
        fh.write(header)
        fh.write(image)
        fh.write(b"\x00" * pad)

    total = PAGE + len(image) + pad
    print(f"    新  : kernel={len(image)} 字节 (+{pad} 补齐), 总大小 {total} 字节 -> {out_path}")

    # 回读校验
    with open(out_path, "rb") as fh:
        back = fh.read()
    assert back[:8] == BOOT_MAGIC
    ksize = struct.unpack_from("<I", back, 8)[0]
    assert ksize == len(image), "kernel_size 回读不一致"
    assert back[PAGE:PAGE + 4] == image[:4], "kernel 起始内容不一致"
    assert struct.unpack_from("<I", back, 40)[0] == header_version
    assert struct.unpack_from("<I", back, 12)[0] == 0, "ramdisk_size 被改动"
    assert struct.unpack_from("<I", back, 16)[0] == os_version, "os_version 被改动"
    assert back[PAGE + 56:PAGE + 60] == b"ARMd", "arm64 magic 不在预期位置"
    print("    校验: kernel_size / ramdisk_size / os_version / ARMd magic 全部符合预期")
    return 0


if __name__ == "__main__":
    sys.exit(main())
