#!/usr/bin/env bash
# 配置 AMD ROCm 官方用户态 apt 源 (repo.radeon.com/rocm)。
#
# ROCm 用户态仓库只按 Ubuntu LTS 代号发布套件 (2026-10 时: jammy=22.04 / noble=24.04)。
# 更新的发行版 (如 26.04 resolute) 尚无专属套件 —— 该仓库是纯用户态二进制,
# 依赖 glibc 向后兼容, 回落到 noble 即可; 探测逻辑对将来新增的代号同样自适应。
# (内核态驱动 amdgpu-dkms 走另一仓库 repo.radeon.com/amdgpu, 容器/CI 无需。)
set -euo pipefail

REPO_URL="https://repo.radeon.com/rocm/apt/debian"
KEY_URL="https://repo.radeon.com/rocm/rocm.gpg.key"
# 套件探测次序: 本机代号优先, 之后按 新 → 旧 回落
FALLBACK_SUITES="noble jammy"

SUDO=""
[ "$(id -u)" = 0 ] || SUDO="sudo"

# 本机代号 (ubuntu: noble/resolute...; debian: bookworm/trixie...)
. /etc/os-release
CODENAME="${VERSION_CODENAME:-}"

pick_suite() {
  local s
  for s in "$CODENAME" $FALLBACK_SUITES; do
    [ -n "$s" ] || continue
    if command -v curl >/dev/null 2>&1 \
       && curl -fsSI --max-time 20 "$REPO_URL/dists/$s/Release" >/dev/null 2>&1; then
      echo "$s"
      return 0
    fi
  done
  # 探测不了 (离线/无 curl) 时按 2026-10 的仓库现状给缺省
  echo noble
}
SUITE="$(pick_suite)"

# 密钥为 ASCII armored 格式, apt >= 2.4 (jammy+) 的 signed-by 可直接引用, 无需 gpg 反装甲
$SUDO install -m 0755 -d /etc/apt/keyrings
KEYFILE="$(mktemp)"
trap 'rm -f "$KEYFILE"' EXIT
curl -fsSL "$KEY_URL" -o "$KEYFILE"
$SUDO install -m 0644 "$KEYFILE" /etc/apt/keyrings/rocm.asc

echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/rocm.asc] $REPO_URL $SUITE main" \
  | $SUDO tee /etc/apt/sources.list.d/rocm.list >/dev/null

# Ubuntu 26.04+ 的 universe 自带 ROCm 包 (rocminfo/hipcc 等, 版本号高于 AMD 仓库的),
# 会顶掉候选并打断 AMD 元包的精确版本依赖 (=x.y.z)。把 repo.radeon.com 钉到 1000
# (>=1000 允许降级), 保证 AMD 官方包始终优先; 不影响其它来源的包。
$SUDO tee /etc/apt/preferences.d/rocm > /dev/null <<'ROCM_PIN'
Package: *
Pin: origin "repo.radeon.com"
Pin-Priority: 1000
ROCM_PIN

echo "已配置 ROCm apt 源: suite=$SUITE (本机代号: ${CODENAME:-未知})"
