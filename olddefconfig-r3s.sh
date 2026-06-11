#!/usr/bin/env bash
# =============================================================================
#  olddefconfig-r3s.sh
#  在 Armbian build 工程内，单独对 userpatches/linux-rockchip64-current.config
#  跑一次 make olddefconfig，把依赖收敛后的结果写回。
#
#  用法：
#    ./olddefconfig-r3s.sh                       # 自动找内核源码
#    ./olddefconfig-r3s.sh -k <内核源码目录>     # 手动指定
#    ./olddefconfig-r3s.sh -c <config 路径>      # 自定义 config（默认 userpatches/...）
#    ./olddefconfig-r3s.sh -n                    # 只显示会做什么，不执行
# =============================================================================
set -euo pipefail

# ---------- 默认 ----------
CFG_DEFAULT="userpatches/linux-rockchip64-current.config"
CFG=""; KSRC=""; DRY=0

# ---------- 解析参数 ----------
while [[ $# -gt 0 ]]; do
  case "$1" in
    -k|--kernel-src) KSRC="$2"; shift 2 ;;
    -c|--config)     CFG="$2";  shift 2 ;;
    -n|--dry-run)    DRY=1; shift ;;
    -h|--help)
      sed -n '2,15p' "$0"; exit 0 ;;
    *) echo "未知参数: $1" >&2; exit 2 ;;
  esac
done
CFG="${CFG:-$CFG_DEFAULT}"

# ---------- 颜色 ----------
if [[ -t 1 ]]; then
  R=$'\e[31m'; G=$'\e[32m'; Y=$'\e[33m'; B=$'\e[34m'; X=$'\e[0m'
else R=""; G=""; Y=""; B=""; X=""; fi
log()  { echo "${B}[*]${X} $*"; }
ok()   { echo "${G}[✓]${X} $*"; }
warn() { echo "${Y}[!]${X} $*"; }
err()  { echo "${R}[✗]${X} $*" >&2; }

# ---------- 前置检查 ----------
[[ -f "$CFG" ]] || { err "config 不存在: $CFG"; exit 1; }

# ---------- 自动寻找内核源码 ----------
if [[ -z "$KSRC" ]]; then
  log "自动搜索内核源码目录..."
  # Armbian 常见路径：
  #   build/cache/sources/linux-kernel-worktree/linux-<ver>-rockchip64
  #   build/cache/sources/linux-rockchip64/linux-<ver>
  candidates=()
  while IFS= read -r d; do candidates+=("$d"); done < <(
    find cache/sources -maxdepth 5 -type d \
         \( -name 'linux-*rockchip64*' -o -name 'linux-rockchip64*' \) \
         2>/dev/null | sort -u
  )
  # 过滤：必须包含 Makefile 且看起来是内核源码
  for d in "${candidates[@]}"; do
    if [[ -f "$d/Makefile" ]] && grep -q '^# Linux/' "$d/Makefile" 2>/dev/null; then
      KSRC="$d"; break
    fi
    # 兼容某些版本（Makefile 头部格式不同）
    if [[ -f "$d/Makefile" && -d "$d/arch/arm64" ]]; then
      KSRC="$d"; break
    fi
  done

  if [[ -z "$KSRC" ]]; then
    err "未找到内核源码目录。请先触发一次 Armbian kernel 解包，或用 -k 手动指定。"
    err "可尝试："
    err "  ./compile.sh BOARD=nanopi-r3s BRANCH=current kernel KERNEL_CONFIGURE=prebuilt"
    err "  （上面命令会解包内核但不实际编译完，速度较快）"
    exit 1
  fi
  ok "找到: $KSRC"
fi

[[ -d "$KSRC" && -f "$KSRC/Makefile" && -d "$KSRC/arch/arm64" ]] \
  || { err "不是有效的内核源码目录: $KSRC"; exit 1; }

# ---------- 工具链检测 ----------
CROSS=""
if command -v aarch64-linux-gnu-gcc >/dev/null 2>&1; then
  CROSS="aarch64-linux-gnu-"
elif command -v aarch64-linux-musl-gcc >/dev/null 2>&1; then
  CROSS="aarch64-linux-musl-"
else
  warn "未检测到 aarch64 交叉编译器，olddefconfig 仅做配置不需编译器，"
  warn "但某些 Kconfig 依赖检测脚本可能需要 \$CC，必要时执行："
  warn "  sudo apt install -y gcc-aarch64-linux-gnu"
fi

# ---------- 备份 ----------
TS=$(date +%Y%m%d-%H%M%S)
BAK="${CFG}.before-olddef.${TS}"

stat_cfg() {
  local f="$1"
  local y m n
  y=$(grep -c '^CONFIG_.*=y$' "$f" || true)
  m=$(grep -c '^CONFIG_.*=m$' "$f" || true)
  n=$(grep -c '^# CONFIG_.* is not set$' "$f" || true)
  printf "y=%-5d m=%-5d not_set=%-5d enabled=%d" "$y" "$m" "$n" "$((y+m))"
}

log "olddefconfig 前: $(stat_cfg "$CFG")"

if [[ $DRY -eq 1 ]]; then
  warn "dry-run，不执行。将要执行的命令："
  echo "  cp $CFG $BAK"
  echo "  cp $CFG $KSRC/.config"
  echo "  make -C $KSRC ARCH=arm64 ${CROSS:+CROSS_COMPILE=$CROSS }olddefconfig"
  echo "  cp $KSRC/.config $CFG"
  exit 0
fi

# ---------- 执行 ----------
cp "$CFG" "$BAK"
ok "已备份: $BAK"

cp "$CFG" "$KSRC/.config"
log "已注入 .config 到 $KSRC"

log "执行 make olddefconfig ..."
make -C "$KSRC" ARCH=arm64 ${CROSS:+CROSS_COMPILE=$CROSS} olddefconfig

cp "$KSRC/.config" "$CFG"
ok "已回写到 $CFG"

# ---------- 结果对比 ----------
log "olddefconfig 后: $(stat_cfg "$CFG")"

# 差异统计：被 olddefconfig 额外关掉的项
extra=$(diff "$BAK" "$CFG" 2>/dev/null \
        | grep -c '^> # CONFIG_.* is not set$' || true)
ok "本次 olddefconfig 额外关闭了 $extra 个配置项"

# 列出前 40 个新增关闭项（按字母序）
echo
log "新增关闭项预览（前 40 个）："
diff "$BAK" "$CFG" 2>/dev/null \
  | awk '/^> # CONFIG_.* is not set$/{print "  " $3}' \
  | head -40

