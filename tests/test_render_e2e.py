"""端到端: 用仓库真实模块生成 ubuntu 安装脚本并做结构断言 + bash -n。"""

import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO))

from lib import distro, manifest, plan as plan_mod, render


def build_ubuntu_script(groups=None):
    modules = manifest.load_all(REPO / "modules")
    p = plan_mod.build_plan(modules, distro.parse_target("ubuntu@24.04"), groups=groups)
    return p, render.render(p, "dotfile.py gen --target ubuntu@24.04 (测试)")


class TestRenderE2E(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.plan_base, cls.script_base = build_ubuntu_script()
        cls.plan_all, cls.script_all = build_ubuntu_script(["all"])

    def test_base_selects_only_base_group(self):
        self.assertEqual(
            [pm.module.name for pm in self.plan_base.modules],
            ["essentials", "git"],
        )

    def test_all_groups_order(self):
        self.assertEqual(
            [pm.module.name for pm in self.plan_all.modules],
            ["essentials", "git", "neovim", "starship"],
        )

    def test_header_embeds_target(self):
        self.assertIn('EXPECTED_ID="ubuntu"', self.script_all)
        self.assertIn('EXPECTED_VERSION="24.04"', self.script_all)
        self.assertIn('export DOTFILES_DISTRO="ubuntu@24.04"', self.script_all)
        self.assertIn('export DOTFILES_FAMILY="debian"', self.script_all)

    def test_commands_and_script_embedded(self):
        self.assertIn("df_step 'sudo apt-get install -y git'", self.script_all)
        self.assertIn("df_step 'sudo apt-get install -y neovim ripgrep fd-find curl'", self.script_all)
        # starship 的官方安装脚本被完整嵌入
        self.assertIn("https://starship.rs/install.sh", self.script_all)
        self.assertIn("df_step_embed \"$DF_TMPDIR/script-01.sh\" './scripts/install.sh'", self.script_all)

    def test_tui_structure(self):
        # gum 自动引导 + 交互选择 + 模块注册表
        self.assertIn("df_ensure_gum", self.script_all)
        self.assertIn("charmbracelet/gum/releases/latest", self.script_all)
        self.assertIn('"$DF_GUM" choose --no-limit', self.script_all)
        self.assertIn('"$DF_GUM" confirm', self.script_all)
        self.assertIn('"$DF_GUM" spin --spinner dot', self.script_all)
        self.assertIn("DF_MODULES=(essentials git neovim starship)", self.script_all)
        self.assertIn("df_mod_starship()", self.script_all)
        self.assertIn("df_requires_essentials=''", self.script_all)
        self.assertIn("df_check_requires", self.script_all)
        # 降级模式与跳过选择
        self.assertIn("--no-tui)", self.script_all)
        self.assertIn("--yes|-y)", self.script_all)
        # 非 TTY 时安装全部模块
        self.assertIn('DF_PICKED=("${DF_MODULES[@]}")', self.script_all)

    def test_no_symlink_and_delim_unique(self):
        self.assertNotIn("ln -s", self.script_all)
        delims = [ln for ln in self.script_all.splitlines() if ln.startswith("DOTFILE_EOF_")]
        self.assertEqual(len(delims), len(set(delims)), "heredoc 定界符必须唯一")

    def test_dry_run_flag_supported(self):
        self.assertIn("--dry-run", self.script_all)

    def test_bash_n(self):
        for script in (self.script_base, self.script_all):
            with tempfile.NamedTemporaryFile("w", suffix=".sh", delete=False) as f:
                f.write(script)
                path = f.name
            try:
                r = subprocess.run(["bash", "-n", path], capture_output=True, text=True)
                self.assertEqual(r.returncode, 0, r.stderr)
            finally:
                Path(path).unlink(missing_ok=True)

    def test_cli_gen_stdout(self):
        r = subprocess.run(
            [sys.executable, "dotfile.py", "gen", "--target", "ubuntu@24.04"],
            capture_output=True, text=True, cwd=REPO,
        )
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("#!/usr/bin/env bash", r.stdout)
        self.assertIn("apt-get install -y git", r.stdout)

    def test_cli_gen_missing_recipe_errors(self):
        # 仓库模块目前只有 debian 段, 对 arch 目标应清晰报错
        r = subprocess.run(
            [sys.executable, "dotfile.py", "gen", "--target", "arch"],
            capture_output=True, text=True, cwd=REPO,
        )
        self.assertEqual(r.returncode, 1)
        self.assertIn("没有适配", r.stderr)
        self.assertIn("查找链", r.stderr)

    def test_cli_gen_all_targets(self):
        # targets.toml 声明的每个目标各生成一份, 文件名以 install-<id>-<ver>.sh 落盘
        import tomllib

        specs = tomllib.loads((REPO / "targets.toml").read_text(encoding="utf-8"))["targets"]
        expected = sorted(f"install-{s.replace('@', '-')}.sh" for s in specs)
        with tempfile.TemporaryDirectory() as d:
            r = subprocess.run(
                [sys.executable, "dotfile.py", "gen", "--all", "-d", d],
                capture_output=True, text=True, cwd=REPO,
            )
            self.assertEqual(r.returncode, 0, r.stderr)
            names = sorted(p.name for p in Path(d).glob("*.sh"))
            self.assertEqual(names, expected)
            for p in Path(d).glob("*.sh"):
                syntax = subprocess.run(["bash", "-n", str(p)], capture_output=True, text=True)
                self.assertEqual(syntax.returncode, 0, f"{p}: {syntax.stderr}")

    def test_cli_gen_all_and_target_conflict(self):
        r = subprocess.run(
            [sys.executable, "dotfile.py", "gen", "--all", "--target", "arch"],
            capture_output=True, text=True, cwd=REPO,
        )
        self.assertEqual(r.returncode, 2)
        self.assertIn("互斥", r.stderr)


if __name__ == "__main__":
    unittest.main()
