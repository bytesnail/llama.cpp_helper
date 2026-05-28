.DEFAULT_GOAL := help

# Check for user-local tool paths; fall back to bare names if not found
SHELLCHECK  := $(shell command -v shellcheck 2>/dev/null || echo shellcheck)  # fallback unused when _check_shellcheck guards lint target
BATS        := $(shell command -v bats 2>/dev/null || echo bats)

SHELL_SCRIPTS := common.sh config.sh build.sh update.sh run_env.sh tests/test_helper.bash
TEST_COUNT   := $(shell grep -c '@test' tests/*.bats 2>/dev/null | awk -F: '{s+=$$NF} END{print s+0}')

# Verify tool availability before running targets that require them
_check_shellcheck: SHELLCHECK_OK := $(shell command -v shellcheck 2>/dev/null)
_check_shellcheck:
	@[ -n "$(SHELLCHECK_OK)" ] || { echo "Error: shellcheck not found. Install: apt install shellcheck"; exit 1; }

_check_bats: BATS_OK := $(shell command -v bats 2>/dev/null)
_check_bats:
	@[ -n "$(BATS_OK)" ] || { echo "Error: bats not found. Install: bats (https://github.com/bats-core/bats-core)"; exit 1; }


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
