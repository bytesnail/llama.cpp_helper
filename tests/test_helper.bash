#!/usr/bin/env bats

setup() {
    export TEST_TMPDIR
    TEST_TMPDIR=$(mktemp -d)
    export LOCK_FILE="${TEST_TMPDIR}/test.lock"
}

teardown() {
    rm -rf "${TEST_TMPDIR:-}"
}
