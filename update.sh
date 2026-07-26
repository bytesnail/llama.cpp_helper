#!/bin/bash
# ============================================================
# update.sh — llama.cpp 一键更新脚本
# 功能：查询 GitHub 最新发布版本 → 拉取 → 构建
# Usage: cd /path/to/llama.cpp_helper && bash update.sh [tag|commit]
# ============================================================

# 仅在正常执行时启用严格模式（为测试提取而 source 时不启用）
if [[ "${_LLAMA_SOURCE_ONLY:-}" != "1" ]]; then
    set -euo pipefail
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null && pwd)"
readonly SCRIPT_DIR
# 注意：此处内联初始化 SCRIPT_DIR，因为 source common.sh 需要它。
# llama_init_script_dir() 存在但仅在无法提前解析 SCRIPT_DIR 时使用（如 run_env.sh）。
source "${SCRIPT_DIR}/common.sh"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/config.sh"

BUILD_SCRIPT="${SCRIPT_DIR}/build.sh"
readonly BUILD_SCRIPT
# --- 会话状态（C4：写入面收窄为具名入口）-----------------------
# 7 个脚本级全局，每个只有一个具名写入入口：
#   current_commit/current_tag/current_branch — _session_capture_current
#   release_tag/release_date                 — _session_set_target
#   need_source_update/skip_update           — _resolve_target（更新决策，两态显式写）
# 其余原脚本级全局已消除：短 SHA 由 _short_sha 现算（derive-don't-store），
# release_commit/release_url/actual_commit/actual_tag 改函数局部，
# target_version 改 main 局部经参数传递；fetcher 经 seam 返回 TAB 行（C5）。
# 上述不变量由 tests/test_smoke.bats 三个契约测试钉住。
current_commit=""
current_tag=""
current_branch=""
release_tag=""
release_date=""
need_source_update=1
skip_update=0

# --- 帮助信息 ------------------------------------------------
# Usage: _show_help
_show_help() {
    llama_show_help \
        "$(basename "$0")" \
        "将 llama.cpp 更新到指定版本或最新 release，并自动重新构建。" \
        "  -h, --help      显示此帮助信息
      --version   显示版本信息" \
        "  bash update.sh                    # 更新到最新 release
  bash update.sh b3631              # 更新到指定 commit
  bash update.sh b8941              # 更新到指定标签
  bash update.sh --help             # 显示帮助"
}

# --- 工具函数 ------------------------------------------------

# Usage: _short_sha <full_sha>
# 输出短 SHA（前 7 位）——派生现算，替代原 current_short/release_short
# 两个存储全局（derive-don't-store）。bash 子串对短字符串天然返回整串，
# 空输入输出空串。
_short_sha() {
    printf '%s\n' "${1:0:7}"
}

# 捕获更新前 git 状态用于回滚——current_commit/current_tag/current_branch
# 三全局的唯一写入入口（C4）。
# Usage: _session_capture_current
_session_capture_current() {
    current_commit=$(git -C "$LLAMA_CPP_SRC" rev-parse HEAD)
    # 无标签/无分支（detached HEAD）时留空串——原 "(无标签)" 哨兵字符串
    # 把显示文案与逻辑判断耦合（消费点需逐个过滤哨兵）
    current_tag=$(git -C "$LLAMA_CPP_SRC" describe --tags --exact-match 2>/dev/null || true)
    current_branch=$(git -C "$LLAMA_CPP_SRC" symbolic-ref --short HEAD 2>/dev/null || true)
}

# 记录目标版本——release_tag/release_date 两全局的唯一写入入口（C4）。
# Usage: _session_set_target <tag> [date]
_session_set_target() {
    release_tag="$1"
    release_date="${2:-}"
}

