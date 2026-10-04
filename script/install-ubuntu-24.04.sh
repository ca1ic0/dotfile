#!/usr/bin/env bash
# 由 dotfile 生成器产出 — 请勿手改; 变更请回到仓库重新 gen
# 生成命令: ./dotfile.py gen --all
set -Eeuo pipefail

EXPECTED_ID="ubuntu"
EXPECTED_VERSION="24.04"

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

export DOTFILES_DISTRO="ubuntu@24.04"
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
DF_MODULES=(essentials git uv neovim docker starship hexo cuda-toolkit oneapi rocm)
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
df_desc_uv='Astral uv — 极快的 Python 包/项目管理器'
df_requires_uv=''
DF_SECTION_uv='debian'
df_item_uv='uv — Astral uv — 极快的 Python 包/项目管理器
     └─ uv'
df_desc_neovim='Neovim 编辑器 + 常用依赖'
df_requires_neovim=''
DF_SECTION_neovim='debian'
df_item_neovim='neovim — Neovim 编辑器 + 常用依赖
     ├─ neovim
     ├─ ripgrep
     └─ fd-find'
df_desc_docker='Docker Engine (官方 apt 源)'
df_requires_docker=''
DF_SECTION_docker='debian'
df_item_docker='docker — Docker Engine (官方 apt 源)
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
df_desc_hexo='Hexo 静态博客框架 (Node.js + hexo-cli)'
df_requires_hexo=''
DF_SECTION_hexo='debian'
df_item_hexo='hexo — Hexo 静态博客框架 (Node.js + hexo-cli)
     ├─ nodejs
     ├─ npm
     └─ hexo-cli'
df_desc_cuda_toolkit='NVIDIA CUDA Toolkit'
df_requires_cuda_toolkit=''
DF_SECTION_cuda_toolkit='debian'
df_item_cuda_toolkit='cuda-toolkit — NVIDIA CUDA Toolkit
     ├─ cuda-toolkit-13 (nvcc + 开发库 + 工具, 不含 GPU 驱动)
     └─ cuda-keyring (NVIDIA CUDA 网络源)'
df_desc_oneapi='Intel oneAPI 工具链 (DPC++/icx)'
df_requires_oneapi=''
DF_SECTION_oneapi='debian'
df_item_oneapi='oneapi — Intel oneAPI 工具链 (DPC++/icx)
     ├─ oneAPI apt 源 (apt.repos.intel.com/oneapi, GPG keyring + signed-by)
     └─ intel-oneapi-compiler-dpcpp-cpp -> icx / icpx / DPC++ (2026.x, 约 1 GiB 下载)'
df_desc_rocm='AMD ROCm (HIP 运行时与编译器, 官方 repo.radeon.com 源)'
df_requires_rocm=''
DF_SECTION_rocm='debian'
df_item_rocm='rocm — AMD ROCm (HIP 运行时与编译器, 官方 repo.radeon.com 源)
     ├─ rocm-hip-runtime → hip-runtime-amd / hsa-rocr / comgr / rocminfo
     ├─ hipcc + hip-dev → rocm-llvm (HIP 编译器与头文件)
     └─ /opt/rocm (PATH 经 /etc/profile.d/rocm.sh)'
cat > "$DF_TMPDIR/script-01.sh" <<'DOTFILE_EOF_1'
#!/usr/bin/env bash
# Astral uv 官方安装脚本, 装到 ~/.local/bin (无需 root)。
# 安装器会自动把 ~/.local/bin 写入 shell 配置的 PATH (幂等)。
set -euo pipefail
curl -LsSf https://astral.sh/uv/install.sh | sh
DOTFILE_EOF_1
cat > "$DF_TMPDIR/script-02.sh" <<'DOTFILE_EOF_2'
#!/usr/bin/env bash
# 配置 Docker 官方 apt 源 (download.docker.com) — 官方推荐的 keyring 方式, deb822 格式。
# 写法依据官方文档: https://docs.docker.com/engine/install/ubuntu/
#   * GPG key (ASCII) 落 /etc/apt/keyrings/docker.asc, 源文件用 Signed-By 指向它
#   * suite 取本机代号: ubuntu 26.04=resolute 24.04=noble 22.04=jammy (已实测源上有 resolute)
#   * debian 家族分仓: ID=debian 走 linux/debian, 其余 (ubuntu/pop 等) 走 linux/ubuntu
set -euo pipefail

