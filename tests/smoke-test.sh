#!/bin/bash
# Smoke test for claude-session-search.
# Verifies DB, FTS5, search, hooks, and cleanup.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
DB="$HOME/.claude/session-index.db"
SEARCH_PY="$HOME/.claude/bin/session-search.py"
PASS=0
FAIL=0

check() {
    local desc="$1"
    shift
    if "$@" >/dev/null 2>&1; then
        echo "  ✓ $desc"
        PASS=$((PASS + 1))
    else
        echo "  ✗ $desc"
        FAIL=$((FAIL + 1))
    fi
}

echo "Smoke Test: claude-session-search"
echo "──────────────────────────────────"

# 1. Database exists
echo ""
echo "Database:"
check "DB file exists" test -f "$DB"
check "Sessions table" sqlite3 "$DB" "SELECT COUNT(*) FROM sessions;"
check "FTS5 table" sqlite3 "$DB" "SELECT COUNT(*) FROM sessions_fts;"
check "Synonyms loaded" test "$(sqlite3 "$DB" 'SELECT COUNT(*) FROM synonyms;')" -gt 0

# 2. FTS5 search works
echo ""
echo "FTS5:"
check "FTS5 MATCH query" sqlite3 "$DB" "SELECT session_id FROM sessions_fts WHERE sessions_fts MATCH 'session' LIMIT 1;"

# 3. Search CLI works
echo ""
echo "Search CLI:"
check "session-search.py exists" test -f "$SEARCH_PY"
check "Stats mode" python3 "$SEARCH_PY" --stats
check "Search returns results" python3 "$SEARCH_PY" --format=json "session" --limit 1

# 4. SessionEnd hook test
echo ""
echo "SessionEnd hook:"
TEST_SID="smoke-test-$(date +%s)"
echo "{\"session_id\":\"$TEST_SID\",\"transcript_path\":\"/dev/null\",\"cwd\":\"/tmp\",\"hook_event_name\":\"SessionEnd\"}" | \
    "$HOME/.claude/hooks/session-index-end.sh" 2>/dev/null || true
check "Hook created row" test "$(sqlite3 "$DB" "SELECT COUNT(*) FROM sessions WHERE session_id='$TEST_SID';")" -eq 1

# 5. SessionStart hook test
echo ""
echo "SessionStart hook:"
CONTEXT_OUTPUT=$(echo '{"session_id":"x","cwd":"/tmp","hook_event_name":"SessionStart","source":"startup"}' | \
    "$HOME/.claude/hooks/session-index-start.sh" 2>/dev/null || echo "")
check "Hook produces JSON" bash -c "echo '$CONTEXT_OUTPUT' | jq -e .hookSpecificOutput"

# 6. Preview mode
echo ""
echo "Preview:"
check "Preview test session" python3 "$SEARCH_PY" --preview "$TEST_SID"

# 7. Cleanup
echo ""
echo "Cleanup:"
sqlite3 "$DB" "DELETE FROM sessions WHERE session_id='$TEST_SID';"
check "Test row removed" test "$(sqlite3 "$DB" "SELECT COUNT(*) FROM sessions WHERE session_id='$TEST_SID';")" -eq 0

# Summary
echo ""
echo "──────────────────────────────────"
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && echo "All tests passed!" || exit 1
