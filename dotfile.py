#!/usr/bin/env python3
"""dotfile — 声明式多发行版软件安装脚本生成器。

子命令:
  gen      按目标生成自包含安装脚本
  install  在本机直接执行 (自动检测发行版)
  plan     打印解析后的安装计划 (审查用)
  validate 校验所有 module.toml
  list     列出模块
"""

from __future__ import annotations

import argparse
import os
import subprocess
import sys
import tempfile
import tomllib
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent
MODULES_DIR = REPO_ROOT / "modules"

sys.path.insert(0, str(REPO_ROOT))

from lib import distro, manifest, plan as plan_mod, render  # noqa: E402


def _add_selection_args(p: argparse.ArgumentParser) -> None:
    p.add_argument("--groups", "-g", default=None, metavar="A,B|all",
                   help="选择软件包组 (逗号分隔; 缺省 base; all=全部)")
    p.add_argument("--without-groups", default=None, metavar="A,B",
                   help="排除软件包组 (显式 --modules 追加的模块不受影响)")
    p.add_argument("--modules", "-m", default=None, metavar="A,B",
                   help="在组选择基础上追加指定模块")
    p.add_argument("--without-modules", default=None, metavar="A,B",
                   help="强制排除指定模块 (优先级最高)")


def _csv(value: str | None) -> list[str] | None:
    if value is None:
        return None
    items = [v.strip() for v in value.split(",") if v.strip()]
    return items or None


def _build_plan(args) -> plan_mod.Plan:
    target = distro.parse_target(args.target)
    modules = manifest.load_all(MODULES_DIR)
    return plan_mod.build_plan(
        modules,
        target,
        groups=_csv(args.groups),
        without_groups=_csv(args.without_groups),
        extra_modules=_csv(args.modules),
        without_modules=_csv(args.without_modules),
    )


def _gen_command(argv: list[str]) -> str:
    return "./dotfile.py " + " ".join(argv)


def _load_ci_targets() -> list[str]:
    path = REPO_ROOT / "targets.toml"
    try:
        data = tomllib.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        raise ValueError(f"缺少 {path}")
    targets = data.get("targets")
    if not isinstance(targets, list) or not targets or not all(
        isinstance(t, str) and t.strip() for t in targets
    ):
        raise ValueError(f"{path} 需要非空字符串数组字段 targets")
    return [t.strip() for t in targets]


def cmd_gen(args, argv: list[str]) -> int:
    if args.all:
        if args.target:
            print("错误: --all 与 --target 互斥", file=sys.stderr)
            return 2
        # 批量产物含全部模块, 供目标机上 TUI 运行时勾选子集
        if not args.groups:
            args.groups = "all"
        out_dir = Path(args.dir)
        out_dir.mkdir(parents=True, exist_ok=True)
        for spec in _load_ci_targets():
            args.target = spec
            p = _build_plan(args)
            text = render.render(p, gen_command=_gen_command(argv))
            name = f"install-{str(p.target).replace('@', '-')}.sh"
            out = out_dir / name
            out.write_text(text, encoding="utf-8")
            out.chmod(0o755)
            print(f"已生成: {out} ({len(p.modules)} 个模块)")
        return 0

    p = _build_plan(args)
    text = render.render(p, gen_command=_gen_command(argv))
    if args.output:
        out = Path(args.output)
        out.write_text(text, encoding="utf-8")
        out.chmod(0o755)
        print(f"已生成: {out} ({len(text.splitlines())} 行, {len(p.modules)} 个模块)")
    else:
        sys.stdout.write(text)
    return 0


def cmd_install(args, argv: list[str]) -> int:
    if not args.target:
        target = distro.detect()
        print(f"检测到本机: {target}")
        args.target = str(target)
    p = _build_plan(args)
    text = render.render(p, gen_command=_gen_command(argv))
    pass_through = []
    if args.dry_run:
        pass_through.append("--dry-run")
    if args.force:
        pass_through.append("--force")
    with tempfile.NamedTemporaryFile("w", suffix=".sh", delete=False, encoding="utf-8") as f:
        f.write(text)
        tmp = f.name
    try:
        result = subprocess.run(["bash", tmp, *pass_through])
        return result.returncode
    finally:
        os.unlink(tmp)


