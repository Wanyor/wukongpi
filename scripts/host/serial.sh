#!/usr/bin/env bash
#
# 连板子的串口控制台（macOS）
#
#   ./scripts/host/serial.sh              # 自动探测设备，115200
#   ./scripts/host/serial.sh 1500000      # 指定波特率
#   ./scripts/host/serial.sh -l           # 列出可用串口设备
#
# 用 tio 而不是 screen：串口没有远端 pty，screen 无法把终端宽高传过去，
# 板子的 shell 会一直以为是 80x24、长命令折行错乱。tio 会在连接时和
# 窗口变化时都发送尺寸，还会断线重连、可选日志。
#
set -euo pipefail

SRC_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

BAUD="${BAUD:-115200}"
LOG=""

die() { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }
log() { printf '\033[1;32m==>\033[0m %s\n' "$*"; }

# ---- 参数 ----
while [ $# -gt 0 ]; do
    case "$1" in
        -l|--list) LIST_ONLY=1 ;;
        -L|--log)  LOG="1" ;;
        -h|--help)
            sed -n '3,12p' "$0" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        [0-9]*)    BAUD="$1" ;;
        /dev/*)    DEV="$1" ;;
        *)         die "不认识的参数: $1" ;;
    esac
    shift
done

# ---- 枚举串口设备 ----
# 优先 cu.*（call-out，出站连接用；tty.* 会阻塞等 DCD）
list_devices() {
    ls /dev/cu.usbserial-* /dev/cu.usbmodem* /dev/cu.SLAB_USBtoUART* 2>/dev/null || true
}

DEVICES="$(list_devices)"

if [ "${LIST_ONLY:-0}" = "1" ]; then
    if [ -z "$DEVICES" ]; then
        echo "  没有检测到 USB 串口设备"
    else
        echo "  可用串口设备："
        for d in $DEVICES; do printf '    %s\n' "$d"; done
    fi
    exit 0
fi

if [ -z "${DEV:-}" ]; then
    COUNT="$(printf '%s\n' "$DEVICES" | grep -c . || true)"
    [ "$COUNT" -gt 0 ] || die "没检测到串口设备。

请确认：
  1. 板子已通过 Type-C 连到电脑（板载 USB 转串口）
  2. 或 USB-TTL 已接到板子的 TX/RX/GND
  然后执行 ./scripts/host/serial.sh -l 看设备列表"

    if [ "$COUNT" -eq 1 ]; then
        DEV="$(printf '%s\n' "$DEVICES" | head -1)"
    else
        # 多个设备时，用上次记住的；否则让用户选一次并记住。
        # 设备名里的数字是 USB 位置 ID，换 USB 口会变，所以缓存失效时重新选。
        CACHE="$SRC_ROOT/out/.serial-device"
        if [ -f "$CACHE" ] && [ -e "$(cat "$CACHE" 2>/dev/null)" ]; then
            DEV="$(cat "$CACHE")"
            log "沿用上次的设备 $(basename "$DEV")（要换：rm $CACHE）"
        else
            echo "  检测到多个串口设备，请选择板子所在的那个："
            i=1
            for d in $DEVICES; do printf '    %d) %s\n' "$i" "$d"; i=$((i+1)); done
            printf '  输入序号（默认 1）: '
            read -r pick
            pick="${pick:-1}"
            DEV="$(printf '%s\n' "$DEVICES" | sed -n "${pick}p")"
            [ -n "$DEV" ] || die "无效的序号: $pick"
            mkdir -p "$(dirname "$CACHE")"
            printf '%s\n' "$DEV" > "$CACHE"
            log "已记住 $(basename "$DEV")"
        fi
    fi
fi

[ -e "$DEV" ] || die "$DEV 不存在"

# ---- 用 tio 还是 screen ----
if command -v tio >/dev/null 2>&1; then
    log "tio $DEV @ $BAUD（窗口尺寸自动同步）"
    [ -n "$LOG" ] && set -- -l "$SRC_ROOT/out/serial-$(date +%Y%m%d-%H%M%S).log"
    exec tio "$DEV" -b "$BAUD" --databits 8 --parity n --stopbits 1 "$@"
else
    cat <<EOF >&2
[!] 没装 tio，退回 screen。
    串口下 screen 无法同步终端宽高，板子会以为自己是 80x24 —— 想解决就：
        brew install tio

EOF
    log "screen $DEV @ $BAUD（退出：Ctrl-A 然后 K，再按 Y）"
    exec screen "$DEV" "$BAUD"
fi
