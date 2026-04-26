#!/bin/bash
# ============================================================
# llama.cpp 运行时性能优化环境变量
# 使用：source /mnt/hdd/projects/llama.cpp_helper/run_env.sh
# ============================================================

# 启用 GPU 间 P2P 直传（NVLink 已连接，绕过系统内存）
export GGML_CUDA_P2P=1

# 增大 CUDA 命令缓冲区（多 GPU pipeline 并行受益）
export CUDA_SCALE_LAUNCH_QUEUES=4x

# 统一内存（模型超出 VRAM 时 swap 到 251GB 系统内存而不崩溃）
export GGML_CUDA_ENABLE_UNIFIED_MEMORY=1

echo "✅ llama.cpp 运行环境已加载"
echo "   GGML_CUDA_P2P=1"
echo "   CUDA_SCALE_LAUNCH_QUEUES=4x"
echo "   GGML_CUDA_ENABLE_UNIFIED_MEMORY=1"
