#!/usr/bin/env python3
"""产物验收：结构 + 版本串 + 内嵌配置 + 生成 build-info.md

任何一项不通过就返回非 0 —— 构建流水线据此拒绝发布。
"""
from __future__ import annotations

import argparse
import gzip
import json
import os
import re
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import pack as bootpack  # noqa: E402


def extract_config(image: bytes):
    start = image.find(b"IKCFG_ST")
    end = image.find(b"IKCFG_ED", start + 1) if start >= 0 else -1
    if start < 0 or end < 0:
        return None
    try:
        return gzip.decompress(image[start + 8:end]).decode("utf-8", "replace")
    except OSError:
        return None


def cfg_value(config: str, name: str) -> str:
    for pat in (rf"^{name}=(.+)$", rf"^# {name} is not set$"):
        m = re.search(pat, config, re.M)
        if m:
            return m.group(1) if m.groups() else "n"
    return "?"


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--boot", required=True)
    ap.add_argument("--image", required=True)
    ap.add_argument("--root", default="sukisu-ultra")
    ap.add_argument("--susfs", default="true")
    ap.add_argument("--out", default="dist/build-info.md")
    ap.add_argument("--sublevel", default="")
    args = ap.parse_args()

    susfs = args.susfs.lower() in ("1", "true", "yes", "on")
    failures: list[str] = []

    def check(cond: bool, label: str, detail: str = "") -> None:
        if cond:
            print(f"    [OK]   {label}" + (f"  ({detail})" if detail else ""))
        else:
            print(f"    [FAIL] {label}" + (f"  ({detail})" if detail else ""))
            failures.append(label)

    print("== 1. boot.img 结构 ==")
    rc = bootpack.inspect(args.boot)
    check(rc == 0, "boot.img 结构（header / vbmeta / AVB footer）")

    with open(args.boot, "rb") as fh:
        boot = fh.read()
    with open(args.image, "rb") as fh:
        image = fh.read()

    meta = json.load(open(os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                       "..", "firmware", "boot-template.json"),
                          encoding="utf-8"))
    check(len(boot) == meta["partition_size"], "输出大小等于分区大小",
          f"{len(boot)}")
    ks = struct.unpack_from("<I", boot, 8)[0]
    check(ks == len(image), "header.kernel_size 与 Image 一致", str(ks))
    rs = struct.unpack_from("<I", boot, 12)[0]
    check(rs == 0, "ramdisk_size = 0（ramdisk 在 init_boot）", str(rs))

    print("== 2. 内核版本 ==")
    m = re.search(rb"Linux version ([^\x00]{0,120})", image)
    version = m.group(1).decode("utf-8", "replace") if m else ""
    short_version = version.split(" ")[0] if version else ""
    print(f"    版本串: {version or '未找到'}")
    check(bool(version), "Image 里有版本串")
    if args.sublevel:
        check(re.fullmatch(rf"6\.6\.{args.sublevel}[-\s].*", version) is not None,
              f"sublevel 与手机一致（6.6.{args.sublevel}）", version)
    check("android15-8" in version, "KMI 代次为 android15-8", version)

    print("== 3. 内嵌配置（CONFIG_IKCONFIG）==")
    config = extract_config(image)
    check(config is not None, "能从 Image 解出 .config")
    if config:
        checks = [
            ("CONFIG_ARM64_4K_PAGES", "y"),
            ("CONFIG_MODVERSIONS", "y"),
            ("CONFIG_TRIM_UNUSED_KSYMS", "n"),
            ("CONFIG_MODULE_SIG_PROTECT", "y"),
            ("CONFIG_CFI_CLANG", "y"),
        ]
        if args.root != "none":
            checks.append(("CONFIG_KSU", "y"))
            if susfs:
                checks.append(("CONFIG_KSU_SUSFS", "y"))
        for name, want in checks:
            got = cfg_value(config, name)
            check(got == want, f"{name}={want}", f"实际 {got}")

    if failures:
        print(f"\n[x] {len(failures)} 项不通过: {', '.join(failures)}")
        return 1

    MANAGERS = {
        "bakasu": ("BakaSU Manager", "https://github.com/Baka-SU/BakaSU/releases"),
        "sukisu-ultra": ("SukiSU-Ultra Manager", "https://github.com/SukiSU-Ultra/SukiSU-Ultra/releases"),
        "kernelsu": ("KernelSU Manager", "https://github.com/tiann/KernelSU/releases"),
        "kernelsu-next": ("KernelSU Next Manager", "https://github.com/KernelSU-Next/KernelSU-Next/releases"),
        "kowsu": ("KowSU Manager", "https://github.com/KOWX712/KernelSU/releases"),
    }
    manager, manager_url = MANAGERS.get(args.root, ("无（纯内核）", ""))

    os.makedirs(os.path.dirname(os.path.abspath(args.out)) or ".", exist_ok=True)
    with open(args.out, "w", encoding="utf-8", newline="\n") as fh:
        fh.write("# K90 Ultra (warsaw) GKI 构建信息\n\n")
        fh.write(f"- 内核版本：`{short_version}`\n")
        fh.write(f"- root：`{args.root}`")
        if manager_url:
            fh.write(f" → 需要安装 [{manager}]({manager_url})")
        fh.write("\n")
        if args.root != "none":
            fh.write(f"- SUSFS：`{'on' if susfs else 'off'}`\n")
        fh.write(f"- boot.img 大小：{len(boot)} 字节（= 分区大小，含 vbmeta 与 AVB footer）\n")
        fh.write(f"- 内核 Image：{len(image)} 字节\n")
        fh.write(f"- 源码：ACK `android15-6.6` @ `6.6.{args.sublevel}`\n\n")
        fh.write("## 刷入\n\n```bash\n")
        fh.write("# 0) 若之前用过 LKM，先把 init_boot 回原厂（否则一定卡 logo）\n")
        fh.write("fastboot flash init_boot stock_init_boot.img\n")
        fh.write("# 1) 刷本包\nfastboot flash boot boot-warsaw.img\n")
        fh.write("# 2) 重启\nfastboot reboot\n```\n\n")
        if args.root != "none":
            fh.write(f"> 内核里集成的是 **{args.root}** 的代码，必须装 {manager}，"
                     "装别家会显示\"未安装\"。\n")
    print(f"\n    已写入 {args.out}")
    print("    结论：全部通过")
    return 0


if __name__ == "__main__":
    sys.exit(main())
