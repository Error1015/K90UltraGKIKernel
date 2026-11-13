#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# 阶段 1：源码 + root + SUSFS + 内核配置
#
# 设计取向（相对旧流水线的重要变化）：
#   * 构建系统：Kbuild（make），不用 Kleaf/Bazel —— 与本机型已验证的构建方式一致
#   * 内核配置：**直接使用原厂 .config**（从 boot.img 提取，见 configs/warsaw_defconfig），
#     只在上面叠加 KSU/SUSFS 与版本串，不做任何"顺手优化"。
#     原因是 builtin/module 的划分与 ABI 敏感项必须与出厂一致，否则 vendor 模块加载不了。
#   * 源码版本：钉到与手机同 sublevel 的 ACK 发布 tag（默认 6.6.118）
# ---------------------------------------------------------------------------
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

MANIFEST_URL="${MANIFEST_URL:-https://android.googlesource.com/kernel/manifest}"
COMMON_URL="${COMMON_URL:-https://android.googlesource.com/kernel/common}"

KERNEL_RELEASE="${KERNEL_RELEASE:-6.6.118}"   # 手机 uname -r 的 sublevel
KERNEL_TAG="${KERNEL_TAG:-}"                  # 直接指定 ACK tag，优先于 KERNEL_RELEASE
MANIFEST_BRANCH="${MANIFEST_BRANCH:-common-${ANDROID_BRANCH}-lts}"

ROOT_IMPL="${ROOT_IMPL:-sukisu-ultra}"        # sukisu-ultra | none
SUKISU_REF="${SUKISU_REF:-v4.3.0}"
SUSFS="${SUSFS:-true}"
SUSFS_BRANCH="${SUSFS_BRANCH:-gki-android15-6.6}"
SUSFS_REPO="${SUSFS_REPO:-https://gitlab.com/simonpunk/susfs4ksu.git}"
LOCALVERSION="${LOCALVERSION:--android15-8-warsaw-4k}"

mkdir -p "$KROOT"

# ---------------------------------------------------------------------------
log "阶段 1/5：同步 ACK 源码（${MANIFEST_BRANCH}）"
# ---------------------------------------------------------------------------
cd "$KROOT"
if [ ! -d .repo ]; then
  # 分支名在 ACK 里变过几次（-lts / 纯版本线），逐个试，别因为一个名字挂掉整条流水线
  INIT_OK=0
  for b in "$MANIFEST_BRANCH" "common-${ANDROID_BRANCH}"; do
    info "尝试 manifest 分支: $b"
    if retry 2 repo init -u "$MANIFEST_URL" -b "$b" --depth=1; then
      INIT_OK=1
      MANIFEST_BRANCH="$b"
      break
    fi
  done
  [ "$INIT_OK" = "1" ] || die "repo init 失败（manifest 分支都不存在？）"
fi

TAG="$KERNEL_TAG"
if [ -z "$TAG" ]; then
  log "解析 6.6.${KERNEL_RELEASE##*.} 对应的 ACK 发布 tag"
  if TAG="$(python3 "$WS/project/resolve_tag.py" \
              --repo "$COMMON_URL" --branch "$ANDROID_BRANCH" --version "$KERNEL_RELEASE")"; then
    info "命中 tag: $TAG"
  else
    TAG=""
    warn "没解析到 tag，回退到分支 HEAD（KMI 可能与手机不一致，见 README）"
  fi
fi

if [ -n "$TAG" ]; then
  MANIFEST_FILE="$(find "$KROOT/.repo/manifests" -maxdepth 1 -name '*.xml' | head -1)"
  [ -n "$MANIFEST_FILE" ] || die "找不到 manifest 文件"
  python3 "$WS/project/pin_manifest.py" "$MANIFEST_FILE" "refs/tags/$TAG" \
    || die "钉 manifest 失败"
fi

log "repo sync（首次约 5~10 分钟）"
# revision 写成完整的 refs/tags/...，所以不需要拉全部 tag
SYNC_ARGS=(-c --current-branch --no-tags -j"$(nproc)")

export GIT_CONFIG_COUNT=2
export GIT_CONFIG_KEY_0=http.lowSpeedLimit
export GIT_CONFIG_VALUE_0=1024
export GIT_CONFIG_KEY_1=http.lowSpeedTime
export GIT_CONFIG_VALUE_1=120

retry 3 repo sync "${SYNC_ARGS[@]}" || die "repo sync 失败（googlesource 限速时重跑即可）"

[ -f "$COMMON/Makefile" ] || die "同步后找不到 $COMMON/Makefile"

# ---------------------------------------------------------------------------
log "阶段 2/5：校验源码版本"
# ---------------------------------------------------------------------------
WANT_SUB="${KERNEL_RELEASE##*.}"
GOT_SUB="$(sed -n 's/^SUBLEVEL *= *//p' "$COMMON/Makefile" | head -1 | tr -d '[:space:]')"
info "源码 SUBLEVEL = $GOT_SUB（期望 $WANT_SUB）"
if [ -n "$WANT_SUB" ] && [ "$GOT_SUB" != "$WANT_SUB" ]; then
  die "源码版本与手机不一致：期望 6.6.$WANT_SUB，实际 6.6.$GOT_SUB。
    KMI 冻结的是符号 CRC，跨 sublevel 可能让 vendor 模块全部加载失败。
    想强行继续就显式传 KERNEL_RELEASE=$GOT_SUB。"
