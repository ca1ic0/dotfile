#!/usr/bin/env bash
# 由 dotfile 生成器产出 — 请勿手改; 变更请回到仓库重新 gen
# 生成命令: ./dotfile.py gen --all
set -euo pipefail

EXPECTED_ID="ubuntu"
EXPECTED_VERSION="24.04"

df_usage() {
  echo "用法: bash $0 [--dry-run] [--yes] [--no-tui] [--force]"
  echo "  --dry-run  只打印将执行的动作, 不实际执行"
  echo "  --yes      跳过交互选择, 安装脚本内全部模块"
  echo "  --no-tui   不用 TUI, 逐行日志输出 (非终端自动生效)"
  echo "  --force    跳过目标发行版复核"
}

DF_DRY_RUN=0
DF_FORCE=0
DF_ASSUME_YES=0
DF_NO_TUI=0
for df_arg in "$@"; do
  case "$df_arg" in
    --dry-run) DF_DRY_RUN=1 ;;
    --force)   DF_FORCE=1 ;;
    --yes|-y)  DF_ASSUME_YES=1 ;;
    --no-tui)  DF_NO_TUI=1 ;;
    -h|--help) df_usage; exit 0 ;;
    *) printf '未知参数: %s (支持 --dry-run/--yes/--no-tui/--force)\n' "$df_arg" >&2; exit 2 ;;
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

DF_TMPBASE="${TMPDIR:-/tmp}"; DF_TMPBASE="${DF_TMPBASE%/}"
DF_TMPDIR="$(mktemp -d "$DF_TMPBASE/dotfile-XXXXXX")"
DF_LOG="$DF_TMPBASE/dotfile-install-$$.log"   # 退出后保留
: > "$DF_LOG"
export DF_LOG
DF_RUNNER="$DF_TMPDIR/runner.sh"
cat > "$DF_RUNNER" <<'DF_RUNNER_EOF'
#!/usr/bin/env bash
# gum spin 的命令包装: 输出全部收进日志文件
exec >>"$DF_LOG" 2>&1
eval "$1"
DF_RUNNER_EOF

on_exit() {
  df_ret=$?
  rm -rf "$DF_TMPDIR"
  if [ "$df_ret" -ne 0 ]; then
    err "安装失败 (exit $df_ret) — 出错模块: ${DOTFILES_MODULE:-<初始化>}; 日志: $DF_LOG"
  fi
  exit "$df_ret"
}
trap on_exit EXIT

df_ver_prefix_ok() {
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

# ---- TUI 依赖引导 (gum 为必须依赖, 自动安装) --------------------------------
DF_GUM=""
df_ensure_curl() {
  command -v curl >/dev/null 2>&1 && return 0
  local df_s=""
  [ "$(id -u)" = 0 ] || df_s="sudo"
  case "debian" in
    debian) $df_s apt-get update -qq </dev/null; $df_s apt-get install -y curl </dev/null ;;
    redhat) $df_s dnf install -y curl ;;
    arch)   $df_s pacman -Sy --noconfirm curl ;;
  esac >>"$DF_LOG" 2>&1
  command -v curl >/dev/null 2>&1
}
df_ensure_gum() {
  command -v gum >/dev/null 2>&1 && { DF_GUM="$(command -v gum)"; return 0; }
  df_ensure_curl || { info "gum: 无法准备 curl, TUI 不可用"; return 1; }
  local df_arch
  case "$(uname -s)/$(uname -m)" in
    Linux/x86_64)  df_arch="x86_64" ;;
    Linux/aarch64) df_arch="arm64" ;;
    *) info "gum: 不支持的平台 $(uname -s)/$(uname -m), TUI 不可用"; return 1 ;;
  esac
  local df_ver
  df_ver="${GUM_VERSION:-$(curl -fsSL https://api.github.com/repos/charmbracelet/gum/releases/latest 2>/dev/null | sed -n 's/.*"tag_name": *"\(v[0-9][0-9.]*\)".*/\1/p' | head -1)}"
  [ -n "$df_ver" ] || { info "gum: 无法获取版本号 (可用 GUM_VERSION=v0.x.y 固定)"; return 1; }
  mkdir -p "$HOME/.local/bin"
  local df_t="$(mktemp -d "$DF_TMPDIR/gum-XXXXXX")"
  local df_url="https://github.com/charmbracelet/gum/releases/download/${df_ver}/gum_${df_ver#v}_Linux_${df_arch}.tar.gz"
  curl -fsSL "$df_url" | tar -xz -C "$df_t" >>"$DF_LOG" 2>&1 || { info "gum: 下载失败"; return 1; }
  mv "$df_t"/gum_*/gum "$HOME/.local/bin/gum" || { info "gum: 解包失败"; return 1; }
  DF_GUM="$HOME/.local/bin/gum"
  info "已自动安装 TUI 依赖 gum $df_ver -> $DF_GUM"
}
df_ensure_gum || true

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