# 回滚到之前的状态
# Usage: _rollback
_rollback() {
    if [[ -z "${current_commit:-}" ]]; then
        llama_err "无法回滚：未保存原始 commit"
        return 1
    fi

    llama_warn "正在回滚到之前的版本..."
    local orig_short
    orig_short=$(_short_sha "$current_commit")
    local failed=0
    if ! git -C "$LLAMA_CPP_SRC" checkout "$current_commit" --quiet 2>/dev/null; then
        llama_err "checkout 失败: 无法恢复到 ${orig_short}"
        failed=1
    fi
    # 清理回滚后可能出现的旧子模块残留
    # || true：清理失败（索引不可读）保守不删除，不阻断回滚主流程
    if [[ "$failed" -eq 0 ]]; then
        _cleanup_stale_submodules || true
    fi
    if ! git -C "$LLAMA_CPP_SRC" submodule update --recursive --quiet 2>/dev/null; then
        llama_warn "子模块回滚不完全，可能需要手动处理"
        failed=1
    fi
    if [[ "$failed" -eq 0 ]]; then
        llama_ok "已回滚到 ${orig_short}"
    fi
    # 分支恢复独立于 checkout/子模块操作的成功与否：即使回滚部分失败，
    # 恢复原始分支名也有助于用户手动恢复
    # （detached HEAD 更难理解）。
    if [[ -n "${current_branch:-}" ]]; then
        if git -C "$LLAMA_CPP_SRC" checkout "$current_branch" --quiet 2>/dev/null; then
            :  # 分支已恢复
        else
            llama_warn "无法恢复到原始分支: ${current_branch}（当前处于 detached HEAD）"
        fi
    fi
    return "$failed"
}

# 中断恢复 trap — 在 SIGINT/SIGTERM 时恢复更新前状态
# llama_safe_exit 130：130 = 128 + 2（SIGINT 标准退出码）
# Usage: _cleanup_on_interrupt
_cleanup_on_interrupt() {
    llama_warn "更新被中断，正在恢复..."
    llama_cleanup_trap
    # 复用 _rollback 完整逻辑（含子模块残留清理与分支恢复）——原内联子集
    # 缺少 _cleanup_stale_submodules，与显式回滚的行为已发生漂移
    if [[ -n "${current_commit:-}" ]]; then
        _rollback || true
    fi
    llama_safe_exit 130
}

