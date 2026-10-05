#!/usr/bin/env bash
# 由 dotfile 生成器产出 — 请勿手改; 变更请回到仓库重新 gen
# 生成命令: ./dotfile.py gen --all
set -Eeuo pipefail

EXPECTED_ID="debian"
EXPECTED_VERSION="12"

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

export DOTFILES_DISTRO="debian@12"
export DOTFILES_FAMILY="debian"

DF_TUI_PROG=0
DF_TUI_SEL=0
if [ -n "$DF_GUM" ] && [ "$DF_NO_TUI" -eq 0 ] && [ "$DF_DRY_RUN" -eq 0 ] && [ -t 1 ]; then
  DF_TUI_PROG=1
fi
# 交互判定看 /dev/tty 而非 stdin: curl|bash 时 stdin 是管道, 但用户终端仍在
# /dev/tty 上 — 选择界面照常弹出, 键盘输入经 /dev/tty 读取 (CI 等无终端环境
# /dev/tty 不可读, 自动回落为装全部)。
if [ "$DF_TUI_PROG" -eq 1 ] && [ "$DF_ASSUME_YES" -eq 0 ] && [ -r /dev/tty ]; then
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
DF_MODULES=(base nodejs uv dev-cli tools docker cuda-toolkit oneapi rocm agentharness)
df_desc_base='基础环境: 常用 CLI (htop/btop/tree/jq/gdu) + git + 编译工具链'
df_requires_base=''
DF_SECTION_base='debian'
df_item_base='base — 基础环境: 常用 CLI (htop/btop/tree/jq/gdu) + git + 编译工具链
     ├─ htop / btop / tree / curl / jq / gdu
     ├─ git
     ├─ build-essential (gcc/g++/make)
     ├─ llvm + clang
     └─ cmake + ninja'
df_desc_nodejs='Node.js 环境 (nvm + 最新版 node/npm)'
df_requires_nodejs=''
DF_SECTION_nodejs='debian@12'
df_item_nodejs='nodejs — Node.js 环境 (nvm + 最新版 node/npm)
     ├─ nvm (~/.nvm, 官方安装器)
     └─ 最新版 node + npm (nvm install node)'
df_desc_uv='Astral uv — 极快的 Python 包/项目管理器'
df_requires_uv=''
DF_SECTION_uv='debian'
df_item_uv='uv — Astral uv — 极快的 Python 包/项目管理器
     └─ uv + uvx (~/.local/bin, 免 root)'
df_desc_dev_cli='开发 CLI 工具集: gh / 飞书 / Notion CLI (ntn) / hexo-cli'
df_requires_dev_cli='nodejs'
DF_SECTION_dev_cli='debian'
df_item_dev_cli='dev-cli — 开发 CLI 工具集: gh / 飞书 / Notion CLI (ntn) / hexo-cli
     ├─ gh (档案库直装)
     ├─ 飞书桌面版 (官方 API 直链)
     ├─ ntn — Notion CLI (npm)
     └─ hexo-cli (npm)'
df_desc_tools='终端效率工具: yazi 文件管理器 + fzf 模糊查找'
df_requires_tools=''
DF_SECTION_tools='debian'
df_item_tools='tools — 终端效率工具: yazi 文件管理器 + fzf 模糊查找
     ├─ yazi + ya (GitHub releases 官方产物)
     └─ fzf (档案库直装)'
df_desc_docker='Docker Engine (官方离线包一次性安装, 不注册第三方源)'
df_requires_docker=''
DF_SECTION_docker='debian'
df_item_docker='docker — Docker Engine (官方离线包一次性安装, 不注册第三方源)
     ├─ docker-ce
     ├─ docker-ce-cli
     ├─ containerd.io
     ├─ docker-buildx-plugin
     └─ docker-compose-plugin'
df_desc_cuda_toolkit='NVIDIA CUDA Toolkit (Ubuntu/Debian 档案库优先; Fedora 与 Debian13 走 NVIDIA 官方源临时注册)'
df_requires_cuda_toolkit='base'
DF_SECTION_cuda_toolkit='debian'
df_item_cuda_toolkit='cuda-toolkit — NVIDIA CUDA Toolkit (Ubuntu/Debian 档案库优先; Fedora 与 Debian13 走 NVIDIA 官方源临时注册)
     ├─ cuda-toolkit 元包 (26.04 档案库 / fedora / debian13, NVIDIA 官方渠道)
     ├─ nvidia-cuda-toolkit (24.04 / debian12 档案库)
     └─ nvcc + 开发库 + 工具, 不含 GPU 驱动'
