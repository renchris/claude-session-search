#!/usr/bin/env bats
# uninstall.sh, run for real against a sandbox HOME with launchctl stubbed. Nothing here touches the
# real ~/.claude.
#
# shellcheck disable=SC2030,SC2031 # bats's $output is per test

load helpers_scripts

setup() {
    script_sandbox_setup
    SETTINGS="$HOME/.claude/settings.json"
    BIN="$HOME/.claude/bin"
    HOOKS="$HOME/.claude/hooks"
    AGENTS="$HOME/Library/LaunchAgents"
    PYC_PATTERN="$BIN/__pycache__/session-search.*.pyc"
    DB="$HOME/.claude/session-index.db"
    LINKS=(
        "$HOOKS/session-index-end.sh"
        "$HOOKS/session-index-start.sh"
        "$HOOKS/session-index-sweep.sh"
        "$HOOKS/lib/session-index-helpers.sh"
        "$BIN/session-search.py"
        "$BIN/claude-search"
        "$BIN/session-index-tag.py"
        "$BIN/session-index-backfill.sh"
        "$BIN/session-index-chunk.py"
    )
    BACKFILL_PLIST="$AGENTS/com.claude.session-search-backfill.plist"
    SWEEP_PLIST="$AGENTS/com.claude.session-search-sweep.plist"
}
teardown() { sandbox_teardown; }

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

# Settings as install.sh leaves them, plus a sibling that must survive.
seed_settings() {
    cat >"$SETTINGS" <<'JSON'
{
  "model": "opus",
  "hooks": {
    "SessionEnd": [
      {"hooks": [{"type": "command", "command": "~/.claude/hooks/session-index-end.sh"}]}
    ],
    "SessionStart": [
      {"hooks": [{"type": "command", "command": "~/.claude/hooks/session-index-start.sh"}]},
      {"hooks": [{"type": "command", "command": "~/other-start.sh"}]}
    ]
  }
}
JSON
}

# A full install's footprint, built by hand: every link, the settings entries, both plists, a pyc.
seed_installed() {
    local link
    for link in "${LINKS[@]}"; do
        rm -f "$link"
        ln -s "$REPO/somewhere/${link##*/}" "$link"
    done
    seed_settings
    : >"$BACKFILL_PLIST"
    : >"$SWEEP_PLIST"
    mkdir -p "$BIN/__pycache__"
    : >"$BIN/__pycache__/session-search.cpython-311.pyc"
    tree_snapshot
}

