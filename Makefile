# dmd-lsp Makefile — minimal, exact.
# The dmd frontend is VENDORED under src/dmd/ (a snapshot of the exact
# transitive closure, plus the two string imports VERSION and
# res/default_ddoc_theme.ddoc), so the build is self-contained and carries
# our fixes until they land upstream. See "Vendored dmd" in README.md.
# RULE: never edit ../dmd without explicit permission; refresh the snapshot
# with `make vendor` instead.
# Build uses `dmd -i` so the compiler pulls *exactly* the transitively
# imported dmd modules — nothing else. `make deps` audits the list.

# Toolchain: pinned to 2.113.0 (never system dmd).
DC ?= dmd
# dmd-lsp derives default stdlib import paths from the dmd executable. Prefer
# the sibling dev build (its druntime matches the vendored frontend), else the
# compiler the build uses.
DEV_DMD = ../dmd/generated/linux/release/64/dmd
DMD ?= $(shell test -x $(DEV_DMD) && echo $(DEV_DMD) || echo $(DC))
export DMD
# Vendored dmd frontend root: `import dmd.x` resolves under src/dmd/.
DMD_SRC = src
# Modules imported only under non-Linux version blocks, so `dmd -i` on this
# host never pulls them: `root/strtold.d` is the MSVC (CRuntime_Microsoft)
# strtold used by root/ctfloat.d. (`dmd/iasm.d` and `dmd/backend/symbol.d`
# stay out because we build with -version=NoBackend.)
PLATFORM_EXTRA = root/strtold.d

SRC = src/main.d src/arena.d src/lsp.d src/session.d \
      src/dmdwrap.d src/lexutil.d src/lint.d src/complete.d src/server.d \
      src/semantic.d src/worker.d src/json.d src/pathutil.d src/symbols.d \
      src/references.d src/fsutil.d src/timing.d

# Same versions as dmd's own `frontend` dub package, plus DMDLIB for the
# tooling-oriented lexer API. -preview=dip1000 matches the dmd build.
DFLAGS = -I$(DMD_SRC) -i \
  -version=MARS -version=NoMain -version=GC -version=NoBackend \
  -version=CallbackAPI -version=DMDLIB \
  -preview=dip1000 -O \
  -Jsrc/dmd/res -Jsrc/dmd -Jstringimp

BIN = dmd-lsp

# VS Code extension (TypeScript + esbuild); built with npm, not dmd.
VSCODE_DIR = editor/vscode

all: $(BIN)

$(BIN): $(SRC) Makefile stringimp/SYSCONFDIR.imp
	$(DC) $(DFLAGS) $(SRC) -of$(BIN)

# Compile the extension (tsc --noEmit + esbuild bundle -> dist/extension.js).
vscode: $(VSCODE_DIR)/node_modules
	cd $(VSCODE_DIR) && npm run compile

# Package the extension -> editor/vscode/dmd-lsp.vsix (compiles first).
vsix: vscode
	cd $(VSCODE_DIR) && npm run package

$(VSCODE_DIR)/node_modules: $(VSCODE_DIR)/package.json $(VSCODE_DIR)/package-lock.json
	cd $(VSCODE_DIR) && npm ci

# Guard: our sources stay struct-only (vendored dmd is excluded). The only
# exceptions are DMD interop adapters: classes deriving from a dmd `Visitor`
# (the supported way to traverse the frontend's resolved AST) and `RegionGC`
# (custom GC).
check-no-oop:
	@if grep -rnE '^[[:space:]]*(extern[[:space:]]*\(C\+\+\)[[:space:]]*)?(final[[:space:]]+)?(class|interface)[[:space:]]' src/ | grep -v '^src/dmd/' | grep -v 'Visitor' | grep -v 'RegionGC' ; then echo "OOP forbidden in src/ (outside vendor)"; exit 1; fi
	@echo "struct-only check ok (interop adapters excepted)"

