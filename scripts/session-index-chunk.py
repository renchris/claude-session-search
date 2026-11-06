#!/usr/bin/env python3
"""Generate turn-based chunks from session transcripts for deep search.

Usage:
    session-index-chunk.py SESSION_ID --transcript FILE  # Chunk one session
    session-index-chunk.py --backfill                    # Chunk all sessions
    session-index-chunk.py --backfill --since TIME       # Recent sessions only
"""
import argparse
import json
import os
import re
import sqlite3
import sys
from collections import Counter
from dataclasses import dataclass, field
from pathlib import Path
from datetime import datetime, timedelta, timezone
from typing import Any, Optional

sys.path.insert(0, str(Path(__file__).resolve().parent / "lib"))

import cli_common  # noqa: E402

PROG = "session-index-chunk.py"
DB_PATH = Path.home() / ".claude" / "session-index.db"
PROJECTS_DIR = Path.home() / ".claude" / "projects"

# Chunking parameters
WINDOW_SIZE = 5      # turns per window
STRIDE = 4           # advance by 4 turns (1-turn overlap)
MAX_USER_TEXT = 2000  # chars per chunk
MAX_ASST_TEXT = 3000  # chars per chunk
MAX_CHUNKS = 50       # per session
MIN_TURNS = 5         # skip short sessions
MAX_TRANSCRIPT_BYTES = 52428800  # skip huge files

SESSION_ID_RE = re.compile(r'[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}')


@dataclass
class ChunkStats:
    succeeded: int = 0
    skipped: Counter = field(default_factory=Counter)  # short, oversize, missing
    failed: int = 0
    not_attempted: int = 0
    malformed_lines: int = 0
    truncated_sessions: int = 0
    total_chunks: int = 0
    results: list[dict[str, Any]] = field(default_factory=list)


def _note(line: str) -> None:
    # A closed stderr must not change the outcome of a run that already wrote to the DB.
    try:
        print(cli_common.sanitize_display(line), file=sys.stderr)
    except (OSError, ValueError, AttributeError):
        pass


def _emit(line: str) -> None:
    # run_cli reads a BrokenPipeError as exit 0, which would hide a failed batch.
    try:
        print(line, flush=True)
    except (OSError, ValueError, AttributeError):
        cli_common.detach_stdout()


def _emit_json(doc: Any) -> None:
    try:
        cli_common.emit_json(doc)
        sys.stdout.flush()
    except (OSError, ValueError, AttributeError):
        cli_common.detach_stdout()


def parse_transcript(path, stats):
    """Parse JSONL transcript into turns.
    A turn = one user message + all subsequent assistant/tool messages until next user message.
    """
    turns = []
    current_turn = None

    with open(path, 'r', encoding='utf-8', errors='replace') as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                record = json.loads(line)
            except (ValueError, RecursionError):
                stats.malformed_lines += 1
                continue
            if not isinstance(record, dict):
                stats.malformed_lines += 1
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


def chunk_session(conn, session_id, transcript_path, stats):
    """Chunk a single session. Returns (chunks written, skip reason or None)."""
    if not os.path.exists(transcript_path):
        return 0, 'missing'
    if os.path.getsize(transcript_path) > MAX_TRANSCRIPT_BYTES:
        return 0, 'oversize'

    turns = parse_transcript(transcript_path, stats)
    chunks = generate_chunks(session_id, turns)
    if not chunks:
        return 0, 'short'
    written = store_chunks(conn, chunks)
    if len(chunks) >= MAX_CHUNKS and chunks[-1]['end_turn'] < len(turns) - 1:
        stats.truncated_sessions += 1
    return written, None


def _record_failure(stats: ChunkStats, item_id: str, path: Any, exc: Exception) -> None:
    if isinstance(exc, OSError) and exc.strerror:
        reason = exc.strerror
    else:
        reason = f"{type(exc).__name__}: {exc}"
    stats.failed += 1
    stats.results.append({
        'id': item_id, 'outcome': 'failed', 'chunks': 0,
        'error': cli_common.sanitize_display(reason),
    })
    _note(f"session-index-chunk: failed: {path}: {reason}")


def _chunk_item(conn: sqlite3.Connection, session_id: str, path: str, stats: ChunkStats) -> bool:
    """Chunk one transcript. Returns False when a database failure must stop the batch."""
    try:
        written, skip_reason = chunk_session(conn, session_id, path, stats)
    except sqlite3.Error as exc:
        conn.rollback()
        _record_failure(stats, session_id, path, exc)
        return False
    except (OSError, ValueError, AttributeError, TypeError) as exc:
        # Valid JSON of the wrong shape lands here too. store_chunks deletes before it
        # inserts, so without the rollback the next session's commit keeps the delete.
        conn.rollback()
        _record_failure(stats, session_id, path, exc)
        return True
    if skip_reason:
        stats.skipped[skip_reason] += 1
        stats.results.append(
            {'id': session_id, 'outcome': 'skipped', 'chunks': 0, 'reason': skip_reason}
        )
    else:
        stats.succeeded += 1
        stats.total_chunks += written
        stats.results.append({'id': session_id, 'outcome': 'chunked', 'chunks': written})
    return True


