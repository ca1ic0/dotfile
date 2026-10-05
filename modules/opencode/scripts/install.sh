#!/usr/bin/env bash
# opencode 官方安装器 (opencode.ai)。
set -euo pipefail

# ---- 安装 ----
echo "==> 安装 opencode"
curl -fsSL https://opencode.ai/install | bash

# ---- Verification ----
# opencode 安装到 ~/.opencode/bin (安装器输出为准)
"$HOME/.opencode/bin/opencode" --version
