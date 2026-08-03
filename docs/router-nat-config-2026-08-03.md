# 核心框架 - 编译进内核
CONFIG_NETFILTER=y
CONFIG_NF_TABLES=y
CONFIG_NF_CONNTRACK=y
CONFIG_NF_NAT=y

# nftables NAT组件 - 编译进内核
CONFIG_NFT_NAT=y
CONFIG_NFT_MASQ=y
CONFIG_NFT_REDIR=y

# 协议栈支持 - 编译进内核
CONFIG_NF_TABLES_IPV4=y
CONFIG_NF_TABLES_IPV6=y
CONFIG_NF_TABLES_INET=y

# IP转发功能 - 运行时仍需开启
# 注意：即使编译进内核，也需要通过 sysctl 在运行时开启
CONFIG_SYSCTL=y  # 确保 sysctl 可用


# 内核加上启动参数直接允许ip_forward功能开启
最后再强调一下：即使你将 net.ipv4.ip_forward 相关的所有代码都编译进内核，它默认仍然是关闭的。你必须在系统启动脚本中（如 /etc/sysctl.conf 文件）通过 net.ipv4.ip_forward=1 明确开启，或者在内核启动参数中加入 ip_forward=1，这个转发开关才会真正生效。这是由Linux内核的网络协议栈设计决定的，编译无法改变这个行为
