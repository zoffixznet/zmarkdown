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

# Where `make install` puts things. A user install by default (no root); override
# with e.g. `make install PREFIX=/usr/local`.
PREFIX ?= $(HOME)/.local

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

# icon-128.png is committed and embedded into the binary; the rest are generated
# for packaging. Build only needs the embedded one, which is already present, so
# build does not force a regeneration (that would churn the committed file).
src/ui/assets/icon-128.png:
	bash scripts/gen-icons.sh

## build: build the release binary into build/
.PHONY: build
build: src/ui/assets/icon-128.png
	@mkdir -p build
	$(NIM) $(NIMFLAGS_RELEASE) --app:gui -o:$(BIN) $(SRC)
	@echo "Built $(BIN)"

## debug: build a debug binary with verbose logging and stack traces
.PHONY: debug
debug: src/ui/assets/icon-128.png
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
	$(NIM) c -r --hints:off tests/test_history.nim

## smoke: build then run the headless end-to-end self-test under a virtual display
.PHONY: smoke
smoke: build
	bash scripts/smoke.sh

## dist: build and package the Linux tarball (binary, README, .desktop, icons)
.PHONY: dist
dist: icons build
	bash scripts/package-linux.sh

## install: install the binary, desktop entry, and icons into PREFIX (Linux; default ~/.local)
.PHONY: install
install: build
	install -Dm755 $(BIN) "$(PREFIX)/bin/zmarkdown"
	install -Dm644 packaging/zmarkdown.desktop "$(PREFIX)/share/applications/zmarkdown.desktop"
	@bash scripts/gen-icons.sh >/dev/null 2>&1 || echo "note: icon generation skipped, using the committed icon"
	install -Dm644 src/ui/assets/icon.svg "$(PREFIX)/share/icons/hicolor/scalable/apps/zmarkdown.svg"
	@for s in 16 32 48 64 128 256; do \
	  if [ -f "src/ui/assets/icon-$$s.png" ]; then \
	    install -Dm644 "src/ui/assets/icon-$$s.png" "$(PREFIX)/share/icons/hicolor/$${s}x$${s}/apps/zmarkdown.png"; \
	  fi; \
	done
	@echo "Installed ZMarkdown to $(PREFIX). Make sure $(PREFIX)/bin is on your PATH."

## uninstall: remove what 'install' put into PREFIX
.PHONY: uninstall
uninstall:
	rm -f "$(PREFIX)/bin/zmarkdown" "$(PREFIX)/share/applications/zmarkdown.desktop"
	rm -f "$(PREFIX)/share/icons/hicolor/scalable/apps/zmarkdown.svg"
	@for s in 16 32 48 64 128 256; do rm -f "$(PREFIX)/share/icons/hicolor/$${s}x$${s}/apps/zmarkdown.png"; done
	@echo "Removed ZMarkdown from $(PREFIX)."

## clean: remove build outputs, caches, and generated icons
.PHONY: clean
clean:
	rm -rf build dist nimcache
	# Remove generated icons except the committed, embedded icon-128.png.
	rm -f src/ui/assets/icon-16.png src/ui/assets/icon-32.png \
	      src/ui/assets/icon-48.png src/ui/assets/icon-64.png \
	      src/ui/assets/icon-256.png src/ui/assets/icon.ico
	rm -f tests/test_editing tests/test_state tests/test_files tests/test_markdown tests/test_history
	@echo "Cleaned"
