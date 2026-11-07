#!/usr/bin/env bats
# install.sh, run for real against a sandbox HOME with launchctl stubbed. Nothing here touches the
# real ~/.claude.
#
# Most cases run the installer from a copy of the repo inside the sandbox (use_fast_repo), whose
# backfill and tagger do nothing, because the real backfill is slow and these cases are about the
# steps around it. "bare install runs and exits 0" runs the real thing.
#
# RED-proof, read from the pre-fix code and not run: B14.2, B14.3 and B14.5 cases fail on it, because it backed up a broken file,
# its FTS rebuild left search_aliases out, and its recovery commands were faint on stderr.
#
# shellcheck disable=SC2016,SC2030,SC2031,SC2088 # text for another shell; bats's $output is per test

load helpers_scripts

setup() {
    script_sandbox_setup
    SETTINGS="$HOME/.claude/settings.json"
    DB="$HOME/.claude/session-index.db"
    AGENTS="$HOME/Library/LaunchAgents"
    ESC=$'\033'
    INSTALL="$REPO/install.sh"
    # The stub answers Darwin on any host, so a case that wants launchd behaves the same on CI.
    export STUB_UNAME=Darwin
}

teardown() {
    # A case may leave a directory read-only, which rm -rf cannot empty.
    chmod -R u+rwx "$HOME" 2>/dev/null || true
    sandbox_teardown
}

# Substring checks as functions: on bash 3.2 a failing [[ ]] does not fail a test unless it is last.
has() {
    case "$1" in
        *"$2"*) ;;
        *)
            printf 'expected to find: %s\nin: %s\n' "$2" "$1" >&2
            return 1
            ;;
    esac
}
lacks() {
    case "$1" in
        *"$2"*)
            printf 'expected not to find: %s\nin: %s\n' "$2" "$1" >&2
            return 1
            ;;
    esac
}

# Points INSTALL at a copy of the repo with a backfill and a tagger that do nothing, then retakes the
# snapshot. The demo DB stays, so the FTS rebuild still runs against a real schema.
use_fast_repo() {
    local fast="$HOME/repo"
    mkdir -p "$fast/scripts" || return 1
    cp "$REPO/install.sh" "$REPO/VERSION" "$fast/" || return 1
    cp -R "$REPO/hooks" "$REPO/bin" "$REPO/config" "$fast/" || return 1
    cp -R "$REPO/scripts/lib" "$fast/scripts/" || return 1
    cp "$REPO/scripts/session-index-chunk.py" "$fast/scripts/" || return 1
    printf '#!/bin/bash\nexit "${FAKE_BACKFILL_RC:-0}"\n' >"$fast/scripts/session-index-backfill.sh" || return 1
    printf 'import sys\nsys.exit(0)\n' >"$fast/scripts/session-index-tag.py" || return 1
    chmod +x "$fast/install.sh" "$fast/scripts/session-index-backfill.sh" || return 1
    # pwd, because TMPDIR ends in a slash and the installer prints the path it resolved.
    FAST="$(cd "$fast" && pwd)"
    INSTALL="$FAST/install.sh"
    tree_snapshot
}

# A directory holding only the named commands, for a case about one that is absent. Echoes its path.
path_with_only() {
    local dir="$HOME/only-path" tool real
    mkdir -p "$dir" || return 1
    for tool in "$@"; do
        real="$(command -v "$tool")" || return 1
        ln -s "$real" "$dir/$tool" || return 1
    done
    printf '%s' "$dir"
}

backup_count() {
    find "$HOME/.claude" -name 'settings.json.bak*' | wc -l | tr -d ' '
}

hook_count() {
    jq --arg name "$1" '[.. | objects | .command? // empty | select(test($name))] | length' "$SETTINGS"
}

# ─── Help and parsing ─────────────────────────────────────

@test "--help changes nothing" {
    run --separate-stderr "$INSTALL" --help
    [ "$status" -eq 0 ]
    has "$output" "Usage:"
    assert_tree_unchanged
    [ -z "$(calls launchctl)" ]
}

@test "--help works with HOME unset" {
    run env -u HOME "$INSTALL" --help
    [ "$status" -eq 0 ]
    has "$output" "Usage:"
}

