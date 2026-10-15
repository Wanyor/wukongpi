#!/usr/bin/env bash
#
# 组装可烧录的 TF 卡镜像
#
#   偏移 8KiB   : u-boot-sunxi-with-spl.bin (SPL + U-Boot)
#   分区1 1MiB  : FAT32  BOOT  —— zImage / dtb / extlinux.conf
#   分区2       : ext4   rootfs
#
# 全程不用 loop 设备，因此在 Docker 容器里也能直接构建。
#
set -euo pipefail
# shellcheck source=/dev/null
source /project/scripts/inner/env.sh

UBOOT_BIN="$OUT_DIR/uboot/u-boot-sunxi-with-spl.bin"
KERNEL_ZIMAGE="$OUT_DIR/kernel/zImage"
KERNEL_DTB="$OUT_DIR/kernel/${BOARD_DTS}.dtb"
KERNEL_MODULES="$OUT_DIR/kernel/modules"
ROOTFS_TAR="$OUT_DIR/rootfs/rootfs.tar"

for f in "$UBOOT_BIN" "$KERNEL_ZIMAGE" "$KERNEL_DTB" "$ROOTFS_TAR"; do
    [ -e "$f" ] || die "缺少产物: ${f}（请先跑完 make uboot / kernel / rootfs）"
done

KVER="$(cat "$OUT_DIR/kernel/kernel.release")"
DATE="$(date +%Y%m%d)"
IMG="$OUT_DIR/${BOARD_NAME}-${KVER}-${DATE}.img"

# 确保 DTB 不比项目里的 DTS 旧。
# 只改设备树、不重编内核是很常见的情况（增量构建的盲区），
# 这里自己补上，避免镜像里带着陈旧的 DTB 还不自知。
DTS_SRC="$PROJECT_DIR/board/dts/${BOARD_DTS}.dts"
DTS_BIN="$OUT_DIR/kernel/${BOARD_DTS}.dtb"
if [ "$DTS_SRC" -nt "$DTS_BIN" ]; then
    warn "设备树源码比产物新，重新编译 dtb"
    cp "$DTS_SRC" "$LINUX_SRC/arch/arm/boot/dts/allwinner/"
    make -C "$LINUX_SRC" "allwinner/${BOARD_DTS}.dtb" >/dev/null
    cp "$LINUX_SRC/arch/arm/boot/dts/allwinner/${BOARD_DTS}.dtb" "$DTS_BIN"
    publish "kernel/${BOARD_DTS}.dtb"
    log "dtb 已更新: $(date -r "$DTS_BIN" '+%F %T')"
fi

STAGE="$BUILD_DIR/stage"
BOOT_STAGE="$STAGE/boot"
ROOT_STAGE="$STAGE/rootfs"
BOOT_IMG="$STAGE/boot.vfat"
ROOT_IMG="$STAGE/rootfs.ext4"
rm -rf "$STAGE"; mkdir -p "$BOOT_STAGE" "$ROOT_STAGE"

BOOT_OFF_MB=1
ROOT_OFF_MB=$(( BOOT_OFF_MB + BOOT_SIZE_MB ))
ROOT_SIZE_MB=$(( IMAGE_SIZE_MB - ROOT_OFF_MB ))
[ "$ROOT_SIZE_MB" -gt 256 ] || die "IMAGE_SIZE_MB 太小（至少 $((ROOT_OFF_MB+257))）"

# ---------------------------------------------------------------- 1. 启动分区
step "准备 BOOT 分区"
cp "$KERNEL_ZIMAGE" "$BOOT_STAGE/zImage"
cp "$KERNEL_DTB"    "$BOOT_STAGE/${BOARD_DTS}.dtb"

cat > "$BOOT_STAGE/extlinux.conf" <<EOF
# 悟空派 H3 Zero —— U-Boot distro boot 配置
# U-Boot 会在 TF 卡上寻找 /extlinux/extlinux.conf 并按这里的参数启动内核
PROMPT 0
TIMEOUT 10
DEFAULT wukongpi

LABEL wukongpi
	MENU LABEL WukongPi H3 Zero (Linux ${KVER})
	LINUX /zImage
	FDT /${BOARD_DTS}.dtb
	APPEND console=ttyS0,115200 earlycon root=/dev/mmcblk0p2 rootwait rw rootfstype=ext4 net.ifnames=0 loglevel=4
EOF
mkdir -p "$BOOT_STAGE/_extlinux"
mv "$BOOT_STAGE/extlinux.conf" "$BOOT_STAGE/_extlinux/extlinux.conf"

