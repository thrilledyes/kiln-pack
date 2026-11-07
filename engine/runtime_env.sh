# shellcheck shell=sh
# SPDX-License-Identifier: Apache-2.0
# 由 launch.sh 在镜像内 source。框架底座的缓存变量常指向底座用户的目录，打包后换了用户就写不了，
# 作业到用的时候才报 PermissionError。这里在启动前检查一遍，写不了的改到 HOME 下。
# 写得了的不动，底座里预置的缓存照常用。预置的缓存只读也要用时，设 KILN_KEEP_CACHE_ENV=1 跳过这一步。

kiln_writable() {
  mkdir -p "$1" 2>/dev/null && [ -w "$1" ]
}

# 用 --user 指定了镜像里不存在的 uid 时，HOME 也写不了。
if ! kiln_writable "${HOME:-/nonexistent-kiln}"; then
  HOME="/tmp/kiln-home-$(id -u)"
  mkdir -p "$HOME"
  export HOME
  echo "[kiln] HOME 不可写，改用 ${HOME}"
fi

if [ "${KILN_KEEP_CACHE_ENV:-}" != 1 ]; then
  for _kiln_var in HF_HOME HF_HUB_CACHE HF_DATASETS_CACHE TRANSFORMERS_CACHE MODELSCOPE_CACHE TORCH_HOME XDG_CACHE_HOME TORCH_EXTENSIONS_DIR TRITON_CACHE_DIR; do
    eval "_kiln_dir=\${${_kiln_var}:-}"
    if [ -z "${_kiln_dir}" ] || kiln_writable "${_kiln_dir}"; then
      continue
    fi
    _kiln_new="${HOME}/.cache/kiln/${_kiln_var}"
    mkdir -p "${_kiln_new}"
    export "${_kiln_var}=${_kiln_new}"
    echo "[kiln] ${_kiln_var}=${_kiln_dir} 不可写，改用 ${_kiln_new}"
  done
  unset _kiln_var _kiln_dir _kiln_new
fi
