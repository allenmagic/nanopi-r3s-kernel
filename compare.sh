echo "===== 1. 编译后 config 里 BPF 相关全貌 ====="
grep -E "^CONFIG_.*BPF" config-6.18.35-current-rockchip64 | grep -v "is not set"

echo ""
echo "===== 2. 可能 select BPF_SYSCALL 的项 ====="
grep -E "^CONFIG_(CGROUP_BPF|BPF_EVENTS|BPF_JIT|LWTUNNEL_BPF|NETFILTER_BPF_LINK|XDP_SOCKETS|NET_CLS_BPF|NET_ACT_BPF|KPROBES|PERF_EVENTS|FUNCTION_TRACER|HAVE_EBPF_JIT)=" config-6.18.35-current-rockchip64

echo ""
echo "===== 3. 编译后 NET_CLS_ACT 状态 ====="
grep -E "^CONFIG_NET_CLS_ACT" config-6.18.35-current-rockchip64

echo ""
echo "===== 4. baseline vs final 对比 BPF ====="
diff <(grep -E "BPF" linux-rockchip64-current.config.baseline | sort) \
     <(grep -E "BPF" config-6.18.35-current-rockchip64 | sort)
