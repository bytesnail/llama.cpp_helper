#!/bin/bash
# ============================================================
# llama.cpp 运行时性能优化环境变量
# 硬件：2× RTX 2080 Ti (NVLink) - 离散 GPU，不建议启用统一内存
# 使用：source /mnt/hdd/projects/llama.cpp_helper/run_env.sh
# ============================================================

# 防止直接执行
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "[WARN] 本脚本应当使用 source 执行，而非直接运行" >&2
    echo "用法: source ${BASH_SOURCE[0]} [选项]" >&2
    echo "" >&2
    echo "直接执行不会在当前 shell 中设置环境变量。" >&2
    exit 1
fi

# 本脚本设计为被 source 执行，不启用 set -euo pipefail
# 因为 source 时退出会影响当前 shell

# 加载 common.sh
# Save existing color variables to restore after execution
# (run_env.sh is designed to be sourced; we must not pollute parent shell)
for _v in RED GREEN YELLOW CYAN BLUE BOLD NC; do
    printf -v "_LLAMA_SAVED_${_v}" '%s' "${!_v-}"
done
unset _v


# Bootstrap: find and source common.sh (shared helpers not yet available)
_BOOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" > /dev/null && pwd)"
if [[ ! -f "${_BOOT_DIR}/common.sh" ]]; then
    # shellcheck disable=SC2317
    echo "[ERROR] 未找到 common.sh: ${_BOOT_DIR}/common.sh" >&2
    return 1 2>/dev/null || exit 1
fi
# shellcheck source=/dev/null
source "${_BOOT_DIR}/common.sh"
unset _BOOT_DIR

# Now shared helpers are available — properly set SCRIPT_DIR
llama_init_script_dir

# Source config.sh for version info (used by llama_show_version)
if [[ -f "${SCRIPT_DIR}/config.sh" ]]; then
    # shellcheck source=/dev/null
    source "${SCRIPT_DIR}/config.sh"
fi

# --- 环境变量定义 --------------------------------------------
# 使用关联数组定义所有要设置的环境变量
# 格式: [变量名]="值|描述"
declare -A LLAMA_ENV_VARS=(
    ["GGML_CUDA_P2P"]="1|启用 GPU 间 P2P 直传（NVLink）"
    ["CUDA_SCALE_LAUNCH_QUEUES"]="4x|增大 CUDA 命令缓冲区（多 GPU 并行受益）"
)

# --- 帮助信息 ------------------------------------------------
show_help() {
    llama_show_help \
        "source $(basename "${BASH_SOURCE[0]}")" \
        "设置 llama.cpp 运行时环境变量，优化双 GPU NVLink 性能。" \
        "  -s, --status    显示当前环境变量状态（不设置）
  -h, --help      显示此帮助信息
      --version   显示版本信息" \
        "  source run_env.sh              # 加载环境变量
  source run_env.sh --status     # 查看当前状态
  source run_env.sh --help       # 显示帮助"
    show_env_vars
}

show_env_vars() {
    local var
    # 使用排序确保输出顺序确定性
    for var in $(echo "${!LLAMA_ENV_VARS[@]}" | tr ' ' '\n' | sort); do
        local info="${LLAMA_ENV_VARS[$var]}"
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

# --- 主函数 --------------------------------------------------
main() {
    local SHOW_STATUS=0
    if (($# > 0)); then
        case "$1" in
            -s|--status)
                SHOW_STATUS=1
                ;;
            -h|--help)
                show_help
                return 0
                ;;
            --version)
                llama_show_version
                return 0
                ;;
            *)
                llama_err "未知选项: $1"
                show_help
                return 1
                ;;
        esac
    fi

    # --- 状态模式 ------------------------------------------------
    if [[ "$SHOW_STATUS" -eq 1 ]]; then
        llama_step "当前 llama.cpp 环境变量状态"
        show_env_vars

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

    # 检测 GPU
    local GPU_COUNT=0
    if command -v nvidia-smi &>/dev/null; then
        GPU_COUNT=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | wc -l)
    fi

    if [[ "$GPU_COUNT" -lt 2 ]]; then
        llama_warn "检测到 ${GPU_COUNT} 块 GPU，P2P 优化效果有限"
    else
        llama_ok "检测到 ${GPU_COUNT} 块 GPU"
    fi

    # 设置每个环境变量
    local var info value desc
    for var in $(echo "${!LLAMA_ENV_VARS[@]}" | tr ' ' '\n' | sort); do
        info="${LLAMA_ENV_VARS[$var]}"
        value="${info%|*}"
        desc="${info#*|}"

        # 检查是否已设置（允许用户预先覆盖）
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

# 清理 common.sh 留下的颜色变量，防止污染父 shell
# Restore color variables to their pre-existing values
for _v in RED GREEN YELLOW CYAN BLUE BOLD NC; do
    _saved_var="_LLAMA_SAVED_${_v}"
    if [[ -n "${!_saved_var+isset}" ]]; then
        printf -v "$_v" '%s' "${!_saved_var}"
    else
        unset "$_v" 2>/dev/null || :
    fi
    unset "_LLAMA_SAVED_${_v}"
done
unset _v _saved_var

llama_return_or_exit ${_main_rc:-0}
