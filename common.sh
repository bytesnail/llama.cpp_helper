#!/bin/bash
# ============================================================
# common.sh — 共享工具函数库
# 所有辅助脚本的共享工具
# 要求：Bash >= 4.2（变量测试 [[ -v ]]）
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
# 颜色变量名清单（单一来源）：驱动 llama_save_colors / llama_restore_colors，
# 消除此前 common.sh 与 run_env.sh 各维护一份副本的重复。
readonly _LLAMA_COLOR_VARS=(RED GREEN YELLOW CYAN BLUE BOLD NC)

# Usage: llama_save_colors
# 保存当前颜色变量值（_LLAMA_COLOR_VARS 列表），供 llama_restore_colors 恢复。
llama_save_colors() {
    local cvar
    for cvar in "${_LLAMA_COLOR_VARS[@]}"; do
        printf -v "_LLAMA_SAVED_${cvar}" '%s' "${!cvar-}"
    done
}

# Usage: llama_restore_colors
# 恢复 llama_save_colors 保存的颜色变量。清理临时变量。
llama_restore_colors() {
    local cvar saved_var
    for cvar in "${_LLAMA_COLOR_VARS[@]}"; do
        saved_var="_LLAMA_SAVED_${cvar}"
        if [[ -n "${!saved_var+isset}" ]]; then
            printf -v "$cvar" '%s' "${!saved_var}"
        else
            unset "$cvar" 2>/dev/null || true
        fi
        unset "$saved_var"
    done
}

# source 时自动保存调用者已有的同名变量（防重复 source 守卫保证只执行一次），
# 使 run_env.sh 退出时的 llama_restore_colors 能真正恢复父 shell 原值，
# 而不是无条件 unset 销毁用户预设（unset 与空串不做区分，恢复为空串）。
llama_save_colors

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
# 前缀用 %b 展开颜色转义，消息体用 %s 字面输出——防止外部文本（编译器/conda
# 报错等）中的反斜杠序列被 %b 改写，或向终端注入 ANSI 控制序列。
llama_info()  { printf '%b%s\n' "${CYAN}[INFO]${NC} " "$*"; }
llama_ok()    { printf '%b%s\n' "${GREEN}[OK]${NC} " "$*"; }
llama_warn()  { printf '%b%s\n' "${YELLOW}[WARN]${NC} " "$*"; }
llama_err()   { printf '%b%s\n' "${RED}[ERROR]${NC} " "$*" >&2; }
llama_step()  { printf '%b=== %s ===%b\n' "\n${BOLD}" "$*" "${NC}"; }
llama_detail() { printf '%b%s\n' "${BLUE}  →${NC} " "$*"; }

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
    ncpu=4 # 回退 4：未知平台的保守默认值
    echo "$ncpu"
}

# --- GPU 检测 ------------------------------------------------
# Usage: llama_get_gpu_count
# 返回通过 nvidia-smi 检测到的 NVIDIA GPU 数量。
# 输出：stdout 输出 GPU 数量（无则为 0）；退出码：nvidia-smi 存在返回 0，未安装返回 1。
llama_get_gpu_count() {
    if command -v nvidia-smi &>/dev/null; then
        local count
        # || true：nvidia-smi 存在但运行失败（驱动错误等）时，pipefail 会使管线
        # 返回非零，在 set -e 下终止整个脚本；此处应降级为 0 GPU 而非中止构建。
        count=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | wc -l || true)
        echo "$count"
        return 0
    fi
    echo "0"
    return 1
}

# --- 硬件信息采集 --------------------------------------------
# 集中采集对 llama.cpp 构建与运行有意义的硬件信息。
# 设计原则：无 root 依赖；外部工具缺失时优雅降级（输出空串/0/未知）；
#           仅读取系统状态，绝不修改。复用上文 llama_get_cpu_count /
#           llama_get_gpu_count，此处补充结构化的拓扑/指令集/互联信息。

