# 悟空派 H3 Zero —— 主线 U-Boot + Linux 内核移植

给 **悟空派 H3 Zero**（Allwinner H3，512MB DDR3）移植 **主线 U-Boot** 与
**主线 Linux 内核**，全流程用 Docker 编译，一条命令产出可以直接烧进 TF 卡的镜像。

- **U-Boot**：`v2026.07`（主线 tag）
- **Linux**：`v6.18.56`（当前 LTS）
- **rootfs**：Debian 12 bookworm armhf
- **WiFi**：板载 XR819，用 out-of-tree 驱动（主线无驱动）

> **本仓库已在 macOS + Docker Desktop 上完整跑通一遍**（含 U-Boot、内核、
> XR819 驱动、Debian rootfs、2GB 可烧录镜像），产物见 `out/`。
> 实测结果：`u-boot-sunxi-with-spl.bin` 559KiB、`zImage` 6.3MiB、
> 内核模块 33 个（含 `xradio_wlan.ko`）、rootfs 192MiB、镜像压缩后 70MiB。

---

## 1. 硬件概览

| 项目 | 参数 | 主线支持情况 |
|---|---|---|
| SoC | Allwinner H3，4×Cortex-A7 @1.2GHz | ✅ `sun8i-h3` |
| 内存 | DDR3 256MB / 512MB | ✅ SPL 运行时自动探测容量 |
| TF 卡 | SDC0（PF0–PF5） | ✅ |
| 有线网口 | H3 内置 10/100 MII PHY | ✅ `dwmac-sun8i` |
| WiFi | XR819（SDC1 / PG0–PG5） | ⚠️ 需 out-of-tree 驱动 |
| SPI NOR | 2MB（SPI0 / PC0–PC3） | ✅ `spi-nor` |
| 串口 | UART0，板载 USB 转串口（Type-C） | ✅ |
| USB | 1×USB-A + 2×USB（13pin 转接）+ 1×OTG（Type-C） | ✅ |
| CVBS 视频 | 需 13pin 转接板 | ❌ **主线无 H3 TVE 驱动** |
| 音频 | H3 codec，13pin 转接板引出 | ✅ `sun8i-codec` |

> **这块板与香橙派 Orange Pi Zero 是同款硬件**（悟空派把它做成了 Type-C 供电 +
> 板载 USB 转串口）。所以移植策略是：以主线里现成的
> `sun8i-h2-plus-orangepi-zero` 为基线，换成真正的 H3（`sun8i-h3`），
> 再补上 XR819 的板级细节。

### 1.1 13pin 扩展口（1×13，0.1"）

板子没有 HDMI，视频/音频/USB/红外全靠这个排针接转接板引出：

| 脚 | 信号 | 脚 | 信号 |
|---|---|---|---|
| 1 | 5V | 2 | GND |
| 3 | USB-DM2 | 4 | USB-DP2 |
| 5 | USB-DM3 | 6 | USB-DP3 |
| 7 | LINEOUT-R | 8 | LINEOUT-L |
| 9 | **TV-OUT (CVBS)** | 10 | MIC-BIAS |
| 11 | MIC1P | 12 | MIC1N |
| 13 | CIR-RX（红外接收） | | |

对应到设备树：3–6 脚 = USB2/USB3（`&ehci1/&ohci1` + `&ehci2/&ohci2`），
7–8 脚 = `&codec` 的 LINEOUT，13 脚 = 红外。

> ⚠️ **注意：13pin 上没有串口。** 调试串口 UART0 是板上独立的 3pin
> （TX/RX/GND，在网口旁边），或者直接用 Type-C 的板载 USB 转串口。

### 1.2 26pin 排针（兼容树莓派定义）

UART1 / UART2、TWI0 / TWI1、SPI1、PWM1 都在这排上。设备树里
`&uart1` / `&uart2` 默认是 `disabled`，要用就改成 `okay`。


---

## 2. 快速开始

### 2.1 依赖

只需要 **Docker Desktop**（macOS / Windows）或 Docker Engine（Linux）。
所有交叉编译工具链都在容器里，宿主机器上不需要装任何 ARM 工具链。

```bash
make check      # 检查 docker、armhf 模拟能力、磁盘空间
```

### 2.2 一条命令出镜像

```bash
make image
```

这一步会依次做：

```
docker 镜像 → 下载源码 → 编译 U-Boot → 编译内核 → 编译 WiFi 驱动
            → 制作 Debian rootfs → 组装 TF 卡镜像
```

首次约需 **30–60 分钟**（取决于网速，主要在下载内核源码和 qemu 模拟装包）。
之后增量重建只要几分钟。

产物都在 `./out/`：

```
out/
├── wukongpi-h3-6.18.56-YYYYMMDD-gXXXXXXX.img       # 可直接烧录的镜像（2GB）
├── wukongpi-h3-6.18.56-YYYYMMDD-gXXXXXXX.img.xz    # 压缩版（约 70MB）
├── wukongpi-h3-6.18.56-YYYYMMDD-gXXXXXXX.img.bmap  # bmaptool 用的块映射
├── uboot/
│   ├── u-boot-sunxi-with-spl.bin           # 含 SPL，写入偏移 8KiB
│   ├── u-boot.bin
│   ├── sun8i-h3-wukongpi-h3.dtb
│   └── config                              # U-Boot 的 .config
└── kernel/
    ├── zImage                              # 6.3MB
    ├── sun8i-h3-wukongpi-h3.dtb
    ├── System.map
    ├── kernel.config                       # 内核 .config
    ├── kernel.release                      # 6.18.56
    └── modules.tar.gz                      # 内核模块（33 个）
```

### 2.3 烧录到 TF 卡

```bash
./scripts/host/flash-sd.sh                      # 交互式选择磁盘
./scripts/host/flash-sd.sh out/xxx.img.xz /dev/disk4
./scripts/host/flash-sd.sh --force ...          # 跳过「有数据」的二次确认
```

脚本有三层安全检查，避免手滑抹掉有用的数据：

