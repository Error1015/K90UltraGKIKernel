#!/usr/bin/env python3
"""SUSFS 在 6.6 上的编译适配。

susfs4ksu 的 gki-android15-6.6 分支是按某个具体 sublevel 写的补丁，落到
更新的 ACK 代码上时会有几处 "补丁能打上、但编译不过" 的地方。这里只处理
确定性的四处，全部幂等，已修过的文件不会重复处理。

用法: susfs_66_compat.py <内核根目录> [sublevel]
"""
import re
import sys
from pathlib import Path

notes: list[str] = []


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def write(path: Path, text: str) -> None:
    path.write_text(text, encoding="utf-8")


def ensure_include(path: Path, anchor: str, include: str, label: str) -> None:
    """在 anchor 那一行 include 之后补一行 include。"""
    if not path.exists():
        return
    src = read(path)
    if include in src:
        return
    if anchor not in src:
        notes.append(f"跳过 {label}: 找不到锚点 {anchor}")
        return
    src = src.replace(anchor, f"{anchor}\n{include}", 1)
    write(path, src)
    notes.append(f"{label}: 补充 {include}")


def fix_vma_pad_start(kernel: Path) -> None:
    """SUSFS 的 OPEN_REDIRECT 会调用 VMA_PAD_START()，只有带页大小迁移特性的
    ACK 分支才有这个宏；没有时给一个不做 padding 的兜底定义。"""
    path = kernel / "fs/proc/task_mmu.c"
    if not path.exists():
        return
    src = read(path)
    if "VMA_PAD_START(" not in src:
        return
    if re.search(r"#\s*define\s+VMA_PAD_START", src):
        return
    if "pgsize_migration" in src or "page_size_compat.h" in src:
        return

    lines = src.splitlines(keepends=True)
    last_include = max(
        (i for i, line in enumerate(lines) if line.startswith("#include")),
        default=-1,
    )
    if last_include < 0:
        return
    fallback = (
        "\n#ifndef VMA_PAD_START\n"
        "/* SUSFS: 该分支没有页大小迁移特性，给出无 padding 的等价定义 */\n"
        "#define VMA_PAD_START(vma) ((vma)->vm_end)\n"
        "#endif\n"
    )
    lines.insert(last_include + 1, fallback)
    write(path, "".join(lines))
    notes.append("fs/proc/task_mmu.c: 补充 VMA_PAD_START 兜底定义")


def fix_fanotify_arity(kernel: Path) -> None:
    """SUSFS 在开启 SUS_MOUNT / SUS_KSTAT 时把 show_fdinfo 的回调扩成 3 个参数，
    但补丁没有同步改 fanotify 侧的实现/声明。"""
    pattern = re.compile(
        r"(fanotify_fdinfo\s*\(\s*struct seq_file \*m\s*,\s*struct fsnotify_mark \*mark)"
        r"(\s*\))"
    )
    touched = False
    for rel in (
        "fs/notify/fanotify/fanotify.c",
        "fs/notify/fanotify/fanotify.h",
        "fs/notify/fdinfo.c",
    ):
        path = kernel / rel
        if not path.exists():
            continue
        src = read(path)
        if "fanotify_fdinfo" not in src:
            continue
        new_src, count = pattern.subn(r"\1, struct file *file\2", src)
        if count:
            write(path, new_src)
            notes.append(f"{rel}: fanotify_fdinfo 补充 struct file *file 参数")
            touched = True
    if not touched:
        notes.append("fanotify 回调签名无需调整")


def main() -> int:
    if len(sys.argv) < 2:
        print("用法: susfs_66_compat.py <内核根目录> [sublevel]", file=sys.stderr)
        return 2

    kernel = Path(sys.argv[1])
    if not (kernel / "fs").is_dir():
        print(f"{kernel} 看起来不是内核源码树", file=sys.stderr)
        return 2

    ensure_include(
        kernel / "fs/proc/base.c",
        "#include <linux/cpufreq_times.h>",
        "#include <linux/dma-buf.h>",
        "fs/proc/base.c",
    )
    ensure_include(
        kernel / "mm/memory.c",
        "#include <linux/sched/sysctl.h>",
        "#include <linux/zswap.h>",
        "mm/memory.c",
    )
    fix_vma_pad_start(kernel)
    fix_fanotify_arity(kernel)

    for note in notes:
        print(f"    {note}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
