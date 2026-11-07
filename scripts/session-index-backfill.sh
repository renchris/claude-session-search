#!/bin/bash
# Idempotent backfill, run at install, weekly by launchd, and on stale index.
# Usage and options: session-index-backfill.sh --help
set -euo pipefail

_backfill_usage() {
    cat <<'USAGE'
Usage: session-index-backfill.sh [options]

Build or refresh the session index from all data sources. Safe to run again.

Options:
  -s, --since <TIME>  Only sessions changed since TIME. Default: all history.
                      TIME is whole days (1-36500), a relative value (7d, 12h)
                      or ISO 8601 (2026-03-01). With no offset, a date is UTC.
                      The last one given wins. An empty value is refused.
      --enrich-only   Skip discovery and only re-extract enrichment.
      --if-idle       Exit 0 without running if another run holds the index
                      lock, and log the skip. Default: wait for the lock.
      --json          Print one JSON document on stdout with the phase counts, and
                      send the progress to stderr. On failure, ok is false.
      --no-color      Print no color.
      --quiet         Hide the database line and the phase-start lines. Otherwise
                      no effect: the other output stays the same.
  -v, --version       Print the version.
  -h, --help          Show this help.

Examples:
  session-index-backfill.sh
  session-index-backfill.sh --enrich-only
  session-index-backfill.sh --since 7
  session-index-backfill.sh --since 12h
  session-index-backfill.sh --since 2026-03-01
  session-index-backfill.sh --enrich-only --since 3
  session-index-backfill.sh --json

Notes:
  Needs sqlite3, jq and python3. Reads and writes ~/.claude.
  A locked database is retried a few times, up to 60 seconds per try.
  SESSION_INDEX_BUSY_TIMEOUT sets that wait, in milliseconds.

Exit codes:
  0              Success, or skipped by --if-idle.
  1              Failure, including a missing prerequisite or file.
  2              Usage error.
  5              The database stayed locked. A re-run is safe.
  129, 130, 143  Stopped by HUP, INT or TERM.
  Other          A failed step's own exit code.
USAGE
}

# This scan runs before any source, so help needs no DB or library and wins over other validation.
if [ "${1:-}" = help ]; then
    _backfill_usage
    exit 0
fi
_since_given=0
for _arg in "$@"; do
    case "$_arg" in
        --) break ;;
        -h | --help)
            _backfill_usage
            exit 0
            ;;
        # The parser leaves an empty value looking like no option at all.
        -s | --since | --since=*) _since_given=1 ;;
    esac
done

