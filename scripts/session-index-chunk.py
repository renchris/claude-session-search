#!/usr/bin/env python3
"""Generate turn-based chunks from session transcripts for deep search.

Usage:
    session-index-chunk.py SESSION_ID TRANSCRIPT_PATH  # Chunk one session
    session-index-chunk.py --backfill                   # Chunk all sessions
    session-index-chunk.py --backfill --since N         # Recent N days only
"""
import argparse
import json
import os
import re
import sqlite3
import sys
from pathlib import Path
from datetime import datetime, timedelta, timezone

DB_PATH = Path.home() / ".claude" / "session-index.db"
PROJECTS_DIR = Path.home() / ".claude" / "projects"

# Chunking parameters
WINDOW_SIZE = 5      # turns per window
STRIDE = 4           # advance by 4 turns (1-turn overlap)
MAX_USER_TEXT = 2000  # chars per chunk
MAX_ASST_TEXT = 3000  # chars per chunk
MAX_CHUNKS = 50       # per session
MIN_TURNS = 5         # skip short sessions


def parse_transcript(path):
    """Parse JSONL transcript into turns.
    A turn = one user message + all subsequent assistant/tool messages until next user message.
    """
    turns = []
    current_turn = None

    with open(path, 'r') as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                record = json.loads(line)
            except json.JSONDecodeError:
                continue

            rec_type = record.get('type', '')

            if rec_type == 'user':
                # Start a new turn
                msg = record.get('message', {})
                content = msg.get('content', '') if isinstance(msg, dict) else ''

                # Extract text from content (could be string or list of blocks)
                user_text = ''
                if isinstance(content, str):
                    # Skip task notifications and tool results
                    if not content.startswith('<task-notification>') and not content.startswith('<local-command'):
                        user_text = content
                elif isinstance(content, list):
                    for block in content:
                        if isinstance(block, dict):
                            if block.get('type') == 'text':
                                text = block.get('text', '')
                                if not text.startswith('<task-notification>'):
                                    user_text += text + ' '
                            elif block.get('type') == 'tool_result':
                                pass  # Skip tool results

                user_text = user_text.strip()
                if user_text and len(user_text) > 10:
                    if current_turn:
                        turns.append(current_turn)
                    current_turn = {
                        'user_text': user_text,
                        'assistant_text': '',
                        'files': set(),
                        'commands': set(),
                    }

            elif rec_type == 'assistant' and current_turn:
                msg = record.get('message', {})
                content = msg.get('content', [])
                if isinstance(content, list):
                    for block in content:
                        if isinstance(block, dict):
                            if block.get('type') == 'text':
                                current_turn['assistant_text'] += block.get('text', '')[:500] + ' '
                            elif block.get('type') == 'tool_use':
                                tool_name = block.get('name', '')
                                tool_input = block.get('input', {})
                                if tool_name in ('Read', 'Edit', 'Write', 'Glob'):
                                    fp = tool_input.get('file_path', '') or tool_input.get('pattern', '')
                                    if fp:
                                        current_turn['files'].add(os.path.basename(fp))
                                elif tool_name == 'Bash':
                                    cmd = tool_input.get('command', '')
                                    if cmd and len(cmd) < 200:
                                        current_turn['commands'].add(cmd[:100])

    if current_turn:
        turns.append(current_turn)

    return turns


def generate_chunks(session_id, turns):
    """Generate 5-turn sliding windows with stride 4."""
    if len(turns) < MIN_TURNS:
        return []

    chunks = []
    for i in range(0, len(turns), STRIDE):
        window = turns[i:i + WINDOW_SIZE]
        if not window:
            break

        user_text = ' '.join(t['user_text'][:400] for t in window)[:MAX_USER_TEXT]
        asst_text = ' '.join(t['assistant_text'][:600] for t in window)[:MAX_ASST_TEXT]
        files = set()
        commands = set()
        for t in window:
            files.update(t['files'])
            commands.update(t['commands'])

        chunk_index = len(chunks)
        chunks.append({
            'chunk_id': f"{session_id}:{chunk_index}",
            'session_id': session_id,
            'chunk_index': chunk_index,
            'start_turn': i,
            'end_turn': min(i + WINDOW_SIZE - 1, len(turns) - 1),
            'user_text': user_text.strip(),
            'assistant_text': asst_text.strip(),
            'files_mentioned': ' '.join(sorted(files)[:20]),
            'commands_mentioned': ' '.join(sorted(commands)[:10]),
        })

        if len(chunks) >= MAX_CHUNKS:
            break

    return chunks


