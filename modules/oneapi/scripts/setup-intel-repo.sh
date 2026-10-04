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
