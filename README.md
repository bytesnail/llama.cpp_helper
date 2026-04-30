# llama.cpp Helper Scripts

针对 [llama.cpp](https://github.com/ggml-org/llama.cpp) 的自动化构建与管理工具集，专为 **双路 RTX 2080 Ti (NVLink)** 工作站优化。

## 硬件环境

| 组件 | 规格 |
|------|------|
| CPU | Intel Xeon E5-2667 v4 (32核) |
| RAM | 251GB |
| GPU | 2× RTX 2080 Ti 22GB (NVLink 2链路) |
| CUDA | sm_75 |

## 软件依赖

当前环境已安装：

- CMake ≥ 3.20
- Ninja ≥ 1.10
- GCC/G++ ≥ 12.0
- CUDA Toolkit 13.0 (Anaconda)
- OpenBLAS ≥ 0.3.25
- Python 3
- Git
- **Bash >= 4.2** (required for associative arrays and `[[ -v ]]` variable tests)

> **磁盘空间要求**：构建需要至少 10GB 可用空间（脚本会自动检查）。

## 脚本说明

### 配置文件

#### `config.sh`
集中定义共享路径和常量，build.sh 和 update.sh 会 source 此文件。

```bash
# 默认路径（可通过环境变量覆盖）
LLAMA_CPP_SRC="/mnt/hdd/projects/llama.cpp"

# 覆盖示例
export LLAMA_CPP_SRC="/your/path/to/llama.cpp"
bash build.sh
```

#### 可配置构建选项

以下变量可在运行 `build.sh` 前通过环境变量覆盖：

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `CMAKE_BUILD_TYPE` | `Release` | 构建类型 |
| `CMAKE_CUDA_ARCHITECTURES` | `75` | CUDA 目标架构 (sm_75) |
| `GGML_CUDA_PEER_MAX_BATCH_SIZE` | `512` | NVLink P2P 批量大小 |
| `GGML_CUDA_FA_ALL_QUANTS` | `ON` | 全量化 FlashAttention |
| `GGML_NATIVE` | `ON` | 本机 CPU 优化 |
| `GGML_BLAS` | `ON` | 启用 BLAS |
| `GGML_BLAS_VENDOR` | `OpenBLAS` | BLAS 库供应商 |

```bash
# 为不同 GPU 架构构建
CMAKE_CUDA_ARCHITECTURES="86" bash build.sh

# 禁用 OpenBLAS（仅 CUDA）
GGML_BLAS="OFF" bash build.sh
```

### 核心脚本

#### `build.sh` - 构建 llama.cpp

使用 CMake + Ninja 构建 llama.cpp，启用 OpenBLAS + CUDA 双后端。

支持 `--version` 查看版本。
```bash
# 完整重新构建（清理 + 配置 + 编译）
bash build.sh

# 增量构建（保留 build 目录，仅重新编译变更）
bash build.sh -i

# 显示帮助
bash build.sh --help
```

**安全特性：**
- 文件锁防止并发构建冲突
- 磁盘空间预检查（需 ≥10GB）
- SIGINT/SIGTERM 信号处理（自动清理未完成构建）
- 跨平台 `stat` 支持（Linux/BSD/macOS）

**构建选项：**
- OpenBLAS (CPU 加速)
- CUDA (GPU 加速，sm_75)
- 编译时 `GGML_CUDA_PEER_MAX_BATCH_SIZE=512` (NVLink P2P 传输优化)
- `GGML_CUDA_FA_ALL_QUANTS=ON` (全量化类型 FlashAttention)

**验证步骤：**
- 检查 `llama-cli` 和 `llama-server` 二进制文件
- 验证 CUDA/OpenBLAS 动态库链接
- 列出可用 GPU 设备

#### `update.sh` - 更新到最新版本

查询 GitHub 最新构建标签（build tag），自动拉取、切换、同步子模块并重新构建。

支持 `--version` 查看版本。
```bash
# 更新到最新构建标签
bash update.sh

# 更新到指定 commit
bash update.sh b3631

# 更新到指定标签
bash update.sh b8941

# 显示帮助
bash update.sh --help
```

**安全特性：**
- 文件锁防止并发更新冲突
- 检查未提交的更改（主仓库 + 子模块）
- 构建失败自动回滚到之前的版本
- 回滚失败时提供详细的恢复指导
- SIGINT/SIGTERM 信号处理（自动恢复到更新前状态）
- 自动清理旧版本遗留的子模块目录和 `.git/modules/` 条目

**特性：**
- 优先使用 `gh` CLI（已认证时无 API 限流），回退到 `curl`
- 构建失败自动回滚到之前的版本并重新构建
- 自动同步 Git 子模块

#### `run_env.sh` - 运行时环境变量

设置 llama.cpp 运行时性能优化参数。

支持 `--version` 查看版本。
```bash
# 加载环境变量
source run_env.sh

# 查看当前环境状态（不修改）
source run_env.sh --status

# 显示帮助
source run_env.sh --help
```

> **注意：** 本脚本必须使用 `source` 执行。直接运行 `bash run_env.sh` 会提示警告并退出。

**设置的环境变量：**

| 变量 | 值 | 说明 |
|------|-----|------|
| `GGML_CUDA_P2P` | `1` | 启用 GPU 间 P2P 直传（NVLink 绕过系统内存） |
| `CUDA_SCALE_LAUNCH_QUEUES` | `4x` | 增大 CUDA 命令缓冲区（多 GPU pipeline 并行受益） |

**注意：** `GGML_CUDA_ENABLE_UNIFIED_MEMORY` **未被启用**，因为统一内存对离散 GPU（如 RTX 2080 Ti）性能有害。仅在集成 GPU 或 VRAM 不足导致 OOM 时手动启用。

### 共享库

#### `common.sh`
所有脚本共享的工具函数库，提供：
- 彩色日志输出 (`llama_info`, `llama_ok`, `llama_warn`, `llama_err`)
- 依赖检查 (`llama_check_commands`)
- 路径验证 (`llama_check_dir`, `llama_check_file`)
- CPU/GPU 检测 (`llama_get_cpu_count`, `llama_check_gpu`)
- 文件锁 (`llama_acquire_lock`, `llama_release_lock`)
- 磁盘空间检查 (`llama_check_disk_space`)
- 信号陷阱管理 (`llama_setup_trap`, `llama_cleanup_trap`)
- 网络错误上下文 (`llama_with_network_context`)
- 跨平台文件大小检测 (`llama_file_size`)

## 典型工作流

### 首次使用

```bash
# 1. 克隆 llama.cpp（如果尚未克隆）
git clone https://github.com/ggml-org/llama.cpp /mnt/hdd/projects/llama.cpp

# 2. 构建
cd /mnt/hdd/projects/llama.cpp_helper
bash build.sh

# 3. 加载运行环境
source run_env.sh

# 4. 运行模型
/mnt/hdd/projects/llama.cpp/build/bin/llama-cli \
    -m /path/to/model.gguf \
    -ngl 99 \
    -p "你好"
```

### 日常更新

```bash
cd /mnt/hdd/projects/llama.cpp_helper
bash update.sh
source run_env.sh
```

### 开发调试（增量构建）

```bash
cd /mnt/hdd/projects/llama.cpp_helper
bash build.sh -i
```

## 故障排除

### CMake 配置失败

**症状：** `CMake 配置失败`

**可能原因：**
- CUDA 工具链未正确安装
- OpenBLAS 开发包未安装：`sudo apt install libopenblas-dev`
- GCC 版本与 CUDA 不兼容（CUDA 13 需要 GCC ≤ 13）

### 编译失败

**症状：** `编译失败`

**排查步骤：**
1. 检查内存：`free -h`（32核并行编译需要大量内存）
2. 降低并行度：修改 `JOBS` 变量或临时用 `cmake --build build -j 8`
3. 检查磁盘空间：`df -h`

### GPU 未检测到

**症状：** `--list-devices` 无输出

**排查步骤：**
1. 检查 NVIDIA 驱动：`nvidia-smi`
2. 检查 CUDA 路径：`which nvcc`
3. 确认运行时环境已加载：`source run_env.sh`

### 更新后构建失败

**症状：** `update.sh` 执行后构建失败

**处理：** 脚本会自动回滚到之前的版本。如果回滚后构建也失败，脚本会输出详细的恢复步骤指导。

如需手动回滚：
```bash
cd /mnt/hdd/projects/llama.cpp
git log --oneline -5          # 查看历史
git checkout <之前的commit>  # 回滚
git submodule update --recursive
```

### 并发执行冲突

**症状：** `另一个进程正在运行，请等待其完成`

**原因：** build.sh 和 update.sh 使用文件锁防止并发执行冲突。

**处理：** 等待其他构建/更新进程完成后再重试。

## 可选环境变量

除 `run_env.sh` 设置的变量外，llama.cpp 还支持以下 CUDA 相关环境变量：

| 变量 | 说明 |
|------|------|
| `GGML_CUDA_GRAPH_OPT=1` | 启用 CUDA 图优化（单 GPU 场景受益） |
| `GGML_CUDA_NO_PINNED=1` | 禁用固定内存（低显存场景） |
| `GGML_CUDA_DISABLE_FUSION=1` | 禁用 kernel fusion（调试用途） |
| `GGML_CUDA_FORCE_CUBLAS_COMPUTE_32F=1` | 强制 FP32 计算（精度优先） |
| `GGML_CUDA_FORCE_CUBLAS_COMPUTE_16F=1` | 强制 FP16 计算（速度优先） |

## 文件结构

```
llama.cpp_helper/
├── common.sh       # 共享工具库
├── config.sh       # 配置（路径 + 构建常量）
├── build.sh        # 构建脚本
├── update.sh       # 更新脚本
├── run_env.sh      # 运行时环境
├── Makefile        # lint/test/check
├── .shellcheckrc   # ShellCheck 配置
├── tests/          # bats-core 测试套件
│   ├── test_helper.bash
│   ├── test_smoke.bats
│   ├── test_common.bats
│   ├── test_build.bats
│   ├── test_update.bats
│   └── test_run_env.bats
└── README.md

## 许可证

与 llama.cpp 相同（MIT）。

## 开发

```bash
# ShellCheck 静态分析
make lint

# bash -n 语法检查
make syntax

# 运行测试套件
make test

# 全部检查（lint + syntax + test）
make check
```

**测试依赖：** 需要安装 `bats-core` 和 `shellcheck`。

**Bash 版本要求：** 本项目使用 Bash >= 4.2 特性（关联数组 `declare -A`、`[[ -v ]]` 变量测试）。
