#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# 准备阶段：同步 GKI 源码 → 集成 Root 管理器 → SUSFS → 各功能补丁 → 内核配置
# 环境变量由 .github/workflows/build.yml 注入
# ---------------------------------------------------------------------------
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
source "$SCRIPT_DIR/lib.sh"

# ---------------------------------------------------------------------------
# 参数与默认值
# ---------------------------------------------------------------------------
ROOT_MANAGER="${ROOT_MANAGER:-kernelsu-next}"
ROOT_REF="${ROOT_REF:-}"

MANIFEST_URL="${MANIFEST_URL:-https://android.googlesource.com/kernel/manifest}"
COMMON_URL="${COMMON_URL:-https://android.googlesource.com/kernel/common}"
MANIFEST_BRANCH="${MANIFEST_BRANCH:-common-android15-6.6-lts}"
KERNEL_TAG="${KERNEL_TAG:-}"
STOCK_KERNEL_VERSION="${STOCK_KERNEL_VERSION:-}"

SUSFS_REPO="${SUSFS_REPO:-https://gitlab.com/simonpunk/susfs4ksu.git}"
SUSFS_BRANCH="${SUSFS_BRANCH:-gki-android15-6.6}"
SUSFS_COMMIT="${SUSFS_COMMIT:-}"

KERNEL_PATCHES_REPO="${KERNEL_PATCHES_REPO:-https://github.com/WildKernels/kernel_patches.git}"
KERNEL_PATCHES_REF="${KERNEL_PATCHES_REF:-main}"

NOMOUNT_REPO_RAW="${NOMOUNT_REPO_RAW:-https://raw.githubusercontent.com/maxsteeel/nomount}"
NOMOUNT_REF="${NOMOUNT_REF:-dev}"

BBG_SETUP_URL="${BBG_SETUP_URL:-https://raw.githubusercontent.com/vc-teahouse/Baseband-guard/main/setup.sh}"

DROIDSPACES_REPO="${DROIDSPACES_REPO:-https://github.com/ravindu644/Droidspaces-OSS.git}"
DROIDSPACES_REF="${DROIDSPACES_REF:-}"

ALLOW_PATCH_FUZZ="${ALLOW_PATCH_FUZZ:-true}"
PRESET="${PRESET:-full}"

SUSFS_ON="${SUSFS:-false}"
NOMOUNT_ON="${NOMOUNT:-false}"
BBG_ON="${BBG:-false}"
DROIDSPACES_ON="${DROIDSPACES:-false}"
NETWORKING_ON="${NETWORKING:-false}"
NTSYNC_ON="${NTSYNC:-false}"
PTRACE_ON="${PTRACE_FIX:-false}"
UNICODE_ON="${UNICODE_FIX:-false}"
BPF_ON="${BPF:-false}"

export ALLOW_PATCH_FUZZ

# ---------------------------------------------------------------------------
# 预设：把"高风险补丁组合"收口，避免一次引入太多变量导致卡标难以定位
#   safe    —— 只保留 root + SUSFS（社区验证最充分的组合），其余强制关闭
#   full    —— 完全按开关走（workflow 默认）
#   vanilla —— 不集成 root、不加任何补丁，用来单独验证"基础 GKI 内核能不能启动"
# ---------------------------------------------------------------------------
resolve_preset() {
  case "$PRESET" in
    vanilla)
      warn "preset=vanilla：不集成 root 与任何功能补丁，用于验证基础 GKI 内核"
      ROOT_MANAGER="none"
      SUSFS_ON=false; NOMOUNT_ON=false; BBG_ON=false; DROIDSPACES_ON=false
      NETWORKING_ON=false; NTSYNC_ON=false; PTRACE_ON=false; UNICODE_ON=false; BPF_ON=false
      ;;
    safe)
      info "preset=safe：保留 root + SUSFS，其余功能补丁强制关闭"
      NOMOUNT_ON=false; BBG_ON=false; DROIDSPACES_ON=false
      NETWORKING_ON=false; NTSYNC_ON=false; PTRACE_ON=false; UNICODE_ON=false; BPF_ON=false
      ;;
    full)
      info "preset=full：按开关全量构建"
      ;;
    *)
      die "未知 preset: $PRESET（可选 safe / full / vanilla）"
      ;;
  esac
}

