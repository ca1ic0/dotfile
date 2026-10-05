#!/usr/bin/env bash
# 由 dotfile 生成器产出 — 请勿手改; 变更请回到仓库重新 gen
# 生成命令: ./dotfile.py gen --all
set -Eeuo pipefail

EXPECTED_ID="ubuntu"
EXPECTED_VERSION="26.04"

df_usage() {
  echo "用法: bash $0 [--dry-run] [--yes] [--no-tui] [--force]"
  echo "  --dry-run  只打印将执行的动作, 不实际执行"
  echo "  --yes      跳过交互选择, 安装脚本内全部模块"
  echo "  --no-tui   不用 TUI, 逐行日志输出 (非终端自动生效)"
  echo "  --force    跳过目标发行版复核"
}

DF_DRY_RUN=0
DF_FORCE=0
DF_ASSUME_YES=0
DF_NO_TUI=0
for df_arg in "$@"; do
  case "$df_arg" in
    --dry-run) DF_DRY_RUN=1 ;;
    --force)   DF_FORCE=1 ;;
    --yes|-y)  DF_ASSUME_YES=1 ;;
    --no-tui)  DF_NO_TUI=1 ;;
    -h|--help) df_usage; exit 0 ;;
    *) printf '未知参数: %s (支持 --dry-run/--yes/--no-tui/--force)\n' "$df_arg" >&2; exit 2 ;;
  esac
done

if [ -t 2 ] && [ "${TERM:-}" != "dumb" ]; then
  DF_C_INFO='\033[1;32m'; DF_C_MOD='\033[1;36m'; DF_C_ERR='\033[1;31m'; DF_C_OFF='\033[0m'
else
  DF_C_INFO=''; DF_C_MOD=''; DF_C_ERR=''; DF_C_OFF=''
fi
info() { printf "${DF_C_INFO}==> %s${DF_C_OFF}\n" "$*"; }
mod()  { printf "\n${DF_C_MOD}==== %s ====${DF_C_OFF}\n" "$1"; }
err()  { printf "${DF_C_ERR}错误: %s${DF_C_OFF}\n" "$*" >&2; }

DF_TMPBASE="${TMPDIR:-/tmp}"; DF_TMPBASE="${DF_TMPBASE%/}"
DF_TMPDIR="$(mktemp -d "$DF_TMPBASE/dotfile-XXXXXX")"
DF_LOG="$DF_TMPBASE/dotfile-install-$$.log"   # 退出后保留
: > "$DF_LOG"
export DF_LOG
DF_RUNNER="$DF_TMPDIR/runner.sh"
cat > "$DF_RUNNER" <<'DF_RUNNER_EOF'
#!/usr/bin/env bash
# gum spin 的命令包装: 输出全部收进日志文件, stdin 与终端完全隔离
# (否则 apt 的 debconf 交互提示会在日志里静默等键盘输入, 造成 spinner 死锁)
export DEBIAN_FRONTEND=noninteractive
exec </dev/null >>"$DF_LOG" 2>&1
# root 且无 sudo 二进制的环境 (容器常见): 透传 — 命令在独立子进程跑, 主脚本的垫片传不进来
if [ "$(id -u)" = 0 ] && ! command -v sudo >/dev/null 2>&1; then
  sudo() { "$@"; }
fi
eval "$1"
DF_RUNNER_EOF

on_exit() {
  df_ret=$?
  rm -rf "$DF_TMPDIR"
  if [ "$df_ret" -ne 0 ]; then
    err "安装失败 (exit $df_ret) — 出错模块: ${DOTFILES_MODULE:-<初始化>}; 日志: $DF_LOG"
  fi
  exit "$df_ret"
}
trap on_exit EXIT
trap 'err "失败命令: $BASH_COMMAND"' ERR   # 定位无声失败

df_ver_prefix_ok() {
  local IFS='.'
  local -a df_exp df_act
  read -r -a df_exp <<<"$1"
  read -r -a df_act <<<"$2"
  local df_i
  for df_i in "${!df_exp[@]}"; do
    [ "${df_act[df_i]:-x}" = "${df_exp[df_i]}" ] || return 1
  done
  return 0
}

