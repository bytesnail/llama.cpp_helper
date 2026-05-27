# 项目知识库

**生成时间：** 2026-05-26
**提交：** ad129b5
**分支：** main

## 概述

llama.cpp 自动构建与管理的 shell 脚本工具集。5 个 Bash 脚本（1813 LOC），面向双路 RTX 2080 Ti (NVLink) 工作站优化。质量保障：ShellCheck 静态分析 + bats-core 132 项测试。

用户文档（快速开始、配置、故障排除）见 [README.md](README.md)。本文档面向 AI 代理和开发者。


## 语言策略

**核心原则：以中文为主要语言，仅在必要时使用英文。**

- **中文（默认）**：日志输出、错误消息、帮助文本、CLI 输出、代码注释、项目文档
- **英文（仅在必要时）**：代码引用（函数名/变量名）、文件引用（路径/文件名）、技术术语/专有名词、Git ref、URL

## 结构

项目结构和依赖图见 [README.md](README.md#项目结构)。

## 模块分层

| 层 | 文件 | LOC | 职责 |
|----|------|-----|------|
| 配置层 | `config.sh` | 59 | 纯数据：路径、构建常量、版本号。用 `${VAR:-default}` 允许环境覆盖 |
| 工具层 | `common.sh` | 615 | 所有共享函数：日志、锁、信号、磁盘、GPU 检测、conda 激活、网络、Git 辅助、构建健康检查、文件大小、颜色管理、退出辅助 |
| 入口层 | `build.sh`, `update.sh`, `run_env.sh` | 388/548/203 | 各自独立的业务逻辑，均以 `main "$@"` 开头，`llama_return_or_exit` 结尾 |
| 测试层 | `tests/` | 1283 | 每个源文件对应一个 `test_*.bats`，另有 `test_smoke.bats` 覆盖基础设施检查 |

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

> **ShellCheck 禁用说明：** `.shellcheckrc` 禁用规则 (SC2034/SC2119/SC2312/SC2317) 除 SC2312 外均在 0.10.0 触发，均为已知误报，保留以供旧版本兼容。

## 命名约定

| 类型 | 模式 | 示例 |
|------|------|------|
| 公开函数 | `llama_<verb>` / `llama_<noun>_<verb>` | `llama_info`, `llama_acquire_lock` |
| 私有函数 | `_<lowercase_snake>` | `_show_help`, `_verify_binary_exists`, `_recover_stale_lock` |
| 全局常量 | `UPPER_SNAKE_CASE` | `REPO`, `MIN_FREE_DISK_GB` |
| 可覆盖变量 | `UPPER_SNAKE_CASE` + `${VAR:-default}` | `LLAMA_CPP_SRC`, `CMAKE_BUILD_TYPE`, `CMAKE_CUDA_ARCHITECTURES` |
| 局部变量 | `lowercase_snake` | `local exit_code=$?` |
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

- **测试提取模式**：`_LLAMA_SOURCE_ONLY=1` 允许测试 source 入口脚本时跳过锁获取和 trap 注册等副作用（`build.sh` 和 `update.sh` 使用）
## 反模式（本项目禁止）

1. **绝不直接执行** `config.sh` 或 `run_env.sh` — 它们有 source-only 守卫。`run_env.sh` 只能用 `source run_env.sh`
2. **绝不在 source 脚本中无条件启用** `set -euo pipefail` — 会导致父 shell 退出
3. **绝不删除锁文件** — `flock` 基于 inode，删除会导致等待进程锁住已删除 inode。`llama_release_lock` 只关 FD
4. **绝不在 Python 中嵌入字段名** — 使用 `sys.argv[1]` 传递字段名避免 Python 注入（参考 `_json_field` / `_verify_openblas_runtime`）
5. **source 脚本绝不污染父 shell 颜色变量** — `run_env.sh` 使用内联代码保存颜色（等价于 llama_save_colors），然后调用 llama_restore_colors 恢复
6. **绝不启用** `GGML_CUDA_ENABLE_UNIFIED_MEMORY` — 离散 GPU（RTX 2080 Ti）有害。仅集成 GPU 或 OOM 时手动启用

## 安全特性

- **文件锁**：`flock` + 动态 FD（`exec {fd}>>`），`build.sh` 和 `update.sh` 互斥；`update.sh` 在调用 `build.sh` 前释放锁以避免死锁
- **构建失败清理**：`build.sh` 通过双重 trap（SIGINT/SIGTERM + EXIT）删除未完成构建目录
- **更新失败回滚**：`update.sh` 自动回滚到更新前 commit + 重新构建；回滚失败时输出详细恢复步骤
- **磁盘空间检查**：构建前验证 ≥10GB 可用（`llama_check_disk_space`）
- **子模块清理**：`update.sh` 自动清理旧版本遗留的子模块目录和 `.git/modules/` 条目

## 命令

开发命令（make lint/test/check 等）见 [README.md](README.md#开发)。

## 依赖

依赖列表见 [README.md](README.md#环境要求)。

## 注意事项

- **临时方案**：`build.sh` L294-308 的 CUDA RPATH 检测是 llama.cpp b8940+ 的临时补丁（CUDA 私有依赖 RPATH 问题）。上游修复后应移除
- **`llama_check_disk_space` 不阻塞**：路径不存在时仅警告，不阻止继续
- **测试未覆盖端到端构建**：`build.sh` 和 `update.sh` 的测试只覆盖 CLI 接口（`--help`, `--version`, 参数解析），实际构建/更新行为不在此项目的测试范围
- **无 CI/CD**：所有质量检查（lint/syntax/test）仅支持本地手动运行
- **Bash 源文件扩展名**：测试辅助使用 `.bash`（`test_helper.bash`），不是 `.bats`——它是被 load 的库文件，不是测试文件
- **脚本注释布局**：文件头 `# ===...===` 块；节分隔 `# --- 节名 ---`；函数注释 `# Usage: <name> <args>`
