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

# --- 文件锁定 ------------------------------------------------
# 为测试提取而 source 时跳过设置代码
if [[ "${_LLAMA_SOURCE_ONLY:-}" != "1" ]]; then
    llama_acquire_lock || llama_die "无法获取文件锁"
fi

BUILD_SCRIPT="${SCRIPT_DIR}/build.sh"
readonly BUILD_SCRIPT
# --- 状态变量 ------------------------------------------------
release_tag=""
release_commit=""
release_date=""
release_url=""
current_commit=""
current_short=""
current_tag=""
current_branch=""
orig_dir=""
target_version=""
release_short=""
need_source_update=1
skip_update=0  # 由 _resolve_target 设置 — 无需操作时跳过更新
actual_commit=""
actual_tag=""

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

# 保存当前状态用于回滚
# Usage: _save_state
_save_state() {
    current_commit=$(git -C "$LLAMA_CPP_SRC" rev-parse HEAD)
    current_short=$(git -C "$LLAMA_CPP_SRC" rev-parse --short HEAD)
    current_tag=$(git -C "$LLAMA_CPP_SRC" describe --tags --exact-match 2>/dev/null || echo "(无标签)")
    local branch
    if branch=$(git -C "$LLAMA_CPP_SRC" symbolic-ref --short HEAD 2>/dev/null); then
        current_branch="$branch"
    else
        current_branch=""
    fi
}

# 回滚到之前的状态
# Usage: _rollback
_rollback() {
    if [[ -z "${current_commit:-}" ]]; then
        llama_err "无法回滚：未保存原始 commit"
        return 1
    fi

    llama_warn "正在回滚到之前的版本..."
    local failed=0
    if ! git -C "$LLAMA_CPP_SRC" checkout "$current_commit" --quiet 2>/dev/null; then
        llama_err "git checkout 失败: 无法恢复到 ${current_short}"
        failed=1
    fi
    # 清理回滚后可能出现的旧子模块残留
    if [[ "$failed" -eq 0 ]]; then
        _cleanup_stale_submodules
    fi
    if ! git -C "$LLAMA_CPP_SRC" submodule update --recursive --quiet 2>/dev/null; then
        llama_warn "子模块回滚不完全，可能需要手动处理"
        failed=1
    fi
    if [[ "$failed" -eq 0 ]]; then
        llama_ok "已回滚到 ${current_short}"
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
    if [[ -n "${current_commit:-}" ]]; then
        git -C "$LLAMA_CPP_SRC" checkout "$current_commit" --quiet 2>/dev/null || true
        git -C "$LLAMA_CPP_SRC" submodule update --recursive --quiet 2>/dev/null || true
    fi
    if [[ -n "${orig_dir:-}" ]]; then
        llama_cd_back
    fi
    llama_safe_exit 130
}

# Usage: _cleanup_stale_submodules
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
            ((stale_count++)) || true  # || true：set -e 下 ((0)) 退出码为 1
        fi
    done < <(find "$LLAMA_CPP_SRC" -path "${LLAMA_CPP_SRC}/build" -prune -o -path "${LLAMA_CPP_SRC}/.git" -prune -o -type f -name '.git' -print)

    if [[ "$stale_count" -gt 0 ]]; then
        llama_ok "旧子模块清理完成 (${stale_count} 个)"
    fi
}

# Usage: _json_field <field_name>
# 使用 Python 提取 JSON 字段。输入通过 stdin 管道传入。
_json_field() {
    python3 -c "import json,sys; print(json.load(sys.stdin)[sys.argv[1]])" "$1"
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
    fi
    echo
    llama_print_run_examples "${LLAMA_CPP_SRC}/build/bin"
}

# --- GitHub API 查询 -----------------------------------------
# Usage: _fetch_latest_release_gh
_fetch_latest_release_gh() {
    local json
    if ! json=$(gh release view --repo "$REPO" --json tagName,targetCommitish,publishedAt,url 2>/dev/null); then
        return 1
    fi
    release_tag=$(printf '%s' "$json" | _json_field tagName) || return 1
    release_commit=$(printf '%s' "$json" | _json_field targetCommitish) || return 1
    release_date=$(printf '%s' "$json" | _json_field publishedAt) || return 1
    release_url=$(printf '%s' "$json" | _json_field url) || return 1
}

