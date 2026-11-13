# K90 Ultra GKI Kernel（warsaw / SM8750 / 6.6）

为 **Redmi K90 Ultra（代号 warsaw，SM8750，内核 6.6.118，4K 页）** 构建 GKI 内核，
内置 **SukiSU-Ultra + SUSFS**，产物是一个 **可以直接 `fastboot flash boot` 的完整 boot.img**。

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
project/prepare.sh   repo sync ACK → 锁到 6.6.118 的发布 tag → 集成 SukiSU/SUSFS → 写配置
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

一次运行出两份（矩阵并行，互不影响）：

| 包 | 内容 | 用途 |
| --- | --- | --- |
| `boot-warsaw-vanilla-6.6.118.img` | 纯内核，不带 root | 先证明内核本身能起 |
| `boot-warsaw-sukisu-6.6.118.img` | SukiSU-Ultra + SUSFS | 日常使用 |

两份都是 96MB 完整分区镜像，**没有 zip，不要用 recovery 刷**。

---

## 三、跑一次构建

```text
Actions → Build K90 Ultra GKI → Run workflow
```

默认参数（`kernel_release=6.6.118`、`root=sukisu-ultra`、`susfs=true`）直接跑即可，
约 20~35 分钟（矩阵两个 job 并行）。

| 参数 | 默认 | 说明 |
| --- | --- | --- |
| `kernel_release` | `6.6.118` | 手机 `uname -r` 的版本。会自动解析出同版本的 ACK 发布 tag 并锁源码；解析不到会回退到分支 HEAD，但随后会因为版本校验不通过而**中断**（不会产出包） |
| `kernel_tag` | 空 | 直接钉 ACK tag，例如 `android15-6.6-2026-XX_rN`，填了就忽略 `kernel_release` |
| `root` | `sukisu-ultra` | 也可以选 `none`（等价于只要 vanilla 那份） |
| `susfs` | `true` | 需要 root 不为 none |
| `localversion` | `-android15-8-warsaw-4k` | 保留 `-android15-8` 前缀（KMI 标识） |
| `release` | `release` | `release` / `prerelease` / `none`（只留 Artifacts） |

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

# 2) 刷本仓库的 boot.img（完整分区镜像，不是 zip）
fastboot flash boot boot-warsaw-sukisu-6.6.118.img

# 3) 重启
fastboot reboot
```

刷完管理器首页应该显示 **GKI 模式 / 已安装**，不需要再 patch 任何分区。
包里内置的是 SukiSU-Ultra 的内核代码，**必须装 SukiSU-Ultra 的管理器 APK**，装别家会显示"未安装"。

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
| 卡 logo，但 init_boot 已回原厂 | 刷 vanilla 那份；还卡就是打包/刷写问题，不是 root 的问题 |
| 能进系统但相机/WiFi 没了 | `adb shell dmesg \| grep -iE "disagrees about version\|version magic"` → 符号 CRC 不匹配，源码版本没锁对 |
| 想拿上一轮失败的内核日志 | `bash tools/get-last-log.sh`（时序：刷→卡住→重启进原系统→立刻跑） |

`tools/check-device.sh` 会输出页大小、KMI、`init_boot` 是否残留 LKM、KSU 状态，全是只读操作。

---

## 六、目录

```
.github/workflows/build.yml   唯一构建入口（vanilla / sukisu 两条并行）
project/
  prepare.sh                  同步源码 + 锁版本 + 集成 root/SUSFS + 写配置
  build.sh                    make Image + 配置回读 + 产物自检
  pack.py                     AVB 感知的 boot.img 打包/检查
  verify.py                   发布前验收（结构 + 版本 + 内嵌配置）
  resolve_tag.py              6.6.118 → ACK 发布 tag
  pin_manifest.py             把 manifest 里 common 的 revision 钉到 tag
  lib.sh                      日志 / 补丁 / 配置片段
configs/
  warsaw_defconfig            原厂完整配置（从 boot.img 提取，勿手改）
  base.fragment               必须项（关符号裁剪、版本串）
  root/sukisu-ultra.fragment  CONFIG_KSU=y
  features/susfs.fragment     SUSFS 10 个开关
patches/
  susfs-for-sukisu-v4.3.0.patch   susfs4ksu → SukiSU 的胶水移植（来自已验证案例）
firmware/
  boot-template.bin           原厂 header(4096) + vbmeta(2368)，6.4KB
  boot-template.json          分区大小 / 页大小 / vbmeta 尺寸
tools/
  check-device.sh             连手机只读自检
  get-last-log.sh             抓上一次开机的 pstore
legacy/                       旧流水线（Kleaf + AK3），仅作参考
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

## 七、这一版的范围

**只做 root + SUSFS。** NoMount / Baseband Guard / NTSync / DroidSpaces / 各类网络增强
这一版没有做进去 —— 它们都要改 VFS、块设备或 net 层，是最容易"内核活着但 Android 起不来"的部分。
先让这台机器稳定跑起来，再按"一次只加一层"的方式往回加。

需要加的时候的顺序建议：`vanilla` → `sukisu` → 再加 SUSFS 以外的第一个补丁 → 逐个二分。

---

## 八、致谢

- [Android Common Kernel](https://android.googlesource.com/kernel/common) — GKI 源码
- [SukiSU-Ultra](https://github.com/SukiSU-Ultra/SukiSU-Ultra) — root
- [simonpunk/susfs4ksu](https://gitlab.com/simonpunk/susfs4ksu) — SUSFS
- [wjljh/xiaomi_kernel_for_warsaw_sukisu_susfs](https://github.com/wjljh/xiaomi_kernel_for_warsaw_sukisu_susfs) — 同机型的真机验证案例，boot.img 布局与 AVB 处理、SUSFS 移植补丁均出自这里
- [WildKernels/GKI_KernelSU_SUSFS](https://github.com/WildKernels/GKI_KernelSU_SUSFS) — 构建流程参考

脚本 GPL-2.0；内核与各补丁遵循其原始许可。