@test "--help lists the exit codes" {
    run "$INSTALL" --help
    [ "$status" -eq 0 ]
    has "$output" "Exit codes:"
    has "$output" "0  Success"
    has "$output" "1  A required step failed"
    has "$output" "2  Usage error"
}

@test "--bogus exits 2 and changes nothing" {
    run --separate-stderr "$INSTALL" --bogus
    [ "$status" -eq 2 ]
    [ -z "$output" ]
    has "$stderr" "unknown option: --bogus"
    has "$stderr" "--help"
    assert_tree_unchanged
    [ -z "$(calls launchctl)" ]
}

@test "a positional exits 2 and changes nothing" {
    run --separate-stderr "$INSTALL" extra
    [ "$status" -eq 2 ]
    has "$stderr" "unexpected argument: extra"
    assert_tree_unchanged
}

@test "--bogus --help prints help" {
    run "$INSTALL" --bogus --help
    [ "$status" -eq 0 ]
    has "$output" "Usage:"
    assert_tree_unchanged
}

@test "help word shows help" {
    run "$INSTALL" help
    [ "$status" -eq 0 ]
    has "$output" "Usage:"
    assert_tree_unchanged
}

@test "--version prints only the version" {
    run --separate-stderr "$INSTALL" --version
    [ "$status" -eq 0 ]
    [ "$output" = "$(cat "$REPO/VERSION")" ]
    [ -z "$stderr" ]
    assert_tree_unchanged
}

@test "--version works with HOME unset" {
    run env -u HOME "$INSTALL" -v
    [ "$status" -eq 0 ]
    [ "$output" = "$(cat "$REPO/VERSION")" ]
}

@test "--version --json is one document" {
    run --separate-stderr "$INSTALL" --version --json
    [ "$status" -eq 0 ]
    assert_one_json_doc
    [ "$(printf '%s' "$output" | jq -r .version)" = "$(cat "$REPO/VERSION")" ]
    assert_tree_unchanged
}

@test "every install help example parses" {
    local help examples=0 line
    help="$("$INSTALL" --help)"
    while IFS= read -r line; do
        case "$line" in
            "  ./install.sh"*)
                examples=$((examples + 1))
                # shellcheck disable=SC2086 # the example's own words
                run env __SESSION_SEARCH_PARSE_ONLY=1 "$INSTALL" ${line#*./install.sh}
                [ "$status" -eq 0 ]
                ;;
        esac
    done <<<"$help"
    [ "$examples" -ge 2 ]
    assert_tree_unchanged
    [ -z "$(calls launchctl)" ]
}

@test "--non-interactive is accepted, and help says it has no effect" {
    run "$INSTALL" --help
    has "$output" "--non-interactive  Accepted; has no effect"
    use_fast_repo
    run "$INSTALL" --non-interactive
    [ "$status" -eq 0 ]
    has "$output" "Installed"
}

# The one run of the real backfill. The demo DB's synonyms table is older than the backfill's
# schema, so this starts from no DB, which is the clean machine in invariant 12.
@test "bare install runs and exits 0" {
    rm -f "$DB"
    run "$INSTALL"
    [ "$status" -eq 0 ]
    has "$output" "Installed"
    [ "$(readlink "$HOME/.claude/bin/session-index-backfill.sh")" = "$REPO/scripts/session-index-backfill.sh" ]
    [ "$(hook_count session-index-end)" = 1 ]
    [ "$(hook_count session-index-start)" = 1 ]
    [ -f "$AGENTS/com.claude.session-search-sweep.plist" ]
    [ "$(sqlite3 "$DB" 'SELECT COUNT(*) FROM sessions_fts')" = "$(sqlite3 "$DB" 'SELECT COUNT(*) FROM sessions')" ]
}

# ─── settings.json ────────────────────────────────────────

@test "broken settings exits 1 with line, column and path and writes nothing" {
    use_fast_repo
    printf '{\n  "model": "opus",\n  oops\n}\n' >"$SETTINGS"
    cp "$SETTINGS" "$HOME/settings.before"
    run --separate-stderr "$INSTALL"
    [ "$status" -eq 1 ]
    has "$stderr" "settings.json is not valid JSON: $SETTINGS:"
    has "$stderr" "at line "
    has "$stderr" ", column "
    has "$stderr" "Fix that line, then re-run ./install.sh. The file was not changed."
    cmp "$SETTINGS" "$HOME/settings.before"
    [ "$(backup_count)" = 0 ]
    lacks "$stderr" "corrupted"
}

