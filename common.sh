#!/bin/bash
# ============================================================
# common.sh — shared utility function library
# Shared utilities for all helper scripts
# Requires: Bash >= 4.2 (declare -A associative arrays, [[ -v ]] variable test)
# ============================================================

# --- 防止重复 source -----------------------------------------
_LLAMA_COMMON_SOURCED=${_LLAMA_COMMON_SOURCED:-0}
if [[ "$_LLAMA_COMMON_SOURCED" -eq 1 ]]; then
    return 0 2>/dev/null || true
fi
_LLAMA_COMMON_SOURCED=1
# Language policy: user-facing messages (logs, errors, help text, CLI output) use Chinese.
# Code comments: design rationale in Chinese, function behavior descriptions (return values, params) may use English. Usage: lines use English. Section separator comments ("# --- name ---") use Chinese.
# Follow this convention when adding or editing messages.
# --- 安全设置 ------------------------------------------------
# Enable strict mode only when executed directly (not when sourced)
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
# Logs a detail message to stdout with blue arrow prefix.
# Usage: llama_step <header>
# Logs a bold section header to stdout.
# Usage: llama_err <message>
# Logs an error message to stderr with red [ERROR] prefix.
# Usage: llama_warn <message>
# Logs a warning message to stdout with yellow [WARN] prefix.
# Usage: llama_ok <message>
# Logs a success message to stdout with green [OK] prefix.
# Usage: llama_info <message>
# Logs an informational message to stdout with cyan [INFO] prefix.
llama_info()  { echo -e "${CYAN}[INFO]${NC} $*"; }
llama_ok()    { echo -e "${GREEN}[OK]${NC} $*"; }
llama_warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
llama_err()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }
llama_step()  { echo -e "\n${BOLD}=== $* ===${NC}"; }
llama_detail() { echo -e "${BLUE}  →${NC} $*"; }

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
# Returns the number of NVIDIA GPUs detected via nvidia-smi.
# Output: GPU count on stdout (0 if none), exit code 0 if nvidia-smi found, 1 if nvidia-smi not installed.
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
# Detects and activates conda environment. Respects CONDA_AUTO_ACTIVATE
# and CONDA_ENV_NAME from config.sh. Never fails — always returns 0.
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

    # Save shell options and relax strict mode for external conda scripts.
    # Conda activation scripts may reference unset variables or fail in ways
    # that would kill our script under set -euo pipefail (e.g. conda's
    # ~cuda-nvcc_activate.sh references NVCC_PREPEND_FLAGS without guarding).
    local prev_opts
    prev_opts=$(set +o)
    set +eu

    # shellcheck source=/dev/null
    source "$conda_sh"

    local env_name="${CONDA_ENV_NAME:-base}"
    # Execute conda activate directly (not in a command substitution subshell, or env changes are lost)
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
        # Cannot create temp file, fall back to silent mode (no stderr capture)
        if conda activate "$env_name" 2>/dev/null; then
            llama_ok "已激活 conda 环境: ${env_name}"
        else
            llama_warn "conda 环境激活失败: ${env_name}"
        fi
    fi

    # Restore previous shell options
    eval "$prev_opts" 2>/dev/null || true

    return 0
}

# --- 文件锁 --------------------------------------------------
# Use dynamic file descriptor (auto FD_CLOEXEC) to prevent child processes from inheriting the lock

# Usage: _recover_stale_lock <lock_file>
# Attempts to recover a stale lock. Returns 0 on success (LOCK_FD set), 1 on failure.
# Internal helper - called only by llama_acquire_lock.
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

