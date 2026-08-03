#!/usr/bin/env bash
# =============================================================================
# nanopir3s-kconfig.sh — NanoPi R3S 路由器专用内核配置撤销钩子
#
# 运行时机: custom_kernel_config（Armbian 注入 opts_y/opts_m 之后，olddefconfig 之前）
# 用途:     从 Armbian 核心注入列表中删除 R3S 路由器不需要的项
#
# 关键原理: Armbian 的 armbian_kernel_config_apply_opts_from_arrays()
#           先处理 opts_n，再处理 opts_y/opts_m，所以仅加 opts_n 无效！
#           必须从 opts_y/opts_m 数组中删除对应项。
# =============================================================================

function custom_kernel_config__nanopir3s_undo_armbian_ebpf_injections() {
	display_alert "${EXTENSION}" "Undoing Armbian eBPF/DEBUG/BTF injections for minimal R3S router kernel"

	# =========================================================================
	# 裁剪模式检测（与 trim-r3s-kernel.sh --mode 对齐）
	#   读取优先级：环境变量 R3S_TRIM_MODE > userpatches/.trim-mode 标记文件 > minimal
	#   docker/ebpf/full 模式下，对应的容器/eBPF 符号会进入 keep_set，
	#   在后续 opts_y/opts_m 过滤、opts_n 追加、.config 直写四处全部跳过，
	#   避免把 trim 脚本刚开启的项又关掉。
	# =========================================================================
	local trim_mode="${R3S_TRIM_MODE:-}"
	if [[ -z "$trim_mode" ]]; then
		local mode_file
		for mode_file in \
			"$(dirname "$(dirname "${BASH_SOURCE[0]}")")/.trim-mode" \
			"$(dirname "${BASH_SOURCE[0]}")/.trim-mode" \
			"./userpatches/.trim-mode" \
			"./.trim-mode"; do
			[[ -f "$mode_file" ]] && { trim_mode="$(<"$mode_file")"; break; }
		done
	fi
	trim_mode="${trim_mode//[[:space:]]/}"
	[[ -z "$trim_mode" ]] && trim_mode="minimal"

	local enable_docker=0 enable_ebpf=0
	case "$trim_mode" in
		minimal) ;;
		docker)  enable_docker=1 ;;
		ebpf)    enable_ebpf=1 ;;
		full)    enable_docker=1; enable_ebpf=1 ;;
		*)
			display_alert "${EXTENSION}" "未知 R3S_TRIM_MODE='${trim_mode}'，按 minimal 处理" "wrn"
			trim_mode="minimal"
			;;
	esac
	display_alert "${EXTENSION}" "Trim mode: ${trim_mode} (docker=${enable_docker}, ebpf=${enable_ebpf})" "info"

	# keep_set：本模式下必须保留、严禁被钩子关闭的符号（含依赖闭包）
	local -A keep_set=()
	if [[ $enable_docker -eq 1 ]]; then
		local k
		for k in \
			MULTIUSER NAMESPACES UTS_NS IPC_NS PID_NS NET_NS CGROUP_NS TIME_NS USER_NS \
			POSIX_MQUEUE POSIX_MQUEUE_SYSCTL \
			MEMCG MEMCG_KMEM CPUSETS PROC_PID_CPUSET \
			CGROUP_SCHED FAIR_GROUP_SCHED CFS_BANDWIDTH \
			CGROUP_PIDS CGROUP_DEVICE CGROUP_CPUACCT CGROUP_HUGETLB CGROUP_FREEZER FREEZER \
			CGROUP_NET_PRIO CGROUP_NET_CLASSID \
			BLK_CGROUP CGROUP_WRITEBACK BLK_CGROUP_IOLATENCY BLK_CGROUP_IOCOST BLK_CGROUP_IOPRIO \
			BLK_CGROUP_RWSTAT BLK_CGROUP_PUNT_BIO \
			BINFMT_MISC \
			BRIDGE BRIDGE_VLAN_FILTERING STP LLC \
			VETH MACVLAN IPVLAN IPVLAN_L3S NET_L3_MASTER_DEV \
			OVERLAY_FS FS_STACK; do
			keep_set[$k]=1
		done
	fi
	if [[ $enable_ebpf -eq 1 ]]; then
		local k
		for k in \
			NETFILTER_BPF_LINK BPF_SYSCALL BPF_JIT BPF_JIT_ALWAYS_ON BPF_EVENTS \
			CGROUP_BPF NET_CLS_BPF NET_ACT_BPF NET_SOCK_MSG \
			XDP_SOCKETS XDP_SOCKETS_DIAG \
			DEBUG_INFO DEBUG_INFO_DWARF5 DEBUG_INFO_BTF DEBUG_INFO_BTF_MODULES; do
			keep_set[$k]=1
		done
	fi

	# 判定某符号是否处于 keep_set（被保护）
	_r3s_kept() { [[ -n "${keep_set[$1]:-}" ]]; }

	# =========================================================================
	# 0. 从 opts_y 中删除不需要强制 =y 的项（opts_y 后处理，opts_n 无效！）
	# =========================================================================
	local -a remove_from_y=(
		# --- P0-1: BPF 链 ---
		"NETFILTER_BPF_LINK"           # 元凶：select BPF_SYSCALL
		"BPF_SYSCALL"                  # BPF 系统调用
		"CGROUP_BPF"                   # cgroup BPF

		# --- P0-3: AppArmor → AUDIT 链 ---
		"SECURITY_APPARMOR"            # AppArmor LSM（select AUDIT/SECURITYFS）

		# --- systemd 专属 cgroup（openrc 不需要）---
		"POSIX_MQUEUE"                 # systemd 消息队列
		"USER_NS"                      # 非特权用户命名空间（无容器需求）
		"BLK_CGROUP"                   # 块设备 cgroup（容器 IO 限制）
		"FAIR_GROUP_SCHED"             # CFS 调度组
		"RT_GROUP_SCHED"               # RT 调度组
		"CFS_BANDWIDTH"                # CFS 带宽控制
		"CGROUP_SCHED"                 # cgroup 调度框架
		"CGROUP_PIDS"                  # systemd TasksMax
		"CGROUP_FREEZER"               # systemd-cgroup freezer
		"CGROUP_DEVICE"                # 容器设备访问控制
		"CGROUP_CPUACCT"               # CPU 记账 cgroup
		"CGROUP_HUGETLB"               # 大页 cgroup
		"CGROUP_NET_CLASSID"           # 网络分类 ID
		"CGROUP_NET_PRIO"              # 网络优先级
		"CGROUP_PERF"                  # perf cgroup
		"CPUSETS"                      # cpuset cgroup
		"PROC_PID_CPUSET"              # /proc cpuset

		# --- 内核调试/信息泄露 ---
		"IKCONFIG"                     # /proc/config.gz
		"IKCONFIG_PROC"                # /proc/config.gz 接口

		# --- 实验性/不需要的网络框架 ---
		"NETKIT"                       # 实验性网络设备框架
		"NET_SCHED"                    # tc 框架（无 QoS 需求）
		"NET_L3_MASTER_DEV"            # L3 主设备

		# --- IPsec 框架（WireGuard 不用）---
		"XFRM"                         # IPsec 核心

		# --- 密钥环（无 TPM/容器需求）---
		"KEYS"                         # 内核密钥环
		"KEY_DH_OPERATIONS"            # DH 密钥操作
		"ENCRYPTED_KEYS"               # TPM 加密密钥
		"PERSISTENT_KEYRINGS"          # 持久化密钥环

		# --- ZSWAP 冗余（ZRAM 已够）---
		"ZSWAP"                        # ZSWAP（与 ZRAM 重叠）
		"ZSWAP_ZPOOL_DEFAULT_ZBUD"     # ZSWAP zbud 池

		# --- ZRAM 多余后端/特性（保留 LZ4 + LZ4HC + ZSTD）---
		"ZRAM_BACKEND_842"             # POWER 专用
		"ZRAM_BACKEND_LZO"             # LZ4 更快
		"ZRAM_BACKEND_DEFLATE"         # ZSTD 更好
		"ZRAM_WRITEBACK"               # 无 swap 后端盘
		"ZRAM_MEMORY_TRACKING"         # 调试用

		# --- IP_VS 负载均衡（路由器不需要）---
		"IP_VS_NFCT"
		"IP_VS_PROTO_TCP"
		"IP_VS_PROTO_UDP"

		# --- 文件系统安全扩展属性（无 SELinux/AppArmor）---
		"EXT4_FS_SECURITY"

		# --- 旧版 GPIO sysfs（gpiolib cdev v2 已替代）---
		"GPIO_SYSFS"

		# --- xtables 兼容层（纯 nftables 不需要）---
		"NETFILTER_XTABLES_LEGACY"
		"NETFILTER_XTABLES_COMPAT"

		# --- 调度器/块设备调优（microSD 不需要）---
		"BLK_DEV_THROTTLING"
		"CFQ_GROUP_IOSCHED"

		# --- 其他 ---
		"BRIDGE_VLAN_FILTERING"        # 桥接 VLAN 过滤
		"MEMCG_KMEM"                   # 内核内存 accounting

		# --- 孤儿 crypto（dm-crypt + IPsec 已全砍）---
		"CRYPTO_AUTHENC"               # IPsec AEAD，WireGuard 自包含
		"CRYPTO_ECB"                   # ECB 弱模式，无安全消费者
		"CRYPTO_CRYPTD"                # dm-crypt 工作队列

		# --- TEXTSEARCH（xt_string 已砍，无消费者）---
		"TEXTSEARCH"

		# --- v2.1 新增：内核框架瘦身 ---
		"BRIDGE"                       # 纯路由器不需桥接
		"BRIDGE_VLAN_FILTERING"        # 桥接 VLAN 过滤
		"MEMCG"                        # 内存 cgroup（无容器）
		"COMPACTION"                   # 内存压缩
		"KALLSYMS"                     # 内核符号表
		"PERF_EVENTS"                  # 性能计数器
		"ELFCORE"                      # core dump
		"DEBUG_KERNEL"                 # 调试框架门控
		"POWER_SUPPLY"                 # 电源框架
		"NETFILTER_FAMILY_BRIDGE"      # bridge netfilter
		"NETFILTER_FAMILY_ARP"         # ARP netfilter
		"NF_TABLES_ARP"                # ARP nftables
		"CPU_FREQ_GOV_ONDEMAND"        # ondemand governor
		"CPU_FREQ_DEFAULT_GOV_ONDEMAND"
		"CPU_IDLE_GOV_MENU"            # menu idle governor
		"CRYPTO_HW"                    # HW 加密框架
		"CRYPTO_SHA3"                  # SHA3（WireGuard 不用）
		"NET_SELFTESTS"                # 网络自测试
		"NET_RX_BUSY_POLL"             # busy poll
		"NET_FLOW_LIMIT"               # 流控
		"SOCK_RX_QUEUE_MAPPING"        # 多队列
		"LEDS_TRIGGER_CPU"             # CPU LED
		"LEDS_TRIGGER_ACTIVITY"        # 活动 LED
		"LEDS_TRIGGER_PANIC"           # Panic LED
		"GPIOLIB_LEGACY"               # GPIO legacy
		"SERIAL_8250_FSL"              # Freescale UART

		# --- v2.3 修复：Armbian 注入为 opts_y，需在 remove_from_y 过滤 ---
		"NF_CONNTRACK_LABELS"          # conntrack labels（opts_y 注入）
		"NF_CONNTRACK_ZONES"           # conntrack zones（opts_y 注入）
		"NF_CONNTRACK_EVENTS"          # conntrack events（opts_y 注入）
		"NF_TABLES_NETDEV"             # nftables netdev family（opts_y 注入）
		"ZRAM_BACKEND_LZ4HC"           # LZ4HC backend（opts_y 注入）
		"ZRAM_BACKEND_ZSTD"            # ZSTD backend（opts_y 注入）
		"EXT4_FS_POSIX_ACL"            # ext4 ACL（opts_y 注入）
	)

	# 过滤 opts_y
	local -a filtered_y=()
	local opt
	for opt in "${opts_y[@]}"; do
		# keep_set 项一律保留（docker/ebpf 模式需要）
		if _r3s_kept "$opt"; then
			filtered_y+=("$opt")
			continue
		fi
		local skip=0
		for rem in "${remove_from_y[@]}"; do
			[[ "$opt" == "$rem" ]] && { skip=1; break; }
		done
		[[ $skip -eq 0 ]] && filtered_y+=("$opt")
	done
	opts_y=("${filtered_y[@]}")

	# =========================================================================
	# 1. 从 opts_m 中删除不需要强制 =m 的项
	# =========================================================================
	local -a remove_from_m=(
		# --- P0-2: bridge netfilter → ebtables 链（root cause）---
		"BRIDGE_NETFILTER"             # 桥接 netfilter 框架
		"BRIDGE_NF_EBTABLES"           # ebtables nftables 桥接
		"BRIDGE_NF_EBTABLES_LEGACY"    # ebtables legacy
		# 所有 ebtables 子模块
		"BRIDGE_EBT_BROUTE" "BRIDGE_EBT_T_FILTER" "BRIDGE_EBT_T_NAT"
		"BRIDGE_EBT_802_3" "BRIDGE_EBT_AMONG" "BRIDGE_EBT_ARP"
		"BRIDGE_EBT_ARPREPLY" "BRIDGE_EBT_DNAT" "BRIDGE_EBT_IP"
		"BRIDGE_EBT_IP6" "BRIDGE_EBT_LIMIT" "BRIDGE_EBT_LOG"
		"BRIDGE_EBT_MARK" "BRIDGE_EBT_MARK_T" "BRIDGE_EBT_NFLOG"
		"BRIDGE_EBT_PKTTYPE" "BRIDGE_EBT_REDIRECT" "BRIDGE_EBT_SNAT"
		"BRIDGE_EBT_STP" "BRIDGE_EBT_VLAN"

		# --- xtables 全栈（纯 nftables 不需要）---
		"NETFILTER_XTABLES"
		"NETFILTER_XT_CONNMARK" "NETFILTER_XT_MARK"
		"NETFILTER_XT_MATCH_ADDRTYPE" "NETFILTER_XT_MATCH_BPF"
		"NETFILTER_XT_MATCH_CGROUP" "NETFILTER_XT_MATCH_CLUSTER"
		"NETFILTER_XT_MATCH_COMMENT" "NETFILTER_XT_MATCH_CONNBYTES"
		"NETFILTER_XT_MATCH_CONNLABEL" "NETFILTER_XT_MATCH_CONNLIMIT"
		"NETFILTER_XT_MATCH_CONNMARK" "NETFILTER_XT_MATCH_CONNTRACK"
		"NETFILTER_XT_MATCH_CPU" "NETFILTER_XT_MATCH_DCCP"
		"NETFILTER_XT_MATCH_DEVGROUP" "NETFILTER_XT_MATCH_DSCP"
		"NETFILTER_XT_MATCH_ECN" "NETFILTER_XT_MATCH_ESP"
		"NETFILTER_XT_MATCH_HASHLIMIT" "NETFILTER_XT_MATCH_HELPER"
		"NETFILTER_XT_MATCH_HL" "NETFILTER_XT_MATCH_IPCOMP"
		"NETFILTER_XT_MATCH_IPRANGE" "NETFILTER_XT_MATCH_IPVS"
		"NETFILTER_XT_MATCH_L2TP" "NETFILTER_XT_MATCH_LENGTH"
		"NETFILTER_XT_MATCH_LIMIT" "NETFILTER_XT_MATCH_MAC"
		"NETFILTER_XT_MATCH_MARK" "NETFILTER_XT_MATCH_MULTIPORT"
		"NETFILTER_XT_MATCH_NFACCT" "NETFILTER_XT_MATCH_OSF"
		"NETFILTER_XT_MATCH_OWNER" "NETFILTER_XT_MATCH_PHYSDEV"
		"NETFILTER_XT_MATCH_PKTTYPE" "NETFILTER_XT_MATCH_POLICY"
		"NETFILTER_XT_MATCH_QUOTA" "NETFILTER_XT_MATCH_RATEEST"
		"NETFILTER_XT_MATCH_REALM" "NETFILTER_XT_MATCH_RECENT"
		"NETFILTER_XT_MATCH_SCTP" "NETFILTER_XT_MATCH_SOCKET"
		"NETFILTER_XT_MATCH_STATE" "NETFILTER_XT_MATCH_STATISTIC"
		"NETFILTER_XT_MATCH_STRING" "NETFILTER_XT_MATCH_TCPMSS"
		"NETFILTER_XT_MATCH_TIME" "NETFILTER_XT_MATCH_U32"
		"NETFILTER_XT_NAT" "NETFILTER_XT_SET"
		"NETFILTER_XT_TARGET_AUDIT" "NETFILTER_XT_TARGET_CHECKSUM"
		"NETFILTER_XT_TARGET_CLASSIFY" "NETFILTER_XT_TARGET_CONNMARK"
		"NETFILTER_XT_TARGET_CONNSECMARK" "NETFILTER_XT_TARGET_CT"
		"NETFILTER_XT_TARGET_DSCP" "NETFILTER_XT_TARGET_FLOWOFFLOAD"
		"NETFILTER_XT_TARGET_HL" "NETFILTER_XT_TARGET_HMARK"
		"NETFILTER_XT_TARGET_IDLETIMER" "NETFILTER_XT_TARGET_LED"
		"NETFILTER_XT_TARGET_LOG" "NETFILTER_XT_TARGET_MARK"
		"NETFILTER_XT_TARGET_MASQUERADE" "NETFILTER_XT_TARGET_NETMAP"
		"NETFILTER_XT_TARGET_NFLOG" "NETFILTER_XT_TARGET_NFQUEUE"
		"NETFILTER_XT_TARGET_NOTRACK" "NETFILTER_XT_TARGET_RATEEST"
		"NETFILTER_XT_TARGET_REDIRECT" "NETFILTER_XT_TARGET_SECMARK"
		"NETFILTER_XT_TARGET_TCPMSS" "NETFILTER_XT_TARGET_TCPOPTSTRIP"
		"NETFILTER_XT_TARGET_TEE" "NETFILTER_XT_TARGET_TPROXY"
		"NETFILTER_XT_TARGET_TRACE"

		# --- ipset 全套（依赖 xtables）---
		"IP_SET" "IP_SET_BITMAP_IP" "IP_SET_BITMAP_PORT"
		"IP_SET_HASH_IP" "IP_SET_HASH_IPPORT" "IP_SET_HASH_IPPORTNET"
		"IP_SET_HASH_NET" "IP_SET_HASH_NETPORT"

		# --- iptables legacy (IPv4/IPv6) ---
		"IP_NF_FILTER" "IP_NF_IPTABLES" "IP_NF_MANGLE"
		"IP_NF_NAT" "IP_NF_RAW" "IP_NF_SECURITY"
		"IP_NF_TARGET_MASQUERADE" "IP_NF_TARGET_NETMAP"
		"IP_NF_TARGET_REDIRECT"
		"IP6_NF_FILTER" "IP6_NF_IPTABLES" "IP6_NF_MANGLE"
		"IP6_NF_MATCH_AH" "IP6_NF_MATCH_EUI64" "IP6_NF_MATCH_FRAG"
		"IP6_NF_MATCH_HL" "IP6_NF_MATCH_IPV6HEADER" "IP6_NF_MATCH_MH"
		"IP6_NF_MATCH_OPTS" "IP6_NF_MATCH_RPFILTER" "IP6_NF_MATCH_RT"
		"IP6_NF_MATCH_SRH" "IP6_NF_NAT" "IP6_NF_RAW" "IP6_NF_SECURITY"
		"IP6_NF_TARGET_HL" "IP6_NF_TARGET_MASQUERADE" "IP6_NF_TARGET_NPT"
		"IP6_NF_TARGET_REJECT" "IP6_NF_TARGET_SYNPROXY"

		# --- nftables compat（让 nftables 兼容 iptables 的桥接层）---
		"NFT_COMPAT" "NFT_COMPAT_ARP"

		# --- IP_VS（负载均衡）---
		"IP_VS" "IP_VS_RR"

		# --- 容器网络（无 Docker 需求）---
		"VETH" "MACVLAN" "IPVLAN" "VXLAN" "OVERLAY_FS"

		# --- 多余文件系统 ---
		"BTRFS_FS" "EROFS_FS"

		# --- IPsec (WireGuard 不用) ---
		"INET_ESP" "XFRM_ALGO" "XFRM_USER"

		# --- IPsec 加密组件 ---
		"CRYPTO_SEQIV" "CRYPTO_GHASH" "CRYPTO_GCM"

		# --- Windows NT 同步（Wine/Proton 用）---
		"NTSYNC"

		# --- 通用 IP 隧道框架 ---
		"NET_IP_TUNNEL"

		# --- Conntrack 冷门协议 helper ---
		"NF_CONNTRACK_IRC" "NF_CONNTRACK_PPTP" "NF_CONNTRACK_TFTP"
		"NF_CONNTRACK_FTP"  # FTP helper，主动模式几乎不用
		"NF_NAT_FTP" "NF_NAT_IRC" "NF_NAT_TFTP" "NF_NAT_PPTP"
		"NF_NAT_SIP"        # SIP NAT helper
		"NF_CONNTRACK_BRIDGE"  # bridge conntrack
		"NF_LOG_ARP"           # ARP 日志

		# --- nftables 多余模块 ---
		"NFT_OSF" "NFT_XFRM" "NFT_SYNPROXY" "NFT_TUNNEL" "NFT_NUMGEN"
		"NFT_CONNLIMIT" "NFT_QUEUE"     # connlimit + NFQUEUE
		"NFT_BRIDGE_META" "NFT_BRIDGE_REJECT"   # bridge nftables
		"NFT_FIB_NETDEV" "NFT_REJECT_NETDEV"    # netdev nftables

		# --- netfilter 调试/日志框架 ---
		"NETFILTER_NETLINK" "NETFILTER_NETLINK_ACCT"
		"NETFILTER_NETLINK_HOOK" "NETFILTER_NETLINK_LOG"
		"NETFILTER_NETLINK_OSF" "NETFILTER_NETLINK_QUEUE"
		"NETFILTER_SYNPROXY" "NETFILTER_CONNCOUNT"

		# --- tc 残留 ---
		"NET_ACT_IPT" "NET_EMATCH_IPT" "NET_CLS_CGROUP"

		# --- 无线（R3S 无 WiFi/BT）---
		"CFG80211" "MAC80211"

		# --- 旧 netfilter NAT ---
		"NF_NAT_IPV4" "NF_NAT_MASQUERADE_IPV4"
		"RESOURCE_COUNTERS"
		"NFT_COUNTER" "NFT_OBJREF"

		# --- v2.1 新增：nftables 冗余模块 + conntrack 瘦身 ---
		"NFT_DUP_NETDEV" "NFT_FWD_NETDEV" "NFT_QUOTA" "NFT_HASH"
		"NFT_SOCKET" "NFT_TPROXY"
		"NFT_FIB" "NFT_FIB_INET" "NFT_FIB_IPV4" "NFT_FIB_IPV6" "NFT_FIB_NETDEV"
		"NF_SOCKET_IPV4" "NF_TPROXY_IPV4" "NF_SOCKET_IPV6" "NF_TPROXY_IPV6"
		"NF_DUP_NETDEV" "NF_DUP_IPV4" "NF_DUP_IPV6" "NFT_DUP_IPV4" "NFT_DUP_IPV6"
		"NF_TABLES_BRIDGE"
		"NET_IP_TUNNEL" "NET_UDP_TUNNEL"
		"DUMMY"                        # v2.4: dummy 虚拟网卡（opts_m 注入）
	)

	# 过滤 opts_m
	local -a filtered_m=()
	for opt in "${opts_m[@]}"; do
		# keep_set 项一律保留（docker/ebpf 模式需要）
		if _r3s_kept "$opt"; then
			filtered_m+=("$opt")
			continue
		fi
		local skip=0
		for rem in "${remove_from_m[@]}"; do
			[[ "$opt" == "$rem" ]] && { skip=1; break; }
		done
		[[ $skip -eq 0 ]] && filtered_m+=("$opt")
	done
	opts_m=("${filtered_m[@]}")

	# =========================================================================
	# 2. 添加 opts_n 作为双重保险（belt + suspenders）
	# =========================================================================
	# --- P0-1: BPF 链 ---
	opts_n+=("NETFILTER_BPF_LINK")
	opts_n+=("BPF_SYSCALL")
	opts_n+=("BPF_JIT")
	opts_n+=("BPF_JIT_ALWAYS_ON")
	opts_n+=("BPF_JIT_DEFAULT_ON")
	opts_n+=("BPF_EVENTS")
	opts_n+=("BPF_KPROBE_OVERRIDE")
	opts_n+=("BPF_LSM")
	opts_n+=("BPF_STREAM_PARSER")
	opts_n+=("BPF_UNPRIV_DEFAULT_OFF")
	opts_n+=("CGROUP_BPF")

	# --- P0-3: AppArmor → AUDIT 链 ---
	opts_n+=("SECURITY_APPARMOR")

	# --- systemd 专属 cgroup ---
	opts_n+=("POSIX_MQUEUE")          # POSIX 消息队列
	opts_n+=("USER_NS")
	opts_n+=("BLK_CGROUP")
	opts_n+=("FAIR_GROUP_SCHED")
	opts_n+=("RT_GROUP_SCHED")
	opts_n+=("CFS_BANDWIDTH")
	opts_n+=("CGROUP_SCHED")
	opts_n+=("CGROUP_PIDS")
	opts_n+=("CGROUP_FREEZER")
	opts_n+=("CGROUP_DEVICE")
	opts_n+=("CGROUP_CPUACCT")
	opts_n+=("CGROUP_HUGETLB")
	opts_n+=("CGROUP_NET_CLASSID")
	opts_n+=("CGROUP_NET_PRIO")
	opts_n+=("CGROUP_PERF")
	opts_n+=("CGROUP_MISC")
	opts_n+=("CPUSETS")
	opts_n+=("PROC_PID_CPUSET")

	# --- 内核调试 ---
	opts_n+=("IKCONFIG")
	opts_n+=("IKCONFIG_PROC")

	# --- 网络 ---
	opts_n+=("NETKIT")
	opts_n+=("NET_SCHED")
	opts_n+=("NET_L3_MASTER_DEV")
	opts_n+=("XFRM")

	# --- 密钥环 ---
	opts_n+=("KEYS")
	opts_n+=("KEY_DH_OPERATIONS")
	opts_n+=("ENCRYPTED_KEYS")
	opts_n+=("PERSISTENT_KEYRINGS")

	# --- ZSWAP / ZRAM ---
	opts_n+=("ZSWAP")
	opts_n+=("ZSWAP_ZPOOL_DEFAULT_ZBUD")
	opts_n+=("ZRAM_WRITEBACK")
	opts_n+=("ZRAM_MEMORY_TRACKING")
	opts_n+=("ZRAM_BACKEND_842")
	opts_n+=("ZRAM_BACKEND_LZO")
	opts_n+=("ZRAM_BACKEND_DEFLATE")

	# --- 其他 ---
	opts_n+=("IP_VS_NFCT")
	opts_n+=("IP_VS_PROTO_TCP")
	opts_n+=("IP_VS_PROTO_UDP")
	opts_n+=("EXT4_FS_SECURITY")
	opts_n+=("GPIO_SYSFS")
	opts_n+=("NETFILTER_XTABLES_LEGACY")
	opts_n+=("NETFILTER_XTABLES_COMPAT")
	opts_n+=("BLK_DEV_THROTTLING")
	opts_n+=("CFQ_GROUP_IOSCHED")
	opts_n+=("BRIDGE_VLAN_FILTERING")
	opts_n+=("MEMCG_KMEM")

	# --- 调试 / BTF ---
	opts_n+=("DEBUG_INFO")
	opts_n+=("DEBUG_INFO_DWARF5")
	opts_n+=("DEBUG_INFO_BTF")
	opts_n+=("DEBUG_INFO_BTF_MODULES")
	opts_n+=("DEBUG_INFO_COMPRESSED_NONE")
	opts_n+=("DEBUG_INFO_REDUCED")
	opts_n+=("DEBUG_INFO_NONE")

	# --- Ftrace ---
	opts_n+=("FTRACE")
	opts_n+=("FTRACE_SYSCALLS")
	opts_n+=("FUNCTION_TRACER")
	opts_n+=("DYNAMIC_FTRACE")
	opts_n+=("DYNAMIC_FTRACE_WITH_ARGS")
	opts_n+=("DYNAMIC_FTRACE_WITH_CALL_OPS")
	opts_n+=("DYNAMIC_FTRACE_WITH_DIRECT_CALLS")
	opts_n+=("FTRACE_MCOUNT_USE_PATCHABLE_FUNCTION_ENTRY")
	opts_n+=("TRACEFS_AUTOMOUNT_DEPRECATED")

	# --- Kprobes ---
	opts_n+=("KPROBES")
	opts_n+=("KPROBE_EVENTS")
	opts_n+=("PROBE_EVENTS_BTF_ARGS")

	# --- 加密冗余 ---
	opts_n+=("INET_ESP")
	opts_n+=("CRYPTO_SEQIV")
	opts_n+=("CRYPTO_GHASH")

	# --- netfilter ---
	opts_n+=("NF_TABLES_ARP")
	opts_n+=("NF_NAT_IPV4")
	opts_n+=("NF_NAT_MASQUERADE_IPV4")

	# --- 抢占模型调整为 VOLUNTARY（路由器不需要低延迟）---
	opts_n+=("PREEMPT")