# ---- TUI 依赖引导 (gum 为必须依赖, 自动安装) --------------------------------
DF_GUM=""
df_ensure_curl() {
  command -v curl >/dev/null 2>&1 && return 0
  local df_s=""
  [ "$(id -u)" = 0 ] || df_s="sudo"
  case "debian" in
    debian) $df_s apt-get update -qq </dev/null; $df_s apt-get install -y curl </dev/null ;;
    redhat) $df_s dnf install -y curl ;;
    arch)   $df_s pacman -Sy --noconfirm curl ;;
  esac >>"$DF_LOG" 2>&1
  command -v curl >/dev/null 2>&1
}
df_ensure_gum() {
  command -v gum >/dev/null 2>&1 && { DF_GUM="$(command -v gum)"; return 0; }
  df_ensure_curl || { info "gum: 无法准备 curl, TUI 不可用"; return 1; }
  local df_arch
  case "$(uname -s)/$(uname -m)" in
    Linux/x86_64)  df_arch="x86_64" ;;
    Linux/aarch64) df_arch="arm64" ;;
    *) info "gum: 不支持的平台 $(uname -s)/$(uname -m), TUI 不可用"; return 1 ;;
  esac
  local df_ver
  df_ver="${GUM_VERSION:-$(curl -fsSL https://api.github.com/repos/charmbracelet/gum/releases/latest 2>/dev/null | sed -n 's/.*"tag_name": *"\(v[0-9][0-9.]*\)".*/\1/p' | head -1)}"
  [ -n "$df_ver" ] || { info "gum: 无法获取版本号 (可用 GUM_VERSION=v0.x.y 固定)"; return 1; }
  mkdir -p "$HOME/.local/bin"
  local df_t="$(mktemp -d "$DF_TMPDIR/gum-XXXXXX")"
  local df_url="https://github.com/charmbracelet/gum/releases/download/${df_ver}/gum_${df_ver#v}_Linux_${df_arch}.tar.gz"
  curl -fsSL "$df_url" | tar -xz -C "$df_t" >>"$DF_LOG" 2>&1 || { info "gum: 下载失败"; return 1; }
  mv "$df_t"/gum_*/gum "$HOME/.local/bin/gum" || { info "gum: 解包失败"; return 1; }
  DF_GUM="$HOME/.local/bin/gum"
  info "已自动安装 TUI 依赖 gum $df_ver -> $DF_GUM"
}
df_ensure_gum || true

# ---- 目标复核 -------------------------------------------------------------
if [ ! -r /etc/os-release ]; then
  err "读不到 /etc/os-release, 无法确认本机是否为生成目标 $EXPECTED_ID"
  [ "$DF_FORCE" -eq 1 ] || exit 1
  info "(--force) 跳过复核"
else
  . /etc/os-release
  if [ "${ID:-}" != "$EXPECTED_ID" ]; then
    err "本机发行版为 ${ID:-未知}, 而本脚本为 $EXPECTED_ID 生成"
    [ "$DF_FORCE" -eq 1 ] || exit 1
    info "(--force) 强制继续"
  elif [ -n "$EXPECTED_VERSION" ] && [ -n "${VERSION_ID:-}" ] \
    && ! df_ver_prefix_ok "$EXPECTED_VERSION" "$VERSION_ID"; then
    err "本机版本为 ${VERSION_ID}, 而本脚本按 $EXPECTED_VERSION 生成 (配方可能不适用)"
    [ "$DF_FORCE" -eq 1 ] || exit 1
    info "(--force) 强制继续"
  fi
fi

export DOTFILES_DISTRO="ubuntu@26.04"
export DOTFILES_FAMILY="debian"

DF_TUI_PROG=0
DF_TUI_SEL=0
if [ -n "$DF_GUM" ] && [ "$DF_NO_TUI" -eq 0 ] && [ "$DF_DRY_RUN" -eq 0 ] && [ -t 1 ]; then
  DF_TUI_PROG=1
fi
if [ "$DF_TUI_PROG" -eq 1 ] && [ "$DF_ASSUME_YES" -eq 0 ] && [ -t 0 ]; then
  DF_TUI_SEL=1
fi

