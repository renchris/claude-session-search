#!/bin/bash
# One-time idempotent backfill of session index from all data sources.
# Usage:
#   session-index-backfill.sh                    # Full backfill
#   session-index-backfill.sh --enrich-only      # Skip discovery, just re-extract enrichment
#   session-index-backfill.sh --since 7          # Only sessions modified in last 7 days
#   session-index-backfill.sh --enrich-only --since 3  # Re-enrich recent sessions only
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
source "$REPO_DIR/hooks/lib/session-index-helpers.sh"
source "$SCRIPT_DIR/lib/progress-ui.sh"

QUIET=false
ENRICH_ONLY=false
SINCE_DAYS=""

while [ $# -gt 0 ]; do
    case "$1" in
        --quiet) QUIET=true; shift ;;
        --enrich-only) ENRICH_ONLY=true; shift ;;
        --since) SINCE_DAYS="$2"; shift 2 ;;
        *) echo "Unknown flag: $1" >&2; exit 1 ;;
    esac
done

# Build optional SQL filter for --since
SINCE_FILTER=""
SINCE_EPOCH=0
if [ -n "$SINCE_DAYS" ]; then
    SINCE_FILTER="AND modified_at > datetime('now', '-${SINCE_DAYS} days')"
    # Compute epoch threshold for file mtime comparisons (macOS date)
    SINCE_EPOCH=$(date -v-"${SINCE_DAYS}"d +%s 2>/dev/null || date -d "-${SINCE_DAYS} days" +%s 2>/dev/null || echo 0)
fi

# ─── Prerequisites ─────────────────────────────────────────

if ! command -v sqlite3 &>/dev/null; then
    echo "ERROR: sqlite3 not found" >&2; exit 1
fi
if ! command -v jq &>/dev/null; then
    echo "ERROR: jq not found" >&2; exit 1
fi

# ─── Init DB ───────────────────────────────────────────────

session_index_init_db

# ─── Pre-count totals for progress tracking ────────────────

_backfill_start=$(_ui_now)

# Count existing sessions for the header
_existing_total=$(sqlite3 "$SESSION_INDEX_DB" "SELECT COUNT(*) FROM sessions;" 2>/dev/null || echo 0)

