#!/usr/bin/env bash
#
# 生成可以直接发给上游的补丁（git apply / patch -p1 都能用）
#
# 原理：fetch 阶段保留了未经改动的原始 Makefile，这里把「原始版本」和
# 「已插入本项目板级内容的版本」分别放进 a/ b/ 两棵目录树做 diff，
# 得到 `--- a/...` / `+++ b/...` 这种 git 标准格式的补丁；
# 新增文件的 `---` 头会被改写成 `/dev/null`，这样 git apply 才认。
#
set -euo pipefail
# shellcheck source=/dev/null
source /project/scripts/inner/env.sh

PRISTINE="$BUILD_DIR/pristine"
WORK="$BUILD_DIR/patchgen"
[ -d "$PRISTINE" ] || die "缺少 ${PRISTINE}，请先执行 make fetch"

rm -rf "$WORK"; mkdir -p "$WORK"

# 把文件放进 a/（原始）或 b/（修改后）；源文件不存在就当作「新增文件」
put() {
    local side="$1" rel="$2" src="$3"
    mkdir -p "$WORK/$side/$(dirname "$rel")"
    [ -f "$src" ] && cp -a "$src" "$WORK/$side/$rel"
    return 0
}

# 新增文件在 GNU diff 里会输出 `--- a/路径`，git apply 不认，改成 /dev/null
normalize_new_files() {
    python3 - "$1" <<'PY'
import sys
path = sys.argv[1]
lines = open(path, encoding='utf-8').read().split('\n')
out, i = [], 0
while i < len(lines):
    cur = lines[i]
    if (cur.startswith('--- ') and i + 2 < len(lines)
            and lines[i + 1].startswith('+++ ')
            and lines[i + 2].startswith('@@ -0,0 ')):
        out.append('--- /dev/null')
        out.append(lines[i + 1])
        out.append(lines[i + 2])
        i += 3
        continue
    out.append(cur)
    i += 1
open(path, 'w', encoding='utf-8').write('\n'.join(out))
PY
}

emit_patch() {  # emit_patch <输出文件>
    local out="$1"
    mkdir -p "$(dirname "$out")"
    (
        cd "$WORK"
        diff -Naur a b > "$out" || true
    )
    [ -s "$out" ] || die "补丁为空: $out"
    normalize_new_files "$out"
    log "-> ${out#"$PROJECT_DIR"/}  ($(grep -c '^+++' "$out") 个文件)"
}

reset_trees() { rm -rf "$WORK/a" "$WORK/b"; mkdir -p "$WORK/a" "$WORK/b"; }

# ---------------------------------------------------------------------------
step "生成 Linux 内核补丁"
# ---------------------------------------------------------------------------
LINUX_MK_REL="arch/arm/boot/dts/allwinner/Makefile"
LINUX_DTS_REL="arch/arm/boot/dts/allwinner/${BOARD_DTS}.dts"

reset_trees
put a "$LINUX_MK_REL"   "$PRISTINE/linux-allwinner-Makefile"
put b "$LINUX_MK_REL"   "$LINUX_SRC/$LINUX_MK_REL"
put b "$LINUX_DTS_REL"  "$LINUX_SRC/$LINUX_DTS_REL"
emit_patch "$PROJECT_DIR/patches/linux/0001-arm-dts-allwinner-add-WukongPi-H3-Zero.patch"

# ---------------------------------------------------------------------------
step "生成 U-Boot 补丁"
# ---------------------------------------------------------------------------
UBOOT_DTS_PATH="$(sed -n 's/^uboot-dts-path=//p' "$PRISTINE/uboot-dts-path")"
[ -n "$UBOOT_DTS_PATH" ] || UBOOT_DTS_PATH="arch/arm/dts"
UBOOT_MK_REL="${UBOOT_DTS_PATH}/Makefile"
UBOOT_DTS_REL="${UBOOT_DTS_PATH}/${BOARD_DTS}.dts"
UBOOT_DEFCONFIG_REL="configs/$(echo "$BOARD_NAME" | tr '-' '_')_defconfig"

reset_trees
put a "$UBOOT_MK_REL"        "$PRISTINE/uboot-allwinner-Makefile"
put b "$UBOOT_MK_REL"        "$UBOOT_SRC/$UBOOT_MK_REL"
put b "$UBOOT_DTS_REL"       "$UBOOT_SRC/$UBOOT_DTS_REL"
put b "$UBOOT_DEFCONFIG_REL" "$UBOOT_SRC/$UBOOT_DEFCONFIG_REL"
emit_patch "$PROJECT_DIR/patches/uboot/0001-sunxi-add-WukongPi-H3-Zero-board.patch"

step "完成"
ls -l "$PROJECT_DIR/patches"/*/*.patch | sed 's/^/    /'
