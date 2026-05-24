#!/bin/bash
# ============================================================
# update.sh — llama.cpp 一键更新脚本
# 功能：查询 GitHub 最新 release → 拉取 → 构建
# 用法：cd /path/to/llama.cpp_helper && bash update.sh [tag|commit]
# ============================================================

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null && pwd)"
# 注意：SCRIPT_DIR 在此内联初始化是因为 source common.sh 需要它。
# llama_init_script_dir() 存在但仅用于无法提前解析 SCRIPT_DIR 的脚本（如 run_env.sh）。
source "${SCRIPT_DIR}/common.sh"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/config.sh"

# --- 文件锁定 ------------------------------------------------
llama_acquire_lock || llama_die "无法获取文件锁"

BUILD_SCRIPT="${SCRIPT_DIR}/build.sh"

# --- 状态变量 ------------------------------------------------
RELEASE_TAG=""
RELEASE_COMMIT=""
RELEASE_DATE=""
RELEASE_URL=""
CURRENT_COMMIT=""
CURRENT_SHORT=""
CURRENT_TAG=""
CURRENT_BRANCH=""
ORIG_DIR=""
TARGET_VERSION=""
RELEASE_SHORT=""
NEED_SOURCE_UPDATE=1
SKIP_UPDATE=0  # _resolve_target 设置 —— 无需任何操作时跳过更新
ACTUAL_COMMIT=""
ACTUAL_TAG=""

# --- 帮助信息 ------------------------------------------------
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

# 保存当前状态以便回滚
_save_state() {
    CURRENT_COMMIT=$(git -C "$LLAMA_CPP_SRC" rev-parse HEAD)
    CURRENT_SHORT=$(git -C "$LLAMA_CPP_SRC" rev-parse --short HEAD)
    CURRENT_TAG=$(git -C "$LLAMA_CPP_SRC" describe --tags --exact-match 2>/dev/null || echo "(无标签)")
    local _branch
    if _branch=$(git -C "$LLAMA_CPP_SRC" symbolic-ref --short HEAD 2>/dev/null); then
        CURRENT_BRANCH="$_branch"
    else
        CURRENT_BRANCH=""
    fi
}

# 回滚到之前的状态
_rollback() {
    if [[ -z "${CURRENT_COMMIT:-}" ]]; then
        llama_err "无法回滚：未保存原始 commit"
        return 1
    fi

    llama_warn "正在回滚到之前的版本..."
    local failed=0
    if ! git -C "$LLAMA_CPP_SRC" checkout "$CURRENT_COMMIT" --quiet 2>/dev/null; then
        llama_err "git checkout 失败: 无法恢复到 ${CURRENT_SHORT}"
        failed=1
    fi
    # 清理回滚后可能出现的旧版本子模块残留
    if [[ "$failed" -eq 0 ]]; then
        _cleanup_stale_submodules
    fi
    if ! git -C "$LLAMA_CPP_SRC" submodule update --recursive --quiet 2>/dev/null; then
        llama_warn "子模块回滚不完全，可能需要手动处理"
        failed=1
    fi
    if [[ "$failed" -eq 0 ]]; then
        llama_ok "已回滚到 ${CURRENT_SHORT}"
    fi
    # Always attempt branch restoration regardless of rollback issues
    if [[ -n "${CURRENT_BRANCH:-}" ]]; then
        if git -C "$LLAMA_CPP_SRC" checkout "$CURRENT_BRANCH" --quiet 2>/dev/null; then
            :  # branch restored successfully
        else
            llama_warn "无法恢复到原始分支: ${CURRENT_BRANCH}（当前处于 detached HEAD）"
        fi
    fi
    return "$failed"
}

# 中断恢复陷阱 — SIGINT/SIGTERM 时恢复到更新前状态
# llama_safe_exit 130: 130 = 128 + 2 (SIGINT 标准退出码)
_cleanup_on_interrupt() {
    llama_warn "更新被中断，正在恢复..."
    llama_cleanup_trap
    if [[ -n "${CURRENT_COMMIT:-}" ]]; then
        git -C "$LLAMA_CPP_SRC" checkout "$CURRENT_COMMIT" --quiet 2>/dev/null || true
        git -C "$LLAMA_CPP_SRC" submodule update --recursive --quiet 2>/dev/null || true
    fi
    if [[ -n "${ORIG_DIR:-}" ]]; then
        llama_cd_back
    fi
    llama_safe_exit 130
}

