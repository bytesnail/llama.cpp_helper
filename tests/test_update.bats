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
    # Script exits with non-zero after _check_local_repo failure,
    # but the extra argument warning fires before that — sufficient for test coverage
    [ "$status" -ne 0 ]
}

@test "update.sh reports version switch failure on non-existent target" {
    # Create a fake llama.cpp repo to pass _check_local_repo
    local fake_repo="${TEST_TMPDIR}/llama.cpp"
    mkdir -p "${fake_repo}"
    git -C "${fake_repo}" init -q
    git -C "${fake_repo}" commit --allow-empty -q -m "init"
    git -C "${fake_repo}" remote add origin "file:///tmp/nonexistent-git-repo-$$"

    # Sync origin URL to match REPO_URL check (remote mismatch only warns, doesn't fail)

    # Use a non-existent tag so git checkout fails inside _update_source
    LLAMA_CPP_SRC="${fake_repo}" run timeout 10 bash "${BATS_TEST_DIRNAME}/../update.sh" nonexistent_tag_xyz 2>&1 || true
    # The script should report failure (non-zero exit) or a version error message
    # git fetch will quickly fail with the fake file:// remote
    [[ "$output" =~ "版本切换失败" || "$output" =~ "本地找不到目标版本" || "$output" =~ "拉取失败" || "$status" -ne 0 ]]
}

@test "_save_state sets current_branch after sourcing" {
    # Create a fake llama.cpp repo on a branch
    local fake_repo="${TEST_TMPDIR}/llama.cpp"
    mkdir -p "${fake_repo}"
    git -C "${fake_repo}" init -q
    git -C "${fake_repo}" commit --allow-empty -q -m "init"
    git -C "${fake_repo}" checkout -q -b test-branch

    # Source update.sh in test-only mode to load _save_state
    _LLAMA_SOURCE_ONLY=1 source "${BATS_TEST_DIRNAME}/../update.sh"
    LLAMA_CPP_SRC="${fake_repo}"
    current_commit=""; current_short=""; current_tag=""; current_branch=""
    _save_state
    [ "$current_branch" = "test-branch" ]
}

@test "_print_success_summary outputs expected format" {
    _LLAMA_SOURCE_ONLY=1 source "${BATS_TEST_DIRNAME}/../update.sh"

    # llama_print_run_examples needs SCRIPT_DIR
    llama_init_script_dir

    current_short="abc1234"
    release_tag="b4000"
    current_tag="(旧标签)"
    run _print_success_summary 1 "旧版" "b4000" "2026-01-01"
    [ "$status" -eq 0 ]
    [[ "$output" == *"abc1234"* || "$output" == *"旧版"* ]]
    [[ "$output" == *"b4000"* ]]
}

@test "_cleanup_stale_submodules handles no stale entries cleanly" {
    _LLAMA_SOURCE_ONLY=1 source "${BATS_TEST_DIRNAME}/../update.sh"

    # Create a minimal git repo with a .gitmodules file (no stale entries)
    local fake_repo="${TEST_TMPDIR}/clean_repo"
    mkdir -p "$fake_repo"
    git -C "$fake_repo" init -q
    git -C "$fake_repo" commit --allow-empty -q -m "init"
    # Create a valid submodule entry to make find not prune everything
    mkdir -p "${fake_repo}/sub"
    touch "${fake_repo}/sub/.git"  # regular file, not gitdir ref — won't match grep
    git -C "$fake_repo" add sub/.git 2>/dev/null || true

    LLAMA_CPP_SRC="$fake_repo" run _cleanup_stale_submodules
    [ "$status" -eq 0 ]
    # No stale entries means no cleanup output message
    [[ "$output" != *"清理旧子模块"* ]]
}


