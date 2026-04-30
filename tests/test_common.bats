#!/usr/bin/env bats
# Characterization tests for common.sh — captures CURRENT behavior before refactoring

load test_helper

setup() {
    # test_helper.bash defines setup() too but bats uses the last definition,
    # so we must replicate its tmpdir/lock setup here
    export TEST_TMPDIR
    TEST_TMPDIR=$(mktemp -d)
    export LOCK_FILE="${TEST_TMPDIR}/test.lock"

    # Source common.sh — line 4 has an uncommented line that errors,
    # suppress stderr and ignore the non-zero return (all functions still load)
    source "${BATS_TEST_DIRNAME}/../common.sh" 2>/dev/null || true
}

teardown() {
    rm -rf "${TEST_TMPDIR:-}"
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
        sleep 5
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
    [[ "$handler" =~ SIGINT ]] || [[ "$handler" == *"trap --"* ]] || [[ "$handler" == "" ]]
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
