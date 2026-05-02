#!/bin/bash
# ============================================================
# update.sh — llama.cpp 一键更新脚本
# 功能：查询 GitHub 最新 release → 拉取 → 构建
# 用法：cd /mnt/hdd/projects/llama.cpp_helper && bash update.sh [tag|commit]
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
ORIG_DIR=""

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
}

# 回滚到之前的状态
_rollback() {
    llama_warn "正在回滚到之前的版本..."
    local failed=0
    if ! git -C "$LLAMA_CPP_SRC" checkout "$CURRENT_COMMIT" --quiet 2>/dev/null; then
        llama_err "git checkout 失败: 无法恢复到 ${CURRENT_SHORT}"
        failed=1
    fi
    # 清理回滚后可能出现的旧版本子模块残留
    if [[ "$failed" -eq 0 ]]; then
        llama_cleanup_stale_submodules
    fi
    if ! git -C "$LLAMA_CPP_SRC" submodule update --recursive --quiet 2>/dev/null; then
        llama_warn "子模块回滚不完全，可能需要手动处理"
        failed=1
    fi
    if [[ "$failed" -eq 0 ]]; then
        llama_ok "已回滚到 ${CURRENT_SHORT}"
    fi
    return "$failed"
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
    RELEASE_TAG=$(printf '%s' "$json" | python3 -c "import json,sys; print(json.load(sys.stdin)['tagName'])") || return 1
    RELEASE_COMMIT=$(printf '%s' "$json" | python3 -c "import json,sys; print(json.load(sys.stdin)['targetCommitish'])") || return 1
    RELEASE_DATE=$(printf '%s' "$json" | python3 -c "import json,sys; print(json.load(sys.stdin)['publishedAt'])") || return 1
    RELEASE_URL=$(printf '%s' "$json" | python3 -c "import json,sys; print(json.load(sys.stdin)['url'])") || return 1
}

_fetch_latest_release_curl() {
    if ! command -v curl &>/dev/null; then
        llama_err "需要 curl 命令，请先安装"
        return 1
    fi

    local api_url="https://api.github.com/repos/${REPO}/releases/latest"
    local tmp
    tmp=$(mktemp /tmp/llama_release.XXXXXX.json)
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
            cat "$tmp" >&2 || :
        fi
        return 1
    fi

    # 使用 stdin 重定向避免路径注入到 Python 字符串中
    RELEASE_TAG=$(python3 -c "import json,sys; print(json.load(sys.stdin)['tag_name'])" < "$tmp") || return 1
    RELEASE_COMMIT=$(python3 -c "import json,sys; print(json.load(sys.stdin)['target_commitish'])" < "$tmp") || return 1
    RELEASE_DATE=$(python3 -c "import json,sys; print(json.load(sys.stdin)['published_at'])" < "$tmp") || return 1
    RELEASE_URL=$(python3 -c "import json,sys; print(json.load(sys.stdin)['html_url'])" < "$tmp") || return 1
}