@test "_cleanup_stale_submodules removes stale submodule with gitdir ref" {
    _LLAMA_SOURCE_ONLY=1 source "${BATS_TEST_DIRNAME}/../update.sh"

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

@test "_json_field extracts field from valid JSON" {
    _LLAMA_SOURCE_ONLY=1 source "${BATS_TEST_DIRNAME}/../update.sh"

    local test_json='{"tagName":"b4000","targetCommitish":"abc1234567890"}'
    run _json_field "tagName" <<< "$test_json"
    [ "$status" -eq 0 ]
    [ "$output" = "b4000" ]
}

@test "_save_state captures empty branch when detached HEAD" {
    _LLAMA_SOURCE_ONLY=1 source "${BATS_TEST_DIRNAME}/../update.sh"

    local fake_repo="${TEST_TMPDIR}/detached_repo"
    mkdir -p "$fake_repo"
    git -C "$fake_repo" init -q
    git -C "$fake_repo" commit --allow-empty -q -m "init"
    # Checkout a detached HEAD
    local commit_sha
    commit_sha=$(git -C "$fake_repo" rev-parse HEAD)
    git -C "$fake_repo" checkout -q "$commit_sha" 2>/dev/null

    LLAMA_CPP_SRC="$fake_repo"
    _save_state
    [ -n "$current_commit" ]
    [ -z "$current_branch" ]
}

@test "_print_success_summary with source_updated=0 shows rebuild message" {
    _LLAMA_SOURCE_ONLY=1 source "${BATS_TEST_DIRNAME}/../update.sh"
    llama_init_script_dir

    run _print_success_summary 0 "abc1234" "b4000" ""
    [ "$status" -eq 0 ]
    [[ "$output" =~ "重新构建完成" || "$output" =~ "构建完成" ]]
}

@test "_rollback restores previous commit with fake repo" {
    _LLAMA_SOURCE_ONLY=1 source "${BATS_TEST_DIRNAME}/../update.sh"

    local fake_repo="${TEST_TMPDIR}/rollback_test"
    mkdir -p "$fake_repo"
    git -C "$fake_repo" init -q
    git -C "$fake_repo" commit --allow-empty -q -m "first"
    local first_commit
    first_commit=$(git -C "$fake_repo" rev-parse HEAD)
    git -C "$fake_repo" commit --allow-empty -q -m "second"
    local second_commit
    second_commit=$(git -C "$fake_repo" rev-parse HEAD)

    LLAMA_CPP_SRC="$fake_repo"
    current_commit="$first_commit"
    current_short=$(git -C "$fake_repo" rev-parse --short "$first_commit")

    run _rollback
    [ "$status" -eq 0 ]
    [[ "$output" =~ "已回滚到" ]]

    # Verify HEAD was restored to first commit
    local restored_head
    restored_head=$(git -C "$fake_repo" rev-parse HEAD)
    [ "$restored_head" = "$first_commit" ]
}

# --- No-argument behavior ---
@test "update.sh without args shows error when repo missing (not just banner)" {
    # This test verifies that the script doesn't silently exit after the banner
    # (regression test for set -u crash in conda activation)
    run bash "${BATS_TEST_DIRNAME}/../update.sh"
    # Should exit non-zero
    [ "$status" -ne 0 ]
    # Should show the banner
    [[ "$output" =~ "llama.cpp 一键更新脚本" ]]
    # Should show more than just the banner (error messages or progress)
    # If the bug were present, only the banner would appear before silent exit
    [[ "$output" =~ "检查前置条件" || "$output" =~ "不存在" || "$output" =~ "ERROR" || "$output" =~ "失败" ]]
}

# --- _resolve_target 单元测试 ---

@test "_resolve_target: user-specified target version (full commit SHA)" {
    _LLAMA_SOURCE_ONLY=1 source "${BATS_TEST_DIRNAME}/../update.sh"

    local fake_repo="${TEST_TMPDIR}/llama.cpp"
    local full_sha
    full_sha=$(git -C "$fake_repo" rev-parse HEAD)

    # 模拟用户传入 40 字符的 commit SHA
    target_version="$full_sha"
    release_tag=""; release_commit=""; release_short=""
    current_commit=""; current_tag=""; current_short=""
    need_source_update=0; skip_update=0

    _resolve_target
    # target_version 是完整 SHA → release_commit 应被设置
    [ "$release_commit" = "$full_sha" ]
    [ "$release_tag" = "$full_sha" ]
    [ "$release_short" = "${full_sha:0:7}" ]
}

@test "_resolve_target: user-specified target version (tag name)" {
    _LLAMA_SOURCE_ONLY=1 source "${BATS_TEST_DIRNAME}/../update.sh"

    local fake_repo="${TEST_TMPDIR}/llama.cpp"
    git -C "$fake_repo" tag b4000 HEAD

    # 模拟用户传入标签名（非 40 字符 SHA）
    target_version="b4000"
    release_tag=""; release_commit=""; release_short=""
    current_commit=""; current_tag=""; current_short=""
    need_source_update=0; skip_update=0

    _resolve_target
    # 非完整 SHA → release_tag 被设置，release_commit 不被设置
    [ "$release_tag" = "b4000" ]
    [ -z "$release_commit" ]
}

@test "_resolve_target: already on target tag → skip" {
    _LLAMA_SOURCE_ONLY=1 source "${BATS_TEST_DIRNAME}/../update.sh"

    local fake_repo="${TEST_TMPDIR}/llama.cpp"
    git -C "$fake_repo" tag b4000 HEAD
    local head_sha
    head_sha=$(git -C "$fake_repo" rev-parse HEAD)

    # 当前和目标都是 b4000
    target_version="b4000"
    release_tag="b4000"; release_commit="$head_sha"; release_short="${head_sha:0:7}"
    current_commit="$head_sha"; current_tag="b4000"; current_short="${head_sha:0:7}"
    need_source_update=0; skip_update=0

    _resolve_target
    [ "$need_source_update" -eq 0 ]
}

@test "_resolve_target: different version → need update" {
    _LLAMA_SOURCE_ONLY=1 source "${BATS_TEST_DIRNAME}/../update.sh"

    local fake_repo="${TEST_TMPDIR}/llama.cpp"
    git -C "$fake_repo" tag b4000 HEAD
    local head_sha
    head_sha=$(git -C "$fake_repo" rev-parse HEAD)

    # 当前是 b3000，目标是 b4000
    target_version="b4000"
    release_tag="b4000"; release_commit=""; release_short="unknown"
    current_commit="abc123def456789abc123def456789abc123def4"; current_tag="b3000"; current_short="abc123d"
    need_source_update=0; skip_update=0

    _resolve_target
    [ "$need_source_update" -eq 1 ]
}

@test "_resolve_target: release_short derivation from 40-char commit" {
    _LLAMA_SOURCE_ONLY=1 source "${BATS_TEST_DIRNAME}/../update.sh"

    local fake_repo="${TEST_TMPDIR}/llama.cpp"
    local full_sha
    full_sha=$(git -C "$fake_repo" rev-parse HEAD)
    git -C "$fake_repo" tag b4000 HEAD

    # 用户指定标签（非 SHA），但预填充 release_commit 测试 release_short 推导
    target_version="b4000"
    release_tag="b4000"; release_commit="$full_sha"; release_short=""
    current_commit="someother"; current_tag="b3000"; current_short=""
    need_source_update=0; skip_update=0

    _resolve_target
    # 40 字符 SHA → release_short 应为前 7 位
    [ "$release_short" = "${full_sha:0:7}" ]
}

# --- _fetch_latest_release_gh / _fetch_latest_release_curl mock 测试 ---

@test "_fetch_latest_release_gh parses gh JSON output correctly" {
    local mock_dir inner
    mock_dir=$(mktemp -d)
    cat > "${mock_dir}/gh" << 'MOCK_EOF'
#!/bin/bash
printf '%s' '{"tagName":"b4000","targetCommitish":"abc1234567890abcdef1234567890abcdef12","publishedAt":"2026-01-15T10:30:00Z","url":"https://github.com/ggml-org/llama.cpp/releases/tag/b4000"}'
MOCK_EOF
    chmod +x "${mock_dir}/gh"

    # 将测试脚本写入文件：变量部分用 echo 展开字面部分用引用 heredoc
    inner="${mock_dir}/test_inner.sh"
    {
        echo "#!/bin/bash"
        echo "_LLAMA_SOURCE_ONLY=1 source '${BATS_TEST_DIRNAME}/../update.sh'"
        echo "PATH='${mock_dir}:$PATH'"
        cat << 'INNER_EOF'
release_tag=""; release_commit=""; release_date=""; release_url=""
_fetch_latest_release_gh
echo "tag=$release_tag"
echo "commit=$release_commit"
echo "date=$release_date"
echo "url=$release_url"
INNER_EOF
    } > "$inner"

    run bash "$inner"
    [ "$status" -eq 0 ]
    [[ "$output" == *"tag=b4000"* ]]
    [[ "$output" == *"commit=abc1234567890abcdef1234567890abcdef12"* ]]
    [[ "$output" == *"date=2026-01-15T10:30:00Z"* ]]
    [[ "$output" == *"url=https://github.com/ggml-org/llama.cpp/releases/tag/b4000"* ]]

    rm -rf "${mock_dir}"
}

@test "_fetch_latest_release_curl parses curl JSON response correctly" {
    local mock_dir inner
    mock_dir=$(mktemp -d)
    # mock curl: 解析 -o 参数写入 mock JSON，输出 HTTP 200
    cat > "${mock_dir}/curl" << 'MOCK_EOF'
#!/bin/bash
tmp_file=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        -o) tmp_file="$2"; shift 2 ;;
        -w) shift 2 ;;
        -H) shift 2 ;;
        --*) shift ;;
        *) shift ;;
    esac
