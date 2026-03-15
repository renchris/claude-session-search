#!/bin/bash
# Session tagger — thin wrapper around Python implementation.
# All flags are forwarded: --dry-run, --limit, --project, --regex-only, --quiet
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PYTHON_SCRIPT="$SCRIPT_DIR/session-index-tag.py"

if [ ! -f "$PYTHON_SCRIPT" ]; then
    echo "error: missing $PYTHON_SCRIPT" >&2
    echo "  Re-clone the repo or run install.sh" >&2
    exit 1
fi

exec python3 "$PYTHON_SCRIPT" "$@"
