# nanopi-r3s-kernel

NanoPi R3S 路由器专用最小化内核配置工具链。

基于 Armbian build framework，从基线 888 项（y/m）按需裁剪至 871~943 项，支持 3 种裁剪模式：纯路由器 / 容器 / 全功能（含 eBPF）。

## 目录结构

```
nanopi-r3s-kernel/
├── trim-r3s-kernel.sh                  # 内核配置裁剪脚本（A-Z + ENABLE_DOCKER/EBPF 守卫）
├── olddefconfig-r3s.sh                 # Kconfig 依赖解析（make olddefconfig 封装）
├── config-nanopir3s.conf               # R3S 构建参数（Armbian compile.sh 用）
├── samples/
│   ├── linux-rockchip64-current.config.baseline  # 裁剪输入基线（888 y/m）
│   └── linux-rockchip64-current.config.base      # 未裁剪 Armbian 默认 config
├── kernel/
│   └── rockchip64-current/
│       └── linux-rockchip64-current.config       # 裁剪产物（按 --mode 产出）
├── extensions/
│   └── nanopir3s-kconfig.sh            # Armbian 扩展钩子（移除 Armbian opts 注入 + keep_set）
├── docs/
│   ├── r3s-device.md                   # R3S 硬件规格
│   ├── trim-requirement.md             # 裁剪需求清单
│   └── build-r3s-alpine.md             # Alpine Linux 集成指南
├── CLAUDE.md                           # AI 辅助指引
└── .gitignore
```

## 技术栈

**硬件**: NanoPi R3S (RK3566, 2GB RAM, 2× GbE)  
**内核**: Linux 6.18 arm64  
**软件**: nftables + dnsmasq 为底，WireGuard 由内核提供；按 `INFRA` 叠加 tailscale +
cloudflared，`sing-box` 模式再由 sing-box 接管 DNS（`landscape` 规划中）。
init 随发行版：OpenRC（alpine/gentoo）、systemd（debian）、sysvinit（devuan）、runit（void）。

## 本地裁剪（可选，无需 Armbian 构建环境）

在将配置部署到 Armbian 之前，可先在本 repo 内按需裁剪：

```bash
git clone https://github.com/YOURNAME/nanopi-r3s-kernel
cd nanopi-r3s-kernel

# 默认 minimal 模式（纯路由器，871 y/m，最大裁剪）
./trim-r3s-kernel.sh

# 保留容器栈（Docker/Podman，907 y/m）
./trim-r3s-kernel.sh --mode docker

# 全功能（docker + eBPF；landscape router / cilium / bpftrace / bcc 用这个，943 y/m）
./trim-r3s-kernel.sh --mode full

# 查看帮助
./trim-r3s-kernel.sh --help
```

产物写入 `kernel/rockchip64-current/linux-rockchip64-current.config`。

### 模式对照

| 模式 | Docker | eBPF | y/m | 用途 |
|------|--------|------|-----|------|
| `minimal` | ✗ | ✗ | 871 | 纯路由器，最大裁剪 |
| `docker` | ✓ | ✗ | 907 | 在 minimal 之上加容器栈 |
| `full` | ✓ | ✓ | 943 | 在 docker 之上再加 eBPF/landscape |

## 在 Armbian 构建中使用

```bash
# 1. 克隆 Armbian 构建框架
git clone https://github.com/armbian/build
cd build

# 2. 将本 repo 作为 userpatches
rm -rf userpatches
git clone https://github.com/YOURNAME/nanopi-r3s-kernel userpatches

# 3. 确保空骨架目录存在（Armbian 约定）
mkdir -p userpatches/{atf,crust,kernel,misc,overlay,u-boot}

# 4. 编译内核（完整命令）
./compile.sh BOARD=nanopi-r3s BRANCH=current kernel KERNEL_CONFIGURE=no KERNEL_GIT="shallow"

#    或使用配置文件简写（读取 config-nanopir3s.conf 中的参数）
./compile.sh kernel nanopir3s

# 5. 编译 U-Boot
./compile.sh BOARD=nanopi-r3s BRANCH=current u-boot KERNEL_CONFIGURE=no KERNEL_GIT="shallow"
#    简写
./compile.sh u-boot nanopir3s

# 6. 编译完整镜像
./compile.sh BOARD=nanopi-r3s BRANCH=current KERNEL_CONFIGURE=no KERNEL_GIT="shallow"
#    简写
./compile.sh nanopir3s
```

## 从产出物提取文件

构建完成后，产物位于 Armbian 构建树根目录的 `output/debs/` 下。以下命令均在 Armbian 构建树根目录执行。

