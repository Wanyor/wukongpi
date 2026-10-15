#!/usr/bin/env bash
#
# rootfs 第二阶段：系统配置（用户、网络、SSH、WiFi 固件、zram、扩容服务…）
#
# 在 linux/arm/v7 容器里以 root 执行，前提是 01-install-packages.sh 已经跑过。
#
set -euo pipefail

: "${ROOTFS_HOSTNAME:=wukongpi}"
: "${ROOTFS_USER:=orangepi}"
: "${ROOTFS_PASSWORD:=orangepi}"
: "${ROOTFS_ROOT_PASSWORD:=root}"
: "${ROOTFS_TIMEZONE:=Asia/Shanghai}"
: "${CONSOLE:=ttyS0}"

export DEBIAN_FRONTEND=noninteractive
export LC_ALL=C.UTF-8

log() { printf '\n\033[1;32m==>\033[0m %s\n' "$*"; }

# 启用 systemd 单元；容器里 systemctl 可能连不上 bus，退化成手动建软链接。
# 注意：这个函数永远返回 0 —— 个别单元找不到不应该让整个构建失败。
enable_unit() {
    local unit="$1" target="${2:-multi-user.target}" dir
    if systemctl enable "$unit" >/dev/null 2>&1; then
        echo "  ✓ $unit"
        return 0
    fi
    for dir in /etc/systemd/system /lib/systemd/system /usr/lib/systemd/system; do
        if [ -e "$dir/$unit" ]; then
            mkdir -p "/etc/systemd/system/$target.wants"
            ln -sf "$dir/$unit" "/etc/systemd/system/$target.wants/$unit"
            echo "  ✓ $unit (手动软链接 -> $target)"
            return 0
        fi
    done
    echo "  ! 找不到 ${unit}，跳过"
    return 0
}

# ---------------------------------------------------------------------------
log "主机名 / 时区 / machine-id"
# ---------------------------------------------------------------------------
echo "$ROOTFS_HOSTNAME" > /etc/hostname
cat > /etc/hosts <<EOF
127.0.0.1       localhost
127.0.1.1       ${ROOTFS_HOSTNAME}
::1             localhost ip6-localhost ip6-loopback
ff02::1         ip6-allnodes
ff02::2         ip6-allrouters
EOF

ln -snf "/usr/share/zoneinfo/${ROOTFS_TIMEZONE}" /etc/localtime
echo "$ROOTFS_TIMEZONE" > /etc/timezone

# 让 systemd 在首次开机时重新生成 machine-id
: > /etc/machine-id
rm -f /var/lib/dbus/machine-id

# ---------------------------------------------------------------------------
log "启用服务"
# ---------------------------------------------------------------------------
enable_unit ssh.service multi-user.target
enable_unit systemd-timesyncd.service multi-user.target
enable_unit "serial-getty@${CONSOLE}.service" getty.target

# ifupdown 的 networking 是 SysV 脚本，走 update-rc.d
update-rc.d networking defaults 2>/dev/null || true

# ---------------------------------------------------------------------------
log "用户与密码"
# ---------------------------------------------------------------------------
echo "root:${ROOTFS_ROOT_PASSWORD}" | chpasswd

for g in i2c spi gpio; do getent group "$g" >/dev/null || groupadd -r "$g"; done

if ! id "$ROOTFS_USER" >/dev/null 2>&1; then
    useradd -m -s /bin/bash -G \
        sudo,adm,dialout,cdrom,audio,video,plugdev,games,users,input,netdev,i2c,spi,gpio \
        "$ROOTFS_USER"
fi
echo "${ROOTFS_USER}:${ROOTFS_PASSWORD}" | chpasswd

cat > "/etc/sudoers.d/010-${ROOTFS_USER}-nopasswd" <<EOF
${ROOTFS_USER} ALL=(ALL) NOPASSWD: ALL
EOF
chmod 440 "/etc/sudoers.d/010-${ROOTFS_USER}-nopasswd"

