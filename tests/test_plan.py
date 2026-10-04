import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from lib import distro, manifest, plan as plan_mod


def make_module(name: str, groups=None, order=100, requires=None, recipes=None, path=None):
    return manifest.Module(
        name=name,
        description="",
        order=order,
        groups=groups or ["base"],
        requires=requires or [],
        recipes=(
            recipes if recipes is not None
            else {distro.parse_section_key("debian"): ["echo " + name]}
        ),
        path=path or Path("."),
    )


def sel(mods, **kw):
    return [m.name for m in plan_mod.select_modules(mods, **kw)[0]]


class TestSelection(unittest.TestCase):
    def setUp(self):
        self.mods = [
            make_module("git", groups=["base"]),
            make_module("essentials", groups=["base"]),
            make_module("neovim", groups=["dev", "editor"]),
            make_module("steam", groups=["games"]),
        ]

    def test_default_base_only(self):
        self.assertEqual(sel(self.mods), ["essentials", "git"])

    def test_explicit_groups_replace_default(self):
        self.assertEqual(sel(self.mods, groups=["dev"]), ["neovim"])

    def test_groups_union(self):
        self.assertEqual(sel(self.mods, groups=["base", "games"]), ["essentials", "git", "steam"])

    def test_all(self):
        self.assertEqual(sel(self.mods, groups=["all"]), ["essentials", "git", "neovim", "steam"])

    def test_without_groups(self):
        self.assertEqual(sel(self.mods, groups=["all"], without_groups=["games"]), ["essentials", "git", "neovim"])

    def test_explicit_module_beats_without_groups(self):
        # 显式 --modules 追加的模块不受 --without-groups 影响
        self.assertEqual(
            sel(self.mods, groups=["base"], without_groups=["games"], extra_modules=["steam"]),
            ["essentials", "git", "steam"],
        )

    def test_without_modules_highest_priority(self):
        self.assertEqual(
            sel(self.mods, groups=["all"], without_modules=["git", "steam"]),
            ["essentials", "neovim"],
        )

    def test_unknown_group_and_module(self):
        with self.assertRaises(plan_mod.PlanError):
            sel(self.mods, groups=["nope"])
        with self.assertRaises(plan_mod.PlanError):
            sel(self.mods, extra_modules=["nope"])
        with self.assertRaises(plan_mod.PlanError):
            sel(self.mods, without_groups=["nope"])

    def test_empty_selection(self):
        with self.assertRaises(plan_mod.PlanError):
            sel(self.mods, groups=["games"], without_modules=["steam"])


class TestOrdering(unittest.TestCase):
    def test_order_then_name(self):
        mods = [
            make_module("zeta", order=10),
            make_module("alpha", order=10),
            make_module("beta", order=5),
        ]
        p = plan_mod.build_plan(mods, distro.parse_target("ubuntu@24.04"))
        self.assertEqual([pm.module.name for pm in p.modules], ["beta", "alpha", "zeta"])

    def test_requires_constrains_order(self):
        # order 更小的 late 依赖 order 更大的 early, 拓扑优先
        mods = [
            make_module("early", order=50),
            make_module("late", order=1, requires=["early"]),
        ]
        p = plan_mod.build_plan(mods, distro.parse_target("ubuntu@24.04"))
        self.assertEqual([pm.module.name for pm in p.modules], ["early", "late"])

    def test_requires_missing(self):
        mods = [make_module("late", requires=["ghost"])]
        with self.assertRaises(plan_mod.PlanError) as ctx:
            plan_mod.build_plan(mods, distro.parse_target("ubuntu@24.04"))
        self.assertIn("ghost", str(ctx.exception))

    def test_cycle(self):
        mods = [
            make_module("a", requires=["b"]),
            make_module("b", requires=["a"]),
        ]
        with self.assertRaises(plan_mod.PlanError) as ctx:
            plan_mod.build_plan(mods, distro.parse_target("ubuntu@24.04"))
        self.assertIn("成环", str(ctx.exception))


class TestResolveRecipe(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        root = Path(self._tmp.name)
        mod_dir = root / "demo"
        (mod_dir / "scripts").mkdir(parents=True)
        (mod_dir / "module.toml").write_text(
            '[module]\nname = "demo"\n\n'
            '[redhat]\ninstall = "sudo dnf install -y demo"\n\n'
            '["rocky@8"]\ninstall = ["sudo dnf install -y epel-release", "./scripts/x.sh"]\n',
            encoding="utf-8",
        )
        (mod_dir / "scripts" / "x.sh").write_text("#!/bin/bash\necho hi\n", encoding="utf-8")
        self.module = manifest.load_module(mod_dir)

    def tearDown(self):
        self._tmp.cleanup()

    def _module(self):
        return self.module

    def test_version_section_wins(self):
        pm = plan_mod.resolve_recipe(self._module(), distro.parse_target("rocky@8.7"))
        self.assertEqual(str(pm.section), "rocky@8")
        kinds = [s.kind for s in pm.steps]
        self.assertEqual(kinds, ["cmd", "script"])
        self.assertIn("echo hi", pm.steps[1].script_content)

    def test_family_fallback(self):
        pm = plan_mod.resolve_recipe(self._module(), distro.parse_target("rocky@9.1"))
        self.assertEqual(str(pm.section), "redhat")

    def test_no_match(self):
        with self.assertRaises(plan_mod.PlanError) as ctx:
            plan_mod.resolve_recipe(self._module(), distro.parse_target("arch"))
        self.assertIn("demo", str(ctx.exception))
        self.assertIn("arch", str(ctx.exception))


if __name__ == "__main__":
    unittest.main()
