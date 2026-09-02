# llama_activate_conda 权威语义改造实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 重写 `common.sh` 的 `llama_activate_conda` 为 `CONDA_ENV_NAME` 权威语义（当前激活其他环境时强制切换，激活失败返回 1），修复显式设置被静默忽略的缺陷。

**Architecture:** 单函数改写：`CONDA_PREFIX` 提前返回替换为基于 `CONDA_DEFAULT_ENV` 的目标比较短路；激活失败路径由 warn+0 升级为 err+1；conda 定位级联、`set +eu` 保护/对称恢复、mktemp 错误捕获全部保留。三个调用点零改动（build.sh/update.sh 靠 set -e 自然中止；run_env.sh 打印错误继续）。

**Tech Stack:** Bash ≥ 4.2、bats-core、ShellCheck（`make check` 质量门禁）。

**Spec:** `docs/superpowers/specs/2026-09-02-conda-env-authoritative-design.md`（已批准，commit 91d04fe）

## Global Constraints

- 日志/注释/提交信息用中文；代码引用（函数名/变量名/路径）用英文。
- `llama_` 前缀公开函数命名不变；函数签名不变（`llama_activate_conda`，无参数）。
- 保存/恢复 errexit 必须用 `$-`（严禁 `prev_opts=$(set +o)`），现有实现保留。
- 绝不删除锁文件、绝不修改生产 `../llama.cpp`（本任务不涉及）。
- 测试只用 mock conda（`_make_stub_exec` + 假 `conda.sh` 模式），绝不触碰真实 conda 环境；真实环境验证仅 activate + 只读查询（`nvcc --version`），**保持 base 环境干净，不在 base 安装任何包**。
- 测试进程继承开发机 base 激活状态（`CONDA_PREFIX`/`CONDA_DEFAULT_ENV`），凡要走激活/发现路径的用例必须显式 `unset CONDA_PREFIX CONDA_DEFAULT_ENV` 或显式赋值。
- 提交遵循 Conventional Commits 中文风格，直接提交到 `main`；每个 Task 结束提交一次。
- 完成标准：`make check`（lint + syntax + test）全绿。

---

### Task 1: 改写/新增 bats 用例（红）

**Files:**
- Modify: `tests/test_common.bats`（conda Activation 段约 588-655 行；errexit 回归用例约 432-446 行）
- Test: `tests/test_common.bats`

**Interfaces:**
- Consumes: 现有 `llama_activate_conda`（旧语义）、`_make_stub_exec`（tests/test_helper.bash:44）
- Produces: 新语义的测试契约——Task 2 实现后全部转绿

注意：bats 的 `run` 默认将 stderr 合并进 `$output`，`llama_err` 的消息可直接对 `$output` 断言。

- [ ] **Step 1: 改写"已激活"用例为短路语义**

将：

```bash
@test "llama_activate_conda skips when already activated (CONDA_PREFIX set)" {
    CONDA_PREFIX="/fake/conda/env" CONDA_AUTO_ACTIVATE=1 run llama_activate_conda
    [ "$status" -eq 0 ]
    [[ "$output" =~ "conda 环境已激活" ]]
}
```

替换为：

```bash
@test "llama_activate_conda short-circuits when target env already active" {
    # 目标即当前环境（默认 base）时短路，不进入发现/切换路径。
    # 必须显式控制 CONDA_DEFAULT_ENV——测试进程继承开发机 base 激活状态
    CONDA_PREFIX="/fake/conda" CONDA_DEFAULT_ENV=base CONDA_AUTO_ACTIVATE=1 run llama_activate_conda
    [ "$status" -eq 0 ]
    [[ "$output" =~ "conda 环境已激活" ]]
}
```

（该用例在旧代码下也碰巧通过——它是行为保持性改写，红灯由 Step 3/4 的用例提供。）

- [ ] **Step 2: 既有发现/跳过用例补显式环境控制**

- `"returns 0 when no conda found"`：`unset CONDA_EXE CONDA_PREFIX` 改为 `unset CONDA_EXE CONDA_PREFIX CONDA_DEFAULT_ENV`。
- `"detects conda from CONDA_EXE"`：在 `run` 前加一行 `unset CONDA_PREFIX CONDA_DEFAULT_ENV`（旧代码靠 CONDA_PREFIX 提前返回，新代码靠 CONDA_DEFAULT_ENV 短路——不 unset 时继承的 base 状态会让用例测不到发现路径）。
- `"detects conda from common path"`：`unset CONDA_EXE CONDA_PREFIX` 改为 `unset CONDA_EXE CONDA_PREFIX CONDA_DEFAULT_ENV`。
- `"warns when conda.sh missing"`：在 `run` 前加一行 `unset CONDA_PREFIX CONDA_DEFAULT_ENV`。

