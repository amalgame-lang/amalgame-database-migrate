#!/bin/bash
# ─────────────────────────────────────────────────────
#  amalgame-database-migrate — Test Runner
#  Usage: ./tests/run_tests.sh [/path/to/amc]
#
#  Builds the migrate facade against a sibling amalgame-database-sqlite
#  checkout (wired through the fake-cache + amalgame.lock pattern),
#  compiles + links the test sample against the vendored sqlite3.c,
#  runs it, and asserts the expected [PASS] lines.
# ─────────────────────────────────────────────────────
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PKG_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# ── Locate amc ─────────────────────────────────────────
if [ $# -ge 1 ]; then AMC="$1"
elif [ -n "${AMC:-}" ]; then :
elif command -v amc >/dev/null 2>&1; then AMC="$(command -v amc)"
else echo "ERROR: amc not found (arg / AMC env / PATH)." >&2; exit 2; fi
[ -x "$AMC" ] || { echo "ERROR: amc '$AMC' not executable" >&2; exit 2; }

AMC_DIR="$(cd "$(dirname "$AMC")" && pwd)"
if [ -n "${AMC_RUNTIME:-}" ] && [ -d "$AMC_RUNTIME" ]; then :
elif [ -d "$AMC_DIR/runtime" ]; then AMC_RUNTIME="$AMC_DIR/runtime"
elif [ -d "$PKG_DIR/../Amalgame/runtime" ]; then AMC_RUNTIME="$PKG_DIR/../Amalgame/runtime"
else echo "ERROR: amc runtime/ not found; set AMC_RUNTIME" >&2; exit 2; fi

# ── Locate sibling amalgame-database-sqlite ────────────
if [ -n "${AMALGAME_DB_SQLITE:-}" ] && [ -d "$AMALGAME_DB_SQLITE" ]; then
    SQLITE_DIR="$AMALGAME_DB_SQLITE"
elif [ -d "$PKG_DIR/../amalgame-database-sqlite" ]; then
    SQLITE_DIR="$PKG_DIR/../amalgame-database-sqlite"
elif [ -d "$HOME/.amalgame/packages/github.com/amalgame-lang/amalgame-database-sqlite" ]; then
    SQLITE_DIR="$(ls -d "$HOME/.amalgame/packages/github.com/amalgame-lang/amalgame-database-sqlite"/*/ 2>/dev/null | tail -1)"
    SQLITE_DIR="${SQLITE_DIR%/}"
fi
SQLITE_C="$SQLITE_DIR/runtime/Amalgame_Database/sqlite/sqlite3.c"
if [ -z "${SQLITE_DIR:-}" ] || [ ! -f "$SQLITE_C" ]; then
    echo "ERROR: amalgame-database-sqlite not found (set AMALGAME_DB_SQLITE or check out as a sibling)" >&2
    exit 2
fi
SQLITE_RUNTIME="$SQLITE_DIR/runtime"

GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'
echo "  amc:     $AMC ($("$AMC" --version 2>&1))"
echo "  runtime: $AMC_RUNTIME"
echo "  sqlite:  $SQLITE_DIR"

BUILD_DIR="$(mktemp -d -t adm-tests-XXXXXX)"

# ── Fake cache + lock so `import Amalgame.Database.SQLite` resolves ──
FAKE_CACHE="$BUILD_DIR/cache"
SQLITE_GIT="github.com/amalgame-lang/amalgame-database-sqlite"
SQLITE_TAG="${SQLITE_TAG:-v0.4.0}"
SQLITE_SHA="deadbeefcafebabe0000000000000000000000ab"
SQLITE_CACHE_DIR="$FAKE_CACHE/$SQLITE_GIT/${SQLITE_TAG}_${SQLITE_SHA:0:8}"
mkdir -p "$(dirname "$SQLITE_CACHE_DIR")"
ln -s "$SQLITE_DIR" "$SQLITE_CACHE_DIR"
export AMALGAME_PACKAGES_DIR="$FAKE_CACHE"

# Lock in the package dir (restored / removed by the trap).
LOCK_BAK=""
[ -f "$PKG_DIR/amalgame.lock" ] && { LOCK_BAK="$BUILD_DIR/lock.bak"; cp "$PKG_DIR/amalgame.lock" "$LOCK_BAK"; }
trap '
    rm -rf "$BUILD_DIR"
    if [ -n "$LOCK_BAK" ] && [ -f "$LOCK_BAK" ]; then mv "$LOCK_BAK" "$PKG_DIR/amalgame.lock";
    else rm -f "$PKG_DIR/amalgame.lock"; fi
' EXIT
cat > "$PKG_DIR/amalgame.lock" <<EOF
[[package]]
name = "amalgame-database-sqlite"
git  = "$SQLITE_GIT"
tag  = "$SQLITE_TAG"
rev  = "$SQLITE_SHA"
EOF

# ── Pre-compile sqlite3.c once ─────────────────────────
SQLITE_OBJ="$BUILD_DIR/sqlite3.o"
gcc -O2 -I"$AMC_RUNTIME" -I"$SQLITE_RUNTIME" -w -c "$SQLITE_C" -o "$SQLITE_OBJ" || { echo "sqlite3.c build failed"; exit 1; }

# ── Build the migrate facade (--lib) ───────────────────
( cd "$PKG_DIR" && "$AMC" --lib -o "$BUILD_DIR/facade" facade.am ) 2>&1 | tail -20
gcc -O2 -Wno-incompatible-pointer-types -I"$AMC_RUNTIME" -I"$SQLITE_RUNTIME" -c "$BUILD_DIR/facade.c" -o "$BUILD_DIR/facade.o" 2>"$BUILD_DIR/gcc.log"; head -8 "$BUILD_DIR/gcc.log"
[ -s "$BUILD_DIR/facade.o" ] || { echo -e "${RED}facade build failed${NC}"; cat "$BUILD_DIR/gcc.log"; exit 1; }

# ── Build + run the test sample ────────────────────────
cp "$SCRIPT_DIR/stdlib_migrate.am" "$PKG_DIR/_test.am"
trap '
    rm -f "$PKG_DIR/_test.am"
    rm -rf "$BUILD_DIR"
    if [ -n "$LOCK_BAK" ] && [ -f "$LOCK_BAK" ]; then mv "$LOCK_BAK" "$PKG_DIR/amalgame.lock";
    else rm -f "$PKG_DIR/amalgame.lock"; fi
' EXIT
( cd "$PKG_DIR" && "$AMC" -o "$BUILD_DIR/test" _test.am --external facade.am ) 2>&1 | tail -20
gcc -O2 -Wno-incompatible-pointer-types -I"$AMC_RUNTIME" -I"$SQLITE_RUNTIME" "$BUILD_DIR/test.c" "$BUILD_DIR/facade.o" "$SQLITE_OBJ" \
    -lgc -lm -ldl -lpthread -o "$BUILD_DIR/test" 2>"$BUILD_DIR/gcc.log"; head -10 "$BUILD_DIR/gcc.log"
[ -x "$BUILD_DIR/test" ] || { echo -e "${RED}test build failed${NC}"; cat "$BUILD_DIR/gcc.log"; exit 1; }

OUT="$("$BUILD_DIR/test" 2>&1)"
echo "$OUT"

PASS=0; FAIL=0
check() {
    if echo "$OUT" | grep -qF "$1"; then PASS=$((PASS+1));
    else FAIL=$((FAIL+1)); echo -e "  ${RED}MISSING${NC}: $1"; fi
}
check "[PASS] up applies all in ascending order"
check "[PASS] current=3 and migrated schema usable"
check "[PASS] re-run up applies nothing (idempotent)"
check "[PASS] pending empty when up to date"
check "[PASS] down rolls back v3 (table dropped)"
check "[PASS] down refuses irreversible migration"
check "[PASS] failing migration rolls back + stops (no drift)"
check "[PASS] duplicate version rejected"
check "[PASS] downTo target rolls back the rest"

echo "────────────────────────────────────────────"
echo -e "  ${GREEN}PASS: $PASS${NC}  |  ${RED}FAIL: $FAIL${NC}"
echo "────────────────────────────────────────────"
[ "$FAIL" -eq 0 ]
