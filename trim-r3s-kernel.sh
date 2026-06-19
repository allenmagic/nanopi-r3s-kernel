#!/usr/bin/env bash
# =============================================================================
# apply-trim-final.sh
# R3S 软路由内核精准裁剪（基于已裁剪 baseline）
#
# 输入：./linux-rockchip64-current.config.baseline (1251 项 y/m)
# 输出：./linux-rockchip64-current.config
#
# 设计原则：
#   1. 只操作 baseline 里"还开着、需要砍"的项
#   2. 不重复砍 baseline 已砍的项（保持脚本精简）
#   3. 红线项用 set_y/set_m 确认（防止被联动关闭）
# =============================================================================
set -euo pipefail

# ---------- 路径 ----------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="${SCRIPT_DIR}/samples/linux-rockchip64-current.config.baseline"
DST="${SCRIPT_DIR}/linux-rockchip64-current.config"

# ---------- 日志 ----------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
info()  { echo -e "${BLUE}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
err()   { echo -e "${RED}[ERR]${NC}   $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }

# ---------- 命令行参数 ----------
# 用法：
#   ./trim-r3s-kernel.sh                    # 默认 minimal 模式
#   ./trim-r3s-kernel.sh --mode minimal     # 纯路由器（最小裁剪）
#   ./trim-r3s-kernel.sh --mode docker      # 支持 Docker/Podman 容器
#   ./trim-r3s-kernel.sh --mode ebpf        # 支持 eBPF 工具链（cilium/bpftrace/bcc）
#   ./trim-r3s-kernel.sh --mode full        # Docker + eBPF 全开
TRIM_MODE="minimal"

usage() {
	cat <<EOF
Usage: $(basename "$0") [--mode <minimal|docker|ebpf|full>] [-h|--help]

裁剪模式：
  minimal  纯路由器（默认），最大限度裁剪，~879 项 y/m
  docker   保留容器栈（namespaces/cgroup controllers/OVERLAY_FS/VETH/BRIDGE）
  ebpf     保留 eBPF 工具链（BPF_SYSCALL/CGROUP_BPF/BPF_JIT/BTF/XDP）
  full     docker + ebpf 全开
EOF
}

while [[ $# -gt 0 ]]; do
	case "$1" in
		--mode)
			[[ $# -ge 2 ]] || { err "--mode 缺少参数"; usage; exit 1; }
			TRIM_MODE="$2"
			shift 2
			;;
		--mode=*)
			TRIM_MODE="${1#--mode=}"
			shift
			;;
		-h|--help)
			usage; exit 0
			;;
		*)
			err "未知参数：$1"
			usage; exit 1
			;;
	esac
done

ENABLE_DOCKER=0
ENABLE_EBPF=0
case "$TRIM_MODE" in
	minimal) ;;
	docker)  ENABLE_DOCKER=1 ;;
	ebpf)    ENABLE_EBPF=1 ;;
	full)    ENABLE_DOCKER=1; ENABLE_EBPF=1 ;;
	*)
		err "未知 --mode: $TRIM_MODE (可选：minimal|docker|ebpf|full)"
		usage; exit 1
		;;
esac

info "裁剪模式：${YELLOW}${TRIM_MODE}${NC}  (Docker=${ENABLE_DOCKER}, eBPF=${ENABLE_EBPF})"

# ---------- 前置检查 ----------
[[ -f "$SRC" ]] || { err "baseline 不存在：$SRC"; exit 1; }
info "输入：$SRC"
info "输出：$DST"
mkdir -p "$(dirname "$DST")"
cp "$SRC" "$DST"

# 记录裁剪模式：供扩展钩子 extensions/nanopir3s-kconfig.sh 读取，
# 使其在 docker/ebpf 模式下不要再砍掉容器/eBPF 相关项。
# 钩子读取顺序：环境变量 R3S_TRIM_MODE > 本标记文件 > 默认 minimal
echo "$TRIM_MODE" > "${SCRIPT_DIR}/.trim-mode"
info "已写入裁剪模式标记：${SCRIPT_DIR}/.trim-mode = ${TRIM_MODE}"

# ---------- 辅助函数 ----------
set_y()  { local k="CONFIG_$1"; sed -i "/^# *${k} is not set/d; /^${k}=/d" "$DST"; echo "${k}=y" >> "$DST"; }
set_m()  { local k="CONFIG_$1"; sed -i "/^# *${k} is not set/d; /^${k}=/d" "$DST"; echo "${k}=m" >> "$DST"; }
unset_k(){ local k="CONFIG_$1"; sed -i "/^${k}=/d; /^# *${k} is not set/d" "$DST"; echo "# ${k} is not set" >> "$DST"; }

# =============================================================================
# A. 关闭 NETFILTER_XTABLES + 全套 xt_* （走纯 nftables 路线）
# =============================================================================
info "[A] 关闭 NETFILTER_XTABLES + xt_* (共 ~40 个模块)"

unset_k NETFILTER_XTABLES
unset_k NETFILTER_XTABLES_LEGACY
unset_k NETFILTER_XTABLES_COMPAT
unset_k NETFILTER_XT_MARK
unset_k NETFILTER_XT_CONNMARK
unset_k NETFILTER_XT_SET
unset_k NETFILTER_XT_TARGET_CLASSIFY
unset_k NETFILTER_XT_TARGET_CONNMARK
unset_k NETFILTER_XT_TARGET_LOG
unset_k NETFILTER_XT_TARGET_MARK
unset_k NETFILTER_XT_NAT
unset_k NETFILTER_XT_TARGET_NFLOG
unset_k NETFILTER_XT_TARGET_NFQUEUE
unset_k NETFILTER_XT_TARGET_REDIRECT
unset_k NETFILTER_XT_TARGET_MASQUERADE
unset_k NETFILTER_XT_TARGET_TPROXY
unset_k NETFILTER_XT_TARGET_TCPMSS
unset_k NETFILTER_XT_MATCH_ADDRTYPE
unset_k NETFILTER_XT_MATCH_COMMENT
unset_k NETFILTER_XT_MATCH_CONNLABEL
unset_k NETFILTER_XT_MATCH_CONNLIMIT
unset_k NETFILTER_XT_MATCH_CONNMARK
unset_k NETFILTER_XT_MATCH_CONNTRACK
unset_k NETFILTER_XT_MATCH_CPU
unset_k NETFILTER_XT_MATCH_DSCP
unset_k NETFILTER_XT_MATCH_HASHLIMIT
unset_k NETFILTER_XT_MATCH_IPRANGE
unset_k NETFILTER_XT_MATCH_LENGTH
unset_k NETFILTER_XT_MATCH_LIMIT
unset_k NETFILTER_XT_MATCH_MAC
unset_k NETFILTER_XT_MATCH_MARK
unset_k NETFILTER_XT_MATCH_MULTIPORT
unset_k NETFILTER_XT_MATCH_OWNER
unset_k NETFILTER_XT_MATCH_PHYSDEV
unset_k NETFILTER_XT_MATCH_QUOTA
unset_k NETFILTER_XT_MATCH_RECENT
unset_k NETFILTER_XT_MATCH_SOCKET
unset_k NETFILTER_XT_MATCH_STATE
unset_k NETFILTER_XT_MATCH_STATISTIC
unset_k NETFILTER_XT_MATCH_STRING
unset_k NETFILTER_XT_MATCH_TCPMSS
unset_k NETFILTER_XT_MATCH_TIME
unset_k NETFILTER_XT_MATCH_U32

# ipset 全套（依赖 xtables）
unset_k IP_SET
unset_k IP_SET_BITMAP_IP
unset_k IP_SET_BITMAP_IPMAC
unset_k IP_SET_BITMAP_PORT
unset_k IP_SET_HASH_IP
unset_k IP_SET_HASH_IPMARK
unset_k IP_SET_HASH_IPPORT
unset_k IP_SET_HASH_IPPORTIP
unset_k IP_SET_HASH_IPPORTNET
unset_k IP_SET_HASH_IPMAC
unset_k IP_SET_HASH_MAC
unset_k IP_SET_HASH_NETPORTNET
unset_k IP_SET_HASH_NET
unset_k IP_SET_HASH_NETNET
unset_k IP_SET_HASH_NETPORT
unset_k IP_SET_HASH_NETIFACE
unset_k IP_SET_LIST_SET

# NF_TABLES_COMPAT（让 nftables 兼容 iptables 规则的桥接层，不需要）
unset_k NFT_COMPAT
unset_k NF_TABLES_BRIDGE_COMPAT

# =============================================================================
# A.2 关闭 BRIDGE_NETFILTER + ebtables 全栈（P0-2 root cause）
#    BRIDGE_NETFILTER → select NETFILTER_XTABLES → 76项 xt_* 复活
#    关掉它后 ebtables/xtables 自动消失
# =============================================================================
info "[A.2] 关闭 BRIDGE_NETFILTER + ebtables (root cause, ~30 项)"

unset_k BRIDGE_NETFILTER
unset_k BRIDGE_NF_EBTABLES
unset_k BRIDGE_NF_EBTABLES_LEGACY

# 所有 ebtables 子模块
unset_k BRIDGE_EBT_BROUTE
unset_k BRIDGE_EBT_T_FILTER
unset_k BRIDGE_EBT_T_NAT
unset_k BRIDGE_EBT_802_3
unset_k BRIDGE_EBT_AMONG
unset_k BRIDGE_EBT_ARP
unset_k BRIDGE_EBT_ARPREPLY
unset_k BRIDGE_EBT_DNAT
unset_k BRIDGE_EBT_IP
unset_k BRIDGE_EBT_IP6
unset_k BRIDGE_EBT_LIMIT
unset_k BRIDGE_EBT_LOG
unset_k BRIDGE_EBT_MARK
unset_k BRIDGE_EBT_MARK_T
unset_k BRIDGE_EBT_NFLOG
unset_k BRIDGE_EBT_PKTTYPE
unset_k BRIDGE_EBT_REDIRECT
unset_k BRIDGE_EBT_SNAT
unset_k BRIDGE_EBT_STP
unset_k BRIDGE_EBT_VLAN

# IP_NF_IPTABLES_LEGACY / IP6_NF_IPTABLES_LEGACY（select NETFILTER_XTABLES）
unset_k IP_NF_IPTABLES_LEGACY
unset_k IP6_NF_IPTABLES_LEGACY

	# IP_NF_IPTABLES 全栈（iptables IPv4 非 legacy，依赖 NETFILTER_XTABLES）
	unset_k IP_NF_IPTABLES
	unset_k IP_NF_FILTER
	unset_k IP_NF_MANGLE
	unset_k IP_NF_NAT
	unset_k IP_NF_RAW
	unset_k IP_NF_TARGET_MASQUERADE
	unset_k IP_NF_TARGET_NETMAP
	unset_k IP_NF_TARGET_REDIRECT
	unset_k IP_NF_TARGET_REJECT
	unset_k IP_NF_TARGET_SYNPROXY
	unset_k IP_NF_TARGET_ECN
	unset_k IP_NF_MATCH_ECN
	unset_k IP_NF_MATCH_TTL

	# IP6_NF_IPTABLES 全栈（iptables IPv6 非 legacy）
	unset_k IP6_NF_IPTABLES
	unset_k IP6_NF_FILTER
	unset_k IP6_NF_MANGLE
	unset_k IP6_NF_NAT
	unset_k IP6_NF_RAW
	unset_k IP6_NF_TARGET_MASQUERADE
	unset_k IP6_NF_TARGET_NPT
	unset_k IP6_NF_TARGET_REJECT
	unset_k IP6_NF_TARGET_SYNPROXY
	unset_k IP6_NF_TARGET_HL
	unset_k IP6_NF_MATCH_EUI64
	unset_k IP6_NF_MATCH_FRAG
	unset_k IP6_NF_MATCH_HL
	unset_k IP6_NF_MATCH_IPV6HEADER
	unset_k IP6_NF_MATCH_OPTS
	unset_k IP6_NF_MATCH_RT