# --- 全量复活项 opt_n 双重保险 (295项) ---
opts_n+=("842_COMPRESS")
opts_n+=("842_DECOMPRESS")
opts_n+=("ARCH_ENABLE_MEMORY_HOTPLUG")
opts_n+=("ARM_AMBA")
opts_n+=("ASSOCIATIVE_ARRAY")
opts_n+=("AUDIT")
opts_n+=("AUDITSYSCALL")
opts_n+=("BCMA_POSSIBLE")
opts_n+=("BINARY_PRINTF")
opts_n+=("BLK_CGROUP")
opts_n+=("BLK_CGROUP_PUNT_BIO")
opts_n+=("BLK_CGROUP_RWSTAT")
opts_n+=("BLK_DEV_THROTTLING")
opts_n+=("BPF_SYSCALL")
opts_n+=("BRIDGE")
opts_n+=("BRIDGE_EBT_BROUTE")
opts_n+=("BRIDGE_EBT_T_FILTER")
opts_n+=("BRIDGE_EBT_T_NAT")
opts_n+=("BRIDGE_NETFILTER")
opts_n+=("BRIDGE_NF_EBTABLES")
opts_n+=("BRIDGE_NF_EBTABLES_LEGACY")
opts_n+=("BRIDGE_VLAN_FILTERING")
opts_n+=("BTRFS_FS")
opts_n+=("BTRFS_FS_POSIX_ACL")
opts_n+=("CFS_BANDWIDTH")
opts_n+=("CGROUP_BPF")
opts_n+=("CGROUP_CPUACCT")
opts_n+=("CGROUP_DEVICE")
opts_n+=("CGROUP_FREEZER")
opts_n+=("CGROUP_NET_CLASSID")
opts_n+=("CGROUP_NET_PRIO")
opts_n+=("CGROUP_PERF")
opts_n+=("CGROUP_PIDS")
opts_n+=("CGROUP_SCHED")
opts_n+=("CGROUP_WRITEBACK")
opts_n+=("CPU_FREQ_GOV_ONDEMAND")
opts_n+=("CPU_FREQ_GOV_PERFORMANCE")
opts_n+=("CPUSETS")
opts_n+=("CRYPTO_AEAD")
opts_n+=("CRYPTO_AKCIPHER2")
opts_n+=("CRYPTO_AUTHENC")
opts_n+=("CRYPTO_BLAKE2B")
opts_n+=("CRYPTO_CBC")
opts_n+=("CRYPTO_CRC32C")
opts_n+=("CRYPTO_CTR")
opts_n+=("CRYPTO_DEFLATE")
opts_n+=("CRYPTO_DH")
opts_n+=("CRYPTO_ECB")
opts_n+=("CRYPTO_ECHAINIV")
opts_n+=("CRYPTO_GCM")
opts_n+=("CRYPTO_GENIV")
opts_n+=("CRYPTO_GHASH")
opts_n+=("CRYPTO_KDF800108_CTR")
opts_n+=("CRYPTO_LIB_GF128MUL")
opts_n+=("CRYPTO_LIB_POLY1305")
opts_n+=("CRYPTO_RNG_DEFAULT")
opts_n+=("CRYPTO_SEQIV")
opts_n+=("CRYPTO_SHA3")
opts_n+=("CRYPTO_XXHASH")
opts_n+=("DEBUG_INFO_NONE")
opts_n+=("DEBUG_KERNEL")
opts_n+=("DUMMY")
opts_n+=("EDAC_SUPPORT")
opts_n+=("ELFCORE")
opts_n+=("ENCRYPTED_KEYS")
opts_n+=("EROFS_FS")
opts_n+=("EXPORTFS")
opts_n+=("EXT4_FS_POSIX_ACL")
opts_n+=("EXT4_FS_SECURITY")
opts_n+=("FAIR_GROUP_SCHED")
opts_n+=("FS_POSIX_ACL")
opts_n+=("FS_STACK")
opts_n+=("GPIOLIB_LEGACY")
opts_n+=("GPIO_SYSFS")
opts_n+=("IKCONFIG")
opts_n+=("IKCONFIG_PROC")
opts_n+=("INET_ESP")
opts_n+=("INIT_STACK_NONE")
opts_n+=("IP6_NF_IPTABLES")
opts_n+=("IP6_NF_MATCH_AH")
opts_n+=("IP6_NF_MATCH_EUI64")
opts_n+=("IP6_NF_MATCH_FRAG")
opts_n+=("IP6_NF_MATCH_HL")
opts_n+=("IP6_NF_MATCH_IPV6HEADER")
opts_n+=("IP6_NF_MATCH_MH")
opts_n+=("IP6_NF_MATCH_OPTS")
opts_n+=("IP6_NF_MATCH_RPFILTER")
opts_n+=("IP6_NF_MATCH_RT")
opts_n+=("IP6_NF_MATCH_SRH")
opts_n+=("IP6_NF_TARGET_NPT")
opts_n+=("IP6_NF_TARGET_REJECT")
opts_n+=("IP6_NF_TARGET_SYNPROXY")
opts_n+=("IP_NF_IPTABLES")
opts_n+=("IP_ROUTE_CLASSID")
opts_n+=("IP_SET")
opts_n+=("IP_SET_BITMAP_IP")
opts_n+=("IP_SET_BITMAP_PORT")
opts_n+=("IP_SET_HASH_IP")
opts_n+=("IP_SET_HASH_IPPORT")
opts_n+=("IP_SET_HASH_IPPORTNET")
opts_n+=("IP_SET_HASH_NET")
opts_n+=("IP_SET_HASH_NETPORT")
opts_n+=("IPVLAN")
opts_n+=("IPVLAN_L3S")
opts_n+=("IP_VS")
opts_n+=("IP_VS_NFCT")
opts_n+=("IP_VS_PROTO_TCP")
opts_n+=("IP_VS_PROTO_UDP")
opts_n+=("IP_VS_RR")
opts_n+=("KEY_DH_OPERATIONS")
opts_n+=("KEYS")
opts_n+=("LLC")
opts_n+=("LZ4_COMPRESS")
opts_n+=("LZ4HC_COMPRESS")
opts_n+=("LZO_COMPRESS")
opts_n+=("LZO_DECOMPRESS")
opts_n+=("MACVLAN")
opts_n+=("MPILIB")
opts_n+=("NET_CLS")
opts_n+=("NET_CLS_CGROUP")
opts_n+=("NETFILTER_BPF_LINK")
opts_n+=("NETFILTER_CONNCOUNT")
opts_n+=("NETFILTER_FAMILY_ARP")
opts_n+=("NETFILTER_FAMILY_BRIDGE")
opts_n+=("NETFILTER_NETLINK_ACCT")
opts_n+=("NETFILTER_NETLINK_HOOK")
opts_n+=("NETFILTER_NETLINK_LOG")
opts_n+=("NETFILTER_NETLINK_OSF")
opts_n+=("NETFILTER_NETLINK_QUEUE")
opts_n+=("NETFILTER_SYNPROXY")
opts_n+=("NETFILTER_XTABLES")
opts_n+=("NETFILTER_XTABLES_LEGACY")
opts_n+=("NETFILTER_XT_CONNMARK")
opts_n+=("NETFILTER_XT_MARK")
opts_n+=("NETFILTER_XT_MATCH_ADDRTYPE")
opts_n+=("NETFILTER_XT_MATCH_BPF")
opts_n+=("NETFILTER_XT_MATCH_CGROUP")
opts_n+=("NETFILTER_XT_MATCH_CLUSTER")
opts_n+=("NETFILTER_XT_MATCH_COMMENT")
opts_n+=("NETFILTER_XT_MATCH_CONNBYTES")
opts_n+=("NETFILTER_XT_MATCH_CONNLABEL")
opts_n+=("NETFILTER_XT_MATCH_CONNLIMIT")
opts_n+=("NETFILTER_XT_MATCH_CONNMARK")
opts_n+=("NETFILTER_XT_MATCH_CONNTRACK")
opts_n+=("NETFILTER_XT_MATCH_CPU")
opts_n+=("NETFILTER_XT_MATCH_DCCP")
opts_n+=("NETFILTER_XT_MATCH_DEVGROUP")
opts_n+=("NETFILTER_XT_MATCH_DSCP")
opts_n+=("NETFILTER_XT_MATCH_ECN")
opts_n+=("NETFILTER_XT_MATCH_ESP")
opts_n+=("NETFILTER_XT_MATCH_HASHLIMIT")
opts_n+=("NETFILTER_XT_MATCH_HELPER")
opts_n+=("NETFILTER_XT_MATCH_HL")
opts_n+=("NETFILTER_XT_MATCH_IPCOMP")
opts_n+=("NETFILTER_XT_MATCH_IPRANGE")
opts_n+=("NETFILTER_XT_MATCH_IPVS")
opts_n+=("NETFILTER_XT_MATCH_L2TP")
opts_n+=("NETFILTER_XT_MATCH_LENGTH")
opts_n+=("NETFILTER_XT_MATCH_LIMIT")
opts_n+=("NETFILTER_XT_MATCH_MAC")
opts_n+=("NETFILTER_XT_MATCH_MARK")
opts_n+=("NETFILTER_XT_MATCH_MULTIPORT")
opts_n+=("NETFILTER_XT_MATCH_NFACCT")
opts_n+=("NETFILTER_XT_MATCH_OSF")
opts_n+=("NETFILTER_XT_MATCH_OWNER")
opts_n+=("NETFILTER_XT_MATCH_PHYSDEV")
opts_n+=("NETFILTER_XT_MATCH_PKTTYPE")
opts_n+=("NETFILTER_XT_MATCH_POLICY")
opts_n+=("NETFILTER_XT_MATCH_QUOTA")
opts_n+=("NETFILTER_XT_MATCH_RATEEST")
opts_n+=("NETFILTER_XT_MATCH_REALM")
opts_n+=("NETFILTER_XT_MATCH_RECENT")
opts_n+=("NETFILTER_XT_MATCH_SCTP")
opts_n+=("NETFILTER_XT_MATCH_SOCKET")
opts_n+=("NETFILTER_XT_MATCH_STATE")
opts_n+=("NETFILTER_XT_MATCH_STATISTIC")
opts_n+=("NETFILTER_XT_MATCH_STRING")
opts_n+=("NETFILTER_XT_MATCH_TCPMSS")
opts_n+=("NETFILTER_XT_MATCH_TIME")
opts_n+=("NETFILTER_XT_MATCH_U32")
opts_n+=("NETFILTER_XT_NAT")
opts_n+=("NETFILTER_XT_SET")
opts_n+=("NETFILTER_XT_TARGET_AUDIT")
opts_n+=("NETFILTER_XT_TARGET_CHECKSUM")
opts_n+=("NETFILTER_XT_TARGET_CLASSIFY")
opts_n+=("NETFILTER_XT_TARGET_CONNMARK")
opts_n+=("NETFILTER_XT_TARGET_CT")
opts_n+=("NETFILTER_XT_TARGET_DSCP")
opts_n+=("NETFILTER_XT_TARGET_HL")
opts_n+=("NETFILTER_XT_TARGET_HMARK")
opts_n+=("NETFILTER_XT_TARGET_IDLETIMER")
opts_n+=("NETFILTER_XT_TARGET_LED")
opts_n+=("NETFILTER_XT_TARGET_LOG")
opts_n+=("NETFILTER_XT_TARGET_MARK")
opts_n+=("NETFILTER_XT_TARGET_MASQUERADE")
opts_n+=("NETFILTER_XT_TARGET_NETMAP")
opts_n+=("NETFILTER_XT_TARGET_NFLOG")
opts_n+=("NETFILTER_XT_TARGET_NFQUEUE")
opts_n+=("NETFILTER_XT_TARGET_RATEEST")
opts_n+=("NETFILTER_XT_TARGET_REDIRECT")
opts_n+=("NETFILTER_XT_TARGET_TCPMSS")
opts_n+=("NETFILTER_XT_TARGET_TCPOPTSTRIP")
opts_n+=("NETFILTER_XT_TARGET_TEE")
opts_n+=("NETFILTER_XT_TARGET_TPROXY")
opts_n+=("NET_IP_TUNNEL")
opts_n+=("NETKIT")
opts_n+=("NET_L3_MASTER_DEV")
opts_n+=("NET_RX_BUSY_POLL")
opts_n+=("NET_SCHED")
opts_n+=("NET_SCH_FIFO")
opts_n+=("NET_SELFTESTS")
opts_n+=("NET_SOCK_MSG")
opts_n+=("NET_UDP_TUNNEL")
opts_n+=("NF_CONNTRACK_FTP")
opts_n+=("NF_CONNTRACK_IRC")
opts_n+=("NF_CONNTRACK_PPTP")
opts_n+=("NF_CONNTRACK_TFTP")
opts_n+=("NF_CT_PROTO_GRE")
opts_n+=("NF_DUP_IPV4")
opts_n+=("NF_DUP_IPV6")
opts_n+=("NF_DUP_NETDEV")
opts_n+=("NF_NAT_FTP")
opts_n+=("NF_NAT_IRC")
opts_n+=("NF_NAT_PPTP")
opts_n+=("NF_NAT_TFTP")
opts_n+=("NF_TABLES_ARP")
opts_n+=("NF_TABLES_BRIDGE")
opts_n+=("NF_TABLES_NETDEV")
opts_n+=("NFT_BRIDGE_META")
opts_n+=("NFT_BRIDGE_REJECT")
opts_n+=("NFT_COMPAT")
opts_n+=("NFT_COMPAT_ARP")
opts_n+=("NFT_CONNLIMIT")
opts_n+=("NFT_DUP_IPV4")
opts_n+=("NFT_DUP_IPV6")
opts_n+=("NFT_DUP_NETDEV")
opts_n+=("NFT_FIB_NETDEV")
opts_n+=("NFT_FWD_NETDEV")
opts_n+=("NFT_NUMGEN")
opts_n+=("NFT_OSF")
opts_n+=("NFT_QUEUE")
opts_n+=("NFT_REJECT_NETDEV")
opts_n+=("NFT_SYNPROXY")
opts_n+=("NFT_TUNNEL")
opts_n+=("NFT_XFRM")
opts_n+=("NTSYNC")
opts_n+=("OVERLAY_FS")
opts_n+=("PCI_SYSCALL")
opts_n+=("PCS_XPCS")
opts_n+=("PERSISTENT_KEYRINGS")
opts_n+=("PHYLIB_LEDS")
opts_n+=("POSIX_MQUEUE")
opts_n+=("POSIX_MQUEUE_SYSCTL")
opts_n+=("RAID6_PQ")
opts_n+=("RT_GROUP_SCHED")
opts_n+=("SCHED_HRTICK")
opts_n+=("SCHED_HW_PRESSURE")
opts_n+=("SCSI_MOD")
opts_n+=("SECURITY_APPARMOR")
opts_n+=("SECURITYFS")
opts_n+=("SECURITY_NETWORK")
opts_n+=("SECURITY_PATH")
opts_n+=("SERIAL_8250_FSL")
opts_n+=("SERIAL_MCTRL_GPIO")
opts_n+=("SLHC")
opts_n+=("SSB_POSSIBLE")
opts_n+=("STP")
opts_n+=("TEXTSEARCH")
opts_n+=("TEXTSEARCH_BM")
opts_n+=("TEXTSEARCH_FSM")
opts_n+=("TEXTSEARCH_KMP")
opts_n+=("TRACING_SUPPORT")
opts_n+=("USB_OHCI_LITTLE_ENDIAN")
opts_n+=("USER_NS")
opts_n+=("VETH")
opts_n+=("VXLAN")
opts_n+=("XFRM")
opts_n+=("XFRM_ALGO")
opts_n+=("XFRM_ESP")
opts_n+=("XFRM_USER")
opts_n+=("XOR_BLOCKS")
opts_n+=("XXHASH")
opts_n+=("XZ_DEC_BCJ")
opts_n+=("ZRAM_BACKEND_842")
opts_n+=("ZRAM_BACKEND_DEFLATE")
opts_n+=("ZRAM_BACKEND_LZ4HC")
opts_n+=("ZRAM_BACKEND_LZO")
opts_n+=("ZRAM_BACKEND_ZSTD")
opts_n+=("ZRAM_DEF_COMP_LZORLE")
opts_n+=("ZRAM_WRITEBACK")
opts_n+=("ZSTD_COMMON")
opts_n+=("ZSTD_COMPRESS")
opts_n+=("ZSTD_DECOMPRESS")
opts_n+=("ZSWAP")
opts_n+=("ZSWAP_COMPRESSOR_DEFAULT_DEFLATE")

