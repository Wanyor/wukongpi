#!/usr/bin/env bash
#
# 把构建好的镜像烧写到 TF 卡（macOS）
#
#   ./scripts/host/flash-sd.sh out/wukongpi-h3-6.18.56-20261014.img.xz /dev/disk4
#   ./scripts/host/flash-sd.sh --force ...      # 跳过有数据时的二次确认
#
# 不带参数运行时会列出所有可移动磁盘让你选。
#
# 安全检查（三层）：
#   1. 拒绝写入内置磁盘
#   2. 目标盘上如果挂着有数据的卷，把内容列出来并要求你手打磁盘号确认
#   3. 没有 --force 时一律要输 yes
#
set -euo pipefail

SRC_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

FORCE=0
ARGS=()
for a in "$@"; do
    case "$a" in
        --force|-f) FORCE=1 ;;
        *) ARGS+=("$a") ;;
    esac
done

die() { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
log() { printf '\033[1;32m==>\033[0m %s\n' "$*"; }

[ "$(uname)" = "Darwin" ] || die "本脚本只支持 macOS；Linux 下用 bmaptool 或 dd 即可"

IMG="${ARGS[0]:-}"
DISK="${ARGS[1]:-}"

if [ -z "$IMG" ]; then
    IMG="$(ls -t "$SRC_ROOT"/out/*.img.xz 2>/dev/null | head -1 || true)"
    [ -n "$IMG" ] || die "out/ 里没有 .img.xz，请先执行 make image"
fi
[ -f "$IMG" ] || die "找不到镜像文件: $IMG"

if [ -z "$DISK" ]; then
    log "可移动磁盘："
    diskutil list external physical | sed 's/^/    /'
    echo
    printf '请输入目标磁盘（例如 /dev/disk4）: '
    read -r DISK
fi

[ -b "$DISK" ] || die "$DISK 不是块设备"

INFO="$(diskutil info "$DISK" 2>/dev/null || true)"
[ -n "$INFO" ] || die "读不到 $DISK 的信息"

# ---- 第 1 层：绝不允许写内置磁盘 ----
if echo "$INFO" | grep -q "Internal:.*Yes"; then
    die "$DISK 是内置磁盘，拒绝写入（防止把系统盘抹掉）"
fi
if echo "$INFO" | grep -q "Virtual:.*Yes"; then
    die "$DISK 是虚拟磁盘，拒绝写入"
fi

# ---- 收集目标盘上各分区的挂载点与占用 ----
existing_data() {
    local disk="$1" part mp sz found=0
    local dname="${disk#/dev/}"
    for part in $(diskutil list "$disk" 2>/dev/null \
                  | awk -v d="$dname" '$NF ~ "^"d"s[0-9]+$" {print "/dev/" $NF}'); do
        mp="$(diskutil info "$part" 2>/dev/null | sed -n 's/^ *Mount Point: *//p')"
        case "$mp" in
            ""|"Not applicable"*) continue ;;
        esac
        [ -d "$mp" ] || continue
        sz="$(du -sh "$mp" 2>/dev/null | cut -f1)"
        printf '    %s  ->  %s  (已用 %s)\n' "$part" "$mp" "${sz:-?}"
        found=1
    done
    return $(( 1 - found ))
}

log "即将把 $(basename "$IMG") 写入 $DISK"
echo "$INFO" | grep -E "Device / Media Name|Disk Size|Removable Media" | sed 's/^/    /'

# ---- 第 2 层：盘上有数据就要求手打磁盘号 ----
if existing_data "$DISK"; then
    echo
    warn "目标磁盘上有已挂载的卷，里面可能是有用的数据！"
    warn "写入会不可恢复地抹掉上面的一切。"
    echo
    if [ "$FORCE" = 1 ]; then
        warn "--force 已指定，跳过这项确认"
    else
        printf '如果确认这些数据不要了，请输入磁盘号（%s）继续: ' "${DISK#/dev/}"
        read -r answer
        [ "$answer" = "${DISK#/dev/}" ] || die "输入不匹配，已取消"
    fi
else
    log "目标磁盘上没有已挂载的数据卷"
fi

# ---- 第 3 层：最终确认 ----
printf '\n确认要继续吗？输入 yes: '
read -r ans
[ "$ans" = "yes" ] || die "已取消"

log "卸载磁盘"
# 普通卸载失败就强制卸载；再不行就明确报错，避免 dd 报 "Resource busy"
diskutil unmountDisk "$DISK" >/dev/null 2>&1 \
    || diskutil unmountDisk force "$DISK" >/dev/null 2>&1 \
    || true

mounted_vols() {
    df -h 2>/dev/null | awk -v d="${1#/dev/}" '$1 ~ "^"d"s[0-9]+$" {print "    " $1 "  ->  " $NF}'
}
if [ -n "$(mounted_vols "$DISK")" ]; then
    die "磁盘上还有分区处于挂载状态，dd 会报 Resource busy：
$(mounted_vols "$DISK")

请先手动卸载后再执行本脚本：
    diskutil unmountDisk $DISK"
fi

RAW="${DISK/\/dev\/disk//dev/rdisk}"
log "写入中（用 rdisk 加速，请耐心等待）"
case "$IMG" in
    *.xz)  xz -dc "$IMG"  | sudo dd of="$RAW" bs=4m ;;
    *.gz)  gzip -dc "$IMG" | sudo dd of="$RAW" bs=4m ;;
    *.zst) zstd -dc "$IMG" | sudo dd of="$RAW" bs=4m ;;
    *)     sudo dd if="$IMG" of="$RAW" bs=4m ;;
esac

sync
diskutil eject "$DISK" >/dev/null 2>&1 || true
log "烧写完成，TF 卡可以拔下来插到板子上了"
