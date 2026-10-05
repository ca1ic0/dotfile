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

echo "==> 安装 GPG keyring 到 /etc/apt/keyrings/docker.asc"
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL "https://download.docker.com/linux/${REPO_ID}/gpg" -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc

echo "==> 写入 deb822 源文件 /etc/apt/sources.list.d/docker.sources"
sudo tee /etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/${REPO_ID}
Suites: ${CODENAME}
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
EOF

echo "==> apt-get update 刷新索引"
sudo apt-get update

# ---------------------------------------------------------------------------
# Verification — 确认脚本到底配置成了什么
# 用意: 本脚本只配源、不装包, 没有二进制可跑 --version, 验证对象是「源已生效」:
#   1. keyring 与 deb822 源文件确实落盘且非空;
#   2. apt-cache policy 查本模块要装的主包 docker-ce, 完整 policy 输出先原样
#      打印, 再 grep 断言版本表里出现 download.docker.com/linux/${REPO_ID}
#      的条目 — 即 apt 真的从这个源拿到了 docker-ce 的候选版本。若 suite/
#      component/arch 配错, update 阶段拿不到该源的 Packages 索引 (apt-get
#      update 对个别索引失败可能只发 warning 仍以 0 退出, 所以不能只靠它
#      的退出码), 这里就匹配不到, grep 非零退出, 由开头的 set -e 让整个
#      脚本失败。grep 命中的源条目直接打印留档, 不吞任何输出。
echo "==> 验证 Docker 源已生效"
test -s /etc/apt/keyrings/docker.asc
test -s /etc/apt/sources.list.d/docker.sources
POLICY="$(apt-cache policy docker-ce)"
echo "$POLICY"
echo "$POLICY" | grep -F "https://download.docker.com/linux/${REPO_ID}"
echo "已配置: Docker 官方 apt 源 (linux/${REPO_ID}, suite=${CODENAME}, keyring=/etc/apt/keyrings/docker.asc)"
