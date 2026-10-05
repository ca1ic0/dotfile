#!/usr/bin/env bash
# MiniMax Code CLI (npm: @minimax-ai/code), 提供 mcode / mcode-tools 命令。
# node/npm 由 nodejs 模块经 nvm 提供, 非交互 shell 需手动加载。
set -euo pipefail

export NVM_DIR="$HOME/.nvm"
. "$NVM_DIR/nvm.sh"
nvm use --silent default

# ---- 安装 ----
npm install -g @minimax-ai/code

# ---- Verification ----
mcode --version