fi
echo "$GOT_SUB" > "$WS/.kernel_sublevel"

# ---------------------------------------------------------------------------
log "阶段 3/5：集成 root（$ROOT_IMPL）"
# ---------------------------------------------------------------------------
if [ "$ROOT_IMPL" != "none" ]; then
  case "$ROOT_IMPL" in
    sukisu-ultra)
      SUKISU_DIR="$WS/SukiSU-Ultra"
      [ -d "$SUKISU_DIR" ] || retry 3 git clone --depth 1 -b "$SUKISU_REF" \
        https://github.com/SukiSU-Ultra/SukiSU-Ultra.git "$SUKISU_DIR" \
        || die "clone SukiSU-Ultra 失败"
      ;;
    *) die "不支持的 root: $ROOT_IMPL（v1 只保留 sukisu-ultra / none）" ;;
  esac

  [ -d "$SUKISU_DIR/kernel" ] || die "$SUKISU_DIR/kernel 不存在，仓库结构变了？"

  # 官方约定的接入方式：软链到 drivers/kernelsu，再挂 Kbuild / Kconfig
  rm -rf "$COMMON/drivers/kernelsu"
  ln -sfn "$SUKISU_DIR/kernel" "$COMMON/drivers/kernelsu"

  if ! grep -q 'kernelsu/' "$COMMON/drivers/Makefile"; then
    echo 'obj-$(CONFIG_KSU) += kernelsu/' >> "$COMMON/drivers/Makefile"
    info "drivers/Makefile += kernelsu/"
  fi

  python3 - "$COMMON/drivers/Kconfig" <<'PY'
import sys
path = sys.argv[1]
src = 'source "drivers/kernelsu/Kconfig"\n'
with open(path, encoding="utf-8") as fh:
    text = fh.read()
if "drivers/kernelsu/Kconfig" not in text:
    idx = text.rfind("endmenu")
    if idx < 0:
        text += src
    else:
        text = text[:idx] + src + text[idx:]
    with open(path, "w", encoding="utf-8", newline="") as fh:
        fh.write(text)
    print("    drivers/Kconfig += source kernelsu/Kconfig")
PY

  if is_true "$SUSFS"; then
    log "阶段 3/5：集成 SUSFS（$SUSFS_BRANCH）"
    SUSFS_DIR="$WS/susfs4ksu"
    [ -d "$SUSFS_DIR" ] || retry 3 git clone --depth 1 -b "$SUSFS_BRANCH" \
      "$SUSFS_REPO" "$SUSFS_DIR" || die "clone susfs4ksu 失败"

    PATCH="$(find "$SUSFS_DIR/kernel_patches" -maxdepth 1 -name '50_add_susfs_in_*' | head -1)"
    [ -n "$PATCH" ] || die "susfs4ksu 里找不到 50_add_susfs_in_* 补丁"

    # 1) 内核侧：fs/susfs.c + include/linux/susfs*.h + 各处 hooked 调用点
    apply_patch "$COMMON" "$PATCH" "susfs4ksu 50_add"

    # 2) root 侧：把 susfs4ksu 的 KernelSU 胶水移植到 SukiSU（补丁已随仓库固定）
    apply_patch "$SUKISU_DIR" "$WS/patches/susfs-for-sukisu-v4.3.0.patch" \
      "SUSFS -> SukiSU 胶水"
  fi
fi

# ---------------------------------------------------------------------------
log "阶段 4/5：写内核配置"
# ---------------------------------------------------------------------------
cp "$WS/configs/warsaw_defconfig" "$OUT/.config"
info "基础配置：原厂 .config（取自 boot.img 内嵌 IKCONFIG，7756 行）"

apply_fragment "$WS/configs/base.fragment"
set_cfg LOCALVERSION "$LOCALVERSION"

if [ "$ROOT_IMPL" != "none" ]; then
  apply_fragment "$WS/configs/root/sukisu-ultra.fragment"
  if is_true "$SUSFS"; then
    apply_fragment "$WS/configs/features/susfs.fragment"
  fi
fi

# ---------------------------------------------------------------------------
log "阶段 5/5：准备构建环境"
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
info "clang       : $CLANG_DIR ($("$CLANG_DIR/bin/clang" --version | head -1))"

if command -v pahole >/dev/null 2>&1; then
  info "pahole      : $(pahole --version 2>/dev/null || echo 未知)"
else
  warn "PATH 里没有 pahole（DEBUG_INFO_BTF=y 需要它，构建阶段会尝试系统包）"
fi

log "准备完成"
info "内核源码 : $COMMON"
info "配置文件 : $OUT/.config"
