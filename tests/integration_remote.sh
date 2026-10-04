#!/usr/bin/env bash
# 远程 docker 集成测试: 在远程服务器的 ubuntu 容器里真实执行生成的安装脚本。
# 用法: tests/integration_remote.sh   (可用环境变量覆盖 HOST/IMAGE/TARGET)
set -euo pipefail
cd "$(dirname "$0")/.."

HOST="${REMOTE_HOST:-100.108.141.76}"
IMAGE="${IMAGE:-ubuntu:24.04}"
TARGET="${TARGET:-ubuntu@24.04}"
SCRIPT="$(mktemp /tmp/dotfile-integration-XXXXXX.sh)"
trap 'rm -f "$SCRIPT"' EXIT

echo "==> 生成安装脚本 (--target $TARGET, 全部组)"
uv run python dotfile.py gen --target "$TARGET" --groups all -o "$SCRIPT"

# 容器以 root 运行但配方里显式写 sudo, 故先装 sudo;
# 安装脚本先物化到文件再执行 (cat 吃完管道到 EOF) — 否则 apt 的
# debconf 交互提示会从同一管道读走脚本的后续内容;
# \$HOME 转义: 由容器内 bash 展开 (装到容器用户的 ~/.local/bin)。
REMOTE_CMD="docker run --rm -i $IMAGE bash -c '
  apt-get update -qq </dev/null && apt-get install -y -qq sudo </dev/null \
  && cat > /tmp/dotfile-install.sh \
  && bash /tmp/dotfile-install.sh \
  && echo ---- 验证 ---- \
  && command -v git \
  && command -v jq \
  && command -v nvim \
  && \$HOME/.local/bin/starship --version \
  && \$HOME/.local/bin/gum --version \
  && \$HOME/.local/bin/gum spin --spinner dot --title smoke -- true \
  && echo gum-smoke-OK
'"

echo "==> 在 $HOST 的 $IMAGE 容器中真实执行"
ssh -o BatchMode=yes "$HOST" "$REMOTE_CMD" < "$SCRIPT"

echo "==> 集成测试通过: $TARGET @ $IMAGE"
