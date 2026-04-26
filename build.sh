#!/bin/bash
set -e

# ============================================================
# llama.cpp 构建脚本
# 目标：同时启用 OpenBLAS (CPU) + CUDA (双 RTX 2080 Ti NVLink)
# 硬件：Intel Xeon E5-2667 v4 (32核) / 251GB RAM
#       2× RTX 2080 Ti 22GB (NVLink 2链路, sm_75)
# 软件：CUDA 13.0 / OpenBLAS 0.3.25 / GCC 12.3.0 / Ninja 1.12.1
# 使用：cd /mnt/hdd/projects/llama.cpp_helper && bash build.sh
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.sh"
BUILD_DIR="${LLAMA_CPP_SRC}/build"

echo "=== 步骤 1/4：清理旧构建 ==="
if [ -d "${BUILD_DIR}" ]; then
    echo "移除旧 build 目录..."
    rm -rf "${BUILD_DIR}"
fi

echo ""
echo "=== 步骤 2/4：CMake 配置 ==="
cmake -S "${LLAMA_CPP_SRC}" -B "${BUILD_DIR}" -G Ninja \
  -DCMAKE_C_COMPILER=/usr/bin/gcc \
  -DCMAKE_CXX_COMPILER=/usr/bin/g++ \
  -DCMAKE_BUILD_TYPE=Release \
  -DLLAMA_BUILD_TESTS=OFF \
  -DLLAMA_BUILD_EXAMPLES=OFF \
  -DGGML_NATIVE=ON \
  -DGGML_BLAS=ON \
  -DGGML_BLAS_VENDOR=OpenBLAS \
  -DGGML_CUDA=ON \
  -DCMAKE_CUDA_ARCHITECTURES="75" \
  -DCMAKE_CUDA_FLAGS=--threads=0 \
  -DGGML_CUDA_PEER_MAX_BATCH_SIZE=512 \
  -DGGML_CUDA_FA_ALL_QUANTS=ON

echo ""
echo "=== 步骤 3/4：编译（32核并行）==="
cmake --build "${BUILD_DIR}" --config Release -j 32

echo ""
echo "=== 步骤 4/4：验证构建 ==="
echo ""
echo "二进制文件:"
ls -lh "${BUILD_DIR}/bin/llama-cli" "${BUILD_DIR}/bin/llama-server" || {
    echo "  ⚠️  部分二进制文件未生成，请检查上方编译日志"
    exit 1
}
echo ""
echo "CUDA 链接:"
ldd "${BUILD_DIR}/bin/llama-cli" | grep -E "cuda|cublas" || echo "  (未找到 CUDA 链接)"
echo ""
echo "OpenBLAS 链接:"
ldd "${BUILD_DIR}/bin/llama-cli" | grep openblas || echo "  (未找到 OpenBLAS 链接)"
echo ""
echo "可用设备:"
"${BUILD_DIR}/bin/llama-cli" --list-devices || true
echo ""
echo "✅ 构建完成！"
echo ""
echo "运行示例:"
echo "  source /mnt/hdd/projects/llama.cpp_helper/run_env.sh"
echo "  ${BUILD_DIR}/bin/llama-cli -m /path/to/model.gguf -ngl 99 -p \"你好\""
echo "  ${BUILD_DIR}/bin/llama-server -m /path/to/model.gguf -ngl 99 --port 8080"
