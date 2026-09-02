# update.sh 源码目录缺失时自动克隆 — 实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `LLAMA_CPP_SRC` 目录不存在或为空目录时，`update.sh` 自动完整克隆 llama.cpp 源码并走正常更新流程（查最新 release → checkout → 构建）。

**Architecture:** 方案 A（前置补齐 + 完全复用现有流程）：在 `main()` 的 `llama_activate_conda` 之后、`_normalize_src_path` 之前插入 `_ensure_source_repo`，clone 完成后 `_normalize_src_path`/`_check_local_repo`/`_resolve_target`/`_update_source`/`_build_with_rollback` 全部零改动，事务/回滚/锁语义复用现有路径。

**Tech Stack:** Bash ≥ 4.2、bats-core 测试、git（`file://` 本地仓做离线真实 clone）。

**Spec:** `docs/superpowers/specs/2026-09-03-auto-clone-on-missing-src-design.md`

## Global Constraints

- **Bash ≥ 4.2** 硬性要求；空目录判定等不得使用 Bash 4.3+ 特性（如 `[[ -v arr[k] ]]`）
- **语言策略**：日志/错误消息/注释用中文，代码标识符/路径/Git ref 用英文
- **提交前** `make check`（lint + syntax + test）全绿；提交信息 Conventional Commits 中文风格，结尾加 `Co-Authored-By: Claude Code <noreply@anthropic.com>`
- **直接提交到 `main`**（个人仓简易流程，不用 feature 分支）
- **每个提交聚焦单一变更**
- 测试**绝不触碰生产** `../llama.cpp`：使用 `tests/test_helper.bash` 的 `TEST_TMPDIR` 沙盒与 `LLAMA_CPP_SRC` 覆盖
- 测试加载被测函数用 `_load_update`（`_LLAMA_SOURCE_ONLY=1` 提取模式）；调用会 `llama_die`(exit) 的函数必须经 `run` 包裹（子 shell 隔离 exit 与 trap 副作用）
- 管线可能非零时 `var=$(pipeline)` 必须 `|| true` 保护（反模式 8）
- 无命令的 `exec {fd}>&-` 绝不加输出重定向（反模式 9）
- 注释布局：函数头 `# Usage: <name> <args>`，节分隔 `# --- 节名 ---`
- 新函数均为 update.sh 私有（`_` 前缀命名）；**零新增脚本级全局**（C4 契约由 test_smoke.bats 钉住，新增脚本级赋值会触发违规）
- `config.sh` 零改动（`REPO_URL`/`GIT_HTTP_LOW_SPEED_*` 复用现有定义）

---

### Task 1: `_clone_repo` + `_cleanup_clone_artifacts` + C3 契约豁免

**Files:**
- Modify: `update.sh`（在 `_git_net` 定义之后插入两个函数，约 update.sh:73 之后）
- Test: `tests/test_update.bats`（文件末尾追加 4 个用例）
- Modify: `tests/test_smoke.bats:114-132`（C3 契约放行 `git clone`）

**Interfaces:**
- Consumes: `llama_info`/`llama_warn`(common.sh)、`GIT_HTTP_LOW_SPEED_LIMIT`/`GIT_HTTP_LOW_SPEED_TIME`(config.sh:88-89)
- Produces:
  - `_clone_repo <url> <dest>` — 完整克隆，成功 0 / 失败非零（不做清理）
  - `_cleanup_clone_artifacts <path>` — 目录存在则 `rm -rf`，不存在静默通过，恒返回 0

- [ ] **Step 1: 写失败测试**

`tests/test_update.bats` 末尾追加：