def _in_window(path: Path, session_id: str, cutoff: Optional[float], stats: ChunkStats) -> bool:
    if cutoff is None:
        return True
    try:
        return path.stat().st_mtime >= cutoff
    except FileNotFoundError:
        return False  # A dangling link or a file that just went away: nothing to chunk.
    except OSError as exc:
        _record_failure(stats, session_id, path, exc)
        return False


def _discover(cutoff: Optional[float], stats: ChunkStats) -> list[tuple[str, Path]]:
    items = []
    for project_dir in PROJECTS_DIR.iterdir():
        if not project_dir.is_dir():
            continue
        try:
            # Flat layout: {sid}.jsonl
            for f in project_dir.glob('*.jsonl'):
                sid = f.stem
                if SESSION_ID_RE.fullmatch(sid) and _in_window(f, sid, cutoff, stats):
                    items.append((sid, f))

            # Subdirectory layout: {sid}/transcript.jsonl (skip if flat exists)
            for d in project_dir.iterdir():
                if not d.is_dir():
                    continue
                sid = d.name
                if not SESSION_ID_RE.fullmatch(sid):
                    continue
                if (project_dir / f"{sid}.jsonl").exists():
                    continue
                transcript = d / "transcript.jsonl"
                if transcript.exists() and _in_window(transcript, sid, cutoff, stats):
                    items.append((sid, transcript))
        except OSError as exc:
            _record_failure(stats, project_dir.name, project_dir, exc)
    return items


def backfill(conn, cutoff=None):
    """Chunk all sessions from transcript files. Each session commits separately."""
    stats = ChunkStats()
    if not PROJECTS_DIR.exists():
        _note("session-index-chunk: projects dir not found: nothing to chunk")
        return stats
    try:
        items = _discover(cutoff, stats)
    except OSError as exc:
        _record_failure(stats, PROJECTS_DIR.name, PROJECTS_DIR, exc)
        return stats

    for index, (sid, path) in enumerate(items):
        if not _chunk_item(conn, sid, str(path), stats):
            # A locked DB would otherwise cost the busy timeout once per remaining session.
            _note("session-index-chunk: stopping: database error")
            remainder = items[index + 1:]
            stats.not_attempted = len(remainder)
            stats.results.extend(
                {'id': rest, 'outcome': 'not_attempted', 'chunks': 0} for rest, _ in remainder
            )
            break
    return stats


def _report_backfill(stats: ChunkStats, as_json: bool) -> None:
    skipped = sum(stats.skipped.values())
    if as_json:
        _emit_json({
            'results': stats.results,
            'summary': {
                'succeeded': stats.succeeded,
                'failed': stats.failed,
                'skipped': skipped,
                'unknown': stats.not_attempted,
            },
            'counts': {
                'chunks': stats.total_chunks,
                'malformed_lines': stats.malformed_lines,
                'truncated_sessions': stats.truncated_sessions,
            },
        })
        return
    _emit(f"Chunked {stats.succeeded} sessions -> {stats.total_chunks} chunks")
    if stats.results:
        _note(
            f"session-index-chunk: {stats.succeeded} succeeded, {skipped} skipped, "
            f"{stats.failed} failed, {stats.not_attempted} not attempted; "
            f"{cli_common.plural(stats.malformed_lines, 'malformed line')}, "
            f"{cli_common.plural(stats.truncated_sessions, 'truncated session')}. "
            "Not atomic: each session commits separately, so re-running is safe."
        )


def _report_session(session_id: str, stats: ChunkStats, as_json: bool) -> None:
    result = stats.results[0]
    outcome = result['outcome']
    if as_json:
        doc: dict[str, Any] = {
            'session': {'session_id': session_id, 'chunks': result['chunks']},
            'outcome': 'unchanged' if outcome == 'skipped' else outcome,
        }
        for key in ('reason', 'error'):
            if key in result:
                doc[key] = result[key]
        _emit_json(doc)
    elif outcome != 'failed':
        _emit(f"Generated {result['chunks']} chunks for {session_id}")


def _since_cutoff(value: str) -> Optional[float]:
    """Turn a --since value into an epoch cutoff. None means no cutoff.

    Until C8 a bare 0 stays no cutoff and a negative count of days stays a future
    cutoff, which matches nothing.
    """
    try:
        days = int(value)
    except ValueError:
        return cli_common.parse_time(value)
    if days == 0:
        return None
    if days > 0:
        return cli_common.parse_time(str(days))
    try:
        return (datetime.now(timezone.utc) - timedelta(days=days)).timestamp()
    except OverflowError as exc:
        raise argparse.ArgumentTypeError("The number of days is out of range.") from exc


