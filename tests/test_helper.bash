
_setup_tmpdir() {
    export TEST_TMPDIR
    TEST_TMPDIR=$(mktemp -d)
    # 测试绝不应修改生产环境的 llama.cpp 仓库。此处创建最小 git 仓库，
    # 所有测试操作均在此临时仓库中进行，teardown 时自动清理。
    export LLAMA_CPP_SRC="${TEST_TMPDIR}/llama.cpp"
    mkdir -p "${LLAMA_CPP_SRC}"
    git -C "${LLAMA_CPP_SRC}" init -q
    git -C "${LLAMA_CPP_SRC}" config user.email "test@test.test"
    git -C "${LLAMA_CPP_SRC}" config user.name "Test"
    git -C "${LLAMA_CPP_SRC}" commit --allow-empty -q -m "test-init"
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
