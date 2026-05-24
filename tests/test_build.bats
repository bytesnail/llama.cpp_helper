#!/usr/bin/env bats
load test_helper

@test "build.sh --help exits 0" {
    run bash "${BATS_TEST_DIRNAME}/../build.sh" --help
    [ "$status" -eq 0 ]
    [[ "$output" =~ "用法" ]]
}

@test "build.sh --version exits 0 and shows version" {
    run bash "${BATS_TEST_DIRNAME}/../build.sh" --version
    [ "$status" -eq 0 ]
    [[ "$output" =~ "llama.cpp_helper" ]]
}

@test "build.sh -h is alias for --help" {
    run bash "${BATS_TEST_DIRNAME}/../build.sh" -h
    [ "$status" -eq 0 ]
    [[ "$output" =~ "用法" ]]
}

@test "build.sh rejects unknown flags with error" {
    run bash "${BATS_TEST_DIRNAME}/../build.sh" --bogus
    [ "$status" -ne 0 ]
    [[ "$output" =~ "未知" ]]
}

@test "build.sh --help mentions --incremental" {
    run bash "${BATS_TEST_DIRNAME}/../build.sh" --help
    [[ "$output" =~ "incremental" ]]
}

@test "build.sh --help mentions --version" {
    run bash "${BATS_TEST_DIRNAME}/../build.sh" --help
    [[ "$output" =~ "version" ]]
}

@test "_verify_linking returns 0 and warns when bin_dir is empty" {
    # Source common.sh for llama_* functions, config.sh for config vars
    source "${BATS_TEST_DIRNAME}/../common.sh"
    # shellcheck source=/dev/null
    source "${BATS_TEST_DIRNAME}/../config.sh"

    # Extract _verify_linking function from build.sh without executing top-level code
    eval "$(sed -n '/^_verify_linking()/,/^}/p' "${BATS_TEST_DIRNAME}/../build.sh")"

    run _verify_linking "" "llama-cli" "libcudart" "CUDA" "not found"
    [ "$status" -eq 0 ]
    [[ "$output" =~ "未指定二进制目录" ]]
}
