#!/usr/bin/env bash
#
# 拉取 / 校验上游源码（Linux 内核、U-Boot、xradio WiFi 驱动）
#
# 默认走国内镜像的 tar 包（比 git clone 快得多），失败自动回退。
#   FETCH_METHOD=git  ./scripts/host/run.sh /project/scripts/inner/fetch-sources.sh
#
set -euo pipefail
# shellcheck source=/dev/null
source /project/scripts/inner/env.sh

FETCH_METHOD="${FETCH_METHOD:-tarball}"

linux_tree_version() {
    [ -f "$LINUX_SRC/Makefile" ] || return 1
    awk -F' = ' '
        /^VERSION =/    { v = $2 }
        /^PATCHLEVEL =/ { p = $2 }
        /^SUBLEVEL =/   { s = $2 }
        END { if (v != "" && p != "" && s != "") printf "%s.%s.%s\n", v, p, s }
    ' "$LINUX_SRC/Makefile"
}

# ---------------------------------------------------------------- Linux
fetch_linux() {
    local want="${LINUX_VERSION#v}" have
    have="$(linux_tree_version || true)"
    if [ "$have" = "$want" ]; then
        log "Linux 源码已就绪 ($LINUX_SRC @ $have)"
        return 0
    fi
    [ -n "$have" ] && warn "现有内核源码版本为 ${have}，需要 ${want}，重新拉取"

    local major minor
    major="${want%%.*}"; minor="${want#*.}"; minor="${minor%%.*}"
    local tarball="linux-${want}.tar.xz"
    local urls=()
    [ -n "${LINUX_MIRROR:-}" ] && urls+=("${LINUX_MIRROR%/}/$tarball")
    urls+=(
        "https://mirrors.aliyun.com/linux-kernel/v${major}.x/$tarball"
        "https://mirrors.tuna.tsinghua.edu.cn/kernel/v${major}.x/$tarball"
        "https://mirrors.ustc.edu.cn/kernel.org/linux/kernel/v${major}.x/$tarball"
        "https://cdn.kernel.org/pub/linux/kernel/v${major}.x/$tarball"
        "https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git/snapshot/linux-${want}.tar.gz"
    )

    rm -rf "$LINUX_SRC"; mkdir -p "$LINUX_SRC"

    if [ "$FETCH_METHOD" != "git" ]; then
        local file
        if file="$(download_first "$DOWNLOADS_DIR" "${urls[@]}")"; then
            log "解压 $(basename "$file")"
            extract_tarball "$file" "$LINUX_SRC"
            [ -f "$LINUX_SRC/Makefile" ] || die "解压后没找到内核 Makefile"
            log "Linux 源码就绪: $LINUX_SRC ($(linux_tree_version))"
            return 0
        fi
        warn "所有 tar 镜像都失败，回退到 git clone"
    fi

    log "git clone $LINUX_REPO ($LINUX_VERSION)"
    git clone --depth 1 --branch "$LINUX_VERSION" "$LINUX_REPO" "$LINUX_SRC" \
        || git clone --depth 1 --branch "$LINUX_VERSION" \
               https://github.com/torvalds/linux "$LINUX_SRC"
}

# ---------------------------------------------------------------- U-Boot
fetch_uboot() {
    local want="${UBOOT_VERSION#v}" have=""
    if [ -f "$UBOOT_SRC/Makefile" ]; then
        have="$(sed -n 's/^VERSION = //p' "$UBOOT_SRC/Makefile" | head -1).$(sed -n 's/^PATCHLEVEL = //p' "$UBOOT_SRC/Makefile" | head -1)"
    fi
    if [ "$have" = "$want" ]; then
        log "U-Boot 源码已就绪 ($UBOOT_SRC @ v$have)"
        return 0
    fi

    local urls=()
    [ -n "${UBOOT_MIRROR:-}" ] && urls+=("$UBOOT_MIRROR")
    urls+=(
        "https://github.com/u-boot/u-boot/archive/refs/tags/${UBOOT_VERSION}.tar.gz"
        "https://gh-proxy.com/https://github.com/u-boot/u-boot/archive/refs/tags/${UBOOT_VERSION}.tar.gz"
        "https://gitcode.com/gh_mirrors/ub/u-boot/archive/refs/tags/${UBOOT_VERSION}.tar.gz"
        "https://ftp.denx.de/pub/u-boot/u-boot-${want}.tar.bz2"
    )

    rm -rf "$UBOOT_SRC"; mkdir -p "$UBOOT_SRC"

    if [ "$FETCH_METHOD" != "git" ]; then
        local file
        if file="$(download_first "$DOWNLOADS_DIR" "${urls[@]}")"; then
            log "解压 $(basename "$file")"
            extract_tarball "$file" "$UBOOT_SRC"
            log "U-Boot 源码就绪: $UBOOT_SRC"
            return 0
        fi
        warn "所有 tar 镜像都失败，回退到 git clone"
    fi

    log "git clone $UBOOT_REPO ($UBOOT_VERSION)"
    git clone --depth 1 --branch "$UBOOT_VERSION" "$UBOOT_REPO" "$UBOOT_SRC"
}