export DOTFILES_DISTRO="ubuntu@24.04"
export DOTFILES_FAMILY="debian"

DF_TUI_PROG=0
DF_TUI_SEL=0
if [ -n "$DF_GUM" ] && [ "$DF_NO_TUI" -eq 0 ] && [ "$DF_DRY_RUN" -eq 0 ] && [ -t 1 ]; then
  DF_TUI_PROG=1
fi
if [ "$DF_TUI_PROG" -eq 1 ] && [ "$DF_ASSUME_YES" -eq 0 ] && [ -t 0 ]; then
  DF_TUI_SEL=1
fi

# ---- 执行原语 -------------------------------------------------------------
df_module_header() {  # $1=模块名 $2=配方段
  local d=""
  eval "d="\$df_desc_$1""
  if [ "$DF_TUI_PROG" -eq 1 ]; then
    "$DF_GUM" style --bold --foreground 51 "── $1 · $d"
  else
    mod "$1 — $d"
    info "配方段: $2"
  fi
}

df_fail() {  # $1=步骤描述
  if [ "$DF_TUI_PROG" -eq 1 ]; then
    "$DF_GUM" style --bold --foreground 196 "  ✗ $1"
    "$DF_GUM" style --foreground 245 "-- 日志尾部 ($DF_LOG):"
    tail -n 15 "$DF_LOG" | "$DF_GUM" style --foreground 245
  else
    err "步骤失败: $1 (日志: $DF_LOG)"
    tail -n 15 "$DF_LOG" >&2 || true
  fi
  exit 1
}

df_step() {  # $1=命令字符串
  if [ "$DF_DRY_RUN" -eq 1 ]; then info "  \$ $1"; return 0; fi
  if [ "$DF_TUI_PROG" -eq 1 ]; then
    "$DF_GUM" spin --spinner dot --title "$1" -- bash "$DF_RUNNER" "$1" \
      || df_fail "$1"
    "$DF_GUM" style --foreground 46 "  ✓ $1"
  else
    info "  \$ $1"
    eval "$1"
  fi
}

df_step_embed() {  # $1=脚本临时路径 $2=展示名
  if [ "$DF_DRY_RUN" -eq 1 ]; then info "  \$ bash <$2>"; return 0; fi
  if [ "$DF_TUI_PROG" -eq 1 ]; then
    "$DF_GUM" spin --spinner dot --title "bash <$2>" -- bash "$1" \
      || df_fail "bash <$2>"
    "$DF_GUM" style --foreground 46 "  ✓ bash <$2>"
  else
    info "  \$ bash <$2> (嵌入脚本)"
    bash "$1"
  fi
}

