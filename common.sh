#!/bin/bash
# ============================================================
# llama.cpp helper - Common Library
# Shared utilities for all helper scripts
# ============================================================

# --- Safety --------------------------------------------------
# Only enable strict mode when executed directly (not when sourced)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    set -euo pipefail
fi

# --- Colors --------------------------------------------------
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

# --- Logging -------------------------------------------------
llama_info()  { echo -e "${CYAN}[INFO]${NC} $*"; }
llama_ok()    { echo -e "${GREEN}[OK]${NC} $*"; }
llama_warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
llama_err()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }
llama_step()  { echo -e "\n${BOLD}=== $* ===${NC}"; }
llama_detail(){ echo -e "${BLUE}  →${NC} $*"; }

# --- Prerequisite Checking -----------------------------------
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
        llama_warn "llama_check_commands 参数未成对，忽略: $1"
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

# --- Path Validation -----------------------------------------
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

# --- CPU Detection -------------------------------------------
llama_get_cpu_count() {
    local ncpu
    ncpu=$(nproc 2>/dev/null) || \
    ncpu=$(sysctl -n hw.ncpu 2>/dev/null) || \
    ncpu=$(grep -c ^processor /proc/cpuinfo 2>/dev/null) || \
    ncpu=4
    echo "$ncpu"
}

# --- GPU Detection -------------------------------------------
llama_check_gpu() {
    if command -v nvidia-smi &>/dev/null; then
        local gpu_count
        gpu_count=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | wc -l)
        if [[ "$gpu_count" -gt 0 ]]; then
            local line
            nvidia-smi --query-gpu=name,memory.total --format=csv,noheader 2>/dev/null | while IFS= read -r line; do
                llama_detail "$line"
            done
            return 0
        fi
    fi
    llama_warn "未检测到 NVIDIA GPU"
    return 1
}

# --- File Locking --------------------------------------------
# 使用动态文件描述符（自动 FD_CLOEXEC），防止子进程继承锁
# Usage: llama_acquire_lock [lock_file]
# Returns 0 on success, 1 if lock is held by another process
llama_acquire_lock() {
    local lock_file="${1:-$LOCK_FILE}"
    if [[ -z "$lock_file" ]]; then
        llama_err "未指定锁文件路径"
        return 1
    fi
    # 使用动态 fd，bash 自动设置 close-on-exec，防止子进程继承
    local fd
    exec {fd}>"$lock_file"
    if ! flock -n "$fd"; then
        # 锁被占用，尝试读取持有者 PID 用于诊断
        local holder_pid holder_cmd
        holder_pid=$(cat "$lock_file" 2>/dev/null || true)
        if [[ -n "$holder_pid" ]] && kill -0 "$holder_pid" 2>/dev/null; then
            holder_cmd=$(ps -p "$holder_pid" -o comm= 2>/dev/null || echo "未知")
            llama_err "另一个进程正在运行 (PID: ${holder_pid}, 命令: ${holder_cmd})，请等待其完成"
        else
            # 锁文件中的 PID 已不存在，但 flock 仍被持有，说明是其他进程继承了 fd
            llama_err "另一个进程正在运行，请等待其完成"
            llama_detail "提示: 如果确认无其他更新/构建进程在运行，可手动删除锁文件: rm -f ${lock_file}"
        fi
        exec {fd}>&- 2>/dev/null || true
        return 1
    fi
    # 获取锁成功，写入 PID 用于诊断
    echo $$ >&"$fd"
    # 保存 fd 到全局变量，供 llama_release_lock 使用
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
}

# --- Disk Space Check ----------------------------------------
# Usage: llama_check_disk_space <path> [min_gb]
# Returns 0 if sufficient space, 1 otherwise
llama_check_disk_space() {
    local path="$1"
    local min_gb="${2:-${MIN_FREE_DISK_GB:-10}}"
    
    if [[ ! -d "$path" ]]; then
        llama_warn "无法检查磁盘空间：路径不存在 $path"
        return 0  # 不阻塞，仅警告
    fi
    
    local available_kb
    available_kb=$(df -P "$path" 2>/dev/null | awk 'NR==2 {print $4}')
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

# --- Signal Trap Management ----------------------------------
# Usage: llama_setup_trap <cleanup_command>
# Sets up SIGINT and SIGTERM handlers
llama_setup_trap() {
    local cleanup_cmd="$1"
    if [[ -z "$cleanup_cmd" ]]; then
        return 1
    fi
    trap "$cleanup_cmd" SIGINT SIGTERM
}

# Usage: llama_cleanup_trap
# Resets signal handlers to default
llama_cleanup_trap() {
    trap - SIGINT SIGTERM
}

# --- Network Context Wrapping --------------------------------
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

# --- Portable stat -------------------------------------------
# Usage: llama_file_size <path>
# Returns file size in bytes, or empty string on error
llama_file_size() {
    local path="$1"
    if [[ ! -f "$path" ]]; then
        return 1
    fi
    # Try GNU stat first, then BSD stat
    local size
    size=$(stat -c %s "$path" 2>/dev/null) || \
    size=$(stat -f%z "$path" 2>/dev/null) || \
    size=""
    echo "$size"
}
