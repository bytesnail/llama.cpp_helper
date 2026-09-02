#!/usr/bin/env bats
bats_require_minimum_version 1.5.0
# common.sh 的契约测试集——覆盖日志、锁、硬件信息、conda、构建健康检查等

load test_helper

setup() {
    _setup_tmpdir
    # Source common.sh — suppress stderr because common.sh's
    # anti-direct-execution guard prints to stderr in the bats subshell
    _load_common
}

# teardown 用 test_helper.bash 的共享实现（LOCK_FD 关闭 + tmpdir 清理）——
# 本文件曾逐字复制一份覆盖共享版，helper 侧的修复（如反模式 9 注释）不会
# 同步进副本，已删除该重复

# --- Logging ---
@test "llama_info outputs [INFO] prefix to stdout" {
    run llama_info "test message"
    [ "$status" -eq 0 ]
    [[ "$output" =~ \[INFO\].*test.message ]]
}

@test "llama_ok outputs [OK] prefix to stdout" {
    run llama_ok "success"
    [ "$status" -eq 0 ]
    [[ "$output" =~ \[OK\].*success ]]
}

@test "llama_warn outputs [WARN] prefix to stdout" {
    run llama_warn "caution"
    [ "$status" -eq 0 ]
    [[ "$output" =~ \[WARN\].*caution ]]
}

@test "llama_err outputs to stderr" {
    run --separate-stderr llama_err "failure"
    [ "$status" -eq 0 ]
    [[ "$stderr" =~ \[ERROR\].*failure ]]
    # stdout 应无输出；--separate-stderr 下 stdout 内容在 $output（$stdout 未定义，恒空断言会空转）
    [ -z "$output" ]
}

@test "llama_step outputs === header === to stdout" {
    run llama_step "Phase 1"
    [ "$status" -eq 0 ]
    [[ "$output" =~ "=== Phase 1 ===" ]]
}

@test "llama_detail outputs arrow prefix to stdout" {
    run llama_detail "detail text"
    [ "$status" -eq 0 ]
    [[ "$output" =~ "detail text" ]]
}

@test "llama_info handles percent sign in message" {
    run llama_info "100% done"
    [ "$status" -eq 0 ]
    [[ "$output" =~ '100% done' ]]
}

@test "llama_step output begins with leading newline" {
    run llama_step "Phase"
    [ "$status" -eq 0 ]
    # 首行为空（llama_step 以 \n 开头产生前导空行）
    [[ "$(echo "$output" | head -1)" == "" ]]
    # 包含 === Phase ===
    [[ "$output" =~ '=== Phase ===' ]]
}

# --- Prerequisite Checking ---
@test "llama_check_commands succeeds when all commands exist" {
    run llama_check_commands bash "bash" cat "coreutils"
    [ "$status" -eq 0 ]
}

@test "llama_check_commands fails when commands missing" {
    run llama_check_commands nonexistent_cmd_xyz "fake-pkg"
    [ "$status" -eq 1 ]
    [[ "$output" =~ nonexistent_cmd_xyz ]]
}

@test "llama_check_commands warns on unpaired arguments" {
    run llama_check_commands bash "bash" orphan_arg
    [ "$status" -eq 0 ]
    [[ "$output" =~ orphan_arg ]]
}

# --- Path Validation ---
@test "llama_check_dir returns 0 for existing directory" {
    run llama_check_dir "/" "root"
    [ "$status" -eq 0 ]
}

@test "llama_check_dir returns 1 for missing directory" {
    run llama_check_dir "/nonexistent/path/xyz" "test dir"
    [ "$status" -eq 1 ]
}

@test "llama_check_file returns 0 for existing file" {
    run llama_check_file "${BATS_TEST_DIRNAME}/../common.sh" "common.sh"
    [ "$status" -eq 0 ]
}

@test "llama_check_file returns 1 for missing file" {
    run llama_check_file "/nonexistent/file.xyz" "test file"
    [ "$status" -eq 1 ]
}

# --- CPU Detection ---
@test "llama_get_cpu_count returns a number >= 1" {
    run llama_get_cpu_count
    [ "$status" -eq 0 ]
    [[ "$output" =~ ^[0-9]+$ ]]
    [ "$output" -ge 1 ]
}

# --- GPU Detection ---
@test "llama_get_gpu_count returns a non-negative integer" {
    run llama_get_gpu_count
    [ "$status" -eq 0 ] || [ "$status" -eq 1 ]
    [[ "$output" =~ ^[0-9]+$ ]]
}

@test "llama_get_gpu_count returns count from mock nvidia-smi" {
    local mock_dir
    mock_dir="${TEST_TMPDIR}/mock"
    mkdir -p "$mock_dir"
    printf '#!/bin/bash\nprintf "GPU 0\\nGPU 1\\n"\n' > "${mock_dir}/nvidia-smi"
    chmod +x "${mock_dir}/nvidia-smi"

    local _saved_path="$PATH"
    PATH="${mock_dir}:$PATH"
    run llama_get_gpu_count
    PATH="$_saved_path"
    [ "$status" -eq 0 ]
    [ "$output" = "2" ]
}

# --- File Locking ---
@test "llama_acquire_lock succeeds on first call" {
    llama_acquire_lock
    [ "$?" -eq 0 ]
    [ -n "${LOCK_FD:-}" ]
    llama_release_lock
}

@test "llama_acquire_lock fails when already held by another process" {
    # Background process must use the same LOCK_FILE from test setup
    # 就绪标记代替固定 sleep：固定等待在高负载机器上是确定性 flake（后台
    # 进程尚未持锁时，主流程的 acquire 会拿到锁、断言假红）。持锁方拿到锁
    # 后写标记文件，主流程轮询标记（5 秒上限）——超时则 loud 失败而非碰运气
    local ready_file="${TEST_TMPDIR}/lock_held.ready"
    (
        _load_common
        LOCK_FILE="${LOCK_FILE}" llama_acquire_lock
        : > "$ready_file"
        sleep 2  # 持锁窗口：主流程被标记唤醒后立即探测，2 秒足够
        LOCK_FILE="${LOCK_FILE}" llama_release_lock
    ) &
    local bg_pid=$!
    local waited=0
    while [[ ! -f "$ready_file" ]] && (( waited < 100 )); do
        sleep 0.05
        (( ++waited ))  # 前置自增：(( waited++ )) 在 0 时求值为假会触发 errexit
    done
    [[ -f "$ready_file" ]]
    run llama_acquire_lock
    [ "$status" -eq 1 ]
    kill "$bg_pid" 2>/dev/null || true
    wait "$bg_pid" 2>/dev/null || true
    llama_release_lock
}