- [ ] **Step 3: 新增"强制切换"用例**

在 `"detects conda from common path"` 之后插入：

```bash
@test "llama_activate_conda switches to CONDA_ENV_NAME when another env is active" {
    # 权威语义核心：当前激活 other 环境，显式指定 myenv，必须强制切换
    local mock_base="${TEST_TMPDIR}/mock_switch"
    mkdir -p "${mock_base}/etc/profile.d" "${mock_base}/bin"
    _make_stub_exec "${mock_base}/bin/conda"
    cat > "${mock_base}/etc/profile.d/conda.sh" <<EOF
conda() {
    if [[ "\$1" == "activate" ]]; then
        echo "activate \$2" >> "${mock_base}/activate.log"
        export CONDA_PREFIX="${mock_base}/envs/\${2:-base}"
        export CONDA_DEFAULT_ENV="\${2:-base}"
        return 0
    fi
}
EOF
    CONDA_PREFIX="/fake/other" CONDA_DEFAULT_ENV=other CONDA_ENV_NAME=myenv \
        CONDA_EXE="${mock_base}/bin/conda" CONDA_AUTO_ACTIVATE=1 \
        run llama_activate_conda
    [ "$status" -eq 0 ]
    [[ "$output" =~ "已激活 conda 环境: myenv" ]]
    grep -q "activate myenv" "${mock_base}/activate.log"
}
```

- [ ] **Step 4: 改写"激活失败"用例为返回 1**

将 `"llama_activate_conda warns on conda activate failure"` 整体替换为：

```bash
@test "llama_activate_conda returns 1 on conda activate failure" {
    # 权威语义：显式指定的环境激活失败 → 硬报错返回 1（build.sh/update.sh
    # 的裸调用在 set -e 下随之中止）
    local mock_fail="${TEST_TMPDIR}/mock_fail"
    mkdir -p "${mock_fail}/etc/profile.d" "${mock_fail}/bin"
    _make_stub_exec "${mock_fail}/bin/conda"
    echo 'conda() { if [[ "$1" == "activate" ]]; then echo "环境不存在" >&2; return 1; fi; }' \
        > "${mock_fail}/etc/profile.d/conda.sh"
    unset CONDA_PREFIX CONDA_DEFAULT_ENV
    CONDA_ENV_NAME=no_such_env CONDA_EXE="${mock_fail}/bin/conda" CONDA_AUTO_ACTIVATE=1 \
        run llama_activate_conda
    [ "$status" -eq 1 ]
    [[ "$output" =~ "conda 环境激活失败" ]]
    [[ "$output" =~ "no_such_env" ]]
    [[ "$output" =~ "环境不存在" ]]
}
```

- [ ] **Step 5: errexit 回归用例强制走激活路径**

`"preserves caller errexit after activation (regression)"`（约 432 行）的 `run bash -c "` 块内，`source` 行之前插入一行：

```bash
        unset CONDA_PREFIX CONDA_DEFAULT_ENV
```

（否则继承开发机 base 激活状态会经短路返回，失去对 source conda.sh → activate → 选项恢复路径的回归保护。）

- [ ] **Step 5b: Resilience 段三用例（798/823/847 行）同步处理**

执行中发现（计划初版遗漏）：该段三用例的 `bash -c` 子 shell 继承开发机 `CONDA_PREFIX`，旧代码下经"提前返回"碰巧通过但并未真正覆盖激活路径；其中 823 行用例的契约与新语义直接冲突，必须改写。

1. `"survives set -u when conda script references unset variable"`（798 行）：`bash -c` 块内 `source` 行前插入 `unset CONDA_PREFIX CONDA_DEFAULT_ENV`（真正走激活路径，行为保持）。
2. `"survives set -e when conda activate fails"`（823 行）**整体替换**为两个用例——新契约下 set -e 上下文的裸调用**应当中止**，容忍失败须显式 `|| true`：