# The name on PATH is a symlink into ~/.claude/bin, so follow the whole chain to find the repo.
# A loop, because `readlink -f` is missing on older macOS.
_self="$0"
while [ -L "$_self" ]; do
    _link="$(readlink "$_self")"
    case "$_link" in
        /*) _self="$_link" ;;
        *) _self="$(dirname "$_self")/$_link" ;;
    esac
done
SCRIPT_DIR="$(cd -P "$(dirname "$_self")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"

_require_file() {
    if [ ! -f "$1" ]; then
        printf 'session-index-backfill: cannot find %s (resolved repo: %s). Re-run install.sh from the claude-session-search checkout.\n' \
            "$1" "$REPO_DIR" >&2
        exit 1
    fi
}

_require_file "$SCRIPT_DIR/lib/cli-common.sh"
# shellcheck disable=SC1091 # bare shellcheck does not follow sources
source "$SCRIPT_DIR/lib/cli-common.sh"

_PROG=session-index-backfill.sh
_enrich_flag=0
_if_idle_flag=0
_quiet_flag=0
_json_flag=0
_no_color_flag=0
_version_flag=0
_since_value=""
# Parse-only stops below instead, so that a help example with a bad --since fails too.
__SESSION_SEARCH_PARSE_ONLY='' css_parse_args "$_PROG" \
    "quiet||bool|_quiet_flag" \
    "enrich-only||bool|_enrich_flag" \
    "if-idle||bool|_if_idle_flag" \
    "since|s|value|_since_value" \
    "json||bool|_json_flag" \
    "no-color||bool|_no_color_flag" \
    "version|v|bool|_version_flag" \
    "help|h|bool|_help_flag" \
    -- "$@"
ENRICH_ONLY=false
if [ "$_enrich_flag" = 1 ]; then
    ENRICH_ONLY=true
fi
QUIET=false
if [ "$_quiet_flag" = 1 ]; then
    QUIET=true
fi
if [ "$_no_color_flag" = 1 ]; then
    export __SESSION_SEARCH_NO_COLOR=1
fi

if [ "$_version_flag" = 1 ]; then
    if [ "$_json_flag" = 1 ]; then
        printf '{"version":"%s"}\n' "$(_css_json_escape "$(css_version "$REPO_DIR")")"
    else
        css_version "$REPO_DIR"
    fi
    exit 0
fi

# ─── --json ────────────────────────────────────────────────

# The step a failure is reported against.
_bf_phase="Startup"

# The counters, as a JSON object. A skipped or unreached phase counts 0.
_backfill_counts_json() {
    jq -cn \
        --argjson p1 "${phase1_count:-0}" \
        --argjson p2 "${phase2_count:-0}" --argjson p2s "${phase2_skip:-0}" \
        --argjson p3 "${phase3_count:-0}" \
        --argjson p4e "${phase4_enriched:-0}" --argjson p4i "${phase4_inserted:-0}" --argjson p4s "${phase4_skipped:-0}" \
        --argjson p4bi "${phase4b_indexed:-0}" --argjson p4bb "${phase4b_bad:-0}" \
        --argjson p5e "${phase5_enriched:-0}" --argjson p5s "${phase5_skipped:-0}" --argjson p5n "${phase5_nofound:-0}" \
        --argjson fts "${_fts_count:-0}" --argjson syn "${_syn_count:-0}" \
        --argjson chunks "${_chunk_count:-0}" \
        --argjson total "${total:-0}" --argjson untagged "${untagged:-0}" \
        '{phases: {
            phase1: {indexed: $p1},
            phase2: {new: $p2, skipped: $p2s},
            phase3: {synthetic: $p3},
            phase4: {enriched: $p4e, inserted: $p4i, skipped: $p4s},
            phase4b: {indexed: $p4bi, unreadable: $p4bb},
            phase5: {enriched: $p5e, empty: $p5s, no_transcript: $p5n},
            phase6: {fts_entries: $fts, synonyms: $syn},
            phase7: {chunks: $chunks}
        }, total: $total, untagged: $untagged}'
}

# The failure document on fd 3, keeping exit status RC. Does nothing without --json or on success.
# The fallback is for a failure before jq could run; its strings are the constant phase names.
_backfill_json_failure() {
    local rc="$1" counts
    if [ "$_json_flag" != 1 ] || [ "$rc" = 0 ]; then
        return 0
    fi
    counts=$(_backfill_counts_json 2>/dev/null) || counts='{}'
    jq -cn --argjson rc "$rc" --arg phase "$_bf_phase" --arg db "${SESSION_INDEX_DB:-}" \
        --argjson counts "$counts" \
        '{ok: false, exit_code: $rc, phase: $phase, database: $db,
          message: "backfill failed in \($phase) (exit \($rc)). A re-run is safe."} + $counts' \
        >&3 2>/dev/null ||
        printf '{"ok":false,"exit_code":%d,"phase":"%s"}\n' "$rc" "$_bf_phase" >&3
}

if [ "$_json_flag" = 1 ]; then
    export __SESSION_SEARCH_NON_INTERACTIVE=1
    # Before progress-ui.sh is sourced, so its check of stdout sees stderr. Fd 3 holds the document.
    exec 3>&1 1>&2
    trap '_backfill_json_failure "$?"' EXIT
fi

_require_file "$REPO_DIR/hooks/lib/session-index-helpers.sh"
_require_file "$SCRIPT_DIR/lib/progress-ui.sh"
_require_file "$SCRIPT_DIR/lib/cli_common.py"

# ─── Prerequisites ─────────────────────────────────────────

for _tool in sqlite3 jq python3; do
    if ! command -v "$_tool" >/dev/null 2>&1; then
        css_fail "$_tool not found" "Install $_tool, then run session-index-backfill.sh again."
    fi
done

# ─── --since ───────────────────────────────────────────────
# SINCE_DAYS is empty with no --since. Otherwise it is a whole number of days, rounded up, because
# session-index-chunk.py takes that form and a wider window only chunks a superset. SINCE_EPOCH is
# always an integer, which is what keeps SINCE_FILTER's SQL free of user input.

_refuse_since() {
    css_usage_fail "$_PROG" "invalid --since '$1': whole days 1-36500, a relative value (7d, 12h), or ISO 8601."
}

SINCE_DAYS=""
SINCE_EPOCH=0
SINCE_FILTER=""
SINCE_LABEL=""
if [ "$_since_given" = 1 ]; then
    # parse-time alone takes 0h, 007 and 100000, so a count is bounded here.
    _since_amount="${_since_value%[dhm]}"
    case "$_since_amount" in
        "" | *[!0-9]*) SINCE_LABEL="since $_since_value" ;;
        0*) _refuse_since "$_since_value" ;;
        *)
            case "$_since_value" in
                *[hm]) SINCE_LABEL="last $_since_value" ;;
                *)
                    if [ "${#_since_amount}" -gt 5 ] || [ "$_since_amount" -gt 36500 ]; then
                        _refuse_since "$_since_value"
                    fi
                    SINCE_DAYS="$_since_amount"
                    SINCE_LABEL="last ${_since_amount}d"
                    ;;
            esac
            ;;
    esac

    _since_rc=0
    SINCE_EPOCH="$(python3 "$SCRIPT_DIR/lib/cli_common.py" parse-time "$_since_value" --min-days 1 2>/dev/null)" || _since_rc=$?
    if [ "$_since_rc" = 2 ]; then
        _refuse_since "$_since_value"
    fi
    if [ "$_since_rc" != 0 ]; then
        css_fail "could not read --since: cli_common.py exited $_since_rc" "Run it directly to see why" \
            "python3 $SCRIPT_DIR/lib/cli_common.py parse-time 7"
    fi
    # --since=-h reaches argparse as its own help, which exits 0.
    case "$SINCE_EPOCH" in
        "" | *[!0-9-]*) _refuse_since "$_since_value" ;;
    esac

    if [ -z "$SINCE_DAYS" ]; then
        SINCE_DAYS=$((($(date +%s) - SINCE_EPOCH + 86399) / 86400))
        # chunk.py reads 0 as no cutoff, which a future date must not become. The ceiling reaches
        # back past any file's mtime, and chunk.py overflows on a date near year 1.
        if [ "$SINCE_DAYS" -lt 1 ]; then
            SINCE_DAYS=1
        elif [ "$SINCE_DAYS" -gt 36500 ]; then
            SINCE_DAYS=36500
        fi
    fi
    SINCE_FILTER="AND modified_at > datetime($SINCE_EPOCH,'unixepoch')"
fi

if [ "${__SESSION_SEARCH_PARSE_ONLY:-}" = 1 ]; then
    exit 0
fi

# Before the source, whose own default is 5 seconds: logged lock failures got through that default.
# Each locked statement waits this long, and session_index_retry_busy repeats the bulk writes.
export SESSION_INDEX_BUSY_TIMEOUT="${SESSION_INDEX_BUSY_TIMEOUT:-60000}"

source "$REPO_DIR/hooks/lib/session-index-helpers.sh"
source "$SCRIPT_DIR/lib/progress-ui.sh"

if [ "$QUIET" = "true" ]; then
    # shellcheck disable=SC2034 # session_index_retry_busy reads it
    SESSION_INDEX_RETRY_NOTICE=""
else
    _UI_PHASE_LINES=true
fi

# ─── Cleanup ───────────────────────────────────────────────
# Here and not in the helpers or the UI library, whose traps the hooks and install.sh depend on.

TMPFILE=""
_P5_TMP=""
_BF_CHILD=""

# Calls no exit, so the status survives. Errexit goes off first for the same reason.
_backfill_cleanup() {
    local rc=$?
    set +e
    if [ -n "${_BF_CHILD:-}" ]; then
        kill "$_BF_CHILD" 2>/dev/null
    fi
    _ui_cleanup
    rm -f "${TMPFILE:-}" "${_P5_TMP:-}" 2>/dev/null
    session_index_unlock
    _backfill_json_failure "$rc"
}

_backfill_on_signal() {
    trap - INT TERM HUP
    exit "$1"
}

# EXIT only for now: a signal trap would hold a stop request until the wait for the lock ends.
trap '_backfill_cleanup' EXIT

[ "$QUIET" = "true" ] || echo "Session index: $SESSION_INDEX_DB" >&2

# ─── Acquire exclusive lock (blocks if tagger/another backfill is running) ───

if [ "$_if_idle_flag" = 1 ]; then
    if ! session_index_trylock; then
        session_index_log "Backfill skipped: index busy"
        if [ "$_json_flag" = 1 ]; then
            jq -cn --arg db "$SESSION_INDEX_DB" '{ok: true, skipped: true, reason: "index_busy", database: $db}' >&3
        fi
        exit 0
    fi
else
    session_index_lock
fi

# The lock replaced the EXIT trap, so this has to come after it. No PIPE: the repo plist pipes this
# script into `head -50`, and a closed pipe keeps its old meaning there.
trap '_backfill_cleanup' EXIT
trap '_backfill_on_signal 130' INT
trap '_backfill_on_signal 143' TERM
trap '_backfill_on_signal 129' HUP
# It only adds a line: errexit still ends the run, with the failed step's status.
_bf_rc=0
trap '_bf_rc=$?; echo "error: backfill failed at line $LINENO (exit $_bf_rc)" >&2' ERR

# ─── Init DB ───────────────────────────────────────────────

session_index_init_db

# A time that can't be read says nothing about age, so the row stays. Writes are repeatable, and one
# warning per run keeps the scheduled job's output short.
_time_warned=false
_warn_unknown_time() {
    if [ "$_time_warned" = false ]; then
        _time_warned=true
        css_warn "Can't read a session's time. Keeping it despite --since."
    fi
}

# ─── Pre-count totals for progress tracking ────────────────

_backfill_start=$(_ui_now)

# Count existing sessions for the header
_existing_total=$(session_index_sql "SELECT COUNT(*) FROM sessions;" 2>/dev/null || echo 0)

# Count transcript files for Phase 4 progress (flat + subdirectory layouts)
_transcript_total=0
for _pd in "$CLAUDE_PROJECTS_DIR"/*/; do
    # Flat layout: {project_dir}/{session_id}.jsonl
    for _tf in "$_pd"*.jsonl; do
        [ -f "$_tf" ] || continue
        _fn=$(basename "$_tf" .jsonl)
        [[ "$_fn" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] || continue
        _transcript_total=$((_transcript_total + 1))
    done
    # Subdirectory layout: {project_dir}/{session_id}/transcript.jsonl
    for _sd in "$_pd"*/; do
        [ -d "$_sd" ] || continue
        _dn=$(basename "$_sd")
        [[ "$_dn" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] || continue
        [ -f "$_sd/transcript.jsonl" ] || continue
        # Don't double-count if flat file also exists
        [ -f "$_pd${_dn}.jsonl" ] && continue
        _transcript_total=$((_transcript_total + 1))
    done
done

# ─── Header ────────────────────────────────────────────────

if [ -n "$SINCE_DAYS" ]; then
    _header_detail="${SINCE_LABEL}  ${_existing_total} existing"
else
    _header_detail="${_existing_total} existing"
fi
if [ "$ENRICH_ONLY" = "true" ]; then
    _header_detail="enrich-only  $_header_detail"
fi

ui_header "Session Index Backfill" "$_header_detail"
ui_cursor_hide

# ─── Phases 1-3: Session discovery (skipped with --enrich-only) ───

if [ "$ENRICH_ONLY" = "true" ]; then
    ui_phase_skip "Phase 1: Session index scan" "--enrich-only"
    ui_phase_skip "Phase 2: History gap fill" "--enrich-only"
    ui_phase_skip "Phase 3: Legacy entries" "--enrich-only"
else

# ─── Phase 1: sessions-index.json (highest quality) ───────

_bf_phase="Phase 1: Session index scan"
_p1_start=$(_ui_now)
phase1_count=0

# Pre-count Phase 1 entries for progress bar
_p1_total=0
for project_dir in "$CLAUDE_PROJECTS_DIR"/*/; do
    index_file="$project_dir/sessions-index.json"
    [ -f "$index_file" ] || continue
    _ec=$(jq '[.entries[] | select(.sessionId != null and .sessionId != "" and (.isSidechain // false | not))] | length' "$index_file" 2>/dev/null || echo 0)
    _p1_total=$((_p1_total + _ec))
done

if [ "$_p1_total" -eq 0 ]; then
    ui_phase_skip "Phase 1: Session index scan" "no entries"
else
    ui_phase_active "Phase 1: Session index scan" 0 "$_p1_total" "$_p1_start"

    for project_dir in "$CLAUDE_PROJECTS_DIR"/*/; do
        index_file="$project_dir/sessions-index.json"
        [ -f "$index_file" ] || continue

        entry_count=$(jq '.entries | length' "$index_file" 2>/dev/null || echo 0)
        [ "$entry_count" -eq 0 ] && continue

        # Dump all entries to a temp file (avoids subshell counter loss from pipes)
        TMPFILE=$(mktemp)
        # Output one JSON object per line (JSONL) — robust against tabs/newlines in fields
        jq -c '.entries[] | select(.sessionId != null and .sessionId != "" and (.isSidechain // false | not)) |
            {
                sid: .sessionId,
                summary: (.summary // ""),
                first_prompt: (.firstPrompt // "" | gsub("[\\n\\t]"; " ") | .[:500]),
                branch: (.gitBranch // ""),
                created: (.created // ""),
                modified: (.modified // ""),
                msg_count: ((.messageCount // 0) | tostring),
                project_path: (.projectPath // ""),
                full_path: (.fullPath // "")
            }' "$index_file" > "$TMPFILE" 2>/dev/null || true

        while IFS= read -r json_line; do
            [ -z "$json_line" ] && continue
            sid=$(echo "$json_line" | jq -r '.sid')
            [ -z "$sid" ] || [ "$sid" = "null" ] && continue

            summary=$(echo "$json_line" | jq -r '.summary')
            first_prompt=$(echo "$json_line" | jq -r '.first_prompt')
            branch=$(echo "$json_line" | jq -r '.branch')
            created=$(echo "$json_line" | jq -r '.created')
            modified=$(echo "$json_line" | jq -r '.modified')
            msg_count=$(echo "$json_line" | jq -r '.msg_count')
            project_path=$(echo "$json_line" | jq -r '.project_path')
            full_path=$(echo "$json_line" | jq -r '.full_path')

            # --since filter: skip sessions older than threshold
            if [ -n "$SINCE_DAYS" ] && [ -n "$modified" ] && [ "$modified" != "null" ]; then
                mod_epoch=$(session_index_date_to_epoch "${modified%%.*}" 2>/dev/null || echo "")
                if [ -z "$mod_epoch" ]; then
                    _warn_unknown_time
                elif [ "$mod_epoch" -lt "$SINCE_EPOCH" ]; then
                    continue
                fi
            fi

            # Use projectPath from JSON; fallback
            if [ -z "$project_path" ] || [ "$project_path" = "null" ]; then
                project_path="unknown"
            fi
            project_name=$(basename "$project_path")

            # Extract context_text from transcript (first 5 user messages)
            # Try fullPath first, then <project_dir>/<sid>.jsonl
            context_text=""
            transcript_file=""
            if [ -n "$full_path" ] && [ "$full_path" != "null" ] && [ -f "$full_path" ]; then
                transcript_file="$full_path"
            elif [ -f "${project_dir}${sid}.jsonl" ]; then
                transcript_file="${project_dir}${sid}.jsonl"
            fi
            if [ -n "$transcript_file" ]; then
                context_text=$(session_index_extract_context "$transcript_file" 5)
            fi

            keywords=$(session_index_extract_keywords "$summary $first_prompt $context_text" 2>/dev/null || echo "")
            session_index_retry_busy session_index_upsert \
                "$sid" \
                "$project_path" \
                "$project_name" \
                "$summary" \
                "$first_prompt" \
                "$branch" \
                "$created" \
                "$modified" \
                "${msg_count:-0}" \
                "" \
                "$keywords" \
                "sessions-index" \
                "$context_text"

            phase1_count=$((phase1_count + 1))
            ui_should_update "$phase1_count" "$_p1_total" && \
                ui_phase_active "Phase 1: Session index scan" "$phase1_count" "$_p1_total" "$_p1_start"
        done < "$TMPFILE"

        rm -f "$TMPFILE"
    done

    ui_phase_done "Phase 1: Session index scan" "$phase1_count indexed" "$_p1_start"
fi

# ─── Phase 2: history.jsonl (gap fill) ────────────────────

_bf_phase="Phase 2: History gap fill"
_p2_start=$(_ui_now)
phase2_count=0
phase2_skip=0

if [ -f "$CLAUDE_HISTORY" ]; then
    # Extract entries with sessionId, group to get first prompt per session
    TMPFILE=$(mktemp)
    jq -r 'select(.sessionId != null and .sessionId != "") |
        [
            .sessionId,
            (.display // "" | gsub("\n"; " ") | .[:500]),
            (.project // ""),
            ((.timestamp // 0) | tostring)
        ] | @tsv' "$CLAUDE_HISTORY" 2>/dev/null | \
    sort -t$'\t' -k1,1 -k4,4n | \
    awk -F'\t' '!seen[$1]++ { print }' > "$TMPFILE" || true

    _p2_total=$(wc -l < "$TMPFILE" | tr -d ' ')

    if [ "$_p2_total" -eq 0 ]; then
        ui_phase_skip "Phase 2: History gap fill" "no entries"
    else
        _p2_processed=0
        ui_phase_active "Phase 2: History gap fill" 0 "$_p2_total" "$_p2_start"

        while IFS=$'\t' read -r sid display project_path timestamp_ms; do
            _p2_processed=$((_p2_processed + 1))
            [ -z "$sid" ] && continue
            [ -z "$project_path" ] && continue

            # --since filter: skip sessions older than threshold
            if [ -n "$SINCE_DAYS" ] && [ -n "$timestamp_ms" ] && [ "$timestamp_ms" != "0" ]; then
                ts_epoch=$((timestamp_ms / 1000))
                [ "$ts_epoch" -lt "$SINCE_EPOCH" ] && continue
            fi

            # Check if already indexed from Phase 1
            existing=$(session_index_sql "SELECT source FROM sessions WHERE session_id='$(echo "$sid" | sed "s/'/''/g")' LIMIT 1;" 2>/dev/null || echo "")
            if [ "$existing" = "sessions-index" ]; then
                phase2_skip=$((phase2_skip + 1))
                ui_should_update "$_p2_processed" "$_p2_total" && \
                    ui_phase_active "Phase 2: History gap fill" "$_p2_processed" "$_p2_total" "$_p2_start"
                continue
            fi

            project_name=$(basename "$project_path")

            # Convert epoch ms to ISO8601
            created_at=""
            if [ -n "$timestamp_ms" ] && [ "$timestamp_ms" != "0" ]; then
                epoch_sec=$((timestamp_ms / 1000))
                created_at=$(session_index_epoch_to_iso "$epoch_sec" 2>/dev/null || echo "")
            fi
            [ -z "$created_at" ] && created_at=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

            keywords=$(session_index_extract_keywords "$display" 2>/dev/null || echo "")
            session_index_retry_busy session_index_upsert \
                "$sid" \
                "$project_path" \
                "$project_name" \
                "" \
                "$display" \
                "" \
                "$created_at" \
                "$created_at" \
                1 \
                "" \
                "$keywords" \
                "history"

            phase2_count=$((phase2_count + 1))
            ui_should_update "$_p2_processed" "$_p2_total" && \
                ui_phase_active "Phase 2: History gap fill" "$_p2_processed" "$_p2_total" "$_p2_start"
        done < "$TMPFILE"

        ui_phase_done "Phase 2: History gap fill" "$phase2_count new, $phase2_skip skipped" "$_p2_start"
    fi

    rm -f "$TMPFILE"
else
    ui_phase_skip "Phase 2: History gap fill" "no history.jsonl"
fi

# ─── Phase 3: Legacy entries (no sessionId) ───────────────

_bf_phase="Phase 3: Legacy entries"
_p3_start=$(_ui_now)
phase3_count=0

if [ -f "$CLAUDE_HISTORY" ]; then
    TMPFILE=$(mktemp)
    jq -r 'select(.sessionId == null or .sessionId == "") |
        [
            (.display // "" | gsub("\n"; " ") | .[:500]),
            (.project // ""),
            ((.timestamp // 0) | tostring)
        ] | @tsv' "$CLAUDE_HISTORY" 2>/dev/null | \
    sort -t$'\t' -k2,2 -k3,3n | \
    awk -F'\t' '
    BEGIN { gap = 300000 }
    {
        display = $1; project = $2; ts = $3
        key = project
        if (key != prev_key || ts - prev_ts > gap) {
            if (NR > 1 && prev_key != "" && first_display != "") {
                print first_display "\t" prev_key "\t" first_ts "\t" last_ts "\t" count
            }
            first_display = display; first_ts = ts; count = 1
        } else {
            count++
        }
        last_ts = ts; prev_key = key; prev_ts = ts
    }
    END {
        if (prev_key != "" && first_display != "") {
            print first_display "\t" prev_key "\t" first_ts "\t" last_ts "\t" count
        }
    }' > "$TMPFILE" || true

    _p3_total=$(wc -l < "$TMPFILE" | tr -d ' ')

    if [ "$_p3_total" -eq 0 ]; then
        ui_phase_skip "Phase 3: Legacy entries" "no entries"
    else
        _p3_processed=0
        ui_phase_active "Phase 3: Legacy entries" 0 "$_p3_total" "$_p3_start"

        while IFS=$'\t' read -r display project_path first_ts last_ts count; do
            _p3_processed=$((_p3_processed + 1))
            [ -z "$project_path" ] && continue

            # --since filter: skip sessions older than threshold
            if [ -n "$SINCE_DAYS" ] && [ -n "$last_ts" ] && [ "$last_ts" != "0" ]; then
                ts_epoch=$((last_ts / 1000))
                [ "$ts_epoch" -lt "$SINCE_EPOCH" ] && continue
            fi

            # Generate synthetic ID
            synthetic_id="legacy-$(echo -n "${display}${first_ts}" | shasum -a 256 | cut -c1-16)"
            project_name=$(basename "$project_path")

            # Convert epoch ms to ISO8601
            created_at=""
            if [ -n "$first_ts" ] && [ "$first_ts" != "0" ]; then
                epoch_sec=$((first_ts / 1000))
                created_at=$(session_index_epoch_to_iso "$epoch_sec" 2>/dev/null || echo "")
            fi
            [ -z "$created_at" ] && created_at=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

            modified_at="$created_at"
            if [ -n "$last_ts" ] && [ "$last_ts" != "0" ]; then
                epoch_sec=$((last_ts / 1000))
                modified_at=$(session_index_epoch_to_iso "$epoch_sec" 2>/dev/null || echo "$created_at")
            fi

            keywords=$(session_index_extract_keywords "$display" 2>/dev/null || echo "")
            session_index_retry_busy session_index_upsert \
                "$synthetic_id" \
                "$project_path" \
                "$project_name" \
                "" \
                "$display" \
                "" \
                "$created_at" \
                "$modified_at" \
                "${count:-1}" \
                "" \
                "$keywords" \
                "history-legacy"

            phase3_count=$((phase3_count + 1))
            ui_should_update "$_p3_processed" "$_p3_total" && \
                ui_phase_active "Phase 3: Legacy entries" "$_p3_processed" "$_p3_total" "$_p3_start"
        done < "$TMPFILE"

        ui_phase_done "Phase 3: Legacy entries" "$phase3_count synthetic" "$_p3_start"
    fi

    rm -f "$TMPFILE"
else
    ui_phase_skip "Phase 3: Legacy entries" "no history.jsonl"
fi

fi  # end --enrich-only skip

# ─── Phase 4: Enrich from transcript files ────────────────
# Runs AFTER all other phases so every session is in the DB.
# Scans .jsonl transcripts: updates context_text + message_count for existing rows,
# INSERTs new rows for transcript-only sessions.

_bf_phase="Phase 4: Transcript enrichment"
_p4_start=$(_ui_now)
phase4_enriched=0
phase4_inserted=0
phase4_skipped=0
_p4_processed=0

if [ "$_transcript_total" -eq 0 ]; then
    ui_phase_skip "Phase 4: Transcript enrichment" "no transcripts"
else
    ui_phase_active "Phase 4: Transcript enrichment" 0 "$_transcript_total" "$_p4_start"

    for project_dir in "$CLAUDE_PROJECTS_DIR"/*/; do
        dir_name=$(basename "$project_dir")
        proj_path=$(echo "$dir_name" | sed 's/^-/\//' | sed 's/-/\//g')
        proj_name=$(basename "$proj_path")

        # Collect transcripts: flat ({sid}.jsonl) and subdirectory ({sid}/transcript.jsonl)
        _p4_transcripts=()
        _p4_sids=()

        for transcript in "$project_dir"*.jsonl; do
            [ -f "$transcript" ] || continue
            sid=$(basename "$transcript" .jsonl)
            [[ "$sid" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] || continue
            _p4_transcripts+=("$transcript")
            _p4_sids+=("$sid")
        done

        for subdir in "$project_dir"*/; do
            [ -d "$subdir" ] || continue
            sid=$(basename "$subdir")
            [[ "$sid" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] || continue
            [ -f "$subdir/transcript.jsonl" ] || continue
            # Skip if flat file already queued (prefer flat — same content)
            [ -f "$project_dir${sid}.jsonl" ] && continue
            _p4_transcripts+=("$subdir/transcript.jsonl")
            _p4_sids+=("$sid")
        done

        for _idx in "${!_p4_transcripts[@]}"; do
            transcript="${_p4_transcripts[$_idx]}"
            sid="${_p4_sids[$_idx]}"

            _p4_processed=$((_p4_processed + 1))
            ui_should_update "$_p4_processed" "$_transcript_total" && \
                ui_phase_active "Phase 4: Transcript enrichment" "$_p4_processed" "$_transcript_total" "$_p4_start"

            # Skip if already enriched (unless --enrich-only which means force re-enrich)
            if [ "$ENRICH_ONLY" != "true" ]; then
                _sid_check=$(echo "$sid" | sed "s/'/''/g")
                already_enriched=$(session_index_sql \
                    "SELECT 1 FROM sessions WHERE session_id='$_sid_check' AND length(context_text) > 0 AND length(assistant_text) > 0 LIMIT 1;" \
                    2>/dev/null || echo "")
                if [ -n "$already_enriched" ]; then
                    phase4_skipped=$((phase4_skipped + 1))
                    continue
                fi
            fi

            # Extract context and message count from transcript
            context_text=$(session_index_extract_context "$transcript" 10)
            msg_count=$(session_index_extract_transcript_meta "$transcript")
            [ -z "$context_text" ] && [ "${msg_count:-0}" -lt 2 ] && continue

            # Extract enriched data (assistant text, file paths, commands)
            enriched_data=$(session_index_extract_enriched "$transcript")
            IFS=$'\t' read -r assistant_text files_changed commands_run <<< "$enriched_data"

            ctx_escaped=$(echo "$context_text" | sed "s/'/''/g")
            at_escaped=$(echo "$assistant_text" | sed "s/'/''/g")
            fc_escaped=$(echo "$files_changed" | sed "s/'/''/g")
            cr_escaped=$(echo "$commands_run" | sed "s/'/''/g")
            sid_escaped=$(echo "$sid" | sed "s/'/''/g")

            exists=$(session_index_sql "SELECT 1 FROM sessions WHERE session_id='$sid_escaped' $SINCE_FILTER LIMIT 1;" 2>/dev/null || echo "")

            # These writes keep stdin, not session_index_sql: its stdin mode re-passes the SQL as one
            # argument, and Linux caps one argument at 128 KiB, under the largest row.
            if [ -n "$exists" ]; then
                sqlite3 "$SESSION_INDEX_DB" <<SQL
.timeout $SESSION_INDEX_BUSY_TIMEOUT
UPDATE sessions SET
    context_text = '$ctx_escaped',
    assistant_text = CASE WHEN '$at_escaped' != '' THEN '$at_escaped' ELSE assistant_text END,
    files_changed = CASE WHEN '$fc_escaped' != '' THEN '$fc_escaped' ELSE files_changed END,
    commands_run = CASE WHEN '$cr_escaped' != '' THEN '$cr_escaped' ELSE commands_run END,
    message_count = CASE WHEN $msg_count > message_count THEN $msg_count ELSE message_count END
WHERE session_id = '$sid_escaped' $SINCE_FILTER;
SQL
                phase4_enriched=$((phase4_enriched + 1))
            else
                # --since filter for new sessions: check file mtime
                if [ -n "$SINCE_DAYS" ]; then
                    file_epoch=$(session_index_file_epoch "$transcript" 2>/dev/null || echo "")
                    if [ -z "$file_epoch" ]; then
                        _warn_unknown_time
                    elif [ "$file_epoch" -lt "$SINCE_EPOCH" ]; then
                        continue
                    fi
                fi
                now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
                file_mtime=$(session_index_file_mtime_iso "$transcript" 2>/dev/null || echo "$now")
                first_prompt=$(echo "$context_text" | head -c 500)
                fp_escaped=$(echo "$first_prompt" | sed "s/'/''/g")
                pp_escaped=$(echo "$proj_path" | sed "s/'/''/g")
                pn_escaped=$(echo "$proj_name" | sed "s/'/''/g")
                keywords=$(session_index_extract_keywords "$context_text" 2>/dev/null || echo "")
                kw_escaped=$(echo "$keywords" | sed "s/'/''/g")

                sqlite3 "$SESSION_INDEX_DB" <<SQL
.timeout $SESSION_INDEX_BUSY_TIMEOUT
INSERT OR IGNORE INTO sessions (session_id, project_path, project_name, summary, first_prompt,
    context_text, assistant_text, files_changed, commands_run,
    git_branch, created_at, modified_at, message_count, tags, keywords, source, indexed_at)
VALUES ('$sid_escaped', '$pp_escaped', '$pn_escaped', '', '$fp_escaped',
    '$ctx_escaped', '$at_escaped', '$fc_escaped', '$cr_escaped',
    '', '$file_mtime', '$file_mtime', $msg_count, '', '$kw_escaped', 'transcript', '$now');
SQL
                phase4_inserted=$((phase4_inserted + 1))
            fi
        done
    done

    _p4_summary="$phase4_enriched enriched, $phase4_inserted new"
    [ "$phase4_skipped" -gt 0 ] && _p4_summary="$_p4_summary, $phase4_skipped skipped"
    ui_phase_done "Phase 4: Transcript enrichment" "$_p4_summary" "$_p4_start"
fi

# ─── Phase 4b: Workflow result files ──────────────────────
# A Dynamic Workflow's result lives only in {project_dir}/{session_id}/workflows/wf_*.json.
# Each becomes its OWN row keyed on the file stem (`wf_…`), with the same rules as the sweep:
# source 'workflow-sweep', the parent's project, never the parent's row. Phase 6 rebuilds FTS.

_bf_phase="Phase 4b: Workflow results"
_p4b_start=$(_ui_now)
phase4b_indexed=0
phase4b_bad=0
for project_dir in "$CLAUDE_PROJECTS_DIR"/*/; do
    dir_name=$(basename "$project_dir")
    proj_path=$(echo "$dir_name" | sed 's/^-/\//' | sed 's/-/\//g')
    proj_name=$(session_index_project_name "$proj_path")
    for wf in "$project_dir"*/workflows/wf_*.json; do
        [ -f "$wf" ] || continue
        if [ -n "$SINCE_DAYS" ]; then
            file_epoch=$(session_index_file_epoch "$wf" 2>/dev/null || echo "")
            if [ -z "$file_epoch" ]; then
                _warn_unknown_time
            elif [ "$file_epoch" -lt "$SINCE_EPOCH" ]; then
                continue
            fi
        fi
        extracted=$(session_index_extract_workflow "$wf" 2>/dev/null || true)
        wf_head=""; wf_text=""
        { IFS= read -r wf_head || true; IFS= read -r wf_text || true; } <<< "$extracted"
        if [ -z "$wf_text" ]; then
            phase4b_bad=$((phase4b_bad + 1))
            continue
        fi
        now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
        file_mtime=$(session_index_file_mtime_iso "$wf" 2>/dev/null || echo "$now")
        keywords=$(session_index_extract_keywords "$wf_head $wf_text" 2>/dev/null || echo "")
        session_index_retry_busy session_index_upsert "$(basename "$wf" .json)" "$proj_path" "$proj_name" "" "$wf_head" "" \
            "$file_mtime" "$file_mtime" 0 "" "$keywords" "workflow-sweep" "$wf_text" "" "" "" ""
        phase4b_indexed=$((phase4b_indexed + 1))
    done
done
if [ "$phase4b_indexed" -eq 0 ] && [ "$phase4b_bad" -eq 0 ]; then
    ui_phase_skip "Phase 4b: Workflow results" "no workflow files"
else
    _p4b_summary="$phase4b_indexed indexed"
    [ "$phase4b_bad" -gt 0 ] && _p4b_summary="$_p4b_summary, $phase4b_bad unreadable"
    ui_phase_done "Phase 4b: Workflow results" "$_p4b_summary" "$_p4b_start"
fi

# ─── Phase 5: DB-driven enrichment gap-fill ───────────────
# Queries sessions with empty assistant_text, locates their transcript,
# and populates assistant_text, files_changed, commands_run.
# Catches sessions that Phase 4 missed (e.g., transcript in unexpected
# location, or session discovered in Phases 1-3 without a matching
# transcript file in the standard scan paths).

_bf_phase="Phase 5: Enrichment gap-fill"
_p5_start=$(_ui_now)
phase5_enriched=0
phase5_skipped=0
phase5_nofound=0

# Query sessions missing assistant_text
_p5_total=$(session_index_sql \
    "SELECT COUNT(*) FROM sessions WHERE assistant_text = '' AND session_id NOT LIKE 'legacy-%' AND session_id NOT LIKE 'wf\_%' ESCAPE '\' $SINCE_FILTER;" \
    2>/dev/null || echo 0)

if [ "$_p5_total" -eq 0 ]; then
    ui_phase_skip "Phase 5: Enrichment gap-fill" "no gaps"
else
    ui_phase_active "Phase 5: Enrichment gap-fill" 0 "$_p5_total" "$_p5_start"
    _p5_processed=0

    # Dump session_id + project_path pairs to temp file. Raw because the wrapper can't pass
    # -separator, and this is the one recorded exception to its rule.
    _P5_TMP=$(mktemp)
    sqlite3 -separator $'\t' "$SESSION_INDEX_DB" ".timeout $SESSION_INDEX_BUSY_TIMEOUT" \
        "SELECT session_id, project_path FROM sessions WHERE assistant_text = '' AND session_id NOT LIKE 'legacy-%' AND session_id NOT LIKE 'wf\_%' ESCAPE '\' $SINCE_FILTER;" \
        > "$_P5_TMP" 2>/dev/null || true

    while IFS=$'\t' read -r sid proj_path; do
        _p5_processed=$((_p5_processed + 1))
        ui_should_update "$_p5_processed" "$_p5_total" && \
            ui_phase_active "Phase 5: Enrichment gap-fill" "$_p5_processed" "$_p5_total" "$_p5_start"

        [ -z "$sid" ] && continue

        # Encode project_path to directory name: /Users/foo/bar → -Users-foo-bar
        encoded_path=$(echo "$proj_path" | sed 's|/|-|g')
        base_dir="$CLAUDE_PROJECTS_DIR/$encoded_path"

        # Locate transcript: try flat file, then subdirectory, then find fallback
        transcript=""
        if [ -f "$base_dir/${sid}.jsonl" ]; then
            transcript="$base_dir/${sid}.jsonl"
        elif [ -f "$base_dir/${sid}/transcript.jsonl" ]; then
            transcript="$base_dir/${sid}/transcript.jsonl"
        else
            # Fallback: search all project dirs for this session ID
            for _pd in "$CLAUDE_PROJECTS_DIR"/*/; do
                if [ -f "$_pd${sid}.jsonl" ]; then
                    transcript="$_pd${sid}.jsonl"
                    break
                elif [ -f "$_pd${sid}/transcript.jsonl" ]; then
                    transcript="$_pd${sid}/transcript.jsonl"
                    break
                fi
            done
        fi

        if [ -z "$transcript" ] || [ ! -f "$transcript" ]; then
            phase5_nofound=$((phase5_nofound + 1))
            continue
        fi

        # Extract enriched data
        enriched_data=$(session_index_extract_enriched "$transcript")
        IFS=$'\t' read -r assistant_text files_changed commands_run <<< "$enriched_data"

        # Skip if extraction returned nothing
        if [ -z "$assistant_text" ] && [ -z "$files_changed" ] && [ -z "$commands_run" ]; then
            phase5_skipped=$((phase5_skipped + 1))
            continue
        fi

        at_escaped=$(echo "$assistant_text" | sed "s/'/''/g")
        fc_escaped=$(echo "$files_changed" | sed "s/'/''/g")
        cr_escaped=$(echo "$commands_run" | sed "s/'/''/g")
        sid_escaped=$(echo "$sid" | sed "s/'/''/g")

        sqlite3 "$SESSION_INDEX_DB" <<SQL
.timeout $SESSION_INDEX_BUSY_TIMEOUT
UPDATE sessions SET
    assistant_text = '$at_escaped',
    files_changed = '$fc_escaped',
    commands_run = '$cr_escaped'
WHERE session_id = '$sid_escaped' AND assistant_text = '';
SQL
        phase5_enriched=$((phase5_enriched + 1))
    done < "$_P5_TMP"

    rm -f "$_P5_TMP"

    _p5_summary="$phase5_enriched enriched"
    [ "$phase5_skipped" -gt 0 ] && _p5_summary="$_p5_summary, $phase5_skipped empty"
    [ "$phase5_nofound" -gt 0 ] && _p5_summary="$_p5_summary, $phase5_nofound no transcript"
    ui_phase_done "Phase 5: Enrichment gap-fill" "$_p5_summary" "$_p5_start"
fi

# ─── Phase 6: Synonyms + FTS rebuild ──────────────────────

_bf_phase="Phase 6: FTS rebuild"
_p6_start=$(_ui_now)
ui_phase_active_simple "Phase 6: FTS rebuild" "loading synonyms..." "$_p6_start"

synonyms_file="$REPO_DIR/synonyms/default.json"
_syn_count=0
if [ -f "$synonyms_file" ]; then
    session_index_retry_busy session_index_load_synonyms "$synonyms_file"
    _syn_count=$(session_index_sql "SELECT COUNT(*) FROM synonyms;" 2>/dev/null || echo 0)
fi

ui_phase_active_simple "Phase 6: FTS rebuild" "rebuilding index..." "$_p6_start"

session_index_retry_busy session_index_rebuild_fts
session_index_sql "INSERT INTO sessions_fts(sessions_fts) VALUES ('optimize');" 2>/dev/null

_fts_count=$(session_index_sql "SELECT COUNT(*) FROM sessions_fts;" 2>/dev/null || echo 0)
ui_phase_done "Phase 6: FTS rebuild" "$_fts_count entries, $_syn_count synonyms" "$_p6_start"

# ─── Phase 7: Generate search chunks ─────────────────────

_bf_phase="Phase 7: Chunk generation"
_p7_start=$(_ui_now)
CHUNK_SCRIPT="$REPO_DIR/scripts/session-index-chunk.py"
if [ -f "$CHUNK_SCRIPT" ]; then
    ui_phase_active_simple "Phase 7: Chunk generation" "generating chunks..." "$_p7_start"
    # In the background with wait, so a TERM ends the run now instead of when the child returns.
    if [ -n "${SINCE_DAYS:-}" ]; then
        python3 "$CHUNK_SCRIPT" --backfill --since "$SINCE_DAYS" 2>/dev/null &
    else
        python3 "$CHUNK_SCRIPT" --backfill 2>/dev/null &
    fi
    _BF_CHILD=$!
    wait "$_BF_CHILD"
    _BF_CHILD=""
    _chunk_count=$(session_index_sql "SELECT COUNT(*) FROM session_chunks;" 2>/dev/null || echo 0)
    ui_phase_done "Phase 7: Chunk generation" "$_chunk_count chunks" "$_p7_start"
else
    ui_phase_skip "Phase 7: Chunk generation" "chunk script not found"
fi

# ─── Summary ──────────────────────────────────────────────

_bf_phase="Summary"
total=$(session_index_sql "SELECT COUNT(*) FROM sessions;" 2>/dev/null)
untagged=$(session_index_sql "SELECT COUNT(*) FROM sessions WHERE tagged_at IS NULL;" 2>/dev/null)
db_size=$(ls -lh "$SESSION_INDEX_DB" | awk '{print $5}')
_total_elapsed=$(_ui_elapsed "$_backfill_start")

ui_cursor_show

ui_summary "Backfill Complete" "${_total_elapsed}s" \
    "Sessions" "$total total" \
    "Untagged" "$untagged remaining" \
    "FTS index" "${_fts_count:-0} entries" \
    "Database" "$db_size"

# Update meta
session_index_sql "INSERT OR REPLACE INTO meta (key, value) VALUES ('last_backfill', '$(date -u +"%Y-%m-%dT%H:%M:%SZ")');"

session_index_log "Backfill complete: $total sessions"

if [ "$_json_flag" = 1 ]; then
    _bf_counts=$(_backfill_counts_json)
    jq -cn --arg db "$SESSION_INDEX_DB" --argjson counts "$_bf_counts" '{ok: true, database: $db} + $counts' >&3
fi
