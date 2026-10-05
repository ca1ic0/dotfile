import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from lib import manifest


def write_module(root: Path, name: str, toml: str, scripts: dict[str, str] | None = None) -> Path:
    d = root / name
    d.mkdir(parents=True, exist_ok=True)
    (d / "module.toml").write_text(toml, encoding="utf-8")
    for rel, content in (scripts or {}).items():
        target = d / rel
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(content, encoding="utf-8")
    return d


MINIMAL = """
[module]
name = "demo"

[debian]
install = "sudo apt-get install -y demo"
"""


class TestLoadModule(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.root = Path(self._tmp.name)

    def tearDown(self):
        self._tmp.cleanup()

    def test_minimal_defaults(self):
        m = manifest.load_module(write_module(self.root, "demo", MINIMAL))
        self.assertEqual(m.name, "demo")
        self.assertEqual(m.order, manifest.DEFAULT_ORDER)
        self.assertEqual(m.groups, ["base"])
        self.assertEqual(m.requires, [])
        recipes = {str(k): v for k, v in m.recipes.items()}
        self.assertEqual(recipes, {"debian": ["sudo apt-get install -y demo"]})

    def test_install_string_and_array_normalize(self):
        toml = """
[module]
name = "demo"

["rocky@8"]
install = ["echo a", "./scripts/x.sh", "echo b"]

[arch]
install = "echo c"
"""
        write_module(self.root, "demo", toml, {"scripts/x.sh": "#!/bin/bash\necho x\n"})
        m = manifest.load_module(self.root / "demo")
        recipes = {str(k): v for k, v in m.recipes.items()}
        self.assertEqual(recipes["rocky@8"], ["echo a", "./scripts/x.sh", "echo b"])
        self.assertEqual(recipes["arch"], ["echo c"])

    def test_errors(self):
        cases = {
            "name/dir 不一致": '[module]\nname = "other"\n\n[debian]\ninstall = "x"\n',
            "缺 install": '[module]\nname = "demo"\n\n[debian]\nfoo = 1\n',
            "install 类型错": '[module]\nname = "demo"\n\n[debian]\ninstall = 42\n',
            "install 空数组": '[module]\nname = "demo"\n\n[debian]\ninstall = []\n',
            "未知段键": '[module]\nname = "demo"\n\n[opensuse]\ninstall = "x"\n',
            "family 带版本": '[module]\nname = "demo"\n\n["redhat@9"]\ninstall = "x"\n',
            "段内未知字段": '[module]\nname = "demo"\n\n[debian]\ninstall = "x"\nnote = "hi"\n',
            "无 OS 段": '[module]\nname = "demo"\n',
            "groups 空": '[module]\nname = "demo"\ngroups = []\n\n[debian]\ninstall = "x"\n',
            "content 非数组": '[module]\nname = "demo"\ncontent = "htop"\n\n[debian]\ninstall = "x"\n',
            "content 含空串": '[module]\nname = "demo"\ncontent = ["htop", ""]\n\n[debian]\ninstall = "x"\n',
            "order 非整数": '[module]\nname = "demo"\norder = "9"\n\n[debian]\ninstall = "x"\n',
            "脚本不存在": '[module]\nname = "demo"\n\n[debian]\ninstall = "./scripts/none.sh"\n',
            "脚本越出模块目录": '[module]\nname = "demo"\n\n[debian]\ninstall = "./../outside.sh"\n',
        }
        for label, toml in cases.items():
            with self.subTest(label):
                write_module(self.root, "demo", toml)
                with self.assertRaises(manifest.ManifestError):
                    manifest.load_module(self.root / "demo")

    def test_load_all_duplicate_and_requires(self):
        write_module(self.root, "a", '[module]\nname = "a"\nrequires = ["nope"]\n\n[debian]\ninstall = "x"\n')
        write_module(self.root, "b", '[module]\nname = "a"\n\n[debian]\ninstall = "x"\n')
        with self.assertRaises(manifest.ManifestError):
            manifest.load_all(self.root)

    def test_load_all_skips_non_module_dirs(self):
        write_module(self.root, "demo", MINIMAL)
        (self.root / "notamodule").mkdir()
        modules = manifest.load_all(self.root)
        self.assertEqual([m.name for m in modules], ["demo"])


if __name__ == "__main__":
    unittest.main()
