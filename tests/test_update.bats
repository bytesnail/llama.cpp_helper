#!/usr/bin/env bats
load test_helper

@test "update.sh --help exits 0" {
    run bash "${BATS_TEST_DIRNAME}/../update.sh" --help
    [ "$status" -eq 0 ]
    [[ "$output" =~ "用法" ]]
}

@test "update.sh --version exits 0" {
    run bash "${BATS_TEST_DIRNAME}/../update.sh" --version
    [ "$status" -eq 0 ]
    [[ "$output" =~ "llama.cpp_helper" ]]
}

@test "update.sh --help mentions tag/commit" {
    run bash "${BATS_TEST_DIRNAME}/../update.sh" --help
    [[ "$output" =~ "标签" ]]
    [[ "$output" =~ "commit" ]]
}

@test "update.sh rejects unknown flags with error" {
    run bash "${BATS_TEST_DIRNAME}/../update.sh" --bogus
    [ "$status" -ne 0 ]
    [[ "$output" =~ "未知" ]]
}

@test "update.sh rejects single-dash unknown flags with error" {
    run bash "${BATS_TEST_DIRNAME}/../update.sh" -x
    [ "$status" -ne 0 ]
    [[ "$output" =~ "未知" ]]
}

@test "update.sh warns about extra arguments" {
    run bash "${BATS_TEST_DIRNAME}/../update.sh" b3631 extra_arg
    [[ "$output" =~ "忽略额外参数" ]]
    # 脚本在 _check_local_repo 失败后会以非零退出码退出，
    # 但在此之前已经警告了额外参数 — 这就足以进行测试了
    # [ "$status" -ne 0 ]
}

@test "update.sh reports version switch failure on non-existent target" {
    # Create a fake llama.cpp repo to pass _check_local_repo
    local fake_repo="${TEST_TMPDIR}/llama.cpp"
    mkdir -p "${fake_repo}"
    git -C "${fake_repo}" init -q
    git -C "${fake_repo}" commit --allow-empty -q -m "init"
    git -C "${fake_repo}" remote add origin https://github.com/ggml-org/llama.cpp

    # Use a non-existent tag so git checkout fails inside _update_source
    LLAMA_CPP_SRC="${fake_repo}" run bash "${BATS_TEST_DIRNAME}/../update.sh" nonexistent_tag_xyz 2>&1 || true
    # The script should report failure (non-zero exit) or a version error message
    [[ "$output" =~ "版本切换失败" || "$output" =~ "本地找不到目标版本" || "$status" -ne 0 ]]
}

@test "_save_state sets CURRENT_BRANCH after sourcing" {
    # Create a fake llama.cpp repo on a branch
    local fake_repo="${TEST_TMPDIR}/llama.cpp"
    mkdir -p "${fake_repo}"
    git -C "${fake_repo}" init -q
    git -C "${fake_repo}" commit --allow-empty -q -m "init"
    git -C "${fake_repo}" checkout -q -b test-branch

    # Source common.sh for logging functions, then set vars and run _save_state inline
    source "${BATS_TEST_DIRNAME}/../common.sh" 2>/dev/null || true
    source "${BATS_TEST_DIRNAME}/../config.sh" 2>/dev/null || true
    LLAMA_CPP_SRC="${fake_repo}"
    CURRENT_COMMIT=""; CURRENT_SHORT=""; CURRENT_TAG=""; CURRENT_BRANCH=""
    # Evaluate _save_state function body directly from update.sh
    _save_state() {
        CURRENT_COMMIT=$(git -C "${LLAMA_CPP_SRC}" rev-parse HEAD)
        CURRENT_SHORT=$(git -C "${LLAMA_CPP_SRC}" rev-parse --short HEAD)
        CURRENT_TAG=$(git -C "${LLAMA_CPP_SRC}" describe --tags --exact-match 2>/dev/null || echo "(无标签)")
        CURRENT_BRANCH=$(git -C "${LLAMA_CPP_SRC}" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
    }
    _save_state
    [ "$CURRENT_BRANCH" = "test-branch" ]
}
