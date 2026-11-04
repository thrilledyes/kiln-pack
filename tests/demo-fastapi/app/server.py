"""演示用的最小推理服务。真实项目里这里是 vLLM/SGLang 的起服入口或自研编排。"""
import os

from fastapi import FastAPI
from pydantic import BaseModel

from app.secret_logic import proprietary_score

app = FastAPI(title="kiln-demo")

# 构建指纹：由打包流程注入，用于生产环境核对“正在跑的是哪一版”。
BUILD_INFO = {
    "app": os.environ.get("KILN_APP", "demo-fastapi"),
    "version": os.environ.get("KILN_VERSION", "dev"),
    "build_id": os.environ.get("KILN_BUILD_ID", "unknown"),
    "built_at": os.environ.get("KILN_BUILT_AT", "unknown"),
}


class InferRequest(BaseModel):
    prompt: str


@app.get("/healthz")
def healthz():
    return {"status": "ok"}


@app.get("/version")
def version():
    return BUILD_INFO


@app.post("/infer")
def infer(req: InferRequest):
    return {"prompt": req.prompt, "score": proprietary_score(req.prompt)}