# ---------------------------------------------------------------------------
log "网络（内核命令行带 net.ifnames=0，所以是经典的 eth0/wlan0）"
# ---------------------------------------------------------------------------
cat > /etc/network/interfaces <<EOF
# 有线网口（DHCP）
auto lo
iface lo inet loopback

allow-hotplug eth0
iface eth0 inet dhcp

# WiFi 需要先填好 /etc/wpa_supplicant/wpa_supplicant.conf 再取消下面的注释
#allow-hotplug wlan0
#iface wlan0 inet dhcp
#    wpa-conf /etc/wpa_supplicant/wpa_supplicant.conf
EOF

cat > /etc/wpa_supplicant/wpa_supplicant.conf <<'EOF'
# 把下面几行改成你自己的 WiFi，然后执行：
#   sudo ifup wlan0
country=CN
ctrl_interface=DIR=/var/run/wpa_supplicant GROUP=netdev
update_config=1

#network={
#    ssid="你的WiFi名字"
#    psk="你的WiFi密码"
#}
EOF
chmod 600 /etc/wpa_supplicant/wpa_supplicant.conf

# DNS 兜底（dhclient 启动后会覆盖它）
cat > /etc/resolv.conf <<'EOF'
nameserver 223.5.5.5
nameserver 8.8.8.8
EOF

ln -snf /lib/systemd/systemd /sbin/init

# ---------------------------------------------------------------------------
log "SSH：清掉构建阶段生成的 host key，改为首次开机生成"
# ---------------------------------------------------------------------------
# 不能用 ssh.service 的 ExecStartPre drop-in！
# systemd 会把 drop-in 里的 ExecStartPre 追加到主单元之后，而 Debian 的
# ssh.service 本来就有 ExecStartPre=/usr/sbin/sshd -t（配置自检），
# 它会先跑、并因为找不到 host key 而失败 → ssh.service 永远起不来。
# 正确做法是单独一个 oneshot 单元，用 Before=ssh.service 排在自检之前。
rm -f /etc/ssh/ssh_host_*
rm -rf /etc/systemd/system/ssh.service.d

cat > /etc/systemd/system/ssh-keygen-host-keys.service <<'EOF'
[Unit]
Description=Generate SSH host keys (first boot only)
ConditionPathExists=!/etc/ssh/ssh_host_ed25519_key
Before=ssh.service
After=local-fs.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/bin/ssh-keygen -A

[Install]
WantedBy=multi-user.target
EOF
enable_unit ssh-keygen-host-keys.service multi-user.target

# ---------------------------------------------------------------------------
log "XR819 WiFi：固件 + 按需加载（默认不自动加载）"
# ---------------------------------------------------------------------------
mkdir -p /lib/firmware/xr819
FW_CACHE=/build/firmware/xr819
fw_missing=0
for f in boot_xr819.bin fw_xr819.bin sdd_xr819.bin; do
    if [ -s "$FW_CACHE/$f" ]; then
        cp "$FW_CACHE/$f" "/lib/firmware/xr819/$f"
        echo "  ✓ $f ($(stat -c%s "/lib/firmware/xr819/$f") 字节)"
    else
        echo "  ✗ $f 缺失"
        fw_missing=1
    fi
done
# 固件缺失会让 WiFi 直接失效（驱动报 error -2），必须让构建失败而不是静默继续
[ "$fw_missing" = 0 ] || {
    echo "XR819 固件不完整，请先执行 make fetch 把它下载到 $FW_CACHE" >&2
    exit 1
}

