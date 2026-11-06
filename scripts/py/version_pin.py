#!/usr/bin/env python3
"""把内核 Makefile 的版本号改成指定值。

用途：部分厂商 vendor_dlkm 模块的 vermagic 里带完整内核版本号，只有
      UTS_RELEASE 与出厂内核完全一致时模块才会被加载。这个脚本是
      "版本对齐" 开关的实现，属于 hack，默认不启用。
"""
import re
import sys


def main() -> int:
    if len(sys.argv) != 3:
        print("用法: version_pin.py <Makefile> <x.y.z>", file=sys.stderr)
        return 2

    path, target = sys.argv[1], sys.argv[2].strip()
    m = re.fullmatch(r"(\d+)\.(\d+)\.(\d+)", target)
    if not m:
        print(f"版本号格式不正确: {target}（应为 x.y.z）", file=sys.stderr)
        return 2

    version, patchlevel, sublevel = m.groups()
    with open(path, encoding="utf-8") as fh:
        src = fh.read()

    def current(field: str) -> str | None:
        found = re.search(rf"^{field} = (\S+)$", src, re.M)
        return found.group(1) if found else None

    before = ".".join(filter(None, (current("VERSION"), current("PATCHLEVEL"), current("SUBLEVEL"))))
    for field, value in (("VERSION", version), ("PATCHLEVEL", patchlevel), ("SUBLEVEL", sublevel)):
        pattern = rf"^{field} = .*$"
        if not re.search(pattern, src, re.M):
            print(f"Makefile 中找不到 {field} 行", file=sys.stderr)
            return 1
        src = re.sub(pattern, f"{field} = {value}", src, count=1, flags=re.M)

    with open(path, "w", encoding="utf-8") as fh:
        fh.write(src)

    print(f"    Makefile 版本: {before or '?'} -> {target}")
    print(f"    已写入 VERSION={version} PATCHLEVEL={patchlevel} SUBLEVEL={sublevel}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
