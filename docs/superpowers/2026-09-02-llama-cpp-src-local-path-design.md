# 本机 llama.cpp 源码路径覆盖设计

- 日期:2026-09-02
- 状态:已实施并验证(2026-09-02,验证输出见会话记录)

## 背景与问题

`llama.cpp_helper`(/mnt/usr/project/system/llama.cpp_helper)的 `config.sh:26` 默认将
llama.cpp 源码定位在与项目相邻的 `../llama.cpp`(即 /mnt/usr/project/system/llama.cpp),
并支持 `LLAMA_CPP_SRC` 环境变量覆盖。用户希望本机使用时源码位于
`/mnt/usr/tools/llama.cpp`(遵循 /mnt/usr/tools 的"每工具一子目录"惯例:
anaconda、go、rust 等)。

该仓库可能多机使用/发布,故不改其项目默认值,采用本机环境变量覆盖(用户在
方案对比中明确选择 `~/.bashrc` 导出,而非 config.local.sh 机制或每次手动前缀,
并知情接受其权衡)。

## 用户已确认的关键决策

1. **仓库零改动**:llama.cpp_helper 保持通用默认 `../llama.cpp`;
   README 已文档化 `LLAMA_CPP_SRC` 覆盖用法,无需新增机制。
2. **覆盖机制 = `~/.bashrc` 导出**(用户明示同意写入该全局配置文件)。
3. **完整克隆**而非 shallow:`update.sh` 的版本切换与失败回滚需要 git 历史。
4. **不执行构建**:clone 后不跑 `build.sh`(完整 CUDA 构建耗时长,用户另行决定)。

## 实施内容

### 变更 1 — `~/.bashrc` 末尾追加(纯追加,不触碰现有行)

```bash
# llama.cpp_helper:本机 llama.cpp 源码路径(覆盖 config.sh 默认的相邻目录 ../llama.cpp)
export LLAMA_CPP_SRC=/mnt/usr/tools/llama.cpp
```

写前已核查:现有 `~/.bashrc` 无任何 LLAMA 相关定义,无重复/冲突风险。

### 变更 2 — 克隆源码

```bash
git clone https://github.com/ggml-org/llama.cpp /mnt/usr/tools/llama.cpp
```

写前已核查:`/mnt/usr/tools/llama.cpp` 不存在;磁盘(tank,11T 可用)空间充足
(项目自身构建门槛为 ≥10GB)。

## 验证

1. `bash -ic 'echo "$LLAMA_CPP_SRC"'` → 新交互 shell 输出 `/mnt/usr/tools/llama.cpp`
2. `git -C /mnt/usr/tools/llama.cpp remote get-url origin` → `https://github.com/ggml-org/llama.cpp`
   (与 config.sh 的 `REPO_URL` 一致,满足 update.sh 的 remote 校验)
3. 在已导出的环境下 source config.sh,确认 `LLAMA_CPP_SRC` 不被默认值覆盖

## 已知权衡(用户知情选择)

- 仅该用户的交互式 shell 生效:cron、非登录上下文、其他用户调用
  build.sh/update.sh 时需自带 `LLAMA_CPP_SRC=...` 前缀,否则回落默认路径
  (该路径不存在时脚本显式报错,不会误操作)。
- 追加时已开的其他 shell 不受影响,需各自 `source ~/.bashrc` 后生效。

## 不在范围内

- llama.cpp_helper 仓库的任何改动(config.local.sh 机制等,已评估未采纳)
- llama.cpp 的构建、模型下载、run_env.sh 运行时环境加载