truncate -s $(( BOOT_SIZE_MB * 1024 * 1024 )) "$BOOT_IMG"
mkfs.fat -F 32 -n BOOT "$BOOT_IMG" >/dev/null
mmd  -i "$BOOT_IMG" ::/extlinux
mcopy -i "$BOOT_IMG" "$BOOT_STAGE/zImage"                        ::/zImage
mcopy -i "$BOOT_IMG" "$BOOT_STAGE/${BOARD_DTS}.dtb"              ::/
mcopy -i "$BOOT_IMG" "$BOOT_STAGE/_extlinux/extlinux.conf"       ::/extlinux/
log "BOOT 分区内容:"
mdir -i "$BOOT_IMG" ::/ ::/extlinux 2>/dev/null | sed 's/^/    /'

# ---------------------------------------------------------------- 2. 根文件系统
step "准备 rootfs 分区（解压 + 安装内核模块）"
tar -xpf "$ROOTFS_TAR" -C "$ROOT_STAGE"

rm -f "$ROOT_STAGE/.dockerenv"
mkdir -p "$ROOT_STAGE"/{dev,proc,sys,tmp,run,mnt,media,srv,boot}
chmod 1777 "$ROOT_STAGE/tmp"
chmod 700  "$ROOT_STAGE/root"

# 内核模块
MODDIR="$ROOT_STAGE/lib/modules/$KVER"
mkdir -p "$ROOT_STAGE/lib/modules"
if [ -d "$KERNEL_MODULES/lib/modules/$KVER" ]; then
    cp -a "$KERNEL_MODULES/lib/modules/$KVER" "$ROOT_STAGE/lib/modules/"
    depmod -b "$ROOT_STAGE" "$KVER"
    log "已安装 $(find "$MODDIR" -name '*.ko' | wc -l | tr -d ' ') 个内核模块"
else
    warn "没有找到内核模块目录，跳过"
fi

# /boot 与根分区
# nofail: 即使启动分区暂时挂不上，也不要把系统拖进 emergency mode
cat > "$ROOT_STAGE/etc/fstab" <<EOF
# <file system>  <mount point>  <type>  <options>                                <dump> <pass>
/dev/mmcblk0p1   /boot          vfat    defaults,noatime,nofail,x-systemd.device-timeout=10   0      2
/dev/mmcblk0p2   /              ext4    defaults,noatime                     0      1
EOF

truncate -s $(( ROOT_SIZE_MB * 1024 * 1024 )) "$ROOT_IMG"
step "生成 ext4 文件系统（${ROOT_SIZE_MB}MB）"
mke2fs -q -t ext4 -F -L rootfs -m 1 -d "$ROOT_STAGE" "$ROOT_IMG"

# ---------------------------------------------------------------- 3. 组装磁盘镜像
step "组装磁盘镜像（${IMAGE_SIZE_MB}MB，全程不使用 loop 设备）"
truncate -s $(( IMAGE_SIZE_MB * 1024 * 1024 )) "$IMG"

# u-boot 先写进去，再写分区表（顺序无所谓，但先分区更直观）
sfdisk --quiet "$IMG" <<EOF
label: dos
unit: sectors
sector-size: 512

start=2048, size=$(( BOOT_SIZE_MB * 2048 )), type=c, bootable
start=$(( ROOT_OFF_MB * 2048 )), size=$(( ROOT_SIZE_MB * 2048 )), type=83
EOF

dd if="$UBOOT_BIN" of="$IMG" bs=1024 seek="$UBOOT_SPL_SEEK_KB" conv=notrunc status=none
dd if="$BOOT_IMG"  of="$IMG" bs=1M   seek="$BOOT_OFF_MB"       conv=notrunc status=none
dd if="$ROOT_IMG"  of="$IMG" bs=1M   seek="$ROOT_OFF_MB"       conv=notrunc status=none

log "分区表:"
sfdisk -l "$IMG" 2>/dev/null | sed 's/^/    /'

# ---------------------------------------------------------------- 4. 压缩 + bmap
step "压缩镜像"
(
    cd "$OUT_DIR"
    xz -T0 -3 -k -f "${IMG##*/}"
)
rm -f "$IMG.bmap"
bmaptool create -o "$IMG.bmap" "$IMG" >/dev/null 2>&1 || warn "bmaptool 生成失败，忽略"

publish "$(basename "$IMG")"
publish "$(basename "$IMG").xz"
publish "$(basename "$IMG").bmap"

step "完成"
ls -lh "$OUT_DIR"/*.img* | sed 's/^/    /'
cat <<EOF

  烧录到 TF 卡：
    xz -dc $(basename "$IMG").xz | sudo dd of=/dev/diskN bs=4m
  或（推荐，只写有效数据）：
    bmaptool copy $(basename "$IMG").xz /dev/diskN

EOF
