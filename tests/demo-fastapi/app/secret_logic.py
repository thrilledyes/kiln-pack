# === PROPRIETARY ===
# 这个文件代表“必须保护的知识产权”：真实场景里对应推理框架的补丁、
# 自研调度/量化/路由逻辑等。打包后它绝不能以明文 .py 出现在镜像里。
#
# 敏感常量不写死在源码里——否则会被 Cython 连同字符串常量一起编进 .so，
# strings 仍可抠出（见 README“边界”一节）。改为运行时从环境变量注入，
# 这样镜像/归档里 grep 不到真实值，verify.sh 第 3 步据此检查。
import os

# 由 pack.conf 的 REQUIRED_ENV 声明、launch.sh 启动前校验：缺失即拒绝起服。
SECRET_MARKER = os.environ.get("KILN_SECRET_MARKER", "")


def proprietary_score(prompt: str) -> float:
    """一段假装很值钱的打分逻辑，仅用于演示‘有源码就能被抄走’。"""
    acc = 0.0
    for i, ch in enumerate(prompt):
        acc += (ord(ch) * 7 + i * 3) % 13
    return round(acc / (len(prompt) or 1), 4)
