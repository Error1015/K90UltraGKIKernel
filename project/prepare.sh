#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# 阶段 1：源码 + root + SUSFS + 附加功能 + 内核配置
#
# 设计取向：
#   * 构建系统：Kbuild（make），不用 Kleaf/Bazel
#   * 内核配置：直接使用原厂 .config（configs/warsaw_defconfig，从 boot.img 提取），
#     只在上面叠加 root / 功能 / 版本串
#   * 源码版本：钉到与手机同 sublevel 的 ACK 发布 tag（默认 6.6.118）
#   * root 默认 BakaSU，其余 4 个管理器同样支持，按需切换
# ---------------------------------------------------------------------------
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

MANIFEST_URL="${MANIFEST_URL:-https://android.googlesource.com/kernel/manifest}"
COMMON_URL="${COMMON_URL:-https://android.googlesource.com/kernel/common}"

# KERNEL_RELEASE / KERNEL_TAG / ANDROID_BRANCH / MANIFEST_BRANCH / LOCALVERSION /
# PAGE_SIZE / PARTITION_SIZE / SUSFS_BRANCH 全部来自 project/device.env（lib.sh 已 source），
# 这里不再做默认值回退 —— 那些值是要锁死的。

ROOT_IMPL="${ROOT_IMPL:-bakasu}"               # bakasu 为默认
ROOT_REF="${ROOT_REF:-}"                       # 留空 = 各仓库默认分支

SUSFS="${SUSFS:-true}"
SUSFS_REPO="${SUSFS_REPO:-https://gitlab.com/simonpunk/susfs4ksu.git}"
SUSFS_COMMIT="${SUSFS_COMMIT:-}"

NOMOUNT="${NOMOUNT:-false}"
# 留空 = 让 NoMount 的 setup.sh 自己选默认分支（dev，回退 master）
# 注意：maxsteeel/nomount 没有 main 分支，传 "main" 会 git checkout 失败
NOMOUNT_REF="${NOMOUNT_REF:-}"
BBG="${BBG:-false}"
NTSYNC="${NTSYNC:-false}"
NETWORKING="${NETWORKING:-false}"
BPF="${BPF:-false}"
DROIDSPACES="${DROIDSPACES:-false}"
UNICODE="${UNICODE:-false}"

KERNEL_PATCHES_REF="${KERNEL_PATCHES_REF:-main}"
KERNEL_PATCHES_REPO="${KERNEL_PATCHES_REPO:-https://github.com/WildKernels/kernel_patches.git}"

mkdir -p "$KROOT"

# ---------------------------------------------------------------------------
# 前置：repo launcher + git 身份
#
# 两个都属于"不装就一定挂"的东西：
#   1. GitHub runner 上没有 repo 这个命令，必须先下载 launcher，否则
#      `repo init` 直接 command not found（表现为"准备源码"步骤几秒就红）。
#   2. runner 上没有 git 身份，`repo init` 会交互式问 "is that correct [y/n]?"，
#      CI 里没人回答 → 一直等 → 看起来像卡住。
# ---------------------------------------------------------------------------
ensure_repo() {
  command -v repo >/dev/null 2>&1 && { info "repo: $(command -v repo)"; return 0; }

  local dest="$WS/.bin/repo"
  mkdir -p "$WS/.bin"
  for url in \
      "https://storage.googleapis.com/git-repo-downloads/repo" \
      "https://android.googlesource.com/tools/repo"; do
    if retry 3 curl -fsSL --retry 3 --retry-delay 3 "$url" -o "$dest" && [ -s "$dest" ]; then
      chmod +x "$dest"
      export PATH="$WS/.bin:$PATH"
      info "已安装 repo launcher（$url）"
      return 0
    fi
    warn "下载 repo 失败: $url"
  done
  die "拿不到 repo launcher，无法同步内核源码"
}

ensure_git_identity() {
  if [ -z "$(git config --global user.email 2>/dev/null || true)" ]; then
    git config --global user.email "k90-ci@localhost"
    git config --global user.name  "k90-ci"
    info "已设置 git 身份（避免 repo init 交互式确认）"
  fi
  # 任何需要输入的场景都直接失败，而不是挂在那里等
  export GIT_TERMINAL_PROMPT=0
  export GIT_ASKPASS=/bin/true
}

ensure_repo
ensure_git_identity

# ---------------------------------------------------------------------------
log "阶段 1/6：同步 ACK 源码（${MANIFEST_BRANCH}）"
# ---------------------------------------------------------------------------
cd "$KROOT"
if [ ! -d .repo ]; then
  INIT_OK=0
  for b in "$MANIFEST_BRANCH" "common-${ANDROID_BRANCH}"; do
    info "尝试 manifest 分支: $b"
    if retry 2 repo init -u "$MANIFEST_URL" -b "$b" --depth=1 < /dev/null; then
      INIT_OK=1
      MANIFEST_BRANCH="$b"
      break
    fi
  done
  [ "$INIT_OK" = "1" ] || die "repo init 失败（manifest 分支都不存在？）"
