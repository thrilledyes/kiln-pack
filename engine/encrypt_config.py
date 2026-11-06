# SPDX-License-Identifier: Apache-2.0
"""打包阶段的配置加密工具：由 pack.sh 放进断网的一次性容器里运行。

用法: encrypt_config.py <明文根目录> <输出根目录> <相对路径>...
密钥从环境变量 KILN_CONFIG_KEY 读取，不经过命令行和 docker build。
"""
import os
import sys

from kiln_config import KEY_ENV, ENC_SUFFIX, KilnConfigError, encrypt_bytes, normalize_rel, parse_key


def main(argv):
    if len(argv) < 4:
        print(__doc__, file=sys.stderr)
        return 2
    src_root, out_root, rels = argv[1], argv[2], argv[3:]
    try:
        key = parse_key(os.environ.get(KEY_ENV))
        for rel in rels:
            rel = normalize_rel(rel)
            with open(os.path.join(src_root, rel), "rb") as f:
                blob = encrypt_bytes(f.read(), key, rel)
            out_path = os.path.join(out_root, rel + ENC_SUFFIX)
            os.makedirs(os.path.dirname(out_path), exist_ok=True)
            with open(out_path, "wb") as f:
                f.write(blob)
            print(f"  已加密: {rel} -> {rel}{ENC_SUFFIX}")
    except (KilnConfigError, OSError) as exc:
        print(f"!! 配置加密失败: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
