
_setup_tmpdir() {
    export TEST_TMPDIR
    TEST_TMPDIR=$(mktemp -d)
    export LOCK_FILE="${TEST_TMPDIR}/test.lock"
}

_teardown_tmpdir() {
    rm -rf "${TEST_TMPDIR:-}"
}

setup() {
    _setup_tmpdir
}

teardown() {
    if [[ -n "${LOCK_FD:-}" ]]; then
        exec {LOCK_FD}>&- 2>/dev/null || true
    fi
    _teardown_tmpdir
}