# root 且无 sudo 二进制的环境 (容器常见): 透传。
# 生成器主脚本里有同名垫片, 但本脚本经 bash 子进程执行, 垫片传不进来, 需自带。
if [ "$(id -u)" = 0 ] && ! command -v sudo >/dev/null 2>&1; then
  sudo() { "$@"; }
fi

# 官方源按发行版分仓: ubuntu 仓 (含衍生版) 与 debian 仓, 二者 URL 仅差这一段
REPO_ID="ubuntu"
case "${ID:-}" in
  debian) REPO_ID="debian" ;;
esac

# 官方文档取 ${UBUNTU_CODENAME:-$VERSION_CODENAME} (ubuntu 26.04 起 os-release 带 UBUNTU_CODENAME)
CODENAME="$(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}")"
if [ -z "$CODENAME" ]; then
  echo "setup-docker-repo: 无法从 /etc/os-release 取得发行版代号" >&2
  exit 1
fi

sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL "https://download.docker.com/linux/${REPO_ID}/gpg" -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc

sudo tee /etc/apt/sources.list.d/docker.sources >/dev/null <<EOF
Types: deb
URIs: https://download.docker.com/linux/${REPO_ID}
Suites: ${CODENAME}
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
EOF

sudo apt-get update
DOTFILE_EOF_2
cat > "$DF_TMPDIR/script-03.sh" <<'DOTFILE_EOF_3'
#!/usr/bin/env bash
# Starship 官方安装脚本, 装到用户目录 (无需 root)。
set -euo pipefail
mkdir -p "$HOME/.local/bin"
curl -fsSL https://starship.rs/install.sh | sh -s -- --yes --bin-dir "$HOME/.local/bin"
DOTFILE_EOF_3
cat > "$DF_TMPDIR/script-04.sh" <<'DOTFILE_EOF_4'
#!/usr/bin/env bash
# 全局安装 hexo-cli。
# npm -g 需要写入系统目录 (/usr/lib/node_modules, /usr/bin):
# - root (含无 sudo 二进制的容器, 生成器的 sudo 垫片在父 shell, 传不进本子进程): 直接装;
# - 普通用户: 经 sudo 提权。
set -euo pipefail

if [ "$(id -u)" = 0 ]; then
  npm install -g hexo-cli
else
  sudo npm install -g hexo-cli
fi
DOTFILE_EOF_4
cat > "$DF_TMPDIR/script-05.sh" <<'DOTFILE_EOF_5'
#!/usr/bin/env bash
# 配置 NVIDIA CUDA 网络源 — 官方 cuda-keyring 包方式。
# 相比手工 gpg --dearmor, keyring 包一步安装三样东西:
#   /usr/share/keyrings/cuda-archive-keyring.gpg          (签名密钥)
#   /etc/apt/sources.list.d/cuda-<distro>-<arch>.list     (网络源条目)
#   /etc/apt/preferences.d/cuda-repository-pin-600        (apt pin, 防止遮蔽发行版包)
#
# 行为:
#   1. 由 /etc/os-release 推导 NVIDIA 仓库名 (ubuntu 26.04 -> ubuntu2604, debian 12 -> debian12)
#   2. 探测仓库是否存在, 不存在则回落 ubuntu2404 (NVIDIA 对新发行版上架可能滞后)
#   3. 从仓库索引挑最新 cuda-keyring_*_all.deb 安装 (写死版本号会在升级后 404)
#   4. apt-get update, 让 NVIDIA 源里的 cuda-toolkit 元包对后续步骤可见
set -euo pipefail

# root 且无 sudo 的环境 (容器常见): 透传 — 嵌入脚本跑在子进程里,
# 生成器主脚本的 sudo 垫片传不进来, 需自带同款
if [ "$(id -u)" = 0 ] && ! command -v sudo >/dev/null 2>&1; then
  sudo() { "$@"; }
fi

NV_BASE="https://developer.download.nvidia.com/compute/cuda/repos"

