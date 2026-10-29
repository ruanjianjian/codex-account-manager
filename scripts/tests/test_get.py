"""Offline checks for the one-line installer's network handling (no real downloads)."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / "get.sh"


class InstallerNetworkTests(unittest.TestCase):
    def run_installer(self, proxy_output, env_extra=None):
        with tempfile.TemporaryDirectory() as tmp:
            stubs = Path(tmp) / "bin"
            stubs.mkdir()
            log = Path(tmp) / "curl.log"
            stub = {
                "uname": 'case "$1" in -s) echo Darwin;; -m) echo arm64;; esac',
                "sw_vers": "echo 15.0",
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
