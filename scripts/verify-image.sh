#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# 刷机前体检：接受 AnyKernel3 zip 或裸 Image，做静态检查
# 用法: bash scripts/verify-image.sh <zip 或 Image> [--expect-root] [--expect-susfs]
# ---------------------------------------------------------------------------
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

target="${1:-}"
[ -n "$target" ] || { echo "用法: bash scripts/verify-image.sh <zip 或 Image> [--expect-root] [--expect-susfs]" >&2; exit 2; }
shift
[ -f "$target" ] || { echo "文件不存在: $target" >&2; exit 2; }

workdir="$(mktemp -d)"
trap 'rm -rf "$workdir" 2>/dev/null || true' EXIT

case "$target" in
  *.zip)
    echo "解包 $target"
    unzip -q "$target" -d "$workdir"
    image="$workdir/Image"
    [ -f "$image" ] || { echo "zip 里没有 Image，结构不对" >&2; exit 1; }
    if [ -f "$workdir/anykernel.sh" ]; then
      echo "--- anykernel.sh 关键项 ---"
      grep -E '^(kernel\.string|do\.devicecheck|do\.modules|do\.systemless)=' "$workdir/anykernel.sh" | sed 's/^/  /'
      echo
    fi
    ;;
  *)
    image="$target"
    ;;
esac

python3 "$SCRIPT_DIR/py/inspect_image.py" "$image" "$@"
