"""module.toml 的加载与校验。

模块目录结构约定:
    modules/<name>/
        module.toml     必需, 唯一的声明文件
        scripts/        可选, install 配方里以 "./" 引用的脚本存放处

module.toml 内容 = [module] 元数据 + 若干 OS 段 (debian / rocky / "rocky@8" ...)。
"""

from __future__ import annotations

from dataclasses import dataclass, field
from pathlib import Path

import tomllib

from . import distro

DEFAULT_ORDER = 100
DEFAULT_GROUPS = ["base"]
ALLOWED_SECTION_FIELDS = {"install"}


class ManifestError(Exception):
    """module.toml 不合法。"""


@dataclass
class Module:
    name: str
    description: str
    order: int
    groups: list[str]
    requires: list[str]
    recipes: dict[distro.SectionKey, list[str]] = field(default_factory=dict)  # 规范化段键 -> 命令列表
    path: Path = field(default_factory=Path)


def _err(module_dir: Path, msg: str) -> ManifestError:
    return ManifestError(f"{module_dir / 'module.toml'}: {msg}")


def _normalize_install(module_dir: Path, section: str, value: object) -> list[str]:
    """install 值: 字符串 → 单命令; 字符串数组 → 逐条命令。"""
    if isinstance(value, str):
        commands = [value]
    elif isinstance(value, list) and value and all(isinstance(v, str) and v.strip() for v in value):
        commands = list(value)
    else:
        raise _err(
            module_dir,
            f"[{section}] install 必须是非空命令字符串或非空字符串数组, 实际: {value!r}",
        )
    for cmd in commands:
        if not cmd.strip():
            raise _err(module_dir, f"[{section}] install 含空命令")
        if cmd.startswith("./"):
            script = (module_dir / cmd).resolve()
            if not script.is_relative_to(module_dir.resolve()):
                raise _err(module_dir, f"[{section}] 脚本路径越出模块目录: {cmd!r}")
            if not script.is_file():
                raise _err(module_dir, f"[{section}] 引用的脚本不存在: {cmd!r}")
    return commands


def load_module(module_dir: Path) -> Module:
    toml_path = module_dir / "module.toml"
    if not toml_path.is_file():
        raise _err(module_dir, "缺少 module.toml")
    try:
        data = tomllib.loads(toml_path.read_text(encoding="utf-8"))
    except tomllib.TOMLDecodeError as e:
        raise _err(module_dir, f"TOML 语法错误: {e}") from e

    mod = data.get("module")
    if not isinstance(mod, dict):
        raise _err(module_dir, "缺少 [module] 段")

    name = mod.get("name")
    if not isinstance(name, str) or not name.strip():
        raise _err(module_dir, "[module] name 必须是非空字符串")
    name = name.strip()
    if name != module_dir.name:
        raise _err(module_dir, f"[module] name ({name!r}) 与目录名 ({module_dir.name!r}) 不一致")

    description = mod.get("description", "")
    if not isinstance(description, str):
        raise _err(module_dir, "[module] description 必须是字符串")

    order = mod.get("order", DEFAULT_ORDER)
    if not isinstance(order, int) or isinstance(order, bool):
        raise _err(module_dir, f"[module] order 必须是整数, 实际: {order!r}")

    groups = mod.get("groups", DEFAULT_GROUPS)
    if (
        not isinstance(groups, list)
        or not groups
        or not all(isinstance(g, str) and g.strip() for g in groups)
    ):
        raise _err(module_dir, f"[module] groups 必须是非空字符串数组 (缺省为 {DEFAULT_GROUPS})")
    groups = [g.strip() for g in groups]

    requires = mod.get("requires", [])
    if not isinstance(requires, list) or not all(isinstance(r, str) and r.strip() for r in requires):
        raise _err(module_dir, "[module] requires 必须是字符串数组")
    requires = [r.strip() for r in requires]

    unknown_meta = set(mod) - {"name", "description", "order", "groups", "requires"}
    if unknown_meta:
        raise _err(module_dir, f"[module] 含未知字段: {sorted(unknown_meta)}")

    recipes: dict[str, list[str]] = {}
    for key, section in data.items():
        if key == "module":
            continue
        if not isinstance(section, dict):
            raise _err(module_dir, f"顶层键 {key!r} 必须是 OS 段 (表)")
        try:
            canonical = distro.parse_section_key(key)
        except ValueError as e:
            raise _err(module_dir, str(e)) from e
        unknown = set(section) - ALLOWED_SECTION_FIELDS
        if unknown:
            raise _err(module_dir, f"[{key}] 含未知字段: {sorted(unknown)} (只允许 install)")
        if "install" not in section:
            raise _err(module_dir, f"[{key}] 缺少 install")
        if canonical in recipes:
            raise _err(module_dir, f"OS 段重复 (规范化后均为 [{canonical}])")
        recipes[canonical] = _normalize_install(module_dir, key, section["install"])

    if not recipes:
        raise _err(module_dir, "至少需要一个 OS 段 (如 [debian] / [fedora] / [arch])")

    return Module(
        name=name,
        description=description,
        order=order,
        groups=groups,
        requires=requires,
        recipes=recipes,
        path=module_dir,
    )


def load_all(modules_dir: Path) -> list[Module]:
    """加载 modules/ 下全部模块 (按 name 排序, 保证确定性), 校验重名与 requires 可达。"""
    if not modules_dir.is_dir():
        raise ManifestError(f"模块目录不存在: {modules_dir}")
    modules: list[Module] = []
    seen: dict[str, Path] = {}
    for entry in sorted(modules_dir.iterdir()):
        if not entry.is_dir() or not (entry / "module.toml").is_file():
            continue
        module = load_module(entry)
        if module.name in seen:
            raise ManifestError(f"模块重名: {module.name} ({seen[module.name]} 与 {entry})")
        seen[module.name] = entry
        modules.append(module)
    if not modules:
        raise ManifestError(f"{modules_dir} 下没有可用模块")
    names = {m.name for m in modules}
    for m in modules:
        for r in m.requires:
            if r not in names:
                raise ManifestError(f"模块 {m.name} requires 不存在的模块: {r!r} (已知: {sorted(names)})")
    return modules
