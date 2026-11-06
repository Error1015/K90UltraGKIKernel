# 功能详解

每个开关"到底改了什么"，方便出问题时定位。所有补丁都在 `scripts/prepare.sh` 里按顺序应用，任一必需补丁失败都会让构建直接中断。

---

## SUSFS

| 项 | 内容 |
| --- | --- |
| 补丁来源 | `gitlab.com/simonpunk/susfs4ksu`，分支 `gki-android15-6.6` |
| 直接拷贝的文件 | `kernel_patches/fs/susfs.c`、`kernel_patches/include/linux/susfs.h`、`susfs_def.h` |
| 主补丁 | `kernel_patches/50_add_susfs_in_gki-android15-6.6.patch`（27 个文件：fs/、mm/、kernel/、security/selinux/） |
| tiann KernelSU 额外补丁 | `kernel_patches/KernelSU/10_enable_susfs_for_ksu.patch`（补 Kconfig 符号 + 调用点） |
| 编译适配 | `scripts/py/susfs_66_compat.py` |
| 配置 | `config/features/susfs.config`（`CONFIG_KSU_SUSFS` 及 9 个子项全开） |
| 验证 | 构建后 `kernel.config` 含 `CONFIG_KSU_SUSFS=y`；`Image` 里 `grep -ac susfs` 不为 0 |

6.6 上的三处已知坑（脚本已处理，且幂等）：

1. `fs/proc/base.c` 缺 `#include <linux/dma-buf.h>` —— 补丁的 hunk 上下文需要它；
2. `mm/memory.c` 缺 `#include <linux/zswap.h>` —— 同上；
3. `fs/proc/task_mmu.c` 用了 `VMA_PAD_START()`，只有带"页大小迁移"特性的 ACK 分支才有这个宏，缺失时补一个不做 padding 的等价定义；
4. `show_fdinfo` 回调在 `SUS_MOUNT`/`SUS_KSTAT` 下会扩成 3 个参数，但补丁没同步改 `fanotify_fdinfo()`，开 `CONFIG_FANOTIFY=y` 就会编译失败 —— 脚本自动补参数。

