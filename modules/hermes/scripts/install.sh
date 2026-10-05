#!/usr/bin/env bash
# Hermes Agent 官方安装器 (hermes-agent.nousresearch.com)。
# 源码装到 ~/.hermes/hermes-agent, CLI 包装器放 ~/.local/bin/hermes;
# 安装器自带固定版 uv/Python/Node/ripgrep/ffmpeg, 不与系统冲突。
# 默认同时安装浏览器工具 (agent-browser + 固定 Chromium) 与 cua-driver;
# 服务器/容器等无桌面环境可设 HERMES_SKIP_BROWSER=1 跳过这两件。
set -euo pipefail

if [ "${HERMES_SKIP_BROWSER:-0}" = "1" ]; then
  echo "==> 运行 Hermes 官方安装器 (HERMES_SKIP_BROWSER=1: 跳过浏览器工具与 cua-driver)"
  curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash -s -- --skip-browser --skip-computer-use
else
  echo "==> 运行 Hermes 官方安装器"
  curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash -s --
fi

# ---- Verification ----
# 用意: 安装动作全在 curl|bash 进来的官方安装器里, 本段验证它到底装成了什么 —
# 用绝对路径调 CLI 包装器, 不依赖安装器刚写进 shell 配置的 PATH 在本进程生效。
# `hermes --version` 报的是安装检出的源码版本, 能正常输出即证明包装器
# (~/.local/bin/hermes)、源码检出 (~/.hermes/hermes-agent) 与其自带运行时
# (uv/Python/Node) 链路完整; 它附带的更新检查自带网络超时, 离线也能正常退出。
# 验证失败由 set -e 兜底, 让整个安装脚本失败。
"$HOME/.local/bin/hermes" --version
echo "已安装: $HOME/.local/bin/hermes (源码与运行时: $HOME/.hermes/hermes-agent)"