summary() {
  log "构建选项"
  info "预设          : ${PRESET}"
  info "目标设备      : Redmi K90 Ultra (warsaw / SM8750, ${ANDROID_VERSION}-${KERNEL_VERSION})"
  info "Root 管理器   : ${ROOT_MANAGER}${ROOT_REF:+ (ref: $ROOT_REF)}"
  info "SUSFS         : ${SUSFS_ON} (branch: ${SUSFS_BRANCH})"
  info "NoMount       : ${NOMOUNT_ON} (ref: ${NOMOUNT_REF})"
  info "Baseband Guard: ${BBG_ON}"
  info "DroidSpaces   : ${DROIDSPACES_ON}"
  info "Networking    : ${NETWORKING_ON}"
  info "NTSync        : ${NTSYNC_ON}"
  info "Ptrace Fix    : ${PTRACE_ON}"
  info "Unicode Fix   : ${UNICODE_ON}"
  info "BTF/eBPF/FUSE : ${BPF_ON}"
  info "源码分支      : ${MANIFEST_BRANCH}${KERNEL_TAG:+ @ $KERNEL_TAG}"
  info "页大小        : ${PAGE_SIZE:-4k}"
}

# ---------------------------------------------------------------------------
# 1. 同步 GKI 源码（repo + Kleaf 布局）
# ---------------------------------------------------------------------------
sync_kernel() {
  log "同步 GKI 内核源码: ${MANIFEST_BRANCH}"
  mkdir -p "$KROOT"
  cd "$KROOT"

  export GIT_CONFIG_COUNT=2
  export GIT_CONFIG_KEY_0=http.lowSpeedLimit
  export GIT_CONFIG_VALUE_0=1024
  export GIT_CONFIG_KEY_1=http.lowSpeedTime
  export GIT_CONFIG_VALUE_1=60

  if [ ! -d .repo ]; then
    if ! retry 2 repo init -u "$MANIFEST_URL" -b "$MANIFEST_BRANCH" --depth=1; then
      warn "清单分支 ${MANIFEST_BRANCH} 初始化失败，回退到 common-${ANDROID_VERSION}-${KERNEL_VERSION}"
      rm -rf .repo
      retry 2 repo init -u "$MANIFEST_URL" -b "common-${ANDROID_VERSION}-${KERNEL_VERSION}" --depth=1
    fi
  else
    info "已存在 .repo，复用本地清单"
  fi

  local sync_tags="--no-tags"
  if [ -n "$KERNEL_TAG" ]; then
    # 精确锁定到不可变 tag：把 default.xml 里 common 的 revision 换成 tag 全名，
    # 因为 repo 默认把 revision 当分支名解析（dated 清单里的 android15-6.6-2024-12
    # 在 kernel/common 里只有 tag、没有同名分支，直接 fetch 分支会报
    # "couldn't find remote ref refs/heads/..."）。
    local manifest=".repo/manifests/default.xml"
    [ -f "$manifest" ] || die "找不到 $manifest"

    if ! git ls-remote --tags --exit-code "$COMMON_URL" "refs/tags/${KERNEL_TAG}" > /dev/null 2>&1; then
      warn "kernel/common 中不存在 tag: ${KERNEL_TAG}"
      echo "  可用的 6.6 相关 tag（最近的 15 个，挑一个填到 kernel_tag）："
      git ls-remote --tags "$COMMON_URL" 2>/dev/null \
        | awk '{print $2}' | sed 's|^refs/tags/||' | grep -v '\^{}' \
        | grep -E '^android15-6\.6-202[456]' | sort -V | tail -15 | sed 's/^/    /'
      die "请把 kernel_tag 改成上面列出的某个 tag，或留空用清单分支默认版本"
    fi

    sed -i "/path=\"common\"/ s|revision=\"[^\"]*\"|revision=\"refs/tags/${KERNEL_TAG}\"|" "$manifest"
    grep -q "refs/tags/${KERNEL_TAG}" "$manifest" || die "清单中未找到 path=\"common\"，无法锁定 tag"
    info "已把 common 锁定到 tag: ${KERNEL_TAG}"
    sync_tags=""
  fi

  retry 3 repo sync -c --current-branch --no-clone-bundle $sync_tags \
    -j"$(nproc)" --jobs-checkout="$(nproc)"

  [ -d "$COMMON" ] || die "同步完成但找不到 $COMMON"
  [ -f "$COMMON/Makefile" ] || die "$COMMON 不是内核源码树"

  local ver
  ver="$(awk '/^VERSION =/{v=$3} /^PATCHLEVEL =/{p=$3} /^SUBLEVEL =/{s=$3} END{printf "%s.%s.%s", v, p, s}' "$COMMON/Makefile")"
  log "内核源码版本: ${ver}"
  SOURCE_KERNEL_VERSION="$ver"
  SOURCE_KERNEL_VERSION_MM="$(printf '%s' "$ver" | cut -d. -f1,2)"
  export SOURCE_KERNEL_VERSION SOURCE_KERNEL_VERSION_MM
  echo "SOURCE_KERNEL_VERSION=${ver}" >> "${GITHUB_ENV:-/dev/null}"
  echo "$ver" > "$OUT/source-kernel-version.txt"
}

