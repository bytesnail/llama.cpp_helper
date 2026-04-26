#!/bin/bash
# ============================================================
# llama.cpp 运行时性能优化环境变量
# 硬件：2× RTX 2080 Ti (NVLink) - 离散 GPU，不建议启用统一内存
# 使用：source /mnt/hdd/projects/llama.cpp_helper/run_env.sh
# ============================================================

# 本脚本设计为被 source 执行，不启用 set -euo pipefail
# 因为 source 时退出会影响当前 shell

# 加载 common.sh
_SCRIPT_PATH="${BASH_SOURCE[0]:-$0}"
if [[ -z "$_SCRIPT_PATH" ]]; then
    echo "[ERROR] 无法确定脚本路径，请从脚本所在目录运行" >&2
    return 1 2>/dev/null || exit 1
fi
SCRIPT_DIR="$(cd "$(dirname "$_SCRIPT_PATH")" > /dev/null && pwd)"
if [[ ! -f "${SCRIPT_DIR}/common.sh" ]]; then
    echo "[ERROR] 未找到 common.sh: ${SCRIPT_DIR}/common.sh" >&2
    return 1 2>/dev/null || exit 1
fi
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/common.sh"
unset SCRIPT_DIR _SCRIPT_PATH

# --- 环境变量定义 --------------------------------------------
# 使用关联数组定义所有要设置的环境变量
# 格式: [变量名]="值|描述"
declare -A LLAMA_ENV_VARS=(
    ["GGML_CUDA_P2P"]="1|启用 GPU 间 P2P 直传（NVLink）"
    ["CUDA_SCALE_LAUNCH_QUEUES"]="4x|增大 CUDA 命令缓冲区（多 GPU 并行受益）"
)

# --- 帮助信息 ------------------------------------------------
show_help() {
    cat <<EOF
用法: source $(basename "${BASH_SOURCE[0]}") [选项]

描述:
  设置 llama.cpp 运行时环境变量，优化双 GPU NVLink 性能。

选项:
  -s, --status    显示当前环境变量状态（不设置）
  -h, --help      显示此帮助信息

示例:
  source run_env.sh              # 加载环境变量
  source run_env.sh --status     # 查看当前状态
  source run_env.sh --help       # 显示帮助

已设置的环境变量:
EOF
    show_env_vars
}

show_env_vars() {
    local var
    for var in "${!LLAMA_ENV_VARS[@]}"; do
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
                return 0 2>/dev/null || exit 0
                ;;
            *)
                llama_err "未知选项: $1"
                show_help
                return 1 2>/dev/null || exit 1
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
        return 0 2>/dev/null || exit 0
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
    for var in "${!LLAMA_ENV_VARS[@]}"; do
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

# 清理 common.sh 留下的颜色变量，防止污染父 shell
unset RED GREEN YELLOW CYAN BLUE BOLD NC 2>/dev/null || true
