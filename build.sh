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
    # _BUILD_COMMITTED：构建成功后显式置位——即便 EXIT trap 因信号路径上
    # $? 偶非零而被触发，删除条件亦据此短路，保护已提交事务（不依赖 $?==0
    # 这一非结构保证，见下方 407 处说明）。
    if [[ "${_BUILD_TOUCHED:-0}" -eq 1 && "${_BUILD_COMMITTED:-0}" -ne 1 && "${incremental:-0}" -eq 0 && "$exit_code" -ne 0 && -d "${BUILD_DIR:-}" ]]; then
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
    nvcc_dir=$(dirname "$(dirname "$nvcc_real_path")")
    local cuda_lib_dir
    cuda_lib_dir="${nvcc_dir}/targets/$(uname -m)-linux/lib"
    if [[ ! -d "$cuda_lib_dir" ]]; then
        local cuda_rt max_search_depth=6
        # || true 保护降级路径：find 遇遍历错误（子目录权限拒绝）会返回非零，
        # set -euo pipefail 下会在此中止整个 build.sh，使函数设计的 return 1
        # 与调用点 if/else 降级分支（见行 ~314）永远无法到达。参考反模式 8。
        cuda_rt=$(find "$nvcc_dir" -maxdepth "$max_search_depth" -name libcudart.so -not -path '*/stubs/*' -print -quit 2>/dev/null || true)
        if [[ -n "$cuda_rt" ]]; then
            # 内层 readlink 必须防护：本函数在调用点的 if 条件中执行（set -e
            # 已失效），readlink 失败（TOCTOU/异常文件系统）时 dirname 空串
            # 得到 "."——能通过下方 -d 检查被当作 CUDA 库目录，静默把
            # CMAKE_BUILD_RPATH 污染为当前目录（已实证）
            local cuda_rt_real
            cuda_rt_real=$(readlink -f "$cuda_rt" 2>/dev/null || true)
            if [[ -n "$cuda_rt_real" ]]; then
                cuda_lib_dir=$(dirname "$cuda_rt_real")
            fi
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
    local binary="${2:-${REQUIRED_BINARIES[0]}}"
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
    _verify_linking "${1:-}" "${2:-${REQUIRED_BINARIES[0]}}" "libcudart|libcublas|libcuda" "CUDA" "未找到 CUDA 动态库链接（可能是静态链接）" "${3:-}"
}

# Usage: _verify_openblas_linking <bin_dir> [binary] [ldd_output]
_verify_openblas_linking() {
    _verify_linking "${1:-}" "${2:-${REQUIRED_BINARIES[0]}}" "libopenblas|libblas" "OpenBLAS" "未找到 OpenBLAS 动态库链接（可能是静态链接或未启用）" "${3:-}"
}

