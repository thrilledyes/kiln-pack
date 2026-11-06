# SPDX-License-Identifier: Apache-2.0
"""kiln-pack 配置加密：密文落盘，运行时只在内存里解密。

打包阶段 encrypt_config.py 把 CONFIG_GLOBS 匹配的配置加密成 <原路径>.enc；
镜像里的训练代码这样读，拿到的是解析好的配置，明文不落盘：

    from kiln_config import load_yaml
    cfg = load_yaml("configs/recipe.yaml")

CONFIG_ENCRYPT=off 时镜像里是明文文件，同样的调用照常工作，项目代码不用改。
别在模块顶层读配置：builder 阶段的 import 自检拿不到密钥。

框架只接受配置文件路径时，launch.sh 用 materialize 把配置解密到内存盘（见 CONFIG_MATERIALIZE）。

密文格式：MAGIC(8) + nonce(12) + AES-256-GCM 密文和标签。
相对路径作为附加认证数据，把一份密文改名冒充另一份配置会解密失败。
"""
import base64
import binascii
import os
import shutil
import sys
import tempfile

MAGIC = b"KILNCFG1"
NONCE_LEN = 12
KEY_LEN = 32
KEY_ENV = "KILN_CONFIG_KEY"
ENC_SUFFIX = ".enc"
# /dev/shm 只作为 mkdtemp 的父目录：下面创建 0700 私有子目录、0600 文件，并强制校验 tmpfs。
SHM_DIR = "/dev/shm"  # NOSONAR(S5443)


class KilnConfigError(RuntimeError):
    """配置读取或解密失败。错误信息里不会带密钥和配置内容。"""


def _aesgcm(key):
    # 延迟导入：CONFIG_ENCRYPT=off 的镜像没有装 cryptography。
    from cryptography.hazmat.primitives.ciphers.aead import AESGCM

    return AESGCM(key)


def parse_key(text):
    """把 base64 文本解析成 32 字节密钥。"""
    try:
        key = base64.b64decode((text or "").strip(), validate=True)
    except (binascii.Error, ValueError):
        raise KilnConfigError(f"{KEY_ENV} 不是合法的 base64") from None
    if len(key) != KEY_LEN:
        raise KilnConfigError(f"{KEY_ENV} 解码后必须是 {KEY_LEN} 字节，可用 openssl rand -base64 32 生成")
    return key


def normalize_rel(rel):
    """规范化相对路径，拒绝绝对路径和跳出应用目录的路径。"""
    norm = os.path.normpath(rel).replace(os.sep, "/")
    if os.path.isabs(rel) or norm == "." or norm == ".." or norm.startswith("../"):
        raise KilnConfigError(f"配置路径必须是应用目录内的相对路径: {rel}")
    return norm


def _aad(rel):
    return MAGIC + normalize_rel(rel).encode("utf-8")


def encrypt_bytes(plaintext, key, rel):
    nonce = os.urandom(NONCE_LEN)
    return MAGIC + nonce + _aesgcm(key).encrypt(nonce, plaintext, _aad(rel))


def decrypt_bytes(blob, key, rel):
    from cryptography.exceptions import InvalidTag

    header = len(MAGIC) + NONCE_LEN
    if len(blob) < header or not blob.startswith(MAGIC):
        raise KilnConfigError(f"不是 kiln 配置密文: {rel}")
    try:
        return _aesgcm(key).decrypt(blob[len(MAGIC):header], blob[header:], _aad(rel))
    except InvalidTag:
        raise KilnConfigError(f"解密失败（密钥不对，或密文被改动/改名）: {rel}") from None


def _app_root():
    return os.environ.get("KILN_APP_ROOT", "/app")


def load(rel, root=None):
    """读取一份配置，返回明文 bytes。优先读密文，没有密文时读明文文件。"""
    rel = normalize_rel(rel)
    root = root or _app_root()
    enc_path = os.path.join(root, rel + ENC_SUFFIX)
    if os.path.exists(enc_path):
        text = os.environ.get(KEY_ENV)
        if not text:
            raise KilnConfigError(f"读取加密配置需要环境变量 {KEY_ENV}: {rel}")
        with open(enc_path, "rb") as f:
            return decrypt_bytes(f.read(), parse_key(text), rel)
    plain_path = os.path.join(root, rel)
    if os.path.exists(plain_path):
        with open(plain_path, "rb") as f:
            return f.read()
    raise KilnConfigError(f"找不到配置: {rel}")


def load_yaml(rel, root=None):
    """读取一份 YAML 配置并解析。需要项目在 requirements 里装 PyYAML。"""
    try:
        import yaml
    except ImportError:
        raise KilnConfigError("load_yaml 需要 PyYAML，请加进项目的 requirements") from None
    try:
        return yaml.safe_load(load(rel, root))
    except yaml.YAMLError as exc:
        # YAML 的报错会带上出错位置附近的内容，这里只留行列号，免得配置明文进日志。
        mark = getattr(exc, "problem_mark", None)
        where = f"第 {mark.line + 1} 行第 {mark.column + 1} 列" if mark else "位置未知"
        raise KilnConfigError(f"配置不是合法的 YAML（{where}）: {rel}") from None


def _mount_fstype(path, mounts_file="/proc/mounts"):
    """返回 path 所在挂载点的文件系统类型，查不到时返回 None。"""
    path = os.path.realpath(path)
    best, fstype = "", None
    with open(mounts_file, encoding="utf-8", errors="replace") as f:
        for line in f:
            fields = line.split()
            if len(fields) < 3:
                continue
            mount = fields[1].replace("\\040", " ")
            inside = path == mount or path.startswith(mount.rstrip("/") + "/")
            if inside and len(mount) >= len(best):
                best, fstype = mount, fields[2]
    return fstype


def materialize(rels, root=None, base_dir=SHM_DIR):
    """把配置解密成文件放到内存盘，返回目录。文件按原相对路径摆放。

    只写 tmpfs，明文绝不落到磁盘；目录 0700、文件 0600，只有当前用户读得到。
    """
    fstype = _mount_fstype(base_dir)
    if fstype != "tmpfs":
        raise KilnConfigError(f"{base_dir} 不是内存盘（{fstype}），拒绝把配置明文写上去")
    out_dir = tempfile.mkdtemp(prefix="kiln-config-", dir=base_dir)
    try:
        for rel in rels:
            rel = normalize_rel(rel)
            data = load(rel, root)
            path = os.path.join(out_dir, rel)
            os.makedirs(os.path.dirname(path), mode=0o700, exist_ok=True)
            fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            with os.fdopen(fd, "wb") as f:
                f.write(data)
    except BaseException:
        shutil.rmtree(out_dir, ignore_errors=True)
        raise
    return out_dir


def _main(argv):
    if len(argv) < 2 or argv[0] != "materialize":
        print("用法: python -m kiln_config materialize <相对路径>...", file=sys.stderr)
        return 2
    try:
        print(materialize(argv[1:]))
    except (KilnConfigError, OSError) as exc:
        print(f"[kiln] 解密配置失败: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(_main(sys.argv[1:]))
