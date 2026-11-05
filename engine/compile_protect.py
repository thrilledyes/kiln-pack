#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""把受保护的 .py 编译成原生扩展模块（.so），删除对应明文源码。

在镜像的构建阶段执行，不进入最终运行镜像。
用法:
    python compile_protect.py <SRC_ROOT> <glob> [<glob> ...]

对每个 glob 匹配到的 .py:
  1. 用 Cython 编译成同名 .so（import 方式完全不变）；
  2. strip 掉符号表；
  3. 删除原始 .py 和编译中间产物 .c。
最后做一次 import 自检：确保编译产物真的能被加载。
"""
import glob as globmod
import os
import subprocess
import sys


def run(cmd):
    print("+", " ".join(cmd), flush=True)
    subprocess.run(cmd, check=True)


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        sys.exit(2)
    root = os.path.abspath(sys.argv[1])
    patterns = sys.argv[2:]

    targets = []
    for pat in patterns:
        matches = sorted(globmod.glob(os.path.join(root, pat), recursive=True))
        if not matches:
            print(f"!! glob 没有匹配到任何文件: {pat}", file=sys.stderr)
            sys.exit(3)
        for m in matches:
            base = os.path.basename(m)
            if base == "__init__.py":
                print(f"!! 拒绝编译包初始化文件（容易出问题，见教程）: {m}", file=sys.stderr)
                sys.exit(4)
            targets.append(m)

    if not targets:
        print("没有需要编译的文件", file=sys.stderr)
        sys.exit(3)

    # 逐个编译成 .so。--no-docstrings 连文档字符串一起去掉，减少可读信息。
    for f in targets:
        run([sys.executable, "-m", "Cython.Build.Cythonize",
             "-3", "-i", "-q", "--no-docstrings", "-X", "binding=True", f])

    # strip 符号表（失败不致命，老镜像可能没有 strip）
    for dirpath, _dirs, files in os.walk(root):
        for fn in files:
            if fn.endswith(".so"):
                so = os.path.join(dirpath, fn)
                subprocess.run(["strip", so], check=False)

    # 删除明文源码与中间产物
    removed = []
    for f in targets:
        for ext in (".py", ".c"):
            p = os.path.splitext(f)[0] + ext
            if os.path.exists(p):
                os.remove(p)
                removed.append(p)
    print("已删除明文:", *[os.path.relpath(p, root) for p in removed])

    # 清理 Cython/distutils 的中间目录（inplace 编译会在工作目录留下 build/，
    # 里面是 .so 副本，不该进最终镜像）。
    import shutil
    build_dir = os.path.join(root, "build")
    if os.path.isdir(build_dir):
        shutil.rmtree(build_dir, ignore_errors=True)
        print("已清理中间目录:", os.path.relpath(build_dir, root))

    # 记录被保护文件清单（相对 root），供 verify.sh 精确核对，
    # 避免验收端再自行解释 glob，与实际编译结果保持一致。
    kiln_dir = os.path.join(root, ".kiln")
    if os.path.isdir(kiln_dir):
        rels = [os.path.relpath(t, root) for t in targets]
        with open(os.path.join(kiln_dir, "protected.list"), "w") as fh:
            for rel in rels:
                fh.write(rel + os.linesep)
        print("已记录受保护清单:", os.path.join(".kiln", "protected.list"))

    print("编译完成，产物:")
    for dirpath, _dirs, files in os.walk(root):
        for fn in sorted(files):
            if fn.endswith(".so"):
                print("  ", os.path.relpath(os.path.join(dirpath, fn), root))

    # import 自检：确保编译产物本身能被正常加载（不是语法上编过去就算完）。
    sys.path.insert(0, root)
    for f in targets:
        rel = os.path.relpath(f, root)
        mod = os.path.splitext(rel)[0].replace(os.sep, ".")
        try:
            __import__(mod)
        except Exception as e:  # noqa: BLE001
            print(f"!! 自检失败：import {mod} 出错: {e}", file=sys.stderr)
            sys.exit(5)
    print("import 自检通过:", ", ".join(
        os.path.splitext(os.path.relpath(f, root))[0].replace(os.sep, ".")
        for f in targets
    ))


if __name__ == "__main__":
    main()
