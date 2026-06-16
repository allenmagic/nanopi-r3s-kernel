cd /path/to/r3s-kernel-trim

echo "===== 1. 关键大类是否启用？ ====="
grep -E "^CONFIG_(NF_TABLES|NF_CONNTRACK|NETFILTER|IP_NF_|IP6_NF_|NETFILTER_XT|IP_SET|EBTABLES|BRIDGE_NF)" linux-rockchip64-current.config.baseline | head -60

echo ""
echo "===== 2. NET_SCHED / NET_CLS 现状 ====="
grep -E "^CONFIG_NET_(SCH|CLS|ACT|EMATCH)" linux-rockchip64-current.config.baseline

echo ""
echo "===== 3. 容器栈现状 ====="
grep -E "^CONFIG_(OVERLAY_FS|VETH|MACVLAN|IPVLAN|VXLAN|GENEVE|BRIDGE|MEMCG|BLK_CGROUP|CGROUP|NAMESPACES|.*_NS|POSIX_MQUEUE|USERFAULTFD)=" linux-rockchip64-current.config.baseline

echo ""
echo "===== 4. ZRAM/SWAP 现状 ====="
grep -E "^CONFIG_(SWAP|ZRAM|ZSMALLOC)" linux-rockchip64-current.config.baseline

echo ""
echo "===== 5. NFS/CIFS/SQUASHFS 现状 ====="
grep -E "^CONFIG_(NFS|CIFS|SMB|SQUASHFS)" linux-rockchip64-current.config.baseline

echo ""
echo "===== 6. EFI / SMMU / COMPAT 现状 ====="
grep -E "^CONFIG_(EFI|ARM_SMMU|COMPAT)" linux-rockchip64-current.config.baseline

echo ""
echo "===== 7. Rockchip 加密引擎 ====="
grep -E "^CONFIG_CRYPTO_DEV_ROCKCHIP" linux-rockchip64-current.config.baseline

echo ""
echo "===== 8. PPP / WireGuard / TUN ====="
grep -E "^CONFIG_(PPP|WIREGUARD|TUN)" linux-rockchip64-current.config.baseline

echo ""
echo "===== 9. IPv6 / SCTP / DCCP / RDS 等冷门协议 ====="
grep -E "^CONFIG_(IPV6|SCTP|DCCP|RDS|TIPC|ATM|X25|LAPB|6LOWPAN|IEEE802154|IPV6_TUNNEL|IPV6_GRE)" linux-rockchip64-current.config.baseline

echo ""
echo "===== 10. HID / INPUT ====="
grep -E "^CONFIG_(HID|INPUT)" linux-rockchip64-current.config.baseline | head -20

echo ""
echo "===== 11. CRYPTO ARM64 加速 ====="
grep -E "^CONFIG_CRYPTO_(AES|GHASH|CHACHA|POLY1305|CURVE25519|SHA).*ARM64" linux-rockchip64-current.config.baseline