# ---------------------------------------------------------------------------
# 2. 可选：把源码版本号伪装成整机版本，保证 vendor 模块 vermagic 匹配
# ---------------------------------------------------------------------------
pin_kernel_version() {
  [ -n "$STOCK_KERNEL_VERSION" ] || return 0
  log "版本对齐: 把内核版本改为 ${STOCK_KERNEL_VERSION}"
  warn "这是一种 hack：只有当厂商 vendor_dlkm 模块因 vermagic 不匹配而拒绝加载时才需要。"
  python3 "$SCRIPT_DIR/py/version_pin.py" "$COMMON/Makefile" "$STOCK_KERNEL_VERSION"
}

# ---------------------------------------------------------------------------
# 3. 集成 Root 管理器
# ---------------------------------------------------------------------------
setup_root() {
  if [ "$ROOT_MANAGER" = "none" ]; then
    log "不集成任何 Root 管理器"
    return 0
  fi

  local repo dir default_branch manager
  case "$ROOT_MANAGER" in
    kernelsu)
      repo="https://github.com/tiann/KernelSU.git"; dir="KernelSU"
      default_branch="main"; manager="KernelSU Manager" ;;
    kernelsu-next)
      repo="https://github.com/KernelSU-Next/KernelSU-Next.git"; dir="KernelSU-Next"
      default_branch="dev"; manager="KernelSU Next Manager" ;;
    bakasu)
      repo="https://github.com/Baka-SU/BakaSU.git"; dir="BakaSU"
      default_branch="main"; manager="BakaSU Manager" ;;
    sukisu-ultra)
      repo="https://github.com/SukiSU-Ultra/SukiSU-Ultra.git"; dir="SukiSU-Ultra"
      default_branch="main"; manager="SukiSU-Ultra Manager" ;;
    kowsu)
      repo="https://github.com/KOWX712/KernelSU.git"; dir="KowSU"
      default_branch="master"; manager="KowSU Manager" ;;
    *)
      die "不支持的 Root 管理器: $ROOT_MANAGER" ;;
  esac

  if is_true "$SUSFS_ON" && [ "$ROOT_MANAGER" = "kowsu" ]; then
    die "KowSU 与 SUSFS 不兼容（workflow 选 root_manager=all 时会自动为 kowsu 关掉 SUSFS）：请关闭 SUSFS 或换一个 Root 管理器"
  fi

  log "克隆 Root 管理器: ${ROOT_MANAGER}"
  local ref="${ROOT_REF:-$default_branch}"
  # 只允许一个 Root 集成，避免上次的残留互相污染
  local existing
  for existing in KernelSU KernelSU-Next BakaSU SukiSU-Ultra KowSU; do
    if [ "$existing" != "$dir" ] && [ -e "$KROOT/$existing" ]; then
      die "发现残留的 $existing，请清理后重试（一次只能集成一个 Root 管理器）"
    fi
  done
  rm -rf "$KROOT/$dir"
  retry 3 git clone --depth=1 -b "$ref" "$repo" "$KROOT/$dir"

  [ -d "$KROOT/$dir/kernel" ] || die "$dir 中没有 kernel/ 目录，无法集成"
  local root_commit
  root_commit="$(git -C "$KROOT/$dir" rev-parse HEAD)"
  info "commit: $root_commit"

  # 用相对软链接挂进 drivers/kernelsu（必须落在 kernel 工作区内，Bazel 沙箱才能读到）
  local rel
  rel="$(realpath --relative-to="$COMMON/drivers" "$KROOT/$dir/kernel")"
  rm -f "$COMMON/drivers/kernelsu"
  ln -s "$rel" "$COMMON/drivers/kernelsu"
  info "drivers/kernelsu -> $rel"
  ROOT_DIR="$dir"
  export ROOT_DIR

  grep -qF 'obj-$(CONFIG_KSU) += kernelsu/' "$COMMON/drivers/Makefile" \
    || printf '\nobj-$(CONFIG_KSU) += kernelsu/\n' >> "$COMMON/drivers/Makefile"

  python3 - "$COMMON/drivers/Kconfig" <<'PY'
