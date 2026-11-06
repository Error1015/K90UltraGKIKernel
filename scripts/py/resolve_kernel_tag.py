#!/usr/bin/env python3
"""按内核版本号解析出 ACK 的发布 tag。

背景：ACK 的 `android15-6.6` 分支 HEAD 一直在往前走（现在是 6.6.144），
而手机出厂内核是某个固定版本（例如 6.6.118）。两者相差几十个 stable 合并，
虽然 vermagic 的版本前缀在有 CRC 时会被忽略，但**导出符号的 CRC 不一定相同**
（Google 只冻结核心 KMI 白名单，厂商追加的符号没有这个保证）。
CRC 一变，vendor_boot / vendor_dlkm 里的模块就全部 `disagrees about version
of symbol`，表现就是卡 logo、不 panic、不重启。

所以正确做法是：把 common 锁到与手机同版本的 ACK 发布 tag 上。

ACK 的发布 tag 有两种命名：
  android15-6.6.118_r00            按 sublevel 的旧式 tag（只到 111）
  android15-6.6-2025-09_r1          按月发布（sublevel 随月份递增）

用法：
  resolve_kernel_tag.py --repo https://android.googlesource.com/kernel/common \
                        --branch android15-6.6 --version 6.6.118

成功时把 tag 名打到 stdout 并返回 0；失败返回非 0，信息打到 stderr。
"""

from __future__ import annotations

import argparse
import base64
import collections
import re
import subprocess
import sys
import urllib.request

TIMEOUT = 40


def norm_version(text: str) -> tuple[int, int, int]:
    parts = (text or "").strip().split(".")
    while len(parts) < 3:
        parts.append("0")
    try:
        return tuple(int(p) for p in parts[:3])  # type: ignore[return-value]
    except ValueError:
        return (0, 0, 0)


def list_tags(repo: str, branch: str) -> list[str]:
    """列出远端所有 tag，只保留与本分支对应的。"""
    out = None
    last_err = ""
    for candidate in (repo, repo if repo.endswith(".git") else repo + ".git"):
        cmd = ["git", "ls-remote", "--tags", candidate]
        try:
            out = subprocess.run(cmd, capture_output=True, text=True, timeout=600, check=True).stdout
            break
        except (subprocess.SubprocessError, OSError) as exc:
            last_err = str(exc)
    if out is None:
        raise SystemExit(f"无法列出远端 tag：{last_err}")

    prefix = re.escape(branch)
    month_pat = re.compile(rf"^{prefix}-(\d{{4}}-\d{{2}})_r(\d+)$")
    sub_pat = re.compile(rf"^{prefix}\.(\d+)_r(\d+)$")

    names = set()
    for line in out.splitlines():
        ref = line.split("\t")[-1].strip()
        ref = ref.replace("refs/tags/", "").replace("^{}", "")
        if month_pat.match(ref) or sub_pat.match(ref):
            names.add(ref)
    return sorted(names)


def probe_urls(repo: str, tag: str) -> list[str]:
    """按仓库类型给出可读 Makefile 的 URL（多个候选，逐个尝试）。"""
    base = repo.rstrip("/")
    if base.endswith(".git"):
        base = base[: -len(".git")]

    urls = []
    if "googlesource.com" in base:
        urls.append(f"{base}/+/{tag}/Makefile?format=TEXT")
        urls.append(f"{base}/+refs/tags/{tag}/Makefile?format=TEXT")
    if base.startswith("https://github.com/"):
        slug = base[len("https://github.com/"):]
        urls.append(f"https://raw.githubusercontent.com/{slug}/{tag}/Makefile")
    return urls