```bash
@test "llama_activate_conda aborts set -e caller when conda activate fails" {
    # 新契约：激活失败返回 1，set -e 调用方（build.sh/update.sh 的裸调用）随之中止
    local mock_sete="${TEST_TMPDIR}/mock_sete"
    mkdir -p "${mock_sete}/etc/profile.d" "${mock_sete}/bin"
    _make_stub_exec "${mock_sete}/bin/conda"
    cat > "${mock_sete}/etc/profile.d/conda.sh" <<'CONDAEOF'
conda() {
    if [[ "$1" == "activate" ]]; then
        return 1
    fi
}
CONDAEOF
    CONDA_EXE="${mock_sete}/bin/conda" CONDA_AUTO_ACTIVATE=1 run bash -c "
        set -euo pipefail
        unset CONDA_PREFIX CONDA_DEFAULT_ENV
        source '${BATS_TEST_DIRNAME}/../common.sh' 2>/dev/null || true
        llama_activate_conda
        echo SURVIVED
    "
    [ "$status" -eq 1 ]
    [[ "$output" != *"SURVIVED"* ]]
    [[ "$output" =~ "conda 环境激活失败" ]]
}

@test "llama_activate_conda failure can be tolerated with || true under set -e" {
    # 调用方显式 || true 可容忍失败（run_env.sh 场景：错误已打印，流程继续）
    local mock_tol="${TEST_TMPDIR}/mock_tol"
    mkdir -p "${mock_tol}/etc/profile.d" "${mock_tol}/bin"
    _make_stub_exec "${mock_tol}/bin/conda"
    cat > "${mock_tol}/etc/profile.d/conda.sh" <<'CONDAEOF'
conda() {
    if [[ "$1" == "activate" ]]; then
        return 1
    fi
}
CONDAEOF
    CONDA_EXE="${mock_tol}/bin/conda" CONDA_AUTO_ACTIVATE=1 run bash -c "
        set -euo pipefail
        unset CONDA_PREFIX CONDA_DEFAULT_ENV
        source '${BATS_TEST_DIRNAME}/../common.sh' 2>/dev/null || true
        llama_activate_conda || true
        echo SURVIVED
    "
    [ "$status" -eq 0 ]
    [[ "$output" =~ "SURVIVED" ]]
    [[ "$output" =~ "conda 环境激活失败" ]]
}
```

3. `"restores set -u after conda activation"`（847 行）：`bash -c` 块内 `source` 行前插入 `unset CONDA_PREFIX CONDA_DEFAULT_ENV`。

Step 6 红灯预期相应更新：Step 3 新用例、Step 4 用例、Step 5b.2 的 "aborts set -e caller" 在旧代码下失败；其余通过。

- [ ] **Step 6: 运行测试确认红灯**

Run: `bats tests/test_common.bats -f "llama_activate_conda"`
Expected: FAIL——Step 3 新用例（旧代码无切换逻辑，output 无 "已激活 conda 环境: myenv"，activate.log 不存在）与 Step 4 用例（旧代码返回 0 而非 1）失败；其余用例通过。

- [ ] **Step 7: Commit**

```bash
git add tests/test_common.bats
git commit -m "test: llama_activate_conda 权威语义用例——强制切换与激活失败返回 1

Co-Authored-By: Claude Code <noreply@anthropic.com>"
```

---

### Task 2: 实现 common.sh 权威语义重写（绿）

**Files:**
- Modify: `common.sh`（`llama_activate_conda`，约 396-508 行）
- Test: `tests/test_common.bats`

**Interfaces:**
- Consumes: Task 1 的测试契约
- Produces: `llama_activate_conda` 新返回契约——0=成功/按设计跳过；1=已定位 conda 但 `conda activate` 失败。签名不变（无参数）。调用点（build.sh:271、update.sh:749、run_env.sh:155）无需改动。

- [ ] **Step 1: 整体替换函数**

将 `common.sh` 中从 `# --- conda 环境 ---` 节头注释到函数结束的整个 `llama_activate_conda` 替换为（发现级联、`set +eu` 保护、对称恢复注释块均保留原文）：

