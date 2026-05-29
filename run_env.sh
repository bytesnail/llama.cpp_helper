#!/bin/bash
# ============================================================
# run_env.sh — 运行时性能优化环境变量
# 硬件：2× RTX 2080 Ti (NVLink) — 离散 GPU，不建议启用统一内存
# Usage: source /path/to/llama.cpp_helper/run_env.sh
# ============================================================

# 防止直接执行
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "[WARN] 本脚本应当使用 source 执行，而非直接运行" >&2
    echo "用法: source ${BASH_SOURCE[0]} [选项]" >&2
    echo >&2
    echo "直接执行不会在当前 shell 中设置环境变量。" >&2
    exit 1
fi

# 防止重复 source
_LLAMA_RUN_ENV_SOURCED=${_LLAMA_RUN_ENV_SOURCED:-0}
if [[ "$_LLAMA_RUN_ENV_SOURCED" -eq 1 ]]; then
    return 0 2>/dev/null || true
fi
_LLAMA_RUN_ENV_SOURCED=1

# 本脚本设计为 source 使用；未启用 set -euo pipefail
# 因为 source 时退出会杀死父 shell

# 加载 common.sh
# 保存颜色变量 — 必须在 source common.sh 之前完成（common.sh 会覆盖它们）
# 使用内联代码而非 llama_save_colors()（common.sh 的 llama_save_colors() 函数），因为 common.sh 尚未加载。
# 两份副本必须保持同步：修改此处的变量列表时，需同步修改 common.sh 中的
# llama_save_colors() 函数。
for cvar in RED GREEN YELLOW CYAN BLUE BOLD NC; do
    printf -v "_LLAMA_SAVED_${cvar}" '%s' "${!cvar-}"
done
unset cvar

# 引导：查找并 source common.sh（共享辅助函数尚不可用）
boot_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null && pwd)"
if [[ ! -f "${boot_dir}/common.sh" ]]; then
    # shellcheck disable=SC2317
    echo "[ERROR] 未找到 common.sh: ${boot_dir}/common.sh" >&2
    unset boot_dir
    return 1 2>/dev/null || exit 1
fi
# shellcheck source=/dev/null
source "${boot_dir}/common.sh"
unset boot_dir

# 共享辅助函数已可用 — 正确设置 SCRIPT_DIR
llama_init_script_dir

# source config.sh 获取版本信息（供 llama_show_version 使用）
if [[ -f "${SCRIPT_DIR}/config.sh" ]]; then
    # shellcheck source=/dev/null
    source "${SCRIPT_DIR}/config.sh"
fi

# --- 环境变量定义 --------------------------------------------
# 使用关联数组定义所有要设置的环境变量
# 格式：[变量名]="值|描述"
declare -A _LLAMA_RUN_ENV_VARS=(
    ["GGML_CUDA_P2P"]="1|启用 GPU 间 P2P 直传（NVLink）"
    ["CUDA_SCALE_LAUNCH_QUEUES"]="4x|增大 CUDA 命令缓冲区（多 GPU 并行受益）"
)

# --- 帮助信息 ------------------------------------------------
# Usage: _show_help
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

# Usage: _show_env_vars
_show_env_vars() {
    local var
    echo
    echo "环境变量:"
    # 使用 sort 确保输出顺序确定性
    while IFS= read -r var; do
        local info="${_LLAMA_RUN_ENV_VARS[$var]}"
        local desc="${info#*|}"
        echo "  ${var}"
        echo "    作用: ${desc}"
        if [[ -n "${!var:-}" ]]; then
            echo "    当前值: ${!var}"
        else
            echo "    当前值: (未设置)"
        fi
        echo
    done < <(_sorted_env_var_names)
}

# Usage: _sorted_env_var_names
_sorted_env_var_names() {
    printf '%s\n' "${!_LLAMA_RUN_ENV_VARS[@]}" | sort
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

    # 激活 conda 环境（如果可用）
    llama_activate_conda
    # 检测 GPU
    local gpu_count
    gpu_count=$(llama_get_gpu_count)

    if [[ "$gpu_count" -lt 2 ]]; then
        llama_warn "检测到 ${gpu_count} 块 GPU，P2P 优化效果有限"
    else
        llama_ok "检测到 ${gpu_count} 块 GPU"
    fi

    # 逐个设置环境变量
    local var info value desc
    while IFS= read -r var; do
        info="${_LLAMA_RUN_ENV_VARS[$var]}"
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
    done < <(_sorted_env_var_names)

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