# Usage: llama_acquire_lock [lock_file] — returns 0 on success, 1 if lock held
llama_acquire_lock() {
    local lock_file="${1:-$LOCK_FILE}"  # default to script-level LOCK_FILE
    if [[ -z "$lock_file" ]]; then
        llama_err "未指定锁文件路径"
        return 1
    fi

    # Ensure lock file directory exists
    local lock_dir
    lock_dir=$(dirname "$lock_file")
    if [[ ! -d "$lock_dir" ]]; then
        mkdir -p "$lock_dir" 2>/dev/null || true
    fi

    local fd
    exec {fd}>>"$lock_file"

    if ! flock -n "$fd"; then
        # Lock is held — read PID from file for diagnostics only after flock fails
        local holder_pid
        holder_pid=$(cat "$lock_file" 2>/dev/null || true)
        local holder_cmd
        if [[ -n "$holder_pid" ]] && kill -0 "$holder_pid" 2>/dev/null; then
            holder_cmd=$(ps -p "$holder_pid" -o comm= 2>/dev/null || echo "未知")
            llama_err "另一个进程正在运行 (PID: ${holder_pid}, 命令: ${holder_cmd})，请等待其完成"
        else
            exec {fd}>&- 2>/dev/null || true
            _recover_stale_lock "$lock_file"
            return $?
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
# Closes the lock file descriptor
llama_release_lock() {
    if [[ -n "${LOCK_FD:-}" ]]; then
        exec {LOCK_FD}>&- 2>/dev/null || true
        unset LOCK_FD
    fi
    # Lock files must not be deleted — flock operates on inodes, not filenames.
    # Deleting while another process is waiting would cause it to lock a deleted inode.
}

# --- 磁盘空间检查 --------------------------------------------
# Usage: llama_check_disk_space <path> [min_gb]
# Returns 0 if sufficient space, 1 otherwise
llama_check_disk_space() {
    local path="$1"
    local min_gb="${2:-${MIN_FREE_DISK_GB:-10}}"

    if [[ ! -d "$path" ]]; then
        llama_warn "无法检查磁盘空间：路径不存在 $path"
        return 0  # Non-blocking, warn only
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
# Sets up SIGINT and SIGTERM handlers
llama_setup_trap() {
    local cleanup_cmd="$1"
    if [[ -z "$cleanup_cmd" ]]; then
        return 1
    fi
    # shellcheck disable=SC2064  # Intentional: expand $cleanup_cmd at definition time, not signal time
    trap "$cleanup_cmd" SIGINT SIGTERM
}

# Usage: llama_cleanup_trap
# Resets signal handlers to default
llama_cleanup_trap() {
    trap - SIGINT SIGTERM
}

# --- 网络上下文包装 ------------------------------------------
# Usage: llama_with_network_context <description> <command> [args...]
# Runs a command with network error context
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
# Returns 0 if the argument is a full 40-char hex commit SHA, 1 otherwise.
llama_is_full_commit_sha() { [[ "$1" =~ ^[a-fA-F0-9]{40}$ ]]; }

# Usage: llama_check_build_health
# Checks if the current build is complete and matches the current source commit.
# Returns 0 = build healthy, 1 = build missing or stale.
llama_check_build_health() {
    # Guard: ensure config.sh has been sourced
    if [[ -z "${LLAMA_CPP_SRC:-}" ]]; then
        return 1
    fi
    local bin_dir="${LLAMA_CPP_SRC}/build/bin"
    if [[ ! -d "$bin_dir" ]]; then
        return 1
    fi
    # Check that critical binaries exist and are executable
    for binary in "${REQUIRED_BINARIES[@]}"; do
        if [[ ! -x "${bin_dir}/${binary}" ]]; then
            return 1
        fi
    done
    # Check that build stamp file exists and matches current source commit
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
    # No stamp file or mismatch means build dir may be from a different version
    return 1
}

# --- 跨平台文件大小 ------------------------------------------
# Usage: llama_file_size <path>
# Returns file size in bytes, or empty string on error
llama_file_size() {
    local path="$1"
    if [[ ! -f "$path" ]]; then
        return 1
    fi
    # Prefer GNU stat, then fall back to BSD stat
    local size
    size=$(stat -c %s "$path" 2>/dev/null) || \
    size=$(stat -f%z "$path" 2>/dev/null) || \
    size=""
    echo "$size"
}

# --- 可读文件大小 --------------------------------------------
# Byte constants for llama_human_size
readonly _LLAMA_BYTES_KIB=1024
readonly _LLAMA_BYTES_MIB=1048576
readonly _LLAMA_BYTES_GIB=1073741824
# Usage: llama_human_size <bytes>
# Converts byte count to human-readable format (KiB/MiB/GiB)
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
# Returns to orig_dir safely. Designed for update.sh error paths.
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
    llama_cleanup_trap
    llama_release_lock
    exit "$code"
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
    # In source context: return succeeds. In script context: return fails, fall back to exit.
    { return "$code"; } 2>/dev/null || exit "$code"
}

# --- 初始化/引用/帮助辅助 ------------------------------------
# Usage: llama_init_script_dir
# Initializes SCRIPT_DIR to the directory containing the calling script.
# Sets and exports SCRIPT_DIR to the resolved absolute path.
llama_init_script_dir() {
    # Do nothing if SCRIPT_DIR is already set (e.g., by build.sh/update.sh directly)
    if [[ -v SCRIPT_DIR ]] && [[ -n "${SCRIPT_DIR:-}" ]]; then
        return 0
    fi
    local caller="${BASH_SOURCE[1]:-${BASH_SOURCE[0]}}"
    SCRIPT_DIR="$(cd "$(dirname "$caller")" >/dev/null && pwd)"
    export SCRIPT_DIR
}

# Help text labels follow the language policy defined at file top.

# Usage: llama_show_help <script_name> <description> [options] [examples]
# Displays formatted help text to stdout with usage, description, options, and examples sections.
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
# Prints the version string to stdout.
llama_show_version() {
    echo "llama.cpp_helper ${LLAMA_HELPER_VERSION:-unknown}"
}

# Usage: llama_save_colors
# Saves current color variable values for later restoration.
# NOTE: run_env.sh contains an inline copy of this loop (color save section) because common.sh
#       is not yet loaded when colors must be saved. Both copies must be kept in sync.
llama_save_colors() {
    local cvar
    for cvar in RED GREEN YELLOW CYAN BLUE BOLD NC; do
        printf -v "_LLAMA_SAVED_${cvar}" '%s' "${!cvar-}"
    done
}

# Usage: llama_restore_colors
# Restores color variables saved by llama_save_colors. Cleans up temp vars.
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
# Runs command without set -e, capturing output. On failure, prints output to stderr.
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