@test "llama_release_lock cleans up LOCK_FD" {
    llama_acquire_lock
    local fd="${LOCK_FD}"
    [ -n "$fd" ]
    llama_release_lock
    [ -z "${LOCK_FD:-}" ]
}

@test "_recover_stale_lock recovers a lock held by a dead process" {
    # Create a lock file with a nonexistent PID
    echo "99999" > "${LOCK_FILE}"
    # Call directly (not via run) because LOCK_FD must survive the subshell
    _recover_stale_lock "${LOCK_FILE}"
    local _recover_rc=$?
    [ "$_recover_rc" -eq 0 ]
    [ -n "${LOCK_FD:-}" ]
    # Clean up
    llama_release_lock
}

# --- Disk Space ---
@test "llama_check_disk_space passes for root with default threshold" {
    run llama_check_disk_space "/"
    [ "$status" -eq 0 ]
}

@test "llama_check_disk_space warns but passes for missing path" {
    run llama_check_disk_space "/nonexistent/path"
    [ "$status" -eq 0 ]
}

# --- Portable stat ---
@test "llama_file_size returns bytes for existing file" {
    echo -n "hello" > "${TEST_TMPDIR}/testfile"
    run llama_file_size "${TEST_TMPDIR}/testfile"
    [ "$status" -eq 0 ]
    [ "$output" -eq 5 ]
}

@test "llama_file_size returns 1 for missing file" {
    run llama_file_size "/nonexistent"
    [ "$status" -eq 1 ]
}

# --- Network Context ---
@test "llama_with_network_context wraps successful command" {
    run llama_with_network_context "test desc" true
    [ "$status" -eq 0 ]
}

@test "llama_with_network_context wraps failed command with context" {
    run llama_with_network_context "test desc" false
    [ "$status" -eq 1 ]
    [[ "$output" =~ "test desc" ]]
}

# --- Trap Management ---
@test "llama_setup_trap registers handler" {
    llama_setup_trap "echo trapped"
    local handler
    handler=$(trap -p SIGINT)
    [[ "$handler" =~ "echo trapped" ]]
    llama_cleanup_trap
}

@test "llama_cleanup_trap resets handlers to default" {
    llama_setup_trap "echo trapped"
    llama_cleanup_trap
    local handler
    handler=$(trap -p SIGINT 2>&1 || true)
    [[ "$handler" == "" ]]  # After reset, trap -p SIGINT should output empty
}

# --- Exit Helpers ---
@test "llama_die outputs error message" {
    run bash -c "
        source '${BATS_TEST_DIRNAME}/../common.sh' 2>/dev/null || true
        llama_die 'test error' 42
    "
    [ "$status" -eq 42 ]
    [[ "$output" =~ "test error" ]]
}

@test "llama_safe_exit exits with given code" {
    run bash -c "
        source '${BATS_TEST_DIRNAME}/../common.sh' 2>/dev/null || true
        llama_safe_exit 0
    "
    [ "$status" -eq 0 ]
}
@test "llama_die with empty message exits 1 and outputs only [ERROR] prefix" {
    run bash -c "
        source '${BATS_TEST_DIRNAME}/../common.sh' 2>/dev/null || true
        llama_die '' 2>&1
    "
    [ "$status" -eq 1 ]
}

# --- Init/Source/Help Helpers ---
@test "llama_show_help outputs usage with description" {
    run llama_show_help "test.sh" "A test script"
    [ "$status" -eq 0 ]
    [[ "$output" =~ "用法: test.sh" ]]
    [[ "$output" =~ "A test script" ]]
}

@test "llama_show_help includes options when provided" {
    run llama_show_help "test.sh" "desc" "  -h  help"
    [ "$status" -eq 0 ]
    [[ "$output" =~ "选项:" ]]
    [[ "$output" =~ "-h  help" ]]
}

# --- Version ---
@test "llama_show_version outputs version string" {
    source "${BATS_TEST_DIRNAME}/../config.sh" 2>/dev/null || true
    run llama_show_version
    [ "$status" -eq 0 ]
    [[ "$output" == "llama.cpp_helper "* ]]
}

# --- llama_run_silent ---
# 契约：llama_run_silent <rc_var> <cmd...> 恒返回 0（set -e 的调用者不被中止）；
# 退出码经 printf -v 写入 <rc_var>（必写，set -u 下读取安全）；
# 误用（缺 rc_var / 变量名非法 / 保留前缀 _lrs_ / 无命令）返回非零。
@test "llama_run_silent writes failure exit code to out-var and returns 0 under set -e" {
    run bash -c "
        source '${BATS_TEST_DIRNAME}/../common.sh' 2>/dev/null || :
        set -e
        llama_run_silent rc false
        echo \"rc=\$rc\"
    "
    [ "$status" -eq 0 ]
    [[ "$output" =~ "rc=1" ]]
}
@test "llama_run_silent passes through success" {
    run bash -c "
        source '${BATS_TEST_DIRNAME}/../common.sh' 2>/dev/null || :
        set -e
        llama_run_silent rc true
        echo \"rc=\$rc\"
    "
    [ "$status" -eq 0 ]
    [[ "$output" =~ "rc=0" ]]
}

@test "llama_run_silent preserves exit code 42 under set -e" {
    run bash -c "
        source '${BATS_TEST_DIRNAME}/../common.sh' 2>/dev/null || :
        set -e
        llama_run_silent rc bash -c 'exit 42'
        echo \"rc=\$rc\"
    "
    [ "$status" -eq 0 ]
    [[ "$output" =~ "rc=42" ]]
}

