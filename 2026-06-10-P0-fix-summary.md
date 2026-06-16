# P0 三件事修复总结 — 2026-06-10

## 背景

裁剪脚本 `trim-r3s-kernel.sh` 声称禁用了大量内核配置项，但 `make olddefconfig` 编译后大量项被恢复（1303 项 vs baseline 1251 项）。经分析，Armbian 构建框架的核心注入机制是根本原因。

## 根本原因

Armbian 框架中 `armbian_kernel_config_apply_opts_from_arrays()` 的执行顺序：

```
1. opts_n 处理（先禁用）
2. opts_y 处理（后启用）← 覆盖掉 opts_n！
3. opts_m 处理（后设为模块）
```

`opts_y` 在 `opts_n` 之后执行，扩展钩子中通过 `opts_n+=` 禁用项会被核心 `armbian-kernel.sh` 的 `opts_y+=` 覆盖。

### 举例

```
核心 armbian-kernel.sh:   opts_y+=("BPF_SYSCALL")          # 第498行
扩展钩子 nanopir3s-kconfig: opts_n+=("BPF_SYSCALL")        # 第13行
执行顺序: opts_n 先禁用 BPF_SYSCALL → opts_y 重新启用 BPF_SYSCALL

结果：CONFIG_BPF_SYSCALL=y（钩子的禁用被覆盖！）
```

## 修复方法

**核心思路：从 `opts_y` / `opts_m` 数组中删除冲突项，而不只是加 `opts_n`。**

扩展钩子在 `custom_kernel_config` 阶段运行，此时 Armbian 核心已将各项注入到 `opts_y` / `opts_m` 数组。钩子先从数组中过滤掉不需要的项，再追加 `opts_n` 作为双重保险。

## 修改的文件

### 1. `extensions/nanopir3s-kconfig.sh`（重写）

**文件结构**：
- **0 节**：从 `opts_y` 中删除不需要强制 =y 的项（~55项）
  - P0-1: `NETFILTER_BPF_LINK`, `BPF_SYSCALL`, `CGROUP_BPF`
  - P0-3: `SECURITY_APPARMOR`
  - systemd 专属 cgroup: `POSIX_MQUEUE`, `USER_NS`, `BLK_CGROUP`, `FAIR_GROUP_SCHED`, `RT_GROUP_SCHED`, `CFS_BANDWIDTH`, `CGROUP_SCHED`, `CGROUP_PIDS`, `CGROUP_FREEZER`, `CGROUP_DEVICE`, `CGROUP_CPUACCT`, `CGROUP_HUGETLB`, `CGROUP_NET_CLASSID`, `CGROUP_NET_PRIO`, `CGROUP_PERF`, `CPUSETS`, `PROC_PID_CPUSET`
  - 内核调试: `IKCONFIG`, `IKCONFIG_PROC`
  - 网络: `NETKIT`, `NET_SCHED`, `NET_L3_MASTER_DEV`, `XFRM`
  - 密钥环: `KEYS`, `KEY_DH_OPERATIONS`, `ENCRYPTED_KEYS`, `PERSISTENT_KEYRINGS`
  - ZRAM/ZSWAP: `ZSWAP`, `ZSWAP_ZPOOL_DEFAULT_ZBUD`, `ZRAM_BACKEND_842/LZO/DEFLATE`, `ZRAM_WRITEBACK`, `ZRAM_MEMORY_TRACKING`
  - IP_VS: `IP_VS_NFCT`, `IP_VS_PROTO_TCP`, `IP_VS_PROTO_UDP`
  - 其他: `EXT4_FS_SECURITY`, `GPIO_SYSFS`, `NETFILTER_XTABLES_LEGACY/COMPAT`, `BLK_DEV_THROTTLING`, `CFQ_GROUP_IOSCHED`, `BRIDGE_VLAN_FILTERING`, `MEMCG_KMEM`

- **1 节**：从 `opts_m` 中删除不需要强制 =m 的项（~180项）
  - P0-2: `BRIDGE_NETFILTER`, `BRIDGE_NF_EBTABLES*`, 所有 `BRIDGE_EBT_*`（22项）
  - xtables 全栈: `NETFILTER_XTABLES`, 所有 `NETFILTER_XT_*`（76项）
  - ipset 全套: `IP_SET`, `IP_SET_*`（9项）
  - iptables legacy (IPv4/IPv6): `IP_NF_*`, `IP6_NF_*`（~40项）
  - nftables compat: `NFT_COMPAT`, `NFT_COMPAT_ARP`
  - IP_VS: `IP_VS`, `IP_VS_RR`
  - 容器网络: `VETH`, `MACVLAN`, `IPVLAN`, `VXLAN`, `OVERLAY_FS`
  - 文件系统: `BTRFS_FS`, `EROFS_FS`
  - IPsec: `INET_ESP`, `XFRM_ALGO`, `XFRM_USER`
  - 加密: `CRYPTO_SEQIV`, `CRYPTO_GHASH`, `CRYPTO_GCM`
  - 其他: `NTSYNC`, `NET_IP_TUNNEL`, conntrack 冷门 helper, nftables 多余模块, netfilter 调试框架, tc 残留, wireless