df_desc_oneapi='Intel oneAPI 工具链 (DPC++/icx; 官方 apt/yum 仓 — 上游无单组件离线形式, 离线全家桶数 GB, 按约定退回仓库形式)'
df_requires_oneapi=''
DF_SECTION_oneapi='debian'
df_item_oneapi='oneapi — Intel oneAPI 工具链 (DPC++/icx; 官方 apt/yum 仓 — 上游无单组件离线形式, 离线全家桶数 GB, 按约定退回仓库形式)
     ├─ oneAPI 官方源 (apt: keyring+signed-by 常驻 / dnf: repofrompath 一次性)
     └─ intel-oneapi-compiler-dpcpp-cpp -> icx / icpx / DPC++ (2026.x, 约 1 GiB 下载)'
df_desc_rocm='AMD ROCm (各目标档案库官方包; 26.04 为 rocm 7.1 元包, 其余为 hipcc/rocminfo 组件)'
df_requires_rocm=''
DF_SECTION_rocm='debian'
df_item_rocm='rocm — AMD ROCm (各目标档案库官方包; 26.04 为 rocm 7.1 元包, 其余为 hipcc/rocminfo 组件)
     ├─ rocm 元包 (26.04: 7.1)
     └─ hipcc / rocminfo / rocm-smi (旧目标: 5.7)'
df_desc_agentharness='Agent CLI 全家桶 (npm 全局安装; hermes 走官方安装器收在 ~/.agentharness)'
df_requires_agentharness='nodejs base'
DF_SECTION_agentharness='debian'
df_item_agentharness='agentharness — Agent CLI 全家桶 (npm 全局安装; hermes 走官方安装器收在 ~/.agentharness)
     ├─ claude (@anthropic-ai/claude-code)
     ├─ pi (@earendil-works/pi-coding-agent)
     ├─ mcode (@minimax-ai/code)
     ├─ zcode-cli
     ├─ opencode (opencode-ai)
     └─ hermes (官方安装器, HERMES_HOME=~/.agentharness/hermes)'
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

# nvm 是 shell 函数, 安装脚本不在交互 shell 里, 需手动加载后才能用;
# 其函数体内存在未定义变量路径 (如远程索引不可达时的版本解析), set -u 会在
# 函数调用时误杀 (STABLE: unbound variable) — 整个 nvm 交互区临时关闭 -u
set +u
. "$NVM_DIR/nvm.sh"

echo "==> 安装最新版 Node.js"
nvm install node
nvm alias default node
set -u

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
# 飞书 (Feishu) 桌面版离线安装: 运行时调官方 package_info API 解析下载直链,
# 下载安装包后本地安装 (deb: apt-get install ./file, rpm: dnf install ./file),
# 不注册任何软件源。
# 官方无 apt/dnf 仓库 (www.feishu.cn/download 为 JS SPA, 无静态包链接); 真实
# 下载链由页面 JS 调 https://www.feishu.cn/api/package_info?platform=<N> 取得,
# 是带 x-signature/x-expires 的短时效签名 CDN 直链 (实测约 30 分钟过期, CDN
# 域名与哈希目录随版本变), 无法离线拼接稳定 URL, 只能装时现取。
set -euo pipefail

# root 且无 sudo 二进制的环境 (容器常见): 透传 — 子进程里主脚本垫片不可见
if [ "$(id -u)" = 0 ] && ! command -v sudo >/dev/null 2>&1; then
  sudo() { "$@"; }
fi

. /etc/os-release   # 本脚本在子进程执行, 主脚本的 os-release 变量传不进来, 必须自行加载

# 版本 pin 旋钮: 缺省空 = 装 API 当前返回的最新版; 设置时 (如 7.72.23, 带不带
# V 均可) 先与 API 版本比对, 不一致即失败 — 免得白下 ~338MB 才发现版本不符。
# 注意该渠道只有「最新版」一个候选, 无法按版本号点装历史版本。
FEISHU_VERSION="${FEISHU_VERSION:-}"