# Usage: _verify_openblas_runtime <bin_dir> [binary] [ldd_output]
_verify_openblas_runtime() {
    local bin_dir="$1"
    local binary="${2:-${REQUIRED_BINARIES[0]}}"
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
    # BUILD_BIN_DIR 由 config.sh 无条件定义（本脚本顶部恒 source，含
    # _LLAMA_SOURCE_ONLY 提取模式）——无回退，直接引用
    local bin_dir="$BUILD_BIN_DIR"
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

# Usage: _pin_host_toolchain
# 激活 conda 后调用（调用点紧随 llama_activate_conda）：gcc 从 PATH 查找
# ld/as 等子程序，conda 环境带入的交叉 binutils 裸名工具位于 env bin 最前，
# 会劫持链接（见 config.sh 的 LLAMA_HOST_TOOLCHAIN_BIN 注释）。COMPILER_PATH
# 是 gcc 子程序搜索的官方机制且优先于 PATH，钉到系统 binutils 目录恢复匹配；
# 已有值保留在前缀之后，不破坏调用者的自定义配置。
_pin_host_toolchain() {
    export COMPILER_PATH="${LLAMA_HOST_TOOLCHAIN_BIN}${COMPILER_PATH:+:${COMPILER_PATH}}"
    llama_detail "host 工具链查找路径 (COMPILER_PATH): ${COMPILER_PATH}"
}

# --- 主逻辑 --------------------------------------------------
main() {
incremental=0  # 脚本级变量：trap handler 无法访问 main() 局部变量
    local jobs
    # cuda_lib_dir 无初始化：313 行的命令替换赋值是唯一写入点且必然执行
    # （失败时赋空串并进 else），提前 ="" 是掩盖真实数据流的死代码
    local gcc_path gxx_path cuda_lib_dir
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
    # 劫持由激活引入，钉住也须紧随其后：CMake try_compile 经环境继承，
    # nvcc 驱动 host 链接同样走 gcc 子进程——均在 CMake 配置前覆盖
    _pin_host_toolchain

    llama_step "前置检查"

    # if/else 而非 A && B || C：llama_ok 的 printf 失败（写端关闭/文件系统满）
    # 会被 || 分支误判为检查失败
    if llama_check_commands \
        cmake "cmake" \
        gcc "gcc" \
        g++ "g++" \
        python3 "python3" \
        flock "util-linux"; then
        llama_ok "构建工具检查通过"
    else
        llama_die "构建工具检查失败"
    fi

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
        # 命令替换失败时 cuda_lib_dir 已被赋为空串（检测函数无输出），
        # 无需显式重置
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

    # 由 config.sh 的 LLAMA_CMAKE_KNOBS 旋钮表生成 -D 透传参数：
    # 新增/调整构建旋钮只需改 config.sh，此处无需同步修改；
    # ${!knob} 间接展开在旋钮未定义时由 set -u 大声失败（而非静默漏传）
    local cmake_knob_args=() knob
    for knob in "${LLAMA_CMAKE_KNOBS[@]}"; do
        cmake_knob_args+=("-D${knob}=${!knob}")
    done

    # llama_run_silent 恒返回 0，退出码写入 cmake_exit（先 local 声明，
    # 动态作用域下的 printf -v 才会写入此局部变量）
    local cmake_exit
    llama_run_silent cmake_exit cmake -S "$LLAMA_CPP_SRC" -B "$BUILD_DIR" -G Ninja \
        -DCMAKE_C_COMPILER="$gcc_path" \
        -DCMAKE_CXX_COMPILER="$gxx_path" \
        ${cmake_knob_args[@]+"${cmake_knob_args[@]}"} \
        ${cmake_extra_args[@]+"${cmake_extra_args[@]}"}

    if [[ "$cmake_exit" -ne 0 ]]; then
        llama_die "CMake 配置失败 (退出码: $cmake_exit)"
    fi

    llama_ok "CMake 配置完成"

    # --- 步骤 3：编译 --------------------------------------------
    llama_step "步骤 3/4：编译（${jobs} 核并行）"

    # 直跑（不经 llama_run_silent）：完整编译要 30-60 分钟，ninja 进度须
    # 流式可见——静默包装期间控制台零输出，无法区分卡死与编译中。
    # 步骤 2 的 CMake 配置保留 llama_run_silent：秒级命令，失败时转储完整
    # 输出、成功时保持安静。|| 捕获退出码（set -e 下失败不中止，由下方 die 报告）
    local build_exit=0
    cmake --build "$BUILD_DIR" -j "$jobs" || build_exit=$?

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
    # 构建已验证通过且 stamp 写入——事务已提交。双保险防止摘要打印期间
    # SIGINT/SIGTERM 撤销已提交事务（与 update.sh "成功事务不可被信号撤销"对齐）：
    #   - _BUILD_COMMITTED=1：使 _cleanup_on_exit 的删除条件结构性短路，不依赖
    #     EXIT trap 上 $? 偶为 0 这一非保证（信号路径 $? 因 bash 版本/上下文而异）
    #   - llama_cleanup_trap：解除 SIGINT/SIGTERM trap，阻止 _cleanup_on_exit 被显式
    #     传入 130/143（否则即便不删目录也会以非零退出码谎报失败）
    _BUILD_COMMITTED=1
    llama_cleanup_trap
    echo
    llama_ok "构建完成！"
    echo
    # BUILD_BIN_DIR（config.sh 单一定义的共享协议，可独立覆盖）——
    # 与 _verify_build 及 update.sh 的成功摘要保持同一视角
    llama_print_run_examples "$BUILD_BIN_DIR"
    return 0
}

if [[ "${_LLAMA_SOURCE_ONLY:-}" != "1" ]]; then
    main "$@"
    _main_rc=$?
    llama_return_or_exit "$_main_rc"
fi
