#!/usr/bin/env bash
#
# 制作根文件系统（宿主机执行）
#
# 用 `--platform linux/arm/v7` 起一个 armhf 容器：Docker Desktop 自带 qemu 模拟，
# 于是在里面 apt 装出来的就是原生 armhf 用户态，不需要特权、不需要 chroot、
# 不需要注册 binfmt。
#
# 分两阶段并做缓存：
#   stage1  装软件包（qemu 下十几分钟）→ docker commit 成 wukongpi-rootfs:<rel>-stage1
#   stage2  系统配置 + 打包（很快）
# 改配置脚本后重跑只会执行 stage2。
#
# 产物：构建卷里的 /build/out/rootfs/rootfs.tar
#
set -euo pipefail

HOST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# 注意：不要叫 PROJECT_DIR，configs/versions.env 里那个是容器内路径 /project
SRC_ROOT="$(cd "$HOST_DIR/../.." && pwd)"
# shellcheck source=/dev/null
source "$SRC_ROOT/configs/versions.env"

BUILD_VOLUME="${BUILD_VOLUME:-wukongpi-build}"
ROOTFS_BASE_TAG="${ROOTFS_BASE_TAG:-wukongpi-base:${ROOTFS_RELEASE}}"
STAGE1_TAG="${ROOTFS_STAGE1_TAG:-wukongpi-rootfs:${ROOTFS_RELEASE}-stage1}"
ROOTFS_APT_MIRROR="${ROOTFS_APT_MIRROR:-${APT_MIRROR:-mirrors.ustc.edu.cn}}"
KEEP_ON_FAIL="${KEEP_ON_FAIL:-0}"

CID1="wukongpi-rootfs1-$$"
CID2="wukongpi-rootfs2-$$"

log() { printf '\n\033[1;32m==>\033[0m %s\n' "$*"; }
die() { printf '\n\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

# 只实现了 Debian。明确拒绝其它取值，而不是静默跑出一个坏 rootfs。
case "${ROOTFS_DISTRO:-debian}" in
    debian) ;;
    *) die "ROOTFS_DISTRO=${ROOTFS_DISTRO} 暂不支持。
本项目目前只实现 Debian armhf（ROOTFS_RELEASE 可选 bookworm / trixie / bullseye）。
换发行版需要改 apt 源格式、包名和部分系统配置，不是改一个变量就行。" ;;
esac

cleanup() {
    local rc=$?
    docker rm -f "$CID1" >/dev/null 2>&1 || true
    if [ "$rc" -ne 0 ] && [ "$KEEP_ON_FAIL" = "1" ]; then
        printf '\n\033[1;33m[i]\033[0m 容器 %s 保留着，可进去排查：\n' "$CID2"
        printf '    docker exec -it %s bash\n' "$CID2"
        printf '    完事后 docker rm -f %s\n\n' "$CID2"
    else
        docker rm -f "$CID2" >/dev/null 2>&1 || true
    fi
}
trap cleanup EXIT

docker volume inspect "$BUILD_VOLUME" >/dev/null 2>&1 || docker volume create "$BUILD_VOLUME" >/dev/null

is_armhf() {
    docker image inspect "$1" >/dev/null 2>&1 || return 1
    [ "$(docker image inspect "$1" --format '{{.Architecture}}')" = "arm" ]
}

# ---------------------------------------------------------------- 基础镜像
BASE_IMG=""
for ref in "${ROOTFS_BASE_IMAGE:-}" "$ROOTFS_BASE_TAG"; do
    [ -n "$ref" ] || continue
    if is_armhf "$ref"; then BASE_IMG="$ref"; break; fi
done
if [ -z "$BASE_IMG" ]; then
    log "本地没有 armhf 基础镜像，尝试拉取"
    "$HOST_DIR/fetch-base-image.sh"
    BASE_IMG="$ROOTFS_BASE_TAG"
fi

# ---------------------------------------------------------------- stage1：装包
if is_armhf "$STAGE1_TAG" && \
   docker run --rm --platform linux/arm/v7 "$STAGE1_TAG" \
        test -f /opt/wukongpi-packages-installed >/dev/null 2>&1; then
    log "复用已缓存的软件包层: $STAGE1_TAG"
