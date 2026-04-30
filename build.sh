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
llama_source_deps

# --- 文件锁定 ------------------------------------------------
llama_acquire_lock || llama_die "无法获取文件锁"

# 确保所有退出路径都释放文件锁（包括正常退出和 set -e 触发的异常退出）
trap 'llama_release_lock' EXIT

# --- 退出清理 ------------------------------------------------
cleanup_on_exit() {
    local exit_code=$?
    if [[ "${INCREMENTAL:-0}" -eq 0 && "$exit_code" -ne 0 && -d "${BUILD_DIR:-}" ]]; then
        llama_warn "清理未完成的构建目录..."
        rm -rf "$BUILD_DIR"
    fi
    llama_safe_exit "$exit_code"
}
llama_setup_trap cleanup_on_exit

# --- 帮助信息 ------------------------------------------------
show_help() {
    llama_show_help \
        "$(basename "$0")" \
        "使用 CMake + Ninja 构建 llama.cpp，启用 OpenBLAS 和 CUDA 支持。" \
        "  -i, --incremental    增量构建（不清理旧 build 目录）
  -h, --help           显示此帮助信息
      --version        显示版本信息" \
        "  bash build.sh              # 完整重新构建
  bash build.sh -i           # 增量构建
  bash build.sh --help       # 显示帮助"
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
            llama_release_lock
            exit 0
            ;;
        --version)
            llama_show_version
            llama_release_lock
            exit 0
            ;;
        *)
            llama_die "未知选项: $1"
            ;;
    esac
done

# --- 前置检查 ------------------------------------------------
llama_step "前置检查"

# shellcheck disable=SC2015
    llama_check_commands \
    cmake "cmake" \
    gcc "gcc" \
    g++ "g++" \
    python3 "python3" \
    && llama_ok "构建工具检查通过" || llama_die "构建工具检查失败"

# ninja 在 Debian/Ubuntu 上可能安装为 ninja-build
if ! command -v ninja &>/dev/null && ! command -v ninja-build &>/dev/null; then
    llama_die "缺少 ninja 或 ninja-build"
fi

if ! command -v nvcc &>/dev/null; then
    llama_warn "未找到 nvcc，CUDA 支持可能不可用"
else
    llama_detail "NVCC: $(nvcc --version 2>/dev/null | tail -1)"
fi

llama_check_dir "$LLAMA_CPP_SRC" "llama.cpp 源码目录" || llama_die "llama.cpp 源码目录不存在"
llama_check_file "${LLAMA_CPP_SRC}/CMakeLists.txt" "llama.cpp CMakeLists.txt" || llama_die "llama.cpp CMakeLists.txt 不存在"

llama_check_gpu || :

# --- 磁盘空间检查 --------------------------------------------
llama_check_disk_space "$LLAMA_CPP_SRC" || llama_die "磁盘空间不足"

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
    _NVCC_DIR=$(dirname "$(dirname "$(readlink -f "$(which nvcc)")")")
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

# 条件性添加 CUDA 库 RPATH（仅当 CUDA_LIB_DIR 非空时）
if [[ -n "$CUDA_LIB_DIR" ]]; then
    CMAKE_EXTRA_ARGS=("-DCMAKE_BUILD_RPATH=$CUDA_LIB_DIR")
else
    CMAKE_EXTRA_ARGS=()
fi

llama_run_silent cmake -S "$LLAMA_CPP_SRC" -B "$BUILD_DIR" -G Ninja \
    -DCMAKE_C_COMPILER="$GCC_PATH" \
    -DCMAKE_CXX_COMPILER="$GXX_PATH" \
    -DCMAKE_BUILD_TYPE="${CMAKE_BUILD_TYPE}" \
    -DLLAMA_BUILD_TESTS=OFF \
    -DLLAMA_BUILD_EXAMPLES=OFF \
    -DGGML_NATIVE="${GGML_NATIVE}" \
    -DGGML_BLAS="${GGML_BLAS}" \
    -DGGML_BLAS_VENDOR="${GGML_BLAS_VENDOR}" \
    -DGGML_CUDA=ON \
    -DCMAKE_CUDA_ARCHITECTURES="${CMAKE_CUDA_ARCHITECTURES}" \
    -DCMAKE_CUDA_FLAGS="${CMAKE_CUDA_FLAGS}" \
    -DGGML_CUDA_PEER_MAX_BATCH_SIZE="${GGML_CUDA_PEER_MAX_BATCH_SIZE}" \
    -DGGML_CUDA_FA_ALL_QUANTS="${GGML_CUDA_FA_ALL_QUANTS}" \
    "${CMAKE_EXTRA_ARGS[@]}"
CMAKE_EXIT=$?

if [[ "$CMAKE_EXIT" -ne 0 ]]; then
    llama_die "CMake 配置失败 (退出码: $CMAKE_EXIT)"
fi

llama_ok "CMake 配置完成"

# --- 步骤 3：编译 --------------------------------------------
llama_step "步骤 3/4：编译（${JOBS} 核并行）"

llama_run_silent cmake --build "$BUILD_DIR" --config Release -j "$JOBS"
BUILD_EXIT=$?

if [[ "$BUILD_EXIT" -ne 0 ]]; then
    llama_die "编译失败 (退出码: $BUILD_EXIT)"
fi

llama_ok "编译完成"

