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


def fix_priority_uid_filter_guard(kernel: Path) -> None:
    """susfs_switch_to_ksu_domain / susfs_restore_creds 只在
    CONFIG_KSU_SUSFS_PRIORITY_UID_FILTER 的块里被调用。多数 root 实现的
    Kconfig 还没有这个符号（上游 susfs4ksu 比它们新），olddefconfig 会把它
    静默丢掉，于是那个块被编译掉，两个 static 函数变成未使用：

        error: unused function 'susfs_switch_to_ksu_domain' [-Werror,-Wunused-function]

    给这两个函数补上和调用点一模一样的条件编译保护，符号在就照常编进去，
    符号不在就一起编译掉，两种情况都不会触发 -Werror。
    """
    path = kernel / "fs/susfs.c"
    if not path.exists():
        return
    src = read(path)
    guard = "CONFIG_KSU_SUSFS_PRIORITY_UID_FILTER"
    if f"#ifdef {guard}" not in src and f"#if defined({guard})" not in src:
        # 上游没有这个特性，函数一定被用到，不用动
        return

    lines = src.splitlines(keepends=True)

    def find(pattern: str) -> int:
        for i, line in enumerate(lines):
            if re.match(pattern, line):
                return i
        return -1

    i_switch = find(r"^\s*static\s+struct\s+cred\s*\*\s*susfs_switch_to_ksu_domain\s*\(")
    i_restore = find(r"^\s*static\s+void\s+susfs_restore_creds\s*\(")
    if i_switch < 0 or i_restore < 0:
        notes.append("fs/susfs.c: 没找到 cred 辅助函数，跳过守卫")
        return

    # 已经加过保护（幂等）：往上找一段，注释块本身就占 7~10 行
    for line in lines[max(0, i_switch - 40): i_switch]:
        text = line.strip()
        if guard in text and text.startswith(("#ifdef", "#if defined")):
            notes.append("fs/susfs.c: cred 辅助函数已有条件编译保护")
            return

    # 起点：连同紧贴的函数注释块一起包进去
    start = i_switch
    while start > 0:
        text = lines[start - 1].strip()
        if text == "" or text.startswith(("/*", "*", "*/")) or text.endswith("*/"):
            start -= 1
            continue
        break
    while start < i_switch and lines[start].strip() == "":
        start += 1

    # 终点：susfs_restore_creds 的收尾大括号
    end = -1
    for i in range(i_restore, len(lines)):
        if lines[i].rstrip("\r\n") == "}":
            end = i
            break
    if end < 0:
        notes.append("fs/susfs.c: 没找到 susfs_restore_creds 的结束位置，跳过守卫")
        return

    indent = ""
    lines.insert(end + 1, f"{indent}#endif /* {guard} */\n")
    lines.insert(start, f"{indent}#ifdef {guard}\n")
    write(path, "".join(lines))
    notes.append(f"fs/susfs.c: 给 cred 辅助函数补上 #ifdef {guard} 保护")


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
    fix_priority_uid_filter_guard(kernel)

    for note in notes:
        print(f"    {note}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