```bash
# --- conda 环境 -----------------------------------------------
# Usage: llama_activate_conda
# 检测并激活 conda 环境。遵循 config.sh 中的 CONDA_AUTO_ACTIVATE
# 和 CONDA_ENV_NAME 设置。CONDA_ENV_NAME 恒为权威：当前激活的是
# 其他环境时强制切换；已定位 conda 但激活失败（环境不存在等）
# 返回 1。找不到 conda 安装 / 缺 conda.sh 时软跳过返回 0
# （conda 仅为可选工具链来源，CUDA 亦可系统级安装）。
llama_activate_conda() {
    if [[ "${CONDA_AUTO_ACTIVATE:-1}" != "1" ]]; then
        return 0
    fi

    local target_env="${CONDA_ENV_NAME:-base}"

    # 已在目标环境则短路。必须用 CONDA_DEFAULT_ENV 比较——base 环境的
    # CONDA_PREFIX 是安装根（basename 是 anaconda 而非 base）。
    # CONDA_DEFAULT_ENV 缺失但 CONDA_PREFIX 存在时无法可靠判断，
    # 按需要切换处理（conda activate 幂等，安全）。
    if [[ -n "${CONDA_DEFAULT_ENV:-}" && "$CONDA_DEFAULT_ENV" == "$target_env" ]]; then
        llama_info "conda 环境已激活: ${CONDA_PREFIX:-$target_env}"
        return 0
    fi

    local conda_root=""

    if [[ -n "${CONDA_EXE:-}" && -x "$CONDA_EXE" ]]; then
        conda_root="$(cd "$(dirname "$CONDA_EXE")/.." 2>/dev/null && pwd)" || true
    fi

    if [[ -z "$conda_root" ]]; then
        local candidate
        for candidate in \
            "${HOME}/miniconda3" \
            "${HOME}/anaconda3" \
            "${HOME}/miniforge3" \
            "/opt/conda" \
            "/opt/miniconda3" \
            "/opt/anaconda3" \
            "/opt/miniforge3"
        do
            if [[ -f "${candidate}/etc/profile.d/conda.sh" ]]; then
                conda_root="$candidate"
                break
            fi
        done
    fi

    if [[ -z "$conda_root" ]]; then
        if command -v conda &>/dev/null; then
            conda_root="$(conda info --base 2>/dev/null || true)"
        fi
    fi

    if [[ -z "$conda_root" ]]; then
        return 0
    fi

    local conda_sh="${conda_root}/etc/profile.d/conda.sh"
    if [[ ! -f "$conda_sh" ]]; then
        llama_warn "找到 conda 安装 (${conda_root}) 但缺少 shell 初始化脚本"
        return 0
    fi

    # 保存 shell 选项，为外部 conda 脚本放宽严格模式。
    # conda 激活脚本可能引用未设置变量，或在 set -euo pipefail
    # 下导致脚本退出（例如 conda 的 ~cuda-nvcc_activate.sh
    # 未做防护就直接引用 NVCC_PREPEND_FLAGS）。
    # 注意：不能用 prev_opts=$(set +o) 保存 errexit——bash 默认在命令替换
    # 子 shell 中重置 errexit（shopt inherit_errexit 默认 off），捕获到的
    # 恒为 "set +o errexit"，eval 恢复后会把调用者的 set -e 永久静默关闭。
    # $- 在当前 shell 读取，不受该重置影响（|| / if 等豁免上下文中仍正确）。
    local restore_e=0 restore_u=0
    if [[ $- == *e* ]]; then restore_e=1; fi
    if [[ $- == *u* ]]; then restore_u=1; fi
    set +eu

    # shellcheck source=/dev/null
    source "$conda_sh"

    # 直接执行 conda activate（不在命令替换子 shell 中执行，否则环境变更会丢失）
    local activate_rc=0
    local conda_err_file
    conda_err_file=$(mktemp "${TMPDIR:-/tmp}/conda_activate_err.XXXXXX" 2>/dev/null) || conda_err_file=""
    if [[ -n "$conda_err_file" ]]; then
        if conda activate "$target_env" 2>"$conda_err_file"; then
            llama_ok "已激活 conda 环境: ${target_env}"
        else
            activate_rc=1
            llama_err "conda 环境激活失败: ${target_env}（环境不存在？请用 conda env list 确认，或检查 CONDA_ENV_NAME 设置）"
            llama_detail "$(cat "$conda_err_file" 2>/dev/null || true)"
        fi
        rm -f "$conda_err_file"
    else
        # 无法创建临时文件，回退到静默模式（不捕获 stderr）
        if conda activate "$target_env" 2>/dev/null; then
            llama_ok "已激活 conda 环境: ${target_env}"
        else
            activate_rc=1
            llama_err "conda 环境激活失败: ${target_env}（环境不存在？请用 conda env list 确认，或检查 CONDA_ENV_NAME 设置）"
        fi
    fi

    # 恢复之前的 shell 选项（仅恢复本函数改动的 e/u）
    # 对称恢复：原本开启的重新开启；原本关闭的强制关闭——既精确还原调用者
    # 原状（函数内部曾 set +e/+u 容忍 conda 失败），又防止被 source 的
    # conda.sh/profile.d 脚本新启用的 -e/-u 泄漏（如 source run_env.sh 的父
    # shell，其按设计不启用 errexit）
    if ((restore_u)); then set -u; else set +u; fi
    if ((restore_e)); then set -e; else set +e; fi

    return "$activate_rc"
}
```

- [ ] **Step 2: 运行 conda 用例确认转绿**

Run: `bats tests/test_common.bats -f "llama_activate_conda"`
Expected: 全部 PASS（含 Task 1 的红灯用例）。

- [ ] **Step 3: 全量质量门禁**

