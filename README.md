# K90Ultra GKI Kernel

在 GitHub Actions 上为 **Redmi K90 Ultra（代号 warsaw / SM8750 / 内核 6.6）** 构建 GKI 内核，内置 **KernelSU 系 root 管理器** 与 **SUSFS** 隐藏方案，并把常见的自定义功能（NoMount、Baseband Guard、DroidSpaces、BBRv3、NTSync、Ptrace/Unicode 修复、BTF/eBPF）做成勾选项。

产物是 **AnyKernel3 刷机包**，只替换 boot 分区里的内核镜像，不动 vendor_boot / vendor_dlkm / dtbo。

---

## 一、先看这里（重要）

1. **刷机有风险。** 变砖、数据丢失、指纹/支付失效都可能发生，请先备份 `boot` 分区并确认自己能进 fastboot / recovery。
2. **内核来自 Google ACK 的 GKI 6.6 源码，不是小米私有的 msm-kernel 树。**
   小米开源的 `warsaw-w-oss` 分支是 Qualcomm kernel_platform 里的 `msm-kernel` 部分，它的 Bazel 定义（`msm_kernel_la.bzl`）明确写着 `base_kernel = "//common:kernel_aarch64"` —— 也就是说设备 boot 里的内核主体本来就是 GKI，小米那边编译的是同一份 ACK + vendor 模块。本仓库等价地直接构建这份 GKI，因此不需要（也无法）单独构建小米的 msm-kernel。
3. **KMI 必须匹配。** 出厂固件是 6.6 + 4k 页，对应的 GKI 线是 `android15-6.6`（ACK 没有 `android16-6.6` 分支，Android 16 的 6.6 设备继续用这条线）。默认值已经按这个设置好，**不要**随便改成 6.1 / 6.12。
4. **vendor_dlkm 里的厂商模块不一定兼容所有 sublevel。** 如果刷完出现相机/WiFi/指纹异常或模块加载失败，用 `stock_kernel_version` 选项把内核版本对齐到出厂版本（例如 `6.6.57`）再试。

---

## 二、快速开始

```text
1. Fork 本仓库（或者直接用它当模板新建仓库）
2. 打开 Actions → Build GKI Kernel → Run workflow
3. 按需勾选功能，点绿色按钮
4. 等 40~90 分钟，在运行页面的 Artifacts 下载 zip
5. 备份 boot → 用 KernelSU 管理器刷入 zip → 装对应管理器 APK
```

### 刷入步骤

```bash
# 1) 备份原始 boot（强烈建议，出问题可救）
adb shell su -c 'dd if=/dev/block/by-name/boot of=/sdcard/stock_boot.img'
adb pull /sdcard/stock_boot.img

# 2) 刷入
#    推荐：在已 root 的系统里用 KernelSU 管理器的"安装 → 选择本地文件"刷 zip；
#    或者进 recovery 直接刷 zip。
#    刷完重启，再安装与内核匹配的管理器 APK。
```

