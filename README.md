# llama.cpp Helper Scripts

针对 [llama.cpp](https://github.com/ggml-org/llama.cpp) 的自动化构建与管理工具集，针对多路 NVIDIA GPU (NVLink) 工作站优化。

## 环境要求

- CMake ≥ 3.20
- Ninja ≥ 1.10
- GCC/G++ ≥ 12.0
- CUDA Toolkit 13.0
- OpenBLAS ≥ 0.3.25
- Python 3
- Git
- Bash ≥ 4.2（需要关联数组 `declare -A` 和 `[[ -v ]]` 变量测试功能）

> 磁盘空间：构建需要至少 10GB 可用空间（脚本自动检查）。

## 快速开始

### 首次使用

```bash
# 1. 克隆 llama.cpp（如果尚未克隆）
git clone https://github.com/ggml-org/llama.cpp /mnt/hdd/projects/llama.cpp

# 2. 构建
cd /mnt/hdd/projects/llama.cpp_helper
bash build.sh

# 3. 加载运行时环境
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

### 增量构建（开发调试）

```bash
cd /mnt/hdd/projects/llama.cpp_helper
bash build.sh -i
```

## 脚本

所有脚本均支持 `--help` 和 `--version`。

### build.sh — 构建 llama.cpp

使用 CMake + Ninja 构建，启用 OpenBLAS + CUDA 双后端。

```bash
bash build.sh       # 完整重新构建（清理 + 配置 + 编译）
bash build.sh -i    # 增量构建（保留 build 目录，仅重新编译变更）
```

安全特性：文件锁、磁盘空间预检查（≥10GB）、信号处理（自动清理未完成构建）。

构建后自动验证 `llama-cli` 和 `llama-server` 二进制文件、CUDA/OpenBLAS 动态库链接、GPU 设备列表。

### update.sh — 更新到最新版本

查询 GitHub 最新构建标签，自动拉取、切换、同步子模块并重新构建。优先使用 `gh` CLI，回退到 `curl`。

```bash
bash update.sh         # 更新到最新构建标签
bash update.sh b3631   # 更新到指定 commit
bash update.sh b8941   # 更新到指定标签
```

安全特性：文件锁、未提交更改检查、构建失败自动回滚（含详细恢复指导）、信号处理。

### run_env.sh — 运行时环境变量

设置 llama.cpp 运行时性能优化参数。

```bash
source run_env.sh           # 加载环境变量
source run_env.sh --status  # 查看当前环境状态（不修改）
```

> **⚠️ 必须使用 `source` 执行**，直接运行 `bash run_env.sh` 会报错退出。

| 变量 | 值 | 说明 |
|------|-----|------|
| `GGML_CUDA_P2P` | `1` | 启用 GPU 间 P2P 直传（NVLink 绕过系统内存） |
| `CUDA_SCALE_LAUNCH_QUEUES` | `4x` | 增大 CUDA 命令缓冲区（多 GPU 受益） |

> `GGML_CUDA_ENABLE_UNIFIED_MEMORY` 未被启用——统一内存对离散 GPU 性能有害。仅在集成 GPU 或 VRAM 不足时手动启用。

## 配置

### 构建选项

以下变量可在运行 `build.sh` 前通过环境变量覆盖：

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `LLAMA_CPP_SRC` | `/mnt/hdd/projects/llama.cpp` | llama.cpp 源码路径 |
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

# 自定义源码路径
LLAMA_CPP_SRC="/your/path/to/llama.cpp" bash build.sh
```

### 可选 CUDA 环境变量

除 `run_env.sh` 设置的变量外，还支持以下 CUDA 相关运行时变量：

| 变量 | 说明 |
|------|------|
| `GGML_CUDA_GRAPH_OPT=1` | 启用 CUDA 图优化（单 GPU 场景受益） |
| `GGML_CUDA_NO_PINNED=1` | 禁用固定内存（低显存场景） |
| `GGML_CUDA_DISABLE_FUSION=1` | 禁用 kernel fusion（调试用途） |
| `GGML_CUDA_FORCE_CUBLAS_COMPUTE_32F=1` | 强制 FP32 计算（精度优先） |
| `GGML_CUDA_FORCE_CUBLAS_COMPUTE_16F=1` | 强制 FP16 计算（速度优先） |

## 故障排除

### CMake 配置失败

**症状：** `CMake 配置失败`

可能原因：CUDA 工具链未正确安装、OpenBLAS 开发包缺失 (`sudo apt install libopenblas-dev`)、GCC 版本不兼容（CUDA 13 需要 GCC ≤ 13）。

### 编译失败

**症状：** `编译失败`

排查：`free -h` 检查内存（32 核并行编译需要大量内存）；降低并行度：修改 `JOBS` 变量或 `cmake --build build -j 8`；`df -h` 检查磁盘空间。

### GPU 未检测到

**症状：** `--list-devices` 无输出

排查：`nvidia-smi` 检查驱动；`which nvcc` 检查 CUDA 路径；确认已 `source run_env.sh`。

### 更新后构建失败

**症状：** `update.sh` 执行后构建失败

脚本会自动回滚到之前的版本。回滚失败时输出详细恢复步骤。如需手动回滚：

```bash
cd /mnt/hdd/projects/llama.cpp
git log --oneline -5          # 查看历史
git checkout <之前的commit>  # 回滚
git submodule update --recursive
```

### 并发执行冲突

**症状：** `另一个进程正在运行，请等待其完成`

`build.sh` 和 `update.sh` 使用文件锁防止并发执行。等待其他进程完成后再重试。

## 开发

```bash
make lint      # ShellCheck 静态分析
make syntax    # bash -n 语法检查
make test      # bats-core 测试套件（73 项）
make check     # lint + syntax + test 全部
```

测试依赖：`bats-core` 和 `shellcheck`。

> 详细架构、编码规范、模块分层等信息请参见 [AGENTS.md](AGENTS.md)。

## 许可证

与 llama.cpp 相同（MIT）。