# 平台枚举 (取自官方 download JS): 10=x64-deb 11=x64-rpm 12=arm64-deb 13=arm64-rpm
case "${ID:-}/$(uname -m)" in
  debian/x86_64|ubuntu/x86_64)   PLATFORM=10; PKG=deb ;;
  debian/aarch64|ubuntu/aarch64) PLATFORM=12; PKG=deb ;;
  fedora/x86_64)                 PLATFORM=11; PKG=rpm ;;
  fedora/aarch64)                PLATFORM=13; PKG=rpm ;;
  *) echo "错误: 不支持的目标 ${ID:-未知}/$(uname -m) (仅 debian/ubuntu/fedora 的 x64/arm64)" >&2; exit 1 ;;
esac

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

json_str() {  # $1=键名: 从 API 响应提取字符串值 (实测为单行紧凑 JSON)
  printf '%s' "$JSON" | grep -oE "\"$1\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" | head -1 \
    | sed -E 's/^.*:[[:space:]]*"(.*)"$/\1/'
}

# ---- 安装: 调 API → 还原转义 → 下载 → md5 校验 → 本地安装 ----
echo "==> 调官方 package_info API (platform=$PLATFORM)"
JSON="$(curl -fsSL "https://www.feishu.cn/api/package_info?platform=$PLATFORM")"

# JSON 里 & 转义为 \u0026, 必须还原, 不还原则签名参数截断, CDN 403 (实测)。
# 用 sed 还原而非 ${var//\\u0026/&}: bash ≥5.2 默认 patsub_replacement 把替换串
# 里的 & 当「匹配文本」, 该写法静默变 no-op (实测 24.04/44 容器复现), bash 5.1 又正常。
LINK="$(json_str download_link | sed 's/\\u0026/\&/g')"
API_VER="$(json_str version_number)"; API_VER="${API_VER##*@}"   # Linux-x64-deb@V7.72.23 → V7.72.23
MD5="$(json_str hash)"
if [ -z "$LINK" ] || [ -z "$API_VER" ] || [ -z "$MD5" ]; then
  echo "错误: API 响应缺 download_link/version_number/hash, 原始响应: $JSON" >&2
  exit 1
fi

if [ -n "$FEISHU_VERSION" ] && [ "${FEISHU_VERSION#[vV]}" != "${API_VER#[vV]}" ]; then
  echo "错误: 渠道当前版本 $API_VER 与 FEISHU_VERSION=$FEISHU_VERSION 不符 (该渠道仅提供最新版)" >&2
  exit 1
fi

echo "==> 下载飞书 $API_VER ($PKG, ~338MB)"
FILE="$TMP/Feishu-linux.$PKG"
curl -fsSL "$LINK" -o "$FILE"
echo "$MD5  $FILE" | md5sum -c -

case "$PKG" in
  deb) sudo apt-get install -y "$FILE" ;;
  rpm) sudo dnf install -y "$FILE" ;;
esac

# ---- Verification ----
# GUI 桌面应用, 容器/无显示环境无法启动属预期; 验证包登记 + 程序文件落地即可。
# 包名为 bytedance-feishu-stable 而非 'feishu' (dpkg-deb -f / rpm -qp 实证)。
case "$PKG" in
  deb)
    dpkg -s bytedance-feishu-stable | grep -E '^(Package|Version|Status):'
    test -x /opt/bytedance/feishu/feishu
    ;;
  rpm)
    rpm -q bytedance-feishu-stable
    test -x /usr/bin/bytedance-feishu-stable
    ;;