# ---------------------------------------------------------------- xradio (XR819 WiFi)
fetch_xradio() {
    local marker="$XRADIO_SRC/.xradio-branch"
    if [ -f "$XRADIO_SRC/Kconfig" ] && [ -f "$marker" ] \
       && [ "$(cat "$marker" 2>/dev/null)" = "$XRADIO_VERSION" ]; then
        log "xradio 源码已就绪（分支 $XRADIO_VERSION）"
        return 0
    fi
    rm -rf "$XRADIO_SRC"; mkdir -p "$XRADIO_SRC"

    local urls=(
        "https://gh-proxy.com/https://github.com/fifteenhex/xradio/archive/refs/heads/${XRADIO_VERSION}.tar.gz"
        "https://github.com/fifteenhex/xradio/archive/refs/heads/${XRADIO_VERSION}.tar.gz"
    )
    local file
    if file="$(download_first "$DOWNLOADS_DIR" "${urls[@]}")"; then
        extract_tarball "$file" "$XRADIO_SRC"
        echo "$XRADIO_VERSION" > "$marker"
        log "xradio 源码就绪: $XRADIO_SRC（分支 $XRADIO_VERSION）"
        return 0
    fi

    warn "tar 下载失败，回退到 git clone"
    rm -rf "$XRADIO_SRC"
    git clone --depth 1 --branch "$XRADIO_VERSION" "$XRADIO_REPO" "$XRADIO_SRC"
    echo "$XRADIO_VERSION" > "$XRADIO_SRC/.xradio-branch"
}

# ---------------------------------------------------------------- XR819 固件
#
# 固件缓存到构建卷里，只下载一次。下载不到就**直接让构建失败**——
# 之前这里只打警告，结果镜像里固件目录是空的，WiFi 静默失效。
fetch_xr819_firmware() {
    local dir="$BUILD_DIR/firmware/xr819"
    mkdir -p "$dir"

    # 参考大小：boot=2308  fw=130472  sdd=744
    local bases=(
        "https://raw.githubusercontent.com/armbian/firmware/master/xr819"
        "https://gh-proxy.com/https://raw.githubusercontent.com/armbian/firmware/master/xr819"
    )

    local f base size ok
    for f in boot_xr819.bin fw_xr819.bin sdd_xr819.bin; do
        size="$(stat -c%s "$dir/$f" 2>/dev/null || echo 0)"
        if [ "$size" -gt 100 ]; then
            log "固件已缓存: $f ($size 字节)"
            continue
        fi

        ok=0
        for base in "${bases[@]}"; do
            log "下载固件 $f"
            if curl -fSL --retry 3 --retry-delay 2 --connect-timeout 20 \
                    -o "$dir/$f.part" "$base/$f" 2>/dev/null; then
                size="$(stat -c%s "$dir/$f.part" 2>/dev/null || echo 0)"
                if [ "$size" -gt 100 ]; then
                    mv "$dir/$f.part" "$dir/$f"
                    log "  ✓ $f ($size 字节)"
                    ok=1
                    break
                fi
                warn "  $f 大小异常 ($size 字节)，换下一个源"
            fi
            rm -f "$dir/$f.part"
        done

        [ "$ok" = 1 ] || die "XR819 固件 $f 下载失败。

WiFi 会因此不可用，所以这里直接中断。手动处理方式：
  1. 从 https://github.com/armbian/firmware/tree/master/xr819 下载三个文件
  2. 放到 $dir/
  3. 重新执行 make fetch"
    done

    ls -l "$dir" | sed 's/^/    /'
}

step "拉取上游源码"
fetch_linux
fetch_uboot
fetch_xradio
fetch_xr819_firmware

# 保留未被修改的原始文件，供 gen-patches.sh 生成上游补丁
step "保存原始文件（用于生成补丁）"
mkdir -p "$BUILD_DIR/pristine"
cp -a "$LINUX_SRC/arch/arm/boot/dts/allwinner/Makefile" \
      "$BUILD_DIR/pristine/linux-allwinner-Makefile"
if [ -f "$UBOOT_SRC/dts/upstream/src/arm/allwinner/Makefile" ]; then
    cp -a "$UBOOT_SRC/dts/upstream/src/arm/allwinner/Makefile" \
          "$BUILD_DIR/pristine/uboot-allwinner-Makefile"
    echo "uboot-dts-path=dts/upstream/src/arm/allwinner" > "$BUILD_DIR/pristine/uboot-dts-path"
else
    cp -a "$UBOOT_SRC/arch/arm/dts/Makefile" "$BUILD_DIR/pristine/uboot-allwinner-Makefile"
    echo "uboot-dts-path=arch/arm/dts" > "$BUILD_DIR/pristine/uboot-dts-path"
fi

step "源码准备完成"
du -sh "$LINUX_SRC" "$UBOOT_SRC" "$XRADIO_SRC" 2>/dev/null || true