> **为什么还需要 SUSFS 模块？** 内核侧只提供 syscall 与钩子，`sus_path`/`sus_mount` 的列表管理、开机自启、WebUI 都在 [susfs4ksu-module](https://github.com/sidex15/susfs4ksu-module) 里。

---

## NoMount

| 项 | 内容 |
| --- | --- |
| 来源 | `github.com/maxsteeel/nomount`，分支 `dev`，官方 `kernel/setup.sh` 安装 |
| 产物 | `common/fs/nomount/`（软链）+ `fs/Makefile`、`fs/Kconfig` 的钩子 |
| 配置 | `CONFIG_NOMOUNT=y` |
| 验证 | 构建日志里出现 `fs/nomount` 软链；`kernel.config` 含 `CONFIG_NOMOUNT=y` |

NoMount 与 Mountify 都是"元模块（metamodule）"路线，二选一即可，不要同时装。

---

## Baseband Guard (BBG)

| 项 | 内容 |
| --- | --- |
| 来源 | `github.com/vc-teahouse/Baseband-guard` 的 `setup.sh` |
| 产物 | `common/security/baseband-guard/`，并把它排进 `security/Kconfig` 的默认 LSM 顺序 |
| 配置 | `CONFIG_BBG=y` |
| 验证 | `security/Kconfig` 出现 `baseband_guard`；`kernel.config` 含 `CONFIG_BBG=y` |

作用：拦截对 `efs`/`modem`/`persist` 等基带分区的读写，避免"基带未知 / IMEI 丢失"这类不可逆故障。

---

## DroidSpaces-OSS

| 项 | 内容 |
| --- | --- |
| 来源 | `github.com/ravindu644/Droidspaces-OSS` |
| 补丁 | `Documentation/resources/kernel-patches/GKI/below-kernel-6.12/001.GKI-below-6.12-fix_sysvipc_kabi_6_7_8.patch`（修 SYSVIPC 的 kABI 布局，6.6 属于 below-6.12 档） |
| 配置 | `config/features/droidspaces.config`（约 30 项：IPC/PID/USER namespace、DEVTMPFS、BINFMT、tmpfs ACL、NAT/macvlan、UFW reject、fail2ban 用的 IPSet） |
| 验证 | `kernel.config` 含 `CONFIG_IPC_NS=y`、`CONFIG_SYSVIPC=y`、`CONFIG_MACVLAN=y` |

容器运行在 Android 上直接依赖 namespace 与 IPC 的 ABI 布局，所以 kABI 补丁是必需的，不是可选优化。

---

## Networking

| 项 | 内容 |
| --- | --- |
| BBRv3 | `WildKernels/kernel_patches` → `common/bbrv3/0001-net-tcp-backport-BBRv3-to-android15-6.6.patch` |
| 配置 | `CONFIG_TCP_CONG_BBR=y`、`CONFIG_DEFAULT_TCP_CONG="bbr"`、`FQ/FQ_CODEL`、`WIREGUARD`、`IP_SET*`、`CIFS*` |
| 回退 | BBRv3 补丁不适用当前源码时，只告警并保留内核自带 BBR（功能可用，算法版本不同） |

`CONFIG_TCP_CONG_BBR` 必须是 `=y`：默认拥塞控制算法不能是模块，否则开机时算法还没加载。

---

## NTSync

| 项 | 内容 |
| --- | --- |
| 来源 | `WildKernels/kernel_patches` → `common/ntsync/ntsync_compat_android15-6.6.patch` + `ntsync_base.patch` |
| 配置 | `CONFIG_NTSYNC=y` |
| 用途 | Windows NT 同步原语（event/mutant/semaphore），Proton / Wine 系应用需要 |

6.14 才进上游，6.6 只能回移。`ntsync_compat_*` 负责把新 API 适配到旧内核，`ntsync_base` 是驱动本体，顺序不能反。

---

## Ptrace Leak Fix

- 内核 **< 5.16**：应用 `WildKernels/kernel_patches/gki_ptrace.patch`。
- 内核 **≥ 5.16（含 6.6）**：不需要独立补丁，相关修复已经在 SUSFS 的内核侧补丁里。勾选后只会在日志里提示，不会重复打补丁。

---

## Unicode Fix

| 项 | 内容 |
| --- | --- |
| 来源 | `WildKernels/kernel_patches` → `common/unicode_bypass_fix_6.1+.patch` |
| 用途 | 修复 `/proc` 里用非常规 Unicode 文件名绕过检测的问题 |
| 容错 | 用 `apply_patch_optional`，已应用或不适用时只告警 |

---

## BTF / eBPF / FUSE-BPF

| 项 | 内容 |
| --- | --- |
| 配置 | `CONFIG_DEBUG_INFO_BTF=y`、`BPF_SYSCALL`、`BPF_EVENTS`、`KPROBE_EVENTS`、`UPROBES`、`UPROBE_EVENTS`、`FUSE_FS=y`、`FUSE_BPF=y` |
| 验证 | `kernel.config` 含 `CONFIG_DEBUG_INFO_BTF=y` |

- BTF 是 eBPF CO-RE 的基础，缺了它基于 libbpf 的程序无法加载；
- `FUSE_BPF` 依赖 `FUSE_FS=y`（不能是模块），这是很多人踩的坑；
- 开启 BTF 会增加编译时间与镜像体积，Kleaf 会用自带的 pahole，无需额外装依赖。

---

## 全局配置（`config/base.config`）

| 配置 | 原因 |
| --- | --- |
| `OVERLAY_FS`、`TMPFS_XATTR`、`TMPFS_POSIX_ACL` | 模块挂载、magisk/ksu 模块的 xattr 依赖 |
| `KALLSYMS`、`KALLSYMS_ALL` | SUSFS 与部分内核模块需要完整符号表 |
| `FANOTIFY`、`FANOTIFY_ACCESS_PERMISSIONS` | SUSFS 的路径隐藏/文件监控 |
| `WERROR=n` | 第三方补丁在较新 ACK 上常带无害 warning，开着 WERROR 会直接失败；真正的编译错误依然会中断 |

---

## 版本对齐（`stock_kernel_version`）

`vermagic` 的完整形式是 `<UTS_RELEASE> SMP preempt mod_unload modversions aarch64`。GKI 内核开了
`CONFIG_MODVERSIONS=y`，模块加载时走 `same_magic()` 的 "有 CRC" 分支，**只比较第一个空格之后的部分**：

```c
/* kernel/module/version.c */
/* First part is kernel version, which we ignore if module has crcs. */
int same_magic(const char *amagic, const char *bmagic, bool has_crcs)
{
	if (has_crcs) {
		amagic += strcspn(amagic, " ");
		bmagic += strcspn(bmagic, " ");
	}
	return strcmp(amagic, bmagic) == 0;
}
```

结论：

- 6.6.118 与出厂的 6.6.57 之间、版本号里带 `-maybe-dirty`，**都不影响厂商模块加载**；
- 真正决定能不能加载的是导出符号的 CRC（`disagrees about version of symbol xxx` 才是致命错误）；
- 所以 `stock_kernel_version` 属于"基本用不上"的开关，只在关掉 MODVERSIONS 或模块不带 CRC 时才有意义。

真正需要严格对齐版本的场景，应该用 `kernel_tag` 把源码钉到与出厂同代的 ACK tag。

> 构建时源码树有未提交改动会让 `scripts/setlocalversion` 追加 `-maybe-dirty`。`prepare.sh`
> 结束前会把改动提交掉（`finalize_tree`），所以正常产物的 release 字符串是干净的 `6.6.x-android15-8-4k`。
