#!/usr/bin/env bash
# 由 dotfile 生成器产出 — 请勿手改; 变更请回到仓库重新 gen
# 生成命令: ./dotfile.py gen --all
set -euo pipefail

EXPECTED_ID="ubuntu"
EXPECTED_VERSION="22.04"

df_usage() {
  echo "用法: bash $0 [--dry-run] [--force]"
  echo "  --dry-run  只打印将执行的动作, 不实际执行"
  echo "  --force    跳过目标发行版复核"
}

DF_DRY_RUN=0
DF_FORCE=0
for df_arg in "$@"; do
  case "$df_arg" in
    --dry-run) DF_DRY_RUN=1 ;;
    --force)   DF_FORCE=1 ;;
    -h|--help) df_usage; exit 0 ;;
    *) printf '未知参数: %s (支持 --dry-run / --force)\n' "$df_arg" >&2; exit 2 ;;
  esac
done

if [ -t 2 ] && [ "${TERM:-}" != "dumb" ]; then
  DF_C_INFO='\033[1;32m'; DF_C_MOD='\033[1;36m'; DF_C_ERR='\033[1;31m'; DF_C_OFF='\033[0m'
else
  DF_C_INFO=''; DF_C_MOD=''; DF_C_ERR=''; DF_C_OFF=''
fi
info() { printf "${DF_C_INFO}==> %s${DF_C_OFF}\n" "$*"; }
mod()  { printf "\n${DF_C_MOD}==== %s ====${DF_C_OFF}\n" "$1"; }
err()  { printf "${DF_C_ERR}错误: %s${DF_C_OFF}\n" "$*" >&2; }

DF_TMPDIR="$(mktemp -d "${TMPDIR:-/tmp}/dotfile-XXXXXX")"
on_exit() {
  df_ret=$?
  rm -rf "$DF_TMPDIR"
  if [ "$df_ret" -ne 0 ]; then
    err "安装失败 (exit $df_ret) — 出错模块: ${DOTFILES_MODULE:-<初始化>}"
  fi
  exit "$df_ret"
}
trap on_exit EXIT

df_ver_prefix_ok() {
  # $1=期望前缀(22.04) $2=实际(22.04.5): 逐段比较, 数值不等或实际过短即失败
  local IFS='.'
  local -a df_exp df_act
  read -r -a df_exp <<<"$1"
  read -r -a df_act <<<"$2"
  local df_i
  for df_i in "${!df_exp[@]}"; do
    [ "${df_act[df_i]:-x}" = "${df_exp[df_i]}" ] || return 1
  done
  return 0
}

df_run() {
  info "  \$ $1"
  if [ "$DF_DRY_RUN" -eq 1 ]; then return 0; fi
  eval "$1"
}

# ---- 目标复核 -------------------------------------------------------------
if [ ! -r /etc/os-release ]; then
  err "读不到 /etc/os-release, 无法确认本机是否为生成目标 $EXPECTED_ID"
  [ "$DF_FORCE" -eq 1 ] || exit 1
  info "(--force) 跳过复核"
else
  . /etc/os-release
  if [ "${ID:-}" != "$EXPECTED_ID" ]; then
    err "本机发行版为 ${ID:-未知}, 而本脚本为 $EXPECTED_ID 生成"
    [ "$DF_FORCE" -eq 1 ] || exit 1
    info "(--force) 强制继续"
  elif [ -n "$EXPECTED_VERSION" ] && [ -n "${VERSION_ID:-}" ] \
    && ! df_ver_prefix_ok "$EXPECTED_VERSION" "$VERSION_ID"; then
    err "本机版本为 ${VERSION_ID}, 而本脚本按 $EXPECTED_VERSION 生成 (配方可能不适用)"
    [ "$DF_FORCE" -eq 1 ] || exit 1
    info "(--force) 强制继续"
  fi
fi

export DOTFILES_DISTRO="ubuntu@22.04"
export DOTFILES_FAMILY="debian"

# ---- 概览 -----------------------------------------------------------------
info "目标: ubuntu@22.04 (family: debian)"
info "模块: essentials, git"
info "组:   base"

# ---- 安装 -----------------------------------------------------------------
mod 'essentials — 常用 CLI 工具: htop/tree/curl/jq'
export DOTFILES_MODULE='essentials'
info "配方段: debian"
df_run 'sudo apt-get install -y htop tree curl jq'

mod 'git — Git 版本控制'
export DOTFILES_MODULE='git'
info "配方段: debian"
df_run 'sudo apt-get install -y git'

# ---- 汇总 -----------------------------------------------------------------
info "完成: 2 个模块 (组: base)"