import sys

path = sys.argv[1]
src = open(path, encoding="utf-8").read()
if "drivers/kernelsu/Kconfig" not in src:
    idx = src.rfind("\nendmenu")
    line = 'source "drivers/kernelsu/Kconfig"\n'
    src = src[:idx] + "\n" + line + src[idx:] if idx != -1 else src + "\n" + line
    open(path, "w", encoding="utf-8").write(src)
    print("    drivers/Kconfig: 已加入 kernelsu Kconfig")
PY

  # --- 各管理器已知的上游坑，逐个打平 ---
  case "$ROOT_MANAGER" in
    kernelsu-next)
      # Kbuild 在 mrproper 阶段（尚无 .config）就 $(error)，会直接终止清理步骤
      local kbuild="$KROOT/$dir/kernel/Kbuild"
      if [ -f "$kbuild" ] && grep -q 'KernelSU requires either CONFIG_KPROBES' "$kbuild"; then
        sed -i 's/\$(error "KernelSU requires either CONFIG_KPROBES=y or CONFIG_KSU_SUSFS=y")/$(warning "KernelSU requires either CONFIG_KPROBES=y or CONFIG_KSU_SUSFS=y")/' "$kbuild"
        info "已把 Next 的 Kbuild 配置检查降级为 warning"
      fi
      ;;
    bakasu)
      local kbuild="$KROOT/$dir/kernel/Kbuild"
      if [ -f "$kbuild" ] && grep -q 'as a git submodule instead of copying code directly' "$kbuild"; then
        sed -i 's/\$(error You should use \$(REPO_NAME) as a git submodule instead of copying code directly)/$(warning You should use $(REPO_NAME) as a git submodule instead of copying code directly)/' "$kbuild"
        info "已把 BakaSU 的子模块检查降级为 warning"
      fi
      local compat="$KROOT/$dir/kernel/tools/susfs_compat.mk"
      if [ -f "$compat" ] && grep -q 'Please wait susfs update' "$compat"; then
        sed -i '/susfs has NOT update with latest KernelSU source/,$d' "$compat"
        info "已移除 BakaSU 的 susfs_compat 强制中断"
      fi
      ;;
  esac

  {
    echo "ROOT_IMPLEMENTATION=${ROOT_MANAGER}"
    echo "ROOT_DIR=${dir}"
    echo "ROOT_COMMIT=${root_commit}"
    echo "ROOT_MANAGER_NAME=${manager}"
  } >> "${GITHUB_ENV:-/dev/null}"
}

