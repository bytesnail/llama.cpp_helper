# 本机 llama.cpp 源码路径覆盖 Implementation Plan

- 状态:已实施并验证(2026-09-02);本文件为执行计划历史归档,复选框未勾选系原貌

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 本机使用 llama.cpp_helper 时,llama.cpp 源码位于 `/mnt/usr/tools/llama.cpp`,经 `~/.bashrc` 导出 `LLAMA_CPP_SRC` 覆盖默认相邻目录。

**Architecture:** 纯机器配置操作,零代码改动——`~/.bashrc` 追加一个 export(llama.cpp_helper 的 `config.sh` 用 `${LLAMA_CPP_SRC:-默认}` 模式,环境变量天然优先),完整克隆上游仓库到 tools 目录,三步验证。

**Tech Stack:** Bash、git(https 克隆)。

**Spec:** `docs/superpowers/specs/2026-09-02-llama-cpp-src-local-path-design.md`

## Global Constraints

- `~/.bashrc` **只允许末尾追加已批准的两行**(1 行注释 + 1 行 export),不得触碰、重排或"顺手优化"任何现有内容(用户全局纪律:全局配置写入范围以明示批准为限)
- 克隆必须是**完整克隆**,禁止 `--depth`/`--single-branch`(update.sh 的版本切换与失败回滚需要 git 历史)
- **不执行** `build.sh`/任何构建;**不改动** llama.cpp_helper 仓库(/mnt/usr/project/system/llama.cpp_helper)的任何文件
- 所有路径一字不差:目标 `/mnt/usr/tools/llama.cpp`,仓库 URL `https://github.com/ggml-org/llama.cpp`

---

### Task 1: `~/.bashrc` 追加 LLAMA_CPP_SRC 导出

**Files:**
- Modify: `~/.bashrc`(仅末尾追加 2 行)

**Interfaces:**
- Consumes: 无
- Produces: 机器状态——交互 shell 中环境变量 `LLAMA_CPP_SRC=/mnt/usr/tools/llama.cpp`(Task 3 验证依赖)

- [ ] **Step 1: 幂等预检——确认尚无 LLAMA 定义**

Run: `grep -n "LLAMA" ~/.bashrc`
Expected: 无输出(退出码 1)。**若有输出:停止,不要追加**,向用户报告已有定义及出处再议

- [ ] **Step 2: 末尾追加两行**

```bash
printf '\n# llama.cpp_helper:本机 llama.cpp 源码路径(覆盖 config.sh 默认的相邻目录 ../llama.cpp)\nexport LLAMA_CPP_SRC=/mnt/usr/tools/llama.cpp\n' >> ~/.bashrc
```

(行首 `\n` 保证与现有末行间有空行分隔;现有文件以空行结尾时会出现两个空行,可接受,不为美化而改动其他内容)

- [ ] **Step 3: 复核追加结果**

Run: `tail -4 ~/.bashrc`
Expected: 末尾为刚追加的注释行 + `export LLAMA_CPP_SRC=/mnt/usr/tools/llama.cpp`;上方原有内容(此前末行是 `export CODEGRAPH_MCP_TOOLS=...`)原样存在

---

### Task 2: 完整克隆 llama.cpp 到 /mnt/usr/tools/llama.cpp

**Files:**
- Create: `/mnt/usr/tools/llama.cpp/`(git 仓库,约数百 MB 含历史)

**Interfaces:**
- Consumes: 无
- Produces: 机器状态——`/mnt/usr/tools/llama.cpp` 为 origin 指向上游 https 的完整 git 仓库(Task 3 验证依赖;后续 build.sh/update.sh 的消费对象)

- [ ] **Step 1: 预检——目标目录不存在、磁盘充足**

Run: `ls -d /mnt/usr/tools/llama.cpp 2>/dev/null && echo EXISTS || echo OK_ABSENT; df -h /mnt/usr/tools | tail -1`
Expected: `OK_ABSENT`;可用空间 ≥10GB(实测 11T)。**若 EXISTS:停止,向用户报告**(可能已有克隆,勿覆盖)

- [ ] **Step 2: 完整克隆**

Run: `git clone https://github.com/ggml-org/llama.cpp /mnt/usr/tools/llama.cpp`
Expected: 正常完成,无 `--depth` 参数。网络较慢时该步可能耗时数分钟——超时则重跑;**中断的半成品目录须先删除再重试**:`rm -rf /mnt/usr/tools/llama.cpp`(该目录由本任务创建,删除安全;删除前 `ls` 确认里面只有 .git 等克隆中间产物)

- [ ] **Step 3: 校验 origin 与完整性**

Run: `git -C /mnt/usr/tools/llama.cpp remote get-url origin && git -C /mnt/usr/tools/llama.cpp log --oneline -1 && git -C /mnt/usr/tools/llama.cpp tag | tail -3`
Expected: URL 为 `https://github.com/ggml-org/llama.cpp`(与 config.sh 的 `REPO_URL` 一致,满足 update.sh remote 校验);log 正常输出;tag 列表非空(完整历史证据)

---

### Task 3: 端到端验证

**Files:**
- 无文件改动;只读验证

**Interfaces:**
- Consumes: Task 1 的 bashrc 导出、Task 2 的克隆仓库
- Produces: 验证结论(spec 验证节三项全过)

- [ ] **Step 1: 新交互 shell 中环境变量生效**

Run: `bash -ic 'echo "$LLAMA_CPP_SRC"'`
Expected: 输出 `/mnt/usr/tools/llama.cpp`。(bash 以 `-i` 启动时可能伴随 "cannot set terminal process group"/"no job control" 提示,属正常噪音,不影响判定)

- [ ] **Step 2: config.sh 解析链——默认值不覆盖已导出的环境变量**

Run: `bash -c 'export LLAMA_CPP_SRC=/mnt/usr/tools/llama.cpp; source /mnt/usr/project/system/llama.cpp_helper/config.sh; echo "$LLAMA_CPP_SRC"; echo "$BUILD_DIR"'`
Expected: 第一行 `/mnt/usr/tools/llama.cpp`(未被默认值 `../llama.cpp` 覆盖);第二行 `/mnt/usr/tools/llama.cpp/build`(BUILD_DIR 正确派生)

- [ ] **Step 3: 三项验证结果汇总报告**

向用户报告 spec 验证节三项的实测输出:①新 shell 变量值;②origin URL;③config.sh 解析链。任一不符则按各任务的预期输出定位修复,不得带病通过

---

### Task 4: 文档闭环

**Files:**
- Modify: `docs/superpowers/specs/2026-09-02-llama-cpp-src-local-path-design.md`(状态行)

**Interfaces:**
- Consumes: Task 3 全部通过
- Produces: spec 状态更新为已实施并提交(仓库惯例闭环)

- [ ] **Step 1: 更新 spec 状态行**

将 `- 状态:已批准,待实施` 改为 `- 状态:已实施并验证(2026-09-02,验证输出见会话记录)`

- [ ] **Step 2: 提交**

```bash
cd /mnt/usr/project/system/system-config
git add docs/superpowers/specs/2026-09-02-llama-cpp-src-local-path-design.md
git commit -m "docs: llama.cpp 本机路径覆盖 spec 状态闭环——已实施并验证"
```

Expected: 提交成功,工作树干净
