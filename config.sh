#!/bin/bash
# ============================================================
# config.sh — 集中定义共享路径和常量
# 用法：source /path/to/llama.cpp_helper/config.sh
# ============================================================

# 防止直接执行
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "[WARN] 本文件应当被 source，而非直接执行" >&2
    echo "用法: source ${BASH_SOURCE[0]}" >&2
    exit 1
fi

# 防止重复 source
_LLAMA_CONFIG_SOURCED=${_LLAMA_CONFIG_SOURCED:-0}
if [[ "$_LLAMA_CONFIG_SOURCED" -eq 1 ]]; then
    return 0 2>/dev/null || true
fi
_LLAMA_CONFIG_SOURCED=1

# 允许通过环境变量覆盖，默认为本项目相邻目录下的 llama.cpp
_LLAMA_PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly _LLAMA_PROJECT_ROOT
LLAMA_CPP_SRC="${LLAMA_CPP_SRC:-${_LLAMA_PROJECT_ROOT}/../llama.cpp}"

# 仓库信息
REPO="ggml-org/llama.cpp"
readonly REPO
REPO_URL="https://github.com/ggml-org/llama.cpp"
readonly REPO_URL

# 资源限制与路径
MIN_FREE_DISK_GB=10
readonly MIN_FREE_DISK_GB
LOCK_FILE="${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}/llama_cpp_helper-${UID}.lock"
readonly LOCK_FILE

# 构建配置（可通过环境变量覆盖）
CMAKE_BUILD_TYPE="${CMAKE_BUILD_TYPE:-Release}"
CMAKE_CUDA_ARCHITECTURES="${CMAKE_CUDA_ARCHITECTURES:-75}"
CMAKE_CUDA_FLAGS="${CMAKE_CUDA_FLAGS:---threads=0}"
GGML_CUDA_PEER_MAX_BATCH_SIZE="${GGML_CUDA_PEER_MAX_BATCH_SIZE:-512}"
GGML_CUDA_FA_ALL_QUANTS="${GGML_CUDA_FA_ALL_QUANTS:-ON}"
GGML_NATIVE="${GGML_NATIVE:-ON}"
GGML_BLAS="${GGML_BLAS:-ON}"
GGML_BLAS_VENDOR="${GGML_BLAS_VENDOR:-OpenBLAS}"

# conda 配置
CONDA_AUTO_ACTIVATE="${CONDA_AUTO_ACTIVATE:-1}"     # 0=跳过, 1=自动激活
CONDA_ENV_NAME="${CONDA_ENV_NAME:-base}"             # 激活的 conda 环境名称

# 网络超时配置（可通过环境变量覆盖）
CURL_CONNECT_TIMEOUT="${CURL_CONNECT_TIMEOUT:-10}"
CURL_MAX_TIME="${CURL_MAX_TIME:-30}"
# 关键二进制文件（构建验证和健康检查使用）
REQUIRED_BINARIES=("llama-cli" "llama-server")
readonly REQUIRED_BINARIES
# 版本号
LLAMA_HELPER_VERSION="1.0.0"
readonly LLAMA_HELPER_VERSION
