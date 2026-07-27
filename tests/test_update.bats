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
    # test_helper 已在 LLAMA_CPP_SRC 建好最小 git 仓库（含 identity 与初始 commit）
    local fake_repo="${TEST_TMPDIR}/llama.cpp"
    git -C "${fake_repo}" remote add origin "file:///tmp/nonexistent-git-repo-$$"

    # Sync origin URL to match REPO_URL check (remote mismatch only warns, doesn't fail)

    # Use a non-existent tag so git checkout fails inside _update_source
    LLAMA_CPP_SRC="${fake_repo}" run timeout 10 bash "${BATS_TEST_DIRNAME}/../update.sh" nonexistent_tag_xyz 2>&1 || true
    # The script should report failure (non-zero exit) or a version error message
    # git fetch will quickly fail with the fake file:// remote
    [[ "$output" =~ "版本切换失败" || "$output" =~ "本地找不到目标版本" || "$output" =~ "拉取失败" || "$status" -ne 0 ]]
}

@test "_session_capture_current sets current_branch after sourcing" {
    # test_helper 已在 LLAMA_CPP_SRC 建好最小 git 仓库
    local fake_repo="${TEST_TMPDIR}/llama.cpp"
    git -C "${fake_repo}" checkout -q -b test-branch

    # Source update.sh in test-only mode to load _session_capture_current
    _LLAMA_SOURCE_ONLY=1 source "${BATS_TEST_DIRNAME}/../update.sh"
    LLAMA_CPP_SRC="${fake_repo}"
    _session_capture_current
    [ "$current_branch" = "test-branch" ]
}

@test "_print_success_summary outputs expected format" {
    _LLAMA_SOURCE_ONLY=1 source "${BATS_TEST_DIRNAME}/../update.sh"

    # SCRIPT_DIR 已由 update.sh 顶层设置（readonly），llama_print_run_examples 直接使用

    run _print_success_summary 1 "旧版" "b4000" "2026-01-01"
    [ "$status" -eq 0 ]
    [[ "$output" == *"旧版"* ]]
    [[ "$output" == *"b4000"* ]]
}

