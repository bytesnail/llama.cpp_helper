.DEFAULT_GOAL := help

# 检测用户本地工具路径；未找到时回退到裸命令名（由 _check_* 目标给出安装提示）
SHELLCHECK  := $(shell command -v shellcheck 2>/dev/null || echo shellcheck)
BATS        := $(shell command -v bats 2>/dev/null || echo bats)

SHELL_SCRIPTS := common.sh config.sh build.sh update.sh run_env.sh tests/test_helper.bash
TEST_COUNT   := $(shell grep -c '@test' tests/*.bats 2>/dev/null | awk -F: '{s+=$$NF} END{print s+0}')

# 运行依赖工具的目标前先验证工具可用性
_check_shellcheck: SHELLCHECK_OK := $(shell command -v shellcheck 2>/dev/null)
_check_shellcheck:
	@[ -n "$(SHELLCHECK_OK)" ] || { echo "错误: 未找到 shellcheck，请安装: apt install shellcheck"; exit 1; }

_check_bats: BATS_OK := $(shell command -v bats 2>/dev/null)
_check_bats:
	@[ -n "$(BATS_OK)" ] || { echo "错误: 未找到 bats，请安装: bats (https://github.com/bats-core/bats-core)"; exit 1; }


.PHONY: lint syntax test check all help _check_shellcheck _check_bats

lint: _check_shellcheck
	$(SHELLCHECK) $(SHELL_SCRIPTS)

syntax:
	@for f in $(SHELL_SCRIPTS); do bash -n "$$f" && echo "OK: $$f" || { echo "FAIL: $$f"; exit 1; }; done

test: _check_bats
	$(BATS) tests/

check: lint syntax test

all: check

help:
	@echo "可用目标:"
	@echo "  lint     - ShellCheck 静态分析（6 个脚本）"
	@echo "  syntax   - bash -n 语法检查"
	@echo "  test     - bats-core 测试套件（$(TEST_COUNT) 项）"
	@echo "  check    - lint + syntax + test 全部"
	@echo "  all      - 等同于 check"
