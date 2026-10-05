#!/usr/bin/env bash
# pi coding agent 官方安装器 (pi.dev), 需要前置 Node 22.19+ (由 nodejs 模块经 nvm 提供)。
# 安装到 ~/.pi/agent/bin, 自带固定版本依赖, pi update 自升级。
set -euo pipefail

# nvm 管理的 node 不在非交互 shell 的 PATH 里, 手动加载
export NVM_DIR="$HOME/.nvm"
. "$NVM_DIR/nvm.sh"
nvm use --silent default

# ---- 安装 ----
echo "==> 安装 pi coding agent"
curl -fsSL https://pi.dev/install.sh | sh

# ---- Verification ----
# pi 安装到 ~/.pi/agent/bin (安装器输出的 PATH 提示为准)
"$HOME/.pi/agent/bin/pi" --version
