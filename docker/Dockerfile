#
# 悟空派 H3 Zero (Allwinner H3 / sun8i) 交叉编译环境
#
#   docker build -t wukongpi-build:latest docker/
#
# 可选构建参数:
#   --build-arg APT_MIRROR=mirrors.tuna.tsinghua.edu.cn   # 国内加速
#   --build-arg APT_MIRROR=                               # 使用 Debian 官方源
#
ARG DEBIAN_RELEASE=bookworm
ARG APT_MIRROR=mirrors.ustc.edu.cn
FROM debian:${DEBIAN_RELEASE}-slim

ARG APT_MIRROR

LABEL org.opencontainers.image.title="wukongpi-build" \
      org.opencontainers.image.description="Cross toolchain for WukongPi H3 Zero (Allwinner sun8i H3)" \
      org.opencontainers.image.licenses="MIT"

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    ARCH=arm \
    CROSS_COMPILE=arm-linux-gnueabihf- \
    APT_OPTS="-o Acquire::Retries=5 -o Acquire::http::Timeout=60"

# ccache 通过 /usr/lib/ccache 下的符号链接生效, 必须排在 PATH 最前面
ENV PATH=/usr/lib/ccache:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# ---- 可选：切换到国内镜像源 ----
RUN set -eux; \
    if [ -n "${APT_MIRROR}" ]; then \
        find /etc/apt \( -name '*.list' -o -name '*.sources' \) -type f -print0 \
            | xargs -0 -r sed -i \
                -e "s|https\?://deb.debian.org|http://${APT_MIRROR}|g" \
                -e "s|https\?://security.debian.org|http://${APT_MIRROR}|g"; \
        grep -rhE '^(URIs|deb )' /etc/apt/sources.list /etc/apt/sources.list.d/ 2>/dev/null || true; \
    fi

# ---- 1. 基础工具链 + 内核/U-Boot 编译依赖 ----
RUN apt-get $APT_OPTS update && apt-get $APT_OPTS install -y --no-install-recommends \
        build-essential bc bison flex \
        libssl-dev libelf-dev libncurses-dev libgnutls28-dev \
        device-tree-compiler u-boot-tools \
        python3 python3-dev python3-setuptools python3-pip python3-venv \
        python3-pyelftools swig \
        git ca-certificates wget curl aria2 openssh-client \
        xz-utils zstd lz4 bzip2 pigz \
        rsync cpio kmod file locales sudo vim less tree jq \
        crossbuild-essential-armhf \
        ccache \
    && rm -rf /var/lib/apt/lists/*

# ---- 2. 镜像制作工具 (全程不需要 loop 设备) ----
RUN apt-get $APT_OPTS update && apt-get $APT_OPTS install -y --no-install-recommends \
        parted fdisk dosfstools e2fsprogs mtools uuid-runtime fakeroot bmap-tools \
    && rm -rf /var/lib/apt/lists/*

# ---- 3. rootfs 制作工具 (在 linux/arm/v7 容器里原生执行) ----
RUN apt-get $APT_OPTS update && apt-get $APT_OPTS install -y --no-install-recommends \
        debootstrap \
    && rm -rf /var/lib/apt/lists/*

# ---- 4. sunxi-fel / sunxi-tools, 用于 FEL 启动与 SPI NOR 烧写 ----
#      属于可选增强：GitHub 抽风时跳过，不影响固件编译
RUN apt-get $APT_OPTS update && apt-get $APT_OPTS install -y --no-install-recommends \
        libusb-1.0-0-dev libusb-1.0-0 zlib1g-dev pkg-config libfdt-dev \
    && rm -rf /var/lib/apt/lists/*

RUN set -eux; \
    ok=0; \
    for url in \
        https://github.com/linux-sunxi/sunxi-tools \
        https://gh-proxy.com/https://github.com/linux-sunxi/sunxi-tools \
    ; do \
        if timeout 150 git -c http.lowSpeedLimit=10000 -c http.lowSpeedTime=25 \
                clone --depth 1 "$url" /opt/sunxi-tools 2>/dev/null; then ok=1; break; fi; \
        rm -rf /opt/sunxi-tools; \
    done; \
    if [ "$ok" = 1 ]; then \
        if make -C /opt/sunxi-tools -j"$(nproc)" && make -C /opt/sunxi-tools install PREFIX=/usr/local; then \
            rm -rf /opt/sunxi-tools/.git; \
            command -v sunxi-fel; \
        else \
            echo "警告: sunxi-tools 编译失败，sunxi-fel 不可用"; \
        fi; \
    else \
        echo "警告: sunxi-tools 源码下载失败，sunxi-fel 不可用（不影响固件编译）"; \
    fi; \
    true

# ccache 需要在 PATH 最前面提供交叉编译器的符号链接。
# 由于 ccache 与工具链是同一条 apt 命令安装的，这里显式补一遍。
RUN for t in gcc g++ cpp; do \
        ln -sf /usr/bin/ccache "/usr/lib/ccache/arm-linux-gnueabihf-$t"; \
    done; \
    ls -l /usr/lib/ccache/ | head

RUN sed -i 's/^# *en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen && locale-gen

WORKDIR /build
