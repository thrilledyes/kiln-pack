# === PROPRIETARY ===
# 这个文件代表“必须保护的知识产权”：真实场景里对应推理框架的补丁、
# 自研调度/量化/路由逻辑等。打包后它绝不能以明文 .py 出现在镜像里。
# 下面这个独一无二的字符串用于验收脚本检测源码是否泄漏。
SECRET_MARKER = "SECRET_MARKER_DO_NOT_LEAK_7f3a9c"


def proprietary_score(prompt: str) -> float:
    """一段假装很值钱的打分逻辑，仅用于演示‘有源码就能被抄走’。"""
    acc = 0.0
    for i, ch in enumerate(prompt):
        acc += (ord(ch) * 7 + i * 3) % 13
    return round(acc / (len(prompt) or 1), 4)
