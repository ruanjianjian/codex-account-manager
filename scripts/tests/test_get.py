"""Offline checks for the one-line installer's network handling and language selection (no real downloads)."""
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / "get.sh"


class InstallerNetworkTests(unittest.TestCase):
    def run_installer(self, proxy_output, env_extra=None, languages='( "zh-Hans" )', defaults_status=0):
        with tempfile.TemporaryDirectory() as tmp:
            stubs = Path(tmp) / "bin"
            stubs.mkdir()
            log = Path(tmp) / "curl.log"
            stub = {
                "uname": 'case "$1" in -s) echo Darwin;; -m) echo arm64;; esac',
                "sw_vers": "echo 15.0",
                "defaults": f"cat <<'OUT'\n{languages}\nOUT\nexit {defaults_status}",
                "scutil": f"cat <<'OUT'\n{proxy_output}\nOUT",
                # Record what curl was asked and under which proxy, then fail like an unreachable host.
                "curl": f'echo "https_proxy=${{https_proxy:-}} all_proxy=${{all_proxy:-}} $*" >> "{log}"; exit 35',
            }
            for name, body in stub.items():
                path = stubs / name
                path.write_text("#!/bin/bash\n" + body + "\n")
                path.chmod(0o755)
            env = {"PATH": f"{stubs}:/usr/bin:/bin", "HOME": tmp, **(env_extra or {})}
            result = subprocess.run(["/bin/bash", str(SCRIPT)], env=env, capture_output=True, text=True, timeout=30)
            return result, log.read_text() if log.exists() else ""

    def assert_language(self, languages, expected, override=None, defaults_status=0):
        env = {"CODEX_ACCOUNTS_VERSION": "offline-test"}
        if override is not None:
            env["TIBOT_LANG"] = override
        result, calls = self.run_installer("", env, languages, defaults_status)
        self.assertEqual(result.returncode, 1)
        self.assertTrue(calls, "The stubbed download should be attempted")
        if expected == "en":
            self.assertEqual(result.stdout.splitlines()[0], "Downloading Tibot offline-test …")
            self.assertEqual(result.stderr.strip(), "Install not finished: Failed to download the app archive: "
                             "Cannot connect to GitHub. If you need a proxy to access GitHub, turn it on "
                             "(or set https_proxy in your terminal) and try again.")
        else:
            self.assertEqual(result.stdout.splitlines()[0], "下载 Tibot offline-test …")
            self.assertEqual(result.stderr.strip(), "安装未完成：安装包下载失败：连不上 GitHub。"
                             "如果平时要开代理才能上 GitHub，先打开代理（或在终端设置 https_proxy）再重试。")

    def test_english_without_chinese_language(self):
        self.assert_language('( "en-US", "ja-JP" )', "en")

    def test_chinese_anywhere_in_language_list(self):
        self.assert_language('(\n    "en-MF",\n    "zh-Hans-MF"\n)', "zh")

    def test_english_override(self):
        self.assert_language('( "en-MF", "zh-Hans-MF" )', "en", "en")

    def test_chinese_override(self):
        self.assert_language('( "en-US", "ja-JP" )', "zh", "zh")

    def test_defaults_failure_falls_back_to_english(self):
        self.assert_language('( "zh-Hans" )', "en", defaults_status=1)

    def test_overrides_when_defaults_fails(self):
        for lang in ("zh", "en"):
            with self.subTest(lang=lang):
                self.assert_language("", lang, lang, defaults_status=1)

    def test_invalid_override_uses_language_list(self):
        self.assert_language('( "en-MF", "zh-Hans-MF" )', "zh", "fr")

    def test_unquoted_chinese_language(self):
        self.assert_language('(en, zh)', "zh")

    def test_language_codes_ignore_case_like_the_app(self):
        self.assert_language('( "en-US", "ZH-Hans" )', "zh")

    def test_zh_inside_another_language_does_not_match(self):
        self.assert_language('( "en-zh" )', "en")

    def test_uses_system_proxy_and_never_the_api(self):
        proxy = "<dictionary> {\n  HTTPSEnable : 1\n  HTTPSPort : 7890\n  HTTPSProxy : 127.0.0.1\n}"
        result, calls = self.run_installer(proxy)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("使用系统代理 127.0.0.1:7890", result.stdout)
        self.assertIn("https_proxy=http://127.0.0.1:7890", calls)
        self.assertIn("github.com/ruanjianjian/codex-account-manager/releases/download/", calls)
        self.assertNotIn("api.github.com", calls)
        self.assertIn("先打开代理", result.stderr)

    def test_socks_only_proxy(self):
        proxy = "<dictionary> {\n  SOCKSEnable : 1\n  SOCKSPort : 1080\n  SOCKSProxy : 127.0.0.1\n}"
        _, calls = self.run_installer(proxy)
        self.assertIn("all_proxy=socks5h://127.0.0.1:1080", calls)

    def test_terminal_proxy_wins_over_system_proxy(self):
        proxy = "<dictionary> {\n  HTTPSEnable : 1\n  HTTPSPort : 7890\n  HTTPSProxy : 127.0.0.1\n}"
        result, calls = self.run_installer(proxy, {"https_proxy": "http://10.0.0.2:3128"})
        self.assertNotIn("使用系统代理", result.stdout)
        self.assertIn("https_proxy=http://10.0.0.2:3128", calls)

    def test_no_proxy_configured(self):
        result, calls = self.run_installer("<dictionary> {\n  HTTPEnable : 0\n}")
        self.assertNotIn("使用系统代理", result.stdout)
        self.assertIn("https_proxy= all_proxy= ", calls)


if __name__ == "__main__":
    unittest.main()