# BRIDGE_VLAN_FILTERING（桥接 VLAN 过滤，单路由场景不需要）
unset_k BRIDGE_VLAN_FILTERING

# =============================================================================
# B. 关闭 NET_SCHED / NET_CLS / NET_ACT 全套（无 QoS 需求）
# =============================================================================
info "[B] 关闭 NET_SCHED / NET_CLS / NET_ACT (共 ~20 个模块)"

unset_k NET_SCHED
unset_k NET_SCH_HTB
unset_k NET_SCH_HFSC
unset_k NET_SCH_FQ_CODEL
unset_k NET_SCH_CAKE
unset_k NET_SCH_INGRESS
unset_k NET_SCH_DEFAULT
unset_k NET_SCH_FIFO
unset_k NET_SCH_FQ_PIE
unset_k NET_SCH_FQ
unset_k NET_SCH_PFIFO_FAST
unset_k DEFAULT_NET_SCH

unset_k NET_CLS
unset_k NET_CLS_BASIC
unset_k NET_CLS_FW
unset_k NET_CLS_U32
unset_k NET_CLS_FLOWER
unset_k NET_CLS_ACT

unset_k NET_ACT_POLICE
unset_k NET_ACT_MIRRED
unset_k NET_ACT_NAT
unset_k NET_ACT_PEDIT
unset_k NET_ACT_SKBEDIT
unset_k NET_ACT_VLAN

unset_k IFB

# =============================================================================
# C. 容器栈裁剪（保留 namespaces + cgroup 框架，砍掉容器专用网络/存储）
# =============================================================================
if [[ $ENABLE_DOCKER -eq 0 ]]; then
	info "[C] 容器专用网络/存储裁剪（namespaces/cgroup 框架保留）"

	# 保留：MEMCG / BLK_CGROUP / 全套 namespaces（其他工具可能用到）
	# 砍掉：容器专用设备

	unset_k OVERLAY_FS           # 容器分层文件系统
	unset_k VETH                 # 容器虚拟网卡对
	unset_k MACVLAN              # 容器 MACVLAN
	unset_k IPVLAN               # 容器 IPVLAN

	# 桥接 — 纯路由器（R3S 双网口路由转发，不需桥接）
	unset_k BRIDGE
	unset_k BRIDGE_VLAN_FILTERING
else
	info "[C] ${YELLOW}[Docker 模式]${NC} 保留容器网络/存储 (OVERLAY_FS/VETH/MACVLAN/IPVLAN/BRIDGE)"
	set_m OVERLAY_FS
	set_m VETH
	set_m MACVLAN
	set_m IPVLAN
	set_m BRIDGE
	set_y BRIDGE_VLAN_FILTERING
fi

# =============================================================================
# D. SQUASHFS 全关（路由器不用 squashfs 镜像）
# =============================================================================
info "[D] SQUASHFS 全关（节省 ~150KB）"

unset_k SQUASHFS
unset_k SQUASHFS_FILE_DIRECT
unset_k SQUASHFS_DECOMP_SINGLE
unset_k SQUASHFS_DECOMP_MULTI
unset_k SQUASHFS_DECOMP_MULTI_PERCPU
unset_k SQUASHFS_CHOICE_DECOMP_BY_MOUNT
unset_k SQUASHFS_MOUNT_DECOMP_THREADS
unset_k SQUASHFS_XATTR
unset_k SQUASHFS_ZLIB
unset_k SQUASHFS_LZ4
unset_k SQUASHFS_XZ
unset_k SQUASHFS_4K_DEVBLK_SIZE
unset_k SQUASHFS_EMBEDDED

# =============================================================================
# E. EFI / SMMU / COMPAT 全关（R3S U-Boot 启动，不需要 EFI；ARMv8.2 无 SMMU）
# =============================================================================
info "[E] EFI / SMMU / COMPAT 关闭"

unset_k EFI
unset_k EFI_STUB
unset_k EFI_PARAMS_FROM_FDT
unset_k EFI_RUNTIME_WRAPPERS
unset_k EFI_GENERIC_STUB
unset_k EFI_ARMSTUB_DTB_LOADER
unset_k EFI_EARLYCON
# ⚠️ EFI_PARTITION 保留，因为 SD 卡可能用 GPT 分区表
set_y EFI_PARTITION

unset_k ARM_SMMU
unset_k ARM_SMMU_V3
unset_k ARM_SMMU_DISABLE_BYPASS_BY_DEFAULT
unset_k ARM_SMMU_MMU_500_CPRE_ERRATA

unset_k COMPAT
unset_k COMPAT_BINFMT_ELF
unset_k COMPAT_OLD_SIGACTION
unset_k ARCH_WANT_COMPAT_IPC_PARSE_VERSION

# =============================================================================
# F. Rockchip 硬件加密引擎（不用，CPU 加速指令更快更稳）
# =============================================================================
info "[F] 关闭 Rockchip 硬件加密引擎"

unset_k CRYPTO_DEV_ROCKCHIP
unset_k CRYPTO_DEV_ROCKCHIP2
unset_k CRYPTO_DEV_ROCKCHIP_TRNG

# 红线确认：ARM CPU 加速保留（baseline 已开，这里只是防御性确认）
set_y CRYPTO_AES_ARM64
set_y CRYPTO_AES_ARM64_CE
set_y CRYPTO_AES_ARM64_CE_BLK
set_y CRYPTO_AES_ARM64_NEON_BLK
set_y CRYPTO_AES_ARM64_BS
set_y CRYPTO_GHASH_ARM64_CE
set_y CRYPTO_AES_ARM64_CE_CCM

# =============================================================================
# G. 不常用网络隧道（保留 WireGuard 必需的）
# =============================================================================
info "[G] 关闭不常用网络隧道"

unset_k IPV6_TUNNEL          # IPv6-over-IPv6 (SIT 已关，这个也关)
unset_k IPV6_GRE             # IPv6 GRE
unset_k IP_GRE               # IPv4 GRE
unset_k IP_GRE_DEMUX
unset_k IP_VTI               # IPsec VTI（用 WireGuard 不用 IPsec）
unset_k IP6_VTI
unset_k NET_IPGRE
unset_k NET_IPGRE_DEMUX
unset_k NET_IPIP             # IP-in-IP
unset_k NET_IP_TUNNEL        # 通用隧道框架

# MPLS（路由器场景不用）
unset_k MPLS_ROUTING
unset_k MPLS_IPTUNNEL
unset_k NET_MPLS_GSO

# XFRM（IPsec 框架，WireGuard 不用）
unset_k XFRM
unset_k INET_ESP

# =============================================================================
# H. NF_CONNTRACK helper 精简（仅保留 FTP，其他冷门协议关闭）
# =============================================================================
info "[H] NF_CONNTRACK helper 精简"

unset_k NF_CONNTRACK_FTP      # FTP helper，主动模式几乎不用
	unset_k NF_NAT_FTP            # FTP NAT helper
	unset_k NF_NAT_IRC            # IRC NAT helper
	unset_k NF_NAT_TFTP           # TFTP NAT helper
	unset_k NF_NAT_PPTP           # PPTP NAT helper
unset_k NF_CONNTRACK_AMANDA
unset_k NF_CONNTRACK_H323
unset_k NF_CONNTRACK_NETBIOS_NS
unset_k NF_CONNTRACK_PPTP
unset_k NF_CONNTRACK_SANE
unset_k NF_CONNTRACK_SIP
	unset_k NF_NAT_SIP             # SIP NAT helper
unset_k NF_CONNTRACK_SNMP
unset_k NF_CONNTRACK_TFTP
unset_k NF_CONNTRACK_BROADCAST
unset_k NF_CT_PROTO_DCCP
unset_k NF_CT_PROTO_SCTP
unset_k NF_CT_PROTO_GRE
unset_k NF_CT_NETLINK_TIMEOUT
unset_k NF_CT_NETLINK_HELPER

# =============================================================================
# H.2 冷门 netfilter 模块清除（SYNPROXY/CONNCOUNT/NFT_QUEUE/NFT_TUNNEL 等）
# =============================================================================
info "[H.2] 冷门 netfilter 模块清除 (~16 项)"

	# SYN proxy（无对外 TCP 服务，不需要）
	unset_k NETFILTER_SYNPROXY
	unset_k NFT_SYNPROXY

	# Connection count/limit（连接数限流，家庭路由可选）
	unset_k NETFILTER_CONNCOUNT
	unset_k NFT_CONNLIMIT

	# NFQUEUE（用户态排队，sing-box 不用）
	unset_k NETFILTER_NETLINK_QUEUE
	unset_k NFT_QUEUE

	# Bridge conntrack（无 bridge 过滤需求）
	unset_k NF_CONNTRACK_BRIDGE

	# Bridge/Netdev nftables family（inet family 已够）
	unset_k NFT_BRIDGE_META
	unset_k NFT_BRIDGE_REJECT

	# Netdev FIB/Reject（高级特性，home router 不需要）
	unset_k NFT_FIB_NETDEV
	unset_k NFT_REJECT_NETDEV

	# Tunnel matching（无 GRE/IPIP 隧道）
	unset_k NFT_TUNNEL

	# ARP logging（调试用）
	unset_k NF_LOG_ARP

# =============================================================================
# H.3 孤儿网络模块 / 非RK3566驱动 / 可选精简（D+E+F）
# =============================================================================
info "[H.3] 孤儿网络/非RK3566/可选精简 (~8 项)"

# --- D: 孤儿网络模块 ---
# NET_UDP_TUNNEL: VXLAN/FOU/GENEVE 全部已砍，无消费者
unset_k NET_UDP_TUNNEL
# INET6_TUNNEL: IPV6_SIT/IPV6_GRE 已砍，6in4 隧道孤儿
unset_k INET6_TUNNEL
# PSAMPLE: tc 统计采样框架，NET_SCHED/NET_CLS 全砍后无消费者
unset_k PSAMPLE

# --- E: 非RK3566驱动 ---
# FAN53555: 仅用于 RK3588 Anbernic/Powkiddy 掌机，R3S 用 RK808 PMIC
unset_k REGULATOR_FAN53555

# --- F1: loop 块设备（无 snap/flatpak，mount -o loop 不需要）---
unset_k BLK_DEV_LOOP

# --- F2: PCIe Port Bus 框架（AER/ASPM/PME/Hotplug 全关，空壳）---
unset_k PCIEPORTBUS

