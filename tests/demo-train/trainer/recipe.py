# === PROPRIETARY ===
# 这个文件代表“训练侧必须保护的知识产权”：真实场景里对应自研的模型结构、
# 数据配方、loss 设计、学习率调度、单步训练逻辑（RL/蒸馏/量化等编排同理）。
# 打包后它绝不能以明文 .py 出现在镜像里——由 pack.conf 的 PROTECT_GLOBS 编成 .so。
#
# 注意（Cython + torch 的坑）：这里只“构造现成的 nn 类”（nn.Sequential），
# 不在本模块里定义自定义 nn.Module 子类。torch 的 Module 元类/__init_subclass__
# 机制和 Cython 编译的类容易相互别扭；把自定义子类留给明文入口或干脆不用，
# 编译面只放纯函数 + 现成类的构造，最稳。
#
# 敏感常量不写死在源码里——否则会被 Cython 连字符串常量一起编进 .so，strings 仍可抠出。
# 改为运行时从环境变量注入（见 train.py 读取 KILN_SECRET_MARKER）。
import math

import torch
from torch import nn


def build_model(dim: int, hidden: int) -> nn.Module:
    """自研模型结构（示意）。只用现成 nn 类拼装，避免在 Cython 模块里定义 Module 子类。"""
    return nn.Sequential(
        nn.Linear(dim, hidden),
        nn.ReLU(),
        nn.Linear(hidden, hidden),
        nn.ReLU(),
        nn.Linear(hidden, 1),
    )


def make_synthetic_batch(n: int, dim: int, seed: int, device):
    """数据配方（示意）：真实场景里这是你值钱的数据构造/混合/增广逻辑。

    这里造一个线性真相 + 噪声的回归批，保证模型可拟合、loss 可下降，便于冒烟验收。
    """
    g = torch.Generator().manual_seed(int(seed))
    x = torch.randn(n, dim, generator=g)
    w = torch.linspace(-1.0, 1.0, dim).unsqueeze(1)          # 固定“真相”权重
    y = x @ w + 0.05 * torch.randn(n, 1, generator=g)        # 加一点观测噪声
    return x.to(device), y.to(device)


def proprietary_loss(pred: torch.Tensor, target: torch.Tensor, delta: float) -> torch.Tensor:
    """自研 loss（示意）：一段带阈值的 Huber，代表“对异常样本更鲁棒”的自家设计。"""
    diff = pred - target
    absd = diff.abs()
    quad = torch.clamp(absd, max=delta)
    lin = absd - quad
    return (0.5 * quad * quad + delta * lin).mean()


def lr_schedule(step: int, total: int, base_lr: float, warmup_ratio: float) -> float:
    """自研学习率调度（示意）：先线性 warmup，之后余弦退火。"""
    warmup = max(1, int(total * warmup_ratio))
    if step <= warmup:
        return base_lr * step / warmup
    progress = (step - warmup) / max(1, total - warmup)
    return 0.5 * base_lr * (1.0 + math.cos(math.pi * progress))


def train_one_step(model: nn.Module, optimizer, batch, huber_delta: float) -> float:
    """单步训练逻辑（示意）：前向 → 自研 loss → 反向 → 更新。返回标量 loss。"""
    x, y = batch
    optimizer.zero_grad(set_to_none=True)
    pred = model(x)
    loss = proprietary_loss(pred, y, huber_delta)
    loss.backward()
    optimizer.step()
    return float(loss.detach())
