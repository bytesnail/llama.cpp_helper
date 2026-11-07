#!/usr/bin/env bats
load test_helper

@test "build.sh --help exits 0" {
    run bash "${BATS_TEST_DIRNAME}/../build.sh" --help
    [ "$status" -eq 0 ]
    [[ "$output" =~ "用法" ]]
}

@test "build.sh --version exits 0 and shows version" {
    run bash "${BATS_TEST_DIRNAME}/../build.sh" --version
    [ "$status" -eq 0 ]
    [[ "$output" =~ "llama.cpp_helper" ]]
}

@test "build.sh -h is alias for --help" {
    run bash "${BATS_TEST_DIRNAME}/../build.sh" -h
    [ "$status" -eq 0 ]
    [[ "$output" =~ "用法" ]]
}

@test "build.sh rejects unknown flags with error" {
    run bash "${BATS_TEST_DIRNAME}/../build.sh" --bogus
    [ "$status" -ne 0 ]
    [[ "$output" =~ "未知" ]]
}

@test "build.sh --help mentions --incremental" {
    run bash "${BATS_TEST_DIRNAME}/../build.sh" --help
    [[ "$output" =~ "incremental" ]]
}

@test "build.sh --help mentions --version" {
    run bash "${BATS_TEST_DIRNAME}/../build.sh" --help
    [[ "$output" =~ "version" ]]
}

@test "_verify_linking returns 0 and warns when bin_dir is empty" {
    # Source build.sh in test-only mode to load all functions without executing top-level code
    _load_build

    run _verify_linking "" "llama-cli" "libcudart" "CUDA" "not found"
    [ "$status" -eq 0 ]
    [[ "$output" =~ "未指定二进制目录" ]]
}

@test "_detect_cuda_lib_dir returns failure when nvcc not found" {
    _load_build

    local _saved_path="$PATH"
    export PATH="/nonexistent"
    run _detect_cuda_lib_dir
    export PATH="$_saved_path"
    [ "$status" -eq 1 ]
    [ -z "$output" ]
}


@test "_detect_cuda_lib_dir returns correct path when nvcc is in standard CUDA layout" {
    _load_build

    # Create fake CUDA layout
    local fake_cuda="${TEST_TMPDIR}/fake_cuda"
    local nvcc_bin="${fake_cuda}/bin"
    mkdir -p "$nvcc_bin/../lib64"
    _make_stub_exec "${nvcc_bin}/nvcc"
    touch "${nvcc_bin}/../lib64/libcudart.so"
    mkdir -p "${nvcc_bin}/../targets/x86_64-linux/lib"
    touch "${nvcc_bin}/../targets/x86_64-linux/lib/libcudart.so"

    local _saved_path="$PATH"
    PATH="${nvcc_bin}:$PATH"
    run _detect_cuda_lib_dir
    PATH="$_saved_path"
    [ "$status" -eq 0 ]
    [ -n "$output" ]
}

@test "_verify_binary_exists returns 1 and warns when binary is missing" {
    _load_build

    local empty_dir="${TEST_TMPDIR}/empty_bin"
    mkdir -p "$empty_dir"
    run _verify_binary_exists "llama-cli" "$empty_dir"
    [ "$status" -eq 1 ]
    [[ "$output" =~ "二进制文件未生成" ]]
}

@test "_verify_linking returns 0 when binary does not exist at given path" {
    _load_build

    run _verify_linking "/nonexistent" "llama-cli" "libcudart" "CUDA" "not found"
    [ "$status" -eq 0 ]
    [[ "$output" =~ "不存在" || "$output" =~ "跳过" ]]
}