# --- F3: LZMA 解压（initramfs 用 gzip/lz4，.lzma 格式已淘汰）---
unset_k DECOMPRESS_LZMA
unset_k RD_LZMA

	# ============================================================================
	# G 类：Alpine/OpenRC 场景精简（CRYPTO_DRBG/解压/FHANDLE/MFD_SPI）
	# ============================================================================
	info "[H.3-G] Alpine/OpenRC 场景精简 (~11 项)"

	# --- G2a: CRYPTO DRBG 冗余（/dev/random 默认用 HMAC，HASH+CTR 是备选）---
	unset_k CRYPTO_DRBG_HASH
	unset_k CRYPTO_DRBG_CTR

	# --- G3: XZ initramfs 解压（Alpine mkinitfs 用 gzip/lz4）---
	unset_k DECOMPRESS_XZ
	unset_k RD_XZ

	# --- G6: FHANDLE（systemd 用，OpenRC 不需要。0 个 Kconfig select 它）---
	unset_k FHANDLE

	# --- G7: LZO initramfs 解压（Alpine 不用 LZO）---
	unset_k DECOMPRESS_LZO
	unset_k RD_LZO

	# --- G8: ZSTD initramfs 解压（Alpine 不用 ZSTD initramfs；ZSTD_DECOMPRESS 保留给内核模块）---
	unset_k DECOMPRESS_ZSTD
	unset_k RD_ZSTD

	# ============================================================================
	# H 类：sing-box 纯路由视角 — L2桥接/容器框架/孤儿压缩/ACL
	# ============================================================================
	info "[H.3-H] sing-box纯路由精简 (~13 项)"

	# --- H1: BRIDGE 全链（R3S仅2端口WAN+LAN，无需L2桥接）---
	# Docker 模式下 BRIDGE/STP/LLC 是默认 docker0 桥接网络必需，保留
	if [[ $ENABLE_DOCKER -eq 0 ]]; then
		unset_k BRIDGE
		unset_k STP
		unset_k LLC
		unset_k NETFILTER_FAMILY_BRIDGE
	fi

	# --- H2: IP_ROUTE_CLASSID（xt_realm + tc route 已砍，孤儿）---
	unset_k IP_ROUTE_CLASSID

	# --- H3: IPVLAN_L3S（depends on IPVLAN 已砍，def_bool y 残留）---
	unset_k IPVLAN_L3S

	# --- H4: ZSTD_COMPRESS + LZO_COMPRESS（ZRAM仅LZ4，孤儿）---
	unset_k ZSTD_COMPRESS
	unset_k LZO_COMPRESS

	# --- H5: OVERLAY_FS 残留子选项（depends on OVERLAY_FS 已砍）---
	unset_k OVERLAY_FS_REDIRECT_ALWAYS_FOLLOW
	unset_k OVERLAY_FS_XINO_AUTO

	# --- H6: FS_STACK（仅 OVERLAY_FS + ECRYPT_FS 用，均已砍）---
	unset_k FS_STACK

	# --- H7: NF_TABLES_BRIDGE（depends on BRIDGE）---
	unset_k NF_TABLES_BRIDGE

	# --- H8: ACL 全链（Alpine 默认不用 ACL，sing-box 不需要）---
	unset_k EXT4_FS_POSIX_ACL
	unset_k FS_POSIX_ACL
	unset_k TMPFS_POSIX_ACL

	# ============================================================================
	# I 类：显微镜级残余 — 孤儿NET/PCI/SYSVIPC/BONDING
	# ============================================================================
	info "[H.3-I] 显微镜级残余 (~6 项)"

	# --- I1: NET_REDIRECT（IFB 已砍，唯一selector移除）---
	unset_k NET_REDIRECT

	# --- I2: PCI_HOST_GENERIC（RK3566 用 PCIE_ROCKCHIP_DW_HOST）---
	unset_k PCI_HOST_GENERIC

	# --- I3: PCI_QUIRKS（R3S 仅 RTL8111H，无已知 quirks）---
	unset_k PCI_QUIRKS

	# --- I4: SYSVIPC（musl/OpenRC/sing-box 均不用 SysV IPC）---
	unset_k SYSVIPC
	unset_k SYSVIPC_SYSCTL
	unset_k SYSVIPC_COMPAT

	# --- I5: BONDING（R3S 2口 WAN+LAN 独立路由，不聚合）---
	unset_k BONDING

	# ============================================================================
	# J 类：孤儿 crypto 算法 — CRYPTO_CBC / MD5 / AES_ARM64_BS_NEON
	# ============================================================================
	info "[H.3-J] 孤儿crypto算法 (~6 项)"

	# --- J1: CRYPTO_CBC（15个selector全在non-RK驱动/已砍子系统）---
	# AES CE 驱动自带 CBC 硬件实现，不依赖 CRYPTO_CBC
	unset_k CRYPTO_CBC

	# --- J2: CRYPTO_MD5 + CRYPTO_LIB_MD5（TCP_MD5SIG=n，selector全在已砍子系统）---
	unset_k CRYPTO_MD5
	unset_k CRYPTO_LIB_MD5

	# --- J3+J4: AES_ARM64_BS + NEON_BLK（A55有CE硬件指令，BS/NEON是备选驱动）---
	unset_k CRYPTO_AES_ARM64_BS
	unset_k CRYPTO_AES_ARM64_NEON_BLK

	# --- K2: CRYPTO_CCM + CTR + CE_CCM（mac80211/smb已砍，CCM无消费者）---
	unset_k CRYPTO_CCM
	unset_k CRYPTO_CTR
	unset_k CRYPTO_AES_ARM64_CE_CCM

	# --- K3: CRYPTO_CHACHA20POLY1305=y（OVPN=n，WireGuard用LIB版=m）---
	unset_k CRYPTO_CHACHA20POLY1305

	# --- K4: GHASH_ARM64_CE + GF128MUL（GCM/GHASH均n，CCM不用GHASH）---
	unset_k CRYPTO_GHASH_ARM64_CE
	unset_k CRYPTO_LIB_GF128MUL

	# ============================================================================
	# M 类：TCP拥塞/调试符号精简
	# ============================================================================
	info "[H.3-M] TCP/调试精简 (~3 项)"

	# --- M1: TCP_CONG_ADVANCED + BBR（路由器自身TCP流量极小，CUBIC足够）---
	unset_k TCP_CONG_ADVANCED
	unset_k TCP_CONG_BBR

	# --- M2: SYMBOLIC_ERRNAME（errno号→名称, 生产环境不需要）---
	unset_k SYMBOLIC_ERRNAME

	# ============================================================================
	# N 类：非 R3S 硬件驱动残留
	# ============================================================================
	info "[H.3-N] 非R3S硬件驱动精简 (~5 项)"

	# --- N1: GPIO_PCA953X（I2C GPIO扩展器，R3S DTS无引用）---
	unset_k GPIO_PCA953X
	unset_k GPIO_PCA953X_IRQ

	# --- N2: REGULATOR_GPIO（GPIO调压，R3S用RK808 PMIC）---
	unset_k REGULATOR_GPIO

	# --- N3: REGULATOR_PWM（PWM调压，R3S用RK808 PMIC）---
	unset_k REGULATOR_PWM

	# --- N4: PINCTRL_SINGLE（通用单寄存器pinctrl，RK3566用ROCKCHIP驱动）---
	unset_k PINCTRL_SINGLE

	# --- Q2: BLK_CGROUP_RWSTAT + PUNT_BIO（BLK_CGROUP=n，纯孤儿）---
	unset_k BLK_CGROUP_RWSTAT
	unset_k BLK_CGROUP_PUNT_BIO

	# ============================================================================
	# R 类：DIAG调试/文件系统/模块精简
	# ============================================================================
	info "[H.3-R] DIAG/文件系统/模块精简 (~10 项)"

	# --- R1: DIAG 全砍（生产路由不需要ss/tcpdump调试）---
	unset_k PACKET_DIAG
	unset_k UNIX_DIAG
	unset_k NETLINK_DIAG
	unset_k INET_DIAG
	unset_k INET_TCP_DIAG
	unset_k INET_UDP_DIAG
	unset_k INET_RAW_DIAG

	# --- R6: FILE_LOCKING（OpenRC 服务管理必需）---
	# KEEP: OpenRC 依赖 fcntl/flock 管理服务状态和锁文件
	set_y FILE_LOCKING

	# --- R7: PROC_CHILDREN（/proc/pid/task/children，调试用）---
	unset_k PROC_CHILDREN

	# --- R8: TMPFS_XATTR（ACL已砍，/tmp扩展属性不需要）---
	unset_k TMPFS_XATTR

	# --- R9: MODULE_UNLOAD（生产环境不需要rmmod）---
	unset_k MODULE_UNLOAD

	# ============================================================================
	# S 类：孤儿crypto引擎 / HW_RANDOM可选 / IPv6 RA高级选项
	# ============================================================================
	info "[H.3-S] crypto引擎/HWRNG/IPv6RA精简 (~5 项)"

	# --- S1: CRYPTO_ENGINE（所有selector在non-RK硬件，ARM CE不用）---
	unset_k CRYPTO_ENGINE

	# --- S2: HW_RANDOM（JITTERENTROPY已提供足够CPU熵源）---
	unset_k HW_RANDOM_ROCKCHIP
	unset_k HW_RANDOM

	# --- S3: IPV6_ROUTER_PREF + ROUTE_INFO（单路由不需要RFC4191）---
	unset_k IPV6_ROUTER_PREF
	unset_k IPV6_ROUTE_INFO

	# --- U1: IO_URING + IO_WQ（Go/sing-box/Alpine不用，~50KB）---
	unset_k IO_URING
	unset_k IO_WQ

	# --- W1: NF_CT_NETLINK（conntrack -L/-D工具用，nftables NAT不需要）---
	unset_k NF_CT_NETLINK


	# --- U3: 安全硬化精简（路由器单用户、无本地shell、攻击面小）---
	unset_k RANDOMIZE_KSTACK_OFFSET
	unset_k INIT_STACK_ALL_ZERO
	unset_k INIT_ON_ALLOC_DEFAULT_ON

	# --- O1: INET_DIAG_DESTROY（ss -K关闭socket，调试用，生产路由不需要）---
	unset_k INET_DIAG_DESTROY

	# --- O2: IPV6_SUBTREES（IPv6源地址路由，高级特性）---
	unset_k IPV6_SUBTREES

	# ============================================================================
	# P 类：非必要 =m 模块精简
	# ============================================================================
	info "[H.3-P] 非必要模块精简 (~4 项)"

	# --- P1: NETFILTER_NETLINK_LOG（ulogd用，sing-box/NFT_LOG不用）---
	unset_k NETFILTER_NETLINK_LOG

	# --- P2: LEDS_TRIGGER_TIMER + ONESHOT（非必要LED效果）---
	unset_k LEDS_TRIGGER_TIMER
	unset_k LEDS_TRIGGER_ONESHOT

	# --- P3: NF_TABLES_NETDEV（sing-box用inet family，不需要netdev）---
	unset_k NF_TABLES_NETDEV

	# ============================================================================
	# L 类：非核心网络/CPU/定时器精简
	# ============================================================================
	info "[H.3-L] 非核心网络/CPU精简 (~6 项)"

	# --- L1: IP_ROUTE_MULTIPATH（2口路由单路径，不需要多路径）---
	unset_k IP_ROUTE_MULTIPATH

	# --- L2: IPV6_OPTIMISTIC_DAD（路由器用静态IPv6，不需要DAD加速）---
	unset_k IPV6_OPTIMISTIC_DAD

	# --- L3: UNIX98_PTYS（现代Linux用 /dev/pts）---
	unset_k UNIX98_PTYS

	# --- L4: NET_L3_MASTER_DEV（NET_VRF+IPVLAN_L3S均砍，孤儿）---
	unset_k NET_L3_MASTER_DEV

	# --- L5: ARM_ARCH_TIMER_EVTSTREAM（KVM已砍，不需要定时器事件流）---
	unset_k ARM_ARCH_TIMER_EVTSTREAM

	# --- L6: CPU_FREQ_GOV_PERFORMANCE（保留 ondemand+schedutil 足够）---
	unset_k CPU_FREQ_GOV_PERFORMANCE

# =============================================================================
# I. nftables 全套确认（红线，防御性 set_m）
# =============================================================================
info "[I] nftables 全套确认"

