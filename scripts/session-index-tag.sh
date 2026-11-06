#!/bin/bash
# Session tagger — thin wrapper around Python implementation.
# All flags are forwarded; see session-index-tag.py --help
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
PYTHON_SCRIPT="$SCRIPT_DIR/session-index-tag.py"
CLI_COMMON="$SCRIPT_DIR/lib/cli-common.sh"

if [ -f "$CLI_COMMON" ]; then
    # shellcheck source=/dev/null # the shellcheck gate runs per file and checks the library itself
    . "$CLI_COMMON"
else
    # The library that formats errors is gone too, so the same layout in plain words.
    css_fail() {
        printf 'Error: %s\n\n%s:\n    %s\n' "$1" "${2%:}" "$3" >&2
        exit 1
    }
fi

if [ ! -f "$PYTHON_SCRIPT" ]; then
    # install.sh would not help here: it only links, so a missing file gets a dangling link.
    if git -C "$REPO_DIR" ls-files --error-unmatch scripts/session-index-tag.py >/dev/null 2>&1; then
        css_fail "Missing $PYTHON_SCRIPT" "Restore it" \
            "git -C $REPO_DIR restore scripts/session-index-tag.py"
    fi
    css_fail "Missing $PYTHON_SCRIPT" "Clone a fresh copy" \
        "git clone https://github.com/renchris/claude-session-search.git"
fi

# Known limit: on macOS /usr/bin/python3 can be an Xcode stub that satisfies this check.
if ! command -v python3 >/dev/null 2>&1; then
    rerun="$(printf '%q ' "$0" "$@")"
    css_fail "Cannot start tagger: python3 not found" "Install Python 3, then re-run" "${rerun% }"
fi

exec python3 "$PYTHON_SCRIPT" "$@"
