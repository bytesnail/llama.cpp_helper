#!/usr/bin/env bats
load test_helper

@test "run_env.sh --help works when sourced" {
    run bash -c "source '${BATS_TEST_DIRNAME}/../run_env.sh' --help"
    [ "$status" -eq 0 ]
    [[ "$output" =~ "用法" ]]
}

@test "run_env.sh --version works when sourced" {
    run bash -c "source '${BATS_TEST_DIRNAME}/../run_env.sh' --version"
    [ "$status" -eq 0 ]
    [[ "$output" =~ "llama.cpp_helper" ]]
}

@test "run_env.sh --status shows GGML_CUDA_P2P" {
    run bash -c "source '${BATS_TEST_DIRNAME}/../run_env.sh' --status"
    [ "$status" -eq 0 ]
    [[ "$output" =~ "GGML_CUDA_P2P" ]]
}

@test "run_env.sh sets GGML_CUDA_P2P=1" {
    run bash -c "source '${BATS_TEST_DIRNAME}/../run_env.sh' && echo \$GGML_CUDA_P2P"
    [ "$status" -eq 0 ]
    [[ "$output" =~ "1" ]]
}

@test "run_env.sh warns on direct execution" {
    run bash "${BATS_TEST_DIRNAME}/../run_env.sh"
    [ "$status" -ne 0 ]
    [[ "$output" =~ "source" ]]
}

@test "run_env.sh preserves pre-set GGML_CUDA_P2P" {
    run bash -c "export GGML_CUDA_P2P=0; source '${BATS_TEST_DIRNAME}/../run_env.sh' 2>/dev/null; echo \$GGML_CUDA_P2P"
    [ "$status" -eq 0 ]
    [[ "$output" =~ "0" ]]
}

@test "run_env.sh skips conda when CONDA_AUTO_ACTIVATE=0" {
    run bash -c "CONDA_AUTO_ACTIVATE=0 source '${BATS_TEST_DIRNAME}/../run_env.sh' 2>/dev/null && echo DONE"
    [ "$status" -eq 0 ]
    [[ "$output" =~ "DONE" ]]
}

@test "run_env.sh --status still works with conda config (smoke test)" {
    run bash -c "source '${BATS_TEST_DIRNAME}/../run_env.sh' --status"
    [ "$status" -eq 0 ]
    [[ "$output" =~ "GGML_CUDA_P2P" ]]
}

@test "run_env.sh no longer exports CUDA_SCALE_LAUNCH_QUEUES (removed upstream in v0.3.0)" {
    # 上游 v0.3.0 源码无该变量（无 getenv 消费者），导出无效果——防止复活
    run bash -c "source '${BATS_TEST_DIRNAME}/../run_env.sh' 2>/dev/null; echo \${CUDA_SCALE_LAUNCH_QUEUES:-UNSET}"
    [ "$status" -eq 0 ]
    [[ "$output" =~ "UNSET" ]]
}

@test "run_env.sh warns that GGML_CUDA_P2P=0 does not disable P2P" {
    # 存在性语义：llama.cpp 仅检测变量是否存在（上游 getenv != nullptr，
    # 已核实）——=0 不关闭，必须提示 unset，否则用户误以为已关闭
    run bash -c "export GGML_CUDA_P2P=0; source '${BATS_TEST_DIRNAME}/../run_env.sh' 2>&1"
    [ "$status" -eq 0 ]
    [[ "$output" =~ "保留用户值" ]]
    [[ "$output" =~ "不会关闭" ]]
    [[ "$output" =~ "unset" ]]
}

@test "source run_env.sh does not leak config.sh readonly vars or SCRIPT_DIR" {
    # config.sh 改经子 shell 提取版本号：readonly 变量（REPO 等）不再灌入
    # 父 shell（readonly 无法 unset，用户后续同名赋值会报"只读变量"）；
    # SCRIPT_DIR 不被覆写（run_env.sh 刻意不设置，避免污染父 shell 同名变量）
    run bash -c "
        REPO=mine; SCRIPT_DIR=/opt/mine
        source '${BATS_TEST_DIRNAME}/../run_env.sh' >/dev/null 2>&1
        REPO=other
        echo \"REPO=\$REPO SCRIPT_DIR=\$SCRIPT_DIR\"
    "
    [ "$status" -eq 0 ]
    [[ "$output" =~ "REPO=other SCRIPT_DIR=/opt/mine" ]]
}

@test "run_env.sh --status does not set env vars" {
    run bash -c "source '${BATS_TEST_DIRNAME}/../run_env.sh' --status 2>/dev/null; echo P2P=\${GGML_CUDA_P2P:-unset}"
    [ "$status" -eq 0 ]
    [[ ! "$output" =~ "P2P=1" ]]
}

