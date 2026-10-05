#!/usr/bin/env bash
# nvm (官方安装器) + 最新版 Node.js。
# nvm 装到 ~/.nvm 并把初始化写进 ~/.bashrc; 非交互 shell 需自行 source nvm.sh。
set -euo pipefail

export NVM_DIR="$HOME/.nvm"

# ---- 安装 ----
# METHOD=script: 用 curl 拉 tarball 而非 git clone (容器里 git 的 GnuTLS 常握手失败, 且少一个依赖)
echo "==> 安装 nvm"
curl -fsSL -o- https://raw.githubusercontent.com/nvm-sh/nvm/master/install.sh | METHOD=script bash

# nvm 是 shell 函数, 安装脚本不在交互 shell 里, 需手动加载后才能用
. "$NVM_DIR/nvm.sh"

echo "==> 安装最新版 Node.js"
nvm install node
nvm alias default node

# ---- Verification ----
nvm use --silent default
node --version
npm --version
