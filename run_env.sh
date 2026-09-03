#!/bin/bash
# ============================================================
# run_env.sh — 运行时性能优化环境变量
# 硬件：2× RTX 2080 Ti (NVLink) — 离散 GPU，不建议启用统一内存
# Usage: source /path/to/llama.cpp_helper/run_env.sh
# 注意：在带位置参数的脚本/函数内 source 时，不传参会继承调用者的位置
# 参数（bash source 语义）——请先 set -- 清空或显式传参（如 source
# run_env.sh --status），否则会被误认为本脚本的选项而报"未知选项"。
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

# 引导：查找并 source common.sh（共享辅助函数尚不可用）
# 颜色变量由 common.sh 统一管理（_LLAMA_COLOR_VARS 为单一来源）；
# 退出时由 llama_restore_colors 清理，不污染父 shell。
_llama_boot_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null && pwd)"
if [[ ! -f "${_llama_boot_dir}/common.sh" ]]; then
    # shellcheck disable=SC2317
    echo "[ERROR] 未找到 common.sh: ${_llama_boot_dir}/common.sh" >&2
    unset _llama_boot_dir
    return 1 2>/dev/null || exit 1
fi
# shellcheck source=/dev/null
source "${_llama_boot_dir}/common.sh"

# 版本号不在 source 时急切提取：只有 --version 分支消费 LLAMA_HELPER_VERSION，
# 提取逻辑移入 _llama_run_env_main 的该分支（见下）——日常 source 热路径不再为罕见分支
# 支付子 shell + config.sh 解析开销，值也不残留父 shell。
unset _llama_boot_dir

# --- 环境变量定义 --------------------------------------------
# 使用关联数组定义所有要设置的环境变量
# 格式：[变量名]="值|语义|描述"；语义 ∈ presence（llama.cpp 仅检测变量
# 是否存在，关闭须 unset）| value（读取变量值）
declare -A _LLAMA_RUN_ENV_VARS=(
    ["GGML_CUDA_P2P"]="1|presence|启用 GPU 间 P2P 直传（NVLink）——存在性语义：llama.cpp 仅检测变量是否存在，置 0 不关闭，关闭须 unset"
)
# 注：CUDA_SCALE_LAUNCH_QUEUES 已移除——llama.cpp v0.3.0 源码中不存在该变量
# （全仓 grep 无 getenv 消费者），导出后无任何效果

# Usage: _llama_run_env_var_value <name> / _llama_run_env_var_sem <name> / _llama_run_env_var_desc <name>
# "值|语义|描述" 格式的统一解析点（_llama_run_env_show_vars 与 _llama_run_env_main 设置循环共用）
_llama_run_env_var_value() { printf '%s' "${_LLAMA_RUN_ENV_VARS[$1]%%|*}"; }
_llama_run_env_var_sem()   { local _rest="${_LLAMA_RUN_ENV_VARS[$1]#*|}"; printf '%s' "${_rest%%|*}"; }
_llama_run_env_var_desc()  { printf '%s' "${_LLAMA_RUN_ENV_VARS[$1]#*|*|}"; }

# --- 帮助信息 ------------------------------------------------
# Usage: _llama_run_env_show_help
_llama_run_env_show_help() {
    llama_show_help \
        "source $(basename "${BASH_SOURCE[0]}")" \
        "设置 llama.cpp 运行时环境变量，优化双 GPU NVLink 性能。" \
        "  -s, --status    显示当前环境变量状态（不设置）
  -h, --help      显示此帮助信息
      --version   显示版本信息" \
        "  source run_env.sh              # 加载环境变量
  source run_env.sh --status     # 查看当前状态
  source run_env.sh --help       # 显示帮助"
    _llama_run_env_show_vars
}

# Usage: _llama_run_env_show_vars
_llama_run_env_show_vars() {
    local var
    echo
    echo "环境变量:"
    # 使用 sort 确保输出顺序确定性
    while IFS= read -r var; do
        local desc
        desc=$(_llama_run_env_var_desc "$var")
        echo "  ${var}"
        echo "    作用: ${desc}"
        if [[ -n "${!var:-}" ]]; then
            echo "    当前值: ${!var}"
        else
            echo "    当前值: (未设置)"
        fi
        echo
    done < <(_llama_run_env_sorted_var_names)
}

# Usage: _llama_run_env_sorted_var_names
_llama_run_env_sorted_var_names() {
    printf '%s\n' "${!_LLAMA_RUN_ENV_VARS[@]}" | sort
}