Run: `make check`
Expected: lint（shellcheck）+ syntax + 全部测试 PASS。

- [ ] **Step 4: Commit**

```bash
git add common.sh
git commit -m "fix: llama_activate_conda 改为 CONDA_ENV_NAME 权威语义

当前激活其他环境时强制切换到目标环境，修复显式设置被静默忽略；
激活失败由警告升级为返回 1（build.sh/update.sh 经 set -e 中止）。

Co-Authored-By: Claude Code <noreply@anthropic.com>"
```

---

### Task 3: 文档同步 + 真实环境验证

**Files:**
- Modify: `config.sh`（CONDA_ENV_NAME 注释，约 63 行）
- Modify: `README.md`（conda 配置表，约 276 行）
- Modify: `AGENTS.md`（错误处理模式段，约 142 行之后）

**Interfaces:**
- Consumes: Task 2 完成的新语义
- Produces: 文档与代码行为一致

- [ ] **Step 1: config.sh 注释**

将：

```bash
CONDA_ENV_NAME="${CONDA_ENV_NAME:-base}"             # 要激活的 conda 环境名称
```

改为：

```bash
CONDA_ENV_NAME="${CONDA_ENV_NAME:-base}"             # 要激活的 conda 环境名称（权威：已激活其他环境时强制切换；激活失败 build.sh/update.sh 报错中止）
```

- [ ] **Step 2: README 配置表**

将：

```markdown
| `CONDA_ENV_NAME` | `base` | 激活的 conda 环境名称 |
```

改为：

```markdown
| `CONDA_ENV_NAME` | `base` | 激活的 conda 环境名称（权威：当前激活其他环境时强制切换；环境不存在/激活失败时 build.sh/update.sh 报错中止） |
```

- [ ] **Step 3: AGENTS.md 错误处理模式段**

在 `- **保存/恢复 errexit 必须用 `$-`**…` 一条之后插入新条目：

```markdown
- **conda 环境选择**：`llama_activate_conda` 中 `CONDA_ENV_NAME` 恒为权威——当前激活其他环境时强制切换；已定位 conda 但激活失败返回 1（build.sh/update.sh 的裸调用在 `set -e` 下中止；run_env.sh 打印错误后继续，不杀父 shell）；找不到 conda 安装才软跳过。判断"已在目标环境"必须用 `CONDA_DEFAULT_ENV`——base 的 `CONDA_PREFIX` 是安装根，basename 不是 `base`
```

- [ ] **Step 4: 真实环境验证（只读，保持 base 干净）**

在当前已激活 base 的 shell 依次执行（只 activate + 查询，不安装任何包）：

```bash
# ① 显式指定 llama.cpp：当前是 base，必须强制切换且 nvcc 可用
CONDA_ENV_NAME=llama.cpp bash -c 'source /mnt/usr/project/system/llama.cpp_helper/common.sh && llama_activate_conda && command -v nvcc && nvcc --version | tail -1'
```

Expected: 输出"已激活 conda 环境: llama.cpp"，nvcc 路径在 `envs/llama.cpp/bin/` 下，版本 13.0。

```bash
# ② 默认 base：从 llama.cpp 环境切回 base（幂等权威）
bash -c 'source /mnt/usr/tools/anaconda/etc/profile.d/conda.sh && conda activate llama.cpp && source /mnt/usr/project/system/llama.cpp_helper/common.sh && llama_activate_conda && [[ "$CONDA_DEFAULT_ENV" == "base" ]] && echo SWITCH_BACK_OK'
```

Expected: 输出 SWITCH_BACK_OK。

```bash
# ③ 不存在的环境：必须返回 1 且打印错误
CONDA_ENV_NAME=no_such_env bash -c 'source /mnt/usr/project/system/llama.cpp_helper/common.sh; llama_activate_conda; echo "rc=$?"'
```

Expected: stderr 含"conda 环境激活失败: no_such_env"，`rc=1`。

```bash
# ④ 短路：base 已激活且目标为 base，不重复激活
bash -c 'source /mnt/usr/tools/anaconda/etc/profile.d/conda.sh && conda activate base && source /mnt/usr/project/system/llama.cpp_helper/common.sh && llama_activate_conda'
```

Expected: 输出"conda 环境已激活: ..."（info 而非 ok 行）。

- [ ] **Step 5: 终验**

Run: `make check`
Expected: 全绿。

- [ ] **Step 6: Commit**

```bash
git add config.sh README.md AGENTS.md
git commit -m "docs: 同步 CONDA_ENV_NAME 权威语义的配置说明与代理指南

Co-Authored-By: Claude Code <noreply@anthropic.com>"
```
