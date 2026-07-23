#!/bin/bash
# ============================================================
# build.sh — llama.cpp 构建脚本
# 目标：同时启用 OpenBLAS（CPU）+ CUDA（双 RTX 2080 Ti NVLink）
# 硬件：Intel Xeon E5-2667 v4（2 路 × 8 物理核，16 物理核 / 32 线程，AVX2+FMA，无 AVX-512）
#       256GB RAM
#       2× RTX 2080 Ti 22GB（NVLink NV2 双链路，sm_75）
# 软件：CUDA / OpenBLAS / GCC / Ninja（版本要求：见 README）
# Usage: cd /path/to/llama.cpp_helper && bash build.sh
# ============================================================

# 仅在正常执行时启用严格模式（为测试提取而 source 时不启用）
if [[ "${_LLAMA_SOURCE_ONLY:-}" != "1" ]]; then
    set -euo pipefail
fi

# 注意：此处内联初始化 SCRIPT_DIR，因为 source common.sh 需要它。
# llama_init_script_dir() 存在但仅用于无法提前解析 SCRIPT_DIR 的场景（如 run_env.sh）。
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null && pwd)"
readonly SCRIPT_DIR
source "${SCRIPT_DIR}/common.sh"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/config.sh"

# --- 退出清理 ------------------------------------------------
# BUILD_DIR 由 config.sh 统一定义（写方 build.sh 与读方 common.sh/update.sh 的
# 共享协议）；文件锁在 main() 参数解析之后才获取，--help/--version 不受锁占用影响。
# Usage: _cleanup_on_exit [exit_code]
_cleanup_on_exit() {
    # 信号路径由 trap 显式传入退出码（130/143）：信号在 builtin 间隙到达时
    # $? 可能为 0，会导致不清理并以 0 退出（update.sh 据此误判构建成功）
    local exit_code="${1:-$?}"
    [[ "${_CLEANUP_DONE:-0}" -eq 1 ]] && return 0
    _CLEANUP_DONE=1
    # 仅当本次运行确实进入重建流程（_BUILD_TOUCHED）后才清理构建目录；
    # 否则参数错误/前置检查失败等早期退出会误删上一次成功的构建产物。
    if [[ "${_BUILD_TOUCHED:-0}" -eq 1 && "${incremental:-0}" -eq 0 && "$exit_code" -ne 0 && -d "${BUILD_DIR:-}" ]]; then
        llama_warn "清理未完成的构建目录..."
        rm -rf "$BUILD_DIR"
    fi
    llama_safe_exit "$exit_code"
}
if [[ "${_LLAMA_SOURCE_ONLY:-}" != "1" ]]; then
    trap '_cleanup_on_exit 130' SIGINT   # 130 = 128 + SIGINT(2)
    trap '_cleanup_on_exit 143' SIGTERM  # 143 = 128 + SIGTERM(15)
    trap '_cleanup_on_exit' EXIT
fi

# trap 设计说明：
# - 信号 trap 显式传入退出码 → _cleanup_on_exit（用户中断时强制非零退出 + 清理）
# - trap EXIT 无参 → _cleanup_on_exit 使用 $?（llama_die→exit 路径也执行清理）
# _CLEANUP_DONE 守卫防止信号与 EXIT 同时触发时的重复执行。
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
# 返回：0=存在, 1=缺失
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
# Usage: _verify_linking <bin_dir> [binary] [grep_pattern] [label] [not_found_msg] [ldd_output]
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
    # 可选第 6 参：调用方缓存的 ldd 输出（避免对同一二进制重复 ldd）
    local ldd_output="${6:-}"

    llama_info "${label} 链接检查:"
    local bin_path="${bin_dir}/${binary}"

    if [[ ! -x "$bin_path" ]]; then
        llama_warn "${binary} 不存在，跳过 ${label} 链接检查"
        return 0
    fi
    if [[ -z "$ldd_output" ]]; then
        ldd_output=$(ldd "$bin_path" 2>/dev/null) || true
    fi
    # 单次 grep 捕获匹配行（原实现先 grep -q 判断、再用相同模式 grep 第二遍
    # 打印，同一正则扫描两遍且判断与输出可能漂移）
    local matches
    matches=$(grep -iE "$pattern" <<< "$ldd_output" || true)
    if [[ -n "$matches" ]]; then
        while IFS= read -r line; do
            llama_detail "$line"
        done <<< "$matches"
        llama_ok "${label} 链接正常"
    else
        llama_warn "${not_found_msg}"
    fi
}