```bash
@test "_clone_repo clones a local file:// repo with tags" {
    _load_update

    # 本地仓作 file:// origin:离线真实 clone(tags 随 clone 就位)
    local origin="${TEST_TMPDIR}/origin"
    _init_git_repo "$origin"
    git -C "$origin" tag b7000

    local dest="${TEST_TMPDIR}/clone_dest"
    run _clone_repo "file://${origin}" "$dest"
    [ "$status" -eq 0 ]
    [ -f "${dest}/.git/config" ]
    [ "$(git -C "$dest" tag)" = "b7000" ]
}

@test "_clone_repo fails for non-existent url" {
    _load_update

    run _clone_repo "file://${TEST_TMPDIR}/no-such-repo" "${TEST_TMPDIR}/clone_dest_fail"
    [ "$status" -ne 0 ]
}

@test "_cleanup_clone_artifacts removes directory" {
    _load_update

    local dest="${TEST_TMPDIR}/half_cloned"
    mkdir -p "${dest}/.git"
    run _cleanup_clone_artifacts "$dest"
    [ "$status" -eq 0 ]
    [[ ! -d "$dest" ]]
}

@test "_cleanup_clone_artifacts tolerates missing directory" {
    _load_update

    run _cleanup_clone_artifacts "${TEST_TMPDIR}/never_existed"
    [ "$status" -eq 0 ]
}
```

- [ ] **Step 2: 跑测试确认红**

Run: `bats tests/test_update.bats -f "_clone_repo|_cleanup_clone_artifacts"`
Expected: FAIL — `_clone_repo: command not found` / `_cleanup_clone_artifacts: command not found`

- [ ] **Step 3: 实现两个函数**

`update.sh` 中 `_git_net` 定义（73 行 `}`）之后插入：

```bash
# Usage: _clone_repo <url> <dest>
# 完整克隆 <url> 到 <dest>（首次安装场景，由 _ensure_source_repo 调用）。
# 低速保护与 _git_net 同源（同一对 config.sh 常量）：对端半挂起时中止传输。
# 不加 --quiet：clone 是数百 MB 的首次大下载，tty 下 git 自适应显示进度。
# 失败时目录清理由调用点负责（git 自身也会清理其创建的目录）。
# 注：clone 无法带 -C（dest 尚不存在）——C3 契约测试中的登记豁免行。
_clone_repo() {
    local url="$1"
    local dest="$2"
    llama_info "正在从 ${url} 克隆 llama.cpp 源码..."
    env GIT_HTTP_LOW_SPEED_LIMIT="${GIT_HTTP_LOW_SPEED_LIMIT}" \
        GIT_HTTP_LOW_SPEED_TIME="${GIT_HTTP_LOW_SPEED_TIME}" \
        git clone -- "$url" "$dest"
}

# Usage: _cleanup_clone_artifacts <path>
# 删除 clone 半成品目录，恢复"未安装"状态；目录不存在时静默通过。
# 安全不变量：仅可在 _ensure_source_repo 判定目录缺失/为空之后调用
# （目录内无用户数据），trap 注册窗口本身即该标记。
_cleanup_clone_artifacts() {
    local path="$1"
    if [[ -d "$path" ]]; then
        llama_warn "清理未完成的克隆目录: ${path}"
        rm -rf -- "$path"
    fi
}
```

- [ ] **Step 4: 跑测试确认绿（新用例），并观察 smoke 契约红**

Run: `bats tests/test_update.bats -f "_clone_repo|_cleanup_clone_artifacts"`
Expected: 4 PASS

Run: `bats tests/test_smoke.bats -f "git invocations"`
Expected: FAIL — 裸 `git clone` 行被 C3 契约捕获（预期中的红，下一步豁免）

- [ ] **Step 5: 更新 C3 契约测试登记豁免**

`tests/test_smoke.bats` 的 `"update.sh git invocations all use explicit -C \$LLAMA_CPP_SRC"` 用例（114-132 行），注释块与放行模式同步修改。

注释（121-122 行的"已知局限"两句）改为：

```
    # 已知局限（行级检查）：submodule foreach 的内层 'git diff' 由 foreach 自身
    # 提供 cwd，属合法裸调用，靠同行的外层 git -C 放行；git clone 是结构性
    # 例外（目标目录尚不存在，-C 无意义），集中在 _clone_repo 一行并在此登记。
```

放行 grep（127 行）改为：

```bash
        | grep -vE 'git[[:space:]]+-C[[:space:]]+\\?"?\$\{?LLAMA_CPP_SRC\}?\\?"?|git[[:space:]]+clone' || true)
```

- [ ] **Step 6: 全量质量门禁**