### 提取内核和 DTB

```bash
# kernel deb 包含 vmlinuz + config
# dtb deb 包含设备树 .dtb 文件

mkdir -p /tmp/r3s-kernel
for deb in output/debs/linux-image-*nanopi-r3s*_arm64.deb; do
    dpkg-deb -x "$deb" /tmp/r3s-kernel
done
for deb in output/debs/linux-dtb-*nanopi-r3s*_arm64.deb; do
    dpkg-deb -x "$deb" /tmp/r3s-kernel
done

# 提取产物路径：
#   /tmp/r3s-kernel/boot/vmlinuz-*    → 内核镜像
#   /tmp/r3s-kernel/boot/config-*     → 内核配置
#   /tmp/r3s-kernel/usr/lib/linux-image-*-current-rockchip64/rockchip/rk3566-nanopi-r3s.dtb  → 设备树（注意排除同目录下的 rk3566-nanopi-r3s-lts.dtb）
#   /tmp/r3s-kernel/lib/modules/      → 内核模块

# 重命名方便使用（版本号按实际调整）
cp /tmp/r3s-kernel/boot/vmlinuz-* /tmp/r3s-kernel/vmlinuz
cp /tmp/r3s-kernel/boot/config-* /tmp/r3s-kernel/config
find /tmp/r3s-kernel -name 'rk3566-nanopi-r3s.dtb' \
    -exec cp {} /tmp/r3s-kernel/ \;
```

### 提取 U-Boot

```bash
# u-boot deb 包含 u-boot-rockchip.bin（idbloader + u-boot FIT 合并镜像）
mkdir -p /tmp/r3s-uboot
for deb in output/debs/linux-u-boot-*nanopi-r3s*_arm64.deb; do
    dpkg-deb -x "$deb" /tmp/r3s-uboot
done

# 提取产物路径：
#   /tmp/r3s-uboot/usr/lib/linux-u-boot-current-nanopi-r3s/u-boot-rockchip.bin

# 拷贝到统一目录
find /tmp/r3s-uboot -name 'u-boot-rockchip.bin' -exec cp {} /tmp/r3s-uboot/ \;
```

## 裁剪效果

### 各模式 y/m 配置项数

脚本产物（**olddefconfig 之前**的统计，= `trim-r3s-kernel.sh` 末尾打印的口径）：

| 模式 | =y | =m | 合计 | 相对 minimal |
|------|-----|-----|------|------|
| `minimal` | 835 | 36 | **871** | 基线 |
| `docker` | 865 | 42 | **907** | +36（容器栈） |
| `full` | 899 | 44 | **943** | +72（容器栈 + eBPF/landscape 闭包） |

> 早先版本此处列的是 860/872/894/906，那是另一阶段（olddefconfig 之后）的计数口径，两者不可直接比较。

### 编译产物（minimal 模式）

| 指标 | 上游 Armbian | v2.12 minimal | 改善 |
|------|-------------|---------------|------|
| vmlinuz | 28.5 MiB | 9.0 MiB | -68.4% |
| 模块大小 | 15.7 MiB | 2.0 MiB | -87.3% |
| 模块数量 | 412 | 68 | -83.5% |
| deb 包 | 78 MB | 42 MB | -46.2% |
| 可烧录镜像 | 159 MB | 94 MB | -40.9% |

> 注：docker/full 模式的编译产物大小未单独测量，差距主要在内核模块增量（`OVERLAY_FS`/`VETH`/`BINFMT_MISC` 等 =m 项 + BTF 调试段）。

## 红线保护

没有集中式的检查函数，红线靠两处兜底：

- **脚本内联**：关键项在各自小节用 `set_y` 显式确认（`# 红线确认` 注释）防止被联动关闭——
  TUN、WireGuard、nftables、GMAC、RTC(HYM8563)、RK808 PMIC 等。
- **CI 产物级自检**（真正的闸门）：`.github/workflows/build-kernel.yml` 在编译完成后直接校验
  `boot/config-*`，不通过即中止发布。查的是 12 个路由器核心符号（TUN/WIREGUARD/NF_TABLES/
  IPV6/VLAN/PPPoE/BBR/RPS…），以及 full 模式专属的 eBPF/landscape 闭包。

之所以必须查产物而不是查脚本输出：扩展钩子在构建期还会改写 `.config`，只看 trim 结果会漏判
（2026-08-03 就有 12 项在产物里被静默关掉，直到核对 `boot/config-*` 才暴露）。

## License

MIT