fi

# tag 直接取自 device.env，不再每次去 googlesource 列一遍远端 tag。
# 那一步既慢又容易限速，更麻烦的是会让"同一份仓库、不同时间跑"拉到不同源码。
TAG="$KERNEL_TAG"
[ -n "$TAG" ] || die "project/device.env 里 KERNEL_TAG 是空的"
case "$TAG" in
  *"$KERNEL_RELEASE"*) : ;;
  *) die "KERNEL_TAG($TAG) 与 KERNEL_RELEASE($KERNEL_RELEASE) 对不上，检查 project/device.env" ;;
esac
info "锁定 tag: $TAG"

if [ -n "$TAG" ]; then
  MANIFEST_FILE="$(find "$KROOT/.repo/manifests" -maxdepth 1 -name '*.xml' | head -1)"
  [ -n "$MANIFEST_FILE" ] || die "找不到 manifest 文件"
  python3 "$WS/project/pin_manifest.py" "$MANIFEST_FILE" "refs/tags/$TAG" \
    || die "钉 manifest 失败"
fi

log "repo sync（首次约 5~15 分钟；单次上限 ${SYNC_TIMEOUT:-1800} 秒）"
SYNC_ARGS=(-c --current-branch --no-tags -j"$(nproc)")

# 单次 sync 加超时：真卡住时宁可失败重试，也不要一路烧到 job 的 150 分钟上限
sync_once() {
  timeout "${SYNC_TIMEOUT:-1800}" repo sync "${SYNC_ARGS[@]}" < /dev/null
}

export GIT_CONFIG_COUNT=2
export GIT_CONFIG_KEY_0=http.lowSpeedLimit
export GIT_CONFIG_VALUE_0=1024
export GIT_CONFIG_KEY_1=http.lowSpeedTime
export GIT_CONFIG_VALUE_1=120

retry 2 sync_once || die "repo sync 失败（googlesource 限速时重跑即可）"
[ -f "$COMMON/Makefile" ] || die "同步后找不到 $COMMON/Makefile"

# ---------------------------------------------------------------------------
log "阶段 1a/6：确认 build/ 项目"
# ---------------------------------------------------------------------------
# 官方构建入口是 kernel/build 里的 build/build.sh：
#   LTO=thin BUILD_CONFIG=common/build.config.gki.aarch64 build/build.sh
# 但 common-android15-6.6-lts 这个 manifest 分支只保证 common + prebuilts，
# build 项目不一定跟着下来。缺了它就跑不了官方路径，所以这里兜底单拉一份。
BUILD_DIR="$KROOT/build"
if [ ! -f "$BUILD_DIR/build.sh" ]; then
  # 先按 manifest 里的定义同步 —— 它带的 revision 与 common 最匹配
  info "尝试按 manifest 定义同步 build 项目"
  if timeout 300 repo sync -c --current-branch --no-tags -j"$(nproc)" build < /dev/null > /dev/null 2>&1; then
    [ -f "$BUILD_DIR/build.sh" ] && info "build 项目已按 manifest 同步"
  fi
fi
if [ ! -f "$BUILD_DIR/build.sh" ]; then
  warn "缺少 $BUILD_DIR/build.sh，单独拉取 kernel/build"
  for br in "common-${ANDROID_BRANCH}" "${ANDROID_BRANCH}" "common-${MANIFEST_BRANCH#common-}" main; do
    rm -rf "$KROOT/build.tmp"
    info "尝试分支 $br"
    if retry 2 git clone --depth 1 -b "$br" \
         https://android.googlesource.com/kernel/build "$KROOT/build.tmp" < /dev/null; then
      rm -rf "$BUILD_DIR"
      mv "$KROOT/build.tmp" "$BUILD_DIR"
      info "kernel/build 已就绪（分支 $br）"
      break
    fi
    warn "分支 $br 拉取失败"
  done
  rm -rf "$KROOT/build.tmp"
fi
[ -f "$BUILD_DIR/build.sh" ] \
  || die "仍然没有 $BUILD_DIR/build.sh，无法使用官方 build/build.sh"
info "build.sh : $BUILD_DIR/build.sh"

# 官方 build.sh 除了 clang 还要这几样；缺了会在十几分钟后才报错，先看一眼
for p in prebuilts/clang/host/linux-x86 \
         prebuilts/build-tools/linux-x86/bin \
         prebuilts/gas/linux-x86; do
  if [ -e "$KROOT/$p" ]; then
    info "[prebuilts] $p ✓"
  else
    warn "[prebuilts] 缺 $p —— build.sh 可能中途失败"
  fi
done