# NVIDIA 仓库目录用自有架构名, 与 dpkg 不同: amd64 -> x86_64, arm64 -> sbsa
case "$(dpkg --print-architecture)" in
  amd64) arch="x86_64" ;;
  arm64) arch="sbsa" ;;
  *) arch="$(dpkg --print-architecture)" ;;
esac

# 1) 发行版 -> NVIDIA 仓库名 (linuxmint/pop 与 ubuntu 同源, 版本对不上会走下面的回落)
. /etc/os-release
repo_distro=""
case "${ID:-}" in
  ubuntu | linuxmint | pop)
    repo_distro="ubuntu${VERSION_ID%%.*}${VERSION_ID#*.}"   # 26.04 -> ubuntu2604
    ;;
  debian)
    repo_distro="debian${VERSION_ID%%.*}"                    # 12 -> debian12
    ;;
esac

# 2) 仓库存在性校验 + 回落
#    注意必须 -L: 该 CDN 对不存在的路径回 301 (跳转到加斜杠的 404), 不跟随会误判为可用
repo_ok() { curl -fsSIL --max-time 20 "$NV_BASE/$1/$arch/Release" >/dev/null 2>&1; }
if [ -z "$repo_distro" ] || ! repo_ok "$repo_distro"; then
  echo "==> NVIDIA CUDA 源 ${repo_distro:-<未知>} 不可用, 回落 ubuntu2404" >&2
  repo_distro="ubuntu2404"
  repo_ok "$repo_distro" || { echo "错误: 回落源 $NV_BASE/$repo_distro/$arch 也不可达" >&2; exit 1; }
fi
repo_url="$NV_BASE/$repo_distro/$arch"
echo "==> 使用 CUDA 网络源: $repo_url"

# 3) 安装最新 cuda-keyring 包
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT
deb_name="$(curl -fsSL "$repo_url/" | grep -oE 'cuda-keyring_[0-9][0-9A-Za-z.+~_-]*_all\.deb' | sort -uV | tail -n 1)"
if [ -z "$deb_name" ]; then
  echo "错误: 在 $repo_url/ 索引里找不到 cuda-keyring 包" >&2
  exit 1
fi
echo "==> 安装 $deb_name"
curl -fsSL "$repo_url/$deb_name" -o "$tmpdir/cuda-keyring.deb"
sudo dpkg -i "$tmpdir/cuda-keyring.deb"

# 4) 刷新元数据, 让 NVIDIA 源里的包可见
sudo apt-get update
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

KEY_URL="https://apt.repos.intel.com/intel-gpg-keys/GPG-PUB-KEY-INTEL-SW-PRODUCTS.PUB"
KEYRING="/usr/share/keyrings/oneapi-archive-keyring.gpg"
LIST="/etc/apt/sources.list.d/oneapi.list"

tmp_pub="$(mktemp)"
tmp_gpg="$(mktemp)"
trap 'rm -f "$tmp_pub" "$tmp_gpg"' EXIT

curl -fsSL "$KEY_URL" -o "$tmp_pub"
gpg --yes --dearmor -o "$tmp_gpg" "$tmp_pub"
sudo install -m 0644 "$tmp_gpg" "$KEYRING"
echo "deb [signed-by=${KEYRING}] https://apt.repos.intel.com/oneapi all main" | sudo tee "$LIST" >/dev/null

# --allow-releaseinfo-change: Intel 偶尔调整仓库 Label, 重跑时避免交互确认卡死。
sudo apt-get update --allow-releaseinfo-change
DOTFILE_EOF_6
cat > "$DF_TMPDIR/script-07.sh" <<'DOTFILE_EOF_7'
#!/usr/bin/env bash
# 配置 AMD ROCm 官方用户态 apt 源 (repo.radeon.com/rocm)。
#
# ROCm 用户态仓库只按 Ubuntu LTS 代号发布套件 (2026-10 时: jammy=22.04 / noble=24.04)。
# 更新的发行版 (如 26.04 resolute) 尚无专属套件 —— 该仓库是纯用户态二进制,
# 依赖 glibc 向后兼容, 回落到 noble 即可; 探测逻辑对将来新增的代号同样自适应。
# (内核态驱动 amdgpu-dkms 走另一仓库 repo.radeon.com/amdgpu, 容器/CI 无需。)
set -euo pipefail

