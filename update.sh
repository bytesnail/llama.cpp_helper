#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.sh"
BUILD_SCRIPT="${SCRIPT_DIR}/build.sh"
REPO="ggml-org/llama.cpp"
REPO_URL="https://github.com/ggml-org/llama.cpp"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

info()  { echo -e "${CYAN}[INFO]${NC} $*"; }
ok()    { echo -e "${GREEN}[OK]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }

RELEASE_TAG=""
RELEASE_COMMIT=""
RELEASE_DATE=""
RELEASE_URL=""

is_commit_sha() { [[ "$1" =~ ^[a-fA-F0-9]{40}$ ]]; }

fetch_latest_release_gh() {
    local json
    json=$(gh release view --repo "${REPO}" --json tagName,targetCommitish,publishedAt,url) || return 1
    RELEASE_TAG=$(echo "${json}" | python3 -c "import json,sys; print(json.load(sys.stdin)['tagName'])") || return 1
    RELEASE_COMMIT=$(echo "${json}" | python3 -c "import json,sys; print(json.load(sys.stdin)['targetCommitish'])") || return 1
    RELEASE_DATE=$(echo "${json}" | python3 -c "import json,sys; print(json.load(sys.stdin)['publishedAt'])") || return 1
    RELEASE_URL=$(echo "${json}" | python3 -c "import json,sys; print(json.load(sys.stdin)['url'])") || return 1
}

fetch_latest_release_curl() {
    if ! command -v curl &>/dev/null; then
        err "需要 curl 命令，请先安装"
        return 1
    fi
    local api_url="https://api.github.com/repos/${REPO}/releases/latest"
    local tmp
    tmp=$(mktemp /tmp/llama_release.XXXXXX.json)
    trap 'rm -f "${tmp}"' RETURN
    local http_code
    http_code=$(curl -sL --connect-timeout 10 --max-time 30 \
        -o "${tmp}" -w "%{http_code}" \
        -H "Accept: application/vnd.github+json" "${api_url}") || return 1
    if [ "${http_code}" != "200" ]; then
        err "GitHub API 请求失败 (HTTP ${http_code})"
        cat "${tmp}" 2>/dev/null >&2
        return 1
    fi
    RELEASE_TAG=$(python3 -c "import json; r=json.load(open('${tmp}')); print(r['tag_name'])") || return 1
    RELEASE_COMMIT=$(python3 -c "import json; r=json.load(open('${tmp}')); print(r['target_commitish'])") || return 1
    RELEASE_DATE=$(python3 -c "import json; r=json.load(open('${tmp}')); print(r['published_at'])") || return 1
    RELEASE_URL=$(python3 -c "import json; r=json.load(open('${tmp}')); print(r['html_url'])") || return 1
}

echo ""
echo "=========================================="
echo "  llama.cpp 一键更新脚本"
echo "=========================================="
echo ""

info "检查前置条件..."

if [ ! -d "${LLAMA_CPP_SRC}/.git" ]; then
    err "未找到 llama.cpp 仓库: ${LLAMA_CPP_SRC}"
    err "请先克隆仓库: git clone ${REPO_URL} ${LLAMA_CPP_SRC}"
    exit 1
fi

if [ ! -f "${BUILD_SCRIPT}" ]; then
    err "未找到构建脚本: ${BUILD_SCRIPT}"
    exit 1
fi

if ! command -v python3 &>/dev/null; then
    err "需要 python3 命令，请先安装"
    exit 1
fi

ok "前置条件检查通过"

echo ""
info "检查本地仓库状态..."

cd "${LLAMA_CPP_SRC}"

if [ -n "$(git status --porcelain)" ]; then
    err "检测到未提交的更改，请先处理（stash 或 commit）后再更新："
    git status --short
    exit 1
fi

ACTUAL_REMOTE=$(git remote get-url origin 2>/dev/null || echo "")
if [ "${ACTUAL_REMOTE}" != "${REPO_URL}" ]; then
    warn "远程 origin (${ACTUAL_REMOTE}) 与预期 (${REPO_URL}) 不一致"
    warn "如果 origin 是 fork，可能无法获取上游最新 release 标签"
fi

CURRENT_COMMIT=$(git rev-parse HEAD)
CURRENT_SHORT=$(git rev-parse --short HEAD)
CURRENT_TAG=$(git describe --tags --exact-match 2>/dev/null || echo "(不在发布标签上)")

ok "本地仓库状态正常"
echo "  当前 Commit: ${CURRENT_SHORT}"
echo "  当前标签:    ${CURRENT_TAG}"

echo ""
info "正在查询 GitHub 最新发布版本..."

if command -v gh &>/dev/null && gh auth status &>/dev/null; then
    info "使用 gh CLI 查询（已认证，无限流顾虑）"
    if ! fetch_latest_release_gh; then
        warn "gh 查询失败，回退到 curl"
        if ! fetch_latest_release_curl; then
            exit 1
        fi
    fi
else
    warn "gh 未安装或未登录，使用 curl 直接访问 API"
    if ! fetch_latest_release_curl; then
        exit 1
    fi
fi

RELEASE_SHORT="${RELEASE_COMMIT:0:7}"

ok "查询成功"
echo "  最新版本:    ${RELEASE_TAG}"
if is_commit_sha "${RELEASE_COMMIT}"; then
    echo "  对应 Commit: ${RELEASE_SHORT} (${RELEASE_COMMIT})"
else
    echo "  目标分支:    ${RELEASE_COMMIT}"
fi
echo "  发布时间:    ${RELEASE_DATE}"
echo "  发布页面:    ${RELEASE_URL}"

echo ""
info "对比版本..."

if [ "${CURRENT_TAG}" = "${RELEASE_TAG}" ]; then
    ok "本地已在该发布标签上 (${RELEASE_TAG})，无需更新！"
    exit 0
fi

if is_commit_sha "${RELEASE_COMMIT}" && [ "${CURRENT_COMMIT}" = "${RELEASE_COMMIT}" ]; then
    ok "本地已是最新发布版本的 commit (${RELEASE_SHORT})，无需更新！"
    exit 0
fi

if is_commit_sha "${RELEASE_COMMIT}"; then
    warn "需要更新: ${CURRENT_SHORT} (${CURRENT_TAG}) → ${RELEASE_SHORT} (${RELEASE_TAG})"
else
    warn "需要更新: ${CURRENT_SHORT} (${CURRENT_TAG}) → ${RELEASE_TAG}"
fi

echo ""
info "正在从远程仓库拉取最新引用和标签..."

git fetch origin --quiet --force "refs/tags/${RELEASE_TAG}:refs/tags/${RELEASE_TAG}"

if ! git rev-parse "${RELEASE_TAG}" &>/dev/null; then
    err "本地找不到标签 ${RELEASE_TAG}，fetch 可能失败"
    exit 1
fi

info "切换到发布版本 ${RELEASE_TAG}..."

git checkout "${RELEASE_TAG}" --quiet

ACTUAL_COMMIT=$(git rev-parse HEAD)
ACTUAL_TAG=$(git describe --tags --exact-match 2>/dev/null || echo "")

if [ "${ACTUAL_TAG}" != "${RELEASE_TAG}" ]; then
    err "checkout 后不在预期标签上 (期望: ${RELEASE_TAG}, 实际: ${ACTUAL_TAG})"
    exit 1
fi

if is_commit_sha "${RELEASE_COMMIT}" && [ "${ACTUAL_COMMIT}" != "${RELEASE_COMMIT}" ]; then
    warn "checkout commit (${ACTUAL_COMMIT:0:7}) 与 API 返回的 commitish (${RELEASE_SHORT}) 不一致"
    warn "但标签 ${RELEASE_TAG} 已确认 checkout 成功，继续构建..."
fi

ok "源码已更新到 ${RELEASE_TAG} (${ACTUAL_COMMIT:0:7})"

echo ""
info "同步子模块..."
if [ -f "${LLAMA_CPP_SRC}/.gitmodules" ]; then
    git submodule update --init --recursive --quiet
    ok "子模块已同步"
else
    info "当前版本无子模块，跳过"
fi

echo ""
echo "=========================================="
echo "  源码更新完成，开始构建..."
echo "=========================================="
echo ""

bash "${BUILD_SCRIPT}"

echo ""
echo "=========================================="
echo "  llama.cpp 更新并构建完成！"
echo "=========================================="
echo ""
echo "  更新: ${CURRENT_SHORT} → ${ACTUAL_COMMIT:0:7}"
echo "  版本: ${RELEASE_TAG}"
echo "  发布: ${RELEASE_DATE}"
echo ""
echo "运行示例:"
echo "  source /mnt/hdd/projects/llama.cpp_helper/run_env.sh"
echo "  ${LLAMA_CPP_SRC}/build/bin/llama-cli -m /path/to/model.gguf -ngl 99 -p \"你好\""
echo "  ${LLAMA_CPP_SRC}/build/bin/llama-server -m /path/to/model.gguf -ngl 99 --port 8080"
