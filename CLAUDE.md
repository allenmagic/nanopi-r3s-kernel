# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository context

This is a standalone toolchain repo designed to be deployed as the `userpatches/` directory inside an Armbian Linux build framework checkout (`armbian/build`; `VERSION` = 26.05.0-trunk). All custom work targets one goal: a minimal, trimmed kernel config for a **NanoPi R3S** router build — pure router role running userspace network tools (sing-box, WireGuard, tailscale, cloudflared/WARP, easytier), no display / wireless / Bluetooth / virtualization. By default also cuts Docker/container runtime (optional via `--mode docker` / `--mode full`). Those tools all rely on the kernel `TUN` device (`CONFIG_TUN`, kept in the red line), so trimming must never drop it.

When deployed, this repo's files go into `userpatches/`. When working locally, the repo is self-contained at its own root — the trimming script reads baseline from `samples/` and writes output to `kernel/rockchip64-current/linux-rockchip64-current.config`. The `olddefconfig-r3s.sh` still references `userpatches/linux-rockchip64-current.config` as its default (when deployed inside an Armbian build tree).

## Commands

When deployed inside an Armbian build tree, all commands run from the Armbian build root (e.g. `/home/zhengyouxin/Projects/build`). When working on this repo standalone, run from the repo root.

### Building (upstream Armbian CLI)
```bash
./compile.sh                                   # interactive build
./compile.sh BOARD=nanopi-r3s BRANCH=current   # build R3S image, current kernel
./compile.sh BOARD=nanopi-r3s BRANCH=current kernel          # kernel artifact only
./compile.sh BOARD=nanopi-r3s BRANCH=current KERNEL_CONFIGURE=yes  # open menuconfig
```
Requires root/sudo. Host: Ubuntu 24.04 / Armbian, or any Docker-capable Linux for containerized builds.

### Kernel config trimming toolchain (the custom work)
```bash
# 1. Trim the config (disables unneeded subsystems, enforces a "red line" of must-keep options)
#    输入 baseline: samples/linux-rockchip64-current.config.baseline
#    输出 config:   kernel/rockchip64-current/linux-rockchip64-current.config
./trim-r3s-kernel.sh                       # 默认 minimal 模式（纯路由器，最大裁剪）
./trim-r3s-kernel.sh --mode minimal        # 同上，显式指定
./trim-r3s-kernel.sh --mode docker         # 保留容器栈（Docker/Podman 可运行）
./trim-r3s-kernel.sh --mode ebpf           # 保留 eBPF 工具链（cilium/bpftrace/bcc）
./trim-r3s-kernel.sh --mode full           # docker + ebpf 全开
./trim-r3s-kernel.sh --help                # 用法
# 运行结束打印生成 config 的 =y / =m / 合计 计数 + 当前模式

# 2. Resolve Kconfig dependencies after trimming (runs `make olddefconfig` against real kernel source)
./olddefconfig-r3s.sh            # auto-locates unpacked kernel source under cache/sources
./olddefconfig-r3s.sh -n         # dry-run: print what it would do
./olddefconfig-r3s.sh -k <kernel-src-dir>   # point at source manually
```
`olddefconfig-r3s.sh` needs unpacked kernel source. If none exists, trigger one with a kernel build first (see Building above). Both scripts auto-backup the config before writing (`.bak.<epoch>` / `.before-olddef.<ts>`).

### 裁剪模式（`--mode`，v2.12 新增）

`trim-r3s-kernel.sh` 支持四种模式，按需保留 eBPF / 容器（Docker/Podman）支持：

| 模式 | Docker | eBPF | 实测 y/m 合计 | 用途 |
|------|--------|------|--------------|------|
| `minimal`（默认） | ✗ | ✗ | 860 | 纯路由器，最大裁剪 |
| `ebpf` | ✗ | ✓ | 872 | cilium / bpftrace / bcc 网络调试 |
| `docker` | ✓ | ✗ | 894 | 在 R3S 上跑容器化服务 |
| `full` | ✓ | ✓ | 906 | 全功能 |

实现要点（脚本内用 `ENABLE_DOCKER` / `ENABLE_EBPF` 标志包裹原裁剪块）：
- **docker** 在 docker 模式恢复：`MULTIUSER`+全套 namespaces、`USER_NS`、`MEMCG`、`CPUSETS`、`CGROUP_*` controllers、`CGROUP_SCHED`+`FAIR_GROUP_SCHED`+`CFS_BANDWIDTH`、`BLK_CGROUP` 全链、`OVERLAY_FS`/`VETH`/`MACVLAN`/`IPVLAN`/`BRIDGE`(=m)、`BINFMT_MISC`。注意 H1 节原本无条件再砍 `BRIDGE`，已加 docker 守卫；`FREEZER` 同理（由 `CGROUP_FREEZER` select）。
- **ebpf** 在 ebpf 模式恢复：`BPF_SYSCALL`、`CGROUP_BPF`、`BPF_JIT`、`XDP_SOCKETS`、`BPF_EVENTS`、`NET_CLS_BPF`/`NET_ACT_BPF`、`DEBUG_INFO`+`DEBUG_INFO_BTF`(+MODULES，CO-RE 必需)。
- 脚本运行后把模式写入 `.trim-mode` 标记文件（gitignored），供扩展钩子读取——见下方"扩展钩子模式同步"。

**已知未决（需实机验证）**：docker 模式下钩子仍砍掉全部 `IP_NF_*`/xtables，故 Docker 默认 iptables 后端不可用，需让 Docker 走 nftables 后端或 `--iptables=false`。容器/eBPF 的完整依赖闭包尚未跑 olddefconfig 验证。

## How the custom config reaches the build

Armbian's `prepare_kernel_config_core_or_userpatches` (in `lib/functions/compilation/kernel-config.sh`) checks for `userpatches/$LINUXCONFIG.config` and uses it **in place of** the in-tree `config/kernel/$LINUXCONFIG.config` when present. For the R3S, `LINUXCONFIG` resolves to `linux-rockchip64-current`, so `userpatches/linux-rockchip64-current.config` is the file that actually gets compiled. That is why the trimming scripts target exactly that filename.

Board mapping: `config/boards/nanopi-r3s.csc` → `BOARDFAMILY=rk35xx`, `KERNEL_TARGET=current,edge`. (`nanopi-r3s-lts.conf` is a separate LTS variant.)

