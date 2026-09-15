# dmd-lsp Makefile — minimal, exact, no copies.
# RULE: never copy ../dmd files; reference via -I only.
# RULE: never edit ../dmd without explicit permission.
# Build uses `dmd -i` so the compiler pulls *exactly* the transitively
# imported dmd modules — nothing else. `make deps` audits the list.

# Toolchain: pinned to 2.113.0 (never system dmd).
DC ?= dmd
DMD_SRC = ../dmd/compiler/src

SRC = src/main.d src/arena.d src/lsp.d src/session.d \
      src/dmdwrap.d src/lexutil.d src/lint.d src/complete.d src/server.d \
      src/worker.d src/json.d

# Same versions as dmd's own `frontend` dub package, plus DMDLIB for the
# tooling-oriented lexer API. -preview=dip1000 matches the dmd build.
DFLAGS = -I$(DMD_SRC) -i \
  -version=MARS -version=NoMain -version=GC -version=NoBackend \
  -version=CallbackAPI -version=DMDLIB \
  -preview=dip1000 -O \
  -J$(DMD_SRC)/dmd/res -J../dmd -Jstringimp

BIN = dmd-lsp

all: $(BIN)

$(BIN): $(SRC) Makefile stringimp/SYSCONFDIR.imp
	$(DC) $(DFLAGS) $(SRC) -of$(BIN)

# Guard: our sources must stay struct-only (no class/interface inheritance).
check-no-oop:
	@if grep -rnE '^\s*(class|interface) ' src/ ; then echo "OOP forbidden in src/"; exit 1; fi
	@echo "struct-only check ok"

# Audit exactly which dmd modules got pulled in.
deps:
	@$(DC) $(DFLAGS) $(SRC) -of/dev/null -deps 2>/dev/null | sort -u | head -100

# Regression: struct-only guard + batch checks + LSP loop tests.
check: $(BIN) check-no-oop
	./$(BIN) --check --import=tests tests/u1.d
	./$(BIN) --check --import=tests tests/u2.d
	./$(BIN) --check tests/ok.d || true
	python3 tests/test_lsp.py
	python3 tests/test_cache.py
	python3 tests/test_debounce.py
	python3 tests/test_config.py
	python3 tests/test_memory.py
	python3 tests/test_spawn.py
	python3 tests/test_sync.py

clean:
	rm -f $(BIN) *.o

.PHONY: all clean check-no-oop deps