1. 拒绝写入**内置磁盘**（防止把系统盘干掉）
2. 目标盘上如果挂着**有数据的卷**，会把每个卷的挂载点和占用列出来，
   并要求你手打磁盘号（例如 `disk2`）才能继续
3. 最后还要再输一次 `yes`

> 第 2 层是踩过坑加的：一开始只拦了内置磁盘，结果一张插着 13GB
> 行车记录仪素材的相机卡差点被当成空白卡烧掉。

也可以用 **balenaEtcher** 直接烧 `.img.xz`，或者：

```bash
xz -dc out/xxx.img.xz | sudo dd of=/dev/rdiskN bs=4m
```

### 2.4 上电看串口

板子的 **Type-C 口自带 USB 转串口芯片**。用一根 Type-C 线插到电脑上，
除了供电还会出现一个串口设备。

**推荐用 `make serial`**（自动探测设备、记住选择）：

```bash
make serial-list     # 列出可用串口设备
make serial          # 连接（多个设备时首次会让你选一次，之后记住）
make serial 1500000  # 指定波特率
```

窗口尺寸**在板子侧解决，不依赖客户端**：rootfs 里的
`/etc/profile.d/00-tty-size.sh` 会给串口会话（`/dev/ttyS*`）固定一个较大的
尺寸（默认 60 行 × 200 列），所以 `screen` / `tio` / `minicom` / PuTTY
都不会再出现 80×24 折行错乱。

> 为什么必须这么做：串口**没有远端 pty**，host 端终端的宽高根本传不到板子上，
> 板子的 shell 只能一直以为自己 80×24。在板子侧固定尺寸是唯一与客户端无关的解法。
> 该脚本只对串口 tty 生效，SSH 会话有正确的尺寸，不会被覆盖。
> 要改尺寸：改 `configs/versions.env` 里的 `ROOTFS_SERIAL_SIZE`（格式 `"行 列"`），
> 然后 `make rootfs && make sd-image`。
>
> 注意全屏程序（`vim` / `htop`）在串口下仍可能错位 —— 那类操作请用 SSH。

