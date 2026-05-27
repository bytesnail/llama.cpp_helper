#!/bin/bash
# ============================================================
# common.sh — 共享工具函数库
# 所有辅助脚本的共享工具
# 要求：Bash >= 4.2（关联数组 declare -A，变量测试 [[ -v ]]）
# ============================================================

# --- 防止重复 source -----------------------------------------
_LLAMA_COMMON_SOURCED=${_LLAMA_COMMON_SOURCED:-0}
if [[ "$_LLAMA_COMMON_SOURCED" -eq 1 ]]; then
    return 0 2>/dev/null || true
fi
_LLAMA_COMMON_SOURCED=1
# --- 安全设置 ------------------------------------------------
# 仅在直接执行时启用严格模式（source 时不启用）
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    set -euo pipefail
fi

# --- 颜色 ----------------------------------------------------
if [[ -t 1 ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    CYAN='\033[0;36m'
    BLUE='\033[0;34m'
    BOLD='\033[1m'
    NC='\033[0m'
else
    RED=''
    GREEN=''
    YELLOW=''
    CYAN=''
    BLUE=''
    BOLD=''
    NC=''
fi

# --- 日志 ----------------------------------------------------
# Usage: llama_detail <message>
# 向 stdout 输出带有蓝色箭头前缀的详细信息。
# Usage: llama_step <header>
# 向 stdout 输出粗体节标题。
# Usage: llama_err <message>
# 向 stderr 输出红色 [ERROR] 前缀的错误消息。
# Usage: llama_warn <message>
# 向 stdout 输出黄色 [WARN] 前缀的警告消息。
# Usage: llama_ok <message>
# 向 stdout 输出绿色 [OK] 前缀的成功消息。
# Usage: llama_info <message>
# 向 stdout 输出青色 [INFO] 前缀的信息消息。
llama_info()  { printf '%b\n' "${CYAN}[INFO]${NC} $*"; }
llama_ok()    { printf '%b\n' "${GREEN}[OK]${NC} $*"; }
llama_warn()  { printf '%b\n' "${YELLOW}[WARN]${NC} $*"; }
llama_err()   { printf '%b\n' "${RED}[ERROR]${NC} $*" >&2; }
llama_step()  { printf '%b\n' "\n${BOLD}=== $* ===${NC}"; }
llama_detail() { printf '%b\n' "${BLUE}  →${NC} $*"; }

# --- 前置条件检查 --------------------------------------------
# Usage: llama_check_commands <cmd1> [pkg1] <cmd2> [pkg2] ...
llama_check_commands() {
    local missing=()
    while (($# >= 2)); do
        local cmd="$1"
        local pkg="$2"
        shift 2
        if ! command -v "$cmd" &>/dev/null; then
            missing+=("$cmd ($pkg)")
        fi
    done
    if (($# > 0)); then
        llama_warn "依赖参数不完整，已忽略: $*"
    fi
    if ((${#missing[@]} > 0)); then
        llama_err "缺少以下依赖:"
        local m
        for m in "${missing[@]}"; do
            llama_detail "$m"
        done
        return 1
    fi
    return 0
}

# --- 路径验证 ------------------------------------------------
# Usage: llama_check_dir <path> [description]
llama_check_dir() {
    local path="$1"
    local desc="${2:-目录}"
    if [[ ! -d "$path" ]]; then
        llama_err "$desc 不存在: $path"
        return 1
    fi
    return 0
}

# Usage: llama_check_file <path> [description]
llama_check_file() {
    local path="$1"
    local desc="${2:-文件}"
    if [[ ! -f "$path" ]]; then
        llama_err "$desc 不存在: $path"
        return 1
    fi
    return 0
}

# --- CPU 检测 ------------------------------------------------
# Usage: llama_get_cpu_count
llama_get_cpu_count() {
    local ncpu
    ncpu=$(nproc 2>/dev/null) || \
    ncpu=$(sysctl -n hw.ncpu 2>/dev/null) || \
    ncpu=$(grep -c ^processor /proc/cpuinfo 2>/dev/null) || \
    ncpu=4
    echo "$ncpu"
}

# --- GPU 检测 ------------------------------------------------
# Usage: llama_get_gpu_count
# 返回通过 nvidia-smi 检测到的 NVIDIA GPU 数量。
# 输出：stdout 输出 GPU 数量（无则为 0）；退出码：nvidia-smi 存在返回 0，未安装返回 1。
llama_get_gpu_count() {
    if command -v nvidia-smi &>/dev/null; then
        local count
        count=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | wc -l)
        echo "$count"
        return 0
    fi
    echo "0"
    return 1
}

# Usage: llama_check_gpu
llama_check_gpu() {
    local gpu_count
    gpu_count=$(llama_get_gpu_count)
    if [[ "$gpu_count" =~ ^[0-9]+$ ]] && ((gpu_count > 0)); then
        local line
        nvidia-smi --query-gpu=name,memory.total --format=csv,noheader 2>/dev/null | while IFS= read -r line; do
            llama_detail "$line"
        done
        return 0
    fi
    llama_warn "未检测到 NVIDIA GPU"
    return 1
}

# --- conda 环境 -----------------------------------------------
# Usage: llama_activate_conda
# 检测并激活 conda 环境。遵循 config.sh 中的 CONDA_AUTO_ACTIVATE
# 和 CONDA_ENV_NAME 设置。永不失败 — 始终返回 0。
llama_activate_conda() {
    if [[ "${CONDA_AUTO_ACTIVATE:-1}" != "1" ]]; then
        return 0
    fi

    if [[ -n "${CONDA_PREFIX:-}" ]]; then
        llama_info "conda 环境已激活: ${CONDA_PREFIX}"
        return 0
    fi

    local conda_root=""

    if [[ -n "${CONDA_EXE:-}" && -x "$CONDA_EXE" ]]; then
        conda_root="$(cd "$(dirname "$CONDA_EXE")/.." 2>/dev/null && pwd)" || true
    fi

    if [[ -z "$conda_root" ]]; then
        local candidate
        for candidate in \
            "${HOME}/miniconda3" \
            "${HOME}/anaconda3" \
            "${HOME}/miniforge3" \
            "${HOME}/miniconda4" \
            "/opt/conda" \
            "/opt/miniconda3" \
            "/opt/anaconda3" \
            "/opt/miniforge3"
        do
            if [[ -f "${candidate}/etc/profile.d/conda.sh" ]]; then
                conda_root="$candidate"
                break
            fi
        done
    fi

    if [[ -z "$conda_root" ]]; then
        if command -v conda &>/dev/null; then
            conda_root="$(conda info --base 2>/dev/null || true)"
        fi
    fi

    if [[ -z "$conda_root" ]]; then
        return 0
    fi

    local conda_sh="${conda_root}/etc/profile.d/conda.sh"
    if [[ ! -f "$conda_sh" ]]; then
        llama_warn "找到 conda 安装 (${conda_root}) 但缺少 shell 初始化脚本"
        return 0
    fi

    # 保存 shell 选项，为外部 conda 脚本放宽严格模式。
    # conda 激活脚本可能引用未设置变量，或在 set -euo pipefail
    # 下导致脚本退出（例如 conda 的 ~cuda-nvcc_activate.sh
    # 未做防护就直接引用 NVCC_PREPEND_FLAGS）。
    local prev_opts
    prev_opts=$(set +o)
    set +eu

    # shellcheck source=/dev/null
    source "$conda_sh"

    local env_name="${CONDA_ENV_NAME:-base}"
    # 直接执行 conda activate（不在命令替换子 shell 中执行，否则环境变更会丢失）
    local conda_err_file
    conda_err_file=$(mktemp "${TMPDIR:-/tmp}/conda_activate_err.XXXXXX" 2>/dev/null) || conda_err_file=""
    if [[ -n "$conda_err_file" ]]; then
        if conda activate "$env_name" 2>"$conda_err_file"; then
            llama_ok "已激活 conda 环境: ${env_name}"
        else
            llama_warn "conda 环境激活失败: ${env_name}"
            llama_detail "$(cat "$conda_err_file" 2>/dev/null || true)"
        fi
        rm -f "$conda_err_file"
    else
        # 无法创建临时文件，回退到静默模式（不捕获 stderr）
        if conda activate "$env_name" 2>/dev/null; then
            llama_ok "已激活 conda 环境: ${env_name}"
        else
            llama_warn "conda 环境激活失败: ${env_name}"
        fi
    fi

    # 恢复之前的 shell 选项
    eval "$prev_opts" 2>/dev/null || true

    return 0
}

# --- 文件锁 --------------------------------------------------
# 使用动态文件描述符（自动 FD_CLOEXEC），防止子进程继承锁

# Usage: _recover_stale_lock <lock_file>
# 尝试恢复残留锁。成功返回 0（设置 LOCK_FD），失败返回 1。
# 内部辅助函数 — 仅由 llama_acquire_lock 调用。
_recover_stale_lock() {
    local lock_file="$1"
    local holder_pid
    holder_pid=$(cat "$lock_file" 2>/dev/null || true)

    llama_warn "检测到残留锁（原持有者 PID ${holder_pid:-未知} 已不存在）"
    llama_detail "尝试自动清理残留锁..."
    local fd
    exec {fd}>>"$lock_file"

    if ! flock -n "$fd"; then
        llama_err "自动清理失败，锁仍然被占用"
        llama_detail "请手动检查是否有其他进程在使用该锁文件"
        llama_detail "请在确认没有其他进程占用锁文件后重试"
        exec {fd}>&- 2>/dev/null || true
        return 1
    fi

    llama_ok "残留锁已自动清理，继续执行"
    : > "$lock_file"
    echo $$ >&"$fd"
    LOCK_FD=$fd
    return 0
}

# Usage: llama_acquire_lock [lock_file]
# 返回：成功返回 0（设置 LOCK_FD），锁被占用返回 1。
llama_acquire_lock() {
    local lock_file="${1:-$LOCK_FILE}"  # 默认使用脚本级 LOCK_FILE
    if [[ -z "$lock_file" ]]; then
        llama_err "未指定锁文件路径"
        return 1
    fi

    # 确保锁文件目录存在
    local lock_dir
    lock_dir=$(dirname "$lock_file")
    if [[ ! -d "$lock_dir" ]]; then
        mkdir -p "$lock_dir" 2>/dev/null || true
    fi

    local fd
    exec {fd}>>"$lock_file"

    if ! flock -n "$fd"; then
        # 锁被占用 — 仅在 flock 失败后从文件读取 PID 用于诊断
        local holder_pid
        holder_pid=$(cat "$lock_file" 2>/dev/null || true)
        local holder_cmd
        if [[ -n "$holder_pid" ]] && kill -0 "$holder_pid" 2>/dev/null; then
            holder_cmd=$(ps -p "$holder_pid" -o comm= 2>/dev/null || echo "未知")
            llama_err "另一个进程正在运行 (PID: ${holder_pid}, 命令: ${holder_cmd})，请等待其完成"
        else
            exec {fd}>&- 2>/dev/null || true
            _recover_stale_lock "$lock_file"
            return
        fi
        exec {fd}>&- 2>/dev/null || true
        return 1
    fi
    : > "$lock_file"
    echo $$ >&"$fd"
    LOCK_FD=$fd
    return 0
}

# Usage: llama_release_lock
# 关闭锁文件描述符
llama_release_lock() {
    if [[ -n "${LOCK_FD:-}" ]]; then
        exec {LOCK_FD}>&- 2>/dev/null || true
        unset LOCK_FD
    fi
    # 锁文件不可删除 — flock 基于 inode 而非文件名操作。
    # 当另一个进程正在等待时删除文件，会导致其锁定已删除的 inode。
}

# --- 磁盘空间检查 --------------------------------------------
# Usage: llama_check_disk_space <path> [min_gb]
# 空间充足返回 0，不足返回 1
llama_check_disk_space() {
    local path="$1"
    local min_gb="${2:-${MIN_FREE_DISK_GB:-10}}"

    if [[ ! -d "$path" ]]; then
        llama_warn "无法检查磁盘空间：路径不存在 $path"
    return 0  # 不阻塞，仅警告
    fi

    local available_kb
    available_kb=$(LC_ALL=C df -P "$path" 2>/dev/null | awk 'NR==2 {print $4}')
    if [[ -z "$available_kb" ]]; then
        llama_warn "无法获取磁盘空间信息"
        return 0
    fi

    local available_gb=$((available_kb / 1024 / 1024))
    llama_detail "磁盘可用空间: ${available_gb}GB (要求: ${min_gb}GB)"

    if ((available_gb < min_gb)); then
        llama_err "磁盘空间不足: 可用 ${available_gb}GB, 需要至少 ${min_gb}GB"
        return 1
    fi

    llama_ok "磁盘空间检查通过"
    return 0
}

# --- 信号陷阱管理 --------------------------------------------
# Usage: llama_setup_trap <cleanup_command>
# 注册 SIGINT 和 SIGTERM 处理函数
llama_setup_trap() {
    local cleanup_cmd="$1"
    if [[ -z "$cleanup_cmd" ]]; then
        return 1
    fi
    # shellcheck disable=SC2064  # 有意为之：在定义时展开 $cleanup_cmd，而非信号触发时
    trap "$cleanup_cmd" SIGINT SIGTERM
}

# Usage: llama_cleanup_trap
# 将信号处理函数重置为默认值
llama_cleanup_trap() {
    trap - SIGINT SIGTERM
}

# --- 网络上下文包装 ------------------------------------------
# Usage: llama_with_network_context <description> <command> [args...]
# 在网络错误上下文中运行命令
llama_with_network_context() {
    local desc="$1"
    shift
    if "$@"; then
        return 0
    else
        local exit_code=$?
        llama_err "${desc} 失败 (退出码: ${exit_code})"
        llama_detail "请检查网络连接和远程仓库状态"
        return "$exit_code"
    fi
}

# --- Git 辅助 ------------------------------------------------
# Usage: llama_is_full_commit_sha <string>
# 参数为完整 40 字符十六进制 commit SHA 时返回 0，否则返回 1。
llama_is_full_commit_sha() { [[ "$1" =~ ^[a-fA-F0-9]{40}$ ]]; }

# Usage: llama_check_build_health
# 检查当前构建是否完整且与当前源码 commit 匹配。
# 返回 0 = 构建健康，1 = 构建缺失或过期。
llama_check_build_health() {
    # 前置检查：确保 config.sh 已被 source
    if [[ -z "${LLAMA_CPP_SRC:-}" ]]; then
        return 1
    fi
    local bin_dir="${LLAMA_CPP_SRC}/build/bin"
    if [[ ! -d "$bin_dir" ]]; then
        return 1
    fi
    # 检查关键二进制文件是否存在且可执行
    for binary in "${REQUIRED_BINARIES[@]}"; do
        if [[ ! -x "${bin_dir}/${binary}" ]]; then
            return 1
        fi
    done
    # 检查构建标记文件是否存在且与当前源码 commit 匹配
    local build_stamp="${LLAMA_CPP_SRC}/build/.build-stamp"
    local current_head
    current_head=$(git -C "$LLAMA_CPP_SRC" rev-parse HEAD 2>/dev/null || echo "")
    if [[ -f "$build_stamp" ]]; then
        local stamped_head
        stamped_head=$(cat "$build_stamp" 2>/dev/null || echo "")
        if [[ "$stamped_head" == "$current_head" ]]; then
            return 0
        fi
    fi
    # 无标记文件或不匹配意味着构建目录可能来自不同版本
    return 1
}

# --- 跨平台文件大小 ------------------------------------------
# Usage: llama_file_size <path>
# 返回文件大小（字节数），出错时返回空字符串
llama_file_size() {
    local path="$1"
    if [[ ! -f "$path" ]]; then
        return 1
    fi
    # 优先使用 GNU stat，然后回退到 BSD stat
    local size
    size=$(stat -c %s "$path" 2>/dev/null) || \
    size=$(stat -f%z "$path" 2>/dev/null) || \
    size=""
    echo "$size"
}

# --- 可读文件大小 --------------------------------------------
# llama_human_size 的字节常量
readonly _LLAMA_BYTES_KIB=1024
readonly _LLAMA_BYTES_MIB=1048576
readonly _LLAMA_BYTES_GIB=1073741824
# Usage: llama_human_size <bytes>
# 将字节数转换为人类可读格式（KiB/MiB/GiB）
llama_human_size() {
    local bytes="$1"
    if ((bytes >= _LLAMA_BYTES_GIB)); then
        local gb=$((bytes / _LLAMA_BYTES_GIB))
        local frac=$(( (bytes % _LLAMA_BYTES_GIB) * 100 / _LLAMA_BYTES_GIB ))
        local frac_str
        printf -v frac_str '%02d' "$frac"
        echo "${gb}.${frac_str}GiB"
    elif ((bytes >= _LLAMA_BYTES_MIB)); then
        echo "$((bytes / _LLAMA_BYTES_MIB))MiB"
    elif ((bytes >= _LLAMA_BYTES_KIB)); then
        echo "$((bytes / _LLAMA_BYTES_KIB))KiB"
    else
        echo "${bytes}B"
    fi
}

# --- 退出辅助 ------------------------------------------------
# Usage: llama_cd_back
# 安全返回 orig_dir。为 update.sh 错误路径设计。
llama_cd_back() {
    if [[ -z "${orig_dir:-}" ]]; then
        return 0
    fi
    cd "$orig_dir" >/dev/null 2>&1 || {
        llama_warn "无法返回原始目录: ${orig_dir}"
        return 1
    }
}

# Usage: llama_die [message] [exit_code]
llama_die() {
    local msg="${1:-}"
    local code="${2:-1}"
    if [[ -n "$msg" ]]; then
        llama_err "$msg"
    fi
    llama_safe_exit "$code"
}

# Usage: llama_safe_exit [exit_code]
llama_safe_exit() {
    local code="${1:-0}"
    llama_cleanup_trap
    llama_release_lock
    exit "$code"
}

# Usage: llama_return_or_exit <exit_code>
llama_return_or_exit() {
    local code="$1"
    # source 上下文中：return 成功。脚本上下文中：return 失败，回退到 exit。
    { return "$code"; } 2>/dev/null || exit "$code"
}

# --- 初始化/引用/帮助辅助 ------------------------------------
# Usage: llama_init_script_dir
# 将 SCRIPT_DIR 初始化为调用脚本所在目录。
# 设置并导出 SCRIPT_DIR 为解析后的绝对路径。
llama_init_script_dir() {
    # SCRIPT_DIR 已设置时不做任何操作（例如由 build.sh/update.sh 直接设置）
    if [[ -v SCRIPT_DIR ]] && [[ -n "${SCRIPT_DIR:-}" ]]; then
        return 0
    fi
    local caller="${BASH_SOURCE[1]:-${BASH_SOURCE[0]}}"
    SCRIPT_DIR="$(cd "$(dirname "$caller")" >/dev/null && pwd)"
    export SCRIPT_DIR
}

# 帮助文本标签遵循文件顶部定义的语言策略。

# Usage: llama_show_help <script_name> <description> [options] [examples]
# 向 stdout 输出格式化帮助文本，包含用法、描述、选项和示例节。
llama_show_help() {
    local script_name="$1"
    local description="$2"
    local options="${3:-}"
    local examples="${4:-}"
    cat <<EOF
用法: ${script_name} [选项]

描述:
  ${description}
EOF
    if [[ -n "$options" ]]; then
        echo
        echo "选项:"
        echo "$options"
    fi
    if [[ -n "$examples" ]]; then
        echo
        echo "示例:"
        echo "$examples"
    fi
}

# Usage: llama_show_version
# 向 stdout 输出版本字符串。
llama_show_version() {
    echo "llama.cpp_helper ${LLAMA_HELPER_VERSION:-unknown}"
}

# Usage: llama_save_colors
# 保存当前颜色变量值，供后续恢复使用。
# 注意：run_env.sh 包含此循环的内联副本（颜色保存部分），因为 common.sh
#       在需要保存颜色时尚未加载。两份副本必须保持同步。
llama_save_colors() {
    local cvar
    for cvar in RED GREEN YELLOW CYAN BLUE BOLD NC; do
        printf -v "_LLAMA_SAVED_${cvar}" '%s' "${!cvar-}"
    done
}

# Usage: llama_restore_colors
# 恢复 llama_save_colors 保存的颜色变量。清理临时变量。
llama_restore_colors() {
    local cvar saved_var
    for cvar in RED GREEN YELLOW CYAN BLUE BOLD NC; do
        saved_var="_LLAMA_SAVED_${cvar}"
        if [[ -n "${!saved_var+isset}" ]]; then
            printf -v "$cvar" '%s' "${!saved_var}"
        else
            unset "$cvar" 2>/dev/null || true
        fi
        unset "$saved_var"
    done
}
# Usage: llama_print_run_examples <bin_dir>
llama_print_run_examples() {
    local bin_dir="${1:?bin_dir required}"
    local script_dir="${SCRIPT_DIR:-.}"
    echo "运行示例:"
    echo "  source ${script_dir}/run_env.sh"
    echo "  ${bin_dir}/llama-cli -m /path/to/model.gguf -ngl 99 -p \"你好\""
    echo "  ${bin_dir}/llama-server -m /path/to/model.gguf -ngl 99 --port 8080"
}

# Usage: llama_run_silent <command> [args...]
# 在禁用 set -e 的情况下运行命令并捕获输出。失败时将输出发送到 stderr。
llama_run_silent() {
    local ret
    local prev_opts
    local tmp_out
    tmp_out=$(mktemp "${TMPDIR:-/tmp}/llama_run_silent.XXXXXX" 2>/dev/null) || tmp_out=""
    prev_opts=$(set +o)
    set +e
    if [[ -n "$tmp_out" ]]; then
        "$@" >"$tmp_out" 2>&1
        ret=$?
        if [[ "$ret" -ne 0 ]]; then
            llama_warn "命令失败 (退出码: ${ret})"
            cat "$tmp_out" >&2 2>/dev/null || true
        fi
        rm -f "$tmp_out"
    else
        "$@"
        ret=$?
    fi
    eval "$prev_opts" 2>/dev/null || true
    return "$ret"
}