@test "a bare array is refused as not one object, and no good backup is lost" {
    use_fast_repo
    printf '[]\n' >"$SETTINGS"
    printf 'the good copy\n' >"$SETTINGS.bak"
    run --separate-stderr "$INSTALL"
    [ "$status" -eq 1 ]
    has "$stderr" "not one JSON object"
    [ "$(cat "$SETTINGS.bak")" = "the good copy" ]
    [ "$(cat "$SETTINGS")" = "[]" ]
}

@test "wrong shape exits 1 naming the key path" {
    use_fast_repo
    local shape
    # Each wrong type, with the key path the message must name.
    for shape in \
        '{"hooks": []}|.hooks should be of type object, found array' \
        '{"hooks": {"SessionEnd": {}}}|.hooks.SessionEnd should be of type array, found object' \
        '{"hooks": {"SessionStart": [{"hooks": {}}]}}|.hooks.SessionStart[0].hooks should be of type array, found object' \
        '{"hooks": {"SessionEnd": [{"hooks": [{"command": 3}]}]}}|.hooks.SessionEnd[0].hooks[0].command should be of type string, found number'; do
        printf '%s\n' "${shape%%|*}" >"$SETTINGS"
        cp "$SETTINGS" "$HOME/settings.before"
        run --separate-stderr "$INSTALL"
        [ "$status" -eq 1 ]
        has "$stderr" "${shape#*|}"
        has "$stderr" "$SETTINGS"
        cmp "$SETTINGS" "$HOME/settings.before"
        [ "$(backup_count)" = 0 ]
    done
}

@test "a wrong type outside this installer's keys does not stop it" {
    use_fast_repo
    printf '{"hooks": {"PreToolUse": "not a list"}}\n' >"$SETTINGS"
    run "$INSTALL"
    [ "$status" -eq 0 ]
    [ "$(hook_count session-index-end)" = 1 ]
    [ "$(jq -r .hooks.PreToolUse "$SETTINGS")" = "not a list" ]
}

@test "a commandless hook does not cause a duplicate" {
    use_fast_repo
    cat >"$SETTINGS" <<'JSON'
{"hooks": {
  "SessionEnd": [{"hooks": [{"type": "prompt"}, {"type": "command", "command": "~/.claude/hooks/session-index-end.sh"}]}],
  "SessionStart": [{"hooks": [{"type": "prompt"}]}]
}}
JSON
    run "$INSTALL"
    [ "$status" -eq 0 ]
    [ "$(hook_count session-index-end)" = 1 ]
    [ "$(hook_count session-index-start)" = 1 ]
    run "$INSTALL"
    [ "$status" -eq 0 ]
    [ "$(hook_count session-index-end)" = 1 ]
    [ "$(hook_count session-index-start)" = 1 ]
}

@test "adding the hooks keeps what was there and reports the backup and the reformat" {
    use_fast_repo
    run "$INSTALL"
    [ "$status" -eq 0 ]
    [ "$(jq -r .model "$SETTINGS")" = opus ]
    [ "$(hook_count unrelated-hook)" = 1 ]
    [ "$(jq -r '.hooks.SessionEnd[0].hooks[0].timeout' "$SETTINGS")" = 10 ]
    [ "$(jq -r '.hooks.SessionStart[0].hooks[0].timeout' "$SETTINGS")" = 5 ]
    [ "$(backup_count)" = 1 ]
    has "$output" "reformatted"
    has "$output" "$(basename "$(find "$HOME/.claude" -name 'settings.json.bak*')")"
    [ "$(jq -r .model "$(find "$HOME/.claude" -name 'settings.json.bak*')")" = opus ]
}

@test "symlinked settings.json stays a symlink" {
    use_fast_repo
    mv "$SETTINGS" "$HOME/real-settings.json"
    ln -s "$HOME/real-settings.json" "$SETTINGS"
    run "$INSTALL"
    [ "$status" -eq 0 ]
    [ -L "$SETTINGS" ]
    [ "$(readlink "$SETTINGS")" = "$HOME/real-settings.json" ]
    [ "$(jq '.hooks | has("SessionEnd")' "$HOME/real-settings.json")" = true ]
}