done
printf '%s' '{"tag_name":"b4001","target_commitish":"def9876543210abcdef9876543210abcdef98","published_at":"2026-02-20T08:00:00Z","html_url":"https://github.com/ggml-org/llama.cpp/releases/tag/b4001"}' > "$tmp_file"
echo "200"
MOCK_EOF
    chmod +x "${mock_dir}/curl"

    inner="${mock_dir}/test_inner.sh"
    {
        echo "#!/bin/bash"
        echo "_LLAMA_SOURCE_ONLY=1 source '${BATS_TEST_DIRNAME}/../update.sh'"
        echo "PATH='${mock_dir}:$PATH'"
        cat << 'INNER_EOF'
release_tag=""; release_commit=""; release_date=""; release_url=""
_fetch_latest_release_curl
echo "tag=$release_tag"
echo "commit=$release_commit"
echo "date=$release_date"
echo "url=$release_url"
INNER_EOF
    } > "$inner"

    run bash "$inner"
    [ "$status" -eq 0 ]
    [[ "$output" == *"tag=b4001"* ]]
    [[ "$output" == *"commit=def9876543210abcdef9876543210abcdef98"* ]]
    [[ "$output" == *"date=2026-02-20T08:00:00Z"* ]]
    [[ "$output" == *"url=https://github.com/ggml-org/llama.cpp/releases/tag/b4001"* ]]

    # 验证 RETURN trap 清理了临时文件
    ! ls "${TMPDIR:-/tmp}/llama_release."*.json 2>/dev/null

    rm -rf "${mock_dir}"
}

