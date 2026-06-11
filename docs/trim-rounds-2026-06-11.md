# R3S 内核裁剪全程记录 — 2026-06-11 最终版

## 环境

- **目标硬件**: NanoPi R3S (RK3566, Cortex-A55 x4, 2GB RAM, 2x GbE)
- **内核版本**: Linux 6.18.35-current-rockchip64
- **Rootfs**: Alpine Linux + OpenRC
- **核心软件**: sing-box + WireGuard + tailscale + cloudflared/WARP + easytier
- **工具链**: Armbian build framework (26.05.0-trunk)

## 裁剪总览

```
5935 (Armbian 默认 olddefconfig)
  ↓ -4684 (Armbian 板级配置已禁用)
1251 (baseline, 裁剪起点)
  ↓ -342 (trim-r3s-kernel.sh 全部round)
 909 (=y:862, =m:47)  最终配置
```

## trim-r3s-kernel.sh 结构

脚本读取 `linux-rockchip64-current.config.baseline` (1251项 y/m)，输出 `linux-rockchip64-current.config`。

### 核心函数

```bash
unset_k()  # 禁用 CONFIG 项 → "# CONFIG_X is not set"
set_y()    # 强制启用 =y
set_m()    # 强制启用 =m
```

---

## Round A: NETFILTER_XTABLES + iptables 全栈清除

**影响**: ~70 项 unset

禁用整个 xtables 框架 (`NETFILTER_XTABLES`) 及所有 xt_* match/target 模块，迫使系统走纯 nftables 路线。

### A.1 — NETFILTER_XTABLES 本体 (~40 项)
```
NETFILTER_XTABLES, NETFILTER_XTABLES_LEGACY, NETFILTER_XTABLES_COMPAT
NETFILTER_XT_MARK, NETFILTER_XT_CONNMARK, NETFILTER_XT_SET
NETFILTER_XT_TARGET_* (CLASSIFY, CONNMARK, LOG, MARK, NFLOG, NFQUEUE,
                        REDIRECT, MASQUERADE, TPROXY, TCPMSS)
NETFILTER_XT_MATCH_* (ADDRTYPE, COMMENT, CONNLABEL, CONNLIMIT, CONNMARK,
                      CONNTRACK, CPU, DSCP, HASHLIMIT, IPRANGE, LENGTH,
                      LIMIT, MAC, MARK, MULTIPORT, OWNER, PHYSDEV, QUOTA,
                      RECENT, SOCKET, STATE, STATISTIC, STRING, TCPMSS,
                      TIME, U32)
IP_SET + 全部子模块 (BITMAP_IP/BMAC/PORT, HASH_IP/IPMARK/IPPORT/...)
NFT_COMPAT, NF_TABLES_BRIDGE_COMPAT
```

### A.2 — BRIDGE_NETFILTER root cause (P0-2, ~25 项)
```
BRIDGE_NETFILTER → select NETFILTER_XTABLES (元凶!)
BRIDGE_NF_EBTABLES, BRIDGE_NF_EBTABLES_LEGACY
BRIDGE_EBT_* (20个子模块)
IP_NF_IPTABLES_LEGACY, IP6_NF_IPTABLES_LEGACY
BRIDGE_VLAN_FILTERING
```

### A.3 — iptables 非 legacy 全栈 (29 项)
```
IP_NF_IPTABLES, IP_NF_FILTER, IP_NF_MANGLE, IP_NF_NAT, IP_NF_RAW
IP_NF_TARGET_MASQUERADE/NETMAP/REDIRECT/REJECT/SYNPROXY/ECN
IP_NF_MATCH_ECN/TTL
IP6_NF_IPTABLES, IP6_NF_FILTER, IP6_NF_MANGLE, IP6_NF_NAT, IP6_NF_RAW
IP6_NF_TARGET_MASQUERADE/NPT/REJECT/SYNPROXY/HL
IP6_NF_MATCH_EUI64/FRAG/HL/IPV6HEADER/OPTS/RT
```