@test "mode 644 is kept" {
    use_fast_repo
    chmod 644 "$SETTINGS"
    run "$INSTALL"
    [ "$status" -eq 0 ]
    [ "$(hook_count session-index-end)" = 1 ]
    [ "$(python3 -c 'import os, sys; print(oct(os.stat(sys.argv[1]).st_mode & 0o777))' "$SETTINGS")" = 0o644 ]
}

@test "a second run writes no backup" {
    use_fast_repo
    run "$INSTALL"
    [ "$status" -eq 0 ]
    [ "$(backup_count)" = 1 ]
    cp "$SETTINGS" "$HOME/settings.before"
    run "$INSTALL"
    [ "$status" -eq 0 ]
    has "$output" "hooks already registered"
    lacks "$output" "reformatted"
    [ "$(backup_count)" = 1 ]
    cmp "$SETTINGS" "$HOME/settings.before"
}

@test "a failed patch exits 1, says why and leaves the file" {
    use_fast_repo
    # A held lock is the one patch failure that reaches the library without a read-only tree.
    mkdir "$SETTINGS.lock.d"
    cp "$SETTINGS" "$HOME/settings.before"
    run --separate-stderr env __SESSION_SEARCH_LOCK_TRIES=3 "$INSTALL"
    [ "$status" -eq 1 ]
    has "$stderr" "Can't patch settings.json:"
    has "$stderr" "another install holds the lock"
    has "$stderr" "The file was not changed."
    has "$stderr" "$FAST/install.sh"
    cmp "$SETTINGS" "$HOME/settings.before"
    [ "$(backup_count)" = 0 ]
}

# ─── Search index ─────────────────────────────────────────

@test "re-running install keeps aliases searchable" {
    use_fast_repo
    local id
    id="$(sqlite3 "$DB" 'SELECT session_id FROM sessions LIMIT 1')"
    sqlite3 "$DB" "UPDATE sessions SET search_aliases = 'zzqaliasword' WHERE session_id = '$id'"
    run "$INSTALL"
    [ "$status" -eq 0 ]
    [ "$(sqlite3 "$DB" "SELECT COUNT(*) FROM sessions_fts WHERE sessions_fts MATCH 'zzqaliasword'")" = 1 ]
}

@test "install.sh has no INSERT INTO sessions_fts" {
    run grep -c 'INSERT INTO sessions_fts' "$REPO/install.sh"
    [ "$status" -eq 1 ]
    [ "$output" = 0 ]
}

@test "a failed FTS rebuild is reported and the install still finishes" {
    use_fast_repo
    sqlite3 "$DB" 'DROP TABLE sessions_fts'
    run --separate-stderr "$INSTALL"
    [ "$status" -eq 0 ]
    has "$output" "search index rebuild failed; rerun scripts/session-index-backfill.sh"
    has "$stderr" "sessions_fts"
    has "$output" "Scheduler: "
    has "$output" "Installed"
}

# ─── Scheduler ────────────────────────────────────────────

@test "Linux skips the scheduler by name and exits 0" {
    use_fast_repo
    rmdir "$AGENTS" "$HOME/Library"
    STUB_UNAME=Linux run "$INSTALL"
    [ "$status" -eq 0 ]
    has "$output" "Scheduler: skipped: launchd is macOS-only"
    has "$output" "The sweep and weekly backfill are not scheduled"
    has "$output" "~/.claude/bin/session-index-backfill.sh --quiet"
    lacks "$output" "(60s) registered"
    [ ! -e "$HOME/Library" ]
    [ -z "$(calls launchctl)" ]
}

@test "Darwin creates a missing LaunchAgents dir" {
    use_fast_repo
    rmdir "$AGENTS"
    run "$INSTALL"
    [ "$status" -eq 0 ]
    [ -f "$AGENTS/com.claude.session-search-backfill.plist" ]
    [ -f "$AGENTS/com.claude.session-search-sweep.plist" ]
    has "$output" "Scheduler: backfill + sweep (60s) registered"
    [ "$(calls launchctl | grep -c '^load$')" = 2 ]
}

