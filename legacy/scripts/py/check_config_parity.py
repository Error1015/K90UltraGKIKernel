#!/usr/bin/env python3
"""比较"我们编出来的 .config"与"手机出厂 .config"，只盯 ABI 敏感项。

用法：
    check_config_parity.py <构建产物 .config> <出厂 .config> [--strict]

为什么只比 ABI 敏感项：
    vendor_boot / vendor_dlkm 里的 .ko 是照出厂 config 编的，模块里带着导出符号的
    CRC（CONFIG_MODVERSIONS）。CRC 由符号的类型签名 + 相关 struct 布局决定，而
    struct 布局又由 config 决定。只要 ABI 敏感项有一项不同，`module_layout` 之类的
    CRC 就变，所有厂商模块都会 `disagrees about version of symbol` 装不上，
    一阶段 init 等不到 /system —— 表现就是卡 logo、不 panic、不重启。

    DEBUG_INFO / 日志 / 无关驱动这类项不同则无所谓，脚本不会因为它们报警。
"""
import re
import sys

# 只要这些项不同，模块 ABI 就会变
ABI_SENSITIVE = [
    (r"^CONFIG_MODVERSIONS$", "模块版本校验开关本身"),
    (r"^CONFIG_MODULE_SIG", "模块签名字段会进 struct module"),
    (r"^CONFIG_MODULE_UNLOAD$", "struct module 有无 refcount 字段"),
    (r"^CONFIG_MODULE_ALLOW_BTF_MISMATCH$", "BTF 不匹配时的策略"),
    (r"^CONFIG_MODULES_TREE_LOOKUP$", "模块查找结构"),
    (r"^CONFIG_KALLSYMS", "符号表结构"),
    (r"^CONFIG_TRIM_UNUSED_KSYMS$", "导出符号集合"),
    (r"^CONFIG_UNUSED_KSYMS_WHITELIST$", "导出符号白名单"),
    (r"^CONFIG_LTO", "LTO 模式"),
    (r"^CONFIG_CFI", "CFI 类型检查"),
    (r"^CONFIG_SHADOW_CALL_STACK$", "SCS 改成函数序言"),
    (r"^CONFIG_RANDSTRUCT", "结构体随机化"),
    (r"^CONFIG_ARM64_(4K|16K)_PAGES$", "页大小"),
    (r"^CONFIG_ARM64_VA_BITS", "虚拟地址位宽"),
    (r"^CONFIG_ARM64_PA_BITS", "物理地址位宽"),
    (r"^CONFIG_ARM64_LSE_ATOMICS$", "原子操作实现"),
    (r"^CONFIG_ARM64_USE_LSE_ATOMICS$", "原子操作实现"),
    (r"^CONFIG_ARM64_PTR_AUTH", "指针认证"),
    (r"^CONFIG_ARM64_BTI", "分支目标识别"),
    (r"^CONFIG_ARM64_MTE$", "内存标记"),
    (r"^CONFIG_STACKPROTECTOR", "栈保护"),
    (r"^CONFIG_HARDENED_USERCOPY$", "usercopy 检查"),
    (r"^CONFIG_DEBUG_INFO_BTF_MODULES$", "模块 BTF"),
    (r"^CONFIG_DEBUG_LOCK_ALLOC$", "锁调试会改结构体"),
    (r"^CONFIG_LOCKDEP$", "锁调试会改结构体"),
    (r"^CONFIG_PROVE_LOCKING$", "锁调试会改结构体"),
    (r"^CONFIG_PREEMPT", "抢占模型影响锁与结构"),
    (r"^CONFIG_SMP$", "SMP"),
    (r"^CONFIG_NR_CPUS$", "CPU 数量"),
    (r"^CONFIG_HZ$", "时钟频率"),
    (r"^CONFIG_ANDROID_BINDER", "binder 结构"),
    (r"^CONFIG_RELR$", "重定位格式"),
    (r"^CONFIG_CC_IS_CLANG$", "编译器"),
]

ABI_RE = [re.compile(p) for p, _ in ABI_SENSITIVE]
LABEL = {p: d for p, d in ABI_SENSITIVE}


def parse(path):
    values = {}
    with open(path, encoding="utf-8", errors="ignore") as fh:
        for line in fh:
            line = line.rstrip("\n")
            if line.startswith("# "):
                m = re.match(r"# (CONFIG_\S+) is not set", line)
                if m:
                    values[m.group(1)] = "n"
            elif "=" in line:
                k, v = line.split("=", 1)
                if k.startswith("CONFIG_"):
                    values[k] = v.strip()
    return values


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        return 2
    ours_p, stock_p = sys.argv[1], sys.argv[2]
    strict = "--strict" in sys.argv

    ours, stock = parse(ours_p), parse(stock_p)

    diffs = []
    for key, val in sorted(stock.items()):
        # 只看 ABI 敏感项
        if not any(r.search(key) for r in ABI_RE):
            continue
        mine = ours.get(key, "<不存在>")
        if mine != val:
            reason = next((d for p, d in ABI_SENSITIVE if re.match(p, key)), "")
            diffs.append((key, val, mine, reason))

    print(f"    对比 {len(stock)} 项出厂配置，其中 ABI 敏感项差异 {len(diffs)} 个")
    if not diffs:
        print("    \033[32m[OK]\033[0m ABI 敏感项与出厂完全一致，厂商模块可以正常加载")
        return 0

    print()
    for key, want, mine, reason in diffs:
        print(f"    \033[33m[差异]\033[0m {key}")
        print(f"           出厂 = {want}")
        print(f"           我们 = {mine}")
        print(f"           影响 = {reason}")
    print()
    print("    这些差异会改变导出符号的 CRC，导致 vendor_boot / vendor_dlkm 里的模块")
    print("    全部加载失败（disagrees about version of symbol），表现是卡 logo。")
    print("    解决：config_mode=device，用出厂配置当 defconfig。")
    return 1 if strict else 0


if __name__ == "__main__":
    sys.exit(main())
