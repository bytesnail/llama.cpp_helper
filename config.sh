#!/bin/bash
# ============================================================
# llama.cpp helper - 配置文件
# 作用：集中定义共享路径和常量
# 用法：source /mnt/hdd/projects/llama.cpp_helper/config.sh
# ============================================================

# 防止直接执行
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "[ERROR] 本文件应当被 source，而非直接执行" >&2
    echo "用法: source ${BASH_SOURCE[0]}" >&2
    exit 1
fi

# 允许通过环境变量覆盖，默认为固定路径
LLAMA_CPP_SRC="${LLAMA_CPP_SRC:-/mnt/hdd/projects/llama.cpp}"

# 仓库信息
REPO="ggml-org/llama.cpp"
REPO_URL="https://github.com/ggml-org/llama.cpp"

# 资源限制与路径
MIN_FREE_DISK_GB=10
LOCK_FILE="${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}/llama_cpp_helper-${UID}.lock"

# Build configuration (overridable via environment)
CMAKE_BUILD_TYPE="${CMAKE_BUILD_TYPE:-Release}"
CMAKE_CUDA_ARCHITECTURES="${CMAKE_CUDA_ARCHITECTURES:-75}"
CMAKE_CUDA_FLAGS="${CMAKE_CUDA_FLAGS:---threads=0}"
GGML_CUDA_PEER_MAX_BATCH_SIZE="${GGML_CUDA_PEER_MAX_BATCH_SIZE:-512}"
GGML_CUDA_FA_ALL_QUANTS="${GGML_CUDA_FA_ALL_QUANTS:-ON}"
GGML_NATIVE="${GGML_NATIVE:-ON}"
GGML_BLAS="${GGML_BLAS:-ON}"
GGML_BLAS_VENDOR="${GGML_BLAS_VENDOR:-OpenBLAS}"

# Version
LLAMA_HELPER_VERSION="1.0.0"
