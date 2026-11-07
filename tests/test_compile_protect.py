# SPDX-License-Identifier: Apache-2.0
"""检查 START_CMD 直接启动受保护模块的判断。

用法: python tests/test_compile_protect.py
"""
import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "engine"))

from compile_protect import protected_entries  # noqa: E402


class ProtectedEntries(unittest.TestCase):
    def check(self, start_cmd, expected):
        self.assertEqual(protected_entries(start_cmd, ["proj/prepare.py", "server.py", "pkg/__main__.py"]), expected)

    def test_module_entry_is_found(self):
        self.check("python -m proj.prepare", ["python -m proj.prepare"])

    def test_interpreter_variants(self):
        for py in ("python3", "python3.11", "/opt/conda/bin/python"):
            self.check(f"{py} -m proj.prepare --x 1", ["python -m proj.prepare"])

    def test_interpreter_options_are_skipped(self):
        self.check("python -u -m proj.prepare", ["python -m proj.prepare"])

    def test_inside_compound_command(self):
        self.check("export A=1; python -m proj.prepare && train", ["python -m proj.prepare"])

    def test_package_main_is_found(self):
        self.check("python -m pkg", ["python -m pkg"])

    def test_script_entry_is_found(self):
        self.check("python server.py --port 1", ["python server.py"])
        self.check("python /app/server.py", ["python /app/server.py"])

    def test_plain_entries_are_allowed(self):
        for cmd in (
            "python -m uvicorn server:app",
            "python -m trainer.train --steps 5",
            "python train.py",
            "uvicorn server:app",
            "llamafactory-cli train x.yaml",
        ):
            self.check(cmd, [])

    def test_python_c_is_allowed(self):
        self.check('python -c "from proj.prepare import main; main()" && train', [])

    def test_module_as_argument_is_not_an_entry(self):
        self.check("uvicorn proj.prepare:app", [])


if __name__ == "__main__":
    unittest.main()