# 实测 xradio_wlan 会写坏内核内存（先是 clk_core_prepare 拿到野指针，
# 后是 SLUB obj_stock 被破坏直接 kernel panic），所以**默认不自动加载**：
# 开机保持干净，需要 WiFi 时用 `sudo wifi` 显式 modprobe。
#
# 注意：blacklist 只拦截 udev / alias 触发的自动加载，
# 显式 `modprobe xradio_wlan` 依然有效，所以 wifi 命令不受影响。
rm -f /etc/modules-load.d/xradio.conf
cat > /etc/modprobe.d/blacklist-xradio.conf <<'EOF'
# XR819 的 out-of-tree 驱动已知会破坏内核内存（实测会 kernel panic）。
# 默认不自动加载；需要 WiFi 时执行:  sudo wifi "SSID" "密码"
# 它内部会显式 modprobe，不受这里影响。
blacklist xradio_wlan
EOF

# ---------------------------------------------------------------------------
log "一键联网命令 wukongpi-wifi"
# ---------------------------------------------------------------------------
if [ -f /tmp/wukongpi-wifi ]; then
    install -m 0755 /tmp/wukongpi-wifi /usr/local/sbin/wukongpi-wifi
    ln -sf /usr/local/sbin/wukongpi-wifi /usr/local/bin/wifi
    echo "  ✓ /usr/local/sbin/wukongpi-wifi（别名 wifi）"
else
    echo "  ! 没找到 wukongpi-wifi，跳过"
fi

# ---------------------------------------------------------------------------
log "zram（512MB 内存下很有用）"
# ---------------------------------------------------------------------------
cat > /etc/systemd/zram-generator.conf <<'EOF'
[zram0]
zram-size = min(ram, 512)
compression-algorithm = lz4
EOF

# ---------------------------------------------------------------------------
log "首次开机自动把根分区撑满整张 TF 卡"
# ---------------------------------------------------------------------------
# 分两阶段做，避免在「根分区已挂载」的状态下重写分区表：
#   第一次开机: growpart 撑大分区表 -> 重启一次，让内核干净地重新读取
#   第二次开机: resize2fs 扩文件系统 -> 写完成标记
install -m 0755 /dev/stdin /usr/local/sbin/growrootfs <<'EOF'
#!/bin/sh
# 把 rootfs 分区扩到 TF 卡末尾。
#
# 为什么不一步做完：growpart 会重写分区表，而这时 mmcblk0p2 正被当作根分区
# 挂载使用，内核重读分区表可能失败、甚至把兄弟分区（mmcblk0p1）的设备节点
# 摘掉。所以先只改分区表并重启，下次开机分区表已是干净状态，再扩文件系统。
set -u

DEV=/dev/mmcblk0
PART=2
PART_MARK=/var/lib/growrootfs.partition-done
FS_MARK=/var/lib/growrootfs.done

# ---- 阶段 1：撑大分区表 ----
if [ ! -e "$PART_MARK" ]; then
    if growpart "$DEV" "$PART" >/dev/null 2>&1; then
        # growpart 返回 0 = 分区表确实变了，需要重启让内核重新读取
        touch "$PART_MARK"
        sync
        echo "growrootfs: 分区表已扩展，重启一次以重新读取分区表" > /dev/console 2>/dev/null || true
        systemctl reboot
        exit 0
    fi
    # 返回非 0 = 本来就已经是最大（比如重烧到同一张已扩容的卡），继续往下
    touch "$PART_MARK"
fi

# ---- 阶段 2：扩文件系统 ----
if resize2fs "${DEV}p${PART}" >/dev/null 2>&1; then
    touch "$FS_MARK"
fi

exit 0
EOF

cat > /etc/systemd/system/growrootfs.service <<'EOF'
[Unit]
Description=Expand root filesystem to fill the SD card (first boot only)
DefaultDependencies=no
ConditionPathExists=!/var/lib/growrootfs.done
After=local-fs.target
Requires=local-fs.target
Conflicts=shutdown.target
Before=shutdown.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/growrootfs

[Install]
WantedBy=sysinit.target
EOF
enable_unit growrootfs.service sysinit.target

# ---------------------------------------------------------------------------
log "收尾清理"
# ---------------------------------------------------------------------------
rm -rf /tmp/* /var/tmp/*
rm -f /.dockerenv 2>/dev/null || true

log "rootfs 配置完成"