- **2 节**：所有项同时追加 `opts_n`（双重保险）

### 2. `trim-r3s-kernel.sh`（新增两节）

- **新增 A.2 节**：`BRIDGE_NETFILTER + ebtables` 清理（~30项 unset）
  ```bash
  # P0-2 root cause: BRIDGE_NETFILTER → select NETFILTER_XTABLES
  unset_k BRIDGE_NETFILTER
  unset_k BRIDGE_NF_EBTABLES
  unset_k BRIDGE_NF_EBTABLES_LEGACY
  # + 20x BRIDGE_EBT_* 子模块
  # + IP_NF_IPTABLES_LEGACY / IP6_NF_IPTABLES_LEGACY
  # + BRIDGE_VLAN_FILTERING
  ```

- **新增 M.0 节**：`SECURITY_APPARMOR + AUDIT` 链清理（~7项 unset）
  ```bash
  # P0-3 root cause: SECURITY_APPARMOR → select AUDIT/SECURITYFS/SECURITY_NETWORK/SECURITY_PATH
  unset_k SECURITY_APPARMOR
  unset_k SECURITYFS
  unset_k SECURITY_NETWORK
  unset_k SECURITY_PATH
  unset_k AUDIT
  unset_k AUDITSYSCALL
  unset_k DEFAULT_SECURITY_APPARMOR
  ```

- **增强 K 节**（BPF）：明确 `BPF=y` 由 `NET=y` select（不可禁），但 `BPF_SYSCALL/CGROUP_BPF` 必须显式禁用
- **增强 M 节**：新增 `CGROUP_SCHED`, `CPUSETS` unset
- **增强 G 节**：新增 `XFRM`, `INET_ESP` unset
- **增强 A.2 节**：新增 `BRIDGE_VLAN_FILTERING` unset

## 关键技术发现

### BPF=y 无法禁用
```
menuconfig NET (net/Kconfig:8)
    select BPF    ← 6.18内核 NET=y 强制 select BPF

BPF 是一个无 prompt 的 bool，仅被其他符号 select。
在 NET=y 的前提下，BPF=y 是强制且无法禁用的。
但它只是一个选项声明，不引入实际代码。
```

### NETFILTER_XTABLES 的 select 链
```
BRIDGE_NETFILTER → (无直接select, 但BRIDGE_NF_EBTABLES_LEGACY依赖)
IP_NF_IPTABLES → select NETFILTER_XTABLES
IP6_NF_IPTABLES → select NETFILTER_XTABLES
IP_NF_IPTABLES_LEGACY → (depends on NETFILTER_XTABLES)
IP6_NF_IPTABLES_LEGACY → (depends on NETFILTER_XTABLES)
```

### SECURITY_APPARMOR 的 select 链
```
SECURITY_APPARMOR → select AUDIT
                  → select SECURITYFS
                  → select SECURITY_NETWORK
                  → select SECURITY_PATH
```

## 预期效果

编译后预期：
- `# CONFIG_BPF_SYSCALL is not set`（disable）
- `CONFIG_BPF=y`（NET 强制，无法禁）
- `# CONFIG_CGROUP_BPF is not set`（disable）
- `# CONFIG_BRIDGE_NETFILTER is not set`（disable）
- `# CONFIG_NETFILTER_XTABLES is not set`（disable，ebtables 连同消失）
- `# CONFIG_SECURITY_APPARMOR is not set`（disable）
- `# CONFIG_AUDIT is not set`（disable）
- 预估：1303 → ~1175 项（-128）

## 文件路径

| 文件 | 位置 |
|------|------|
| 扩展钩子（repo） | `extensions/nanopir3s-kconfig.sh` |
| 扩展钩子（构建） | `../build/userpatches/extensions/nanopir3s-kconfig.sh`（已同步） |
| 裁剪脚本 | `trim-r3s-kernel.sh` (1271行) |
| 编译产物 | `config-6.18.35-current-rockchip64`（待重新编译更新） |
