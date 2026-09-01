# llama_activate_conda 权威语义改造 — 设计文档

日期：2026-09-02
状态：已获用户批准（2026-09-02）

## 背景与问题

`common.sh` 的 `llama_activate_conda()` 当前在检测到 `CONDA_PREFIX` 非空（任何 conda 环境处于激活状态）时直接提前返回，沿用当前环境，**不切换到 `CONDA_ENV_NAME`**：

```bash
if [[ -n "${CONDA_PREFIX:-}" ]]; then
    llama_info "conda 环境已激活: ${CONDA_PREFIX}"
    return 0
fi
```

本机交互 shell 由 conda 默认配置自动激活 base（`CONDA_SHLVL=1`、`CONDA_DEFAULT_ENV=base`）。因此用户即使在 `.bashrc` 中显式设置 `CONDA_ENV_NAME=llama.cpp`，该变量也会被静默忽略，`build.sh` 实际仍在 base 下构建——而 base 中没有 nvcc，构建必然失败。

**用户预期（本次设计的目标语义）**：明确设置了 `CONDA_ENV_NAME` 就必须明确使用该环境；指定的环境不存在/激活失败时报错。经澄清问题确认：未显式设置（默认 base）时同样统一切换——**`CONDA_ENV_NAME` 恒为权威**，不做"显式设置 vs 默认值"的区分。

## 新行为矩阵

| 情形 | 行为 | 返回值 |
|------|------|--------|
| `CONDA_AUTO_ACTIVATE ≠ 1` | 跳过（不变） | 0 |
| 当前激活环境 == 目标（`${CONDA_ENV_NAME:-base}`） | 短路，info 提示（沿用现有"已激活"消息） | 0 |
| 当前无激活环境 / 激活的是其他环境 | `conda activate "$目标"`，强制切换 | 0 |
| 激活失败（环境不存在等） | `llama_err` 打印环境名与排查指引 | **1** |
| 找不到 conda 安装 | 静默跳过（conda 是可选工具链来源，不变） | 0 |
| 找到 conda 但缺 `conda.sh` | 警告后跳过（不变） | 0 |

## 实现方案

改动集中在 `common.sh` 的 `llama_activate_conda()` 一个函数：

1. **删除** `CONDA_PREFIX` 非空即返回的提前返回，改为目标比较短路：
   - 目标 = `"${CONDA_ENV_NAME:-base}"`。
   - 以 `CONDA_DEFAULT_ENV` 与目标名比较判断是否已在目标环境。**不能用** `basename "$CONDA_PREFIX"`：base 环境的 `CONDA_PREFIX` 是安装根（如 `/mnt/usr/tools/anaconda`），basename 为 `anaconda` 而非 `base`。
   - `CONDA_DEFAULT_ENV` 缺失但 `CONDA_PREFIX` 存在时无法可靠判断，按"需要切换"处理——`conda activate` 幂等，安全。
2. **激活失败路径升级**：`conda activate` 失败时由 `llama_warn` + 返回 0 改为 `llama_err` + 返回 1；错误消息含环境名，并指引 `conda env list` / 检查 `CONDA_ENV_NAME` 设置。保留现有 mktemp 捕获 stderr 并 `llama_detail` 输出的机制。
3. **保留不变**：conda 定位级联（`CONDA_EXE` 反推 → 常见安装路径扫描 → `conda info --base`）；source `conda.sh` 前后的 `set +eu` 放宽与基于 `$-` 的对称恢复；找不到 conda / 缺 conda.sh 的软跳过。
4. **函数头注释重写**："永不失败 — 始终返回 0"契约改为"激活失败返回 1"，并说明权威语义。
5. **无新增全局状态**：不引入"显式设置"标志位；`config.sh` 仅给 `CONDA_ENV_NAME` 注释补一句权威语义说明。

## 调用点行为（零代码改动）

- `build.sh:271`、`update.sh:749`：裸调用 + `set -e`，返回 1 即中止脚本——显式指定环境失败时构建/更新立即报错停止，符合预期。
- `run_env.sh:155`：source 上下文、无 `set -e`，打印错误后继续设置性能环境变量（构建产物经 RPATH 运行本就不依赖激活状态），不杀父 shell——符合该脚本"source 使用不伤害父 shell"的既有承诺。

## 错误处理

- 返回值契约：0 = 成功或按设计跳过；1 = 已定位 conda 但 `conda activate "$目标"` 失败。
- 错误消息经 `llama_err` 走 stderr；`llama_detail` 附 conda 自身报错内容（mktemp 捕获）。
- `build.sh`/`update.sh` 的中止依赖既有的 `set -e` + 裸调用组合，不新增 `|| llama_die`（保持调用点简洁；裸调用在 `set -e` 下即致命）。

## 测试计划

bats 用例（`tests/test_common.bats`，全部使用 mock conda，不触碰真实环境）：

- **改写** `"llama_activate_conda skips when already activated (CONDA_PREFIX set)"`（现 596 行）→ "目标环境已激活时短路"：显式设置 `CONDA_DEFAULT_ENV`/`CONDA_PREFIX` 为目标环境，断言短路消息且不触发切换。注意测试进程会继承开发机 base 激活状态，用例必须显式控制这两个变量，避免脏通过。
- **新增** "切换到 CONDA_ENV_NAME 指定的环境（当前激活其他环境）"：mock conda（复用现有 `_make_stub_exec` + 假 `conda.sh` 模式），`CONDA_PREFIX` 指向其他环境、`CONDA_ENV_NAME=X`，断言 mock 收到 `activate X` 且输出"已激活 conda 环境: X"。
- **新增** "激活失败返回 1"：mock `conda activate` 返回 1，断言函数返回 1 且 stderr 含错误消息。
- **保留不变**：`CONDA_AUTO_ACTIVATE=0` 跳过；找不到 conda 返回 0；缺 conda.sh 警告。
- **调整** errexit 对称恢复回归（432 行）：用例必须显式强制走激活路径（如将 `CONDA_DEFAULT_ENV` 设为与目标不同的值或 unset），否则在继承开发机 base 激活状态时会经短路路径返回，失去对该代码路径（source conda.sh → activate → 选项恢复）的回归保护。
- `make check`（lint + syntax + test）全绿为完成标准。

真实环境验证（实现后手动执行，只读操作，**保持 base 环境干净，不在 base 中安装任何包**）：

- `CONDA_ENV_NAME=llama.cpp` 下直接调用函数，验证真实切换到用户已创建的 `llama.cpp` 环境（`nvcc --version` 可用）。
- 不设 `CONDA_ENV_NAME` 时验证切换到 base 的幂等行为。

## 文档同步

- `README.md` conda 配置表（275-276 行附近）：`CONDA_ENV_NAME` 描述补充权威语义（指定后强制切换，激活失败即报错）。
- `AGENTS.md`（`CLAUDE.md` 为其软链接）错误处理模式段：更新对 `llama_activate_conda` 的描述（`$-` 保存/恢复 errexit 的参考实现保留，追加权威语义一句）。
- `config.sh` 的 `CONDA_ENV_NAME` 注释、`common.sh` 函数头注释同步。

## 明确不做（YAGNI）

- 不改 conda 定位级联逻辑。
- 不改 `build.sh` 对 nvcc 缺失的 warn-only 检查。
- 不引入"环境不存在时自动创建"等附加功能。
- 不区分"显式设置 vs 默认值"（用户已确认权威语义覆盖两种情形）。