set_m NF_TABLES
set_y NF_TABLES_INET
set_y NF_TABLES_IPV4
set_y NF_TABLES_IPV6
set_m NFT_CT
set_m NFT_NAT
set_m NFT_MASQ
set_m NFT_REDIR
	set_m NFT_FLOW_OFFLOAD       # 软路由软件fast-path
	set_m NF_FLOW_TABLE
	set_m NF_FLOW_TABLE_INET
set_m NFT_REJECT
set_m NFT_REJECT_INET
set_m NFT_LOG
set_m NFT_LIMIT
set_m NFT_QUOTA
set_m NFT_HASH
set_m NFT_FIB
set_m NFT_FIB_INET
set_m NFT_FIB_IPV4
set_m NFT_FIB_IPV6
set_m NFT_TPROXY             # sing-box tproxy 需要
set_m NFT_SOCKET             # sing-box socket 匹配需要

# =============================================================================
# J. 用户态工具红线（防御性确认）
# =============================================================================
info "[J] 用户态工具红线确认"

set_m TUN
set_m WIREGUARD
set_m PPP
set_m PPPOE
unset_k PPP_MULTILINK  # 单WAN不需要多链路
set_y IPV6                   # WireGuard / cloudflared 可能用

# R8169 网卡
set_m R8169
set_y NET_VENDOR_REALTEK

# GMAC (RK3566 内置)
set_y NET_VENDOR_STMICRO
set_y STMMAC_ETH
set_y STMMAC_PLATFORM
set_y DWMAC_GENERIC
set_y DWMAC_ROCKCHIP

# PCIe (RTL8111H 走 PCIe)
set_y PCI
set_y PCIE_ROCKCHIP_HOST

# microSD
set_y MMC
set_y MMC_DW_ROCKCHIP

# rootfs
set_y EXT4_FS

# Watchdog
set_y WATCHDOG
set_y DW_WATCHDOG

# =============================================================================
# K. BPF 终结者（P0-1）
#    ⚠️ CONFIG_BPF=y 由 CONFIG_NET=y select，无法禁用（6.18+ 强制）
#    但 BPF_SYSCALL/CGROUP_BPF 可以且必须禁掉
#    root cause: NETFILTER_BPF_LINK（Armbian 核心 opts_y 注入 + default y）
# =============================================================================
if [[ $ENABLE_EBPF -eq 0 ]]; then
	info "[K] BPF 终结者 (BPF=y 由 NET=y 强制select，无法禁用)"

	# 元凶: NETFILTER_BPF_LINK (default y，select BPF_SYSCALL → select BPF → select CGROUP_BPF)
	unset_k NETFILTER_BPF_LINK

	# BPF_SYSCALL + 子项（BPF_SYSCALL select BPF，但 NET 已经 select BPF）
	unset_k BPF_SYSCALL
	unset_k BPF_JIT
	unset_k BPF_JIT_ALWAYS_ON
	unset_k BPF_JIT_DEFAULT_ON
	unset_k BPF_UNPRIV_DEFAULT_OFF

	# cgroup BPF（被 BPF_SYSCALL 反向拉起）
	unset_k CGROUP_BPF

	# 防御性：其他可能 select BPF_SYSCALL 的项
	unset_k NETFILTER_XT_MATCH_BPF    # xt_bpf（xtables 已全砍，防御性）
	unset_k LWTUNNEL_BPF              # 轻量级隧道 BPF
	unset_k XDP_SOCKETS               # XDP socket
	unset_k XDP_SOCKETS_DIAG
	unset_k BPF_STREAM_PARSER         # sockmap BPF
	unset_k BPF_EVENTS                # tracing BPF
	unset_k BPF_KPROBE_OVERRIDE
	unset_k BPF_LSM
	unset_k NET_CLS_BPF               # tc BPF 分类器
	unset_k NET_ACT_BPF               # tc BPF action

	# ⚠️ 不砍 PERF_EVENTS（影响 perf 工具、CPU 性能计数器）
	# ⚠️ 不砍 KPROBES（影响某些内核机制）
	# ⚠️ 不砍 HAVE_EBPF_JIT（架构能力声明，砍不掉）
	# ⚠️ BPF 本身无法禁（NET=y → select BPF），但 BPF=y 只是 bool 声明，无实际代码
else
	info "[K] ${YELLOW}[eBPF 模式]${NC} 保留 BPF_SYSCALL/CGROUP_BPF/JIT/XDP + BTF"
	set_y BPF_SYSCALL
	set_y BPF_JIT
	set_y BPF_JIT_ALWAYS_ON
	set_y CGROUP_BPF
	set_y BPF_EVENTS              # tracing BPF（bpftrace/bcc 需要）
	set_y XDP_SOCKETS             # XDP socket（cilium 高性能数据面）
	set_y NET_CLS_BPF             # tc BPF 分类器
	set_y NET_ACT_BPF             # tc BPF action

	# CO-RE eBPF 需要 BTF 调试信息
	set_y DEBUG_INFO
	set_y DEBUG_INFO_BTF
	set_y DEBUG_INFO_BTF_MODULES

	# NETFILTER_BPF_LINK 由 BPF_SYSCALL 拉起，不显式 set_y（让 default y 生效）
fi

# =============================================================================
# L. USB 子系统全栈砍除（USB-C 仅供电，无数据需求）
# =============================================================================
info "[L] USB 子系统全栈砍除（节省 ~1.3MB）"

# HCD 控制器
unset_k USB_SUPPORT
unset_k USB
unset_k USB_COMMON
unset_k USB_ARCH_HAS_HCD
unset_k USB_XHCI_HCD
unset_k USB_XHCI_PLATFORM
unset_k USB_XHCI_RCAR
unset_k USB_XHCI_PCI
unset_k USB_XHCI_PCI_RENESAS
unset_k USB_EHCI_HCD
unset_k USB_EHCI_HCD_PLATFORM
unset_k USB_EHCI_PCI
unset_k USB_EHCI_ROOT_HUB_TT
unset_k USB_EHCI_TT_NEWSCHED
unset_k USB_OHCI_HCD
unset_k USB_OHCI_HCD_PLATFORM
unset_k USB_OHCI_HCD_PCI

# DWC2/DWC3（Rockchip USB IP 核）
unset_k USB_DWC2
unset_k USB_DWC2_HOST
unset_k USB_DWC2_DUAL_ROLE
unset_k USB_DWC2_PERIPHERAL
unset_k USB_DWC2_PCI
unset_k USB_DWC3
unset_k USB_DWC3_HOST
unset_k USB_DWC3_DUAL_ROLE
unset_k USB_DWC3_GADGET
unset_k USB_DWC3_OF_SIMPLE
unset_k USB_DWC3_ROCKCHIP
unset_k USB_DWC3_PCI

# 通用 USB
unset_k USB_OTG
unset_k USB_OTG_FSM
unset_k USB_LEDS_TRIGGER_USBPORT
unset_k USB_AUTOSUSPEND_DELAY
unset_k USB_DEFAULT_PERSIST
unset_k USB_DYNAMIC_MINORS
unset_k USB_HID
unset_k USB_HIDDEV
unset_k USB_ACM
unset_k USB_PRINTER
unset_k USB_STORAGE
unset_k USB_UAS
unset_k USB_MON
unset_k USB_WDM
unset_k USB_TMC
unset_k USB_SERIAL
unset_k USB_NET_DRIVERS
unset_k USB_USBNET
unset_k USB_CONN_GPIO
unset_k USB_ULPI_BUS
unset_k USB_ROLE_SWITCH

# USB Gadget（设备端框架）
unset_k USB_GADGET
unset_k USB_CONFIGFS
unset_k USB_LIBCOMPOSITE
unset_k USB_F_ACM
unset_k USB_F_SS_LB
unset_k USB_F_NCM
unset_k USB_F_ECM
unset_k USB_F_EEM
unset_k USB_F_RNDIS
unset_k USB_F_MASS_STORAGE
unset_k USB_F_FS
unset_k USB_F_HID
unset_k USB_F_UAC1
unset_k USB_F_UAC2
unset_k USB_F_UVC
unset_k USB_F_MIDI
unset_k USB_F_OBEX
unset_k USB_F_SUBSET
unset_k USB_F_PRINTER
unset_k USB_G_NCM
unset_k USB_G_SERIAL
unset_k USB_G_PRINTER
unset_k USB_ETH
unset_k USB_MASS_STORAGE
unset_k USB_GADGET_TARGET

# Type-C
unset_k TYPEC
unset_k TYPEC_TCPM
unset_k TYPEC_TCPCI
unset_k TYPEC_FUSB302
unset_k TYPEC_MUX
unset_k TYPEC_DP_ALTMODE
unset_k TYPEC_HD3SS3220
unset_k TYPEC_TPS6598X
unset_k TYPEC_ANX7411
unset_k TYPEC_RT1719

# USB/USB-C 相关 PHY（关闭后 USB 物理层不初始化，纯供电不受影响）
unset_k PHY_ROCKCHIP_INNO_USB2
unset_k PHY_ROCKCHIP_INNO_USB3
unset_k PHY_ROCKCHIP_USB
unset_k PHY_ROCKCHIP_TYPEC
unset_k PHY_ROCKCHIP_NANENG_COMBPHY
unset_k PHY_ROCKCHIP_NANENG_COMBOPHY
unset_k PHY_ROCKCHIP_USBDP

# 兜底清扫
sed -i 's/^CONFIG_USB_\(.*\)=[my]/# CONFIG_USB_\1 is not set/' "$DST"
sed -i 's/^CONFIG_TYPEC\(.*\)=[my]/# CONFIG_TYPEC\1 is not set/' "$DST"

# =============================================================================
# M.0 SECURITY_APPARMOR + AUDIT 链（P0-3 root cause）
#    SECURITY_APPARMOR → select AUDIT/SECURITYFS/SECURITY_NETWORK/SECURITY_PATH
# =============================================================================
info "[M.0] 关闭 SECURITY_APPARMOR + AUDIT 链 (root cause, ~6 项)"

unset_k SECURITY_APPARMOR
unset_k SECURITYFS
unset_k SECURITY_NETWORK
unset_k SECURITY_PATH
unset_k AUDIT
unset_k AUDITSYSCALL
unset_k DEFAULT_SECURITY_APPARMOR

# =============================================================================
# M. systemd 专属 cgroup/特性砍除（openrc 不需要）
# =============================================================================
info "[M] systemd 专属 cgroup/特性砍除"

if [[ $ENABLE_DOCKER -eq 0 ]]; then
	# v1 controllers（openrc 不依赖）
	unset_k CGROUP_PIDS              # systemd 的 TasksMax 用
	unset_k CGROUP_RDMA
	unset_k CGROUP_DEVICE            # 容器设备访问控制
	unset_k CGROUP_CPUACCT
	unset_k CGROUP_PERF              # perf cgroup 隔离
	unset_k CGROUP_HUGETLB
	unset_k CGROUP_NET_PRIO
	unset_k CGROUP_NET_CLASSID
	unset_k CGROUP_MISC
	unset_k CGROUP_DMEM
	unset_k CGROUP_FREEZER           # systemd-cgroup 用，openrc 可选

	# 调度组（单一负载无需精细调度）
	unset_k RT_GROUP_SCHED
	unset_k FAIR_GROUP_SCHED
	unset_k CFS_BANDWIDTH
	unset_k CGROUP_SCHED               # 调度组框架（FAIR/RT 都依赖它）
	unset_k CPUSETS                    # cpuset cgroup

	# 块设备 cgroup
	unset_k BLK_CGROUP
	unset_k CGROUP_WRITEBACK
	unset_k BLK_CGROUP_IOLATENCY
	unset_k BLK_CGROUP_IOCOST
	unset_k BLK_CGROUP_IOPRIO
	unset_k BLK_CGROUP_FC_APPID

	# USER_NS（无容器需求；如未来需要 sing-box rootless 模式可恢复）
	unset_k USER_NS

	# systemd 专属基础设施
	unset_k FANOTIFY                 # systemd 文件监控
	unset_k FANOTIFY_ACCESS_PERMISSIONS
	unset_k AUDIT                    # systemd 审计接口
	unset_k AUDITSYSCALL
	unset_k AUDIT_WATCH
	unset_k AUDIT_TREE
	unset_k BINFMT_MISC              # systemd-binfmt；纯 ARM64 原生二进制不需要
