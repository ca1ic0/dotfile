#!/usr/bin/env bash
# Starship 官方安装脚本, 装到用户目录 (无需 root)。
set -euo pipefail

DEST="$HOME/.local/bin" # 安装目的地, 下文 mkdir / --bin-dir / 验证三处引用

echo "==> 准备安装目录 $DEST"
mkdir -p "$DEST"

echo "==> 通过官方安装器安装 starship 到 $DEST"
curl -fsSL https://starship.rs/install.sh | sh -s -- --yes --bin-dir "$DEST"

# ---------------------------------------------------------------------------
# Verification — 确认脚本到底装成了什么
# 用意: starship 被装进用户目录 $DEST, 当前 shell 的 PATH 很可能尚未包含它,
# 因此按绝对路径直接执行二进制的 --version (不依赖 PATH / command -v 查找)。
# 若二进制缺失、损坏或架构不符, 该命令非零退出, set -e 让整个脚本失败;
# 成功则打印版本与落点。本模块没有配置 apt 源, 无需 apt-cache policy 验证。
echo "==> 验证安装"
"$DEST/starship" --version
echo "已安装: $DEST/starship"