# --- OpenBLAS linking: ensure pattern does not match cublas ---
@test "_verify_openblas_linking does not match cublas (no false positive)" {

    local fake_bin="${TEST_TMPDIR}/fake_bin_cublas"
    mkdir -p "$fake_bin"
    local fake_binary="${fake_bin}/llama-cli"
    _make_stub_exec "$fake_binary"

    # Stub ldd inside the run subshell so the function dies with it
    run bash -c "_LLAMA_SOURCE_ONLY=1 source \"${BATS_TEST_DIRNAME}/../build.sh\"; ldd() { echo 'libcublas.so.12 => /usr/lib/x86_64-linux-gnu/libcublas.so.12'; }; _verify_openblas_linking \"${fake_bin}\""
    [ "$status" -eq 0 ]
    [[ "$output" =~ "未找到 OpenBLAS" ]]
}

@test "_verify_openblas_linking matches libopenblas correctly" {
    local fake_bin="${TEST_TMPDIR}/fake_bin_openblas"
    mkdir -p "$fake_bin"
    local fake_binary="${fake_bin}/llama-cli"
    _make_stub_exec "$fake_binary"

    # Stub ldd inside the run subshell so the function dies with it
    run bash -c "_LLAMA_SOURCE_ONLY=1 source \"${BATS_TEST_DIRNAME}/../build.sh\"; ldd() { echo 'libopenblas.so.0 => /usr/lib/x86_64-linux-gnu/libopenblas.so.0'; }; _verify_openblas_linking \"${fake_bin}\""
    [ "$status" -eq 0 ]
    [[ "$output" =~ "OpenBLAS 链接正常" ]]
}

@test "_pin_host_toolchain sets COMPILER_PATH to host toolchain bin when unset" {
    # 回归：conda 环境激活后 env bin 的交叉 binutils（sysroot_linux-64 依赖链）
    # 裸名 ld 会劫持系统 gcc 的链接（链接系统 glibc 报 GLIBC_PRIVATE 符号
    # 未定义，CMake try_compile 即失败）——gcc 子程序查找必须钉到系统目录
    _load_build
    unset COMPILER_PATH

    _pin_host_toolchain
    [[ "$COMPILER_PATH" == "$LLAMA_HOST_TOOLCHAIN_BIN" ]]
}

@test "_pin_host_toolchain preserves pre-existing COMPILER_PATH after prefix" {
    _load_build
    COMPILER_PATH="/opt/custom-tools"

    _pin_host_toolchain
    [[ "$COMPILER_PATH" == "${LLAMA_HOST_TOOLCHAIN_BIN}:/opt/custom-tools" ]]
}

# --- UI 资产缓存 ------------------------------------------------
# 契约：provisioning 成功（.ui-stamp 存在）后把 build/tools/ui 三项产物
# 快照进 LLAMA_UI_ASSET_CACHE_DIR/<HEAD>/；全量清理后预放置回去，使
# provisioning 走 stamp 匹配的离线快路径。

@test "_ui_asset_cache_save snapshots stamped tools/ui keyed by HEAD" {
    _load_build
    export LLAMA_UI_ASSET_CACHE_DIR="${TEST_TMPDIR}/ui-cache"
    local head
    head=$(git -C "$LLAMA_CPP_SRC" rev-parse HEAD)
    mkdir -p "${BUILD_DIR}/tools/ui/dist"
    echo "fake-archive" > "${BUILD_DIR}/tools/ui/dist.tar.gz"
    printf 'ggml-org/llama-ui|b0000' > "${BUILD_DIR}/tools/ui/.ui-stamp"
    echo '<html>' > "${BUILD_DIR}/tools/ui/dist/index.html"

    _ui_asset_cache_save
    [[ -f "${LLAMA_UI_ASSET_CACHE_DIR}/${head}/dist.tar.gz" ]]
    [[ -f "${LLAMA_UI_ASSET_CACHE_DIR}/${head}/.ui-stamp" ]]
    [[ -f "${LLAMA_UI_ASSET_CACHE_DIR}/${head}/dist/index.html" ]]
}

@test "_ui_asset_cache_save skips when provisioning stamp missing" {
    _load_build
    export LLAMA_UI_ASSET_CACHE_DIR="${TEST_TMPDIR}/ui-cache"
    local head
    head=$(git -C "$LLAMA_CPP_SRC" rev-parse HEAD)
    mkdir -p "${BUILD_DIR}/tools/ui"
    echo "partial" > "${BUILD_DIR}/tools/ui/dist.tar.gz"

    _ui_asset_cache_save
    [[ ! -e "${LLAMA_UI_ASSET_CACHE_DIR}/${head}" ]]
}

