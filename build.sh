#!/bin/bash
# ============================================================
# llama.cpp 构建脚本
# 目标：同时启用 OpenBLAS (CPU) + CUDA (双 RTX 2080 Ti NVLink)
# 硬件：Intel Xeon E5-2667 v4 (32核) / 251GB RAM
#       2× RTX 2080 Ti 22GB (NVLink 2链路, sm_75)
# 软件：CUDA 13.0 / OpenBLAS 0.3.25 / GCC 12.3.0 / Ninja 1.12.1
# 使用：cd /mnt/hdd/projects/llama.cpp_helper && bash build.sh
# ============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null && pwd)"

# shellcheck source=/dev/null
source "${SCRIPT_DIR}/common.sh"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/config.sh"

# --- 帮助信息 ------------------------------------------------
show_help() {
    cat <<EOF
用法: $(basename "$0") [选项]

描述:
  使用 CMake + Ninja 构建 llama.cpp，启用 OpenBLAS 和 CUDA 支持。

选项:
  -i, --incremental    增量构建（不清理旧 build 目录）
  -h, --help           显示此帮助信息

示例:
  bash build.sh              # 完整重新构建
  bash build.sh -i           # 增量构建
  bash build.sh --help       # 显示帮助
EOF
}

# --- 参数解析 ------------------------------------------------
INCREMENTAL=0
while (($# > 0)); do
    case "$1" in
        -i|--incremental)
            INCREMENTAL=1
            shift
            ;;
        -h|--help)
            show_help
            exit 0
            ;;
        *)
            llama_err "未知选项: $1"
            show_help
            exit 1
            ;;
    esac
done

# --- 前置检查 ------------------------------------------------
llama_step "前置检查"

llama_check_commands \
    cmake "cmake" \
    gcc "gcc" \
    g++ "g++" \
    python3 "python3" \
    && llama_ok "构建工具检查通过" || exit 1

# ninja 在 Debian/Ubuntu 上可能安装为 ninja-build
if ! command -v ninja &>/dev/null && ! command -v ninja-build &>/dev/null; then
    llama_err "缺少 ninja 或 ninja-build"
    exit 1
fi

if ! command -v nvcc &>/dev/null; then
    llama_warn "未找到 nvcc，CUDA 支持可能不可用"
else
    llama_detail "NVCC: $(nvcc --version 2>/dev/null | tail -1)"
fi

llama_check_dir "$LLAMA_CPP_SRC" "llama.cpp 源码目录" || exit 1
llama_check_file "${LLAMA_CPP_SRC}/CMakeLists.txt" "llama.cpp CMakeLists.txt" || exit 1

llama_check_gpu || true

# --- 动态检测 ------------------------------------------------
BUILD_DIR="${LLAMA_CPP_SRC}/build"
JOBS=$(llama_get_cpu_count)
llama_detail "并行编译任务数: $JOBS"

# 自动检测 GCC/G++ 路径
GCC_PATH=$(command -v gcc)
GXX_PATH=$(command -v g++)
llama_detail "C 编译器: $GCC_PATH"
llama_detail "C++ 编译器: $GXX_PATH"

