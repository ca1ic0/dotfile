#!/usr/bin/env bash
# 飞书 (Feishu) 桌面版离线安装: 运行时调官方 package_info API 解析下载直链,
# 下载安装包后本地安装 (deb: apt-get install ./file, rpm: dnf install ./file),
# 不注册任何软件源。
# 官方无 apt/dnf 仓库 (www.feishu.cn/download 为 JS SPA, 无静态包链接); 真实
# 下载链由页面 JS 调 https://www.feishu.cn/api/package_info?platform=<N> 取得,
# 是带 x-signature/x-expires 的短时效签名 CDN 直链 (实测约 30 分钟过期, CDN
# 域名与哈希目录随版本变), 无法离线拼接稳定 URL, 只能装时现取。
set -euo pipefail

# root 且无 sudo 二进制的环境 (容器常见): 透传 — 子进程里主脚本垫片不可见
if [ "$(id -u)" = 0 ] && ! command -v sudo >/dev/null 2>&1; then
  sudo() { "$@"; }
fi

. /etc/os-release   # 本脚本在子进程执行, 主脚本的 os-release 变量传不进来, 必须自行加载

# 版本 pin 旋钮: 缺省空 = 装 API 当前返回的最新版; 设置时 (如 7.72.23, 带不带
# V 均可) 先与 API 版本比对, 不一致即失败 — 免得白下 ~338MB 才发现版本不符。
# 注意该渠道只有「最新版」一个候选, 无法按版本号点装历史版本。
FEISHU_VERSION="${FEISHU_VERSION:-}"

# 平台枚举 (取自官方 download JS): 10=x64-deb 11=x64-rpm 12=arm64-deb 13=arm64-rpm
case "${ID:-}/$(uname -m)" in
  debian/x86_64|ubuntu/x86_64)   PLATFORM=10; PKG=deb ;;
  debian/aarch64|ubuntu/aarch64) PLATFORM=12; PKG=deb ;;
  fedora/x86_64)                 PLATFORM=11; PKG=rpm ;;
  fedora/aarch64)                PLATFORM=13; PKG=rpm ;;
  *) echo "错误: 不支持的目标 ${ID:-未知}/$(uname -m) (仅 debian/ubuntu/fedora 的 x64/arm64)" >&2; exit 1 ;;
esac

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

json_str() {  # $1=键名: 从 API 响应提取字符串值 (实测为单行紧凑 JSON)
  printf '%s' "$JSON" | grep -oE "\"$1\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" | head -1 \
    | sed -E 's/^.*:[[:space:]]*"(.*)"$/\1/'
}

# ---- 安装: 调 API → 还原转义 → 下载 → md5 校验 → 本地安装 ----
echo "==> 调官方 package_info API (platform=$PLATFORM)"
JSON="$(curl -fsSL "https://www.feishu.cn/api/package_info?platform=$PLATFORM")"

# JSON 里 & 转义为 \u0026, 必须还原, 不还原则签名参数截断, CDN 403 (实测)。
# 用 sed 还原而非 ${var//\\u0026/&}: bash ≥5.2 默认 patsub_replacement 把替换串
# 里的 & 当「匹配文本」, 该写法静默变 no-op (实测 24.04/44 容器复现), bash 5.1 又正常。
LINK="$(json_str download_link | sed 's/\\u0026/\&/g')"
API_VER="$(json_str version_number)"; API_VER="${API_VER##*@}"   # Linux-x64-deb@V7.72.23 → V7.72.23
MD5="$(json_str hash)"
if [ -z "$LINK" ] || [ -z "$API_VER" ] || [ -z "$MD5" ]; then
  echo "错误: API 响应缺 download_link/version_number/hash, 原始响应: $JSON" >&2
  exit 1
fi

if [ -n "$FEISHU_VERSION" ] && [ "${FEISHU_VERSION#[vV]}" != "${API_VER#[vV]}" ]; then
  echo "错误: 渠道当前版本 $API_VER 与 FEISHU_VERSION=$FEISHU_VERSION 不符 (该渠道仅提供最新版)" >&2
  exit 1
fi

echo "==> 下载飞书 $API_VER ($PKG, ~338MB)"
FILE="$TMP/Feishu-linux.$PKG"
curl -fsSL "$LINK" -o "$FILE"
echo "$MD5  $FILE" | md5sum -c -

case "$PKG" in
  deb) sudo apt-get install -y "$FILE" ;;
  rpm) sudo dnf install -y "$FILE" ;;
esac

# ---- Verification ----
# GUI 桌面应用, 容器/无显示环境无法启动属预期; 验证包登记 + 程序文件落地即可。
# 包名为 bytedance-feishu-stable 而非 'feishu' (dpkg-deb -f / rpm -qp 实证)。
case "$PKG" in
  deb)
    dpkg -s bytedance-feishu-stable | grep -E '^(Package|Version|Status):'
    test -x /opt/bytedance/feishu/feishu
    ;;
  rpm)
    rpm -q bytedance-feishu-stable
    test -x /usr/bin/bytedance-feishu-stable
    ;;
esac
find /usr/share/applications -maxdepth 1 -iname '*feishu*'
echo "已安装: 飞书 $API_VER (官方 $PKG 直装, 未注册任何软件源)"