# ---------------------------------------------------------------------------
# build.config.constants 里写死的 CLANG_VERSION 必须和实际拉到的 prebuilts 对得上。
# 兜底 clone 的若是 main 分支，它指向的 clang 版本可能比 prebuilts 里的新，
# build.sh 会直接找不到编译器。这里改成实际存在的那个。
# ---------------------------------------------------------------------------
CONST="$BUILD_DIR/build.config.constants"
CLANG_ROOT="$KROOT/prebuilts/clang/host/linux-x86"
if [ -f "$CONST" ]; then
  WANT_CC="$(sed -n 's/^CLANG_VERSION=//p' "$CONST" | head -1 | tr -d "\"[:space:]")"
  HAVE_CC="$(ls -1 "$CLANG_ROOT" 2>/dev/null | grep -E '^clang-r[0-9]+$' | sort -V | tail -1)"
  if [ -n "$WANT_CC" ] && [ -n "$HAVE_CC" ] && [ "$WANT_CC" != "$HAVE_CC" ]; then
    if [ -d "$CLANG_ROOT/$WANT_CC" ]; then
      info "clang: $WANT_CC（build.config 与 prebuilts 一致）"
    else
      warn "build.config 要 $WANT_CC，prebuilts 只有 $HAVE_CC —— 改用后者"
      sed -i "s|^CLANG_VERSION=.*|CLANG_VERSION=$HAVE_CC|" "$CONST"
    fi
  fi
fi

# ---------------------------------------------------------------------------
log "阶段 1b/6：切到原厂内核 commit"
# ---------------------------------------------------------------------------
# repo sync 拿到的只是 manifest 指向的 revision（我们钉的 tag）。
# 但原厂内核版本串里的 g<sha> 才是它真正编译用的那版代码。
# 两者不是一回事：tag 是「6.6.118 的第一次发布」，原厂可能用了之后的提交。
# 配置对齐了、代码没对齐，编出来的仍然不是同一个内核。
if [ -n "$KERNEL_COMMIT" ]; then
  info "目标 commit: $KERNEL_COMMIT（来自原厂版本串 $STOCK_VERSION）"

  if git -C "$COMMON" cat-file -e "${KERNEL_COMMIT}^{commit}" 2>/dev/null; then
    info "本地已有该 commit"
  else
    info "本地没有，按 sha 从远端补拉（--depth 1）"
    if retry 3 git -C "$COMMON" fetch --depth 1 origin "$KERNEL_COMMIT" < /dev/null; then
      info "补拉成功"
    else
      warn "按 sha 补拉失败（远端多半不允许按任意 sha fetch）"
      warn "退回 tag $KERNEL_TAG —— 本轮编出来的不是原厂那份代码"
      KERNEL_COMMIT=""
    fi
  fi

  if [ -n "$KERNEL_COMMIT" ]; then
    git -C "$COMMON" checkout -q --detach "$KERNEL_COMMIT" \
      || die "checkout $KERNEL_COMMIT 失败"
    GOT_SHA="$(git -C "$COMMON" rev-parse HEAD 2>/dev/null || echo unknown)"
    info "common HEAD = $GOT_SHA"
    # 记进 build-info，方便事后确认这一个包到底用的哪份源码
    echo "KERNEL_COMMIT=$GOT_SHA" >> "${GITHUB_ENV:-/dev/null}"
  fi
else
  warn "版本串里解析不到源码 commit，使用 tag $KERNEL_TAG"
fi

# ---------------------------------------------------------------------------
# 探测：这棵源码树认不认原厂的 GKI task_struct 布局
# ---------------------------------------------------------------------------
# 原厂内核里 CONFIG_GKI_TASK_STRUCT_VENDOR_SIZE_MAX=1024，厂商模块按这个
# 布局算 task_struct 偏移。这组符号只有在 init/Kconfig.gki 里存在时才可能生效；
# 不存在的树上，原厂 .config 里那几行会被 olddefconfig 静默丢掉。
# 这里只报告，不改变构建行为 —— 让 CI 日志能直接回答这个问题。
GKI_KCONFIG="$COMMON/init/Kconfig.gki"
if [ -f "$GKI_KCONFIG" ]; then
  if grep -q '^config GKI_DYNAMIC_TASK_STRUCT_SIZE' "$GKI_KCONFIG"; then
    info "[ABI] 源码树含 GKI_DYNAMIC_TASK_STRUCT_SIZE（原厂 task_struct 布局可复刻）"
  else
    warn "[ABI] 源码树不含 GKI_DYNAMIC_TASK_STRUCT_SIZE"
    warn "[ABI] 原厂 CONFIG_GKI_TASK_STRUCT_VENDOR_SIZE_MAX=1024 在这棵树上无法生效"
  fi