# ---------------------------------------------------------------------------
# 4. SUSFS
# ---------------------------------------------------------------------------
setup_susfs() {
  if ! is_true "$SUSFS_ON"; then
    log "跳过 SUSFS"
    return 0
  fi
  [ "$ROOT_MANAGER" != "none" ] || die "SUSFS 需要先选择 Root 管理器"

  log "同步 SUSFS 补丁: ${SUSFS_BRANCH}"
  rm -rf "$WS/susfs4ksu"
  retry 3 git clone --depth=1 -b "$SUSFS_BRANCH" "$SUSFS_REPO" "$WS/susfs4ksu"
  if [ -n "$SUSFS_COMMIT" ]; then
    retry 3 git -C "$WS/susfs4ksu" fetch --depth=1 origin "$SUSFS_COMMIT"
    git -C "$WS/susfs4ksu" checkout --detach "$SUSFS_COMMIT"
  fi
  local susfs_commit
  susfs_commit="$(git -C "$WS/susfs4ksu" rev-parse HEAD)"
  info "SUSFS commit: $susfs_commit"
  echo "SUSFS_COMMIT=${susfs_commit}" >> "${GITHUB_ENV:-/dev/null}"

  local patches="$WS/susfs4ksu/kernel_patches"
  # susfs.c 与头文件不在补丁里，是直接放入内核树的文件
  cp "$patches/fs/"* "$COMMON/fs/"
  cp "$patches/include/linux/"* "$COMMON/include/linux/"

  local main_patch="$patches/50_add_susfs_in_${SUSFS_BRANCH}.patch"
  [ -f "$main_patch" ] || die "找不到内核侧补丁: $main_patch"
  apply_patch_file "$main_patch" "SUSFS 内核侧补丁 (${SUSFS_BRANCH})"

  # 6.6 专有的编译适配（include 缺失、VMA_PAD_START、fanotify 回调签名）
  python3 "$SCRIPT_DIR/py/susfs_66_compat.py" "$COMMON" "${SOURCE_KERNEL_VERSION##*.}"

  # tiann/KernelSU 主分支本身不带 SUSFS 胶水，需要额外使能补丁；
  # Next / BakaSU / SukiSU-Ultra 自带 Kconfig 与调用，无需处理。
  if [ "$ROOT_MANAGER" = "kernelsu" ]; then
    local enable_patch="$patches/KernelSU/10_enable_susfs_for_ksu.patch"
    [ -f "$enable_patch" ] || die "缺少 $enable_patch"
    log "给 KernelSU(tiann) 应用 SUSFS 使能补丁"
    ( cd "$KROOT/$ROOT_DIR" && patch -p1 --batch < "$enable_patch" ) | sed 's/^/    /'
  fi
}

# ---------------------------------------------------------------------------
# 5. 功能补丁
# ---------------------------------------------------------------------------
fetch_kernel_patches() {
  if [ -d "$WS/kernel_patches" ]; then
    return 0
  fi
  log "同步通用补丁集 (WildKernels/kernel_patches)"
  retry 3 git clone --depth=1 -b "$KERNEL_PATCHES_REF" "$KERNEL_PATCHES_REPO" "$WS/kernel_patches"
}

setup_nomount() {
  is_true "$NOMOUNT_ON" || return 0
  log "集成 NoMount (${NOMOUNT_REF})"
  run_remote_setup "${NOMOUNT_REPO_RAW}/${NOMOUNT_REF}/kernel/setup.sh" "$COMMON" "$NOMOUNT_REF"
  [ -L "$COMMON/fs/nomount" ] || warn "未检测到 fs/nomount 软链接，NoMount 可能没有正确安装"
  local nomount_commit
  nomount_commit="$(git -C "$COMMON/NoMount" rev-parse HEAD 2>/dev/null || echo unknown)"
  echo "NOMOUNT_COMMIT=${nomount_commit}" >> "${GITHUB_ENV:-/dev/null}"
  info "NoMount commit: $nomount_commit"
}

setup_bbg() {
  is_true "$BBG_ON" || return 0
  log "集成 Baseband Guard"
  run_remote_setup "$BBG_SETUP_URL" "$KROOT"

  local bbg_dir="$COMMON/security/baseband-guard"
  [ -d "$bbg_dir" ] || die "Baseband Guard 安装失败: 找不到 $bbg_dir"

  # 把 baseband_guard 排进默认 LSM 顺序（已包含则不动）
  sed -i '/^config LSM$/,/^help$/{ /^[[:space:]]*default/ { /baseband_guard/! s/selinux/selinux,baseband_guard/ } }' \
    "$COMMON/security/Kconfig"
  grep -q 'baseband_guard' "$COMMON/security/Kconfig" \
    || warn "security/Kconfig 中没找到 baseband_guard，请检查上游 setup.sh 是否改过路径"
  info "BBG commit: $(git -C "$KROOT/Baseband-guard" rev-parse --short HEAD 2>/dev/null || echo unknown)"
}