@test "a failed cp exits 1 naming the destination and the retry command" {
    use_fast_repo
    chmod a-w "$AGENTS"
    run --separate-stderr "$INSTALL"
    [ "$status" -eq 1 ]
    has "$output" "Error: Scheduler: failed"
    has "$stderr" "Can't copy the scheduled job to $AGENTS/com.claude.session-search-backfill.plist"
    has "$stderr" "Symlinks, settings, the index and PATH are done"
    has "$stderr" "$FAST/install.sh"
    lacks "$output" "Installed"
}

@test "fzf hint follows the package manager" {
    use_fast_repo
    rm "$HOME/stubs/fzf"
    _write_stub apt-get </dev/null
    run "$INSTALL"
    [ "$status" -eq 0 ]
    has "$output" "sudo apt-get install fzf"
    has "$output" "interactive mode (--fzf)"
    lacks "$output" "brew install fzf"
    # brew comes first in the cascade, as it does for the prerequisites.
    _write_stub brew </dev/null
    run "$INSTALL"
    [ "$status" -eq 0 ]
    has "$output" "brew install fzf"
    has "$output" "interactive mode (--fzf)"
    lacks "$output" "apt-get"
}

# ─── Colour and rows ──────────────────────────────────────

@test "recovery commands are not faint" {
    local only
    only="$(path_with_only dirname python3 sqlite3)"
    ln -s "$HOME/stubs/launchctl" "$only/brew"
    FORCE_COLOR=1 run --separate-stderr env PATH="$only" "$INSTALL"
    [ "$status" -eq 1 ]
    has "$stderr" "${ESC}[36mbrew install jq${ESC}[0m"
    lacks "$stderr" "${ESC}[2m"
}

@test "./install.sh 2>err.log writes no escape codes to the file" {
    local only err="$BATS_TEST_TMPDIR/err.log"
    only="$(path_with_only dirname python3 sqlite3)"
    ln -s "$HOME/stubs/launchctl" "$only/brew"
    # stdout keeps the terminal, so this is the case where stdout's colour set could tint stderr.
    run run_in_pty /bin/bash -c 'PATH="$1" "$2" 2>"$3"' _ "$only" "$INSTALL" "$err"
    [ "$status" -eq 1 ]
    has "$(cat "$err")" "brew install jq"
    assert_no_ansi "$(cat "$err")"
}

@test "plain mode has no [ok] markers" {
    use_fast_repo
    run "$INSTALL"
    [ "$status" -eq 0 ]
    assert_no_ansi
    lacks "$output" "[ok]"
    lacks "$output" "[!!]"
    lacks "$output" "✓"
    has "$output" "Symlinks: hooks + bin linked"
    has "$output" "Settings: hooks registered in settings.json"
}

@test "a rich terminal draws the glyphs as glyphs" {
    use_fast_repo
    run run_in_pty "$INSTALL"
    [ "$status" -eq 0 ]
    has "$output" "✓"
    has "$output" "${ESC}[5A"
    lacks "$output" '\033'
}

@test "--no-color has no colour but keeps layout" {
    use_fast_repo
    run run_in_pty "$INSTALL" --no-color
    [ "$status" -eq 0 ]
    has "$output" "✓"
    has "$output" "╭"
    has "$output" "${ESC}[5A"
    has "$output" "${ESC}[?25l"
    lacks "$output" "${ESC}[0m"
    lacks "$output" "${ESC}[1m"
    lacks "$output" "${ESC}[2m"
    lacks "$output" "${ESC}[32m"
    lacks "$output" "${ESC}[36m"
}

# ─── Error copy and next steps ────────────────────────────

@test "missing prerequisite names the command and exits 1" {
    local only
    only="$(path_with_only dirname python3 sqlite3)"
    ln -s "$HOME/stubs/launchctl" "$only/brew"
    tree_snapshot
    run --separate-stderr env PATH="$only" "$INSTALL"
    [ "$status" -eq 1 ]
    [ -z "$output" ]
    has "$stderr" "Can't install. Missing jq."
    has "$stderr" "brew install jq"
    has "$stderr" "$REPO/install.sh"
    assert_tree_unchanged
}

@test "missing prerequisite with no package manager still says what to do" {
    local only
    only="$(path_with_only dirname python3 sqlite3)"
    run --separate-stderr env PATH="$only" "$INSTALL"
    [ "$status" -eq 1 ]
    has "$stderr" "Missing jq."
    has "$stderr" "system package manager"
    has "$stderr" "$REPO/install.sh"
}