fi
if [ -f "$COMMON/arch/Kconfig" ] && ! grep -q '^config ARCH_WANTS_DYNAMIC_TASK_STRUCT' "$COMMON/arch/Kconfig"; then
  warn "[ABI] arch/Kconfig 里也没有 ARCH_WANTS_DYNAMIC_TASK_STRUCT"
fi

# ---------------------------------------------------------------------------
log "阶段 2/6：校验源码版本"
# ---------------------------------------------------------------------------
WANT_SUB="${KERNEL_RELEASE##*.}"
GOT_SUB="$(sed -n 's/^SUBLEVEL *= *//p' "$COMMON/Makefile" | head -1 | tr -d '[:space:]')"
info "源码 SUBLEVEL = $GOT_SUB（期望 $WANT_SUB）"
if [ -n "$WANT_SUB" ] && [ "$GOT_SUB" != "$WANT_SUB" ]; then
  die "源码版本与手机不一致：期望 6.6.$WANT_SUB，实际 6.6.$GOT_SUB。
    KMI 冻结的是符号 CRC，跨 sublevel 可能让 vendor 模块全部加载失败。
    确实要换版本就去改 project/device.env 里的 KERNEL_RELEASE / KERNEL_TAG。"
fi

# ---------------------------------------------------------------------------
log "阶段 3/6：集成 root（$ROOT_IMPL）"
# ---------------------------------------------------------------------------
ROOT_DIR=""
ROOT_MANAGER_NAME="N/A"
if [ "$ROOT_IMPL" != "none" ]; then
  case "$ROOT_IMPL" in
    bakasu)
      ROOT_REPO="https://github.com/Baka-SU/BakaSU.git";             ROOT_DIR="BakaSU"
      ROOT_BRANCH="main";        ROOT_MANAGER_NAME="BakaSU Manager" ;;
    sukisu-ultra)
      ROOT_REPO="https://github.com/SukiSU-Ultra/SukiSU-Ultra.git";  ROOT_DIR="SukiSU-Ultra"
      ROOT_BRANCH="v4.3.0";      ROOT_MANAGER_NAME="SukiSU-Ultra Manager" ;;
    kernelsu)
      ROOT_REPO="https://github.com/tiann/KernelSU.git";             ROOT_DIR="KernelSU"
      ROOT_BRANCH="main";        ROOT_MANAGER_NAME="KernelSU Manager" ;;
    kernelsu-next)
      ROOT_REPO="https://github.com/KernelSU-Next/KernelSU-Next.git"; ROOT_DIR="KernelSU-Next"
      ROOT_BRANCH="dev";         ROOT_MANAGER_NAME="KernelSU Next Manager" ;;
    kowsu)
      ROOT_REPO="https://github.com/KOWX712/KernelSU.git";           ROOT_DIR="KowSU"
      ROOT_BRANCH="master";      ROOT_MANAGER_NAME="KowSU Manager" ;;
    *) die "不支持的 root: $ROOT_IMPL" ;;
  esac

  # KowSU 与 SUSFS 不兼容：不硬失败，自动关掉并留下明显记录，
  # 免得一次误勾把整份构建拖死（build.sh 会按 GITHUB_ENV 里的最终值校验）
  if is_true "$SUSFS" && [ "$ROOT_IMPL" = "kowsu" ]; then
    warn "KowSU 与 SUSFS 不兼容，已自动关闭 SUSFS"
    SUSFS=false
    echo "SUSFS=false" >> "${GITHUB_ENV:-/dev/null}"
  fi

  REF="${ROOT_REF:-$ROOT_BRANCH}"
  ROOT_SRC="$WS/$ROOT_DIR"
  rm -rf "$ROOT_SRC"
  retry 3 git clone --depth 1 -b "$REF" "$ROOT_REPO" "$ROOT_SRC" \
    || die "clone $ROOT_DIR（ref=$REF）失败"
  [ -d "$ROOT_SRC/kernel" ] || die "$ROOT_DIR 里没有 kernel/，仓库结构变了？"
  ROOT_COMMIT="$(git -C "$ROOT_SRC" rev-parse HEAD)"
  info "$ROOT_DIR @ ${ROOT_COMMIT:0:12}"

  # 官方约定的接入方式：软链到 drivers/kernelsu，再挂 Kbuild / Kconfig
  rm -rf "$COMMON/drivers/kernelsu"
  ln -sfn "$ROOT_SRC/kernel" "$COMMON/drivers/kernelsu"
  grep -qF 'obj-$(CONFIG_KSU) += kernelsu/' "$COMMON/drivers/Makefile" \
    || printf '\nobj-$(CONFIG_KSU) += kernelsu/\n' >> "$COMMON/drivers/Makefile"

  python3 - "$COMMON/drivers/Kconfig" <<'PY'
import sys
path = sys.argv[1]
src = 'source "drivers/kernelsu/Kconfig"\n'
with open(path, encoding="utf-8") as fh:
    text = fh.read()
