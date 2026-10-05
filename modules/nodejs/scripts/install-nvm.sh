#!/usr/bin/env bash
# nvm (官方安装器) + 最新版 Node.js。
# nvm 装到 ~/.nvm 并把初始化写进 ~/.bashrc; 非交互 shell 需自行 source nvm.sh。
set -euo pipefail

NVM_VERSION="${NVM_VERSION:-v0.40.8}" # 上游 README 的安装示例均 pin release tag, 不追 master
export NVM_DIR="$HOME/.nvm"

# ---- 安装 ----
echo "==> 安装 nvm $NVM_VERSION"
# METHOD=script: 用 curl 拉 tarball 而非 git clone (容器里 git 的 GnuTLS 常握手失败, 且少一个依赖)
curl -fsSL -o- "https://raw.githubusercontent.com/nvm-sh/nvm/$NVM_VERSION/install.sh" | METHOD=script bash

# nvm 是 shell 函数, 安装脚本不在交互 shell 里, 需手动加载后才能用;
# 其函数体内存在未定义变量路径 (如远程索引不可达时的版本解析), set -u 会在
# 函数调用时误杀 (STABLE: unbound variable) — 整个 nvm 交互区临时关闭 -u
set +u
. "$NVM_DIR/nvm.sh"

echo "==> 安装最新版 Node.js"
nvm install node
nvm alias default node
set -u

# ---- Verification ----
# node/npm 由本进程 nvm use 挂上 PATH, 失败由 set -e 拦截; 成功打印实际落点。
echo "==> 验证安装结果"
nvm use --silent default
node --version
npm --version
echo "已安装: $(command -v node) ($(node --version))"
