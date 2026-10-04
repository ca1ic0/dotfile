#!/usr/bin/env bash
# ROCm 链接器兼容垫片 (仅 noble 回落环境需要; 依赖完整时零动作)。
#
# 背景: AMD 仓库目前只发布 22.04/24.04 套件, 更新的发行版回落用 noble 的包
# (见 setup-rocm-repo.sh)。其中 rocm-llvm 的 lld 在 24.04 上构建, 运行期依赖
# libxml2.so.2 (连带 libicuuc.so.74); Ubuntu 26.04 把 libxml2 升到 soname 16
# 且不再提供旧运行库, 于是 hipcc 编译任何含 device code 的源文件都会在
# amdgcn-link 阶段报 "libxml2.so.2: cannot open shared object file"。
#
# 处理: 从 Ubuntu 官方 pool 解包 (dpkg-deb -x, 不安装包) 这两组运行库到
# /usr/lib/x86_64-linux-gnu —— 与 soname 16 的新 libxml2 同机共存, 无侵入。
# 垫片属于尽力而为: 下载失败只告警不阻断安装 (hipcc/rocminfo 二进制不受影响)。
set -euo pipefail

LIBDIR=/usr/lib/x86_64-linux-gnu
XML2_DEB="https://archive.ubuntu.com/ubuntu/pool/main/libx/libxml2/libxml2_2.9.14+dfsg-1.3ubuntu3_amd64.deb"
ICU_DEB="https://archive.ubuntu.com/ubuntu/pool/main/i/icu/libicu74_74.2-1ubuntu3.1_amd64.deb"

LLD="/opt/rocm/lib/llvm/bin/lld"
[ -x "$LLD" ] || { echo "rocm: 未找到 $LLD, 跳过链接器兼容检查"; exit 0; }

if ! ldd "$LLD" 2>/dev/null | grep -q 'libxml2.so.2.*not found'; then
  echo "rocm: 链接器依赖完整 (libxml2.so.2 可用), 无需兼容垫片"
  exit 0
fi

SUDO=""
[ "$(id -u)" = 0 ] || SUDO="sudo"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fetch_extract() {  # $1=deb URL  $2=要拷贝的文件 glob
  local name; name="$(basename "$1")"
  curl -fsSL --retry 2 -o "$TMP/$name" "$1" \
    || { echo "rocm 兼容垫片: 下载失败 $name (跳过)" >&2; return 1; }
  dpkg-deb -x "$TMP/$name" "$TMP/x" || return 1
  $SUDO cp -a "$TMP"/x"$LIBDIR"/$2 "$LIBDIR"/ || return 1
}

# shellcheck disable=SC2015
fetch_extract "$XML2_DEB" 'libxml2.so.2*' \
  && fetch_extract "$ICU_DEB" 'libicu*.so.74*' \
  && $SUDO ldconfig \
  || { echo "rocm 兼容垫片: 未能补齐 libxml2.so.2/libicu74 — hipcc 编译 device code 可能失败 (hipcc/rocminfo 二进制不受影响)" >&2; exit 0; }

if ldd "$LLD" 2>/dev/null | grep -q 'not found'; then
  echo "rocm 兼容垫片: 补齐后 lld 仍缺库:" >&2
  ldd "$LLD" 2>/dev/null | grep 'not found' >&2 || true
  exit 0
fi
echo "rocm: 已补齐 lld 运行库 (libxml2.so.2 + libicu74), hipcc 链接可用"