Run: `make check`
Expected: 全绿（lint + syntax + test）

- [ ] **Step 7: 提交**

```bash
git add update.sh tests/test_update.bats tests/test_smoke.bats
git commit -m "feat: 新增 _clone_repo/_cleanup_clone_artifacts，C3 契约登记 clone 豁免

Co-Authored-By: Claude Code <noreply@anthropic.com>"
```

---

### Task 2: `_ensure_source_repo` + `_cleanup_on_clone_interrupt`

**Files:**
- Modify: `update.sh`（`_cleanup_on_clone_interrupt` 放 `_cleanup_on_interrupt` 定义之后，约 172 行后；`_ensure_source_repo` 放 `_normalize_src_path` 定义之前，约 411 行前）
- Test: `tests/test_update.bats`（末尾追加 6 个用例）

**Interfaces:**
- Consumes: Task 1 的 `_clone_repo <url> <dest>`、`_cleanup_clone_artifacts <path>`；`llama_check_commands`/`llama_check_disk_space`/`llama_die`/`llama_safe_exit`/`llama_with_network_context`(common.sh)；`REPO_URL`(config.sh:40)
- Produces:
  - `_ensure_source_repo [url]` — 非空目录 no-op 返回 0；缺失/空目录 → clone；一切失败经 `llama_die`。`[url]` 缺省 `$REPO_URL`（参数为测试 seam，Task 3 main 接线不传参）
  - `_cleanup_on_clone_interrupt [exit_code]` — clone 期间专用 trap handler（清理 + `llama_safe_exit`），仅由 `_ensure_source_repo` 注册/解除

- [ ] **Step 1: 写失败测试**

`tests/test_update.bats` 末尾追加：

```bash
@test "_ensure_source_repo no-op on non-empty directory" {
    _load_update

    # test_helper 已建好最小 git 仓库（非空）：url 不应被使用
    local before
    before=$(ls -A "$LLAMA_CPP_SRC")
    run _ensure_source_repo "file:///unused"
    [ "$status" -eq 0 ]
    [ "$(ls -A "$LLAMA_CPP_SRC")" = "$before" ]
}

@test "_ensure_source_repo clones when directory missing" {
    _load_update

    local origin="${TEST_TMPDIR}/origin"
    _init_git_repo "$origin"
    git -C "$origin" tag b7000

    LLAMA_CPP_SRC="${TEST_TMPDIR}/fresh_src" run _ensure_source_repo "file://${origin}"
    [ "$status" -eq 0 ]
    [ -f "${TEST_TMPDIR}/fresh_src/.git/config" ]
    [ "$(git -C "${TEST_TMPDIR}/fresh_src" tag)" = "b7000" ]
}

@test "_ensure_source_repo clones into empty directory" {
    _load_update

    local origin="${TEST_TMPDIR}/origin"
    _init_git_repo "$origin"
    mkdir -p "${TEST_TMPDIR}/empty_src"

    LLAMA_CPP_SRC="${TEST_TMPDIR}/empty_src" run _ensure_source_repo "file://${origin}"
    [ "$status" -eq 0 ]
    [ -f "${TEST_TMPDIR}/empty_src/.git/config" ]
}

@test "_ensure_source_repo fails when parent directory missing" {
    _load_update

    LLAMA_CPP_SRC="${TEST_TMPDIR}/no_such_parent/src" run _ensure_source_repo "file:///unused"
    [ "$status" -ne 0 ]
    [[ "$output" =~ "父目录不存在" ]]
    [[ ! -e "${TEST_TMPDIR}/no_such_parent/src" ]]
}

@test "_ensure_source_repo cleans up after failed clone (missing dir start)" {
    _load_update

    LLAMA_CPP_SRC="${TEST_TMPDIR}/fail_src" run _ensure_source_repo "file://${TEST_TMPDIR}/no-such-repo"
    [ "$status" -ne 0 ]
    [[ ! -e "${TEST_TMPDIR}/fail_src" ]]
}

@test "_ensure_source_repo cleans up after failed clone (empty dir start)" {
    _load_update

    mkdir -p "${TEST_TMPDIR}/fail_empty"
    LLAMA_CPP_SRC="${TEST_TMPDIR}/fail_empty" run _ensure_source_repo "file://${TEST_TMPDIR}/no-such-repo"
    [ "$status" -ne 0 ]
    [[ ! -e "${TEST_TMPDIR}/fail_empty" ]]
}
```