_cleanup_stale_submodules() {
    local -A expected_paths
    while IFS= read -r path; do
        expected_paths["$path"]=1
    done < <(git -C "$LLAMA_CPP_SRC" ls-files --stage | grep '^160000' | awk '{print $NF}')

    local stale_count=0
    local gitlink mod_dir
    while IFS= read -r gitlink; do
        gitlink="${gitlink#"${LLAMA_CPP_SRC}"/}"
        mod_dir="$(dirname "$gitlink")"
        if [[ -v expected_paths[$mod_dir] ]]; then
            continue
        fi
        if grep -q '^gitdir:' "${LLAMA_CPP_SRC}/${gitlink}" 2>/dev/null; then
            llama_info "清理旧子模块残留: ${mod_dir}"
            # shellcheck disable=SC2115
            rm -rf "${LLAMA_CPP_SRC}/${gitlink}" "${LLAMA_CPP_SRC}/${mod_dir}"
            local git_modules_dir="${LLAMA_CPP_SRC}/.git/modules/${mod_dir}"
            if [[ -d "$git_modules_dir" ]]; then
                rm -rf "$git_modules_dir"
                llama_detail "清理 .git/modules: ${mod_dir}"
            fi
            ((stale_count++)) || true  # || true: ((0)) is exit code 1 under set -e
        fi
    done < <(find "$LLAMA_CPP_SRC" -path "${LLAMA_CPP_SRC}/build" -prune -o -path "${LLAMA_CPP_SRC}/.git" -prune -o -type f -name '.git' -print)

    if [[ "$stale_count" -gt 0 ]]; then
        llama_ok "旧子模块清理完成 (${stale_count} 个)"
    fi
}

_json_field_gh() {
    local json="$1" field="$2"
    printf '%s' "$json" | python3 -c "import json,sys; print(json.load(sys.stdin)[sys.argv[1]])" "$field"
}

_json_field_curl() {
    local file="$1" field="$2"
    python3 -c "import json,sys; print(json.load(sys.stdin)[sys.argv[1]])" "$field" < "$file"
}

# 打印构建成功的汇总信息
# 参数: source_updated ("1"=源码已更新, "0"=仅重新构建), current_ver, target_ver, release_date
_print_success_summary() {
    local source_updated="$1"
    local current_ver="$2"
    local target_ver="$3"
    local release_date="$4"

    echo ""
    echo "=========================================="
    if [[ "$source_updated" -eq 1 ]]; then
        echo "  llama.cpp 更新并构建完成！"
    else
        echo "  构建完成！"
    fi
    echo "=========================================="
    echo ""
    if [[ "$source_updated" -eq 1 ]]; then
        echo "  更新: ${current_ver} → ${target_ver}"
        echo "  版本: ${target_ver}"
        if [[ -n "$release_date" ]]; then
            echo "  发布: ${release_date}"
        fi
    else
        echo "  版本: ${current_ver}"
        echo "  状态: 重新构建完成"
    fi
    echo ""
    llama_print_run_examples "${LLAMA_CPP_SRC}/build/bin"
}

# --- GitHub API 查询 -----------------------------------------
_fetch_latest_release_gh() {
    local json
    if ! json=$(gh release view --repo "$REPO" --json tagName,targetCommitish,publishedAt,url 2>/dev/null); then
        return 1
    fi
    RELEASE_TAG=$(_json_field_gh "$json" tagName) || return 1
    RELEASE_COMMIT=$(_json_field_gh "$json" targetCommitish) || return 1
    RELEASE_DATE=$(_json_field_gh "$json" publishedAt) || return 1
    RELEASE_URL=$(_json_field_gh "$json" url) || return 1
}

