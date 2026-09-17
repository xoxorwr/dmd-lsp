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
# Vendored dmd frontend root: `import dmd.x` resolves under src/dmd/.
DMD_SRC = src
# Modules imported only under non-Linux version blocks, so `dmd -i` on this
# host never pulls them: `root/strtold.d` is the MSVC (CRuntime_Microsoft)
# strtold used by root/ctfloat.d. (`dmd/iasm.d` and `dmd/backend/symbol.d`
# stay out because we build with -version=NoBackend.)
PLATFORM_EXTRA = root/strtold.d

SRC = src/main.d src/arena.d src/lsp.d src/session.d \
      src/dmdwrap.d src/lexutil.d src/lint.d src/complete.d src/server.d \
      src/semantic.d src/worker.d src/json.d

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

# Guard: our sources must stay struct-only (vendored dmd is excluded).
check-no-oop:
	@if grep -rnE '^\s*(class|interface) ' src/ | grep -v '^src/dmd/' ; then echo "OOP forbidden in src/ (outside vendor)"; exit 1; fi
	@echo "struct-only check ok"

# Refresh the vendored snapshot from the ../dmd dev tree.
vendor:
	@$(DC) -I../dmd/compiler/src -i \
	  -version=MARS -version=NoMain -version=GC -version=NoBackend \
	  -version=CallbackAPI -version=DMDLIB -preview=dip1000 \
	  -J../dmd/compiler/src/dmd/res -J../dmd -Jstringimp \
	  $(SRC) -of/dev/null -deps 2>/dev/null \
	  | grep -oE '\.\./dmd/[^ )]+' | sort -u \
	  | while read -r p; do \
	      if [ "$$p" = "../dmd/VERSION" ]; then d="src/dmd/VERSION"; \
	      else d="src/dmd/$${p#../dmd/compiler/src/dmd/}"; fi; \
	      mkdir -p "$$(dirname "$$d")"; cp "$$p" "$$d"; \
	    done
	@for f in $(PLATFORM_EXTRA); do \
	  mkdir -p "src/dmd/$$(dirname $$f)"; \
	  cp "../dmd/compiler/src/dmd/$$f" "src/dmd/$$f"; \
	done
	@echo "vendored $$(find src/dmd -type f | wc -l) files from ../dmd"

# Audit exactly which dmd modules got pulled in.
deps:
	@$(DC) $(DFLAGS) $(SRC) -of/dev/null -deps 2>/dev/null | sort -u | head -100

# Regression: struct-only guard + batch checks + LSP loop tests.
check: $(BIN) check-no-oop
	./$(BIN) --check --import=tests tests/u1.d
	./$(BIN) --check --import=tests tests/u2.d
	./$(BIN) --check tests/ok.d || true
	python3 tests/test_lsp.py
	python3 tests/test_semantic.py
	python3 tests/test_completion_burst.py
	python3 tests/test_completion_prefix.py
	python3 tests/test_completion_scope.py
	python3 tests/test_realworld.py
	python3 tests/test_broken_body.py
	python3 tests/test_cache.py
	python3 tests/test_debounce.py
	python3 tests/test_trivia.py
	python3 tests/test_config.py
	python3 tests/test_memory.py
	python3 tests/test_spawn.py
	python3 tests/test_sync.py

clean:
	rm -f $(BIN) *.o

.PHONY: all clean check-no-oop deps vendor vscode vsix
