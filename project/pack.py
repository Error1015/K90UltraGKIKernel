#!/usr/bin/env python3
"""boot.img v4 打包器（AVB 感知）—— warsaw / K90 Ultra 专用。

为什么不能直接用 AnyKernel3 / magiskboot：
    这台机器的 boot 分区不是"裸内核 + 可选 ramdisk"，而是
        [4096 头部][内核 Image][...][vbmeta blob][...][64 字节 AVB footer]
    并且 footer 里写着 original_image_size / vbmeta_offset / vbmeta_size。
    换内核后必须把 vbmeta blob 整个挪到新的页对齐位置、重写 footer 的三个字段，
    输出长度还要与分区大小完全一致（100663296）。
    任何一步没做（AK3 只写内核；旧脚本只改 kernel_size），
    结果就是 footer 指向被新内核覆盖的旧偏移 → AVB 校验失败 → 卡 logo。

用法:
    pack.py pack    <Image> <输出 boot.img> [--template-dir firmware]
    pack.py inspect <boot.img>
"""
from __future__ import annotations

import argparse
import json
import os
import struct
import sys

PAGE = 4096
FOOTER = 64
BOOT_MAGIC = b"ANDROID!"
ARM64_MAGIC = b"ARM\x64"
AVB_MAGIC = b"AVBf"
VBMETA_MAGIC = b"AVB0"


def round_up(value: int, align: int) -> int:
    return (value + align - 1) // align * align


def load_template(template_dir: str):
    meta_path = os.path.join(template_dir, "boot-template.json")
    bin_path = os.path.join(template_dir, "boot-template.bin")
    with open(meta_path, encoding="utf-8") as fh:
        meta = json.load(fh)
    with open(bin_path, "rb") as fh:
        blob = fh.read()

    header_bytes = meta["header_bytes"]
    tail_size = meta.get("tail_size", 0)
    expect = header_bytes + meta["vbmeta_size"] + tail_size
    if len(blob) != expect:
        raise SystemExit(f"模板损坏：期望 {expect} 字节，实际 {len(blob)}")
    header = blob[:header_bytes]
    vbmeta = blob[header_bytes:header_bytes + meta["vbmeta_size"]]
    tail = blob[header_bytes + meta["vbmeta_size"]:]

    if header[:8] != BOOT_MAGIC:
        raise SystemExit("模板头部 magic 不是 ANDROID!")
    if vbmeta[:4] != VBMETA_MAGIC:
        raise SystemExit("模板里的 vbmeta 不是 AVB0")
    return meta, bytearray(header), vbmeta, tail


def read_footer(data: bytes):
    """AVB footer 的所有字段都是大端。"""
    foot = data[-FOOTER:]
    if foot[:4] != AVB_MAGIC:
        return None
    return {
        "version_major": struct.unpack_from(">I", foot, 4)[0],
        "version_minor": struct.unpack_from(">I", foot, 8)[0],
        "original_image_size": struct.unpack_from(">Q", foot, 12)[0],
        "vbmeta_offset": struct.unpack_from(">Q", foot, 20)[0],
        "vbmeta_size": struct.unpack_from(">Q", foot, 28)[0],
    }


def pack(image_path: str, out_path: str, template_dir: str) -> int:
    meta, header, vbmeta, tail = load_template(template_dir)
    part_size = meta["partition_size"]

    with open(image_path, "rb") as fh:
        image = fh.read()
    if len(image) < 64 or image[56:60] != ARM64_MAGIC:
        raise SystemExit(f"{image_path} 不是 arm64 Image（偏移 56 不是 'ARMd'）")

    kernel_size = len(image)
    kernel_end = PAGE + kernel_size
    aligned = round_up(kernel_end, PAGE)
    # 原厂在 [页对齐, original_image_size) 之间还有一段自己的 AVB 元数据，原样搬过去
    tail_end = aligned + len(tail)
    vbmeta_offset = tail_end
    vbmeta_end = vbmeta_offset + len(vbmeta)

    if vbmeta_end + FOOTER > part_size:
        raise SystemExit(
            f"放不下：内核 {kernel_size} 字节，vbmeta 要放到 {vbmeta_offset}，"
            f"分区只有 {part_size} 字节"
        )

    out = bytearray(part_size)
    out[0:PAGE] = header
    struct.pack_into("<I", out, 8, kernel_size)   # kernel_size
    struct.pack_into("<I", out, 12, 0)            # ramdisk_size（本机内核与 ramdisk 分离，必须为 0）
    out[PAGE:kernel_end] = image
    if tail:
        out[aligned:tail_end] = tail
    out[vbmeta_offset:vbmeta_end] = vbmeta

    fpos = part_size - FOOTER
    out[fpos:fpos + 4] = AVB_MAGIC
    struct.pack_into(">I", out, fpos + 4, 1)                  # version_major
    struct.pack_into(">I", out, fpos + 8, 0)                  # version_minor
    struct.pack_into(">Q", out, fpos + 12, vbmeta_offset)     # original_image_size
    struct.pack_into(">Q", out, fpos + 20, vbmeta_offset)     # vbmeta_offset
    struct.pack_into(">Q", out, fpos + 28, len(vbmeta))       # vbmeta_size

    os.makedirs(os.path.dirname(os.path.abspath(out_path)) or ".", exist_ok=True)
    tmp = out_path + ".tmp"
    with open(tmp, "wb") as fh:
        fh.write(out)
    os.replace(tmp, out_path)

    print(f"    模板内核   : {meta['stock_kernel_size']} 字节 -> 新内核 {kernel_size} 字节")
    print(f"    原厂尾部   : {len(tail)} 字节（页对齐 {aligned} 起，原样保留）")
    print(f"    vbmeta     : 偏移 {vbmeta_offset}（{len(vbmeta)} 字节）")
    print(f"    输出大小   : {len(out)} 字节（= 分区大小 {part_size}）")
    print(f"    写入       : {out_path}")
    return 0


