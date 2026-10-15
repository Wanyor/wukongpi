#!/usr/bin/env bash
#
# 编译主线 U-Boot（SPL + U-Boot + 板级设备树）
#
set -euo pipefail
# shellcheck source=/dev/null
source /project/scripts/inner/env.sh

[ -f "$UBOOT_SRC/Makefile" ] || die "U-Boot 源码不存在，请先执行 make fetch"

DEFCONFIG="$(echo "$BOARD_NAME" | tr '-' '_')_defconfig"

step "配置 U-Boot ($UBOOT_VERSION, $DEFCONFIG)"

# ---- 1. 放入板级 defconfig 并生成 .config ----
cp "$PROJECT_DIR/configs/uboot/$DEFCONFIG" "$UBOOT_SRC/configs/"

make -C "$UBOOT_SRC" "$DEFCONFIG" 2>&1 | tee "$BUILD_DIR/uboot-defconfig.log"
if grep -qiE 'unexpected data|unknown (config|symbol)' "$BUILD_DIR/uboot-defconfig.log"; then
    warn "defconfig 中存在被 Kconfig 忽略的符号，见 $BUILD_DIR/uboot-defconfig.log"
fi

# ---- 2. 决定设备树放哪 ----
# 老版本 U-Boot 用 arch/arm/dts，启用 OF_UPSTREAM 后改用内嵌的上游 dts 副本。
# sunxi（H3）在 v2026.07 上仍然是前者，这里按实际 .config 判断，两种都支持。
if grep -q '^CONFIG_OF_UPSTREAM=y' "$UBOOT_SRC/.config"; then
    DTS_DIR="$UBOOT_SRC/dts/upstream/src/arm/allwinner"
    log "OF_UPSTREAM 已启用，设备树目录: dts/upstream/src/arm/allwinner"
else
    DTS_DIR="$UBOOT_SRC/arch/arm/dts"
    log "OF_UPSTREAM 未启用，设备树目录: arch/arm/dts"
fi
[ -d "$DTS_DIR" ] || die "找不到设备树目录: $DTS_DIR"
DTS_MAKEFILE="$DTS_DIR/Makefile"

# ---- 3. 放入板级设备树，并在 Makefile 里登记 ----
cp "$PROJECT_DIR/board/dts/${BOARD_DTS}.dts" "$DTS_DIR/"

ANCHOR="sun8i-h2-plus-orangepi-zero.dtb"   # 参照同族板子的写法

add_dtb_entry() {
    local mk="$1" anchor="$2" name="$3"
    if grep -qF "${name}.dtb" "$mk"; then
        log "Makefile 中已有 ${name}.dtb，跳过"
        return 0
    fi
    if grep -qF "$anchor" "$mk"; then
        if grep -F "$anchor" "$mk" | grep -q '\\$'; then
            # 跟随既有列表风格：制表符缩进 + 行尾反斜杠续行
            awk -v a="$anchor" -v n="\t${name}.dtb \\" \
                '{ print } index($0, a) && !done { print n; done = 1 }' \
                "$mk" > "$mk.tmp"
        else
            awk -v a="$anchor" -v n="${name}.dtb" \
                '{ print } index($0, a) && !done { print n; done = 1 }' \
                "$mk" > "$mk.tmp"
        fi
        mv "$mk.tmp" "$mk"
        log "已在 $mk 中插入 ${name}.dtb"
    else
        warn "Makefile 里没有参照项 ${anchor}，改为追加一条 dtb- 规则"
        ensure_line "$mk" "dtb-\$(CONFIG_ARCH_SUNXI) += ${name}.dtb"
    fi
}

add_dtb_entry "$DTS_MAKEFILE" "$ANCHOR" "$BOARD_DTS"

# ---- 4. 编译 ----
step "编译 U-Boot (-j$KERNEL_JOBS)"
make -C "$UBOOT_SRC" -j"$KERNEL_JOBS"

# ---- 5. 收集产物 ----
step "收集 U-Boot 产物"
mkdir -p "$OUT_DIR/uboot"

[ -f "$UBOOT_SRC/u-boot-sunxi-with-spl.bin" ] || die "未生成 u-boot-sunxi-with-spl.bin"

# 必须塞进 TF 卡第一个分区之前的空隙（默认 1MiB - 8KiB）
SPL_SIZE=$(stat -c%s "$UBOOT_SRC/u-boot-sunxi-with-spl.bin")
MAX_SIZE=$(( (BOOT_SIZE_MB * 1024 * 1024) - (UBOOT_SPL_SEEK_KB * 1024) ))
log "u-boot-sunxi-with-spl.bin: $(( SPL_SIZE / 1024 )) KiB（上限 $(( MAX_SIZE / 1024 )) KiB）"
[ "$SPL_SIZE" -lt "$MAX_SIZE" ] || die "U-Boot 太大，会覆盖第一个分区"

cp "$UBOOT_SRC/u-boot-sunxi-with-spl.bin" "$OUT_DIR/uboot/"
cp "$UBOOT_SRC/u-boot.bin"                "$OUT_DIR/uboot/"
cp "$UBOOT_SRC/spl/sunxi-spl.bin"         "$OUT_DIR/uboot/" 2>/dev/null || true
cp "$UBOOT_SRC/.config"                   "$OUT_DIR/uboot/config"
cp "$UBOOT_SRC/u-boot.dtb"                "$OUT_DIR/uboot/u-boot.dtb" 2>/dev/null || true

# 板级设备树（U-Boot 自己编译出来的那份）
for cand in "$UBOOT_SRC/${BOARD_DTS}.dtb" \
            "$UBOOT_SRC/dts/${BOARD_DTS}.dtb" \
            "$DTS_DIR/${BOARD_DTS}.dtb"; do
    if [ -f "$cand" ]; then
        cp "$cand" "$OUT_DIR/uboot/${BOARD_DTS}.dtb"
        break
    fi
done
[ -f "$OUT_DIR/uboot/${BOARD_DTS}.dtb" ] \
    || warn "没找到编译出的 U-Boot 设备树，请检查 Makefile 插入是否生效"

# ---- 6. 导出小体积产物到宿主机 ./out ----
publish uboot/u-boot-sunxi-with-spl.bin
publish uboot/u-boot.bin
publish uboot/config
if [ -f "$OUT_DIR/uboot/${BOARD_DTS}.dtb" ]; then
    publish "uboot/${BOARD_DTS}.dtb"
fi

log "U-Boot 编译完成 -> $OUT_DIR/uboot"