# 自动检测 CUDA 库路径（用于 RPATH）
# 背景：b8940 起 llama.cpp 将 CUDA 后端拆分为独立的 libggml-cuda.so，
# 且 CUDA 依赖声明为 PRIVATE，不会通过 CMake 传播到最终可执行文件。
# 当 CUDA 安装在非标准路径（如 Anaconda）时，链接器无法找到 libcudart.so / libcublas.so。
# 此处通过 CMAKE_BUILD_RPATH 将 CUDA 库目录加入链接器搜索路径。
#
# ⚠️ 这是临时方案。如果未来 llama.cpp 在 CMake 中自行处理了 CUDA 库的 RPATH
#    （例如将 PRIVATE 改为 PUBLIC，或显式设置 RPATH），则此处不再需要。
#    验证方法：更新 llama.cpp 后，删除此处 CUDA_LIB_DIR 检测和 CMAKE_BUILD_RPATH，
#    执行完整构建（bash build.sh），若链接阶段无 "libcudart.so.* not found" 错误，
#    即说明 llama.cpp 已自行解决此问题，可安全移除。
if command -v nvcc &>/dev/null; then
    _NVCC_DIR=$(dirname $(dirname $(readlink -f $(which nvcc))))
    # 优先使用标准 CUDA 目录结构推断
    CUDA_LIB_DIR="$_NVCC_DIR/targets/x86_64-linux/lib"
    if [[ ! -d "$CUDA_LIB_DIR" ]]; then
        # 回退：从 libcudart.so 位置反推
        _CUDA_RT=$(find "$_NVCC_DIR" -name libcudart.so -not -path '*/stubs/*' -print -quit 2>/dev/null)
        if [[ -n "$_CUDA_RT" ]]; then
            CUDA_LIB_DIR=$(dirname "$(readlink -f "$_CUDA_RT")")
        fi
    fi
    if [[ -n "$CUDA_LIB_DIR" && -d "$CUDA_LIB_DIR" ]]; then
        llama_detail "CUDA 库路径: $CUDA_LIB_DIR"
    else
        llama_warn "无法自动检测 CUDA 库路径，构建可能失败"
        CUDA_LIB_DIR=""
    fi
    unset _NVCC_DIR _CUDA_RT
else
    CUDA_LIB_DIR=""
fi

# --- 步骤 1：清理旧构建 --------------------------------------
if [[ "$INCREMENTAL" -eq 0 ]]; then
    llama_step "步骤 1/4：清理旧构建"
    if [[ -d "$BUILD_DIR" ]]; then
        llama_info "移除旧 build 目录..."
        rm -rf "$BUILD_DIR"
    fi
    llama_ok "清理完成"
else
    llama_step "步骤 1/4：增量构建（跳过清理）"
fi

# --- 步骤 2：CMake 配置 ---------------------------------------
llama_step "步骤 2/4：CMake 配置"

llama_info "运行 CMake 配置..."

set +e
# 条件性添加 CUDA 库 RPATH（仅当 CUDA_LIB_DIR 非空时）
if [[ -n "$CUDA_LIB_DIR" ]]; then
    CMAKE_EXTRA_ARGS=("-DCMAKE_BUILD_RPATH=$CUDA_LIB_DIR")
else
    CMAKE_EXTRA_ARGS=()
fi

cmake -S "$LLAMA_CPP_SRC" -B "$BUILD_DIR" -G Ninja \
    -DCMAKE_C_COMPILER="$GCC_PATH" \
    -DCMAKE_CXX_COMPILER="$GXX_PATH" \
    -DCMAKE_BUILD_TYPE=Release \
    -DLLAMA_BUILD_TESTS=OFF \
    -DLLAMA_BUILD_EXAMPLES=OFF \
    -DGGML_NATIVE=ON \
    -DGGML_BLAS=ON \
    -DGGML_BLAS_VENDOR=OpenBLAS \
    -DGGML_CUDA=ON \
    -DCMAKE_CUDA_ARCHITECTURES="75" \
    -DCMAKE_CUDA_FLAGS="--threads=0" \
    -DGGML_CUDA_PEER_MAX_BATCH_SIZE=512 \
    -DGGML_CUDA_FA_ALL_QUANTS=ON \
    "${CMAKE_EXTRA_ARGS[@]}"

CMAKE_EXIT=$?
set -e

if [[ "$CMAKE_EXIT" -ne 0 ]]; then
    llama_err "CMake 配置失败 (退出码: $CMAKE_EXIT)"
    llama_detail "请检查上方错误信息，常见问题："
    llama_detail "  - CUDA 工具链未正确安装"
    llama_detail "  - OpenBLAS 开发包未安装 (libopenblas-dev)"
    llama_detail "  - GCC 版本与 CUDA 不兼容"
    exit 1
fi

llama_ok "CMake 配置完成"

# --- 步骤 3：编译 --------------------------------------------
llama_step "步骤 3/4：编译（${JOBS} 核并行）"

set +e
cmake --build "$BUILD_DIR" --config Release -j "$JOBS"
BUILD_EXIT=$?
set -e

if [[ "$BUILD_EXIT" -ne 0 ]]; then
    llama_err "编译失败 (退出码: $BUILD_EXIT)"
    llama_detail "请检查上方编译错误"
    exit 1
