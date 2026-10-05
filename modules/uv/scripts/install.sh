#!/usr/bin/env bash
# Astral uv 官方安装脚本, 装到 ~/.local/bin (无需 root)。
# 安装器会自动把 ~/.local/bin 写入 shell 配置的 PATH (幂等)。
set -euo pipefail

# 版本/目录均由官方安装器决定, 本脚本无使用者可调旋钮, 故不设变量。
# 本脚本全程不需要提权 (落点在 $HOME 下), 无需 sudo 垫片。

echo "==> 运行 Astral uv 官方安装器"
curl -LsSf https://astral.sh/uv/install.sh | sh

# ---- Verification ----
# 用意: 安装器把 uv 和 uvx 落在 ~/.local/bin, 但当前 shell 的 PATH 要重开
# 终端才可能生效, 所以这里用绝对路径直接执行 --version, 确认二进制真的
# 落地且可运行, 而不是只听安装器自己汇报「装好了」。任何一步失败都由
# 开头的 set -e 让整个脚本以非零退出。
echo "==> 验证安装结果"
"$HOME/.local/bin/uv" --version
"$HOME/.local/bin/uvx" --version
echo "已安装: $HOME/.local/bin/uv, $HOME/.local/bin/uvx"