# Source of the vendored frontend. Defaults to the sibling dev checkout; a
# different tree or ref can be selected:
#   make vendor                  # current working tree of $(DMD_DIR)
#   make vendor DMD_DIR=~/dmd    # vendor from another checkout (absolute path)
#   make vendor BRANCH=fork      # vendor a branch/ref of $(DMD_DIR)
# A branch is materialised in a temporary git worktree (detached), so the
# current checkout of $(DMD_DIR) is left untouched and removed afterwards.
DMD_DIR ?= ../dmd
BRANCH ?=

# Refresh the vendored snapshot from the dmd dev tree.
vendor:
	@set -e; \
	src="$(DMD_DIR)"; wt=""; deps="$$(mktemp)"; \
	if [ -n "$(BRANCH)" ]; then \
	  wt="$$(mktemp -d)"; \
	  git -C "$(DMD_DIR)" worktree add --detach "$$wt" "$(BRANCH)" >/dev/null; \
	  src="$$wt"; \
	fi; \
	trap 'rm -f "$$deps"; test -n "$$wt" && git -C "$(DMD_DIR)" worktree remove --force "$$wt" >/dev/null 2>&1; true' EXIT; \
	$(DC) -I"$$src/compiler/src" -i \
	  -version=MARS -version=NoMain -version=GC -version=NoBackend \
	  -version=CallbackAPI -version=DMDLIB -preview=dip1000 \
	  -J"$$src/compiler/src/dmd/res" -J"$$src" -Jstringimp \
	  $(SRC) -o- -deps >"$$deps" 2>/dev/null || true; \
	if ! grep -q "$$src/" "$$deps"; then \
	  echo "vendor: no dmd modules resolved from $$src (incompatible branch/ref?)" >&2; \
	  exit 1; \
	fi; \
	grep -oE "$$src/[^ )]+" "$$deps" | sort -u \
	  | while read -r p; do \
	      rel="$${p#"$$src/"}"; \
	      if [ "$$rel" = "VERSION" ]; then d="src/dmd/VERSION"; \
	      else d="src/dmd/$${rel#compiler/src/dmd/}"; fi; \
	      mkdir -p "$$(dirname "$$d")"; cp "$$p" "$$d"; \
	    done; \
	for f in $(PLATFORM_EXTRA); do \
	  mkdir -p "src/dmd/$$(dirname $$f)"; \
	  cp "$$src/compiler/src/dmd/$$f" "src/dmd/$$f"; \
	done; \
	echo "vendored $$(find src/dmd -type f | wc -l) files from $$src"

# Audit exactly which dmd modules got pulled in.
deps:
	@$(DC) $(DFLAGS) $(SRC) -of/dev/null -deps 2>/dev/null | sort -u | head -100

# Regression: struct-only guard + batch checks + LSP loop tests.
check: $(BIN) check-no-oop unittest
	./$(BIN) --check --import=tests tests/u1.d
	./$(BIN) --check --import=tests tests/u2.d
	./$(BIN) --check tests/ok.d || true
	python3 tests/test_lsp.py
	python3 tests/test_semantic.py
	python3 tests/test_semantic_hints.py
	python3 tests/test_lint.py
	python3 tests/test_completion_burst.py
	python3 tests/test_completion_prefix.py
	python3 tests/test_completion_scope.py
	python3 tests/test_field_scope.py
	python3 tests/test_symbols.py
	python3 tests/test_references.py
	python3 tests/test_rename.py
	python3 tests/test_inlay_hints.py
	python3 tests/test_workspace_symbols.py
	python3 tests/test_recovery_scope.py
	python3 tests/test_realworld.py
	python3 tests/test_broken_body.py
	python3 tests/test_cache.py
	python3 tests/test_debounce.py
	python3 tests/test_trivia.py
	python3 tests/test_config.py
	python3 tests/test_memory.py
	python3 tests/test_spawn.py
	python3 tests/test_sync.py

# D unittests for the pure path helpers (no dmd, so the vendored frontend's
# unittests don't run). `-main` generates a runner that executes them.
unittest: src/pathutil.d src/json.d src/arena.d
	$(DC) -unittest -main src/pathutil.d src/json.d src/arena.d -of$(BIN)-ut
	./$(BIN)-ut

clean:
	rm -f $(BIN) $(BIN)-ut *.o

.PHONY: all clean check check-no-oop unittest deps vendor vscode vsix