- [ ] **Step 2: 跑测试确认红**

Run: `bats tests/test_update.bats -f "_ensure_source_repo"`
Expected: FAIL — `_ensure_source_repo: command not found`

- [ ] **Step 3: 实现两个函数**

`update.sh` 中 `_cleanup_on_interrupt` 定义（172 行 `}`）之后插入：

```bash
# Usage: _cleanup_on_clone_interrupt [exit_code]
# clone 期间专用的中断清理（注册/解除均在 _ensure_source_repo 内）：
# 清理半成品目录后按信号语义退出（130/143，与 _cleanup_on_interrupt 同形态）。
_cleanup_on_clone_interrupt() {
    local exit_code="${1:-130}"
    llama_warn "克隆被中断，正在清理..."
    _cleanup_clone_artifacts "$LLAMA_CPP_SRC"
    llama_safe_exit "$exit_code"
}
```

`update.sh` 中 `_normalize_src_path` 定义（411 行注释块）之前插入：

```bash
# Usage: _ensure_source_repo [url]
# 首次安装场景：LLAMA_CPP_SRC 不存在或为空目录时自动克隆源码；
# 非空目录 no-op（后续 _check_local_repo 的 fail-closed 检查不变）。
# [url] 缺省 REPO_URL；参数主要为测试 seam（file:// 本地仓离线测试）。
_ensure_source_repo() {
    local url="${1:-$REPO_URL}"

    if [[ -d "$LLAMA_CPP_SRC" ]]; then
        # ls -A：空目录（无 . .. 以外条目）输出空；2>/dev/null 防 TOCTOU 竞态
        if [[ -n "$(ls -A "$LLAMA_CPP_SRC" 2>/dev/null)" ]]; then
            return 0  # 非空目录：no-op
        fi
        llama_info "源码目录为空: ${LLAMA_CPP_SRC}"
    else
        llama_info "源码目录不存在: ${LLAMA_CPP_SRC}"
    fi
    llama_info "首次使用，将自动克隆 llama.cpp 源码"

    # clone 最小依赖；完整工具检查在 _check_local_repo（幂等重复无害）
    llama_check_commands "git" "git" || llama_die "缺少 git，无法克隆源码"

    # 父目录必须存在：不自动 mkdir -p，防止在错误挂载点静默创建目录树
    local parent_dir
    parent_dir=$(dirname -- "$LLAMA_CPP_SRC")
    if [[ ! -d "$parent_dir" ]]; then
        llama_err "父目录不存在: ${parent_dir}"
        llama_die "请检查 LLAMA_CPP_SRC 路径拼写或挂载状态"
    fi
    llama_check_disk_space "$parent_dir" || llama_die

    # clone 期间的中断清理 trap：注册窗口即"目录内无用户数据"的安全标记，
    # clone 成功后立即解除（后续由 _check_local_repo 注册 _cleanup_on_interrupt 接管）
    trap '_cleanup_on_clone_interrupt 130' SIGINT
    trap '_cleanup_on_clone_interrupt 143' SIGTERM

    local clone_rc=0
    llama_with_network_context "克隆 llama.cpp 源码" \
        _clone_repo "$url" "$LLAMA_CPP_SRC" || clone_rc=$?

    trap - SIGINT SIGTERM

    if [[ "$clone_rc" -ne 0 ]]; then
        _cleanup_clone_artifacts "$LLAMA_CPP_SRC"
        llama_die "克隆失败，已恢复到未安装状态"
    fi
    llama_ok "源码克隆完成"
}
```

- [ ] **Step 4: 跑测试确认绿**

Run: `bats tests/test_update.bats -f "_ensure_source_repo"`
Expected: 6 PASS

- [ ] **Step 5: 全量质量门禁**

Run: `make check`
Expected: 全绿

- [ ] **Step 6: 提交**