# ---- 模块注册表 (生成) ----------------------------------------------------
DF_MODULES=(essentials git neovim starship)
df_desc_essentials='常用 CLI 工具: htop/tree/curl/jq'
df_requires_essentials=''
DF_SECTION_essentials='debian'
df_desc_git='Git 版本控制'
df_requires_git=''
DF_SECTION_git='debian'
df_desc_neovim='Neovim 编辑器 + 常用依赖'
df_requires_neovim=''
DF_SECTION_neovim='debian'
df_desc_starship='Starship 终端提示符 (官方脚本安装到 ~/.local/bin)'
df_requires_starship=''
DF_SECTION_starship='debian'
cat > "$DF_TMPDIR/script-01.sh" <<'DOTFILE_EOF_1'
#!/usr/bin/env bash
# Starship 官方安装脚本, 装到用户目录 (无需 root)。
set -euo pipefail
mkdir -p "$HOME/.local/bin"
curl -fsSL https://starship.rs/install.sh | sh -s -- --yes --bin-dir "$HOME/.local/bin"
DOTFILE_EOF_1
df_mod_essentials() {
  df_step 'sudo apt-get install -y htop tree curl jq'
}
df_mod_git() {
  df_step 'sudo apt-get install -y git'
}
df_mod_neovim() {
  df_step 'sudo apt-get install -y neovim ripgrep fd-find curl'
}
df_mod_starship() {
  df_step 'sudo apt-get install -y curl'
  df_step_embed "$DF_TMPDIR/script-01.sh" './scripts/install.sh'
}


# ---- 交互选择 (TTY + gum; 否则安装全部) ------------------------------------
df_pick_name() {  # "name — desc" -> name
  local df_item="$1" df_n
  for df_n in "${DF_MODULES[@]}"; do
    case "$df_item" in
      "$df_n"|"$df_n — "*) echo "$df_n"; return 0 ;;
    esac
  done
  return 1
}

df_check_requires() {  # 参数: 已选模块名列表
  local df_sel=" $* " df_n df_deps df_dep
  for df_n in "$@"; do
    eval "df_deps=\"\$df_requires_$df_n\""
    for df_dep in $df_deps; do
      case "$df_sel" in
        *" $df_dep "*) ;;
        *) err "模块 $df_n 依赖 $df_dep, 但其未被选择"; exit 1 ;;
      esac
    done
  done
}

DF_PICKED=()
if [ "$DF_TUI_SEL" -eq 1 ]; then
  DF_ITEMS=()
  DF_DEFAULTS=""
  for df_n in "${DF_MODULES[@]}"; do
    eval "df_d=\"\$df_desc_$df_n\""
    DF_ITEMS+=("$df_n — $df_d")
    DF_DEFAULTS="$DF_DEFAULTS,$df_n — $df_d"
  done
  # 注意: gum 的 TUI 渲染在 stderr, 结果走 stdout — 不能重定向 stderr, 否则界面不可见
  DF_PICKED_RAW="$("$DF_GUM" choose --no-limit \
    --header "选择要安装的模块 (空格勾选, 回车确认) — 目标: ubuntu@24.04" \
    --selected "${DF_DEFAULTS#,}" "${DF_ITEMS[@]}" || true)"
  if [ -z "$DF_PICKED_RAW" ]; then
    info "未选择任何模块, 退出"
    exit 0
  fi
  while IFS= read -r df_line; do
    [ -n "$df_line" ] && DF_PICKED+=("$(df_pick_name "$df_line")")
  done <<<"$DF_PICKED_RAW"
  df_check_requires "${DF_PICKED[@]}"
  "$DF_GUM" confirm "安装 ${#DF_PICKED[@]} 个模块到 ubuntu@24.04?" || { info "已取消"; exit 0; }
else
  DF_PICKED=("${DF_MODULES[@]}")
fi


# ---- 安装 -----------------------------------------------------------------
for df_m in "${DF_PICKED[@]}"; do
  export DOTFILES_MODULE="$df_m"
  eval "df_sec=\"\$DF_SECTION_$df_m\""
  df_module_header "$df_m" "$df_sec"
  "df_mod_$df_m"
done

# ---- 汇总 -----------------------------------------------------------------
if [ "$DF_TUI_PROG" -eq 1 ]; then
  "$DF_GUM" style --border rounded --padding 0 1 --foreground 46 \
    "完成: ${#DF_PICKED[@]} 个模块   日志: $DF_LOG"
else
  info "完成: ${#DF_PICKED[@]} 个模块 (日志: $DF_LOG)"
fi
