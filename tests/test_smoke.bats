#!/usr/bin/env bats

load test_helper

@test "shellcheck is available" {
    command -v shellcheck
}

@test "all scripts pass bash -n syntax check" {
    for script in common.sh config.sh build.sh update.sh run_env.sh; do
        run bash -n "${BATS_TEST_DIRNAME}/../${script}"
        [ "$status" -eq 0 ]
    done
}
