# llama.cpp_helper — AI 代理开发指南

本文档为本项目的 AI 编码代理（Claude Code、opencode 等）提供统一上下文，面向修改脚本的开发者。`CLAUDE.md` 是指向本文件的软链接，两套工具读取同一份内容。用户文档（快速开始、配置、故障排除）见 [README.md](README.md)。

> 本项目是针对 [llama.cpp](https://github.com/ggml-org/llama.cpp) 的自动化构建与管理 **Bash 脚本工具集**（5 个脚本，2000 LOC），面向双路 RTX 2080 Ti (NVLink) 工作站调优。**不含 C/C++ 代码**——通过调用 CMake/Ninja/git 等外部工具构建位于相邻目录 `../llama.cpp` 的上游源码。

## 语言策略

**核心原则：以中文为主要语言，仅在必要时使用英文。**

- **中文（默认）**：日志输出、错误消息、帮助文本、CLI 输出、代码注释、项目文档
- **英文（仅在必要时）**：代码引用（函数名/变量名）、文件引用（路径/文件名）、技术术语/专有名词、Git ref、URL

## 开发命令

```bash
make check          # lint + syntax + test 全部（质量门禁，提交前运行）
make lint           # ShellCheck 静态分析（6 个脚本：common/config/build/update/run_env + test_helper.bash）
make syntax         # bash -n 语法检查
make test           # bats-core 测试套件（156 项）

# 运行单个测试文件
bats tests/test_common.bats

# 按名称过滤运行单个用例（-f 对 @test 描述做正则匹配）
bats tests/test_common.bats -f "acquire_lock"
```

构建/更新/运行入口（用户侧）：

```bash
bash build.sh            # 完整重建（清理+配置+编译+验证）
bash build.sh -i         # 增量构建
bash update.sh           # 更新到上游最新构建标签
bash update.sh b3631     # 更新到指定 commit/tag
source run_env.sh        # 加载运行时环境变量（必须 source，直接执行会报错）
```

所有入口脚本均支持 `--help` 和 `--version`。**测试依赖** `shellcheck` 和 `bats-core`（`make` 各目标会自动检测缺失并提示安装）。

## Git 工作流

本项目采用 **feature 分支 + Pull Request** 工作流，**禁止直接向 `main` 提交**。

### 分支与提交约定

- 从最新 `main` 创建分支：`git checkout main && git pull --ff-only && git checkout -b <type>/<描述>`
- 分支名前缀 `<type>`：`feat`（新功能）、`fix`（修复）、`docs`（文档）、`refactor`（重构）、`test`（测试）、`chore`（构建/配置/工具）
- 提交信息遵循 [Conventional Commits](https://www.conventionalcommits.org/) 中文风格：`<type>: <描述>`（如 `docs: 完善 build.sh 注释`），并遵循 [语言策略](#语言策略)（中文描述 + 英文代码引用/路径）
- 每个提交聚焦单一变更

### PR 流程

1. 本地开发完成后，先运行 `make check`（lint + syntax + test 全部通过）再推送
2. 推送分支：`git push -u origin <type>/<描述>` —— feature 分支推送由 `.claude/settings.json` 的 `Bash(git push:*)` 规则自动放行
3. 创建 PR：`gh pr create`（标题与首条提交一致，正文说明变更与动机）
4. 在 GitHub 上 review + merge（单人项目可自合；建议 **squash merge** 保持线性历史）
5. 合并后清理：`git checkout main && git pull --ff-only && git branch -d <branch>`

> **为何禁止直推 main：** harness 的权限分类器对默认分支推送设有独立安全闸（绕过 PR review），即便配置了 `git push` 权限规则，每次推送 `main` 仍需单独显式授权；feature 分支推送则可自动放行。PR 工作流既契合此约束，又保留 review 与回溯点。

## 架构

理解四层 source 链是高效修改的前提：

```
config.sh   (配置层，纯数据)   ─┐
common.sh   (工具层，共享函数) ─┤  被下面三个入口脚本 source
                               │
build.sh ──┐                   │
update.sh ─┼── source ─────────┤
run_env.sh ┘                   │
```

每个入口脚本的统一骨架：

```bash
main "$@"                          # 入口函数：参数解析 + 全部业务逻辑
_main_rc=$?
llama_return_or_exit "$_main_rc"   # source 上下文用 return，脚本上下文用 exit
```

入口脚本通过 `_LLAMA_SOURCE_ONLY=1` 支持**测试提取模式**：测试 source 入口脚本时跳过锁获取、trap 注册、`set -euo pipefail` 等副作用，仅加载函数定义供测试调用（`build.sh` 和 `update.sh` 使用）。

## 模块分层

| 层 | 文件 | LOC | 职责 |
|----|------|-----|------|
| 配置层 | `config.sh` | 61 | 纯数据：路径、构建常量、版本号。用 `${VAR:-default}` 允许环境覆盖 |
| 工具层 | `common.sh` | 798 | 所有共享函数：日志、锁、信号、磁盘、GPU 检测、**硬件信息采集**（CPU 拓扑/指令集/内存/GPU/NVLink）、conda 激活、网络、Git 辅助、构建健康检查、文件大小、颜色管理、退出辅助 |
| 入口层 | `build.sh`, `update.sh`, `run_env.sh` | 394/557/190 | 各自独立的业务逻辑，均以 `main "$@"` 开头，`llama_return_or_exit` 结尾 |
| 测试层 | `tests/` | 1647 | 每个源文件对应一个 `test_*.bats`，另有 `test_smoke.bats` 覆盖基础设施检查 |

## 何处查找

| 需求 | 位置 | 备注 |
|------|------|------|
| 修改构建逻辑 | `build.sh` → `main()` | main() 包含参数解析和全部构建逻辑 |
| 修改更新逻辑 | `update.sh` → `_update_source()` / `_build_with_rollback()` | 查询 → 切换 → 构建 → 回滚链路 |
| 添加新工具函数 | `common.sh` | 遵循 `llama_` 公开 / `_` 私有两级命名 |
| 修改配置默认值 | `config.sh` | 所有变量用 `${VAR:-default}` 模式 |
| 修改测试 | `tests/test_<name>.bats` | 每脚本对应一个文件 |
| 测试辅助函数 | `tests/test_helper.bash` | setup/teardown + 共享 fixture |
| ShellCheck 规则调整 | `.shellcheckrc` | 每条 disable 有注释说明原因 |

> **ShellCheck 禁用说明：** `.shellcheckrc` 禁用规则 (SC2034/SC2119/SC2312/SC2317)，其中仅 SC2034 在 0.10.0 触发（已知误报），其余三条保留以供旧版本兼容。

## 命名约定

| 类型 | 模式 | 示例 |
|------|------|------|
| 公开函数 | `llama_<verb>` / `llama_<noun>_<verb>` | `llama_info`, `llama_acquire_lock` |
| 私有函数 | `_<lowercase_snake>` | `_show_help`, `_verify_binary_exists`, `_recover_stale_lock` |
| 全局常量 | `UPPER_SNAKE_CASE` | `REPO`, `MIN_FREE_DISK_GB` |
| 可覆盖变量 | `UPPER_SNAKE_CASE` + `${VAR:-default}` | `LLAMA_CPP_SRC`, `CMAKE_BUILD_TYPE`, `CMAKE_CUDA_ARCHITECTURES` |
| 局部变量 | `lowercase_snake_case` | `local exit_code=$?` |
| Source 守卫 | `_LLAMA_<NAME>_SOURCED` | `_LLAMA_COMMON_SOURCED` |
| 脚本文件 | `lowercase.sh` | `build.sh`, `common.sh` |

`LOCK_FD` 是主要的跨模块可变状态例外：由 `common.sh` 函数设置和读取，多处访问（含各脚本和测试 teardown），保留 `UPPER_SNAKE_CASE` 以突出其跨模块可见性。

其他跨模块变量例外：
- `orig_dir`：由 `update.sh` 设置，`llama_cd_back()` 读取。
- `incremental` 和 `_CLEANUP_DONE`：`build.sh` 中的 script-level 可变状态，供 trap handler 访问。
- `_LLAMA_SOURCE_ONLY`：由测试设置，供 `build.sh` 和 `update.sh` 读取以跳过副作用。

## 日志规范

6 级彩色日志（定义于 `common.sh`），仅在终端时着色（`[[ -t 1 ]]` 检测）：

| 函数 | 标签 | 颜色 | 输出 |
|------|------|------|------|
| `llama_info` | `[INFO]` | 青色 | stdout |
| `llama_ok` | `[OK]` | 绿色 | stdout |
| `llama_warn` | `[WARN]` | 黄色 | stdout |
| `llama_err` | `[ERROR]` | 红色 | **stderr** |
| `llama_step` | `=== text ===` | 粗体 | stdout |
| `llama_detail` | `  →` | 蓝色 | stdout |

## 错误处理模式

- **严格模式**：直接执行脚本（`build.sh`, `update.sh`）必须 `set -euo pipefail`
- **source 脚本**：`common.sh` 条件启用严格模式；`run_env.sh` 不启用（防止杀死父 shell）
- **防重复 source**：`_LLAMA_*_SOURCED` 守卫，二次 source 时 `return 0`
- **防直接执行**：`run_env.sh`、`config.sh` 检测 `BASH_SOURCE[0] == $0` 并报错
- **退出路径**：`llama_return_or_exit` — source 上下文用 `return`，脚本上下文用 `exit`
- **信号处理**：`llama_setup_trap <cmd>` 注册 SIGINT/SIGTERM；`llama_cleanup_trap` 重置
- **命令包装**：`llama_run_silent` 临时禁用 `set -e` 捕获退出码，失败时输出捕获的错误信息
- **测试提取模式**：`_LLAMA_SOURCE_ONLY=1` 允许测试 source 入口脚本时跳过锁获取和 trap 注册等副作用

## 反模式（本项目禁止）

1. **绝不直接执行** `config.sh` 或 `run_env.sh` — 它们有 source-only 守卫。`run_env.sh` 只能用 `source run_env.sh`
2. **绝不在 source 脚本中无条件启用** `set -euo pipefail` — 会导致父 shell 退出
3. **绝不删除锁文件** — `flock` 基于 inode，删除会导致等待进程锁住已删除 inode。`llama_release_lock` 只关 FD
4. **绝不在 Python 中嵌入字段名** — 使用 `sys.argv[1]` 传递字段名避免 Python 注入（参考 `_json_field`）
5. **source 脚本绝不污染父 shell 颜色变量** — 颜色变量名清单（`_LLAMA_COLOR_VARS`）在 `common.sh` 单一定义，`run_env.sh` source 后由 `llama_restore_colors` 在退出时 unset 清理
6. **绝不启用** `GGML_CUDA_ENABLE_UNIFIED_MEMORY` — 离散 GPU（RTX 2080 Ti）有害。仅集成 GPU 或 OOM 时手动启用
7. **绝不在测试中修改生产环境的 llama.cpp 仓库** — 所有测试操作必须在 `tests/test_helper.bash` 创建的临时目录中进行。`_setup_tmpdir()` 自动创建 `${TEST_TMPDIR}/llama.cpp` 最小 git 仓库并 export `LLAMA_CPP_SRC` 指向它，`teardown` 时自动清理。测试需不同仓库时显式覆盖 `LLAMA_CPP_SRC`，但不得指向 `_LLAMA_PROJECT_ROOT/../llama.cpp`（生产路径）

## 安全特性

- **文件锁**：`flock` + 动态 FD（`exec {fd}>>`），`build.sh` 和 `update.sh` 互斥；`update.sh` 在调用 `build.sh` 前释放锁以避免死锁
- **构建失败清理**：`build.sh` 通过双重 trap（SIGINT/SIGTERM + EXIT）删除未完成构建目录
- **更新失败回滚**：`update.sh` 自动回滚到更新前 commit + 重新构建；回滚失败时输出详细恢复步骤
- **磁盘空间检查**：构建前验证 ≥10GB 可用（`llama_check_disk_space`）
- **子模块清理**：`update.sh` 自动清理旧版本遗留的子模块目录和 `.git/modules/` 条目

## 注意事项

- **Bash ≥ 4.2 是硬性要求**：`declare -A` 关联数组（`run_env.sh` 的 `declare -A`、`update.sh` 的 `local -A`）和 `[[ -v ]]` 变量测试（`common.sh`、`update.sh`）
- **测试范围**：仅覆盖 CLI 接口（`--help`/`--version`/参数解析），实际构建/更新行为不在测试范围（依赖真实 CUDA 工具链和 llama.cpp 源码）
- **无 CI/CD**：所有质量检查（lint/syntax/test）仅支持本地手动运行
- **临时补丁**：`build.sh` 的 CUDA RPATH 检测（`_detect_cuda_lib_dir` 周围，注释标记 `TODO(upstream)`）是 llama.cpp b8940+ 的临时补丁（CUDA 私有依赖 RPATH 问题），上游修复后应移除
- **`llama_check_disk_space` 不阻塞**：路径不存在时仅警告，不阻止继续
- **测试隔离机制**：`tests/test_helper.bash` 的 `_setup_tmpdir()` 为每个测试创建独立的临时 git 仓库并 export `LLAMA_CPP_SRC` 指向它（覆盖 `config.sh` 的默认生产路径），确保测试绝不触碰生产 `../llama.cpp`。`_teardown_tmpdir` 在 `teardown` 时自动清理。新增测试应使用已导出的 `LLAMA_CPP_SRC` 或在 `TEST_TMPDIR` 下自建 fake repo
- **Bash 源文件扩展名**：测试辅助使用 `.bash`（`test_helper.bash`），不是 `.bats`——它是被 load 的库文件，不是测试文件
- **脚本注释布局**：文件头 `# ===...===` 块；节分隔 `# --- 节名 ---`；函数注释 `# Usage: <name> <args>`
