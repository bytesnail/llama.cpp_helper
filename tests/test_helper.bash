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

# Usage: _load_common / _load_build / _load_update
# 被测脚本的一行式加载器：common.sh 直接 source（屏蔽防直接执行守卫的
# stderr——source 场景本不触发，属双保险）；入口脚本用 _LLAMA_SOURCE_ONLY=1
# 提取模式（跳过锁/trap/严格模式等副作用，仅加载函数定义）。策略点只在
# 本文件维护一份，60+ 个调用点不留咒语拷贝。
_load_common() { source "${BATS_TEST_DIRNAME}/../common.sh" 2>/dev/null || true; }
_load_build()  { _LLAMA_SOURCE_ONLY=1 source "${BATS_TEST_DIRNAME}/../build.sh"; }
_load_update() { _LLAMA_SOURCE_ONLY=1 source "${BATS_TEST_DIRNAME}/../update.sh"; }

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
# 构造 fake 构建仓库：build/bin 下全部必需二进制（可执行）、git 初始
# commit、.build-stamp（默认写当前 HEAD；传参可写任意内容制造不匹配）。
# 二进制清单以 config.sh 的 REQUIRED_BINARIES 为单一事实来源（调用方未
# 定义时回退默认两个）——清单漂移时夹具自动跟随，不会从假绿变假红。
_make_fake_built_repo() {
    local repo="$1"
    mkdir -p "${repo}/build/bin"
    local -a bins=("llama-cli" "llama-server")
    if [[ -n "${REQUIRED_BINARIES[*]:-}" ]]; then
        bins=("${REQUIRED_BINARIES[@]}")
    fi
    local b
    for b in "${bins[@]}"; do
        touch "${repo}/build/bin/$b"
        chmod +x "${repo}/build/bin/$b"
    done
    _init_git_repo "$repo"
    local head
    head=$(git -C "$repo" rev-parse HEAD)
    printf '%s\n' "${2:-$head}" > "${repo}/build/.build-stamp"
}

# Usage: _make_mock_conda <dir> [activate_rc] [activate_log]
# 构造 mock conda 安装（bin/conda stub + etc/profile.d/conda.sh 定义的
# conda() 函数）：activate 子命令导出 CONDA_PREFIX/CONDA_DEFAULT_ENV 模拟
# 真实激活，按 <activate_rc> 返回（默认 0；非 0 时向 stderr 打印 mock
# 失败消息——与真实 conda 报错形态一致）；给定 <activate_log> 时把每次
# 激活的环境名追加到该文件（供断言"强制切换"）。接口形态（函数名 conda、
# activate 子命令、导出约定）只在此维护一份，此前散落约 9 份手写拷贝。
_make_mock_conda() {
    local dir="$1"
    local activate_rc="${2:-0}"
    local activate_log="${3:-}"
    mkdir -p "${dir}/etc/profile.d" "${dir}/bin"
    _make_stub_exec "${dir}/bin/conda"
    # shellcheck disable=SC2016  # 生成器刻意输出字面 $：单引号内的 $1/$2/${2:-base} 属于 stub 脚本体，非遗漏展开
    {
        printf 'conda() {\n'
        printf '    if [[ "$1" == "activate" ]]; then\n'
        if [[ -n "$activate_log" ]]; then
            printf '        echo "activate $2" >> %q\n' "$activate_log"
        fi
        printf '        export CONDA_PREFIX="%s/envs/${2:-base}"\n' "$dir"
        printf '        export CONDA_DEFAULT_ENV="${2:-base}"\n'
        if [[ "$activate_rc" != "0" ]]; then
            printf '        echo "mock conda: 环境不存在或激活失败（%s）" >&2\n' "$activate_rc"
        fi
        printf '        return %s\n' "$activate_rc"
        printf '    fi\n'
        printf '}\n'
    } > "${dir}/etc/profile.d/conda.sh"
}

# Usage: _mock_curl_response <http_code> <body>
# 生成 mock curl 脚本体（供 _make_stub_exec 使用）：解析 -o 参数写入
# <body>，输出 <http_code> 作为 %{http_code} 结果。
# body 双层转义：先转 heredoc 展开层（\ $ `），再转生成脚本的单引号层
#（' → '\''）——否则 body 含单引号会破坏 stub 语法、含 $/反引号会在
# 生成期被当前 shell 意外展开（已实证脆性）。
_mock_curl_response() {
    local http_code="$1"
    local body="$2"
    local esc="${body//\\/\\\\}"
    esc="${esc//\$/\\$}"
    esc="${esc//\`\\/\\\`}"
    esc="${esc//\'/\'\\\'\'}"
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
printf '%s' '${esc}' > "\$tmp_file"
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
