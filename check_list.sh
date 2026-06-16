echo "===== 反向验证：脚本声称砍掉的项是否真的没了 ====="
declare -a items=(
    # A 档：xtables
    "NETFILTER_XTABLES" "NETFILTER_XTABLES_LEGACY"
    # B 档：网络调度
    "NET_SCHED" "NET_CLS" "NET_CLS_ACT" "NET_SCH_HTB" "NET_SCH_CAKE"
    # C 档：容器
    "OVERLAY_FS" "VETH" "MACVLAN" "IPVLAN"
    # D 档：squashfs
    "SQUASHFS" "SQUASHFS_XZ" "SQUASHFS_ZLIB"
    # E 档：EFI/SMMU/COMPAT
    "EFI" "EFI_STUB" "ARM_SMMU" "ARM_SMMU_V3" "COMPAT"
    # F 档：Rockchip 加密
    "CRYPTO_DEV_ROCKCHIP" "CRYPTO_DEV_ROCKCHIP2"
    # G 档：隧道
    "IPV6_TUNNEL" "IP_GRE" "NET_IPIP" "MPLS_ROUTING"
    # H 档：conntrack helper
    "NF_CONNTRACK_H323" "NF_CONNTRACK_SIP" "NF_CONNTRACK_PPTP"
    # K 档（新增）：BPF
    "BPF" "BPF_SYSCALL" "CGROUP_BPF" "NETFILTER_BPF_LINK"
)

for item in "${items[@]}"; do
    line=$(grep -E "^CONFIG_${item}=" config-6.18.35-current-rockchip64 2>/dev/null)
    if [[ -n "$line" ]]; then
        echo "❌ STILL ENABLED: $line"
    else
        # 检查是否为 is not set
        if grep -qE "^# CONFIG_${item} is not set" config-6.18.35-current-rockchip64; then
            : # echo "✅ $item: not set"
        else
            echo "⚠️  $item: 既不是 =y/=m，也不是 is not set（可能依赖未满足而隐藏）"
        fi
    fi
done

echo ""
echo "完成。只输出异常项（still enabled 或未出现的）。"