## trim-r3s-kernel.sh structure

Single self-contained bash script. Key pieces:
- Helpers: `disable_config` (→ `# CONFIG_X is not set`), `set_y`, `set_m`.
- `trim_A` (hardware drivers), `trim_B` (subsystems), `trim_C` (advanced features) — each disables large arrays of `CONFIG_*` symbols:
  - **A.1**: GPU/DRM/display
  - **A.2**: Multimedia (V4L/DVB/Radio) + joystick
  - **A.3**: Sound cards
  - **A.4**: WLAN vendor drivers
  - **A.5**: Ethernet vendor switches (keep REALTEK only), DSA switch chips, WWAN/cellular
  - **A.6**: Touchscreen/HID devices
  - **A.7**: Industrial buses
  - **B.1**: CAN/NFC/IIO/industrial
  - **B.2**: RTC/Watchdog vendor drivers
  - **B.2.5**: Server storage controllers (SCSI RAID), datacenter hardware (CXL/VFIO)
  - **B.3**: Crypto vendor drivers + obscure algorithms (SEED, NHPOLY1305, etc.)
  - **B.4**: Kernel debugging/profiling + embedded config/headers (IKCONFIG/IKHEADERS)
  - **C.1**: Obscure filesystems (NTFS3, ZONEFS, CRAMFS, etc.)
  - **C.2**: Obscure block devices
  - **C.3**: Virtualization (KVM/XEN/VirtIO)
  - **C.4**: Advanced memory management
  - **C.5**: Security modules (SELinux/SMACK/IMA/EVM/INTEGRITY)
  - **C.6**: Scheduler/tracing
  - **C.7**: Network filesystems (NFS/CIFS/Ceph/9P)
  - **C.8**: Bluetooth + wireless stack (CFG80211/MAC80211/RFKILL/802.15.4)
  - **C.9**: Obscure network protocols (TIPC/BATMAN_ADV/ATALK/ATM/X25/etc.), tunnels (L2TP/PPTP/GENEVE), precision time sync (PTP/PPS)
- `trim_D` — fourth round (deep sub-driver cleanup):
  - **D.1**: DRM panel drivers (60+ specific panel models)
  - **D.2**: DRM bridges/encoders (40+ items)
  - **D.3**: Rockchip display subsystem (VOP/HDMI/MIPI/LVDS/RGB)
  - **D.4**: HID sensor/gamepad-specific drivers
  - **D.5**: Input device redundancy (beeper/vibrate/joydev)
  - **D.6-D.7**: USB serial leftovers, RTC vendor residuals
  - **D.8**: Entire SND_SOC tree (150+ codec drivers)
  - **D.9**: Xen/Hyper-V/VMware residuals
  - **D.10**: IO schedulers (BFQ/KYBER), KEXEC, UFS, non-RK regulators
  - **D.11**: IR infrared receivers
  - **D.12**: USB host/PHY vendor drivers (non-RK)
  - **D.13**: TCP congestion control (14 removed, kept CUBIC+BBR)
  - **D.14**: FOU/VXLAN/MACSEC/industrial Ethernet
  - **D.15**: USB Gadget non-essential (HID/printer/Mass Storage)
  - **D.16**: PHYLIB_LEDS
- `trim_E` — fifth round (driver-level cleanup + cold subsystem residuals):
  - **E.0**: BUGFIX: re-enable RTC_DRV_HYM8563 (R3S onboard RTC)
  - **E.1**: Backlight drivers (9 items)
  - **E.2**: Non-essential ETH PHY (30 items, keep Realtek/Rockchip/Motorcomm)
  - **E.3**: Crypto USER API (6 items)
  - **E.4**: Crypto HW non-Rockchip (8 items)
  - **E.5**: Crypto obscure algorithms (12 items: AEGIS128/ECRDSA/LRW/PCBC/MD4/etc.)
  - **E.6**: Crypto SIMD for SM3/SM4/SHA3/NHPOLY1305 (7 items)
  - **E.7**: USB Gadget non-essential (7 items)
  - **E.8**: LED triggers non-essential (6 items)
  - **E.9**: GPIO expanders non-Rockchip (18 items)
  - **E.10**: I2C USB adapters/test stubs (9 items)
  - **E.11**: SPI non-Rockchip (21 items)
  - **E.12**: Regulator non-Rockchip (33 items)
  - **E.13**: PWM non-Rockchip (7 items)
  - **E.14**: Watchdog non-core (6 items)
  - **E.15**: PINCTRL non-Rockchip (3 items)
  - **E.16**: XZ Decoder non-ARM64 arch filters (7 items)
  - **E.17**: HWMON I2C/SPI sensors (~165 items, keep GPIO_FAN + ARM_SCPI)
  - **E.18**: NLS charsets cold (5 items)
  - **E.19**: Network qdisc cold (25 items, keep HTB/HFSC/FQ_CODEL/CAKE/INGRESS)
  - **E.20**: Network classifier/actions cold (18 items)
- `check_red_line` — the safety gate. Three tiers:
  - `RED_LINE_STRICT_Y`: must be `=y` (e.g. `ARM64`, `NET`, `EXT4_FS`, WireGuard crypto-lib primitives).
  - `RED_LINE_EXIST`: must be `=y` or `=m` (netfilter, nftables, NAT, VLAN, WIREGUARD, TUN, GMAC Ethernet, RTC).
  - `RED_LINE_OPTIONAL`: warn only.
  - Plus a reverse WireGuard guard: fails if any WireGuard dependency is explicitly disabled.
- `main` runs trim_A through trim_W (23 rounds), then `check_red_line`; **on red-line failure it restores the backup and exits 1**. Never let a change ship that breaks the red line.

When editing trimming logic: the red-line lists encode hard requirements for the router workload (networking stack, netfilter, WireGuard). Treat them as invariants — add disables, but verify against `check_red_line` rather than weakening it. The reference list of intended-to-remove subsystems is in `docs/trim-requirement.md`.

**v2.1 (2026-06-11):** 基于 v2.0 编译产物（973 项）逐类分析，新增 ~50 项裁剪。868(y/m)。

