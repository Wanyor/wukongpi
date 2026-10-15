#!/usr/bin/env bash
#
# rootfs 第一阶段：配置 APT 源 + 安装软件包。
#
# 在 linux/arm/v7 容器里以 root 执行。因为这一步最慢（qemu 模拟下十几分钟），
# 宿主机脚本会在它跑完后 docker commit 成 wukongpi-rootfs:<release>-stage1，
# 之后调配置脚本时就能直接复用，不用重新装一遍。
#
set -euo pipefail

: "${APT_MIRROR:=mirrors.ustc.edu.cn}"
: "${ROOTFS_RELEASE:=bookworm}"

export DEBIAN_FRONTEND=noninteractive
export LC_ALL=C.UTF-8

log() { printf '\n\033[1;32m==>\033[0m %s\n' "$*"; }

# ---------------------------------------------------------------------------
log "配置 APT 源: $APT_MIRROR ($ROOTFS_RELEASE)"
# ---------------------------------------------------------------------------
if [ -n "$APT_MIRROR" ]; then
    # 统一改写成经典 sources.list，行为可预测、用户也看得懂
    rm -f /etc/apt/sources.list.d/debian.sources
    cat > /etc/apt/sources.list <<EOF
deb http://${APT_MIRROR}/debian ${ROOTFS_RELEASE} main contrib non-free-firmware
deb http://${APT_MIRROR}/debian ${ROOTFS_RELEASE}-updates main contrib non-free-firmware
deb http://${APT_MIRROR}/debian-security ${ROOTFS_RELEASE}-security main contrib non-free-firmware
EOF
    cat /etc/apt/sources.list
fi

# ---------------------------------------------------------------------------
log "安装基础软件包（qemu 模拟下较慢，请耐心等待）"
# ---------------------------------------------------------------------------
# 安装期间禁止任何服务被真实拉起（容器里没有 systemd 在跑）
printf '#!/bin/sh\nexit 101\n' > /usr/sbin/policy-rc.d
chmod +x /usr/sbin/policy-rc.d

apt-get -o Acquire::Retries=5 update

apt-get -o Acquire::Retries=5 install -y --no-install-recommends \
    systemd systemd-sysv systemd-timesyncd udev dbus \
    openssh-server sudo \
    locales tzdata \
    kmod \
    iproute2 iputils-ping net-tools \
    ifupdown isc-dhcp-client \
    wpasupplicant wireless-tools rfkill iw \
    systemd-zram-generator cloud-guest-utils \
    e2fsprogs dosfstools parted fdisk usbutils pciutils \
    ca-certificates curl wget rsync less nano vim-tiny \
    htop tree jq \
    python3 \
    nftables iptables \
    fake-hwclock

rm -f /usr/sbin/policy-rc.d

# ---------------------------------------------------------------------------
log "清理 apt 缓存"
# ---------------------------------------------------------------------------
apt-get clean
rm -rf /var/cache/apt/archives/*.deb
rm -rf /tmp/* /var/tmp/*

# 给宿主机脚本用的标记：这一层已经做完了
touch /opt/wukongpi-packages-installed

log "软件包安装完成"