`make serial` 优先用 [`tio`](https://github.com/tio/tio)（断线重连、会话日志），
没装就退回 `screen`，两者都可用：

```bash
brew install tio     # 可选，不装也不影响窗口尺寸
```

也可以手工连：

| 系统 | 设备名 | 连接命令 |
|---|---|---|
| macOS | `/dev/cu.usbserial-*` | `tio /dev/cu.usbserial-xxx -b 115200` |
| Linux | `/dev/ttyUSB0` | `picocom -b 115200 /dev/ttyUSB0` |
| Windows | `COMx` | MobaXterm / PuTTY @115200 |

> macOS 上要用 `/dev/cu.*` 而不是 `/dev/tty.*`：后者会阻塞等待 DCD 信号。

登录：`root` / `root`，或 `wukongpi` / `wukongpi`（带 sudo 免密）。

> 默认凭据在 `configs/versions.env` 里可改：`ROOTFS_USER`、`ROOTFS_PASSWORD`、
> `ROOTFS_ROOT_PASSWORD`、`ROOTFS_HOSTNAME`（改完 `make rootfs && make sd-image`）。
>
> 语言与中文显示：镜像会生成 `en_US.UTF-8` 和 `zh_CN.UTF-8` 两套 locale，
> 默认 `LANG=en_US.UTF-8`（UTF-8 下中文显示本来就正常，区别只在系统消息的语言）。
> 想要中文的 apt / systemd 提示就把 `ROOTFS_LOCALE` 改成 `zh_CN.UTF-8`；
> 时区用 `ROOTFS_TIMEZONE`（默认 `Asia/Shanghai`）。

> **日常建议用 SSH 而不是串口** —— 网络通了之后 `ssh wukongpi@<板子IP>` 能自动
> 同步窗口尺寸、能滚动复制、不用重连。串口留给「网络还没起来 / 系统起不来」的
> 救砖场景。

---

## 3. 目录结构

```
.
├── Makefile                      # 所有构建入口
├── configs/
│   ├── versions.env              # 版本与路径锁定（改这里切版本）
│   ├── uboot/wukongpi_h3_defconfig
│   └── linux/wukongpi.fragment   # 内核配置增量片段
├── board/
│   ├── dts/sun8i-h3-wukongpi-h3.dts   # 板级设备树
│   └── rootfs/
│       ├── 01-install-packages.sh     # rootfs 阶段1：装包（会被 docker commit 缓存）
│       └── 02-configure-system.sh     # rootfs 阶段2：系统配置
├── docker/
│   ├── Dockerfile                # 交叉编译环境
├── patches/                      # 给上游提交用的 git patch
├── scripts/
│   ├── host/                     # 宿主机侧（需要 docker 命令）
│   │   ├── run.sh                # 进容器的统一入口
│   │   ├── build-rootfs.sh       # armhf 容器里做 rootfs
│   │   └── flash-sd.sh
│   └── inner/                    # 容器内侧
│       ├── env.sh                # 公共函数
│       ├── fetch-sources.sh
│       ├── build-uboot.sh
│       ├── build-kernel.sh
│       ├── build-xradio.sh
│       └── mk-sd-image.sh
└── out/                          # 产物（gitignore）
```

---

## 4. 构建系统是怎么设计的

有两点值得说明，都是踩过坑之后的选择：

### 4.1 源码放在 Docker volume 里，不放 bind mount

在 macOS 上实测，Docker Desktop 的 bind mount（gRPC-FUSE）写 2000 个小文件
要 **36 秒**，而 Docker volume 只要 **4 秒**——差 9 倍。内核编译会产生几万个
小文件，放 bind mount 上会慢到无法接受。

所以：

- **源码与产物** → 放在名为 `wukongpi-build` 的 Docker volume（`/build`）
- **配置、脚本、补丁** → bind mount 到 `/project`（宿主机上可以直接改，改完立即生效）
- 产物最后复制回宿主机的 `./out/`

`make shell` 可以进容器翻源码。

### 4.2 rootfs 用 armhf 容器原生制作

rootfs 需要在 armhf 用户态下跑 `apt`，但容器默认是 x86_64。
这里用的是 Docker Desktop 自带的 qemu 模拟：

```bash
docker run --platform linux/arm/v7 wukongpi-base:bookworm ...
```

好处是**不需要特权容器、不需要 chroot、不需要注册 binfmt**，
apt 装出来就是原生 armhf 用户态。代价是模拟执行慢，装包阶段要多等一会儿。

因为慢，rootfs 被拆成两阶段并做了缓存：

| 阶段 | 内容 | 耗时 |
|---|---|---|
| stage1 | 装软件包 → `docker commit` 成 `wukongpi-rootfs:bookworm-stage1` | 十几分钟（只跑一次） |
| stage2 | 系统配置 + 打包 | 1–2 分钟 |

所以改 `02-configure-system.sh` 之后重跑 `make rootfs` 是秒级的。

> **关于基础镜像标签**：Docker 老式镜像存储「一个 tag 只对应一个平台」。
> 直接用 `debian:bookworm-slim` 拉 arm/v7 会把本地 amd64 那份覆盖掉，
> 因此本项目把 armhf 基础镜像单独打了 `wukongpi-base:bookworm` 标签，
> 编译容器和 rootfs 容器互不干扰。

---

## 5. 移植要点

### 5.1 U-Boot

`configs/uboot/wukongpi_h3_defconfig`，基线是 `orangepi_zero_defconfig`：

| 配置 | 值 | 说明 |
|---|---|---|
| `CONFIG_MACH_SUN8I_H3` | y | 选 H3 平台，自动带上 `SUNXI_DRAM_DW` |
| `CONFIG_DRAM_CLK` | **528** | ⚠️ **实测值，不要照抄香橙派 Zero 的 624**，详见下方踩坑记录 |
| `CONFIG_SPL_SUNXI_LED_STATUS_GPIO` | 362 | SPL 阶段点亮绿色电源灯（PL10） |
| `CONFIG_SPL_SPI_SUNXI` | y | 允许把 U-Boot 烧进板载 SPI NOR |
| `CONFIG_BOOTCOMMAND` | `run distro_bootcmd` | 扫描 TF 卡上的 `extlinux.conf` |
| `CONFIG_SYS_BOOTM_LEN` | 0x4000000 | 内核镜像上限从默认 8MB 提到 64MB |
| `CONFIG_CMD_MEMTEST` | y | U-Boot 提示符下可跑 `mtest` 裸机内存测试 |

**内存容量不用管**：H3 的 DRAM 初始化在 SPL 阶段调用
`mctl_auto_detect_dram_size()` 自动探测，256MB 和 512MB 的板子都能跑同一个固件。

**设备树放哪**：U-Boot 的 `OF_UPSTREAM` 机制对 sunxi 在 `v2026.07` 上**没有启用**
（`# CONFIG_OF_UPSTREAM is not set`），所以走的是传统路径：

```
U-Boot : arch/arm/dts/sun8i-h3-wukongpi-h3.dts   + arch/arm/dts/Makefile 里登记
内核   : arch/arm/boot/dts/allwinner/sun8i-h3-wukongpi-h3.dts + 同目录 Makefile
```

`scripts/inner/build-uboot.sh` 会读 `.config` 里的 `CONFIG_OF_UPSTREAM`
自己判断该放 `arch/arm/dts/` 还是 `dts/upstream/src/arm/allwinner/`，
并自动往 Makefile 里插入对应的一行，两种布局都支持。

### 5.2 内核

基线 `sunxi_defconfig`，再用 `configs/linux/wukongpi.fragment` 增量叠加：

- **WiFi**：`CFG80211` / `MAC80211`（xradio 依赖，sunxi_defconfig 默认关掉了 `WLAN`）
- **容器支持**：namespaces、cgroups、veth、bridge、overlayfs、netfilter/nat
- **zram**：512MB 内存下的关键优化
- **USB gadget**：Type-C 的 OTG 能力
- **NFS/中文**：`NLS_CODEPAGE_936`（挂 U 盘看中文文件名不花屏）
- **硬件**：SPI NOR、PWM、红外、H3 加密引擎

### 5.3 设备树：XR819 是重点

XR819 是整块板子最麻烦的部分，主线没有驱动，必须用
[fifteenhex/xradio](https://github.com/fifteenhex/xradio) 这个移植版。
驱动作者在香橙派 Zero 上实测可用的设备树要求如下，本项目已经照做：

```dts
/* 1.8V IO 供电由 PA20 控制 */
vdd_wifi: vdd-wifi {
	compatible = "regulator-fixed";
	regulator-min-microvolt = <1800000>;
	regulator-max-microvolt = <1800000>;
	gpio = <&pio 0 20 GPIO_ACTIVE_HIGH>;
	startup-delay-us = <70000>;
	enable-active-high;
};

/* mmc1：vmmc 固定 3.3V，vqmmc 接 1.8V；频率必须压到 16MHz */
&mmc1 {
	vmmc-supply = <&reg_vcc3v3>;
	vqmmc-supply = <&vdd_wifi>;
	mmc-pwrseq = <&wifi_pwrseq>;
	max-frequency = <16000000>;
	non-removable;
	status = "okay";

	xr819: wifi@1 {
		reg = <1>;
		compatible = "xradio,xr819";
		interrupt-parent = <&pio>;
		interrupts = <6 10 IRQ_TYPE_EDGE_RISING>;  /* PG10 host-wake */
		interrupt-names = "host-wake";
	};
};
```

另外还需要 `wifi_wake`（PG10）和 `wifi_rst`（PL7）两个 pinctrl 组，
以及 `aliases` 里的 `ethernet1 = &xr819`（这样 U-Boot 会按芯片唯一 ID
给它填一个固定的 MAC 地址）。

固件（`boot_xr819.bin` / `fw_xr819.bin` / `sdd_xr819.bin`）在 rootfs 制作阶段
自动下载到 `/lib/firmware/xr819/`。

### 5.4 分区布局

```
偏移 8KiB                     ← u-boot-sunxi-with-spl.bin（SPL + U-Boot，约 600KB）
偏移 1MiB   分区1 FAT32  BOOT ← zImage / dtb / extlinux/extlinux.conf
偏移 65MiB  分区2 ext4   rootfs
```

U-Boot 用 **distro boot**：自动在 TF 卡上找 `/extlinux/extlinux.conf`，
不需要 `boot.scr`，也不需要 `mkimage`。想改内核启动参数，直接编辑
TF 卡第一个分区里的 `extlinux/extlinux.conf` 就行。

整个镜像组装过程**不使用 loop 设备**（用 `mke2fs -d`、`mkfs.fat`、`dd`
拼接），所以在普通容器里就能完成，不需要特权。

---

## 6. 常用命令

```bash
make help          # 列出所有目标
make image         # 一站式构建
make fetch         # 只拉源码
make uboot         # 只编 U-Boot
make kernel        # 只编内核
make xradio        # 只编 WiFi 驱动
make rootfs        # 只做 rootfs
make sd-image      # 只组装镜像
make verify-image  # 检查 out/ 最新镜像是否包含当前 HEAD 的全部提交
make patches       # 生成可直接提交上游的补丁，写进 ./patches
make base          # 准备 rootfs 用的 armhf 基础镜像
make shell         # 进容器（源码在 /build/sources）
make out           # 把产物同步到 ./out
make clean         # 清产物（保留源码）
make distclean     # 连源码一起删
```

换版本只要改 `configs/versions.env`：

```bash
LINUX_VERSION=v6.18.56
UBOOT_VERSION=v2026.07
ROOTFS_RELEASE=bookworm
```

也可以临时用环境变量覆盖：

```bash
LINUX_VERSION=v6.6.158 make kernel
ROOTFS_RELEASE=bookworm make rootfs
```

加速选项（源码下载走国内镜像，默认已配好）：

```bash
LINUX_MIRROR=https://mirrors.aliyun.com/linux-kernel make fetch
APT_MIRROR=mirrors.tuna.tsinghua.edu.cn make docker
```

### 6.1 判断「镜像里是哪一版代码」

镜像文件名里带提交号，系统里也留了一份：

```bash
make verify-image            # 一条命令回答「最新镜像包含全部修改吗」
cat /etc/wukongpi-release    # 在板子上直接看这版镜像的来源
```

`make verify-image` 读镜像文件名里的 `-g<提交号>` 与 `HEAD` 比对，并区分
**「缺的提交会不会改变镜像内容」** —— 只改了 README / `scripts/host/` 的提交
会明确告诉你不必重构建。不解包，也不需要 Docker。

退出码：`0` 已是最新（或只差文档）；`1` 需要 `make image`；`2` 无法判定。

**为什么不能用文件时间戳判断**：`git rebase` 会先 checkout 到上游提交、再逐个
重放，过程中所有文件都被重写一遍，mtime 全部变成「构建之后」——
于是镜像看起来比所有源码都旧，用它做判断必然误判。

工作区不干净时文件名会带 `-dirty`：脏工作区不对应任何提交，
`make verify-image` 会直说这种情况无法用提交号判断。

---

## 7. 板子到手后怎么用

### 首次开机：会自动扩容并重启一次

镜像本体是 2GB，卡上剩下的空间靠首次开机自动扩上去：

| 第几次开机 | 动作 |
|---|---|
| 第一次 | `growpart` 撑大分区表 → **自动重启一次** |
| 第二次 | `resize2fs` 扩文件系统 → 完成，之后不再执行 |

串口上会看到一行提示：

```
growrootfs: 分区表已扩展，重启一次以重新读取分区表
```

**为什么要重启一次**：`growpart` 会重写分区表，而此时根分区正被挂载使用，
内核重读分区表可能失败、甚至把兄弟分区（`mmcblk0p1`）的设备节点摘掉。
先只改分区表、重启后再扩文件系统，是最稳的做法。

开机完成后 `df -h /` 应该显示整张卡的大小。

### 有线网络

插上网线即 DHCP，`ssh wukongpi@<板子IP>`（密码 `wukongpi`）。

### WiFi

> **实测结论**：**XR819 在这块板子上是可以正常工作的** —— SDIO 枚举、固件加载、
> 扫描、关联、DHCP、上网全部验证通过，WSM 协议序号零错误。
>
> 但它有一个**前置条件：SDIO 初始化必须干净**。这颗芯片的上电/复位时序很敏感，
> 开机时偶发（约 1/5 概率）会出现：
>
> ```
> mmc1: Failed to initialize a non-removable card
> ```
>
> 更麻烦的是「边际成功」——卡枚举了但通信不可靠，固件会收到被破坏的数据并
> assert 卡死（表现为 `bh thread exiting` + `wlan0` 消失）。
>
> **对照实验（唯一变量是 SDIO 初始化过程）**：
>
> | 初始化方式 | 结果 |
> |---|---|
> | 开机自动（偶发/边际） | 崩 |
> | `unbind/bind` 手动重新枚举（时序干净） | 扫描 ✓ 连接 ✓ 上网 ✓ 序号零错误 ✓ |
>
> 所以设备树里 `post-power-on-delay-ms` 给到了 **1000ms**（上游香橙派 Zero 用 200ms、
> xradio README 用 50ms，实测都不够）。这个值如果还不够，可以继续加大。
>
> 掉线后的恢复（新版 `wifi` 脚本会自动做这一步）：
>
> ```bash
> sudo modprobe -r xradio_wlan && sleep 2 && sudo modprobe xradio_wlan
> ```
>
> **当服务器用仍建议插网线** —— 有线是主线驱动，不依赖这些时序玄学，
> 而且 XR819 本身丢帧严重（驱动作者原话：「The xr819 chip/firmware drops
> tons and tons of frames with FCS errors」，实测 ping 丢包率约 30%）。
>
> **驱动默认被 blacklist**（`/etc/modprobe.d/blacklist-xradio.conf`），
> 开机保持干净。执行一次 `sudo wifi "SSID" "密码"` 之后脚本会**自动解除黑名单**，
> 从此开机自动加载驱动并自动连 WiFi。

镜像里预装了 `wukongpi-wifi`（短别名 `wifi`），一条命令搞定：

```bash
sudo wukongpi-wifi "你的WiFi名字" "你的密码"
```

```
[!] XR819 在主线没有驱动，只能用 out-of-tree 的 xradio 移植版。
[!] 作者自己说它不成熟、可能把内核搞挂；实测丢包率也偏高（约 30%）。
[!] 当服务器用建议插网线；WiFi 适合偶尔用一下。
[!] （配置过一次之后会自动解除黑名单，之后开机自动加载并自动连）
==> wlan0 未出现，加载 xradio_wlan ...
==> 写入 /etc/wpa_supplicant/wpa_supplicant.conf
==> 连接 "MyWiFi" ...
==> 已联网：wlan0  192.168.1.123/24
==> 外网可达 ✓
```

| 命令 | 作用 |
|---|---|
| `sudo wukongpi-wifi` | 交互式输入 SSID / 密码 |
| `sudo wifi "SSID" "密码"` | 一步到位 |
| `sudo wifi -s` | 扫描周边 WiFi（含信号强度） |
| `sudo wifi -i` | 查看连接状态（IP / 信道 / 信号） |
| `sudo wifi -d` | 断开 |

它做的事：检查 `wlan0`（没有就 `modprobe xradio_wlan`）→ `rfkill unblock wifi`
→ 用 `wpa_passphrase` 生成配置（**PSK 哈希存储，不落明文密码**）→
自动启用 `/etc/network/interfaces` 里的 `wlan0` 段落（**之后开机自动连**）
→ 等 IP → ping 一次确认外网。

> 驱动版本用的是 `clankerfixedmywifi-260903` 分支而不是 `master`：
> 这个分支加了固件崩溃后的自动恢复（warm reboot），
> 而 `master` 在缓冲区溢出时是 `BUG_ON` 直接 panic。

### SPI NOR（可选）

> ⚠️ **实测悟空派上这颗 Flash 不响应**（`unrecognized JEDEC id bytes: 00 00 00 00 00 00`），
> 所以设备树里 `&spi0` 默认是 `disabled`（和上游香橙派 Zero 的处理一致）。
> 如果你的板子确实焊了，把 `board/dts/sun8i-h3-wukongpi-h3.dts` 里
> `&spi0` 的 `status` 改成 `"okay"` 重新编译即可。

板上 2MB SPI NOR 可以单独存一份 U-Boot，实现「SPI 启动 U-Boot + TF 卡启动内核」：

```bash
# 让板子进入 FEL 模式（按住 FEL 键上电，或短接），然后在电脑上：
sunxi-fel -p spiflash-write 0 out/uboot/u-boot-sunxi-with-spl.bin
```

### 跑 Docker

rootfs 里已经打开了容器所需的内核选项，装一个 docker：

```bash
sudo apt update && sudo apt install -y docker.io
sudo usermod -aG docker wukongpi
```

---

## 8. 已知限制

### ⚠️ CVBS 视频输出主线不支持

H3 的**电视编码器（TVE）没有主线驱动**。
`drivers/gpu/drm/sun4i/` 里只有给 A10/A20 用的 `sun4i_tv.c`，
H3 的 TVE 补丁提交过多次但一直没被合并。
所以 **13pin 转接板上的 AV（复合视频）输出在本固件上不可用**。

可行的绕法：

1. 用厂商 BSP 内核（全志 3.4 / 友善 4.14）——但那就不是主线了；
2. 自己把 out-of-tree 的 H3 TVE 补丁打在主线内核上；
3. 换用 USB 转 HDMI 之类的方案。

**音频不受影响**：H3 codec 有主线驱动，13pin 上的 LINEOUT 可以直接用。

### ⚠️ XR819 驱动质量一般

驱动作者自己在 README 里写得很直白：这个驱动「能跑，但结构不好，
出问题可能会把内核搞挂」，而且 XR819 芯片本身丢帧严重、性能很差。
**当服务器用的话建议直接插网线。**

### 其它

- 板载 2MB SPI NOR 的具体型号没有确认，设备树用的是通用 `jedec,spi-nor`；
  如果 `dmesg` 里认不出来，在 `board/dts/sun8i-h3-wukongpi-h3.dts`
  的 `flash@0` 里补一个具体的 `compatible`（比如 `winbond,w25q16`）。
- LED、TF 卡检测脚（PF6）、WiFi 供电脚（PA20）都是**按香橙派 Zero 抄的**。
  如果这块板有改动，对应位置都在设备树顶部，改起来很直观。
- U-Boot 默认没有配置可写环境变量分区（env 是只读默认值）。
  要改启动参数请编辑 TF 卡第一分区的 `extlinux/extlinux.conf`。

---

## 9. 排查问题

| 现象 | 排查方向 |
|---|---|
| 完全没有串口输出 | 供电不足（换好一点的 USB 线/头）；串口波特率 115200；TX/RX 是否接反 |
| SPL 有输出，U-Boot 卡住 | DDR 参数问题，把 `CONFIG_DRAM_CLK=624` 降到 `528` 试试 |
| 找不到内核 `/extlinux/extlinux.conf` | 第一个分区是不是 FAT32；文件名大小写；用 `make sd-image` 重新生成 |
| 内核起来但 `VFS: Unable to mount root` | 第二个分区的 UUID/ext4；确认 `root=/dev/mmcblk0p2` |
| **`mmc1: Failed to initialize a non-removable card`，`wlan0` 不出现** | **不要把 `&spi0` 改成 `disabled`**！关掉 spi0 会让 PC0-PC3 退出引脚复用、进而破坏 XR819 的 SDIO 初始化。保持 `status = "okay"`，详见下方踩坑记录 |
| **`ssh` 报 `REMOTE HOST IDENTIFICATION HAS CHANGED`** | **正常现象**，不是攻击：镜像故意不在构建时生成 host key（否则所有板子共用同一套密钥），每台设备首次开机自己生成，所以重刷一次换一次。删掉旧记录即可：`ssh-keygen -R <板子IP>`。想严格核对就在板子上跑 `ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub` 比对指纹 |
| **`Failed to start ssh.service`，`systemctl status ssh` 说没有 host key** | host key 的生成步骤排在了 `sshd -t` 自检之后。执行 `sudo ssh-keygen -A && sudo systemctl restart ssh` 立即修复，详见下方踩坑记录 |
| **开机几分钟后随机崩溃，崩溃点在毫不相干的子系统（时钟/SLUB/内存管理/代码段），`Code:` 里出现 `ffffffff`** | **DDR 频率过高**导致随机内存损坏。把 `CONFIG_DRAM_CLK` 从 624 降到 **528**，详见下方踩坑记录 |
| 开机掉进 emergency，日志有 `Timed out waiting for device dev-mmcblk0p1.device` | systemd 单元有**循环依赖**，它打破循环时会随机删掉某个任务（可能删到设备单元）。用 `systemd-analyze verify <unit>` 可直接复现，详见下方踩坑记录 |
| `wlan0` 不出现 | 驱动默认被 blacklist（设计如此），先 `sudo modprobe xradio_wlan` 或直接 `sudo wifi`；再看 `dmesg \| grep -i xradio`、`/lib/firmware/xr819/`、SDIO 是否枚举（`mmc1`） |
| **`wlan0` 突然消失，`dmesg` 里有 `xradio_wlan ... bh thread exiting`** | xradio 驱动内部崩了。重载模块：`sudo modprobe -r xradio_wlan && sleep 2 && sudo modprobe xradio_wlan`（新版 `wifi` 脚本会自动做这一步） |
| **普通用户 `ping` 报 `ping: socket: Address family not supported by protocol`，连 `ping 1.1.1.1` 也一样** | 内核没开 IPv6。iputils 的 `ping` 是双栈的，启动时会无条件创建 IPv6 套接字，失败就直接退出，所以纯 IPv4 目标也一起挂。判别实验：`ping -4 1.1.1.1` 通、`ping 1.1.1.1` 不通就是它。详见下方踩坑记录 |
| **普通用户 `ping` 报 `Operation not permitted`** | 镜像里 `ping` 的 `security.capability` 丢了（打包时 `tar` 少了 `--xattrs`），而系统又没有设置 `ping_group_range`，普通用户拿不到原始套接字。`getcap /usr/bin/ping` 输出为空即可确认。临时修复：`sudo setcap cap_net_raw+ep /usr/bin/ping`。详见下方踩坑记录 |
| `modprobe` 刷 `ignoring bad line starting with 'options'` | `/etc/modprobe.d/*.conf` 里有无效行（`options` 后面必须跟参数，只写模块名是错的） |
| 编译报错找不到工具链 | 确认容器镜像构建成功：`make docker` |
| `docker pull` 超时 / registry-1.docker.io 连不上 | Docker Hub 在国内经常抽风，多试几次；rootfs 步骤可改用 `make base` 走镜像站 |
| 源码下载卡住 | 换镜像：`LINUX_MIRROR=... make fetch`，U-Boot 用 `UBOOT_MIRROR=...` |

卡在内核早期启动时，串口上看到的最后一行往往就是线索。
需要更详细的日志就把 `extlinux.conf` 里的 `loglevel=4` 改成 `loglevel=7`。

### 踩坑记录：XR819 的根因被误判了三次

XR819 这条线是整个项目里最曲折的。**我先后给出过三个错误结论**，
值得完整记下来，因为每次错的原因都不一样：

| 次 | 当时的结论 | 依据 | 为什么错 |
|---|---|---|---|
| 1 | 驱动破坏内核内存 | 随机崩溃 + 内核带 `[O]=OOT_MODULE` 污染 | 真因是 `CONFIG_DRAM_CLK=624`。反证很明确：那次 PID-1 崩溃时 `Modules linked in: configfs`，**xradio 根本没加载** |
| 2 | 固件会 assert 并自旋，改不了 | 看到 `bh thread exiting` | `bh thread exiting` 是**正常卸载**的消息（`kthread_stop()`），不是崩溃 |
| 3 | 驱动违反了宿主接口规则 | 逆向文档列出 7 条「宿主可触发」的 assert | 加了 WSM 追踪后发现**序号零错误、扫描正常**，协议层完全健康 |

**最终结论**：驱动和固件都是好的，**问题在 SDIO 初始化的时序边际性**。
对照实验只改了一个变量（初始化过程），结果却是「崩」对「完全正常」。

**这次调查里做对的两件事**：

1. **读逆向文档**。作者那份 196 行的 `docs/firmware.md` 把固件的
   assert 点、WSM 分发表、异常上报格式全列出来了，还**在驱动里内置了解码表**
   （收到异常上报会直接打印「违反了哪条规则」）。没有这份文档，我只能在日志里猜。

2. **加观测而不是改逻辑**。写了个 4 行的追踪补丁，把每条 WSM 消息的
   `id/序号/长度` 打成 `XRDIAG:` 日志——**行为完全不变，只是多了输出**。
   拿到轨迹后，序号是否连续、崩在第几条，全都一目了然。

**这次调查里做错的一件事**：**过早下结论**。
三次都是「看到现象 → 编一个合理的故事 → 当成结论」，而没有先做对照实验。
正确顺序应该是：**先设计能区分假设的实验，再下结论**。

**如果当时真去改固件**（patch 掉 assert 让它别自旋），会得到一个
「不报警但内部状态已损坏」的芯片——比卡死更难查。**逆向的价值是让我们知道
不用碰固件**，而不是让我们去碰它。

### 踩坑记录：关掉 spi0 把 WiFi 搞挂了

这颗板载 SPI NOR 实测**完全不响应**：

```
spi-nor spi0.0: unrecognized JEDEC id bytes: 00 00 00 00 00 00
```

六个字节全零。我当时的推理是：「没焊 Flash → 把 `&spi0` 改成 `disabled` 更干净」
（上游香橙派 Zero 的 dts 也正是这么写的）。**结果 WiFi 直接挂了**：

```
[ 0.53] mmc1: Failed to initialize a non-removable card     ← SDIO 卡认不到
```

改回 `status = "okay"` 立刻恢复：

```
[ 0.58] mmc1: new high speed SDIO card at address 0001
```

**为什么**：`spi0` 用 PC0–PC3，SDIO 用 PG0–PG5，表面上看毫不相干。但关掉
`spi0` 不只是「不探测 Flash」——它还会让 **PC0–PC3 退出 `spi0` 功能复用、回到
复位状态**。而这块板的 PC0–PC3 显然还接着别的东西（很可能和 XR819 的供电或复位
相关），引脚状态一变，WiFi 就起不来。

**定位方式**（很干净的一次 A/B）：

1. 只换 FAT 分区上的 `.dtb` 一个文件，U-Boot / 内核 / rootfs / 固件全不动
2. 对照组用**逐字节 sha256 相同**的旧版本，而不是「大概差不多」
3. 24KB 文件 vs 2GB 整卡，测试周期从几分钟缩到几秒

**教训**：
- 一颗焊在板上的 Flash 读出来全零，**这本身就是反常信号**，应该追这个反常，
  而不是顺手把节点关掉
- **「看起来无害的清理」在没有硬件原理图的情况下可能是有害的**——
  关掉一个外设节点会改变引脚状态，而引脚的复用关系你未必知道
- 所以现在 DTS 里 `&spi0` 的注释里明确写了「不要改成 disabled」，
  并把整个推理过程留在那里，避免以后又有人顺手清理掉

### 踩坑记录：SSH host key 生成排在了自检之后

为了保证每台板子的 SSH host key 唯一（不共用同一套密钥），构建时会把
`/etc/ssh/ssh_host_*` 删掉，改成首次开机生成。第一版是这么写的：

```ini
# /etc/systemd/system/ssh.service.d/10-hostkeys.conf
[Service]
ExecStartPre=/usr/bin/ssh-keygen -A
```

结果 ssh.service 永远起不来。原因是 Debian 的 `ssh.service` 里本来就有：

```
ExecStartPre=/usr/sbin/sshd -t        ← 配置自检
ExecStart=/usr/sbin/sshd -D $SSHD_OPTS
```

而 **systemd 会把 drop-in 里的 `ExecStartPre=` 追加到主单元之后**，所以实际顺序是：

```
① /usr/sbin/sshd -t         先跑 → 此时没有 host key → 失败
② /usr/bin/ssh-keygen -A    轮不到
```

表现就是 `Failed → Stopped → Starting → Failed` 无限重试
（`ssh.service` 带 `Restart=on-failure`）。

**修法**：改成独立的 oneshot 单元，用 `Before=ssh.service` 排在自检之前：

```ini
[Unit]
Description=Generate SSH host keys (first boot only)
ConditionPathExists=!/etc/ssh/ssh_host_ed25519_key
Before=ssh.service
After=local-fs.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/bin/ssh-keygen -A

[Install]
WantedBy=multi-user.target
```

**教训**：drop-in 里的 `ExecStartPre=` / `ExecStartPost=` 是**追加**而不是插入，
想控制顺序就得用独立的单元 + `Before=`/`After=`，或者用空赋值
（`ExecStartPre=`）把整个列表清掉再按顺序重建。

### 踩坑记录：DDR 频率太高导致随机内存损坏

这是整个移植里**最难查**的一个。第一版 `CONFIG_DRAM_CLK` 直接抄了香橙派 Zero 的
`624`（DDR3-1248），结果系统能启动、能登录、能联网，但**几分钟内必然随机崩溃**。

四次崩溃分别在四个**毫不相干**的子系统：

| 崩溃点 | 现象 |
|---|---|
| `clk_core_prepare` | 时钟指针变成 `4`（野指针） |
| `refill_obj_stock` | SLUB 的 per-CPU `obj_stock` 被写坏 |
| `vmalloc_to_page` | 栈指针落在用户空间、整个栈不可读 |
| `cap_vm_enough_memory+0x58` | **内核代码段被写成 `0xffffffff`**（取指直接 oops） |

**为什么难查**：每次开机损坏的地址都不一样 → 崩溃点每次都变；而且系统看起来「能跑」，
让人误以为是某个驱动的 bug。我一开始就误判成 xradio 驱动的问题（它确实是 out-of-tree
的、确实会崩），换了驱动分支、加了黑名单，都没解决。

**定位过程**（值得记住的方法）：

```bash
# 在 U-Boot 提示符下，把内核从 SD 卡读进 RAM 再算校验和
=> load mmc 0:1 0x42000000 zImage
=> crc32 0x42000000 0x64F958
crc32 for 42000000 ... 4264f957 ==> 76ba6c35      ← 和本地算的一致
```

CRC 对上了，说明 **SD 读取和 RAM 静态读写都是好的**。加上「内核是压缩的、解压有校验」
这两个事实，就能推出：**数据是在 RAM 里被动态改坏的**，即内存时序边际性问题，
而不是驱动 bug、也不是 SD 卡坏块。

**修法**：`CONFIG_DRAM_CLK=528`。改完连续运行 11 分钟零 oops。

**教训**：
- 从别的板子抄来的参数（尤其是 DRAM 时序）**必须验证**，不同批次的 DDR 颗粒差别很大
- 「随机位置、随机时间的内存损坏」几乎一定是硬件/时序问题，不要往驱动 bug 上想
- `crc32` / `mtest` 这类**在 Linux 之外做数据完整性校验**的手段，是排除内存问题的利器

### 踩坑记录：systemd 循环依赖导致随机 emergency

第一版 `growrootfs.service` 写成了这样：

```ini
WantedBy=sysinit.target   # sysinit.target 要拉起它
Before=sysinit.target     # 它又必须在 sysinit.target 之前完成   ← 自相矛盾
```

systemd 会报 `Found ordering cycle on growrootfs.service/start`，然后
**删掉循环里的某一个任务**。删到 `growrootfs` 自己时表面上「一切正常」
（只是扩容静默失效）；删到 `dev-mmcblk0p1.device` 时，设备单元永远等不到
→ `boot.mount` 超时 → `local-fs.target` 失败 → **emergency mode**。
同一个 bug 两种表现，非常容易误判成「SD 卡/分区表/udev 有问题」。

修法：把 `Before=` 换成 `After=local-fs.target`，并用

```bash
systemd-analyze verify growrootfs.service
```

确认不再有循环（拿旧版对照，它会明确打印 `unfixable cyclic ordering dependency`）。

**教训**：`WantedBy=X` 和 `Before=X` 不能同时用——前者表示「X 拉起我」，
后者表示「我在 X 之前完成」，对 target 而言这就是一个环。

### 踩坑记录：普通用户 ping 不通，是两个独立缺陷叠在一起

现象（用普通用户，不是 root）：

```console
$ ping wanyor.com
ping: socktype: SOCK_DGRAM
ping: socket: Address family not supported by protocol
$ ping 1.1.1.1        # 纯 IPv4 字面量，照样失败
ping: socktype: SOCK_DGRAM
ping: socket: Address family not supported by protocol
```

`Address family not supported` 就是 `EAFNOSUPPORT`，来自 `socket()`。这个错误码
**只有「地址族/协议组合根本没注册」才会返回**，权限不足是 `EPERM`/`EACCES`。
所以第一步就能把「capability 丢了」这个猜测排除掉（它确实也丢了，但那是第二个缺陷）。

#### 缺陷一：内核没有 IPv6

`net/ipv4/af_inet.c` 里 IPv4 的 ping 套接字是无条件注册的（`proto_register(&ping_prot, 1)`），
所以 AF_INET 不可能报 EAFNOSUPPORT。真正的来源是 AF_INET6：

**iputils 的 `ping` 是双栈实现，启动时会同时创建 IPv4 和 IPv6 两个套接字。**
二进制里的字符串就是证据：

```
socktype: %s
sock4.fd: %d (socktype: %s), sock6.fd: %d (socktype: %s), hints.ai_family: %s
```

IPv6 那个创建失败就直接退出，**于是连 IPv4 目标也一起挂** —— 这正是「`ping 1.1.1.1` 也报
Address family」的原因，也是当初最容易被误导的地方。

根因：配置基线 `arch/arm/configs/sunxi_defconfig` 第 27 行就是
`# CONFIG_IPV6 is not set`，我们原样继承了。修法是在 fragment 里显式打开：

```
CONFIG_IPV6=y
```

顺带一个隐性后果：fragment 里那组 `CONFIG_IP6_NF_*` 在 IPv6 关闭时**全是空操作**，
`merge_config.sh` 既不报错也不警告，只会静默丢弃 —— 光看 fragment 会以为 IPv6 防火墙是配好的。

**判别实验**：`ping -4 1.1.1.1` 能通、`ping 1.1.1.1` 不通 → 就是它。

#### 缺陷二：`security.capability` 被 tar 静默丢掉

打开 IPv6 之后非 root 用户还是 ping 不通，因为：

- rootfs 里**没有任何地方设置 `net.ipv4.ping_group_range`**，内核默认值是 `1 0`
  （内核注释写得很直白：*nobody may create ping sockets*），
  所以无特权 ICMP 套接字（SOCK_DGRAM）对普通用户返回 `EACCES`；
- Debian 让普通用户能 ping 靠的是 `ping` 的**文件 capability** `cap_net_raw+ep`；
- capability 存在**扩展属性**里，而打包流程把它丢了。

各环节实测结果（都是跑出来的，不是推断）：

| 环节 | 是否保留 `security.capability` |
|---|---|
| apt 装出来的 `/usr/bin/ping` | ✅ `getcap` 显示 `cap_net_raw=ep` |
| `tar -cpf`（不带 `--xattrs`） | ❌ 解出来 xattr 为空 |
| `tar --xattrs --xattrs-include='*'` | ✅ 往返后仍在 |
| `mke2fs -d` | ✅ 会写进 ext4 |

所以**只需要修 tar 这一环**，打包和解包两侧都要加：

```bash
tar -C / --xattrs --xattrs-include='*' ... -cpf rootfs.tar .
tar -xpf rootfs.tar -C "$ROOT_STAGE" --xattrs --xattrs-include='*'
```

`build-rootfs.sh` 的产物校验里加了防线：打包后直接数 `rootfs.tar` 里
`SCHILY.xattr.security.capability` 的出现次数，为 0 就报警。

#### 教训

- `socket()` 报 `EAFNOSUPPORT` 就先去查「地址族/协议有没有注册」，别往权限上猜（那是 `EPERM`）。
- **双栈程序会把单栈内核的缺失放大**：一个 IPv6 没开，能让纯 IPv4 的命令也一起失败，
  排查时很容易被「IPv4 怎么会报 Address family」带偏。
- 用 `tar` 打包 rootfs 时 `--xattrs` **不是可选项**：文件 capability 就存在扩展属性里，
  丢了不会有任何报错。
- 验证「镜像里到底有没有某个扩展属性」，不必解包，`debugfs` 可以直接读：
  `debugfs -R "ea_list /usr/bin/ping" rootfs.ext4`

---

## 10. 把这些改动提交给上游

`patches/` 下是整理好的 `git format-patch` 格式补丁，可以直接发给上游：

- `patches/linux/`：新增板级设备树 + Makefile 条目 → 发 `linux-sunxi@lists.linux.dev`
  和 `devicetree@vger.kernel.org`，抄送 `linux-arm-kernel@lists.infradead.org`
- `patches/u-boot/`：新增 defconfig → 发 `u-boot@lists.denx.de`

提交前请按上游规范补上 `Signed-off-by`，并把 `MAINTAINERS` 里对应的
ARM/Allwinner 条目一起更新。

---

## 11. 参考

- [linux-sunxi wiki — Allwinner H3](https://linux-sunxi.org/H3)
- [linux-sunxi wiki — Xunlong Orange Pi Zero](https://linux-sunxi.org/Xunlong_Orange_Pi_Zero)
- [U-Boot sunxi 文档](https://docs.u-boot.org/en/latest/board/allwinner/sunxi.html)
- [XR819 主线驱动移植](https://github.com/fifteenhex/xradio)
- [XR819 固件](https://github.com/armbian/firmware/tree/master/xr819)
- [悟空派 H3 用户手册](https://dl.21ic.com/download/wukong_pi_h3_-677431.html)