**v2.10 (2026-06-11):** MULTIUSER 禁用（⚠️ v2.12 撤回）。EFI_PARTITION 撤回（Armbian R3S 镜像用 GPT）。842→845(y/m)，编译实测 895→879(-16), vmlinuz 10.0→9.0MiB(-9.5%)。

**v2.10 新增裁剪：**
- MULTIUSER（OpenRC 单用户路由不需）
- INIT_STACK_ALL_PATTERN→NONE / RANDOMIZE_BASE+RELOCATABLE / NET_IP_TUNNEL / VDSO_GETRANDOM

**v2.11 (2026-06-16):** 撤回 3 项误裁，修复启动后功能异常
- **FILE_LOCKING**：unset → set_y，OpenRC 服务管理依赖 fcntl/flock，禁用后无法管理服务
- **IP_MULTICAST**：撤回禁用，IPv6 NDP 邻居发现依赖组播（v2.10 误裁）
- **RTC_DRV_HYM8563**：再次撤回，R3S 板载 RTC（DTB rtc@51），砍掉导致 rtc0 缺失、TLS 校时失败

**v2.12 (2026-06-17 ~ 2026-06-18, current):** MULTIUSER 撤回 + 项目结构重构 + 裁剪模式
- **MULTIUSER 撤回**（dda8731）：v2.10 禁用 MULTIUSER 导致 setgroups() syscall 不可用（ENOSYS），chronyd 无法启动，OpenRC start-stop-daemon: unable to set groupid。恢复为 CONFIG_MULTIUSER=y。docker 模式下 MULTIUSER 本身也需要保留（NAMESPACES depends on it）。
- **项目结构重构**（32320f3）：
  - 输入：root-level `linux-rockchip64-current.config.baseline` → `samples/linux-rockchip64-current.config.baseline`
  - 输出：root-level `linux-rockchip64-current.config` → `kernel/rockchip64-current/linux-rockchip64-current.config`
  - 清理 root 级别遗留 config 文件
- **裁剪模式 `--mode` 参数**（32320f3）：新增四种模式（见上方"裁剪模式"章节），脚本内用 `ENABLE_DOCKER` / `ENABLE_EBPF` 标志包裹原裁剪块。C 节（容器网络/store）、K 节（BPF 终结者）、M 节（systemd cgroup）、Y.3/ Y.6/ Y.10 各节均按标志有条件执行。
- **扩展钩子模式同步**（32320f3）：`extensions/nanopir3s-kconfig.sh` 新增 keep_set 机制——从 `.trim-mode` 标记文件或 `R3S_TRIM_MODE` 环境变量检测当前模式，docker/ebpf 保护符号在 opts_y/opts_m 过滤、opts_n 追加、.config 直写三处全部跳过。解决 trim 脚本开启的项被钩子再次关闭的问题。
- **脚本输出增强**：末尾新增生成 config 的 =y / =m / 合计 计数 + 模式打印。
- 实测数据：minimal 860(y/m)，ebpf 872，docker 894，full 906。基线 888(y/m)。

**v2.8 新增裁剪：**
- LRU_GEN x3（多代LRU）+ PWM_ROCKCHIP x2（R3S DTS无PWM）+ PER_VMA_LOCK（def_bool y）

**v2.7 新增裁剪：**
- TMPFS_POSIX_ACL → 级联清除 FS_POSIX_ACL（select 链根节点）

**v2.6 新增裁剪：**
- DEBUG_BUGVERBOSE（~70KB）+ CPU_FREQ_DEFAULT_GOV_PERFORMANCE→SCHEDUTIL

**v2.5 新增裁剪：**
- DW_WATCHDOG / GPIOLIB_LEGACY / GPIO_CDEV_V1 / RTC_I2C_AND_SPI / RTC_NVMEM

**v2.4 新增裁剪：**
- TRACING_SUPPORT / SCSI_MOD / DUMMY / PRINTK_TIME / PCI_SYSCALL / DECOMPRESS_ZSTD

**v2.3 新增裁剪：**
- **Y.5 扩展**: CRYPTO_CHACHA20（孤儿，WireGuard用LIB版本，ADIANTUM/CHACHA20POLY1305均n）
- **Y.6 新增**: ZLIB_DEFLATE / LZO_DECOMPRESS（孤儿压缩库）+ FREEZER
- **扩展钩子 v2.3**: opts_n +4 项

**v2.2 新增裁剪：**
- **Y.5 新增**: LED_TRIGGER_PHY / HW_PERF_EVENTS / VM_EVENT_COUNTERS / INITRAMFS_PRESERVE_MTIME / CRYPTO_JITTERENTROPY（~5 项）
- **扩展钩子 v2.2**: opts_n +5 项

**v2.1 新增裁剪：**
- **Y 节扩展**: PERF_EVENTS / KALLSYMS / ELFCORE（调试/性能监控全砍）
- **Y.2 新增**: nftables 冗余模块（DUP/FWD/QUOTA/HASH/SOCKET/TPROXY/FIB 等 ~25 项）+ conntrack 瘦身（LABELS/ZONES/EVENTS）+ NETFILTER_FAMILY_BRIDGE/ARP
- **Y.3 新增**: 内核框架瘦身（MEMCG/DEBUG_KERNEL/POWER_SUPPLY/CPU_FREQ_GOV_ONDEMAND/CPU_IDLE_GOV_MENU 等 ~20 项）
- **Y.4 新增**: 安全可砍残余（ARM_PMU/ARM_PMUV3/RPS/XPS/SYSCTL_EXCEPTION_TRACE/ANON_VMA_NAME/CONTIG_ALLOC/MIGRATION/AF_UNIX_OOB/FS_POSIX_ACL/EXT4_FS_POSIX_ACL ~12 项）
- **C 节扩展**: BRIDGE + BRIDGE_VLAN_FILTERING（纯路由器不需要桥接）
- **R 节扩展**: CMA 全关 + COMPACTION（无 GPU/VPU/Docker 不需要连续内存）
- **扩展钩子 v2.1**: remove_from_y +31 项, remove_from_m +25 项, opts_n +62 项（含 Y.4）

**关键保留项**: NFT_FLOW_OFFLOAD + NF_FLOW_TABLE（软件 fast-path，性能核心，永不裁剪）

