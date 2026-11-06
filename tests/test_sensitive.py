# SPDX-License-Identifier: Apache-2.0
"""敏感文件规则的单元测试，用 bash 3.2 也支持的写法直接调 engine/sensitive.sh。

用法: python tests/test_sensitive.py
"""
import os
import subprocess
import unittest

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
SENSITIVE = os.path.join(ROOT, "engine", "sensitive.sh")


def bash(script, *args):
    full = f'set -euo pipefail; source "{SENSITIVE}"; {script}'
    return subprocess.run(
        ["bash", "-c", full, "bash", *args],
        capture_output=True,
        text=True,
        check=False,
    )


class Sensitive(unittest.TestCase):
    def assertSensitive(self, rel):
        self.assertEqual(bash('kiln_sensitive_match "$1"', rel).returncode, 0, rel)

    def assertNotSensitive(self, rel):
        self.assertEqual(bash('kiln_sensitive_match "$1"', rel).returncode, 1, rel)

    def test_sensitive_names(self):
        for rel in (
            ".env", "sub/.env", "prod.env", ".env.local", ".envrc",
            "server.pem", "a/b/tls.key", "c.p12", "d.pfx", "e.jks", "f.keystore",
            "id_rsa", "home/id_ed25519", ".netrc", ".pypirc", ".npmrc", ".git-credentials",
            "credentials.json", "service-account-prod.json",
        ):
            self.assertSensitive(rel)

    def test_sensitive_dirs(self):
        for rel in (".ssh/config", "a/.aws/credentials", ".gnupg/pubring.kbx"):
            self.assertSensitive(rel)

    def test_ordinary_files_are_not_sensitive(self):
        for rel in (
            "app/server.py", "environment.yml", "my.env.py", "keys.py", "monkey.txt",
            "configs/recipe.yaml", ".kiln/launch.sh", "ssh/readme.md", "id_rsa.pub",
        ):
            self.assertNotSensitive(rel)

    def test_encrypted_files_are_not_sensitive(self):
        for rel in ("configs/.env.enc", "tls.key.enc"):
            self.assertNotSensitive(rel)

    def test_listing_respects_keep(self):
        listing = "/app/a.py\n/app/.env\n/app/certs/ca.pem\n/app/certs/x.key"
        got = bash('kiln_sensitive_in_listing "$1" "$2"', listing, "certs/ca.pem\ncerts/other.pem")
        self.assertEqual(got.returncode, 0, got.stderr)
        self.assertEqual(got.stdout.split(), ["/app/.env", "/app/certs/x.key"])

    def test_listing_keep_needs_exact_path(self):
        got = bash('kiln_sensitive_in_listing "$1" "$2"', "/app/sub/ca.pem", "ca.pem")
        self.assertEqual(got.stdout.split(), ["/app/sub/ca.pem"])

    def test_generated_arguments_have_no_trailing_or(self):
        got = bash('printf "%s\\n" "${KILN_SENSITIVE_FIND_ARGS[@]}"')
        lines = got.stdout.split("\n")
        self.assertNotEqual([x for x in lines if x][-1], "-o")


if __name__ == "__main__":
    unittest.main()
