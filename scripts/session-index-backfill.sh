#!/bin/bash
# One-time idempotent backfill of session index from all data sources.
# Usage: ./scripts/session-index-backfill.sh [--quiet]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
source "$REPO_DIR/hooks/lib/session-index-helpers.sh"

QUIET="${1:-}"

log() { [ "$QUIET" = "--quiet" ] || echo "$1"; }

# ─── Prerequisites ─────────────────────────────────────────

if ! command -v sqlite3 &>/dev/null; then
    echo "ERROR: sqlite3 not found" >&2; exit 1
fi
if ! command -v jq &>/dev/null; then
    echo "ERROR: jq not found" >&2; exit 1
fi

# ─── Init DB ───────────────────────────────────────────────

session_index_init_db
log "Database initialized: $SESSION_INDEX_DB"

# ─── Phase 1: sessions-index.json (highest quality) ───────

log ""
log "Phase 1/3: sessions-index.json..."
phase1_count=0

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
    done < "$TMPFILE"

    rm -f "$TMPFILE"
done

log "Phase 1/3: sessions-index.json → $phase1_count sessions indexed"

# ─── Phase 2: history.jsonl (gap fill) ────────────────────

log ""
log "Phase 2/3: history.jsonl..."
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

    while IFS=$'\t' read -r sid display project_path timestamp_ms; do
        [ -z "$sid" ] && continue
        [ -z "$project_path" ] && continue

        # Check if already indexed from Phase 1
        existing=$(sqlite3 "$SESSION_INDEX_DB" "SELECT source FROM sessions WHERE session_id='$(echo "$sid" | sed "s/'/''/g")' LIMIT 1;" 2>/dev/null || echo "")
        if [ "$existing" = "sessions-index" ]; then
            phase2_skip=$((phase2_skip + 1))
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
    done < "$TMPFILE"

    rm -f "$TMPFILE"
fi

log "Phase 2/3: history.jsonl → $phase2_count new sessions ($phase2_skip skipped)"

# ─── Phase 3: Legacy entries (no sessionId) ───────────────

log ""
log "Phase 3/3: Legacy entries..."
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

    while IFS=$'\t' read -r display project_path first_ts last_ts count; do
        [ -z "$project_path" ] && continue

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
    done < "$TMPFILE"

    rm -f "$TMPFILE"
fi

log "Phase 3/3: Legacy entries → $phase3_count synthetic sessions"

# ─── Phase 4: Enrich from transcript files ────────────────
# Runs AFTER all other phases so every session is in the DB.
# Scans .jsonl transcripts: updates context_text + message_count for existing rows,
# INSERTs new rows for transcript-only sessions.

log ""
log "Phase 4: Extracting context from transcripts..."
phase4_enriched=0
phase4_inserted=0

for project_dir in "$CLAUDE_PROJECTS_DIR"/*/; do
    dir_name=$(basename "$project_dir")
    proj_path=$(echo "$dir_name" | sed 's/^-/\//' | sed 's/-/\//g')
    proj_name=$(basename "$proj_path")

    for transcript in "$project_dir"*.jsonl; do
        [ -f "$transcript" ] || continue
        sid=$(basename "$transcript" .jsonl)
        [[ "$sid" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] || continue

        # Extract context and message count from transcript
        context_text=$(session_index_extract_context "$transcript" 10)
        msg_count=$(session_index_extract_transcript_meta "$transcript")
        [ -z "$context_text" ] && [ "${msg_count:-0}" -lt 2 ] && continue

        ctx_escaped=$(echo "$context_text" | sed "s/'/''/g")
        sid_escaped=$(echo "$sid" | sed "s/'/''/g")

        exists=$(sqlite3 "$SESSION_INDEX_DB" "SELECT 1 FROM sessions WHERE session_id='$sid_escaped' LIMIT 1;" 2>/dev/null || echo "")

        if [ -n "$exists" ]; then
            sqlite3 "$SESSION_INDEX_DB" <<SQL
UPDATE sessions SET
    context_text = '$ctx_escaped',
    message_count = CASE WHEN $msg_count > message_count THEN $msg_count ELSE message_count END
WHERE session_id = '$sid_escaped';
SQL
            phase4_enriched=$((phase4_enriched + 1))
        else
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
    context_text, git_branch, created_at, modified_at, message_count, tags, keywords, source, indexed_at)
VALUES ('$sid_escaped', '$pp_escaped', '$pn_escaped', '', '$fp_escaped',
    '$ctx_escaped', '', '$file_mtime', '$file_mtime', $msg_count, '', '$kw_escaped', 'transcript', '$now');
SQL
            phase4_inserted=$((phase4_inserted + 1))
        fi
    done
done

log "Phase 4: Transcript context → $phase4_enriched enriched, $phase4_inserted new"

# ─── Load Synonyms ────────────────────────────────────────

synonyms_file="$REPO_DIR/synonyms/default.json"
if [ -f "$synonyms_file" ]; then
    session_index_load_synonyms "$synonyms_file"
    syn_count=$(sqlite3 "$SESSION_INDEX_DB" "SELECT COUNT(*) FROM synonyms;" 2>/dev/null)
    log ""
    log "Synonyms loaded: $syn_count expansions"
fi

# ─── Rebuild FTS + Optimize ────────────────────────────────

session_index_rebuild_fts
sqlite3 "$SESSION_INDEX_DB" "INSERT INTO sessions_fts(sessions_fts) VALUES ('optimize');" 2>/dev/null

# ─── Summary ──────────────────────────────────────────────

total=$(sqlite3 "$SESSION_INDEX_DB" "SELECT COUNT(*) FROM sessions;" 2>/dev/null)
untagged=$(sqlite3 "$SESSION_INDEX_DB" "SELECT COUNT(*) FROM sessions WHERE tagged_at IS NULL;" 2>/dev/null)
db_size=$(ls -lh "$SESSION_INDEX_DB" | awk '{print $5}')

log ""
log "Done. $total sessions indexed. DB: $db_size. Untagged: $untagged"

# Update meta
sqlite3 "$SESSION_INDEX_DB" "INSERT OR REPLACE INTO meta (key, value) VALUES ('last_backfill', '$(date -u +"%Y-%m-%dT%H:%M:%SZ")');"

session_index_log "Backfill complete: $total sessions"
