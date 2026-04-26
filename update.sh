#!/bin/bash
# ============================================================
# llama.cpp 一键更新脚本
# 功能：查询 GitHub 最新 release → 拉取 → 构建
# 用法：cd /mnt/hdd/projects/llama.cpp_helper && bash update.sh [tag|commit]
# ============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null && pwd)"

# shellcheck source=/dev/null
source "${SCRIPT_DIR}/common.sh"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/config.sh"

BUILD_SCRIPT="${SCRIPT_DIR}/build.sh"

# --- 状态变量 ------------------------------------------------
RELEASE_TAG=""
RELEASE_COMMIT=""
RELEASE_DATE=""
RELEASE_URL=""
CURRENT_COMMIT=""
CURRENT_SHORT=""
CURRENT_TAG=""

# --- 帮助信息 ------------------------------------------------
show_help() {
    cat <<EOF
用法: $(basename "$0") [tag|commit]

描述:
  将 llama.cpp 更新到指定版本或最新 release，并自动重新构建。

参数:
  tag|commit    可选。指定要更新到的标签或 commit SHA。
                如果不提供，自动查询 GitHub 最新 release。

选项:
  -h, --help    显示此帮助信息

示例:
  bash update.sh                    # 更新到最新 release
  bash update.sh b3631              # 更新到指定 commit
  bash update.sh v0.0.1             # 更新到指定标签
  bash update.sh --help             # 显示帮助
EOF
}
# --- 工具函数 ------------------------------------------------
is_full_commit_sha() { [[ "$1" =~ ^[a-fA-F0-9]{40}$ ]]; }

# 保存当前状态以便回滚
save_state() {
    CURRENT_COMMIT=$(git -C "$LLAMA_CPP_SRC" rev-parse HEAD)
    CURRENT_SHORT=$(git -C "$LLAMA_CPP_SRC" rev-parse --short HEAD)
    CURRENT_TAG=$(git -C "$LLAMA_CPP_SRC" describe --tags --exact-match 2>/dev/null || echo "(无标签)")
}

# 回滚到之前的状态
rollback() {
    llama_warn "正在回滚到之前的版本..."
    git -C "$LLAMA_CPP_SRC" checkout "$CURRENT_COMMIT" --quiet 2>/dev/null || true
    # 恢复子模块到与主仓库一致的状态
    git -C "$LLAMA_CPP_SRC" submodule update --recursive --quiet 2>/dev/null || true
    llama_info "已回滚到 ${CURRENT_SHORT}"
}

# 检查当前构建是否完整可用
# 返回 0 = 构建完整，1 = 构建缺失或不完整
check_build_health() {
    local bin_dir="${LLAMA_CPP_SRC}/build/bin"
    if [[ ! -d "$bin_dir" ]]; then
        return 1
    fi
    # 检查关键二进制文件是否存在且可执行
    for binary in llama-cli llama-server; do
        if [[ ! -x "${bin_dir}/${binary}" ]]; then
            return 1
        fi
    done
    # 检查构建标记文件是否存在且与当前源码 commit 匹配
    local build_stamp="${LLAMA_CPP_SRC}/build/.build-stamp"
    local current_head
    current_head=$(git -C "$LLAMA_CPP_SRC" rev-parse HEAD 2>/dev/null || echo "")
    if [[ -f "$build_stamp" ]]; then
        local stamped_head
        stamped_head=$(cat "$build_stamp" 2>/dev/null || echo "")
        if [[ "$stamped_head" == "$current_head" ]]; then
            return 0
        fi
    fi
    # 没有标记文件或不匹配，说明 build 目录可能来自其他版本
    return 1
}

# --- GitHub API 查询 -----------------------------------------
fetch_latest_release_gh() {
    local json
    if ! json=$(gh release view --repo "$REPO" --json tagName,targetCommitish,publishedAt,url 2>/dev/null); then
        return 1
    fi
    RELEASE_TAG=$(echo "$json" | python3 -c "import json,sys; print(json.load(sys.stdin)['tagName'])") || return 1
    RELEASE_COMMIT=$(echo "$json" | python3 -c "import json,sys; print(json.load(sys.stdin)['targetCommitish'])") || return 1
    RELEASE_DATE=$(echo "$json" | python3 -c "import json,sys; print(json.load(sys.stdin)['publishedAt'])") || return 1
    RELEASE_URL=$(echo "$json" | python3 -c "import json,sys; print(json.load(sys.stdin)['url'])") || return 1
}

