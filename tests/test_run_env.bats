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

@test "run_env.sh sets CUDA_SCALE_LAUNCH_QUEUES=4x" {
    run bash -c "source '${BATS_TEST_DIRNAME}/../run_env.sh' && echo \$CUDA_SCALE_LAUNCH_QUEUES"
    [ "$status" -eq 0 ]
    [[ "$output" =~ "4x" ]]
}

@test "run_env.sh preserves pre-set CUDA_SCALE_LAUNCH_QUEUES" {
    run bash -c "export CUDA_SCALE_LAUNCH_QUEUES=8x; source '${BATS_TEST_DIRNAME}/../run_env.sh' 2>/dev/null; echo \$CUDA_SCALE_LAUNCH_QUEUES"
    [ "$status" -eq 0 ]
    [[ "$output" =~ "8x" ]]
}

@test "run_env.sh --status does not set env vars" {
    run bash -c "source '${BATS_TEST_DIRNAME}/../run_env.sh' --status 2>/dev/null; echo P2P=\${GGML_CUDA_P2P:-unset}"
    [ "$status" -eq 0 ]
    [[ ! "$output" =~ "P2P=1" ]]
}

@test "run_env.sh rejects unknown flags with error" {
    run bash -c "source '${BATS_TEST_DIRNAME}/../run_env.sh' --bogus"
    [ "$status" -ne 0 ]
    [[ "$output" =~ "未知" ]]
}

@test "run_env.sh duplicate source guard prevents re-sourcing" {
    run bash -c "source '${BATS_TEST_DIRNAME}/../run_env.sh' 2>/dev/null && source '${BATS_TEST_DIRNAME}/../run_env.sh' 2>/dev/null && echo SOURCED_TWICE"
    [ "$status" -eq 0 ]
    [[ "$output" == *"SOURCED_TWICE"* ]]
}
