# shellcheck shell=bash
# Sandbox for tests that run install.sh, uninstall.sh and the index scripts: `load helpers_scripts`,
# then script_sandbox_setup / sandbox_teardown from setup() / teardown(). Builds on helpers.bash,
# whose sandbox_setup scrubs CI, CLAUDECODE, the colour variables and ANTHROPIC_API_KEY (tag.py:753,
# session-search.py:673 read that key).
#
# Bash 3.2, as in helpers.bash.

load helpers

# The whole sandbox except calls/, which is the stubs' own log and not the subject's doing: paths,
# types, modes, owners, sizes and symlink targets from ls (the date columns and the link count
# removed, since a directory's change with any entry), then a checksum of every regular file.
_tree_state() {
    (
        cd "$HOME" || exit 1
        LC_ALL=C find . -path ./calls -prune -o -exec ls -ldn {} + |
            LC_ALL=C awk '{ $2 = $6 = $7 = $8 = ""; print }' | LC_ALL=C sort
        find . -path ./calls -prune -o -type f -exec cksum {} + | LC_ALL=C sort
    )
}

# tree_snapshot: sets the state assert_tree_unchanged compares with. script_sandbox_setup takes the
# first one, so a test that seeds more files takes its own after seeding.
tree_snapshot() {
    _TREE_BEFORE="$(_tree_state)"
}

# assert_tree_unchanged: nothing in the sandbox HOME changed since the last tree_snapshot.
assert_tree_unchanged() {
    local after
    if [ -z "${_TREE_BEFORE-}" ]; then
        echo "assert_tree_unchanged: no snapshot taken" >&2
        return 1
    fi
    after="$(_tree_state)"
    if [ "$after" != "$_TREE_BEFORE" ]; then
        echo "assert_tree_unchanged: the sandbox changed:" >&2
        diff <(printf '%s\n' "$_TREE_BEFORE") <(printf '%s\n' "$after") >&2
        return 1
    fi
}

# Adds to sandbox_setup what the install scripts act on:
# - launchctl, stubbed first on PATH. launchctl acts on the user's domain, not on $HOME, so a temp
#   HOME on a Mac could otherwise reload real jobs.
# - uname, stubbed. STUB_UNAME=Linux|Darwin answers bare `uname` and `uname -s`; unset, the real one.
# - ~/Library/LaunchAgents, because install.sh:257 has no mkdir. A test of that gap removes it.
# - settings.json with one unrelated hook and a .zshrc, without which install.sh:204 and :234 skip.
script_sandbox_setup() {
    sandbox_setup || return 1
    _write_stub launchctl </dev/null || return 1
    _write_stub uname <<'STUB' || return 1
case "${1:-}" in
    "" | -s)
        if [ -n "${STUB_UNAME:-}" ]; then
            printf '%s\n' "$STUB_UNAME"
            exit 0
        fi
        ;;
esac
PATH=/usr/bin:/bin exec uname "$@"
STUB
    mkdir -p "$HOME/Library/LaunchAgents" || return 1
    cat >"$HOME/.claude/settings.json" <<'JSON' || return 1
{
  "model": "opus",
  "hooks": {
    "PreToolUse": [
      {"matcher": "Bash", "hooks": [{"type": "command", "command": "~/unrelated-hook.sh"}]}
    ]
  }
}
JSON
    printf '# seeded by script_sandbox_setup\nexport EDITOR=vi\n' >"$HOME/.zshrc" || return 1
    tree_snapshot
}