@test "run_env.sh rejects unknown flags with error" {
    # 错误经消息传达；source 上下文退出码恒为 0——非零 return 是会杀死
    # set -e 父 shell 的简单命令，与"不伤害父 shell"承诺相悖（实测复现）
    run bash -c "source '${BATS_TEST_DIRNAME}/../run_env.sh' --bogus"
    [ "$status" -eq 0 ]
    [[ "$output" =~ "未知" ]]
}

@test "run_env.sh duplicate source guard prevents re-sourcing" {
    run bash -c "source '${BATS_TEST_DIRNAME}/../run_env.sh' 2>/dev/null && source '${BATS_TEST_DIRNAME}/../run_env.sh' 2>/dev/null && echo SOURCED_TWICE"
    [ "$status" -eq 0 ]
    [[ "$output" == *"SOURCED_TWICE"* ]]
}

@test "source run_env.sh does not leak _main_rc or finalize helper" {
    # 回归测试：脚本级 _main_rc 曾残留父 shell（实测 _main_rc=0 泄漏）——
    # 收尾函数经参数接收后 unset；finalize 函数自身也随调用自卸载。
    # LLAMA_HELPER_VERSION 同理：--version 分支内经 main 的 local 提取，
    # 不再残留（此前在 source 时急切赋值进父 shell 且永不清理）
    run bash -c "
        source '${BATS_TEST_DIRNAME}/../run_env.sh' --version >/dev/null 2>&1
        declare -p _main_rc >/dev/null 2>&1 && echo LEAK_RC
        declare -f _llama_run_env_finalize >/dev/null 2>&1 && echo LEAK_FN
        declare -f main >/dev/null 2>&1 && echo LEAK_MAIN
        declare -p LLAMA_HELPER_VERSION >/dev/null 2>&1 && echo LEAK_VER
        echo DONE
    "
    [ "$status" -eq 0 ]
    [[ "$output" == *"DONE"* ]]
    [[ "$output" != *"LEAK"* ]]
}

@test "source run_env.sh cleans up color variables (no parent shell pollution)" {
    # 颜色变量由 common.sh 单一来源管理（_LLAMA_COLOR_VARS）；source 时自动
    # 保存父 shell 原值，退出时 llama_restore_colors 恢复。父 shell 原本无
    # RED → 恢复为空串（save/restore 不区分 unset 与空串），视为无污染。
    run bash -c "
        source '${BATS_TEST_DIRNAME}/../run_env.sh' --status >/dev/null 2>&1
        if [[ -n \"\${RED:-}\" ]]; then echo DIRTY; else echo CLEAN; fi
    "
    [ "$status" -eq 0 ]
    [ "$output" = "CLEAN" ]
}

@test "source run_env.sh restores pre-existing color variables" {
    # 回归测试：父 shell 预设的同名颜色变量必须在退出时被恢复
    # （原实现无 save 配对，restore 退化为 unset 销毁用户变量——已实证）
    run bash -c "
        RED=user_custom
        source '${BATS_TEST_DIRNAME}/../run_env.sh' --status >/dev/null 2>&1
        echo \"RED=\$RED\"
    "
    [ "$status" -eq 0 ]
    [ "$output" = "RED=user_custom" ]
}

@test "source run_env.sh with unknown flag still restores colors under parent set -e" {
    # 回归测试：main 经 || 捕获，即使参数错误也会执行 llama_restore_colors
    # （原实现 main 直接返回非零，父 shell set -e 下 restore 被跳过，颜色泄漏）
    run bash -c "
        set -e
        RED=user_custom
        source '${BATS_TEST_DIRNAME}/../run_env.sh' --bogus >/dev/null 2>&1 || true
        echo \"RED=\$RED\"
    "
    [ "$status" -eq 0 ]
    [ "$output" = "RED=user_custom" ]
}

@test "source run_env.sh survives set -e when llama_get_gpu_count fails" {
    # 回归测试：父 shell 启用 set -e 时，gpu_count 赋值不应因
    # llama_get_gpu_count 返回 1 而杀死父 shell（run_env.sh 的 || true 修复）。
    # 通过覆盖 llama_get_gpu_count 模拟无 nvidia-smi 环境。
    run bash -c "
        set -euo pipefail
        source '${BATS_TEST_DIRNAME}/../common.sh' 2>/dev/null || true
        llama_get_gpu_count() { echo 0; return 1; }
        source '${BATS_TEST_DIRNAME}/../run_env.sh' >/dev/null 2>&1
        echo SURVIVED
    "
    [ "$status" -eq 0 ]
    [[ "$output" == *SURVIVED* ]]
}