---

## Round B: NET_SCHED / NET_CLS / NET_ACT 全砍

**影响**: ~20 项 unset

无 QoS 需求，tc 框架完全移除。

```
NET_SCHED, NET_SCH_HTB, NET_SCH_HFSC, NET_SCH_FQ_CODEL, NET_SCH_CAKE
NET_SCH_INGRESS, NET_SCH_DEFAULT, NET_SCH_FIFO, NET_SCH_FQ_PIE
NET_SCH_FQ, NET_SCH_PFIFO_FAST, DEFAULT_NET_SCH
NET_CLS, NET_CLS_BASIC, NET_CLS_FW, NET_CLS_U32, NET_CLS_FLOWER, NET_CLS_ACT
NET_ACT_POLICE, NET_ACT_MIRRED, NET_ACT_NAT, NET_ACT_PEDIT
NET_ACT_SKBEDIT, NET_ACT_VLAN, IFB
```

---

## Round C: 容器网络/存储裁剪

**影响**: ~5 项 unset

无 Docker/容器需求。

```
OVERLAY_FS, VETH, MACVLAN, IPVLAN
```

---

## Round D: SQUASHFS 全关

**影响**: ~11 项 unset

```
SQUASHFS + 全部子选项 (FILE_DIRECT, DECOMP_SINGLE/MULTI, XATTR,
                       ZLIB, LZ4, XZ, 4K_DEVBLK, EMBEDDED)
```

---

## Round E: EFI / SMMU / COMPAT

**影响**: ~12 项

R3S 使用 U-Boot，不需要 EFI stub。ARM SMMU 驱动移除。

```
EFI, EFI_STUB, EFI_PARAMS_FROM_FDT, EFI_RUNTIME_WRAPPERS
EFI_GENERIC_STUB, EFI_ARMSTUB_DTB_LOADER, EFI_EARLYCON
ARM_SMMU, ARM_SMMU_V3, ARM_SMMU_DISABLE_BYPASS_BY_DEFAULT
ARM_SMMU_MMU_500_CPRE_ERRATA
COMPAT, COMPAT_BINFMT_ELF, COMPAT_OLD_SIGACTION
```
保留: `EFI_PARTITION` (GPT分区表), `CRYPTO_AES_ARM64*` 硬件加速

---

## Round F: Rockchip 硬件加密引擎

**影响**: ~3 项 unset

移除 Rockchip 异步加密引擎（TRNG保留），保留 ARMv8 Crypto Extensions 驱动。

```
CRYPTO_DEV_ROCKCHIP, CRYPTO_DEV_ROCKCHIP2, CRYPTO_DEV_ROCKCHIP_TRNG
```

---

## Round G: 不常用网络隧道 + IPsec/XFRM

**影响**: ~14 项 unset

WireGuard 替代品。IPsec 全栈移除。

```
IPV6_TUNNEL, IPV6_GRE, IP_GRE, IP_GRE_DEMUX, IP_VTI, IP6_VTI
NET_IPGRE, NET_IPGRE_DEMUX, NET_IPIP, NET_IP_TUNNEL
MPLS_ROUTING, MPLS_IPTUNNEL, NET_MPLS_GSO
XFRM, INET_ESP
```

---

## Round H: NF_CONNTRACK helper 全裁

**影响**: ~14 项 unset

```
NF_CONNTRACK_AMANDA, NF_CONNTRACK_H323, NF_CONNTRACK_NETBIOS_NS
NF_CONNTRACK_PPTP, NF_CONNTRACK_SANE, NF_CONNTRACK_SIP
NF_CONNTRACK_SNMP, NF_CONNTRACK_TFTP, NF_CONNTRACK_BROADCAST
NF_CT_PROTO_DCCP, NF_CT_PROTO_SCTP, NF_CT_PROTO_GRE
NF_CT_NETLINK_TIMEOUT, NF_CT_NETLINK_HELPER
NF_CONNTRACK_FTP, NF_NAT_FTP, NF_NAT_IRC, NF_NAT_TFTP, NF_NAT_PPTP
NF_NAT_SIP
```

