# llama.cpp Helper Scripts

针对 [llama.cpp](https://github.com/ggml-org/llama.cpp) 的自动化构建与管理工具集，面向多路 NVIDIA GPU (NVLink) 工作站优化。

**版本：** 1.0.0

---

## 目录

- [环境要求](#环境要求)
- [快速开始](#快速开始)
- [项目结构](#项目结构)
- [脚本说明](#脚本说明)
  - [build.sh — 构建](#buildsh--构建)
  - [update.sh — 更新](#updatesh--更新)
  - [run_env.sh — 运行时环境](#run_envsh--运行时环境)
- [配置](#配置)
  - [构建配置](#构建配置)
  - [运行时环境变量](#运行时环境变量)
- [故障排除](#故障排除)
- [开发](#开发)
- [许可证](#许可证)

---

## 环境要求

| 依赖 | 说明 |
|------|------|
| Bash ≥ 4.2 | 需要关联数组 `declare -A` 和 `[[ -v ]]` 变量测试 |
| CMake ≥ 3.20 | CMake 最低版本（llama.cpp 要求） |
| Ninja | 构建工具（或 `ninja-build`） |
| GCC / G++ | C/C++ 编译器 |
| CUDA Toolkit | 需 `nvcc` 可用（不强制特定版本） |
| OpenBLAS | `libopenblas-dev` 开发包 |
| Python 3 | JSON 解析（update.sh 使用） |
| Git | 源码管理 |
| `flock` | 文件锁（`util-linux` 包，通常预装） |

> 磁盘空间：构建需要至少 10GB 可用空间（脚本自动检查）。

---

## 快速开始

### 首次使用

```bash
# 0. 克隆本项目
git clone https://github.com/yourname/llama.cpp_helper
cd llama.cpp_helper

# 1. 克隆 llama.cpp 到相邻目录
git clone https://github.com/ggml-org/llama.cpp ../llama.cpp

# 2. 构建
bash build.sh

# 3. 加载运行时环境
source run_env.sh

# 4. 运行模型推理
../llama.cpp/build/bin/llama-cli \
    -m /path/to/model.gguf \
    -ngl 99 \
    -p "你好"

# 5. 运行模型服务
../llama.cpp/build/bin/llama-server \
    -m /path/to/model.gguf \
    -ngl 99 \
    --port 8080
```

### 日常更新

```bash
bash update.sh
source run_env.sh
```

### 增量构建（开发调试）

```bash
bash build.sh -i
```

---

## 项目结构

```
./
├── config.sh         # 配置层：路径、常量、构建参数（source-only）
├── common.sh         # 工具层：日志、锁、信号、磁盘、GPU 检测（source-only）
├── build.sh          # 构建入口（CMake + Ninja + OpenBLAS + CUDA）
├── update.sh         # 更新入口（GitHub 标签查询 → 拉取 → 构建 + 回滚）
├── run_env.sh        # 运行时环境（source-only，设置 CUDA P2P 等变量）
├── Makefile          # lint / syntax / test / check
├── .shellcheckrc     # ShellCheck 规则豁免
└── tests/            # bats-core 测试套件
    ├── test_helper.bash
    ├── test_common.bats
    ├── test_smoke.bats
    ├── test_build.bats
    ├── test_update.bats
    └── test_run_env.bats
```

**依赖图（source 链）：**

```
build.sh    ──source──> common.sh ──source──> config.sh
update.sh   ──source──> common.sh ──source──> config.sh
run_env.sh  ──source──> common.sh ──source──> config.sh
```

| 文件 | 类型 | 职责 |
|------|------|------|
| `config.sh` | source-only | 纯数据：路径、构建常量、版本号。通过 `${VAR:-default}` 允许环境覆盖 |
| `common.sh` | source-only | 共享函数库：日志、锁、信号、磁盘、GPU、退出辅助 |
| `build.sh` | 入口脚本 | CMake 配置 + Ninja 编译 + 构建验证 |
| `update.sh` | 入口脚本 | GitHub 查询 → 源码切换 → 构建 → 失败回滚 |
| `run_env.sh` | source-only | 设置运行时 CUDA 性能优化变量 |

> `config.sh` 和 `common.sh` 由入口脚本 source，不可直接执行。`run_env.sh` 仅能通过 `source` 使用。

---

## 脚本说明

所有脚本均支持 `--help` 和 `--version`。

### build.sh — 构建

使用 CMake + Ninja 构建 llama.cpp，启用 OpenBLAS + CUDA 双后端。构建完成后自动验证二进制文件、动态库链接和 GPU 设备。

```bash
bash build.sh       # 完整重新构建（清理 + 配置 + 编译）
bash build.sh -i    # 增量构建（保留 build 目录，仅重新编译变更）
```

**安全特性：** 文件锁、磁盘空间预检查（≥10GB）、信号处理（中断时自动清理未完成构建）。

**构建验证：**
- 检查 `llama-cli` 和 `llama-server` 二进制文件存在性及大小
- 验证 CUDA 动态库链接（`libcudart` / `libcublas`）
- 验证 OpenBLAS 动态库链接及运行时可加载性
- 通过 `llama-bench --help` 检测 CUDA 设备列表
- 验证 `llama-cli --version` 可正常启动

### update.sh — 更新

查询 GitHub 最新构建标签，拉取、切换、同步子模块并重新构建。优先使用 `gh` CLI，回退到 `curl`。

```bash
bash update.sh         # 更新到最新构建标签
bash update.sh b3631   # 更新到指定 commit
bash update.sh b8941   # 更新到指定标签
```

**安全特性：** 文件锁、未提交更改检查（含子模块脏状态检查）、远程 origin 验证、构建失败自动回滚（含详细恢复指导）、中断信号处理（SIGINT/SIGTERM 时自动恢复原始版本）、旧子模块残留自动清理。

**更新流程：**
1. 前置检查（工具、仓库、未提交更改）
2. 查询目标版本（GitHub API，优先 `gh`）
3. 版本对比（已是最新则检查构建完整性，跳过更新）
4. 拉取 → checkout → 同步子模块 → 清理旧子模块残留
5. 调用 `build.sh` 构建
6. 构建失败 → 自动回滚 + 回滚后重新构建

### run_env.sh — 运行时环境

设置 llama.cpp 运行时性能优化变量。**必须通过 `source` 执行。**

```bash
source run_env.sh           # 加载环境变量
source run_env.sh --status  # 查看当前环境状态（不修改）
```

> **⚠️ 必须使用 `source` 执行**，直接运行 `bash run_env.sh` 会报错退出。`source` 确保变量在当前 shell 中生效。

`run_env.sh` 设置的变量详见 [运行时环境变量](#运行时环境变量)。

---

## 配置

### 构建配置

以下变量可在运行 `build.sh` 前通过环境变量覆盖。未设置时使用默认值。

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `LLAMA_CPP_SRC` | `../llama.cpp`（相对于本项目） | llama.cpp 源码路径 |
| `CMAKE_BUILD_TYPE` | `Release` | 构建类型 |
| `CMAKE_CUDA_ARCHITECTURES` | `75` | CUDA 目标架构 (sm_75) |
| `CMAKE_CUDA_FLAGS` | `--threads=0` | CUDA 编译附加参数 |
| `GGML_CUDA_PEER_MAX_BATCH_SIZE` | `512` | NVLink P2P 批量大小 |
| `GGML_CUDA_FA_ALL_QUANTS` | `ON` | 全量化 FlashAttention |
| `GGML_NATIVE` | `ON` | 本机 CPU 优化 |
| `GGML_BLAS` | `ON` | 启用 BLAS |
| `GGML_BLAS_VENDOR` | `OpenBLAS` | BLAS 库供应商 |

**固定构建选项**（不可通过环境变量覆盖，在 `build.sh` 中硬编码）：

| 选项 | 值 | 说明 |
|------|-----|------|
| `LLAMA_BUILD_TESTS` | `OFF` | 禁用测试构建（节省编译时间） |
| `LLAMA_BUILD_EXAMPLES` | `OFF` | 禁用示例构建 |
| `GGML_CUDA` | `ON` | 始终启用 CUDA 支持 |

```bash
# 为不同 GPU 架构构建
CMAKE_CUDA_ARCHITECTURES="86" bash build.sh

# 禁用 OpenBLAS（仅 CUDA）
GGML_BLAS="OFF" bash build.sh

# 自定义源码路径
LLAMA_CPP_SRC="/your/path/to/llama.cpp" bash build.sh
```

### 运行时环境变量

#### run_env.sh 设置的变量

| 变量 | 值 | 说明 |
|------|-----|------|
| `GGML_CUDA_P2P` | `1` | 启用 GPU 间 P2P 直传（NVLink 绕过系统内存） |
| `CUDA_SCALE_LAUNCH_QUEUES` | `4x` | 增大 CUDA 命令缓冲区（多 GPU 并行受益） |

> 若变量已被用户预先设置（`export`），`run_env.sh` 会保留用户值而非覆盖。

> `GGML_CUDA_ENABLE_UNIFIED_MEMORY` 未被启用——统一内存对离散 GPU 性能有害。仅在集成 GPU 或 VRAM 不足时手动启用。

#### 可选 CUDA 运行时变量

除 `run_env.sh` 设置的变量外，可根据需要手动设置以下 CUDA 相关运行时变量：

| 变量 | 说明 |
|------|------|
| `GGML_CUDA_GRAPH_OPT=1` | 启用 CUDA 图优化（单 GPU 场景受益） |
| `GGML_CUDA_NO_PINNED=1` | 禁用固定内存（低显存场景） |
| `GGML_CUDA_DISABLE_FUSION=1` | 禁用 kernel fusion（调试用途） |
| `GGML_CUDA_FORCE_CUBLAS_COMPUTE_32F=1` | 强制 FP32 计算（精度优先） |
| `GGML_CUDA_FORCE_CUBLAS_COMPUTE_16F=1` | 强制 FP16 计算（速度优先） |

---

## 故障排除

### CMake 配置失败

**症状：** `CMake 配置失败 (退出码: N)`

**可能原因：**
- CUDA 工具链未正确安装或 `nvcc` 不在 `PATH` 中
- OpenBLAS 开发包缺失 → `sudo apt install libopenblas-dev`
- GCC 版本与 CUDA 版本不兼容
- `cmake` 或 `ninja` 未安装

**排查：** 检查 `cmake --version`、`nvcc --version`、`ldconfig -p | grep openblas`。

### 编译失败

**症状：** `编译失败 (退出码: N)`

**排查：**
- `free -h` 检查内存——高并行度编译需要大量内存
- 降低并行度：编辑 `build.sh` 中的 `JOBS` 值，或手动编译：`cmake --build build -j 8`
- `df -h` 检查磁盘空间

### GPU 未检测到

**症状：** `llama-bench --help` 无 CUDA 设备输出，或 `--list-devices` 无输出

**排查：**
- `nvidia-smi` 检查驱动是否正常
- `which nvcc` 检查 CUDA 路径
- 确认已执行 `source run_env.sh`
- 检查 NVIDIA 驱动版本是否与 CUDA Toolkit 版本兼容

### 更新后构建失败

**症状：** `update.sh` 执行后构建失败

脚本会自动回滚到之前的版本并尝试重新构建。回滚失败时输出详细的手动恢复步骤。如需手动回滚：

```bash
cd "$LLAMA_CPP_SRC"
git log --oneline -5
git checkout <之前的commit>
git submodule update --recursive
```

### 并发执行冲突

**症状：** `另一个进程正在运行 (PID: NNNN, 命令: build.sh)，请等待其完成`

`build.sh` 和 `update.sh` 使用 `flock` 文件锁防止并发执行。等待其他进程完成后再重试。

锁文件位置：`${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}/llama_cpp_helper-${UID}.lock`

**残留锁自动恢复：** 如果上一個进程异常终止，下次运行时脚本会自动检测并清理残留锁。

### CUDA 库路径检测失败

**症状：** 构建时提示 `无法自动检测 CUDA 库路径`，随后链接失败

**原因：** `build.sh` 无法通过 `nvcc` 路径回溯找到 CUDA 库目录。常见于 CUDA 安装在非标准路径（如 Anaconda 环境）。

**解决：**
```bash
# 手动指定 CUDA 库路径
export CUDA_LIB_DIR=/usr/local/cuda/lib64
# 或检查 nvcc 符号链接是否正确
readlink -f $(which nvcc)
```

### 子模块同步失败

**症状：** update.sh 在子模块同步阶段报错

**解决：**
```bash
cd "$LLAMA_CPP_SRC"
git submodule update --init --recursive
# 若仍失败，检查 .gitmodules 文件是否存在并正确
git submodule status
```

### 缺少 flock 命令

**症状：** `flock: command not found` 或类似错误

**解决：** 安装 `util-linux` 包：
```bash
sudo apt install util-linux  # Debian/Ubuntu
```

---

## 开发

```bash
make help       # 显示可用目标
make lint       # ShellCheck 静态分析（5 个脚本）
make syntax     # bash -n 语法检查
make test       # bats-core 测试套件
make check      # lint + syntax + test 全部
make all        # 等同于 check
```

**测试依赖：** `bats-core` 和 `shellcheck`。

> 详细架构、编码规范、模块分层、命名约定、日志规范等信息请参见 [AGENTS.md](AGENTS.md)。

---

## 许可证

与 llama.cpp 相同（MIT）。
