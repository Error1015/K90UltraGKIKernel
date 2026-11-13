#!/usr/bin/env python3
"""体检一个 arm64 内核 Image（可来自 AnyKernel3 zip）。

只做静态检查，不刷机、不需要设备。检查项：
  1. arm64 Image 头部（magic / 分支指令 / 页大小标志 / 文件完整性）
  2. 内嵌 .config（IKCONFIG 段）能否解出
  3. 版本字符串与 KMI 代次
  4. 页大小、MODVERSIONS、SMP/PREEMPT 等与 vendor 模块兼容相关的配置
  5. KernelSU / SUSFS / NoMount / BBG / BTF 是否真的编进了内核

用法: inspect_image.py <Image 路径> [--expect-susfs] [--expect-root]
退出码 0 = 通过，1 = 有硬性检查未通过。
"""
import gzip
import re
import struct
import sys

HARD_FAILS: list[str] = []
WARNS: list[str] = []


def section(title: str) -> None:
    print(f"\n=== {title} ===")


def ok(msg: str) -> None:
    print(f"  [OK]   {msg}")


def warn(msg: str) -> None:
    WARNS.append(msg)
    print(f"  [警告] {msg}")


def fail(msg: str) -> None:
    HARD_FAILS.append(msg)
    print(f"  [失败] {msg}")


def check_header(data: bytes) -> dict:
    section("1. Image 头部")
    info = {}
    if len(data) < 64:
        fail("文件小于 64 字节，不是有效的 arm64 Image")
        return info

    code0, code1 = struct.unpack("<II", data[0:8])
    text_offset, image_size, flags = struct.unpack("<QQQ", data[8:32])
    magic = data[56:60]

    if magic == b"ARM\x64":
        ok(f"magic 正确: {magic!r}")
    else:
        fail(f"magic 不是 b'ARM\\x64'，实际: {magic!r}")

    if (code1 >> 26) == 0b000101:
        ok(f"code1 是 b 分支指令 (0x{code1:08x})，bootloader 可直接跳转")
    else:
        warn(f"code1 = 0x{code1:08x} 不是预期的分支指令（可能是压缩镜像？）")

    be = flags & 0x1
    page_size = (flags >> 1) & 0x3
    phys_base = (flags >> 3) & 0x1
    page_names = {1: "4K", 2: "16K", 3: "64K"}
    ok(f"字节序: {'大端' if be else '小端(LE)'}")
    if page_size in page_names:
        ok(f"头部声明的页大小: {page_names[page_size]}")
    else:
        warn(f"头部页大小字段为保留值 {page_size}")
    info["page_size_flag"] = page_names.get(page_size, "?")
    ok(f"PHYS_BASE 标志: {phys_base}（1 = 支持任意物理地址加载）")

    print(f"  文件大小 {len(data)} 字节，头部 image_size {image_size} 字节")
    if image_size >= len(data):
        ok(f"image_size 覆盖文件（差值 {image_size - len(data)} 字节为 BSS，正常）")
    else:
        fail(f"image_size({image_size}) 小于文件({len(data)})，镜像可能被截断或拼接错误")

    info["image_size"] = image_size
    info["file_size"] = len(data)
    info["text_offset"] = text_offset
    return info


def extract_config(data: bytes) -> str | None:
    section("2. 内嵌内核配置 (IKCONFIG)")
    start = data.find(b"IKCFG_ST")
    end = data.find(b"IKCFG_ED", start)
    if start <= 0 or end <= start:
        warn("没找到 IKCONFIG 段（CONFIG_IKCONFIG 未开启），无法离线核对配置")
        return None
    try:
        cfg = gzip.decompress(data[start + 8:end]).decode("utf-8", "replace")
    except Exception as exc:  # noqa: BLE001
        warn(f"IKCONFIG 段解压失败: {exc}")
        return None
    ok(f"解出配置 {len(cfg)} 字节")
    return cfg


def parse_config(cfg: str) -> dict:
    values = {}
    for line in cfg.splitlines():
        line = line.strip()
        if not line:
            continue
        unset = re.match(r"^# (CONFIG_\w+) is not set$", line)
        if unset:
            values[unset.group(1)] = "n"
            continue
        if line.startswith("#"):
            continue
        if "=" in line:
            key, val = line.split("=", 1)
            values[key] = val.strip('"')
    return values


