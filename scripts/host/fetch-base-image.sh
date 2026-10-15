#!/usr/bin/env bash
#
# 准备 rootfs 用的 armhf 基础镜像，并统一打上 wukongpi-base:<release> 标签。
#
# 为什么要单独一个标签：Docker 老式镜像存储「一个 tag 只对应一个平台」，
# 直接用 debian:bookworm-slim 拉 arm/v7 会把本地 amd64 的那份覆盖掉。
# 单独打标签之后，编译容器和 rootfs 容器互不干扰。
#
set -euo pipefail

HOST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_ROOT="$(cd "$HOST_DIR/../.." && pwd)"
# shellcheck source=/dev/null
source "$SRC_ROOT/configs/versions.env"

RELEASE="${ROOTFS_RELEASE:-bookworm}"
TARGET="${ROOTFS_BASE_TAG:-wukongpi-base:$RELEASE}"

log() { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

# 若已存在且确实是 armhf，直接复用
if docker image inspect "$TARGET" >/dev/null 2>&1; then
    if [ "$(docker image inspect "$TARGET" --format '{{.Architecture}}')" = "arm" ]; then
        log "已存在可用的 armhf 基础镜像: $TARGET"
        exit 0
    fi
    docker rmi -f "$TARGET" >/dev/null 2>&1 || true
fi

# 优先用镜像站（独立 repo 路径，不会覆盖官方 tag）
CANDIDATES=(
    "docker.m.daocloud.io/library/debian:${RELEASE}-slim"
    "docker.1ms.run/library/debian:${RELEASE}-slim"
    "dockerproxy.net/library/debian:${RELEASE}-slim"
    "debian:${RELEASE}-slim"
)

log "拉取 armhf 基础镜像 ($RELEASE)"
for ref in "${CANDIDATES[@]}"; do
    for attempt in 1 2 3; do
        log "  $ref (第 $attempt 次)"
        if docker pull --platform linux/arm/v7 "$ref" >/dev/null 2>&1; then
            docker tag "$ref" "$TARGET"
            log "完成: $ref -> $TARGET"
            exit 0
        fi
        sleep 5
    done
done

die "所有镜像源都拉不到 $RELEASE 的 armhf 基础镜像。
可以手动处理，例如：
    docker pull --platform linux/arm/v7 debian:${RELEASE}-slim
    docker tag debian:${RELEASE}-slim $TARGET
或在 configs/versions.env 里设置 ROOTFS_BASE_IMAGE 指向已有的 armhf 镜像。"