# Usage: _llama_join <separator> <element>...
# 用分隔符连接各元素，输出到 stdout；无元素时输出空串。
_llama_join() {
    local sep="$1"; shift
    local out="" e
    for e in "$@"; do
        out="${out:+${out}${sep}}${e}"
    done
    printf '%s' "$out"
}

# Usage: _llama_lscpu_field <field_regex>
# 解析 lscpu 输出中首个匹配字段（$1 为作用于首列的正则）的值，去前导空格。
# lscpu 不可用时输出空串。
# 同进程内缓存 lscpu 输出（硬件汇总会查询多个字段），避免每次 fork lscpu；
# LC_ALL=C 固定英文输出，防止本地化字段名（如中文 "型号:"）导致匹配失败。
_llama_lscpu_field() {
    # || true：lscpu 不可用时（缺失/损坏）赋值在 pipefail 下返回非零，
    # 会中止 build.sh（经 llama_hw_cpu_* → llama_print_hardware_summary 调用链）。
    # 加 || true 后缓存为空串，调用者得到空串，从而触发 /proc/cpuinfo 回退或 0 回退。
    if [[ -z "${_LLAMA_LSCPU_CACHE+x}" ]]; then
        _LLAMA_LSCPU_CACHE=$(LC_ALL=C lscpu 2>/dev/null || true)
    fi
    awk -F: -v re="$1" '
        $1 ~ re { sub(/^[[:space:]]+/, "", $2); print $2; exit }
    ' <<< "$_LLAMA_LSCPU_CACHE"
}

# Usage: llama_hw_cpu_model
# 输出 CPU 型号字符串；无法获取时输出空串。
llama_hw_cpu_model() {
    local model
    model=$(_llama_lscpu_field "Model name")
    if [[ -z "$model" ]]; then
        # || true：/proc/cpuinfo 不可读时（容器/沙箱环境）awk 返回非零，
        # pipefail+set -e 下会中止；加 || true 后 model 为空串，符合契约。
        model=$(awk -F: '/^model name/ { sub(/^ +/, "", $2); print $2; exit }' /proc/cpuinfo 2>/dev/null || true)
    fi
    printf '%s' "$model"
}

# Usage: llama_hw_cpu_sockets
# 输出物理 CPU（socket）数量；无法获取时输出 0。
llama_hw_cpu_sockets() {
    local n
    n=$(_llama_lscpu_field "^Socket")
    [[ "$n" =~ ^[0-9]+$ ]] && printf '%s' "$n" || printf 0
}

# Usage: llama_hw_cpu_cores_physical
# 输出物理核总数（sockets × 每路核数）；无法获取时输出 0。
llama_hw_cpu_cores_physical() {
    local sockets per_socket
    sockets=$(llama_hw_cpu_sockets)
    per_socket=$(_llama_lscpu_field "^Core")
    if [[ "$sockets" =~ ^[0-9]+$ && "$per_socket" =~ ^[0-9]+$ ]]; then
        printf '%s' $((sockets * per_socket))
    else
        printf 0
    fi
}

# Usage: llama_hw_cpu_cores_logical
# 输出逻辑线程数（含超线程）。复用 llama_get_cpu_count，缺失时回退保守值。
llama_hw_cpu_cores_logical() {
    llama_get_cpu_count
}

# llama.cpp CPU 后端相关的指令集映射（/proc/cpuinfo flag 名 → 显示名）。
# 与 ggml/src/CMakeLists.txt 的 CPU 后端变体对应：haswell 起 CPU 路径有意义。
# shellcheck disable=SC2034  # 数组由 llama_hw_cpu_flags 通过下标读取
readonly _LLAMA_HW_CPU_FLAGS_BASIC=(
    "sse4_2:SSE4.2" "avx:AVX" "avx2:AVX2" "fma:FMA" "f16c:F16C" "bmi2:BMI2" "avx_vnni:AVX-VNNI"
)
# shellcheck disable=SC2034
# flag 名须与 /proc/cpuinfo 严格一致（Linux 内核 cpufeatures.h）：
# vnni/bf16/fp16 带下划线（avx512_vnni 等），vbmi 无下划线——拼错会永不命中
readonly _LLAMA_HW_CPU_FLAGS_AVX512=(
    "avx512f:F" "avx512cd:CD" "avx512bw:BW" "avx512dq:DQ" "avx512vl:VL"
    "avx512vbmi:VBMI" "avx512_vnni:VNNI" "avx512_bf16:BF16" "avx512_fp16:FP16"
)

