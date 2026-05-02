#!/usr/bin/env bats

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
    _teardown_tmpdir
}
