NVIM ?= nvim
NVIM_SOURCE ?= ../neovim
EMMYLUA_CHECK ?= emmylua_check
STYLUA ?= stylua
TEST_FILE ?= $(CURDIR)/tests
TEST_ARGS ?=

.DEFAULT_GOAL := check
.PHONY: setup check-deps fmt format-check typecheck test check

# Link local sources for both EmmyLua and Neovim's private test harness.
setup:
	@test -f "$(NVIM_SOURCE)/test/harness.lua" || { echo 'NVIM_SOURCE must point to a recent Neovim source checkout' >&2; exit 1; }
	@mkdir -p .deps
	@test ! -e .deps/neovim || test -L .deps/neovim || { echo 'Refusing to replace .deps/neovim: not a symlink' >&2; exit 1; }
	ln -sfn "$$(cd "$(NVIM_SOURCE)" && pwd -P)" .deps/neovim

check-deps:
	@test -f .deps/neovim/test/harness.lua || { echo 'Run make setup NVIM_SOURCE=/path/to/neovim first' >&2; exit 1; }

fmt:
	"$(STYLUA)" .

format-check:
	"$(STYLUA)" --check .

typecheck: check-deps
	"$(EMMYLUA_CHECK)" . --severity warn --warnings-as-errors
	@sh tests/typecheck.sh "$(EMMYLUA_CHECK)"

test: check-deps
	@set -eu; \
	root="$(CURDIR)"; \
	work=$$(mktemp -d); \
	trap 'rm -rf "$$work"' EXIT; \
	ln -s "$$root/.deps/neovim/runtime" "$$root/.deps/neovim/test" "$$work/"; \
	cd "$$work"; \
	unset NVIM TMUX; \
	NVIM_PRG="$(NVIM)" NVIM_TEST=1 NVIM_LOG_FILE="$$work/nvim.log" SYNAPSE_ROOT="$$root" \
	"$(NVIM)" --headless -u NONE -i NONE -l "$$root/.deps/neovim/test/runner.lua" \
		-P"$$work" -X"$$work/xdg" --helper="$$root/tests/preload.lua" \
		$(TEST_ARGS) "$(abspath $(TEST_FILE))"

check: format-check typecheck test