esac
find /usr/share/applications -maxdepth 1 -iname '*feishu*'
echo "已安装: 飞书 $API_VER (官方 $PKG 直装, 未注册任何软件源)"
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
DOTFILE_EOF_4
df_mod_base() {
  df_step 'sudo apt-get update -qq'
  df_step 'sudo apt-get install -y git htop btop tree curl jq gdu build-essential llvm clang cmake ninja-build'
  df_step 'git --version'
  df_step 'htop --version | head -1'
  df_step 'btop --version'
  df_step 'tree --version | head -1'
  df_step 'jq --version'
  df_step 'gdu --version'
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
  df_step 'curl -LsSf https://astral.sh/uv/install.sh | sh'
  df_step '$HOME/.local/bin/uv --version'
  df_step '$HOME/.local/bin/uvx --version'
}
df_mod_dev_cli() {
  df_step 'sudo apt-get install -y gh curl ca-certificates'
  df_step 'gh --version'
  df_step_embed "$DF_TMPDIR/script-02.sh" './scripts/install-feishu.sh'
  df_step '. $HOME/.nvm/nvm.sh && nvm use --silent default && npm install -g ntn hexo-cli'
  df_step '. $HOME/.nvm/nvm.sh && nvm use --silent default && ntn --version'
  df_step '. $HOME/.nvm/nvm.sh && nvm use --silent default && hexo version | head -3'
}
df_mod_tools() {
  df_step 'sudo apt-get install -y curl fzf'
  df_step 'fzf --version'
  df_step 'curl -fsSL -o /tmp/yazi.deb https://github.com/sxyazi/yazi/releases/latest/download/yazi-x86_64-unknown-linux-gnu.deb && sudo apt-get install -y /tmp/yazi.deb'
  df_step 'yazi --version'
  df_step 'ya --version'
}
df_mod_docker() {
  df_step 'sudo apt-get install -y curl ca-certificates'
  df_step_embed "$DF_TMPDIR/script-03.sh" './scripts/install-docker-debs.sh'
}
df_mod_cuda_toolkit() {
  df_step 'sudo apt-get install -y nvidia-cuda-toolkit'
  df_step 'nvcc --version | tail -2'
}
df_mod_oneapi() {
  df_step 'sudo apt-get install -y curl gnupg'
  df_step_embed "$DF_TMPDIR/script-04.sh" './scripts/setup-intel-repo.sh'
  df_step 'sudo apt-get install -y intel-oneapi-compiler-dpcpp-cpp'
}
df_mod_rocm() {
  df_step 'sudo apt-get install -y --no-install-recommends hipcc rocminfo rocm-smi'
  df_step 'hipcc --version | head -3'
}
df_mod_agentharness() {
  df_step '. $HOME/.nvm/nvm.sh && nvm use --silent default && npm install -g @anthropic-ai/claude-code @minimax-ai/code zcode-cli opencode-ai'
  df_step '. $HOME/.nvm/nvm.sh && nvm use --silent default && npm install -g --ignore-scripts @earendil-works/pi-coding-agent'
  df_step 'sudo apt-get install -y curl ca-certificates && curl -fsSL https://hermes-agent.nousresearch.com/install.sh | HERMES_HOME=$HOME/.agentharness/hermes bash'
  df_step 'mkdir -p $HOME/.agentharness/hermes/bin && mv $HOME/.local/bin/hermes $HOME/.agentharness/hermes/bin/hermes'
  df_step '$HOME/.agentharness/hermes/bin/hermes pm repair'
  df_step '. $HOME/.nvm/nvm.sh && nvm use --silent default && claude --version | head -1'
  df_step '. $HOME/.nvm/nvm.sh && nvm use --silent default && pi --version | head -1'
  df_step '. $HOME/.nvm/nvm.sh && nvm use --silent default && mcode --version | head -1'
  df_step '. $HOME/.nvm/nvm.sh && nvm use --silent default && zcode-cli --version | head -1'
  df_step '. $HOME/.nvm/nvm.sh && nvm use --silent default && opencode --version | head -1'
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
  # 注意: 键盘输入从 /dev/tty 读而非 stdin — curl|bash 时 stdin 是管道 (里面还躺着
  #       脚本剩余内容, gum 误读会吃掉脚本), /dev/tty 才是用户真正的终端
  DF_PICKED_RAW="$("$DF_GUM" choose --no-limit --ordered --output-delimiter $'\035' \
    --header "选择要安装的模块 (↑↓ 移动, x 勾选/取消, 回车确认) — 目标: debian@12" \
    --selected-prefix "[✅] " --unselected-prefix "[  ] " \
    --selected.foreground 2 --item.foreground 7 \
    --selected "${DF_DEFAULTS#,}" "${DF_ITEMS[@]}" < /dev/tty || true)"
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
  "$DF_GUM" confirm "安装 ${#DF_PICKED[@]} 个模块到 debian@12?" < /dev/tty || { info "已取消"; exit 0; }
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
