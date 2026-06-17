#!/usr/bin/env bash
# Regenerate the README demo GIF from synthetic (non-private) data.
#
#   ./assets/demo/build.sh        # build synthetic index + record assets/fzf-demo.gif
#
# Requires: vhs, fzf (brew install vhs fzf). Uses a throwaway HOME so the engine
# reads the synthetic index built here — never your real ~/.claude/session-index.db.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DEMO_HOME="/tmp/claude-search-demo-home"

echo "==> Building synthetic demo index at $DEMO_HOME"
rm -rf "$DEMO_HOME"
mkdir -p "$DEMO_HOME/.claude/bin"
cp "$REPO/bin/session-search.py" "$DEMO_HOME/.claude/bin/session-search.py"
cp "$REPO/bin/claude-search"     "$DEMO_HOME/.claude/bin/claude-search"
python3 "$REPO/assets/demo/build_demo_db.py" "$DEMO_HOME/.claude/session-index.db"

echo "==> Smoke-testing the synthetic index"
HOME="$DEMO_HOME" PATH="$DEMO_HOME/.claude/bin:$PATH" claude-search "migration" | head -8

echo "==> Recording assets/fzf-demo.gif with VHS"
cd "$REPO"
vhs "$REPO/assets/demo/fzf-demo.tape"

echo "==> Done: $REPO/assets/fzf-demo.gif"
ls -lh "$REPO/assets/fzf-demo.gif"