**v2.0 结构（A–Z，26 节）：**
- **A**: NETFILTER_XTABLES + xt_* 全链关闭（~40 模块）
- **A.2**: BRIDGE_NETFILTER + ebtables 根因链（~30 项）
- **B**: NET_SCHED / tc qdisc/classifier/action 全关（无 QoS 需求）
- **C**: 容器专用网络/存储裁剪 — VETH/MACVLAN/IPVLAN/VXLAN/OVERLAY_FS + BRIDGE（纯路由不需桥接，namespaces/cgroup 框架保留）
- **D**: SQUASHFS 全关
- **E**: EFI / SMMU / COMPAT 关闭
- **F**: Rockchip 硬件加密引擎关闭
- **G**: 不常用网络隧道关闭
- **H**: NF_CONNTRACK helper 精简
- **H.2**: 冷门 netfilter 模块清除（~16 项）
- **H.3**: 孤儿网络/非 RK3566/可选精简（~8 项）
- **I**: nftables 全套红线确认
- **J**: 用户态工具红线确认（TUN/WireGuard/PPP/bonding/VLAN）
- **K**: BPF 终结者（BPF=y 由 NET=y 强制 select 无法禁用，禁 BPF_SYSCALL/CGROUP_BPF）
- **L**: USB 子系统全栈砍除（~1.3MB）
- **M.0**: SECURITY_APPARMOR + AUDIT 链（根因修复）
- **M**: systemd 专属 cgroup/特性砍除（POSIX_MQUEUE/USER_NS/BLK_CGROUP/CGROUP_SCHED 等）
- **N**: 内核统计接口砍除
- **O**: KEXEC / Crash dump 砍除
- **P**: INPUT 子系统极简（仅保留 GPIO 按键）
- **Q**: 加密接口精简
- **R**: ZRAM/ZSWAP 精简 + CMA 全关 + COMPACTION 关闭
- **S**: 块设备调优 / 其他平台 MMC 砍除
- **T**: 文件系统冗余砍除
- **U**: PHY 驱动精简
- **V**: MD/DM 全栈砍除（~300KB）
- **W**: 声卡/多媒体/图形兜底
- **X**: 无线/蓝牙/NFC/红外砍除
- **Y**: 调试/Tracing 全砍（PERF_EVENTS/KALLSYMS/ELFCORE + ftrace/kprobes/coresight）
- **Y.2**: nftables 冗余模块/conntrack 瘦身（DUP/FWD/QUOTA/HASH/SOCKET/TPROXY/FIB + NETFILTER_FAMILY_BRIDGE/ARP）
- **Y.3**: 内核框架瘦身（MEMCG/DEBUG_KERNEL/POWER_SUPPLY/CPUFREQ ondemand/CPU_IDLE menu/LED 触发器/SERIAL_8250_FSL/CRYPTO_SHA3/ECB/HW）
- **Z**: 总线/传感器/RTC 等冗余驱动清扫

**P0 修复（扩展钩子 `extensions/nanopir3s-kconfig.sh`）：**
- Section 0: 从 Armbian `opts_y` 数组中删除项（v2.0: ~55 项 BPF/AppArmor/systemd cgroup/IKCONFIG; v2.1: +31 项 BRIDGE/MEMCG/PERF_EVENTS/KALLSYMS/CMA 等）
- Section 1: 从 Armbian `opts_m` 数组中删除项（v2.0: ~180 项 ebtables/xtables/ipset/VETH 容器网络; v2.1: +25 项 NFT_DUP/FWD/QUOTA/HASH/SOCKET/TPROXY/FIB 等）
- Section 2: 所有项同时追加 `opts_n` 双重保险（v2.1: +53 项）
- Section 3: 直接 sed 修改 config 文件作为最终兜底
- **v2.12**: 以上四处（opts_y 过滤、opts_m 过滤、opts_n 追加、.config 直写）均增加 keep_set 守卫，docker/ebpf 模式下保护对应符号不被误关


## 历史版本

### v1.x 裁剪轮次（2026-05-29 ~ 2026-06-05，已由 v2.0 取代）

**v1.x 最终数据:** 23 rounds (A–W, W 含 28 子轮), ~4684 items disabled, 5935 → 1251 items (~78.9% reduction). vmlinuz 14.3 MiB, modules 8.7 MiB, deb 55 MB.

### Rounds A–C (2026-05-29): initial broad-stroke trimming
- **A**: Hardware drivers — GPU/DRM, multimedia, sound, WLAN, Ethernet vendors (keep REALTEK only), DSA switches, WWAN, touchscreen, industrial buses, USB network adapters (fully removed in W), battery/charger, LED chip drivers, HWMON I2C sensors, SCSI/SATA advanced, non-RK MMC drivers.
- **B**: Subsystems — CAN/NFC/IIO, RTC/Watchdog vendors, server storage (SCSI RAID), datacenter (CXL/VFIO), crypto vendors + obscure algorithms, kernel debug (IKCONFIG/IKHEADERS), power management (SUSPEND/HIBERNATION), I2C/SPI userspace interfaces.
- **C**: Advanced features — obscure filesystems (NTFS3/ZONEFS/CRAMFS/ISO9660/UDF), obscure block devices, virtualization (KVM/XEN/VirtIO), memory management (ZSWAP/KSM), security modules (SELinux/SMACK/IMA/EVM/INTEGRITY), scheduler/tracing, network filesystems (NFS/CIFS/Ceph/9P), Bluetooth + wireless stack, obscure network protocols/tunnels (TIPC/BATMAN_ADV/L2TP/PPTP/GENEVE/PTP/PPS), RAID/LVM (MD/DM_CRYPT/DM_SNAPSHOT), USB serial converters (50+ removed, kept core), USB printer/modem, input redundancy.

### Round D (2026-05-29): deep sub-driver cleanup (~300 items)
- DRM panel drivers (60+), DRM bridges/encoders (40+), Rockchip display subsystem (VOP/HDMI/MIPI/LVDS/RGB), HID sensor/gamepad drivers, input redundancy (beeper/vibrate/joydev), USB serial leftovers, RTC vendor residuals, entire SND_SOC tree (150+ codec drivers), Xen/Hyper-V/VMware residuals, IO schedulers (BFQ/KYBER), KEXEC, UFS, non-RK regulators, IR receivers, USB host/PHY non-RK, TCP congestion control (14 removed, kept CUBIC+BBR), FOU/VXLAN/MACSEC, USB Gadget non-essential, PHYLIB_LEDS.

