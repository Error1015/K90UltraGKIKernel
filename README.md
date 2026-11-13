# K90 Ultra GKI Kernel（warsaw / SM8750 / 6.6）

为 **Redmi K90 Ultra（代号 warsaw，SM8750，内核 6.6.118，4K 页）** 构建 GKI 内核，
默认内置 **BakaSU + SUSFS**（也支持 SukiSU-Ultra / KernelSU / KernelSU-Next / KowSU）。
每次出两样东西：**完整 boot.img**（`fastboot flash boot`）和**对应的 AnyKernel3 zip**
（recovery / 内核管理器直接刷）。两者内容完全一致。

> **这一版是重做的。** 旧版"构建成功但刷进去卡 logo"的根因已经定位（见第二节），
> 旧代码整体放在 `legacy/` 里仅作参考，不再参与构建。

---

## 一、先说清楚：为什么旧版一定起不来

旧版的产物体检其实全通过了 —— 配置与出厂逐项一致（6184 项、ABI 敏感项 0 差异）、
arm64 头正常、KernelSU/SUSFS 都编进去了。问题不在内核，在**打包**。

这台机器的 boot 分区不是"裸内核"，而是三块拼起来的一个整体：

```
偏移 0              : boot header v4（header_size=1584, ramdisk_size=0）
偏移 4096           : 内核 Image
round_up(内核末尾)   : vbmeta blob（2368 字节，AVB0 开头）
文件末尾 -64         : AVB footer（AVBf），写着 original_image_size / vbmeta_offset / vbmeta_size
文件总长            : 100663296 字节（= 96MB 分区大小）
```

实测原厂 boot.img（OS 4.0.8.0）：

| 字段 | 值 |
| --- | --- |
| 文件大小 | 100663296 |
| header_version / header_size | 4 / 1584 |
| kernel_size | 36801024 |
| ramdisk_size | **0**（ramdisk 在 `init_boot` 里） |
| vbmeta_offset / vbmeta_size | 36823040 / 2368 |
| 内核版本 | `6.6.118-android15-8-g0908354dac1b-ab16143355-4k` |

**换内核之后，vbmeta blob 必须整体挪到新的页对齐位置，footer 的三个字段必须重写，
输出长度必须还是 100663296。** 少做一步，footer 就指向被新内核覆盖的旧偏移，
AVB 校验必然失败 —— 表现就是**卡在 logo、不 panic、不重启**。

旧版两个产物都踩了：

| 旧产物 | 问题 |
| --- | --- |
| AnyKernel3 zip | AK3 只写内核，完全不处理 vbmeta 与 AVB footer |
| `boot-k90-custom.img`（37MB） | 只改了 `kernel_size`，没有 vbmeta、没有 footer |

再加上当时设备还是 **LKM 模式**（`init_boot` 里有 KernelSU 塞进去的 `kernelsu.ko`），
内核换成 GKI 内置 KSU 之后那份 `.ko` 的符号 CRC 对不上，首阶段 init 等不到模块，
同样卡住不动。**这两个坑必须一起解决**。

---

## 二、现在的做法

```
project/prepare.sh   repo sync ACK → 锁到 6.6.118 的发布 tag → 集成 root/SUSFS/附加功能 → 写配置
project/build.sh     make ARCH=arm64 LLVM=1 O=out Image → 逐项回读校验 → 产物自检
project/pack.py      把 Image 打进「原厂布局」的 boot.img（重定位 vbmeta + 重写 AVB footer）
project/verify.py    结构 / 版本串 / 内嵌配置三重验收，任何一项不过就不发布
```

三个刻意的选择：

1. **用 Kbuild（`make`）而不是 Kleaf/Bazel。**
   Image 就是 `common` 树的标准产物，少一层构建系统就少一类失败。
   这条路也是本机型已有真机验证案例走过的。
2. **配置直接用原厂 `.config`**（`configs/warsaw_defconfig`，从原厂 boot.img 内嵌的
   `IKCONFIG` 提取，7756 行），只在上面叠加 KSU/SUSFS 与版本串。
   builtin/module 的划分必须和出厂一致，否则 vendor_dlkm 里的模块会重复或找不到。
3. **只关掉符号裁剪**（`CONFIG_TRIM_UNUSED_KSYMS=n`）。
   白名单文件 `abi_symbollist.raw` 是 Kleaf 构建时生成的，`make` 构建没有它，
   继续开着会把导出符号裁到只剩内核自己用的那些，厂商模块随即 `unknown symbol`。

### 产物

默认一次只出**一个**包（你选的那个 root），不多跑对照 job；要一次出齐就选 `root=all`。
所有产物发到**同一个 Release** —— 一条 tag、一个页面，不用到处找。

