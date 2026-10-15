#!/usr/bin/env bash
#
# 容器内所有脚本共用的环境与工具函数。
#   用法: source /project/scripts/inner/env.sh
#
set -euo pipefail

PROJECT_DIR="${PROJECT_DIR:-/project}"
BUILD_DIR="${BUILD_DIR:-/build}"

# shellcheck source=/dev/null
source "$PROJECT_DIR/configs/versions.env"

export PROJECT_DIR BUILD_DIR
export SOURCES_DIR OUT_DIR LINUX_SRC UBOOT_SRC XRADIO_SRC ROOTFS_DIR
export CROSS_COMPILE ARCH BOARD_NAME BOARD_DTS

export KERNEL_JOBS="${KERNEL_JOBS:-$(nproc)}"
export CCACHE_DIR="$BUILD_DIR/.ccache"
export CCACHE_MAXSIZE="${CCACHE_MAXSIZE:-5G}"
export DOWNLOADS_DIR="$BUILD_DIR/downloads"

mkdir -p "$SOURCES_DIR" "$OUT_DIR" "$DOWNLOADS_DIR" "$CCACHE_DIR"

if [ -t 1 ]; then
    C_RED=$'\033[1;31m'; C_GREEN=$'\033[1;32m'; C_YELLOW=$'\033[1;33m'
    C_BLUE=$'\033[1;34m'; C_OFF=$'\033[0m'
else
    C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""; C_OFF=""
fi

log()  { printf '%s==>%s %s\n' "$C_GREEN" "$C_OFF" "$*"; }
step() { printf '\n%s########  %s%s\n' "$C_BLUE" "$*" "$C_OFF"; }
warn() { printf '%s[!]%s %s\n' "$C_YELLOW" "$C_OFF" "$*" >&2; }
die()  { printf '%s[x]%s %s\n' "$C_RED" "$C_OFF" "$*" >&2; exit 1; }

# 检查宿主机内核版本号，作为 .deb / 镜像文件名的一部分使用
kernel_version_from_tree() {
    local tree="$1"
    make -s -C "$tree" kernelrelease 2>/dev/null | tail -1
}

# 把某个产物从构建卷复制回宿主机 ./out
publish() {
    local rel="$1"
    [ -e "$OUT_DIR/$rel" ] || die "产物不存在: $OUT_DIR/$rel"
    mkdir -p "$PROJECT_DIR/out/$(dirname "$rel")"
    cp -a "$OUT_DIR/$rel" "$PROJECT_DIR/out/$rel"
    log "已导出 -> out/$rel"
}

# 带重试的下载：download_first <保存目录> <url...>
# 成功时把文件路径写到 stdout，其余信息一律走 stderr（否则会被 $(...) 捕获）
#
# 优先用 aria2c 多连接下载 —— 对 GitHub 这类被限速的链路提升非常明显。
download_first() {
    local destdir="$1"; shift
    local url name out
    for url in "$@"; do
        name="$(basename "${url%%\?*}")"
        out="$destdir/$name"

        if [ -s "$out" ] && tar -tf "$out" >/dev/null 2>&1; then
            log "$name 已在缓存中，跳过下载" >&2
            printf '%s\n' "$out"
            return 0
        fi

        log "下载 $name" >&2
        log "  来源: $url" >&2
        rm -f "$out.part" "$out.aria2"

        if command -v aria2c >/dev/null 2>&1; then
            aria2c -x16 -s16 -k1M \
                   --continue=true \
                   --max-tries=20 --retry-wait=5 \
                   --connect-timeout=20 --timeout=60 \
                   --lowest-speed-limit=4K \
                   --summary-interval=20 --console-log-level=warn \
                   --file-allocation=none --auto-file-renaming=false \
                   -d "$destdir" -o "$name" "$url" >&2 || true
        else
            curl -fL --progress-bar --retry 5 --retry-delay 5 --connect-timeout 20 \
                 -C - -o "$out" "$url" >&2 || true
        fi

        if [ -s "$out" ] && tar -tf "$out" >/dev/null 2>&1; then
            log "$name 下载完成（$(du -h "$out" | cut -f1)）" >&2
            printf '%s\n' "$out"
            return 0
        fi

        warn "$name 校验不通过，换下一个源" >&2
        rm -f "$out" "$out.aria2"
    done
    return 1
}

# extract_tarball <压缩包> <目标目录>
extract_tarball() {
    local file="$1" dest="$2"
    mkdir -p "$dest"
    case "$file" in
        *.tar.xz)  tar -xJf "$file" -C "$dest" --strip-components=1 ;;
        *.tar.gz)  tar -xzf "$file" -C "$dest" --strip-components=1 ;;
        *.tar.bz2) tar -xjf "$file" -C "$dest" --strip-components=1 ;;
        *) die "不认识的压缩包格式: $file" ;;
    esac
}

# 在文件里插入一行（若尚不存在）
ensure_line() {
    local file="$1" line="$2"
    grep -qF -- "$line" "$file" || printf '%s\n' "$line" >> "$file"
}
