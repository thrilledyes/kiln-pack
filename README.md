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
  encrypt_config.py    打包阶段把配置加密成 .enc（train）
  kiln_config.py       镜像内的配置读取助手：在内存里解密，明文不落盘（train）
  kiln_init.py         容器的 PID 1：把 docker stop 的信号转给作业，传回退出码
  sensitive.sh         敏感文件和地址凭据的规则：打包时排除或拒绝，验收时发现就判失败
  verify_lib.sh        两个 profile 的验收脚本共用的检查
  runtime_env.sh       容器启动前的环境检查：底座的缓存目录写不了就改到 HOME 下

profiles/ 两种交付形态，各自的 Dockerfile + 启动/验收脚本
  serve/   常驻服务：Dockerfile（非 root 只读）/ launch.sh / healthcheck.sh / verify.sh
  train/   训练作业：Dockerfile（可写产物目录、无 HEALTHCHECK）/ launch.sh（LAUNCHER 分支）/ verify.sh（冒烟训练）

tests/    测试环境（独立于引擎）
  demo-fastapi/  最小 FastAPI 样例（PROFILE=serve），含受保护的打分逻辑
  demo-train/    最小 CPU torch 训练样例（PROFILE=train），受保护模块含模型/数据/loss/调度/单步逻辑，超参配方在加密的 YAML 里
  test_kiln_config.py  配置加密的单元测试
  test_kiln_init.py    信号转发的单元测试
  test_sensitive.py    敏感文件规则的单元测试
  test_compile_protect.py  START_CMD 启动受保护模块的判断
  acceptance.sh        需要 Docker 的端到端验收，覆盖敏感文件、验收假结果、接口探针、停止信号和各启动器
  acceptance_gpu.sh    真实 GPU 上的端到端验收：多卡训练、真实模型推理、真实训练框架