# --- 辅助函数 ------------------------------------------------
_human_size() {
    local bytes=$1
    if ((bytes >= 1073741824)); then
        local gb=$((bytes / 1073741824))
        local frac=$(( (bytes % 1073741824) * 10 / 1073741824 ))
        echo "${gb}.${frac}GiB"
    elif ((bytes >= 1048576)); then
        echo "$((bytes / 1048576))MiB"
    elif ((bytes >= 1024)); then
        echo "$((bytes / 1024))KiB"
    else
        echo "${bytes}B"
    fi
}

# --- 验证构建 ------------------------------------------------
verify_build() {
    local errors=0
    local bin_dir="${BUILD_DIR}/bin"

    # 检查关键二进制文件
    for binary in llama-cli llama-server; do
        local bin_path="${bin_dir}/${binary}"
        if [[ -x "$bin_path" ]]; then
            local size_bytes=
            size_bytes=$(llama_file_size "$bin_path")
            if [[ -n "$size_bytes" ]]; then
                local bin_size
                bin_size=$(_human_size "$size_bytes")
            else
                local bin_size="unknown"
            fi
            llama_ok "二进制文件: ${binary} (${bin_size})"
        else
            llama_err "二进制文件未生成: ${binary}"
            ((errors++)) || :
        fi
    done

    # 检查 CUDA 链接
    llama_info "CUDA 链接检查:"
    if [[ -x "${bin_dir}/llama-cli" ]]; then
        if ldd "${bin_dir}/llama-cli" 2>/dev/null | grep -qE "libcudart|libcublas|libcuda"; then
            ldd "${bin_dir}/llama-cli" | grep -E "libcudart|libcublas|libcuda" | while IFS= read -r line; do
                llama_detail "$line"
            done
            llama_ok "CUDA 链接正常"
        else
            llama_warn "未找到 CUDA 动态库链接（可能是静态链接）"
        fi
    else
        llama_warn "llama-cli 不存在，跳过 CUDA 链接检查"
    fi

    # 检查 OpenBLAS 链接
    llama_info "OpenBLAS 链接检查:"
    if [[ -x "${bin_dir}/llama-cli" ]]; then
        if ldd "${bin_dir}/llama-cli" 2>/dev/null | grep -qiE "openblas|blas"; then
            ldd "${bin_dir}/llama-cli" | grep -iE "openblas|blas" | while IFS= read -r line; do
                llama_detail "$line"
            done
            llama_ok "OpenBLAS 链接正常"
        else
            llama_warn "未找到 OpenBLAS 动态库链接（可能是静态链接或未启用）"
        fi
    else
        llama_warn "llama-cli 不存在，跳过 OpenBLAS 链接检查"
    fi

    # 验证二进制文件可执行性
    llama_info "验证二进制文件可执行性："
    if "${bin_dir}/llama-cli" --version &>/dev/null; then
        llama_ok "llama-cli 可正常启动"
    else
        llama_warn "llama-cli 启动验证失败"
    fi

    # 检查可用设备 (llama-bench --help 会触发 CUDA 初始化并打印设备信息)
    llama_info "可用设备："
    if [[ -x "${bin_dir}/llama-bench" ]]; then
        local bench_output
        bench_output=$("${bin_dir}/llama-bench" --help 2>&1 || :)
        if echo "$bench_output" | grep -q "found [0-9]* CUDA devices"; then
            echo "$bench_output" | grep -E "found [0-9]* CUDA devices|Device [0-9]*:" | while IFS= read -r line; do
                llama_detail "$line"
            done
            llama_ok "CUDA 设备检测完成"
        else
            llama_warn "CUDA 设备检测失败（可能需要 source run_env.sh）"
        fi
    else
        llama_warn "未找到 llama-bench，跳过设备检测"
    fi

    # 验证 OpenBLAS 运行时可用性
    llama_info "OpenBLAS 运行时验证："
    local openblas_lib
    openblas_lib=$(ldd "${bin_dir}/llama-cli" 2>/dev/null | grep -oE '/[^ ]+libopenblas[^ ]*' | head -1)
    if [[ -n "$openblas_lib" ]]; then
        if python3 -c "import ctypes; ctypes.CDLL('$openblas_lib')" 2>/dev/null; then
            llama_ok "OpenBLAS 可正常加载"
        else
            llama_warn "OpenBLAS 动态加载失败"
        fi
    else
        llama_warn "未检测到 OpenBLAS 动态库路径"
    fi

    return "$errors"
}

# --- 步骤 4：验证构建 ----------------------------------------
llama_step "步骤 4/4：验证构建"

verify_build
VERIFY_EXIT=$?
if [[ "$VERIFY_EXIT" -gt 0 ]]; then
    llama_die "构建验证失败，${VERIFY_EXIT} 个错误"
fi
git -C "$LLAMA_CPP_SRC" rev-parse HEAD > "${BUILD_DIR}/.build-stamp" 2>/dev/null || :
llama_release_lock
# shellcheck disable=SC2153
echo -e "\n${GREEN}✅ 构建完成！${NC}\n\n运行示例:\n  source ${SCRIPT_DIR}/run_env.sh\n  ${BIN_DIR}/llama-cli -m /path/to/model.gguf -ngl 99 -p \"你好\"\n  ${BIN_DIR}/llama-server -m /path/to/model.gguf -ngl 99 --port 8080"