setup_droidspaces() {
  is_true "$DROIDSPACES_ON" || return 0
  log "集成 DroidSpaces-OSS"
  rm -rf "$WS/Droidspaces-OSS"
  retry 3 git clone --depth=1 "$DROIDSPACES_REPO" "$WS/Droidspaces-OSS"
  if [ -n "$DROIDSPACES_REF" ]; then
    retry 3 git -C "$WS/Droidspaces-OSS" fetch --depth=1 origin "$DROIDSPACES_REF"
    git -C "$WS/Droidspaces-OSS" checkout --detach "$DROIDSPACES_REF"
  fi
  echo "DROIDSPACES_COMMIT=$(git -C "$WS/Droidspaces-OSS" rev-parse HEAD)" >> "${GITHUB_ENV:-/dev/null}"

  # 6.6 走 "below-kernel-6.12" 的 SYSVIPC kABI 修正
  local kabi="$WS/Droidspaces-OSS/Documentation/resources/kernel-patches/GKI/below-kernel-6.12/001.GKI-below-6.12-fix_sysvipc_kabi_6_7_8.patch"
  [ -f "$kabi" ] || die "找不到 DroidSpaces kABI 补丁: $kabi"
  apply_patch_file "$kabi" "DroidSpaces SYSVIPC kABI 修正"
}

setup_networking() {
  is_true "$NETWORKING_ON" || return 0
  log "集成网络增强 (BBRv3 / WireGuard / IPSet / CIFS)"
  fetch_kernel_patches
  local bbr_patch="$WS/kernel_patches/common/bbrv3/0001-net-tcp-backport-BBRv3-to-android15-6.6.patch"
  if ! apply_patch_optional "$bbr_patch" "BBRv3 回移"; then
    warn "BBRv3 补丁不适用当前源码，回退到内核自带 BBR（功能不受影响，只是拥塞控制算法版本不同）"
    echo "BBRV3_APPLIED=false" >> "${GITHUB_ENV:-/dev/null}"
  else
    echo "BBRV3_APPLIED=true" >> "${GITHUB_ENV:-/dev/null}"
  fi
}

setup_ntsync() {
  is_true "$NTSYNC_ON" || return 0
  log "集成 NTSync"
  fetch_kernel_patches
  apply_patch_file "$WS/kernel_patches/common/ntsync/ntsync_compat_android15-6.6.patch" "NTSync 兼容层"
  apply_patch_file "$WS/kernel_patches/common/ntsync/ntsync_base.patch" "NTSync 主体"
}

setup_ptrace() {
  is_true "$PTRACE_ON" || return 0
  if [ "$(printf '%s\n5.16\n' "$SOURCE_KERNEL_VERSION_MM" | sort -V | head -n1)" = "5.16" ]; then
    warn "内核 >= 5.16 不需要独立的 ptrace 补丁；ptrace 泄漏修复已包含在 SUSFS 内核侧补丁中"
    is_true "$SUSFS_ON" || warn "当前未启用 SUSFS，ptrace 修复实际未生效"
    return 0
  fi
  log "应用 ptrace 泄漏修复"
  fetch_kernel_patches
  apply_patch_file "$WS/kernel_patches/gki_ptrace.patch" "ptrace leak fix"
}

setup_unicode() {
  is_true "$UNICODE_ON" || return 0
  log "应用 Unicode 绕过修复"
  fetch_kernel_patches
  apply_patch_optional "$WS/kernel_patches/common/unicode_bypass_fix_6.1+.patch" "Unicode bypass fix" || true
}