```

## 用法

```bash
# 推理服务：
bash engine/pack.sh tests/demo-fastapi
# 训练作业（demo 开了配置加密，需要密钥；真实项目的密钥要自己保管好，丢了只能重新打包）：
export KILN_CONFIG_KEY="$(openssl rand -base64 32)"
bash engine/pack.sh tests/demo-train
```

交付形态由 `pack.conf` 里的 `PROFILE` 决定（不写默认 `serve`，兼容旧配置）。
换框架/项目时通常只写一份新的 `pack.conf`，`engine/` 与 `profiles/` 一字不动。

## train profile 要点

- **只保护真正的 IP 模块**：模型结构、数据配方、loss、调度、单步训练逻辑编成 `.so`；
  入口 `train.py` 刻意留明文——`torchrun` 会重新 import 入口模块、DataLoader spawn 子进程也要能 import，
  带 `if __name__=="__main__"` 的入口脚本经不起 Cython 编译 + 多进程的折腾。
- **启动器**：`LAUNCHER=single`（单进程）、`torchrun`（单机多进程，`--standalone` 自带 rendezvous）、
  `deepspeed` 或 `accelerate`。后两者由项目在 requirements 里安装，额外参数走 `DEEPSPEED_ARGS` / `ACCELERATE_ARGS`。
  demo 的 `train.py` 读 `RANK`/`WORLD_SIZE`，三种多进程启动器都能起。
- **数据进、产物出全走挂载卷**：镜像不烘任何数据；checkpoint/日志落到 `OUTPUT_DIR`（默认 `/workspace/output`），
  运行时用 `-v` 挂到宿主取回。代码 `/app` 仍只读，只有产物目录和框架缓存可写。
- **验收 = 冒烟训练**：跑一个短作业，断言「正常退出 + 落下 checkpoint + loss 有限且下降」，而非打接口。
- **配置加密**：`CONFIG_ENCRYPT="on"` 时，`CONFIG_GLOBS` 匹配的 YAML 等配置在打包机上加密成 `.enc`（AES-256-GCM），
  明文和密钥都不经过 `docker build`，不进任何镜像层和构建缓存。运行时注入 `KILN_CONFIG_KEY`，代码用
  `kiln_config.load_yaml()` 在内存里解密。开启后验收会逐层扫描镜像，并确认没有密钥或密钥不对时起不了训。
- **GPU**：demo 用 CPU torch 跑通流程（无卡环境即可验收）。真实训练把 `RUNTIME_BASE`/`BUILDER_BASE`
  换成带 CUDA/ROCm/CANN 的框架镜像，用 `VERIFY_DOCKER_ARGS` 给验收传 `--gpus`，`init_process_group` 换 `nccl`/`hccl`。
  非 root 底座、离线环境和权限严的模型目录见 USAGE「用真实框架底座打包」。

## 通用性

已在 x86_64 + NVIDIA A30 + 带 CUDA torch 的非 root 底座、离线服务器上实测（`tests/acceptance_gpu.sh`）：

- **serve**：加载真实模型的 FastAPI 服务，路由和 pydantic 模型编成 `.so` 后正常工作。
  SGLang 0.5.23 在这套流程上试过（`tests/acceptance_gpu.sh` 的 sglang 场景），服务能起来，但真实推理还没跑通，见文末「目前没有解决的问题」。
  vLLM 还没有在这套流程上测过。
- **train**：`torchrun` 两卡 nccl、`Accelerator` 两卡混合精度、LlamaFactory 只认配置路径的 LoRA 训练，都配合编译保护和配置加密跑通了。
  `deepspeed` 只在 CPU 上验证过能拉起两个进程，`deepspeed.initialize` 和真实 GPU 的配合还没验证（在没有 `nvcc` 的底座上，它的安装就会失败）。
- **还没验证**：昇腾 / CANN、其他厂商的卡、跨节点训练。

## 边界

- 保护的是**代码逻辑**，不是字符串常量：硬编码密钥用 `strings` 仍可从 `.so` 抠出，敏感常量走 `REQUIRED_ENV` 外置。
- **配置加密防的是镜像外泄**：`.tar` 流出去了，没有密钥读不到配置。它防不住拿到密钥的人，
  也防不住能进运行中容器的人：密钥在进程环境变量里（`docker inspect` 也看得到），明文在进程内存里。
  要配置也不让运行方看到，只能把训练放在自己的环境里跑。
- 加密只覆盖配置文件的内容：文件名和大小看得到；`CONFIG_GLOBS` 没覆盖到的配置仍是明文（打包时会警告）；
  数据集不在范围内，它本来就走挂载卷。代码自己把配置打进日志或存进 checkpoint，同样会泄漏，
  验收只能靠 `CONFIG_MARKER` 抽查这一段特征字符串。
- 框架只接受配置文件路径时可以开 `CONFIG_MATERIALIZE`，代价是作业期间明文在内存盘 `/dev/shm`，
  能进容器的人直接 `cat` 就能读到，比只在进程内存里更容易拿。只写内存盘，不落磁盘，文件随容器消失。能用 `kiln_config` 读就别开。
- 依赖默认按 pip 常规方式安装，不锁哈希，源码包的安装脚本会在构建时执行。需要加固时用 `PIP_INSTALL_ARGS` 开启，
  它只作用于项目的 requirements，打包器自己装的 `Cython`、`cryptography` 不受影响。见 USAGE「依赖安装加固」。
- **与 `torch.compile` 的张力**：dynamo 追踪 Python 字节码，编成 `.so` 的模块它无法追踪，会 graph-break 退回 eager。
  最想保护的热点逻辑和最想被 compile 优化的往往是同一块，需按场景二选一。
- `.so` 认平台和 Python 版本：builder 与 runtime 的架构、Python 版本必须一致。
- 这是**抬高抄袭门槛**，不是绝对加密。要「逻辑绝对不可得」只能把算法留在自己服务器、对外只给 API。

## 目前没有解决的问题

**真实推理框架**

- **SGLang 的真实推理没有跑通。** 在 A30、驱动 535 上测 SGLang 0.5.23（底座是手工拼的：靠 `cuda-compat` 13.2 跑 `torch 2.14.1+cu130`）。
  受保护模块编成 `.so` 后能接管启动、加载权重，单卡和 `--tp-size 2` 双卡都走到了调度器；
  但第一个推理请求触发 flashinfer 现场编译 GPU 代码，报 `Ninja build failed`，`/v1/chat/completions` 一次也没成功返回。
  换了 13.0.88 的 `nvcc` 之后的具体错误还没查清，也还不能排除是手工拼的底座本身有问题（比如 SGLang 没钉 `nvidia-cuda-nvcc`，会解析到和头文件对不上的版本）。
- **vLLM 没有测过。**
- **要在运行时现场编译的框架和「编译器不进最终镜像」冲突。** 最新版 SGLang 的最终镜像里要有 `g++`、`nvcc` 和可写的编译缓存目录，
  打包器不会替你准备，只能由底座提供；这一点 USAGE 里还没写。
- **驱动太旧时要靠底座带 `cuda-compat`。** 驱动 535 只到 CUDA 12.2，新框架要前向兼容库，这也只能由底座解决。

**打包器**

- **builder 里装了 `cuda-compat` 时，import 自检会误判失败。** 自检遇到缺 GPU 驱动库（`libcuda.so.1` 这类）会跳过，
  但装了 compat 库后报的是 `0 active drivers`，认不出来，打包直接失败。现在只能让 builder 用不带 compat 的底座绕开，还没有关闭 import 自检的开关。
- **GPU 验收失败时，日志筛选挑不出编译器的错误行**，ninja / nvcc 的真实报错要自己翻完整日志。
- **builder 只会用 `apt-get` 装编译器。** 底座自带 `gcc` 和 `Python.h` 时没问题；昇腾 EulerOS / openEuler 这类 `yum`/`dnf` 底座又没有编译器时会编译失败。
- **不支持跨架构和跨 Python 版本**，builder 和 runtime 必须一致。
- **`__init__.py` 不能编译，递归 glob 会命中它而失败**，`PROTECT_GLOBS` 实际上只能逐个文件列；`CONFIG_GLOBS` 也不支持 `**`。
- **只保护 `.py`。** serve 的 YAML / JSON / 模板仍是明文；配置加密只有 train 有。

**没验证过的环境**

- `deepspeed` 和真实 GPU 的配合、昇腾 / CANN、其他厂商的卡、跨节点训练。

## 许可证

Apache License 2.0，见 [LICENSE](LICENSE)。