fi

llama_ok "编译完成"

# --- 步骤 4：验证构建 ----------------------------------------
llama_step "步骤 4/4：验证构建"

ERRORS=0

# 检查关键二进制文件
BIN_DIR="${BUILD_DIR}/bin"
for binary in llama-cli llama-server; do
    bin_path="${BIN_DIR}/${binary}"
    if [[ -x "$bin_path" ]]; then
        bin_size=$(stat -c %s "$bin_path" 2>/dev/null | numfmt --to=iec-i 2>/dev/null) || bin_size="unknown"
        llama_ok "二进制文件: ${binary} (${bin_size})"
    else
        llama_err "二进制文件未生成: ${binary}"
        ((ERRORS++)) || true
    fi
done

# 检查 CUDA 链接
llama_info "CUDA 链接检查:"
if ldd "${BIN_DIR}/llama-cli" 2>/dev/null | grep -qE "libcudart|libcublas|libcuda"; then
    ldd "${BIN_DIR}/llama-cli" | grep -E "libcudart|libcublas|libcuda" | while IFS= read -r line; do
        llama_detail "$line"
    done
    llama_ok "CUDA 链接正常"
else
    llama_warn "未找到 CUDA 动态库链接（可能是静态链接）"
fi

# 检查 OpenBLAS 链接
llama_info "OpenBLAS 链接检查:"
if ldd "${BIN_DIR}/llama-cli" 2>/dev/null | grep -qiE "openblas|blas"; then
    ldd "${BIN_DIR}/llama-cli" | grep -iE "openblas|blas" | while IFS= read -r line; do
        llama_detail "$line"
    done
    llama_ok "OpenBLAS 链接正常"
else
    llama_warn "未找到 OpenBLAS 动态库链接（可能是静态链接或未启用）"
fi

# 验证二进制文件可执行性
llama_info "验证二进制文件可执行性："
if "${BIN_DIR}/llama-cli" --version &>/dev/null; then
    llama_ok "llama-cli 可正常启动"
else
    llama_warn "llama-cli 启动验证失败"
fi

# 检查可用设备 (llama-bench --help 会触发 CUDA 初始化并打印设备信息)
llama_info "可用设备："
BENCH_OUTPUT=$("${BIN_DIR}/llama-bench" --help 2>&1 || true)
if echo "$BENCH_OUTPUT" | grep -q "found [0-9]* CUDA devices"; then
    echo "$BENCH_OUTPUT" | grep -E "found [0-9]* CUDA devices|Device [0-9]*:" | while IFS= read -r line; do
        llama_detail "$line"
    done
    llama_ok "CUDA 设备检测完成"
else
    llama_warn "CUDA 设备检测失败（可能需要 source run_env.sh）"
fi

# 验证 OpenBLAS 运行时可用性
llama_info "OpenBLAS 运行时验证："
OPENBLAS_LIB=$(ldd "${BIN_DIR}/llama-cli" 2>/dev/null | grep -oE '/[^ ]+libopenblas[^ ]*' | head -1)
if [[ -n "$OPENBLAS_LIB" ]]; then
    if python3 -c "import ctypes; ctypes.CDLL('$OPENBLAS_LIB')" 2>/dev/null; then
        llama_ok "OpenBLAS 可正常加载"
    else
        llama_warn "OpenBLAS 动态加载失败"
    fi
else
    llama_warn "未检测到 OpenBLAS 动态库路径"
fi

# 汇总
if [[ "$ERRORS" -gt 0 ]]; then
    llama_err "构建验证失败，${ERRORS} 个错误"
    exit 1
fi

# 写入构建标记（用于 update.sh 验证构建是否与源码匹配）
git -C "$LLAMA_CPP_SRC" rev-parse HEAD > "${BUILD_DIR}/.build-stamp" 2>/dev/null || true

echo -e "\n${GREEN}✅ 构建完成！${NC}\n\n运行示例:\n  source ${SCRIPT_DIR}/run_env.sh\n  ${BIN_DIR}/llama-cli -m /path/to/model.gguf -ngl 99 -p \"你好\"\n  ${BIN_DIR}/llama-server -m /path/to/model.gguf -ngl 99 --port 8080"