if "drivers/kernelsu/Kconfig" not in text:
    idx = text.rfind("endmenu")
    text = (text[:idx] + src + text[idx:]) if idx >= 0 else (text + src)
    with open(path, "w", encoding="utf-8", newline="") as fh:
        fh.write(text)
    print("    drivers/Kconfig += source kernelsu/Kconfig")
PY

  # --- 各管理器已知的上游坑，逐个打平 ---
  case "$ROOT_IMPL" in
    kernelsu-next)
      # Kbuild 在 mrproper（还没有 .config）阶段就 $(error)，会直接终止清理/配置
      KB="$ROOT_SRC/kernel/Kbuild"
      if [ -f "$KB" ] && grep -q 'KernelSU requires either CONFIG_KPROBES' "$KB"; then
        sed -i 's/\$(error "KernelSU requires either CONFIG_KPROBES=y or CONFIG_KSU_SUSFS=y")/$(warning "KernelSU requires either CONFIG_KPROBES=y or CONFIG_KSU_SUSFS=y")/' "$KB"
        info "Next: Kbuild 配置检查已降级为 warning"
      fi
      ;;
    bakasu)
      # 1) 子模块检查：从外部 clone 会被判定"应该用 git submodule"，直接 error
      KB="$ROOT_SRC/kernel/Kbuild"
      if [ -f "$KB" ] && grep -q 'as a git submodule instead of copying code directly' "$KB"; then
        sed -i 's/\$(error You should use \$(REPO_NAME) as a git submodule instead of copying code directly)/$(warning You should use $(REPO_NAME) as a git submodule instead of copying code directly)/' "$KB"
        info "BakaSU: 子模块检查已降级为 warning"
      fi
      # 2) susfs_compat.mk：SUSFS 版本对不上时它会让构建直接停掉
      COMPAT="$ROOT_SRC/kernel/tools/susfs_compat.mk"
      if [ -f "$COMPAT" ] && grep -q 'Please wait susfs update' "$COMPAT"; then
        sed -i '/susfs has NOT update with latest KernelSU source/,$d' "$COMPAT"
        info "BakaSU: 已移除 susfs_compat 的强制中断"
      fi
      ;;
  esac

  {
    echo "ROOT_DIR=${ROOT_DIR}"
    echo "ROOT_COMMIT=${ROOT_COMMIT}"
    echo "ROOT_MANAGER_NAME=${ROOT_MANAGER_NAME}"
  } >> "${GITHUB_ENV:-/dev/null}"
fi

# ---------------------------------------------------------------------------
log "阶段 4/6：补丁（SUSFS + 附加功能）"
# ---------------------------------------------------------------------------
if is_true "$SUSFS"; then
  [ "$ROOT_IMPL" != "none" ] || die "SUSFS 需要 root，不能是 none"

  log "SUSFS（$SUSFS_BRANCH）"
  SUSFS_SRC="$WS/susfs4ksu"
  rm -rf "$SUSFS_SRC"
  retry 3 git clone --depth 1 -b "$SUSFS_BRANCH" "$SUSFS_REPO" "$SUSFS_SRC" \
    || die "clone susfs4ksu 失败"
  if [ -n "$SUSFS_COMMIT" ]; then
    retry 3 git -C "$SUSFS_SRC" fetch --depth=1 origin "$SUSFS_COMMIT"
    git -C "$SUSFS_SRC" checkout --detach "$SUSFS_COMMIT"
  fi
  info "SUSFS @ $(git -C "$SUSFS_SRC" rev-parse --short HEAD)"
  echo "SUSFS_COMMIT=$(git -C "$SUSFS_SRC" rev-parse HEAD)" >> "${GITHUB_ENV:-/dev/null}"

  SP="$SUSFS_SRC/kernel_patches"
  # 新版 susfs4ksu 把 fs/susfs.c 与 include/linux/susfs*.h 单独放在补丁目录里拷；
  # 老版本这三个文件是补丁内的新增文件 —— 两种布局都兼容
  if [ -d "$SP/fs" ]; then
    cp "$SP/fs/"* "$COMMON/fs/"
    info "已拷入 fs/susfs.c"
  fi
  if [ -d "$SP/include/linux" ]; then
    cp "$SP/include/linux/"* "$COMMON/include/linux/"
    info "已拷入 include/linux/susfs*.h"
  fi

  MAIN_PATCH="$SP/50_add_susfs_in_${SUSFS_BRANCH}.patch"
  if [ ! -f "$MAIN_PATCH" ]; then
    MAIN_PATCH="$(find "$SP" -maxdepth 1 -name '50_add_susfs_in_*6.6*.patch' | head -1)"
  fi
  [ -n "$MAIN_PATCH" ] && [ -f "$MAIN_PATCH" ] || die "找不到 SUSFS 内核侧补丁（$SP）"
  apply_patch "$COMMON" "$MAIN_PATCH" "SUSFS 内核侧 (${SUSFS_BRANCH})"

  # 6.6 上的固定编译坑（补 include / VMA_PAD_START / fanotify 回调签名），幂等
  python3 "$WS/project/susfs_66_compat.py" "$COMMON" "$GOT_SUB"

  # root 侧的 SUSFS 胶水：先探测仓库自带的 Kconfig 有没有 KSU_SUSFS
  if grep -rqE '^[[:space:]]*config KSU_SUSFS[[:space:]]*$' "$ROOT_SRC/kernel" 2>/dev/null; then
    info "$ROOT_DIR 自带 SUSFS 胶水（Kconfig 有 KSU_SUSFS），无需额外补丁"
  else
    case "$ROOT_IMPL" in
      kernelsu)
        ENABLE_PATCH="$SP/KernelSU/10_enable_susfs_for_ksu.patch"
        [ -f "$ENABLE_PATCH" ] || die "缺少 $ENABLE_PATCH"
        apply_patch "$ROOT_SRC" "$ENABLE_PATCH" "KernelSU SUSFS 使能"
        ;;
      sukisu-ultra)
        # 上游补丁是给 tiann KernelSU 写的，直接套会引入大量重构；
        # 用已验证的移植补丁（只保留 SUSFS 相关 hunk）
        apply_patch "$ROOT_SRC" "$WS/patches/susfs-for-sukisu-v4.3.0.patch" \
          "SUSFS -> SukiSU 胶水"
        ;;
      *)
        die "$ROOT_DIR 既没有自带 KSU_SUSFS，也没有对应的胶水补丁；请把 susfs 关掉再构建"
        ;;
    esac
  fi
