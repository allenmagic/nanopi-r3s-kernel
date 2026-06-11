# r3s-kernel-trim

NanoPi R3S 路由器专用最小化内核配置工具链。

基于 Armbian build framework，将上游 5935 项内核配置裁剪至 879 项（-85.2%）。

## 目录结构

```
r3s-kernel-trim/
├── trim-r3s-kernel.sh                  # 内核配置裁剪脚本（A-Z 共 35+ 节）
├── olddefconfig-r3s.sh                 # Kconfig 依赖解析（make olddefconfig 封装）
├── config-nanopir3s.conf               # R3S 构建参数（Argbian compile.sh 用）
├── linux-rockchip64-current.config     # 最终裁剪产物（核心交付件）
├── extensions/
│   └── nanopir3s-kconfig.sh            # Armbian 扩展钩子（移除 Armbian opts 注入）
├── docs/
│   ├── r3s-device.md                   # R3S 硬件规格
│   ├── trim-requirement.md             # 裁剪需求清单
│   └── build-r3s-alpine.md             # Alpine Linux 集成指南
└── CLAUDE.md                           # AI 辅助指引
```

## 技术栈

**硬件**: NanoPi R3S (RK3566, 2GB RAM, 2× GbE)  
**内核**: Linux 6.18 arm64  
**软件**: OpenRC + nftables + sing-box + WireGuard + tailscale + cloudflared/WARP + easytier

## 快速开始

```bash
# 1. 克隆 Armbian 构建框架
git clone https://github.com/armbian/build
cd build

# 2. 将本 repo 作为 userpatches
rm -rf userpatches
git clone https://github.com/YOURNAME/r3s-kernel-trim userpatches

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

| 指标 | 原始 | v2.10 | 改善 |
|------|------|--------|------|
| =y 项 | — | 806 | — |
| =m 项 | — | 73 | — |
| 总配置项 | 5935 | 879 | -85.2% |
| vmlinuz | 28.5 MiB | 9.0 MiB | -68.4% |
| 模块大小 | 15.7 MiB | 2.0 MiB | -87.3% |
| 模块数量 | 412 | 68 | -83.5% |
| deb 包 | 78 MB | 42 MB | -46.2% |
| 可烧录镜像 | 159 MB | 94 MB | -40.9% |

## 裁剪守护（红线检查）

`trim-r3s.sh` 每次运行后自动校验关键功能不被误裁：

- **STRICT_Y**: WireGuard、ext4、TUN、GMAC 驱动（RTL8211F）、RTC（RK808）
- **EXIST**: nftables、Netfilter、NAT、VLAN、PPPoE、bonding
- **反向检查**: WireGuard 依赖链完整性

## License

MIT