_fetch_latest_release_curl() {
    if ! command -v curl &>/dev/null; then
        llama_err "需要 curl 命令，请先安装"
        return 1
    fi

    local api_url="https://api.github.com/repos/${REPO}/releases/latest"
    local tmp
    tmp=$(mktemp "${TMPDIR:-/tmp}/llama_release.XXXXXX.json")
    # shellcheck disable=SC2064
    trap "rm -f '$tmp'" RETURN

    local http_code
    http_code=$(curl -sL --connect-timeout "${CURL_CONNECT_TIMEOUT}" --max-time "${CURL_MAX_TIME}" \
        -o "$tmp" -w "%{http_code}" \
        -H "Accept: application/vnd.github+json" \
        -H "X-GitHub-Api-Version: 2022-11-28" \
        "$api_url") || return 1

    if [[ "$http_code" != "200" ]]; then
        llama_err "GitHub API 请求失败 (HTTP ${http_code})"
        if [[ -s "$tmp" ]]; then
            cat "$tmp" >&2 || true
        fi
        return 1
    fi

    # 使用 stdin 重定向避免路径注入到 Python 字符串中
    RELEASE_TAG=$(_json_field_curl "$tmp" tag_name) || return 1
    RELEASE_COMMIT=$(_json_field_curl "$tmp" target_commitish) || return 1
    RELEASE_DATE=$(_json_field_curl "$tmp" published_at) || return 1
    RELEASE_URL=$(_json_field_curl "$tmp" html_url) || return 1
}

# --- 子函数 --------------------------------------------------