def check_version(data: bytes, values: dict) -> None:
    section("3. 版本字符串与 KMI")
    found = re.search(rb"Linux version ([^ \x00]+) [^\x00]{0,120}", data)
    if not found:
        fail("Image 中找不到 'Linux version' 字符串")
        return
    release = found.group(1).decode()
    print(f"  release: {release}")
    m = re.match(r"(\d+)\.(\d+)\.(\d+)-android(\d+)-(\d+)", release)
    if m:
        major, minor, patch, android, kmi = m.groups()
        ok(f"内核 {major}.{minor}.{patch}，KMI 代次 android{android}-{kmi}")
    else:
        warn(f"release 字符串不符合 GKI 命名约定: {release}")
    if "dirty" in release:
        warn(
            "release 带 dirty 标记（构建时源码树有未提交改动）。"
            "CONFIG_MODVERSIONS=y 时这一节会被忽略，不影响厂商模块加载，只是版本号不好看"
        )
    if values.get("CONFIG_LOCALVERSION") is not None:
        print(f"  CONFIG_LOCALVERSION={values['CONFIG_LOCALVERSION']!r}")
    if release.endswith("-4k"):
        ok("页大小后缀 -4k 与 K90 Ultra 出厂内核一致")
    elif release.endswith("-16k"):
        fail("页大小后缀是 -16k，与出厂 4k 不符，刷入后无法开机")


def check_compat(values: dict) -> None:
    section("4. 与 vendor_dlkm 模块的兼容性")

    def get(name: str) -> str | None:
        return values.get(name)

    if get("CONFIG_MODVERSIONS") == "y":
        ok(
            "CONFIG_MODVERSIONS=y —— 模块加载时内核会忽略 vermagic 里的版本前缀"
            "（kernel/module/version.c: \"First part is kernel version, which we ignore if module has crcs\"），"
            "所以 6.6.118 与出厂的 6.6.x 子版本不同也能加载厂商模块"
        )
    else:
        fail("CONFIG_MODVERSIONS 未开启：vermagic 会严格比较，厂商模块大概率加载失败")

    for name, expect in (("CONFIG_SMP", "y"), ("CONFIG_PREEMPT", "y"), ("CONFIG_MODULE_UNLOAD", "y")):
        actual = get(name)
        if actual == expect:
            ok(f"{name}={actual}（参与 vermagic 比较）")
        else:
            warn(f"{name}={actual}，与出厂 GKI 不一致时会报 version magic 不符")

    page = get("CONFIG_ARM64_4K_PAGES")
    if page == "y":
        ok("CONFIG_ARM64_4K_PAGES=y")
    else:
        fail(f"CONFIG_ARM64_4K_PAGES={page}，K90 Ultra 出厂是 4k 页")

    if get("CONFIG_MODULE_SIG_FORCE") == "y":
        warn("CONFIG_MODULE_SIG_FORCE=y：未签名模块会被拒绝，厂商模块需要有签名")
    else:
        ok("未开启 CONFIG_MODULE_SIG_FORCE（不会因签名拒绝第三方模块）")


