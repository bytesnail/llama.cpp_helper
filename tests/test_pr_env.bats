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

@test "_require_repo accepts a git worktree checkout (.git is a file)" {
    # 回归：worktree 检出的 .git 是文件而非目录，目录判据会把合法仓库
    # 误报为"不是 Git 仓库"；rev-parse --git-dir 对两种形态都成立
    _load_pr_env
    local main_repo="${TEST_TMPDIR}/wt-main"
    local wt="${TEST_TMPDIR}/wt-checkout"
    mkdir -p "$main_repo"
    _init_git_repo "$main_repo"
    git -C "$main_repo" worktree add -q "$wt"
    [[ -f "$wt/.git" ]]  # 前置：worktree 的 .git 确为文件
    pr_src="$wt"
    run _require_repo
    [ "$status" -eq 0 ]
}

@test "update refuses --src pointing at the main source tree" {
    # 回归：--src 指向主源码树（LLAMA_CPP_SRC，测试夹具已 export）时，
    # update 会把主环境切到 PR head 且绕过主环境锁（PR 独立锁文件）——
    # 必须显式拒绝
    run bash "${BATS_TEST_DIRNAME}/../pr_env.sh" update 29625 --src "$LLAMA_CPP_SRC"
    [ "$status" -ne 0 ]
    [[ "$output" == *"不能指向主源码树"* ]]
}

@test "_require_distinct_from_main_env rejects literal and trailing-slash forms" {
    _load_pr_env
    pr_src="/opt/tools/llama.cpp"
    LLAMA_CPP_SRC="/opt/tools/llama.cpp"
    run _require_distinct_from_main_env
    [ "$status" -ne 0 ]
    # 尾随斜杠/symlink 形态经 realpath 归一化后同样拦截
    pr_src="/opt/tools/llama.cpp/"
    run _require_distinct_from_main_env
    [ "$status" -ne 0 ]
    # 默认隔离目录不误伤
    pr_src="/opt/tools/llama.cpp-pr29625"
    run _require_distinct_from_main_env
    [ "$status" -eq 0 ]
}

@test "network git calls in pr_env.sh carry the low-speed guard" {
    # 契约（同 update.sh 的 C3 行级形态）：网络型 git 调用（clone/fetch）
    # 必须经 _pr_git_net 携带 config.sh 的低速保护——对端半挂起时中止传输，
    # 否则数百 MB 的 clone 会无限期挂起前台终端。已知豁免：非网络调用
    #（remote set-url / rev-parse / checkout / status / worktree 判定）。
    local violations
    violations=$(grep -vE '^[[:space:]]*#' "${BATS_TEST_DIRNAME}/../pr_env.sh" \
        | sed 's/[[:space:]]#.*$//' \
        | grep -nE 'git[[:space:]]+(clone|fetch)' \
        | grep -v '_pr_git_net' || true)
    if [ -n "$violations" ]; then
        printf 'unguarded network git invocation(s):\n%s\n' "$violations"
    fi
    [ -z "$violations" ]
}

@test "_create_resume_hint prints resume and retry guidance" {
    _load_pr_env
    pr_src="/tmp/pr-env-x"
    pr_number="29625"
    run _create_resume_hint
    [ "$status" -eq 0 ]
    [[ "$output" == *"update 29625"* ]]
}