# Count transcript files for Phase 4 progress
_transcript_total=0
for _pd in "$CLAUDE_PROJECTS_DIR"/*/; do
    for _tf in "$_pd"*.jsonl; do
        [ -f "$_tf" ] || continue
        _fn=$(basename "$_tf" .jsonl)
        [[ "$_fn" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] || continue
        _transcript_total=$((_transcript_total + 1))
    done
done

# ─── Header ────────────────────────────────────────────────

if [ -n "$SINCE_DAYS" ]; then
    _header_detail="last ${SINCE_DAYS}d  ${_existing_total} existing"
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
                mod_epoch=$(date -jf "%Y-%m-%dT%H:%M:%S" "${modified%%.*}" +%s 2>/dev/null || echo 0)
                [ "$mod_epoch" -lt "$SINCE_EPOCH" ] && continue
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
            session_index_upsert \
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
            existing=$(sqlite3 "$SESSION_INDEX_DB" "SELECT source FROM sessions WHERE session_id='$(echo "$sid" | sed "s/'/''/g")' LIMIT 1;" 2>/dev/null || echo "")
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
                created_at=$(date -r "$epoch_sec" -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || echo "")
            fi
            [ -z "$created_at" ] && created_at=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

            keywords=$(session_index_extract_keywords "$display" 2>/dev/null || echo "")
            session_index_upsert \
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
                created_at=$(date -r "$epoch_sec" -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || echo "")
            fi
            [ -z "$created_at" ] && created_at=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

            modified_at="$created_at"
            if [ -n "$last_ts" ] && [ "$last_ts" != "0" ]; then
                epoch_sec=$((last_ts / 1000))
                modified_at=$(date -r "$epoch_sec" -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || echo "$created_at")
            fi

            keywords=$(session_index_extract_keywords "$display" 2>/dev/null || echo "")
            session_index_upsert \
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

        for transcript in "$project_dir"*.jsonl; do
            [ -f "$transcript" ] || continue
            sid=$(basename "$transcript" .jsonl)
            [[ "$sid" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] || continue

            _p4_processed=$((_p4_processed + 1))
            ui_should_update "$_p4_processed" "$_transcript_total" && \
                ui_phase_active "Phase 4: Transcript enrichment" "$_p4_processed" "$_transcript_total" "$_p4_start"

            # Skip if already enriched (unless --enrich-only which means force re-enrich)
            if [ "$ENRICH_ONLY" != "true" ]; then
                _sid_check=$(echo "$sid" | sed "s/'/''/g")
                already_enriched=$(sqlite3 "$SESSION_INDEX_DB" \
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

            exists=$(sqlite3 "$SESSION_INDEX_DB" "SELECT 1 FROM sessions WHERE session_id='$sid_escaped' $SINCE_FILTER LIMIT 1;" 2>/dev/null || echo "")

            if [ -n "$exists" ]; then
                sqlite3 "$SESSION_INDEX_DB" <<SQL
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
                    file_epoch=$(stat -f "%m" "$transcript" 2>/dev/null || echo 0)
                    [ "$file_epoch" -lt "$SINCE_EPOCH" ] && continue
                fi
                now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
                file_mtime=$(stat -f "%Sm" -t "%Y-%m-%dT%H:%M:%SZ" "$transcript" 2>/dev/null || echo "$now")
                first_prompt=$(echo "$context_text" | head -c 500)
                fp_escaped=$(echo "$first_prompt" | sed "s/'/''/g")
                pp_escaped=$(echo "$proj_path" | sed "s/'/''/g")
                pn_escaped=$(echo "$proj_name" | sed "s/'/''/g")
                keywords=$(session_index_extract_keywords "$context_text" 2>/dev/null || echo "")
                kw_escaped=$(echo "$keywords" | sed "s/'/''/g")

                sqlite3 "$SESSION_INDEX_DB" <<SQL
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

# ─── Phase 5: Synonyms + FTS rebuild ──────────────────────

_p5_start=$(_ui_now)
ui_phase_active_simple "Phase 5: FTS rebuild" "loading synonyms..." "$_p5_start"

synonyms_file="$REPO_DIR/synonyms/default.json"
_syn_count=0
if [ -f "$synonyms_file" ]; then
    session_index_load_synonyms "$synonyms_file"
    _syn_count=$(sqlite3 "$SESSION_INDEX_DB" "SELECT COUNT(*) FROM synonyms;" 2>/dev/null || echo 0)
fi

ui_phase_active_simple "Phase 5: FTS rebuild" "rebuilding index..." "$_p5_start"

session_index_rebuild_fts
sqlite3 "$SESSION_INDEX_DB" "INSERT INTO sessions_fts(sessions_fts) VALUES ('optimize');" 2>/dev/null

_fts_count=$(sqlite3 "$SESSION_INDEX_DB" "SELECT COUNT(*) FROM sessions_fts;" 2>/dev/null || echo 0)
ui_phase_done "Phase 5: FTS rebuild" "$_fts_count entries, $_syn_count synonyms" "$_p5_start"

# ─── Summary ──────────────────────────────────────────────

total=$(sqlite3 "$SESSION_INDEX_DB" "SELECT COUNT(*) FROM sessions;" 2>/dev/null)
untagged=$(sqlite3 "$SESSION_INDEX_DB" "SELECT COUNT(*) FROM sessions WHERE tagged_at IS NULL;" 2>/dev/null)
db_size=$(ls -lh "$SESSION_INDEX_DB" | awk '{print $5}')
_total_elapsed=$(_ui_elapsed "$_backfill_start")

ui_cursor_show

ui_summary "Backfill Complete" "${_total_elapsed}s" \
    "Sessions" "$total total" \
    "Untagged" "$untagged remaining" \
    "FTS index" "${_fts_count:-0} entries" \
    "Database" "$db_size"

# Update meta
sqlite3 "$SESSION_INDEX_DB" "INSERT OR REPLACE INTO meta (key, value) VALUES ('last_backfill', '$(date -u +"%Y-%m-%dT%H:%M:%SZ")');"

session_index_log "Backfill complete: $total sessions"
