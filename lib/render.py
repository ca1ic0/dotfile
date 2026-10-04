"""把安装计划渲染为自包含的 bash 安装脚本。

生成物特征:
- 单文件, 不依赖仓库与 python; 目标机只需 bash
- 命令经 df_run 逐条执行 (支持 --dry-run)
- 模块脚本经带引号定界符的 heredoc 嵌入, 运行时落到临时目录执行
- 启动时复核 /etc/os-release 的 ID/VERSION_ID 与生成目标一致 (不符需 --force)
- bash 3.2 兼容 (macOS 自带 bash 也能 -n 校验)
"""

from __future__ import annotations

from .plan import Plan

_PRELUDE = '''#!/usr/bin/env bash
# 由 dotfile 生成器产出 — 请勿手改; 变更请回到仓库重新 gen
# 生成命令: {gen_command}
set -euo pipefail

EXPECTED_ID="{expected_id}"
EXPECTED_VERSION="{expected_version}"

df_usage() {{
  echo "用法: bash $0 [--dry-run] [--force]"
  echo "  --dry-run  只打印将执行的动作, 不实际执行"
  echo "  --force    跳过目标发行版复核"
}}

DF_DRY_RUN=0
DF_FORCE=0
for df_arg in "$@"; do
  case "$df_arg" in
    --dry-run) DF_DRY_RUN=1 ;;
    --force)   DF_FORCE=1 ;;
    -h|--help) df_usage; exit 0 ;;
    *) printf '未知参数: %s (支持 --dry-run / --force)\\n' "$df_arg" >&2; exit 2 ;;
  esac
done

if [ -t 2 ] && [ "${{TERM:-}}" != "dumb" ]; then
  DF_C_INFO='\\033[1;32m'; DF_C_MOD='\\033[1;36m'; DF_C_ERR='\\033[1;31m'; DF_C_OFF='\\033[0m'
else
  DF_C_INFO=''; DF_C_MOD=''; DF_C_ERR=''; DF_C_OFF=''
fi
info() {{ printf "${{DF_C_INFO}}==> %s${{DF_C_OFF}}\\n" "$*"; }}
mod()  {{ printf "\\n${{DF_C_MOD}}==== %s ====${{DF_C_OFF}}\\n" "$1"; }}
err()  {{ printf "${{DF_C_ERR}}错误: %s${{DF_C_OFF}}\\n" "$*" >&2; }}

DF_TMPDIR="$(mktemp -d "${{TMPDIR:-/tmp}}/dotfile-XXXXXX")"
on_exit() {{
  df_ret=$?
  rm -rf "$DF_TMPDIR"
  if [ "$df_ret" -ne 0 ]; then
    err "安装失败 (exit $df_ret) — 出错模块: ${{DOTFILES_MODULE:-<初始化>}}"
  fi
  exit "$df_ret"
}}
trap on_exit EXIT

df_ver_prefix_ok() {{
  # $1=期望前缀(22.04) $2=实际(22.04.5): 逐段比较, 数值不等或实际过短即失败
  local IFS='.'
  local -a df_exp df_act
  read -r -a df_exp <<<"$1"
  read -r -a df_act <<<"$2"
  local df_i
  for df_i in "${{!df_exp[@]}}"; do
    [ "${{df_act[df_i]:-x}}" = "${{df_exp[df_i]}}" ] || return 1
  done
  return 0
}}

df_run() {{
  info "  \\$ $1"
  if [ "$DF_DRY_RUN" -eq 1 ]; then return 0; fi
  eval "$1"
}}

# ---- 目标复核 -------------------------------------------------------------
if [ ! -r /etc/os-release ]; then
  err "读不到 /etc/os-release, 无法确认本机是否为生成目标 $EXPECTED_ID"
  [ "$DF_FORCE" -eq 1 ] || exit 1
  info "(--force) 跳过复核"
else
  . /etc/os-release
  if [ "${{ID:-}}" != "$EXPECTED_ID" ]; then
    err "本机发行版为 ${{ID:-未知}}, 而本脚本为 $EXPECTED_ID 生成"
    [ "$DF_FORCE" -eq 1 ] || exit 1
    info "(--force) 强制继续"
  elif [ -n "$EXPECTED_VERSION" ] && [ -n "${{VERSION_ID:-}}" ] \\
    && ! df_ver_prefix_ok "$EXPECTED_VERSION" "$VERSION_ID"; then
    err "本机版本为 ${{VERSION_ID}}, 而本脚本按 $EXPECTED_VERSION 生成 (配方可能不适用)"
    [ "$DF_FORCE" -eq 1 ] || exit 1
    info "(--force) 强制继续"
  fi
fi

export DOTFILES_DISTRO="{distro}"
export DOTFILES_FAMILY="{family}"

# ---- 概览 -----------------------------------------------------------------
info "目标: {target} (family: {family})"
info "模块: {module_names}"
info "组:   {group_names}"

# ---- 安装 -----------------------------------------------------------------
'''

_SUMMARY = '''

# ---- 汇总 -----------------------------------------------------------------
info "完成: {count} 个模块 (组: {groups}){dry_run_note}"
'''


def shq(s: str) -> str:
    """单引号包裹, 用于嵌入 df_run 参数。"""
    return "'" + s.replace("'", "'\\''") + "'"


def render(plan: Plan, gen_command: str = "./dotfile.py gen ...") -> str:
    target = plan.target
    prelude = _PRELUDE.format(
        gen_command=gen_command,
        expected_id=target.id,
        expected_version=target.version_str,
        distro=str(target),
        family=target.family,
        target=str(target),
        module_names=", ".join(p.module.name for p in plan.modules),
        group_names=", ".join(plan.groups) or "(空)",
    )

    body: list[str] = []
    script_idx = 0
    for planned in plan.modules:
        m = planned.module
        title = f"{m.name} — {m.description}" if m.description else m.name
        body.append(f"mod {shq(title)}")
        body.append(f"export DOTFILES_MODULE={shq(m.name)}")
        body.append(f'info "配方段: {planned.section}"')
        for step in planned.steps:
            if step.kind == "cmd":
                body.append(f"df_run {shq(step.command)}")
            else:
                script_idx += 1
                tmp_rel = f"script-{script_idx:02d}.sh"
                delim = _unique_delim(step.script_content, script_idx)
                body.append(f'cat > "$DF_TMPDIR/{tmp_rel}" <<\'{delim}\'')
                body.append(step.script_content.rstrip("\n"))
                body.append(delim)
                body.append(f'info "  $ bash <嵌入脚本: {step.script_ref}>"')
                body.append(f'if [ "$DF_DRY_RUN" -eq 0 ]; then bash "$DF_TMPDIR/{tmp_rel}"; fi')
        body.append("")

    summary = _SUMMARY.format(
        count=len(plan.modules),
        groups=", ".join(plan.groups) or "(空)",
        dry_run_note="",
    )
    return prelude + "\n".join(body).rstrip("\n") + summary


def _unique_delim(content: str, idx: int) -> str:
    """heredoc 定界符: 不与脚本内容任何一行相同 (防内容撞定界符)。"""
    lines = {line.strip() for line in content.splitlines()}
    delim = f"DOTFILE_EOF_{idx}"
    n = idx
    while delim in lines:
        n += 1
        delim = f"DOTFILE_EOF_{n}"
    return delim