@test "_ui_asset_cache_save skips when dist/index.html missing (incomplete snapshot poison guard)" {
    # 回归：stamp 存在但 dist 缺 index.html 时不得入缓存——上游 stamp 快路径
    # 只要求 stamp + dist/index.html，半份 dist 入缓存会让下次构建以"完整"
    # 假象跳过下载并静默嵌入缺资产的 UI。判据与上游 ui-assets.cmake 一致。
    _load_build
    export LLAMA_UI_ASSET_CACHE_DIR="${TEST_TMPDIR}/ui-cache"
    local head
    head=$(git -C "$LLAMA_CPP_SRC" rev-parse HEAD)
    mkdir -p "${BUILD_DIR}/tools/ui/dist"
    echo "fake-archive" > "${BUILD_DIR}/tools/ui/dist.tar.gz"
    printf 'ggml-org/llama-ui|b0000' > "${BUILD_DIR}/tools/ui/.ui-stamp"
    # dist 存在但没有 index.html

    _ui_asset_cache_save
    [[ ! -e "${LLAMA_UI_ASSET_CACHE_DIR}/${head}" ]]
}

@test "_ui_asset_cache_save leaves no temp dir behind on failure (atomic replace)" {
    # 契约：快照先写 <cache>.tmp.$$，成功后整目录换名——不存在"半份快照"
    # 直接落进正式缓存目录的窗口；cp 失败时临时目录必须被清理
    _load_build
    export LLAMA_UI_ASSET_CACHE_DIR="${TEST_TMPDIR}/ui-cache"
    local head
    head=$(git -C "$LLAMA_CPP_SRC" rev-parse HEAD)
    mkdir -p "${BUILD_DIR}/tools/ui/dist"
    echo "fake-archive" > "${BUILD_DIR}/tools/ui/dist.tar.gz"
    printf 'ggml-org/llama-ui|b0000' > "${BUILD_DIR}/tools/ui/.ui-stamp"
    echo '<html>' > "${BUILD_DIR}/tools/ui/dist/index.html"

    _ui_asset_cache_save
    local leftovers=0
    set +e
    leftovers=$(find "${LLAMA_UI_ASSET_CACHE_DIR}" -maxdepth 1 -name '*.tmp.*' | wc -l)
    set -e
    [ "$leftovers" -eq 0 ]
}

@test "_ui_asset_cache_restore pre-places cached snapshot into build tree" {
    _load_build
    export LLAMA_UI_ASSET_CACHE_DIR="${TEST_TMPDIR}/ui-cache"
    local head
    head=$(git -C "$LLAMA_CPP_SRC" rev-parse HEAD)
    local cached="${LLAMA_UI_ASSET_CACHE_DIR}/${head}"
    mkdir -p "${cached}/dist"
    echo "fake-archive" > "${cached}/dist.tar.gz"
    printf 'ggml-org/llama-ui|b0000' > "${cached}/.ui-stamp"
    echo '<html>' > "${cached}/dist/index.html"

    run _ui_asset_cache_restore
    [ "$status" -eq 0 ]
    [[ "$output" =~ "缓存命中" ]]
    [[ -f "${BUILD_DIR}/tools/ui/dist.tar.gz" ]]
    [[ -f "${BUILD_DIR}/tools/ui/.ui-stamp" ]]
    [[ -f "${BUILD_DIR}/tools/ui/dist/index.html" ]]
}

@test "_ui_asset_cache_restore is a no-op on cache miss" {
    _load_build
    export LLAMA_UI_ASSET_CACHE_DIR="${TEST_TMPDIR}/ui-cache"

    run _ui_asset_cache_restore
    [ "$status" -eq 0 ]
    [[ "$output" != *"缓存命中"* ]]
    # 未命中不得产生副作用（不创建 build/tools/ui）
    [[ ! -e "${BUILD_DIR}/tools/ui" ]]
}