def check_features(values: dict, expect_root: bool, expect_susfs: bool) -> None:
    section("5. 功能是否真的编进内核")

    def state(name: str) -> str:
        return values.get(name, "<未出现>")

    if expect_root:
        if state("CONFIG_KSU") == "y":
            ok("CONFIG_KSU=y")
        else:
            fail(f"CONFIG_KSU={state('CONFIG_KSU')}，root 管理器没有编进内核")

        hooks = []
        if state("CONFIG_KPROBES") == "y":
            hooks.append("kprobes")
        if state("CONFIG_KSU_MANUAL_HOOK") == "y":
            hooks.append("manual")
        if state("CONFIG_KSU_TRACEPOINT_HOOK") == "y":
            hooks.append("tracepoint")
        if hooks:
            ok(f"KernelSU 钩子方式: {' + '.join(hooks)}")
        else:
            fail("三种 KSU 钩子都没开，刷入后 root 不会生效")

        print(f"  CONFIG_KSU_MULTI_MANAGER_SUPPORT={state('CONFIG_KSU_MULTI_MANAGER_SUPPORT')}")
        if state("CONFIG_KSU_MULTI_MANAGER_SUPPORT") != "y":
            print("        → 只信任单一管理器签名，必须装与该内核对应的那个管理器官网 APK")

    if expect_susfs:
        if state("CONFIG_KSU_SUSFS") == "y":
            enabled = [k for k, v in values.items() if k.startswith("CONFIG_KSU_SUSFS_") and v == "y"]
            ok(f"CONFIG_KSU_SUSFS=y，子功能开启 {len(enabled)} 项")
            for key in sorted(enabled):
                print(f"        {key}")
        else:
            fail(f"CONFIG_KSU_SUSFS={state('CONFIG_KSU_SUSFS')}，SUSFS 没编进去")

    for name, label in (
        ("CONFIG_NOMOUNT", "NoMount"),
        ("CONFIG_BBG", "Baseband Guard"),
        ("CONFIG_NTSYNC", "NTSync"),
        ("CONFIG_DEBUG_INFO_BTF", "BTF"),
        ("CONFIG_FUSE_BPF", "FUSE-BPF"),
        ("CONFIG_OVERLAY_FS", "overlayfs"),
        ("CONFIG_FANOTIFY", "fanotify"),
        ("CONFIG_KALLSYMS_ALL", "完整 kallsyms"),
        ("CONFIG_TMPFS_XATTR", "tmpfs xattr"),
    ):
        val = state(name)
        if val == "y":
            ok(f"{name}=y（{label}）")
        elif val == "<未出现>":
            print(f"  [信息] {name} 未出现（该功能未启用或该版本无此符号）")
        else:
            print(f"  [信息] {name}={val}")

    lsm = values.get("CONFIG_LSM")
    if lsm:
        print(f"  CONFIG_LSM={lsm}")
        if "baseband_guard" in lsm:
            ok("baseband_guard 已排入 LSM 顺序（BBG 真正生效的必要条件）")
        elif state("CONFIG_BBG") == "y":
            warn("CONFIG_BBG=y 但不在 CONFIG_LSM 里，BBG 实际不会挂载")


def main() -> int:
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    path = sys.argv[1]
    expect_root = "--expect-root" in sys.argv
    expect_susfs = "--expect-susfs" in sys.argv

    # --dump-config <路径>：把 Image 里内嵌的 .config 导出来，供与出厂配置比对
    dump_path = None
    if "--dump-config" in sys.argv:
        i = sys.argv.index("--dump-config")
        if i + 1 >= len(sys.argv):
            print("--dump-config 需要跟一个输出路径", file=sys.stderr)
            return 2
        dump_path = sys.argv[i + 1]

    with open(path, "rb") as fh:
        data = fh.read()

    print(f"检查对象: {path}")
    check_header(data)
    cfg = extract_config(data)
    values = parse_config(cfg) if cfg else {}

    if dump_path:
        if not cfg:
            print("Image 里没有内嵌 .config（CONFIG_IKCONFIG 未开）", file=sys.stderr)
            return 1
        with open(dump_path, "w", encoding="utf-8") as fh:
            fh.write(cfg)
        print(f"    已导出内嵌 .config -> {dump_path}（{len(cfg)} 字节）")
        print("    下一步可与出厂配置比对：")
        print(f"      python3 scripts/py/check_config_parity.py {dump_path} config/device/gki_defconfig")
        return 0
    if cfg:
        check_version(data, values)
        check_compat(values)
        check_features(values, expect_root, expect_susfs)

    section("结论")
    if HARD_FAILS:
        print(f"  未通过 {len(HARD_FAILS)} 项：")
        for item in HARD_FAILS:
            print(f"    - {item}")
        return 1
    if WARNS:
        print(f"  静态检查通过，但有 {len(WARNS)} 条提醒：")
        for item in WARNS:
            print(f"    - {item}")
        print("  提醒项不影响启动，但值得看一眼。")
        return 0
    print("  静态检查全部通过。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