fi

# --- 通用补丁集（按需 clone）---
KP="$WS/kernel_patches"
fetch_kernel_patches() {
  [ -d "$KP" ] && return 0
  log "同步通用补丁集（WildKernels/kernel_patches）"
  retry 3 git clone --depth 1 -b "$KERNEL_PATCHES_REF" "$KERNEL_PATCHES_REPO" "$KP" \
    || die "clone kernel_patches 失败"
}

if is_true "$NTSYNC"; then
  log "附加功能：NTSync"
  fetch_kernel_patches
  apply_patch "$COMMON" "$KP/common/ntsync/ntsync_compat_android15-6.6.patch" "NTSync 兼容层"
  apply_patch "$COMMON" "$KP/common/ntsync/ntsync_base.patch" "NTSync 主体"
fi

if is_true "$NETWORKING"; then
  log "附加功能：BBRv3"
  fetch_kernel_patches
  if apply_patch_optional "$COMMON" \
       "$KP/common/bbrv3/0001-net-tcp-backport-BBRv3-to-android15-6.6.patch" "BBRv3 回移"; then
    echo "BBRV3_APPLIED=true" >> "${GITHUB_ENV:-/dev/null}"
  else
    warn "BBRv3 补丁不适用，回退到内核自带 BBR（功能不受影响，只是算法版本不同）"
    echo "BBRV3_APPLIED=false" >> "${GITHUB_ENV:-/dev/null}"
    # "bbr" 这个算法本身出厂就有（CONFIG_TCP_CONG_BBR=y），回退时不用改默认拥塞控制，
    # 也绝对不要去改仓库里的配置文件 —— 那会让工作区变脏、结果不可复现。
  fi
fi

if is_true "$UNICODE"; then
  log "附加功能：Unicode 绕过修复"
  fetch_kernel_patches
  apply_patch_optional "$COMMON" "$KP/common/unicode_bypass_fix_6.1+.patch" "Unicode bypass fix" || true
fi

if is_true "$DROIDSPACES"; then
  log "附加功能：DroidSpaces-OSS"
  rm -rf "$WS/Droidspaces-OSS"
  retry 3 git clone --depth 1 https://github.com/ravindu644/Droidspaces-OSS.git \
    "$WS/Droidspaces-OSS" || die "clone Droidspaces-OSS 失败"
  KABI="$WS/Droidspaces-OSS/Documentation/resources/kernel-patches/GKI/below-kernel-6.12/001.GKI-below-6.12-fix_sysvipc_kabi_6_7_8.patch"
  [ -f "$KABI" ] || die "找不到 DroidSpaces SYSVIPC kABI 补丁（上游目录结构变了？）"
  apply_patch "$COMMON" "$KABI" "DroidSpaces SYSVIPC kABI"
fi

