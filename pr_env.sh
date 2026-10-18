#!/bin/bash
# ============================================================
# pr_env.sh — llama.cpp 指定 PR 的隔离构建环境
# 目标：在独立目录中检出 PR head 并构建，与主环境（release 版本）
#       的源码树、build 目录与锁文件完全隔离。
# 说明：本脚本是对 build.sh 环境变量覆盖能力的薄封装；版本更新不走
#       update.sh（其 release tag 语义会把 PR commit 切换掉）。
# Usage: bash pr_env.sh <create|update|build> <PR号> [--src DIR] [-i]
# ============================================================

# 仅在正常执行时启用严格模式（为测试提取而 source 时不启用）
if [[ "${_LLAMA_SOURCE_ONLY:-}" != "1" ]]; then
    set -euo pipefail
fi

# 防止重复 source（与 build.sh/update.sh 同款守卫）
_LLAMA_PR_ENV_SOURCED=${_LLAMA_PR_ENV_SOURCED:-0}
if [[ "$_LLAMA_PR_ENV_SOURCED" -eq 1 ]]; then
    return 0 2>/dev/null || true
fi
_LLAMA_PR_ENV_SOURCED=1

# source common.sh 需要 SCRIPT_DIR，故此处内联初始化
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null && pwd)"
readonly SCRIPT_DIR
source "${SCRIPT_DIR}/common.sh"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/config.sh"

# --- 脚本级状态（_parse_args 写入，main 读取） -----------------
pr_command=""
pr_number=""
pr_src=""
pr_incremental=0

# --- 帮助信息 ------------------------------------------------
# Usage: _show_help
_show_help() {
    llama_show_help \
        "$(basename "$0")" \
        "创建、更新并构建 llama.cpp 指定 PR 的隔离环境（独立源码树与构建目录）。" \
        "  create <PR号> [--src DIR]       克隆并检出 PR head，执行完整构建
  update <PR号> [--src DIR]       拉取 PR 最新 head，变化时增量构建
  build  <PR号> [--src DIR] [-i]  构建已有隔离环境（-i 增量）
  -h, --help                      显示此帮助信息
      --version                   显示版本信息" \
        "  bash pr_env.sh create 29625
  bash pr_env.sh update 29625
  bash pr_env.sh build 29625 -i

默认源码目录：与 LLAMA_CPP_SRC 同级的 llama.cpp-pr<PR号>"
}

# --- 纯函数 --------------------------------------------------
# Usage: _pr_branch <PR号>
_pr_branch() {
    printf 'pr-%s' "$1"
}

# Usage: _default_pr_src <PR号>
# 默认把隔离源码树放在主源码树同级（默认 /mnt/usr/tools/llama.cpp-pr<N>）。
_default_pr_src() {
    local base
    base=$(dirname -- "${LLAMA_CPP_SRC:?LLAMA_CPP_SRC 未设置}")
    printf '%s/llama.cpp-pr%s' "$base" "$1"
}

# Usage: _pr_lock_file <PR号>
# 每个 PR 独立锁文件：默认锁文件只按 UID 区分，不覆盖会与主环境构建互斥。
_pr_lock_file() {
    printf '%s/llama_cpp_helper-pr%s-%s.lock' \
        "${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}" "$1" "$UID"
}

# Usage: _is_positive_int <value>
_is_positive_int() {
    [[ "$1" =~ ^[1-9][0-9]*$ ]]
}

# --- 参数解析 ------------------------------------------------
# Usage: _parse_args <args...>
# 返回：0=解析成功，1=参数错误，2=已输出帮助/版本（调用方按成功退出）。
_parse_args() {
    pr_command=""
    pr_number=""
    pr_src=""
    pr_incremental=0

    if (($# == 0)); then
        llama_err "缺少子命令（create/update/build）"
        return 1
    fi

    case "$1" in
        create|update|build)
            pr_command="$1"
            shift
            ;;
        -h|--help)
            _show_help
            return 2
            ;;
        --version)
            llama_show_version
            return 2
            ;;
        *)
            llama_err "未知子命令: $1"
            llama_detail "可用子命令: create, update, build"
            return 1
            ;;
    esac

    if (($# == 0)); then
        llama_err "缺少 PR 编号"
        return 1
    fi
    pr_number="$1"
    shift
    if ! _is_positive_int "$pr_number"; then
        llama_err "PR 编号必须为正整数: $pr_number"
        return 1
    fi

    while (($# > 0)); do
        case "$1" in
            --src)
                if (($# < 2)) || [[ -z "$2" ]]; then
                    llama_err "--src 需要一个目录参数"
                    return 1
                fi
                pr_src="$2"
                shift 2
                ;;
            -i|--incremental)
                if [[ "$pr_command" == "create" ]]; then
                    llama_err "create 不支持 -i/--incremental（首次构建必须完整）"
                    return 1
                fi
                pr_incremental=1
                shift
                ;;
            -h|--help)
                _show_help
                return 2
                ;;
            --version)
                llama_show_version
                return 2
                ;;
            *)
                llama_err "未知选项: $1"
                return 1
                ;;
        esac
    done
    return 0
}

