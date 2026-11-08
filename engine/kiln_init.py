# SPDX-License-Identifier: Apache-2.0
"""容器的 PID 1：把停止信号转给作业，回收孤儿进程，原样传回退出码。

用法: python kiln_init.py <命令> [参数...]

不能直接 exec /bin/sh 起作业：dash 不会把最后一条命令 exec 掉，PID 1 还是 sh，而 PID 1
对没有处理函数的信号一律忽略，docker stop 的 SIGTERM 到不了作业，最后被 SIGKILL（退出码 137）。
也不能只在命令前加 exec：START_CMD 可能是复合命令，而且作业自己当 PID 1 时，没装信号处理函数就不会退出。

作业放进单独的进程组，信号发给整组，这样 sh 底下的进程也收得到。sh 自己也在组里，会先被信号杀掉，
所以收到过信号后要等整组都退完才能走：PID 1 一退，内核会把还在存 checkpoint 的进程强杀。
"""
import os
import signal
import subprocess
import sys
import time

FORWARDED = (
    signal.SIGTERM,
    signal.SIGINT,
    signal.SIGHUP,
    signal.SIGQUIT,
    signal.SIGUSR1,
    signal.SIGUSR2,
)


def exit_code(status):
    if os.WIFSIGNALED(status):
        return 128 + os.WTERMSIG(status)
    return os.WEXITSTATUS(status)


def group_alive(pgid):
    try:
        os.killpg(pgid, 0)
    except (ProcessLookupError, PermissionError):
        return False
    return True


def wait_for_group(pgid, status):
    """等进程组里剩下的进程退完，返回最后退出的那个进程的状态。"""
    while group_alive(pgid):
        try:
            pid, reaped = os.waitpid(-1, os.WNOHANG)
        except ChildProcessError:
            pid = 0
        if pid:
            status = reaped
        else:
            time.sleep(0.1)
    return status


def main(argv):
    if not argv:
        print("用法: python kiln_init.py <命令> [参数...]", file=sys.stderr)
        return 2

    job = []
    pending = []
    forwarded = []

    def forward(signum, _frame):
        # 信号可能在作业起来之前就到了，先记下来。
        if not job:
            pending.append(signum)
            return
        forwarded.append(signum)
        try:
            os.killpg(job[0], signum)
        except (ProcessLookupError, PermissionError):
            pass

    for signum in FORWARDED:
        signal.signal(signum, forward)

    try:
        proc = subprocess.Popen(argv, start_new_session=True)
    except OSError as exc:
        print(f"[kiln] 启动作业失败: {exc}", file=sys.stderr)
        return 127
    job.append(proc.pid)
    for signum in pending:
        forward(signum, None)

    # 作为 PID 1，所有孤儿进程都会挂到这里，一起回收；等到作业本身退出才结束。
    while True:
        pid, status = os.wait()
        if pid == proc.pid:
            break
    if forwarded:
        status = wait_for_group(proc.pid, status)
    return exit_code(status)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