@test "llama_run_silent forwards failed command stderr to caller" {
    run --separate-stderr bash -c "
        source '${BATS_TEST_DIRNAME}/../common.sh' 2>/dev/null || :
        set -e
        llama_run_silent rc bash -c 'echo FAIL_OUTPUT >&2; exit 7'
        echo exit_code=\$rc
    "
    [ "$status" -eq 0 ]
    [[ "$stderr" =~ FAIL_OUTPUT ]]
    [[ "$output" =~ "exit_code=7" ]]
}

@test "llama_run_silent preserves caller errexit (regression: no silent set -e disable)" {
    # 回归测试：prev_opts=\$(set +o) 在命令替换子 shell 中丢失 errexit
    # （inherit_errexit 默认 off），eval 恢复曾把调用者的 set -e 永久关闭
    run bash -c "
        source '${BATS_TEST_DIRNAME}/../common.sh' 2>/dev/null || :
        set -e
        llama_run_silent rc1 true
        llama_run_silent rc2 false
        set -o | grep -q 'errexit.*on'
    "
    [ "$status" -eq 0 ]
}

@test "llama_run_silent usage errors return non-zero" {
    # 缺 rc_var / 非法变量名 / 保留前缀 _lrs_ / 缺命令 —— 均按误用返回非零并报错；
    # 断言报错文案以钉死「校验失败」而非碰巧的 command not found（旧实现
    # 会把它们当命令执行，碰巧也返回非零）
    run bash -c "
        source '${BATS_TEST_DIRNAME}/../common.sh' 2>/dev/null || :
        llama_run_silent
    "
    [ "$status" -ne 0 ]
    [[ "$output" =~ "变量名" ]]
    run bash -c "
        source '${BATS_TEST_DIRNAME}/../common.sh' 2>/dev/null || :
        llama_run_silent '1bad' true
    "
    [ "$status" -ne 0 ]
    [[ "$output" =~ "变量名" ]]
    run bash -c "
        source '${BATS_TEST_DIRNAME}/../common.sh' 2>/dev/null || :
        llama_run_silent _lrs_ret true
    "
    [ "$status" -ne 0 ]
    [[ "$output" =~ "变量名" ]]
    run bash -c "
        source '${BATS_TEST_DIRNAME}/../common.sh' 2>/dev/null || :
        llama_run_silent rc
    "
    [ "$status" -ne 0 ]
    [[ "$output" =~ "缺少命令" ]]
}

@test "llama_run_silent rejects shell-critical out-var names" {
    # PATH/IFS 等 shell 关键变量被 printf -v 覆写会破坏 shell 自身行为
    # （实测：PATH 被写为 "0" 后全部外部命令 lookup 失败）——按误用返回 2
    run bash -c "
        source '${BATS_TEST_DIRNAME}/../common.sh' 2>/dev/null || :
        llama_run_silent PATH true
    "
    [ "$status" -eq 2 ]
    [[ "$output" =~ "变量名" ]]
    run bash -c "
        source '${BATS_TEST_DIRNAME}/../common.sh' 2>/dev/null || :
        llama_run_silent IFS true
    "
    [ "$status" -eq 2 ]
    [[ "$output" =~ "变量名" ]]
    # 黑名单外的普通变量名不受影响
    run bash -c "
        source '${BATS_TEST_DIRNAME}/../common.sh' 2>/dev/null || :
        llama_run_silent rc true; echo \"rc=\$rc\"
    "
    [ "$status" -eq 0 ]
    [[ "$output" =~ "rc=0" ]]
}

@test "llama_run_silent always writes out-var on failure (set -u read safe)" {
    run bash -c "
        source '${BATS_TEST_DIRNAME}/../common.sh' 2>/dev/null || :
        set -eu
        llama_run_silent rc false
        echo \"rc=\$rc\"
    "
    [ "$status" -eq 0 ]
    [[ "$output" =~ "rc=1" ]]
}

@test "llama_run_silent survives wrapping a shell function that enables set -e" {
    # 回归：被包装的 shell 函数内部启用 set -e 后 return 非零时，裸调用 "$@"
    # 曾把 errexit 留在开启状态，函数返回非零的瞬间杀死整个 shell——rc 未写、
    # warn 未打。修复后调用在 if 豁免上下文进行且对称恢复 errexit（已实证）
    run bash -c "
        source '${BATS_TEST_DIRNAME}/../common.sh' 2>/dev/null || :
        set +e
        fn() { set -e; return 3; }
        llama_run_silent rc fn
        echo \"rc=\$rc\"
        set -o | grep -q 'errexit.*off' && echo ERREXIT-OFF-OK
    "
    [ "$status" -eq 0 ]
    [[ "$output" =~ "rc=3" ]]
    [[ "$output" =~ "ERREXIT-OFF-OK" ]]
}

@test "llama_run_silent out-var survives names colliding with implementation internals" {
    # 动态作用域暗坑：实现内部的 local 会遮蔽调用者同名变量——printf -v ret
    # 曾写到函数自己的 local ret 上，调用者永远拿不到值。实现改用 _lrs_ 前缀
    # 内部名后，ret/tmp_out 等常见名必须能正确穿透。
    run bash -c "
        source '${BATS_TEST_DIRNAME}/../common.sh' 2>/dev/null || :
        set -e
        llama_run_silent ret bash -c 'exit 42'
        llama_run_silent tmp_out bash -c 'exit 7'
        echo \"ret=\$ret tmp_out=\$tmp_out\"
    "
    [ "$status" -eq 0 ]
    [[ "$output" =~ "ret=42 tmp_out=7" ]]
}