@test "no FTS5 shows sqlite's own message and the brew recovery" {
    _write_stub sqlite3 <<'STUB'
echo 'Error: no such module: fts5' >&2
exit 1
STUB
    _write_stub brew </dev/null
    tree_snapshot
    run --separate-stderr "$INSTALL"
    [ "$status" -eq 1 ]
    has "$stderr" "Can't create an FTS5 table with $HOME/stubs/sqlite3."
    has "$stderr" "no such module: fts5"
    has "$stderr" "brew install sqlite"
    has "$stderr" "\$(brew --prefix sqlite)/bin:\$PATH"
    assert_tree_unchanged
}

@test "a missing library names the file and the restore command" {
    use_fast_repo
    rm "$HOME/repo/scripts/lib/progress-ui.sh"
    run --separate-stderr "$INSTALL"
    [ "$status" -eq 1 ]
    has "$stderr" "Can't load $FAST/scripts/lib/progress-ui.sh. The file is missing."
    has "$stderr" "git -C $FAST restore scripts/lib/progress-ui.sh"
    rm "$HOME/repo/scripts/lib/cli-common.sh"
    run --separate-stderr "$INSTALL"
    [ "$status" -eq 1 ]
    has "$stderr" "Can't load $FAST/scripts/lib/cli-common.sh. The file is missing."
    has "$stderr" "git -C $FAST restore scripts/lib/cli-common.sh"
}

@test "no settings.json prints the printf recovery" {
    use_fast_repo
    rm "$SETTINGS"
    run "$INSTALL"
    [ "$status" -eq 0 ]
    has "$output" "Settings: no settings.json, hooks not registered"
    has "$output" "Hooks aren't registered. Create settings.json, then rerun:"
    has "$output" "printf '{}\n' > ~/.claude/settings.json"
    has "$output" "$FAST/install.sh"
    # Recovery follows the summary, which a terminal's redraw could not overwrite.
    has "${output#*Installed}" "Hooks aren't registered."
    [ ! -e "$SETTINGS" ]
}

@test "missing rc file does not claim already in" {
    use_fast_repo
    rm "$HOME/.zshrc"
    run "$INSTALL"
    [ "$status" -eq 0 ]
    has "$output" "PATH: no shell config found"
    lacks "$output" "already in"
    has "$output" 'export PATH="$HOME/.claude/bin:$PATH"'
    [ ! -e "$HOME/.zshrc" ]
    [ ! -e "$HOME/.bashrc" ]
}

@test "the rc file gets the line once" {
    use_fast_repo
    run "$INSTALL"
    [ "$status" -eq 0 ]
    has "$output" "PATH: added to .zshrc"
    run "$INSTALL"
    [ "$status" -eq 0 ]
    has "$output" "PATH: already in .zshrc"
    [ "$(grep -c '.claude/bin' "$HOME/.zshrc")" = 1 ]
}

@test "success ends with claude-search <QUERY> on its own line" {
    use_fast_repo
    run "$INSTALL"
    [ "$status" -eq 0 ]
    has "$output" "Installed"
    lacks "$output" "Ready"
    lacks "$output" 'claude-search "query"'
    local last
    last="$(printf '%s\n' "$output" | awk 'NF { line = $0 } END { print line }')"
    [ "$last" = "    claude-search <QUERY>" ]
    has "$output" "Search your sessions:"
}

@test "PATH note appears only when bin is not on PATH" {
    use_fast_repo
    run "$INSTALL"
    [ "$status" -eq 0 ]
    lacks "$output" "Add claude-search to this shell:"
    # A rerun in the same old shell: the rc file has the line, and this PATH still lacks it.
    run env PATH="$HOME/stubs:$HOME/tools:/usr/bin:/bin" "$INSTALL"
    [ "$status" -eq 0 ]
    has "$output" "PATH: already in .zshrc"
    has "$output" "Add claude-search to this shell:"
    has "$output" 'export PATH="$HOME/.claude/bin:$PATH"'
}

# ─── --json ───────────────────────────────────────────────

