#!/bin/bash
# Workflow-result indexing test for claude-session-search.
# A Dynamic Workflow writes its result to <project>/<sid>/workflows/wf_*.json. The sweep and the
# backfill index each such file as its OWN row (id = file stem), never touching the parent
# session's row, and claude-search shows the file's path instead of offering to resume it.
#
# Hermetic: everything runs under a scratch $HOME, so the real index is never read or written.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/css-wftest.XXXXXX")"
trap 'rm -rf "$SCRATCH"' EXIT
export HOME="$SCRATCH/home"
DB="$HOME/.claude/session-index.db"
PROJ="$HOME/.claude/projects/-Users-x-proj"
SID=11111111-2222-3333-4444-555555555555
WF_ID=wf_abc12345-678
WF="$PROJ/$SID/workflows/$WF_ID.json"
BAD="$PROJ/$SID/workflows/wf_bad-1.json"
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
eq() { [ "$1" = "$2" ]; }
q() { sqlite3 "$DB" "$1"; }

mkdir -p "$PROJ/$SID/workflows" "$HOME/.claude/logs"
cat > "$PROJ/$SID.jsonl" <<'JSONL'
{"type":"user","message":{"content":"please fix the batched sweep so it stops re-parsing"}}
{"type":"assistant","message":{"content":[{"type":"text","text":"I will collapse the three parses into one pass over each changed transcript file."}]}}
JSONL
# zanzibarquux appears ONLY in `result`; scriptonlyword / logonlyword must never be indexed.
cat > "$WF" <<'JSON'
{"runId":"wf_abc12345-678","timestamp":"2026-09-20T10:00:00Z","taskId":"t1",
 "workflowName":"docs-audit","summary":"Audit the docs tree for stale plans","status":"completed",
 "phases":[{"title":"Ground truth","detail":"map the code"}],
 "result":{"findings":[{"finding":"the zanzibarquux ledger is orphaned"}],"note":"second note"},
 "logs":["logonlyword appeared in a log"],
 "script":"export const meta = { name: 'scriptonlyword' }",
 "scriptPath":"/tmp/x.js","durationMs":10,"totalTokens":5}
JSON
printf '{"runId": "wf_bad-1", "result": [trunc' > "$BAD"

# shellcheck source=hooks/lib/session-index-helpers.sh
source "$REPO_DIR/hooks/lib/session-index-helpers.sh"
session_index_init_db
session_index_init_tracking

echo "Workflow Index Test: claude-session-search"
echo "──────────────────────────────────"

echo ""
echo "Sweep:"
# Index the transcript alone first, so the parent row can be compared before and after.
mv "$WF" "$SCRATCH/wf.json"; mv "$BAD" "$SCRATCH/bad.json"
bash "$REPO_DIR/hooks/session-index-sweep.sh"
PARENT_Q="SELECT session_id,project_path,first_prompt,context_text,assistant_text,message_count,keywords,source FROM sessions WHERE session_id='$SID';"
PARENT_FTS_Q="SELECT first_prompt,context_text FROM sessions_fts WHERE session_id='$SID';"
parent_before=$(q "$PARENT_Q"); parent_fts_before=$(q "$PARENT_FTS_Q")
mv "$SCRATCH/wf.json" "$WF"; mv "$SCRATCH/bad.json" "$BAD"
check "sweep exits 0 with a malformed workflow file present" bash "$REPO_DIR/hooks/session-index-sweep.sh"
check "a word only in the result finds the workflow row" \
    eq "$(q "SELECT session_id FROM sessions_fts WHERE sessions_fts MATCH 'zanzibarquux';")" "$WF_ID"
check "the row carries source, project and first_prompt" \
    eq "$(q "SELECT source||'|'||project_path||'|'||first_prompt FROM sessions WHERE session_id='$WF_ID';")" \
       "workflow-sweep|/Users/x/proj|workflow docs-audit: Audit the docs tree for stale plans"
check "script body is not indexed" eq "$(q "SELECT COUNT(*) FROM sessions_fts WHERE sessions_fts MATCH 'scriptonlyword';")" 0
check "logs are not indexed" eq "$(q "SELECT COUNT(*) FROM sessions_fts WHERE sessions_fts MATCH 'logonlyword';")" 0
check "parent session row is unchanged" eq "$(q "$PARENT_Q")" "$parent_before"
check "parent FTS row is unchanged" eq "$(q "$PARENT_FTS_Q")" "$parent_fts_before"
check "malformed file is tracked, not indexed" \
    eq "$(q "SELECT (SELECT COUNT(*) FROM file_tracking WHERE session_id='wf_bad-1')||'|'||(SELECT COUNT(*) FROM sessions WHERE session_id='wf_bad-1');")" "1|0"
bash "$REPO_DIR/hooks/session-index-sweep.sh"
check "an unchanged workflow file is not re-extracted" \
    eq "$(q "SELECT sweep_count FROM file_tracking WHERE session_id='$WF_ID';")" 1

echo ""
echo "Search CLI:"
json=$(python3 "$REPO_DIR/bin/session-search.py" --format=json zanzibarquux --limit 5)
check "JSON hit carries the workflow file path" \
    eq "$(printf '%s' "$json" | jq -r --arg id "$WF_ID" '.[] | select(.session_id==$id) | .workflow_path')" "$WF"
set +e
resume_err=$(python3 "$REPO_DIR/bin/session-search.py" --resume-result 1 zanzibarquux 2>&1 >/dev/null)
resume_rc=$?
set -e
check "resume refuses a workflow row (exit 1)" eq "$resume_rc" 1
check "resume names the workflow file" eq "$resume_err" "Result #1 is a workflow result, not a session: $WF"
check "preview shows the workflow file" \
    bash -c "python3 '$REPO_DIR/bin/session-search.py' --preview '$WF_ID' | grep -qF '$WF'"

echo ""
echo "Backfill:"
rm -f "$DB" "$DB-wal" "$DB-shm"
session_index_init_db
session_index_init_tracking
check "backfill exits 0" bash "$REPO_DIR/scripts/session-index-backfill.sh"
check "backfill indexes the workflow row" \
    eq "$(q "SELECT source FROM sessions WHERE session_id='$WF_ID';")" "workflow-sweep"
check "backfill FTS finds the result word" \
    eq "$(q "SELECT session_id FROM sessions_fts WHERE sessions_fts MATCH 'zanzibarquux';")" "$WF_ID"

echo ""
echo "──────────────────────────────────"
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && echo "All tests passed!" || exit 1
