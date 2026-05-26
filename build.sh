#!/bin/bash
# ============================================================
# build.sh — llama.cpp build script
# Goal: enable both OpenBLAS (CPU) + CUDA (dual RTX 2080 Ti NVLink)
# Hardware: Intel Xeon E5-2667 v4 (32 cores) / 251GB RAM
#          2× RTX 2080 Ti 22GB (NVLink 2 links, sm_75)
# Software: CUDA / OpenBLAS / GCC / Ninja (version requirements: see README)
# Usage: cd /path/to/llama.cpp_helper && bash build.sh
# ============================================================

# Enable strict mode only when executing normally (not when sourced for test extraction)
if [[ "${_LLAMA_SOURCE_ONLY:-}" != "1" ]]; then
    set -euo pipefail
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null && pwd)"
readonly SCRIPT_DIR
source "${SCRIPT_DIR}/common.sh"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/config.sh"

# --- 文件锁定 ------------------------------------------------
# Skip setup code when sourced for test extraction
if [[ "${_LLAMA_SOURCE_ONLY:-}" != "1" ]]; then
    BUILD_DIR="${LLAMA_CPP_SRC}/build"
    readonly BUILD_DIR

    llama_acquire_lock || llama_die "无法获取文件锁"
fi

# --- 退出清理 ------------------------------------------------
# Usage: _cleanup_on_exit
_cleanup_on_exit() {
    local exit_code=$?
    [[ "${_CLEANUP_DONE:-0}" -eq 1 ]] && return 0
    _CLEANUP_DONE=1
    if [[ "${incremental:-0}" -eq 0 && "$exit_code" -ne 0 && -d "${BUILD_DIR:-}" ]]; then
        llama_warn "清理未完成的构建目录..."
        rm -rf "$BUILD_DIR"
    fi
    llama_safe_exit "$exit_code"
}
if [[ "${_LLAMA_SOURCE_ONLY:-}" != "1" ]]; then
    llama_setup_trap _cleanup_on_exit
    trap '_cleanup_on_exit' EXIT
fi

