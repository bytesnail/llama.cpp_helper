#!/usr/bin/env bash
# ============================================================
# test_helper.bash — bats 共享 fixture 与辅助函数库
# 由每个 test_*.bats 通过 `load test_helper` 加载（.bash 是被加载的库文件，
# 不是测试文件）。提供：临时目录隔离、最小 git 仓库、mock/stub 构造器。
# ============================================================

# Usage: _setup_tmpdir
# 每个测试前调用（setup()）：创建独立临时目录，在其中构造最小 git 仓库
# 并 export LLAMA_CPP_SRC 指向它（覆盖 config.sh 的默认生产路径），
# 同时 export LOCK_FILE 到临时目录。测试绝不应修改生产环境的 llama.cpp。
_setup_tmpdir() {
    export TEST_TMPDIR
    TEST_TMPDIR=$(mktemp -d)
    # 测试绝不应修改生产环境的 llama.cpp 仓库。此处创建最小 git 仓库，
    # 所有测试操作均在此临时仓库中进行，teardown 时自动清理。
    export LLAMA_CPP_SRC="${TEST_TMPDIR}/llama.cpp"
    mkdir -p "${LLAMA_CPP_SRC}"
    _init_git_repo "${LLAMA_CPP_SRC}"
    export LOCK_FILE="${TEST_TMPDIR}/test.lock"
}

# Usage: _teardown_tmpdir
# 每个测试后调用（teardown()）：递归删除临时目录。
_teardown_tmpdir() {
    rm -rf "${TEST_TMPDIR:-}"
}

# Usage: _init_git_repo <path>
# 初始化 git 仓库并配置测试身份、创建初始空 commit。
# 各测试自建仓库时必须使用本函数——裸 git init + commit 在无全局
# user.name/user.email 的机器上会静默失败，产生假阳性/假阴性。
_init_git_repo() {
    local repo="$1"
    git -C "$repo" init -q
    git -C "$repo" config user.email "test@test.test"
    git -C "$repo" config user.name "Test"
    # 沙盒仓局部关闭签名：全局 tag.gpgsign=true 会使 git tag 转为带签名
    # 附注标签（需要说明/交互）而在 bats 中非交互失败——与身份同理，
    # 全局配置不得泄漏进测试仓（commit.gpgsign 一并关闭，测试仓永不签名）
    git -C "$repo" config tag.gpgsign false
    git -C "$repo" config commit.gpgsign false
    git -C "$repo" commit --allow-empty -q -m "test-init"
}

# Usage: _make_stub_exec <path> [body]
# 创建可执行 stub 脚本（默认空 bash 脚本；body 为可选脚本体）。
# 替代套件中 13+ 处重复的「echo '#!/bin/bash' > x; chmod +x x」模式。
_make_stub_exec() {
    local path="$1"
    local body="${2:-}"
    {
        echo '#!/bin/bash'
        [[ -n "$body" ]] && printf '%s\n' "$body"
    } > "$path"
    chmod +x "$path"
}

# Usage: _make_fake_built_repo <path> [stamp_content]
# 构造 fake 构建仓库：build/bin 下两个必需二进制（可执行）、git 初始
# commit、.build-stamp（默认写当前 HEAD；传参可写任意内容制造不匹配）。
_make_fake_built_repo() {
    local repo="$1"
    mkdir -p "${repo}/build/bin"
    local b
    for b in llama-cli llama-server; do
        touch "${repo}/build/bin/$b"
        chmod +x "${repo}/build/bin/$b"
    done
    _init_git_repo "$repo"
    local head
    head=$(git -C "$repo" rev-parse HEAD)
    printf '%s\n' "${2:-$head}" > "${repo}/build/.build-stamp"
}

# Usage: _mock_curl_response <http_code> <body>
# 生成 mock curl 脚本体（供 _make_stub_exec 使用）：解析 -o 参数写入
# <body>，输出 <http_code> 作为 %{http_code} 结果。
_mock_curl_response() {
    local http_code="$1"
    local body="$2"
    cat <<MOCK_EOF
tmp_file=""
while [[ \$# -gt 0 ]]; do
    case "\$1" in
        -o) tmp_file="\$2"; shift 2 ;;
        -w) shift 2 ;;
        -H) shift 2 ;;
        --*) shift ;;
        *) shift ;;
    esac
done
printf '%s' '${body}' > "\$tmp_file"
echo "${http_code}"
MOCK_EOF
}

setup() {
    _setup_tmpdir
}

teardown() {
    if [[ -n "${LOCK_FD:-}" ]]; then
        # 不能加 2>/dev/null：无命令 exec 的重定向会永久改变当前 shell 的
        # stderr；bash 关闭已关闭的 fd 静默返回 0，无需错误屏蔽
        exec {LOCK_FD}>&-
    fi
    _teardown_tmpdir
}
