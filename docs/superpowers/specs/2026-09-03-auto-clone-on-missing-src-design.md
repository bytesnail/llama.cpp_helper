# update.sh 源码目录缺失时自动克隆 — 设计文档

日期：2026-09-03
状态：已获用户批准（2026-09-03）

## 背景与问题

`update.sh` 假设 `LLAMA_CPP_SRC` 已是完好的 git 仓库：目录不存在时 `_normalize_src_path` 直接 die（"无法解析 llama.cpp 仓库路径"），目录存在但无 `.git/config` 时 `_check_local_repo` die。首次使用必须按 README 手动 `git clone`——一键更新的"一键"在首次安装场景断档。

**目标语义（经澄清确认）**：`LLAMA_CPP_SRC` 目录**不存在**或**存在但为空目录**时，`update.sh` 自动从 `REPO_URL`（config.sh，`https://github.com/ggml-org/llama.cpp`）完整克隆源码，然后走完全正常的更新流程（查询最新 release → checkout tag → 构建）。目录非空但不是 git 仓库时保持现有 fail-closed 报错——绝不动用户已有数据。

范围：仅 `update.sh`。`build.sh` 保持纯构建工具语义（源码缺失即报错），不纳入。

## 架构与插入点

新代码集中在一个新函数，其余路径全部是现有成熟逻辑（被契约测试钉住）：

```
main() 流程:
  _parse_args               # 不变（--help/--version 在锁之前，不受影响）
  llama_acquire_lock        # 不变——clone 持锁进行，防并发 build.sh 看到半成品
  llama_activate_conda      # 不变
  _ensure_source_repo  ← 新增：缺失/空目录 → clone；非空 → no-op
  _normalize_src_path       # 不变（clone 后必然解析成功）
  _check_local_repo         # 不变——clone 后的 HEAD 被 _session_capture_current 捕获为回滚锚点
  _resolve_target           # 不变——clone 后 HEAD（默认分支 tip）≠ release tag → need_source_update=1
  _update_source            # 不变——fetch（近 no-op）+ checkout 到 release tag
  _build_with_rollback      # 不变——构建失败回滚到 clone 的 HEAD 并重建，环境可用
```

事务/回滚/锁/中断语义零改动。用户指定版本（`bash update.sh b8000`）时 clone 后由 `_resolve_target`/`_update_source` 正常解析 checkout，天然兼容；clone 后 HEAD 恰好已在最新 release（master tip == release commit）时走 `need_source_update=0` → 构建健康检查 → 直接构建，同样是既有路径。

## 组件（均为 update.sh 私有函数）

### `_ensure_source_repo()`

判定 `LLAMA_CPP_SRC` 三态并分派：

- **非空目录** → 立即 `return 0`（no-op）。后续 `_check_local_repo` 的 `.git/config` 检查对非 git 目录照常 die——行为与现状完全一致。
- **不存在或空目录** → 依次执行：
  1. `llama_check_commands "git" "git"`（clone 的最小依赖；`_check_local_repo` 内的完整工具检查保持不动，幂等重复无害）
  2. **父目录必须存在**：`dirname "$LLAMA_CPP_SRC"` 不存在时 die，提示检查路径拼写/挂载点——不自动 `mkdir -p`，防止在错误挂载点上静默创建目录树
  3. `llama_check_disk_space`（对父目录；其"路径不存在仅警告不阻塞"的既有语义不变）
  4. 注册 clone 期间专用的中断清理 trap（见"错误处理"）
  5. `_clone_repo "$REPO_URL" "$LLAMA_CPP_SRC"`，失败则清理后 die
  6. 成功后解除临时 trap（后续中断保护由 `_check_local_repo` 注册的 `_cleanup_on_interrupt` 接管）

空目录判定用 `nullglob`+`dotglob` 数组展开（无子进程，Bash 4.2 兼容）：目录下除 `.`/`..` 外无任何条目视为空。

### `_clone_repo <url> <dest>`

参数化纯函数，单一职责：

```bash
env GIT_HTTP_LOW_SPEED_LIMIT="${GIT_HTTP_LOW_SPEED_LIMIT}" \
    GIT_HTTP_LOW_SPEED_TIME="${GIT_HTTP_LOW_SPEED_TIME}" \
    git clone -- "$url" "$dest"
```

- **完整克隆**（不 `--depth`）：后续 update 需要完整 tags/历史，浅克隆会让 `_update_source` 的 fetch/checkout 受限
- **不加 `--quiet`**：clone 是数百 MB 的首次大下载，tty 下 git 自适应显示进度（stderr），非 tty 静默
- 低速保护与 `_git_net` 同源（同一对 config.sh 常量）：对端半挂起时中止而非无限持锁
- 调用点经 `llama_with_network_context "克隆 llama.cpp 源码"` 包装，失败时输出与 fetch 一致的网络诊断
- 参数化 URL/dest 使测试可用 `file://` 本地 bare 仓做**离线真实 clone**，无需 mock git

