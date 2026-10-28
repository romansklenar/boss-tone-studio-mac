.DEFAULT_GOAL := help

PYTHON     ?= .venv/bin/python
SRC        ?= bts tests packaging
APP_NAME   ?= BOSS TONE STUDIO for KATANA MkII (Apple Silicon)
INSTALL_DIR ?= $(HOME)/Applications

.PHONY: help setup roland-assets lock run browser trace import-roland app install test lint format check

help:
	@echo "BOSS TONE STUDIO for KATANA MkII — Apple Silicon"
	@echo ""
	@echo "Usage: make <target>"
	@echo ""
	@echo "Targets:"
	@echo "  setup          Install pinned tools (mise.toml), locked packages (requirements.txt) and Roland's web app"
	@echo "  roland-assets  Take Roland's web app and icon out of its installer download (no install, no Rosetta)"
	@echo "  lock           Re-resolve requirements.txt from the pins in pyproject.toml"
	@echo "  run            Open the app window"
	@echo "  browser        Serve the app only; open the printed URL in a browser (no file dialogs)"
	@echo "  trace          Open the app window, logging every bridge command and MIDI message"
	@echo "  import-roland  Re-import the Librarian from Roland's own app"
	@echo "  app            Build a standalone dist/$(APP_NAME).app (PyInstaller; Roland's web app inside)"
	@echo "  install        Copy the built app to $(INSTALL_DIR)"
	@echo "  test           Run the unit tests"
	@echo "  lint           Check the code (ruff check + ruff format --check)"
	@echo "  format         Fix the code (ruff check --fix + ruff format)"
	@echo "  check          lint + test"

setup:
	@which mise > /dev/null 2>&1 || (echo "Error: mise not found (brew install mise)" >&2 && exit 1)
	@mise trust --quiet
	@mise install
	@mise exec -- uv venv --quiet --allow-existing --python "$$(mise which python)" .venv
	@mise exec -- uv pip sync --python $(PYTHON) requirements.txt
	@packaging/fetch-roland-assets.sh build/roland
	@echo "Python: $$($(PYTHON) --version), ruff: $$(mise exec -- ruff --version)"

lock:
	@mise exec -- uv pip compile --quiet --python-version 3.13 pyproject.toml -o requirements.txt
	@mise exec -- uv pip compile --quiet --python-version 3.13 --group app pyproject.toml -o requirements-app.txt

run:
	@./run

browser:
	@./run --browser

trace:
	@BTS_TRACE=1 ./run

import-roland:
	@./run --import-roland

roland-assets:
	@packaging/fetch-roland-assets.sh build/roland

app: roland-assets
	@mise exec -- uv pip sync --quiet --python $(PYTHON) requirements-app.txt
	@$(PYTHON) packaging/make_icon.py build/roland/AppIcon.icns build/AppIcon.icns
	@$(PYTHON) -m PyInstaller --noconfirm --log-level WARN --distpath dist --workpath build/pyinstaller packaging/app.spec
	@rm -rf "dist/$(APP_NAME)"  # the intermediate one-folder build; the .app holds its own copy
	@echo "Built dist/$(APP_NAME).app"

install:
	@test -d "dist/$(APP_NAME).app" || (echo "Error: run 'make app' first" >&2 && exit 1)
	@mkdir -p "$(INSTALL_DIR)" && rm -rf "$(INSTALL_DIR)/$(APP_NAME).app"
	@cp -R "dist/$(APP_NAME).app" "$(INSTALL_DIR)/"
	@echo "Installed $(INSTALL_DIR)/$(APP_NAME).app"

test:
	@$(PYTHON) -m unittest discover -s tests -t .

lint:
	@mise exec -- ruff check $(SRC)
	@mise exec -- ruff format --check $(SRC)

format:
	@mise exec -- ruff check --fix $(SRC)
	@mise exec -- ruff format $(SRC)

check: lint test
