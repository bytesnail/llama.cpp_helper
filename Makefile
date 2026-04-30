# Use user-local shellcheck path if available
SHELLCHECK  := $(shell command -v shellcheck 2>/dev/null || echo shellcheck)
BATS        := $(shell command -v bats 2>/dev/null || echo bats)

SHELL_SCRIPTS := common.sh config.sh build.sh update.sh run_env.sh

.PHONY: lint check test syntax all clean help

help:
	@echo "Targets: lint, syntax, test, check, all"

lint:
	$(SHELLCHECK) $(SHELL_SCRIPTS)

syntax:
	@for f in $(SHELL_SCRIPTS); do bash -n "$$f" && echo "OK: $$f" || echo "FAIL: $$f"; done

test:
	$(BATS) tests/

check: lint syntax test

all: check