启用 SUSFS 时，额外安装 [susfs4ksu-module](https://github.com/sidex15/susfs4ksu-module) 才能用全部隐藏功能（`sus_path`、`sus_mount` 等）。

### 刷机前自检（建议先做）

产物是一个内核二进制，刷错位置的代价很高。可以先在电脑上做两件事，都不碰手机：

```bash
# 1) 静态体检：头部结构、页大小、内嵌 .config、KSU/SUSFS 是否真的编进去了
bash scripts/verify-image.sh K90Ultra-GKI-....zip --expect-root --expect-susfs
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
| `kernelsu-next` | 默认值。功能最全、SUSFS 支持最顺，社区使用最广 |
| `kernelsu` | tiann 原版，需要额外打 `10_enable_susfs_for_ksu.patch` 才能接 SUSFS（仓库已自动处理） |
| `bakasu` | 原 ReSukiSU 团队，自带 SUSFS 胶水与 ksu_toolkit，默认只信任自己的管理器签名 |
| `sukisu-ultra` | 自带 SUSFS 与多管理器签名表 |
| `kowsu` | **与 SUSFS 不兼容**，勾了 SUSFS 会直接拒绝构建 |
| `none` | 纯内核，不集成任何 root，用于对照/排查 |

`root_ref` 可以钉住分支、tag 或 commit。留空则取各仓库默认分支最新（`kernelsu-next` 取 `dev`，其余取 `main`/`master`）。

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
| `page_size` | `4k` | 出厂是 4k。16k 只在确定设备是 16k 时才选 |
| `manifest_branch` | `common-android15-6.6-lts` | 跟踪 6.6 LTS 最新。想复现历史构建就换成 `common-android15-6.6-2025-06` 这类日期分支 |
| `kernel_tag` | 空 | 钉到某个不可变 ACK tag（如 `android15-6.6-2025-06`），只影响 `common` 仓库 |
| `stock_kernel_version` | 空 | 版本对齐 hack，见下文 |
| `susfs_branch` | `gki-android15-6.6` | 换 SUSFS 分支时同步改 |
| `brand` | `K90Ultra` | 只影响产物命名，不改内核版本号（避免破坏 KMI） |
| `publish_release` | `true` | 构建成功自动发 Release，方便手机直接下载 |

#### 关于 `stock_kernel_version`

先说结论：**大多数情况不需要它，留空即可。**

`vermagic` 的格式是 `<内核版本> SMP preempt mod_unload modversions aarch64`。GKI 内核开了 `CONFIG_MODVERSIONS=y`，加载模块时只会比较**第一个空格之后**的部分（源码注释原文：`First part is kernel version, which we ignore if module has crcs.`，见 `kernel/module/version.c`）。也就是说 6.6.118 与出厂的 6.6.57 之间、甚至版本号里的 `-maybe-dirty` 都不影响厂商模块加载 —— 真正起保护作用的是每个导出符号的 CRC（KMI 约定）。

所以这个开关只在极端情况下有意义：比如你关掉了 `CONFIG_MODVERSIONS`，或者某个模块没带 CRC 导致走了严格比较。填 `6.6.57` 会把 Makefile 的 `SUBLEVEL` 改成 57 让 UTS_RELEASE 与出厂一致，代价是版本号和真实代码不再对应。

真正需要担心的是 `disagrees about version of symbol xxx` 这类报错 —— 那是符号 CRC 变了，改版本号救不了，得换回出厂同代的 GKI 源码（用 `kernel_tag` 钉住对应 ACK tag）。

---

## 四、构建流水线

```
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
.github/workflows/build.yml   # 唯一的构建入口，所有选项都在这里
.github/workflows/verify.yml  # 刷机前体检：静态检查 + QEMU 启动冒烟测试
config/
  base.config                 # 每次构建都会应用（overlayfs/tmpfs/kallsyms/fanotify、关 WERROR）
  root/*.config               # 各 root 管理器的 CONFIG_KSU 与专属开关
  features/*.config           # SUSFS / NoMount / BBG / DroidSpaces / Networking / NTSync / BPF
scripts/
  lib.sh                      # 日志、重试、配置写入与回读、补丁应用
  prepare.sh                  # 同步源码 + 集成 root/补丁 + 写配置 + 提交源码树
  build.sh                    # Kleaf 构建 + 产物校验
  package.sh                  # AnyKernel3 打包 + 构建说明
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

## 六、常见问题

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

## 七、维护与更新

- **跟进 SUSFS**：`susfs_branch` 保持 `gki-android15-6.6`，默认取分支最新 commit；想锁死就传 `SUSFS_COMMIT`（改 workflow env 或加 input）。
- **跟进 kernel_patches**：`KERNEL_PATCHES_REF` 默认 `main`。
- **可复现构建**：同时钉住 `manifest_branch`（日期分支）+ `kernel_tag` + 各 root 的 `root_ref`（commit）+ `susfs` 的 commit。
- **升级到别的设备/内核**：需要改 `scripts/lib.sh` 的 `ANDROID_VERSION`/`KERNEL_VERSION`、`manifest_branch` 默认值、`susfs_branch`、以及 `config/features/*` 里随版本变化的配置项。

---

## 八、致谢与许可

本仓库只是把下列项目的成果串成流水线：

- [Google ACK / Kleaf](https://android.googlesource.com/kernel/common) —— GKI 源码与构建系统
- [simonpunk/susfs4ksu](https://gitlab.com/simonpunk/susfs4ksu) —— SUSFS
- [tiann/KernelSU](https://github.com/tiann/KernelSU)、[KernelSU-Next](https://github.com/KernelSU-Next/KernelSU-Next)、[BakaSU](https://github.com/Baka-SU/BakaSU)、[SukiSU-Ultra](https://github.com/SukiSU-Ultra/SukiSU-Ultra)、[KOWX712/KernelSU](https://github.com/KOWX712/KernelSU) —— root 管理器
- [WildKernels/GKI_KernelSU_SUSFS](https://github.com/WildKernels/GKI_KernelSU_SUSFS)、[WildKernels/kernel_patches](https://github.com/WildKernels/kernel_patches)、[WildKernels/AnyKernel3](https://github.com/WildKernels/AnyKernel3) —— 构建思路与补丁集
- [maxsteeel/nomount](https://github.com/maxsteeel/nomount)、[vc-teahouse/Baseband-guard](https://github.com/vc-teahouse/Baseband-guard)、[ravindu644/Droidspaces-OSS](https://github.com/ravindu644/Droidspaces-OSS)
- [bakasu.org 构建文档](https://bakasu.org/zh-Hans/guide/build) —— root 集成流程参考

脚本以 GPL-2.0 发布；内核源码与各补丁遵循其原始许可（GPL-2.0）。刷机风险自负。