```bash
git add update.sh tests/test_update.bats
git commit -m "feat: 新增 _ensure_source_repo——源码目录缺失/为空时自动克隆

Co-Authored-By: Claude Code <noreply@anthropic.com>"
```

---

### Task 3: main() 接线 + --help 说明 + 顺序契约测试

**Files:**
- Modify: `update.sh:801-802`（main 中插入一行）、`update.sh:41-52`（`_show_help` 描述）
- Test: `tests/test_smoke.bats`（末尾追加顺序契约用例）、`tests/test_update.bats`（末尾追加 1 个用例）

**Interfaces:**
- Consumes: Task 2 的 `_ensure_source_repo [url]`（main 不传参，用缺省 `$REPO_URL`）
- Produces: main 流程新顺序（`_ensure_source_repo` 在 `_normalize_src_path` 之前），由新契约测试钉住

- [ ] **Step 1: 写失败测试**

`tests/test_smoke.bats` 末尾追加：

```bash
@test "update.sh main calls _ensure_source_repo before _normalize_src_path" {
    # 自动克隆必须在路径解析之前：_normalize_src_path 对缺失目录 die，
    # 顺序颠倒会使首次安装场景永远无法到达 clone
    local body ensure_line normalize_line
    body=$(sed -n '/^main()/,/^}/p' "${BATS_TEST_DIRNAME}/../update.sh")
    ensure_line=$(grep -n '^[[:space:]]*_ensure_source_repo' <<< "$body" | head -1 | cut -d: -f1)
    normalize_line=$(grep -n '^[[:space:]]*_normalize_src_path' <<< "$body" | head -1 | cut -d: -f1)
    [ -n "$ensure_line" ]
    [ -n "$normalize_line" ]
    [ "$ensure_line" -lt "$normalize_line" ]
}
```

`tests/test_update.bats` 末尾追加：

```bash
@test "update.sh --help mentions auto-clone on missing source" {
    run bash "${BATS_TEST_DIRNAME}/../update.sh" --help
    [ "$status" -eq 0 ]
    [[ "$output" =~ "克隆" ]]
}
```

- [ ] **Step 2: 跑测试确认红**

Run: `bats tests/test_smoke.bats -f "_ensure_source_repo before" && bats tests/test_update.bats -f "auto-clone"`
Expected: 两个均 FAIL（main 中无调用行；help 文本无"克隆"）

- [ ] **Step 3: main() 接线**

`update.sh` main() 中（801-802 行）：

```bash
    llama_activate_conda  # 激活 conda 环境（确保 python3/git 等可用）
    _normalize_src_path
```

改为：

```bash
    llama_activate_conda  # 激活 conda 环境（确保 python3/git 等可用）
    _ensure_source_repo   # 首次使用：目录缺失/为空时自动克隆（持锁状态下）
    _normalize_src_path
```

- [ ] **Step 4: --help 描述更新**

`update.sh` `_show_help`（44 行）描述参数：

```bash
        "将 llama.cpp 更新到指定版本或最新 release，并自动重新构建。" \
```

改为：

```bash
        "将 llama.cpp 更新到指定版本或最新 release，并自动重新构建。源码目录不存在/为空时自动从 GitHub 克隆（首次使用）。" \
```

- [ ] **Step 5: 跑测试确认绿**

Run: `bats tests/test_smoke.bats -f "_ensure_source_repo before" && bats tests/test_update.bats -f "auto-clone"`
Expected: 两个均 PASS

- [ ] **Step 6: 全量质量门禁**

Run: `make check`
Expected: 全绿

- [ ] **Step 7: 提交**

```bash
git add update.sh tests/test_smoke.bats tests/test_update.bats
git commit -m "feat: main 接线自动克隆与 --help 说明，新增调用顺序契约测试

Co-Authored-By: Claude Code <noreply@anthropic.com>"
```

---

### Task 4: 文档同步（README + AGENTS.md）

**Files:**
- Modify: `README.md:68-84`（首次使用节）
- Modify: `AGENTS.md`（"何处查找"表 + "安全特性"节；`CLAUDE.md` 是指向 `AGENTS.md` 的软链接，改一处即可）