# --- v2.1 新增 ---
opts_n+=("BRIDGE")
opts_n+=("BRIDGE_VLAN_FILTERING")
opts_n+=("COMPACTION")
opts_n+=("CPU_FREQ_DEFAULT_GOV_ONDEMAND")
opts_n+=("CPU_FREQ_GOV_ONDEMAND")
opts_n+=("CPU_IDLE_GOV_MENU")
opts_n+=("CRYPTO_HW")
opts_n+=("CRYPTO_SHA3")
opts_n+=("DEBUG_KERNEL")
opts_n+=("ELFCORE")
opts_n+=("GPIOLIB_LEGACY")
opts_n+=("KALLSYMS")
opts_n+=("LEDS_TRIGGER_ACTIVITY")
opts_n+=("LEDS_TRIGGER_CPU")
opts_n+=("LEDS_TRIGGER_PANIC")
opts_n+=("MEMCG")
opts_n+=("NET_FLOW_LIMIT")
opts_n+=("NET_IP_TUNNEL")
opts_n+=("NET_RX_BUSY_POLL")
opts_n+=("NET_SELFTESTS")
opts_n+=("NET_UDP_TUNNEL")
opts_n+=("NETFILTER_FAMILY_ARP")
opts_n+=("NETFILTER_FAMILY_BRIDGE")
opts_n+=("NF_CONNTRACK_EVENTS")
opts_n+=("NF_CONNTRACK_LABELS")
opts_n+=("NF_CONNTRACK_ZONES")
opts_n+=("NF_DUP_IPV4")
opts_n+=("NF_DUP_IPV6")
opts_n+=("NF_DUP_NETDEV")
opts_n+=("NF_SOCKET_IPV4")
opts_n+=("NF_SOCKET_IPV6")
opts_n+=("NF_TABLES_ARP")
opts_n+=("NF_TABLES_BRIDGE")
opts_n+=("NF_TPROXY_IPV4")
opts_n+=("NF_TPROXY_IPV6")
opts_n+=("NFT_DUP_IPV4")
opts_n+=("NFT_DUP_IPV6")
opts_n+=("NFT_DUP_NETDEV")
opts_n+=("NFT_FIB")
opts_n+=("NFT_FIB_INET")
opts_n+=("NFT_FIB_IPV4")
opts_n+=("NFT_FIB_IPV6")
opts_n+=("NFT_FIB_NETDEV")
opts_n+=("NFT_FWD_NETDEV")
opts_n+=("NFT_HASH")
opts_n+=("NFT_QUOTA")
opts_n+=("NFT_SOCKET")
opts_n+=("NFT_TPROXY")
opts_n+=("PERF_EVENTS")
opts_n+=("POWER_SUPPLY")
opts_n+=("SERIAL_8250_FSL")
opts_n+=("SOCK_RX_QUEUE_MAPPING")
# --- v2.1 Y.4 新增 ---
opts_n+=("AF_UNIX_OOB")
opts_n+=("ANON_VMA_NAME")
opts_n+=("ARM_PMU")
opts_n+=("ARM_PMUV3")
opts_n+=("CONTIG_ALLOC")
opts_n+=("MIGRATION")
opts_n+=("RPS")
opts_n+=("SYSCTL_EXCEPTION_TRACE")
opts_n+=("XPS")
# --- v2.2 Y.5 新增 ---
opts_n+=("CRYPTO_JITTERENTROPY")  # select SHA3，不关它 SHA3 关不掉
opts_n+=("HW_PERF_EVENTS")        # ARM_PMU 已关，perf 硬件计数器残留
opts_n+=("INITRAMFS_PRESERVE_MTIME")
opts_n+=("LED_TRIGGER_PHY")        # R3S 用 r8169/stmmac 驱动内置 trigger
opts_n+=("VM_EVENT_COUNTERS")      # /proc/vmstat
opts_n+=("CRYPTO_CHACHA20")         # 孤儿，WireGuard用LIB版本
opts_n+=("FREEZER")                 # suspend freezer，PM_SLEEP/CGROUP_FREEZER均n
opts_n+=("LZO_DECOMPRESS")          # 孤儿，所有压缩消费者已禁
opts_n+=("ZLIB_DEFLATE")            # 孤儿，所有压缩消费者已禁
# --- v2.4 Y.7 新增 ---
opts_n+=("DECOMPRESS_ZSTD")         # 孤儿，ZRAM ZSTD 后端已禁
opts_n+=("DUMMY")                   # 测试虚拟网卡（opts_m 注入）
opts_n+=("PCI_SYSCALL")             # ARM64 已废弃
opts_n+=("PRINTK_TIME")             # dmesg 时间戳
opts_n+=("SCSI_MOD")                # SCSI=n 时 default y 怪圈
opts_n+=("TRACING_SUPPORT")         # default y，追踪框架已全砍
# --- v2.5 Y.8 新增 ---
opts_n+=("DW_WATCHDOG")              # Synopsys watchdog，R3S DTS 未用
opts_n+=("GPIOLIB_LEGACY")           # def_bool y，老旧GPIO接口
opts_n+=("GPIO_CDEV_V1")             # default y，deprecated ABI
opts_n+=("RTC_I2C_AND_SPI")          # default y if I2C=y，RK808不依赖
opts_n+=("RTC_NVMEM")                # default RTC_CLASS，无电池无消费者
opts_n+=("CPU_FREQ_DEFAULT_GOV_PERFORMANCE")  # 强制选择，应改为 schedutil
opts_n+=("DEBUG_BUGVERBOSE")          # 详细BUG输出，生产不需要
opts_n+=("TMPFS_POSIX_ACL")           # tmpfs ACL，禁后 FS_POSIX_ACL 级联消失
opts_n+=("LRU_GEN")                   # 多代LRU，2GB路由标准LRU足够
opts_n+=("PER_VMA_LOCK")              # def_bool y，单用户路由不需要
opts_n+=("PWM_ROCKCHIP")              # R3S DTS 无PWM消费者
opts_n+=("PWM_ROCKCHIP_V4")           # 同上
opts_n+=("INIT_STACK_ALL_PATTERN")    # 最强栈初始化，切换 NONE/ZERO
opts_n+=("NET_IP_TUNNEL")             # 孤儿模块，IPIP/GRE/VTI全禁
opts_n+=("RANDOMIZE_BASE")            # KASLR，路由器无本地用户不需
opts_n+=("RELOCATABLE")               # RANDOMIZE_BASE stop 后的级联
opts_n+=("VDSO_GETRANDOM")            # 纯性能，禁后走syscall
opts_n+=("MULTIUSER")                 # OpenRC单用户不需
	opts_y+=("PREEMPT_VOLUNTARY")

	# 从 opts_n 中剔除 keep_set 成员（docker/ebpf 模式需要这些项，不能进 opts_n）
	if [[ ${#keep_set[@]} -gt 0 ]]; then
		local -a filtered_n=()
		for opt in "${opts_n[@]}"; do
			_r3s_kept "$opt" && continue
			filtered_n+=("$opt")
		done
		opts_n=("${filtered_n[@]}")
	fi


		# =========================================================================
		# 3. 直接修改 .config（绕过 opts数组, 对抗 olddefconfig default y/select）
		# =========================================================================
		if [[ -f .config ]]; then
			display_alert "${EXTENSION}" "Directly disabling items in .config" "info"
			# 合并 remove_from_y + remove_from_m + opts_n 全集
			local -a all_disable=()
			all_disable+=("${remove_from_y[@]}")
			all_disable+=("${remove_from_m[@]}")
			all_disable+=("${opts_n[@]}")
			# 去重 + 跳过 keep_set（docker/ebpf 保护项，严禁直写 disable）
			local -A seen=()
			local -a unique_disable=()
			for item in "${all_disable[@]}"; do
				[[ -n "${seen[$item]}" ]] && continue
				_r3s_kept "$item" && continue
				seen[$item]=1
				unique_disable+=("$item")
			done
			# 直接用 sed 写入 # CONFIG_X is not set
			for item in "${unique_disable[@]}"; do
				sed -i "/^CONFIG_${item}=/d; /^# CONFIG_${item} is not set/d" .config
				echo "# CONFIG_${item} is not set" >> .config
			done

			# =========================================================================
			# 4. 强制路由器核心模块为 =y（对抗 Armbian/olddefconfig 降级为 =m）
			# =========================================================================
			display_alert "${EXTENSION}" "Forcing router core modules to =y" "info"
			local -a force_y=(
				# netfilter/NAT 核心
				NETFILTER NF_CONNTRACK NF_NAT
				NF_DEFRAG_IPV4 NF_DEFRAG_IPV6
				# nftables 框架
				NF_TABLES NF_TABLES_INET NF_TABLES_IPV4 NF_TABLES_IPV6
				# nftables 功能
				NFT_CT NFT_NAT NFT_MASQ NFT_REDIR
				NFT_REJECT NFT_REJECT_INET NFT_REJECT_IPV4 NFT_REJECT_IPV6
				NFT_LOG NFT_LIMIT
				# flow offload
				NFT_FLOW_OFFLOAD NF_FLOW_TABLE NF_FLOW_TABLE_INET
				# IP层
				NF_REJECT_IPV4 NF_REJECT_IPV6
				NF_LOG_IPV4 NF_LOG_IPV6 NF_LOG_SYSLOG
				# VPN/网络工具
				TUN WIREGUARD PPP PPPOE VLAN_8021Q IPV6
			)
			for item in "${force_y[@]}"; do
				sed -i "/^CONFIG_${item}=/d; /^# CONFIG_${item} is not set/d" .config
				echo "CONFIG_${item}=y" >> .config
			done
		fi
	kernel_config_modifying_hashes+=("nanopir3s_undo_armbian_ebpf")
	return 0
}
