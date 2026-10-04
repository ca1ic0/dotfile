import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from lib import distro


class TestVersion(unittest.TestCase):
    def test_parse_version(self):
        self.assertEqual(distro.parse_version("22.04"), (22, 4))
        self.assertEqual(distro.parse_version("8"), (8,))
        self.assertEqual(distro.parse_version("8.7"), (8, 7))
        self.assertIsNone(distro.parse_version("rolling"))
        self.assertIsNone(distro.parse_version(""))
        self.assertIsNone(distro.parse_version("tests"))


class TestSectionKey(unittest.TestCase):
    def test_family(self):
        self.assertEqual(str(distro.parse_section_key("debian")), "debian")
        self.assertEqual(str(distro.parse_section_key(" RedHat ")), "redhat")

    def test_distro(self):
        self.assertEqual(str(distro.parse_section_key("rocky")), "rocky")
        self.assertEqual(str(distro.parse_section_key("Ubuntu")), "ubuntu")

    def test_versioned(self):
        self.assertEqual(str(distro.parse_section_key("rocky@8")), "rocky@8")
        self.assertEqual(str(distro.parse_section_key("Ubuntu@22.04")), "ubuntu@22.04")

    def test_numeric_equality(self):
        # 8.0 与 8 数值相等 (相等性不看原始写法)
        self.assertEqual(distro.parse_section_key("rocky@8"), distro.parse_section_key("rocky@8.0"))
        self.assertNotEqual(distro.parse_section_key("ubuntu@22.04"), distro.parse_section_key("ubuntu@22"))

    def test_invalid(self):
        for bad in ["", "opensuse", "debian@12", "rocky@8@9", "rocky@x", "rocky@8."]:
            with self.assertRaises(ValueError, msg=bad):
                distro.parse_section_key(bad)


class TestTarget(unittest.TestCase):
    def test_parse_target(self):
        t = distro.parse_target("Ubuntu@22.04")
        self.assertEqual((t.id, t.family, t.version), ("ubuntu", "debian", (22, 4)))
        self.assertEqual(str(t), "ubuntu@22.04")

    def test_arch_is_distro_not_family(self):
        # arch 既是 distro id 又是 family 名, 应按 distro 解析
        t = distro.parse_target("arch")
        self.assertEqual((t.id, t.family, t.version), ("arch", "arch", None))
        self.assertEqual(str(t), "arch")

    def test_errors(self):
        # 注: debian/arch 既是 distro id 又是 family 名, 作为 --target 合法
        for bad in ["", "redhat", "opensuse", "rocky@8@9", "rocky@abc"]:
            with self.assertRaises(distro.TargetError, msg=bad):
                distro.parse_target(bad)


class TestLookupChain(unittest.TestCase):
    def _chain(self, spec: str) -> list[str]:
        return [str(k) for k in distro.lookup_chain(distro.parse_target(spec))]

    def test_ubuntu(self):
        self.assertEqual(
            self._chain("ubuntu@22.04"),
            ["ubuntu@22.04", "ubuntu@22", "ubuntu", "debian"],
        )

    def test_rocky_minor(self):
        self.assertEqual(
            self._chain("rocky@8.7"),
            ["rocky@8.7", "rocky@8", "rocky", "redhat"],
        )

    def test_arch_no_version(self):
        self.assertEqual(self._chain("arch"), ["arch"])


class TestDetect(unittest.TestCase):
    def _detect(self, content: str):
        import tempfile

        with tempfile.NamedTemporaryFile("w", suffix=".release", delete=False) as f:
            f.write(content)
            path = f.name
        try:
            return distro.detect(path)
        finally:
            Path(path).unlink(missing_ok=True)

    def test_ubuntu(self):
        t = self._detect('ID="ubuntu"\nID_LIKE=debian\nVERSION_ID="22.04"\n')
        self.assertEqual((t.id, t.family, t.version), ("ubuntu", "debian", (22, 4)))

    def test_rocky_id_like_fallback(self):
        t = self._detect('ID="rocky"\nID_LIKE="rhel centos fedora"\nVERSION_ID="8.7"\n')
        self.assertEqual((t.id, t.family, t.version), ("rocky", "redhat", (8, 7)))

    def test_rolling(self):
        t = self._detect("ID=arch\nID_LIKE=...\nVERSION_ID=rolling\n")
        self.assertEqual((t.id, t.family, t.version), ("arch", "arch", None))

    def test_unknown(self):
        with self.assertRaises(distro.TargetError):
            self._detect('ID="opensuse"\nID_LIKE="suse"\n')

    def test_missing_file(self):
        with self.assertRaises(distro.TargetError):
            distro.detect("/nonexistent/os-release")


if __name__ == "__main__":
    unittest.main()