else
    log "stage1：安装软件包（基于 ${BASE_IMG}，qemu 模拟下较慢）"
    docker rm -f "$CID1" >/dev/null 2>&1 || true
    docker run -d --name "$CID1" --platform linux/arm/v7 \
        "$BASE_IMG" sleep infinity >/dev/null

    arch="$(docker exec "$CID1" dpkg --print-architecture)"
    [ "$arch" = "armhf" ] || die "容器架构不对: ${arch}（需要 armhf）"

    docker cp "$SRC_ROOT/board/rootfs/01-install-packages.sh" "$CID1:/tmp/"
    docker exec \
        -e APT_MIRROR="$ROOTFS_APT_MIRROR" \
        -e ROOTFS_RELEASE="$ROOTFS_RELEASE" \
        "$CID1" bash /tmp/01-install-packages.sh

    log "提交为 ${STAGE1_TAG}（下次可直接复用）"
    docker commit "$CID1" "$STAGE1_TAG" >/dev/null
    docker rm -f "$CID1" >/dev/null 2>&1 || true
fi

# ---------------------------------------------------------------- stage2：配置 + 打包
log "stage2：系统配置"
docker rm -f "$CID2" >/dev/null 2>&1 || true
docker run -d --name "$CID2" --platform linux/arm/v7 \
    -v "${BUILD_VOLUME}:/build" \
    "$STAGE1_TAG" sleep infinity >/dev/null

docker cp "$SRC_ROOT/board/rootfs/02-configure-system.sh" "$CID2:/tmp/"
docker cp "$SRC_ROOT/board/rootfs/wukongpi-wifi" "$CID2:/tmp/"
docker exec \
    -e ROOTFS_RELEASE="$ROOTFS_RELEASE" \
    -e ROOTFS_HOSTNAME="$ROOTFS_HOSTNAME" \
    -e ROOTFS_USER="$ROOTFS_USER" \
    -e ROOTFS_PASSWORD="$ROOTFS_PASSWORD" \
    -e ROOTFS_ROOT_PASSWORD="$ROOTFS_ROOT_PASSWORD" \
    -e ROOTFS_TIMEZONE="$ROOTFS_TIMEZONE" \
    "$CID2" bash /tmp/02-configure-system.sh

log "打包 rootfs（排除挂载点与临时目录）"
docker exec "$CID2" sh -c '
    set -e
    mkdir -p /build/out/rootfs
    # --xattrs 必须显式写出，否则扩展属性会被静默丢掉。
    # Debian 的 ping / arping 等正是靠 security.capability 扩展属性
    # 给普通用户原始套接字权限的，丢了之后非 root 用户 ping 就会失败。
    tar -C / \
        --xattrs --xattrs-include="*" \
        --exclude=./build \
        --exclude=./project \
        --exclude=./proc \
        --exclude=./sys \
        --exclude=./dev \
        --exclude=./run \
        --exclude=./tmp \
        -cpf /build/out/rootfs/rootfs.tar .
'

log "校验产物"
docker run --rm -v "${BUILD_VOLUME}:/build" "$BUILD_IMAGE" sh -c '
    tar -tf /build/out/rootfs/rootfs.tar | head -5
    echo "..."
    du -sh /build/out/rootfs/rootfs.tar
    # 回归防线：扩展属性一旦丢失，非 root 用户就没法 ping。
    # rootfs 里没有任何地方设置 ping_group_range（内核默认 "1 0"，谁都不许用
    # 无特权 ICMP 套接字），所以普通用户完全依赖 security.capability。
    n=$(grep -a -o "SCHILY.xattr.security.capability" /build/out/rootfs/rootfs.tar | wc -l)
    echo "扩展属性 security.capability 记录数: $n"
    [ "$n" -gt 0 ] || echo "[x] 扩展属性丢失 —— 非 root 用户 ping 会失败"
'

log "rootfs 制作完成 -> /build/out/rootfs/rootfs.tar"
