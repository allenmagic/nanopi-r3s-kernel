# 2026-06-11 裁剪会话总结

## 会话成果

### 裁剪轮次（v2.0 → v2.10）

| 版本 | 内容 | 影响 |
|---|---|---|
| v2.0 | 基线（A-Z 26节） | 1251 script |
| v2.1 | Y.2-Y.4: nftables冗余/内核框架/安全残余 ~50项 | 868 |
| v2.2 | Y.5: LED/PERF/VM/JITTER ~6项 | 863 |
| v2.3 | Y.6: 孤儿压缩/CHACHA20/FREEZER ~4项 | 859 |
| v2.4 | Y.7: TRACING/SCSI_MOD/DUMMY ~6项 | 858 |
| v2.5 | Y.8: DW_WATCHDOG/GPIOLIB_LEGACY/GPIO_CDEV_V1等 ~5项 | 854 |
| v2.6 | DEBUG_BUGVERBOSE + CPU_FREQ governor修正 | 854 |
| v2.7 | TMPFS_POSIX_ACL → 级联清除 FS_POSIX_ACL | 854 |
| v2.8 | LRU_GEN x3 + PWM_ROCKCHIP x2 + PER_VMA_LOCK | 848 |
| v2.9 | INIT_STACK/KASLR/NET_IP_TUNNEL/VDSO | 845 |
| v2.10 | MULTIUSER/EFI_PARTITION/IP_MULTICAST | **842** |

### 扩展钩子修复（6 commits）

- fix: NF_CONNTRACK_LABELS/ZONES/EVENTS 从 remove_from_m → remove_from_y
- fix: NF_TABLES_NETDEV 添加 remove_from_y
- fix: ZRAM_BACKEND_LZ4HC/ZSTD 从 opts_n-only → remove_from_y
- fix: EXT4_FS_POSIX_ACL 添加 remove_from_y
- feat: LEDS_TRIGGER_NETDEV 启用
- fix: DUMMY 添加 remove_from_m

### 最终数据

| 指标 | 编译实测 |
|---|---|
| y+m | 879 (806=y + 73=m) |
| vmlinuz | 9.0 MiB |
| modules | 2.0 MiB (68个) |
| deb | 42 MB |

## 关键技术发现

### select 链裁剪策略
1. **类型一 select X**: 追溯根符号 → 判断根可裁 → 禁根断链（如 TMPFS_POSIX_ACL→FS_POSIX_ACL）
2. **类型二 def_bool/default y 无 select**: 显式 unset_k + opts_n，olddefconfig 可能重新评估
3. **类型三 arch select**: ARM64 select 的项绝对不可突破

### 5项硬限制（def_bool/default y 无法对抗）
- PER_VMA_LOCK、VDSO_GETRANDOM、EFI_PARTITION、PTP_1588_CLOCK_OPTIONAL、NET_IP_TUNNEL

### 钩子执行顺序
1. Armbian 核心 armbian_kernel_config__* 注入 opts_y/opts_m
2. custom_kernel_config 钩子运行（过滤 + direct sed）
3. armbian_kernel_config_apply_opts_from_arrays 应用 opts
4. make olddefconfig 重新解析 Kconfig
→ opts_y 在 opts_n 之后执行，会覆盖！

### 分类错误 BUG
Armbian opts_y 注入的项放在了 remove_from_m 中 → opts_y 未过滤 → 项被恢复

## 可裁组件速查

以下是可以安全裁剪的组件类别（纯路由器场景）：

| 类别 | 可裁项 |
|---|---|
| 调试 | PERF_EVENTS, KALLSYMS, ELFCORE, FTRACE, KPROBES, TRACEPOINTS, DEBUG_KERNEL, DEBUG_BUGVERBOSE |
| 安全LSM | SECURITY_APPARMOR, AUDIT, SELinux, SMACK, IMA, EVM |
| 容器 | VETH, MACVLAN, IPVLAN, VXLAN, OVERLAY_FS, BRIDGE, MEMCG, CGROUP_BPF |
| 虚拟化 | KVM, XEN, VirtIO, PARAVIRT |
| 无线/蓝牙 | CFG80211, MAC80211, RFKILL, Bluetooth, NFC |
| 文件系统 | SQUASHFS, BTRFS, EROFS, NFS, CIFS, NLS, FAT, EXFAT, FUSE |
| USB | USB 全栈 (HOST, GADGET, STORAGE, SERIAL, NET) |
| SCSI/RAID | SCSI, MD, DM, NVMe |
| 声卡/GPU | SND_SOC, DRM, V4L, MEDIA, HDMI, MIPI, DSI |
| 网络高级 | TIPC, BATMAN_ADV, X25, ATM, L2TP, PPTP, GENEVE, PTP, MPLS |
| TCP | DCTCP, BIC, HSTCP, HYBLA, VEGAS, NV, SCALABLE, LP, YEAH, ILLINOIS |
| BPF | BPF_SYSCALL, BPF_JIT, CGROUP_BPF, NET_CLS_BPF |
| IPVS | IP_VS 全栈 |
| IPsec/XFRM | XFRM_*, INET_ESP, INET_AH |
| xtables | NETFILTER_XTABLES + 全部 xt_*, ebtables, arptables |
| tc qdisc | NET_SCHED 全家（保留 NFT_FLOW_OFFLOAD） |
| QoS | HTB, HFSC, FQ_CODEL, CAKE, INGRESS（按需保留） |
| 加密 | CRYPTO_DEV_ROCKCHIP_*, CRYPTO_AEGIS128, CRYPTO_ECRDSA, CRYPTO_SM3/SM4 |
| 内存 | CMA, ZSWAP, KSM |
| 块设备 | BFQ, KYBER, loop(降级=m) |
| initramfs | BLK_DEV_INITRD, RD_GZIP, RD_LZ4（extlinux 启动不需要） |

## nftables 当前状态

**保留核心（34项）**: NF_TABLES, NFT_NAT/MASQ, NFT_REJECT, NFT_LIMIT, NFT_CT, NF_CONNTRACK, NF_FLOW_TABLE, NFT_FLOW_OFFLOAD 等

**已禁（~30项）**: LABELS, ZONES, EVENTS, NETDEV family, DUP, FWD, QUOTA, HASH, SOCKET, TPROXY, FIB, bridge/ARP family, 全部 conntrack helpers

## 后续工作

### 待测试验证
- [ ] R3S 实机测试：网络、sing-box、WireGuard、tailscale、cloudflared、easytier
- [ ] 确认 `cma=256M` 可以安全移除

### 下轮可裁候选
- [ ] BLK_DEV_INITRD + RD_GZIP + RD_LZ4 (3项) — extlinux 启动不需要 initramfs
- [ ] 安全加固降级: HARDENED_USERCOPY, VMAP_STACK
- [ ] DRBG_HMAC → DRBG_HASH 切换 (5项)