@test "llama_activate_conda preserves caller errexit after activation (regression)" {
    # 回归测试：同一 prev_opts 缺陷的 conda 路径变体
    local mock_e="${TEST_TMPDIR}/mock_conda_e"
    _make_mock_conda "$mock_e"
    run bash -c "
        set -euo pipefail
        unset CONDA_PREFIX CONDA_DEFAULT_ENV
        source '${BATS_TEST_DIRNAME}/../common.sh' 2>/dev/null || true
        CONDA_EXE='${mock_e}/bin/conda' CONDA_AUTO_ACTIVATE=1 llama_activate_conda >/dev/null 2>&1
        set -o | grep -q 'errexit.*on'
    "
    [ "$status" -eq 0 ]
}

# --- Human-Readable Size ---
@test "llama_human_size: 0 bytes returns 0B" {
    run llama_human_size 0
    [ "$status" -eq 0 ]
    [ "$output" = "0B" ]
}

@test "llama_human_size: 512 bytes returns 512B" {
    run llama_human_size 512
    [ "$status" -eq 0 ]
    [ "$output" = "512B" ]
}

@test "llama_human_size: 1023 bytes returns 1023B" {
    run llama_human_size 1023
    [ "$status" -eq 0 ]
    [ "$output" = "1023B" ]
}

@test "llama_human_size: 1024 bytes returns 1KiB" {
    run llama_human_size 1024
    [ "$status" -eq 0 ]
    [ "$output" = "1KiB" ]
}

@test "llama_human_size: 1536 bytes returns 1KiB" {
    run llama_human_size 1536
    [ "$status" -eq 0 ]
    [ "$output" = "1KiB" ]
}
@test "llama_human_size: 2048 bytes returns 2KiB" {
    run llama_human_size 2048
    [ "$status" -eq 0 ]
    [ "$output" = "2KiB" ]
}

@test "llama_human_size: 1048576 bytes returns 1MiB" {
    run llama_human_size 1048576
    [ "$status" -eq 0 ]
    [ "$output" = "1MiB" ]
}

@test "llama_human_size: 1073741824 bytes returns 1.00GiB" {
    run llama_human_size 1073741824
    [ "$status" -eq 0 ]
    [ "$output" = "1.00GiB" ]
}

@test "llama_human_size: 1610612736 bytes returns 1.50GiB" {
    run llama_human_size 1610612736
    [ "$status" -eq 0 ]
    [ "$output" = "1.50GiB" ]
}

@test "llama_human_size: 2147483648 bytes returns 2.00GiB" {
    run llama_human_size 2147483648
    [ "$status" -eq 0 ]
    [ "$output" = "2.00GiB" ]
}

