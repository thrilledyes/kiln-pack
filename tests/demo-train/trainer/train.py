"""训练入口（明文薄壳）。

真实项目里这里是训练作业的编排层：解析配置、初始化分布式、搭 optimizer、
跑训练循环、存 checkpoint、落日志——这些没有 IP 价值，留明文方便运维排查。
值钱的东西（模型结构、数据配方、loss、调度、单步逻辑）都在 trainer.recipe 里，
打包时被编成 .so；这里 import 方式完全不变。

入口薄壳刻意留明文的另一个原因：torchrun / 多进程会重新 import 入口模块，
带 `if __name__ == "__main__"` 的入口脚本经不起 Cython 编译 + spawn 的折腾。
"""
import argparse
import os

import torch

from trainer import recipe


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--steps", type=int, default=int(os.environ.get("KILN_STEPS", "50")))
    ap.add_argument("--dim", type=int, default=16)
    ap.add_argument("--batch", type=int, default=64)
    ap.add_argument("--lr", type=float, default=0.1)
    args = ap.parse_args()

    # 演示密钥外置：缺失时 launch.sh 已拦截起训；这里读一次，证明运行期注入可用。
    # 真实场景这类值用于拉私有数据/上报等，绝不写死进源码。
    _marker = os.environ.get("KILN_SECRET_MARKER", "")

    # 分布式自适应：torchrun 会设 RANK/WORLD_SIZE/LOCAL_RANK；单机直接跑。
    world_size = int(os.environ.get("WORLD_SIZE", "1"))
    rank = int(os.environ.get("RANK", "0"))
    is_dist = world_size > 1
    if is_dist:
        # CPU 用 gloo；真实 GPU 训练换 nccl（需 CUDA 底座 + --gpus）。
        torch.distributed.init_process_group(backend="gloo")

    torch.manual_seed(1234 + rank)
    device = torch.device("cpu")

    model = recipe.build_model(args.dim).to(device)
    if is_dist:
        model = torch.nn.parallel.DistributedDataParallel(model)
    optimizer = torch.optim.SGD(model.parameters(), lr=args.lr)

    out_dir = os.environ.get("KILN_OUTPUT_DIR", "/workspace/output")
    os.makedirs(out_dir, exist_ok=True)

    if rank == 0:
        print(f"[train] 开始训练 steps={args.steps} dim={args.dim} batch={args.batch} "
              f"world_size={world_size} device={device}", flush=True)

    for step in range(1, args.steps + 1):
        batch = recipe.make_synthetic_batch(args.batch, args.dim, seed=step, device=device)
        lr = recipe.lr_schedule(step, args.steps, args.lr)
        for group in optimizer.param_groups:
            group["lr"] = lr
        loss = recipe.train_one_step(model, optimizer, batch)
        if rank == 0:
            print(f"[train] step={step} lr={lr:.5f} loss={loss:.6f}", flush=True)

    if rank == 0:
        ckpt_path = os.path.join(out_dir, "ckpt.pt")
        state = model.module.state_dict() if is_dist else model.state_dict()
        torch.save(
            {
                "model": state,
                "app": os.environ.get("KILN_APP", "demo-train"),
                "version": os.environ.get("KILN_VERSION", "dev"),
                "build_id": os.environ.get("KILN_BUILD_ID", "unknown"),
                "steps": args.steps,
            },
            ckpt_path,
        )
        print(f"[train] 训练完成，checkpoint 已保存: {ckpt_path}", flush=True)

    if is_dist:
        torch.distributed.destroy_process_group()


if __name__ == "__main__":
    main()
