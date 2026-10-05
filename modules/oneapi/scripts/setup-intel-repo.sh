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
# 即 apt-cache policy 在 intel-basekit (oneAPI Base Toolkit 元包, 此源必有) 的版本表里
# 列出 https://apt.repos.intel.com/oneapi 的候选版本。看不到说明 keyring/list 有误,
# 立即 exit 1 让整条安装链失败, 而不是留下一个看似成功的坏源。
echo "==> Verification: apt-cache policy intel-basekit"
policy="$(apt-cache policy intel-basekit)"
echo "$policy"
if ! grep -qF 'https://apt.repos.intel.com/oneapi' <<<"$policy"; then
  echo "错误: apt-cache policy intel-basekit 未看到来自 https://apt.repos.intel.com/oneapi 的候选版本, Intel 源未生效" >&2
  exit 1
fi
echo "已配置: /etc/apt/sources.list.d/oneapi.list (keyring: ${KEYRING})"