---

## Round H.2: 冷门 netfilter 模块

**影响**: ~16 项 unset

```
NETFILTER_SYNPROXY, NFT_SYNPROXY
NETFILTER_CONNCOUNT, NFT_CONNLIMIT
NETFILTER_NETLINK_QUEUE, NFT_QUEUE
NF_CONNTRACK_BRIDGE
NFT_BRIDGE_META, NFT_BRIDGE_REJECT
NFT_FIB_NETDEV, NFT_REJECT_NETDEV
NFT_TUNNEL
NF_LOG_ARP
```

---

## Round H.3 (D+E+F): 孤儿网络/非RK3566驱动/可选精简

### D: 孤儿网络模块 (~3m)
```
NET_UDP_TUNNEL  (VXLAN/FOU/GENEVE 全部已砍)
INET6_TUNNEL    (SIT/GRE 已砍)
PSAMPLE         (tc 已砍)
```

### E: 非RK3566驱动 (~1y)
```
REGULATOR_FAN53555  (仅RK3588 Anbernic/Powkiddy掌机用)
```

### F: 可选精简 (~5y)
```
BLK_DEV_LOOP       (无 snap/flatpak)
PCIEPORTBUS        (AER/ASPM/PME/Hotplug 全关,空壳)
DECOMPRESS_LZMA    (initramfs 用 gzip/lz4)
RD_LZMA            (同上)
CMA_SIZE_MBYTES=0  (无GPU/VPU/相机,释放16MB RAM)
```

---

## Round H.3 (G): Alpine/OpenRC 场景精简

**影响**: ~10y

```
CRYPTO_DRBG_HASH, CRYPTO_DRBG_CTR  (/dev/random 用 HMAC 即可)
DECOMPRESS_XZ, RD_XZ               (Alpine initramfs 用 gzip/lz4)
MFD_RK8XX_SPI                       (RK808 走 I2C 非 SPI)
FHANDLE                             (systemd 用, OpenRC 不需要)
DECOMPRESS_LZO, RD_LZO              (Alpine不用LZO initramfs)
DECOMPRESS_ZSTD, RD_ZSTD            (Alpine不用ZSTD initramfs)
```

---

## Round H.3 (H): sing-box纯路由视角

**影响**: ~15y + 3m

```
BRIDGE, STP, LLC, NETFILTER_FAMILY_BRIDGE  (R3S仅2口WAN+LAN,无需桥接)
IP_ROUTE_CLASSID         (xt_realm+tc route 孤儿)
IPVLAN_L3S               (IPVLAN已砍, def_bool残留)
ZSTD_COMPRESS, LZO_COMPRESS  (ZRAM仅LZ4, crypto压缩全关)
OVERLAY_FS_REDIRECT_ALWAYS_FOLLOW, OVERLAY_FS_XINO_AUTO  (OVERLAY_FS已砍)
FS_STACK                 (仅OVERLAY_FS+ECRYPT_FS用)
NF_TABLES_BRIDGE         (BRIDGE移除后不需要)
EXT4_FS_POSIX_ACL, FS_POSIX_ACL, TMPFS_POSIX_ACL  (Alpine不用ACL)
```

---

## Round H.3 (I): 显微镜级残余

**影响**: ~7y + 1m

```
NET_REDIRECT        (IFB 已砍, 唯一selector移除)
PCI_HOST_GENERIC    (RK3566 用 PCIE_ROCKCHIP_DW_HOST)
PCI_QUIRKS          (R3S 仅 RTL8111H, 无已知 quirks)
SYSVIPC, SYSVIPC_SYSCTL, SYSVIPC_COMPAT  (musl/OpenRC/sing-box不用SysV IPC)
BONDING             (2口WAN+LAN 独立路由, 不聚合)
```

---

