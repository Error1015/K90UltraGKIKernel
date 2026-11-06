# K90Ultra GKI Kernel

在 GitHub Actions 上为 **Redmi K90 Ultra（代号 warsaw / SM8750 / 内核 6.6）** 构建 GKI 内核，内置 **KernelSU 系 root 管理器** 与 **SUSFS** 隐藏方案，并把常见的自定义功能（NoMount、Baseband Guard、DroidSpaces、BBRv3、NTSync、Ptrace/Unicode 修复、BTF/eBPF）做成勾选项。

产物是 **AnyKernel3 刷机包**，只替换 boot 分区里的内核镜像，不动 vendor_boot / vendor_dlkm / dtbo。

默认一次运行（`preset=full` + `root_manager=all`）会并行构建 **5 个 root 管理器各一份 AK3 包**
（kernelsu-next / kernelsu / bakasu / sukisu-ultra / kowsu），拿到手按需刷其中一个、装对应的管理器 APK 即可。

---

## 一、先看这里（重要）

1. **刷机有风险。** 变砖、数据丢失、指纹/支付失效都可能发生，请先备份 `boot` 分区并确认自己能进 fastboot / recovery。
2. **内核来自 Google ACK 的 GKI 6.6 源码，不是小米私有的 msm-kernel 树。**
   小米开源的 `warsaw-w-oss` 分支是 Qualcomm kernel_platform 里的 `msm-kernel` 部分，它的 Bazel 定义（`msm_kernel_la.bzl`）明确写着 `base_kernel = "//common:kernel_aarch64"` —— 也就是说设备 boot 里的内核主体本来就是 GKI，小米那边编译的是同一份 ACK + vendor 模块。本仓库等价地直接构建这份 GKI，因此不需要（也无法）单独构建小米的 msm-kernel。
