# kiln-pack

通用 **Docker 二进制打包器**，支持两种交付形态：

- **serve** —— 常驻推理服务（vLLM / SGLang / 自研编排）：起服 + 健康检查 + 接口验收；
- **train** —— 训练作业：按启动器起训 + 冒烟训练验收。

核心一致：把值钱的 Python 源码在构建阶段用 Cython 编译成原生扩展（`.so`），最终镜像里只留二进制——
源码不进镜像、不随交付物外发，服务/作业照常可跑、可查版本。面向「上生产但不暴露自研逻辑」的场景。

## 布局

```
engine/   公共引擎（与交付形态无关）
  pack.sh              主入口：读一份 pack.conf，按 PROFILE 选形态，产出镜像并验收
  compile_protect.py   用 Cython 把受保护 .py 编成 .so，strip 符号、删明文与 .c

profiles/ 两种交付形态，各自的 Dockerfile + 启动/验收脚本
  serve/   常驻服务：Dockerfile（非 root 只读）/ launch.sh / healthcheck.sh / verify.sh
  train/   训练作业：Dockerfile（可写产物目录、无 HEALTHCHECK）/ launch.sh（LAUNCHER 分支）/ verify.sh（冒烟训练）

tests/    测试环境（独立于引擎）
  demo-fastapi/  最小 FastAPI 样例（PROFILE=serve），含受保护的打分逻辑
  demo-train/    最小 CPU torch 训练样例（PROFILE=train），受保护模块含模型/数据/loss/调度/单步逻辑
```

## 用法

```bash
# 推理服务：
bash engine/pack.sh tests/demo-fastapi
# 训练作业：
bash engine/pack.sh tests/demo-train
```

交付形态由 `pack.conf` 里的 `PROFILE` 决定（不写默认 `serve`，兼容旧配置）。
换框架/项目时通常只写一份新的 `pack.conf`，`engine/` 与 `profiles/` 一字不动。

## train profile 要点

- **只保护真正的 IP 模块**：模型结构、数据配方、loss、调度、单步训练逻辑编成 `.so`；
  入口 `train.py` 刻意留明文——`torchrun` 会重新 import 入口模块、DataLoader spawn 子进程也要能 import，
  带 `if __name__=="__main__"` 的入口脚本经不起 Cython 编译 + 多进程的折腾。
- **启动器**：`LAUNCHER=single`（单进程）或 `torchrun`（单机多进程，`--standalone` 自带 rendezvous）；
  `deepspeed` / `accelerate` 已留分支占位，v1 未实装。demo 的 `train.py` 已兼容 torchrun（读 `RANK`/`WORLD_SIZE`）。
- **数据进、产物出全走挂载卷**：镜像不烘任何数据；checkpoint/日志落到 `OUTPUT_DIR`（默认 `/workspace/output`），
  运行时用 `-v` 挂到宿主取回。代码 `/app` 仍只读，只有产物目录和框架缓存可写。
- **验收 = 冒烟训练**：跑一个短作业，断言「正常退出 + 落下 checkpoint + loss 有限且下降」，而非打接口。
- **GPU**：demo 用 CPU torch 跑通流程（无卡环境即可验收）。真实训练把 `RUNTIME_BASE`/`BUILDER_BASE`
  换成带 CUDA/ROCm/CANN 的框架镜像，运行时加 `--gpus`，`init_process_group` 换 `nccl`/`hccl`。

## 通用性

- **serve** 已在 vLLM / SGLang 生态上验证过完整打包流程（受保护模块真实 import 框架 API，编成 `.so` 组装进镜像）。
- **train** 目前以 CPU torch demo 验证了完整链路（编译保护 → 起训 → 冒烟验收）；真实 GPU/CANN 框架的打包待在有卡环境验证。

## 边界

- 保护的是**代码逻辑**，不是字符串常量：硬编码密钥用 `strings` 仍可从 `.so` 抠出，敏感常量走 `REQUIRED_ENV` 外置。
- **配置/数据不等于代码**：训练的数据配比、超参配方常躺在 YAML/JSON 里，Cython 保护不了它们。
  `pack.conf` 的 `CONFIG_ENCRYPT` 是预留开关位，**v1 必须为 `off`**，配置/数据的真加密（密文落盘 + 运行时解密）规划在 v2。
- **与 `torch.compile` 的张力**：dynamo 追踪 Python 字节码，编成 `.so` 的模块它无法追踪，会 graph-break 退回 eager。
  最想保护的热点逻辑和最想被 compile 优化的往往是同一块，需按场景二选一。
- `.so` 认平台和 Python 版本：builder 与 runtime 的架构、Python 版本必须一致。
- 这是**抬高抄袭门槛**，不是绝对加密。要「逻辑绝对不可得」只能把算法留在自己服务器、对外只给 API。

## 许可证

Apache License 2.0，见 [LICENSE](LICENSE)。
