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

# ---- 可选：WSM 消息追踪补丁 ----
# 固件 assert 后 SDIO 就死了，异常上报（0x0800）读不出来，拿不到
# file:line:code。这个补丁把驱动与固件之间每条 WSM 消息的
# id / 序号 / 长度都打成 "XRDIAG:" 前缀的 dev_err，用于事后分析。
#
# 注意：它会**连接收数据帧（0x0804）也一起打**，跑起流量后会刷屏，
# 所以默认关闭。要诊断时：XRADIO_DIAG=1 make xradio
XRADIO_DIAG="${XRADIO_DIAG:-0}"
DIAG_PATCH="$PROJECT_DIR/patches/xradio/0001-diag-wsm-trace.patch"
if [ -f "$DIAG_PATCH" ]; then
    if [ "$XRADIO_DIAG" = "1" ]; then
        log "应用 WSM 追踪补丁"
        if patch -d "$XRADIO_SRC" -p1 --forward --silent < "$DIAG_PATCH"; then
            log "  ✓ 已应用（日志前缀 XRDIAG:）"
        else
            warn "  补丁已应用过，继续"
        fi
    else
        # 撤销上一次可能残留的补丁，保证源码干净
        if patch -d "$XRADIO_SRC" -p1 --reverse --silent < "$DIAG_PATCH" 2>/dev/null; then
            log "已撤销 WSM 追踪补丁（干净构建）"
        fi
    fi
fi

step "编译 XR819 驱动 (内核 $KVER)"

# 先清理：驱动是小模块，清理成本极低，但能保证「打了补丁再撤销」
# 这类反复切换之后，产物一定是当前源码的确定结果，而不是增量残留。
make -C "$LINUX_SRC" M="$XRADIO_SRC" clean >/dev/null 2>&1 || true

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