else
	info "    ${YELLOW}[Docker 模式]${NC} 保留 cgroup controllers / USER_NS / BINFMT_MISC"
	# Docker/Podman 必需的 cgroup controllers
	set_y CGROUP_PIDS                # 限制容器内进程数（pids.max）
	set_y CGROUP_DEVICE              # 容器设备 cgroup
	set_y CGROUP_CPUACCT             # CPU 用量统计
	set_y CGROUP_HUGETLB             # 大页内存限制
	set_y CGROUP_FREEZER             # docker pause/unpause
	set_y CGROUP_NET_PRIO            # 容器网络优先级
	set_y CGROUP_NET_CLASSID         # 容器流量分类

	# 调度组（容器 CPU 配额必需）
	set_y FAIR_GROUP_SCHED
	set_y CFS_BANDWIDTH              # docker --cpus 必需
	set_y CGROUP_SCHED
	set_y CPUSETS                    # docker --cpuset-cpus

	# 块设备 cgroup（docker --device-read-bps 等）
	set_y BLK_CGROUP
	set_y BLK_CGROUP_IOLATENCY
	set_y BLK_CGROUP_IOCOST
	set_y BLK_CGROUP_IOPRIO
	set_y CGROUP_WRITEBACK

	# 用户命名空间（rootless 容器 / docker userns-remap）
	set_y USER_NS

	# 多架构镜像支持（docker buildx 跨架构镜像运行）
	set_m BINFMT_MISC

	# 注：FANOTIFY/AUDIT 仍然按 systemd 视角砍除（openrc + docker 也不需要）
	unset_k FANOTIFY
	unset_k FANOTIFY_ACCESS_PERMISSIONS
	unset_k AUDIT
	unset_k AUDITSYSCALL
	unset_k AUDIT_WATCH
	unset_k AUDIT_TREE

	# CGROUP_RDMA / MISC / DMEM / RT_GROUP_SCHED / PERF 容器不需要
	unset_k CGROUP_RDMA
	unset_k CGROUP_PERF
	unset_k CGROUP_MISC
	unset_k CGROUP_DMEM
	unset_k RT_GROUP_SCHED
fi

# =============================================================================
# N. 内核统计/调试接口砍除（路由器不需要 PSI/SCHEDSTATS 等）
# =============================================================================
info "[N] 内核统计接口砍除"

# PSI/调度统计（systemd-oomd / top 用）
unset_k PSI
unset_k PSI_DEFAULT_DISABLED
unset_k SCHEDSTATS
unset_k TASKSTATS
unset_k TASK_DELAY_ACCT
unset_k TASK_XACCT
unset_k TASK_IO_ACCOUNTING

# IRQ/统计接口
unset_k IRQ_TIME_ACCOUNTING
unset_k GENERIC_IRQ_STAT_SNAPSHOT

# /proc 调试接口
unset_k PROC_PAGE_MONITOR        # /proc/kpagecount /proc/kpageflags
unset_k PROC_VMCORE              # kdump 用
unset_k PROC_KCORE               # /proc/kcore（调试用）

# =============================================================================
# O. KEXEC / Crash dump 砍除（路由器场景不用热替换内核/崩溃转储）
# =============================================================================
info "[O] KEXEC / Crash dump 砍除（节省 ~150KB）"

unset_k KEXEC
unset_k KEXEC_FILE
unset_k KEXEC_SIG
unset_k KEXEC_IMAGE_VERIFY_SIG
unset_k KEXEC_JUMP
unset_k CRASH_DUMP
unset_k CRASH_HOTPLUG
unset_k CRASH_RESERVE

# =============================================================================
# P. INPUT 子系统极简（路由器无键盘/鼠标/触摸屏）
# =============================================================================
info "[P] INPUT 子系统极简（仅保留 GPIO 按键）"

unset_k INPUT_EVDEV              # 用户态 /dev/input/event*
unset_k INPUT_MOUSEDEV
unset_k INPUT_JOYDEV
unset_k INPUT_TABLET
unset_k INPUT_TOUCHSCREEN
unset_k INPUT_MISC
unset_k INPUT_FF_MEMLESS
unset_k INPUT_LEDS               # 输入设备 LED（键盘灯），与 GPIO LED 无关
unset_k INPUT_SPARSEKMAP
unset_k INPUT_MATRIXKMAP

# 保留：INPUT / INPUT_KEYBOARD / KEYBOARD_GPIO（如 R3S 有 reset 按钮）
# ⚠️ 如确认 R3S 无 reset 按钮需求，可手动追加：
#    unset_k INPUT
#    unset_k INPUT_KEYBOARD
#    unset_k KEYBOARD_GPIO

# =============================================================================
# Q. 加密算法/接口精简（WireGuard + TLS 用户态已自包含）
# =============================================================================
info "[Q] 加密接口精简"

# AF_ALG 用户态加密接口（sing-box/WireGuard 不用）
unset_k CRYPTO_USER_API
unset_k CRYPTO_USER_API_HASH
unset_k CRYPTO_USER_API_SKCIPHER
unset_k CRYPTO_USER_API_RNG
unset_k CRYPTO_USER_API_AEAD
unset_k CRYPTO_USER

# 冷门哈希/算法
unset_k CRYPTO_SHA3
unset_k CRYPTO_BLAKE2B
unset_k CRYPTO_MD4
unset_k CRYPTO_RMD160
unset_k CRYPTO_SM3
unset_k CRYPTO_SM3_GENERIC
unset_k CRYPTO_SM4
unset_k CRYPTO_SM4_GENERIC
unset_k CRYPTO_CAMELLIA
unset_k CRYPTO_CAST5
unset_k CRYPTO_CAST6
unset_k CRYPTO_SERPENT
unset_k CRYPTO_TWOFISH
unset_k CRYPTO_TWOFISH_COMMON
unset_k CRYPTO_BLOWFISH
unset_k CRYPTO_BLOWFISH_COMMON
unset_k CRYPTO_ANUBIS
unset_k CRYPTO_ARIA
unset_k CRYPTO_TEA
unset_k CRYPTO_KHAZAD
unset_k CRYPTO_FCRYPT

# 块加密模式（dm-crypt 已关，xfrm 已关 → 无消费者）
unset_k CRYPTO_DEFLATE           # IPCOMP 已关
unset_k CRYPTO_LZ4HC             # 仅留 LZ4

# 孤儿加密模式/IPsec 遗留（dm-crypt + IPsec 已全砍）
unset_k CRYPTO_AUTHENC           # IPsec AEAD，WireGuard 自包含
unset_k CRYPTO_ECB               # ECB 弱模式，无安全消费者
unset_k CRYPTO_CRYPTD            # dm-crypt 工作队列，已无消费者

# TEXTSEARCH（xt_string 已砍，无消费者）
unset_k TEXTSEARCH
unset_k TEXTSEARCH_BM
unset_k TEXTSEARCH_FSM
unset_k TEXTSEARCH_KMP

# ⚠️ 红线保留：
#   CRYPTO_LIB_CHACHA20POLY1305 / CRYPTO_LIB_CURVE25519 / CRYPTO_LIB_BLAKE2S
#   (WireGuard 必需，由 WIREGUARD select)
#   CRYPTO_CRC32C / LIB_CRC32C (ext4 必需)

# =============================================================================
# R. ZRAM/ZSWAP/CMA 精简（CMA 保留 — RK3566 平台 DMA 必需）
# =============================================================================
info "[R] 内存压缩/CMA 精简"

# ZSWAP 与 ZRAM 二选一，路由器选 ZRAM（已是 m）
unset_k ZSWAP
unset_k ZSWAP_DEFAULT_ON
unset_k ZSWAP_COMPRESSOR_DEFAULT_LZ4
unset_k ZSWAP_ZPOOL_DEFAULT_ZSMALLOC

# ZRAM 多余后端
unset_k ZRAM_BACKEND_842
unset_k ZRAM_BACKEND_LZ4HC
unset_k ZRAM_BACKEND_DEFLATE
unset_k ZRAM_BACKEND_LZO
unset_k ZRAM_BACKEND_ZSTD
unset_k ZRAM_WRITEBACK           # 无 swap 后端盘

# CMA 保留 — RK3566 平台 DMA 必需（IOMMU 已裁，GMAC/MMC 依赖 CMA 连续内存）
unset_k COMPACTION               # 内存压缩依赖于 CMA/hugepage

# =============================================================================
# S. 块设备调优层 / MMC 冗余平台驱动
# =============================================================================
info "[S] 块设备调优 / 其他平台 MMC 驱动砍除"

# 块设备调优（机械盘/SATA 优化，microSD 无意义）
unset_k BLK_DEV_THROTTLING
unset_k BLK_DEV_THROTTLING_LOW
unset_k BLK_WBT
unset_k BLK_WBT_MQ
unset_k MMC_CQHCI                # eMMC Command Queue，microSD 不需要

# 调整 MMC_BLOCK_MINORS（32 → 8）
sed -i '/^CONFIG_MMC_BLOCK_MINORS=/d' "$DST"
echo 'CONFIG_MMC_BLOCK_MINORS=8' >> "$DST"

# 其他平台 MMC 驱动（Hisilicon/Samsung/Mellanox）
unset_k MMC_DW_K3
unset_k MMC_DW_BLUEFIELD
unset_k MMC_DW_EXYNOS
unset_k MMC_DW_HI3798CV200
unset_k MMC_DW_HI3798MV200
unset_k MMC_DW_PCI

# =============================================================================
# T. 文件系统冗余（仅保留 ext4 + tmpfs + 必要伪文件系统）
# =============================================================================
info "[T] 文件系统冗余砍除"

unset_k BTRFS_FS                 # ~100KB+
unset_k BTRFS_FS_POSIX_ACL
unset_k BTRFS_FS_REF_VERIFY
unset_k EROFS_FS                 # 只读 fs
unset_k F2FS_FS                  # 闪存优化 fs，ext4 即可
unset_k JFS_FS
unset_k XFS_FS
unset_k REISERFS_FS
unset_k NILFS2_FS
unset_k OCFS2_FS
unset_k GFS2_FS
unset_k UDF_FS                   # 光盘 fs
unset_k EXT4_USE_FOR_EXT2        # 已有 EXT4，多余兼容层

# =============================================================================
# U. PHY 驱动精简（仅保留 R3S 实际用到的）
# =============================================================================
info "[U] PHY 驱动精简"

unset_k MOTORCOMM_PHY            # R3S 用 RTL8211F + RK 自带 PHY
unset_k PCS_XPCS                 # 10G/SerDes 用，千兆不需要
unset_k MDIO_BITBANG             # GPIO 模拟 MDIO

# 红线确认：R3S 实际用到的 PHY
set_y REALTEK_PHY                # RTL8211F (GMAC 端)
# Rockchip 内部 PHY 由 DWMAC_ROCKCHIP 处理，无需独立 PHY 驱动


# =============================================================================
# V. RAID/MD/DM 全栈砍除（路由器单 microSD，无 RAID/LVM/dm-crypt 需求）
# =============================================================================
info "[V] MD/DM 全栈砍除（节省 ~300KB）"