# --- 主函数 --------------------------------------------------
_llama_run_env_main() {
    local show_status=0
    while (($# > 0)); do
        case "$1" in
            -s|--status)
                show_status=1
                shift
                ;;
            -h|--help)
                _llama_run_env_show_help
                return 0
                ;;
            --version)
                # 版本号惰性提取（仅此分支消费）：经子 shell 读 config.sh——
                # 直接 source 会把其 readonly 变量/数组（REPO/LOCK_FILE 等约
                # 20 个）灌入父 shell（readonly 无法 unset，已实证）；local
                # 声明经动态作用域供 llama_show_version 读取，_llama_run_env_main 返回后即
                # 销毁，不残留父 shell
                local LLAMA_HELPER_VERSION
                LLAMA_HELPER_VERSION=$(bash -c 'source "$1/config.sh" 2>/dev/null; printf %s "${LLAMA_HELPER_VERSION:-unknown}"' _ "$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null && pwd)")
                llama_show_version
                return 0
                ;;
            *)
                llama_err "未知选项: $1"
                _llama_run_env_show_help
                return 1
                ;;
        esac
    done

    # --- 状态模式 ------------------------------------------------
    if [[ "$show_status" -eq 1 ]]; then
        llama_print_hardware_summary
        llama_step "环境变量状态"
        _llama_run_env_show_vars
        llama_info "GPU 运行时状态："
        if command -v nvidia-smi &>/dev/null; then
            local line
            while IFS= read -r line; do
                llama_detail "$line"
            done < <(nvidia-smi --query-gpu=index,memory.used,memory.free,utilization.gpu,temperature.gpu,power.draw \
                                 --format=csv,noheader 2>/dev/null)
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
    # || true：llama_get_gpu_count 在无 nvidia-smi 时返回 1；run_env.sh 虽未启用 set -e，
    # 但若父 shell 启用了 set -e，未屏蔽的失败赋值会杀死父 shell。
    gpu_count=$(llama_get_gpu_count || true)

    if [[ "$gpu_count" -lt 2 ]]; then
        llama_warn "检测到 ${gpu_count} 块 GPU，P2P 优化效果有限"
    else
        llama_ok "检测到 ${gpu_count} 块 GPU"
    fi

    # 逐个设置环境变量
    local var value desc
    while IFS= read -r var; do
        value=$(_llama_run_env_var_value "$var")
        desc=$(_llama_run_env_var_desc "$var")

        # 检查是否已设置（允许用户预先覆盖）
        if [[ -n "${!var:-}" ]]; then
            llama_warn "${var} 已设置为 ${!var}，保留用户值"
            # 存在性语义变量：llama.cpp 只检测变量是否存在——=0/=false
            # 不会关闭该特性（上游 getenv(...) != nullptr，已核实）
            if [[ "$(_llama_run_env_var_sem "$var")" == "presence" ]]; then
                case "${!var}" in
                    0|false|FALSE|no|NO)
                        llama_warn "${var}=${!var} 不会关闭该特性（llama.cpp 仅检测变量存在）；如需关闭请: unset ${var}"
                        ;;
                esac
            fi
        else
            export "$var=$value"
            llama_ok "${var}=${value}"
            llama_detail "${desc}"
        fi
    done < <(_llama_run_env_sorted_var_names)

    # --- 补充说明 ------------------------------------------------
    cat <<EOF

${YELLOW}⚠️  注意:${NC}
  • 针对 2× RTX 2080 Ti (NVLink) 离散 GPU 优化
  • 运行无需激活 conda（RPATH 内嵌 CUDA 库绝对路径）；本脚本核心目的是设置 GGML_CUDA_P2P
  • GGML_CUDA_ENABLE_UNIFIED_MEMORY 未启用 — 对离散 GPU 有害（x86 无缓存一致性，页迁移慢速），
    仅当模型+KV 超出双卡 44GB 显存 OOM 时临时开启应急
  • 应急开关 GGML_CUDA_NO_PINNED=1：主机锁页内存受限/cudaMallocHost 分配失败时规避
    （代价：CPU↔GPU 传输带宽下降），常规无需设置
EOF

    llama_ok "llama.cpp 运行环境已加载"
}

# || 捕获：本脚本被 source 时在父 shell 中执行；父 shell 启用 set -e 时，
# _llama_run_env_main 返回非零（未知选项等错误路径）作为简单命令会杀死父 shell——
# 与"source 使用不伤害父 shell"的设计承诺相悖（已实证）
_llama_run_env_rc=0
_llama_run_env_main "$@" || _llama_run_env_rc=$?

llama_restore_colors

# 清理脚本级定义，不污染父 shell 命名空间（bash 函数无法局部化）。
# 本脚本的函数一律用 _llama_run_env_ 前缀：原名 main/_show_help 等是父脚本
# 常见命名，source 时直接定义会覆写父 shell 的同名函数、末尾 unset 再把
# 原件一并销毁（已实证：父脚本的 main() source 一次即丢失）——前缀使命名
# 碰撞在结构上不可能，清理本身因此安全
unset -f _llama_run_env_main _llama_run_env_show_help _llama_run_env_show_vars _llama_run_env_sorted_var_names \
    _llama_run_env_var_value _llama_run_env_var_sem _llama_run_env_var_desc
unset _LLAMA_RUN_ENV_VARS

# _llama_run_env_rc 也要清除（实测曾残留父 shell）——但 llama_return_or_exit 仍需它，
# 经参数传入收尾函数后在函数内 unset（函数内 unset 无同名 local 时作用于
# 全局）；BASH_SOURCE 判断不受影响：llama_return_or_exit 的调用者仍是
# 本文件（source 上下文），与原顶层直调语义一致
_llama_run_env_finalize() {
    local _rc="$1"
    unset _llama_run_env_rc
    unset -f _llama_run_env_finalize
    llama_return_or_exit "$_rc"
}
# || true：source 上下文的非零 return 同样是会杀死 set -e 父 shell 的简单
# 命令（直接执行已被文件头部拦截，此处必为 source 上下文）——错误只经
# llama_err 与帮助文本传达，退出码不外传（实测：此前 --bogus 在 set -e
# 父 shell 中照样致命，与上方 || 捕获的承诺相悖）
_llama_run_env_finalize "$_llama_run_env_rc" || true
