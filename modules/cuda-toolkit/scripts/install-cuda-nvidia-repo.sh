#!/usr/bin/env bash
# CUDA Toolkit — NVIDIA 官方 debian13 仓库临时注册安装 (仅 ["debian@13"] 段使用)。
# trixie 档案库无 nvidia-cuda-toolkit (容器实证), 上游 debian13 仓可用。
# cuda-toolkit 元包依赖闭大多落在 NVIDIA 仓内, 本地 .deb 直装解不开依赖闭,
# 属 install-script 规范「依赖闭过大的元包子集可退回仓库形式」例外:
# 临时注册 → 安装 → 删除仓库文件退场 (keyring/pin 保留无害, 重装可复用)。
set -euo pipefail

# root 且无 sudo 二进制的环境 (容器常见): 透传 — 子进程里主脚本垫片不可见
if [ "$(id -u)" = 0 ] && ! command -v sudo >/dev/null 2>&1; then
  sudo() { "$@"; }
fi

REPO_BASE="https://developer.download.nvidia.com/compute/cuda/repos/debian13/x86_64"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# ---- 安装: 解析仓库索引取最新 cuda-keyring 包 → 注册源 → 装 toolkit ----
echo "==> 解析 NVIDIA debian13 仓库索引"
curl -fsSL "$REPO_BASE/Packages.gz" -o "$TMP/Packages.gz"
deb="$(gunzip -c "$TMP/Packages.gz" | awk '
  $1 == "Package:" { cur = $2 }
  $1 == "Filename:" && cur == "cuda-keyring" { fn = $2 }
  END { print fn }')"
if [ -z "$deb" ]; then
  echo "错误: 索引中找不到 cuda-keyring (仓库布局可能已变)" >&2
  exit 1
fi

echo "==> 安装 $deb (注册官方源 + 密钥 + pin)"
curl -fsSL "$REPO_BASE/$deb" -o "$TMP/cuda-keyring.deb"
sudo dpkg -i "$TMP/cuda-keyring.deb"
sudo apt-get update

echo "==> 安装 cuda-toolkit 元包 (跟随最新大版本, 不含驱动)"
sudo apt-get install -y cuda-toolkit

# ---- 退场: 移除仓库注册 (不再从 NVIDIA 拉任何东西; keyring/pin 留存无害) ----
sudo rm -f /etc/apt/sources.list.d/cuda-*.list
sudo apt-get update

# ---- Verification ----
# nvcc 落 /usr/local/cuda/bin (NVIDIA 仓包布局, 档案库版同路径)。
/usr/local/cuda/bin/nvcc --version | tail -2
echo "已安装: CUDA Toolkit (NVIDIA debian13 官方仓, 注册已移除)"