| `root` 输入 | 产出 |
| --- | --- |
| `bakasu`（默认） | `boot-warsaw-bakasu-6.6.118.img` + `ak3-warsaw-bakasu-6.6.118.zip` |
| 指定某一个管理器 | 同上的 `<管理器>` 版本 |
| `all` | 5 套（bakasu / sukisu-ultra / kernelsu / kernelsu-next / kowsu），一个 job 一个，并行 |
| `none` | `boot-warsaw-none-6.6.118.img` + `ak3-warsaw-none-6.6.118.zip`，纯内核（排查用） |

每套都给两种刷法，内容完全一致：

| 文件 | 怎么刷 |
| --- | --- |
| `boot-warsaw-*.img` | 电脑上 `fastboot flash boot xxx.img`（96MB 完整分区镜像） |
| `ak3-warsaw-*.zip` | AnyKernel3 包，recovery / 内核管理器直接刷，手机上就能完成 |

**关于 AK3 的一个前提**：这个 zip 里装的是**完整分区镜像**，安装脚本只做 `dd`，
不在设备上重打包。因为这台机器 boot 分区里有 vbmeta blob 和 AVB footer，
用传统的「解包 → 只换内核 → repack」一定会把它们弄坏，表现就是卡 logo。
所以别拿这份 AK3 去套别的内核，也别用别的内核的 AK3 刷这台机。

### root 支持情况

| root | 状态 | 说明 |
| --- | --- | --- |
| `bakasu` | **默认** | 自带 SUSFS 胶水与 ksu_toolkit；关掉多管理器支持，只认自己的 APK |
| `sukisu-ultra` | 支持 | 自带 SUSFS 胶水；若某版没有，会自动套用仓库内置的移植补丁 |
| `kernelsu` | 支持 | tiann 原版，SUSFS 需要 susfs4ksu 的 `10_enable_susfs_for_ksu.patch`（自动打） |
| `kernelsu-next` | 支持 | 默认分支 `dev`；顺带修掉它 Kbuild 在 mrproper 阶段就 `$(error)` 的坑 |
| `kowsu` | 支持 | **与 SUSFS 不兼容**，勾了 SUSFS 会自动关掉并提示 |
| `all` | 支持 | 一次跑完上面 5 个，产物各一份、发布到同一个 Release |
| `none` | 支持 | 纯内核，不带 root（排查内核/打包问题用） |

SUSFS 胶水是运行时探测的：先看 root 仓库自己的 `Kconfig` 里有没有 `config KSU_SUSFS`，
有就不动，没有才打对应的使能补丁 —— 这样各家版本升级不会一次把流水线卡死。

### 附加功能

| 输入 | 做什么 | 实现方式 |
| --- | --- | --- |
| `susfs` | SUSFS 内核侧补丁 + 10 项 `CONFIG_KSU_SUSFS_*` | susfs4ksu + 各 root 的胶水 |
| `ntsync` | NTSync（Proton / Wine 同步原语） | kernel_patches 两个补丁 |
| `networking` | BBRv3 + IPSet + CIFS，默认拥塞控制 `bbr` | BBRv3 补丁失败时自动回退到内核自带 BBR |
| `nomount` | NoMount（VFS 层无挂载点伪装） | 走上游 `kernel/setup.sh` |
| `bbg` | Baseband Guard（保护 efs / modem） | 走上游 `setup.sh` + 自动排进 LSM 顺序 |
| `droidspaces` | DroidSpaces 容器所需 namespace / IPC | kABI 补丁 + 配置项 |
| `bpf` | BTF / eBPF（出厂已是 `y`，一般不用勾） | 只改配置 |
| `unicode` | Unicode 绕过修复 | kernel_patches，补丁不适用则跳过并告警 |

所有附加功能默认**全关**。每勾一个，`build.sh` 都会在 `olddefconfig` 之后回读最终
`.config` 确认符号真的生效 —— 补丁打了但配置没生效会直接中断构建，不会出"看起来有其实没有"的包。

---

## 三、跑一次构建

```text
Actions → Build K90 Ultra GKI → Run workflow
```

默认参数（`root=bakasu`、`susfs=true`）直接跑即可，约 15~25 分钟；
选 `root=all` 时 5 个 job 并行，墙钟时间差不多（各自独立 sync + 编译）。

**内核版本、tag、版本串、页大小、分区大小全部锁死在 `project/device.env`，不是参数。**
这个仓库只服务 warsaw 一台机器，把版本做成输入只会多一个填错的机会
（填错的表现是能出包、刷进去 vendor 模块全部 `unknown symbol`）。