# EXIT trap: ensures cleanup on llama_die→exit paths; _CLEANUP_DONE guard prevents
# double-fire when SIGINT/SIGTERM (L35) and EXIT both trigger.
# --- 帮助信息 ------------------------------------------------
# Usage: _show_help
_show_help() {
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

# Usage: _detect_cuda_lib_dir
_detect_cuda_lib_dir() {
    if ! command -v nvcc &>/dev/null; then
        return 1
    fi
    local nvcc_dir nvcc_real_path
    nvcc_real_path=$(readlink -f "$(command -v nvcc)" 2>/dev/null) || return 1
    if [[ -z "$nvcc_real_path" ]]; then return 1; fi
    nvcc_dir=$(dirname "$(dirname "$nvcc_real_path")")
    local cuda_lib_dir
    cuda_lib_dir="${nvcc_dir}/targets/$(uname -m)-linux/lib"
    if [[ ! -d "$cuda_lib_dir" ]]; then
        local cuda_rt max_search_depth=6
        cuda_rt=$(find "$nvcc_dir" -maxdepth "$max_search_depth" -name libcudart.so -not -path '*/stubs/*' -print -quit 2>/dev/null)
        if [[ -n "$cuda_rt" ]]; then
            cuda_lib_dir=$(dirname "$(readlink -f "$cuda_rt")")
        fi
    fi
    if [[ -n "$cuda_lib_dir" && -d "$cuda_lib_dir" ]]; then
        echo "$cuda_lib_dir"
        return 0
    fi
    return 1
}

# --- 验证辅助函数 --------------------------------------------

# Usage: _verify_binary_exists <binary_name> <bin_dir>
# Returns: 0=exists, 1=missing
_verify_binary_exists() {
    local binary="$1"
    local bin_dir="$2"
    local bin_path="${bin_dir}/${binary}"

    if [[ -x "$bin_path" ]]; then
        local size_bytes
        size_bytes=$(llama_file_size "$bin_path")
        local bin_size
        if [[ -n "$size_bytes" ]]; then
            bin_size=$(llama_human_size "$size_bytes")
        else
            bin_size="unknown"
        fi
        llama_ok "二进制文件: ${binary} (${bin_size})"
        return 0
    else
        llama_err "二进制文件未生成: ${binary}"
        return 1
    fi
}
# Usage: _verify_linking <bin_dir> [binary] [grep_pattern] [label] [not_found_msg]
_verify_linking() {
    local bin_dir="$1"
    if [[ -z "$bin_dir" ]]; then
        llama_warn "链接检查跳过：未指定二进制目录"
        return 0
    fi
    local binary="${2:-llama-cli}"
    local pattern="$3"
    local label="$4"
    local not_found_msg="$5"

    llama_info "${label} 链接检查:"
    local bin_path="${bin_dir}/${binary}"

    if [[ ! -x "$bin_path" ]]; then
        llama_warn "${binary} 不存在，跳过 ${label} 链接检查"
        return 0
    fi
    local ldd_output
    ldd_output=$(ldd "$bin_path" 2>/dev/null) || true
    if echo "$ldd_output" | grep -qiE "$pattern"; then
        echo "$ldd_output" | grep -iE "$pattern" | while IFS= read -r line; do
            llama_detail "$line"
        done
        llama_ok "${label} 链接正常"
    else
        llama_warn "${not_found_msg}"
    fi
}

# Usage: _verify_cuda_linking <bin_dir> [binary]
_verify_cuda_linking() {
    _verify_linking "${1:-}" "${2:-llama-cli}" "libcudart|libcublas|libcuda" "CUDA" "未找到 CUDA 动态库链接（可能是静态链接）"
}

# Usage: _verify_openblas_linking <bin_dir> [binary]
_verify_openblas_linking() {
    _verify_linking "${1:-}" "${2:-llama-cli}" "openblas|blas" "OpenBLAS" "未找到 OpenBLAS 动态库链接（可能是静态链接或未启用）"
}

# Usage: _verify_cuda_devices <bin_dir>
_verify_cuda_devices() {
    local bin_dir="$1"

    llama_info "可用设备："
    if [[ ! -x "${bin_dir}/llama-bench" ]]; then
        llama_warn "未找到 llama-bench，跳过设备检测"
        return 0
    fi
    local bench_output
    bench_output=$(LC_ALL=C "${bin_dir}/llama-bench" --help 2>&1 || true)
    if echo "$bench_output" | grep -q "found [0-9]* CUDA devices"; then
        echo "$bench_output" | grep -E "found [0-9]* CUDA devices|Device [0-9]*:" | while IFS= read -r line; do
            llama_detail "$line"
        done
        llama_ok "CUDA 设备检测完成"
    else
        llama_warn "CUDA 设备检测失败（可能需要 source run_env.sh）"
    fi
}

# Usage: _verify_openblas_runtime <bin_dir> [binary]
_verify_openblas_runtime() {
    local bin_dir="$1"
    local binary="${2:-llama-cli}"
    local bin_path="${bin_dir}/${binary}"

    llama_info "OpenBLAS 运行时验证："
    local openblas_lib
    openblas_lib=$(ldd "$bin_path" 2>/dev/null | grep -oE '/[^ ]+libopenblas[^ ]*' | head -1)
    if [[ -n "$openblas_lib" ]]; then
        if _LLAMA_OPENBLAS_LIB="$openblas_lib" python3 -c 'import ctypes, os; ctypes.CDLL(os.environ["_LLAMA_OPENBLAS_LIB"])' 2>/dev/null; then
            llama_ok "OpenBLAS 可正常加载"
        else
            llama_warn "OpenBLAS 动态加载失败"
        fi
    else
        llama_warn "未检测到 OpenBLAS 动态库路径"
    fi
}

# Usage: _verify_build
_verify_build() {
    local errors=0
    local bin_dir="${BUILD_DIR}/bin"
    local verify_binary="${REQUIRED_BINARIES[0]}"

    # Check critical binaries
    for binary in "${REQUIRED_BINARIES[@]}"; do
        _verify_binary_exists "$binary" "$bin_dir" || errors=$((errors + 1))
    done

    # Link checks (non-fatal)
    _verify_cuda_linking "$bin_dir" "$verify_binary"
    _verify_openblas_linking "$bin_dir" "$verify_binary"

    # Verify binary executability
    llama_info "验证二进制文件可执行性："
    if "${bin_dir}/${verify_binary}" --version &>/dev/null; then
        llama_ok "${verify_binary} 可正常启动"
    else
        llama_warn "${verify_binary} 启动验证失败"
    fi

    # Runtime verification (non-fatal)
    _verify_cuda_devices "$bin_dir" || true
    _verify_openblas_runtime "$bin_dir" "$verify_binary" || true
    return "$errors"
}

# --- 主逻辑 --------------------------------------------------
main() {
incremental=0  # Script-level variable: trap handler cannot access main() locals
    local jobs
    local gcc_path gxx_path cuda_lib_dir=""
    local -a cmake_extra_args
    while (($# > 0)); do
        case "$1" in
            -i|--incremental)
                incremental=1
                shift
                ;;
            -h|--help)
                _show_help
                llama_safe_exit 0
                ;;
            --version)
                llama_show_version
                llama_safe_exit 0
                ;;
            *)
                llama_die "未知选项: $1"
                ;;
        esac
    done

    # --- 前置检查 ------------------------------------------------
    # Activate conda environment (if CUDA toolchain was installed via conda)
    llama_activate_conda

    llama_step "前置检查"

    # shellcheck disable=SC2015
    llama_check_commands \
        cmake "cmake" \
        gcc "gcc" \
        g++ "g++" \
        python3 "python3" \
        && llama_ok "构建工具检查通过" || llama_die "构建工具检查失败"

    # ninja may be installed as ninja-build on Debian/Ubuntu
    if ! command -v ninja &>/dev/null && ! command -v ninja-build &>/dev/null; then
        llama_die "缺少 ninja 或 ninja-build"
    fi

    if ! command -v nvcc &>/dev/null; then
        llama_warn "未找到 nvcc，CUDA 支持可能不可用"
    else
        llama_detail "NVCC: $(nvcc --version 2>/dev/null | tail -1)"
    fi

    llama_check_dir "$LLAMA_CPP_SRC" "llama.cpp 源码目录" || llama_die
    llama_check_file "${LLAMA_CPP_SRC}/CMakeLists.txt" "llama.cpp CMakeLists.txt" || llama_die

    llama_check_gpu || true

    # --- 磁盘空间检查 --------------------------------------------
    llama_check_disk_space "$LLAMA_CPP_SRC" || llama_die

    # --- 动态检测 ------------------------------------------------
    jobs=$(llama_get_cpu_count)
    llama_detail "并行编译任务数: $jobs"

    # Auto-detect GCC/G++ paths
    gcc_path=$(command -v gcc)
    gxx_path=$(command -v g++)
    llama_detail "C 编译器: $gcc_path"
    llama_detail "C++ 编译器: $gxx_path"

    # CUDA RPATH workaround (b8940+): llama.cpp declares CUDA deps as PRIVATE,
    # causing libcudart.so link failures on non-standard installs (e.g. Anaconda).
    # Inject CUDA library path via CMAKE_BUILD_RPATH.
    # TODO(upstream): llama.cpp b8940+ declares CUDA deps as PRIVATE, breaking
    # non-standard CUDA installs. Remove this block + CMAKE_BUILD_RPATH once
    # upstream fixes the visibility. Test: build without RPATH, run ldd on
    # llama-cli — if libcudart resolves, this workaround is no longer needed.
    if cuda_lib_dir=$(_detect_cuda_lib_dir); then
        llama_detail "CUDA 库路径: $cuda_lib_dir"
    else
        if command -v nvcc &>/dev/null; then
            llama_warn "无法自动检测 CUDA 库路径，构建可能失败"
        fi
        cuda_lib_dir=""
    fi

    # --- 步骤 1：清理旧构建 --------------------------------------
    if [[ "$incremental" -eq 0 ]]; then
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

    # Conditionally add CUDA library RPATH (only when cuda_lib_dir is non-empty)
    if [[ -n "$cuda_lib_dir" ]]; then
        cmake_extra_args=("-DCMAKE_BUILD_RPATH=$cuda_lib_dir")
    else
        cmake_extra_args=()
    fi

    llama_run_silent cmake -S "$LLAMA_CPP_SRC" -B "$BUILD_DIR" -G Ninja \
        -DCMAKE_C_COMPILER="$gcc_path" \
        -DCMAKE_CXX_COMPILER="$gxx_path" \
        -DCMAKE_BUILD_TYPE="${CMAKE_BUILD_TYPE}" \
        -DLLAMA_BUILD_TESTS=OFF \
        -DGGML_NATIVE="${GGML_NATIVE}" \
        -DGGML_BLAS="${GGML_BLAS}" \
        -DGGML_BLAS_VENDOR="${GGML_BLAS_VENDOR}" \
        -DGGML_CUDA=ON \
        -DCMAKE_CUDA_ARCHITECTURES="${CMAKE_CUDA_ARCHITECTURES}" \
        -DCMAKE_CUDA_FLAGS="${CMAKE_CUDA_FLAGS}" \
        -DGGML_CUDA_PEER_MAX_BATCH_SIZE="${GGML_CUDA_PEER_MAX_BATCH_SIZE}" \
        -DGGML_CUDA_FA_ALL_QUANTS="${GGML_CUDA_FA_ALL_QUANTS}" \
        ${cmake_extra_args[@]+"${cmake_extra_args[@]}"}
    local cmake_exit=$?

    if [[ "$cmake_exit" -ne 0 ]]; then
        llama_die "CMake 配置失败 (退出码: $cmake_exit)"
    fi

    llama_ok "CMake 配置完成"

    # --- 步骤 3：编译 --------------------------------------------
    llama_step "步骤 3/4：编译（${jobs} 核并行）"

    llama_run_silent cmake --build "$BUILD_DIR" -j "$jobs"
    local build_exit=$?

    if [[ "$build_exit" -ne 0 ]]; then
        llama_die "编译失败 (退出码: $build_exit)"
    fi

    llama_ok "编译完成"

    # --- 步骤 4：验证构建 ----------------------------------------
    llama_step "步骤 4/4：验证构建"

    _verify_build
    local verify_exit=$?
    if [[ "$verify_exit" -gt 0 ]]; then
        llama_die "构建验证失败，${verify_exit} 个错误"
    fi
    git -C "$LLAMA_CPP_SRC" rev-parse HEAD > "${BUILD_DIR}/.build-stamp" 2>/dev/null || llama_warn "无法写入构建标记"
    echo
    llama_ok "构建完成！"
    echo
    llama_print_run_examples "${BUILD_DIR}/bin"
    return 0
}

if [[ "${_LLAMA_SOURCE_ONLY:-}" != "1" ]]; then
    main "$@"
    _main_rc=$?
    llama_return_or_exit "$_main_rc"
fi