@test "UI asset cache round-trip survives build dir wipe" {
    _load_build
    export LLAMA_UI_ASSET_CACHE_DIR="${TEST_TMPDIR}/ui-cache"
    mkdir -p "${BUILD_DIR}/tools/ui/dist"
    echo "fake-archive" > "${BUILD_DIR}/tools/ui/dist.tar.gz"
    printf 'ggml-org/llama-ui|b0000' > "${BUILD_DIR}/tools/ui/.ui-stamp"
    echo '<html>' > "${BUILD_DIR}/tools/ui/dist/index.html"

    _ui_asset_cache_save
    rm -rf "${BUILD_DIR}"
    _ui_asset_cache_restore

    [[ -f "${BUILD_DIR}/tools/ui/dist.tar.gz" ]]
    [[ -f "${BUILD_DIR}/tools/ui/.ui-stamp" ]]
    [[ -f "${BUILD_DIR}/tools/ui/dist/index.html" ]]
}

@test "_warn_ui_not_embedded warns when UI build system exists but stamp missing" {
    _load_build
    mkdir -p "${LLAMA_CPP_SRC}/tools/ui" "${BUILD_DIR}/tools/ui"
    touch "${LLAMA_CPP_SRC}/tools/ui/CMakeLists.txt"

    run _warn_ui_not_embedded
    [ "$status" -eq 0 ]
    [[ "$output" =~ "Web UI 未嵌入" ]]
}

@test "_warn_ui_not_embedded silent when stamp present or UI system absent" {
    _load_build
    mkdir -p "${LLAMA_CPP_SRC}/tools/ui" "${BUILD_DIR}/tools/ui"
    touch "${LLAMA_CPP_SRC}/tools/ui/CMakeLists.txt" "${BUILD_DIR}/tools/ui/.ui-stamp"

    run _warn_ui_not_embedded
    [ "$status" -eq 0 ]
    [[ -z "$output" ]]

    rm -rf "${LLAMA_CPP_SRC}/tools/ui"
    run _warn_ui_not_embedded
    [ "$status" -eq 0 ]
    [[ -z "$output" ]]
}

@test "_warn_ui_not_embedded silent for upstream Priority 1 prebuilt source dist" {
    # 回归：源码树带预构建 tools/ui/dist（上游 Priority 1，不写 .ui-stamp）
    # 时 UI 已嵌入——不得误报"Web UI 未嵌入"
    _load_build
    mkdir -p "${LLAMA_CPP_SRC}/tools/ui/dist" "${BUILD_DIR}/tools/ui"
    touch "${LLAMA_CPP_SRC}/tools/ui/CMakeLists.txt" \
        "${LLAMA_CPP_SRC}/tools/ui/dist/index.html"

    run _warn_ui_not_embedded
    [ "$status" -eq 0 ]
    [[ -z "$output" ]]
}

@test "config.sh derives default UI cache dir next to the source repo" {
    unset LLAMA_UI_ASSET_CACHE_DIR
    _load_build
    [[ "$LLAMA_UI_ASSET_CACHE_DIR" == "${LLAMA_CPP_SRC%/*}/.llama-helper-cache/ui-assets" ]]
}

@test "config.sh strips trailing slash from LLAMA_CPP_SRC for UI cache derivation" {
    # 回归：`${LLAMA_CPP_SRC%/*}` 对 "/a/b/" 得到 "/a/b"，缓存目录会落进
    # 源码仓库内部——先剥尾随斜杠再取父目录
    run bash -c "
        LLAMA_CPP_SRC='/opt/tools/llama.cpp/'
        source '${BATS_TEST_DIRNAME}/../config.sh' 2>/dev/null
        printf '%s' \"\$LLAMA_UI_ASSET_CACHE_DIR\"
    "
    [ "$status" -eq 0 ]
    [ "$output" = "/opt/tools/.llama-helper-cache/ui-assets" ]
}
