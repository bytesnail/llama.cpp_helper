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

@test "config.sh honors environment variable overrides" {
    # config.sh uses \${VAR:-default} pattern — env vars should take precedence
    run bash -c "
        _LLAMA_PROJECT_ROOT='${TEST_TMPDIR}'
        LLAMA_CPP_SRC='/custom/src/path'
        CMAKE_BUILD_TYPE='Debug'
        CMAKE_CUDA_ARCHITECTURES='86'
        GGML_BLAS='OFF'
        source '${BATS_TEST_DIRNAME}/../config.sh' 2>/dev/null
        [[ \"\$LLAMA_CPP_SRC\" == \"/custom/src/path\" ]]
        [[ \"\$CMAKE_BUILD_TYPE\" == \"Debug\" ]]
        [[ \"\$CMAKE_CUDA_ARCHITECTURES\" == \"86\" ]]
        [[ \"\$GGML_BLAS\" == \"OFF\" ]]
    "
    [ "$status" -eq 0 ]
}

@test "LLAMA_CMAKE_KNOBS contains exactly the expected cmake knobs" {
    # 旋钮表是 cmake -D 透传的单一事实来源；新增/删除旋钮需同步更新此清单
    run bash -c "
        source '${BATS_TEST_DIRNAME}/../config.sh' 2>/dev/null
        expected='CMAKE_BUILD_TYPE CMAKE_CUDA_ARCHITECTURES CMAKE_CUDA_FLAGS GGML_CUDA GGML_CUDA_PEER_MAX_BATCH_SIZE GGML_CUDA_FA_ALL_QUANTS GGML_CUDA_GRAPHS GGML_NATIVE GGML_BLAS GGML_BLAS_VENDOR LLAMA_BUILD_TESTS'
        [[ \"\${LLAMA_CMAKE_KNOBS[*]}\" == \"\$expected\" ]]
    "
    [ "$status" -eq 0 ]
}

@test "every knob in LLAMA_CMAKE_KNOBS has a non-empty definition" {
    # 表内名字必须对应已定义变量，否则 build.sh 的 \${!knob} 间接展开会在 set -u 下中止
    run bash -c "
        source '${BATS_TEST_DIRNAME}/../config.sh' 2>/dev/null
        [[ \${#LLAMA_CMAKE_KNOBS[@]} -gt 0 ]] || exit 1
        for knob in \"\${LLAMA_CMAKE_KNOBS[@]}\"; do
            [[ -n \"\${!knob}\" ]] || { echo \"knob undefined or empty: \$knob\"; exit 1; }
        done
    "
    [ "$status" -eq 0 ]
}

@test "every variable in config.sh build section is listed in LLAMA_CMAKE_KNOBS" {
    # 反向同步：构建配置节新增的 VAR=\${VAR:-...} 定义必须登记到旋钮表
    run bash -c "
        source '${BATS_TEST_DIRNAME}/../config.sh' 2>/dev/null
        names=\$(sed -n '/^# --- 构建配置/,/^# --- /p' '${BATS_TEST_DIRNAME}/../config.sh' \
            | grep -oP '^[A-Z_]+(?==)' | sort -u)
        [[ -n \"\$names\" ]] || exit 1
        for name in \$names; do
            printf '%s\n' \"\${LLAMA_CMAKE_KNOBS[@]}\" | grep -qx \"\$name\" \
                || { echo \"missing from LLAMA_CMAKE_KNOBS: \$name\"; exit 1; }
        done
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
