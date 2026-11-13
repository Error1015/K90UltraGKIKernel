#!/usr/bin/env python3
"""生成构建矩阵 JSON，供 workflow 的 `strategy.matrix.include` 使用。

为什么要单独算：
    GitHub 的 job 级 `if` 是在**展开矩阵之前**求值的，那里没有 `matrix` 上下文，
    写 `if: matrix.name == ...` 会直接报 "Unrecognized named-value: 'matrix'"。
    所以"跑几条腿"必须在这一步就决定好，输出一个干净的矩阵。

规则：
    root=none          → 只有一条（纯内核）
    root=<具体管理器>   → 只有一条（就是它）
    root=all           → 5 个管理器各一条，一次跑完

输入（环境变量，由 workflow 的 inputs 注入）：
    ROOT_INPUT, SUSFS_INPUT, NOMOUNT_INPUT, BBG_INPUT, NTSYNC_INPUT,
    NETWORKING_INPUT, BPF_INPUT, DROIDSPACES_INPUT, UNICODE_INPUT

关键设计：
    * **不默认附带 vanilla**。想验证"内核本身能不能起"就单独选 root=none 跑一次，
      不要每次都多烧一个 job。
    * SUSFS 需要 root：root=none 或 kowsu 时自动置 false（prepare.sh 里还会再兜一次）。
    * 其余功能与 root 无关（networking / bpf 等纯配置项），root=none 时照样生效。

输出：单行 JSON 数组，值一律用字符串 —— 最终要注入 shell 的 env，
      build.sh / prepare.sh 用 is_true 解析。
"""
from __future__ import annotations

import json
import os
import sys

ROOTS = ("bakasu", "sukisu-ultra", "kernelsu", "kernelsu-next", "kowsu")
FEATURES = ("nomount", "bbg", "ntsync", "networking", "bpf", "droidspaces", "unicode")


def flag(env_name: str) -> str:
    raw = os.environ.get(env_name, "").strip().lower()
    return "true" if raw in ("1", "true", "yes", "on") else "false"


def make_leg(root: str) -> dict:
    leg = {
        "name": root,
        "root": root,
        # KowSU 与 SUSFS 不兼容；root=none 也没有 KSU 可挂
        "susfs": "false" if root in ("none", "kowsu") else flag("SUSFS_INPUT"),
    }
    for f in FEATURES:
        leg[f] = flag(f"{f.upper()}_INPUT")
    return leg


def main() -> int:
    root = (os.environ.get("ROOT_INPUT") or "bakasu").strip()

    if root == "all":
        legs = [make_leg(r) for r in ROOTS]
    else:
        legs = [make_leg(root)]

    print(json.dumps(legs, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    sys.exit(main())