| 参数 | 默认 | 说明 |
| --- | --- | --- |
| `root` | `bakasu` | 可选 `bakasu` / `sukisu-ultra` / `kernelsu` / `kernelsu-next` / `kowsu` / `none` |
| `susfs` | `true` | 需要 root 不为 none；kowsu 会自动关掉 |
| `nomount` / `bbg` / `ntsync` / `networking` / `bpf` / `droidspaces` / `unicode` | `false` | 附加功能，见上一节 |
| `release` | `release` | `release` / `prerelease` / `none`（只留 Artifacts） |
| `publish_run_id` | 空 | 只发布：填一次成功运行的 run id，取那次产物发 Release，不重新编译 |

锁定的基准（`project/device.env`）：

| 项 | 值 |
| --- | --- |
| 机型 / SoC | `warsaw` / `sm8750` |
| 内核版本 | `6.6.118`（必须与手机 `uname -r` 一致） |
| ACK tag | `android15-6.6.118_r00`（写死，不再每次去 googlesource 解析） |
| 源码分支 | `android15-6.6` / manifest `common-android15-6.6-lts` |
| 版本串 | `-android15-8-warsaw-4k`（`-android15-8` 是 KMI 标识，别动） |
| 页大小 / 分区 | `4096` / `100663296`（96MB） |

这些值在 `lib.sh` 里以普通赋值覆盖环境变量，**从外部传同名变量不会生效**。
真要换机型或换内核，改这个文件，并在 PR 里说明。

---

## 四、刷入

> ⚠️ 刷机有风险。先备份原厂 `boot` 与 `init_boot`，并确认能进 fastboot。

```bash
# 0) 备份（强烈建议）
adb shell su -c 'dd if=/dev/block/by-name/boot of=/sdcard/stock_boot.img'
adb shell su -c 'dd if=/dev/block/by-name/init_boot of=/sdcard/stock_init_boot.img'
adb pull /sdcard/stock_boot.img
adb pull /sdcard/stock_init_boot.img

# 1) 如果之前用过 LKM 模式（管理器首页显示 LKM，或 ksu_boot 里有 patch 过的 init_boot），
#    必须先把 init_boot 回原厂 —— 这一步漏了，GKI 内核一定卡 logo
fastboot flash init_boot stock_init_boot.img

# 2) 刷本仓库的 boot.img（完整分区镜像，不是普通 AK3 的内核包）
fastboot flash boot boot-warsaw-sukisu-6.6.118.img

# 3) 重启
fastboot reboot
```

没有电脑时用 AK3 的那个 zip：recovery 里 install，或者用内核管理器 App 选这个 zip。
它在安装前会先把当前 boot 备份到 `/sdcard/boot-backup-<时间>.img`，写完后回读前 1MB 校验。

刷完管理器首页应该显示 **GKI 模式 / 已安装**，不需要再 patch 任何分区。
包里集成的是哪个管理器的内核代码，就**必须装哪一个的管理器 APK**，装别家会显示"未安装"：

