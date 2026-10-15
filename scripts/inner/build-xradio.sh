#!/usr/bin/env bash
#
# 编译板载 XR819 WiFi 驱动（out-of-tree 模块）
#
# 驱动：https://github.com/fifteenhex/xradio
# 说明：XR819 在主线内核里没有驱动，必须额外编译这个模块。
#
set -euo pipefail
# shellcheck source=/dev/null
source /project/scripts/inner/env.sh

[ -d "$XRADIO_SRC" ] || die "xradio 源码不存在，请先执行 make fetch"
[ -f "$OUT_DIR/kernel/kernel.release" ] || die "请先编译内核（make kernel）"

KVER="$(cat "$OUT_DIR/kernel/kernel.release")"
MODDIR="$OUT_DIR/kernel/modules/lib/modules/$KVER"

step "编译 XR819 驱动 (内核 $KVER)"

# 驱动作者给出的标准 out-of-tree 构建方式
make -C "$LINUX_SRC" M="$XRADIO_SRC" modules

KO="$(find "$XRADIO_SRC" -maxdepth 1 -name 'xradio_wlan.ko' | head -1)"
[ -n "$KO" ] || die "没有生成 xradio_wlan.ko"

# 安装进内核模块目录，随后由 mk-sd-image 一起写进 rootfs
mkdir -p "$MODDIR/extra"
cp -v "$KO" "$MODDIR/extra/xradio_wlan.ko"

# 记录模块依赖（用到 modinfo / depmod）
depmod -b "$OUT_DIR/kernel/modules" "$KVER" 2>/dev/null || warn "depmod 失败，稍后会重试"

log "XR819 驱动编译完成 -> $MODDIR/extra/xradio_wlan.ko"