fetch_latest_release_curl() {
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
    http_code=$(curl -sL --connect-timeout 10 --max-time 30 \
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

    RELEASE_TAG=$(python3 -c "import json; r=json.load(open('$tmp')); print(r['tag_name'])") || return 1
    RELEASE_COMMIT=$(python3 -c "import json; r=json.load(open('$tmp')); print(r['target_commitish'])") || return 1
    RELEASE_DATE=$(python3 -c "import json; r=json.load(open('$tmp')); print(r['published_at'])") || return 1
    RELEASE_URL=$(python3 -c "import json; r=json.load(open('$tmp')); print(r['html_url'])") || return 1
}

# --- 主逻辑 --------------------------------------------------
echo ""
echo "=========================================="
echo "  llama.cpp 一键更新脚本"
echo "=========================================="
echo ""

# 参数解析
TARGET_VERSION=""
if (($# > 0)); then
    case "$1" in
        -h|--help)
            show_help
            exit 0
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

llama_check_commands \
    git "git" \
    python3 "python3" \
    && llama_ok "基础工具检查通过" || exit 1

llama_check_dir "$LLAMA_CPP_SRC" "llama.cpp 仓库" || exit 1
llama_check_file "${LLAMA_CPP_SRC}/.git/config" "Git 仓库配置" || exit 1
llama_check_file "$BUILD_SCRIPT" "构建脚本" || exit 1

# 检查本地仓库状态
llama_info "检查本地仓库状态..."

cd "$LLAMA_CPP_SRC" >/dev/null

if [[ -n "$(git status --porcelain 2>/dev/null)" ]]; then
    llama_err "检测到未提交的更改，请先处理后再更新:"
    git status --short
    exit 1
fi

save_state

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
    if is_full_commit_sha "$TARGET_VERSION"; then
        RELEASE_COMMIT="$TARGET_VERSION"
    fi
    llama_info "使用用户指定的版本: ${RELEASE_TAG}"
else
    # 查询 GitHub 最新 release
    llama_info "正在查询 GitHub 最新发布版本..."

    if command -v gh &>/dev/null && gh auth status &>/dev/null; then
        llama_info "使用 gh CLI 查询（已认证）"
        if ! fetch_latest_release_gh; then
            llama_warn "gh 查询失败，回退到 curl"
            if ! fetch_latest_release_curl; then
                exit 1
            fi
        fi
    else
        llama_warn "gh 未安装或未登录，使用 curl 直接访问 API"
        if ! fetch_latest_release_curl; then
            exit 1
        fi
    fi

    llama_ok "查询成功"
fi

# 显示版本信息
RELEASE_SHORT="${RELEASE_COMMIT:0:7}"
llama_detail "目标版本:    ${RELEASE_TAG}"
if [[ -n "$RELEASE_COMMIT" ]] && is_full_commit_sha "$RELEASE_COMMIT"; then
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
elif is_full_commit_sha "${RELEASE_COMMIT}" && [[ "$CURRENT_COMMIT" = "$RELEASE_COMMIT" ]]; then
    llama_ok "本地已是最新 commit (${RELEASE_SHORT})，无需更新源码"
    NEED_SOURCE_UPDATE=0
fi

if [[ "$NEED_SOURCE_UPDATE" -eq 0 ]]; then
    # 源码无需更新，检查构建是否完整
    if check_build_health; then
        llama_ok "当前构建完整且与源码匹配，无需任何操作！"
        exit 0
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

    git fetch origin --quiet --tags

    # 尝试 fetch 特定标签（如果是标签的话）
    if git ls-remote --tags origin "refs/tags/${RELEASE_TAG}" 2>/dev/null | grep -q "."; then
        git fetch origin --quiet "refs/tags/${RELEASE_TAG}:refs/tags/${RELEASE_TAG}" || true
    fi

    if ! git rev-parse --verify "${RELEASE_TAG}^{commit}" &>/dev/null; then
        llama_err "本地找不到目标版本: ${RELEASE_TAG}"
        llama_detail "请确认版本号正确，或检查网络连接"
        exit 1
    fi

    llama_info "切换到版本 ${RELEASE_TAG}..."

    git checkout "${RELEASE_TAG}" --quiet

    ACTUAL_COMMIT=$(git rev-parse HEAD)
    ACTUAL_TAG=$(git describe --tags --exact-match 2>/dev/null || echo "")

    if [[ -n "$ACTUAL_TAG" && "$ACTUAL_TAG" != "$RELEASE_TAG" ]]; then
        llama_warn "checkout 后标签不一致 (期望: ${RELEASE_TAG}, 实际: ${ACTUAL_TAG})"
    fi

    if is_full_commit_sha "${RELEASE_COMMIT}" && [[ "$ACTUAL_COMMIT" != "$RELEASE_COMMIT" ]]; then
        llama_warn "checkout commit (${ACTUAL_COMMIT:0:7}) 与 API 返回的 commitish (${RELEASE_SHORT}) 不一致"
        llama_warn "但标签 ${RELEASE_TAG} 已确认 checkout 成功，继续构建..."
    fi

    llama_ok "源码已更新到 ${RELEASE_TAG} (${ACTUAL_COMMIT:0:7})"

    # 清理旧版本残留的子模块目录
    # git checkout 不会自动删除旧版本中已 init 但新版本不再追踪的子模块工作目录
    # 扫描工作目录中的 .git gitlink 文件，对比当前索引中的 submodule 路径，找出残留
    local -A expected_paths
    while IFS= read -r path; do
        expected_paths["$path"]=1
    done < <(git ls-files --stage | grep '^160000' | awk '{print $NF}')

    local stale_count=0
    while IFS= read -r gitlink; do
        local mod_dir="$(dirname "$gitlink")"
        # 跳过当前版本仍在追踪的 submodule
        if [[ -n "${expected_paths[$mod_dir]}" ]]; then
            continue
        fi
        # 确认是 submodule 的 gitlink 文件（内容为 gitdir:...）
        if grep -q '^gitdir:' "$gitlink" 2>/dev/null; then
            llama_info "清理旧子模块残留: ${mod_dir}"
            rm -rf "$mod_dir"
            ((stale_count++)) || true
        fi
    done < <(find . -path './build' -prune -o -path './.git' -prune -o -type f -name '.git' -print | sed 's|^\./||')

    if [[ "$stale_count" -gt 0 ]]; then
        llama_ok "旧子模块清理完成 (${stale_count} 个)"
    fi

    # 同步当前版本的子模块
    llama_info "同步子模块..."
    if [[ -f ".gitmodules" ]]; then
        if ! git submodule update --init --recursive --quiet; then
            llama_err "子模块同步失败"
            rollback
            exit 1
        fi
        llama_ok "子模块已同步"
    else
        llama_info "当前版本无子模块，跳过"
    fi
fi

# 构建（带失败回滚 + 回滚后重新构建）
echo ""
echo "=========================================="
if [[ "$NEED_SOURCE_UPDATE" -eq 1 ]]; then
    echo "  源码更新完成，开始构建..."
else
    echo "  开始重新构建..."
fi
echo "=========================================="
echo ""

set +e
bash "$BUILD_SCRIPT"
BUILD_STATUS=$?
set -e

if [[ "$BUILD_STATUS" -ne 0 ]]; then
    rollback
    llama_warn "新版本构建失败，尝试在回滚版本上重新构建..."
    echo ""
    echo "=========================================="
    echo "  回滚后重新构建..."
    echo "=========================================="
    echo ""
    set +e
    bash "$BUILD_SCRIPT"
    ROLLBACK_BUILD_STATUS=$?
    set -e
    if [[ "$ROLLBACK_BUILD_STATUS" -ne 0 ]]; then
        llama_err "回滚后构建也失败，请手动检查"
        exit 1
    fi
    llama_warn "更新失败但已回滚并重新构建成功"
    echo ""
    echo "=========================================="
    echo "  回滚并重新构建完成"
    echo "=========================================="
    echo ""
    echo "  当前版本: ${CURRENT_SHORT} (${CURRENT_TAG})"
    echo "  目标版本: ${RELEASE_TAG} (构建失败，已回滚)"
    echo ""
    echo "运行示例:"
    echo "  source ${SCRIPT_DIR}/run_env.sh"
    echo "  ${LLAMA_CPP_SRC}/build/bin/llama-cli -m /path/to/model.gguf -ngl 99 -p \"你好\""
    echo "  ${LLAMA_CPP_SRC}/build/bin/llama-server -m /path/to/model.gguf -ngl 99 --port 8080"
    exit 1
fi

# 构建成功
echo ""
echo "=========================================="
echo "  llama.cpp 更新并构建完成！"
echo "=========================================="
echo ""
if [[ "$NEED_SOURCE_UPDATE" -eq 1 ]]; then
    echo "  更新: ${CURRENT_SHORT} → ${ACTUAL_COMMIT:0:7}"
    echo "  版本: ${RELEASE_TAG}"
    if [[ -n "$RELEASE_DATE" ]]; then
        echo "  发布: ${RELEASE_DATE}"
    fi
else
    echo "  版本: ${CURRENT_TAG} (${CURRENT_SHORT})"
    echo "  状态: 重新构建完成"
fi
echo ""
echo "运行示例:"
echo "  source ${SCRIPT_DIR}/run_env.sh"
echo "  ${LLAMA_CPP_SRC}/build/bin/llama-cli -m /path/to/model.gguf -ngl 99 -p \"你好\""
echo "  ${LLAMA_CPP_SRC}/build/bin/llama-server -m /path/to/model.gguf -ngl 99 --port 8080"
