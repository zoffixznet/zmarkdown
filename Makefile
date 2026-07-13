# ZMarkdown build front door.
#
# Run `make` (or `make help`) to list every target. Most people only need:
#   make deps   (once)   then   make run
#
# The Nim toolchain installs per-user via choosenim, so make sure ~/.nimble/bin
# is on PATH (deps adds it to ~/.profile). We also prepend it here so a fresh
# shell that has not sourced the profile still finds nim.

SHELL := /bin/bash
export PATH := $(HOME)/.nimble/bin:$(PATH)

BIN := build/zmarkdown
SRC := src/zmarkdown.nim
NIM := nim

# Release builds are size-optimized and drop stack traces. Debug builds keep
# them and raise log verbosity.
NIMFLAGS_RELEASE := cpp -d:release --hints:off
NIMFLAGS_DEBUG   := cpp -d:debug --hints:off

.DEFAULT_GOAL := help

## help: show this help (default target)
.PHONY: help
help:
	@echo "ZMarkdown - make targets"
	@echo
	@grep -E '^## ' $(MAKEFILE_LIST) | sed 's/^## /  /' | awk -F': ' '{printf "  \033[1m%-12s\033[0m %s\n", $$1, $$2}' 2>/dev/null || \
	 grep -E '^## ' $(MAKEFILE_LIST) | sed 's/^## /  /'
	@echo
	@echo "Typical first run:  make deps  &&  make run"

## deps: install build and run dependencies (uses sudo for system packages on Linux)
.PHONY: deps
deps:
	@if [ "$$(uname -s)" = "Linux" ]; then \
	  bash scripts/deps-linux.sh; \
	elif [ "$$OS" = "Windows_NT" ]; then \
	  powershell -ExecutionPolicy Bypass -File scripts/deps-windows.ps1; \
	else \
	  echo "Unsupported platform. On Windows run: powershell -ExecutionPolicy Bypass -File scripts/deps-windows.ps1"; \
	fi

## icons: regenerate the PNG icons and the .ico from the SVG source
.PHONY: icons
icons:
	bash scripts/gen-icons.sh

## build: build the release binary into build/
.PHONY: build
build: icons
	@mkdir -p build
	$(NIM) $(NIMFLAGS_RELEASE) --app:gui -o:$(BIN) $(SRC)
	@echo "Built $(BIN)"

## debug: build a debug binary with verbose logging and stack traces
.PHONY: debug
debug: icons
	@mkdir -p build
	$(NIM) $(NIMFLAGS_DEBUG) -o:$(BIN) $(SRC)
	@echo "Built $(BIN) (debug)"

## run: build if needed and launch the app
.PHONY: run
run: $(BIN)
	./$(BIN)

$(BIN): $(SRC) $(wildcard src/**/*) $(wildcard src/ui/**/*)
	@$(MAKE) build

## test: run the unit tests and the headless end-to-end smoke test
.PHONY: test
test: unit smoke

## unit: run the Nim unit test suite
.PHONY: unit
unit:
	$(NIM) c -r --hints:off tests/test_editing.nim
	$(NIM) c -r --hints:off tests/test_state.nim
	$(NIM) c -r --hints:off tests/test_files.nim
	$(NIM) c -r --hints:off tests/test_markdown.nim

## smoke: build then run the headless end-to-end self-test under a virtual display
.PHONY: smoke
smoke: build
	bash scripts/smoke.sh

## dist: build and package the Linux tarball (binary, README, .desktop, icons)
.PHONY: dist
dist: build
	bash scripts/package-linux.sh

## clean: remove build outputs, caches, and generated icons
.PHONY: clean
clean:
	rm -rf build dist nimcache
	rm -f src/ui/assets/icon-*.png src/ui/assets/icon.ico
	rm -f tests/test_editing tests/test_state tests/test_files tests/test_markdown
	@echo "Cleaned"
