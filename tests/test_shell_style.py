# SPDX-License-Identifier: Apache-2.0
"""检查 shell 脚本里没有变量紧贴多字节字符的写法。

macOS 自带 bash 3.2 会把紧跟在变量后面的多字节字符吞进变量名，set -u 下脚本直接退出。
这个坑踩过两次，所以变量后面紧跟中文时一律写成 ${VAR}。

用法: python tests/test_shell_style.py
"""
import os
import re
import unittest

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
BARE_VAR_BEFORE_MULTIBYTE = re.compile(r"\$[A-Za-z_][A-Za-z0-9_]*(?=[^\x00-\x7f])")


class ShellStyle(unittest.TestCase):
    def test_no_bare_variable_before_multibyte(self):
        hits = []
        for directory, _, names in os.walk(ROOT):
            for name in names:
                if not name.endswith(".sh"):
                    continue
                path = os.path.join(directory, name)
                with open(path, encoding="utf-8") as f:
                    for number, line in enumerate(f, 1):
                        if not line.lstrip().startswith("#") and BARE_VAR_BEFORE_MULTIBYTE.search(line):
                            hits.append(f"{os.path.relpath(path, ROOT)}:{number}: {line.strip()}")
        self.assertEqual(hits, [])

    def test_pattern_catches_the_bug(self):
        self.assertTrue(BARE_VAR_BEFORE_MULTIBYTE.search('bad "退出（码 $RC）"'))
        self.assertFalse(BARE_VAR_BEFORE_MULTIBYTE.search('bad "退出（码 ${RC}）"'))


if __name__ == "__main__":
    unittest.main()