REPO_URL="https://repo.radeon.com/rocm/apt/debian"
KEY_URL="https://repo.radeon.com/rocm/rocm.gpg.key"
# 套件探测次序: 本机代号优先, 之后按 新 → 旧 回落
FALLBACK_SUITES="noble jammy"

SUDO=""
[ "$(id -u)" = 0 ] || SUDO="sudo"

# 本机代号 (ubuntu: noble/resolute...; debian: bookworm/trixie...)
. /etc/os-release
CODENAME="${VERSION_CODENAME:-}"

pick_suite() {
  local s
  for s in "$CODENAME" $FALLBACK_SUITES; do
    [ -n "$s" ] || continue
    if command -v curl >/dev/null 2>&1 \
       && curl -fsSI --max-time 20 "$REPO_URL/dists/$s/Release" >/dev/null 2>&1; then
      echo "$s"
      return 0
    fi
  done
  # 探测不了 (离线/无 curl) 时按 2026-10 的仓库现状给缺省
  echo noble
}
SUITE="$(pick_suite)"

# 密钥为 ASCII armored 格式, apt >= 2.4 (jammy+) 的 signed-by 可直接引用, 无需 gpg 反装甲
$SUDO install -m 0755 -d /etc/apt/keyrings
KEYFILE="$(mktemp)"
trap 'rm -f "$KEYFILE"' EXIT
curl -fsSL "$KEY_URL" -o "$KEYFILE"
$SUDO install -m 0644 "$KEYFILE" /etc/apt/keyrings/rocm.asc

echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/rocm.asc] $REPO_URL $SUITE main" \
  | $SUDO tee /etc/apt/sources.list.d/rocm.list >/dev/null

# Ubuntu 26.04+ 的 universe 自带 ROCm 包 (rocminfo/hipcc 等, 版本号高于 AMD 仓库的),
# 会顶掉候选并打断 AMD 元包的精确版本依赖 (=x.y.z)。把 repo.radeon.com 钉到 1000
# (>=1000 允许降级), 保证 AMD 官方包始终优先; 不影响其它来源的包。
$SUDO tee /etc/apt/preferences.d/rocm > /dev/null <<'ROCM_PIN'
Package: *
Pin: origin "repo.radeon.com"
Pin-Priority: 1000
ROCM_PIN

echo "已配置 ROCm apt 源: suite=$SUITE (本机代号: ${CODENAME:-未知})"
DOTFILE_EOF_7
cat > "$DF_TMPDIR/script-08.sh" <<'DOTFILE_EOF_8'
#!/usr/bin/env bash
# ROCm 链接器兼容垫片 (仅 noble 回落环境需要; 依赖完整时零动作)。
#
# 背景: AMD 仓库目前只发布 22.04/24.04 套件, 更新的发行版回落用 noble 的包
# (见 setup-rocm-repo.sh)。其中 rocm-llvm 的 lld 在 24.04 上构建, 运行期依赖
# libxml2.so.2 (连带 libicuuc.so.74); Ubuntu 26.04 把 libxml2 升到 soname 16
# 且不再提供旧运行库, 于是 hipcc 编译任何含 device code 的源文件都会在
# amdgcn-link 阶段报 "libxml2.so.2: cannot open shared object file"。
#
# 处理: 从 Ubuntu 官方 pool 解包 (dpkg-deb -x, 不安装包) 这两组运行库到
# /usr/lib/x86_64-linux-gnu —— 与 soname 16 的新 libxml2 同机共存, 无侵入。
# 垫片属于尽力而为: 下载失败只告警不阻断安装 (hipcc/rocminfo 二进制不受影响)。
set -euo pipefail

LIBDIR=/usr/lib/x86_64-linux-gnu
XML2_DEB="https://archive.ubuntu.com/ubuntu/pool/main/libx/libxml2/libxml2_2.9.14+dfsg-1.3ubuntu3_amd64.deb"
ICU_DEB="https://archive.ubuntu.com/ubuntu/pool/main/i/icu/libicu74_74.2-1ubuntu3.1_amd64.deb"

LLD="/opt/rocm/lib/llvm/bin/lld"
[ -x "$LLD" ] || { echo "rocm: 未找到 $LLD, 跳过链接器兼容检查"; exit 0; }

