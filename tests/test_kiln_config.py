# SPDX-License-Identifier: Apache-2.0
"""配置加密的单元测试。需要 cryptography 和 PyYAML，不需要 Docker。

用法: python tests/test_kiln_config.py
"""
import base64
import os
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "engine"))

import encrypt_config  # noqa: E402
import kiln_config  # noqa: E402

REL = "configs/recipe.yaml"
PLAIN = b"recipe_tag: VALUE_THAT_MUST_NOT_LEAK\ntrain:\n  batch: 64\n"


def new_key_text():
    return base64.b64encode(os.urandom(32)).decode()


class Base(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.src = os.path.join(tmp.name, "src")
        self.out = os.path.join(tmp.name, "out")
        os.makedirs(os.path.join(self.src, "configs"))
        with open(os.path.join(self.src, REL), "wb") as f:
            f.write(PLAIN)
        self.key = new_key_text()

    def env(self, key):
        env = {kiln_config.KEY_ENV: key} if key else {}
        patch = mock.patch.dict(os.environ, env)
        patch.start()
        self.addCleanup(patch.stop)
        if not key:
            os.environ.pop(kiln_config.KEY_ENV, None)

    def encrypt(self):
        self.env(self.key)
        rc = encrypt_config.main(["encrypt_config.py", self.src, self.out, REL])
        self.assertEqual(rc, 0)
        return os.path.join(self.out, REL + kiln_config.ENC_SUFFIX)

    def assert_load_fails(self, rel=REL):
        with self.assertRaises(kiln_config.KilnConfigError) as cm:
            kiln_config.load(rel, self.out)
        return str(cm.exception)


class RoundTrip(Base):
    def test_load_returns_plaintext(self):
        self.encrypt()
        self.assertEqual(kiln_config.load(REL, self.out), PLAIN)

    def test_load_yaml_parses(self):
        self.encrypt()
        cfg = kiln_config.load_yaml(REL, self.out)
        self.assertEqual(cfg["train"]["batch"], 64)

    def test_ciphertext_hides_plaintext(self):
        with open(self.encrypt(), "rb") as f:
            blob = f.read()
        self.assertTrue(blob.startswith(kiln_config.MAGIC))
        self.assertNotIn(b"VALUE_THAT_MUST_NOT_LEAK", blob)
        self.assertNotIn(b"batch", blob)

    def test_nonce_differs_between_runs(self):
        path = self.encrypt()
        with open(path, "rb") as f:
            first = f.read()
        self.encrypt()
        with open(path, "rb") as f:
            self.assertNotEqual(first, f.read())

    def test_plaintext_fallback_without_ciphertext(self):
        self.env(None)
        self.assertEqual(kiln_config.load(REL, self.src), PLAIN)


class Rejects(Base):
    def test_wrong_key(self):
        self.encrypt()
        self.env(new_key_text())
        self.assertIn("解密失败", self.assert_load_fails())

    def test_missing_key(self):
        self.encrypt()
        self.env(None)
        self.assertIn(kiln_config.KEY_ENV, self.assert_load_fails())

    def test_tampered_ciphertext(self):
        path = self.encrypt()
        with open(path, "rb") as f:
            blob = bytearray(f.read())
        blob[-1] ^= 1
        with open(path, "wb") as f:
            f.write(blob)
        self.assertIn("解密失败", self.assert_load_fails())

    def test_renamed_ciphertext(self):
        path = self.encrypt()
        os.rename(path, os.path.join(self.out, "configs", "other.yaml.enc"))
        self.assertIn("解密失败", self.assert_load_fails("configs/other.yaml"))

    def test_not_ciphertext(self):
        path = self.encrypt()
        with open(path, "wb") as f:
            f.write(b"plain text pretending to be encrypted")
        self.assertIn("不是 kiln 配置密文", self.assert_load_fails())

    def test_bad_key_formats(self):
        for bad in ["", "not base64!!", base64.b64encode(b"short").decode()]:
            with self.subTest(bad=bad), self.assertRaises(kiln_config.KilnConfigError):
                kiln_config.parse_key(bad)

    def test_path_escape(self):
        for bad in ["../secret.yaml", "/etc/passwd", "configs/../../x", ".", ""]:
            with self.subTest(bad=bad), self.assertRaises(kiln_config.KilnConfigError):
                kiln_config.normalize_rel(bad)

    def test_invalid_yaml_error_hides_content(self):
        self.env(None)
        with open(os.path.join(self.src, "bad.yaml"), "wb") as f:
            f.write(b"VALUE_THAT_MUST_NOT_LEAK: [unclosed\n")
        with self.assertRaises(kiln_config.KilnConfigError) as cm:
            kiln_config.load_yaml("bad.yaml", self.src)
        self.assertNotIn("VALUE_THAT_MUST_NOT_LEAK", str(cm.exception))

    def test_encrypt_tool_rejects_bad_key(self):
        self.key = "not base64!!"
        self.env(self.key)
        rc = encrypt_config.main(["encrypt_config.py", self.src, self.out, REL])
        self.assertEqual(rc, 1)
        self.assertFalse(os.path.exists(os.path.join(self.out, REL + kiln_config.ENC_SUFFIX)))


if __name__ == "__main__":
    unittest.main()
