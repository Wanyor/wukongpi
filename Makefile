# 悟空派 H3 Zero —— 主线 U-Boot + Linux 内核移植
#
# 常用：
#   make image        一站式：拉源码 → 编译 → 做 rootfs → 出可烧录镜像
#   make shell        进入编译容器排查问题
#   make help         查看全部目标
#
SHELL       := /bin/bash
SRC_ROOT    := $(shell pwd)

# configs/versions.env 是 shell 语法（带 ${VAR:-默认值} 的默认值覆盖），
# 不能直接被 Make include。这里用一次子 shell 把里面所有变量导出成
# KEY=VALUE，再喂给 $(eval)，保证 Make 和脚本看到同一份配置。
ENV_KEYS := BUILD_IMAGE BUILD_VOLUME ROOTFS_BASE_TAG BOARD_NAME BOARD_DTS \
            LINUX_VERSION UBOOT_VERSION XRADIO_VERSION \
            ROOTFS_DISTRO ROOTFS_RELEASE ROOTFS_HOSTNAME

ENV_DUMP := $(shell bash -c 'set -a; . configs/versions.env; \
	for v in $(ENV_KEYS); do printf "%s=%s\n" "$$v" "$${!v}"; done')

$(foreach kv,$(ENV_DUMP),$(eval $(kv)))

DOCKER_RUN  := ./scripts/host/run.sh

.DEFAULT_GOAL := help
.PHONY: help all image docker base fetch uboot kernel xradio rootfs sd-image patches \
        shell out flash check clean distclean

help: ## 显示帮助
	@printf '\n\033[1;36m悟空派 H3 Zero 主线移植构建系统\033[0m\n\n'
	@grep -hE '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[1;32m%-14s\033[0m %s\n", $$1, $$2}'
	@printf '\n当前版本：\n'
	@printf '  Linux   : %s\n  U-Boot  : %s\n  rootfs  : %s %s\n  xradio  : %s\n\n' \
		"$(LINUX_VERSION)" "$(UBOOT_VERSION)" "$(ROOTFS_DISTRO)" "$(ROOTFS_RELEASE)" "$(XRADIO_VERSION)"

all: image ## 等价于 make image

image: docker fetch uboot kernel xradio rootfs sd-image ## 一站式生成可烧录镜像
	@printf '\n\033[1;32m✔ 全部完成，镜像在 ./out/\033[0m\n'

docker: ## 构建/更新交叉编译容器镜像
	docker build -t $(BUILD_IMAGE) docker/

base: ## 准备 rootfs 用的 armhf 基础镜像
	./scripts/host/fetch-base-image.sh

fetch: docker ## 拉取 Linux / U-Boot / xradio 源码
	$(DOCKER_RUN) /project/scripts/inner/fetch-sources.sh

uboot: fetch ## 编译 U-Boot
	$(DOCKER_RUN) /project/scripts/inner/build-uboot.sh

kernel: fetch ## 编译内核（zImage + dtb + 模块）
	$(DOCKER_RUN) /project/scripts/inner/build-kernel.sh

xradio: kernel ## 编译 XR819 WiFi 驱动
	$(DOCKER_RUN) /project/scripts/inner/build-xradio.sh

rootfs: ## 制作 Debian armhf 根文件系统（qemu 模拟，较慢）
	./scripts/host/build-rootfs.sh

sd-image: uboot kernel xradio rootfs ## 组装可烧录的 TF 卡镜像
	$(DOCKER_RUN) /project/scripts/inner/mk-sd-image.sh

patches: uboot kernel ## 生成可提交给上游的 git 补丁（写入 ./patches）
	$(DOCKER_RUN) /project/scripts/inner/gen-patches.sh

flash: ## 把 out/ 里最新的镜像烧到 TF 卡（macOS）
	./scripts/host/flash-sd.sh

out: ## 把构建卷里的产物全部同步到 ./out
	mkdir -p out
	docker run --rm -v $(BUILD_VOLUME):/build -v "$(SRC_ROOT)/out:/host-out" \
		$(BUILD_IMAGE) sh -c 'cp -a /build/out/. /host-out/'
	@ls -lh out/

shell: docker ## 进入编译容器（源码在 /build/sources）
	$(DOCKER_RUN) bash

clean: ## 清理产物与中间文件（保留源码）
	$(DOCKER_RUN) sh -c 'rm -rf /build/out /build/stage /build/.ccache'
	rm -rf out

distclean: clean ## 连源码一起删掉
	docker volume rm -f $(BUILD_VOLUME) >/dev/null 2>&1 || true
	rm -rf out

check: ## 检查环境（docker / 模拟 / 空间）
	@printf '== docker ==\n'; docker version --format '  server: {{.Server.Version}}'
	@printf '== 编译镜像 ==\n'
	@docker image inspect "$(BUILD_IMAGE)" >/dev/null 2>&1 \
		&& echo "  ✓ $(BUILD_IMAGE)" || echo "  ✗ 未构建，请执行 make docker"
	@printf '== armhf 模拟（rootfs 用）==\n'
	@if docker image inspect "$(ROOTFS_BASE_TAG)" >/dev/null 2>&1; then \
		docker run --rm --platform linux/arm/v7 "$(ROOTFS_BASE_TAG)" dpkg --print-architecture | sed 's/^/  ✓ /'; \
	else \
		echo "  ✗ 缺少 $(ROOTFS_BASE_TAG)，请执行 make base"; \
	fi
	@printf '== 磁盘 ==\n'; df -h . | tail -1 | sed 's/^/  /'