## Round H.3 (J): 孤儿 crypto 算法

**影响**: ~5y

```
CRYPTO_CBC         (15个selector全在non-RK驱动/已砍子系统)
CRYPTO_MD5, CRYPTO_LIB_MD5  (TCP_MD5SIG=n, selector全在已砍子系统)
CRYPTO_AES_ARM64_BS, CRYPTO_AES_ARM64_NEON_BLK  (A55有CE硬件,备用驱动冗余)
```

---

## Round H.3 (K): 孤儿 crypto 续

**影响**: ~6y

```
CRYPTO_CCM, CRYPTO_CTR, CRYPTO_AES_ARM64_CE_CCM  (mac80211/smb已砍,无消费者)
CRYPTO_CHACHA20POLY1305  (OVPN=n, WireGuard用LIB版)
CRYPTO_GHASH_ARM64_CE, CRYPTO_LIB_GF128MUL  (GCM/GHASH均n, CCM不用GHASH)
```

---

## Round H.3 (L): 非核心网络/CPU精简

**影响**: ~6y

```
IP_ROUTE_MULTIPATH       (2口单路径)
IPV6_OPTIMISTIC_DAD      (静态IPv6不需要)
UNIX98_PTYS              (现代Linux用/dev/pts)
NET_L3_MASTER_DEV        (NET_VRF+IPVLAN_L3S均砍)
ARM_ARCH_TIMER_EVTSTREAM (KVM已砍)
CPU_FREQ_GOV_PERFORMANCE (保留ondemand+schedutil足够)
```

---

## Round H.3 (M): TCP拥塞/调试符号

**影响**: ~2y + 1m

```
TCP_CONG_ADVANCED, TCP_CONG_BBR   (路由器自身TCP流量极小, CUBIC足够)
SYMBOLIC_ERRNAME                  (errno号→名称, 生产不需要)
```

---

## Round H.3 (N): 非R3S硬件驱动残留

**影响**: ~5y

```
GPIO_PCA953X, GPIO_PCA953X_IRQ  (I2C GPIO扩展器, R3S DTS无引用)
REGULATOR_GPIO                   (R3S用RK808 PMIC, 不需要GPIO调压)
REGULATOR_PWM                    (R3S用RK808 PMIC, 不需要PWM调压)
PINCTRL_SINGLE                   (RK3566用PINCTRL_ROCKCHIP)
```

---

## Round H.3 (O): IPv6/网络微调

**影响**: ~2y

```
INET_DIAG_DESTROY   (ss -K关闭socket, 调试用)
IPV6_SUBTREES       (IPv6源地址路由, 高级特性)
```

---

## Round H.3 (P): 非必要 =m 模块精简

**影响**: ~4m

```
NETFILTER_NETLINK_LOG  (ulogd用, sing-box/NFT_LOG不用)
LEDS_TRIGGER_TIMER, LEDS_TRIGGER_ONESHOT  (非必要LED效果)
NF_TABLES_NETDEV       (sing-box用inet family, 无需netdev)
```

---

## Round H.3 (Q): BLK_CGROUP孤儿 + PPP_MULTILINK

**影响**: ~3y

```
PPP_MULTILINK           (单WAN不需要MP多链路)
BLK_CGROUP_RWSTAT, BLK_CGROUP_PUNT_BIO  (BLK_CGROUP=n孤儿)
```

---

## Round H.3 (R): DIAG/文件系统/模块精简

**影响**: ~7m + 4y

```
PACKET_DIAG, UNIX_DIAG, NETLINK_DIAG     (ss/tcpdump调试)
INET_DIAG, INET_TCP_DIAG, INET_UDP_DIAG, INET_RAW_DIAG  (同上)
FILE_LOCKING     (fcntl锁, 路由不需要)
PROC_CHILDREN    (/proc/pid/task/children, 调试用)
TMPFS_XATTR      (ACL已砍, /tmp扩展属性不需要)
MODULE_UNLOAD    (生产环境不需要rmmod)
```

