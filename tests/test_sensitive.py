# SPDX-License-Identifier: Apache-2.0
"""敏感文件规则的单元测试，用 bash 3.2 也支持的写法直接调 engine/sensitive.sh。

用法: python tests/test_sensitive.py
"""
import os
import subprocess
import tempfile
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
            "id_rsa", "home/id_ed25519", ".netrc", ".pypirc", ".npmrc", "pip.conf", ".git-credentials",
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

    def credential_lines(self, text):
        got = bash("printf '%s\\n' \"$1\" | kiln_lines_with_url_credentials || true", text)
        self.assertEqual(got.returncode, 0, got.stderr)
        return got.stdout.split()

    def test_urls_with_credentials_are_found(self):
        for url in (
            "--extra-index-url https://user:pass@pypi.example.com/simple",
            "--index-url=http://token@pypi.example.com/simple",
            "pkg @ git+https://x-access-token:abc@github.com/o/r.git",
            "pkg @ git+ssh://git:secret@host/r.git",
            "# https://user:pass@old.example.com/simple",
        ):
            self.assertEqual(self.credential_lines(url), ["1"], url)

    def test_urls_without_credentials_are_allowed(self):
        for url in (
            "torch==2.5.1",
            "--extra-index-url https://pypi.example.com/simple",
            "--extra-index-url https://pypi.example.com:8443/simple",
            "pkg @ git+ssh://git@github.com/o/r.git",
            "pkg @ https://example.com/pkg-1.0.tar.gz",
            "--index-url https://${PIP_USER}:${PIP_TOKEN}@pypi.example.com/simple",
            "--index-url https://${PIP_TOKEN}@pypi.example.com/simple",
        ):
            self.assertEqual(self.credential_lines(url), [], url)

    def test_credentials_found_only_by_line_number(self):
        got = self.credential_lines("ok==1\n--index-url https://u:secretvalue@x.example/simple\nok2==1")
        self.assertEqual(got, ["2"])

    def test_nested_requirements_are_scanned(self):
        with tempfile.TemporaryDirectory() as tmp:
            os.mkdir(os.path.join(tmp, "sub"))
            files = {
                "requirements.txt": "-r sub/base.txt\n--constraint=c.txt\nsix==1.16.0\n",
                "sub/base.txt": "--index-url https://u:p@x.example/simple\n-r ../requirements.txt\n",
                "c.txt": "a==1\nb @ https://t@x.example/b.whl\n",
            }
            for name, text in files.items():
                with open(os.path.join(tmp, name), "w", encoding="utf-8") as f:
                    f.write(text)
            got = bash(f'cd "{tmp}" && kiln_requirements_credentials requirements.txt')
            self.assertEqual(got.returncode, 0, got.stderr)
            # 互相引用不能死循环。
            self.assertEqual(sorted(got.stdout.split()), ["c.txt:2", "sub/base.txt:1"])

    def test_clean_requirements_print_nothing(self):
        with tempfile.TemporaryDirectory() as tmp:
            with open(os.path.join(tmp, "r.txt"), "w", encoding="utf-8") as f:
                f.write("-r missing.txt\nsix==1.16.0\n")
            got = bash(f'cd "{tmp}" && kiln_requirements_credentials r.txt')
            self.assertEqual((got.returncode, got.stdout), (0, ""), got.stderr)

    def test_generated_arguments_have_no_trailing_or(self):
        got = bash('printf "%s\\n" "${KILN_SENSITIVE_FIND_ARGS[@]}"')
        lines = got.stdout.split("\n")
        self.assertNotEqual([x for x in lines if x][-1], "-o")


if __name__ == "__main__":
    unittest.main()
