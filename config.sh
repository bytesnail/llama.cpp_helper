#!/bin/bash
# ============================================================
# llama.cpp helper - 配置文件
# 作用：集中定义共享路径和常量
# 用法：source /mnt/hdd/projects/llama.cpp_helper/config.sh
# ============================================================

# 允许通过环境变量覆盖，默认为固定路径
LLAMA_CPP_SRC="${LLAMA_CPP_SRC:-/mnt/hdd/projects/llama.cpp}"

# 仓库信息
REPO="ggml-org/llama.cpp"
REPO_URL="https://github.com/ggml-org/llama.cpp"
