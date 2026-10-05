#!/usr/bin/env bash
# ZCode CLI (npm: zcode-cli), GLM 模型的官方终端智能体入口。
# node/npm 由 nodejs 模块经 nvm 提供, 非交互 shell 需手动加载。
set -euo pipefail

export NVM_DIR="$HOME/.nvm"
. "$NVM_DIR/nvm.sh"
nvm use --silent default

# ---- 安装 ----
npm install -g zcode-cli

# ---- Verification ----
zcode-cli --version
