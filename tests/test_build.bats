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
