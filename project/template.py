#!/usr/bin/env python3
"""从原厂 boot.img 生成打包模板（firmware/boot-template.bin + .json）。

模板只保留两块东西，不含内核，所以可以安全地放进仓库：
    [0, 4096)            原厂 boot header v4
    [vbmeta_offset, +vbmeta_size)   原厂 vbmeta blob（AVB0）

用法:
    template.py <原厂 boot.img> [--out-dir firmware]
"""
from __future__ import annotations

import argparse
import json
import os
import re
import struct
import sys

PAGE = 4096
FOOTER = 64


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("stock_boot")
    ap.add_argument("--out-dir", default=os.path.join(
        os.path.dirname(os.path.abspath(__file__)), "..", "firmware"))
    args = ap.parse_args()

    with open(args.stock_boot, "rb") as fh:
        data = fh.read()

    if data[:8] != b"ANDROID!":
        raise SystemExit("不是 Android boot.img")
    header_version = struct.unpack_from("<I", data, 40)[0]
    if header_version != 4:
        raise SystemExit(f"只支持 header v4，这个镜像是 v{header_version}")

    kernel_size, ramdisk_size = struct.unpack_from("<II", data, 8)
    foot = data[-FOOTER:]
    if foot[:4] != b"AVBf":
        raise SystemExit("末尾没有 AVB footer —— 这不是完整的分区镜像，"
                         "请用整份 boot.img（不是 magiskboot 解出来的 kernel）")
    orig, vbo, vbs = struct.unpack_from(">QQQ", foot, 12)

    vbmeta = data[vbo:vbo + vbs]
    if vbmeta[:4] != b"AVB0":
        raise SystemExit(f"footer 指向的位置不是 vbmeta（{vbmeta[:4]!r}）")

    m = re.search(rb"Linux version ([^\x00]{0,120})", data[PAGE:PAGE + kernel_size])
    version = m.group(1).decode("utf-8", "replace") if m else ""

    os.makedirs(args.out_dir, exist_ok=True)
    with open(os.path.join(args.out_dir, "boot-template.bin"), "wb") as fh:
        fh.write(data[:PAGE] + vbmeta)

    meta = {
        "source": os.path.basename(os.path.dirname(os.path.abspath(args.stock_boot))),
        "partition_size": len(data),
        "page_size": PAGE,
        "header_version": header_version,
        "header_bytes": PAGE,
        "vbmeta_size": vbs,
        "template_bytes": PAGE + vbs,
        "stock_kernel_size": kernel_size,
        "stock_ramdisk_size": ramdisk_size,
        "stock_kernel_version": version.split(" ")[0] if version else "",
    }
    with open(os.path.join(args.out_dir, "boot-template.json"), "w",
              encoding="utf-8", newline="\n") as fh:
        json.dump(meta, fh, indent=2, ensure_ascii=False)
        fh.write("\n")

    print(json.dumps(meta, indent=2, ensure_ascii=False))
    print(f"\n    已写入 {args.out_dir}/boot-template.bin（{PAGE + vbs} 字节）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
