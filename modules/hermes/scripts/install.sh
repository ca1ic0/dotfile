#!/usr/bin/env bash
# Hermes Agent 官方安装器 (hermes-agent.nousresearch.com)。
# 源码装到 ~/.hermes/hermes-agent, CLI 包装器放 ~/.local/bin/hermes;
# 安装器自带固定版 uv/Python/Node/ripgrep/ffmpeg, 不与系统冲突。
# 默认同时安装浏览器工具 (agent-browser + 固定 Chromium) 与 cua-driver;
# 服务器/容器等无桌面环境可设 HERMES_SKIP_BROWSER=1 跳过这两件。
set -euo pipefail

args=""
if [ "${HERMES_SKIP_BROWSER:-0}" = "1" ]; then
  args="--skip-browser --skip-computer-use"
fi
# shellcheck disable=SC2086
curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash -s -- $args
