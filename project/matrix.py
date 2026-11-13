#!/usr/bin/env python3
"""生成构建矩阵 JSON，供 workflow 的 `strategy.matrix.include` 使用。

为什么要单独算：
    GitHub 的 job 级 `if` 是在**展开矩阵之前**求值的，那里没有 `matrix` 上下文，
    写 `if: matrix.name == ...` 会直接报 "Unrecognized named-value: 'matrix'"。
    所以"要不要跑第二条腿"必须在这一步就决定好，输出一个干净的矩阵。

输入（环境变量，由 workflow 的 inputs 注入）：
    ROOT_INPUT, SUSFS_INPUT, NOMOUNT_INPUT, BBG_INPUT, NTSYNC_INPUT,
    NETWORKING_INPUT, BPF_INPUT, DROIDSPACES_INPUT, UNICODE_INPUT

输出：单行 JSON 数组，每个元素是一个矩阵 leg（值一律用字符串，
     因为最终要注入到 shell 的 env 里，build.sh / prepare.sh 用 is_true 解析）。
"""
from __future__ import annotations

import json
import os
import sys

FEATURES = ("nomount", "bbg", "ntsync", "networking", "bpf", "droidspaces", "unicode")


def flag(env_name: str) -> str:
    raw = os.environ.get(env_name, "").strip().lower()
    return "true" if raw in ("1", "true", "yes", "on") else "false"


def main() -> int:
    root = (os.environ.get("ROOT_INPUT") or "bakasu").strip()

    # 第一条腿永远是 vanilla：不带 root、不带任何功能，用来证明内核与打包本身没问题
    legs = [{
        "name": "vanilla",
        "root": "none",
        "susfs": "false",
        **{f: "false" for f in FEATURES},
    }]

    if root != "none":
        leg = {
            "name": root,
            "root": root,
            # KowSU 与 SUSFS 不兼容，这里先关掉，prepare.sh 里还会再兜一次
            "susfs": "false" if root == "kowsu" else flag("SUSFS_INPUT"),
        }
        for f in FEATURES:
            leg[f] = flag(f"{f.upper()}_INPUT")
        legs.append(leg)

    print(json.dumps(legs, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    sys.exit(main())