_parse_args() {
    TARGET_VERSION=""
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
            --*)
                llama_die "未知选项: $1"
                ;;
            -*)
                llama_die "未知选项: $1"
                ;;
            *)
                TARGET_VERSION="$1"
                ;;
        esac
        shift
        if (($# > 0)); then
            llama_warn "忽略额外参数: $*"
        fi
    fi
}

_check_local_repo() {
    llama_info "检查前置条件..."

    # shellcheck disable=SC2015
    llama_check_commands \
        git "git" \
        python3 "python3" \
        && llama_ok "基础工具检查通过" || llama_die "基础工具检查失败"

    llama_check_dir "$LLAMA_CPP_SRC" "llama.cpp 仓库" || llama_die
    llama_check_file "${LLAMA_CPP_SRC}/.git/config" "Git 仓库配置" || llama_die
    llama_check_file "$BUILD_SCRIPT" "构建脚本" || llama_die

    llama_info "检查本地仓库状态..."

    ORIG_DIR="$(pwd)"
    cd "$LLAMA_CPP_SRC" >/dev/null

    if [[ -n "$(git status --porcelain 2>/dev/null)" ]]; then
        llama_err "检测到未提交的更改，请先处理后再更新:"
        git status --short
        llama_cd_back
        llama_die "存在未提交的更改，请先处理后再更新"
    fi

    # 检查子模块中的未提交更改
    if git submodule foreach --quiet 'git diff --quiet 2>/dev/null && git diff --cached --quiet 2>/dev/null || echo DIRTY' 2>/dev/null | grep -q 'DIRTY'; then
        llama_err "子模块中存在未提交的更改，请先处理后再更新:"
        git submodule foreach 'git status --short' 2>/dev/null || true
        llama_cd_back
        llama_die "子模块中存在未提交的更改，请先处理后再更新"
    fi

    _save_state

    # 设置中断恢复陷阱（函数定义在顶层）
    llama_setup_trap _cleanup_on_interrupt


    local ACTUAL_REMOTE
    ACTUAL_REMOTE=$(git remote get-url origin 2>/dev/null || echo "")
    local normalized_remote="${ACTUAL_REMOTE%.git}"
    local normalized_expected="${REPO_URL%.git}"
    if [[ "$normalized_remote" != "$normalized_expected" ]]; then
        llama_warn "远程 origin 与预期不一致"
        llama_detail "当前: ${ACTUAL_REMOTE}"
        llama_detail "预期: ${REPO_URL}"
        llama_warn "如果 origin 是 fork，可能无法获取上游最新 release"
    fi

    llama_ok "本地仓库状态正常"
    llama_detail "当前 Commit: ${CURRENT_SHORT}"
    llama_detail "当前标签:    ${CURRENT_TAG}"
}

_resolve_target() {
    if [[ -n "$TARGET_VERSION" ]]; then
        RELEASE_TAG="$TARGET_VERSION"
        if llama_is_full_commit_sha "$TARGET_VERSION"; then
            RELEASE_COMMIT="$TARGET_VERSION"
        fi
        llama_info "使用用户指定的版本: ${RELEASE_TAG}"
    else
        llama_info "正在查询 GitHub 最新发布版本..."

        if command -v gh &>/dev/null && gh auth status &>/dev/null; then
            llama_info "使用 gh CLI 查询（已认证）"
            if ! _fetch_latest_release_gh; then
                llama_warn "gh 查询失败，回退到 curl"
                if ! _fetch_latest_release_curl; then
                    llama_cd_back
                    llama_die "无法获取最新版本信息"
                fi
            fi
        else
            llama_warn "gh 未安装或未登录，使用 curl 直接访问 API"
            if ! _fetch_latest_release_curl; then
                llama_cd_back
                llama_die "无法获取最新版本信息"
            fi
        fi

        llama_ok "查询成功"
    fi

    # 显示版本信息
    if [[ ${#RELEASE_COMMIT} -ge 7 ]]; then
        RELEASE_SHORT="${RELEASE_COMMIT:0:7}"
    elif [[ -n "${RELEASE_COMMIT:-}" ]]; then
        RELEASE_SHORT="${RELEASE_COMMIT}"
    else
        RELEASE_SHORT="unknown"
    fi
    llama_detail "目标版本:    ${RELEASE_TAG}"
    if [[ -n "$RELEASE_COMMIT" ]] && llama_is_full_commit_sha "$RELEASE_COMMIT"; then
        llama_detail "对应 Commit: ${RELEASE_SHORT} (${RELEASE_COMMIT})"
    fi
    if [[ -n "$RELEASE_DATE" ]]; then
        llama_detail "发布时间:    ${RELEASE_DATE}"
    fi
    if [[ -n "$RELEASE_URL" ]]; then
        llama_detail "发布页面:    ${RELEASE_URL}"
    fi

    # 版本对比
    llama_info "对比版本..."
    NEED_SOURCE_UPDATE=1
    if [[ "${CURRENT_TAG}" = "${RELEASE_TAG}" ]]; then
        llama_ok "本地已在该版本 (${RELEASE_TAG})，无需更新源码"
        NEED_SOURCE_UPDATE=0
    elif llama_is_full_commit_sha "${RELEASE_COMMIT}" && [[ "$CURRENT_COMMIT" = "$RELEASE_COMMIT" ]]; then
        llama_ok "本地已是最新 commit (${RELEASE_SHORT})，无需更新源码"
        NEED_SOURCE_UPDATE=0
    fi

    if [[ "$NEED_SOURCE_UPDATE" -eq 0 ]]; then
        # 源码无需更新，检查构建是否完整
        if llama_check_build_health; then
            llama_ok "当前构建完整且与源码匹配，无需任何操作！"
            SKIP_UPDATE=1
            return 0
        fi
        llama_warn "当前构建缺失或与源码不匹配，需要重新构建"
    else
        llama_warn "需要更新: ${CURRENT_SHORT} (${CURRENT_TAG}) → ${RELEASE_TAG}"
    fi
}

_update_source() {
    llama_check_disk_space "$LLAMA_CPP_SRC" || llama_die
    llama_info "正在从远程仓库拉取最新引用..."

    llama_with_network_context "从远程仓库拉取标签" git fetch origin --quiet --tags || {
        llama_cd_back
        llama_die "从远程仓库拉取失败"
    }

    # 尝试 fetch 特定标签（如果是标签的话）
    if git ls-remote --tags origin "refs/tags/${RELEASE_TAG}" 2>/dev/null | grep -q "refs/tags/${RELEASE_TAG}"; then
        local _tag_fetch_rc=0
        git fetch origin --quiet "refs/tags/${RELEASE_TAG}:refs/tags/${RELEASE_TAG}" || _tag_fetch_rc=$?
        if [[ "$_tag_fetch_rc" -ne 0 ]]; then
            llama_detail "特定标签 ref fetch 失败 (退出码: ${_tag_fetch_rc})，将使用已拉取的标签"
        fi
    fi

    if ! git rev-parse --verify "${RELEASE_TAG}^{commit}" &>/dev/null; then
        llama_err "本地找不到目标版本: ${RELEASE_TAG}"
        llama_detail "请确认版本号正确，或检查网络连接"
        llama_cd_back
        llama_die "本地找不到目标版本: ${RELEASE_TAG}"
    fi

    llama_info "切换到版本 ${RELEASE_TAG}..."

    if ! git checkout "${RELEASE_TAG}" --quiet; then
        llama_err "切换到版本 ${RELEASE_TAG} 失败"
        llama_cd_back
        _rollback
        llama_die "版本切换失败"
    fi

    ACTUAL_COMMIT=$(git rev-parse HEAD)
    ACTUAL_TAG=$(git describe --tags --exact-match 2>/dev/null || echo "")

    if [[ -n "$ACTUAL_TAG" && "$ACTUAL_TAG" != "$RELEASE_TAG" ]]; then
        llama_warn "checkout 后标签不一致 (期望: ${RELEASE_TAG}, 实际: ${ACTUAL_TAG})"
    fi

    if llama_is_full_commit_sha "${RELEASE_COMMIT}" && [[ "$ACTUAL_COMMIT" != "$RELEASE_COMMIT" ]]; then
        llama_warn "checkout commit (${ACTUAL_COMMIT:0:7}) 与 API 返回的 commitish (${RELEASE_SHORT}) 不一致"
        llama_warn "但标签 ${RELEASE_TAG} 已确认 checkout 成功，继续构建..."
    fi

    llama_ok "源码已更新到 ${RELEASE_TAG} (${ACTUAL_COMMIT:0:7})"
    # 清理旧版本残留的子模块目录
    _cleanup_stale_submodules

    # 同步当前版本的子模块
    llama_info "同步子模块..."
    if [[ -f ".gitmodules" ]]; then
        if ! git submodule update --init --recursive --quiet; then
            llama_err "子模块同步失败"
            _rollback
            llama_cd_back
            llama_die "子模块同步失败，已回滚到 ${CURRENT_SHORT}"
        fi
        llama_ok "子模块已同步"
    else
        llama_info "当前版本无子模块，跳过"
    fi
}

_build_with_rollback() {
    if [[ "$NEED_SOURCE_UPDATE" -eq 1 ]]; then
        llama_step "源码更新完成，开始构建..."
    else
        llama_step "开始重新构建..."
    fi

    llama_release_lock
    llama_run_silent bash "$BUILD_SCRIPT"
    local BUILD_STATUS=$?

    if [[ "$BUILD_STATUS" -ne 0 ]]; then
        _rollback
        llama_warn "新版本构建失败，尝试在回滚版本上重新构建..."
        llama_step "回滚后重新构建..."
        llama_run_silent bash "$BUILD_SCRIPT"
        local ROLLBACK_BUILD_STATUS=$?
        if [[ "$ROLLBACK_BUILD_STATUS" -ne 0 ]]; then
            llama_err "回滚后构建也失败"
            llama_detail "当前状态:"
            local current_head
            current_head=$(git -C "$LLAMA_CPP_SRC" rev-parse --short HEAD 2>/dev/null || echo "未知")
            llama_detail "  当前 HEAD: ${current_head}"
            llama_detail "  原始版本: ${CURRENT_SHORT} (${CURRENT_TAG})"
            llama_detail "  目标版本: ${RELEASE_TAG}"
            llama_detail "恢复步骤:"
            llama_detail "  cd ${LLAMA_CPP_SRC}"
            llama_detail "  git status"
            llama_detail "  git checkout ${CURRENT_COMMIT}"
            llama_detail "  git submodule update --recursive"
            llama_detail "  bash ${BUILD_SCRIPT}"
            llama_cd_back
            llama_die "回滚后构建也失败，请手动恢复到 ${CURRENT_SHORT} 后重试"
        fi
        llama_ok "更新失败但已回滚并重新构建成功"
        _print_success_summary 0 "${CURRENT_SHORT} (${CURRENT_TAG})" "${RELEASE_TAG} (构建失败，已回滚)" ""
        llama_cd_back
        llama_safe_exit 0
    fi
    # 构建成功
    _print_success_summary "${NEED_SOURCE_UPDATE}" "${CURRENT_SHORT}" "${RELEASE_TAG}" "${RELEASE_DATE:-}"

    llama_cd_back
    return 0
}

# --- 主逻辑 --------------------------------------------------
main() {
    llama_step "llama.cpp 一键更新脚本"
    _parse_args "$@"
    llama_activate_conda  # 激活 conda 环境（确保 python3/git 等工具可用）
    _check_local_repo
    _resolve_target
    if [[ "${SKIP_UPDATE:-0}" -eq 1 ]]; then
        llama_cd_back
        llama_safe_exit 0
    fi
    if [[ "${NEED_SOURCE_UPDATE:-1}" -eq 1 ]]; then
        _update_source
    fi
    _build_with_rollback
    return 0
}

main "$@"
_main_rc=$?
llama_return_or_exit ${_main_rc:-0}