# MD (Multiple Devices) - 软 RAID
unset_k MD
unset_k BLK_DEV_MD
unset_k MD_AUTODETECT
unset_k MD_LINEAR
unset_k MD_RAID0
unset_k MD_RAID1
unset_k MD_RAID10
unset_k MD_RAID456
unset_k MD_MULTIPATH
unset_k MD_FAULTY
unset_k MD_CLUSTER
unset_k BCACHE                   # 块设备缓存（SSD 加速 HDD 用）
unset_k BCACHE_DEBUG
unset_k BCACHE_CLOSURES_DEBUG
unset_k BCACHE_ASYNC_REGISTRATION

# DM (Device Mapper) - LVM/dm-crypt/dm-thin 等
unset_k BLK_DEV_DM
unset_k DM_DEBUG
unset_k DM_BUFIO
unset_k DM_BIO_PRISON
unset_k DM_PERSISTENT_DATA
unset_k DM_UNSTRIPED
unset_k DM_CRYPT
unset_k DM_SNAPSHOT
unset_k DM_THIN_PROVISIONING
unset_k DM_CACHE
unset_k DM_CACHE_SMQ
unset_k DM_WRITECACHE
unset_k DM_EBS
unset_k DM_ERA
unset_k DM_CLONE
unset_k DM_MIRROR
unset_k DM_LOG_USERSPACE
unset_k DM_RAID
unset_k DM_ZERO
unset_k DM_MULTIPATH
unset_k DM_MULTIPATH_QL
unset_k DM_MULTIPATH_ST
unset_k DM_MULTIPATH_HST
unset_k DM_MULTIPATH_IOA
unset_k DM_DELAY
unset_k DM_DUST
unset_k DM_INIT
unset_k DM_UEVENT
unset_k DM_FLAKEY
unset_k DM_VERITY                # Android 启动校验，R3S 无
unset_k DM_VERITY_VERIFY_ROOTHASH_SIG
unset_k DM_VERITY_FEC
unset_k DM_SWITCH
unset_k DM_LOG_WRITES
unset_k DM_INTEGRITY
unset_k DM_AUDIT

# =============================================================================
# W. 声卡/多媒体/图形子系统兜底（R3S 无 HDMI/音频/摄像头，但配置可能残留）
# =============================================================================
info "[W] 声卡/多媒体/图形兜底砍除"

# ALSA / 声卡
unset_k SOUND
unset_k SND
unset_k SND_SOC
unset_k SND_SOC_ROCKCHIP
unset_k SND_SOC_ROCKCHIP_I2S
unset_k SND_SOC_ROCKCHIP_I2S_TDM
unset_k SND_SOC_ROCKCHIP_PDM
unset_k SND_SOC_ROCKCHIP_SPDIF
unset_k SND_SOC_ROCKCHIP_VAD
unset_k SND_SOC_ROCKCHIP_MULTI_DAIS
unset_k SND_SIMPLE_CARD
unset_k SND_SIMPLE_CARD_UTILS
unset_k SND_AUDIO_GRAPH_CARD
unset_k SND_AUDIO_GRAPH_CARD2
unset_k SND_SOC_HDMI_CODEC
unset_k SND_HDA
unset_k SND_USB
unset_k SND_PCM
unset_k SND_TIMER
unset_k SND_PCI
unset_k SND_SPI
unset_k SND_DRIVERS
unset_k SND_VIRTIO

# V4L2 / 摄像头
unset_k MEDIA_SUPPORT
unset_k VIDEO_DEV
unset_k MEDIA_CAMERA_SUPPORT
unset_k MEDIA_ANALOG_TV_SUPPORT
unset_k MEDIA_DIGITAL_TV_SUPPORT
unset_k MEDIA_RADIO_SUPPORT
unset_k MEDIA_SDR_SUPPORT
unset_k MEDIA_PLATFORM_SUPPORT
unset_k MEDIA_TEST_SUPPORT
unset_k MEDIA_CEC_SUPPORT
unset_k MEDIA_CONTROLLER
unset_k V4L_PLATFORM_DRIVERS
unset_k V4L_MEM2MEM_DRIVERS
unset_k VIDEO_ROCKCHIP_ISP1
unset_k VIDEO_ROCKCHIP_RGA
unset_k VIDEO_ROCKCHIP_VPU
unset_k VIDEO_HANTRO
unset_k VIDEO_HANTRO_ROCKCHIP

# DRM / GPU（R3S 是无头部署，但 Mali/Lima 驱动可能开着）
unset_k DRM
unset_k DRM_ROCKCHIP
unset_k DRM_PANFROST              # Mali GPU 用户态驱动
unset_k DRM_LIMA                  # Mali Utgard
unset_k DRM_PANEL
unset_k DRM_BRIDGE
unset_k DRM_DISPLAY_HELPER
unset_k DRM_FBDEV_EMULATION
unset_k DRM_DP_AUX_CHARDEV
unset_k DRM_KMS_HELPER
unset_k DRM_GEM_DMA_HELPER
unset_k DRM_GEM_SHMEM_HELPER

# Framebuffer / Console
unset_k FB
unset_k FB_DEVICE
unset_k FB_SIMPLE
unset_k FRAMEBUFFER_CONSOLE
unset_k FRAMEBUFFER_CONSOLE_DETECT_PRIMARY
unset_k FRAMEBUFFER_CONSOLE_ROTATION
unset_k FRAMEBUFFER_CONSOLE_DEFERRED_TAKEOVER
unset_k LOGO

# Backlight / Panel
unset_k BACKLIGHT_CLASS_DEVICE
unset_k BACKLIGHT_PWM
unset_k LCD_CLASS_DEVICE

# VGA Console（理论 arm64 无 VGA，防御性）
unset_k VGA_CONSOLE
unset_k DUMMY_CONSOLE

# HID（USB 砍后多数自动失效，兜底）
unset_k HID
unset_k HID_GENERIC
unset_k HID_SUPPORT
unset_k UHID

# =============================================================================
# X. 蓝牙 / 无线 80211 / NFC / 红外（R3S 无任何无线硬件）
# =============================================================================
info "[X] 无线/蓝牙/NFC/红外砍除"

# 蓝牙
unset_k BT
unset_k BT_BREDR
unset_k BT_RFCOMM
unset_k BT_BNEP
unset_k BT_HIDP
unset_k BT_HS
unset_k BT_LE
unset_k BT_6LOWPAN
unset_k BT_LEDS
unset_k BT_MSFTEXT
unset_k BT_AOSPEXT
unset_k BT_DEBUGFS
unset_k BT_HCIBTUSB
unset_k BT_HCIUART
unset_k BT_HCIBCM203X
unset_k BT_HCIBPA10X
unset_k BT_HCIBFUSB
unset_k BT_HCIDTL1
unset_k BT_HCIBT3C
unset_k BT_HCIBLUECARD
unset_k BT_HCIVHCI
unset_k BT_MRVL
unset_k BT_MRVL_SDIO
unset_k BT_MTKSDIO
unset_k BT_MTKUART
unset_k BT_QCOMSMD
unset_k BT_RTL
unset_k BT_VIRTIO

# 80211 协议栈
unset_k CFG80211
unset_k MAC80211
unset_k WIRELESS
unset_k WIRELESS_EXT
unset_k WEXT_CORE
unset_k WEXT_PROC
unset_k WEXT_SPY
unset_k WEXT_PRIV
unset_k WLAN
unset_k WLAN_VENDOR_ADMTEK
unset_k WLAN_VENDOR_ATH
unset_k WLAN_VENDOR_ATMEL
unset_k WLAN_VENDOR_BROADCOM
unset_k WLAN_VENDOR_CISCO
unset_k WLAN_VENDOR_INTEL
unset_k WLAN_VENDOR_INTERSIL
unset_k WLAN_VENDOR_MARVELL
unset_k WLAN_VENDOR_MEDIATEK
unset_k WLAN_VENDOR_MICROCHIP
unset_k WLAN_VENDOR_PURELIFI
unset_k WLAN_VENDOR_RALINK
unset_k WLAN_VENDOR_REALTEK
unset_k WLAN_VENDOR_RSI
unset_k WLAN_VENDOR_SILABS
unset_k WLAN_VENDOR_ST
unset_k WLAN_VENDOR_TI
unset_k WLAN_VENDOR_ZYDAS
unset_k WLAN_VENDOR_QUANTENNA

# NFC
unset_k NFC

# 红外
unset_k RC_CORE
unset_k MEDIA_RC_SUPPORT
unset_k LIRC

# =============================================================================
# Y. 调试/Tracing/性能监控全砍（生产路由器不需要）
# =============================================================================
info "[Y] 调试/Tracing 兜底"

# Perf 性能计数器（生产路由器不需要）
unset_k PERF_EVENTS

# 内核符号表（无 tracing/bpf 后无用，但可能影响模块加载，先关闭观察）
unset_k KALLSYMS

# ELF core dump（路由器不产生 core dump）
unset_k ELFCORE

# Ftrace 全套（BPF 已砍，ftrace 无消费者）
unset_k FTRACE
unset_k FUNCTION_TRACER
unset_k FUNCTION_GRAPH_TRACER
unset_k DYNAMIC_FTRACE
unset_k STACK_TRACER
unset_k IRQSOFF_TRACER
unset_k PREEMPT_TRACER
unset_k SCHED_TRACER
unset_k HWLAT_TRACER
unset_k OSNOISE_TRACER
unset_k TIMERLAT_TRACER
unset_k MMIOTRACE
unset_k FTRACE_SYSCALLS
unset_k TRACER_SNAPSHOT
unset_k BLK_DEV_IO_TRACE
unset_k FPROBE
unset_k FUNCTION_ERROR_INJECTION
unset_k FAULT_INJECTION

# KASAN/KCSAN/UBSAN（开发期检测器，生产关闭）
unset_k KASAN
unset_k KCSAN
unset_k UBSAN
unset_k KFENCE
unset_k KMSAN

# 内存调试
unset_k DEBUG_KMEMLEAK
unset_k DEBUG_OBJECTS
unset_k DEBUG_PAGEALLOC
unset_k DEBUG_RODATA_TEST
unset_k DEBUG_WX
unset_k DEBUG_VM
unset_k DEBUG_VM_PGFLAGS
unset_k DEBUG_VM_RB
unset_k DEBUG_VIRTUAL
unset_k DEBUG_MEMORY_INIT
unset_k DEBUG_SHIRQ
unset_k DEBUG_TIMEKEEPING
unset_k DEBUG_PREEMPT
unset_k DEBUG_RT_MUTEXES
unset_k DEBUG_SPINLOCK
unset_k DEBUG_MUTEXES
unset_k DEBUG_WW_MUTEX_SLOWPATH
unset_k DEBUG_RWSEMS
unset_k DEBUG_LOCK_ALLOC
unset_k PROVE_LOCKING
unset_k LOCK_STAT
unset_k DEBUG_LOCKDEP
unset_k DEBUG_ATOMIC_SLEEP
unset_k DEBUG_LIST
unset_k DEBUG_PLIST
unset_k DEBUG_SG
unset_k DEBUG_NOTIFIERS
unset_k DEBUG_CREDENTIALS
unset_k DEBUG_KOBJECT_RELEASE
unset_k DEBUG_STACK_USAGE
unset_k DEBUG_INFO_DWARF_TOOLCHAIN_DEFAULT
unset_k DEBUG_INFO_DWARF4
unset_k DEBUG_INFO_DWARF5
unset_k DEBUG_INFO_REDUCED
unset_k DEBUG_INFO_COMPRESSED_NONE
unset_k DEBUG_INFO_COMPRESSED_ZLIB
unset_k DEBUG_INFO_COMPRESSED_ZSTD
unset_k DEBUG_INFO_SPLIT
unset_k GDB_SCRIPTS
unset_k READABLE_ASM
unset_k HEADERS_INSTALL