# ---- 执行原语 -------------------------------------------------------------
df_module_header() {  # $1=模块名 $2=配方段
  local d=""
  eval "d="\$df_desc_${1//-/_}""   # bash 变量名不允许 '-', 模块名含 - 时映射为 _
  if [ "$DF_TUI_PROG" -eq 1 ]; then
    "$DF_GUM" style --bold --foreground 51 "── $1 · $d"
  else
    mod "$1 — $d"
    info "配方段: $2"
  fi
}

df_fail() {  # $1=步骤描述
  if [ "$DF_TUI_PROG" -eq 1 ]; then
    "$DF_GUM" style --bold --foreground 196 "  ✗ $1"
    "$DF_GUM" style --foreground 245 "日志尾部 ($DF_LOG):"
    tail -n 15 "$DF_LOG" | "$DF_GUM" style --foreground 245
  else
    err "步骤失败: $1 (日志: $DF_LOG)"
    tail -n 15 "$DF_LOG" >&2 || true
  fi
  exit 1
}

# root 且无 sudo 二进制的环境 (常见于容器): sudo 透传, 配方无需改写
if [ "$(id -u)" = 0 ] && ! command -v sudo >/dev/null 2>&1; then
  sudo() { "$@"; }
fi

df_step() {  # $1=命令字符串
  if [ "$DF_DRY_RUN" -eq 1 ]; then info "  \$ $1"; return 0; fi
  if [ "$DF_TUI_PROG" -eq 1 ]; then
    "$DF_GUM" spin --spinner dot --title "$1" -- bash "$DF_RUNNER" "$1" \
      || df_fail "$1"
    "$DF_GUM" style --foreground 46 "  ✓ $1"
  else
    info "  \$ $1"
    eval "$1"
  fi
}

df_step_embed() {  # $1=脚本临时路径 $2=展示名
  if [ "$DF_DRY_RUN" -eq 1 ]; then info "  \$ bash <$2>"; return 0; fi
  if [ "$DF_TUI_PROG" -eq 1 ]; then
    "$DF_GUM" spin --spinner dot --title "bash <$2>" -- bash "$1" \
      || df_fail "bash <$2>"
    "$DF_GUM" style --foreground 46 "  ✓ bash <$2>"
  else
    info "  \$ bash <$2> (嵌入脚本)"
    bash "$1"
  fi
}

# ---- 模块注册表 (生成) ----------------------------------------------------
DF_MODULES=(essentials git buildenv nodejs uv neovim docker starship hexo cuda-toolkit oneapi rocm agentharness)
df_desc_essentials='常用 CLI 工具'
df_requires_essentials=''
DF_SECTION_essentials='debian'
df_item_essentials='essentials — 常用 CLI 工具
     ├─ htop
     ├─ tree
     ├─ curl
     └─ jq'
df_desc_git='Git 版本控制'
df_requires_git=''
DF_SECTION_git='debian'
df_item_git='git — Git 版本控制
     └─ git'
df_desc_buildenv='编译工具链 (gcc/llvm/clang/cmake/ninja)'
df_requires_buildenv=''
DF_SECTION_buildenv='debian'
df_item_buildenv='buildenv — 编译工具链 (gcc/llvm/clang/cmake/ninja)
     ├─ build-essential (gcc/g++/make)
     ├─ llvm + clang
     ├─ cmake
     └─ ninja'
df_desc_nodejs='Node.js 环境 (nvm + 最新版 node/npm)'
df_requires_nodejs=''
DF_SECTION_nodejs='debian'
df_item_nodejs='nodejs — Node.js 环境 (nvm + 最新版 node/npm)
     ├─ nvm (~/.nvm, 官方安装器)
     └─ 最新版 node + npm (nvm install node)'
df_desc_uv='Astral uv — 极快的 Python 包/项目管理器'
df_requires_uv=''
DF_SECTION_uv='debian'
df_item_uv='uv — Astral uv — 极快的 Python 包/项目管理器
     └─ uv + uvx'
df_desc_neovim='Neovim 编辑器 + 常用依赖'
df_requires_neovim=''
DF_SECTION_neovim='debian'
df_item_neovim='neovim — Neovim 编辑器 + 常用依赖
     ├─ neovim
     ├─ ripgrep
     └─ fd (fdfind 兼容链接)'
df_desc_docker='Docker Engine (官方 .deb 离线安装, 不注册第三方源)'
df_requires_docker=''
DF_SECTION_docker='debian'
df_item_docker='docker — Docker Engine (官方 .deb 离线安装, 不注册第三方源)
     ├─ docker-ce
     ├─ docker-ce-cli
     ├─ containerd.io
     ├─ docker-buildx-plugin
     └─ docker-compose-plugin'
df_desc_starship='Starship 终端提示符 (官方脚本安装到 ~/.local/bin)'
df_requires_starship=''
DF_SECTION_starship='debian'
df_item_starship='starship — Starship 终端提示符 (官方脚本安装到 ~/.local/bin)
     └─ starship'
df_desc_hexo='Hexo 静态博客框架 (hexo-cli)'
df_requires_hexo='nodejs'
DF_SECTION_hexo='debian'
df_item_hexo='hexo — Hexo 静态博客框架 (hexo-cli)
     └─ hexo-cli (npm -g, 经 nvm 的 node)'
df_desc_cuda_toolkit='NVIDIA CUDA Toolkit (Ubuntu 档案库官方包; 26.04 为 cuda-toolkit 13.x 元包, 旧目标为 nvidia-cuda-toolkit)'
df_requires_cuda_toolkit='buildenv'
DF_SECTION_cuda_toolkit='ubuntu@26.04'
df_item_cuda_toolkit='cuda-toolkit — NVIDIA CUDA Toolkit (Ubuntu 档案库官方包; 26.04 为 cuda-toolkit 13.x 元包, 旧目标为 nvidia-cuda-toolkit)
     ├─ cuda-toolkit 元包 (26.04, 跟随最新 13.x)
     ├─ nvidia-cuda-toolkit (24.04/22.04/debian12)
     └─ nvcc + 开发库 + 工具, 不含 GPU 驱动'
df_desc_oneapi='Intel oneAPI 工具链 (DPC++/icx; 官方 apt 仓 — 上游无单组件离线形式, 离线全家桶数 GB, 按约定退回仓库形式)'
df_requires_oneapi=''
DF_SECTION_oneapi='debian'
df_item_oneapi='oneapi — Intel oneAPI 工具链 (DPC++/icx; 官方 apt 仓 — 上游无单组件离线形式, 离线全家桶数 GB, 按约定退回仓库形式)
     ├─ oneAPI apt 源 (apt.repos.intel.com/oneapi, GPG keyring + signed-by)
     └─ intel-oneapi-compiler-dpcpp-cpp -> icx / icpx / DPC++ (2026.x, 约 1 GiB 下载)'
df_desc_rocm='AMD ROCm (Ubuntu 档案库官方包; 26.04 为 rocm 7.1 元包, 旧目标为 hipcc/rocminfo 5.7 组件)'
df_requires_rocm=''
DF_SECTION_rocm='ubuntu@26.04'
df_item_rocm='rocm — AMD ROCm (Ubuntu 档案库官方包; 26.04 为 rocm 7.1 元包, 旧目标为 hipcc/rocminfo 5.7 组件)
     ├─ rocm 元包 (26.04: 7.1)
     └─ hipcc / rocminfo / rocm-smi (旧目标: 5.7)'
df_desc_agentharness='Agent CLI 全家桶, 统一收纳到 ~/.agentharness/<工具名>/'
df_requires_agentharness='nodejs git'
DF_SECTION_agentharness='debian'
df_item_agentharness='agentharness — Agent CLI 全家桶, 统一收纳到 ~/.agentharness/<工具名>/
     ├─ claude (@anthropic-ai/claude-code)
     ├─ pi (@earendil-works/pi-coding-agent)
     ├─ mcode (@minimax-ai/code)
     ├─ zcode-cli
     ├─ opencode (opencode-ai)
     └─ hermes (官方安装器, HERMES_HOME)'
cat > "$DF_TMPDIR/script-01.sh" <<'DOTFILE_EOF_1'
#!/usr/bin/env bash
# nvm (官方安装器) + 最新版 Node.js。
# nvm 装到 ~/.nvm 并把初始化写进 ~/.bashrc; 非交互 shell 需自行 source nvm.sh。
set -euo pipefail

NVM_VERSION="${NVM_VERSION:-v0.40.8}" # 上游 README 的安装示例均 pin release tag, 不追 master
export NVM_DIR="$HOME/.nvm"

# ---- 安装 ----
echo "==> 安装 nvm $NVM_VERSION"
# METHOD=script: 用 curl 拉 tarball 而非 git clone (容器里 git 的 GnuTLS 常握手失败, 且少一个依赖)
curl -fsSL -o- "https://raw.githubusercontent.com/nvm-sh/nvm/$NVM_VERSION/install.sh" | METHOD=script bash

# nvm 是 shell 函数, 安装脚本不在交互 shell 里, 需手动加载后才能用
. "$NVM_DIR/nvm.sh"

echo "==> 安装最新版 Node.js"
nvm install node
nvm alias default node

# ---- Verification ----
# node/npm 由本进程 nvm use 挂上 PATH, 失败由 set -e 拦截; 成功打印实际落点。
echo "==> 验证安装结果"
nvm use --silent default
node --version
npm --version
echo "已安装: $(command -v node) ($(node --version))"
DOTFILE_EOF_1
cat > "$DF_TMPDIR/script-02.sh" <<'DOTFILE_EOF_2'
#!/usr/bin/env bash
# Astral uv 官方安装脚本, 装到 ~/.local/bin (无需 root)。
# 安装器会自动把 ~/.local/bin 写入 shell 配置的 PATH (幂等)。
set -euo pipefail

# 版本/目录均由官方安装器决定, 本脚本无使用者可调旋钮, 故不设变量。
# 本脚本全程不需要提权 (落点在 $HOME 下), 无需 sudo 垫片。

echo "==> 运行 Astral uv 官方安装器"
curl -LsSf https://astral.sh/uv/install.sh | sh

# ---- Verification ----
# 用意: 安装器把 uv 和 uvx 落在 ~/.local/bin, 但当前 shell 的 PATH 要重开
# 终端才可能生效, 所以这里用绝对路径直接执行 --version, 确认二进制真的
# 落地且可运行, 而不是只听安装器自己汇报「装好了」。任何一步失败都由
# 开头的 set -e 让整个脚本以非零退出。
echo "==> 验证安装结果"
"$HOME/.local/bin/uv" --version
"$HOME/.local/bin/uvx" --version
echo "已安装: $HOME/.local/bin/uv, $HOME/.local/bin/uvx"
DOTFILE_EOF_2
cat > "$DF_TMPDIR/script-03.sh" <<'DOTFILE_EOF_3'
#!/usr/bin/env bash
# Docker Engine 离线安装: 直取官方 .deb 一次性安装, 不给系统注册第三方源
# (软件添加约定: 第三方仓库软件离线优先; 官方 "Install from a package" 通道)。
# 从 download.docker.com 的 Packages 索引解析五个组件各自最新的 .deb,
# apt-get install ./*.deb 让依赖由发行版官方库解析。
set -euo pipefail

# root 且无 sudo 二进制的环境 (容器常见): 透传 — 子进程里主脚本垫片不可见
if [ "$(id -u)" = 0 ] && ! command -v sudo >/dev/null 2>&1; then
  sudo() { "$@"; }
fi

. /etc/os-release   # 本脚本在子进程执行, 主脚本的 os-release 变量传不进来, 必须自行加载

BASE="https://download.docker.com/linux"
case "${ID:-}" in
  debian) REPO="$BASE/debian" ;;
  *)      REPO="$BASE/ubuntu" ;;
