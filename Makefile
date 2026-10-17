NVIM ?= nvim

.PHONY: test
test:
	$(NVIM) --headless -u NONE -i NONE -l tests/smoke.lua