### `_cleanup_clone_artifacts <path>`

clone 失败/中断时把 `<path>` 恢复为"不存在"（`rm -rf`），仅负责清理、不退出。两条复用路径：

- **失败路径**：`_ensure_source_repo` 中 `_clone_repo` 返回非零 → 调本函数清理 → `llama_die`
- **中断路径**：clone 期间注册的临时 trap（分信号显式退出码 130/143，与 `_cleanup_on_interrupt` 同形态）→ 调本函数清理 → `llama_safe_exit`

**安全不变量**：删除只可能发生在 `_ensure_source_repo` 已判定目录缺失/为空之后——trap 注册窗口本身就是"目录内无用户数据"的标记。clone 成功后立即解除 trap，窗口外该 handler 不可达。零新增脚本级全局。

## 错误处理矩阵

| 场景 | 行为 |
|------|------|
| 非空非 git 目录 | 现有行为不变：`_ensure_source_repo` no-op → `_check_local_repo` die |
| 父目录不存在 | die，提示检查 `LLAMA_CPP_SRC` 路径拼写/挂载点 |
| git 不可用 | die（`llama_check_commands`） |
| clone 网络失败/低速中止 | `llama_with_network_context` 诊断 + 清理目录恢复"未安装"状态 + die |
| clone 期间 SIGINT/SIGTERM | 临时 trap（分信号显式退出码 130/143，与 `_cleanup_on_interrupt` 同形态）：`rm -rf` 半成品目录后退出。git 自身对 clone 中断也有清理，脚本层兜底保证"恢复未安装状态" |
| clone 后 checkout/构建失败 | 现有事务：回滚到 clone 的 HEAD（默认分支 tip）并重建，环境可用；回滚失败走现有 `_print_recovery_steps` |

锁：clone 在 `llama_acquire_lock` 之后执行，持锁期间并发 `build.sh`/`update.sh` 会等待而非看到半成品目录。clone 中断时 flock 随进程退出释放，无泄漏。

## C3 契约测试适配

`tests/test_smoke.bats` 的 C3 契约（"update.sh git invocations all use explicit -C \$LLAMA_CPP_SRC"）逐行钉住 `git -C` 不变量，而 `git clone` 无法带 `-C`（目标目录不存在，`-C` 无意义）。适配方式：clone 调用集中在 `_clone_repo` 一行，在契约测试中登记豁免（与 submodule foreach 内层裸调用靠同行外层 `-C` 放行的先例一致），并在契约测试注释中说明 clone 是结构性例外。

## 测试计划

bats 用例（`tests/test_update.bats` 新增，全部离线；真实 GitHub clone 不在测试范围，与项目既有边界一致）：

- **no-op**：非空目录（现有 fixture 的最小 git 仓）→ `_ensure_source_repo` 返回 0 且目录内容不变
- **目录不存在 + 真实 clone**：`file://` 指向 `TEST_TMPDIR` 下自建的 bare 仓（含 tag），断言返回 0、`.git/config` 存在、tag 已就位
- **空目录 + 真实 clone**：同上，验证空目录被 clone 填充
- **非空非 git 目录**：`_ensure_source_repo` 返回 0 且不执行 clone（no-op，拦截职责在 `_check_local_repo`）
- **父目录不存在**：返回非零且目标目录仍不存在
- **clone 失败清理**（两种起始态）：url 指向不存在的 `file://` 路径，分别从"目录不存在"与"空目录"出发，断言返回非零且目录恢复为不存在
- C3 契约测试更新后 `make check`（lint + syntax + test）全绿为完成标准

## 文档同步

- `README.md` 快速开始：首次使用简化为 clone 本 helper → `bash update.sh`；手动 `git clone ../llama.cpp` 降级为可选步骤（故障排除/自定义路径场景）
- `update.sh --help` 描述补一句"源码目录不存在/为空时自动从 GitHub 克隆"
- `CLAUDE.md`（`AGENTS.md`）架构/模块分层节登记 `_ensure_source_repo`/`_clone_repo`；反模式/安全特性节补 clone 清理不变量一句

## 明确不做（YAGNI）

- `build.sh` 不支持 auto-clone（保持纯构建工具语义）
- 不做浅克隆 / partial clone（`--depth`/`--filter`）
- 不做"clone 时直接 `--branch` 落在目标 tag"（避免 `_resolve_target` 单一 seam 分叉；本地 checkout 代价可忽略）
- 不自动创建不存在的父目录
- 不支持"非空非 git 目录"的任何自动处置（fail-closed 不变）