### Round E (2026-05-29): driver-level cleanup + cold subsystem residuals (~200 items)
- **BUGFIX**: re-enable RTC_DRV_HYM8563 (R3S onboard RTC). Backlight (9), non-essential ETH PHY (30, keep Realtek/Rockchip/Motorcomm), Crypto USER API (6), Crypto HW non-Rockchip (8), Crypto obscure algorithms+SIMD (19), USB Gadget functions (7), LED triggers (6), GPIO expanders non-RK (18), I2C USB adapters (9), SPI non-RK (21), Regulator non-RK (33), PWM non-RK (7), Watchdog non-core (6), PINCTRL non-RK (3), XZ Decoder non-ARM64 filters (7), HWMON I2C/SPI sensors (~165), NLS charsets (5), network qdisc (25, keep HTB/HFSC/FQ_CODEL/CAKE/INGRESS), network classifier/actions (18).

### Round F (2026-05-30): R3S hardware-specific (~80 items)
- PCIe Endpoint framework, Rockchip display/camera/PCIe3 PHYs (10), SATA AHCI (7), CLK non-RK, MFD non-RK PMIC, QCOM CPU errata (6), POWER_RESET non-RK, MMC non-RK, firmware loader debug, CPU_FREQ governors (trim POWERSAVE/USERSPACE/CONSERVATIVE), ARM64 features unsupported by A55 (MTE/EPAN/POE/GCS), netfilter xtables cold (28), IOMMU advanced, EFI non-essential.

