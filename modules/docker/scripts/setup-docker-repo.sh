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
