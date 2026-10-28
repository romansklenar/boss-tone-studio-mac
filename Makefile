.DEFAULT_GOAL := help

PYTHON     ?= .venv/bin/python
# `tests`, not `Tests`, until Python's tests/ goes: only the former exists in the case-sensitive lint container.
SWIFT_SOURCES := $(wildcard Package.swift Sources tests packaging/make-icon.swift)
SWIFT_FLAGS := -Xswiftc -warnings-as-errors
# Command Line Tools' build system sometimes leaves the Swift Testing macro plugin out of the compiler call after a
# clean build (swiftlang/swift-build#1870, fixed upstream, not yet in the CLT release); drop this once a CLT has it.
ifeq ($(shell xcode-select -p 2>/dev/null),/Library/Developer/CommandLineTools)
SWIFT_FLAGS += -Xswiftc -plugin-path -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing
endif
# Must match APP_NAME in bts/__main__.py, which names the bundle.
APP_NAME   ?= BOSS TONE STUDIO for KATANA MkII (Apple Silicon)
INSTALL_DIR ?= $(HOME)/Applications

.PHONY: help setup swift-version deps roland-assets lock run browser trace roland-import build app install \
	release-notes test lint format check

help:
	@echo "BOSS TONE STUDIO for KATANA MkII — Apple Silicon"
	@echo ""
	@echo "Usage: make <target>"
	@echo ""
	@echo "Targets:"
	@echo "  setup          swift-version + deps + roland-assets"
	@echo "  swift-version  Print the Swift version; fail unless it is major version 6"
	@echo "  deps           Install pinned tools (mise.toml) and locked packages (requirements.txt) into .venv"
	@echo "  roland-assets  Take Roland's web app and icon out of its installer download (no install, no Rosetta)"
	@echo "  lock           Re-resolve requirements*.txt from the pins in pyproject.toml"
	@echo "  run            Open the app window"
	@echo "  browser        Serve the app only; open the printed URL in a browser (no file dialogs)"
	@echo "  trace          Open the app window, logging every bridge command and MIDI message"
	@echo "  roland-import  Re-import the Librarian from Roland's own app"
	@echo "  build          Build the Swift package (compiler warnings are errors)"
	@echo "  app            Build a standalone dist/$(APP_NAME).app (PyInstaller; Roland's web app inside)"
	@echo "  install        Copy the built app to $(INSTALL_DIR)"
	@echo "  release-notes  Write the GitHub Release body for VERSION=x.y.z (tagged) to tmp/"
	@echo "  test           Run the unit tests (swift test; compiler warnings are errors)"
	@echo "  lint           Check the code (swift format lint --strict)"
	@echo "  format         Fix the code (swift format --in-place)"
	@echo "  check          lint + test"

setup: swift-version deps roland-assets

swift-version:
	@version="$$(swift --version 2>&1 | sed -n 's/.*Swift version \([0-9][0-9.]*\).*/\1/p' | head -n 1)"; \
	case "$$version" in \
		6|6.*) echo "Swift $$version" ;; \
		*) echo "Error: this project needs Swift 6 (found $${version:-none});" \
			"install or update Apple's Command Line Tools" >&2; exit 1 ;; \
	esac

deps:
	@which mise > /dev/null 2>&1 || (echo "Error: mise not found (brew install mise)" >&2 && exit 1)
	@mise install
	@mise exec -- uv venv --quiet --allow-existing --python "$$(mise which python)" .venv
	@mise exec -- uv pip sync --require-hashes --python $(PYTHON) requirements.txt
	@echo "Python: $$($(PYTHON) --version), ruff: $$(mise exec -- ruff --version)"

lock:
	@mise exec -- uv pip compile --quiet --generate-hashes --python-version 3.13 pyproject.toml -o requirements.txt
	@mise exec -- uv pip compile --quiet --generate-hashes --python-version 3.13 --group app pyproject.toml \
		-o requirements-app.txt

run:
	@swift run -c debug $(SWIFT_FLAGS) BossToneStudio

browser:
	@swift run -c debug $(SWIFT_FLAGS) BossToneStudio --browser

trace:
	@BTS_TRACE=1 swift run -c debug $(SWIFT_FLAGS) BossToneStudio

roland-import:
	@swift run -c debug $(SWIFT_FLAGS) BossToneStudio --import-roland

roland-assets:
	@packaging/fetch-roland-assets.sh build/roland

build: swift-version
	@swift build $(SWIFT_FLAGS)

app: swift-version roland-assets build/AppIcon.icns
	@mise exec -- uv pip sync --quiet --require-hashes --python $(PYTHON) requirements-app.txt
	@$(PYTHON) -m PyInstaller --noconfirm --log-level WARN --distpath dist --workpath build/pyinstaller packaging/app.spec
	@rm -rf "dist/$(APP_NAME)"  # the intermediate one-folder build; the .app holds its own copy
	@echo "Built dist/$(APP_NAME).app"

build/AppIcon.icns: build/roland/AppIcon.icns packaging/make_icon.py
	@mise exec -- uv pip sync --quiet --require-hashes --python $(PYTHON) requirements-app.txt
	@$(PYTHON) packaging/make_icon.py $< $@

install:
	@test -d "dist/$(APP_NAME).app" || (echo "Error: run 'make app' first" >&2 && exit 1)
	@mkdir -p "$(INSTALL_DIR)" && rm -rf "$(INSTALL_DIR)/$(APP_NAME).app"
	@cp -R "dist/$(APP_NAME).app" "$(INSTALL_DIR)/"
	@echo "Installed $(INSTALL_DIR)/$(APP_NAME).app"

release-notes:
	@test -n "$(VERSION)" || (echo "Error: usage: make release-notes VERSION=x.y.z" >&2 && exit 1)
	@packaging/release-notes.sh "$(VERSION)" "tmp/release-notes-v$(VERSION).md"

test: swift-version
	@swift test $(SWIFT_FLAGS)

lint: swift-version
	@swift format lint --strict --recursive --parallel $(SWIFT_SOURCES)

format:
	@swift format format --in-place --recursive --parallel $(SWIFT_SOURCES)

check: lint test