esac
SUITE="${UBUNTU_CODENAME:-$VERSION_CODENAME}"
if [ -z "$SUITE" ]; then
  echo "错误: 无法从 /etc/os-release 取得发行版代号" >&2
  exit 1
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# ---- 安装: 解析索引并下载五个组件的最新 .deb ----
INDEX="$TMP/Packages.gz"
curl -fsSL "$REPO/dists/$SUITE/stable/binary-amd64/Packages.gz" -o "$INDEX"

# 索引按版本升序排列, 逐包取其最后一个 Filename 即最新版
for pkg in docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin; do
  deb="$(gunzip -c "$INDEX" | awk -v p="$pkg" '
    $1 == "Package:" { cur = $2 }
    $1 == "Filename:" && cur == p { fn = $2 }
    END { print fn }')"
  if [ -z "$deb" ]; then
    echo "错误: 索引中找不到 $pkg (suite=$SUITE)" >&2
    exit 1
  fi
  curl -fsSL "$REPO/$deb" -o "$TMP/$(basename "$deb")"
  echo "==> 已下载 $(basename "$deb")"
done

# 本地 .deb 交给 apt 安装, 依赖从发行版官方库解析, 不注册 docker 源
sudo apt-get install -y \
  "$TMP"/docker-ce_*.deb "$TMP"/docker-ce-cli_*.deb "$TMP"/containerd.io_*.deb \
  "$TMP"/docker-buildx-plugin_*.deb "$TMP"/docker-compose-plugin_*.deb

