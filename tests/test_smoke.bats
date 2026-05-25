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

@test "all scripts have correct shebang line" {
    for script in common.sh config.sh build.sh update.sh run_env.sh; do
        local first_line
        first_line=$(head -1 "${BATS_TEST_DIRNAME}/../${script}")
        [[ "$first_line" == "#!/bin/bash" ]]
    done
}

@test "config.sh exports all expected variables" {
    # Source config.sh in a subshell with a fake project root
    run bash -c "
        _LLAMA_PROJECT_ROOT='${TEST_TMPDIR}'
        source '${BATS_TEST_DIRNAME}/../config.sh' 2>/dev/null
        [[ -n \"\${LLAMA_CPP_SRC}\" ]]
        [[ -n \"\${REPO}\" ]]
        [[ -n \"\${LLAMA_HELPER_VERSION}\" ]]
        [[ -n \"\${MIN_FREE_DISK_GB}\" ]]
    "
    [ "$status" -eq 0 ]
}

@test "no script mixes tabs and spaces for indentation" {
    # All .sh scripts use space indentation per .editorconfig
    run bash -c "
        scripts='common.sh config.sh build.sh update.sh run_env.sh'
        for s in \$scripts; do
            grep -nP '^\t' '${BATS_TEST_DIRNAME}/../'\$s && exit 1 || true
        done
        exit 0
    "
    [ "$status" -eq 0 ]
}

@test "config.sh rejects direct execution" {
    run bash "${BATS_TEST_DIRNAME}/../config.sh"
    [ "$status" -ne 0 ]
    [[ "$output" =~ "source" ]]
}