@test "--json stdout is exactly one document, stderr holds the steps" {
    use_fast_repo
    run --separate-stderr "$INSTALL" --json
    [ "$status" -eq 0 ]
    assert_one_json_doc
    [ "$(printf '%s' "$output" | jq -r .outcome)" = installed ]
    [ "$(printf '%s' "$output" | jq -r .installation.claude_dir)" = "$HOME/.claude" ]
    [ "$(printf '%s' "$output" | jq -r .installation.settings)" = "hooks registered in settings.json" ]
    [ "$(printf '%s' "$output" | jq -r .installation.path)" = "added to .zshrc" ]
    [ "$(printf '%s' "$output" | jq -r .installation.scheduler)" = "backfill + sweep (60s) registered" ]
    [ "$(printf '%s' "$output" | jq .installation.sessions)" = "$(sqlite3 "$DB" 'SELECT COUNT(*) FROM sessions')" ]
    [ "$(printf '%s' "$output" | jq '.installation.tagged | type')" = '"number"' ]
    has "$stderr" "Symlinks: hooks + bin linked"
    has "$stderr" "claude-search <QUERY>"
}

@test "--json failure writes nothing to stdout and one error line to stderr" {
    use_fast_repo
    printf '{ oops\n' >"$SETTINGS"
    run --separate-stderr "$INSTALL" --json
    [ "$status" -eq 1 ]
    [ -z "$output" ]
    local last
    last="$(printf '%s\n' "$stderr" | tail -1)"
    assert_one_json_doc "$last"
    [ "$(printf '%s' "$last" | jq -r .status)" = error ]
    [ "$(printf '%s' "$last" | jq -r .reason)" = invalid_settings ]
    has "$(printf '%s' "$last" | jq -r .message)" "not valid JSON"
    [ "$(printf '%s\n' "$stderr" | grep -c '^{"status"')" = 1 ]
}

@test "--json reports a missing jq without jq" {
    local only
    only="$(path_with_only dirname python3 sqlite3)"
    run --separate-stderr env PATH="$only" "$INSTALL" --json
    [ "$status" -eq 1 ]
    [ -z "$output" ]
    local last
    last="$(printf '%s\n' "$stderr" | tail -1)"
    assert_one_json_doc "$last"
    [ "$(printf '%s' "$last" | jq -r .reason)" = missing_dependency ]
}

@test "--json reports a missing library and an abort in the backfill" {
    use_fast_repo
    FAKE_BACKFILL_RC=7 run --separate-stderr "$INSTALL" --json
    [ "$status" -eq 7 ]
    [ -z "$output" ]
    local last
    last="$(printf '%s\n' "$stderr" | tail -1)"
    assert_one_json_doc "$last"
    [ "$(printf '%s' "$last" | jq -r .reason)" = install_failed ]
    has "$(printf '%s' "$last" | jq -r .message)" "Indexing"

    rm "$HOME/repo/scripts/lib/progress-ui.sh"
    run --separate-stderr "$INSTALL" --json
    [ "$status" -eq 1 ]
    [ -z "$output" ]
    last="$(printf '%s\n' "$stderr" | tail -1)"
    assert_one_json_doc "$last"
    [ "$(printf '%s' "$last" | jq -r .reason)" = missing_file ]
}

@test "--json keeps the cursor-restore trap" {
    use_fast_repo
    # A library whose cleanup leaves a mark, so the chain is seen from outside. On a terminal this
    # restores the cursor; under --json the only stream that could show it is not one.
    printf '_ui_cleanup() { : >"$HOME/calls/ui-cleanup"; }\n' >>"$HOME/repo/scripts/lib/progress-ui.sh"
    printf '{ oops\n' >"$SETTINGS"
    run --separate-stderr "$INSTALL" --json
    [ "$status" -eq 1 ]
    [ -e "$HOME/calls/ui-cleanup" ]
    assert_one_json_doc "$(printf '%s\n' "$stderr" | tail -1)"
}

@test "a failure on a terminal restores the cursor and prints below the roadmap" {
    use_fast_repo
    printf '{ oops\n' >"$SETTINGS"
    run run_in_pty "$INSTALL"
    [ "$status" -eq 1 ]
    has "$output" "✗"
    has "$output" "${ESC}[?25h"
    # Three rows remain below Settings; the error follows three bare line feeds.
    has "$output" $'\n\r\n\r\n\r'
}
