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
**软件**: OpenRC + nftables + sing-box + WireGuard + tailscale + cloudflared/WARP + easytier

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

### full 的 eBPF 部分对齐 landscape 官方内核指南

`--mode full` 按 [landscape 内核要求](https://landscape.whileaway.dev/zh/intro/requirements.html)
逐项配置，并补齐了指南没写、但依赖不满足就会让选项被 `olddefconfig` 静默丢弃的整条闭包：

| 指南项 | 状态 | 说明 |
|--------|------|------|
| `BPF` / `HAVE_EBPF_JIT` / `ARCH_WANT_DEFAULT_BPF_JIT` | =y | 架构能力声明，`NET=y` 强制 |
| `BPF_SYSCALL` / `BPF_JIT` / `BPF_JIT_DEFAULT_ON` | =y | 核心 |
| `BPF_JIT_ALWAYS_ON` | **n** | 指南要求保持关闭，保留解释器回退 |
| `BPF_UNPRIV_DEFAULT_OFF` / `BPF_PRELOAD` | y / n | 与指南一致 |
| `BPF_LSM` | =y | 同时写 `CONFIG_LSM="lockdown,yama,integrity,bpf"`——Armbian 默认串里没有 `bpf`，不写就不注册 |
| `CGROUP_BPF` / `NETFILTER_BPF_LINK` | =y | |
| `NET_CLS_BPF` / `NET_ACT_BPF` | =m | 新增 B.1 节保留 `NET_CLS`/`NET_CLS_ACT`/`NET_SCH_INGRESS`（clsact）作为挂载点 |
| `BPF_STREAM_PARSER` / `LWTUNNEL_BPF` / `IPV6_SEG6_BPF` | =y | 补齐 `NET_SOCK_MSG`/`LWTUNNEL`/`IPV6_SEG6_LWTUNNEL` 前置 |
| `BPF_EVENTS` | =y | 补齐 `FTRACE`+`PERF_EVENTS`+`KALLSYMS`+`KPROBES`+`KPROBE_EVENTS`+`UPROBES`+`TRACEPOINTS`+`TRACING_SUPPORT` 闭包（Y 节原本全砍）。**`FTRACE` 是硬前置**：`BPF_EVENTS`/`KPROBE_EVENTS`/`UPROBE_EVENTS` 都写在 `kernel/trace/Kconfig` 的 `if FTRACE`(←194) / `endif`(→1241) 块里，`FTRACE=n` 时它们恒为 n，哪怕其他依赖都满足 |
| `HID_BPF` | n | HID 子系统已整体砍除，恒为 n |
| `NETFILTER_XT_MATCH_BPF` | **未开** | **有意偏离**：它依赖 `NETFILTER_XTABLES`，而 `IP_NF_*`/`IP6_NF_*` 已全砍——没有 iptables 链可挂。landscape 的数据面是动态挂到 XDP/TC 的 eBPF，与 iptables 无关 |

**BTF 的依赖链与三个构建期陷阱**（都已处理，但改动别处时容易踩回去）：

```
BTF 要靠 DEBUG_KERNEL 撑起可见性：
  DEBUG_KERNEL=y                 ← "Debug information" choice 是 depends on DEBUG_KERNEL
    └─ 显式选 DEBUG_INFO_DWARF5  ← choice 没有 default；不点名就落回第一个成员 DEBUG_INFO_NONE
         └─ select DEBUG_INFO
              └─ DEBUG_INFO_BTF  ← 它在 Kconfig 里位于 `if DEBUG_INFO` 块内
```
对应到 menuconfig 就是 landscape 官方说的那条路径：*Kernel hacking → Compile-time checks
and compiler options → Debug information (Generate DWARF Version 5 debuginfo)*，选完
*Generate BTF type information* 才出现。

1. `DEBUG_KERNEL` 原本被无条件砍掉（Y.2 节）。它在 full 模式下必须留住，否则整个
   "Debug information" choice 不可见、`DEBUG_INFO` 恒为 n，BTF 连带拿不到。开这个门控本身
   不引入代码，具体调试项仍由 Y 节那一长串 `unset_k DEBUG_*` 逐个关掉。
2. `DEBUG_INFO_DWARF*` 原本被无条件砍掉。该 choice **没有 `default`**，一旦不点名任何成员，
   kconfig 会落在第一个成员 `DEBUG_INFO_NONE` 上。full 模式改为显式 `set_y DEBUG_INFO_DWARF5`。
3. `config-nanopir3s.conf` 里的 `KERNEL_BTF="no"` **不要改成 `"yes"`**。Armbian 在
   `KERNEL_BTF=no` 时会往 `opts_y` 塞 `DEBUG_INFO_NONE`（这就是它"关掉全部调试信息"的实现），
   而 `apply_opts_from_arrays()` 的施加顺序是 **`opts_n` → `opts_y` → `opts_m`**（后写覆盖先写），
   所以 `opts_y` 的 `DEBUG_INFO_NONE=y` 会盖掉我们 `opts_n` 里的 disable。钩子已加
   `remove_from_y_ebpf=("DEBUG_INFO_NONE")`，仅在 full 模式下把它从 `opts_y` 摘掉。
   反过来若改成 `KERNEL_BTF="yes"`，Armbian 会强制 `BPF_JIT_ALWAYS_ON=y`（与指南相反）
   并要求构建机 ≥6451 MiB 可用内存，否则直接 `exit_with_error`。

另外 `BPF_LSM` 的完整依赖是 `BPF_EVENTS && BPF_SYSCALL && SECURITY && BPF_JIT`，而
`SECURITY` 又 `depends on SYSFS && MULTIUSER`。所以 full 模式下 **`MULTIUSER` 必须开**——
Y.8 节原本只在 docker 模式开它，关掉会让整条 `SECURITY` 链从 Kconfig 里消失。

代码结构上按「**eBPF 基底 + docker 叠加**」组织：`full` ＝ `docker` 再加上 eBPF 栈，
`docker` ＝ `minimal` 再加上容器栈。所以像 `MULTIUSER`、`CGROUP_SCHED` 这种两个模式都要的项，
先由 `if [[ $ENABLE_EBPF -eq 1 ]]` 这个基底块声明，docker 块再独立声明一次自己的需求
（`set_y` 幂等），而不是写成 `if DOCKER -eq 0 && EBPF -eq 0` 那种"二选一"的排除式条件。

**未验证项**：依赖闭包参照 mainline v6.18 的 Kconfig 逐条核对（含 `if FTRACE`、`if DEBUG_INFO`
这类纯文本包裹关系），但**尚未跑 `olddefconfig` 或实机编译**（缺解包的内核源码）。
首次 `--mode full` 构建后请核对产物 `.config` 里指南各项是否真的落地。

**构建机要求**：`DEBUG_INFO_BTF` 的 Kconfig 里有 `depends on PAHOLE_VERSION >= 116` 和
`depends on DEBUG_INFO_DWARF4 || PAHOLE_VERSION >= 121`。我们选的是 DWARF5，所以
**构建机必须装 pahole ≥ 1.21**，否则 `DEBUG_INFO_BTF` 会直接不可见、BTF 静默消失。
这与 `KERNEL_BTF="no"` 无关，是宿主机软件版本问题——构建日志里搜 `pahole` 可确认。

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

## 裁剪守护（红线检查）

`trim-r3s-kernel.sh` 每次运行后自动校验关键功能不被误裁（`check_red_line` 函数）：

- **RED_LINE_STRICT_Y** (必须=y): WireGuard (CURVE25519/BLAKE2S/CHACHA20POLY1305)、ext4、TUN、GMAC 驱动（DWMAC_ROCKCHIP）、RTC（HYM8563）
- **RED_LINE_EXIST** (至少=m): nftables、Netfilter、NAT、VLAN、PPPoE、bonding
- **反向检查**: WireGuard 依赖链完整性（任一依赖被 disable 则失败）

运行结束后自动打印生成 config 的 =y / =m / 合计 计数和当前模式。

## License

MIT