@test "_cleanup_stale_submodules handles no stale entries cleanly" {
    _LLAMA_SOURCE_ONLY=1 source "${BATS_TEST_DIRNAME}/../update.sh"

    # Create a minimal git repo with a .gitmodules file (no stale entries)
    local fake_repo="${TEST_TMPDIR}/clean_repo"
    mkdir -p "$fake_repo"
    _init_git_repo "$fake_repo"
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
    _init_git_repo "$fake_repo"

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

@test "_cleanup_stale_submodules spares untracked git worktrees" {
    _LLAMA_SOURCE_ONLY=1 source "${BATS_TEST_DIRNAME}/../update.sh"

    # 树内未跟踪 worktree：.git 文件的 gitdir 指向 .git/worktrees/，
    # 不是子模块残留——预检查（--untracked-files=no）显式放行的
    # 未跟踪内容，清理不得删除（此前被误判为残留 rm -rf，已实证）
    local fake_repo="${TEST_TMPDIR}/wt_repo"
    mkdir -p "$fake_repo"
    _init_git_repo "$fake_repo"
    git -C "$fake_repo" worktree add -q "${fake_repo}/user_work" 2>/dev/null
    echo "uncommitted work" > "${fake_repo}/user_work/important.txt"

    LLAMA_CPP_SRC="$fake_repo" run _cleanup_stale_submodules
    [ "$status" -eq 0 ]
    [[ "$output" != *"清理旧子模块"* ]]
    [[ -f "${fake_repo}/user_work/important.txt" ]]
}

@test "_cleanup_stale_submodules refuses to delete when git index unreadable" {
    _LLAMA_SOURCE_ONLY=1 source "${BATS_TEST_DIRNAME}/../update.sh"

    # 非 git 目录 + 伪造 gitdir 子模块：ls-files 失败时白名单构建必须
    # 失败并保守不删除（此前进程替换吞错→空白名单→全部误判为残留）
    local fake_repo="${TEST_TMPDIR}/not_a_repo"
    mkdir -p "${fake_repo}/sub"
    echo 'gitdir: ../.git/modules/sub' > "${fake_repo}/sub/.git"

    LLAMA_CPP_SRC="$fake_repo" run _cleanup_stale_submodules
    [ "$status" -eq 1 ]
    [[ "$output" =~ "保守不删除" ]]
    [[ -f "${fake_repo}/sub/.git" ]]
}

# --- C3：无 cwd 环境契约（所有 git 调用显式 -C）---

@test "_check_local_repo does not change the caller's working directory" {
    _LLAMA_SOURCE_ONLY=1 source "${BATS_TEST_DIRNAME}/../update.sh"

    local before_pwd="$PWD"
    LLAMA_CPP_SRC="${TEST_TMPDIR}/llama.cpp"
    _check_local_repo >/dev/null 2>&1
    [ "$PWD" = "$before_pwd" ]
}

@test "_check_local_repo rejects dirty submodule when main status ignores submodules" {
    _LLAMA_SOURCE_ONLY=1 source "${BATS_TEST_DIRNAME}/../update.sh"

    # 主 status 经 diff.ignoreSubmodules=all 放行时，foreach 守卫是唯一防线。
    # 回归：git submodule foreach 恒用 /bin/sh（Debian/Ubuntu 为 dash）执行
    # 内层脚本——bashism `(( rc1 > 1 ))` 被 dash 解析为嵌套子 shell + 重定向
    # `> 1`，两条件恒假、守卫静默失效，并遗留名为 1 的垃圾文件（已实证）。
    local sub_repo="${TEST_TMPDIR}/sub_src"
    local fake_repo="${TEST_TMPDIR}/super_repo"
    mkdir -p "$sub_repo"
    _init_git_repo "$sub_repo"
    echo tracked > "$sub_repo/tracked.txt"
    git -C "$sub_repo" add tracked.txt
    git -C "$sub_repo" commit -q -m tracked
    mkdir -p "$fake_repo"
    _init_git_repo "$fake_repo"
    git -C "$fake_repo" -c protocol.file.allow=always submodule add -q "$sub_repo" sub
    git -C "$fake_repo" commit -q -m add-sub
    git -C "$fake_repo" config diff.ignoreSubmodules all
    echo modified >> "$fake_repo/sub/tracked.txt"

    LLAMA_CPP_SRC="$fake_repo" run _check_local_repo
    [ "$status" -ne 0 ]
    [[ "$output" =~ "子模块中存在未提交的更改" ]]
    # 垃圾文件断言：dash 把 `(( rc1 > 1 ...` 解析为重定向 `> 1` 的历史 bug
    [[ ! -e "$fake_repo/sub/1" ]]
}

@test "_update_source works from an unrelated cwd (git -C everywhere)" {
    _LLAMA_SOURCE_ONLY=1 source "${BATS_TEST_DIRNAME}/../update.sh"

    # 源仓库：含本地标签 b4000；origin 指向本地 bare 克隆（离线可 fetch）
    local fake_repo="${TEST_TMPDIR}/src_repo"
    local origin_repo="${TEST_TMPDIR}/origin.git"
    mkdir -p "$fake_repo"
    _init_git_repo "$fake_repo"
    git -C "$fake_repo" tag b4000
    git clone -q --bare "$fake_repo" "$origin_repo"
    git -C "$fake_repo" remote add origin "$origin_repo"

    # 关键：在「非 git 仓库」目录中调用——若实现依赖 cwd 解析仓库，
    # git fetch 会立即以 not a git repository 失败
    cd "${TEST_TMPDIR}"
    LLAMA_CPP_SRC="$fake_repo"
    # 经具名入口设置会话状态（C4），不再直接戳全局
    _session_capture_current
    _session_set_target "b4000" ""

    run _update_source
    [ "$status" -eq 0 ]
    [[ "$output" =~ "源码已更新到 b4000" ]]
}

@test "_update_source accepts a short commit SHA (7-40 hex)" {
    _LLAMA_SOURCE_ONLY=1 source "${BATS_TEST_DIRNAME}/../update.sh"

    # 短 SHA（非 tag、非 40 位）此前被 llama_is_full_commit_sha 挡在
    # 通用 rev 解析之外，die"本地找不到目标版本"——与 help 文案
    # "更新到指定 commit"不符
    local fake_repo="${TEST_TMPDIR}/src_repo"
    local origin_repo="${TEST_TMPDIR}/origin.git"
    mkdir -p "$fake_repo"
    _init_git_repo "$fake_repo"
    git -C "$fake_repo" commit --allow-empty -q -m "second"
    local short_sha target_sha
    short_sha=$(git -C "$fake_repo" rev-parse --short=7 HEAD)
    target_sha=$(git -C "$fake_repo" rev-parse HEAD)
    git clone -q --bare "$fake_repo" "$origin_repo"
    git -C "$fake_repo" remote add origin "$origin_repo"
    # 回到首个 commit，使短 SHA 目标确实需要切换
    git -C "$fake_repo" checkout -q HEAD~1

    LLAMA_CPP_SRC="$fake_repo"
    _session_capture_current
    _session_set_target "$short_sha" ""

    run _update_source
    [ "$status" -eq 0 ]
    [[ "$output" =~ "源码已更新到 ${short_sha}" ]]
    [ "$(git -C "$fake_repo" rev-parse HEAD)" = "$target_sha" ]
}

@test "_session_capture_current captures empty branch when detached HEAD" {
    _LLAMA_SOURCE_ONLY=1 source "${BATS_TEST_DIRNAME}/../update.sh"

    local fake_repo="${TEST_TMPDIR}/detached_repo"
    mkdir -p "$fake_repo"
    _init_git_repo "$fake_repo"
    # Checkout a detached HEAD
    local commit_sha
    commit_sha=$(git -C "$fake_repo" rev-parse HEAD)
    git -C "$fake_repo" checkout -q "$commit_sha" 2>/dev/null

    LLAMA_CPP_SRC="$fake_repo"
    _session_capture_current
    [ -n "$current_commit" ]
    [ -z "$current_branch" ]
}

@test "_print_success_summary with source_updated=0 shows rebuild message" {
    _LLAMA_SOURCE_ONLY=1 source "${BATS_TEST_DIRNAME}/../update.sh"
    # SCRIPT_DIR 已由 update.sh 顶层设置（readonly）

    run _print_success_summary 0 "abc1234" "b4000" ""
    [ "$status" -eq 0 ]
    [[ "$output" =~ "重新构建完成" || "$output" =~ "构建完成" ]]
}

@test "_rollback restores previous commit with fake repo" {
    _LLAMA_SOURCE_ONLY=1 source "${BATS_TEST_DIRNAME}/../update.sh"

    local fake_repo="${TEST_TMPDIR}/rollback_test"
    mkdir -p "$fake_repo"
    _init_git_repo "$fake_repo"
    local first_commit
    first_commit=$(git -C "$fake_repo" rev-parse HEAD)
    git -C "$fake_repo" commit --allow-empty -q -m "second"
    local second_commit
    second_commit=$(git -C "$fake_repo" rev-parse HEAD)

    LLAMA_CPP_SRC="$fake_repo"
    # 直接赋值 current_commit 模拟「已捕获」状态（HEAD 已在第二 commit，
    # 不能调 _session_capture_current——它会把 HEAD 捕获成新版本）
    current_commit="$first_commit"

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
    # mock 网络层（gh/curl 必失败），避免真实访问 GitHub API：
    # 在线时消耗 API 限额，离线时按 CURL_MAX_TIME 阻塞最长 30 秒
    local mock_dir="${TEST_TMPDIR}/net_mock"
    mkdir -p "$mock_dir"
    _make_stub_exec "${mock_dir}/gh" "exit 1"
    _make_stub_exec "${mock_dir}/curl" "exit 1"
    PATH="${mock_dir}:$PATH" run bash "${BATS_TEST_DIRNAME}/../update.sh"
    # Should exit non-zero
    [ "$status" -ne 0 ]
    # Should show the banner
    [[ "$output" =~ "llama.cpp 一键更新脚本" ]]
    # Should show more than just the banner (error messages or progress)
    # If the bug were present, only the banner would appear before silent exit
    [[ "$output" =~ "检查前置条件" || "$output" =~ "不存在" || "$output" =~ "ERROR" || "$output" =~ "失败" ]]
}

# --- _short_sha 派生函数（C4：derive-don't-store）---

@test "_short_sha prints first 7 chars of a full SHA" {
    _LLAMA_SOURCE_ONLY=1 source "${BATS_TEST_DIRNAME}/../update.sh"

    run _short_sha "abc1234567890abcdef1234567890abcdef12"
    [ "$status" -eq 0 ]
    [ "$output" = "abc1234" ]
}

@test "_short_sha returns empty string for empty input" {
    _LLAMA_SOURCE_ONLY=1 source "${BATS_TEST_DIRNAME}/../update.sh"

    run _short_sha ""
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "_short_sha returns short input unchanged" {
    _LLAMA_SOURCE_ONLY=1 source "${BATS_TEST_DIRNAME}/../update.sh"

    run _short_sha "abc"
    [ "$status" -eq 0 ]
    [ "$output" = "abc" ]
}

# --- 具名写入口（C4）---

@test "_session_set_target writes release_tag and release_date" {
    _LLAMA_SOURCE_ONLY=1 source "${BATS_TEST_DIRNAME}/../update.sh"

    _session_set_target "b4000" "2026-01-15T10:30:00Z"
    [ "$release_tag" = "b4000" ]
    [ "$release_date" = "2026-01-15T10:30:00Z" ]
    # date 可省略（用户指定版本路径无发布日期）
    _session_set_target "b4001"
    [ "$release_tag" = "b4001" ]
    [ -z "$release_date" ]
}

# --- _parse_args out-param（C4：target_version 参数化）---

@test "_parse_args writes target version via out-param" {
    _LLAMA_SOURCE_ONLY=1 source "${BATS_TEST_DIRNAME}/../update.sh"

    local target=""
    _parse_args target "b4000"
    [ "$target" = "b4000" ]
}

@test "_parse_args writes empty target when no args" {
    _LLAMA_SOURCE_ONLY=1 source "${BATS_TEST_DIRNAME}/../update.sh"

    local target="stale"
    _parse_args target
    [ -z "$target" ]
}

@test "_parse_args rejects invalid out-param names" {
    _LLAMA_SOURCE_ONLY=1 source "${BATS_TEST_DIRNAME}/../update.sh"

    # 保留前缀（函数内部局部变量命名空间）与非标识符名均拒绝（C1 防呆模式）
    run _parse_args "_pa_reserved" b4000
    [ "$status" -eq 2 ]
    run _parse_args "1bad-name" b4000
    [ "$status" -eq 2 ]
}

# --- _resolve_target 单元测试 ---

@test "_resolve_target: user-specified target version (full commit SHA)" {
    _LLAMA_SOURCE_ONLY=1 source "${BATS_TEST_DIRNAME}/../update.sh"

    local fake_repo="${TEST_TMPDIR}/llama.cpp"
    local full_sha
    full_sha=$(git -C "$fake_repo" rev-parse HEAD)

    # 网络层 stub（gh/curl 必失败）：保证任何情况下测试离线——
    # 若 _resolve_target 误走 fetch 路径（如参数被忽略），seam 双失败即 die
    local mock_dir="${TEST_TMPDIR}/mock"
    mkdir -p "$mock_dir"
    _make_stub_exec "${mock_dir}/gh" "exit 1"
    _make_stub_exec "${mock_dir}/curl" "exit 1"
    PATH="${mock_dir}:$PATH"

    # C4：目标版本经参数传入；重定向文件替代 bats run（run 在子 shell
    # 执行，函数内全局赋值对测试体不可见）
    _resolve_target "$full_sha" > "${TEST_TMPDIR}/out.txt"
    [ "$release_tag" = "$full_sha" ]
    # rel_commit 是局部变量，其可观测面是「对应 Commit」显示行
    grep -qF "${full_sha:0:7} (${full_sha})" "${TEST_TMPDIR}/out.txt"
}

@test "_resolve_target: user-specified target version (tag name)" {
    _LLAMA_SOURCE_ONLY=1 source "${BATS_TEST_DIRNAME}/../update.sh"

    local mock_dir="${TEST_TMPDIR}/mock"
    mkdir -p "$mock_dir"
    _make_stub_exec "${mock_dir}/gh" "exit 1"
    _make_stub_exec "${mock_dir}/curl" "exit 1"
    PATH="${mock_dir}:$PATH"

    _resolve_target b4000 > /dev/null
    [ "$release_tag" = "b4000" ]
}

@test "_resolve_target: already on target tag → no source update needed" {
    _LLAMA_SOURCE_ONLY=1 source "${BATS_TEST_DIRNAME}/../update.sh"

    local fake_repo="${TEST_TMPDIR}/llama.cpp"
    git -C "$fake_repo" tag b4000 HEAD

    local mock_dir="${TEST_TMPDIR}/mock"
    mkdir -p "$mock_dir"
    _make_stub_exec "${mock_dir}/gh" "exit 1"
    _make_stub_exec "${mock_dir}/curl" "exit 1"
    PATH="${mock_dir}:$PATH"

    # 经具名入口从 git 真实捕获（current_tag=b4000），不再手填全局
    _session_capture_current
    _resolve_target b4000 > /dev/null
    [ "$need_source_update" -eq 0 ]
}

@test "_resolve_target: different version → need update" {
    _LLAMA_SOURCE_ONLY=1 source "${BATS_TEST_DIRNAME}/../update.sh"

    local mock_dir="${TEST_TMPDIR}/mock"
    mkdir -p "$mock_dir"
    _make_stub_exec "${mock_dir}/gh" "exit 1"
    _make_stub_exec "${mock_dir}/curl" "exit 1"
    PATH="${mock_dir}:$PATH"

    _session_capture_current
    _resolve_target b4000 > /dev/null
    [ "$need_source_update" -eq 1 ]
}

@test "_resolve_target always writes both decision flags (reentrant)" {
    _LLAMA_SOURCE_ONLY=1 source "${BATS_TEST_DIRNAME}/../update.sh"

    local mock_dir="${TEST_TMPDIR}/mock"
    mkdir -p "$mock_dir"
    _make_stub_exec "${mock_dir}/gh" "exit 1"
    _make_stub_exec "${mock_dir}/curl" "exit 1"
    PATH="${mock_dir}:$PATH"

    # 预填陈旧决策：非 skip 路径必须显式重置 skip_update（旧实现只在
    # skip 路径写 1，靠顶部初始化保证 0——写入点收敛后由入口自己保证两态）
    skip_update=1
    _session_capture_current
    _resolve_target b4000 > /dev/null
    [ "$need_source_update" -eq 1 ]
    [ "$skip_update" -eq 0 ]
}

@test "_resolve_target: fetch path parses TAB line into release globals" {
    _LLAMA_SOURCE_ONLY=1 source "${BATS_TEST_DIRNAME}/../update.sh"

    # stub gh（auth 成功 + release view 输出 JSON），经 PATH 前置生效
    local mock_dir="${TEST_TMPDIR}/mock"
    mkdir -p "$mock_dir"
    cat > "${mock_dir}/gh" << 'MOCK_EOF'
#!/bin/bash
if [[ "$1" == "auth" ]]; then exit 0; fi
printf '%s' '{"tagName":"b4000","targetCommitish":"abc123def4567890abc123def4567890abc12345","publishedAt":"2026-01-15T10:30:00Z","url":"https://github.com/ggml-org/llama.cpp/releases/tag/b4000"}'
MOCK_EOF
    chmod +x "${mock_dir}/gh"
    PATH="${mock_dir}:$PATH"

    # 无参数 → 走 seam 查询路径；TAB 行分解进 release 全局
    local fake_repo="${TEST_TMPDIR}/llama.cpp"
    current_commit=$(git -C "$fake_repo" rev-parse HEAD)
    current_tag=""

    _resolve_target > "${TEST_TMPDIR}/out.txt"
    [ "$release_tag" = "b4000" ]
    [ "$release_date" = "2026-01-15T10:30:00Z" ]
    # rel_commit/rel_url 的可观测面：显示行（短 SHA 与发布页面）
    grep -qF "对应 Commit: abc123d (abc123def4567890abc123def4567890abc12345)" "${TEST_TMPDIR}/out.txt"
    grep -qF "发布页面:    https://github.com/ggml-org/llama.cpp/releases/tag/b4000" "${TEST_TMPDIR}/out.txt"
}

# --- _fetch_latest_release seam / adapter 测试（C5）---
# C5 后 adapter 经 stdout 返回 TAB 行（tag/commit/date/url），不再写全局；
# seam _fetch_latest_release 内藏 gh→curl 选择逻辑，stdout 契约只允许 TAB 行
# （选择日志走 stderr）。

@test "_fetch_latest_release_gh outputs TAB-separated release line" {
    local mock_dir inner
    mock_dir=$(mktemp -d)
    cat > "${mock_dir}/gh" << 'MOCK_EOF'
#!/bin/bash
printf '%s' '{"tagName":"b4000","targetCommitish":"abc1234567890abcdef1234567890abcdef12","publishedAt":"2026-01-15T10:30:00Z","url":"https://github.com/ggml-org/llama.cpp/releases/tag/b4000"}'
MOCK_EOF
    chmod +x "${mock_dir}/gh"

    inner="${mock_dir}/test_inner.sh"
    {
        echo "#!/bin/bash"
        echo "_LLAMA_SOURCE_ONLY=1 source '${BATS_TEST_DIRNAME}/../update.sh'"
        echo "PATH='${mock_dir}:$PATH'"
        echo '_fetch_latest_release_gh'
    } > "$inner"

    run bash "$inner"
    [ "$status" -eq 0 ]
    [ "$output" = "$(printf 'b4000\tabc1234567890abcdef1234567890abcdef12\t2026-01-15T10:30:00Z\thttps://github.com/ggml-org/llama.cpp/releases/tag/b4000')" ]

    rm -rf "${mock_dir}"
}

@test "_fetch_latest_release_gh writes no release_* globals" {
    local mock_dir inner
    mock_dir=$(mktemp -d)
    cat > "${mock_dir}/gh" << 'MOCK_EOF'
#!/bin/bash
printf '%s' '{"tagName":"b4000","targetCommitish":"abc1234567890abcdef1234567890abcdef12","publishedAt":"2026-01-15T10:30:00Z","url":"https://github.com/ggml-org/llama.cpp/releases/tag/b4000"}'
MOCK_EOF
    chmod +x "${mock_dir}/gh"

    inner="${mock_dir}/test_inner.sh"
    {
        echo "#!/bin/bash"
        echo "_LLAMA_SOURCE_ONLY=1 source '${BATS_TEST_DIRNAME}/../update.sh'"
        echo "PATH='${mock_dir}:$PATH'"
        cat << 'INNER_EOF'
release_tag=""; release_commit=""; release_date=""; release_url=""
_fetch_latest_release_gh >/dev/null
echo "tag=[${release_tag}]"
echo "commit=[${release_commit}]"
echo "date=[${release_date}]"
echo "url=[${release_url}]"
INNER_EOF
    } > "$inner"

    run bash "$inner"
    [ "$status" -eq 0 ]
    [[ "$output" == *"tag=[]"* ]]
    [[ "$output" == *"commit=[]"* ]]
    [[ "$output" == *"date=[]"* ]]
    [[ "$output" == *"url=[]"* ]]

    rm -rf "${mock_dir}"
}

@test "_fetch_latest_release_curl outputs TAB-separated release line" {
    local mock_dir inner
    mock_dir=$(mktemp -d)
    # mock curl：解析 -o 参数写入 mock JSON，输出 HTTP 200
    _make_stub_exec "${mock_dir}/curl" \
        "$(_mock_curl_response 200 '{"tag_name":"b4001","target_commitish":"def9876543210abcdef9876543210abcdef98","published_at":"2026-02-20T08:00:00Z","html_url":"https://github.com/ggml-org/llama.cpp/releases/tag/b4001"}')"

    inner="${mock_dir}/test_inner.sh"
    {
        echo "#!/bin/bash"
        echo "_LLAMA_SOURCE_ONLY=1 source '${BATS_TEST_DIRNAME}/../update.sh'"
        echo "PATH='${mock_dir}:$PATH'"
        echo '_fetch_latest_release_curl'
    } > "$inner"

    # 隔离 TMPDIR 再运行：下方「临时文件已清理」断言的 glob 扫全局 /tmp 时，
    # 并发测试套件或用户真实 update.sh 运行遗留的 llama_release.*.json 会
    # 造成假失败（flake）
    local isolated_tmp="${TEST_TMPDIR}/isolated_tmp"
    mkdir -p "$isolated_tmp"
    export TMPDIR="$isolated_tmp"

    run bash "$inner"
    [ "$status" -eq 0 ]
    [ "$output" = "$(printf 'b4001\tdef9876543210abcdef9876543210abcdef98\t2026-02-20T08:00:00Z\thttps://github.com/ggml-org/llama.cpp/releases/tag/b4001')" ]

    # 验证临时文件已清理（实现为每条退出路径显式 rm -f，非 RETURN trap——
    # bash RETURN trap 会全局泄漏，见 update.sh 中该决策的注释）
    ! ls "$isolated_tmp"/llama_release.*.json 2>/dev/null

    rm -rf "${mock_dir}"
}

@test "_fetch_latest_release_curl returns 1 on HTTP failure" {
    local mock_dir inner
    mock_dir=$(mktemp -d)
    # mock curl：输出 HTTP 403
    _make_stub_exec "${mock_dir}/curl" \
        "$(_mock_curl_response 403 '{"message":"Forbidden"}')"

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
    # mock curl：HTTP 200 但返回无效 JSON
    _make_stub_exec "${mock_dir}/curl" \
        "$(_mock_curl_response 200 'this is not json at all')"

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

# --- _fetch_latest_release seam 选择逻辑测试（C5）---

# Usage: _run_fetch_with_path <mock_dir> <call>
# 在子进程中 source update.sh（提取模式）、前置 mock_dir 到 PATH、执行 <call>，
# 结果经 bats run 捕获（$status/$output 由动态作用域回到调用者）。
_run_fetch_with_path() {
    local mock_dir="$1"
    local call="$2"
    local inner="${mock_dir}/test_inner.sh"
    {
        echo "#!/bin/bash"
        echo "_LLAMA_SOURCE_ONLY=1 source '${BATS_TEST_DIRNAME}/../update.sh'"
        echo "PATH='${mock_dir}':\"\$PATH\""
        printf '%s\n' "$call"
    } > "$inner"
    run bash "$inner"
}

@test "_fetch_latest_release prefers gh adapter when authenticated" {
    local mock_dir
    mock_dir=$(mktemp -d)
    # gh stub：release view 输出 JSON（seam 不再预检 gh auth status——
    # 未认证时 release view 本身即失败并回退，预检是白付的一次 RTT）
    cat > "${mock_dir}/gh" << 'MOCK_EOF'
#!/bin/bash
printf '%s' '{"tagName":"b4000","targetCommitish":"abc1234567890abcdef1234567890abcdef12","publishedAt":"2026-01-15T10:30:00Z","url":"https://github.com/ggml-org/llama.cpp/releases/tag/b4000"}'
MOCK_EOF
    chmod +x "${mock_dir}/gh"
    # curl stub 输出不同 tag——若其内容出现在 stdout 说明选择逻辑错误
    _make_stub_exec "${mock_dir}/curl" \
        "$(_mock_curl_response 200 '{"tag_name":"b9999","target_commitish":"x","published_at":"y","html_url":"z"}')"

    # stderr 丢弃：精确等值断言同时钉住「选择日志不污染 stdout」的 seam 契约
    _run_fetch_with_path "$mock_dir" '_fetch_latest_release 2>/dev/null'
    [ "$status" -eq 0 ]
    [ "$output" = "$(printf 'b4000\tabc1234567890abcdef1234567890abcdef12\t2026-01-15T10:30:00Z\thttps://github.com/ggml-org/llama.cpp/releases/tag/b4000')" ]

    rm -rf "${mock_dir}"
}

@test "_fetch_latest_release falls back to curl when gh query fails" {
    local mock_dir
    mock_dir=$(mktemp -d)
    # gh stub：release view 失败
    cat > "${mock_dir}/gh" << 'MOCK_EOF'
#!/bin/bash
exit 1
MOCK_EOF
    chmod +x "${mock_dir}/gh"
    _make_stub_exec "${mock_dir}/curl" \
        "$(_mock_curl_response 200 '{"tag_name":"b4001","target_commitish":"def9876543210abcdef9876543210abcdef98","published_at":"2026-02-20T08:00:00Z","html_url":"https://github.com/ggml-org/llama.cpp/releases/tag/b4001"}')"

    _run_fetch_with_path "$mock_dir" '_fetch_latest_release 2>/dev/null'
    [ "$status" -eq 0 ]
    [ "$output" = "$(printf 'b4001\tdef9876543210abcdef9876543210abcdef98\t2026-02-20T08:00:00Z\thttps://github.com/ggml-org/llama.cpp/releases/tag/b4001')" ]

    rm -rf "${mock_dir}"
}

@test "_fetch_latest_release falls back to curl when gh is not authenticated" {
    local mock_dir
    mock_dir=$(mktemp -d)
    # gh stub：一切调用失败（未认证时 release view 即失败 → seam 回退 curl）
    _make_stub_exec "${mock_dir}/gh" "exit 1"
    _make_stub_exec "${mock_dir}/curl" \
        "$(_mock_curl_response 200 '{"tag_name":"b4001","target_commitish":"def9876543210abcdef9876543210abcdef98","published_at":"2026-02-20T08:00:00Z","html_url":"https://github.com/ggml-org/llama.cpp/releases/tag/b4001"}')"

    _run_fetch_with_path "$mock_dir" '_fetch_latest_release 2>/dev/null'
    [ "$status" -eq 0 ]
    [ "$output" = "$(printf 'b4001\tdef9876543210abcdef9876543210abcdef98\t2026-02-20T08:00:00Z\thttps://github.com/ggml-org/llama.cpp/releases/tag/b4001')" ]

    rm -rf "${mock_dir}"
}

@test "_fetch_latest_release returns 1 when both adapters fail" {
    local mock_dir
    mock_dir=$(mktemp -d)
    _make_stub_exec "${mock_dir}/gh" "exit 1"
    _make_stub_exec "${mock_dir}/curl" "exit 1"

    _run_fetch_with_path "$mock_dir" '_fetch_latest_release 2>/dev/null'
    [ "$status" -eq 1 ]

    rm -rf "${mock_dir}"
}
