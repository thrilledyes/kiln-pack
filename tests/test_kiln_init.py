# SPDX-License-Identifier: Apache-2.0
"""kiln_init 的单元测试：信号要到得了 sh 底下的进程，退出码要原样传回。

用法: python tests/test_kiln_init.py
"""
import os
import signal
import subprocess
import sys
import tempfile
import time
import unittest

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
INIT = os.path.join(ROOT, "engine", "kiln_init.py")

# 作业收到 SIGTERM 后慢慢写文件再退出，模拟训练存 checkpoint。
HANDLER = """
import signal, sys, time
def on_term(*_):
    time.sleep(1)
    open(sys.argv[1], "w").write("got")
    sys.exit(0)
signal.signal(signal.SIGTERM, on_term)
open(sys.argv[2], "w").write("ready")
time.sleep(60)
"""


def wait_for(path, seconds=10):
    deadline = time.time() + seconds
    while time.time() < deadline:
        if os.path.exists(path):
            return True
        time.sleep(0.05)
    return False


class KilnInit(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)

    def path(self, name):
        return os.path.join(self.tmp.name, name)

    def start(self, shell_cmd):
        return subprocess.Popen([sys.executable, INIT, "/bin/sh", "-c", shell_cmd])

    def test_exit_code_is_passed_through(self):
        proc = self.start("exit 7")
        self.assertEqual(proc.wait(timeout=10), 7)

    def test_missing_command_returns_127(self):
        rc = subprocess.call(
            [sys.executable, INIT, self.path("no-such-command")],
            stderr=subprocess.DEVNULL,
        )
        self.assertEqual(rc, 127)

    def test_no_arguments_is_usage_error(self):
        rc = subprocess.call([sys.executable, INIT], stderr=subprocess.DEVNULL)
        self.assertEqual(rc, 2)

    def run_job_with_handler(self, template):
        script = self.path("job.py")
        with open(script, "w", encoding="utf-8") as f:
            f.write(HANDLER)
        got, ready = self.path("got"), self.path("ready")
        job = f'"{sys.executable}" "{script}" "{got}" "{ready}"'
        proc = self.start(template.format(job=job))
        self.assertTrue(wait_for(ready), "作业没有起来")
        proc.send_signal(signal.SIGTERM)
        return proc.wait(timeout=10), got

    # 下面两个用例的关键是 kiln_init 退出时作业已经写完文件：sh 会先被信号杀掉，不能跟着它一起走。
    # 退出码不查：这里 kiln_init 不是 PID 1，回收不到孤儿进程。容器里的退出码由 tests/acceptance.sh 验证。
    def test_sigterm_reaches_process_under_shell(self):
        _rc, got = self.run_job_with_handler("{job}")
        self.assertTrue(os.path.exists(got), "kiln_init 退出时作业还没存完")

    def test_sigterm_reaches_compound_command(self):
        _rc, got = self.run_job_with_handler("export KILN_X=1; {job}; echo done > /dev/null")
        self.assertTrue(os.path.exists(got), "kiln_init 退出时复合命令里的作业还没存完")

    def test_stragglers_do_not_block_normal_exit(self):
        # 没收到过信号时，作业退出就结束，不等它留在后台的进程。
        proc = self.start("sleep 30 & exit 5")
        self.assertEqual(proc.wait(timeout=5), 5)

    def test_job_without_handler_is_terminated(self):
        ready = self.path("ready")
        proc = self.start(f': > "{ready}"; exec sleep 60')
        self.assertTrue(wait_for(ready))
        time.sleep(0.2)
        proc.send_signal(signal.SIGTERM)
        self.assertEqual(proc.wait(timeout=10), 128 + signal.SIGTERM)


if __name__ == "__main__":
    unittest.main()