# DEBUG_INFO 整体关闭（生产内核不需要符号）
# eBPF 模式下保留 DEBUG_INFO_BTF（CO-RE eBPF 必需），其他仍然砍
if [[ $ENABLE_EBPF -eq 0 ]]; then
	unset_k DEBUG_INFO
	unset_k DEBUG_INFO_NONE
	unset_k DEBUG_INFO_BTF           # ⚠️ BPF 已砍，BTF 也无意义
	unset_k DEBUG_INFO_BTF_MODULES
else
	info "    [eBPF 模式] 保留 DEBUG_INFO + BTF（CO-RE eBPF 需要）"
	# 已在 K 节用 set_y 启用，此处不重复
fi

# Magic SysRq（生产环境无控制台，砍掉）
unset_k MAGIC_SYSRQ
unset_k MAGIC_SYSRQ_DEFAULT_ENABLE
unset_k MAGIC_SYSRQ_SERIAL

# Lockup/Hung 检测器（生产可保留 1 个，砍其余）
unset_k SOFTLOCKUP_DETECTOR
unset_k HARDLOCKUP_DETECTOR
unset_k DETECT_HUNG_TASK
unset_k WQ_WATCHDOG
unset_k RCU_CPU_STALL_TIMEOUT_DEBUG

# Coresight（ARM 硬件 trace，调试用）
unset_k CORESIGHT
unset_k CORESIGHT_LINKS_AND_SINKS
unset_k CORESIGHT_LINK_AND_SINK_TMC
unset_k CORESIGHT_CATU
unset_k CORESIGHT_SINK_TPIU
unset_k CORESIGHT_SINK_ETBV10
unset_k CORESIGHT_SOURCE_ETM4X
unset_k CORESIGHT_STM
unset_k CORESIGHT_CPU_DEBUG
unset_k CORESIGHT_CTI
unset_k CORESIGHT_TRBE

# =============================================================================
# Y.2 nftables 冗余模块 + conntrack 瘦身（纯路由不需要高级匹配）
# =============================================================================
info "[Y.2] nftables 冗余模块/conntrack 瘦身"

# DUP/FWD — 包复制/转发（IDS/监控用，路由器不需要）
unset_k NF_DUP_NETDEV
unset_k NFT_DUP_NETDEV
unset_k NFT_FWD_NETDEV
unset_k NF_DUP_IPV4
unset_k NFT_DUP_IPV4
unset_k NF_DUP_IPV6
unset_k NFT_DUP_IPV6

# QUOTA/HASH — 配额/hash limit match
unset_k NFT_QUOTA
unset_k NFT_HASH

# SOCKET match — 按 socket 属性匹配（罕见场景）
unset_k NFT_SOCKET
unset_k NF_SOCKET_IPV4
unset_k NF_SOCKET_IPV6

# TPROXY — 透明代理（sing-box 只用 TUN，不用 TPROXY）
unset_k NFT_TPROXY
unset_k NF_TPROXY_IPV4
unset_k NF_TPROXY_IPV6

# FIB lookup — nftables 路由表查询（罕见场景）
unset_k NFT_FIB
unset_k NFT_FIB_INET
unset_k NFT_FIB_NETDEV
unset_k NFT_FIB_IPV4
unset_k NFT_FIB_IPV6

# conntrack 精简：去掉 labels/zones/events（多租户/监控特性）
unset_k NF_CONNTRACK_LABELS
unset_k NF_CONNTRACK_ZONES
unset_k NF_CONNTRACK_EVENTS

# conntrack netlink 接口（用户态 conntrack 工具不需要）
unset_k NETFILTER_NETLINK

# bridge netfilter — 桥接已砍，bridge netfilter 无意义
unset_k NETFILTER_FAMILY_BRIDGE
unset_k NF_TABLES_BRIDGE

# ARP netfilter family — 路由器不需要 ARP 层过滤
unset_k NETFILTER_FAMILY_ARP
unset_k NF_TABLES_ARP

# IPIP tunnel — IP-over-IP（WireGuard + TUN 足够）
unset_k NET_IP_TUNNEL

# UDP tunnel — 底层框架（无 VXLAN/FOU/GENEVE 消费者）
unset_k NET_UDP_TUNNEL

# 网络自测试、busy poll、流控 — 生产不需要
unset_k NET_SELFTESTS
unset_k NET_RX_BUSY_POLL
unset_k NET_FLOW_LIMIT
unset_k SOCK_RX_QUEUE_MAPPING

# =============================================================================
# Y.3 内核框架瘦身（无容器/无调试场景）
# =============================================================================
info "[Y.3] 内核框架瘦身"

# Memory cgroup — 无 Docker/容器不需要内存分组限制
if [[ $ENABLE_DOCKER -eq 0 ]]; then
	unset_k MEMCG
else
	set_y MEMCG                  # docker -m / --memory 必需
fi

# DEBUG_KERNEL — 调试框架门控（生产关闭）
unset_k DEBUG_KERNEL

# POWER_SUPPLY — 电源框架（R3S 无电池）
unset_k POWER_SUPPLY

# CPU_FREQ ondemand governor — 只保留 schedutil（A55 EAS 推荐）
unset_k CPU_FREQ_GOV_ONDEMAND
unset_k CPU_FREQ_DEFAULT_GOV_ONDEMAND

# CPU_IDLE menu governor — 只保留 ladder（DDR 延迟远大于 governor 差异）
unset_k CPU_IDLE_GOV_MENU

# LED 触发器精简（保留 heartbeat/default_on/user 用于 GPIO LED）
unset_k LEDS_TRIGGER_CPU
unset_k LEDS_TRIGGER_ACTIVITY
unset_k LEDS_TRIGGER_PANIC

# GPIO legacy 接口（使用 cdev 替代）
unset_k GPIOLIB_LEGACY

# 非 RK Freescale UART
unset_k SERIAL_8250_FSL

# 加密瘦身
unset_k CRYPTO_SHA3              # WireGuard 用 BLAKE2s，nft 不用 SHA3
unset_k CRYPTO_ECB               # ECB 不安全模式，check 无消费者
unset_k CRYPTO_HW                # HW 加密框架（Rockchip engine 已砍）

# =============================================================================
# Y.4 安全可砍残余（perf/acl/组播/时钟等）
# =============================================================================
info "[Y.4] 安全可砍残余"

# ARM PMU 硬件性能计数器（PERF_EVENTS 已砍，无消费者）
unset_k ARM_PMU
unset_k ARM_PMUV3

# 软件 RSS/XPS（R8169 单队列网卡无收益，加逐包开销）
unset_k RPS
unset_k XPS

# POSIX ACL（单用户路由器不需要文件 ACL）
unset_k FS_POSIX_ACL
unset_k EXT4_FS_POSIX_ACL

# sysctl 异常追踪（调试）
unset_k SYSCTL_EXCEPTION_TRACE

# 匿名 VMA 命名（调试/Android 用）
unset_k ANON_VMA_NAME

# CMA 已保留，CONTIG_ALLOC 也随之保留（连续内存助手）

# 页面迁移（COMPACTION/NUMA 全砍后无消费者）
unset_k MIGRATION

# UNIX socket OOB（带外数据，几乎无人使用）
unset_k AF_UNIX_OOB

# PTP 精密时钟（电信/工业用，路由器不需要）
unset_k PTP_1588_CLOCK_OPTIONAL

# =============================================================================
# Y.5 v2.2：冷门内核特性/残留框架精简（~5 项）
# =============================================================================
info "[Y.5] 冷门内核特性/残留框架精简"

# LED_TRIGGER_PHY — PHY link LED 触发器
# R3S 使用 r8169/stmmac 驱动内置 LED trigger，不依赖此框架
unset_k LED_TRIGGER_PHY

# HW_PERF_EVENTS — 硬件 perf 计数器（PERF_EVENTS + ARM_PMU 已全关）
unset_k HW_PERF_EVENTS

# VM_EVENT_COUNTERS — /proc/vmstat（生产路由器不需要内存统计）
unset_k VM_EVENT_COUNTERS

# INITRAMFS_PRESERVE_MTIME — initramfs 内文件 mtime 保留（无价值）
unset_k INITRAMFS_PRESERVE_MTIME

# CRYPTO_JITTERENTROPY — jitter 熵源（R3S 有 HW_RANDOM_ROCKCHIP）
# 注意：JITTERENTROPY select CRYPTO_SHA3，不关它 SHA3 关不掉！⚠️
unset_k CRYPTO_JITTERENTROPY

# CRYPTO_CHACHA20 — 通用 ChaCha20 流密码（孤儿，零消费者）
# WireGuard 使用 CRYPTO_LIB_CHACHA20POLY1305（库版本），不依赖此 API 版本
# ADIANTUM（磁盘加密）和 CHACHA20POLY1305（OpenVPN加速）都已禁用
unset_k CRYPTO_CHACHA20

# ZLIB_DEFLATE — 压缩库（孤儿，所有消费者已禁用）
# CRYPTO_DEFLATE/ZRAM_DEFLATE/PPP_DEFLATE/BTRFS/JFFS2 全部 n
unset_k ZLIB_DEFLATE

# LZO_DECOMPRESS — LZO 解压（孤儿，CRYPTO_LZO/ZRAM_LZO/BTRFS/JFFS2/SQUASHFS 全部 n）
unset_k LZO_DECOMPRESS

# FREEZER — suspend/hibernate 进程冷冻器
# PM_SLEEP 和 CGROUP_FREEZER 均未启用，def_bool 结果为 n
# Docker 模式下 CGROUP_FREEZER=y 会 select FREEZER，此处不强制砍
if [[ $ENABLE_DOCKER -eq 0 ]]; then
	unset_k FREEZER
fi

# =============================================================================
# Y.7 v2.4：编译实测后孤儿/冗余项清扫（~6 项）
# =============================================================================
info "[Y.7] 编译实测后孤儿/冗余项清扫"

# TRACING_SUPPORT — 追踪框架基础设施（hidden, default y, 无 select）
# FTRACE/KPROBES 已全砍，底层框架无用
unset_k TRACING_SUPPORT

# SCSI_MOD — SCSI 层已关(n)，但 default y if SCSI=n 让它继续=y
unset_k SCSI_MOD

# DUMMY — dummy 虚拟网卡（测试用，路由器不需要）
# Armbian 注入为 opts_m，需同时在 remove_from_m 过滤
unset_k DUMMY

# PRINTK_TIME — dmesg 行首时间戳前缀（调试用）
unset_k PRINTK_TIME

# PCI_SYSCALL — PCI syscall 接口（ARM64 已废弃，隐藏 bool）
unset_k PCI_SYSCALL

# DECOMPRESS_ZSTD — ZSTD 解压（ZRAM ZSTD 后端已禁，模块压缩未用）
unset_k DECOMPRESS_ZSTD

# DW_WATCHDOG — Synopsys DesignWare watchdog（R3S DTS 未使用）
unset_k DW_WATCHDOG

# GPIOLIB_LEGACY — 老旧 GPIO sysfs 接口（def_bool y，需显式禁用）
unset_k GPIOLIB_LEGACY

# GPIO_CDEV_V1 — 老旧 GPIO CDEV ABI v1（deprecated，V2 替代）
unset_k GPIO_CDEV_V1

# RTC_I2C_AND_SPI — RTC I2C/SPI 总线层（default y if I2C=y, RK808 不依赖）
unset_k RTC_I2C_AND_SPI

