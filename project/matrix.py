#!/usr/bin/env python3
"""生成构建矩阵 JSON，供 workflow 的 `strategy.matrix.include` 使用。

为什么要单独算：
    GitHub 的 job 级 `if` 是在**展开矩阵之前**求值的，那里没有 `matrix` 上下文，
    写 `if: matrix.name == ...` 会直接报 "Unrecognized named-value: 'matrix'"。
    所以"跑几条腿"必须在这一步就决定好，输出一个干净的矩阵。

规则：
    root=none          → 一条（纯内核）
    root=<具体管理器>   → 一条（就是它）
    root=all           → 5 个管理器各一条，一次跑完
    root=diag          → 4 条诊断腿，用来二分"卡开机"到底是哪一层（见 DIAG）

输入（环境变量，由 workflow 的 inputs 注入）：
    ROOT_INPUT, SUSFS_INPUT, SIGPROTECT_INPUT, NOMOUNT_INPUT, BBG_INPUT,
    NTSYNC_INPUT, NETWORKING_INPUT, BPF_INPUT, DROIDSPACES_INPUT, UNICODE_INPUT

关键设计：
    * **不默认附带 vanilla**。想验证"内核本身能不能起"就单独选 root=none 跑一次，
      不要每次都多烧一个 job。
    * SUSFS 需要 root：root=none 或 kowsu 时自动置 false（prepare.sh 里还会再兜一次）。
    * 其余功能与 root 无关（networking / bpf 等纯配置项），root=none 时照样生效。
    * sigprotect 是 CONFIG_MODULE_SIG_PROTECT 的开关，默认 true（= 原厂值）。

输出：单行 JSON 数组，值一律用字符串 —— 最终要注入 shell 的 env，
      build.sh / prepare.sh 用 is_true 解析。
"""
from __future__ import annotations

import json
import os
import sys

ROOTS = ("bakasu", "sukisu-ultra", "kernelsu", "kernelsu-next", "kowsu")
FEATURES = ("nomount", "bbg", "ntsync", "networking", "bpf", "droidspaces", "unicode")

# ---------------------------------------------------------------------------
# 诊断腿：从"最像原厂"一路加到"完整功能"，用来二分卡开机。
#
#   ① vanilla        纯原厂配置重建（只改 LOCALVERSION）+ 原厂 sigprotect
#                    → 起不来 = 我们这套构建/打包本身有问题，跟补丁无关
#   ② vanilla-nosig  同 ①，但关掉 MODULE_SIG_PROTECT
#                    → 能起 = 是模块签名保护把厂商模块挡了
#   ③ bakasu-nosusfs 只加 KernelSU
#                    → 起不来 = 问题在 KSU 集成
#   ④ bakasu         完整（KSU + SUSFS）
#
# 四个包并行，墙钟时间≈单个；一次 CI 就能把三层全测完，不用"修一次跑一次"。
# 诊断腿一律不带附加功能：这轮只定位，不叠加变量。
# ---------------------------------------------------------------------------
DIAG = (
    # name,            root,     susfs,   sigprotect
    ("vanilla",        "none",   "false", "true"),
    ("vanilla-nosig",  "none",   "false", "false"),
    ("bakasu-nosusfs", "bakasu", "false", "true"),
    ("bakasu",         "bakasu", "true",  "true"),
)


def flag(env_name: str, default: str = "false") -> str:
    raw = os.environ.get(env_name, "").strip().lower()
    if not raw:
        return default
    return "false" if raw in ("0", "false", "no", "off") else "true"


def make_leg(root: str, *, name: str | None = None,
             susfs: str | None = None, sigprotect: str | None = None,
             features: bool = True) -> dict:
    leg = {
        "name": name or root,
        "root": root,
        # KowSU 与 SUSFS 不兼容；root=none 也没有 KSU 可挂
        "susfs": susfs if susfs is not None else (
            "false" if root in ("none", "kowsu") else flag("SUSFS_INPUT")
        ),
        "sigprotect": sigprotect if sigprotect is not None
                      else flag("SIGPROTECT_INPUT", default="true"),
        # 基础配置来源：gki（默认，= gki_defconfig）或 oem（原厂 .config）
        "config": (os.environ.get("CONFIG_SOURCE_INPUT") or "oem").strip() or "oem",
    }
    for f in FEATURES:
        leg[f] = flag(f"{f.upper()}_INPUT") if features else "false"
    return leg


def main() -> int:
    root = (os.environ.get("ROOT_INPUT") or "bakasu").strip()

    if root == "diag":
        legs = [make_leg(r, name=n, susfs=s, sigprotect=p, features=False)
                for n, r, s, p in DIAG]
    elif root == "all":
        legs = [make_leg(r) for r in ROOTS]
    else:
        legs = [make_leg(root)]

    print(json.dumps(legs, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    sys.exit(main())