# ---- Verification ----
# 容器内 dockerd 起不来属预期 (无特权), 验证 CLI 与插件落地即可。
docker --version
docker compose version
echo "已安装: Docker Engine (官方 .deb, suite=$SUITE, 未注册第三方源)"
DOTFILE_EOF_3
cat > "$DF_TMPDIR/script-04.sh" <<'DOTFILE_EOF_4'
#!/usr/bin/env bash
# Starship 官方安装脚本, 装到用户目录 (无需 root)。
set -euo pipefail

DEST="$HOME/.local/bin" # 安装目的地, 下文 mkdir / --bin-dir / 验证三处引用

echo "==> 准备安装目录 $DEST"
mkdir -p "$DEST"

echo "==> 通过官方安装器安装 starship 到 $DEST"
curl -fsSL https://starship.rs/install.sh | sh -s -- --yes --bin-dir "$DEST"

# ---------------------------------------------------------------------------
# Verification — 确认脚本到底装成了什么
# 用意: starship 被装进用户目录 $DEST, 当前 shell 的 PATH 很可能尚未包含它,
# 因此按绝对路径直接执行二进制的 --version (不依赖 PATH / command -v 查找)。
# 若二进制缺失、损坏或架构不符, 该命令非零退出, set -e 让整个脚本失败;
# 成功则打印版本与落点。本模块没有配置 apt 源, 无需 apt-cache policy 验证。
echo "==> 验证安装"
"$DEST/starship" --version
echo "已安装: $DEST/starship"
DOTFILE_EOF_4
cat > "$DF_TMPDIR/script-05.sh" <<'DOTFILE_EOF_5'
#!/usr/bin/env bash
# 全局安装 hexo-cli。
# node/npm 由 nodejs 模块经 nvm 提供 (装在用户目录, npm -g 无需提权);
# 非交互 shell 不加载 ~/.bashrc, 需手动 source nvm。
set -euo pipefail

