#!/bin/bash
# ============================================================
# config.sh — centralized shared paths and constants
# Usage: source /path/to/llama.cpp_helper/config.sh
# ============================================================

# Prevent direct execution
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "[WARN] 本文件应当被 source，而非直接执行" >&2
    echo "用法: source ${BASH_SOURCE[0]}" >&2
    exit 1
fi

# Prevent duplicate source
_LLAMA_CONFIG_SOURCED=${_LLAMA_CONFIG_SOURCED:-0}
if [[ "$_LLAMA_CONFIG_SOURCED" -eq 1 ]]; then
    return 0 2>/dev/null || true
fi
_LLAMA_CONFIG_SOURCED=1

# Overridable via environment variable; defaults to llama.cpp adjacent to this project
_LLAMA_PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly _LLAMA_PROJECT_ROOT
LLAMA_CPP_SRC="${LLAMA_CPP_SRC:-${_LLAMA_PROJECT_ROOT}/../llama.cpp}"

# Repository info
REPO="ggml-org/llama.cpp"
readonly REPO
REPO_URL="https://github.com/ggml-org/llama.cpp"
readonly REPO_URL

# Resource limits and paths
MIN_FREE_DISK_GB=10
readonly MIN_FREE_DISK_GB
LOCK_FILE="${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}/llama_cpp_helper-${UID}.lock"
readonly LOCK_FILE

# Build configuration (overridable via environment)
CMAKE_BUILD_TYPE="${CMAKE_BUILD_TYPE:-Release}"
CMAKE_CUDA_ARCHITECTURES="${CMAKE_CUDA_ARCHITECTURES:-75}"
CMAKE_CUDA_FLAGS="${CMAKE_CUDA_FLAGS:---threads=0}"
GGML_CUDA_PEER_MAX_BATCH_SIZE="${GGML_CUDA_PEER_MAX_BATCH_SIZE:-512}"
GGML_CUDA_FA_ALL_QUANTS="${GGML_CUDA_FA_ALL_QUANTS:-ON}"
GGML_NATIVE="${GGML_NATIVE:-ON}"
GGML_BLAS="${GGML_BLAS:-ON}"
GGML_BLAS_VENDOR="${GGML_BLAS_VENDOR:-OpenBLAS}"

# conda configuration
CONDA_AUTO_ACTIVATE="${CONDA_AUTO_ACTIVATE:-1}"     # 0=skip, 1=auto-activate
CONDA_ENV_NAME="${CONDA_ENV_NAME:-base}"             # conda environment name to activate

# Network timeout configuration (overridable via environment)
CURL_CONNECT_TIMEOUT="${CURL_CONNECT_TIMEOUT:-10}"  # seconds; update.sh HTTP connection timeout
CURL_MAX_TIME="${CURL_MAX_TIME:-30}"                 # seconds; update.sh HTTP max request time
# Critical binaries (used by build verification and health checks)
REQUIRED_BINARIES=("llama-cli" "llama-server")
readonly REQUIRED_BINARIES
# Version number
LLAMA_HELPER_VERSION="1.0.0"
readonly LLAMA_HELPER_VERSION
