#!/usr/bin/env python3
"""Build a synthetic, privacy-safe session index for the README demo GIF.

No real session data is used — every row below is fictional. build.sh points
HOME at a throwaway dir so bin/session-search.py reads THIS database instead of
the real ~/.claude/session-index.db. Schema mirrors the live index exactly.

Usage:  python3 build_demo_db.py <output.db>
"""

import json
import shutil
import sqlite3
import sys
from datetime import datetime, timezone, timedelta
from pathlib import Path

db_path = (
    sys.argv[1]
    if len(sys.argv) > 1
    else "/tmp/claude-search-demo-home/.claude/session-index.db"
)
now = datetime.now(timezone.utc)


def ago(days: int) -> str:
    return (now - timedelta(days=days)).isoformat()


# session_id, project_name, branch, days_ago, msgs, tags, summary, first_prompt, keywords
ROWS = [
    (
        "7f3a9c21e4d50a18",
        "payments-api",
        "db/aurora-cutover",
        152,
        24,
        "migration, database, deployment",
        "Postgres to Aurora migration: schema diff and zero-downtime cutover",
        "We need to migrate our Postgres 14 primary to Aurora with zero downtime. Plan the schema diff, logical replication, and the cutover sequence.",
        "postgres aurora migration cutover schema replication zero downtime",
    ),
    (
        "b4e8d1f6a2c39075",
        "auth-svc",
        "auth/cookie-sessions",
        21,
        18,
        "migration, auth, security",
        "Migrate auth service from JWT to httpOnly session cookies",
        "Move the auth service off stateless JWT to server-side session cookies. Cover CSRF, rotation, and the migration path for already-issued tokens.",
        "jwt session cookie auth migration csrf rotation token",
    ),
    (
        "c9a2e7f10d853b46",
        "analytics-etl",
        "etl/backfill",
        34,
        31,
        "migration, data, performance",
        "Data migration dry-run: 2.4M rows, batched backfill, zero downtime",
        "Design a batched backfill to migrate 2.4M rows into the new events schema without locking the table or blowing the replication lag budget.",
        "data migration backfill batched rows events schema lag",
    ),
    (
        "d1c7b3e90af26845",
        "payments-api",
        "fix/alembic-order",
        65,
        12,
        "migration, bugfix, database",
        "Alembic migration ordering bug: two heads after rebase, down_revision fix",
        "Alembic generated two heads after a rebase. Fix the down_revision chain and squash the duplicate migration cleanly.",
        "alembic migration revision head down_revision autosquash rebase",
    ),
    (
        "e5f0a8d24b1c7e93",
        "observability",
        "main",
        152,
        10,
        "audit, docs, events, monitoring",
        "RUM Analysis: Friday Event Latency Report",
        "Pull the Friday event RUM data and write up the p95 latency regression across regions for the incident review.",
        "rum latency p95 events monitoring regression regions report",
    ),
    (
        "a3b6c9d20e1f4a87",
        "observability",
        "main",
        65,
        8,
        "docs, events, monitoring",
        "CloudWatch dashboards and p95 alarm thresholds",
        "Set up CloudWatch dashboards and tune the p95 latency alarm thresholds so we stop paging on cold-start noise.",
        "cloudwatch dashboard p95 alarm latency threshold monitoring",
    ),
    (
        "f2e1d0c9b8a73654",
        "payments-api",
        "refactor/di",
        6,
        14,
        "refactor, backend",
        "FastAPI dependency injection refactor",
        "Refactor the FastAPI handlers to use dependency injection for the DB session and the auth context instead of globals.",
        "fastapi dependency injection refactor handler db session",
    ),
    (
        "90817263a5b4c3d2",
        "dotfiles",
        "main",
        4,
        6,
        "tooling, cli",
        "fzf keybindings and preview-window tuning",
        "Tune my fzf keybindings and the preview window layout so the ripgrep integration feels instant.",
        "fzf keybinding preview window ripgrep tuning layout",
    ),
]

