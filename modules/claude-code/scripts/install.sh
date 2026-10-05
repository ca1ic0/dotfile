#!/usr/bin/env bash
# Anthropic Claude Code 官方原生安装器 (claude.ai/install.sh)。
# 安装到 ~/.local/bin/claude, 不依赖 Node.js; 装完运行 claude 后 /login 认证。
set -euo pipefail

# ---- 安装 ----
echo "==> 安装 Claude Code (原生安装器)"
curl -fsSL https://claude.ai/install.sh | bash

# ---- Verification ----
"$HOME/.local/bin/claude" --version
