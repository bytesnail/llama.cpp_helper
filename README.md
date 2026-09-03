# llama.cpp Helper Scripts

针对 [llama.cpp](https://github.com/ggml-org/llama.cpp) 的自动化构建与管理工具集，面向双路 NVIDIA RTX 2080 Ti (NVLink) 工作站优化。

**版本：** 1.1.0

> 开发者内部参考（架构、命名约定、反模式、安全特性）：参见 [AGENTS.md](AGENTS.md)

---

## 目录

- [环境要求](#环境要求)
- [快速开始](#快速开始)
- [⚠️ 重要警告](#重要警告)
- [项目结构](#项目结构)
- [脚本说明](#脚本说明)
  - [build.sh — 构建](#buildsh--构建)
  - [update.sh — 更新](#updatesh--更新)
  - [run_env.sh — 运行时环境](#run_envsh--运行时环境)
- [配置](#配置)
  - [构建配置](#构建配置)
  - [conda 配置](#conda-配置)
  - [网络超时配置](#网络超时配置)
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
| GCC / G++ ≥ 12.0 | C/C++ 编译器（GCC 12.x 已验证兼容 CUDA 13.0） |
| CUDA Toolkit | 需 `nvcc` 可用。本机刻意钉住 **CUDA 13.0**（经 conda 环境 `llama.cpp` 提供；驱动 580.119.02 认证上限即 13.0，**升级 CUDA 前须先升驱动**） |
| OpenBLAS | `libopenblas-dev` 开发包 |
| Python 3 | JSON 解析（update.sh）及 OpenBLAS 运行时验证（build.sh） |
| `gh` | GitHub CLI（update.sh 优先使用，未安装时回退到 `curl`） |
| Git | 源码管理 |
| `curl` | HTTP 客户端（`gh` 未安装时 update.sh 使用） |
| `flock` | 文件锁（`util-linux` 包，通常预装） |

> 磁盘空间：构建需要至少 10GB 可用空间（脚本自动检查）。

> **目标硬件：** 本工具集针对以下工作站调优，默认参数（CUDA 架构 sm_75、P2P 直传、NVLink 优化）基于此配置。适用于任何 NVIDIA GPU，但可能需要调整 `CMAKE_CUDA_ARCHITECTURES`。

**目标机器硬件规格：**

| 类别 | 规格 |
|------|------|
| CPU | 2× Intel Xeon E5-2667 v4 @ 3.20GHz（16 物理核 / 32 线程） |
| CPU 指令集 | SSE4.2, AVX, AVX2, FMA, F16C, BMI2（无 AVX-512） |
| 内存 | 256 GB DDR4 |
| GPU | 2× NVIDIA RTX 2080 Ti（22 GiB，sm_75，Turing） |
| GPU 互联 | NVLink NV2（双链路，单链路 ~25.8 GB/s，聚合 ~51.6 GB/s） |

构建与运行时脚本会自动检测并打印上述硬件信息（`bash build.sh` 前置检查、`source run_env.sh --status`）。

---

## 快速开始

### 首次使用

```bash
# 0. 克隆本项目（请替换 YOUR_USERNAME）
git clone https://github.com/YOUR_USERNAME/llama.cpp_helper  # 请替换 YOUR_USERNAME
cd llama.cpp_helper

# 1. 一键更新——首次使用会自动克隆 llama.cpp 源码（默认到 /mnt/usr/tools/llama.cpp，
#    可经 LLAMA_CPP_SRC 覆盖）并构建最新 release
bash update.sh

# 2. 加载运行时环境
source run_env.sh

# 3. 运行模型推理
/mnt/usr/tools/llama.cpp/build/bin/llama-cli \
    -m /path/to/model.gguf \
    -ngl 99 \
    -p "你好"

# 4. 运行模型服务
/mnt/usr/tools/llama.cpp/build/bin/llama-server \
    -m /path/to/model.gguf \
    -ngl 99 \
    --port 8080
```

如需自定义源码位置，先手动克隆再经 `LLAMA_CPP_SRC` 指向它：

```bash
git clone https://github.com/ggml-org/llama.cpp /your/path/llama.cpp
LLAMA_CPP_SRC=/your/path/llama.cpp bash update.sh
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

## ⚠️ 重要警告

- **禁止直接执行 `run_env.sh`**：必须使用 `source run_env.sh` 加载环境变量。直接运行 `bash run_env.sh` 会报错退出，且不会在当前 shell 中产生任何效果。
- **禁止直接执行 `config.sh`**：`config.sh` 是 source-only 配置文件，由入口脚本自动加载。直接运行会提示错误。
- **`common.sh` 由入口脚本自动 source**：无需手动加载。

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
├── .editorconfig     # EditorConfig 统一编辑器配置
├── .gitignore          # Git 忽略规则
├── LICENSE             # MIT 许可证
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
build.sh    ──source──> common.sh
            ──source──> config.sh
update.sh   ──source──> common.sh
            ──source──> config.sh
run_env.sh  ──source──> common.sh（仅此一项：config.sh 的 readonly 变量
                              会灌入父 shell，版本号改经子 shell 提取）
```

> 模块分层详见 [AGENTS.md](AGENTS.md#模块分层)。

> `run_env.sh` 仅能通过 `source` 使用（详见 [⚠️ 重要警告](#重要警告)）。

---

## 脚本说明

所有入口脚本均支持 `--help` 和 `--version`。

### build.sh — 构建

使用 CMake + Ninja 构建 llama.cpp，启用 OpenBLAS + CUDA 双后端。构建完成后自动验证二进制文件存在性、动态库链接与可启动性。

```bash
bash build.sh       # 完整重新构建（清理 + 配置 + 编译 + 验证）
bash build.sh -i    # 增量构建（保留 build 目录，仅重新编译变更）
```

**安全特性：** 文件锁、磁盘空间预检查（≥10GB）、信号处理（中断时自动清理未完成构建）、构建标记（`.build-stamp` 记录源码 commit，供 `update.sh` 检测过期构建）。

**构建验证：**
- 检查 `llama-cli` 和 `llama-server` 二进制文件存在性及大小
- 验证 CUDA 动态库链接（`libcudart` / `libcublas`）
- 验证 OpenBLAS 动态库链接及运行时可加载性
- 验证 `llama-cli --version` 可正常启动
- 写入构建标记（`.build-stamp`），记录当前构建对应的源码 commit

### update.sh — 更新

查询 GitHub 最新构建标签，拉取、切换、同步子模块并重新构建。优先使用 `gh` CLI，回退到 `curl`。

```bash
bash update.sh         # 更新到最新正式 release
bash update.sh -p      # 更新到最新版本（含 pre-release，如上游高频 bXXXX 标签）
bash update.sh b8941   # 更新到指定标签（pre-release 标签同样支持）
bash update.sh 1a2b3c4 # 更新到指定 commit（7-40 位 SHA）
```

> 缺省目标为 GitHub "Latest" 语义下的最新**正式** release（自动排除 pre-release 与 draft）。上游 llama.cpp 以 `bXXXX` 形式高频发布 pre-release、低频发布 `v0.X.0` 正式版——需要跟进 pre-release 时加 `-p`（或 `--pre-release`）；查询在列表端点滤除 draft 后按发布时间取最新。

**安全特性：** 文件锁、未提交更改检查（含子模块脏状态检查）、远程 origin 验证、构建失败自动回滚（含详细恢复指导；仅源码已更新的场景——纯重建失败不回滚，源码本就未动）、中断信号处理（源码修改阶段 SIGINT/SIGTERM 时自动恢复原始版本；查询阶段中断即干净退出）、旧子模块残留自动清理。

**更新流程：**
1. 前置检查（工具、仓库、未提交更改）
2. 查询目标版本（GitHub API，优先 `gh`）
3. 版本对比（已是最新则检查构建完整性，无需操作则自动跳过）
4. 拉取 → checkout → 清理旧子模块残留 → 同步子模块
5. 调用 `build.sh` 构建（输出流式可见）
6. 构建失败 → 源码已更新时自动回滚 + 回滚后重新构建（退出码 2）；纯重建失败不回滚（源码未动，退出码 1）

### run_env.sh — 运行时环境

设置 llama.cpp 运行时性能优化变量。**必须通过 `source` 执行。**

```bash
source run_env.sh           # 加载环境变量
source run_env.sh -s         # 查看硬件信息 + 环境变量 + GPU 运行时（--status 短选项）
source run_env.sh --status  # 查看硬件信息 + 环境变量 + GPU 运行时（显存/利用率/温度/功耗）
```

> **⚠️ 必须使用 `source` 执行**，直接运行 `bash run_env.sh` 会报错退出。`source` 确保变量在当前 shell 中生效。

> **在脚本内 source 时注意**：`source run_env.sh`（不传参）会继承调用者的位置参数（bash source 语义）——父脚本以 `./deploy.sh --verbose` 运行时，`--verbose` 会被误认为本脚本的选项。请先 `set --` 清空位置参数，或显式传参（如 `source run_env.sh --status`）。

`run_env.sh` 设置的变量详见 [运行时环境变量](#运行时环境变量)。

---

## 配置

### 构建配置

以下变量可在运行 `build.sh` 前通过环境变量覆盖。未设置时使用默认值。

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `LLAMA_CPP_SRC` | `/mnt/usr/tools/llama.cpp` | llama.cpp 源码路径（本机事实标准目录；其他机器使用时经环境变量覆盖） |
| `CMAKE_BUILD_TYPE` | `Release` | 构建类型 |
| `CMAKE_CUDA_ARCHITECTURES` | `75` | CUDA 目标架构 (sm_75) |
| `CMAKE_CUDA_FLAGS` | `--threads=0` | CUDA 编译附加参数 |
| `GGML_CUDA_FA_ALL_QUANTS` | `ON` | 全量化 FlashAttention |
| `GGML_CUDA_GRAPHS` | `OFF` | CUDA graphs（固定 shape 推理受益，默认保持上游） |
| `GGML_NATIVE` | `ON` | 本机 CPU 优化 |
| `GGML_BLAS` | `ON` | 启用 BLAS |
| `GGML_BLAS_VENDOR` | `OpenBLAS` | BLAS 库供应商 |
| `GGML_CUDA` | `ON` | 启用 CUDA 支持 |
| `LLAMA_BUILD_TESTS` | `OFF` | 构建 llama.cpp 自身测试（默认 OFF 节省编译时间） |

**固定构建选项**（不可通过环境变量覆盖；`REQUIRED_BINARIES` 定义于 `config.sh`）：

| 选项 | 值 | 说明 |
|------|-----|------|
| `REQUIRED_BINARIES` | `llama-cli` `llama-server` | 必需验证的二进制文件列表 |

**内部常量**（定义于 `config.sh`，由脚本逻辑使用）：

| 变量 | 值 | 说明 |
|------|-----|------|
| `REPO` | `ggml-org/llama.cpp` | GitHub 仓库标识（update.sh 查询） |
| `REPO_URL` | `https://github.com/ggml-org/llama.cpp` | GitHub 仓库 URL（update.sh remote 验证） |
| `BUILD_DIR` / `BUILD_BIN_DIR` / `BUILD_STAMP` | `${LLAMA_CPP_SRC}/build` 及其子路径 | 构建产物布局（写方 build.sh 与读方 common.sh/update.sh 的共享协议） |
| `LLAMA_CMAKE_KNOBS` | 上表 10 个构建变量名 | 构建旋钮表：build.sh 按此表循环生成 cmake `-D` 透传参数 |
**使用示例：**

```bash
# 为不同 GPU 架构构建
CMAKE_CUDA_ARCHITECTURES="86" bash build.sh

# 禁用 OpenBLAS（仅 CUDA）
GGML_BLAS="OFF" bash build.sh

# 自定义源码路径
LLAMA_CPP_SRC="/your/path/to/llama.cpp" bash build.sh
```

### conda 配置

以下变量控制所有脚本的 conda 自动激活行为。可通过环境变量覆盖。

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `CONDA_AUTO_ACTIVATE` | `1` | 自动激活 conda 环境（0=跳过, 1=自动激活） |
| `CONDA_ENV_NAME` | `llama.cpp` | 激活的 conda 环境名称（默认为本机构建专用环境，CUDA 工具链所在；权威：当前激活其他环境时强制切换；环境不存在/激活失败时 build.sh/update.sh 报错中止） |

```bash
# 跳过 conda 自动激活
CONDA_AUTO_ACTIVATE=0 source run_env.sh

# 激活指定 conda 环境
CONDA_ENV_NAME=llama-cpp source run_env.sh
```

### 网络超时配置

以下变量控制 `update.sh` 访问 GitHub API 与 git 网络调用的超时行为。可通过环境变量覆盖。

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `CURL_CONNECT_TIMEOUT` | `10` | curl 连接超时（秒） |
| `CURL_MAX_TIME` | `30` | curl 请求最大用时（秒） |
| `GIT_HTTP_LOW_SPEED_LIMIT` | `1000` | git 低速保护阈值（字节/秒）：传输速率低于该值并持续 `GIT_HTTP_LOW_SPEED_TIME` 秒即中止（作用于 `update.sh` 的 clone/fetch/submodule） |
| `GIT_HTTP_LOW_SPEED_TIME` | `15` | git 低速保护持续时间（秒） |

```bash
# 在慢速网络上增加超时时间
CURL_CONNECT_TIMEOUT=30 CURL_MAX_TIME=60 bash update.sh
```

> 另有 host 工具链查找目录 `LLAMA_HOST_TOOLCHAIN_BIN`（默认 `/usr/bin`，见 `config.sh`）：conda 激活后其 env bin 中的交叉 binutils 裸名 `ld`/`as` 会劫持系统 gcc 的链接，`build.sh` 经 `COMPILER_PATH` 把 gcc 子程序查找钉到该目录。

### 运行时环境变量

#### run_env.sh 设置的变量

| 变量 | 值 | 说明 |
|------|-----|------|
| `GGML_CUDA_P2P` | `1` | 启用 GPU 间 P2P 直传（NVLink 绕过系统内存）。**存在性语义**：llama.cpp 仅检测变量是否存在——置 `0` 不关闭，关闭须 `unset GGML_CUDA_P2P` |

> 若变量已被用户预先设置（`export`），`run_env.sh` 会保留用户值而非覆盖。

#### 可选 CUDA 运行时变量

以下为应急/特殊场景开关，`run_env.sh` 不自动设置。完整列表请参考 [ggml CUDA 后端文档](https://github.com/ggml-org/llama.cpp/blob/master/docs/backend/CUDA.md)。

| 变量 | 说明 |
|------|------|
| `GGML_CUDA_ENABLE_UNIFIED_MEMORY` | 统一内存应急：模型+KV 超出双卡 44GB 显存 OOM 时临时开启。对离散 GPU 性能有害（x86 无缓存一致性，页迁移慢速），勿常态启用 |
| `GGML_CUDA_NO_PINNED=1` | 规避主机锁页内存受限 / `cudaMallocHost` 分配失败；代价是 CPU↔GPU 传输带宽下降 |
| `GGML_CUDA_GRAPH_OPT=1` | CUDA 图调度优化——**本机构建无效**：`GGML_CUDA_GRAPHS=OFF` 未编译 CUDA graphs，且该优化仅单卡生效 |

### 多 GPU 说明（2× RTX 2080 Ti NVLink）

| 项目 | 说明 |
|------|------|
| 默认模式 | `layer` 流水线并行（上游默认）：每卡持有一段连续层，跨卡通信最少，prefill 快、批量吞吐高 |
| `tensor` 模式（实验性） | `--split-mode tensor`：权重与 KV 均按卡切分、每层多次跨卡归约，token 生成延迟最低。约束：必须 `-fa`；KV cache 必须非量化（f32/f16/bf16）；MoE/混合与 Mamba 系架构不支持 |
| NCCL | 已启用（conda 包 `nccl` 2.30.7，经 RPATH 免激活解析）。仅 `tensor` 模式的跨卡归约使用；`layer` 流水线不经 NCCL |
| P2P 直传 | 运行前 `source run_env.sh` 设置 `GGML_CUDA_P2P=1`（存在性语义，关闭须 `unset`） |

### 运行无需激活 conda

构建产物经 RPATH 内嵌 conda 环境 CUDA 库的绝对路径（`libcudart`/`libcublas`/`libcublasLt`/`libnccl`），已在完全干净环境（`env -i`）下实证可正常运行与枚举 GPU。约束：conda 环境目录 `envs/llama.cpp/` **不可删除**，否则二进制失效（重装环境或重建可恢复）。`run_env.sh` 的核心目的是设置 `GGML_CUDA_P2P`，激活 conda 仅为顺带。

---

## 故障排除

### CMake 配置失败

**症状：** `CMake 配置失败 (退出码: N)`

**可能原因：**
- CUDA 工具链未正确安装或 `nvcc` 不在 `PATH` 中
- OpenBLAS 开发包缺失 → `sudo apt install libopenblas-dev`
- GCC 版本与 CUDA 版本不兼容（需 GCC ≥ 12.0）
- `cmake` 或 `ninja` 未安装

**排查：** 检查 `cmake --version`、`nvcc --version`、`ldconfig -p | grep openblas`。

### 编译失败

**症状：** `编译失败 (退出码: N)`

**排查：**
- `free -h` 检查内存——高并行度编译需要大量内存
- 降低并行度：手动编译指定并行度：`cmake --build "$LLAMA_CPP_SRC/build" -j 8`
- `df -h` 检查磁盘空间

### GPU 未检测到

**症状：** 运行 `llama-cli` 或 `llama-bench` 时无法识别 CUDA 设备

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
git submodule update --init --recursive
```

### 并发执行冲突

**症状：** `另一个进程正在运行 (PID: NNNN, 命令: build.sh)，请等待其完成`

`build.sh` 和 `update.sh` 使用 `flock` 文件锁防止并发执行。等待其他进程完成后再重试。

锁文件位置：`${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}/llama_cpp_helper-${UID}.lock`

**残留锁自动恢复：** 如果上一个进程异常终止，下次运行时脚本会自动检测并清理残留锁。

### CUDA 库路径检测失败

**症状：** 构建时提示 `无法自动检测 CUDA 库路径`，随后链接失败

**原因：** CUDA 安装在非标准路径（如 Anaconda 环境），`build.sh` 无法通过 `nvcc` 路径回溯找到 CUDA 库目录。

**解决：**

1. 确保 `nvcc` 在 PATH 中，或通过符号链接指向正确位置：
   `readlink -f $(which nvcc)`
2. 如果 CUDA 库在自定义路径，确保 `ldconfig` 能找到 `libcudart.so`：
   `sudo ldconfig` 或设置 `LD_LIBRARY_PATH`
3. `build.sh` 会自动从 `nvcc` 路径回溯查找 CUDA 库（见 `build.sh` 中的 `_detect_cuda_lib_dir()`）

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
make help       # 显示可用目标（等同于 make）
make lint       # ShellCheck 静态分析（6 个脚本）
make syntax     # bash -n 语法检查
make test       # bats-core 测试套件（数量随开发增长，`make help` 显示实时计数）
make check      # lint + syntax + test 全部
make all        # 等同于 check

# 运行单个测试文件
bats tests/test_common.bats
```

**测试依赖：** `bats-core` 和 `shellcheck`。

> 架构、编码规范、命名约定、日志规范、Git 工作流等详见 [AGENTS.md](AGENTS.md)。

---

## 许可证

[MIT](LICENSE)（Copyright (c) 2024-2026 llama.cpp_helper contributors）
