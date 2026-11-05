# kiln-pack

通用推理服务 **Docker 二进制打包器**。把值钱的 Python 源码在构建阶段编译成原生扩展（`.so`），
最终镜像里只留二进制——源码不进镜像、不随交付物外发，服务照常可起、可查版本、可健康检查。
面向 vLLM / SGLang / 自研编排等需要「上生产但不暴露源码」的场景。

## 布局

```
engine/   核心打包器（通用，不含任何具体项目痕迹）
  pack.sh              主入口：读一份 pack.conf，产出镜像并验收
  Dockerfile           两阶段构建：builder 编译保护 → runtime 干净底座
  compile_protect.py   用 Cython 把受保护 .py 编成 .so，strip 符号、删明文与 .c
  launch.sh            镜像内统一启动入口（校验必需 env 后起服）
  healthcheck.sh       镜像内健康检查入口
  verify.sh            验收：源码看不见 + 服务正常 + 可运维 三件事闭环检查

tests/    测试环境（独立于引擎）
  demo-fastapi/        最小 FastAPI 样例，含受保护的「假装很值钱」的打分逻辑
```

## 用法

```bash
# <项目目录> 下放一份 pack.conf，描述底座镜像、要保护的 .py、起服命令等
bash engine/pack.sh tests/demo-fastapi
```

换推理框架时通常只写一份新的 `pack.conf`（换底座、列出要保护的文件），
`engine/` 一字不动。配置项见 `tests/demo-fastapi/pack.conf` 的注释。

## 通用性测试

已在两个主流推理框架生态上验证过完整打包流程：

- **vLLM** 和 **SGLang** 各建一个独立工程，受保护模块真实 `import` 对应框架的 API（代表「基于该框架的自研调度 / 路由 / 采样逻辑」这类要保护的 IP），经本打包器编译成 `.so` 后组装进镜像。
- 两者均完整通过验收：镜像内无受保护源码明文（仅余 `.so`、容器内 `cat` 不到）、服务正常起、`/version` 指纹正确、`/infer` 走通编译后的自研逻辑、机密标记已外置不随镜像发出。

测试中补齐了对「运行期需写 `~/.cache` 的重框架（如 torch / transformers）」的支持：runtime 以非 root 用户运行时提供可写家目录，避免这类框架在起服阶段因缓存目录不可写而失败。

## 边界

- 保护的是**代码逻辑**，不是字符串常量：硬编码密钥用 `strings` 仍可从 `.so` 抠出，
  敏感常量应走环境变量外置（`pack.conf` 的 `REQUIRED_ENV`）。
- `.so` 认平台和 Python 版本：builder 与 runtime 的架构、Python 版本必须一致。
- 这是**抬高抄袭门槛**，不是绝对加密。要「逻辑绝对不可得」只能把算法留在自己服务器、对外只给 API。