export NVM_DIR="$HOME/.nvm"
. "$NVM_DIR/nvm.sh"
nvm use --silent default

echo "==> 全局安装 hexo-cli"
npm install -g hexo-cli

# --- Verification ---
# hexo-cli 经 npm -g 安装到 nvm 的用户级 bin (已在上文加入 PATH), 命令名是 hexo。
# 能打印 hexo-cli / Node 版本即证明安装落点生效、二进制可执行; set -e 兜底。
echo "==> 验证: hexo version"
hexo version
echo "已安装: hexo-cli (npm -g: $(command -v hexo))"
DOTFILE_EOF_5
cat > "$DF_TMPDIR/script-06.sh" <<'DOTFILE_EOF_6'
#!/usr/bin/env bash
# 配置 Intel oneAPI 官方 apt 源 (官方推荐方式: keyring + signed-by, 取代已废弃的 apt-key)。
#   密钥: https://apt.repos.intel.com/intel-gpg-keys/GPG-PUB-KEY-INTEL-SW-PRODUCTS.PUB
#   源:   deb [signed-by=...] https://apt.repos.intel.com/oneapi all main
# 源使用 "all" 发行版, 不区分 Ubuntu 版本 (26.04 等新版本可直接使用)。
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

# 生成器顶层的 sudo 垫片传不进嵌入脚本的子进程, 这里自行兜底 (root-无-sudo 容器)。
if [ "$(id -u)" = 0 ] && ! command -v sudo >/dev/null 2>&1; then
  sudo() { "$@"; }
fi

KEYRING="/usr/share/keyrings/oneapi-archive-keyring.gpg"

tmp_pub="$(mktemp)"
tmp_gpg="$(mktemp)"
trap 'rm -f "$tmp_pub" "$tmp_gpg"' EXIT

echo "==> 下载 Intel GPG 公钥并转为 binary keyring"
curl -fsSL https://apt.repos.intel.com/intel-gpg-keys/GPG-PUB-KEY-INTEL-SW-PRODUCTS.PUB -o "$tmp_pub"
gpg --yes --dearmor -o "$tmp_gpg" "$tmp_pub"
sudo install -m 0644 "$tmp_gpg" "$KEYRING"

echo "==> 写入 /etc/apt/sources.list.d/oneapi.list"
echo "deb [signed-by=${KEYRING}] https://apt.repos.intel.com/oneapi all main" | sudo tee /etc/apt/sources.list.d/oneapi.list

# --allow-releaseinfo-change: Intel 偶尔调整仓库 Label, 重跑时避免交互确认卡死。
echo "==> apt-get update 刷新包索引"
sudo apt-get update --allow-releaseinfo-change

