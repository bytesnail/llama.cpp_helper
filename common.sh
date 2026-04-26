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
