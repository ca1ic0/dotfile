#!/usr/bin/env bash
# Astral uv 官方安装脚本, 装到 ~/.local/bin (无需 root)。
# 安装器会自动把 ~/.local/bin 写入 shell 配置的 PATH (幂等)。
set -euo pipefail
curl -LsSf https://astral.sh/uv/install.sh | sh