# RTC_NVMEM — RTC 非易失存储（无电池 RTC，无消费者）
unset_k RTC_NVMEM

# DEBUG_BUGVERBOSE — 详细 BUG() 输出（生产路由器不需要，~70KB）
unset_k DEBUG_BUGVERBOSE

# CPU_FREQ 默认 governor 修正：schedutil 是 ARM64/A55 EAS 推荐
unset_k CPU_FREQ_DEFAULT_GOV_PERFORMANCE
set_y CPU_FREQ_DEFAULT_GOV_SCHEDUTIL

# TMPFS_POSIX_ACL — tmpfs 文件 ACL（select FS_POSIX_ACL 的根节点）
# 禁此项后 FS_POSIX_ACL 自动消失（失去唯一ARM64消费者）
unset_k TMPFS_POSIX_ACL

# LRU_GEN — 多代LRU 页面回收（服务器/手机优化，2GB 路由标准LRU足够）
unset_k LRU_GEN
unset_k LRU_GEN_ENABLED
unset_k LRU_GEN_WALKS_MMU

# PWM_ROCKCHIP — R3S DTS 无 PWM 消费者（无风扇/背光）
unset_k PWM_ROCKCHIP
unset_k PWM_ROCKCHIP_V4

# PER_VMA_LOCK — 多线程 VMA 锁优化（def_bool y, 单用户路由不需要）
unset_k PER_VMA_LOCK

# INIT_STACK_ALL_PATTERN — 最强栈初始化，转为不初始化（省代码+CPU）
unset_k INIT_STACK_ALL_PATTERN

# RANDOMIZE_BASE (KASLR) — 内核地址随机化，路由器无本地用户不需
unset_k RANDOMIZE_BASE
unset_k RELOCATABLE

# NET_IP_TUNNEL — IP隧道（IPIP/GRE/VTI全禁，孤儿模块）
unset_k NET_IP_TUNNEL

# VDSO_GETRANDOM — VDSO fast getrandom(), 禁后走syscall
unset_k VDSO_GETRANDOM

# MULTIUSER — 多用户/组/权限支持（OpenRC 单用户路由不需要）
# Docker/容器需要 NAMESPACES，而 NAMESPACES depends on MULTIUSER
if [[ $ENABLE_DOCKER -eq 0 ]]; then
	unset_k MULTIUSER
else
	set_y MULTIUSER              # 容器必需：恢复后级联拉起 NAMESPACES
	set_y NAMESPACES
	set_y UTS_NS
	set_y IPC_NS
	set_y PID_NS
	set_y NET_NS
	set_y CGROUP_NS
	set_y TIME_NS
	set_y POSIX_MQUEUE           # docker 容器内 IPC 可能用
fi

# EFI_PARTITION — GPT 分区表（必须保留！Armbian r3s.csc 使用 GPT）
# IMAGE_PARTITION_TABLE="gpt" → 内核需 GPT 支持才能读取分区表

# IP_MULTICAST — IPv6/NDP 依赖组播，保留

# =============================================================================
# Z. 杂项总清扫（GPIO/I2C/SPI/PWM 等保留必要，砍冗余驱动）
# =============================================================================
info "[Z] 总线/传感器/RTC 等冗余驱动清扫"

# IIO 工业 IO（路由器无传感器需求）
unset_k IIO
unset_k IIO_BUFFER
unset_k IIO_KFIFO_BUF
unset_k IIO_TRIGGER
unset_k IIO_TRIGGERED_BUFFER
unset_k IIO_SW_DEVICE
unset_k IIO_SW_TRIGGER

# Sensors / HWMON 多数（保留 RK808/RK817 PMIC 温度，其他砍）
unset_k SENSORS_LM75
unset_k SENSORS_LM77
unset_k SENSORS_LM80
unset_k SENSORS_LM83
unset_k SENSORS_LM85
unset_k SENSORS_LM87
unset_k SENSORS_LM90
unset_k SENSORS_LM92
unset_k SENSORS_LM93
unset_k SENSORS_LM95234
unset_k SENSORS_LM95241
unset_k SENSORS_LM95245
unset_k SENSORS_W83773G
unset_k SENSORS_PWM_FAN

# 1-Wire（无 1-wire 设备）
unset_k W1
unset_k W1_MASTER_DS2490
unset_k W1_MASTER_DS2482
unset_k W1_MASTER_GPIO
unset_k W1_SLAVE_THERM
unset_k W1_SLAVE_SMEM
unset_k W1_SLAVE_DS2405
unset_k W1_SLAVE_DS2408
unset_k W1_SLAVE_DS2413
unset_k W1_SLAVE_DS2406
unset_k W1_SLAVE_DS2423
unset_k W1_SLAVE_DS2805
unset_k W1_SLAVE_DS2780
unset_k W1_SLAVE_DS2781
unset_k W1_SLAVE_DS2431
unset_k W1_SLAVE_DS2433
unset_k W1_SLAVE_DS2438
unset_k W1_SLAVE_DS250X
unset_k W1_SLAVE_DS2780
unset_k W1_SLAVE_DS28E04
unset_k W1_SLAVE_DS28E17

# Power Supply 多数（保留 RK808 PMIC，其他电池/充电 IC 砍）
unset_k POWER_RESET_GPIO
unset_k POWER_RESET_GPIO_RESTART
unset_k POWER_RESET_RESTART
unset_k POWER_RESET_SYSCON
unset_k POWER_RESET_SYSCON_POWEROFF
unset_k BATTERY_BQ27XXX
unset_k CHARGER_BQ24190
unset_k CHARGER_BQ24257
unset_k CHARGER_BQ24735
unset_k CHARGER_BQ25890
unset_k CHARGER_BQ25980
unset_k CHARGER_BQ256XX
unset_k BATTERY_SBS
unset_k BATTERY_BQ27XXX_I2C
unset_k BATTERY_BQ27XXX_HDQ

# RTC 多数（保留 RK808 PMIC RTC，其他 I2C/SPI RTC 砍）
unset_k RTC_DRV_DS1307
unset_k RTC_DRV_DS1374
unset_k RTC_DRV_DS1672
unset_k RTC_DRV_DS3232
unset_k RTC_DRV_MAX6900
unset_k RTC_DRV_PCF8523
unset_k RTC_DRV_PCF85063
unset_k RTC_DRV_PCF85363
unset_k RTC_DRV_PCF8563
unset_k RTC_DRV_PCF8583
unset_k RTC_DRV_M41T80
unset_k RTC_DRV_RX8581
unset_k RTC_DRV_RX8025
unset_k RTC_DRV_EM3027
unset_k RTC_DRV_RV3028
unset_k RTC_DRV_RV3032
unset_k RTC_DRV_RV8803
unset_k RTC_DRV_SD3078
unset_k RTC_DRV_S35390A
unset_k RTC_DRV_FM3130
unset_k RTC_DRV_RX8010
unset_k RTC_DRV_DS3232_HWMON
# RTC_DRV_HYM8563 不可裁！R3S 板载 RTC 芯片就是 HYM8563（DTB: rtc@51 compatible="haoyu,hym8563"），
# 是设备树指定的 rtc0。砍掉会导致 RTC_HCTOSYS_DEVICE="rtc0" 找不到设备，且 sing-box TLS 校时失败。
# 历史上已修过一次（见 CLAUDE.md E.0），勿再误砍。

# 字符设备杂项
unset_k TCG_TPM                  # TPM 安全芯片，R3S 无
unset_k TCG_TIS
unset_k TCG_TIS_I2C
unset_k TCG_TIS_SPI
unset_k TCG_ATMEL
unset_k TCG_INFINEON
unset_k TCG_CRB
unset_k TCG_VTPM_PROXY
unset_k HW_RANDOM_VIRTIO
unset_k HW_RANDOM_OMAP
unset_k HW_RANDOM_BA431
unset_k HW_RANDOM_CCTRNG
unset_k HW_RANDOM_XIPHERA
unset_k HW_RANDOM_ARM_SMCCC_TRNG # 保留 ROCKCHIP TRNG（如有）

# 红线确认：RK808 PMIC 全套（R3S 必需）
set_y MFD_RK8XX
set_y MFD_RK8XX_I2C
set_y REGULATOR_RK808
set_y RTC_DRV_RK808
set_y COMMON_CLK_RK808
# 红线：HYM8563 是 R3S 板载 RTC（DTB rtc@51 / rtc0），强制内置防止误砍
set_y RTC_DRV_HYM8563

# Thermal（保留 Rockchip thermal，砍其他平台）
unset_k THERMAL_WRITABLE_TRIPS
unset_k THERMAL_DEFAULT_GOV_FAIR_SHARE
unset_k THERMAL_DEFAULT_GOV_USER_SPACE
unset_k THERMAL_DEFAULT_GOV_POWER_ALLOCATOR
unset_k THERMAL_GOV_BANG_BANG
unset_k THERMAL_GOV_FAIR_SHARE
unset_k THERMAL_GOV_USER_SPACE
unset_k THERMAL_GOV_POWER_ALLOCATOR
unset_k DEVFREQ_THERMAL
unset_k THERMAL_EMULATION

# 红线：Rockchip thermal + step-wise governor
set_y ROCKCHIP_THERMAL
set_y THERMAL_GOV_STEP_WISE
set_y THERMAL_DEFAULT_GOV_STEP_WISE

# 其他冷门
unset_k PROFILING                # oprofile 时代遗留
unset_k OPROFILE
unset_k JUMP_LABEL               # 与 tracing 配套，砍 ftrace 后多余 ⚠️但很多模块用，慎重
# 注：JUMP_LABEL 关闭可能影响 static_branch 性能优化，建议保留观察
sed -i '/^# CONFIG_JUMP_LABEL is not set/d' "$DST"
echo 'CONFIG_JUMP_LABEL=y' >> "$DST"

unset_k STRICT_DEVMEM             # /dev/mem 写保护（生产建议保留 ⚠️）
# 改主意：StrictDevmem 是安全特性，保留
set_y STRICT_DEVMEM
set_y IO_STRICT_DEVMEM



# =============================================================================
# 完成
# =============================================================================
ok "最终 config 已写入：$DST"

# 统计
y_count=$(grep -cE '^CONFIG_.*=y$' "$DST" || true)
m_count=$(grep -cE '^CONFIG_.*=m$' "$DST" || true)
ym_total=$((y_count + m_count))
src_total=$(grep -cE '^CONFIG_.*=(y|m)$' "$SRC" || true)
diff_count=$((src_total - ym_total))

info "Baseline (y/m): $src_total"
info "Final (y/m):    $ym_total  (=y: $y_count, =m: $m_count)"
info "净减少:          $diff_count 项"

# ---------- 生成文件 y/m 统计（最终核对） ----------
gen_y=$(grep -cE '^CONFIG_[A-Za-z0-9_]+=y$'  "$DST" || true)
gen_m=$(grep -cE '^CONFIG_[A-Za-z0-9_]+=m$'  "$DST" || true)
echo ""
ok "生成的 config 文件统计：$DST"
echo "  裁剪模式：${TRIM_MODE}  (Docker=${ENABLE_DOCKER}, eBPF=${ENABLE_EBPF})"
echo "  =y 项：$gen_y"
echo "  =m 项：$gen_m"
echo "  合计 ：$((gen_y + gen_m))"

echo ""
info "下一步："
echo "  cp \"$DST\" /path/to/armbian-build/userpatches/linux-rockchip64-current.config"
echo "  cd /path/to/armbian-build"
echo "  bash compile.sh BOARD=nanopi-r3s BRANCH=current KERNEL_CONFIGURE=no KERNEL_ONLY=yes"
