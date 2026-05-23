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
