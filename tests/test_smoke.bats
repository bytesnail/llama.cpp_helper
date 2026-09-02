#!/usr/bin/env bats

load test_helper

@test "shellcheck is available" {
    command -v shellcheck
}

@test "all scripts pass bash -n syntax check" {
    for script in common.sh config.sh build.sh update.sh run_env.sh; do
        run bash -n "${BATS_TEST_DIRNAME}/../${script}"
        [ "$status" -eq 0 ]
    done
}

@test "all scripts have correct shebang line" {
    for script in common.sh config.sh build.sh update.sh run_env.sh; do
        local first_line
        first_line=$(head -1 "${BATS_TEST_DIRNAME}/../${script}")
        [[ "$first_line" == "#!/bin/bash" ]]
    done
}

@test "config.sh exports all expected variables" {
    # Source config.sh in a subshell with a fake project root
    run bash -c "
        _LLAMA_PROJECT_ROOT='${TEST_TMPDIR}'
        source '${BATS_TEST_DIRNAME}/../config.sh' 2>/dev/null
        [[ -n \"\${LLAMA_CPP_SRC}\" ]]
        [[ -n \"\${REPO}\" ]]
        [[ -n \"\${LLAMA_HELPER_VERSION}\" ]]
        [[ -n \"\${MIN_FREE_DISK_GB}\" ]]
    "
    [ "$status" -eq 0 ]
}

@test "config.sh honors environment variable overrides" {
    # config.sh uses \${VAR:-default} pattern — env vars should take precedence
    run bash -c "
        _LLAMA_PROJECT_ROOT='${TEST_TMPDIR}'
        LLAMA_CPP_SRC='/custom/src/path'
        CMAKE_BUILD_TYPE='Debug'
        CMAKE_CUDA_ARCHITECTURES='86'
        GGML_BLAS='OFF'
        source '${BATS_TEST_DIRNAME}/../config.sh' 2>/dev/null
        [[ \"\$LLAMA_CPP_SRC\" == \"/custom/src/path\" ]]
        [[ \"\$CMAKE_BUILD_TYPE\" == \"Debug\" ]]
        [[ \"\$CMAKE_CUDA_ARCHITECTURES\" == \"86\" ]]
        [[ \"\$GGML_BLAS\" == \"OFF\" ]]
    "
    [ "$status" -eq 0 ]
}

@test "LLAMA_CMAKE_KNOBS contains exactly the expected cmake knobs" {
    # 旋钮表是 cmake -D 透传的单一事实来源；新增/删除旋钮需同步更新此清单
    run bash -c "
        source '${BATS_TEST_DIRNAME}/../config.sh' 2>/dev/null
        expected='CMAKE_BUILD_TYPE CMAKE_CUDA_ARCHITECTURES CMAKE_CUDA_FLAGS GGML_CUDA GGML_CUDA_PEER_MAX_BATCH_SIZE GGML_CUDA_FA_ALL_QUANTS GGML_CUDA_GRAPHS GGML_NATIVE GGML_BLAS GGML_BLAS_VENDOR LLAMA_BUILD_TESTS'
        [[ \"\${LLAMA_CMAKE_KNOBS[*]}\" == \"\$expected\" ]]
    "
    [ "$status" -eq 0 ]
}

@test "every knob in LLAMA_CMAKE_KNOBS has a non-empty definition" {
    # 表内名字必须对应已定义变量，否则 build.sh 的 \${!knob} 间接展开会在 set -u 下中止
    run bash -c "
        source '${BATS_TEST_DIRNAME}/../config.sh' 2>/dev/null
        [[ \${#LLAMA_CMAKE_KNOBS[@]} -gt 0 ]] || exit 1
        for knob in \"\${LLAMA_CMAKE_KNOBS[@]}\"; do
            [[ -n \"\${!knob}\" ]] || { echo \"knob undefined or empty: \$knob\"; exit 1; }
        done
    "
    [ "$status" -eq 0 ]
}

@test "every variable in config.sh build section is listed in LLAMA_CMAKE_KNOBS" {
    # 反向同步：构建配置节新增的 VAR=\${VAR:-...} 定义必须登记到旋钮表
    run bash -c "
        source '${BATS_TEST_DIRNAME}/../config.sh' 2>/dev/null
        names=\$(sed -n '/^# --- 构建配置/,/^# --- /p' '${BATS_TEST_DIRNAME}/../config.sh' \
            | grep -oP '^[A-Z_]+(?==)' | sort -u)
        [[ -n \"\$names\" ]] || exit 1
        for name in \$names; do
            printf '%s\n' \"\${LLAMA_CMAKE_KNOBS[@]}\" | grep -qx \"\$name\" \
                || { echo \"missing from LLAMA_CMAKE_KNOBS: \$name\"; exit 1; }
        done
    "
    [ "$status" -eq 0 ]
}

@test "no script mixes tabs and spaces for indentation" {
    # All .sh scripts use space indentation per .editorconfig
    # grep 退出码三态须区分：0=命中 tab（违规）、1=无匹配（通过）、
    # ≥2=grep 自身错误（文件缺失/无 PCRE）——此前 `&& exit 1 || true`
    # 把 rc≥2 吞掉，测试在什么都没检查的情况下空转常绿（已实证风险）
    run bash -c "
        for s in common.sh config.sh build.sh update.sh run_env.sh; do
            out=\$(grep -nP '^\t' '${BATS_TEST_DIRNAME}/../'\$s 2>&1)
            rc=\$?
            if [ \"\$rc\" -eq 0 ]; then echo \"tab indentation in \$s: \$out\"; exit 1; fi
            if [ \"\$rc\" -ge 2 ]; then echo \"grep error on \$s: \$out\"; exit 1; fi
        done
        exit 0
    "
    [ "$status" -eq 0 ]
}

@test "config.sh rejects direct execution" {
    run bash "${BATS_TEST_DIRNAME}/../config.sh"
    [ "$status" -ne 0 ]
    [[ "$output" =~ "source" ]]
}

@test "update.sh git invocations all use explicit -C \$LLAMA_CPP_SRC" {
    # C3 契约：update.sh 不再 cd 进仓库（cwd 环境契约已拆除），每个 git 调用
    # （含 _print_recovery_steps 打印给用户的恢复指引）都必须显式携带 -C。
    # sed 先剥行尾注释；第一个 grep 找「git 后随空白」的行——.git/config 等
    # 路径组件（后随 / 或 "）与 gitdir:/"git" 等形态天然不匹配；
    # 第二个 grep 放行紧跟 -C "$LLAMA_CPP_SRC" 的调用——含恢复指引在双引号
    # 字符串内的转义形态 -C \"${LLAMA_CPP_SRC}\"（空格路径下指引可复制执行）。
    # 已知局限（行级检查）：submodule foreach 的内层 'git diff' 由 foreach 自身
    # 提供 cwd，属合法裸调用，靠同行的外层 git -C 放行；git clone 是结构性
    # 例外（目标目录尚不存在，-C 无意义），集中在 _clone_repo 一行并在此登记。
    local violations
    violations=$(grep -vE '^[[:space:]]*#' "${BATS_TEST_DIRNAME}/../update.sh" \
        | sed 's/[[:space:]]#.*$//' \
        | grep -nE 'git[[:space:]]' \
        | grep -vE 'git[[:space:]]+-C[[:space:]]+\\?"?\$\{?LLAMA_CPP_SRC\}?\\?"?|git[[:space:]]+clone' || true)
    if [ -n "$violations" ]; then
        printf 'bare git invocation(s):\n%s\n' "$violations"
    fi
    [ -z "$violations" ]
}

@test "cwd-restore machinery removed: no orig_dir/llama_cd_back/_die_back in scripts" {
    # C3 契约：cwd 环境契约拆除后，保存/恢复工作目录的机制不应再存在
    run bash -c "
        ! grep -nE 'llama_cd_back|_die_back|orig_dir' \
            '${BATS_TEST_DIRNAME}/../update.sh' '${BATS_TEST_DIRNAME}/../common.sh'
    "
    [ "$status" -eq 0 ]
}

@test "release fetchers do not write release_* globals" {
    # C5 契约：_fetch_latest_release（seam）与两个 adapter 经 stdout 返回
    # TAB 行；release_* 全局的写入已收敛到具名入口，fetcher 函数体内
    # 不得出现 release_* 赋值
    local fn body
    for fn in _fetch_latest_release _fetch_latest_release_gh _fetch_latest_release_curl; do
        body=$(sed -n "/^${fn}()/,/^}/p" "${BATS_TEST_DIRNAME}/../update.sh")
        [ -n "$body" ] || { echo "function missing: ${fn}"; return 1; }
        if grep -qE 'release_(tag|commit|date|url)=' <<< "$body"; then
            echo "${fn} writes release_* globals:"
            grep -nE 'release_(tag|commit|date|url)=' <<< "$body"
            return 1
        fi
    done
}

@test "_resolve_target contains no gh/curl adapter selection logic" {
    # C5 契约：gh 认证检测与 curl 回退的选择逻辑收进 _fetch_latest_release
    # seam 内部；_resolve_target 只剩版本对比本职
    local body
    body=$(sed -n '/^_resolve_target()/,/^}/p' "${BATS_TEST_DIRNAME}/../update.sh")
    [ -n "$body" ]
    ! grep -qE 'command -v gh|gh auth status|_fetch_latest_release_gh|_fetch_latest_release_curl' <<< "$body"
}

@test "update.sh session state: exactly 7 globals, each initialized once at script level" {
    # C4 契约：会话全局从 15 个收敛到 7 个——脚本级（顶格）赋值仅为状态节
    # 初始化，每个变量恰好一次；过程式写入全部收敛在具名入口内。
    # 逐变量钉"恰好一次"：只数总数时，某变量初始化两次+另一变量漏初始化
    # 仍得 7，会假绿
    local v count
    for v in current_commit current_tag current_branch release_tag release_date need_source_update skip_update; do
        count=$(grep -cE "^${v}=" "${BATS_TEST_DIRNAME}/../update.sh")
        [ "$count" -eq 1 ] || { echo "${v}: 脚本级初始化 ${count} 次（期望恰好 1 次）"; return 1; }
    done
}

@test "update.sh derived/localized state names no longer exist" {
    # C4 契约：current_short/release_short 已由 _short_sha 派生——全文件不得
    # 再出现（连局部变量也不应绕过派生机制）；actual_*/target_version/
    # release_commit/release_url 已局部化或参数化——不得再有脚本级顶格赋值
    ! grep -nE '\bcurrent_short\b|\brelease_short\b' "${BATS_TEST_DIRNAME}/../update.sh"
    ! grep -nE '^(actual_commit|actual_tag|target_version|release_commit|release_url)=' \
        "${BATS_TEST_DIRNAME}/../update.sh"
}

@test "update.sh session globals are written only inside their named entry points" {
    # C4 契约：缩进（函数体内）的会话全局赋值只允许出现在各自的具名入口：
    #   release_tag/release_date      → _session_set_target
    #   current_commit/current_tag/current_branch → _session_capture_current
    #   need_source_update/skip_update → _resolve_target
    # awk 状态机：进入允许函数置标志位，行首 } 退出；函数体外的违规赋值即失败
    local violations
    violations=$(awk '
        /^_session_set_target\(\)/    { in_target=1; next }
        /^_session_capture_current\(\)/ { in_current=1; next }
        /^_resolve_target\(\)/        { in_resolve=1; next }
        /^}/                          { in_target=0; in_current=0; in_resolve=0; next }
        /^[[:space:]]+(release_tag|release_date)=/ && !in_target   { print "release_* outside _session_set_target: line " NR }
        /^[[:space:]]+current_(commit|tag|branch)=/ && !in_current { print "current_* outside _session_capture_current: line " NR }
        /^[[:space:]]+(need_source_update|skip_update)=/ && !in_resolve { print "need_source_update/skip_update outside _resolve_target: line " NR }
    ' "${BATS_TEST_DIRNAME}/../update.sh")
    [ -z "$violations" ] || { echo "$violations"; return 1; }
}