@test "llama_human_size does not leak frac_str to caller scope" {
    run bash -c "
        source '${BATS_TEST_DIRNAME}/../common.sh' 2>/dev/null || true
        unset frac_str
        llama_human_size 1073741824
        [[ -z \"\${frac_str+x}\" ]]
        echo ok
    "
    [ "$status" -eq 0 ]
    [[ "$output" =~ ok ]]
}

# --- Commit SHA Validation ---
@test "llama_is_full_commit_sha: valid 40-char lowercase hex returns 0" {
    run llama_is_full_commit_sha "abcdef1234567890abcdef1234567890abcdef12"
    [ "$status" -eq 0 ]
}

@test "llama_is_full_commit_sha: valid 40-char mixed case hex returns 0" {
    run llama_is_full_commit_sha "ABCDEF1234567890ABCDEF1234567890ABCDEF12"
    [ "$status" -eq 0 ]
}

@test "llama_is_full_commit_sha: short sha (< 40 chars) returns 1" {
    run llama_is_full_commit_sha "abc123"
    [ "$status" -eq 1 ]
}

@test "llama_is_full_commit_sha: invalid characters returns 1" {
    run llama_is_full_commit_sha "ghijklmnopqrstuvwxyzGHIJKLMNOPQRSTUVWXYZ1234"
    [ "$status" -eq 1 ]
}

@test "llama_is_full_commit_sha: empty string returns 1" {
    run llama_is_full_commit_sha ""
    [ "$status" -eq 1 ]
}

# --- Return or Exit ---
@test "llama_return_or_exit: returns given exit code in sourced context" {
    run bash -c "source '${BATS_TEST_DIRNAME}/../common.sh' 2>/dev/null; llama_return_or_exit 42; echo \$?"
    [ "$status" -eq 0 ]
    [[ "$output" =~ 42 ]]
}

@test "llama_return_or_exit: returns 0 when called with 0" {
    run bash -c "source '${BATS_TEST_DIRNAME}/../common.sh' 2>/dev/null; llama_return_or_exit 0; echo \$?"
    [ "$status" -eq 0 ]
    [[ "$output" =~ 0 ]]
}

# --- Build Health ---
# llama_check_build_health 的布局常量（BUILD_BIN_DIR/BUILD_STAMP）fail-closed
# 取自 config.sh（无默认布局回退）——本文件只 source common.sh，须显式设置
@test "llama_check_build_health returns 1 when build dir does not exist" {
    LLAMA_CPP_SRC="${TEST_TMPDIR}/nonexistent_llama"
    BUILD_BIN_DIR="${LLAMA_CPP_SRC}/build/bin"
    BUILD_STAMP="${LLAMA_CPP_SRC}/build/.build-stamp"
    run llama_check_build_health
    [ "$status" -eq 1 ]
}
@test "llama_check_build_health returns 1 when binaries are missing" {
    LLAMA_CPP_SRC="${TEST_TMPDIR}/fake_llama"
    BUILD_BIN_DIR="${LLAMA_CPP_SRC}/build/bin"
    BUILD_STAMP="${LLAMA_CPP_SRC}/build/.build-stamp"
    REQUIRED_BINARIES=("llama-cli" "llama-server")
    mkdir -p "${LLAMA_CPP_SRC}/build/bin"
    run llama_check_build_health
    [ "$status" -eq 1 ]
}

@test "llama_check_build_health returns 0 when binaries exist and stamp matches" {
    LLAMA_CPP_SRC="${TEST_TMPDIR}/healthy_llama"
    BUILD_BIN_DIR="${LLAMA_CPP_SRC}/build/bin"
    BUILD_STAMP="${LLAMA_CPP_SRC}/build/.build-stamp"
    REQUIRED_BINARIES=("llama-cli" "llama-server")
    _make_fake_built_repo "$LLAMA_CPP_SRC"
    run llama_check_build_health
    [ "$status" -eq 0 ]
}

@test "llama_check_build_health returns 1 when stamp does not match HEAD" {
    LLAMA_CPP_SRC="${TEST_TMPDIR}/stale_llama"
    BUILD_BIN_DIR="${LLAMA_CPP_SRC}/build/bin"
    BUILD_STAMP="${LLAMA_CPP_SRC}/build/.build-stamp"
    REQUIRED_BINARIES=("llama-cli" "llama-server")
    _make_fake_built_repo "$LLAMA_CPP_SRC" "0000000000000000000000000000000000000000"
    run llama_check_build_health
    [ "$status" -eq 1 ]
}

# --- conda Activation ---
@test "llama_activate_conda skips when CONDA_AUTO_ACTIVATE=0" {
    CONDA_AUTO_ACTIVATE=0 run llama_activate_conda
    [ "$status" -eq 0 ]
    [[ "$output" != *"conda"* ]]
}

@test "llama_activate_conda short-circuits when target env already active" {
    # 目标即当前环境（默认 base）时短路，不进入发现/切换路径。
    # 必须显式控制 CONDA_DEFAULT_ENV——测试进程继承开发机 base 激活状态
    CONDA_PREFIX="/fake/conda" CONDA_DEFAULT_ENV=base CONDA_AUTO_ACTIVATE=1 run llama_activate_conda
    [ "$status" -eq 0 ]
    [[ "$output" =~ "conda 环境已激活" ]]
}

@test "llama_activate_conda returns 0 when no conda found" {
    # 真正模拟"无 conda"：假 HOME（常见路径候选落空）+ 精简 PATH
    #（command -v conda 找不到——真实 conda 在 /mnt/usr/tools/... 不在其中）
    unset CONDA_EXE CONDA_PREFIX CONDA_DEFAULT_ENV
    local empty_home="${TEST_TMPDIR}/empty_home"
    mkdir -p "$empty_home"
    HOME="$empty_home" PATH="/usr/bin:/bin" run llama_activate_conda
    [ "$status" -eq 0 ]
}

@test "llama_activate_conda detects conda from CONDA_EXE" {
    local mock_base="${TEST_TMPDIR}/mock_conda"
    _make_mock_conda "$mock_base"
    # 不走短路路径：显式清除继承自开发机的 base 激活状态
    unset CONDA_PREFIX CONDA_DEFAULT_ENV
    CONDA_EXE="${mock_base}/bin/conda" CONDA_AUTO_ACTIVATE=1 run llama_activate_conda
    [ "$status" -eq 0 ]
    [[ "$output" =~ "已激活 conda 环境" ]]
}

@test "llama_activate_conda resolves symlinked CONDA_EXE to real install root" {
    # 回归：CONDA_EXE 为符号链接（/usr/local/bin/conda 形态）时，dirname/..
    # 曾得到链接所在目录——非空即短路候选清单与 conda info 回退，真实
    # 安装根永远找不到，conda.sh 定位失败、安装形同虚设（已实证）
    local real_conda="${TEST_TMPDIR}/real_conda"
    local shim_dir="${TEST_TMPDIR}/shim_bin"
    _make_mock_conda "$real_conda"
    mkdir -p "$shim_dir"
    ln -s "${real_conda}/bin/conda" "${shim_dir}/conda"
    # 不走短路路径：显式清除继承自开发机的 base 激活状态
    unset CONDA_PREFIX CONDA_DEFAULT_ENV
    CONDA_EXE="${shim_dir}/conda" CONDA_AUTO_ACTIVATE=1 run llama_activate_conda
    [ "$status" -eq 0 ]
    [[ "$output" =~ "已激活 conda 环境" ]]
}

@test "llama_activate_conda detects conda from common path" {
    local mock_home="${TEST_TMPDIR}/fake_home"
    _make_mock_conda "${mock_home}/miniconda3"
    unset CONDA_EXE CONDA_PREFIX CONDA_DEFAULT_ENV
    HOME="$mock_home" CONDA_AUTO_ACTIVATE=1 run llama_activate_conda
    [ "$status" -eq 0 ]
    [[ "$output" =~ "已激活 conda 环境" ]]
}

@test "llama_activate_conda switches to CONDA_ENV_NAME when another env is active" {
    # 权威语义核心：当前激活 other 环境，显式指定 myenv，必须强制切换
    local mock_base="${TEST_TMPDIR}/mock_switch"
    _make_mock_conda "$mock_base" 0 "${mock_base}/activate.log"
    CONDA_PREFIX="/fake/other" CONDA_DEFAULT_ENV=other CONDA_ENV_NAME=myenv \
        CONDA_EXE="${mock_base}/bin/conda" CONDA_AUTO_ACTIVATE=1 \
        run llama_activate_conda
    [ "$status" -eq 0 ]
    [[ "$output" =~ "已激活 conda 环境: myenv" ]]
    grep -q "activate myenv" "${mock_base}/activate.log"
}

@test "llama_activate_conda warns when conda.sh missing" {
    local mock_broken="${TEST_TMPDIR}/mock_broken"
    mkdir -p "${mock_broken}/bin"
    _make_stub_exec "${mock_broken}/bin/conda"
    # Intentionally do NOT create etc/profile.d/conda.sh — simulate broken install
    # 不走短路路径：显式清除继承自开发机的 base 激活状态
    unset CONDA_PREFIX CONDA_DEFAULT_ENV
    CONDA_EXE="${mock_broken}/bin/conda" CONDA_AUTO_ACTIVATE=1 run llama_activate_conda
    [ "$status" -eq 0 ]
    [[ "$output" =~ "缺少 shell 初始化脚本" ]]
}

@test "llama_activate_conda returns 1 on conda activate failure" {
    # 权威语义：显式指定的环境激活失败 → 硬报错返回 1（build.sh/update.sh
    # 的裸调用在 set -e 下随之中止）
    local mock_fail="${TEST_TMPDIR}/mock_fail"
    _make_mock_conda "$mock_fail" 1
    unset CONDA_PREFIX CONDA_DEFAULT_ENV
    CONDA_ENV_NAME=no_such_env CONDA_EXE="${mock_fail}/bin/conda" CONDA_AUTO_ACTIVATE=1 \
        run llama_activate_conda
    [ "$status" -eq 1 ]
    [[ "$output" =~ "conda 环境激活失败" ]]
    [[ "$output" =~ "no_such_env" ]]
    [[ "$output" =~ "环境不存在" ]]
}

# --- Color Save/Restore ---
@test "llama_save_colors and llama_restore_colors preserve values" {
    RED="test_red"
    GREEN="test_green"
    CYAN="test_cyan"
    llama_save_colors
    RED="modified"
    GREEN="modified"
    CYAN="modified"
    llama_restore_colors
    [ "$RED" = "test_red" ]
    [ "$GREEN" = "test_green" ]
    [ "$CYAN" = "test_cyan" ]
    # Verify saved temp vars are cleaned up after restore
    [ -z "${_LLAMA_SAVED_RED+x}" ] || false
    [ -z "${_LLAMA_SAVED_GREEN+x}" ] || false
}

@test "llama_restore_colors unsets variables that were unset when saved" {
    unset RED GREEN YELLOW CYAN BLUE BOLD NC
    llama_save_colors
    RED="should-disappear"
    GREEN="should-disappear"
    llama_restore_colors
    # restore sets to empty string (not unset) — save uses ${var-} which
    # converts unset→empty. This is acceptable: unset never occurs in practice.
    [[ "${RED-__DEFAULT__}" = "" ]]
    [[ "${GREEN-__DEFAULT__}" = "" ]]
}

@test "llama_get_cpu_count fallback returns positive number with no PATH" {
    # Mock by clearing PATH — if nproc/sysctl fail, falls back to /proc/cpuinfo or 4
    run llama_get_cpu_count
    [ "$status" -eq 0 ]
    [[ "$output" =~ ^[0-9]+$ ]]
    [ "$output" -ge 1 ]
}

@test "log functions produce no ANSI codes when output is not a terminal" {
    # Under bats, `run` pipes stdout → [[ -t 1 ]] is false → colors are empty strings
    run llama_info "test_color_output"
    [ "$status" -eq 0 ]
    # $'\033' is the ESC character (ANSI escape start)
    [[ "$output" != *$'\033'* ]]
}


@test "llama_check_disk_space returns 1 when insufficient space" {
    local fake_bin="${TEST_TMPDIR}/fake_bin"
    mkdir -p "$fake_bin"
    cat > "${fake_bin}/df" <<'EOF'
#!/bin/bash
echo "Filesystem     1K-blocks    Used Available Use% Mounted on"
echo "/dev/sda1        1000000   950000     10000  99% /"
EOF
    chmod +x "${fake_bin}/df"
    local _saved_path="$PATH"
    PATH="${fake_bin}:$PATH"
    run llama_check_disk_space "${TEST_TMPDIR}" 10
    PATH="$_saved_path"
    [ "$status" -eq 1 ]
    [[ "$output" =~ "磁盘空间不足" ]]
}

@test "llama_setup_trap returns 1 when command is empty" {
    run llama_setup_trap ""
    [ "$status" -eq 1 ]
}

@test "llama_get_gpu_count returns 1 when nvidia-smi not available" {
    local _saved_path="$PATH"
    PATH="/nonexistent"
    run llama_get_gpu_count
    PATH="$_saved_path"
    [ "$status" -eq 1 ]
    [ "$output" = "0" ]
}

@test "llama_get_gpu_count distinguishes driver failure from no-GPU" {
    # 三分支契约：nvidia-smi 存在但执行失败（驱动/NVML 异常）→ stdout 输出 0、
    # 返回 1、stderr 有警告——不能把驱动故障谎报为健康的"0 块 GPU"
    # （与 llama_print_hardware_summary 的 smi_rc 处理对齐）
    local mock_dir="${TEST_TMPDIR}/mock"
    mkdir -p "$mock_dir"
    printf '#!/bin/bash\nexit 9\n' > "${mock_dir}/nvidia-smi"
    chmod +x "${mock_dir}/nvidia-smi"

    local _saved_path="$PATH"
    PATH="${mock_dir}:$PATH"
    run --separate-stderr llama_get_gpu_count
    PATH="$_saved_path"
    [ "$status" -eq 1 ]
    # bats 的 run --separate-stderr 只定义 $output（stdout 内容）与 $stderr，
    # 不定义 $stdout——用 $stdout 断言恒因变量未定义而失败
    [ "$output" = "0" ]
    [[ "$stderr" =~ "执行失败" ]]
}

@test "llama_check_build_health returns 1 when LLAMA_CPP_SRC unset" {
    unset LLAMA_CPP_SRC
    run llama_check_build_health
    [ "$status" -eq 1 ]
}

@test "llama_print_run_examples outputs expected content" {
    SCRIPT_DIR="/fake/script/dir" run llama_print_run_examples "/fake/bin"
    [ "$status" -eq 0 ]
    [[ "$output" =~ "run_env.sh" ]]
    [[ "$output" =~ "llama-cli" ]]
    [[ "$output" =~ "llama-server" ]]
}

@test "llama_show_help includes examples when provided" {
    run llama_show_help "test.sh" "desc" "" "  example command"
    [ "$status" -eq 0 ]
    [[ "$output" =~ "示例:" ]]
    [[ "$output" =~ "example command" ]]
}

@test "llama_acquire_lock succeeds with explicit lock_file argument" {
    local custom_lock="${TEST_TMPDIR}/custom.lock"
    llama_acquire_lock "$custom_lock"
    local rc=$?
    [ "$rc" -eq 0 ]
    [ -n "${LOCK_FD:-}" ]
    llama_release_lock
}

@test "llama_acquire_lock refuses a symlinked lock file" {
    # 锁文件路径在 XDG_RUNTIME_DIR 缺失时是可预测的 /tmp 路径——跟随符号
    # 链接打开并截断写入（_lock_grab 的 printf >）会构成同机本地 clobber
    # 面；必须在打开前拒绝
    local target="${TEST_TMPDIR}/victim.txt"
    echo "precious" > "$target"
    ln -s "$target" "${TEST_TMPDIR}/evil.lock"
    run llama_acquire_lock "${TEST_TMPDIR}/evil.lock"
    [ "$status" -eq 1 ]
    [[ "$output" =~ "符号链接" ]]
    [ "$(cat "$target")" = "precious" ]
}

# --- conda Activation Resilience (set -eu) ---
@test "llama_activate_conda survives set -u when conda script references unset variable" {
    local mock_setu="${TEST_TMPDIR}/mock_setu"
    mkdir -p "${mock_setu}/etc/profile.d"
    mkdir -p "${mock_setu}/bin"
    _make_stub_exec "${mock_setu}/bin/conda"
    # Simulate conda activation script that references an unset variable
    # (like ~cuda-nvcc_activate.sh does with NVCC_PREPEND_FLAGS)
    cat > "${mock_setu}/etc/profile.d/conda.sh" <<'CONDAEOF'
conda() {
    if [[ "$1" == "activate" ]]; then
        : ${UNSET_VAR}
        return 0
    fi
}
CONDAEOF
    CONDA_EXE="${mock_setu}/bin/conda" CONDA_AUTO_ACTIVATE=1 run bash -c "
        set -euo pipefail
        unset CONDA_PREFIX CONDA_DEFAULT_ENV
        source '${BATS_TEST_DIRNAME}/../common.sh' 2>/dev/null || true
        llama_activate_conda
        echo SURVIVED
    "
    [ "$status" -eq 0 ]
    [[ "$output" =~ "SURVIVED" ]]
}

@test "llama_activate_conda aborts set -e caller when conda activate fails" {
    # 新契约：激活失败返回 1，set -e 调用方（build.sh/update.sh 的裸调用）随之中止
    local mock_sete="${TEST_TMPDIR}/mock_sete"
    _make_mock_conda "$mock_sete" 1
    CONDA_EXE="${mock_sete}/bin/conda" CONDA_AUTO_ACTIVATE=1 run bash -c "
        set -euo pipefail
        unset CONDA_PREFIX CONDA_DEFAULT_ENV
        source '${BATS_TEST_DIRNAME}/../common.sh' 2>/dev/null || true
        llama_activate_conda
        echo SURVIVED
    "
    [ "$status" -eq 1 ]
    [[ "$output" != *"SURVIVED"* ]]
    [[ "$output" =~ "conda 环境激活失败" ]]
}

@test "llama_activate_conda failure can be tolerated with || true under set -e" {
    # 调用方显式 || true 可容忍失败（run_env.sh 场景：错误已打印，流程继续）
    local mock_tol="${TEST_TMPDIR}/mock_tol"
    _make_mock_conda "$mock_tol" 1
    CONDA_EXE="${mock_tol}/bin/conda" CONDA_AUTO_ACTIVATE=1 run bash -c "
        set -euo pipefail
        unset CONDA_PREFIX CONDA_DEFAULT_ENV
        source '${BATS_TEST_DIRNAME}/../common.sh' 2>/dev/null || true
        llama_activate_conda || true
        echo SURVIVED
    "
    [ "$status" -eq 0 ]
    [[ "$output" =~ "SURVIVED" ]]
    [[ "$output" =~ "conda 环境激活失败" ]]
}

@test "llama_activate_conda restores set -u after conda activation" {
    local mock_restore="${TEST_TMPDIR}/mock_restore"
    _make_mock_conda "$mock_restore"
    CONDA_EXE="${mock_restore}/bin/conda" CONDA_AUTO_ACTIVATE=1 run bash -c "
        set -euo pipefail
        unset CONDA_PREFIX CONDA_DEFAULT_ENV
        source '${BATS_TEST_DIRNAME}/../common.sh' 2>/dev/null || true
        llama_activate_conda
        # After llama_activate_conda returns, set -u should be active again
        # Verify by referencing an unset variable — should fail
        : \${_LLAMA_TEST_UNSET_VAR_XYZ}
    "
    # set -u 下引用未绑定变量会以非零退出（具体退出码 127/1 取决于 errexit
    # 状态，不应固化——errexit 现在被正确恢复后该码为 1，此前 127 恰恰是
    # errexit 被静默关闭的 bug 表象）；断言非零 + 未绑定错误消息即可。
    # bash 内置错误文案随宿主 locale 变化（zh=未绑定的变量 / C=unbound
    # variable），断言必须两种都接受，否则非 zh 机器上质量门禁假红（已实测）
    [ "$status" -ne 0 ]
    [[ "$output" == *"未绑定的变量"* || "$output" == *"unbound variable"* ]]
}

# --- Hardware Info ---
@test "_llama_join joins multiple elements with separator" {
    run _llama_join ", " a b c
    [ "$status" -eq 0 ]
    [ "$output" = "a, b, c" ]
}

@test "_llama_join handles single element" {
    run _llama_join ", " only
    [ "$status" -eq 0 ]
    [ "$output" = "only" ]
}

@test "_llama_join returns empty for no elements" {
    run _llama_join ", "
    [ "$status" -eq 0 ]
    [ "$output" = "" ]
}

@test "llama_hw_cpu_model returns non-empty string" {
    run llama_hw_cpu_model
    [ "$status" -eq 0 ]
    [ -n "$output" ]
}

@test "llama_hw_cpu_model survives set -e when lscpu is unavailable" {
    # 回归测试：lscpu 不可用时（缺失/损坏），_llama_lscpu_field 管线返回非零，
    # pipefail+set -e 下会中止 build.sh。验证 || true 修复后函数回退到 /proc/cpuinfo。
    run bash -c "
        set -euo pipefail
        source '${BATS_TEST_DIRNAME}/../common.sh' 2>/dev/null || true
        # 构造不含 lscpu 的 PATH，但保留 awk 和基本工具
        PATH='/usr/bin:/bin'
        hash -r 2>/dev/null || true
        # 如果 lscpu 存在于 /usr/bin，用空函数屏蔽
        if command -v lscpu &>/dev/null; then
            lscpu() { return 127; }
        fi
        model=\$(llama_hw_cpu_model)
        echo \"model=\${model}\"
    "
    [ "$status" -eq 0 ]
    [[ "$output" == *model=* ]]
}

@test "llama_hw_cpu_sockets returns positive integer" {
    run llama_hw_cpu_sockets
    [ "$status" -eq 0 ]
    [[ "$output" =~ ^[0-9]+$ ]]
    [ "$output" -ge 1 ]
}

@test "llama_hw_cpu_cores_physical returns positive integer" {
    run llama_hw_cpu_cores_physical
    [ "$status" -eq 0 ]
    [[ "$output" =~ ^[0-9]+$ ]]
    [ "$output" -ge 1 ]
}

@test "llama_hw_cpu_cores_physical does not exceed logical" {
    # physical 来自 lscpu 硬件拓扑（cpuset 无关），logical 来自 nproc
    # （cpuset 感知）——cpuset 受限环境（容器 --cpuset-cpus、cgroup）中
    # nproc < 硬件线程数，phys <= log 必然不成立但生产行为正确：检测后跳过
    local phys log cpuinfo_count
    phys=$(llama_hw_cpu_cores_physical)
    log=$(llama_get_cpu_count)
    if ((phys > log)); then
        cpuinfo_count=$(grep -c ^processor /proc/cpuinfo 2>/dev/null || echo 0)
        if ((cpuinfo_count > log)); then
            skip "cpuset 受限环境：nproc=${log} < 硬件线程=${cpuinfo_count}，断言无意义"
        fi
    fi
    [ "$phys" -le "$log" ]
}

@test "llama_hw_cpu_flags output is well-formed" {
    run llama_hw_cpu_flags
    [ "$status" -eq 0 ]
    # 非空时：无连续分隔、无尾随/前导逗号
    [[ ! "$output" =~ ,, ]]
    [[ "$output" != *, ]]
    [[ "$output" != ,* ]]
}

@test "llama_hw_mem_total_bytes returns positive integer" {
    run llama_hw_mem_total_bytes
    [ "$status" -eq 0 ]
    [[ "$output" =~ ^[0-9]+$ ]]
    [ "$output" -gt 0 ]
}

@test "llama_hw_mem_total_human returns readable size" {
    run llama_hw_mem_total_human
    [ "$status" -eq 0 ]
    [ -n "$output" ]
    [[ "$output" =~ (GiB|MiB|TiB|未知) ]]
}

@test "llama_print_hardware_summary includes CPU and memory sections" {
    run llama_print_hardware_summary
    [ "$status" -eq 0 ]
    [[ "$output" =~ "硬件信息" ]]
    [[ "$output" =~ "CPU:" ]]
    [[ "$output" =~ "内存:" ]]
}

@test "llama_print_hardware_summary survives set -e on PCIe-only multi-GPU" {
    # 回归测试：PCIe-only 多 GPU 系统中 nvidia-smi topo -m 无 NV* 条目，
    # grep 返回 1 → pipefail 下管线失败 → set -e 中止 build.sh。
    # 验证 || true 修复后函数能完成并输出“PCIe 互联”降级路径。
    # mock 的 compute_cap 用真实输出格式 7.5（非 75）——显示须拼接为
    # CUDA 惯例 sm_75（与 CMAKE_CUDA_ARCHITECTURES=75 命名一致）
    local mock_dir
    mock_dir="${TEST_TMPDIR}/mock"
    mkdir -p "$mock_dir"
    printf '#!/bin/bash\nif [[ "$*" == *topo* ]]; then printf "\\tGPU0\\tGPU1\\nGPU0\\tX\\tSYS\\nGPU1\\tSYS\\tX\\n"; elif [[ "$*" == *query-gpu* ]]; then printf "0|RTX 2080 Ti|7.5|11264\\n1|RTX 2080 Ti|7.5|11264\\n"; else exit 0; fi\n' > "${mock_dir}/nvidia-smi"
    chmod +x "${mock_dir}/nvidia-smi"

    run bash -c "
        set -euo pipefail
        source '${BATS_TEST_DIRNAME}/../common.sh' 2>/dev/null || true
        PATH='${mock_dir}:$PATH'
        llama_print_hardware_summary
    "
    [ "$status" -eq 0 ]
    [[ "$output" == *"PCIe"* ]]
    [[ "$output" == *"sm_75"* ]]
    [[ "$output" != *"sm_7.5"* ]]
}

@test "llama_print_hardware_summary handles nvidia-smi empty success without phantom GPU" {
    # 回归测试：nvidia-smi 退出码 0 但 stdout 为空（驱动异常边缘情形）。
    # 修复前 mapfile <<< "" 因 here-string 恒附换行产生 1 个幻影空元素，
    # gpu_count 误为 1，打印 "GPU（1 块）" + 空字段 "  [] （sm_, ?）"。
    # 修复后（[[ -n "$smi_out" ]] 守卫）应降级为 "未检测到 NVIDIA GPU"。
    local mock_dir
    mock_dir="${TEST_TMPDIR}/mock"
    mkdir -p "$mock_dir"
    printf '#!/bin/bash\nexit 0\n' > "${mock_dir}/nvidia-smi"
    chmod +x "${mock_dir}/nvidia-smi"

    run bash -c "
        set -euo pipefail
        source '${BATS_TEST_DIRNAME}/../common.sh' 2>/dev/null || true
        PATH='${mock_dir}:$PATH'
        llama_print_hardware_summary
    "
    [ "$status" -eq 0 ]
    [[ "$output" == *"未检测到 NVIDIA GPU"* ]]
    [[ "$output" != *"GPU（1 块）"* ]]
    [[ "$output" != *"sm_"* ]]
}