if ! ldd "$LLD" 2>/dev/null | grep -q 'libxml2.so.2.*not found'; then
  echo "rocm: 链接器依赖完整 (libxml2.so.2 可用), 无需兼容垫片"
  exit 0
fi

SUDO=""
[ "$(id -u)" = 0 ] || SUDO="sudo"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fetch_extract() {  # $1=deb URL  $2=要拷贝的文件 glob
  local name; name="$(basename "$1")"
  curl -fsSL --retry 2 -o "$TMP/$name" "$1" \
    || { echo "rocm 兼容垫片: 下载失败 $name (跳过)" >&2; return 1; }
  dpkg-deb -x "$TMP/$name" "$TMP/x" || return 1
  $SUDO cp -a "$TMP"/x"$LIBDIR"/$2 "$LIBDIR"/ || return 1
}

# shellcheck disable=SC2015
fetch_extract "$XML2_DEB" 'libxml2.so.2*' \
  && fetch_extract "$ICU_DEB" 'libicu*.so.74*' \
  && $SUDO ldconfig \
  || { echo "rocm 兼容垫片: 未能补齐 libxml2.so.2/libicu74 — hipcc 编译 device code 可能失败 (hipcc/rocminfo 二进制不受影响)" >&2; exit 0; }

if ldd "$LLD" 2>/dev/null | grep -q 'not found'; then
  echo "rocm 兼容垫片: 补齐后 lld 仍缺库:" >&2
  ldd "$LLD" 2>/dev/null | grep 'not found' >&2 || true
  exit 0
fi
echo "rocm: 已补齐 lld 运行库 (libxml2.so.2 + libicu74), hipcc 链接可用"
DOTFILE_EOF_8
df_mod_essentials() {
  df_step 'sudo apt-get install -y htop tree curl jq'
}
df_mod_git() {
  df_step 'sudo apt-get install -y git'
}
df_mod_uv() {
  df_step 'sudo apt-get install -y curl ca-certificates'
  df_step_embed "$DF_TMPDIR/script-01.sh" './scripts/install.sh'
}
df_mod_neovim() {
  df_step 'sudo apt-get install -y neovim ripgrep fd-find curl'
}
df_mod_docker() {
  df_step 'sudo apt-get install -y curl ca-certificates gnupg'
  df_step_embed "$DF_TMPDIR/script-02.sh" './scripts/setup-docker-repo.sh'
  df_step 'sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin'
}
df_mod_starship() {
  df_step 'sudo apt-get install -y curl'
  df_step_embed "$DF_TMPDIR/script-03.sh" './scripts/install.sh'
}
df_mod_hexo() {
  df_step 'sudo apt-get install -y nodejs npm'
  df_step_embed "$DF_TMPDIR/script-04.sh" './scripts/install-hexo.sh'
}
df_mod_cuda_toolkit() {
  df_step 'sudo apt-get install -y curl'
  df_step_embed "$DF_TMPDIR/script-05.sh" './scripts/setup-nvidia-repo.sh'
  df_step 'sudo apt-get install -y cuda-toolkit-13'
}
df_mod_oneapi() {
  df_step 'sudo apt-get install -y curl gnupg'
  df_step_embed "$DF_TMPDIR/script-06.sh" './scripts/setup-intel-repo.sh'
  df_step 'sudo apt-get install -y intel-oneapi-compiler-dpcpp-cpp'
}
df_mod_rocm() {
  df_step 'sudo apt-get install -y curl ca-certificates'
  df_step_embed "$DF_TMPDIR/script-07.sh" './scripts/setup-rocm-repo.sh'
  df_step 'sudo apt-get update'
  df_step 'sudo apt-get install -y --no-install-recommends rocm-hip-runtime hipcc hip-dev'
  df_step_embed "$DF_TMPDIR/script-08.sh" './scripts/fix-lld-deps.sh'
  df_step 'echo '\''export PATH=/opt/rocm/bin:$PATH'\'' | sudo tee /etc/profile.d/rocm.sh >/dev/null'
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
    --header "选择要安装的模块 (↑↓ 移动, x 勾选/取消, 回车确认) — 目标: ubuntu@24.04" \
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
  "$DF_GUM" confirm "安装 ${#DF_PICKED[@]} 个模块到 ubuntu@24.04?" || { info "已取消"; exit 0; }
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
