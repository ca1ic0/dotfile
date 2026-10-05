#!/usr/bin/env bash
# 全局安装 hexo-cli。
# node/npm 由 nodejs 模块经 nvm 提供 (装在用户目录, npm -g 无需提权);
# 非交互 shell 不加载 ~/.bashrc, 需手动 source nvm。
set -euo pipefail

export NVM_DIR="$HOME/.nvm"
. "$NVM_DIR/nvm.sh"
nvm use --silent default

echo "==> 全局安装 hexo-cli"
npm install -g hexo-cli

# --- Verification ---
# hexo-cli 经 npm -g 安装到 nvm 的用户级 bin (已在上文加入 PATH), 命令名是 hexo。
# 能打印 hexo-cli / Node 版本即证明安装落点生效、二进制可执行; set -e 兜底。
echo "==> 验证: hexo version"
hexo version
echo "已安装: hexo-cli (npm -g: $(command -v hexo))"