| 内核里集成的 | 需要安装的管理器 |
| --- | --- |
| `bakasu` | [BakaSU](https://github.com/Baka-SU/BakaSU/releases) |
| `sukisu-ultra` | [SukiSU-Ultra](https://github.com/SukiSU-Ultra/SukiSU-Ultra/releases) |
| `kernelsu` | [KernelSU](https://github.com/tiann/KernelSU/releases) |
| `kernelsu-next` | [KernelSU Next](https://github.com/KernelSU-Next/KernelSU-Next/releases) |
| `kowsu` | [KowSU](https://github.com/KOWX712/KernelSU/releases) |

### 想先不写 flash 试一下

```bash
fastboot boot boot-warsaw-sukisu-6.6.118.img   # 只在内存里起一次，重启即恢复
```

前提同样是 `init_boot` 已经回原厂，否则会得到和刷入一样的卡 logo，白白误判成"内核坏了"。

---

## 五、起不来怎么查

| 症状 | 先看这里 |
| --- | --- |
| 卡 logo 不动 | `init_boot` 是否还是 LKM 版（`bash tools/check-device.sh`，只读） |
| 卡 logo，但 init_boot 已回原厂 | 换成 `root=none` 跑一份：还卡就是打包/刷写问题，不是 root 的问题 |
| 能进系统但相机/WiFi 没了 | `adb shell dmesg \| grep -iE "disagrees about version\|version magic"` → 符号 CRC 不匹配，源码版本没锁对 |
| 想拿上一轮失败的内核日志 | `bash tools/get-last-log.sh`（时序：刷→卡住→重启进原系统→立刻跑） |

`tools/check-device.sh` 会输出页大小、KMI、`init_boot` 是否残留 LKM、KSU 状态，全是只读操作。

---

## 六、目录

```
.github/workflows/build.yml   唯一构建入口（选定 root 一条，或 root=all 出 5 条；最后合并成一个 Release）
project/
  device.env                  机型/内核基准（版本、tag、版本串、页大小、分区）唯一真源
  prepare.sh                  同步源码 + 锁版本 + 集成 root/SUSFS/附加功能 + 写配置
  build.sh                    make Image + 配置回读 + 产物自检
  pack.py                     AVB 感知的 boot.img 打包/检查
  verify.py                   发布前验收（结构 + 版本 + 内嵌配置）
  template.py                 从原厂 boot.img 重新生成打包模板
  resolve_tag.py              备用：按版本反查 ACK tag（默认走 device.env 里写死的 tag）
  pin_manifest.py             把 manifest 里 common 的 revision 钉到 tag
  susfs_66_compat.py          SUSFS 在 6.6 上的固定编译坑（幂等）
  ak3.sh                      把完整 boot.img 封成 AnyKernel3 zip
  lib.sh                      日志 / 补丁 / 配置片段
ak3/
  anykernel.sh                AK3 安装脚本（dd 整分区镜像，不重打包）
configs/
  warsaw_defconfig            原厂完整配置（从 boot.img 提取，勿手改）
  base.fragment               必须项（关符号裁剪、版本串）
  root/{bakasu,sukisu-ultra,kernelsu,kernelsu-next,kowsu}.fragment
  features/{susfs,ntsync,networking,nomount,bbg,droidspaces,bpf}.fragment
patches/
  susfs-for-sukisu-v4.3.0.patch   susfs4ksu → SukiSU 的胶水移植（来自已验证案例）
firmware/
  boot-template.bin           原厂 header(4096) + vbmeta(2368)，6.4KB
  boot-template.json          分区大小 / 页大小 / vbmeta 尺寸
tools/
  check-device.sh             连手机只读自检
  get-last-log.sh             抓上一次开机的 pstore
legacy/                       旧流水线（Kleaf + AK3）与旧配置，仅作参考
```

### firmware 模板要跟着固件走

`firmware/boot-template.bin` 是从 **OS 4.0.8.0** 的原厂 `boot.img` 提取的。
换了固件版本（分区大小或 vbmeta 变化）就要重新提取：

```bash
python project/pack.py inspect stock_boot.img      # 先看结构对不对
python project/template.py stock_boot.img          # 重新生成 firmware/boot-template.*
```

> 模板里只有 4096 字节头部 + 2368 字节 vbmeta，不含内核，所以可以进仓库。

---

## 七、加功能的顺序（重要）

补丁越多，"内核活着但 Android 起不来"的概率越高。建议一次只加一层，每层都能开机再往下走：

```
① root=none（纯内核）                  → 证明内核 + 打包没问题
② root=bakasu，susfs=true              → 证明 root 方案可用
③ 单个附加功能（先 networking 或 ntsync，它们只碰 net / 内核内部）
④ 最后再上 nomount / bbg               → 这两个要改 VFS 与块设备层，风险最高
```

任何一层起不来，就把那一层关掉重跑。怀疑是内核或打包的问题时，单独跑一次 `root=none`
做对照 —— 它还能开机就说明问题一定在补丁或 root 侧。

---

## 八、致谢

- [Android Common Kernel](https://android.googlesource.com/kernel/common) — GKI 源码
- [BakaSU](https://github.com/Baka-SU/BakaSU)、[SukiSU-Ultra](https://github.com/SukiSU-Ultra/SukiSU-Ultra)、[KernelSU](https://github.com/tiann/KernelSU)、[KernelSU-Next](https://github.com/KernelSU-Next/KernelSU-Next)、[KowSU](https://github.com/KOWX712/KernelSU) — root
- [simonpunk/susfs4ksu](https://gitlab.com/simonpunk/susfs4ksu) — SUSFS
- [wjljh/xiaomi_kernel_for_warsaw_sukisu_susfs](https://github.com/wjljh/xiaomi_kernel_for_warsaw_sukisu_susfs) — 同机型的真机验证案例，boot.img 布局与 AVB 处理、SUSFS 移植补丁均出自这里
- [WildKernels/GKI_KernelSU_SUSFS](https://github.com/WildKernels/GKI_KernelSU_SUSFS) — 构建流程参考

脚本 GPL-2.0；内核与各补丁遵循其原始许可。