---

## Round H.3 (S): crypto引擎/HWRNG/IPv6RA

**影响**: ~2y + 3m

```
CRYPTO_ENGINE              (所有selector在non-RK硬件, ARM CE不用)
HW_RANDOM, HW_RANDOM_ROCKCHIP  (JITTERENTROPY已提供足够CPU熵源)
IPV6_ROUTER_PREF, IPV6_ROUTE_INFO  (单路由不需要RFC4191)
```

---

## Round H.3 (U): IO_URING + 安全硬化

**影响**: ~5y

```
IO_URING, IO_WQ                              (Go/sing-box/Alpine不用, ~50KB)
RANDOMIZE_KSTACK_OFFSET                       (syscall栈随机, 1-2%开销)
INIT_STACK_ALL_ZERO, INIT_ON_ALLOC_DEFAULT_ON (栈/堆清零, 2-3%开销)
```

---

## Round H.3 (W): conntrack netlink

**影响**: ~1m

```
NF_CT_NETLINK  (conntrack -L/-D工具用, nftables NAT不需要)
```

---

## 红线保护 (Section I + J)

### nftables 核心 (Section I)
```
NF_TABLES, NF_TABLES_INET, NF_TABLES_IPV4, NF_TABLES_IPV6
NFT_CT, NFT_NAT, NFT_MASQ, NFT_REDIR, NFT_REJECT, NFT_REJECT_INET
NFT_LOG, NFT_LIMIT, NFT_QUOTA, NFT_HASH
NFT_FIB, NFT_FIB_INET, NFT_FIB_IPV4, NFT_FIB_IPV6
NFT_TPROXY, NFT_SOCKET (sing-box 需要)
NFT_FLOW_OFFLOAD, NF_FLOW_TABLE, NF_FLOW_TABLE_INET (软件fast-path)
```

### 用户态工具 (Section J)
```
TUN, WIREGUARD, PPP, PPPOE, R8169
EXT4_FS, WATCHDOG, DW_WATCHDOG
MMC, MMC_DW_ROCKCHIP (microSD)
PCI, PCIE_ROCKCHIP_HOST (RTL8111H PCIe)
NET_VENDOR_REALTEK, NET_VENDOR_STMICRO
STMMAC_ETH, STMMAC_PLATFORM, DWMAC_GENERIC, DWMAC_ROCKCHIP (GMAC)
```

---

## 扩展钩子 (extensions/nanopir3s-kconfig.sh)

运行于 Armbian `custom_kernel_config` 阶段。核心机制：从 Armbian 注入的 `opts_y`/`opts_m` 数组中过滤掉不需要的项。

### remove_from_y (~60项)
```
BPF链: NETFILTER_BPF_LINK, BPF_SYSCALL, CGROUP_BPF
AppArmor链: SECURITY_APPARMOR
systemd cgroup: POSIX_MQUEUE, USER_NS, BLK_CGROUP, FAIR_GROUP_SCHED,
               RT_GROUP_SCHED, CFS_BANDWIDTH, CGROUP_SCHED, CGROUP_PIDS,
               CGROUP_FREEZER, CGROUP_DEVICE, CGROUP_CPUACCT, CGROUP_HUGETLB,
               CGROUP_NET_CLASSID, CGROUP_NET_PRIO, CGROUP_PERF, CPUSETS
内核调试: IKCONFIG, IKCONFIG_PROC
网络: NETKIT, NET_SCHED, NET_L3_MASTER_DEV, XFRM
密钥/加密: KEYS, KEY_DH_OPERATIONS, ENCRYPTED_KEYS, PERSISTENT_KEYRINGS
ZSWAP/ZRAM: ZSWAP, ZSWAP_ZPOOL_DEFAULT_ZBUD, ZRAM_BACKEND_*
其他: EXT4_FS_SECURITY, GPIO_SYSFS, NETFILTER_XTABLES_*, BLK_DEV_THROTTLING,
      CFQ_GROUP_IOSCHED, BRIDGE_VLAN_FILTERING, MEMCG_KMEM
孤儿crypto: CRYPTO_AUTHENC, CRYPTO_ECB, CRYPTO_CRYPTD
TEXTSEARCH
```

