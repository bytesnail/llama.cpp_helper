# llama.cpp_helper — AI 代理开发指南

本文档为本项目的 AI 编码代理（Claude Code、opencode 等）提供统一上下文，面向修改脚本的开发者。`CLAUDE.md` 是指向本文件的软链接，两套工具读取同一份内容。用户文档（快速开始、配置、故障排除）见 [README.md](README.md)。

> 本项目是针对 [llama.cpp](https://github.com/ggml-org/llama.cpp) 的自动化构建与管理 **Bash 脚本工具集**，面向双路 RTX 2080 Ti (NVLink) 工作站调优。**不含 C/C++ 代码**——通过调用 CMake/Ninja/git 等外部工具构建位于相邻目录 `../llama.cpp` 的上游源码。

## 语言策略

**核心原则：以中文为主要语言，仅在必要时使用英文。**

- **中文（默认）**：日志输出、错误消息、帮助文本、CLI 输出、代码注释、项目文档
- **英文（仅在必要时）**：代码引用（函数名/变量名）、文件引用（路径/文件名）、技术术语/专有名词、Git ref、URL

## 开发命令

```bash
make check          # lint + syntax + test 全部（质量门禁，提交前运行）
make lint           # ShellCheck 静态分析（6 个脚本：common/config/build/update/run_env + test_helper.bash）
make syntax         # bash -n 语法检查
make test           # bats-core 测试套件（172 项）

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

**个人仓，简易流程：修改直接提交到 `main` 分支**（不使用 feature 分支 + PR）。

- **分支**：日常开发直接在 `main` 上提交，无需新建 feature 分支
- **提交前**：先运行 `make check`（lint + syntax + test 全部通过）再提交
- **提交信息**：遵循 [Conventional Commits](https://www.conventionalcommits.org/) 中文风格——`<type>: <描述>`，描述用中文，代码引用/路径用英文（遵循 [语言策略](#语言策略)）
- **类型前缀**：`feat`（新功能）、`fix`（修复）、`docs`（文档）、`refactor`（重构）、`test`（测试）、`chore`（构建/配置/工具）
- **每个提交聚焦单一变更**，保持历史清晰可追溯

> 示例：`fix: 修复 set -e 中止、构建产物误删与 Bash 4.2 兼容性问题`

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

| 层 | 文件 | 职责 |
|----|------|------|
| 配置层 | `config.sh` | 纯数据：路径、构建常量、构建旋钮表（`LLAMA_CMAKE_KNOBS`）、版本号。用 `${VAR:-default}` 允许环境覆盖 |
| 工具层 | `common.sh` | 所有共享函数：日志、锁、信号、磁盘、GPU 检测、**硬件信息采集**（CPU 拓扑/指令集/内存/GPU/NVLink）、conda 激活、网络、Git 辅助、构建健康检查、文件大小、颜色管理、退出辅助 |
| 入口层 | `build.sh`, `update.sh`, `run_env.sh` | 各自独立的业务逻辑，均以 `main "$@"` 开头，`llama_return_or_exit` 结尾 |
| 测试层 | `tests/` | 每个源文件对应一个 `test_*.bats`，另有 `test_smoke.bats` 覆盖基础设施检查 |

## 何处查找

| 需求 | 位置 | 备注 |
|------|------|------|
| 修改构建逻辑 | `build.sh` → `main()` | main() 包含参数解析和全部构建逻辑 |
| 修改更新逻辑 | `update.sh` → `_update_source()` / `_build_with_rollback()` | 查询 → 切换 → 构建 → 回滚链路 |
| 添加新工具函数 | `common.sh` | 遵循 `llama_` 公开 / `_` 私有两级命名 |
| 修改配置默认值 | `config.sh` | 所有变量用 `${VAR:-default}` 模式 |
| 添加/删除构建旋钮 | `config.sh` → `LLAMA_CMAKE_KNOBS` | 定义变量 + 登记旋钮表；`build.sh` 循环生成 `-D`，无需改动 |
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
- `incremental`、`_CLEANUP_DONE` 和 `_BUILD_TOUCHED`：`build.sh` 中的 script-level 可变状态，供 trap handler 访问。
- `_LLAMA_SOURCE_ONLY`：由测试设置，供 `build.sh` 和 `update.sh` 读取以跳过副作用。
- `update.sh` 的更新流程状态变量（`release_tag`、`release_commit`、`release_date`、`release_url`、`release_short`、`current_commit`、`current_short`、`current_tag`、`current_branch`、`target_version`、`need_source_update`、`skip_update`、`actual_commit`、`actual_tag`）：由 `_save_state`/`_parse_args`/`_resolve_target`/`_update_source` 设置，`_rollback`/`_build_with_rollback`/`main` 等跨函数读取，与上述性质相同，故同样使用 `lowercase_snake_case` 脚本级变量。

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
- **退出路径**：`llama_return_or_exit` — 用 `BASH_SOURCE[1] == $0` 判断上下文：脚本上下文 `exit`，source 上下文 `return`（函数体内 `return` 永远合法，不能靠 return 失败检测）
- **信号处理**：`llama_setup_trap <cmd>` 注册 SIGINT/SIGTERM；`llama_cleanup_trap` 重置。`build.sh` 的信号 trap 显式传入退出码（`trap '_cleanup_on_exit 130' SIGINT`）——信号在 builtin 间隙到达时 `$?` 可能为 0，会跳过清理并以 0 退出（下游误判构建成功）
- **命令包装**：`llama_run_silent <rc_var> <cmd...>` 临时禁用 `set -e` 运行命令并捕获输出——**恒返回 0**，退出码经 `printf -v` 写入 `<rc_var>`（必写，`set -u` 下读取安全）；调用点先 `local` 声明该变量（动态作用域下 `printf -v` 才会写入局部变量），再读取它决定失败响应（die/回滚）。误用（缺/非法变量名、保留前缀 `_lrs_`、缺命令）返回 2 大声失败——与被包装命令的失败是两类
- **保存/恢复 errexit 必须用 `$-`**：绝不能用 `prev_opts=$(set +o)` 保存 shell 选项——bash 默认在命令替换子 shell 中重置 errexit（`shopt inherit_errexit` 默认 off），捕获到的恒为 `set +o errexit`，`eval` 恢复后会把调用者的 `set -e` 永久静默关闭。正确写法：`if [[ $- == *e* ]]; then restore_e=1; fi`（`$-` 在当前 shell 读取，`||`/`if` 豁免上下文中仍正确）。参考 `llama_run_silent`、`llama_activate_conda`
- **管线赋值防护**：`var=$(cmd | cmd)` 在 `set -euo pipefail` 下，若管线可能返回非零（如 `grep` 无匹配、外部工具缺失），必须加 `|| true`——否则会中止脚本，使文档承诺的优雅降级路径（空串/0/回退）无法到达。参考 `common.sh` 中 `_llama_lscpu_field`、`llama_print_hardware_summary`、`llama_hw_cpu_*` 的实现
- **测试提取模式**：`_LLAMA_SOURCE_ONLY=1` 允许测试 source 入口脚本时跳过锁获取和 trap 注册等副作用

## 反模式（本项目禁止）

1. **绝不直接执行** `config.sh` 或 `run_env.sh` — 它们有 source-only 守卫。`run_env.sh` 只能用 `source run_env.sh`
2. **绝不在 source 脚本中无条件启用** `set -euo pipefail` — 会导致父 shell 退出
3. **绝不删除锁文件** — `flock` 基于 inode，删除会导致等待进程锁住已删除 inode。`llama_release_lock` 只关 FD
4. **绝不在 Python 中嵌入字段名** — 使用 `sys.argv[1]` 传递字段名避免 Python 注入（参考 `_json_field`）
5. **source 脚本绝不污染父 shell 颜色变量** — 颜色变量名清单（`_LLAMA_COLOR_VARS`）在 `common.sh` 单一定义；`common.sh` 被 source 时先自动 `llama_save_colors` 保存父 shell 原值，`run_env.sh` 退出时由 `llama_restore_colors` 恢复（unset 与空串不做区分，恢复为空串）
6. **绝不启用** `GGML_CUDA_ENABLE_UNIFIED_MEMORY` — 离散 GPU（RTX 2080 Ti）有害。仅集成 GPU 或 OOM 时手动启用
7. **绝不在测试中修改生产环境的 llama.cpp 仓库** — 所有测试操作必须在 `tests/test_helper.bash` 创建的临时目录中进行。`_setup_tmpdir()` 自动创建 `${TEST_TMPDIR}/llama.cpp` 最小 git 仓库并 export `LLAMA_CPP_SRC` 指向它，`teardown` 时自动清理。测试需不同仓库时显式覆盖 `LLAMA_CPP_SRC`，但不得指向 `_LLAMA_PROJECT_ROOT/../llama.cpp`（生产路径）
8. **绝不写无保护的 `var=$(pipeline)` 赋值**（当管线可能返回非零时）— 在 `set -euo pipefail` 下，`grep` 无匹配、外部工具缺失等场景会使管线返回非零，赋值语句中止脚本。若函数设计了优雅降级（输出空串/0/回退值），必须用 `var=$(... || true)` 保护。参考 `common.sh` 的 `_llama_lscpu_field`、`llama_get_gpu_count`、`llama_hw_mem_total_bytes`、`llama_print_hardware_summary` 和 `run_env.sh` 的 `gpu_count=$(llama_get_gpu_count || true)`
9. **绝不给无命令的 `exec {fd}>&-` 加输出重定向**（如 `2>/dev/null`）— 无命令 `exec` 的重定向会**永久改变当前 shell 的 FD**（实测吞掉后续全部 stderr 输出，含 `llama_safe_exit` 前的错误消息）。bash 关闭已关闭的 fd 静默返回 0，无需屏蔽。参考 `llama_release_lock`、`_lock_grab`、测试 teardown
10. **绝不用 `git checkout <tag名>` 切换版本** — 本地存在同名分支时 git 按歧义规则优先取分支，会静默构建错误 commit。必须先 `git rev-parse --verify --quiet "refs/tags/<tag>^{commit}"` 解析到 SHA 再 checkout SHA（参考 `update.sh` 的 `_update_source`）

## 安全特性

- **文件锁**：`flock` + 动态 FD（`exec {fd}>>`），`build.sh` 和 `update.sh` 互斥，均在参数解析**之后**获取（`--help`/`--version` 不受锁占用影响）；`update.sh` 在调用 `build.sh` 前释放锁以避免死锁，构建失败进入回滚前重新取锁（回滚修改源码树，防止与并发进程交错）
- **构建失败清理**：`build.sh` 通过双重 trap（SIGINT/SIGTERM 显式退出码 + EXIT）删除未完成构建目录
- **更新失败回滚**：`update.sh` 自动回滚到更新前 commit + 重新构建；回滚失败时不再继续重建（防止谎报"已回滚"），输出详细恢复步骤后中止；版本切换先解析 `refs/tags/<tag>` 到 SHA 再 checkout，避免分支/tag 同名歧义
- **磁盘空间检查**：构建前验证 ≥10GB 可用（`llama_check_disk_space`）
- **子模块清理**：`update.sh` 自动清理旧版本遗留的子模块目录和 `.git/modules/` 条目（`ls-files --stage` 按 TAB 解析，兼容含空格路径）

## 注意事项

- **Bash ≥ 4.2 是硬性要求**：`declare -A` 关联数组（`run_env.sh` 的 `declare -A`、`update.sh` 的 `local -A`）和 `[[ -v ]]` 变量测试（`common.sh`）。注：`update.sh` 的 `_cleanup_stale_submodules` 刻意用 `${arr[k]+x}` 而非 `[[ -v arr[k] ]]`，因为后者对关联数组元素需 Bash 4.3+
- **测试范围**：覆盖 CLI 接口（`--help`/`--version`/参数解析）及可离线测试的内部函数（如 `_resolve_target`、`_rollback`、`_json_field`、硬件信息采集、`set -e` 管线防护回归等）。实际构建/更新行为（依赖真实 CUDA 工具链和 llama.cpp 源码的端到端流程）不在测试范围
- **无 CI/CD**：所有质量检查（lint/syntax/test）仅支持本地手动运行
- **临时补丁**：`build.sh` 的 CUDA RPATH 检测（`_detect_cuda_lib_dir` 周围，注释标记 `TODO(upstream)`）是 llama.cpp b8940+ 的临时补丁（CUDA 私有依赖 RPATH 问题），上游修复后应移除
- **`llama_check_disk_space` 不阻塞**：路径不存在时仅警告，不阻止继续
- **测试隔离机制**：`tests/test_helper.bash` 的 `_setup_tmpdir()` 为每个测试创建独立的临时 git 仓库并 export `LLAMA_CPP_SRC` 指向它（覆盖 `config.sh` 的默认生产路径），确保测试绝不触碰生产 `../llama.cpp`。`_teardown_tmpdir` 在 `teardown` 时自动清理。新增测试应使用已导出的 `LLAMA_CPP_SRC` 或在 `TEST_TMPDIR` 下自建 fake repo
- **Bash 源文件扩展名**：测试辅助使用 `.bash`（`test_helper.bash`），不是 `.bats`——它是被 load 的库文件，不是测试文件
- **脚本注释布局**：文件头 `# ===...===` 块；节分隔 `# --- 节名 ---`；函数注释 `# Usage: <name> <args>`