def fetch_makefile(repo: str, tag: str) -> str | None:
    for url in probe_urls(repo, tag):
        try:
            req = urllib.request.Request(url, headers={"User-Agent": "k90-resolver"})
            with urllib.request.urlopen(req, timeout=TIMEOUT) as resp:
                raw = resp.read()
        except Exception:
            continue

        # Gitiles 返回 base64，raw.githubusercontent 返回裸文本
        text = None
        try:
            text = base64.b64decode(raw, validate=True).decode("utf-8", "replace")
        except Exception:
            text = raw.decode("utf-8", "replace")

        if "PATCHLEVEL" in text and "SUBLEVEL" in text:
            return text
    return None


def sublevel_of(text: str) -> tuple[int, int, int]:
    vals = {}
    for line in text.splitlines():
        m = re.match(r"^(VERSION|PATCHLEVEL|SUBLEVEL)\s*=\s*(\d+)", line)
        if m:
            vals[m.group(1)] = int(m.group(2))
    return (vals.get("VERSION", 0), vals.get("PATCHLEVEL", 0), vals.get("SUBLEVEL", 0))


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--repo", required=True)
    ap.add_argument("--branch", required=True, help="例如 android15-6.6")
    ap.add_argument("--version", required=True, help="例如 6.6.118 或 118")
    args = ap.parse_args()

    want = norm_version(args.version if args.version.count(".") >= 1 else f"{args.branch.split('-')[1]}.{args.version}")
    target_sub = want[2]
    if target_sub == 0:
        print(f"版本号里没有 sublevel：{args.version}", file=sys.stderr)
        return 2

    tags = list_tags(args.repo, args.branch)
    if not tags:
        print(f"远端没有找到 {args.branch} 相关 tag", file=sys.stderr)
        return 3

    # 1) 名字里直接带 sublevel 的 tag，最省事
    direct = []
    for t in tags:
        m = re.match(rf"^{re.escape(args.branch)}\.(\d+)_r(\d+)$", t)
        if m and int(m.group(1)) == target_sub:
            direct.append((int(m.group(2)), t))
    if direct:
        tag = sorted(direct)[-1][1]
        print(tag)
        return 0

    # 2) 按月 tag：先探 r1 拿到该月的基线版本，再在匹配的月份里挑最高的 r
    by_month: dict[str, list[int]] = collections.defaultdict(list)
    for t in tags:
        m = re.match(rf"^{re.escape(args.branch)}-(\d{{4}}-\d{{2}})_r(\d+)$", t)
        if not m:
            continue
        by_month[m.group(1)].append(int(m.group(2)))

    probes: list[tuple[str, tuple[int, int, int]]] = []

    def probe(month: str, r: int) -> tuple[int, int, int] | None:
        tag = f"{args.branch}-{month}_r{r}"
        text = fetch_makefile(args.repo, tag)
        if not text:
            print(f"  [跳过] 读不到 {tag}", file=sys.stderr)
            return None
        ver = sublevel_of(text)
        probes.append((tag, ver))
        print(f"  {tag} -> {ver[0]}.{ver[1]}.{ver[2]}", file=sys.stderr)
        return ver

    for month in sorted(by_month, reverse=True):
        base = probe(month, 1)
        if base is None:
            continue

        if base[2] > target_sub:
            continue                      # 这个月太新，往前找
        if base[2] < target_sub:
            break                         # 再往前只会更旧

        # 命中月份：从最高 r 往下找，第一个版本对得上的就用它
        for r in sorted(set(by_month[month]), reverse=True):
            if r == 1:
                print(f"{args.branch}-{month}_r1")
                return 0
            ver = probe(month, r)
            if ver and ver[2] == target_sub:
                print(f"{args.branch}-{month}_r{r}")
                return 0
        print(f"{args.branch}-{month}_r1")
        return 0

    seen = collections.OrderedDict((t, v) for t, v in probes)
    avail = ", ".join(f"{v[2]}({t})" for t, v in list(seen.items())[:6]) or "无"
    print(f"没有找到 sublevel={target_sub} 的发布 tag。已探测：{avail}", file=sys.stderr)
    return 4


if __name__ == "__main__":
    sys.exit(main())
