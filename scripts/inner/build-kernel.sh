#!/usr/bin/env bash
#
# 编译主线 Linux 内核（zImage + 板级设备树 + 模块）
#
set -euo pipefail
# shellcheck source=/dev/null
source /project/scripts/inner/env.sh

[ -f "$LINUX_SRC/Makefile" ] || die "内核源码不存在，请先执行 make fetch"

# ---- 1. 放入板级设备树 ----
DTS_DIR="$LINUX_SRC/arch/arm/boot/dts/allwinner"
[ -d "$DTS_DIR" ] || die "找不到 $DTS_DIR"
cp "$PROJECT_DIR/board/dts/${BOARD_DTS}.dts" "$DTS_DIR/"
ensure_line "$DTS_DIR/Makefile" "dtb-\$(CONFIG_ARCH_SUNXI) += ${BOARD_DTS}.dtb"

# ---- 2. 生成 .config：sunxi_defconfig + 本项目片段 ----
step "配置内核 (sunxi_defconfig + wukongpi.fragment)"
make -C "$LINUX_SRC" sunxi_defconfig
"$LINUX_SRC/scripts/kconfig/merge_config.sh" -m -O "$LINUX_SRC" \
    "$LINUX_SRC/.config" "$PROJECT_DIR/configs/linux/wukongpi.fragment" >/dev/null
make -C "$LINUX_SRC" olddefconfig >/dev/null

# 关键项校验，避免 WiFi / 容器支持静默丢失
for sym in CONFIG_CFG80211 CONFIG_MAC80211 CONFIG_OVERLAY_FS CONFIG_MEMCG CONFIG_BRIDGE; do
    grep -q "^${sym}=[ym]" "$LINUX_SRC/.config" \
        || warn "$sym 未启用（xradio WiFi / 容器功能可能不可用）"
done
grep -q '^CONFIG_MODULES=y' "$LINUX_SRC/.config" || die "内核模块支持被关闭，无法编译 xradio"

KVER="$(make -s -C "$LINUX_SRC" kernelrelease | tail -1)"
log "内核版本: $KVER"

# ---- 3. 编译 ----
# 注意：内核的 %.dtb 规则要求目标路径相对于 arch/arm/boot/dts/，
# 所以这里写 allwinner/xxx.dtb，不能写完整路径。
step "编译 zImage / dtb (-j$KERNEL_JOBS)"
make -C "$LINUX_SRC" -j"$KERNEL_JOBS" zImage "allwinner/${BOARD_DTS}.dtb"

step "编译内核模块 (-j$KERNEL_JOBS)"
make -C "$LINUX_SRC" -j"$KERNEL_JOBS" modules

# 为 xradio 这类外部模块准备好环境
make -C "$LINUX_SRC" modules_prepare >/dev/null 2>&1 || true

# ---- 4. 收集产物 ----
step "安装内核与模块"
OUT="$OUT_DIR/kernel"
rm -rf "$OUT"; mkdir -p "$OUT"

cp -v "$LINUX_SRC/arch/arm/boot/zImage"                        "$OUT/zImage"
cp -v "$LINUX_SRC/arch/arm/boot/dts/allwinner/${BOARD_DTS}.dtb" "$OUT/"
cp -v "$LINUX_SRC/System.map"                                   "$OUT/"
cp -v "$LINUX_SRC/.config"                                      "$OUT/kernel.config"
echo "$KVER" > "$OUT/kernel.release"

rm -rf "$OUT/modules"
make -C "$LINUX_SRC" modules_install \
    INSTALL_MOD_PATH="$OUT/modules" \
    INSTALL_MOD_STRIP=1 >/dev/null

KMOD_COUNT="$(find "$OUT/modules" -name '*.ko' | wc -l | tr -d ' ')"
log "内核版本 ${KVER}，模块数量: $KMOD_COUNT"

# 模块目录文件太碎，打成 tar 再导出，避免 bind mount 上复制几千个小文件
tar -czf "$OUT/modules.tar.gz" -C "$OUT/modules" .

# ---- 5. 导出小体积产物到宿主机 ./out ----
publish kernel/zImage
publish "kernel/${BOARD_DTS}.dtb"
publish kernel/System.map
publish kernel/kernel.config
publish kernel/kernel.release
publish kernel/modules.tar.gz

log "内核编译完成 -> $OUT"