if is_true "$NOMOUNT"; then
  log "附加功能：NoMount"
  # setup.sh 的第一个参数是 tag/commit（不是分支名）。不传时它自己 checkout dev。
  # 这个仓库没有 main 分支 —— 传 main 会得到 "pathspec 'main' did not match"。
  NOMOUNT_BASE="https://raw.githubusercontent.com/maxsteeel/nomount"
  if [ -n "${NOMOUNT_REF:-}" ]; then
    run_remote_setup "$NOMOUNT_BASE/${NOMOUNT_REF}/kernel/setup.sh" "$COMMON" "$NOMOUNT_REF"
  else
    run_remote_setup "$NOMOUNT_BASE/dev/kernel/setup.sh" "$COMMON"
  fi
  [ -e "$COMMON/fs/nomount" ] || die "NoMount 装完没看到 fs/nomount 软链"
  [ -f "$COMMON/fs/nomount/Kconfig" ] || die "NoMount 装完找不到 fs/nomount/Kconfig（Kconfig 没挂上）"
  # 它会把整个仓库 clone 进内核树，别让收尾的 git add -A 把它卷进提交
  mkdir -p "$COMMON/.git/info"
  grep -qxF 'NoMount' "$COMMON/.git/info/exclude" 2>/dev/null \
    || echo 'NoMount' >> "$COMMON/.git/info/exclude"
fi

if is_true "$BBG"; then
  log "附加功能：Baseband Guard"
  run_remote_setup "https://raw.githubusercontent.com/vc-teahouse/Baseband-guard/main/setup.sh" "$KROOT"
  [ -d "$COMMON/security/baseband-guard" ] || die "BBG 安装后找不到 security/baseband-guard"
  # 注意：LSM 顺序不能在这里改 security/Kconfig。
  # 厂配 .config 里 CONFIG_LSM 是显式字符串，Kconfig 的 default 根本不参与推导，
  # 改了也不生效（BBG 的 Makefile 会直接 Stop）。真正的修改在"阶段 5：写内核配置"。
fi

# ---------------------------------------------------------------------------
log "阶段 5/6：写内核配置"
# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
# 基础配置来源（CONFIG_SOURCE）：
#   oem —— 原厂 boot.img 内嵌的 .config（configs/warsaw_defconfig），**默认**
#   gki —— ACK 自带的 arch/arm64/configs/gki_defconfig（退路）
#
# 历史：oem 配置在「裸 make」路径下编出来的内核刷进去卡 logo（run24/25 实测），
# 一度把默认改成 gki。但那条结论只证明了「oem 配置 + 裸 make」不行 ——
# Error1015 那份实测能启动的内核同样是这个 KMI，而它走的是官方
# `build/build.sh`（LTO=thin + build.config.gki.aarch64），不是裸 make。
# 裸 make 少了 build.config 那一层预处理，产物形态和官方不一致。
# 现在构建已切到官方路径（BUILD_ENGINE=script），oem 配置值得重新验一次 ——
# 这是唯一能拿到「原厂行为 + 内嵌 root」的组合。
# ---------------------------------------------------------------------------
CONFIG_SOURCE="${CONFIG_SOURCE:-oem}"
if [ "$CONFIG_SOURCE" = "oem" ]; then
  cp "$WS/configs/warsaw_defconfig" "$OUT/.config"
  info "基础配置：原厂 .config（取自 boot.img 内嵌 IKCONFIG）"
else
  GKIDEF="$COMMON/arch/arm64/configs/gki_defconfig"
  [ -f "$GKIDEF" ] || die "找不到 gki_defconfig: $GKIDEF"
  cp "$GKIDEF" "$OUT/.config"
  info "基础配置：gki_defconfig（$GKIDEF）"
  echo "CONFIG_SOURCE=gki" >> "${GITHUB_ENV:-/dev/null}"
fi

apply_fragment "$WS/configs/base.fragment"
set_cfg LOCALVERSION "$LOCALVERSION"

if [ "$ROOT_IMPL" != "none" ]; then
  apply_fragment "$WS/configs/root/$ROOT_IMPL.fragment"
fi

if is_true "$SUSFS";       then info "--- SUSFS ---";       apply_fragment "$WS/configs/features/susfs.fragment"; fi
if is_true "$NTSYNC";      then info "--- NTSync ---";      apply_fragment "$WS/configs/features/ntsync.fragment"; fi
if is_true "$NETWORKING";  then info "--- Networking ---";  apply_fragment "$WS/configs/features/networking.fragment"; fi
if is_true "$NOMOUNT";     then info "--- NoMount ---";     apply_fragment "$WS/configs/features/nomount.fragment"; fi
if is_true "$BBG";         then info "--- BBG ---";         apply_fragment "$WS/configs/features/bbg.fragment"; fi
if is_true "$DROIDSPACES"; then info "--- DroidSpaces ---"; apply_fragment "$WS/configs/features/droidspaces.fragment"; fi
if is_true "$BPF";         then info "--- BTF/eBPF ---";    apply_fragment "$WS/configs/features/bpf.fragment"; fi