3. **KMI 必须匹配。** 出厂固件是 6.6 + 4k 页，对应的 GKI 线是 `android15-6.6`（ACK 没有 `android16-6.6` 分支，Android 16 的 6.6 设备继续用这条线）。默认值已经按这个设置好，**不要**随便改成 6.1 / 6.12。
4. **用手机的内核版本构建，不要用分支最新。** 填 `kernel_release=6.6.118`（换成你自己 `adb shell uname -r` 的版本），仓库会自动把源码锁定到同版本的 ACK 发布 tag。原因见 [源码版本](#源码版本必须与手机一致kernel_release)。

---

## 二、快速开始

```text
1. Fork 本仓库（或者直接用它当模板新建仓库）
2. 打开 Actions → Build GKI Kernel → Run workflow
3. 保持默认（preset=full、root_manager=all）直接跑，就会一次出齐所有 root 管理器的包；
   也可以只挑一个管理器、或按需勾选功能开关
4. 等 40~90 分钟（矩阵并行，每个管理器各一个 job），在运行页面 / Release 里下载 zip
5. 备份 boot → 用管理器刷入对应 root 的那份 zip → 装对应管理器 APK
```

### 刷入步骤

```bash
# 1) 备份原始 boot（强烈建议，出问题可救）
adb shell su -c 'dd if=/dev/block/by-name/boot of=/sdcard/stock_boot.img'
adb pull /sdcard/stock_boot.img

# 2) 刷入 —— 二选一
#    a. recovery（TWRP 等）里直接刷这个 zip；
#    b. 或者用 magiskboot 把 Image 塞回官方 boot.img，再 fastboot 刷：
#         magiskboot unpack stock_boot.img
#         cp Image kernel
#         magiskboot repack stock_boot.img new_boot.img
#         fastboot flash boot new_boot.img
```

> ⚠️ **不要** `fastboot flash boot xxx.zip`，也**不要**把 zip 里的 `Image` 直接
> `fastboot flash boot Image`。boot 分区不是裸内核，写进去必然卡 logo（见第六节）。

启用 SUSFS 时，额外安装 [susfs4ksu-module](https://github.com/sidex15/susfs4ksu-module) 才能用全部隐藏功能（`sus_path`、`sus_mount` 等）。

### 刷机前自检（建议先做）

产物是一个内核二进制，刷错位置的代价很高。可以先在电脑上做两件事，都不碰手机。

**第 0 步（最容易漏）：确认基座不是 LKM 模式。**
管理器首页的「工作模式」如果显示 **LKM**，说明 `init_boot` 被 LKM 改过（塞了 `kernelsu.ko`），
必须先恢复原厂 `boot` + `init_boot` 再刷，否则**一定卡 Logo** —— 原因和完整流程见
[第六节第 1 小节](#1-头号原因之前是-lkm-模式基座没换干净)。

```bash
# 1) 静态体检：头部结构、页大小、内嵌 .config、KSU/SUSFS 是否真的编进去了
bash scripts/verify-image.sh K90Ultra-GKI-....zip --expect-root --expect-susfs

# 1.5) 设备侧自检（只读，连上手机就能跑）：页大小/KMI/LKM 残留/KSU 状态
bash scripts/check-device.sh
```

它会从 Image 里解出内嵌的 `.config`（`CONFIG_IKCONFIG`）逐项核对，输出形如：

```
=== 4. 与 vendor_dlkm 模块的兼容性 ===
  [OK]   CONFIG_MODVERSIONS=y —— 模块加载时内核会忽略 vermagic 里的版本前缀 …
  [OK]   CONFIG_ARM64_4K_PAGES=y
=== 5. 功能是否真的编进内核 ===
  [OK]   CONFIG_KSU=y
  [OK]   KernelSU 钩子方式: kprobes
  [OK]   CONFIG_KSU_SUSFS=y，子功能开启 9 项
```

```text
2) 真实启动：Actions → Verify Image → Run workflow
   默认会拿最新 Release 的 zip，在 QEMU 里把 Image 启动一次
   （没有 rootfs，正常结果是跑到 VFS panic —— 说明内核主体能跑）
```

如果想在**真机**上先验证再决定要不要刷：`fastboot boot <临时 boot.img>` 只在内存里启动一次，重启即恢复原样，不动 flash。需要先把 Image 塞回一份 boot 镜像（可以用 AK3 包里的 `tools/magiskboot` 处理出厂 boot.img）。

> 每个 root 管理器都有自己的签名校验，**内核里集成的是哪一个，就必须装哪一个的管理器 APK**，装错了会显示"未安装"。

| 内核选项 | 需要安装的管理器 |
| --- | --- |
| `kernelsu` | [KernelSU](https://github.com/tiann/KernelSU/releases) |
| `kernelsu-next` | [KernelSU Next](https://github.com/KernelSU-Next/KernelSU-Next/releases) |
| `bakasu` | [BakaSU](https://github.com/Baka-SU/BakaSU/releases) |
| `sukisu-ultra` | [SukiSU-Ultra](https://github.com/SukiSU-Ultra/SukiSU-Ultra/releases) |
| `kowsu` | [KowSU](https://github.com/KOWX712/KernelSU/releases) |

---

## 三、可选项说明

### Root 管理器

| 选项 | 说明 |
| --- | --- |
| `all` | **默认值。** 一次运行把下面 5 个管理器全部构建一遍，每个管理器各出一个 AK3 包（矩阵并行，互不影响） |
| `kernelsu-next` | 功能最全、SUSFS 支持最顺，社区使用最广 |
| `kernelsu` | tiann 原版，需要额外打 `10_enable_susfs_for_ksu.patch` 才能接 SUSFS（仓库已自动处理） |
| `bakasu` | 原 ReSukiSU 团队，自带 SUSFS 胶水与 ksu_toolkit，默认只信任自己的管理器签名 |
| `sukisu-ultra` | 自带 SUSFS 与多管理器签名表 |
| `kowsu` | **与 SUSFS 不兼容**：单独选它会直接拒绝构建；选 `all` 时它的那份会自动关掉 SUSFS |
| `none` | 纯内核，不集成任何 root，用于对照/排查 |

选 `all` 时产物分别是 `...-kernelsu-next-susfs-full-4k-....zip`、`...-bakasu-susfs-full-4k-....zip` 这样的独立包，
**刷哪个就装哪个的管理器**，不能混用。`variants` 里填多个预设时，矩阵是"预设 × root 管理器"的笛卡尔积。

`root_ref` 可以钉住分支、tag 或 commit。留空则取各仓库默认分支最新（`kernelsu-next` 取 `dev`，其余取 `main`/`master`）；选 `all` 时这个 ref 会对所有管理器生效（所以只适合填各仓库都存在的公共分支）。

### 功能开关

| 选项 | 做什么 | 依赖 |
| --- | --- | --- |
| `susfs` | susfs4ksu 内核侧补丁 + 10 项 `CONFIG_KSU_SUSFS_*` 全开，root 隐藏核心 | 需要 root ≠ none |
| `nomount` | 集成 [NoMount](https://github.com/maxsteeel/nomount) 的 VFS 钩子，无挂载点伪装 | 建议配合 NoMount metamodule |
| `bbg` | [Baseband Guard](https://github.com/vc-teahouse/Baseband-guard)，保护 efs/modem 分区 | — |
| `droidspaces` | [DroidSpaces-OSS](https://github.com/ravindu644/Droidspaces-OSS) 容器运行时（含 SYSVIPC kABI 修正与完整 namespace/网络配置） | — |
| `networking` | BBRv3 回移 + WireGuard + IPSet + CIFS，默认拥塞控制设为 `bbr` | 补丁不适用时自动回退到内核自带 BBR |
| `ntsync` | NTSync 回移（Proton / Wine 同步原语） | — |
| `ptrace_fix` | Ptrace 泄漏修复。**6.6 上已经包含在 SUSFS 补丁里**，单独勾选只会提示 | 需要 SUSFS |
| `unicode_fix` | `/proc` 名称绕过修复 | — |
| `bpf` | BTF + eBPF + FUSE-BPF 全套 | — |

### 构建参数

| 选项 | 默认值 | 说明 |
| --- | --- | --- |
| `preset` | `full` | `full` = 按开关全量构建；`safe` = 只留 root + SUSFS，其余开关强制关闭；`vanilla` = 什么都不加，验证基础内核（此时 root 维度会自动收敛成一份，不会重复构建） |
| `root_manager` | `all` | 见上一节。`all` = 所有管理器各出一个包 |
| `page_size` | `4k` | 小米 `build.config.msm.sun` 里写死 `PAGE_SIZE=4096`，K90 Ultra 就是 4K |
| `config_mode` | `overlay` | 配置来源。`device` = 用出厂配置（最稳），`pristine` = 零改动（排查用） |
| `lto` | `thin` | 官方 GKI release 用的就是 thin；`none` 更快但内核二进制与官方不同 |
| `manifest_branch` | `common-android15-6.6-lts` | 跟踪 6.6 LTS 最新。想复现历史构建就换成 `common-android15-6.6-2025-06` 这类日期分支 |
| `kernel_release` | 空 | **推荐填**，例如 `6.6.118`。自动解析出同版本的 ACK 发布 tag 并锁定源码 |
| `kernel_tag` | 空 | 直接钉到某个不可变 ACK tag（如 `android15-6.6-2025-12_r3`），填了就忽略 `kernel_release` |
| `stock_kernel_version` | 空 | 版本对齐 hack，见下文 |
| `susfs_branch` | `gki-android15-6.6` | 换 SUSFS 分支时同步改 |
| `brand` | `K90Ultra` | 只影响产物命名，不改内核版本号（避免破坏 KMI） |
| `release` | `release` | 发布方式：`release` = 正式 Release；`prerelease` = 预发布（GitHub 上打 Pre-release 标记，不会出现在 `/releases/latest`）；`none` = 不发布，只留 Actions Artifacts。每个 root 管理器各一条 Release |

#### 关于 `release`

| 取值 | 行为 |
| --- | --- |
| `release` | 构建成功后创建正式 Release（tag 形如 `k90ultra-bakasu-susfs-full-6.6.118-4k-20261106-1230`），带 `build-info.md` 正文 |
| `prerelease` | 同上，但打上 GitHub 的 **Pre-release** 标记：不会出现在 `/releases/latest`、不会被当成"最新版本"，适合先让少数人试刷 |
| `none` | 完全不建 Release，产物只留在运行页的 Artifacts（需登录、默认保留 90 天） |

一次运行会出多个包（每个 root 管理器一条 Release），所以**不会**给任何一条打 `Latest` 标签 —— 否则每次运行
"最新版本"都会随机落到某个管理器上，容易让人下错包。

发布是每个 job 各自做的：某个管理器编译失败只影响它自己那一份，不会挡住其它管理器的包照常发布（矩阵是 `fail-fast: false`）。

#### 源码版本必须与手机一致（`kernel_release`）

GKI 保证「同一 KMI 代次的内核可以互换」，具体做法是**冻结导出符号的 CRC**——但冻结范围是
Google 的 `abi_gki_aarch64` 白名单。厂商往白名单里追加的符号（`abi_gki_aarch64_qcom`、
`abi_gki_aarch64_xiaomi`，413 项）**没有这个保证**。

符号 CRC 由类型签名算出（`struct` 布局、函数原型都会影响）。所以：

- 分支 HEAD 是 6.6.144，手机是 6.6.118 → 中间几十个 stable 合并，只要有一处改了被导出符号的
  类型，CRC 就变了；
- 变了之后，`vendor_boot` ramdisk 里的 ufs/ufs-phy/rpmh 这些**一阶段模块**会全部
  `disagrees about version of symbol` 而拒绝加载；
- 一阶段模块起不来 → init 挂不到 `/system` → **卡在开机 logo，不 panic、不重启**。

这就是为什么不要拿分支最新去刷一台固定版本的机器。填 `kernel_release` 后，
`scripts/py/resolve_kernel_tag.py` 会做这几件事：

1. `git ls-remote` 列出 `android15-6.6*` 的发布 tag（`android15-6.6.118_r00` 这种按版本命名的，
   或 `android15-6.6-2025-12_r3` 这种按月的）；
2. 直接命中按版本命名的 tag 就用它；否则按月**从新到旧**逐个读 `Makefile` 的 `SUBLEVEL`；
3. 找到 `SUBLEVEL` 等于目标版本的 tag 后，把清单里 `common` 的 revision 钉到
   `refs/tags/<tag>`，再 `repo sync`；
4. 同步完**回读** `common/Makefile`，版本对不上就直接中断，不会产出「版本悄悄不对」的包。

想手动指定（解析失败时）就直接填 `kernel_tag`，错误信息里会列出探测到的月份与版本。

#### 关于 `stock_kernel_version`

先说结论：**大多数情况不需要它，留空即可。**

`vermagic` 的格式是 `<内核版本> SMP preempt mod_unload modversions aarch64`。GKI 内核开了 `CONFIG_MODVERSIONS=y`，加载模块时只会比较**第一个空格之后**的部分（源码注释原文：`First part is kernel version, which we ignore if module has crcs.`，见 `kernel/module/version.c`）。也就是说 6.6.118 与出厂的 6.6.57 之间、甚至版本号里的 `-maybe-dirty` 都不影响厂商模块加载 —— 真正起保护作用的是每个导出符号的 CRC（KMI 约定）。

所以这个开关只在极端情况下有意义：比如你关掉了 `CONFIG_MODVERSIONS`，或者某个模块没带 CRC 导致走了严格比较。填 `6.6.57` 会把 Makefile 的 `SUBLEVEL` 改成 57 让 UTS_RELEASE 与出厂一致，代价是版本号和真实代码不再对应。

真正需要担心的是 `disagrees about version of symbol xxx` 这类报错 —— 那是符号 CRC 变了，改版本号救不了，得换回出厂同代的 GKI 源码（用 `kernel_tag` 钉住对应 ACK tag）。

---

## 四、构建流水线

```
resolve     → preset / variants / root_manager 解析成矩阵（预设 × root 管理器）
              → 每个组合一个并行 job；kowsu 的组合自动关掉 SUSFS；vanilla 收敛成一份

prepare.sh
 ├── 1. repo init/sync kernel_manifest → kernel/（Kleaf 布局：common/ + prebuilts/ + build/）
 ├── 2. 可选：版本对齐（改 Makefile SUBLEVEL）
 ├── 3. Root 集成：clone 到 kernel/<Name>，软链到 common/drivers/kernelsu，补 Makefile/Kconfig
 │      └── 顺手打平各管理器的已知坑（Next 的 Kbuild 检查、BakaSU 的子模块检查与 susfs_compat 死循环）
 ├── 4. SUSFS：clone susfs4ksu → 拷 fs/susfs.c、include/linux/susfs*.h → 打 50_add 补丁
 │      ├── 6.6 编译适配（缺 include、VMA_PAD_START、fanotify 回调签名）
 │      └── tiann KernelSU 额外打 10_enable_susfs_for_ksu.patch
 ├── 5. 功能补丁：NoMount / BBG / DroidSpaces / BBRv3 / NTSync / Ptrace / Unicode
 └── 6. 内核配置：config/*.config 全部经 scripts/config 写进 gki_defconfig 并逐条回读校验

build.sh    → tools/bazel build --config=fast //common:kernel_aarch64/Image
              → 取出 Image 与最终 .config，校验 CONFIG_KSU / CONFIG_KSU_SUSFS / 页大小
              → 不通过就中断（不产出"看起来能用"的包）

package.sh  → AnyKernel3(gki-2.0) → 放入 Image → zip → 生成 build-info.md
```

**设计原则：宁可构建失败，也不要产出跑不起来的内核。** 所有补丁默认 `fuzz=0` 精确应用，失败才退化到 `-F3`，仍失败则收集 `.rej` 到 `patch-rejects` 工件并终止。

---

## 五、目录结构

```
.github/workflows/build.yml   # 唯一的构建入口，所有选项都在这里（含"预设 × root 管理器"矩阵）
.github/workflows/verify.yml  # 刷机前体检：静态检查 + QEMU 启动冒烟测试
config/
  device/gki_defconfig        # 可选：手机出厂配置（config_mode=device 时使用，最贴近 ABI）
  base.config                 # overlay 模式下每次构建都会应用（overlayfs/tmpfs/kallsyms/fanotify、关 WERROR）
  root/*.config               # 各 root 管理器的 CONFIG_KSU 与专属开关
  features/*.config           # SUSFS / NoMount / BBG / DroidSpaces / Networking / NTSync / BPF
scripts/
  lib.sh                      # 日志、重试、配置写入与回读、补丁应用
  prepare.sh                  # 同步源码 + 集成 root/补丁 + 写配置 + 提交源码树
  build.sh                    # Kleaf 构建 + 产物校验
  package.sh                  # AnyKernel3 打包 + 构建说明
  check-device.sh             # 连手机只读自检：LKM 残留 / 页大小 / KMI / KSU 状态
  get-device-config.sh        # 连手机把出厂 /proc/config.gz 取回来 -> config/device/gki_defconfig
  get-last-log.sh             # 连手机抓上一次卡住那轮开机的 ramoops 日志并直接给结论
  check-abi.sh                # 一条命令比对一个包与出厂配置的 ABI 差异（不构建、不刷机）
  make-boot.sh                # 用原厂 boot.img 当模板换内核，绕开 AK3 产出可直接刷的 boot.img
  py/check_config_parity.py   # 产物 config 与出厂 config 的 ABI 敏感项比对（构建时自动跑）
  py/boot_config.py           # 直接从原厂 boot.img 里取出内嵌 .config（不需要手机）
  py/repack_boot.py           # 只改 kernel_size 的 boot.img 重打包（结构与本厂一致）
  verify-image.sh             # 刷机前体检入口（可离线跑）
  py/inspect_image.py         # Image 头部 / 内嵌 .config / 功能项检查
  py/version_pin.py           # 版本对齐
  py/susfs_66_compat.py       # SUSFS 在 6.6 上的编译适配
```

外部依赖（构建时自动拉取，不在本仓库里存副本）：

| 来源 | 用途 |
| --- | --- |
| `android.googlesource.com/kernel/manifest` | GKI 6.6 源码 |
| `gitlab.com/simonpunk/susfs4ksu` (`gki-android15-6.6`) | SUSFS 内核侧补丁 |
| `github.com/WildKernels/kernel_patches` | NTSync / BBRv3 / Unicode / ptrace 补丁集 |
| `github.com/maxsteeel/nomount` | NoMount |
| `github.com/vc-teahouse/Baseband-guard` | BBG |
| `github.com/ravindu644/Droidspaces-OSS` | DroidSpaces |
| `github.com/WildKernels/AnyKernel3` (`gki-2.0`) | 刷机包模板 |

---

## 六、刷入后卡标（Redmi logo）怎么排查

卡在 logo 说明**要么内核没跑起来，要么内核跑起来了但 Android 起不来**。按下面顺序排，别重复盲刷。

### 0. 先救砖

1. **有 boot 备份**：`fastboot flash boot stock_boot.img`
2. **A/B 设备没备份**：切到另一个槽再试 —— `fastboot --set-active=a`（或 `b`），重启
3. **都没有**：下载对应版本的 fastboot 线刷包，只解出 `images/boot.img`，然后 `fastboot flash boot boot.img`（先别整包刷，保住数据）

### 1. 头号原因：之前是 LKM 模式，基座没换干净

**LKM 模式不改内核，改的是 ramdisk。** Android 13 及以后的设备有独立的 `init_boot` 分区，
KernelSU 的 LKM 安装会把 `kernelsu.ko` 塞进 `init_boot` 的 ramdisk，并让首段 init 在开机时加载它；
内核（`boot` 分区）保持出厂原样。

而本仓库产的包是 **GKI 模式（`CONFIG_KSU=y`，KSU 直接编进内核）**，只替换 `boot` 里的内核。
于是刷完之后：

| 分区 | 内容 | 状态 |
| --- | --- | --- |
| `boot` | 我们的内核，KSU 内置 | ✅ 已换 |
| `init_boot` | 出厂内核配套的 `kernelsu.ko` + 加载钩子 | ❌ **还在** |

后果：那份 `kernelsu.ko` 是照**出厂内核 + 官方 GKI 配置**编的，而我们改了配置
（`CONFIG_KSU=y`、关掉符号裁剪、SUSFS/NoMount 等），`module_layout` 这类符号的 CRC 全变了 →
`insmod` 一定失败。而 LKM 的加载钩子挂在首段 init 上，它等不到模块就会停在那里 ——
表现出来正是**卡住不动**，而不是 panic 后重启。

> 反过来，如果你只用 fastboot 刷回出厂 `boot.img` 救砖、没动 `init_boot`，系统能正常开机，
> 那是因为出厂内核配出厂 `kernelsu.ko` 恰好匹配，**不代表基座干净**。

#### 正确切换流程

```bash
# 1) 恢复出厂 boot + init_boot（两个都要，缺一个都还是 LKM）
fastboot flash boot      stock_boot.img
fastboot flash init_boot stock_init_boot.img
fastboot reboot

# 2) 确认基座干净：管理器首页应显示「未安装」
adb shell getprop ro.boot.slot_suffix
```

管理器里更省事的做法：首页 →「卸载」→ 选「恢复原厂镜像」，它会同时把 boot / init_boot 写回原厂。

```bash
# 3) 基座干净后再刷本仓库的 AK3 包（管理器里「安装 → 选择本地文件」，或 recovery 刷 zip）

# 4) 开机后管理器首页应显示「GKI 模式」/「已安装」，不需要再 patch 任何分区
```

#### 怎么判断现在是哪种状态

```bash
# 内核里到底有没有内置 KSU
adb shell su -c 'ls /sys/module/kernelsu'        # 内置 KSU 时存在
# 或直接看版本串与 KSU 状态
adb shell uname -r
```

管理器首页的「工作模式」一栏最直接：**LKM = init_boot 被改过；GKI = 内核内置**。
要切到本仓库的包，目标状态必须是**基座为出厂、然后只换 boot 里的内核**。

### 2. 先确认刷入方式对不对（最常见的坑）

AnyKernel3 的 zip 是给 **recovery / root 管理器**用的，**不是 fastboot 镜像**：

| 做法 | 结果 |
| --- | --- |
| `fastboot flash boot xxx.zip` | ❌ 把 zip 原样写进 boot 分区，必然卡标 |
| `fastboot flash boot Image` | ❌ boot 分区没有 boot header / ramdisk，必然卡标 |
| recovery 里刷 zip | ✅ |
| `magiskboot repack` 后 `fastboot flash boot new_boot.img` | ✅ |

`magiskboot` 可以从 Magisk 官方 APK 里取（`lib/arm64-v8a/libmagiskboot.so` 改名为 `magiskboot`），
或者用 [MagiskOnWSA/magiskboot 的 PC 构建](https://github.com/1nnovat1on/magiskboot)。

### 3. 最快的验证：`fastboot boot` 临时启动（不写分区）

**前提：base 必须是干净的**（第 1 小节那一步已经做完）。`fastboot boot` 只临时替换 `boot` 分区，
`init_boot` 仍然读 flash 里的那一份 —— 基座没洗干净，这一步会得到和刷入一样的卡 Logo，
从而误判成"内核坏了"。

把 Image 塞回一份原始 boot.img，然后**临时启动**它 —— 只在内存里跑一次，重启就恢复原样：

```bash
magiskboot unpack stock_boot.img
cp Image kernel
magiskboot repack stock_boot.img tmp_boot.img
fastboot boot tmp_boot.img
```

- 能进系统 → 内核没问题，问题出在"刷进去的那份 boot.img"或刷写目标；
- 还是卡 logo → 内核侧问题，继续往下看；
- 起不来就长按电源重启，**什么都没写进 flash**。


### 4. 拿内核自己的说法：pstore

内核崩溃/卡死时会把 console 写进 ramoops。**回到原系统后**能读上一次失败的日志：

```bash
bash scripts/get-last-log.sh      # 抓 pstore、自动标出关键证据并给结论
```

**时序很重要**：ramoops 只保留**上一次**开机的 console。正确顺序是

```
刷内核 → 卡住 → 长按电源强制重启进原系统 → 立刻跑脚本
```

再重启几次，旧记录就被覆盖了 —— 这也是为什么之前几次都看到"pstore 是空的"。
本仓库产物的 `CONFIG_PSTORE_CONSOLE=y`、`CONFIG_PSTORE_RAM=y` 都在，只要设备有 ramoops 节点就一定能留下记录。

对照症状：

| 日志里看到 | 结论 | 处理 |
| --- | --- | --- |
| `unknown symbol in module` | 厂商模块要的符号被裁掉了 | 本仓库已加 `CONFIG_TRIM_UNUSED_KSYMS=n` 全量导出，重新构建即可 |
| `disagrees about version of symbol` | 符号 CRC 与厂商模块不一致 | 用与出厂一致的 `manifest_branch`/`kernel_tag` 重编 |
| 一段 `Unable to handle kernel paging request` / `BUG:` 栈 | 内核代码问题，通常是某个功能补丁 | 按第 3 步二分 |
| 什么都没有 | 内核根本没跑起来（刷入方式 / AVB / boot header） | 回到第 1 步 |

### 5. 二分定位：`preset` 管补丁，`config_mode` 管配置

两个维度要分开排：`preset` 控制**打了多少补丁**，`config_mode` 控制**改了多少配置**。
连 `preset=vanilla` 都起不来，说明问题在配置层或更底层，跟 root/SUSFS 无关。

| `config_mode` | 内容 | 用来回答 |
| --- | --- | --- |
| `pristine` | 内核配置**一个字都不改**（连 `base.config` 都不叠加） | "是不是我们的配置改动把内核改坏了" |
| `device` | 用手机出厂配置 `config/device/gki_defconfig` 当 defconfig，只叠加 root/功能项 | "是不是配置与出厂不一致导致的 ABI 问题" |
| `overlay` | 在官方 `gki_defconfig` 上叠加 `config/base.config`（默认） | 正式构建 |

推荐顺序（前两层都不改代码，只改一个下拉框）：

```
① config_mode=pristine + preset=vanilla + root_manager=none
      → 纯 ACK 参考内核。起得来：问题在配置层；起不来：问题在构建流程或设备侧（刷入/AVB/分区）
② config_mode=device   + preset=vanilla + root_manager=none
      → 出厂配置 + 纯 ACK。起得来：说明 ABI 敏感项在 base.config 里，逐行加回去
③ config_mode=device   + preset=safe
      → 出厂配置 + root + SUSFS，正式可用组合
```

`device` 模式需要先把手机上的出厂配置取回来（**只读操作**）：

```bash
bash scripts/get-device-config.sh          # 读 /proc/config.gz -> config/device/gki_defconfig
git add config/device/gki_defconfig && git commit -m "config: 加入 warsaw 出厂内核配置"
```

拿到出厂配置后，**先别急着重新构建**——可以直接拿已经发布的包离线比对，2 分钟出结论：

```bash
bash scripts/check-abi.sh K90Ultra-GKI-....zip     # 默认比对 config/device/gki_defconfig
```

它会导出包里 Image 的内嵌 `.config`，与出厂配置逐项比 ABI 敏感项，并直接给结论：
一致 → 问题不在 config，别再重编；不一致 → 差异项会逐条列出来。

仓库里放了 `config/device/gki_defconfig` 之后，**每次构建都会自动做 ABI 对齐检查**：
`scripts/py/check_config_parity.py` 拿产物的 `.config` 和出厂配置逐项比，只盯 ABI 敏感项
（`MODVERSIONS` / `MODULE_SIG*` / `LTO*` / `CFI*` / 页大小 / `VA_BITS` / `TRIM_UNUSED_KSYMS` …），
有一项不同就**直接终止构建**，不会打包出"看着正常但厂商模块全加载不了"的包。

用出厂配置的意义：内核的 `CONFIG_*` 决定了 `struct` 布局，进而决定导出符号的 CRC。
厂商的 `vendor_dlkm` / `system_dlkm` 模块是按出厂配置编的，配置只要在 ABI 敏感项上偏了一点，
模块就会 `disagrees about version of symbol` 全部加载失败 —— 内核活着、Android 起不来、卡 logo。

### 5.1 用 `preset` 把补丁变量降到最少

| 构建 | 内容 | 用途 |
| --- | --- | --- |
| `preset=vanilla` | 纯 GKI，不集成 root、不加任何补丁 | 先证明"基础内核能启动" |
| `preset=safe` | root + SUSFS（社区验证最充分的组合） | 证明 root 方案可用 |
| `preset=full` | 全量 | 出问题就逐个关开关，定位到具体补丁 |

注意 `full` 是**默认预设**，所以排查时反过来做：先把 `preset` 改成 `safe`（或 `vanilla`）跑一轮，
确认真能开机再回到 `full`。

顺序建议：**vanilla → safe → full**，每次只加一层。NoMount 与 BBG 都会改 VFS / 块设备层，
是最容易"内核活着但 Android 起不来"的两个，建议最后再加。

嫌一轮一轮太慢可以一次性并行出多个包：`variants` 填 `safe,full`，两个预设各跑一份；
再配上 `root_manager=all`，一轮就能同时拿到"所有管理器"的对照包，直接判断是"基础内核的问题、
某个补丁的问题，还是某个管理器的签名/兼容问题"。

## 七、常见问题

**默认会一次出 5 个包，会不会很久 / 很费额度**
矩阵里的每个组合是一个独立 job、独立跑一遍 `repo sync` + 编译，彼此并行。整体墙钟时间和只构建一个差不多
（主要耗时在源码同步与 LTO 链接），代价是并行占用 5 个 runner。只想出某一个管理器就把它单独选上，
或者用 `variants` 控制预设数量（`variants=full,safe` + `root_manager=all` 是 10 个 job）。

**可以只换管理器 APK、不重刷内核吗**
不行。5 个包分别是把对应管理器的内核代码编进去的，签名校验各不相同；换管理器必须刷对应那份 AK3 包。

**构建在 `repo sync` 阶段失败**
googlesource 偶发限速。workflow 已经内置 3 次重试与低速中断（<1KB/s 持续 60s 直接断开重连）。多次失败可改用 `kernel_tag` 钉到一个已发布的 tag。

**补丁报 reject（上传了 `patch-rejects` 工件）**
说明 ACK 源码已经漂移，而 SUSFS 补丁还是按旧代码写的。两个办法：
1. 把 `manifest_branch` 换成更接近 SUSFS 分支的日期分支（SUSFS 的 6.6 分支通常是跟某个 `-lts` 快照对齐的）；
2. 在 `scripts/prepare.sh` 对应的 compat 步骤里补一个 sed/python 适配（参考 `scripts/py/susfs_66_compat.py` 的写法）。

**刷完开不了机 / 卡第一屏**
- 大概率是页大小或 KMI 代次不对：确认 `page_size=4k`、`manifest_branch` 是 6.6 线；
- 用 fastboot 刷回备份的 boot：`fastboot flash boot stock_boot.img`；
- 如果能进系统但相机/WiFi 没了，抓 `adb shell dmesg | grep -iE "disagrees about version|version magic"`：
  - 报 `disagrees about version of symbol` → 符号 CRC 变了，用 `kernel_tag` 把源码钉到与出厂同代的 ACK tag 重新构建；
  - 报 `version magic ... should be ...` → 说明 MODVERSIONS 那条忽略版本前缀的路径没生效，这时才需要 `stock_kernel_version`。

**管理器显示"未安装"**
内核里集成的管理器和你装的 APK 签名不匹配。按上面第三节的表格装对应的管理器；`bakasu` 还额外关掉了多管理器支持，只能用 BakaSU 自己的 APK。

**SUSFS 模块提示"内核不支持"**
确认构建时 `susfs=true`，且 Artifacts 里的 `build-config-and-info` 中 `kernel.config` 含 `CONFIG_KSU_SUSFS=y`。

**想加自己的补丁 / 改配置**
- 配置项：直接往 `config/base.config` 或 `config/features/*.config` 里加行，`prepare.sh` 会自动应用并回读校验；
- 补丁：在 `prepare.sh` 里对应阶段调用 `apply_patch_file <路径> "<说明>"`（失败即中断）或 `apply_patch_optional`（失败只告警）。

---

## 八、维护与更新

- **跟进 SUSFS**：`susfs_branch` 保持 `gki-android15-6.6`，默认取分支最新 commit；想锁死就传 `SUSFS_COMMIT`（改 workflow env 或加 input）。
- **跟进 kernel_patches**：`KERNEL_PATCHES_REF` 默认 `main`。
- **可复现构建**：同时钉住 `manifest_branch`（日期分支）+ `kernel_tag` + 各 root 的 `root_ref`（commit）+ `susfs` 的 commit。
- **升级到别的设备/内核**：需要改 `scripts/lib.sh` 的 `ANDROID_VERSION`/`KERNEL_VERSION`、`manifest_branch` 默认值、`susfs_branch`、以及 `config/features/*` 里随版本变化的配置项。

---

## 九、致谢与许可

本仓库只是把下列项目的成果串成流水线：

- [Google ACK / Kleaf](https://android.googlesource.com/kernel/common) —— GKI 源码与构建系统
- [simonpunk/susfs4ksu](https://gitlab.com/simonpunk/susfs4ksu) —— SUSFS
- [tiann/KernelSU](https://github.com/tiann/KernelSU)、[KernelSU-Next](https://github.com/KernelSU-Next/KernelSU-Next)、[BakaSU](https://github.com/Baka-SU/BakaSU)、[SukiSU-Ultra](https://github.com/SukiSU-Ultra/SukiSU-Ultra)、[KOWX712/KernelSU](https://github.com/KOWX712/KernelSU) —— root 管理器
- [WildKernels/GKI_KernelSU_SUSFS](https://github.com/WildKernels/GKI_KernelSU_SUSFS)、[WildKernels/kernel_patches](https://github.com/WildKernels/kernel_patches)、[WildKernels/AnyKernel3](https://github.com/WildKernels/AnyKernel3) —— 构建思路与补丁集
- [maxsteeel/nomount](https://github.com/maxsteeel/nomount)、[vc-teahouse/Baseband-guard](https://github.com/vc-teahouse/Baseband-guard)、[ravindu644/Droidspaces-OSS](https://github.com/ravindu644/Droidspaces-OSS)
- [bakasu.org 构建文档](https://bakasu.org/zh-Hans/guide/build) —— root 集成流程参考

脚本以 GPL-2.0 发布；内核源码与各补丁遵循其原始许可（GPL-2.0）。刷机风险自负。