# Usage: _cleanup_stale_submodules
# 清理"旧版本遗留"的子模块目录。安全契约（任一不满足即跳过，保守不删除）：
#   1. 白名单必须成功构建——git ls-files 失败时 return 1，绝不按空白名单删除
#   2. gitdir 指针必须指向 .git/modules/——worktree 的 .git 文件指向
#      .git/worktrees/，未跟踪的用户 worktree 不是子模块残留（未跟踪文件
#      经 _check_local_repo 的 --untracked-files=no 显式放行，清理不得删除）
_cleanup_stale_submodules() {
    local -A expected_paths
    local path
    # ls-files --stage 的路径段以 TAB 分隔：必须用 TAB 切分提取完整路径。
    # 原 awk '{print $NF}' 按空白分词，含空格的子模块路径被截断后
    # 查不到 expected_paths，合法子模块会被误判为残留并 rm -rf（已实证）
    # core.quotePath=false：非 ASCII 路径默认被 C 引用转义（如 "vendor/中文"），
    # 与 find 输出的原始路径永不匹配，同样会把合法子模块误判为残留（已实证）
    # 先落变量再查退出码：进程替换的失败不传播（set -e/pipefail 均不可见），
    # 静默空表会把全部子模块误判为残留（已实证）
    local ls_files_out
    if ! ls_files_out=$(git -C "$LLAMA_CPP_SRC" -c core.quotePath=false ls-files --stage 2>/dev/null); then
        llama_warn "无法读取 Git 索引（ls-files 失败），跳过子模块残留清理（保守不删除）"
        return 1
    fi
    while IFS= read -r path; do
        expected_paths["$path"]=1
    done < <(sed -n 's/^160000 [0-9a-fA-F]\{40\} [0-9]\t//p' <<< "$ls_files_out")

    local stale_count=0
    local gitlink mod_dir
    # 不深入当前子模块内部：顶层 gitlinks 之外的嵌套子模块 .git 会被误判为残留
    local -a find_prune_args=()
    for path in "${!expected_paths[@]}"; do
        find_prune_args+=(-path "${LLAMA_CPP_SRC}/${path}" -prune -o)
    done
    while IFS= read -r gitlink; do
        gitlink="${gitlink#"${LLAMA_CPP_SRC}"/}"
        mod_dir="$(dirname "$gitlink")"
        # 使用 ${arr[k]+x} 而非 [[ -v arr[k] ]]：后者对关联数组元素的支持
        # 需要 Bash 4.3+，而本项目声明支持 Bash 4.2（4.2 上 -v 恒为假，
        # 会导致 continue 被跳过、误删合法子模块）。
        if [[ -n "${expected_paths[$mod_dir]+x}" ]]; then
            continue
        fi
        local gitdir_target
        gitdir_target=$(sed -n 's/^gitdir: //p' "${LLAMA_CPP_SRC}/${gitlink}" 2>/dev/null || true)
        case "$gitdir_target" in
            */.git/modules/*) ;;
            *) continue ;;  # 非子模块 gitdir（worktree/空文件等）——不删除
        esac
        llama_info "清理旧子模块残留: ${mod_dir}"
        # shellcheck disable=SC2115
        rm -rf "${LLAMA_CPP_SRC}/${gitlink}" "${LLAMA_CPP_SRC}/${mod_dir}"
        local git_modules_dir="${LLAMA_CPP_SRC}/.git/modules/${mod_dir}"
        if [[ -d "$git_modules_dir" ]]; then
            rm -rf "$git_modules_dir"
            llama_detail "清理 .git/modules: ${mod_dir}"
        fi
        ((stale_count++)) || true  # || true：set -e 下 ((0)) 退出码为 1
    done < <(find "$LLAMA_CPP_SRC" -path "${LLAMA_CPP_SRC}/build" -prune -o \
                -path "${LLAMA_CPP_SRC}/.git" -prune -o \
                ${find_prune_args[@]+"${find_prune_args[@]}"} \
                -type f -name '.git' -print)

    if [[ "$stale_count" -gt 0 ]]; then
        llama_ok "旧子模块清理完成 (${stale_count} 个)"
    fi
}

# Usage: _json_field <field_name>
# 使用 Python 提取 JSON 字段。输入通过 stdin 管道传入。
_json_field() {
    python3 -c "import json,sys; print(json.load(sys.stdin)[sys.argv[1]])" "$1"
}

# Usage: _parse_release_json <field1> [field2] ...
# 单次 python3 调用提取多个 JSON 字段，TAB 分隔输出到一行。
# 供两个 fetcher 复用：原实现每字段起一个 python3 进程（共 4 次 fork）。
# release 字段值（tag/SHA/ISO 日期/URL）不含 TAB 与换行，TAB 分隔安全。
_parse_release_json() {
    python3 -c 'import json,sys
d = json.load(sys.stdin)
print("\t".join(str(d[k]) for k in sys.argv[1:]))' "$@"
}

# Usage: _print_success_summary <source_updated> <current_ver> <target_ver> <release_date>
_print_success_summary() {
    local source_updated="$1"
    local current_ver="$2"
    local target_ver="$3"
    local release_date="$4"

    echo
    echo "=========================================="
    if [[ "$source_updated" -eq 1 ]]; then
        echo "  llama.cpp 更新并构建完成！"
    else
        echo "  构建完成！"
    fi
    echo "=========================================="
    echo
    if [[ "$source_updated" -eq 1 ]]; then
        echo "  更新: ${current_ver} → ${target_ver}"
        echo "  版本: ${target_ver}"
        if [[ -n "$release_date" ]]; then
            echo "  发布: ${release_date}"
        fi
    else
        echo "  版本: ${current_ver}"
        echo "  状态: 重新构建完成"
        # 回滚重建路径会把失败目标版本经此参数传入，不应静默丢弃
        if [[ -n "$target_ver" ]]; then
            echo "  备注: ${target_ver}"
        fi
    fi
    echo
    llama_print_run_examples "${BUILD_BIN_DIR:-${LLAMA_CPP_SRC}/build/bin}"
}

# --- GitHub API 查询 -----------------------------------------
# C5：_fetch_latest_release 是 release 查询的唯一显式 seam——gh/curl 选择
# 逻辑收在其内部，adapter 退到幕后。seam 与 adapter 的 stdout 契约：成功时
# 仅输出一行 TAB 分隔的 tag/commit/date/url（_parse_release_json 形态），
# 失败时返回非零且 stdout 无输出；一切日志走 stderr（>&2），调用点用
# parsed=$(_fetch_latest_release) 捕获时不会混入日志。

# Usage: _fetch_latest_release
# 显式 seam：gh 已认证走 gh adapter（失败回退 curl），否则直接 curl adapter。
_fetch_latest_release() {
    if command -v gh &>/dev/null && gh auth status &>/dev/null; then
        llama_info "使用 gh CLI 查询（已认证）" >&2
        if _fetch_latest_release_gh; then
            return 0
        fi
        llama_warn "gh 查询失败，回退到 curl" >&2
    else
        llama_warn "gh 未安装或未登录，使用 curl 直接访问 API" >&2
    fi
    _fetch_latest_release_curl
}

# Usage: _fetch_latest_release_gh
# gh adapter：成功输出 TAB 行，失败返回 1（不写任何全局）。
_fetch_latest_release_gh() {
    local json
    if ! json=$(gh release view --repo "$REPO" --json tagName,targetCommitish,publishedAt,url 2>/dev/null); then
        return 1
    fi
    printf '%s' "$json" | _parse_release_json tagName targetCommitish publishedAt url
}

# Usage: _fetch_latest_release_curl
# curl adapter：成功输出 TAB 行，失败返回 1（不写任何全局）。
_fetch_latest_release_curl() {
    if ! command -v curl &>/dev/null; then
        llama_err "需要 curl 命令，请先安装"
        return 1
    fi

    local api_url="https://api.github.com/repos/${REPO}/releases/latest"
    local tmp
    tmp=$(mktemp "${TMPDIR:-/tmp}/llama_release.XXXXXX.json")
    # 注意：此处不使用 RETURN trap 清理 $tmp —— bash 的 RETURN trap 不限定于
    # 当前函数，设置后会持续到脚本结束并在其后每个函数返回时触发（全局泄漏，
    # 还会覆盖其它 RETURN trap）。改为在每条退出路径显式 rm -f。

    local http_code
    http_code=$(curl -sL --connect-timeout "${CURL_CONNECT_TIMEOUT}" --max-time "${CURL_MAX_TIME}" \
        -o "$tmp" -w "%{http_code}" \
        -H "Accept: application/vnd.github+json" \
        -H "X-GitHub-Api-Version: 2022-11-28" \
        "$api_url") || { rm -f "$tmp"; return 1; }

    if [[ "$http_code" != "200" ]]; then
        llama_err "GitHub API 请求失败 (HTTP ${http_code})"
        if [[ -s "$tmp" ]]; then
            cat "$tmp" >&2 || true
        fi
        rm -f "$tmp"
        return 1
    fi

    # 单次 python3 提取全部字段（原每字段一个进程，共 4 次 fork）；
    # 使用 stdin 重定向，避免路径注入到 Python 字符串中
    local parsed
    parsed=$(_parse_release_json tag_name target_commitish published_at html_url < "$tmp") || { rm -f "$tmp"; return 1; }
    rm -f "$tmp"
    printf '%s\n' "$parsed"
}

# --- 子函数 --------------------------------------------------

# Usage: _parse_args <result_var> [args...]
# 解析命令行参数；目标版本（若有）经 printf -v 写入 <result_var>（C1
# out-param 模式），不再写脚本级全局（C4）。--help/--version 直接退出。
# 误用（缺失/非法变量名、保留前缀 _pa_）返回 2 大声失败。
# 内部局部变量一律 _pa_ 前缀：动态作用域下同名的函数内 local 会遮蔽
# 调用者变量，printf -v 曾会写到函数自己的 local 上（同 C1 的 _lrs_ 教训）
_parse_args() {
    local _pa_result_var="${1:-}"
    if [[ ! "$_pa_result_var" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ || "$_pa_result_var" == _pa_* ]] \
        || llama_out_var_denylisted "$_pa_result_var"; then
        llama_err "_parse_args: 非法或保留的结果变量名: ${_pa_result_var:-<缺失>}"
        return 2
    fi
    shift

    local _pa_target=""
    if (($# > 0)); then
        case "$1" in
            -h|--help)
                _show_help
                llama_safe_exit 0
                ;;
            --version)
                llama_show_version
                llama_safe_exit 0
                ;;
            -*)
                llama_die "未知选项: $1"
                ;;
            *)
                _pa_target="$1"
                ;;
        esac
        shift
        if (($# > 0)); then
            llama_warn "忽略额外参数: $*"
        fi
    fi
    printf -v "$_pa_result_var" '%s' "$_pa_target"
}

# Usage: _check_local_repo
_check_local_repo() {
    llama_info "检查前置条件..."

    # shellcheck disable=SC2015
    llama_check_commands \
        "git" "git" \
        python3 "python3" \
        flock "util-linux" \
        && llama_ok "基础工具检查通过" || llama_die "基础工具检查失败"

    llama_check_dir "$LLAMA_CPP_SRC" "llama.cpp 仓库" || llama_die
    llama_check_file "${LLAMA_CPP_SRC}/.git/config" "Git 仓库配置" || llama_die
    llama_check_file "$BUILD_SCRIPT" "构建脚本" || llama_die

    llama_info "检查本地仓库状态..."

    # 统一解析为绝对路径（子 shell 内 cd，本进程 cwd 不变），保证后续
    # git -C、find、build.sh 子进程看到一致的路径。本脚本不改变工作目录：
    # 所有 git 调用显式携带 -C "$LLAMA_CPP_SRC"，与调用者 cwd 解耦——
    # 由 tests/test_smoke.bats 的契约测试钉住该不变量。
    local abs_src
    if ! abs_src="$(cd "$LLAMA_CPP_SRC" >/dev/null 2>&1 && pwd)"; then
        llama_die "无法解析 llama.cpp 仓库路径: ${LLAMA_CPP_SRC}"
    fi
    LLAMA_CPP_SRC="$abs_src"
    # --untracked-files=no：未跟踪文件（补丁/笔记/core dump）不会被 checkout
    # 触碰（git 自身也会拒绝覆盖），不应以"未提交的更改"为由阻断更新
    if [[ -n "$(git -C "$LLAMA_CPP_SRC" status --porcelain --untracked-files=no 2>/dev/null)" ]]; then
        llama_err "检测到未提交的更改，请先处理后再更新:"
        git -C "$LLAMA_CPP_SRC" status --short --untracked-files=no
        llama_die "存在未提交的更改，请先处理后再更新"
    fi

    # 检查子模块中的未提交更改
    # 先完整收集输出再 grep：直接 foreach | grep -q 时，grep -q 提前退出
    # 会让 foreach 收到 SIGPIPE(141)，pipefail 下管线返回 141 → if 条件
    # 为假 → 多个子模块且靠前为脏时脏检查被静默跳过（已实证）
    local submodule_status
    submodule_status=$(git -C "$LLAMA_CPP_SRC" submodule foreach --quiet 'git diff --quiet 2>/dev/null && git diff --cached --quiet 2>/dev/null || echo DIRTY' 2>/dev/null || true)
    if grep -q 'DIRTY' <<< "$submodule_status"; then
        llama_err "子模块中存在未提交的更改，请先处理后再更新:"
        git -C "$LLAMA_CPP_SRC" submodule foreach 'git status --short' 2>/dev/null || true
        llama_die "子模块中存在未提交的更改，请先处理后再更新"
    fi

    _session_capture_current

    # 设置中断恢复 trap（函数在顶层定义）
    llama_setup_trap _cleanup_on_interrupt

    local actual_remote
    actual_remote=$(git -C "$LLAMA_CPP_SRC" remote get-url origin 2>/dev/null || echo "")
    local normalized_remote="${actual_remote%.git}"
    local normalized_expected="${REPO_URL%.git}"
    if [[ "$normalized_remote" != "$normalized_expected" ]]; then
        llama_warn "远程 origin 与预期不一致"
        llama_detail "当前: ${actual_remote}"
        llama_detail "预期: ${REPO_URL}"
        llama_warn "如果 origin 是 fork，可能无法获取上游最新 release"
    fi

    llama_ok "本地仓库状态正常"
    llama_detail "当前 Commit: $(_short_sha "$current_commit")"
    llama_detail "当前标签:    ${current_tag:-(无标签)}"
}

# Usage: _resolve_target [target_version]
# 解析目标版本（用户指定经参数传入，否则经 seam 查询最新 release），
# 与当前版本对比后写入更新决策（need_source_update/skip_update——本函数
# 是两全局的唯一写入入口，两态显式写，可重入）。
_resolve_target() {
    # rel_commit/rel_url 仅本函数消费（版本对比与显示），保持局部；
    # release_tag/release_date 跨函数使用（构建摘要/恢复指引），
    # 经 _session_set_target 写入（唯一入口）
    local target_version="${1:-}"
    local rel_commit="" rel_url="" rel_tag="" rel_date=""
    if [[ -n "$target_version" ]]; then
        rel_tag="$target_version"
        if llama_is_full_commit_sha "$target_version"; then
            rel_commit="$target_version"
        fi
        llama_info "使用用户指定的版本: ${rel_tag}"
    else
        llama_info "正在查询 GitHub 最新发布版本..."
        # C5：选择逻辑（gh→curl 回退）收在 seam 内部；此处只消费 TAB 行
        local parsed
        if ! parsed=$(_fetch_latest_release); then
            llama_die "无法获取最新版本信息"
        fi
        IFS=$'\t' read -r rel_tag rel_commit rel_date rel_url <<< "$parsed"
        llama_ok "查询成功"
    fi
    _session_set_target "$rel_tag" "$rel_date"

    # 显示版本信息
    # bash 子串对短字符串天然返回整串；空值显示 unknown
    local rel_short
    rel_short=$(_short_sha "$rel_commit")
    : "${rel_short:=unknown}"
    llama_detail "目标版本:    ${release_tag}"
    if [[ -n "$rel_commit" ]] && llama_is_full_commit_sha "$rel_commit"; then
        llama_detail "对应 Commit: ${rel_short} (${rel_commit})"
    fi
    if [[ -n "$rel_date" ]]; then
        llama_detail "发布时间:    ${rel_date}"
    fi
    if [[ -n "$rel_url" ]]; then
        llama_detail "发布页面:    ${rel_url}"
    fi

    # 版本对比
    llama_info "对比版本..."
    need_source_update=1
    skip_update=0
    if [[ "${current_tag}" = "${release_tag}" ]]; then
        llama_ok "本地已在该版本 (${release_tag})，无需更新源码"
        need_source_update=0
    elif [[ ${#rel_commit} -ge 7 ]] && [[ "$(git -C "$LLAMA_CPP_SRC" rev-parse --verify "${rel_commit}^{commit}" 2>/dev/null)" == "$current_commit" ]]; then
        # 一条路径同时覆盖完整 SHA 与可解析 commitish（分支名/短 SHA）
        llama_ok "本地已是最新 commit (${rel_short})，无需更新源码"
        need_source_update=0
    fi

    if [[ "$need_source_update" -eq 0 ]]; then
        # 源码无需更新，检查构建是否完整
        if llama_check_build_health; then
            llama_ok "当前构建完整且与源码匹配，无需任何操作！"
            skip_update=1
            return 0
        fi
        llama_warn "当前构建缺失或与源码不匹配，需要重新构建"
    else
        llama_warn "需要更新: $(_short_sha "$current_commit") (${current_tag:-(无标签)}) → ${release_tag}"
    fi
}

# Usage: _update_source
_update_source() {
    llama_check_disk_space "$LLAMA_CPP_SRC" || llama_die
    llama_info "正在从远程仓库拉取最新引用..."

    # GIT_HTTP_LOW_SPEED_*：网络半挂起（连接建立但对端不响应）时中止传输，
    # 而非无限期持锁阻塞后续 build.sh/update.sh
    llama_with_network_context "从远程仓库拉取标签" \
        env GIT_HTTP_LOW_SPEED_LIMIT="${GIT_HTTP_LOW_SPEED_LIMIT}" \
            GIT_HTTP_LOW_SPEED_TIME="${GIT_HTTP_LOW_SPEED_TIME}" \
            git -C "$LLAMA_CPP_SRC" fetch origin --quiet --tags || {
        llama_die "从远程仓库拉取失败"
    }

    # 本地解析优先：fetch --tags 已拉取全部标签，绝大多数情况下无需
    # 再做 git ls-remote 网络往返；仅本地缺失时才精确拉取该标签。
    # 解析到 SHA（refs/tags/ 全路径）而非直接使用 tag 名——本地存在同名
    # 分支时 git checkout <name> 按歧义规则优先取分支，会静默构建错误
    # commit（已实证），且 rev-parse 阶段对裸名也无法可靠消歧
    local target_sha
    if ! target_sha=$(git -C "$LLAMA_CPP_SRC" rev-parse --verify --quiet "refs/tags/${release_tag}^{commit}" 2>/dev/null); then
        llama_detail "本地未找到标签 ${release_tag}，尝试精确拉取..."
        git -C "$LLAMA_CPP_SRC" fetch origin --quiet "refs/tags/${release_tag}:refs/tags/${release_tag}" 2>/dev/null || true
        target_sha=$(git -C "$LLAMA_CPP_SRC" rev-parse --verify --quiet "refs/tags/${release_tag}^{commit}" 2>/dev/null || true)
    fi

    # 用户指定的可能是裸 commit SHA（无对应标签）：回退按 rev 解析
    if [[ -z "$target_sha" ]] && llama_is_full_commit_sha "$release_tag"; then
        target_sha=$(git -C "$LLAMA_CPP_SRC" rev-parse --verify --quiet "${release_tag}^{commit}" 2>/dev/null || true)
    fi

    if [[ -z "$target_sha" ]]; then
        llama_err "本地找不到目标版本: ${release_tag}"
        llama_detail "请确认版本号正确，或检查网络连接"
        llama_die "本地找不到目标版本: ${release_tag}"
    fi

    llama_info "切换到版本 ${release_tag}..."

    if ! git -C "$LLAMA_CPP_SRC" checkout --quiet "$target_sha"; then
        llama_err "切换到版本 ${release_tag} 失败"
        _rollback || true
        llama_die "版本切换失败"
    fi

    local actual_commit actual_tag
    actual_commit=$(git -C "$LLAMA_CPP_SRC" rev-parse HEAD)
    actual_tag=$(git -C "$LLAMA_CPP_SRC" describe --tags --exact-match 2>/dev/null || true)

    if [[ -n "$actual_tag" && "$actual_tag" != "$release_tag" ]]; then
        llama_warn "checkout 后标签不一致 (期望: ${release_tag}, 实际: ${actual_tag})"
    fi

    # 一致性校验（无条件执行）：checkout 结果必须与解析的目标 SHA 一致。
    # 原实现仅在 release_commit 为 40 位 SHA 时校验，用户指定 tag 与
    # gh 查询（targetCommitish 为分支名）两条主路径下校验均不生效
    if [[ "$actual_commit" != "$target_sha" ]]; then
        llama_err "checkout commit (${actual_commit:0:7}) 与目标 (${target_sha:0:7}) 不一致"
        _rollback || true
        llama_die "版本切换校验失败"
    fi

    llama_ok "源码已更新到 ${release_tag} (${actual_commit:0:7})"
    # 清理旧版本遗留的子模块目录
    # || true：清理失败（索引不可读）保守不删除，不阻断更新主流程
    _cleanup_stale_submodules || true

    # 同步当前版本的子模块
    llama_info "同步子模块..."
    if [[ -f "${LLAMA_CPP_SRC}/.gitmodules" ]]; then
        if ! git -C "$LLAMA_CPP_SRC" submodule update --init --recursive --quiet; then
            llama_err "子模块同步失败"
            # || true：_rollback 部分失败返回 1 时 set -e 会中止脚本，
            # 导致下方 die 的诊断消息无法输出（退出码由 die 保证）
            _rollback || true
            llama_die "子模块同步失败，已回滚到 $(_short_sha "$current_commit")"
        fi
        llama_ok "子模块已同步"
    else
        llama_info "当前版本无子模块，跳过"
    fi
}

# Usage: _print_recovery_steps
# 输出回滚/重建失败后的当前状态与手动恢复指引
_print_recovery_steps() {
    local current_head
    current_head=$(git -C "$LLAMA_CPP_SRC" rev-parse --short HEAD 2>/dev/null || echo "未知")
    llama_detail "当前状态:"
    llama_detail "  当前 HEAD: ${current_head}"
    llama_detail "  原始版本: $(_short_sha "$current_commit") (${current_tag:-(无标签)})"
    llama_detail "  目标版本: ${release_tag}"
    llama_detail "恢复步骤:"
    llama_detail "  git -C ${LLAMA_CPP_SRC} status"
    llama_detail "  git -C ${LLAMA_CPP_SRC} checkout ${current_commit}"
    llama_detail "  git -C ${LLAMA_CPP_SRC} submodule update --recursive"
    llama_detail "  bash ${BUILD_SCRIPT}"
}

# Usage: _build_with_rollback
_build_with_rollback() {
    if [[ "$need_source_update" -eq 1 ]]; then
        llama_step "源码更新完成，开始构建..."
    else
        llama_step "开始重新构建..."
    fi

    # 在启动 build.sh 前释放锁 — build.sh 会获取自己的锁，
    # 同时持有两个锁会导致死锁（同一锁文件、同一 UID）。
    llama_release_lock
    # llama_run_silent 恒返回 0，退出码写入 build_status（先 local 声明，
    # 动态作用域下的 printf -v 才会写入此局部变量）
    local build_status
    llama_run_silent build_status bash "$BUILD_SCRIPT"

    # 更新前的版本优先使用 tag，获取不到时回退到 commit id
    local before_ver="${current_tag:-$(_short_sha "$current_commit")}"

    if [[ "$build_status" -ne 0 ]]; then
        # 回滚修改源码树：重新取锁防止与并发 build/update 交错
        # （锁已在上方释放）；取锁失败不阻塞回滚（安全路径必须执行）
        if ! llama_acquire_lock; then
            llama_warn "无法重新获取锁，回滚将在无锁保护下进行"
        fi
        if ! _rollback; then
            # 回滚失败时绝不能继续在此源码上重建——重建侥幸成功会
            # 谎报"已回滚"并显示旧版本号（实际 HEAD 仍是新版本）
            llama_err "回滚失败，当前 HEAD 仍停留在 ${release_tag}"
            _print_recovery_steps
            llama_die "回滚失败，请手动恢复到 $(_short_sha "$current_commit") 后重试"
        fi
        llama_release_lock
        llama_warn "新版本构建失败，尝试在回滚版本上重新构建..."
        llama_step "回滚后重新构建..."
        local rollback_build_status
        llama_run_silent rollback_build_status bash "$BUILD_SCRIPT"
        if [[ "$rollback_build_status" -ne 0 ]]; then
            llama_err "回滚后构建也失败"
            _print_recovery_steps
            llama_die "回滚后构建也失败，请手动恢复到 $(_short_sha "$current_commit") 后重试"
        fi
        llama_ok "更新失败但已回滚并重新构建成功"
        _print_success_summary 0 "${before_ver}" "${release_tag} (构建失败，已回滚)" ""
        llama_safe_exit 0
    fi
    # 构建成功
    _print_success_summary "${need_source_update}" "${before_ver}" "${release_tag}" "${release_date:-}"

    return 0
}

# --- 主逻辑 --------------------------------------------------
main() {
    llama_step "llama.cpp 一键更新脚本"
    # target_version 是 main 局部变量，经 out-param/参数传递（C4）
    local target_version=""
    _parse_args target_version "$@"
    # 文件锁在参数解析之后获取（--help/--version 不受锁占用影响）
    llama_acquire_lock || llama_die "无法获取文件锁"
    llama_activate_conda  # 激活 conda 环境（确保 python3/git 等可用）
    _check_local_repo
    _resolve_target "$target_version"
    if [[ "${skip_update:-0}" -eq 1 ]]; then
        llama_safe_exit 0
    fi
    if [[ "${need_source_update:-1}" -eq 1 ]]; then
        _update_source
    fi
    _build_with_rollback
    return 0
}

if [[ "${_LLAMA_SOURCE_ONLY:-}" != "1" ]]; then
    main "$@"
    _main_rc=$?
    llama_return_or_exit "$_main_rc"
fi