# ---------------------------------------------------------------------------
# 6. 内核配置
# ---------------------------------------------------------------------------
apply_configs() {
  log "写入内核配置"

  apply_config_file "$WS/config/base.config"

  if [ "$ROOT_MANAGER" != "none" ] && [ -f "$WS/config/root/${ROOT_MANAGER}.config" ]; then
    info "--- Root: ${ROOT_MANAGER} ---"
    apply_config_file "$WS/config/root/${ROOT_MANAGER}.config"
  fi

  is_true "$SUSFS_ON"       && { info "--- SUSFS ---";        apply_config_file "$WS/config/features/susfs.config"; }
  is_true "$NOMOUNT_ON"     && { info "--- NoMount ---";      apply_config_file "$WS/config/features/nomount.config"; }
  is_true "$BBG_ON"         && { info "--- Baseband Guard ---"; apply_config_file "$WS/config/features/bbg.config"; }
  is_true "$DROIDSPACES_ON" && { info "--- DroidSpaces ---";  apply_config_file "$WS/config/features/droidspaces.config"; }
  is_true "$NETWORKING_ON"  && { info "--- Networking ---";   apply_config_file "$WS/config/features/networking.config"; }
  is_true "$NTSYNC_ON"      && { info "--- NTSync ---";       apply_config_file "$WS/config/features/ntsync.config"; }
  is_true "$BPF_ON"         && { info "--- BTF/eBPF ---";     apply_config_file "$WS/config/features/bpf.config"; }

  # Kleaf 会校验 gki_defconfig 与 savedefconfig 是否一致，改过就必须关掉检查
  python3 - "$COMMON/BUILD.bazel" <<'PY'
import sys

path = sys.argv[1]
src = open(path, encoding="utf-8").read()
if 'name = "kernel_aarch64",' in src and 'check_defconfig = "disabled"' not in src:
    src = src.replace(
        'name = "kernel_aarch64",',
        'name = "kernel_aarch64",\n    check_defconfig = "disabled",',
        1,
    )
    open(path, "w", encoding="utf-8").write(src)
    print("    BUILD.bazel: 已禁用 check_defconfig 校验")
PY

  # legacy build.sh 路径上的同名钩子，无该文件时忽略
  [ -f "$COMMON/build.config.gki" ] && sed -i 's/check_defconfig//' "$COMMON/build.config.gki"
  return 0
}

# ---------------------------------------------------------------------------
# 7. 收尾：把源码树的改动提交掉
#    Kleaf 用 scripts/setlocalversion 生成版本号，工作区有未提交改动时会追加
#    "-maybe-dirty"，uname -r 会变成 6.6.x-android15-8-maybe-dirty-4k 这种丑样子。
#    提交一次即可保持干净（内容不变，只是让 git 状态干净）。
# ---------------------------------------------------------------------------
finalize_tree() {
  log "提交源码树改动，避免版本号带 -maybe-dirty"
  cd "$COMMON"
  if ! git rev-parse --git-dir > /dev/null 2>&1; then
    warn "$COMMON 不是 git 仓库，跳过"
    return 0
  fi
  # NoMount 等工具会把代码 clone 进源码树，别把它们塞进这次提交
  grep -qxF 'NoMount' .git/info/exclude 2>/dev/null || echo 'NoMount' >> .git/info/exclude

  git add -A
  if git diff --cached --quiet; then
    info "没有需要提交的改动"
    return 0
  fi
  if git -c user.name="k90-ci" -c user.email="k90-ci@localhost" \
       commit -q -m "ci: apply kernel patches and config for build"; then
    info "已提交: $(git rev-parse --short HEAD)"
  else
    warn "提交失败，版本号可能带 -maybe-dirty（不影响功能）"
  fi
}

# ---------------------------------------------------------------------------
main() {
  resolve_preset
  summary
  cleanup_rejects

  sync_kernel

  pin_kernel_version
  setup_root
  setup_susfs
  setup_nomount
  setup_bbg
  setup_droidspaces
  setup_networking
  setup_ntsync
  setup_ptrace
  setup_unicode
  apply_configs
  finalize_tree

  cleanup_rejects

  log "准备阶段完成"
  if [ -n "${ROOT_DIR:-}" ]; then
    info "Root: ${ROOT_MANAGER} @ $(git -C "$KROOT/$ROOT_DIR" rev-parse --short HEAD)"
  fi
  info "defconfig: $COMMON/$DEFCONFIG_REL"
}

main "$@"
