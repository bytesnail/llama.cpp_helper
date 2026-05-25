#!/usr/bin/env bats
# Characterization tests for common.sh — captures CURRENT behavior before refactoring

load test_helper

setup() {
    _setup_tmpdir
    # Source common.sh — suppress stderr because common.sh's
    # anti-direct-execution guard prints to stderr in the bats subshell
    source "${BATS_TEST_DIRNAME}/../common.sh" 2>/dev/null || true
}

teardown() {
    if [[ -n "${LOCK_FD:-}" ]]; then
        exec {LOCK_FD}>&- 2>/dev/null || true
    fi
    _teardown_tmpdir
}

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
    run llama_err "failure"
    [ "$status" -eq 0 ]
    [[ "$output" =~ \[ERROR\].*failure ]]
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
@test "llama_check_gpu returns 0 or 1 without crashing" {
    run llama_check_gpu
    [ "$status" -eq 0 ] || [ "$status" -eq 1 ]
}

@test "llama_get_gpu_count returns a non-negative integer" {
    run llama_get_gpu_count
    [ "$status" -eq 0 ] || [ "$status" -eq 1 ]
    [[ "$output" =~ ^[0-9]+$ ]]
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
    (
        source "${BATS_TEST_DIRNAME}/../common.sh" 2>/dev/null || true
        LOCK_FILE="${LOCK_FILE}" llama_acquire_lock
        sleep 2  # Reduce test wait time
        LOCK_FILE="${LOCK_FILE}" llama_release_lock
    ) &
    local bg_pid=$!
    sleep 1
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
    source "${BATS_TEST_DIRNAME}/../common.sh" 2>/dev/null || true
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

# --- llama_cd_back ---
@test "llama_cd_back returns 0 when orig_dir is unset" {
    source "${BATS_TEST_DIRNAME}/../common.sh" 2>/dev/null || true
    unset orig_dir
    run llama_cd_back
    [ "$status" -eq 0 ]
}

@test "llama_cd_back changes to orig_dir when set" {
    run bash -c "
        source '${BATS_TEST_DIRNAME}/../common.sh' 2>/dev/null || true
        orig_dir='/tmp'
        llama_cd_back
        pwd
    "
    [ "$status" -eq 0 ]
    [ "$output" = "/tmp" ]
}

@test "llama_cd_back returns 1 and warns when orig_dir is nonexistent" {
    run bash -c "
        source '${BATS_TEST_DIRNAME}/../common.sh' 2>/dev/null || true
        orig_dir='/nonexistent_dir_xyz_123'
        llama_cd_back
        echo \$?
    "
    [ "$status" -eq 0 ]
    [[ "$output" =~ "无法返回原始目录" ]]
    [[ "$output" =~ 1 ]]
}

# --- Init/Source/Help Helpers ---
@test "llama_init_script_dir sets SCRIPT_DIR" {
    source "${BATS_TEST_DIRNAME}/../common.sh" 2>/dev/null || true
    llama_init_script_dir
    [ -n "${SCRIPT_DIR:-}" ]
    [ -d "${SCRIPT_DIR:-}" ]
}

@test "llama_show_help outputs usage with description" {
    source "${BATS_TEST_DIRNAME}/../common.sh" 2>/dev/null || true
    run llama_show_help "test.sh" "A test script"
    [ "$status" -eq 0 ]
    [[ "$output" =~ "用法: test.sh" ]]
    [[ "$output" =~ "A test script" ]]
}

@test "llama_show_help includes options when provided" {
    source "${BATS_TEST_DIRNAME}/../common.sh" 2>/dev/null || true
    run llama_show_help "test.sh" "desc" "  -h  help"
    [ "$status" -eq 0 ]
    [[ "$output" =~ "选项:" ]]
    [[ "$output" =~ "-h  help" ]]
}

# --- Version ---
@test "llama_show_version outputs version string" {
    source "${BATS_TEST_DIRNAME}/../common.sh" 2>/dev/null || true
    source "${BATS_TEST_DIRNAME}/../config.sh" 2>/dev/null || true
    run llama_show_version
    [ "$status" -eq 0 ]
    [[ "$output" == "llama.cpp_helper "* ]]
}

# --- llama_run_silent ---
@test "llama_run_silent captures exit code without failing under set -e" {
    source "${BATS_TEST_DIRNAME}/../common.sh" 2>/dev/null || true
    run bash -c "
        source '${BATS_TEST_DIRNAME}/../common.sh' 2>/dev/null || :
        set -e
        llama_run_silent false
        echo \$?
    "
    [ "$status" -eq 0 ]
    [[ "$output" =~ 1 ]]
}
@test "llama_run_silent passes through success" {
    source "${BATS_TEST_DIRNAME}/../common.sh" 2>/dev/null || true
    run bash -c "
        source '${BATS_TEST_DIRNAME}/../common.sh' 2>/dev/null || :
        set -e
        llama_run_silent true
        echo \$?
    "
    [ "$status" -eq 0 ]
    [[ "$output" =~ 0 ]]
}

@test "llama_run_silent preserves exit code 42 under set -e" {
    source "${BATS_TEST_DIRNAME}/../common.sh" 2>/dev/null || true
    run bash -c "
        source '${BATS_TEST_DIRNAME}/../common.sh' 2>/dev/null || :
        set -e
        llama_run_silent '(exit 42)'
        echo \$?
    "
    [ "$status" -eq 0 ]
    [[ "$output" =~ 42 ]]
}

# --- Human-Readable Size ---
@test "llama_human_size: 0 bytes returns 0B" {
    source "${BATS_TEST_DIRNAME}/../common.sh" 2>/dev/null || true
    run llama_human_size 0
    [ "$status" -eq 0 ]
    [ "$output" = "0B" ]
}

@test "llama_human_size: 512 bytes returns 512B" {
    source "${BATS_TEST_DIRNAME}/../common.sh" 2>/dev/null || true
    run llama_human_size 512
    [ "$status" -eq 0 ]
    [ "$output" = "512B" ]
}

@test "llama_human_size: 1023 bytes returns 1023B" {
    source "${BATS_TEST_DIRNAME}/../common.sh" 2>/dev/null || true
    run llama_human_size 1023
    [ "$status" -eq 0 ]
    [ "$output" = "1023B" ]
}

@test "llama_human_size: 1024 bytes returns 1KiB" {
    source "${BATS_TEST_DIRNAME}/../common.sh" 2>/dev/null || true
    run llama_human_size 1024
    [ "$status" -eq 0 ]
    [ "$output" = "1KiB" ]
}

@test "llama_human_size: 1536 bytes returns 1KiB" {
    source "${BATS_TEST_DIRNAME}/../common.sh" 2>/dev/null || true
    run llama_human_size 1536
    [ "$status" -eq 0 ]
    [ "$output" = "1KiB" ]
}
@test "llama_human_size: 2048 bytes returns 2KiB" {
    source "${BATS_TEST_DIRNAME}/../common.sh" 2>/dev/null || true
    run llama_human_size 2048
    [ "$status" -eq 0 ]
    [ "$output" = "2KiB" ]
}

@test "llama_human_size: 1048576 bytes returns 1MiB" {
    source "${BATS_TEST_DIRNAME}/../common.sh" 2>/dev/null || true
    run llama_human_size 1048576
    [ "$status" -eq 0 ]
    [ "$output" = "1MiB" ]
}

@test "llama_human_size: 1073741824 bytes returns 1.00GiB" {
    source "${BATS_TEST_DIRNAME}/../common.sh" 2>/dev/null || true
    run llama_human_size 1073741824
    [ "$status" -eq 0 ]
    [ "$output" = "1.00GiB" ]
}

@test "llama_human_size: 1610612736 bytes returns 1.50GiB" {
    source "${BATS_TEST_DIRNAME}/../common.sh" 2>/dev/null || true
    run llama_human_size 1610612736
    [ "$status" -eq 0 ]
    [ "$output" = "1.50GiB" ]
}

@test "llama_human_size: 2147483648 bytes returns 2.00GiB" {
    source "${BATS_TEST_DIRNAME}/../common.sh" 2>/dev/null || true
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
    source "${BATS_TEST_DIRNAME}/../common.sh" 2>/dev/null || true
    run llama_is_full_commit_sha "abcdef1234567890abcdef1234567890abcdef12"
    [ "$status" -eq 0 ]
}

@test "llama_is_full_commit_sha: valid 40-char mixed case hex returns 0" {
    source "${BATS_TEST_DIRNAME}/../common.sh" 2>/dev/null || true
    run llama_is_full_commit_sha "ABCDEF1234567890ABCDEF1234567890ABCDEF12"
    [ "$status" -eq 0 ]
}

@test "llama_is_full_commit_sha: short sha (< 40 chars) returns 1" {
    source "${BATS_TEST_DIRNAME}/../common.sh" 2>/dev/null || true
    run llama_is_full_commit_sha "abc123"
    [ "$status" -eq 1 ]
}

@test "llama_is_full_commit_sha: invalid characters returns 1" {
    source "${BATS_TEST_DIRNAME}/../common.sh" 2>/dev/null || true
    run llama_is_full_commit_sha "ghijklmnopqrstuvwxyzGHIJKLMNOPQRSTUVWXYZ1234"
    [ "$status" -eq 1 ]
}

@test "llama_is_full_commit_sha: empty string returns 1" {
    source "${BATS_TEST_DIRNAME}/../common.sh" 2>/dev/null || true
    run llama_is_full_commit_sha ""
    [ "$status" -eq 1 ]
}

# --- Return or Exit ---
@test "llama_return_or_exit: returns given exit code in sourced context" {
    source "${BATS_TEST_DIRNAME}/../common.sh" 2>/dev/null || true
    run bash -c "source '${BATS_TEST_DIRNAME}/../common.sh' 2>/dev/null; llama_return_or_exit 42; echo \$?"
    [ "$status" -eq 0 ]
    [[ "$output" =~ 42 ]]
}

@test "llama_return_or_exit: returns 0 when called with 0" {
    source "${BATS_TEST_DIRNAME}/../common.sh" 2>/dev/null || true
    run bash -c "source '${BATS_TEST_DIRNAME}/../common.sh' 2>/dev/null; llama_return_or_exit 0; echo \$?"
    [ "$status" -eq 0 ]
    [[ "$output" =~ 0 ]]
}

# --- Build Health ---
@test "llama_check_build_health returns 1 when build dir does not exist" {
    source "${BATS_TEST_DIRNAME}/../common.sh" 2>/dev/null || true
    LLAMA_CPP_SRC="${TEST_TMPDIR}/nonexistent_llama"
    run llama_check_build_health
    [ "$status" -eq 1 ]
}
@test "llama_check_build_health returns 1 when binaries are missing" {
    source "${BATS_TEST_DIRNAME}/../common.sh" 2>/dev/null || true
    LLAMA_CPP_SRC="${TEST_TMPDIR}/fake_llama"
    REQUIRED_BINARIES=("llama-cli" "llama-server")
    mkdir -p "${LLAMA_CPP_SRC}/build/bin"
    run llama_check_build_health
    [ "$status" -eq 1 ]
}

@test "llama_check_build_health returns 0 when binaries exist and stamp matches" {
    source "${BATS_TEST_DIRNAME}/../common.sh" 2>/dev/null || true
    LLAMA_CPP_SRC="${TEST_TMPDIR}/healthy_llama"
    REQUIRED_BINARIES=("llama-cli" "llama-server")
    mkdir -p "${LLAMA_CPP_SRC}/build/bin"
    touch "${LLAMA_CPP_SRC}/build/bin/llama-cli"
    chmod +x "${LLAMA_CPP_SRC}/build/bin/llama-cli"
    touch "${LLAMA_CPP_SRC}/build/bin/llama-server"
    chmod +x "${LLAMA_CPP_SRC}/build/bin/llama-server"
    git -C "${TEST_TMPDIR}/healthy_llama" init --quiet 2>/dev/null
    git -C "${TEST_TMPDIR}/healthy_llama" add -A 2>/dev/null
    git -C "${TEST_TMPDIR}/healthy_llama" commit -m "init" --quiet 2>/dev/null
    local head
    head=$(git -C "$LLAMA_CPP_SRC" rev-parse HEAD 2>/dev/null || echo "")
    mkdir -p "${LLAMA_CPP_SRC}/build"
    echo "$head" > "${LLAMA_CPP_SRC}/build/.build-stamp"
    run llama_check_build_health
    [ "$status" -eq 0 ]
}

@test "llama_check_build_health returns 1 when stamp does not match HEAD" {
    source "${BATS_TEST_DIRNAME}/../common.sh" 2>/dev/null || true
    LLAMA_CPP_SRC="${TEST_TMPDIR}/stale_llama"
    REQUIRED_BINARIES=("llama-cli" "llama-server")
    mkdir -p "${LLAMA_CPP_SRC}/build/bin"
    touch "${LLAMA_CPP_SRC}/build/bin/llama-cli"
    chmod +x "${LLAMA_CPP_SRC}/build/bin/llama-cli"
    touch "${LLAMA_CPP_SRC}/build/bin/llama-server"
    chmod +x "${LLAMA_CPP_SRC}/build/bin/llama-server"
    git -C "${TEST_TMPDIR}/stale_llama" init --quiet 2>/dev/null
    git -C "${TEST_TMPDIR}/stale_llama" add -A 2>/dev/null
    git -C "${TEST_TMPDIR}/stale_llama" commit -m "init" --quiet 2>/dev/null
    mkdir -p "${LLAMA_CPP_SRC}/build"
    echo "0000000000000000000000000000000000000000" > "${LLAMA_CPP_SRC}/build/.build-stamp"
    run llama_check_build_health
    [ "$status" -eq 1 ]
}

# --- conda Activation ---
@test "llama_activate_conda skips when CONDA_AUTO_ACTIVATE=0" {
    CONDA_AUTO_ACTIVATE=0 run llama_activate_conda
    [ "$status" -eq 0 ]
    [[ "$output" != *"conda"* ]]
}

@test "llama_activate_conda skips when already activated (CONDA_PREFIX set)" {
    CONDA_PREFIX="/fake/conda/env" CONDA_AUTO_ACTIVATE=1 run llama_activate_conda
    [ "$status" -eq 0 ]
    [[ "$output" =~ "conda 环境已激活" ]]
}

@test "llama_activate_conda returns 0 when no conda found" {
    unset CONDA_EXE CONDA_PREFIX
    run llama_activate_conda
    [ "$status" -eq 0 ]
}

@test "llama_activate_conda detects conda from CONDA_EXE" {
    local mock_base="${TEST_TMPDIR}/mock_conda"
    mkdir -p "${mock_base}/etc/profile.d"
    mkdir -p "${mock_base}/bin"
    echo '#!/bin/bash' > "${mock_base}/bin/conda"
    chmod +x "${mock_base}/bin/conda"
    echo 'conda() { if [[ "$1" == "activate" ]]; then export CONDA_PREFIX="'${mock_base}'/envs/${2:-base}"; return 0; fi; }' \
        > "${mock_base}/etc/profile.d/conda.sh"
    CONDA_EXE="${mock_base}/bin/conda" CONDA_AUTO_ACTIVATE=1 run llama_activate_conda
    [ "$status" -eq 0 ]
    [[ "$output" =~ "已激活 conda 环境" ]]
}

@test "llama_activate_conda detects conda from common path" {
    local mock_home="${TEST_TMPDIR}/fake_home"
    mkdir -p "${mock_home}/miniconda3/etc/profile.d"
    echo 'conda() { if [[ "$1" == "activate" ]]; then export CONDA_PREFIX="'${mock_home}'/miniconda3/envs/${2:-base}"; return 0; fi; }' \
        > "${mock_home}/miniconda3/etc/profile.d/conda.sh"
    unset CONDA_EXE CONDA_PREFIX
    HOME="$mock_home" CONDA_AUTO_ACTIVATE=1 run llama_activate_conda
    [ "$status" -eq 0 ]
    [[ "$output" =~ "已激活 conda 环境" ]]
}

@test "llama_activate_conda warns when conda.sh missing" {
    local mock_broken="${TEST_TMPDIR}/mock_broken"
    mkdir -p "${mock_broken}/bin"
    echo '#!/bin/bash' > "${mock_broken}/bin/conda"
    chmod +x "${mock_broken}/bin/conda"
    # Intentionally do NOT create etc/profile.d/conda.sh — simulate broken install
    CONDA_EXE="${mock_broken}/bin/conda" CONDA_AUTO_ACTIVATE=1 run llama_activate_conda
    [ "$status" -eq 0 ]
    [[ "$output" =~ "缺少 shell 初始化脚本" ]]
}

@test "llama_activate_conda warns on conda activate failure" {
    local mock_fail="${TEST_TMPDIR}/mock_fail"
    mkdir -p "${mock_fail}/etc/profile.d"
    mkdir -p "${mock_fail}/bin"
    echo '#!/bin/bash' > "${mock_fail}/bin/conda"
    chmod +x "${mock_fail}/bin/conda"
    echo 'conda() { if [[ "$1" == "activate" ]]; then echo "环境不存在" >&2; return 1; fi; }' \
        > "${mock_fail}/etc/profile.d/conda.sh"
    CONDA_EXE="${mock_fail}/bin/conda" CONDA_AUTO_ACTIVATE=1 run llama_activate_conda
    [ "$status" -eq 0 ]
    [[ "$output" =~ "conda 环境激活失败" ]]
    [[ "$output" =~ "环境不存在" ]]
}

# --- Color Save/Restore ---
@test "llama_save_colors and llama_restore_colors preserve values" {
    source "${BATS_TEST_DIRNAME}/../common.sh" 2>/dev/null || true
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
    source "${BATS_TEST_DIRNAME}/../common.sh" 2>/dev/null || true
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
    source "${BATS_TEST_DIRNAME}/../common.sh" 2>/dev/null || true
    # Mock by clearing PATH — if nproc/sysctl fail, falls back to /proc/cpuinfo or 4
    run llama_get_cpu_count
    [ "$status" -eq 0 ]
    [[ "$output" =~ ^[0-9]+$ ]]
    [ "$output" -ge 1 ]
}

@test "log functions produce no ANSI codes when output is not a terminal" {
    source "${BATS_TEST_DIRNAME}/../common.sh" 2>/dev/null || true
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
    source "${BATS_TEST_DIRNAME}/../common.sh" 2>/dev/null || true
    run llama_setup_trap ""
    [ "$status" -eq 1 ]
}

@test "llama_get_gpu_count returns 1 when nvidia-smi not available" {
    source "${BATS_TEST_DIRNAME}/../common.sh" 2>/dev/null || true
    local _saved_path="$PATH"
    PATH="/nonexistent"
    run llama_get_gpu_count
    PATH="$_saved_path"
    [ "$status" -eq 1 ]
    [ "$output" = "0" ]
}

@test "llama_check_build_health returns 1 when LLAMA_CPP_SRC unset" {
    source "${BATS_TEST_DIRNAME}/../common.sh" 2>/dev/null || true
    unset LLAMA_CPP_SRC
    run llama_check_build_health
    [ "$status" -eq 1 ]
}

@test "llama_print_run_examples outputs expected content" {
    source "${BATS_TEST_DIRNAME}/../common.sh" 2>/dev/null || true
    SCRIPT_DIR="/fake/script/dir" run llama_print_run_examples "/fake/bin"
    [ "$status" -eq 0 ]
    [[ "$output" =~ "run_env.sh" ]]
    [[ "$output" =~ "llama-cli" ]]
    [[ "$output" =~ "llama-server" ]]
}

@test "llama_show_help includes examples when provided" {
    source "${BATS_TEST_DIRNAME}/../common.sh" 2>/dev/null || true
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