# --- 主逻辑 --------------------------------------------------
main() {
    llama_step "llama.cpp 一键更新脚本"

    # 参数解析
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
            *)
                TARGET_VERSION="$1"
                ;;
        esac
        shift
        if (($# > 0)); then
            llama_warn "忽略额外参数: $*"
        fi
    fi

    # 前置检查
    llama_info "检查前置条件..."

    # shellcheck disable=SC2015
        llama_check_commands \
        git "git" \
        python3 "python3" \
        && llama_ok "基础工具检查通过" || llama_die "基础工具检查失败"

    llama_check_dir "$LLAMA_CPP_SRC" "llama.cpp 仓库" || llama_die "llama.cpp 仓库不存在"
    llama_check_file "${LLAMA_CPP_SRC}/.git/config" "Git 仓库配置" || llama_die "所需文件不存在"
    llama_check_file "$BUILD_SCRIPT" "构建脚本" || llama_die "所需文件不存在"

    # 检查本地仓库状态
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
        git submodule foreach 'git status --short' 2>/dev/null || :
        llama_cd_back
        llama_die "子模块中存在未提交的更改，请先处理后再更新"
    fi

    _save_state
    llama_setup_trap _cleanup_on_interrupt

    # 中断恢复陷阱 — SIGINT/SIGTERM 时恢复到更新前状态
    # llama_safe_exit 130: 130 = 128 + 2 (SIGINT 标准退出码)
    _cleanup_on_interrupt() {
        llama_warn "更新被中断，正在恢复..."
        llama_cleanup_trap
        if [[ -n "${CURRENT_COMMIT:-}" ]]; then
            git -C "$LLAMA_CPP_SRC" checkout "$CURRENT_COMMIT" --quiet 2>/dev/null || :
            git -C "$LLAMA_CPP_SRC" submodule update --recursive --quiet 2>/dev/null || :
        fi
        if [[ -n "${ORIG_DIR:-}" ]]; then
            llama_cd_back
        fi
        llama_safe_exit 130
    }

    ACTUAL_REMOTE=$(git remote get-url origin 2>/dev/null || echo "")
    if [[ "$ACTUAL_REMOTE" != "$REPO_URL" && "$ACTUAL_REMOTE" != "${REPO_URL}.git" ]]; then
        llama_warn "远程 origin 与预期不一致"
        llama_detail "当前: ${ACTUAL_REMOTE}"
        llama_detail "预期: ${REPO_URL}"
        llama_warn "如果 origin 是 fork，可能无法获取上游最新 release"
    fi

    llama_ok "本地仓库状态正常"
    llama_detail "当前 Commit: ${CURRENT_SHORT}"
    llama_detail "当前标签:    ${CURRENT_TAG}"

    # 确定目标版本
    if [[ -n "$TARGET_VERSION" ]]; then
        # 用户指定了版本
        RELEASE_TAG="$TARGET_VERSION"
        if llama_is_full_commit_sha "$TARGET_VERSION"; then
            RELEASE_COMMIT="$TARGET_VERSION"
        fi
        llama_info "使用用户指定的版本: ${RELEASE_TAG}"
    else
        # 查询 GitHub 最新 release
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
            llama_cd_back
            llama_safe_exit 0
        else
            llama_warn "当前构建缺失或与源码不匹配，需要重新构建"
            # 跳过源码更新，直接进入构建阶段
            ACTUAL_COMMIT="$CURRENT_COMMIT"
            ACTUAL_TAG="$CURRENT_TAG"
            RELEASE_TAG="${CURRENT_TAG}"
        fi
    else
        llama_warn "需要更新: ${CURRENT_SHORT} (${CURRENT_TAG}) → ${RELEASE_TAG}"
    fi

    if [[ "$NEED_SOURCE_UPDATE" -eq 1 ]]; then
        # 拉取并切换
        llama_info "正在从远程仓库拉取最新引用..."

        llama_with_network_context "从远程仓库拉取标签" git fetch origin --quiet --tags || {
            llama_cd_back
            llama_die "从远程仓库拉取失败"
        }

        # 尝试 fetch 特定标签（如果是标签的话）
        if git ls-remote --tags origin "refs/tags/${RELEASE_TAG}" 2>/dev/null | grep -q "."; then
            git fetch origin --quiet "refs/tags/${RELEASE_TAG}:refs/tags/${RELEASE_TAG}" || :
        fi

        if ! git rev-parse --verify "${RELEASE_TAG}^{commit}" &>/dev/null; then
            llama_err "本地找不到目标版本: ${RELEASE_TAG}"
            llama_detail "请确认版本号正确，或检查网络连接"
            llama_cd_back
            llama_die "本地找不到目标版本: ${RELEASE_TAG}"
        fi

        llama_info "切换到版本 ${RELEASE_TAG}..."

        git checkout "${RELEASE_TAG}" --quiet

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
        llama_cleanup_stale_submodules

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
    fi

    # 构建（带失败回滚 + 回滚后重新构建）
    if [[ "$NEED_SOURCE_UPDATE" -eq 1 ]]; then
        llama_step "源码更新完成，开始构建..."
    else
        llama_step "开始重新构建..."
    fi

    llama_release_lock
    llama_run_silent bash "$BUILD_SCRIPT"
    BUILD_STATUS=$?

    if [[ "$BUILD_STATUS" -ne 0 ]]; then
        _rollback
        llama_warn "新版本构建失败，尝试在回滚版本上重新构建..."
        llama_step "回滚后重新构建..."
        llama_run_silent bash "$BUILD_SCRIPT"
        ROLLBACK_BUILD_STATUS=$?
        if [[ "$ROLLBACK_BUILD_STATUS" -ne 0 ]]; then
            llama_err "回滚后构建也失败"
            llama_detail "当前状态:"
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

main "$@"
_main_rc=$?
llama_return_or_exit ${_main_rc:-0}