# --- Verification ---
# 本脚本只配源、不装包, 「装成了什么」= Intel 源是否真的被 apt 采纳。apt-get update
# 跑完只说明网络可达; 真正的判据是 Intel 索引通过了 keyring 签名校验并进入包缓存,
# 即 apt-cache policy 在 intel-basekit (本模块要装的主包) 的版本表里
# 列出 https://apt.repos.intel.com/oneapi 的候选版本。看不到说明 keyring/list 有误,
# 立即 exit 1 让整条安装链失败, 而不是留下一个看似成功的坏源。
echo "==> Verification: apt-cache policy intel-oneapi-compiler-dpcpp-cpp"
policy="$(apt-cache policy intel-oneapi-compiler-dpcpp-cpp)"
echo "$policy"
if ! grep -qF 'https://apt.repos.intel.com/oneapi' <<<"$policy"; then
  echo "错误: apt-cache policy intel-oneapi-compiler-dpcpp-cpp 未看到来自 https://apt.repos.intel.com/oneapi 的候选版本, Intel 源未生效" >&2
  exit 1
fi
echo "已配置: /etc/apt/sources.list.d/oneapi.list (keyring: ${KEYRING})"
DOTFILE_EOF_6
df_mod_essentials() {
  df_step 'sudo apt-get update -qq'
  df_step 'sudo apt-get install -y htop tree curl jq'
  df_step 'htop --version | head -1'
  df_step 'jq --version'
  df_step 'tree --version | head -1'
  df_step 'curl --version | head -1'
}
df_mod_git() {
  df_step 'sudo apt-get install -y git'
  df_step 'git --version'
}
df_mod_buildenv() {
  df_step 'sudo apt-get install -y build-essential llvm clang cmake ninja-build'
  df_step 'gcc --version | head -1'
  df_step 'clang --version | head -1'
  df_step 'cmake --version | head -1'
  df_step 'ninja --version'
}
df_mod_nodejs() {
  df_step 'sudo apt-get install -y curl ca-certificates libatomic1'
  df_step_embed "$DF_TMPDIR/script-01.sh" './scripts/install-nvm.sh'
}
df_mod_uv() {
  df_step 'sudo apt-get install -y curl ca-certificates'
  df_step_embed "$DF_TMPDIR/script-02.sh" './scripts/install.sh'
}
df_mod_neovim() {
  df_step 'sudo apt-get install -y neovim ripgrep fd-find curl'
  df_step 'sudo ln -sf /usr/bin/fdfind /usr/local/bin/fd'
  df_step 'nvim --version | head -1'
  df_step 'rg --version | head -1'
  df_step 'fd --version | head -1'
}
df_mod_docker() {
  df_step 'sudo apt-get install -y curl ca-certificates'
  df_step_embed "$DF_TMPDIR/script-03.sh" './scripts/install-docker-debs.sh'
}
df_mod_starship() {
  df_step 'sudo apt-get install -y curl'
  df_step_embed "$DF_TMPDIR/script-04.sh" './scripts/install.sh'
}
df_mod_hexo() {
  df_step_embed "$DF_TMPDIR/script-05.sh" './scripts/install-hexo.sh'
}
df_mod_cuda_toolkit() {
  df_step 'sudo apt-get install -y cuda-toolkit'
  df_step '/usr/local/cuda/bin/nvcc --version | tail -2'
}
df_mod_oneapi() {
  df_step 'sudo apt-get install -y curl gnupg'
  df_step_embed "$DF_TMPDIR/script-06.sh" './scripts/setup-intel-repo.sh'
  df_step 'sudo apt-get install -y intel-oneapi-compiler-dpcpp-cpp'
}
df_mod_rocm() {
  df_step 'sudo apt-get install -y --no-install-recommends rocm'
  df_step 'hipcc --version | head -3'
}
df_mod_agentharness() {
  df_step '. $HOME/.nvm/nvm.sh && nvm use --silent default && npm install -g --prefix $HOME/.agentharness/claude @anthropic-ai/claude-code'
  df_step '. $HOME/.nvm/nvm.sh && nvm use --silent default && npm install -g --ignore-scripts --prefix $HOME/.agentharness/pi @earendil-works/pi-coding-agent'
  df_step '. $HOME/.nvm/nvm.sh && nvm use --silent default && npm install -g --prefix $HOME/.agentharness/minimax @minimax-ai/code'
  df_step '. $HOME/.nvm/nvm.sh && nvm use --silent default && npm install -g --prefix $HOME/.agentharness/zcode zcode-cli'
  df_step '. $HOME/.nvm/nvm.sh && nvm use --silent default && npm install -g --prefix $HOME/.agentharness/opencode opencode-ai'
  df_step 'sudo apt-get install -y curl ca-certificates && curl -fsSL https://hermes-agent.nousresearch.com/install.sh | HERMES_HOME=$HOME/.agentharness/hermes bash'
  df_step 'mkdir -p $HOME/.agentharness/hermes/bin && mv $HOME/.local/bin/hermes $HOME/.agentharness/hermes/bin/hermes'
  df_step '$HOME/.agentharness/hermes/bin/hermes pm repair'
  df_step '$HOME/.agentharness/claude/bin/claude --version | head -1'
  df_step '$HOME/.agentharness/pi/bin/pi --version | head -1'
  df_step '$HOME/.agentharness/minimax/bin/mcode --version | head -1'
  df_step '$HOME/.agentharness/zcode/bin/zcode-cli --version | head -1'
  df_step '$HOME/.agentharness/opencode/bin/opencode --version | head -1'
  df_step '$HOME/.agentharness/hermes/bin/hermes --version | head -1'
}


