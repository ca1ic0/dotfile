"""发行版注册表、目标解析与 OS 段匹配链。

核心概念:
- family: 一组共享安装方式的发行版 (debian / redhat / arch)
- distro: 具体 ID (/etc/os-release 的 ID 字段, 如 ubuntu / rocky)
- 段键 (section key): module.toml 中的 OS 段名, 三种形态
    "debian"      family 段, 该 family 下所有发行版命中
    "rocky"       distro 段, 仅该 ID 命中
    "rocky@8"     版本段, 点分前缀匹配 VERSION_ID (8 命中 8.7)
- 查找链: 生成时按 目标全版本 → 各级版本前缀 → distro → family 依次找,
  第一个存在的段即为最终配方, 不叠加。
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field
from pathlib import Path

# family -> 成员 distro id (/etc/os-release 的 ID 取小写)
FAMILIES: dict[str, set[str]] = {
    "debian": {"debian", "ubuntu", "linuxmint", "pop"},
    "redhat": {"fedora", "rocky", "almalinux", "alma", "rhel", "centos", "amzn"},
    "arch": {"arch", "manjaro", "endeavouros"},
}

# distro id -> family (反查表)
DISTRO_FAMILY: dict[str, str] = {
    d: f for f, ds in FAMILIES.items() for d in ds
}


class TargetError(Exception):
    """无法解析目标发行版。"""


@dataclass(frozen=True)
class Target:
    """一个生成目标: 具体 distro + 归属 family + 可选版本。

    version 是数值元组 (用于比较); version_str 保留原始写法 (用于展示, 如 24.04)。
    """

    id: str
    family: str
    version: tuple[int, ...] | None = None  # None = 滚动/未知版本 (如 arch)
    version_str: str = ""

    def __str__(self) -> str:
        if self.version:
            return f"{self.id}@{self.version_str}"
        return self.id


@dataclass(frozen=True)
class SectionKey:
    """module.toml 的 OS 段键 (规范化后)。

    相等性只看 base + 数值元组 ("rocky@8" == "rocky@8.0");
    version_str 仅用于展示, 不参与相等性。
    """

    base: str
    version: tuple[int, ...] | None
    version_str: str = field(default="", compare=False)

    def __str__(self) -> str:
        if self.version is not None:
            return f"{self.base}@{self.version_str}"
        return self.base


def parse_version(text: str) -> tuple[int, ...] | None:
    """把 VERSION_ID 解析为点分数值元组; 非数字开头 (如 rolling) 返回 None。"""
    out: list[int] = []
    for part in text.strip().split("."):
        if not part.isdigit():
            break
        out.append(int(part))
    return tuple(out) or None


def parse_section_key(key: str) -> SectionKey:
    """校验并规范化 OS 段键; 非法时抛 ValueError。"""
    k = key.strip().lower()
    if not k:
        raise ValueError("空的 OS 段键")
    base, _, ver = k.partition("@")
    if "@" in ver:
        raise ValueError(f"OS 段键含多个 '@': {key!r}")
    # 注意: debian/arch 的 distro id 与 family 名同名, distro 表必须先判 —
    # ["debian@13"] 是 distro 段, 不是 family 段
    if base not in DISTRO_FAMILY and base in FAMILIES:
        if ver:
            raise ValueError(f"family 段不支持版本号: {key!r} (应挂在具体 distro 上, 如 rocky@8)")
    elif base not in DISTRO_FAMILY:
        raise ValueError(
            f"未知的发行版/family: {key!r} "
            f"(已知 family: {sorted(FAMILIES)}, 已知 distro: {sorted(DISTRO_FAMILY)})"
        )
    if ver:
        if not re.fullmatch(r"\d+(\.\d+)*", ver):
            raise ValueError(f"OS 段键版本格式非法: {key!r} (应为 8 或 22.04 这样的点分数字)")
        v = _numeric_version(ver)
        return SectionKey(base=base, version=v, version_str=ver)
    return SectionKey(base=base, version=None)


def _numeric_version(ver: str) -> tuple[int, ...]:
    """'22.04' -> (22, 4); 去掉末尾的 0 组件使 8.0 与 8 数值相等。"""
    parts = tuple(int(p) for p in ver.split("."))
    while len(parts) > 1 and parts[-1] == 0:
        parts = parts[:-1]
    return parts


def lookup_chain(target: Target) -> list[SectionKey]:
    """返回目标的段键查找链, 从最特定到最宽泛。

    ubuntu@22.04 -> [ubuntu@22.04, ubuntu@22, ubuntu, debian]
    rocky@8.7    -> [rocky@8.7, rocky@8, rocky, redhat]
    arch         -> [arch]
    """
    chain: list[SectionKey] = []
    if target.version:
        for n in range(len(target.version), 0, -1):
            prefix = target.version[:n]
            shown = target.version_str if n == len(target.version) else ".".join(map(str, prefix))
            chain.append(SectionKey(base=target.id, version=prefix, version_str=shown))
    chain.append(SectionKey(base=target.id, version=None))
    if target.family != target.id:  # arch 这类 id 与 family 同名时去重
        chain.append(SectionKey(base=target.family, version=None))
    return chain


def parse_target(spec: str) -> Target:
    """解析 --target 参数, 形如 "rocky@8" / "ubuntu@22.04" / "arch"。"""
    spec = spec.strip().lower()
    if not spec:
        raise TargetError("--target 不能为空")
    base, _, ver = spec.partition("@")
    if "@" in ver:
        raise TargetError(f"--target 含多个 '@': {spec!r}")
    # 注意: arch 既是 distro id 又是 family 名, distro 表必须先判
    if base not in DISTRO_FAMILY:
        if base in FAMILIES:
            raise TargetError(f"--target 需要具体发行版而非 family: {spec!r} (如 ubuntu、rocky)")
        raise TargetError(
            f"未知的发行版: {spec!r} (已知: {sorted(DISTRO_FAMILY)})"
        )
    version = None
    version_str = ""
    if ver:
        if not re.fullmatch(r"\d+(\.\d+)*", ver):
            raise TargetError(f"--target 版本格式非法: {spec!r} (应为 8 或 22.04)")
        version = _numeric_version(ver)
        version_str = ver
    return Target(id=base, family=DISTRO_FAMILY[base], version=version, version_str=version_str)


def parse_os_release(text: str) -> dict[str, str]:
    """解析 os-release 文本为字段字典。"""
    fields: dict[str, str] = {}
    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, value = line.partition("=")
        value = value.strip().strip('"').strip("'")
        fields[key.strip()] = value
    return fields


def family_of(distro_id: str, id_like: str = "") -> str | None:
    """由 ID (精确) 或 ID_LIKE (回落) 推断 family。"""
    if distro_id in DISTRO_FAMILY:
        return DISTRO_FAMILY[distro_id]
    for like in id_like.split():
        if like in FAMILIES:
            return like
        if like in DISTRO_FAMILY:
            return DISTRO_FAMILY[like]
    return None


def detect(path: str | Path = "/etc/os-release") -> Target:
    """从本机 /etc/os-release 检测目标 (供 install --target auto 使用)。"""
    p = Path(path)
    if not p.is_file():
        raise TargetError(
            f"未找到 {p}, 无法自动识别本机发行版 (macOS/容器最小镜像?), 请显式指定 --target"
        )
    fields = parse_os_release(p.read_text(encoding="utf-8"))
    distro_id = fields.get("ID", "").strip().lower()
    family = family_of(distro_id, fields.get("ID_LIKE", ""))
    if family is None:
        raise TargetError(f"无法识别的发行版: ID={distro_id!r}, ID_LIKE={fields.get('ID_LIKE', '')!r}")
    version_str = fields.get("VERSION_ID", "").strip()
    version = parse_version(version_str)
    return Target(
        id=distro_id,
        family=family,
        version=version,
        version_str=version_str if version else "",
    )