# --- 前置检查 ------------------------------------------------
# Usage: _require_repo
_require_repo() {
    if [[ ! -d "$pr_src" ]]; then
        llama_err "源码目录不存在: ${pr_src}"
        llama_detail "请先执行: bash $(basename "$0") create ${pr_number}"
        return 1
    fi
    if [[ ! -d "${pr_src}/.git" ]]; then
        llama_err "源码目录不是 Git 仓库: ${pr_src}"
        return 1
    fi
    return 0
}

# Usage: _require_clean_worktree
# fail-closed：git status 失败时不能把"空输出"误判为干净。
_require_clean_worktree() {
    local porcelain status_rc=0
    porcelain=$(git -C "$pr_src" status --porcelain --untracked-files=no 2>/dev/null) || status_rc=$?
    if [[ "$status_rc" -ne 0 ]]; then
        llama_err "无法读取 Git 仓库状态: ${pr_src}"
        return 1
    fi
    if [[ -n "$porcelain" ]]; then
        llama_err "检测到未提交的更改，请先处理后再更新:"
        printf '%s\n' "$porcelain"
        return 1
    fi
    return 0
}

# --- Git 操作 ------------------------------------------------
# Usage: _fetch_pr_head
# 直接从规范上游拉取 PR head 到本地分支 pr-<N>（不依赖 origin 配置），
# 并以 + 强制更新该本地分支以跟随 PR 的新提交。
_fetch_pr_head() {
    local branch
    branch=$(_pr_branch "$pr_number")
    llama_info "拉取 PR #${pr_number} head（refs/pull/${pr_number}/head）..."
    local fetch_rc=0
    git -C "$pr_src" \
        -c http.lowSpeedLimit="${GIT_HTTP_LOW_SPEED_LIMIT}" \
        -c http.lowSpeedTime="${GIT_HTTP_LOW_SPEED_TIME}" \
        fetch "$REPO_URL" "+refs/pull/${pr_number}/head:refs/heads/${branch}" || fetch_rc=$?
    if [[ "$fetch_rc" -ne 0 ]]; then
        llama_err "拉取 PR head 失败 (退出码: ${fetch_rc})"
        llama_detail "请确认 PR #${pr_number} 存在且网络可访问"
        return 1
    fi
    return 0
}

# Usage: _resolve_pr_sha
# 输出 PR 本地跟踪分支当前指向的 commit SHA。
_resolve_pr_sha() {
    local branch
    branch=$(_pr_branch "$pr_number")
    git -C "$pr_src" rev-parse --verify --quiet "refs/heads/${branch}^{commit}"
}

# Usage: _checkout_pr_sha <sha>
_checkout_pr_sha() {
    local sha="$1"
    local checkout_rc=0
    git -C "$pr_src" checkout --quiet --detach "$sha" || checkout_rc=$?
    if [[ "$checkout_rc" -ne 0 ]]; then
        llama_err "检出 PR commit 失败 (退出码: ${checkout_rc}): ${sha}"
        return 1
    fi
    return 0
}

# --- 构建 ----------------------------------------------------
# Usage: _run_build <incremental 0|1>
_run_build() {
    local incremental="$1"
    local lock_file
    lock_file=$(_pr_lock_file "$pr_number")
    local -a build_args=()
    if [[ "$incremental" -eq 1 ]]; then
        build_args+=("-i")
    fi

    llama_step "构建隔离环境 PR #${pr_number}"
    llama_detail "源码: ${pr_src}"
    llama_detail "构建: ${pr_src}/build"
    llama_detail "锁:   ${lock_file}"

    # 流式输出：不捕获 build.sh 输出（长时编译需要可见进度）
    local build_rc=0
    LLAMA_CPP_SRC="$pr_src" \
        BUILD_DIR="${pr_src}/build" \
        LOCK_FILE="$lock_file" \
        bash "${SCRIPT_DIR}/build.sh" ${build_args[@]+"${build_args[@]}"} || build_rc=$?
    if [[ "$build_rc" -ne 0 ]]; then
        llama_err "构建失败 (退出码: ${build_rc})"
        return "$build_rc"
    fi

    llama_ok "PR #${pr_number} 隔离环境构建完成"
    llama_detail "二进制目录: ${pr_src}/build/bin"
    return 0
}

