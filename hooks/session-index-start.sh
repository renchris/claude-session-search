#!/bin/bash
# SessionStart hook — injects recent session context.
# Performance target: <100ms.
set -euo pipefail

# Read stdin
INPUT=$(cat)
CWD=$(echo "$INPUT" | jq -r '.cwd // empty' 2>/dev/null)

# Resolve helpers
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HELPERS="$SCRIPT_DIR/lib/session-index-helpers.sh"
if [ ! -f "$HELPERS" ]; then
    HELPERS="$HOME/.claude/hooks/lib/session-index-helpers.sh"
fi

# Fast exit if no DB or helpers
[ -f "$HELPERS" ] || exit 0
source "$HELPERS"
[ -f "$SESSION_INDEX_DB" ] || exit 0

# Generate context via Python (fast, <50ms with warm Python)
CONTEXT=$(python3 "$HOME/.claude/bin/session-search.py" --context-inject "${CWD:-$HOME}" 2>/dev/null || echo "")

if [ -n "$CONTEXT" ]; then
    # Escape for JSON
    ESCAPED=$(echo "$CONTEXT" | jq -Rs .)
    cat <<EOF
{
  "hookSpecificOutput": {
    "hookEventName": "SessionStart",
    "additionalContext": $ESCAPED
  }
}
EOF
fi

exit 0
