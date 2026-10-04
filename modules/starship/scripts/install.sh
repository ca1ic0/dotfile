#!/usr/bin/env bash
# Starship 官方安装脚本, 装到用户目录 (无需 root)。
set -euo pipefail
mkdir -p "$HOME/.local/bin"
curl -fsSL https://starship.rs/install.sh | sh -s -- --yes --bin-dir "$HOME/.local/bin"