# --- 子命令 --------------------------------------------------
# Usage: _cmd_create
_cmd_create() {
    if [[ -e "$pr_src" ]]; then
        if [[ -d "$pr_src" ]] && [[ -z "$(ls -A "$pr_src" 2>/dev/null)" ]]; then
            llama_info "目标目录为空，将直接克隆到: ${pr_src}"
        else
            llama_err "目标目录已存在且非空: ${pr_src}"
            llama_detail "如需更新已有环境，请使用: bash $(basename "$0") update ${pr_number}"
            return 1
        fi
    fi

    local seed="${LLAMA_CPP_SRC:-}"
    local clone_url="$REPO_URL"
    if [[ -n "$seed" ]] && [[ -d "${seed}/.git" ]]; then
        clone_url="$seed"
        llama_info "从本地仓库克隆（种子: ${seed}）"
    else
        llama_info "从上游克隆: ${REPO_URL}"
    fi

    local clone_rc=0
    git clone "$clone_url" "$pr_src" || clone_rc=$?
    if [[ "$clone_rc" -ne 0 ]]; then
        llama_err "克隆失败 (退出码: ${clone_rc})"
        return 1
    fi

    local remote_rc=0
    git -C "$pr_src" remote set-url origin "$REPO_URL" || remote_rc=$?
    if [[ "$remote_rc" -ne 0 ]]; then
        llama_err "设置 origin 失败 (退出码: ${remote_rc})"
        return 1
    fi

    _fetch_pr_head || return $?
    local sha
    sha=$(_resolve_pr_sha) || {
        llama_err "无法解析 PR head commit"
        return 1
    }
    llama_info "检出 PR head: ${sha}"
    _checkout_pr_sha "$sha" || return $?

    _run_build 0 || return $?
    return 0
}

# Usage: _cmd_update
_cmd_update() {
    _require_repo || return $?
    _require_clean_worktree || return $?

    local old_sha
    old_sha=$(git -C "$pr_src" rev-parse HEAD 2>/dev/null || true)
    if [[ -z "$old_sha" ]]; then
        llama_err "无法读取当前 HEAD: ${pr_src}"
        return 1
    fi

    _fetch_pr_head || return $?
    local new_sha
    new_sha=$(_resolve_pr_sha) || {
        llama_err "无法解析 PR head commit"
        return 1
    }

    if [[ "$new_sha" == "$old_sha" ]]; then
        llama_ok "已是最新 PR head: ${new_sha:0:12}"
        llama_detail "如需强制重建，请执行: bash $(basename "$0") build ${pr_number}"
        return 0
    fi

    llama_info "PR head 更新: ${old_sha:0:12} → ${new_sha:0:12}"
    _checkout_pr_sha "$new_sha" || return $?
    _run_build 1 || return $?
    return 0
}

# Usage: _cmd_build
_cmd_build() {
    _require_repo || return $?
    _run_build "$pr_incremental" || return $?
    return 0
}

# --- 主逻辑 --------------------------------------------------
main() {
    local parse_rc=0
    _parse_args "$@" || parse_rc=$?
    if [[ "$parse_rc" -eq 2 ]]; then
        llama_safe_exit 0
    elif [[ "$parse_rc" -ne 0 ]]; then
        llama_safe_exit 1
    fi

    if [[ -z "$pr_src" ]]; then
        pr_src=$(_default_pr_src "$pr_number")
    fi

    local rc=0
    case "$pr_command" in
        create) _cmd_create || rc=$? ;;
        update) _cmd_update || rc=$? ;;
        build)  _cmd_build  || rc=$? ;;
    esac
    llama_safe_exit "$rc"
}

if [[ "${_LLAMA_SOURCE_ONLY:-}" != "1" ]]; then
    main "$@"
    _main_rc=$?
    llama_return_or_exit "$_main_rc"
fi
