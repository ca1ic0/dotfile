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