def inspect(path: str) -> int:
    with open(path, "rb") as fh:
        data = fh.read()

    ok = True
    print(f"  文件          : {path}")
    print(f"  大小          : {len(data)} 字节")

    if data[:8] != BOOT_MAGIC:
        print("  [!] 不是 Android boot.img（magic 不对）")
        return 1

    kernel_size, ramdisk_size = struct.unpack_from("<II", data, 8)
    header_version = struct.unpack_from("<I", data, 40)[0]
    header_size = struct.unpack_from("<I", data, 20)[0]
    print(f"  头部          : v{header_version}, header_size={header_size}")
    print(f"  kernel_size   : {kernel_size}")
    print(f"  ramdisk_size  : {ramdisk_size}")

    if ramdisk_size != 0:
        print("  [!] ramdisk_size != 0 —— 本机 ramdisk 在 init_boot，boot 里塞 ramdisk 会起不来")
        ok = False

    kernel_end = PAGE + kernel_size
    if data[PAGE + 56:PAGE + 60] != ARM64_MAGIC:
        print(f"  [!] 内核魔数不是 ARMd: {data[PAGE + 56:PAGE + 60].hex()}")
        ok = False
    else:
        print("  内核魔数      : ARMd ✓")

    foot = read_footer(data)
    if foot is None:
        print("  [!] 没有 AVB footer —— 这不是一个完整的 boot 分区镜像")
        ok = False
    else:
        print(f"  AVB footer    : v{foot['version_major']}.{foot['version_minor']}")
        print(f"    original_image_size : {foot['original_image_size']}")
        print(f"    vbmeta_offset       : {foot['vbmeta_offset']}")
        print(f"    vbmeta_size         : {foot['vbmeta_size']}")

        aligned = round_up(kernel_end, PAGE)
        if foot["vbmeta_offset"] < aligned:
            print(f"  [!] vbmeta_offset({foot['vbmeta_offset']}) 落进内核/尾部保护区"
                  f"（页对齐至少 {aligned}）")
            ok = False
        if foot["original_image_size"] != foot["vbmeta_offset"]:
            print(f"  [!] original_image_size({foot['original_image_size']}) "
                  f"与 vbmeta_offset 不一致 —— 原厂的取值是两者相等")
            ok = False

        vb = data[foot["vbmeta_offset"]:foot["vbmeta_offset"] + foot["vbmeta_size"]]
        if vb[:4] != VBMETA_MAGIC:
            print(f"  [!] vbmeta 位置上的数据不是 AVB0: {vb[:4].hex()}")
            ok = False
        else:
            print("    vbmeta 内容         : AVB0 ✓")
            print(f"    页对齐/尾部         : 内核止于 {kernel_end}，页对齐 {aligned}，"
                  f"尾部 {foot['vbmeta_offset'] - aligned} 字节")

        if foot["original_image_size"] > len(data):
            print("  [!] original_image_size 超过文件长度")
            ok = False

        if kernel_end > foot["vbmeta_offset"]:
            print("  [!] 内核与 vbmeta 区间重叠")
            ok = False

    print("  结论          : " + ("通过" if ok else "不通过"))
    return 0 if ok else 1


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("pack", help="把 Image 打进原厂布局的 boot.img")
    p.add_argument("image")
    p.add_argument("output")
    p.add_argument("--template-dir", default=os.path.join(
        os.path.dirname(os.path.abspath(__file__)), "..", "firmware"))

    i = sub.add_parser("inspect", help="检查一个 boot.img 的结构")
    i.add_argument("boot")

    args = ap.parse_args()
    if args.cmd == "pack":
        rc = pack(args.image, args.output, args.template_dir)
        print("  --- 回读校验 ---")
        return rc or inspect(args.output)
    return inspect(args.boot)


if __name__ == "__main__":
    sys.exit(main())
