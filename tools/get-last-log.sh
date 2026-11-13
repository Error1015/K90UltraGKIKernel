#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# 把上一次开机（尤其是"刷了内核卡 logo 那次"）的内核日志抓下来
#
#   bash tools/get-last-log.sh
#
# 重要：ramoops 只保留**上一次**开机的 console。所以正确用法是
#   刷内核 -> 卡住 -> 长按电源重启进原系统 -> 立刻跑本脚本
# 再重启几次旧记录就被覆盖了。
#
# 只读操作，不改手机任何东西。
# ---------------------------------------------------------------------------
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/../project/lib.sh"
set +e

command -v adb >/dev/null 2>&1 || die "找不到 adb，请先把 platform-tools 加进 PATH"
adb get-state >/dev/null 2>&1 || die "没有检测到设备（adb devices 为空，或未授权 USB 调试）"

STAMP="$(date +%Y%m%d-%H%M%S)"
DEST="${1:-$SCRIPT_DIR/../last-boot-log-$STAMP.txt}"

sh_get() { adb shell "$1" 2>/dev/null | tr -d '\r'; }
sh_su()  { adb shell "su -c '$1'" 2>/dev/null | tr -d '\r'; }

log "读取 /sys/fs/pstore"
LIST="$(sh_get 'ls -l /sys/fs/pstore/ 2>/dev/null')"
if [ -z "$LIST" ] || ! printf '%s' "$LIST" | grep -q 'ramoops\|console'; then
  LIST="$(sh_su 'ls -l /sys/fs/pstore/ 2>/dev/null')"
fi
if [ -z "$LIST" ]; then
  warn "/sys/fs/pstore 是空的（或读不到）"
  info "常见原因："
  info "  1) 已经重启过多次，旧记录被覆盖 —— 请按「刷→卡住→重启→立刻跑」的顺序"
  info "  2) 设备没启用 ramoops"
  info "  3) 需要 root 才能读（本脚本会尝试 su）"
  exit 1
fi
printf '%s\n' "$LIST" | sed 's/^/    /'

: > "$DEST"
for f in $(printf '%s\n' "$LIST" | awk '{print $NF}' | grep -E 'ramoops|console|dmesg' | sort -u); do
  printf '\n===== /sys/fs/pstore/%s =====\n' "$f" >> "$DEST"
  sh_su "cat /sys/fs/pstore/$f" >> "$DEST"
  [ -s "$DEST" ] || sh_get "cat /sys/fs/pstore/$f" >> "$DEST"
done

[ -s "$DEST" ] || die "连上了 pstore 但内容为空"
log "已保存: $DEST  ($(wc -l < "$DEST") 行)"

# ---------------------------------------------------------------------------
log "关键证据"
# hit <正则> <标签> [good|bad]  bad=命中是坏消息（红），good=命中是好消息（绿）
hit() {
  local pat="$1" label="$2" mode="${3:-bad}"
  local n
  n="$(grep -c -a -E "$pat" "$DEST" 2>/dev/null || true)"
  [ -z "$n" ] && n=0
  if [ "$n" -gt 0 ]; then
    if [ "$mode" = "good" ]; then
      printf '  \033[1;32m[+]\033[0m %-42s %s 处\n' "$label" "$n"
    else
      printf '  \033[1;31m[!]\033[0m %-42s %s 处\n' "$label" "$n"
    fi
    grep -a -E "$pat" "$DEST" | head -3 | sed 's/^/        /'
  else
    printf '  \033[2m[ ]\033[0m %-42s 0\n' "$label"
  fi
}

hit 'Linux version '                    '内核启动横幅（内核确实起来了）' good
hit 'Freeing unused kernel memory'      '进入用户态（Android init 开始跑）' good
hit 'Run /init as init process'         'init 被拉起来' good
hit 'unknown symbol in module'          'unknown symbol（模块要的符号没导出）'
hit 'disagrees about version of symbol' '符号 CRC 不一致（配置/ABI 变了）'
hit 'module verification failed|Loading of module with unavailable key' '模块签名校验失败'
hit 'version magic'                     'vermagic 不匹配'
hit 'Kernel panic|Unable to handle kernel|BUG: ' '内核崩溃/异常'
hit 'kernelsu|ksu_|insmod'              'KernelSU / insmod 相关'
hit 'dm-verity|avb|verified boot|orange' 'AVB / dm-verity'
hit 'init: |Init encountered'           'init 阶段报错'

echo
log "这几条日志分别来自哪个内核"
grep -a -o 'Linux version [^ ]*' "$DEST" 2>/dev/null | sort -u | sed 's/^/    /'
echo "    如果上面出现的是你刷进去的版本（不是 6.6.118 原厂），说明失败那轮内核确实跑起来了。"

log "结论"
if grep -q -a 'unknown symbol in module' "$DEST"; then
  warn "厂商模块需要的符号没被导出 —— 需要放宽导出符号裁剪（或补上对应 abi 符号表）"
elif grep -q -a 'disagrees about version of symbol' "$DEST"; then
  warn "符号 CRC 不一致 —— 内核配置与出厂配置在 ABI 敏感项上不一致，用 config_mode=device 重建"
elif grep -q -a 'Kernel panic\|Unable to handle kernel' "$DEST"; then
  warn "内核 panic —— 看上面的调用栈，通常是某个补丁"
elif grep -q -a 'Freeing unused kernel memory\|Run /init as init process' "$DEST"; then
  warn "内核已经跑到用户态才停住 —— 问题在 ramdisk / 模块 / init_boot，不是内核本体"
else
  warn "日志里没有内核启动横幅 —— 内核可能根本没被执行（boot 镜像 / 刷写位置 / AVB）"
fi

echo
info "请把 $DEST 的内容发我，或者只看最后 200 行："
info "  tail -n 200 \"$DEST\""