**Interfaces:**
- Consumes: Task 1-3 已合入的行为
- Produces: 用户文档与代理指南的新语义登记

- [ ] **Step 1: README 首次使用节改写**

`README.md` 68-84 行的"### 首次使用"代码块：

````markdown
```bash
# 0. 克隆本项目（请替换 YOUR_USERNAME）
git clone https://github.com/YOUR_USERNAME/llama.cpp_helper  # 请替换 YOUR_USERNAME
cd llama.cpp_helper

# 1. 克隆 llama.cpp 到相邻目录
git clone https://github.com/ggml-org/llama.cpp ../llama.cpp

# 2. 构建
bash build.sh

# 3. 加载运行时环境
source run_env.sh
```
````

改为：

````markdown
```bash
# 0. 克隆本项目（请替换 YOUR_USERNAME）
git clone https://github.com/YOUR_USERNAME/llama.cpp_helper  # 请替换 YOUR_USERNAME
cd llama.cpp_helper

# 1. 一键更新——首次使用会自动克隆 llama.cpp 源码（到 ../llama.cpp）并构建最新 release
bash update.sh

# 2. 加载运行时环境
source run_env.sh
```

如需自定义源码位置，先手动克隆再经 `LLAMA_CPP_SRC` 指向它：

```bash
git clone https://github.com/ggml-org/llama.cpp /your/path/llama.cpp
LLAMA_CPP_SRC=/your/path/llama.cpp bash update.sh
```
````

注意：该代码块后续的 `# 4. 运行模型推理`/`# 5. 运行模型服务` 步骤号随之上移（改为 3/4），命令内容不变。

- [ ] **Step 2: AGENTS.md 登记**

"何处查找"表中"修改更新逻辑"行：

```
| 修改更新逻辑 | `update.sh` → `_resolve_target()` / `_update_source()` / `_build_with_rollback()` | 决策 → 切换 → 构建 → 回滚链路 |
```

改为：

```
| 修改更新逻辑 | `update.sh` → `_ensure_source_repo()` / `_resolve_target()` / `_update_source()` / `_build_with_rollback()` | 首装克隆 → 决策 → 切换 → 构建 → 回滚链路 |
```

"安全特性"节追加一条（加在"文件锁"条目之前，保持列表风格）：

```
- **首次自动克隆**：`update.sh` 在 `LLAMA_CPP_SRC` 缺失/为空时自动完整克隆（`_ensure_source_repo`）；clone 失败/中断（SIGINT/SIGTERM 分信号 trap）清理半成品目录恢复"未安装"状态，trap 注册窗口即"目录内无用户数据"不变量；父目录不存在时 die（不自动创建目录树，防错误挂载点）；`git clone` 是 C3 `git -C` 契约的登记豁免（目标不存在时 `-C` 无意义，集中在 `_clone_repo` 一行）
```

- [ ] **Step 3: 全量质量门禁（文档改动不影响测试，但按流程跑）**

Run: `make check`
Expected: 全绿

- [ ] **Step 4: 提交**

```bash
git add README.md AGENTS.md
git commit -m "docs: 快速开始改为 update.sh 一键首装，登记 auto-clone 语义

Co-Authored-By: Claude Code <noreply@anthropic.com>"
```

---

## 自审记录

- **Spec 覆盖**：触发三态/仅 update.sh（Task 2）、完整克隆+低速保护（Task 1）、父目录 die（Task 2）、失败/中断清理（Task 1+2）、C3 豁免（Task 1）、main 接线+help（Task 3）、README/AGENTS.md（Task 4）——spec 每节均有对应任务
- **占位符**：无 TBD/TODO；所有测试与实现代码完整给出
- **类型一致性**：`_clone_repo <url> <dest>`、`_cleanup_clone_artifacts <path>`、`_ensure_source_repo [url]`、`_cleanup_on_clone_interrupt [exit_code]` 在 Tasks 1-3 间签名一致
- **端到端验证**（计划外手动项，实现完成后由用户执行）：`LLAMA_CPP_SRC=<不存在路径> bash update.sh` 真实克隆 GitHub——不在 bats 范围（项目既有测试边界）