def build_parser() -> argparse.ArgumentParser:
    size_mb = f"{MAX_TRANSCRIPT_BYTES / 1_000_000:.1f} MB"
    epilog = f"""\
Examples:
  Chunk the sessions changed in the last week:
    {PROG} --backfill --since 7d
  Chunk one session from its transcript:
    {PROG} 123e4567-e89b-12d3-a456-426614174000 --transcript ~/.claude/projects/my-project/123e4567-e89b-12d3-a456-426614174000.jsonl

Notes:
  Writes ~/.claude/session-index.db and creates its chunk tables if missing.
  Exits 1 if that database does not exist.
  A transcript over {size_mb} or under {MIN_TURNS} turns yields 0 chunks.
  A session gets at most {MAX_CHUNKS} chunks.

Exit codes:
  0    success, including skipped sessions
  1    failure, a missing database, or a bare invocation
  2    usage error
  130  interrupted
"""
    parser = argparse.ArgumentParser(
        prog=PROG,
        description="Generate search chunks from session transcripts",
        allow_abbrev=False,
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=epilog,
    )
    parser.add_argument('session_id', nargs='?', metavar='session', help="Session ID to chunk")
    parser.add_argument(
        'legacy_transcript', nargs='?', metavar='transcript', help="Deprecated: use --transcript"
    )
    parser.add_argument(
        '--transcript', dest='transcript_file', metavar='<FILE>', help="Path to transcript JSONL"
    )
    parser.add_argument('--backfill', action='store_true', help="Chunk all sessions")
    parser.add_argument(
        '-s', '--since', type=_since_cutoff, metavar='<TIME>',
        help="With --backfill, only transcripts changed since this time: 7d, 12h, 30m, a bare "
             "number of days, or ISO 8601 (no offset reads as UTC). Default: all sessions.",
    )
    parser.add_argument(
        '--json', action='store_true', help="Print one JSON document instead of the summary line."
    )
    parser.add_argument('-v', '--version', action='store_true', help="Print the version and exit.")
    parser.add_argument('--no-color', action='store_true', help="Turn off color.")
    parser.add_argument('-d', '--debug', action='store_true', help="Show tracebacks for internal errors.")
    return parser


def _transcript_arg(args: argparse.Namespace) -> Optional[str]:
    return args.transcript_file or args.legacy_transcript


def _is_single_session(args: argparse.Namespace) -> bool:
    return not args.backfill and bool(args.session_id and _transcript_arg(args))


def validate_args(parser: argparse.ArgumentParser, args: argparse.Namespace) -> None:
    if args.transcript_file is not None and args.legacy_transcript is not None:
        parser.error("give the transcript once: --transcript <FILE> or the positional, not both")
    if not _is_single_session(args):
        return
    session_id = cli_common.sanitize_display(args.session_id)
    if not SESSION_ID_RE.fullmatch(args.session_id):
        parser.error(f"session ID must be a lowercase UUID: {session_id}")
    # Without resolving symlinks: the name on the path is what a later backfill would use.
    transcript = Path(_transcript_arg(args))
    if transcript.name == "transcript.jsonl":
        named = transcript.parent.name
    else:
        named = transcript.stem if transcript.suffix == ".jsonl" else ""
    if named != args.session_id:
        shown = cli_common.sanitize_display(str(transcript))
        parser.error(
            f"session ID {session_id} does not match transcript {shown}: "
            "expected <session>.jsonl or <session>/transcript.jsonl"
        )


def _describe_scope(args: argparse.Namespace) -> str:
    if not args.backfill:
        return f"session {args.session_id}"
    if args.since is None:
        return f"all sessions under {PROJECTS_DIR}"
    since = datetime(1970, 1, 1, tzinfo=timezone.utc) + timedelta(seconds=args.since)
    return f"sessions under {PROJECTS_DIR} changed since {since:%Y-%m-%dT%H:%M:%SZ}"


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    if args.no_color:
        os.environ["__SESSION_SEARCH_NO_COLOR"] = "1"
    if args.debug:
        os.environ["SESSION_SEARCH_DEBUG"] = "1"

    if args.version:
        if args.json:
            cli_common.emit_json({"version": cli_common.VERSION})
        else:
            print(cli_common.VERSION)
        return 0

    validate_args(parser, args)
    if args.legacy_transcript is not None:
        prefix = cli_common.glyph("warning", cli_common.resolve_style(sys.stderr, args.no_color))
        _note(f"{prefix} The positional transcript is deprecated; use --transcript <FILE>.")

    if not DB_PATH.exists():
        _note(f"Database not found: {DB_PATH}")
        return 1

    if not args.backfill and not _is_single_session(args):
        parser.print_help()
        return 1

    _note(f"session-index-chunk: rewriting chunks in {DB_PATH}; scope: {_describe_scope(args)}")

    conn = sqlite3.connect(str(DB_PATH), timeout=10)
    try:
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
            stats = backfill(conn, cutoff=args.since)
            _report_backfill(stats, args.json)
        else:
            stats = ChunkStats()
            _chunk_item(conn, args.session_id, _transcript_arg(args), stats)
            _report_session(args.session_id, stats, args.json)
    finally:
        conn.close()

    return 1 if stats.failed or stats.not_attempted else 0


if __name__ == '__main__':
    cli_common.run_cli(main, PROG)
