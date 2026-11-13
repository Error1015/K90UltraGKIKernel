#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# 阶段 2：make 构建 Image + 逐项回读校验
#
# 只用 Kbuild：make ARCH=arm64 LLVM=1 O=out Image
# （不需要 Bazel/Kleaf；GKI 的 Image 就是 common 树的标准产物）
# ---------------------------------------------------------------------------
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT_IMPL="${ROOT_IMPL:-sukisu-ultra}"
SUSFS="${SUSFS:-true}"

CLANG_DIR="${CLANG_DIR:-$(find "$KROOT/prebuilts/clang/host/linux-x86" -maxdepth 1 -type d -name 'clang-r*' | sort -V | tail -1)}"
BUILD_TOOLS="${BUILD_TOOLS:-$KROOT/prebuilts/build-tools/linux-x86/bin}"
[ -d "$CLANG_DIR" ] || die "找不到 clang 工具链"
export PATH="$CLANG_DIR/bin:$BUILD_TOOLS:$PATH"

# ---------------------------------------------------------------------------
# 工具链自检：缺工具时 make 只会甩一个 "Error 127"，日志里连 error: 都没有，
# 事后极难判断。在这里提前说清楚。
# ---------------------------------------------------------------------------
MISSING=()
for t in clang ld.lld llvm-ar llvm-nm llvm-objcopy llvm-objdump llvm-readelf \
         pahole bc flex bison; do
  command -v "$t" >/dev/null 2>&1 || MISSING+=("$t")
done
if [ "${#MISSING[@]}" -gt 0 ]; then
  die "缺少构建工具：${MISSING[*]}（PATH 里找不到）"
fi
info "工具链：$(clang --version | head -1)"

export ARCH=arm64
export LLVM=1
export KBUILD_BUILD_USER=kleaf
export KBUILD_BUILD_HOST=build-host
export KBUILD_BUILD_VERSION=1
# 固定时间戳：同样的源码 + 同样的配置 → 同样的二进制（便于复现与比对）
KBUILD_BUILD_TIMESTAMP="${KBUILD_BUILD_TIMESTAMP:-$(date -u '+%a %b %d %H:%M:%S UTC %Y')}"
export KBUILD_BUILD_TIMESTAMP

cd "$COMMON"

# ---------------------------------------------------------------------------
log "收敛配置（olddefconfig）"
# ---------------------------------------------------------------------------
make O="$OUT" olddefconfig > "$OUT/olddefconfig.log" 2>&1 \
  || { tail -40 "$OUT/olddefconfig.log"; die "olddefconfig 失败"; }

[ -f "$OUT/.config" ] || die "olddefconfig 之后没有 .config"

# ---------------------------------------------------------------------------
log "回读校验：确认关键配置真的生效"
# 必须在 olddefconfig 之后查，否则 Kconfig 依赖不满足时符号会被静默丢掉。
# ---------------------------------------------------------------------------
if [ "$ROOT_IMPL" != "none" ]; then
  require_cfg KSU y
  if is_true "$SUSFS"; then
    require_cfg KSU_SUSFS y
    # 片段里写了的每个 SUSFS 开关都回读一遍：符号存在但没生效 → 直接中断；
    # 该 root 的 Kconfig 压根没有这个符号 → 提示后跳过（不算错）。
    # 这样"片段写了、olddefconfig 静默丢掉"不会再悄悄溜过去。
    while read -r sym; do
      expect_cfg "$sym" y
    done < <(sed -n 's/^CONFIG_\(KSU_SUSFS[A-Z0-9_]*\)=y$/\1/p' \
               "$WS/configs/features/susfs.fragment" | grep -vx 'KSU_SUSFS')
  fi
fi

# 附加功能：勾了就必须在最终配置里（符号来自各自的 Kconfig，缺了说明补丁没真正生效）
is_true "${NTSYNC:-false}"      && require_cfg NTSYNC y
is_true "${NOMOUNT:-false}"     && require_cfg NOMOUNT y
is_true "${BBG:-false}"         && require_cfg BBG y
is_true "${DROIDSPACES:-false}" && require_cfg USER_NS y
if is_true "${NETWORKING:-false}"; then
  require_cfg IP_SET y
  require_cfg CIFS y
  require_cfg DEFAULT_TCP_CONG bbr
fi
is_true "${BPF:-false}"         && require_cfg FUSE_BPF y

require_cfg ARM64_4K_PAGES y
require_cfg MODVERSIONS y
require_cfg TRIM_UNUSED_KSYMS n
require_cfg IKCONFIG y

# 这几项是 ABI 敏感项，与出厂不一致时只告警不中断（KMI 判定看的是符号 CRC）
require_cfg CFI_CLANG y
require_cfg MODULE_SIG_PROTECT y
require_cfg KALLSYMS_ALL y