@test "_fetch_latest_release_curl returns 1 on HTTP failure" {
    local mock_dir inner
    mock_dir=$(mktemp -d)
    # mock curl: 输出 HTTP 403
    cat > "${mock_dir}/curl" << 'MOCK_EOF'
#!/bin/bash
tmp_file=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        -o) tmp_file="$2"; shift 2 ;;
        -w) shift 2 ;;
        -H) shift 2 ;;
        --*) shift ;;
        *) shift ;;
    esac
done
echo '{"message":"Forbidden"}' > "$tmp_file"
echo "403"
MOCK_EOF
    chmod +x "${mock_dir}/curl"

    inner="${mock_dir}/test_inner.sh"
    {
        echo "#!/bin/bash"
        echo "_LLAMA_SOURCE_ONLY=1 source '${BATS_TEST_DIRNAME}/../update.sh'"
        echo "PATH='${mock_dir}:$PATH'"
        cat << 'INNER_EOF'
_fetch_latest_release_curl 2>&1
INNER_EOF
    } > "$inner"

    run bash "$inner"
    [ "$status" -eq 1 ]
    [[ "$output" == *"HTTP 403"* ]]

    rm -rf "${mock_dir}"
}

@test "_fetch_latest_release_curl returns 1 on invalid JSON" {
    local mock_dir inner
    mock_dir=$(mktemp -d)
    # mock curl: HTTP 200 但返回无效 JSON
    cat > "${mock_dir}/curl" << 'MOCK_EOF'
#!/bin/bash
tmp_file=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        -o) tmp_file="$2"; shift 2 ;;
        -w) shift 2 ;;
        -H) shift 2 ;;
        --*) shift ;;
        *) shift ;;
    esac
done
echo 'this is not json at all' > "$tmp_file"
echo "200"
MOCK_EOF
    chmod +x "${mock_dir}/curl"

    inner="${mock_dir}/test_inner.sh"
    {
        echo "#!/bin/bash"
        echo "_LLAMA_SOURCE_ONLY=1 source '${BATS_TEST_DIRNAME}/../update.sh'"
        echo "PATH='${mock_dir}:$PATH'"
        cat << 'INNER_EOF'
_fetch_latest_release_curl 2>&1
INNER_EOF
    } > "$inner"

    run bash "$inner"
    [ "$status" -eq 1 ]

    rm -rf "${mock_dir}"
}