# ---------------------------------------------------------------------------
# CONFIG_MODULE_SIG_PROTECT：Android GKI 的模块保护。
#
# 它允许「用本次构建的签名密钥签出来的模块」随便用符号；其它模块（含厂商签名的
# vendor_dlkm / vendor_boot 模块）只有在**不碰** android/abi_gki_protected_exports
# 里的符号时才放行。
#
# 我们的签名密钥是构建时现生成的（certs/signing_key.pem 不存在就会自动造一把），
# 和厂商那把毫无关系。一旦厂商模块用到受保护导出，内核会拒绝加载 ——
# 显示 / 存储这类早期模块一挂，表现就是内核起来了、画面停在开机 logo。
#
# 默认保持原厂的 y；诊断分支可以关掉（关掉后签名仍然校验，只是不强制）。
# ---------------------------------------------------------------------------
if ! is_true "${SIGPROTECT:-true}"; then
  warn "CONFIG_MODULE_SIG_PROTECT=n（诊断模式：放行非本次密钥签名的厂商模块）"
  set_cfg MODULE_SIG_PROTECT n
fi

# ---------------------------------------------------------------------------
# BBG 的 Makefile 在编译期硬校验：CONFIG_BBG=y 时 CONFIG_LSM 里必须有 baseband_guard，
# 否则直接 $(error) "Please follow Baseband-guard's README.md" 然后 Stop。
# 而厂配 .config 里 CONFIG_LSM 是显式字符串（不是 Kconfig 的 default），
# 改 security/Kconfig 完全不参与推导 —— 只能在 .config 里改。
# ---------------------------------------------------------------------------
if is_true "$BBG"; then
  LSM_OLD="$(sed -n 's/^CONFIG_LSM="\(.*\)"$/\1/p' "$OUT/.config" | head -1)"
  if printf ',%s,' "$LSM_OLD" | grep -q ',baseband_guard,'; then
    info "CONFIG_LSM 已含 baseband_guard：$LSM_OLD"
  else
    # 排在 selinux 之后：BBG 需要 selinux 侧的 cred/state，放在它后面最稳
    if [ -z "$LSM_OLD" ]; then
      warn "CONFIG_LSM 是空的，用完整默认顺序兜底"
      LSM_NEW="landlock,lockdown,yama,loadpin,safesetid,selinux,baseband_guard,smack,tomoyo,apparmor,bpf"
    else
      LSM_NEW="$(printf '%s' "$LSM_OLD" \
        | sed 's/\(^\|,\)selinux\(,\|$\)/\1selinux,baseband_guard\2/')"
      if [ "$LSM_NEW" = "$LSM_OLD" ]; then
        LSM_NEW="$LSM_OLD,baseband_guard"
      fi
    fi
    set_cfg LSM "$LSM_NEW"
    info "CONFIG_LSM += baseband_guard"
  fi
fi

# ---------------------------------------------------------------------------
log "阶段 6/6：准备构建环境"
# ---------------------------------------------------------------------------
CLANG_DIR="$(find "$KROOT/prebuilts/clang/host/linux-x86" -maxdepth 1 -type d -name 'clang-r*' \
             | sort -V | tail -1)"
[ -n "$CLANG_DIR" ] || die "找不到 prebuilts/clang（repo sync 不完整？）"
BUILD_TOOLS="$KROOT/prebuilts/build-tools/linux-x86/bin"
[ -d "$BUILD_TOOLS" ] || die "找不到 prebuilts/build-tools"

{
  echo "CLANG_DIR=$CLANG_DIR"
  echo "BUILD_TOOLS=$BUILD_TOOLS"
} >> "${GITHUB_ENV:-/dev/null}"

export PATH="$CLANG_DIR/bin:$BUILD_TOOLS:$PATH"
info "clang  : $CLANG_DIR ($("$CLANG_DIR/bin/clang" --version | head -1))"
if command -v pahole >/dev/null 2>&1; then
  info "pahole : $(pahole --version 2>/dev/null || echo 未知)"
else
  warn "PATH 里没有 pahole（DEBUG_INFO_BTF=y 需要它）"
fi

# 让版本号保持干净：工作区有未提交改动时 setlocalversion 可能追加标记
if git -C "$COMMON" rev-parse --git-dir >/dev/null 2>&1; then
  ( cd "$COMMON" \
    && git add -A >/dev/null 2>&1 \
    && git -c user.name="k90-ci" -c user.email="k90-ci@localhost" \
         commit -q -m "ci: apply kernel patches and config" >/dev/null 2>&1 ) || true
fi

log "准备完成"
info "root     : ${ROOT_IMPL}${ROOT_COMMIT:+ @ ${ROOT_COMMIT:0:12}}"
info "SUSFS    : ${SUSFS}"
info "功能     : ntsync=${NTSYNC} networking=${NETWORKING} nomount=${NOMOUNT} bbg=${BBG} droidspaces=${DROIDSPACES} bpf=${BPF} unicode=${UNICODE}"
info "源码     : $COMMON"
info "配置     : $OUT/.config"