conn = sqlite3.connect(db_path)
cur = conn.cursor()
cur.executescript(
    """
    DROP TABLE IF EXISTS sessions;
    DROP TABLE IF EXISTS sessions_fts;
    DROP TABLE IF EXISTS synonyms;
    DROP TABLE IF EXISTS meta;
    DROP TABLE IF EXISTS search_log;

    CREATE TABLE sessions (
        session_id    TEXT PRIMARY KEY,
        project_path  TEXT NOT NULL,
        project_name  TEXT NOT NULL,
        summary       TEXT NOT NULL DEFAULT '',
        first_prompt  TEXT NOT NULL DEFAULT '',
        git_branch    TEXT NOT NULL DEFAULT '',
        created_at    TEXT NOT NULL,
        modified_at   TEXT NOT NULL,
        message_count INTEGER NOT NULL DEFAULT 0,
        tags          TEXT NOT NULL DEFAULT '',
        keywords      TEXT NOT NULL DEFAULT '',
        source        TEXT NOT NULL DEFAULT 'unknown',
        indexed_at    TEXT NOT NULL,
        tagged_at     TEXT DEFAULT NULL,
        context_text  TEXT NOT NULL DEFAULT '',
        assistant_text TEXT NOT NULL DEFAULT '',
        files_changed TEXT NOT NULL DEFAULT '',
        commands_run  TEXT NOT NULL DEFAULT '',
        search_aliases TEXT NOT NULL DEFAULT '',
        sweep_mtime   INTEGER DEFAULT NULL,
        sweep_size    INTEGER DEFAULT NULL
    );

    CREATE VIRTUAL TABLE sessions_fts USING fts5(
        session_id, summary, first_prompt, tags, keywords, project_name,
        context_text, assistant_text, files_changed, commands_run, search_aliases,
        tokenize='porter unicode61 remove_diacritics 1',
        prefix='2 3'
    );

    CREATE TABLE synonyms (term TEXT, expansion TEXT);
    CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT);
    CREATE TABLE search_log (
        id            INTEGER PRIMARY KEY AUTOINCREMENT,
        query         TEXT,
        result_count  INTEGER,
        selected_id   TEXT,
        selected_rank INTEGER,
        pipeline_ms   INTEGER,
        created_at    TEXT DEFAULT (datetime('now'))
    );
    """
)

for sid, proj, branch, days, msgs, tags, summary, first_prompt, keywords in ROWS:
    ts = ago(days)
    project_path = f"/Users/dev/code/{proj}"
    cur.execute(
        """INSERT INTO sessions
           (session_id, project_path, project_name, summary, first_prompt, git_branch,
            created_at, modified_at, message_count, tags, keywords, source, indexed_at, tagged_at)
           VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)""",
        (
            sid,
            project_path,
            proj,
            summary,
            first_prompt,
            branch,
            ts,
            ts,
            msgs,
            tags,
            keywords,
            "transcript",
            now.isoformat(),
            now.isoformat(),
        ),
    )
    cur.execute(
        """INSERT INTO sessions_fts
           (session_id, summary, first_prompt, tags, keywords, project_name,
            context_text, assistant_text, files_changed, commands_run, search_aliases)
           VALUES (?,?,?,?,?,?,?,?,?,?,?)""",
        (sid, summary, first_prompt, tags, keywords, proj, "", "", "", "", ""),
    )

# Synthetic transcripts so the preview pane shows a "Recent Messages" timeline.
FOLLOWUPS = {
    "7f3a9c21e4d50a18": [
        "Use logical replication with pglogical, not dump/restore — we can't take the downtime.",
        "Add a row-count + checksum reconciliation step before the DNS cutover.",
    ],
    "b4e8d1f6a2c39075": [
        "Keep JWTs valid during rollout; dual-read both until the cookie path is proven.",
        "CSRF strategy — double-submit token or SameSite=strict?",
    ],
    "c9a2e7f10d853b46": [
        "Batch size 5k with a sleep between batches to keep replica lag under 2s.",
        "Make the backfill resumable from the last committed offset.",
    ],
    "d1c7b3e90af26845": [
        "Both heads came from the auth branch and the billing branch merging together.",
        "Squash into one revision and pin down_revision to the last shared ancestor.",
    ],
    "e5f0a8d24b1c7e93": [
        "Break the p95 down by region — us-east is fine, eu-west is the regression.",
        "Correlate the spike with the 14:00 UTC deploy.",
    ],
    "a3b6c9d20e1f4a87": [
        "Raise the alarm to p95 > 800ms for 5 minutes to cut the cold-start noise.",
    ],
    "f2e1d0c9b8a73654": [
        "Inject the DB session via Depends() and drop the module-level global.",
    ],
    "90817263a5b4c3d2": [
        "Bind ctrl-/ to toggle the preview window and ctrl-d/u to page it.",
    ],
}

projects_dir = Path(db_path).parent / "projects"
shutil.rmtree(projects_dir, ignore_errors=True)
for sid, proj, branch, days, msgs, tags, summary, first_prompt, keywords in ROWS:
    encoded = ("/Users/dev/code/" + proj).replace("/", "-")
    tdir = projects_dir / encoded
    tdir.mkdir(parents=True, exist_ok=True)
    with open(tdir / f"{sid}.jsonl", "w") as f:
        for text in [first_prompt] + FOLLOWUPS.get(sid, []):
            f.write(json.dumps({"type": "user", "message": {"content": text}}) + "\n")

# A few synonyms so the engine behaves like the real one (rum -> monitoring, etc.)
SYN = [
    ("rum", "monitoring"),
    ("rum", "observability"),
    ("latency", "performance"),
    ("p95", "latency"),
    ("auth", "authentication"),
    ("db", "database"),
]
cur.executemany("INSERT INTO synonyms (term, expansion) VALUES (?,?)", SYN)

# Fresh backfill marker so _check_index_freshness() never tries to rebuild this DB.
cur.execute(
    "INSERT INTO meta (key, value) VALUES ('last_backfill', ?)", (now.isoformat(),)
)

conn.commit()
conn.close()
print(f"Built synthetic demo index: {db_path} ({len(ROWS)} sessions)")