# ---- 交互选择 (TTY + gum; 否则安装全部) ------------------------------------
df_pick_name() {  # "name — desc" -> name
  local df_item="$1" df_n
  for df_n in "${DF_MODULES[@]}"; do
    case "$df_item" in
      "$df_n"|"$df_n — "*) echo "$df_n"; return 0 ;;
    esac
  done
  return 1
}

df_check_requires() {  # 参数: 已选模块名列表
  local df_sel=" $* " df_n df_deps df_dep
  for df_n in "$@"; do
    eval "df_deps=\"\$df_requires_${df_n//-/_}\""
    for df_dep in $df_deps; do
      case "$df_sel" in
        *" $df_dep "*) ;;
        *) err "模块 $df_n 依赖 $df_dep, 但其未被选择"; exit 1 ;;
      esac
    done
  done
}

DF_PICKED=()
if [ "$DF_TUI_SEL" -eq 1 ]; then
  DF_ITEMS=()
  DF_DEFAULTS=""
  for df_n in "${DF_MODULES[@]}"; do
    eval "df_it=\"\$df_item_${df_n//-/_}\""    # 多行条目: 首行模块名 + 树状内容 (整体一个选项)
    DF_ITEMS+=("$df_it")
    DF_DEFAULTS="$DF_DEFAULTS,$df_it"
  done
  # 注意: gum 的 TUI 渲染在 stderr, 结果走 stdout — 不能重定向 stderr, 否则界面不可见
  # 注意: gum 2.x 的勾选/取消键是 x (空格无效); --ordered 保持注册表顺序输出
  # 注意: 条目是多行的 (树状), 输出必须用记录分隔符 \035 原子读取, 按行读会把树状子行
  #       误当独立选择项喂给 df_pick_name, 然后被 set -e 无声击毙
  DF_PICKED_RAW="$("$DF_GUM" choose --no-limit --ordered --output-delimiter $'\035' \
    --header "选择要安装的模块 (↑↓ 移动, x 勾选/取消, 回车确认) — 目标: ubuntu@26.04" \
    --selected-prefix "[✅] " --unselected-prefix "[  ] " \
    --selected.foreground 2 --item.foreground 7 \
    --selected "${DF_DEFAULTS#,}" "${DF_ITEMS[@]}" || true)"
  if [ -z "$DF_PICKED_RAW" ]; then
    info "未选择任何模块, 退出"
    exit 0
  fi
  while IFS= read -r -d $'\035' df_item || [ -n "$df_item" ]; do
    [ -n "$df_item" ] || continue
    if df_p="$(df_pick_name "$df_item")"; then
      DF_PICKED+=("$df_p")
    else
      err "无法识别所选条目: $df_item"
      exit 1
    fi
  done <<<"$DF_PICKED_RAW"
  df_check_requires "${DF_PICKED[@]}"
  "$DF_GUM" confirm "安装 ${#DF_PICKED[@]} 个模块到 ubuntu@26.04?" || { info "已取消"; exit 0; }
else
  DF_PICKED=("${DF_MODULES[@]}")
fi


# ---- 安装 -----------------------------------------------------------------
for df_m in "${DF_PICKED[@]}"; do
  export DOTFILES_MODULE="$df_m"
  eval "df_sec=\"\$DF_SECTION_${df_m//-/_}\""
  df_module_header "$df_m" "$df_sec"
  "df_mod_${df_m//-/_}"
done

# ---- 汇总 -----------------------------------------------------------------
if [ "$DF_TUI_PROG" -eq 1 ]; then
  "$DF_GUM" style --border rounded --padding "0 1" --foreground 46 \
    "完成: ${#DF_PICKED[@]} 个模块   日志: $DF_LOG"
else
  info "完成: ${#DF_PICKED[@]} 个模块 (日志: $DF_LOG)"
fi
