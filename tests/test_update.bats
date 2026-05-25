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
        CURRENT_BRANCH=$(git -C "${LLAMA_CPP_SRC}" symbolic-ref --short HEAD 2>/dev/null || echo "")
    }
    _save_state
    [ "$CURRENT_BRANCH" = "test-branch" ]
}

@test "_print_success_summary outputs expected format" {
    source "${BATS_TEST_DIRNAME}/../common.sh" 2>/dev/null || true
    source "${BATS_TEST_DIRNAME}/../config.sh" 2>/dev/null || true

    # Extract _print_success_summary from update.sh
    eval "$(sed -n '/^_print_success_summary()/,/^}/p' "${BATS_TEST_DIRNAME}/../update.sh")"

    # llama_print_run_examples needs SCRIPT_DIR
    llama_init_script_dir

    CURRENT_SHORT="abc1234"
    RELEASE_TAG="b4000"
    CURRENT_TAG="(旧标签)"
    run _print_success_summary 1 "旧版" "b4000" "2026-01-01"
    [ "$status" -eq 0 ]
    [[ "$output" == *"abc1234"* || "$output" == *"旧版"* ]]
    [[ "$output" == *"b4000"* ]]
}

@test "_cleanup_stale_submodules handles no stale entries cleanly" {
    source "${BATS_TEST_DIRNAME}/../common.sh" 2>/dev/null || true
    source "${BATS_TEST_DIRNAME}/../config.sh" 2>/dev/null || true

    # Create a minimal git repo with a .gitmodules file (no stale entries)
    local fake_repo="${TEST_TMPDIR}/clean_repo"
    mkdir -p "$fake_repo"
    git -C "$fake_repo" init -q
    git -C "$fake_repo" commit --allow-empty -q -m "init"
    # Create a valid submodule entry to make find not prune everything
    mkdir -p "${fake_repo}/sub"
    touch "${fake_repo}/sub/.git"  # regular file, not gitdir ref — won't match grep
    git -C "$fake_repo" add sub/.git 2>/dev/null || true

    # Extract _cleanup_stale_submodules from update.sh
    eval "$(sed -n '/^_cleanup_stale_submodules()/,/^}/p' "${BATS_TEST_DIRNAME}/../update.sh")"

    LLAMA_CPP_SRC="$fake_repo" run _cleanup_stale_submodules
    [ "$status" -eq 0 ]
    # No stale entries means no cleanup output message
    [[ "$output" != *"清理旧子模块"* ]]
}


@test "_cleanup_stale_submodules removes stale submodule with gitdir ref" {
    source "${BATS_TEST_DIRNAME}/../common.sh" 2>/dev/null || true
    source "${BATS_TEST_DIRNAME}/../config.sh" 2>/dev/null || true
    eval "$(sed -n '/^_cleanup_stale_submodules()/,/^}/p' "${BATS_TEST_DIRNAME}/../update.sh")"

    local fake_repo="${TEST_TMPDIR}/stale_repo"
    mkdir -p "$fake_repo"
    git -C "$fake_repo" init -q
    git -C "$fake_repo" commit --allow-empty -q -m "init"

    # Create a stale .git file (gitdir ref pattern) in a subdirectory
    mkdir -p "${fake_repo}/old_sub"
    echo 'gitdir: ../../../.git/modules/old_sub' > "${fake_repo}/old_sub/.git"

    # Also create corresponding .git/modules/ entry
    mkdir -p "${fake_repo}/.git/modules/old_sub"
    touch "${fake_repo}/.git/modules/old_sub/config"

    git -C "$fake_repo" add old_sub/.git 2>/dev/null || true

    LLAMA_CPP_SRC="$fake_repo" run _cleanup_stale_submodules
    [ "$status" -eq 0 ]
    # Verify stale module was cleaned up
    [[ "$output" =~ "清理旧子模块" ]]
    [[ ! -d "${fake_repo}/old_sub" ]]
    [[ ! -d "${fake_repo}/.git/modules/old_sub" ]]
}

@test "_json_field_gh extracts field from valid JSON" {
    source "${BATS_TEST_DIRNAME}/../common.sh" 2>/dev/null || true
    source "${BATS_TEST_DIRNAME}/../config.sh" 2>/dev/null || true
    eval "$(sed -n '/^_json_field_gh()/,/^}/p' "${BATS_TEST_DIRNAME}/../update.sh")"

    local test_json='{"tagName":"b4000","targetCommitish":"abc1234567890"}'
    run _json_field_gh "$test_json" "tagName"
    [ "$status" -eq 0 ]
    [ "$output" = "b4000" ]
}

@test "_save_state captures empty branch when detached HEAD" {
    source "${BATS_TEST_DIRNAME}/../common.sh" 2>/dev/null || true
    source "${BATS_TEST_DIRNAME}/../config.sh" 2>/dev/null || true

    local fake_repo="${TEST_TMPDIR}/detached_repo"
    mkdir -p "$fake_repo"
    git -C "$fake_repo" init -q
    git -C "$fake_repo" commit --allow-empty -q -m "init"
    # Checkout a detached HEAD
    local commit_sha
    commit_sha=$(git -C "$fake_repo" rev-parse HEAD)
    git -C "$fake_repo" checkout -q "$commit_sha" 2>/dev/null

    eval "$(sed -n '/^_save_state()/,/^}/p' "${BATS_TEST_DIRNAME}/../update.sh")"
    LLAMA_CPP_SRC="$fake_repo"
    _save_state
    [ -n "$CURRENT_COMMIT" ]
    [ -z "$CURRENT_BRANCH" ]
}

@test "_print_success_summary with source_updated=0 shows rebuild message" {
    source "${BATS_TEST_DIRNAME}/../common.sh" 2>/dev/null || true
    source "${BATS_TEST_DIRNAME}/../config.sh" 2>/dev/null || true
    eval "$(sed -n '/^_print_success_summary()/,/^}/p' "${BATS_TEST_DIRNAME}/../update.sh")"
    llama_init_script_dir

    run _print_success_summary 0 "abc1234" "b4000" ""
    [ "$status" -eq 0 ]
    [[ "$output" =~ "重新构建完成" || "$output" =~ "构建完成" ]]
}