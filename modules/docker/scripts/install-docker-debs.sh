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