LOCALVER="$(sed -n 's/^CONFIG_LOCALVERSION="\(.*\)"$/\1/p' "$OUT/.config")"
info "LOCALVERSION = $LOCALVER"

# ---------------------------------------------------------------------------
log "启动编译（make Image，约 10~25 分钟）"
# ---------------------------------------------------------------------------
JOBS="${JOBS:-$(nproc)}"
START=$(date +%s)
# --output-sync=target：每个目标（单个 .o / 单个子目录）的输出聚在一起不交错，
# 失败时"根因"和它的 make 摘要行必然相邻，日志尾部就是线索。
MAKE_ARGS=(-j"$JOBS")
[ "$JOBS" -gt 1 ] && MAKE_ARGS+=(--output-sync=target)
# -k：一次把"所有"坏掉的地方都编出来，而不是撞到第一个就停。
# 失败时能一次性看到全部错误，省掉"修一处 → 重跑 15 分钟 → 再撞下一个"的循环。
MAKE_ARGS+=(-k)
set +e
make O="$OUT" "${MAKE_ARGS[@]}" Image > "$OUT/build.log" 2>&1
RC=$?
set -e
ELAPSED=$(( $(date +%s) - START ))

if [ "$RC" != "0" ]; then
  LOG="$OUT/build.log"
  warn "编译失败（${ELAPSED}s，make 返回 $RC）"

  # 1) 第一条 make 摘要行，连同它前面 80 行 —— 真正的根因就在这里
  FIRST="$(grep -nE 'make(\[[0-9]+\])?: \*\*\*' "$LOG" | head -1 | cut -d: -f1 || true)"
  if [ -n "${FIRST:-}" ]; then
    FROM=$(( FIRST > 80 ? FIRST - 80 : 1 ))
    echo "===== 根因所在（第 ${FROM}~${FIRST} 行）====="
    sed -n "${FROM},${FIRST}p" "$LOG"
  else
    echo "===== 没有 make 的 *** 行，见下面的疑似错误 ====="
  fi

  # 2) 诊断行：clang 是 "error:"、GNU as 是大写 "Error:"、汇编器还可能只给位置。
  #    只认小写 error: 会漏掉后两种 —— 干脆按 "文件:行:列:" 的格式全抓。
  echo "===== 诊断行（文件:行:列，最多 40 条）====="
  grep -nE '^[^ :]+:[0-9]+:([0-9]+)?: ' "$LOG" | head -40 || true

  # 3) 兜底：把一切像错误的行都列出来（含大写 ERROR:、Killed、undefined 等）
  echo "===== 疑似错误行（最多 60 条）====="
  grep -niE 'error|undefined reference|no rule to make target|is not available|unrecognized|killed|fatal|abort' "$LOG" \
    | grep -viE '^[0-9]+: *[[:space:]]*(CC|LD|AR|AS|GEN|BTF|OBJCOPY|HOSTCC|HOSTLD|CALL|DESCEND|SYMLINK)\b' \
    | head -60 || true

  echo "===== 日志末尾 40 行 ====="
  tail -40 "$LOG"
  die "make 返回 $RC"
fi
log "编译完成（${ELAPSED}s）"

IMG="$OUT/arch/arm64/boot/Image"
[ -f "$IMG" ] || die "没找到 $IMG"
mkdir -p "$DIST"
cp "$IMG" "$DIST/Image"

# ---------------------------------------------------------------------------
log "产物自检"
# ---------------------------------------------------------------------------
SIZE=$(stat -c %s "$IMG")
info "Image 大小 : $SIZE 字节"

MAGIC="$(dd if="$IMG" bs=1 skip=56 count=4 status=none | od -An -tx1 | tr -d ' \n')"
[ "$MAGIC" = "41524d64" ] || die "ARM64 头魔数不对（期望 41524d64 = 'ARMd'，实际 $MAGIC）"
info "ARM64 头   : ARMd"

VERSION_STR="$(strings -a "$IMG" | grep -m1 -E '^Linux version ' || true)"
info "版本串     : ${VERSION_STR:-未找到}"
echo "$VERSION_STR" > "$DIST/kernel-version.txt"

# Image 不能大到把 vbmeta 挤出 boot 分区（96MB）
PART_SIZE="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["partition_size"])' \
             "$WS/firmware/boot-template.json")"
NEED=$(( 4096 + SIZE ))
NEED=$(( (NEED + 4095) / 4096 * 4096 ))
VB="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["vbmeta_size"])' \
      "$WS/firmware/boot-template.json")"
TOTAL=$(( NEED + VB + 64 ))
[ "$TOTAL" -le "$PART_SIZE" ] || die "内核太大：打包后需 $TOTAL 字节，分区只有 $PART_SIZE"
info "打包后占用 : $TOTAL / $PART_SIZE 字节"

log "构建阶段完成"