# Usage: llama_hw_cpu_flags
# 输出 llama.cpp 相关的 CPU 加速指令集（逗号分隔）；无 AVX-512 时不含其子集。
# AVX-512 各子集合并显示为 AVX-512(F,CD,BW,...)。无 /proc/cpuinfo 时输出空串。
llama_hw_cpu_flags() {
    local flags_line
    flags_line=$(awk -F: '/^flags/ { sub(/^ +/, "", $2); print $2; exit }' /proc/cpuinfo 2>/dev/null || true)
    [[ -z "$flags_line" ]] && return 0

    local padded=" $flags_line "
    local result=() pair flag name
    for pair in "${_LLAMA_HW_CPU_FLAGS_BASIC[@]}"; do
        flag="${pair%%:*}"; name="${pair##*:}"
        [[ "$padded" == *" $flag "* ]] && result+=("$name")
    done

    local avx512=()
    for pair in "${_LLAMA_HW_CPU_FLAGS_AVX512[@]}"; do
        flag="${pair%%:*}"; name="${pair##*:}"
        [[ "$padded" == *" $flag "* ]] && avx512+=("$name")
    done
    if ((${#avx512[@]} > 0)); then
        result+=("AVX-512($(_llama_join ',' "${avx512[@]}"))")
    fi

    # ${result[@]+...}：空数组在 Bash ≤4.3 + set -u 下展开 "${result[@]}"
    # 会报 unbound variable（4.4 才修复），与 build.sh 的 cmake_extra_args 同款防护。
    _llama_join ', ' ${result[@]+"${result[@]}"}
}

# Usage: llama_hw_mem_total_bytes
# 输出内存总量（字节）；无法获取时输出 0。
llama_hw_mem_total_bytes() {
    local kb
    kb=$(awk '/^MemTotal:/ { print $2; exit }' /proc/meminfo 2>/dev/null || true)
    [[ "$kb" =~ ^[0-9]+$ ]] && printf '%s' $((kb * 1024)) || printf 0
}

# Usage: llama_hw_mem_total_human
# 输出内存总量的人类可读格式（复用 llama_human_size）；未知时输出"未知"。
llama_hw_mem_total_human() {
    local bytes
    bytes=$(llama_hw_mem_total_bytes)
    if ((bytes > 0)); then
        llama_human_size "$bytes"
    else
        printf '未知'
    fi
}

# Usage: llama_print_hardware_summary
# 打印完整硬件信息汇总（CPU 拓扑/指令集、内存、GPU、NVLink 互联）。
# 外部工具（lscpu/nvidia-smi）缺失时优雅降级，仅打印可获取的部分。
# 供 build.sh 前置检查与 run_env.sh --status 调用。
llama_print_hardware_summary() {
    llama_step "硬件信息"

    # --- CPU ---
    local cpu_model sockets cores_phy cores_log flags
    cpu_model=$(llama_hw_cpu_model)
    sockets=$(llama_hw_cpu_sockets)
    cores_phy=$(llama_hw_cpu_cores_physical)
    cores_log=$(llama_hw_cpu_cores_logical)
    flags=$(llama_hw_cpu_flags)

    [[ -n "$cpu_model" ]] && llama_detail "CPU:    ${cpu_model}"
    if ((sockets > 0 && cores_phy > 0)); then
        local per_socket=$((cores_phy / sockets))
        llama_detail "拓扑:   ${sockets} 路 × ${per_socket} 物理核（共 ${cores_phy} 物理核 / ${cores_log} 线程）"
    fi
    if [[ -n "$flags" ]]; then
        llama_detail "指令集: ${flags}"
        [[ "$flags" == *"AVX-512"* ]] || \
            llama_detail "        （无 AVX-512 — GGML_NATIVE 将生成 haswell 级 CPU 后端）"
    fi

    # --- 内存 ---
    llama_detail "内存:   $(llama_hw_mem_total_human)"

    # --- GPU + NVLink 互联 ---
    # 单次 nvidia-smi 查询同时得到数量与详情：nvidia-smi 每次启动需 50-150ms
    # （驱动初始化），先计数再查详情的两段式会重复付出该开销。
    # command -v 只验证二进制存在；执行失败（驱动/NVML 不匹配）必须区分于
    # "无 GPU"——进程替换的失败不可见，曾把驱动故障谎报为"未检测到 NVIDIA GPU"
    local gpu_lines=()
    if command -v nvidia-smi &>/dev/null; then
        local smi_out smi_rc=0
        smi_out=$(nvidia-smi --query-gpu=index,name,compute_cap,memory.total \
                            --format=csv,noheader,nounits 2>/dev/null) || smi_rc=$?
        if [[ "$smi_rc" -ne 0 ]]; then
            llama_warn "nvidia-smi 存在但执行失败（退出码: ${smi_rc}）——驱动异常？GPU 信息不可用"
        else
            # 参数扩展替代 sed（csv 的 ", " → 字段分隔符 "|"）
            mapfile -t gpu_lines <<< "${smi_out//, /|}"
        fi
    fi
    local gpu_count=${#gpu_lines[@]}
    if ((gpu_count > 0)); then
        llama_detail "GPU（${gpu_count} 块）:"
        local idx name cc vram vram_human gpu_line
        for gpu_line in "${gpu_lines[@]}"; do
            IFS='|' read -r idx name cc vram <<< "$gpu_line"
            vram_human="?"
            [[ "$vram" =~ ^[0-9]+$ ]] && vram_human=$(llama_human_size $((vram * 1024 * 1024)))
            # compute_cap 输出形如 7.5——CUDA 惯例命名是拼接（sm_75），
            # 与 CMAKE_CUDA_ARCHITECTURES=75 / build.sh 头注释保持一致
            llama_detail "  [${idx}] ${name}（sm_${cc/./}, ${vram_human}）"
        done

        # NVLink 拓扑：topo -m 矩阵中 GPU 间互联类型，NV# 表示 # 条 NVLink 绑定
        local max_nv
        # || true：PCIe-only 多 GPU 系统中 grep 找不到 NV* 条目返回 1，
        # pipefail+set -e 下会中止 build.sh（本函数由 build.sh:268 在 set -euo pipefail 下调用）。
        # sort -uV（版本排序）：混合拓扑中 NV12 字典序小于 NV2，
        # 字典序 sort -u | tail -1 会错取 NV2；按数值排序取最大绑定数。
        max_nv=$(nvidia-smi topo -m 2>/dev/null | grep -oE 'NV[0-9]+' | sort -uV | tail -1 || true)
        if [[ -n "$max_nv" ]]; then
            local links link_bw
            links=${max_nv#NV}
            link_bw=$(nvidia-smi nvlink --status -i 0 2>/dev/null | grep -oE '[0-9.]+ GB/s' | head -1 || true)
            if [[ -n "$link_bw" ]]; then
                local agg
                agg=$(awk -v b="${link_bw% GB/s}" -v n="$links" 'BEGIN{printf "%.1f", b*n}')
                llama_detail "NVLink: ${max_nv}（${links} 链路，单链路 ${link_bw}，聚合约 ${agg} GB/s）"
            else
                llama_detail "NVLink: ${max_nv}（${links} 链路）"
            fi
        else
            llama_detail "NVLink: 未检测到（GPU 间经 PCIe 互联）"
        fi
    else
        llama_detail "GPU:    未检测到 NVIDIA GPU"
    fi
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
    # 注意：不能用 prev_opts=$(set +o) 保存 errexit——bash 默认在命令替换
    # 子 shell 中重置 errexit（shopt inherit_errexit 默认 off），捕获到的
    # 恒为 "set +o errexit"，eval 恢复后会把调用者的 set -e 永久静默关闭。
    # $- 在当前 shell 读取，不受该重置影响（|| / if 等豁免上下文中仍正确）。
    local restore_e=0 restore_u=0
    if [[ $- == *e* ]]; then restore_e=1; fi
    if [[ $- == *u* ]]; then restore_u=1; fi
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

    # 恢复之前的 shell 选项（仅恢复本函数改动的 e/u）
    # 对称恢复：原本开启的重新开启；原本关闭的强制关闭——既精确还原调用者
    # 原状（函数内部曾 set +e/+u 容忍 conda 失败），又防止被 source 的
    # conda.sh/profile.d 脚本新启用的 -e/-u 泄漏（如 source run_env.sh 的父
    # shell，其按设计不启用 errexit）
    if ((restore_u)); then set -u; else set +u; fi
    if ((restore_e)); then set -e; else set +e; fi

    return 0
}

# --- 文件锁 --------------------------------------------------
# 动态文件描述符（exec {fd}>>）：bash 不会为此自动设置 FD_CLOEXEC，故
# fork 出的子进程（ninja/gcc 等）会继承该 fd。正常运行无害——本进程退出
# （含经 trap 清理的信号）时 fd 关闭、锁随即释放；仅当本进程被 SIGKILL/
# OOM-kill 而 fork 的子进程仍幸存时，锁可能延迟至孤儿退出才释放。

# Usage: _lock_grab <lock_file>
# 打开锁文件、非阻塞 flock、写入持有者 PID。
# 返回：0=成功（设置 LOCK_FD），1=锁被占用，2=锁文件无法打开/写入（已输出错误）。
# 内部辅助 — 供 llama_acquire_lock 与 _recover_stale_lock 复用，消除两份
# 「exec {fd}>> → flock -n → 截断 → 写 PID → LOCK_FD=$fd」重复拷贝。
_lock_grab() {
    local lock_file="$1"
    local fd
    # if ! 守护：exec 重定向失败时只打印错误并返回，不杀死 shell
    if ! exec {fd}>>"$lock_file"; then
        llama_err "无法打开锁文件: ${lock_file}"
        return 2
    fi
    if ! flock -n "$fd"; then
        # bash 关闭已关闭/无效的 fd 静默返回 0——这里不能加 2>/dev/null：
        # 无命令 exec 的重定向会永久改变当前 shell 的 stderr，
        # 实测会吞掉调用点之后的全部 llama_err 输出
        exec {fd}>&-
        return 1
    fi
    # 单步 open+write 写入 PID：原「: > 截断 + echo $$ 追加」两步之间存在
    # 竞争者读到空文件的窗口。$BASHPID 在子 shell 中也是实际持锁进程的
    # PID（$$ 会写成顶层 shell 的 PID，活锁被误诊为残留锁）
    if ! printf '%s\n' "$BASHPID" > "$lock_file"; then
        llama_err "无法写入锁文件: ${lock_file}"
        exec {fd}>&-
        return 2
    fi
    LOCK_FD=$fd
    return 0
}

# Usage: _recover_stale_lock <lock_file>
# 尝试恢复残留锁。成功返回 0（设置 LOCK_FD），失败返回 1。
# 内部辅助函数 — 仅由 llama_acquire_lock 调用。
_recover_stale_lock() {
    local lock_file="$1"
    local holder_pid
    holder_pid=$(cat "$lock_file" 2>/dev/null || true)

    llama_warn "检测到残留锁（原持有者 PID ${holder_pid:-未知} 已不存在）"
    llama_detail "尝试自动清理残留锁..."
    local grab_rc=0
    _lock_grab "$lock_file" || grab_rc=$?
    if [[ "$grab_rc" -eq 2 ]]; then
        return 1  # 打开/写入失败，_lock_grab 已输出明确错误
    fi
    if [[ "$grab_rc" -ne 0 ]]; then
        llama_err "自动清理失败，锁仍然被占用"
        llama_detail "请手动检查是否有其他进程在使用该锁文件"
        llama_detail "请在确认没有其他进程占用锁文件后重试"
        return 1
    fi

    llama_ok "残留锁已自动清理，继续执行"
    return 0
}

# Usage: llama_acquire_lock [lock_file]
# 返回：成功返回 0（设置 LOCK_FD），锁被占用或不可用返回 1。
llama_acquire_lock() {
    local lock_file="${1:-$LOCK_FILE}"  # 默认使用脚本级 LOCK_FILE
    if [[ -z "$lock_file" ]]; then
        llama_err "未指定锁文件路径"
        return 1
    fi

    # flock 缺失时 flock -n 返回 127，会被误判为"锁被占用"——提前明确诊断
    if ! command -v flock &>/dev/null; then
        llama_err "缺少 flock 命令（通常由 util-linux 包提供），无法进行文件锁检查"
        return 1
    fi

    # 确保锁文件目录存在
    local lock_dir
    lock_dir=$(dirname "$lock_file")
    if [[ ! -d "$lock_dir" ]]; then
        if ! mkdir -p "$lock_dir" 2>/dev/null; then
            llama_err "无法创建锁目录: ${lock_dir}"
            return 1
        fi
    fi

    local grab_rc=0
    _lock_grab "$lock_file" || grab_rc=$?
    case "$grab_rc" in
        0) return 0 ;;
        2) return 1 ;;  # 打开/写入失败，_lock_grab 已输出明确错误
    esac

    # 锁被占用 — 从文件读取 PID 用于诊断
    local holder_pid
    holder_pid=$(cat "$lock_file" 2>/dev/null || true)
    if [[ -z "$holder_pid" ]]; then
        # 持有者在获得 flock 后、写入 PID 前存在极窄窗口；
        # 短暂重读一次，避免把正常锁竞争误诊为残留锁
        sleep 0.1
        holder_pid=$(cat "$lock_file" 2>/dev/null || true)
    fi
    local holder_cmd
    if [[ -n "$holder_pid" ]] && kill -0 "$holder_pid" 2>/dev/null; then
        holder_cmd=$(ps -p "$holder_pid" -o comm= 2>/dev/null || echo "未知")
        llama_err "另一个进程正在运行 (PID: ${holder_pid}, 命令: ${holder_cmd})，请等待其完成"
        return 1
    fi
    _recover_stale_lock "$lock_file"
}

# Usage: llama_release_lock
# 关闭锁文件描述符
llama_release_lock() {
    if [[ -n "${LOCK_FD:-}" ]]; then
        # bash 关闭已关闭的 fd 静默返回 0，无需错误屏蔽；
        # 绝不能加 2>/dev/null——无命令 exec 的重定向会永久改变当前
        # shell 的 stderr（实测吞掉 llama_safe_exit 之前的全部错误输出）
        exec {LOCK_FD}>&-
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
    # || true：df 在某些文件系统（FUSE/损坏挂载）下失败时，pipefail 使管线返回非零，
    # 在 set -e 下会中止脚本。本函数契约是"不阻塞"（仅警告），故显式忽略退出码，
    # 交由下方 -z 检查处理空输出。
    # -k 强制 1K 块：POSIXLY_CORRECT=1 时裸 -P 退化为 512 字节块（POSIX 语义的
    # 默认块大小），可用量被高估 2×（实测）——fail-open 方向，会把磁盘不足
    # 误判为充足。
    available_kb=$(LC_ALL=C df -Pk "$path" 2>/dev/null | awk 'NR==2 {print $4}') || true
    if [[ -z "$available_kb" ]]; then
        llama_warn "无法获取磁盘空间信息"
        return 0
    fi
    # 某些文件系统（FUSE/overlay/损坏挂载）df 成功但第 4 列非数字（如 "-"）：
    # 算术展开在 set -e/-u 下会中止脚本，绕过本函数"不阻塞"契约
    if [[ ! "$available_kb" =~ ^[0-9]+$ ]]; then
        llama_warn "无法解析磁盘可用空间: ${available_kb}"
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
    # 构建布局常量由 config.sh 统一定义；未 source config.sh 时按默认布局回退
    local bin_dir="${BUILD_BIN_DIR:-${LLAMA_CPP_SRC}/build/bin}"
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
    local build_stamp="${BUILD_STAMP:-${LLAMA_CPP_SRC}/build/.build-stamp}"
    local current_head
    current_head=$(git -C "$LLAMA_CPP_SRC" rev-parse HEAD 2>/dev/null || echo "")
    # git 不可用（缺失/dubious ownership/.git 损坏）时无法判定：
    # 空串与 git 失败时留下的空 stamp 文件相等会造成"健康"误判，必须按不健康处理
    [[ -z "$current_head" ]] && return 1
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
# Usage: llama_die [message] [exit_code]
llama_die() {
    local msg="${1:-}"
    local code="${2:-1}"
    if [[ -n "$msg" ]]; then
        llama_err "$msg"
    fi
    llama_safe_exit "$code"
}

# out-param（printf -v 写回）接口的保留变量名单：覆写这些变量会破坏
# shell 自身行为（PATH 被改写后全部外部命令 lookup 失败——已实证）或
# 直接报错（UID/SHELLOPTS 等 readonly）。llama_run_silent 与 _parse_args
# 等 out-param 接口在形态校验之外必须过此名单。
# declare -ar 是 Bash 中声明只读数组的唯一方式（readonly 无法作用于数组）
declare -ar _LLAMA_OUT_VAR_DENY=(
    PATH IFS HOME PWD OLDPWD SHELL TERM LANG LC_ALL LC_CTYPE PS1 PS2
    BASH_SOURCE FUNCNAME BASHPID BASHOPTS SHELLOPTS
    UID EUID PPID GROUPS RANDOM SECONDS LINENO DIRSTACK PIPESTATUS
)
# Usage: llama_out_var_denylisted <name>
# <name> 在 out-param 保留名单（_LLAMA_OUT_VAR_DENY）中时返回 0，否则返回 1。
llama_out_var_denylisted() {
    local name="$1" denied
    for denied in "${_LLAMA_OUT_VAR_DENY[@]}"; do
        [[ "$name" == "$denied" ]] && return 0
    done
    return 1
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
    # BASH_SOURCE[1] 是调用者所在文件：与 $0 相同 → 脚本上下文（exit）；
    # 不同（调用者正被 source）→ source 上下文（return）。
    # 原实现靠"函数体内 return 失败回退 exit"检测上下文——但函数体内
    # return 永远合法，该回退是死代码，脚本退出码实际依赖"它是文件最后
    # 一条命令"这一巧合（末尾追加任何语句都会把失败退出码覆盖为 0）。
    if [[ "${BASH_SOURCE[1]}" == "$0" ]]; then
        exit "$code"
    fi
    return "$code"
}

# --- 初始化/引用/帮助辅助 ------------------------------------
# SCRIPT_DIR 由各入口脚本在 source common.sh 之前内联解析（见 build.sh /
# update.sh 顶部）；run_env.sh 刻意不设置 SCRIPT_DIR——source 场景下赋值
# 会覆写父 shell 的同名变量（dotfiles 常用名），其 run_env.sh:40-47 注释
# 记录了该决定。

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

# 注：llama_save_colors / llama_restore_colors 已移至文件顶部颜色区定义
# （颜色赋值之前），以便 source 时自动保存调用者原值。

# Usage: llama_print_run_examples <bin_dir>
llama_print_run_examples() {
    local bin_dir="${1:?bin_dir required}"
    local script_dir="${SCRIPT_DIR:-.}"
    echo "运行示例:"
    echo "  source ${script_dir}/run_env.sh"
    echo "  ${bin_dir}/llama-cli -m /path/to/model.gguf -ngl 99 -p \"你好\""
    echo "  ${bin_dir}/llama-server -m /path/to/model.gguf -ngl 99 --port 8080"
}

# Usage: llama_run_silent <rc_var> <command> [args...]
# 在禁用 set -e 的情况下运行命令并捕获输出；退出码经 printf -v 写入 <rc_var>。
# 契约：
#   - 恒返回 0 —— 被包装命令失败不会中止 set -e 的调用者；状态只经 <rc_var> 传递。
#     如何响应失败（die / 回滚 / 忽略）由调用者读取 <rc_var> 决定
#   - <rc_var> 必写（含失败路径），调用者在 set -u 下读取安全；调用点应先
#     local 声明该变量，使动态作用域下的 printf -v 写入局部变量而非产生全局变量
#   - 命令失败时 warn 并转储捕获输出到 stderr
#   - 误用（rc_var 缺失/非法、保留前缀 _lrs_、缺少命令）返回 2 —— 程序员错误，
#     与被包装命令的失败是两类，必须大声失败
# 内部局部变量使用 _lrs_ 前缀：动态作用域下同名的函数内 local 会遮蔽调用者
# 变量，printf -v 会写到函数自己的 local 上（调用者永远拿不到值）；保留前缀
# 使碰撞在结构上不可能。
llama_run_silent() {
    local _lrs_rc_var="${1:-}"
    if [[ ! "$_lrs_rc_var" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ || "$_lrs_rc_var" == _lrs_* ]] \
        || llama_out_var_denylisted "$_lrs_rc_var"; then
        llama_err "llama_run_silent: 无效或保留的输出变量名: ${_lrs_rc_var:-<空>}（_lrs_ 前缀与 shell 关键变量名为实现保留）"
        return 2
    fi
    shift
    if (($# == 0)); then
        llama_err "llama_run_silent: 缺少命令"
        return 2
    fi

    # 先落默认值：任何后续路径都保证 <rc_var> 必写（set -u 调用者读取安全）；
    # 默认非零——命令未运行按失败处理，绝不谎报成功
    printf -v "$_lrs_rc_var" '%s' 1

    local _lrs_tmp_out
    _lrs_tmp_out=$(mktemp "${TMPDIR:-/tmp}/llama_run_silent.XXXXXX" 2>/dev/null) || _lrs_tmp_out=""
    # 与 llama_activate_conda 同理：不能用 prev_opts=$(set +o) 保存/恢复
    # errexit——bash 默认在命令替换子 shell 中重置 errexit（inherit_errexit
    # 默认 off），eval 恢复后会把调用者的 set -e 永久静默关闭（已实证）。
    # $- 在当前 shell 读取，|| / if 等豁免上下文中仍反映真实选项状态。
    local _lrs_restore_e=0
    if [[ $- == *e* ]]; then _lrs_restore_e=1; fi
    set +e
    local _lrs_ret
    if [[ -n "$_lrs_tmp_out" ]]; then
        "$@" >"$_lrs_tmp_out" 2>&1
        _lrs_ret=$?
        if [[ "$_lrs_ret" -ne 0 ]]; then
            llama_warn "命令失败 (退出码: ${_lrs_ret})"
            cat "$_lrs_tmp_out" >&2 2>/dev/null || true
        fi
        rm -f "$_lrs_tmp_out"
    else
        "$@"
        _lrs_ret=$?
    fi
    if ((_lrs_restore_e)); then set -e; fi
    printf -v "$_lrs_rc_var" '%s' "$_lrs_ret"
    return 0
}
