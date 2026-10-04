"""安装计划的组装: 组/模块选择 → 配方解析 → order/requires 排序。"""

from __future__ import annotations

import heapq
from dataclasses import dataclass, field

from . import distro
from .manifest import Module


class PlanError(Exception):
    """计划无法组装。"""


@dataclass
class Step:
    """配方中的一步: shell 命令, 或模块内脚本 (内容在计划期读入)。"""

    kind: str  # "cmd" | "script"
    command: str = ""        # kind=cmd 时的完整命令
    script_ref: str = ""     # kind=script 时的相对路径 (展示用)
    script_content: str = ""


@dataclass
class PlannedModule:
    module: Module
    section: distro.SectionKey  # 命中的规范化段键, 如 rocky@8
    steps: list[Step] = field(default_factory=list)


@dataclass
class Plan:
    target: distro.Target
    groups: list[str]        # 本次选择实际生效的组
    modules: list[PlannedModule]  # 已排序


def all_group_names(modules: list[Module]) -> list[str]:
    names: set[str] = set()
    for m in modules:
        names.update(m.groups)
    return sorted(names)


def select_modules(
    modules: list[Module],
    groups: list[str] | None = None,
    without_groups: list[str] | None = None,
    extra_modules: list[str] | None = None,
    without_modules: list[str] | None = None,
) -> tuple[list[Module], list[str]]:
    """按组/模块名过滤, 返回 (选中模块, 生效组名)。

    语义:
    - groups 为 None → 默认 ["base"]; 含 "all" → 全部模块
    - extra_modules 在组过滤结果上追加指定模块
    - without_groups 剔除命中组且未被显式追加的模块
    - without_modules 最后强制剔除
    """
    groups = list(groups) if groups else ["base"]
    without_groups = list(without_groups or [])
    extra_modules = list(extra_modules or [])
    without_modules = list(without_modules or [])

    known_groups = set(all_group_names(modules))
    for g in groups + without_groups:
        if g != "all" and g not in known_groups:
            raise PlanError(f"未知的软件包组: {g!r} (已知: {sorted(known_groups)})")
    by_name = {m.name: m for m in modules}
    for name in extra_modules + without_modules:
        if name not in by_name:
            raise PlanError(f"未知的模块: {name!r} (已知: {sorted(by_name)})")

    include_all = "all" in groups
    effective_groups = ["all"] if include_all else [g for g in groups if g != "all"]

    selected: dict[str, Module] = {}
    for m in modules:
        if include_all or set(m.groups) & set(groups):
            selected[m.name] = m
    for name in extra_modules:
        selected[name] = by_name[name]
    for g in without_groups:
        for m in list(selected.values()):
            if g in m.groups and m.name not in extra_modules:
                del selected[m.name]
    for name in without_modules:
        selected.pop(name, None)

    if not selected:
        raise PlanError("选择结果为空: 没有任何模块被选中")
    return sorted(selected.values(), key=lambda m: m.name), effective_groups


def _topo_sort(selected: list[Module]) -> list[Module]:
    """Kahn 拓扑排序; 同层按 (order, name) 取最小, 保证确定性。

    requires 只约束先后, 不引入模块 — 未选中的依赖在调用方先报错。
    """
    selected_names = {m.name for m in selected}
    indegree = {m.name: 0 for m in selected}
    dependents: dict[str, list[str]] = {m.name: [] for m in selected}
    for m in selected:
        for r in m.requires:
            if r in selected_names:  # 外部依赖已在前置校验中报错
                indegree[m.name] += 1
                dependents[r].append(m.name)

    heap = [(m.order, m.name) for m in selected if indegree[m.name] == 0]
    heapq.heapify(heap)
    by_name = {m.name: m for m in selected}
    ordered: list[Module] = []
    while heap:
        _, name = heapq.heappop(heap)
        ordered.append(by_name[name])
        for dep in dependents[name]:
            indegree[dep] -= 1
            if indegree[dep] == 0:
                heapq.heappush(heap, (by_name[dep].order, dep))
    if len(ordered) != len(selected):
        cyc = sorted(n for n, d in indegree.items() if d > 0)
        raise PlanError(f"模块依赖成环, 涉及: {cyc}")
    return ordered


def resolve_recipe(module: Module, target: distro.Target) -> PlannedModule:
    """按目标的段键查找链解析模块的最终配方 (命中即止, 不叠加)。"""
    chain = distro.lookup_chain(target)
    section = next((k for k in chain if k in module.recipes), None)
    if section is None:
        raise PlanError(
            f"模块 {module.name} 没有适配 {target} 的 OS 段\n"
            f"  查找链: {' -> '.join(str(k) for k in chain)}\n"
            f"  已有段: {sorted(str(k) for k in module.recipes)}"
        )
    steps: list[Step] = []
    for cmd in module.recipes[section]:
        if cmd.startswith("./"):
            steps.append(
                Step(
                    kind="script",
                    script_ref=cmd,
                    script_content=(module.path / cmd).read_text(encoding="utf-8"),
                )
            )
        else:
            steps.append(kind_step(cmd))
    return PlannedModule(module=module, section=section, steps=steps)


def kind_step(cmd: str) -> Step:
    return Step(kind="cmd", command=cmd)


def build_plan(
    modules: list[Module],
    target: distro.Target,
    groups: list[str] | None = None,
    without_groups: list[str] | None = None,
    extra_modules: list[str] | None = None,
    without_modules: list[str] | None = None,
) -> Plan:
    selected, effective_groups = select_modules(
        modules, groups, without_groups, extra_modules, without_modules
    )
    selected_names = {m.name for m in selected}
    for m in selected:
        missing = [r for r in m.requires if r not in selected_names]
        if missing:
            raise PlanError(
                f"模块 {m.name} 依赖 {missing}, 但其未被选中 "
                f"(用 --modules {','.join(missing)} 或对应组一起选择)"
            )
    ordered = _topo_sort(selected)
    planned = [resolve_recipe(m, target) for m in ordered]
    return Plan(target=target, groups=effective_groups, modules=planned)
