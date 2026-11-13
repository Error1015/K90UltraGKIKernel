#!/usr/bin/env python3
"""从 boot.img 里直接取出厂内核配置（不需要手机、不需要 root）。

用法：
    boot_config.py <boot.img> [-o 输出路径]

原理：
    boot.img 头部里有 page_size / kernel_size，按 page_size 对齐就能定位 kernel。
    kernel 可能是 raw Image，也可能是 gzip / lz4 压缩的。
    取到 Image 后，找 IKCFG_ST..IKCFG_ED 之间的 gzip 数据，解出来就是 .config
    （GKI 内核 CONFIG_IKCONFIG=y，出厂镜像里一定有这份配置）。

lz4 需要额外装 lz4 模块（pip install lz4）；raw / gzip 无需任何依赖。
"""
import gzip
import struct
import sys

BOOT_MAGIC = b"ANDROID!"
LZ4_LEGACY_MAGIC = b"\x02\x21\x4c\x18"
LZ4_FRAME_MAGIC = b"\x04\x22\x4d\x18"


def parse_header(data):
    """返回页大小 / kernel 偏移等。v0~v2 与 v3~v4 的头部布局不同。"""
    if len(data) < 48 or data[:8] != BOOT_MAGIC:
        raise SystemExit("不是 Android boot.img（magic 不对）")

    # header_version 字段在 v0~v2 与 v3~v4 里都在偏移 40
    header_version = struct.unpack_from("<I", data, 40)[0]

    if header_version >= 3:
        # v3/v4：kernel_size@8 ramdisk_size@12 os_version@16 header_size@20
        # 固定 4096 页，kernel 紧跟第一页；cmdline 在 44 起 1536 字节
        kernel_size = struct.unpack_from("<I", data, 8)[0]
        os_version = struct.unpack_from("<I", data, 16)[0]
        page_size = 4096
        name = ""
        cmdline = data[44:44 + 1536].split(b"\0", 1)[0].decode("utf-8", "replace")
    else:
        # v0~v2：老布局
        kernel_size = struct.unpack_from("<I", data, 8)[0]
        page_size = struct.unpack_from("<I", data, 36)[0]
        os_version = struct.unpack_from("<I", data, 44)[0]
        name = data[48:64].split(b"\0", 1)[0].decode("utf-8", "replace")
        cmdline = data[64:64 + 512].split(b"\0", 1)[0].decode("utf-8", "replace")
        if page_size < 512 or page_size > 65536 or page_size & (page_size - 1):
            raise SystemExit(f"page_size 异常（{page_size}），头部可能不完整")

    return {
        "kernel_size": kernel_size,
        "page_size": page_size,
        "header_version": header_version,
        "os_version": os_version,
        "name": name,
        "cmdline": cmdline,
    }


def decompress_lz4_legacy(blob):
    try:
        import lz4.block  # type: ignore
    except ImportError:
        raise SystemExit(
            "kernel 是 lz4 压缩的，需要先装 lz4：pip install lz4\n"
            "  或者用手机上的 magiskboot 解：magiskboot unpack boot.img"
        )
    out = bytearray()
    pos = 0
    while pos + 8 <= len(blob):
        size = struct.unpack_from("<I", blob, pos)[0]
        pos += 4
        if size == 0:
            break
        chunk = blob[pos:pos + size]
        pos += size
        out += lz4.block.decompress(chunk, uncompressed_size=1 << 24)
    return bytes(out)


def to_image(kernel):
    """把 kernel 还原成未压缩的 arm64 Image。"""
    if kernel[:2] == b"\x1f\x8b":
        return gzip.decompress(kernel), "gzip"
    if kernel[:4] == LZ4_LEGACY_MAGIC:
        return decompress_lz4_legacy(kernel[4:]), "lz4-legacy"
    if kernel[:4] == LZ4_FRAME_MAGIC:
        try:
            import lz4.frame  # type: ignore
        except ImportError:
            raise SystemExit("kernel 是 lz4 frame 压缩的，需要 pip install lz4")
        return lz4.frame.decompress(kernel), "lz4-frame"
    return kernel, "raw"


def extract_config(image):
    start = image.find(b"IKCFG_ST")
    end = image.find(b"IKCFG_ED", start + 1) if start >= 0 else -1
    if start < 0 or end < 0:
        return None
    try:
        return gzip.decompress(image[start + 8:end]).decode("utf-8", "replace")
    except OSError:
        return None


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    path = sys.argv[1]
    out = None
    if "-o" in sys.argv:
        out = sys.argv[sys.argv.index("-o") + 1]

    with open(path, "rb") as fh:
        data = fh.read()

    hdr = parse_header(data)
    print(f"    header_version : {hdr['header_version']}")
    print(f"    page_size      : {hdr['page_size']}")
    print(f"    kernel_size    : {hdr['kernel_size']} 字节")
    if hdr["name"]:
        print(f"    board name     : {hdr['name']}")
    if hdr["cmdline"]:
        print(f"    cmdline        : {hdr['cmdline'][:120]}")

    off = hdr["page_size"]
    kernel = data[off:off + hdr["kernel_size"]]
    if len(kernel) != hdr["kernel_size"]:
        raise SystemExit("按头部取 kernel 长度不足，文件被截断？")

    image, fmt = to_image(kernel)
    print(f"    kernel 压缩格式: {fmt}，解出 {len(image)} 字节")

    cfg = extract_config(image)
    if not cfg:
        raise SystemExit("Image 里没有内嵌 .config（该内核未开 CONFIG_IKCONFIG）")

    print(f"    解出 .config   : {len(cfg.splitlines())} 行")
    if out:
        with open(out, "w", encoding="utf-8") as fh:
            fh.write(cfg)
        print(f"    已写入         : {out}")
    else:
        sys.stdout.write(cfg)
    return 0


if __name__ == "__main__":
    sys.exit(main())
