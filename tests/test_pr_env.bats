#!/usr/bin/env bats
# ============================================================
# test_pr_env.bats — pr_env.sh 的 CLI 与纯函数契约测试
# 不触网、不执行真实构建：网络拉取与真实构建属于端到端行为，
# 由人工验证覆盖；此处只钉住参数解析、路径派生与前置拒绝逻辑。
# ============================================================

load test_helper

setup() {
    _setup_tmpdir
    _load_pr_env
}

teardown() {
    _teardown_tmpdir
}

@test "pr_env.sh --help lists create, update and build subcommands" {
    run bash "${BATS_TEST_DIRNAME}/../pr_env.sh" --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"create"* ]]
    [[ "$output" == *"update"* ]]
    [[ "$output" == *"build"* ]]
}

@test "pr_env.sh --version prints helper version" {
    run bash "${BATS_TEST_DIRNAME}/../pr_env.sh" --version
    [ "$status" -eq 0 ]
    [[ "$output" == *"llama.cpp_helper"* ]]
}

@test "pr_env.sh rejects missing subcommand" {
    run bash "${BATS_TEST_DIRNAME}/../pr_env.sh"
    [ "$status" -ne 0 ]
    [[ "$output" == *"子命令"* ]]
}

@test "pr_env.sh rejects non-numeric PR number" {
    run bash "${BATS_TEST_DIRNAME}/../pr_env.sh" build abc
    [ "$status" -ne 0 ]
    [[ "$output" == *"PR"* ]]
}

@test "pr_env.sh rejects zero as PR number" {
    run bash "${BATS_TEST_DIRNAME}/../pr_env.sh" build 0
    [ "$status" -ne 0 ]
}

@test "_default_pr_src derives sibling directory of LLAMA_CPP_SRC" {
    LLAMA_CPP_SRC="/opt/tools/llama.cpp"
    run _default_pr_src 29625
    [ "$status" -eq 0 ]
    [ "$output" = "/opt/tools/llama.cpp-pr29625" ]
}

@test "_pr_branch formats the PR head branch name" {
    run _pr_branch 29625
    [ "$status" -eq 0 ]
    [ "$output" = "pr-29625" ]
}

@test "_pr_lock_file is isolated per PR number" {
    XDG_RUNTIME_DIR="${TEST_TMPDIR}/run"
    run _pr_lock_file 29625
    [ "$status" -eq 0 ]
    [ "$output" = "${XDG_RUNTIME_DIR}/llama_cpp_helper-pr29625-${UID}.lock" ]
}

@test "_parse_args accepts build with --src and --incremental" {
    _parse_args build 29625 --src /tmp/pr-src -i
    [ "$pr_command" = "build" ]
    [ "$pr_number" = "29625" ]
    [ "$pr_src" = "/tmp/pr-src" ]
    [ "$pr_incremental" -eq 1 ]
}

@test "_parse_args rejects --incremental for create" {
    run _parse_args create 29625 --src /tmp/pr-src -i
    [ "$status" -ne 0 ]
}

@test "create refuses an existing non-empty source directory" {
    local src="${TEST_TMPDIR}/existing"
    mkdir -p "$src"
    touch "$src/file"
    run bash "${BATS_TEST_DIRNAME}/../pr_env.sh" create 29625 --src "$src"
    [ "$status" -ne 0 ]
    [[ "$output" == *"已存在"* ]]
}

@test "update refuses a non-git source directory" {
    local src="${TEST_TMPDIR}/not-a-repo"
    mkdir -p "$src"
    run bash "${BATS_TEST_DIRNAME}/../pr_env.sh" update 29625 --src "$src"
    [ "$status" -ne 0 ]
    [[ "$output" == *"Git 仓库"* ]]
}

@test "update refuses a dirty git repository before fetching" {
    local src="${TEST_TMPDIR}/dirty-repo"
    mkdir -p "$src"
    _init_git_repo "$src"
    echo "tracked" > "$src/tracked.txt"
    git -C "$src" add tracked.txt
    git -C "$src" commit -q -m "add tracked"
    echo "dirty" >> "$src/tracked.txt"
    run bash "${BATS_TEST_DIRNAME}/../pr_env.sh" update 29625 --src "$src"
    [ "$status" -ne 0 ]
    [[ "$output" == *"未提交"* ]]
}