# Usage: _fetch_latest_release_curl
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
    # 注意：RETURN trap 仅在函数正常返回时触发，不处理 SIGINT 等信号。
    # 若函数被信号中断时 $tmp 尚未清理，属于低风险的临时文件残留。

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

    # 使用 stdin 重定向，避免路径注入到 Python 字符串中
    release_tag=$(_json_field tag_name < "$tmp") || return 1
    release_commit=$(_json_field target_commitish < "$tmp") || return 1
    release_date=$(_json_field published_at < "$tmp") || return 1
    release_url=$(_json_field html_url < "$tmp") || return 1
}

# --- 子函数 --------------------------------------------------

# Usage: _parse_args [target_version]
_parse_args() {
    target_version=""
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
                target_version="$1"
                ;;
        esac
        shift
        if (($# > 0)); then
            llama_warn "忽略额外参数: $*"
        fi
    fi
}

# Usage: _check_local_repo
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

    orig_dir="$(pwd)"
    cd "$LLAMA_CPP_SRC" >/dev/null
    # 注意：此处 cd 改变全局工作目录。后续函数（_update_source, _rollback 等）
    # 运行 git 命令时不带 -C，依赖此工作目录。所有错误路径必须调用
    # llama_cd_back 恢复原始目录。重构为 git -C 需要修改约 15 处调用。
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

    # 设置中断恢复 trap（函数在顶层定义）
    llama_setup_trap _cleanup_on_interrupt

    local actual_remote
    actual_remote=$(git remote get-url origin 2>/dev/null || echo "")
    local normalized_remote="${actual_remote%.git}"
    local normalized_expected="${REPO_URL%.git}"
    if [[ "$normalized_remote" != "$normalized_expected" ]]; then
        llama_warn "远程 origin 与预期不一致"
        llama_detail "当前: ${actual_remote}"
        llama_detail "预期: ${REPO_URL}"
        llama_warn "如果 origin 是 fork，可能无法获取上游最新 release"
    fi

    llama_ok "本地仓库状态正常"
    llama_detail "当前 Commit: ${current_short}"
    llama_detail "当前标签:    ${current_tag}"
}

# Usage: _resolve_target
_resolve_target() {
    if [[ -n "$target_version" ]]; then
        release_tag="$target_version"
        if llama_is_full_commit_sha "$target_version"; then
            release_commit="$target_version"
        fi
        llama_info "使用用户指定的版本: ${release_tag}"
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
    if [[ ${#release_commit} -ge 7 ]]; then
        release_short="${release_commit:0:7}"
    elif [[ -n "${release_commit:-}" ]]; then
        release_short="${release_commit}"
    else
        release_short="unknown"
    fi
    llama_detail "目标版本:    ${release_tag}"
    if [[ -n "$release_commit" ]] && llama_is_full_commit_sha "$release_commit"; then
        llama_detail "对应 Commit: ${release_short} (${release_commit})"
    fi
    if [[ -n "$release_date" ]]; then
        llama_detail "发布时间:    ${release_date}"
    fi
    if [[ -n "$release_url" ]]; then
        llama_detail "发布页面:    ${release_url}"
    fi

    # 版本对比
    llama_info "对比版本..."
    need_source_update=1
    if [[ "${current_tag}" = "${release_tag}" ]]; then
        llama_ok "本地已在该版本 (${release_tag})，无需更新源码"
        need_source_update=0
    elif llama_is_full_commit_sha "${release_commit}" && [[ "$current_commit" = "$release_commit" ]]; then
        llama_ok "本地已是最新 commit (${release_short})，无需更新源码"
        need_source_update=0
    elif [[ ${#release_commit} -ge 7 ]] && [[ "$(git -C "$LLAMA_CPP_SRC" rev-parse --verify "${release_commit}^{commit}" 2>/dev/null)" == "$current_commit" ]]; then
        llama_ok "本地已是最新 commit (${release_short})，无需更新源码"
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
        llama_warn "需要更新: ${current_short} (${current_tag}) → ${release_tag}"
    fi
}

# Usage: _update_source
_update_source() {
    llama_check_disk_space "$LLAMA_CPP_SRC" || llama_die
    llama_info "正在从远程仓库拉取最新引用..."

    llama_with_network_context "从远程仓库拉取标签" git fetch origin --quiet --tags || {
        llama_cd_back
        llama_die "从远程仓库拉取失败"
    }

    # 尝试拉取特定标签（如果是标签）
    if git ls-remote --tags origin "refs/tags/${release_tag}" 2>/dev/null | grep -q "refs/tags/${release_tag}"; then
        local tag_fetch_rc=0
        git fetch origin --quiet "refs/tags/${release_tag}:refs/tags/${release_tag}" || tag_fetch_rc=$?
        if [[ "$tag_fetch_rc" -ne 0 ]]; then
            llama_detail "特定标签 ref fetch 失败 (退出码: ${tag_fetch_rc})，将使用已拉取的标签"
        fi
    fi

    if ! git rev-parse --verify "${release_tag}^{commit}" &>/dev/null; then
        llama_err "本地找不到目标版本: ${release_tag}"
        llama_detail "请确认版本号正确，或检查网络连接"
        llama_cd_back
        llama_die "本地找不到目标版本: ${release_tag}"
    fi

    llama_info "切换到版本 ${release_tag}..."

    if ! git checkout "${release_tag}" --quiet; then
        llama_err "切换到版本 ${release_tag} 失败"
        llama_cd_back
        _rollback
        llama_die "版本切换失败"
    fi

    actual_commit=$(git rev-parse HEAD)
    actual_tag=$(git describe --tags --exact-match 2>/dev/null || echo "")

    if [[ -n "$actual_tag" && "$actual_tag" != "$release_tag" ]]; then
        llama_warn "checkout 后标签不一致 (期望: ${release_tag}, 实际: ${actual_tag})"
    fi

    if llama_is_full_commit_sha "${release_commit}" && [[ "$actual_commit" != "$release_commit" ]]; then
        llama_warn "checkout commit (${actual_commit:0:7}) 与 API 返回的 commitish (${release_short}) 不一致"
        llama_warn "但标签 ${release_tag} 已确认 checkout 成功，继续构建..."
    fi

    llama_ok "源码已更新到 ${release_tag} (${actual_commit:0:7})"
    # 清理旧版本遗留的子模块目录
    _cleanup_stale_submodules

    # 同步当前版本的子模块
    llama_info "同步子模块..."
    if [[ -f ".gitmodules" ]]; then
        if ! git submodule update --init --recursive --quiet; then
            llama_err "子模块同步失败"
            _rollback
            llama_cd_back
            llama_die "子模块同步失败，已回滚到 ${current_short}"
        fi
        llama_ok "子模块已同步"
    else
        llama_info "当前版本无子模块，跳过"
    fi
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
    llama_run_silent bash "$BUILD_SCRIPT"
    local build_status=$?

    if [[ "$build_status" -ne 0 ]]; then
        _rollback || true
        llama_warn "新版本构建失败，尝试在回滚版本上重新构建..."
        llama_step "回滚后重新构建..."
        llama_run_silent bash "$BUILD_SCRIPT"
        local rollback_build_status=$?
        if [[ "$rollback_build_status" -ne 0 ]]; then
            llama_err "回滚后构建也失败"
            llama_detail "当前状态:"
            local current_head
            current_head=$(git -C "$LLAMA_CPP_SRC" rev-parse --short HEAD 2>/dev/null || echo "未知")
            llama_detail "  当前 HEAD: ${current_head}"
            llama_detail "  原始版本: ${current_short} (${current_tag})"
            llama_detail "  目标版本: ${release_tag}"
            llama_detail "恢复步骤:"
            llama_detail "  cd ${LLAMA_CPP_SRC}"
            llama_detail "  git status"
            llama_detail "  git checkout ${current_commit}"
            llama_detail "  git submodule update --recursive"
            llama_detail "  bash ${BUILD_SCRIPT}"
            llama_cd_back
            llama_die "回滚后构建也失败，请手动恢复到 ${current_short} 后重试"
        fi
        llama_ok "更新失败但已回滚并重新构建成功"
        _print_success_summary 0 "${current_short} (${current_tag})" "${release_tag} (构建失败，已回滚)" ""
        llama_cd_back
        llama_safe_exit 0
    fi
    # 构建成功
    _print_success_summary "${need_source_update}" "${current_short}" "${release_tag}" "${release_date:-}"

    llama_cd_back
    return 0
}

# --- 主逻辑 --------------------------------------------------
main() {
    llama_step "llama.cpp 一键更新脚本"
    _parse_args "$@"
    llama_activate_conda  # 激活 conda 环境（确保 python3/git 等可用）
    _check_local_repo
    _resolve_target
    if [[ "${skip_update:-0}" -eq 1 ]]; then
        llama_cd_back
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
