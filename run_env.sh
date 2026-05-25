#!/bin/bash
# ============================================================
# run_env.sh — runtime performance optimization environment variables
# Hardware: 2× RTX 2080 Ti (NVLink) - discrete GPUs, unified memory not recommended
# Usage: source /path/to/llama.cpp_helper/run_env.sh
# ============================================================

# Prevent direct execution
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "[WARN] 本脚本应当使用 source 执行，而非直接运行" >&2
    echo "用法: source ${BASH_SOURCE[0]} [选项]" >&2
    echo "" >&2
    echo "直接执行不会在当前 shell 中设置环境变量。" >&2
    exit 1
fi

# Prevent duplicate source
_LLAMA_RUN_ENV_SOURCED=${_LLAMA_RUN_ENV_SOURCED:-0}
if [[ "$_LLAMA_RUN_ENV_SOURCED" -eq 1 ]]; then
    return 0 2>/dev/null || true
fi
_LLAMA_RUN_ENV_SOURCED=1

# This script is designed to be sourced; set -euo pipefail not enabled
# because exiting when sourced would kill the parent shell

# Load common.sh
# Save color variables — must be done before sourcing common.sh (common.sh would overwrite them)
# Note: inline code is used instead of llama_save_colors() because that function is in common.sh
#       and common.sh has not been loaded yet. Functionally equivalent to llama_save_colors() in common.sh.
for _v in RED GREEN YELLOW CYAN BLUE BOLD NC; do
    printf -v "_LLAMA_SAVED_${_v}" '%s' "${!_v-}"
done
unset _v

# Bootstrap: find and source common.sh (shared helpers not yet available)
_BOOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null && pwd)"
if [[ ! -f "${_BOOT_DIR}/common.sh" ]]; then
    # shellcheck disable=SC2317
    echo "[ERROR] 未找到 common.sh: ${_BOOT_DIR}/common.sh" >&2
    return 1 2>/dev/null || exit 1
fi
# shellcheck source=/dev/null
source "${_BOOT_DIR}/common.sh"
unset _BOOT_DIR

# Shared helpers now available — set SCRIPT_DIR correctly
llama_init_script_dir

# Source config.sh for version info (used by llama_show_version)
if [[ -f "${SCRIPT_DIR}/config.sh" ]]; then
    # shellcheck source=/dev/null
    source "${SCRIPT_DIR}/config.sh"
fi

# --- 环境变量定义 --------------------------------------------
# Use associative array to define all environment variables to set
# Format: [var_name]="value|description"
declare -A _LLAMA_RUN_ENV_VARS=(
    ["GGML_CUDA_P2P"]="1|启用 GPU 间 P2P 直传（NVLink）"
    ["CUDA_SCALE_LAUNCH_QUEUES"]="4x|增大 CUDA 命令缓冲区（多 GPU 并行受益）"
)

# --- 帮助信息 ------------------------------------------------
_show_help() {
    llama_show_help \
        "source $(basename "${BASH_SOURCE[0]}")" \
        "设置 llama.cpp 运行时环境变量，优化双 GPU NVLink 性能。" \
        "  -s, --status    显示当前环境变量状态（不设置）
  -h, --help      显示此帮助信息
      --version   显示版本信息" \
        "  source run_env.sh              # 加载环境变量
  source run_env.sh --status     # 查看当前状态
  source run_env.sh --help       # 显示帮助"
    _show_env_vars
}

_show_env_vars() {
    local var
    echo ""
    echo "环境变量:"
    # Use sort for deterministic output order
    for var in $(_sorted_env_var_names); do
        local info="${_LLAMA_RUN_ENV_VARS[$var]}"
        local desc="${info#*|}"
        echo "  ${var}"
        echo "    作用: ${desc}"
        if [[ -n "${!var:-}" ]]; then
            echo "    当前值: ${!var}"
        else
            echo "    当前值: (未设置)"
        fi
        echo ""
    done
}

_sorted_env_var_names() {
    echo "${!_LLAMA_RUN_ENV_VARS[@]}" | tr ' ' '
' | sort
}

# --- 主函数 --------------------------------------------------
main() {
    local show_status=0
    while (($# > 0)); do
        case "$1" in
            -s|--status)
                show_status=1
                shift
                ;;
            -h|--help)
                _show_help
                return 0
                ;;
            --version)
                llama_show_version
                return 0
                ;;
            *)
                llama_err "未知选项: $1"
                _show_help
                return 1
                ;;
        esac
    done

    # --- 状态模式 ------------------------------------------------
    if [[ "$show_status" -eq 1 ]]; then
        llama_step "当前 llama.cpp 环境变量状态"
        _show_env_vars

        llama_info "GPU 信息:"
        if command -v nvidia-smi &>/dev/null; then
            nvidia-smi --query-gpu=name,memory.total,memory.free,temperature.gpu,utilization.gpu \
                       --format=csv,noheader 2>/dev/null | while IFS= read -r line; do
                llama_detail "$line"
            done
        else
            llama_warn "未找到 nvidia-smi"
        fi
        return 0
    fi

    # --- 设置环境变量 --------------------------------------------
    llama_step "设置 llama.cpp 运行环境"

    # Activate conda environment (if available)
    llama_activate_conda
    # Detect GPU
    local gpu_count
    gpu_count=$(llama_get_gpu_count)

    if [[ "$gpu_count" -lt 2 ]]; then
        llama_warn "检测到 ${gpu_count} 块 GPU，P2P 优化效果有限"
    else
        llama_ok "检测到 ${gpu_count} 块 GPU"
    fi

    # Set each environment variable
    local var info value desc
    for var in $(_sorted_env_var_names); do
        info="${_LLAMA_RUN_ENV_VARS[$var]}"
        value="${info%|*}"
        desc="${info#*|}"

        # Check if already set (allow user to pre-override)
        if [[ -n "${!var:-}" ]]; then
            llama_warn "${var} 已设置为 ${!var}，保留用户值"
        else
            export "$var=$value"
            llama_ok "${var}=${value}"
            llama_detail "${desc}"
        fi
    done

    # --- 重要提示 ------------------------------------------------
    cat <<EOF

${YELLOW}⚠️  重要提示:${NC}
  本配置针对双 RTX 2080 Ti (NVLink) 离散 GPU 优化。

${YELLOW}未启用的变量:${NC}
  GGML_CUDA_ENABLE_UNIFIED_MEMORY - 统一内存对离散 GPU 性能有害，
  仅在集成 GPU 或 VRAM 不足导致 OOM 时使用。

${YELLOW}可选的额外优化:${NC}
  export GGML_CUDA_GRAPH_OPT=1     # 启用 CUDA 图优化（单 GPU 场景受益）
  export GGML_CUDA_NO_PINNED=1     # 禁用固定内存（低显存场景）

EOF

    llama_ok "llama.cpp 运行环境已加载"
}

main "$@"
_main_rc=$?

llama_restore_colors

llama_return_or_exit "$_main_rc"
