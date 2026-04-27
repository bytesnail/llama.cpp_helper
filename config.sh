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
LOCK_FILE="/tmp/llama_cpp_helper.lock"
TRAP_CLEANUP_DIR="/tmp/llama_helper_cleanup"