def store_chunks(conn, chunks):
    """Write chunks to session_chunks + chunks_fts."""
    if not chunks:
        return 0

    session_id = chunks[0]['session_id']

    # Delete existing chunks for this session
    conn.execute("DELETE FROM chunks_fts WHERE session_id = ?", (session_id,))
    conn.execute("DELETE FROM session_chunks WHERE session_id = ?", (session_id,))

    for chunk in chunks:
        conn.execute("""
            INSERT INTO session_chunks (chunk_id, session_id, chunk_index, start_turn, end_turn,
                user_text, assistant_text, files_mentioned, commands_mentioned)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        """, (
            chunk['chunk_id'], chunk['session_id'], chunk['chunk_index'],
            chunk['start_turn'], chunk['end_turn'],
            chunk['user_text'], chunk['assistant_text'],
            chunk['files_mentioned'], chunk['commands_mentioned'],
        ))
        conn.execute("""
            INSERT INTO chunks_fts (chunk_id, session_id, user_text, assistant_text,
                files_mentioned, commands_mentioned)
            VALUES (?, ?, ?, ?, ?, ?)
        """, (
            chunk['chunk_id'], chunk['session_id'],
            chunk['user_text'], chunk['assistant_text'],
            chunk['files_mentioned'], chunk['commands_mentioned'],
        ))

    conn.commit()
    return len(chunks)


def chunk_session(conn, session_id, transcript_path):
    """Chunk a single session."""
    if not os.path.exists(transcript_path):
        return 0
    # Skip huge files (>50MB)
    if os.path.getsize(transcript_path) > 52428800:
        return 0

    turns = parse_transcript(transcript_path)
    chunks = generate_chunks(session_id, turns)
    return store_chunks(conn, chunks)


def backfill(conn, since_days=None):
    """Chunk all sessions from transcript files."""
    total_chunks = 0
    total_sessions = 0

    cutoff = None
    if since_days:
        cutoff = (datetime.now(timezone.utc) - timedelta(days=since_days)).timestamp()

    for project_dir in PROJECTS_DIR.iterdir():
        if not project_dir.is_dir():
            continue

        # Flat layout: {sid}.jsonl
        for f in project_dir.glob('*.jsonl'):
            sid = f.stem
            if not re.match(r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$', sid):
                continue
            if cutoff and f.stat().st_mtime < cutoff:
                continue

            n = chunk_session(conn, sid, str(f))
            if n > 0:
                total_chunks += n
                total_sessions += 1

        # Subdirectory layout: {sid}/transcript.jsonl (skip if flat exists)
        for d in project_dir.iterdir():
            if not d.is_dir():
                continue
            sid = d.name
            if not re.match(r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$', sid):
                continue
            if (project_dir / f"{sid}.jsonl").exists():
                continue
            transcript = d / "transcript.jsonl"
            if not transcript.exists():
                continue
            if cutoff and transcript.stat().st_mtime < cutoff:
                continue

            n = chunk_session(conn, sid, str(transcript))
            if n > 0:
                total_chunks += n
                total_sessions += 1

    print(f"Chunked {total_sessions} sessions -> {total_chunks} chunks")
    return total_chunks


def main():
    parser = argparse.ArgumentParser(description="Generate search chunks from session transcripts")
    parser.add_argument('session_id', nargs='?', help="Session ID to chunk")
    parser.add_argument('transcript_path', nargs='?', help="Path to transcript JSONL")
    parser.add_argument('--backfill', action='store_true', help="Chunk all sessions")
    parser.add_argument('--since', type=int, help="Only process sessions from last N days")
    args = parser.parse_args()

    if not DB_PATH.exists():
        print(f"Database not found: {DB_PATH}", file=sys.stderr)
        sys.exit(1)

    conn = sqlite3.connect(str(DB_PATH), timeout=10)
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("PRAGMA busy_timeout=5000")

    # Ensure tables exist
    conn.executescript("""
        CREATE TABLE IF NOT EXISTS session_chunks (
            chunk_id TEXT PRIMARY KEY, session_id TEXT NOT NULL,
            chunk_index INTEGER NOT NULL, start_turn INTEGER NOT NULL,
            end_turn INTEGER NOT NULL, user_text TEXT NOT NULL DEFAULT '',
            assistant_text TEXT NOT NULL DEFAULT '', files_mentioned TEXT NOT NULL DEFAULT '',
            commands_mentioned TEXT NOT NULL DEFAULT '', UNIQUE(session_id, chunk_index)
        );
        CREATE INDEX IF NOT EXISTS idx_chunks_session ON session_chunks(session_id);
        CREATE VIRTUAL TABLE IF NOT EXISTS chunks_fts USING fts5(
            chunk_id, session_id, user_text, assistant_text, files_mentioned, commands_mentioned,
            tokenize='porter unicode61 remove_diacritics 1', prefix='2 3'
        );
    """)

    if args.backfill:
        backfill(conn, since_days=args.since)
    elif args.session_id and args.transcript_path:
        n = chunk_session(conn, args.session_id, args.transcript_path)
        print(f"Generated {n} chunks for {args.session_id}")
    else:
        parser.print_help()
        sys.exit(1)

    conn.close()


if __name__ == '__main__':
    main()