### remove_from_m (~180项)
```
BRIDGE_NETFILTER + ebtables全栈 (22项)
xtables全栈 (76项 NETFILTER_XT_*)
ipset全套 (9项 IP_SET*)
iptables IPv4/IPv6 (40项 IP_NF_*/IP6_NF_*)
nftables compat: NFT_COMPAT, NFT_COMPAT_ARP
IP_VS: IP_VS, IP_VS_RR
容器网络: VETH, MACVLAN, IPVLAN, VXLAN, OVERLAY_FS
文件系统: BTRFS_FS, EROFS_FS
IPsec: INET_ESP, XFRM_ALGO, XFRM_USER
加密冗余: CRYPTO_SEQIV, CRYPTO_GHASH, CRYPTO_GCM
冷门模块: NTSYNC, NET_IP_TUNNEL, conntrack冷门helper,
         nftables多余模块, netfilter调试框架, tc残留, wireless
```

---

## 累计效果

| 轮次 | 内容 | 减项 | y/m 总数 |
|------|------|------|----------|
| baseline | Armbian olddefconfig | — | 1251 |
| P0 | BPF/BRIDGE_NETFILTER/AppArmor 根因 | -196 | 1055 |
| A/B/C | 冷门netfilter+iptables全栈+孤儿crypto | -50 | 1005 |
| D/E/F | 孤儿网络+FAN53555+LOOP/PCIEPORT/LZMA | -8 | 997 |
| G | DRBG冗余+initramfs精简+FHANDLE+RK8XX_SPI | -10 | 987 |
| H | BRIDGE全链+孤儿路由+OVERLAY/ACL残留 | -15 | 972 |
| I | NET_REDIRECT+PCI+SYSVIPC+BONDING | -7 | 965 |
| J | CRYPTO_CBC+MD5链+AES_ARM64_BS/NEON | -5 | 960 |
| K | CRYPTO_CCM/CTR+CHACHA20POLY1305+GHASH | -6 | 954 |
| L | IP_ROUTE_MULTIPATH+DAD+PTYS+NET_L3+TIMER+GOV | -6 | 948 |
| M | TCP_CONG_ADVANCED+BBR+SYMBOLIC_ERRNAME | -3 | 945 |
| N | GPIO_PCA953X+REGULATOR_GPIO/PWM+PINCTRL_SINGLE | -5 | 940 |
| O | INET_DIAG_DESTROY+IPV6_SUBTREES | -2 | 938 |
| P | NETFILTER_NETLINK_LOG+LED_TRIGGERS+NF_TABLES_NETDEV | -4 | 934 |
| Q | PPP_MULTILINK+BLK_CGROUP孤儿 | -3 | 931 |
| R | DIAG全砍+FILE_LOCKING+PROC_CHILDREN+TMPFS_XATTR+MODULE_UNLOAD | -11 | 920 |
| S | CRYPTO_ENGINE+HW_RANDOM+IPV6_ROUTER_PREF/INFO | -5 | 915 |
| U | IO_URING+IO_WQ+安全硬化3项 | -5 | 910 |
| W | NF_CT_NETLINK | -1 | 909 |
| **最终** | | **-342** | **909 (=y:862, =m:47)** |

## 文件清单

| 文件 | 说明 |
|------|------|
| `trim-r3s-kernel.sh` | 主裁剪脚本 (~1350行, 26节) |
| `extensions/nanopir3s-kconfig.sh` | Armbian构建钩子 (过滤opts_y/opts_m) |
| `linux-rockchip64-current.config` | 最终裁剪产物 (909项) |
| `linux-rockchip64-current.config.baseline` | 裁剪起点 (1251项, Armbian olddefconfig输出) |