# The links under ~/.claude that point into this repo, one per line.
repo_links() {
    local link
    find "$HOME/.claude" -type l | while IFS= read -r link; do
        case "$(readlink "$link")" in
            "$REPO"/*) printf '%s\n' "$link" ;;
        esac
    done
}

backup_count() {
    find "$HOME/.claude" -name 'settings.json.bak.*' | wc -l | tr -d ' '
}

# ─── Help and parsing ─────────────────────────────────────

@test "--help removes nothing" {
    seed_installed
    for flag in --help -h help; do
        run "$REPO/uninstall.sh" "$flag"
        [ "$status" -eq 0 ]
        has "$output" "Usage: ./uninstall.sh"
        assert_tree_unchanged
    done
    [ -z "$(calls launchctl)" ]
}

@test "--help wins over any other argument and removes nothing" {
    seed_installed
    run "$REPO/uninstall.sh" --bogus --version --help
    [ "$status" -eq 0 ]
    has "$output" "Usage: ./uninstall.sh"
    assert_tree_unchanged
}

@test "--help works with HOME unset" {
    run --separate-stderr env -u HOME "$REPO/uninstall.sh" --help
    [ "$status" -eq 0 ]
    has "$output" "Usage: ./uninstall.sh"
    [ -z "$stderr" ]
}

@test "help lists the exit codes" {
    run "$REPO/uninstall.sh" --help
    [ "$status" -eq 0 ]
    block="$(printf '%s\n' "$output" | sed -n '/^Exit codes:$/,$p')"
    has "$block" "0  Success"
    has "$block" "1  settings.json could not be edited"
    has "$block" "2  Usage error"
}

@test "--bogus exits 2 and removes nothing" {
    seed_installed
    run --separate-stderr "$REPO/uninstall.sh" --bogus
    [ "$status" -eq 2 ]
    [ -z "$output" ]
    has "$stderr" "unknown option: --bogus"
    has "$stderr" "See './uninstall.sh --help'."
    assert_tree_unchanged
    [ -z "$(calls launchctl)" ]
}

@test "a positional exits 2 and removes nothing" {
    seed_installed
    run "$REPO/uninstall.sh" everything
    [ "$status" -eq 2 ]
    assert_tree_unchanged
}

@test "every uninstall help example parses" {
    seed_installed
    run "$REPO/uninstall.sh" --help
    [ "$status" -eq 0 ]
    examples="$(printf '%s\n' "$output" | sed -n '/^Examples:$/,/^$/p' | sed -n 's/^  \.\/uninstall\.sh//p')"
    checked=0
    while IFS= read -r args; do
        # shellcheck disable=SC2086 # the words of one example
        run env __SESSION_SEARCH_PARSE_ONLY=1 "$REPO/uninstall.sh" $args
        [ "$status" -eq 0 ]
        assert_tree_unchanged
        checked=$((checked + 1))
    done <<<"$examples"
    [ "$checked" -ge 3 ]
}

@test "--version needs no HOME" {
    run env -u HOME "$REPO/uninstall.sh" --version
    [ "$status" -eq 0 ]
    [ "$output" = "$(cat "$REPO/VERSION")" ]
    run env -u HOME "$REPO/uninstall.sh" -v
    [ "$status" -eq 0 ]
    [ "$output" = "$(cat "$REPO/VERSION")" ]
}

@test "--version --json is one version document" {
    run --separate-stderr "$REPO/uninstall.sh" --version --json
    [ "$status" -eq 0 ]
    assert_one_json_doc
    [ "$(printf '%s' "$output" | jq -r .version)" = "$(cat "$REPO/VERSION")" ]
}

@test "--no-color and --non-interactive are accepted and the run still happens" {
    seed_installed
    run "$REPO/uninstall.sh" --no-color --non-interactive
    [ "$status" -eq 0 ]
    [ ! -L "$BIN/claude-search" ]
}

# ─── Removal ──────────────────────────────────────────────

@test "uninstall on a machine with nothing installed exits 0 and writes nothing" {
    empty="$HOME/empty-home"
    mkdir "$empty"
    run env HOME="$empty" "$REPO/uninstall.sh"
    [ "$status" -eq 0 ]
    has "$output" "Uninstall complete."
    lacks "$output" "Left in place:"
    [ -z "$(ls -A "$empty")" ]
}

# What a used install leaves, with a .bashrc that has no PATH line and so must not be listed.
# shellcheck disable=SC2016 # the lines as a profile holds them
seed_left_behind() {
    printf '# claude-session-search\nexport PATH="$HOME/.claude/bin:$PATH"\n' >"$HOME/.zshrc"
    printf 'export PATH="/opt/bin:$PATH"\n' >"$HOME/.bashrc"
    printf '{}' >"$SETTINGS.bak.Ab12Cd"
    mkdir -p "$HOME/.claude/logs"
    printf 'line\n' >"$HOME/.claude/logs/session-index.log"
    printf '[]' >"$HOME/.claude/.last-search-results.json"
    printf '{}' >"$HOME/.claude/.session-search-tips.json"
    LEFT_BEHIND=(
        "$HOME/.zshrc"
        "$SETTINGS.bak.Ab12Cd"
        "$HOME/.claude/logs"
        "$HOME/.claude/.last-search-results.json"
        "$HOME/.claude/.session-search-tips.json"
    )
}

@test "what stays is listed before the summary, and none of it changes" {
    seed_left_behind
    before="$(cd "$HOME" && cksum .zshrc .bashrc .claude/settings.json.bak.Ab12Cd .claude/logs/session-index.log \
        .claude/.last-search-results.json .claude/.session-search-tips.json)"
    run --separate-stderr "$REPO/uninstall.sh"
    [ "$status" -eq 0 ]
    for path in "${LEFT_BEHIND[@]}"; do
        has "$output" "  - $path ("
    done
    has "$output" "$HOME/.zshrc (PATH line)"
    lacks "$output" "  - $HOME/.bashrc"
    has "${output%%Uninstall complete.*}" "Left in place:"
    [ "$(cd "$HOME" && cksum .zshrc .bashrc .claude/settings.json.bak.Ab12Cd .claude/logs/session-index.log \
        .claude/.last-search-results.json .claude/.session-search-tips.json)" = "$before" ]
}

@test "--json marks what stays as skipped, on a real run and a dry run" {
    seed_left_behind
    for args in --json '--json --dry-run'; do
        # shellcheck disable=SC2086 # two words on purpose
        run --separate-stderr "$REPO/uninstall.sh" $args
        [ "$status" -eq 0 ]
        assert_one_json_doc
        for path in "${LEFT_BEHIND[@]}"; do
            printf '%s' "$output" | jq -e --arg id "$path" 'any(.results[]; .id == $id and .outcome == "skipped")'
        done
        printf '%s' "$output" | jq -e --arg id "$HOME/.bashrc" 'all(.results[]; .id != $id)'
    done
}

@test "uninstall removes every link install created" {
    # sandbox_setup's regular copies stand where install.sh links; it never overwrites a regular file.
    rm -f "$BIN/session-search.py" "$BIN/claude-search" "$HOOKS/session-index-end.sh" \
        "$HOOKS/session-index-start.sh" "$HOOKS/session-index-sweep.sh" "$HOOKS/lib/session-index-helpers.sh"
    # A fresh machine has no DB. The sandbox's demo DB has a synonyms table the backfill cannot use.
    rm -f "$DB"
    run "$REPO/install.sh"
    if [ "$status" -ne 0 ]; then
        printf 'install.sh exited %s:\n%s\n' "$status" "$output" >&2
        return 1
    fi
    [ "$(repo_links | wc -l | tr -d ' ')" -ge 9 ]
    ln -s /usr/bin/true "$BIN/unrelated-tool"
    db_before="$(cksum <"$DB")"

    run "$REPO/uninstall.sh"
    [ "$status" -eq 0 ]
    [ -z "$(repo_links)" ]
    [ "$(readlink "$BIN/unrelated-tool")" = /usr/bin/true ]
    [ "$(cksum <"$DB")" = "$db_before" ]
    [ "$(jq -r '[.hooks.SessionEnd[]?, .hooks.SessionStart[]?] | .[].hooks[].command' "$SETTINGS" | grep -c session-index)" = 0 ]
}

@test "uninstall removes the compiled session-search files and no other" {
    seed_installed
    : >"$BIN/__pycache__/session-search.cpython-310.pyc"
    : >"$BIN/__pycache__/other.cpython-311.pyc"
    run "$REPO/uninstall.sh"
    [ "$status" -eq 0 ]
    [ "$(find "$BIN/__pycache__" -type f)" = "$BIN/__pycache__/other.cpython-311.pyc" ]
}

@test "a regular file at a link path stays and is reported as skipped" {
    printf 'mine\n' >"$BIN/session-index-tag.py"
    run "$REPO/uninstall.sh"
    [ "$status" -eq 0 ]
    has "$output" "$BIN/session-index-tag.py is not a symlink, skipping"
    [ "$(cat "$BIN/session-index-tag.py")" = mine ]
}

@test "the database stays, with its -wal and -shm" {
    seed_installed
    : >"$DB-wal"
    : >"$DB-shm"
    db_before="$(cksum <"$DB")"
    run "$REPO/uninstall.sh"
    [ "$status" -eq 0 ]
    [ "$(cksum <"$DB")" = "$db_before" ]
    [ -e "$DB-wal" ]
    [ -e "$DB-shm" ]
}

@test "plists are unloaded, then deleted" {
    seed_installed
    run "$REPO/uninstall.sh"
    [ "$status" -eq 0 ]
    [ ! -e "$BACKFILL_PLIST" ]
    [ ! -e "$SWEEP_PLIST" ]
    calls launchctl | grep -qxF "$BACKFILL_PLIST"
    calls launchctl | grep -qxF "$SWEEP_PLIST"
}

# ─── settings.json ────────────────────────────────────────

@test "hook entries are removed and everything else stays" {
    seed_settings
    run "$REPO/uninstall.sh"
    [ "$status" -eq 0 ]
    has "$output" "✓ Hook entries removed from settings.json"
    jq -e '.model == "opus"
        and .hooks.SessionEnd == []
        and ([.hooks.SessionStart[].hooks[].command] == ["~/other-start.sh"])' "$SETTINGS"
    [ "$(backup_count)" -eq 1 ]
}

@test "absent keys are not created" {
    printf '{"model":"x"}' >"$SETTINGS"
    tree_snapshot
    run "$REPO/uninstall.sh"
    [ "$status" -eq 0 ]
    has "$output" "- no hook entries in settings.json"
    [ "$(cat "$SETTINGS")" = '{"model":"x"}' ]
    assert_tree_unchanged
}

@test "a prompt-type sibling survives" {
    cat >"$SETTINGS" <<'JSON'
{"hooks": {"SessionEnd": [{"hooks": [
    {"type": "prompt", "prompt": "summarize"},
    {"type": "command", "command": "~/.claude/hooks/session-index-end.sh"}
]}]}}
JSON
    run "$REPO/uninstall.sh"
    [ "$status" -eq 0 ]
    has "$output" "✓ Hook entries removed"
    jq -e '.hooks.SessionEnd == [{"hooks": [{"type": "prompt", "prompt": "summarize"}]}]' "$SETTINGS"
}

@test "odd shapes in settings.json do not stop the edit" {
    cat >"$SETTINGS" <<'JSON'
{"hooks": {
    "SessionEnd": ["a string entry", {"hooks": "not an array"},
        {"hooks": [7, {"command": 7}, {"command": "~/.claude/hooks/session-index-end.sh"}]}],
    "SessionStart": "not an array"
}}
JSON
    run "$REPO/uninstall.sh"
    [ "$status" -eq 0 ]
    has "$output" "✓ Hook entries removed"
    jq -e '.hooks.SessionStart == "not an array"
        and .hooks.SessionEnd == ["a string entry", {"hooks": "not an array"}, {"hooks": [7, {"command": 7}]}]' "$SETTINGS"
}

@test "symlink and mode are kept" {
    real="$HOME/dotfiles-settings.json"
    seed_settings
    mv "$SETTINGS" "$real"
    chmod 600 "$real"
    ln -s "$real" "$SETTINGS"
    run "$REPO/uninstall.sh"
    [ "$status" -eq 0 ]
    [ "$(readlink "$SETTINGS")" = "$real" ]
    # shellcheck disable=SC2012 # one known file, and stat's flags differ between macOS and Linux
    [ "$(ls -ln "$real" | cut -c1-10)" = "-rw-------" ]
    jq -e '.hooks.SessionEnd == []' "$real"
}

@test "invalid JSON exits 1 with bytes unchanged and plists still removed" {
    seed_installed
    printf '{"hooks": \n' >"$SETTINGS"
    before="$(cksum <"$SETTINGS")"
    run --separate-stderr "$REPO/uninstall.sh"
    [ "$status" -eq 1 ]
    has "$stderr" "ERROR: $SETTINGS is not valid JSON; left unchanged"
    has "$stderr" "Uninstall incomplete: fix $SETTINGS, then re-run ./uninstall.sh"
    lacks "$output" "Uninstall complete."
    [ "$(cksum <"$SETTINGS")" = "$before" ]
    [ "$(backup_count)" -eq 0 ]
    [ ! -e "$BACKFILL_PLIST" ]
    [ ! -e "$SWEEP_PLIST" ]
    calls launchctl | grep -qxF "$SWEEP_PLIST"
}

@test "a failed edit exits 1 and does not claim success" {
    seed_settings
    # A held lock is a failure css_settings_patch reports after its timeout.
    mkdir "$SETTINGS.lock.d"
    before="$(cksum <"$SETTINGS")"
    run --separate-stderr env __SESSION_SEARCH_LOCK_TRIES=3 "$REPO/uninstall.sh"
    [ "$status" -eq 1 ]
    has "$stderr" "ERROR: could not edit $SETTINGS; left unchanged"
    lacks "$output" "Hook entries removed"
    lacks "$output" "Uninstall complete."
    [ "$(cksum <"$SETTINGS")" = "$before" ]
}

@test "a rerun adds no backup" {
    seed_installed
    run "$REPO/uninstall.sh"
    [ "$status" -eq 0 ]
    [ "$(backup_count)" -eq 1 ]
    has "$output" "Backup: "
    has "$output" "settings.json.bak."
    tree_snapshot
    run "$REPO/uninstall.sh"
    [ "$status" -eq 0 ]
    [ "$(backup_count)" -eq 1 ]
    assert_tree_unchanged
}

@test "an earlier settings.json.bak is not overwritten" {
    seed_settings
    printf 'pre-install\n' >"$SETTINGS.bak"
    run "$REPO/uninstall.sh"
    [ "$status" -eq 0 ]
    [ "$(cat "$SETTINGS.bak")" = pre-install ]
}

@test "with no jq the edit is refused, plists still go, and the message names jq" {
    seed_installed
    mkdir "$HOME/nojq"
    ln -s /usr/bin/dirname "$HOME/nojq/dirname"
    ln -s /bin/rm "$HOME/nojq/rm"
    before="$(cksum <"$SETTINGS")"
    run --separate-stderr env PATH="$HOME/stubs:$HOME/nojq" "$REPO/uninstall.sh"
    [ "$status" -eq 1 ]
    has "$stderr" "ERROR: jq not found, so $SETTINGS was left unchanged"
    has "$stderr" "Uninstall incomplete: install jq, then re-run ./uninstall.sh"
    lacks "$stderr" "not valid JSON"
    [ "$(cksum <"$SETTINGS")" = "$before" ]
    [ ! -e "$BACKFILL_PLIST" ]
}

# ─── Preview ──────────────────────────────────────────────

@test "--dry-run changes nothing and lists every target" {
    seed_installed
    run --separate-stderr "$REPO/uninstall.sh" --dry-run
    [ "$status" -eq 0 ]
    assert_tree_unchanged
    [ -z "$(calls launchctl)" ]
    for target in "${LINKS[@]}"; do
        printf '%s\n' "$output" | grep -qxF "  remove $target"
    done
    printf '%s\n' "$output" | grep -qxF "  remove $PYC_PATTERN"
    printf '%s\n' "$output" | grep -qxF "  edit   $SETTINGS (remove hook entries, keep a backup)"
    printf '%s\n' "$output" | grep -qxF "  remove $BACKFILL_PLIST (unload and delete)"
    printf '%s\n' "$output" | grep -qxF "  remove $SWEEP_PLIST (unload and delete)"
    printf '%s\n' "$output" | grep -qxF "  keep   $DB"
}

@test "--dry-run says what a real run would skip, and exits 0 on invalid JSON" {
    printf 'not json' >"$SETTINGS"
    tree_snapshot
    run "$REPO/uninstall.sh" --dry-run
    [ "$status" -eq 0 ]
    has "$output" "  skip   $BIN/claude-search (not a symlink)"
    has "$output" "  absent $BIN/session-index-tag.py"
    has "$output" "  skip   $SETTINGS (not valid JSON, left unchanged)"
    assert_tree_unchanged
}

@test "delete hint quotes a HOME with a space and names -wal and -shm" {
    spaced="$HOME/with space"
    mkdir -p "$spaced/.claude"
    db="$spaced/.claude/session-index.db"
    : >"$db"
    : >"$db-wal"
    : >"$db-shm"
    run env HOME="$spaced" "$REPO/uninstall.sh"
    [ "$status" -eq 0 ]
    [ -e "$db" ]
    hint="$(printf '%s\n' "$output" | sed -n '/^To delete it:$/{n;p;}')"
    has "$hint" "  rm -f "
    # Run it: only correct quoting removes all three, and it names nothing outside the sandbox.
    bash -c "$hint"
    [ ! -e "$db" ]
    [ ! -e "$db-wal" ]
    [ ! -e "$db-shm" ]
    [ -d "$spaced/.claude" ]
}

@test "plan prints before the first removal" {
    seed_installed
    _write_stub rm <<'STUB'
printf 'RM-CALLED\n' >&2
PATH=/usr/bin:/bin exec rm "$@"
STUB
    run "$REPO/uninstall.sh"
    [ "$status" -eq 0 ]
    plan_end="$(printf '%s\n' "$output" | grep -nF "  keep   $DB" | head -1 | cut -d: -f1)"
    first_rm="$(printf '%s\n' "$output" | grep -n '^RM-CALLED$' | head -1 | cut -d: -f1)"
    [ -n "$plan_end" ]
    [ -n "$first_rm" ]
    [ "$plan_end" -lt "$first_rm" ]
}

@test "a real run prints the plan on stderr and keeps stdout's success lines" {
    seed_installed
    run --separate-stderr "$REPO/uninstall.sh"
    [ "$status" -eq 0 ]
    has "$stderr" "  remove $BIN/claude-search"
    lacks "$output" "  remove $BIN/claude-search"
    has "$output" "Uninstalling claude-session-search..."
    has "$output" "✓ Removed $BIN/claude-search"
    has "$output" "Uninstall complete."
    has "$output" "Database preserved at: $DB"
}

# ─── Machine output ───────────────────────────────────────

# The rows of the last --json run, one "id<TAB>outcome" per line, sorted.
json_rows() {
    printf '%s' "$output" | jq -r '.results[] | [.id, .outcome] | @tsv' | LC_ALL=C sort
}

expected_rows() {
    local target
    {
        for target in "${LINKS[@]}" "$PYC_PATTERN" "$SETTINGS" "$BACKFILL_PLIST" "$SWEEP_PLIST"; do
            printf '%s\t%s\n' "$target" "$1"
        done
        printf '%s\tskipped\n' "$DB"
    } | LC_ALL=C sort
}

@test "--json is one document with one row per target" {
    seed_installed
    run --separate-stderr "$REPO/uninstall.sh" --json
    [ "$status" -eq 0 ]
    assert_one_json_doc
    # The run's own settings backup stays too, under a random name.
    [ "$(json_rows | grep -Fv "$SETTINGS.bak.")" = "$(expected_rows removed)" ]
    [ "$(json_rows | grep -Fc "$SETTINGS.bak.")" -eq 1 ]
    printf '%s' "$output" | jq -e '.summary == {succeeded: 13, failed: 0, skipped: 2, unknown: 0}'
    has "$stderr" "Uninstall complete."
    [ ! -L "$BIN/claude-search" ]
}

@test "--json reports each real outcome" {
    # sandbox_setup left regular copies at some link paths and nothing at the others.
    run --separate-stderr "$REPO/uninstall.sh" --json
    [ "$status" -eq 0 ]
    assert_one_json_doc
    printf '%s' "$output" | jq -e --arg bin "$BIN" --arg settings "$SETTINGS" '
        (.results | map({key: .id, value: .outcome}) | from_entries) as $o
        | $o[$bin + "/claude-search"] == "skipped"
        and $o[$bin + "/session-index-tag.py"] == "not_found"
        and $o[$settings] == "not_found"
        and .summary == {succeeded: 0, failed: 0, skipped: 14, unknown: 0}'
}

@test "--json reports a failed settings edit as failed" {
    seed_installed
    printf 'not json' >"$SETTINGS"
    run --separate-stderr "$REPO/uninstall.sh" --json
    [ "$status" -eq 1 ]
    assert_one_json_doc
    printf '%s' "$output" | jq -e --arg settings "$SETTINGS" '
        (.results[] | select(.id == $settings)) == {id: $settings, outcome: "failed", error: "not valid JSON"}
        and .summary.failed == 1 and .summary.succeeded == 12'
}

@test "--json --dry-run changes nothing and reports planned rows" {
    seed_installed
    run --separate-stderr "$REPO/uninstall.sh" --json --dry-run
    [ "$status" -eq 0 ]
    assert_one_json_doc
    assert_tree_unchanged
    [ -z "$(calls launchctl)" ]
    [ "$(json_rows)" = "$(expected_rows planned)" ]
    printf '%s' "$output" | jq -e '.dry_run == true and .summary.planned == 13 and .summary.succeeded == 0'
}

@test "--json with no jq exits 1 before any effect" {
    seed_installed
    mkdir "$HOME/nojq"
    ln -s /usr/bin/dirname "$HOME/nojq/dirname"
    tree_snapshot
    run --separate-stderr env PATH="$HOME/nojq" "$REPO/uninstall.sh" --json
    [ "$status" -eq 1 ]
    [ -z "$output" ]
    has "$stderr" '"reason":"missing_dependency"'
    assert_tree_unchanged
}
