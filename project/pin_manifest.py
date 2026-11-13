#!/usr/bin/env python3
"""把 repo manifest 里 common 项目的 revision 钉到指定 tag/分支。

用法:
    pin_manifest.py <default.xml> <revision> [--project common]

ACK 的 default.xml 里 common 是这样的：
    <project path="common" name="kernel/common" revision="android15-6.6-lts" />

`repo` 只有在 revision 写成完整的 refs/tags/... 时才会按 tag 解析，
所以这里统一写成 refs/tags/<tag>（tag 不可变，sync 最稳）。
"""
import re
import sys


def main() -> int:
    if len(sys.argv) < 3:
        print(__doc__)
        return 2
    path, revision = sys.argv[1], sys.argv[2]
    project = "common"
    if "--project" in sys.argv:
        project = sys.argv[sys.argv.index("--project") + 1]

    with open(path, encoding="utf-8") as fh:
        text = fh.read()

    changed = 0
    out_lines = []
    for line in text.splitlines(keepends=True):
        if "<project" in line and f'path="{project}"' in line and "revision=" in line:
            new = re.sub(r'revision="[^"]*"', f'revision="{revision}"', line, count=1)
            if new != line:
                changed += 1
            out_lines.append(new)
        else:
            out_lines.append(line)

    if changed == 0:
        print(f"[x] manifest 里没找到 path=\"{project}\" 的项目行: {path}", file=sys.stderr)
        return 1

    with open(path, "w", encoding="utf-8", newline="") as fh:
        fh.write("".join(out_lines))
    print(f"    {project} -> {revision}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