# Usage: _verify_cuda_linking <bin_dir> [binary] [ldd_output]
_verify_cuda_linking() {
    _verify_linking "${1:-}" "${2:-llama-cli}" "libcudart|libcublas|libcuda" "CUDA" "未找到 CUDA 动态库链接（可能是静态链接）" "${3:-}"
}

# Usage: _verify_openblas_linking <bin_dir> [binary] [ldd_output]
_verify_openblas_linking() {
    _verify_linking "${1:-}" "${2:-llama-cli}" "libopenblas|libblas" "OpenBLAS" "未找到 OpenBLAS 动态库链接（可能是静态链接或未启用）" "${3:-}"
}

# Usage: _verify_openblas_runtime <bin_dir> [binary] [ldd_output]
_verify_openblas_runtime() {
    local bin_dir="$1"
    local binary="${2:-llama-cli}"
    local ldd_output="${3:-}"
    local bin_path="${bin_dir}/${binary}"

    llama_info "OpenBLAS 运行时验证："
    if [[ -z "$ldd_output" ]]; then
        ldd_output=$(ldd "$bin_path" 2>/dev/null || true)
    fi
    local openblas_lib
    # || true：grep 无匹配（如 GGML_BLAS=OFF 构建）管线在 pipefail 下返回
    # 非零，会在到达降级分支前中止脚本（反模式 8：函数设计了优雅降级，
    # 管线赋值必须防护，不能依赖调用点的 || true）
    openblas_lib=$(grep -oE '/[^ ]+libopenblas[^ ]*' <<< "$ldd_output" | head -1 || true)
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
    # BUILD_BIN_DIR 由 config.sh 统一定义（_LLAMA_SOURCE_ONLY 提取模式同样
    # 经 build.sh 顶部 source config.sh 获得，不再依赖被跳过的顶层赋值）
    local bin_dir="${BUILD_BIN_DIR:-${BUILD_DIR}/bin}"
    local verify_binary="${REQUIRED_BINARIES[0]}"

    # 对同一二进制只执行一次 ldd，缓存供全部链接/运行时检查复用
    # （ldd 需解析全部动态依赖，对 llama-cli 每次约 10-50ms）
    local ldd_cache=""
    if [[ -x "${bin_dir}/${verify_binary}" ]]; then
        ldd_cache=$(ldd "${bin_dir}/${verify_binary}" 2>/dev/null || true)
    fi

    # 检查关键二进制文件
    for binary in "${REQUIRED_BINARIES[@]}"; do
        _verify_binary_exists "$binary" "$bin_dir" || errors=$((errors + 1))
    done

    # 链接检查（非致命）
    _verify_cuda_linking "$bin_dir" "$verify_binary" "$ldd_cache"
    _verify_openblas_linking "$bin_dir" "$verify_binary" "$ldd_cache"

    # 验证二进制文件可执行性
    llama_info "验证二进制文件可执行性："
    if "${bin_dir}/${verify_binary}" --version &>/dev/null; then
        llama_ok "${verify_binary} 可正常启动"
    else
        # 二进制无法运行（如缺少运行时依赖/RPATH 错误）属真正的构建失败：
        # 计入 errors 以阻止写入 .build-stamp，否则 llama_check_build_health
        # 会将损坏的构建误判为健康，update.sh 据此跳过重建。
        llama_err "${verify_binary} 启动验证失败（二进制无法运行，可能缺少运行时依赖）"
        errors=$((errors + 1))
    fi

    # 运行时验证（非致命）
    _verify_openblas_runtime "$bin_dir" "$verify_binary" "$ldd_cache" || true
    return "$errors"
}

