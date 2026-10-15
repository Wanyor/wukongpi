#!/usr/bin/env bash
#
# 在交叉编译容器里执行一条命令。
# 这是所有「容器内脚本」的唯一入口，负责挂载与参数透传。
#
#   ./scripts/host/run.sh /project/scripts/inner/build-kernel.sh
#
# 环境变量：
#   BUILD_IMAGE   镜像名（默认 wukongpi-build:latest）
#   BUILD_VOLUME  构建卷名（默认 wukongpi-build）
#
set -euo pipefail

HOST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# 注意：不要叫 PROJECT_DIR，configs/versions.env 里那个是容器内路径 /project
SRC_ROOT="$(cd "$HOST_DIR/../.." && pwd)"

# shellcheck source=/dev/null
source "$SRC_ROOT/configs/versions.env"

BUILD_IMAGE="${BUILD_IMAGE:-wukongpi-build:latest}"
BUILD_VOLUME="${BUILD_VOLUME:-wukongpi-build}"

if ! docker image inspect "$BUILD_IMAGE" >/dev/null 2>&1; then
    echo "==> 构建镜像不存在，先执行: make docker" >&2
    exit 1
fi

docker volume inspect "$BUILD_VOLUME" >/dev/null 2>&1 || docker volume create "$BUILD_VOLUME" >/dev/null

# bash 3.2 在 set -u 下展开空数组会报错，统一用 ${arr[@]+...} 写法
TTY_FLAGS=()
if [ -t 0 ] && [ -t 1 ]; then
    TTY_FLAGS=(-t)
fi

# 允许从宿主机覆盖这些变量
FORWARD_VARS=(
    LINUX_VERSION LINUX_REPO UBOOT_VERSION UBOOT_REPO XRADIO_VERSION XRADIO_REPO
    ROOTFS_RELEASE ROOTFS_MIRROR ROOTFS_HOSTNAME ROOTFS_USER ROOTFS_PASSWORD
    ROOTFS_ROOT_PASSWORD ROOTFS_TIMEZONE
    IMAGE_SIZE_MB BOOT_SIZE_MB UBOOT_SPL_SEEK_KB
    LINUX_MIRROR UBOOT_MIRROR
    KERNEL_JOBS SKIP_FETCH
)
ENV_ARGS=()
for v in "${FORWARD_VARS[@]}"; do
    if [ -n "${!v:-}" ]; then
        ENV_ARGS+=(-e "$v=${!v}")
    fi
done

exec docker run --rm -i ${TTY_FLAGS[@]+"${TTY_FLAGS[@]}"} \
    -v "$BUILD_VOLUME:/build" \
    -v "$SRC_ROOT:/project" \
    -w /build \
    ${ENV_ARGS[@]+"${ENV_ARGS[@]}"} \
    "$BUILD_IMAGE" "$@"
