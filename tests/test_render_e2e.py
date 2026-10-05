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
        # 覆盖仓库全部模块, 且按 (order, name) 排序 (仓库模块当前无 requires)
        all_names = {m.name for m in manifest.load_all(REPO / "modules")}
        names = [pm.module.name for pm in self.plan_all.modules]
        self.assertEqual(set(names), all_names)
        keys = [(pm.module.order, pm.module.name) for pm in self.plan_all.modules]
        self.assertEqual(keys, sorted(keys))

    def test_header_embeds_target(self):
        self.assertIn('EXPECTED_ID="ubuntu"', self.script_all)
        self.assertIn('EXPECTED_VERSION="24.04"', self.script_all)
        self.assertIn('export DOTFILES_DISTRO="ubuntu@24.04"', self.script_all)
        self.assertIn('export DOTFILES_FAMILY="debian"', self.script_all)

    def test_commands_and_script_embedded(self):
        self.assertIn("df_step 'sudo apt-get install -y git'", self.script_all)
        self.assertIn("df_step 'sudo apt-get install -y neovim ripgrep fd-find curl'", self.script_all)
        # starship 的官方安装脚本被完整嵌入 (嵌入编号随模块增删变化, 不写死)
        self.assertIn("https://starship.rs/install.sh", self.script_all)
        self.assertRegex(
            self.script_all,
            r"df_step_embed \"\$DF_TMPDIR/script-\d+\.sh\" '\./scripts/install\.sh'",
        )

    def test_tui_structure(self):
        # gum 自动引导 + 交互选择 + 模块注册表
        self.assertIn("df_ensure_gum", self.script_all)
        self.assertIn("charmbracelet/gum/releases/latest", self.script_all)
        self.assertIn('"$DF_GUM" choose --no-limit --ordered', self.script_all)
        self.assertIn("x 勾选/取消", self.script_all)  # gum 2.x 切换键是 x, 不是空格
        self.assertIn('--selected-prefix "[✅] "', self.script_all)
        self.assertIn('"$DF_GUM" confirm', self.script_all)
        self.assertIn('"$DF_GUM" spin --spinner dot', self.script_all)
        expected_registry = "DF_MODULES=(" + " ".join(
            pm.module.name for pm in self.plan_all.modules
        ) + ")"
        self.assertIn(expected_registry, self.script_all)
        self.assertIn("df_mod_starship()", self.script_all)
        self.assertIn("df_requires_essentials=''", self.script_all)
        self.assertIn("df_check_requires", self.script_all)
        # 树状内容条目: 多行整体作为一个选项
        self.assertIn("df_item_essentials=", self.script_all)
        self.assertIn("     ├─ htop", self.script_all)
        self.assertIn("     └─ jq", self.script_all)
        self.assertIn('eval "df_it=\\"\\$df_item_${df_n//-/_}\\""', self.script_all)
        # 降级模式与跳过选择
        self.assertIn("--no-tui)", self.script_all)
        self.assertIn("--yes|-y)", self.script_all)
        # 非 TTY 时安装全部模块
        self.assertIn('DF_PICKED=("${DF_MODULES[@]}")', self.script_all)

    def test_registry_assignments_executable(self):
        # 回归: 模块名含 '-' (如 cuda-toolkit) 时, 注册表变量名必须映射为 '_',
        # 否则 bash 会把 df_desc_xxx-toolkit=... 当作命令执行 (127)
        import re

        first_lines = [ln for ln in self.script_all.splitlines()
                       if re.match(r"^(df_desc_|df_requires_|df_item_|DF_SECTION_)", ln)]
        self.assertGreater(len(first_lines), 4)
        for ln in first_lines:
            self.assertNotIn("-", ln.split("=", 1)[0], f"变量名含 '-': {ln}")
        # df_item 是多行赋值, 只执行单行安全的注册表变量
        exec_lines = [ln for ln in first_lines if not ln.startswith("df_item_")]
        r = subprocess.run(
            ["bash", "-c", "\n".join(exec_lines) + "\necho REGISTRY_OK"],
            capture_output=True, text=True,
        )
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("REGISTRY_OK", r.stdout)

    def test_no_symlink_and_delim_unique(self):
        # 禁 dotfile 部署型软链 (目标指向 $HOME); 系统级二进制名兼容链接允许 (如 fdfind->fd)
        for line in self.script_all.splitlines():
            if line.lstrip().startswith(("ln -s", "sudo ln -s")):
                self.assertNotIn("$HOME", line, f"HOME 内不允许软链: {line}")
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
