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
# Must match AppPaths.appName and packaging/Info.plist.
APP_NAME   ?= BOSS TONE STUDIO for KATANA MkII (Apple Silicon)
APP        = dist/$(APP_NAME).app
APP_VERSION = $(shell cat VERSION)
INSTALL_DIR ?= $(HOME)/Applications

.PHONY: help setup swift-version deps roland-assets roland-fresh lock run browser trace roland-import build app \
	install release-notes test lint format check

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
	@echo "  roland-fresh   Extract them again from the verified download (what app does first)"
	@echo "  lock           Re-resolve requirements*.txt from the pins in pyproject.toml"
	@echo "  run            Open the app window"
	@echo "  browser        Serve the app only; open the printed URL in a browser (no file dialogs)"
	@echo "  trace          Open the app window, logging every bridge command and MIDI message"
	@echo "  roland-import  Re-import the Librarian from Roland's own app"
	@echo "  build          Build the Swift package (compiler warnings are errors)"
	@echo "  app            Build dist/$(APP_NAME).app (ad-hoc signed, hardened runtime; Roland's web app inside)"
	@echo "  install        Check the built app's signature, then copy it to $(INSTALL_DIR)"
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

# Roland's web app goes into the bundle from the SHA-256-checked installer zip every time, never as it stands in
# build/roland/html (the fetch script skips a folder that already has an index.html).
roland-fresh:
	@rm -rf build/roland/html
	@packaging/fetch-roland-assets.sh build/roland

# The icon is built by a sub-make: it must see the timestamp of the icon `roland-fresh` has just replaced.
# cp -X: extended attributes (Finder info, resource forks) would break the bundle's seal.
app: swift-version roland-fresh
	@$(MAKE) --no-print-directory build/AppIcon.icns
	@swift build -c release --arch arm64 $(SWIFT_FLAGS)
	@rm -rf "$(APP)"
	@mkdir -p "$(APP)/Contents/MacOS" "$(APP)/Contents/Resources"
	@cp "$$(swift build -c release --arch arm64 --show-bin-path)/BossToneStudio" "$(APP)/Contents/MacOS/"
	@sed 's/@VERSION@/$(APP_VERSION)/g' packaging/Info.plist > "$(APP)/Contents/Info.plist"
	@cp -X build/AppIcon.icns "$(APP)/Contents/Resources/AppIcon.icns"
	@cp -RX build/roland/html "$(APP)/Contents/Resources/roland-html"
	@codesign --force --sign - --options runtime --timestamp=none "$(APP)"
	@echo "Built $(APP)"

build/roland/AppIcon.icns:
	@packaging/fetch-roland-assets.sh build/roland

build/AppIcon.icns: build/roland/AppIcon.icns packaging/make-icon.swift
	@swift packaging/make-icon.swift $< $@

install:
	@test -d "$(APP)" || (echo "Error: run 'make app' first" >&2 && exit 1)
	@codesign --verify --strict "$(APP)" || (echo "Error: $(APP) has no valid signature; run 'make app'" >&2 && exit 1)
	@codesign --display --verbose "$(APP)" 2>&1 | grep -Eq 'flags=0x[0-9a-f]+\([a-z,]*runtime' \
		|| (echo "Error: $(APP) lacks the hardened runtime; run 'make app'" >&2 && exit 1)
	@mkdir -p "$(INSTALL_DIR)" && rm -rf "$(INSTALL_DIR)/$(APP_NAME).app"
	@cp -R "$(APP)" "$(INSTALL_DIR)/"
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