### Round G (2026-05-30): eBPF & filesystem slim (~30 items)
- **eBPF fully disabled** (BPF_SYSCALL/BPF_JIT/CGROUP_BPF/NET_CLS_BPF etc. — nftables router doesn't need eBPF).
- Filesystem slim: standalone EXT2, FS_ENCRYPTION, FS_VERITY, PSTORE, AUTOFS_FS, FANOTIFY/DNOTIFY (keep inotify), FUSE advanced (FUSE_PASSTHROUGH/FUSE_IO_URING).
- Cgroup slim: RDMA/PERF/MISC/NET_PRIO/NET_CLASSID (keep Docker-required ones).

### Round H (2026-05-30): accelerators & security (~85 items)
- Cold accelerators (TIFM/BCM_VK/XILINX_SDFEC/NITRO_ENCLAVES/MOST), non-RK PHY/MDIO/HWRNG/MTD.
- KUNIT/TEST all (26 — production router doesn't need kernel self-tests).
- TPM/trusted keys (9 — no TPM chip on R3S).
- Thermal governor slim (keep STEP_WISE only), crypto slim (CRYPTO_842/ZRAM_BACKEND_842/CRYPTO_SEQIV/CRYPTO_LIB_ARC4/CRYPTO_GHASH).
- GPU peripherals (DMABUF_HEAPS/SYNC_FILE/IOMMUFD/IOMMU_SVA/ROCKCHIP_IOMMU), display residuals (FONT_SUPPORT/USB_APPLEDISPLAY).
- Security slim (UNMAP_KERNEL_AT_EL0/ARM64_E0PD/ARM64_BTI/SECURITY_NETWORK_XFRM — A55 not affected by Meltdown).

### Round I (2026-05-30): subsystem deep-dive (~115 items)
- Serial non-RK + line discipline (Fintek/NXP/Xilinx/Moxa/HDLC/GSM), USB non-essential (PCI USB/OHCI/ChipIdea RK3288/HSIC Hub/OTG).
- Devfreq (RK3328/RK3399 DDR — RK3566 has no DMC), EDAC/RAS (LPDDR4 has no ECC), SCSI/NVMe non-essential, SDHCI (keep DW_MMC_ROCKCHIP only).
- IPsec/XFRM slim (WireGuard replacement, keep XFRM core), MPLS/IPv6 advanced/misc networking (Mobile IPv6/SRv6/PPPoATM/TCP MD5/hardware switch framework).
- Conntrack/NAT helpers cold (AMANDA/H323/IRC/NETBIOS/SMTP/TFTP), power management slim.
- IP_VS all removed, multicast routing, diskless boot IP_PNP, USB misc (~40), I2C/GPIO non-RK, xtables conservative slim.
- AppArmor removed (router doesn't need LSM MAC — 9 items incl. SECURITY_NETWORK/SECURITY_PATH/SECURITYFS).

### Round J (2026-05-30): protocol & bus cleanup (~160 items)
- QRTR (Qualcomm IPC Router), MHI (Modem Host Interface), GNSS, COUNTER, AMT, OPENVSWITCH, NET_TEAM (keep bonding), SLIP, RMI4 (Synaptics touch — 10), VMXNET3, NETDEVSIM, NET_IFE, EQUALIZER, NTSYNC.
- Misc PCI devices (CB710/GENWQE/MISC_ALCOR/RTSX/PHANTOM/NOZOMI/XILLYBUS), serial non-RK (16: 8250_PCI/EXAR/PERICOM/JSM/SIFIVE/SC16IS7XX/ALTERA/RP2/FSL/CONEXANT/SPRD/LITEUART).
- IPsec residuals (olddefconfig re-enabled — XFRM_AH/ESP/IPCOMP — 9), non-RK DMA (FSL_QDMA/PLX_DMA/SF_PDMA/ALTERA_MSGDMA/DW_DMAC_PCI/DW_EDMA_PCIE — 6).
- MFD non-RK cold (21), keyboard non-RK, cold drivers/tools (CORDIC/CRC8/INTERRUPT_CNT/KHADAS_MCU_FAN/LITEX_SOC/APPLE_MFI_FASTCHARGE/SERIO_SERPORT/LCD_CLASS/EEPROM_93CX6).
- Netfilter OSF (OS fingerprint), USB Gadget function slim (OBEX/CDC Subset/Multi-Config).

### Round K (2026-05-31): hardware + software stack deep clean (~33 items)
- **K.1**: HiSilicon non-RK (HISI_PCIE_PMU/HI6421V600_IRQ).
- **K.2**: LMK04832 (TI clock jitter cleaner, not on R3S).
- **K.3**: SFP (optical transceiver — no SFP cage on R3S).
- **K.4**: USBIP (USB over IP — router doesn't need).
- **K.5**: Network debug/test (NETCONSOLE/NULL_TTY).
- **K.6**: PMBUS (industrial power management bus).
- **K.7**: REGMAP_SPMI (Qualcomm SPMI).
- **K.8**: SLHC (serial header compression, olddefconfig residual).
- **K.9**: Netfilter SELinux security hooks (IP_NF_SECURITY/IP6_NF_SECURITY).
- **K.10**: Netfilter IPsec/MIPv6/SRv6 matchers (IP6_NF_MATCH_AH/MH/SRH).
- **K.11**: nftables IPsec/OSF match (NFT_XFRM/NFT_OSF).
- **K.12**: CUSE (userspace char device).
- **K.13**: UIO (userspace I/O, DPDK uses it — router doesn't need).
- **K.14**: UHID (userspace HID, headless router).
- **K.15**: NET_VRF (enterprise VRF, home router doesn't need).
- **K.16**: NET_IPVTI (IPsec VTI tunnel).
- **K.17**: MACVTAP/IPVTAP (VM TAP devices, Docker doesn't need).
- **K.18**: BINFMT_MISC (no Docker/container runtime).
- **K.19**: PCIe AER/DOE (advanced error reporting).
- **K.20**: Kernel debug residuals (26 items: DEBUG_KERNEL/DEBUG_FS/FTRACE/TRACING/TRACEPOINTS/KPROBES/UPROBES/MEMTEST/SCHED_INFO etc.).
- **K.21**: Console fonts (FONT_SUPPORT/FONT_8x16/FONT_AUTOSELECT — no VT/FB).
- **K.22**: Network residuals (IP6_NF_MATCH_RPFILTER/IP_NF_MATCH_RPFILTER).

### Round L (2026-05-31): useless hardware/arch/legacy (~45 items)
- **L.1**: PS/2 mouse drivers (10 items: ALPS/BYD/CYPRESS/FOCALTECH/SYNAPTICS/TRACKPOINT).
- **L.2**: PS/2 keyboard + legacy mouse layer (KEYBOARD_ATKBD/INPUT_MOUSE).
- **L.3**: ARM 32-bit legacy (SWP_EMULATION/CP15_BARRIER_EMULATION/SETEND_EMULATION/UID16/COMPAT_32BIT_TIME).
- **L.4**: XZ decoder ARM32 BCJ filters (XZ_DEC_ARM/XZ_DEC_ARMTHUMB).
- **L.5**: Enterprise block devices (NVMe core/driver, BLK_DEV_ZONED, INTEGRITY, WRITE_MOUNTED, BSG — no M.2 slot on R3S).
- **L.6**: x86 legacy/debug (DMI/DEVMEM/CHECKPOINT_RESTORE/BSD_PROCESS_ACCT/TASKSTATS/PSI/RELAY).
- **L.7**: Type-C port controllers/MUX (TYPEC_RT1711H/TPS6598X/HD3SS3220/FSA4480/PI3USB30532/UCSI).
- **L.8**: External connectors (EXTCON_PTN5150/USBC_TUSB320/USBC_VIRTUAL_PD).
- **L.9**: Non-RK3566 SoC drivers (ARM_CCI_PMU/FFA_TRANSPORT/MHU_V2/V3).
- **L.10**: EEPROM drivers (AT24/AT25/EE1004 — no external EEPROM needed).
- **L.11**: NVMEM U-Boot env/RAID attrs/LZ4 modules.

### Round M (2026-05-31): kernel slim (~30 items)
- **M.1**: PCIe virtualization (PCI_ATS/SR-IOV/PCI_SYSCALL).
- **M.2**: Kernel debug residuals (DMA_ENGINE_RAID/SYSTEM_TRUSTED_KEYRING/MODULE_FORCE_UNLOAD/FW_LOADER_SYSFS/PAGED_BUF/ZRAM_TRACK_ENTRY_ACTIME/NETWORK_PHY_TIMESTAMPING).
- **M.3**: Kernel features (SECRETMEM/AIO/KCMP/CROSS_MEMORY_ATTACH/CACHESTAT_SYSCALL/IO_URING_ZCRX).
- **M.4**: Scheduler/time (SCHED_HW_PRESSURE/SCHED_HRTICK).
- **M.5**: Network slim (IPV6_SIT_6RD).
- **M.6**: CPU freq slim (CPU_FREQ_STAT/CPU_FREQ_GOV_ONDEMAND — keep schedutil + performance).
- **M.7**: Irrelevant drivers (SI544/AXI_CLKGEN/XLNX_CLKWZRD/USB_SIERRA_NET/TLS/NLMON).
- **M.8**: Misc (POWER_SUPPLY_HWMON/PROC_PAGE_MONITOR).

### Round N (2026-05-31): non-RK DMA + NLS slim (~22 items)
- **N.1**: DW_DMAC family (RK3566 uses PL330, not DesignWare DMA — DW_DMAC_CORE/DW_DMAC/DW_AXI_DMAC/DW_EDMA/DMA_VIRTUAL_CHANNELS).
- **N.2**: Conntrack helpers (NF_CONNTRACK_PPTP/NF_NAT_PPTP/NF_CONNTRACK_SANE).
- **N.3**: USB_MON (USB debug monitor).
- **N.4**: NLS codepages (keep UTF-8 + CP437 only — 6 CJK/Eastern Europe codepages removed).
- **N.5**: IP tunnels (IPV6_SIT/IPV6_GRE/NET_IPGRE_DEMUX/NET_IPGRE).

### Round O (2026-05-31): Input / USB misc / thermal debug (~14 items)
- **O.1**: PS/2 + AMBA input framework (SERIO/SERIO_LIBPS2/SERIO_AMBAKMI/INPUT_MATRIXKMAP).
- **O.2**: USB misc (NOP_USB_XCEIV/USB_ONBOARD_DEV/USB_LED_TRIG/USB_LEDS_TRIGGER_USBPORT/EXTCON_USB_GPIO/USB_ROLE_SWITCH).
- **O.3**: Thermal debug (THERMAL_STATISTICS/THERMAL_HWMON).

### Round P (2026-05-31): USB Gadget full removal (~8 items)
- **P.1**: DWC2/DWC3 Dual Role → Host-only (USB_DWC2_DUAL_ROLE/USB_DWC3_DUAL_ROLE).
- **P.2**: USB Configfs Gadget functions (ACM/ECM/ECM_SUBSET/NCM/SERIAL).
- **P.3**: USB_GADGET core (router only needs Host mode).

### Round Q (2026-05-31): olddefconfig restore + non-ARM64 (~15 items)
- **Q.1**: olddefconfig re-enabled items (IO_URING_ZCRX re-disabled, LZ4/LZ4HC re-disabled).
- **Q.2**: Non-ARM64/Rockchip drivers (CLK_VEXPRESS_OSC/SERIAL_ARC/MMC_DW_HI3798CV200/MMC_HSQ).
- **Q.3**: Type-C framework residuals (TYPEC/TYPEC_TCPM/TYPEC_TCPCI/TYPEC_FUSB302).

### Round R (2026-05-31): orphaned crypto / DMA residuals / PCI legacy (~14 items)
- **R.0**: **BUGFIX**: re-enable GMAC driver (NET_VENDOR_STMICRO/STMMAC_ETH/STMMAC_PLATFORM/DWMAC_GENERIC/DWMAC_ROCKCHIP — mistakenly disabled by A.5).
- **R.1**: RAID DMA residuals (ASYNC_TX_DMA/DMA_ENGINE_RAID).
- **R.2**: PCI legacy (PCI_SYSCALL/PCIE_PME).
- **R.3**: Orphaned crypto (CRYPTO_DES/CRYPTO_XTS/CRYPTO_CTS/CRYPTO_ECHAINIV).
- **R.4**: initramfs slim (RD_BZIP2/BLK_DEV_RAM).

### Round S (2026-05-31): final cleanup (~11 items)
- **S.1**: Non-R3S PinCtrl (PINCTRL_SX150X/PINCTRL_MAX77620).
- **S.2**: Orphaned clock (COMMON_CLK_PWM).
- **S.3**: Red-line cleanup (LWTUNNEL/DUMMY — MPLS/SRv6 all removed).
- **S.4**: Core Dump/ELF Core (COREDUMP/ELF_CORE — production doesn't need).

### Round T (2026-05-31): module slim (~18 items)
- **T.1**: PPP redundancy (PPP_MPPE/PPP_BSDCOMP/PPP_DEFLATE/PPP_ASYNC/PPP_SYNC_TTY).
- **T.2**: MSDOS_FS (VFAT_FS=y already covers it).
- **T.3**: Packet duplicate/forward (NFT_DUP_IPV4/IPV6/NETDEV, NFT_FWD_NETDEV, NF_DUP_IPV4/IPV6/NETDEV — IDS/monitoring, router doesn't need).
- **T.4**: Obsolete crypto (CRYPTO_LIB_DES/CRYPTO_LIB_ARC4).
- **T.5**: FTP conntrack helper (NF_CONNTRACK_FTP/NF_NAT_FTP).

### Round U (2026-06-01): redundant crypto algorithms (~14 items)
- **U.1**: No-consumer =y crypto (CRYPTO_DEFLATE/CRYPTO_ZSTD/CRYPTO_LZO — only ZSWAP used these, ZSWAP already removed).
- **U.2**: Redundant/orphaned =m crypto (CRYPTO_AES_TI/CRYPTO_DES/CRYPTO_LIB_DES/CRYPTO_SM3_GENERIC/CRYPTO_LIB_SM3/CRYPTO_GCM/CRYPTO_GHASH/CRYPTO_ECDSA/CRYPTO_SHA1/CRYPTO_LZ4/CRYPTO_LZ4HC).

### Round V (2026-06-01): non-R3S drivers + legacy GPIO (~8 items)
- **V.1**: Non-R3S PMIC/GPIO (GPIO_MAX77620/GPIO_PL061/GPIO_XILINX/REGULATOR_MAX77620/REGULATOR_ACT8865).
- **V.2**: Legacy GPIO interfaces (GPIO_SYSFS/GPIO_SYSFS_LEGACY/GPIOLIB_LEGACY).

### Round W (2026-06-04 ~ 2026-06-05): 全面深度裁剪，25 子轮，1458 → 1254 (-204 项)

- **W.1**: USB 网卡框架全裁 — USB_RTL8152/USB_USBNET/USB_NET_DRIVERS + USB_UAS/USB_SERIAL + SIP ALG (NF_CONNTRACK_SIP/NF_NAT_SIP) + NF_CT_NETLINK_HELPER. 红线移除 USB_SERIAL.
- **W.2**: MTD / SPI NOR Flash + SPI 总线整链 — MTD 全链 (47+), SPI_MEM, SPI/SPI_MASTER/SPI_PL022/SPI_ROCKCHIP.
- **W.3**: CONFIGFS/DT Overlay — CONFIGFS_FS, OF_CONFIGFS, OF_OVERLAY.
- **W.4**: CRYPTO_DEV_ROCKCHIP_TRNG 去重 (保留 HW_RANDOM_ROCKCHIP=m).
- **W.5**: 非 R3S 硬件/孤儿 — ATA, SERIAL_AMBA_PL010/PL011 + CONSOLE, ARM_AMBA, MFD_RK8XX_SPI, MFD_MAX77620, PMIC_ADP5520.
- **W.6**: 非 RK3566 CLK 驱动 — CLK_PX30/RK3308/RK3328/RK3368/RK3399/RK3528/RK3562/RK3576/RK3588 (9 项).
- **W.7**: 非 A55/非 RK 服务器 ARM errata — Ampere/Cavium/Fujitsu/HiSilicon/NVIDIA (12 项).
- **W.8**: 内核特性精简 — ALLOW_DEV_COREDUMP, RTC_INTF_SYSFS, POSIX_MQUEUE + SYSCTL, EXT4_FS_SECURITY. CONFIG_LSM 修正 (清除已禁用 LSM 引用).
- **W.9**: 模块裁剪 — SENSORS_GPIO_FAN, NET_EMATCH 全链 (CMP/U32/EMATCH), IP_NF_MATCH_AH.
- **W.10**: 孤儿框架/sysfs — WATCHDOG_SYSFS, EXPORTFS, EXPORTFS_BLOCK_OPS, NETWORK_FILESYSTEMS.
- **W.11**: FAT/FUSE =y→=m — FAT_FS/VFAT_FS/FUSE_FS (R3S 单分区 ext4, 无 /boot FAT).
- **W.12**: ZRAM 后端精简 — 5→2 (保留 LZ4+ZSTD), 默认 lzo-rle→lz4.
- **W.13**: 非对称密钥链全裁 — KEYS/ASYMMETRIC_KEY/PUBLIC_KEY/X509/PKCS7/CRYPTO_RSA/DH/ECC/ECDH/AKCIPHER/ASN1/OID (13 项).
- **W.14**: ZRAM/DAX/netlink glue — ZRAM_MULTI_COMP, ZRAM_WRITEBACK, DAX, NETFILTER_NETLINK_GLUE_CT.
- **W.15**: 非 A55 ARM64 特性/非 RK 平台 — ARM64_SME/SVE/PTR_AUTH/AMU_EXTN/BRBE, SOCIONEXT_SYNQUACER, SURFACE_PLATFORMS, VEXPRESS_CONFIG, MV_XOR_V2, PARAVIRT, DWC_PCIE_PMU.
- **W.16**: 遗留接口/企业功能 — DEVPORT, LEGACY_PTYS, LEGACY_TIOCSTI, KUSER_HELPERS, BRIDGE_IGMP_SNOOPING, NETWORK_SECMARK, DCB, CRYPTO_DH_RFC7919_GROUPS.
- **W.17**: 空菜单/残留框架 — VIRT_DRIVERS, VIRTIO_MENU, AUXDISPLAY/CHARLCD, SSB_POSSIBLE, BCMA_POSSIBLE, BOOT_CONFIG, BLOCK_LEGACY_AUTOLOAD, ELFCORE.
- **W.18**: 冷门模块 — NET_ACT_SIMP, NET_ACT_CSUM, NFT_NUMGEN, NET_IPIP.
- **W.19**: 前轮残留 — KEYS_REQUEST_CACHE, REGMAP_SPI, SPMI, SCSI_LOWLEVEL, FW_UPLOAD, PPP_FILTER, PPP_MULTILINK.
- **W.20**: 深层孤儿 — ASYNC_TX_ENABLE_CHANNEL_SWITCH, LEGACY_DIRECT_IO, BLK_RQ_ALLOC_TIME, CLS_U32_PERF/MARK.
- **W.21**: 空框架 — HID/HID_SUPPORT (零驱动), HOTPLUG_PCI (焊死 NIC).
- **W.22**: USB 存储/FAT 全裁 — EXFAT_FS, FAT_FS, VFAT_FS, FUSE_FS, NLS/NLS_UTF8/NLS_CODEPAGE_437/NLS_ASCII/UNICODE. 红线移除 FUSE_FS.
- **W.23**: SCSI 全裁 — USB_STORAGE/BLK_DEV_SD/SCSI/SCSI_MOD/SCSI_COMMON/SCSI_DMA. BLK_DEV_LOOP =y→=m. 红线移除 USB_STORAGE.
- **W.24**: 孤儿库/端序 — MPILIB, TUN_VNET_CROSS_LE, EXTCON/EXTCON_GPIO.
- **W.25**: 边缘孤儿 — VMGENID, ARMV8_DEPRECATED, ASSOCIATIVE_ARRAY.
- **W.26**: olddefconfig 新增孤儿 — NETKIT, XOR_BLOCKS, RAID6_PQ+bench, BTRFS_ACL, ERofs_XATTR*5, NETFILTER_XT_MATCH_POLICY, NFT_COMPAT_ARP, CRYPTO_GENIV, NF_CT_PROTO_GRE, NETFILTER_FAMILY_ARP, BINARY_PRINTF, CRYPTO_KDF800108_CTR (17 项).
- **W.27**: ZSWAP choice 残留 — Kconfig choice 后端全覆盖 (LZO/DEFLATE/LZ4/LZ4HC/ZSTD/842).
- **W.28**: CRYPTO RNG default choice 残留.

**红线调整**: USB_SERIAL, FUSE_FS, USB_STORAGE 从保护列表移除.

**保留项**: MOTORCOMM_PHY=y, PSAMPLE=m, RD_LZO/RD_ZSTD=y.

**Total reduction (all rounds, finalized)**: 5935 → 1251 items (~4684 items / ~78.9% reduction). vmlinuz 14.3 MiB, modules 8.7 MiB, deb 55 MB. Red-line check passed. Key features preserved: TUN, WireGuard, nftables, PPPoE, bonding, VLAN, Docker networking (VETH/MACVLAN/IPVLAN), tc qdiscs (HTB/HFSC/FQ_CODEL/CAKE/INGRESS), ext4 rootfs, OVERLAY_FS, GPIO/PCA953X, GMAC Ethernet (STMMAC + DWMAC_ROCKCHIP), RTC (HYM8563), HW_RANDOM_ROCKCHIP, PSAMPLE.

## Target hardware

NanoPi R3S: **RK3566** (quad Cortex-A55), **2GB** RAM, 2x GbE (RTL8211F + RTL8111H). Authoritative source is the upstream board file `config/boards/nanopi-r3s.csc`; `docs/r3s-device.md` matches.

## Conventions

- Custom shell scripts use Chinese comments/log output and colorized `info`/`warn`/`err`/`ok` helpers. Match that style when extending them.
- `config-nanopir3s.conf` is the R3S build parameter file for Armbian's `compile.sh`.
- `extensions/nanopir3s-kconfig.sh` is the Armbian extension hook that removes unwanted items from Armbian's `opts_y`/`opts_m` arrays (BPF/AppArmor/systemd cgroup/ebtables/xtables/容器网络等) and adds `opts_n` as double insurance before olddefconfig. v2.12 新增 keep_set 机制：从 `.trim-mode` 标记文件或 `R3S_TRIM_MODE` 环境变量检测裁剪模式，docker/ebpf 模式下保护符号在 opts_y 过滤、opts_m 过滤、opts_n 追加、.config 直写四处全部跳过，避免 trim 脚本开启的项被钩子再次关闭。
- `*.config.bak.*`, `*.baseline`, and `trim-r3s.log` are generated artifacts, not source.
- `samples/linux-rockchip64-current.config.base` is the untrimmed Armbian default config (4447 items, 1877 y/m); `samples/linux-rockchip64-current.config.baseline` is the v2.11 裁剪产物的 olddefconfig 解析结果（2788 项，其中 888 y/m），作为 trim-r3s-kernel.sh 的输入基线。
