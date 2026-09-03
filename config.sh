#!/bin/bash
# ============================================================
# config.sh — 集中管理共享路径和常量
# Usage: source /path/to/llama.cpp_helper/config.sh
# ============================================================

# 防止直接执行
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "[WARN] 本文件应当被 source，而非直接执行" >&2
    echo "用法: source ${BASH_SOURCE[0]}" >&2
    exit 1
fi

# 防止重复 source
_LLAMA_CONFIG_SOURCED=${_LLAMA_CONFIG_SOURCED:-0}
if [[ "$_LLAMA_CONFIG_SOURCED" -eq 1 ]]; then
    return 0 2>/dev/null || true
fi
_LLAMA_CONFIG_SOURCED=1

# --- 路径 ----------------------------------------------------
# 可通过环境变量覆盖；默认为本机事实标准目录（与 ~/.bashrc 的同名 export
# 对齐的配置层落地）：非交互上下文（cron/systemd 等）不加载 bashrc，若默认
# 仍按相邻布局解析为 <本项目>/../llama.cpp，update.sh 的首次自动克隆会在
# 错误位置静默克隆出第二份源码。其他机器使用本项目时显式设置 LLAMA_CPP_SRC。
LLAMA_CPP_SRC="${LLAMA_CPP_SRC:-/mnt/usr/tools/llama.cpp}"

# 构建产物布局（写方 build.sh 与读方 common.sh/update.sh 的共享协议，单一定义）
BUILD_DIR="${BUILD_DIR:-${LLAMA_CPP_SRC}/build}"
BUILD_BIN_DIR="${BUILD_BIN_DIR:-${BUILD_DIR}/bin}"
BUILD_STAMP="${BUILD_STAMP:-${BUILD_DIR}/.build-stamp}"

# --- 仓库信息 ------------------------------------------------
REPO="ggml-org/llama.cpp"
readonly REPO
# 由 REPO 派生（单一事实来源）：两处字面量各自维护会在迁移 fork/镜像时漂移
REPO_URL="https://github.com/${REPO}"
readonly REPO_URL

# --- 资源限制和路径 ------------------------------------------
MIN_FREE_DISK_GB=10
readonly MIN_FREE_DISK_GB

# host 工具链（gcc 的 ld/as 等子程序）查找目录：conda 激活后 env bin 优先于
# 系统 PATH，其中的交叉 binutils（sysroot_linux-64 依赖链带入）裸名 ld/as
# 会劫持系统 gcc 的链接——conda ld 为 glibc 2.28 sysroot 构建，链接系统
# glibc 报 GLIBC_PRIVATE 符号未定义，CMake try_compile 即失败
LLAMA_HOST_TOOLCHAIN_BIN="${LLAMA_HOST_TOOLCHAIN_BIN:-/usr/bin}"
LOCK_FILE="${LOCK_FILE:-${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}/llama_cpp_helper-${UID}.lock}"
readonly LOCK_FILE

# --- 构建配置（可通过环境变量覆盖） ---------------------------
CMAKE_BUILD_TYPE="${CMAKE_BUILD_TYPE:-Release}"
CMAKE_CUDA_ARCHITECTURES="${CMAKE_CUDA_ARCHITECTURES:-75}"
CMAKE_CUDA_FLAGS="${CMAKE_CUDA_FLAGS:---threads=0}" # NVCC 并行编译线程数（0=自动检测所有核心）
GGML_CUDA="${GGML_CUDA:-ON}"
# 注：GGML_CUDA_PEER_MAX_BATCH_SIZE 已移除——llama.cpp v0.3.0 的 CUDA 后端
# 不再消费该选项（上游 #24216/#19378 重构中移除，仅 SYCL 侧还有同名），
# 透传为无效参数；如上游恢复使用，经环境变量设置即可（CMake cache STRING）
GGML_CUDA_FA_ALL_QUANTS="${GGML_CUDA_FA_ALL_QUANTS:-ON}"
GGML_CUDA_GRAPHS="${GGML_CUDA_GRAPHS:-OFF}" # CUDA graphs（编译期开关；固定 shape 推理受益，默认 OFF 保持上游行为）
GGML_NATIVE="${GGML_NATIVE:-ON}"
GGML_BLAS="${GGML_BLAS:-ON}"
GGML_BLAS_VENDOR="${GGML_BLAS_VENDOR:-OpenBLAS}"
LLAMA_BUILD_TESTS="${LLAMA_BUILD_TESTS:-OFF}" # 是否构建 llama.cpp 自身测试（节省编译时间默认 OFF）

# 构建旋钮表：build.sh 按此表循环生成 cmake -D 透传参数（单一事实来源）。
# 新增构建旋钮 = 在上方定义变量（${VAR:-default}）+ 在此表登记名字，build.sh 无需改动；
# 表内名字与本节变量定义的同步由 test_smoke.bats 钉住。
# declare -ar 是 Bash 中声明只读数组的唯一方式（readonly 无法作用于数组）
declare -ar LLAMA_CMAKE_KNOBS=(
    CMAKE_BUILD_TYPE
    CMAKE_CUDA_ARCHITECTURES
    CMAKE_CUDA_FLAGS
    GGML_CUDA
    GGML_CUDA_FA_ALL_QUANTS
    GGML_CUDA_GRAPHS
    GGML_NATIVE
    GGML_BLAS
    GGML_BLAS_VENDOR
    LLAMA_BUILD_TESTS
)

# --- conda 配置 ----------------------------------------------
CONDA_AUTO_ACTIVATE="${CONDA_AUTO_ACTIVATE:-1}"     # 0=跳过, 1=自动激活
CONDA_ENV_NAME="${CONDA_ENV_NAME:-llama.cpp}"        # 要激活的 conda 环境名称（默认为本机构建专用环境，CUDA 工具链所在；权威：已激活其他环境时强制切换；激活失败 build.sh/update.sh 报错中止）

# --- 网络超时配置（可通过环境变量覆盖） -----------------------
CURL_CONNECT_TIMEOUT="${CURL_CONNECT_TIMEOUT:-10}"  # 秒；update.sh HTTP 连接超时
CURL_MAX_TIME="${CURL_MAX_TIME:-30}"                 # 秒；update.sh HTTP 最大请求时间
# git HTTP 低速保护：低于限速持续超时秒数即中止传输（防止网络半挂起时 update.sh 无限期持锁）
GIT_HTTP_LOW_SPEED_LIMIT="${GIT_HTTP_LOW_SPEED_LIMIT:-1000}"  # 字节/秒
GIT_HTTP_LOW_SPEED_TIME="${GIT_HTTP_LOW_SPEED_TIME:-15}"      # 秒

# --- 关键二进制文件（用于构建验证和健康检查） -----------------
# declare -ar 是 Bash 中声明只读数组的唯一方式（readonly 无法作用于数组）
declare -ar REQUIRED_BINARIES=("llama-cli" "llama-server")

# --- 版本号 ---------------------------------------------------
LLAMA_HELPER_VERSION="1.0.0"
readonly LLAMA_HELPER_VERSION
