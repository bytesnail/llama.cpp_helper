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