# --- 主逻辑 --------------------------------------------------
main() {
incremental=0  # 脚本级变量：trap handler 无法访问 main() 局部变量
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

    # --- 文件锁（在参数解析之后获取，--help/--version 不受锁占用影响） -------
    llama_acquire_lock || llama_die "无法获取文件锁"

    # --- 前置检查 ------------------------------------------------
    # 激活 conda 环境（如果 CUDA 工具链通过 conda 安装）
    llama_activate_conda

    llama_step "前置检查"

    # shellcheck disable=SC2015
    llama_check_commands \
        cmake "cmake" \
        gcc "gcc" \
        g++ "g++" \
        python3 "python3" \
        flock "util-linux" \
        && llama_ok "构建工具检查通过" || llama_die "构建工具检查失败"

    # ninja 在 Debian/Ubuntu 上可能以 ninja-build 名称安装
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

    llama_print_hardware_summary

    # --- 磁盘空间检查 --------------------------------------------
    llama_check_disk_space "$LLAMA_CPP_SRC" || llama_die

    # --- 动态检测 ------------------------------------------------
    jobs=$(llama_get_cpu_count)
    llama_detail "并行编译任务数: $jobs"

    # 自动检测 GCC/G++ 路径
    gcc_path=$(command -v gcc)
    gxx_path=$(command -v g++)
    llama_detail "C 编译器: $gcc_path"
    llama_detail "C++ 编译器: $gxx_path"

    # CUDA RPATH 临时方案（b8940+）：llama.cpp 将 CUDA 依赖声明为 PRIVATE，
    # 导致非标准安装路径下 libcudart.so 链接失败（如 Anaconda）。
    # 通过 CMAKE_BUILD_RPATH 注入 CUDA 库路径。
    # TODO(upstream)：llama.cpp b8940+ 将 CUDA 依赖声明为 PRIVATE，导致
    # 非标准 CUDA 安装失败。上游修复可见性后，移除此代码块 + CMAKE_BUILD_RPATH。
    # 测试方法：构建时不设置 RPATH，对 llama-cli 运行 ldd —
    # 如果 libcudart 能正确解析，则此临时方案不再需要。
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
        _BUILD_TOUCHED=1  # 脚本级标记：已进入重建流程，EXIT trap 据此判断是否清理
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

    # 仅在 cuda_lib_dir 非空时添加 CUDA 库 RPATH
    if [[ -n "$cuda_lib_dir" ]]; then
        cmake_extra_args=("-DCMAKE_BUILD_RPATH=$cuda_lib_dir")
    else
        cmake_extra_args=()
    fi

    # llama_run_silent 恒返回 0，退出码写入 cmake_exit（先 local 声明，
    # 动态作用域下的 printf -v 才会写入此局部变量）
    local cmake_exit
    llama_run_silent cmake_exit cmake -S "$LLAMA_CPP_SRC" -B "$BUILD_DIR" -G Ninja \
        -DCMAKE_C_COMPILER="$gcc_path" \
        -DCMAKE_CXX_COMPILER="$gxx_path" \
        -DCMAKE_BUILD_TYPE="${CMAKE_BUILD_TYPE}" \
        -DLLAMA_BUILD_TESTS="${LLAMA_BUILD_TESTS}" \
        -DGGML_NATIVE="${GGML_NATIVE}" \
        -DGGML_BLAS="${GGML_BLAS}" \
        -DGGML_BLAS_VENDOR="${GGML_BLAS_VENDOR}" \
        -DGGML_CUDA="${GGML_CUDA}" \
        -DCMAKE_CUDA_ARCHITECTURES="${CMAKE_CUDA_ARCHITECTURES}" \
        -DCMAKE_CUDA_FLAGS="${CMAKE_CUDA_FLAGS}" \
        -DGGML_CUDA_PEER_MAX_BATCH_SIZE="${GGML_CUDA_PEER_MAX_BATCH_SIZE}" \
        -DGGML_CUDA_FA_ALL_QUANTS="${GGML_CUDA_FA_ALL_QUANTS}" \
        -DGGML_CUDA_GRAPHS="${GGML_CUDA_GRAPHS}" \
        ${cmake_extra_args[@]+"${cmake_extra_args[@]}"}

    if [[ "$cmake_exit" -ne 0 ]]; then
        llama_die "CMake 配置失败 (退出码: $cmake_exit)"
    fi

    llama_ok "CMake 配置完成"

    # --- 步骤 3：编译 --------------------------------------------
    llama_step "步骤 3/4：编译（${jobs} 核并行）"

    local build_exit
    llama_run_silent build_exit cmake --build "$BUILD_DIR" -j "$jobs"

    if [[ "$build_exit" -ne 0 ]]; then
        llama_die "编译失败 (退出码: $build_exit)"
    fi

    llama_ok "编译完成"

    # --- 步骤 4：验证构建 ----------------------------------------
    llama_step "步骤 4/4：验证构建"

    # _verify_build 以返回码报告错误数；|| 捕获防止 set -e 提前中止
    local verify_exit=0
    _verify_build || verify_exit=$?
    if [[ "$verify_exit" -gt 0 ]]; then
        llama_die "构建验证失败，${verify_exit} 个错误"
    fi
    # 先取 HEAD 成功后再写 stamp：重定向先于 git 执行，
    # git 失败时直接写会留下空 stamp（llama_check_build_health 曾因此误判健康）
    local head_sha
    if head_sha=$(git -C "$LLAMA_CPP_SRC" rev-parse HEAD 2>/dev/null); then
        printf '%s\n' "$head_sha" > "$BUILD_STAMP" || llama_warn "无法写入构建标记"
    else
        llama_warn "无法读取源码 commit，跳过构建标记"
    fi
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