def cmd_plan(args, argv: list[str]) -> int:
    p = _build_plan(args)
    print(f"目标: {p.target} (family: {p.target.family})")
    print(f"组:   {', '.join(p.groups)}")
    print(f"模块: {len(p.modules)} 个, 执行顺序:")
    for i, pm in enumerate(p.modules, 1):
        m = pm.module
        req = f" (requires: {', '.join(m.requires)})" if m.requires else ""
        print(f"\n{i}. {m.name}  [段: {pm.section}]{req}")
        for j, c in enumerate(m.content):
            branch = "└─" if j == len(m.content) - 1 else "├─"
            print(f"     {branch} {c}")
        for step in pm.steps:
            if step.kind == "cmd":
                print(f"   $ {step.command}")
            else:
                preview = step.script_content.splitlines()
                head = next((ln for ln in preview if ln.strip() and not ln.startswith("#!")), "")
                print(f"   $ bash <{step.script_ref}>  # {len(preview)} 行, 如: {head.strip()[:60]}")
    return 0


def cmd_validate(args, argv: list[str]) -> int:
    modules = manifest.load_all(MODULES_DIR)
    groups = plan_mod.all_group_names(modules)
    sections = sum(len(m.recipes) for m in modules)
    print(f"OK: {len(modules)} 个模块, {sections} 个 OS 段, 组: {', '.join(groups)}")
    return 0


def cmd_list(args, argv: list[str]) -> int:
    modules = manifest.load_all(MODULES_DIR)
    name_w = max(len(m.name) for m in modules)
    for m in sorted(modules, key=lambda x: (x.order, x.name)):
        print(f"{m.name:<{name_w}}  order={m.order:<4} groups={','.join(m.groups):<12} "
              f"段={','.join(sorted(str(k) for k in m.recipes)):<28} 内容={len(m.content):<3} {m.description}")
    return 0


def main(argv: list[str] | None = None) -> int:
    argv = list(sys.argv[1:] if argv is None else argv)
    parser = argparse.ArgumentParser(prog="dotfile.py", description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)

    p_gen = sub.add_parser("gen", help="生成自包含安装脚本")
    p_gen.add_argument("--target", "-t", default=None, metavar="ID[@VER]",
                       help="如 rocky@8 / ubuntu@22.04 / arch (与 --all 二选一)")
    p_gen.add_argument("--all", action="store_true",
                       help="为 targets.toml 声明的全部目标各生成一份 (CI 批量模式)")
    p_gen.add_argument("--dir", "-d", default="script",
                       help="--all 模式的输出目录, 缺省 script/")
    _add_selection_args(p_gen)
    p_gen.add_argument("--output", "-o", default=None, help="输出文件 (缺省打印到 stdout)")
    p_gen.set_defaults(fn=cmd_gen)

    p_ins = sub.add_parser("install", help="在本机直接执行 (缺省自动检测发行版)")
    p_ins.add_argument("--target", "-t", default=None, metavar="ID[@VER]",
                       help="缺省 auto: 检测 /etc/os-release")
    _add_selection_args(p_ins)
    p_ins.add_argument("--dry-run", action="store_true", help="只打印动作")
    p_ins.add_argument("--force", action="store_true", help="跳过发行版复核")
    p_ins.set_defaults(fn=cmd_install)

    p_plan = sub.add_parser("plan", help="打印解析后的安装计划")
    p_plan.add_argument("--target", "-t", required=True, metavar="ID[@VER]")
    _add_selection_args(p_plan)
    p_plan.set_defaults(fn=cmd_plan)

    p_val = sub.add_parser("validate", help="校验所有 module.toml")
    p_val.set_defaults(fn=cmd_validate)

    p_ls = sub.add_parser("list", help="列出模块")
    p_ls.set_defaults(fn=cmd_list)

    args = parser.parse_args(argv)
    try:
        return args.fn(args, argv)
    except (distro.TargetError, manifest.ManifestError, plan_mod.PlanError, ValueError) as e:
        print(f"错误: {e}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
