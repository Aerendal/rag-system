#!/usr/bin/env python3
# rag_tools/cli_logger.py
"""
CLI Logger - Log AI conversations to SQLite knowledge base.

This script logs conversations between user and AI assistant to the
sessions and messages tables in the SQLite RAG database.

Usage:
    # Start new session
    python cli_logger.py start --topic-id 1 --model "claude-sonnet-4-5"

    # Log user message
    python cli_logger.py log-user --session-id 1 "Explain WAL checkpoints"

    # Log assistant message
    python cli_logger.py log-assistant --session-id 1 "WAL checkpoints..."

    # End session
    python cli_logger.py end --session-id 1 --notes "Covered all modes"

    # Interactive mode (recommended)
    python cli_logger.py interactive --topic-id 1

Author: Claude (AI System Architect)
Created: 2025-11-22
Version: 1.0.0
"""

import sqlite3
import sys
import argparse
from datetime import datetime
from typing import Optional, Tuple
import json


class CLILogger:
    """Handles logging of CLI conversations to SQLite database."""

    def __init__(self, db_path: str = "sqlite_knowledge.db"):
        """
        Initialize CLI logger.

        Args:
            db_path: Path to SQLite database file
        """
        self.db_path = db_path
        self.conn = None

    def __enter__(self):
        """Context manager entry - connect to database."""
        self.conn = sqlite3.connect(self.db_path)
        self.conn.row_factory = sqlite3.Row
        # Enable foreign keys
        self.conn.execute("PRAGMA foreign_keys = ON")
        return self

    def __exit__(self, exc_type, exc_val, exc_tb):
        """Context manager exit - close database connection."""
        if self.conn:
            self.conn.close()

    def start_session(
        self,
        topic_id: Optional[int] = None,
        model: str = "claude-sonnet-4-5-20250929",
        notes: Optional[str] = None
    ) -> int:
        """
        Start a new conversation session.

        Args:
            topic_id: ID of topic being discussed (NULL for general session)
            model: AI model identifier
            notes: Optional initial notes

        Returns:
            session_id: ID of created session
        """
        cursor = self.conn.execute(
            """
            INSERT INTO sessions (topic_id, model, notes)
            VALUES (?, ?, ?)
            """,
            (topic_id, model, notes)
        )
        self.conn.commit()
        session_id = cursor.lastrowid

        print(f"✓ Started session {session_id}")
        if topic_id:
            topic = self.conn.execute(
                "SELECT title FROM topics WHERE id = ?", (topic_id,)
            ).fetchone()
            if topic:
                print(f"  Topic: {topic['title']}")

        return session_id

    def log_message(
        self,
        session_id: int,
        role: str,
        content: str,
        tokens: Optional[int] = None,
        metadata: Optional[dict] = None
    ) -> int:
        """
        Log a single message to the session.

        Args:
            session_id: Session ID
            role: 'user', 'assistant', or 'system'
            content: Message content
            tokens: Optional token count
            metadata: Optional metadata dict (stored as JSON)

        Returns:
            message_id: ID of inserted message
        """
        # Get next step number
        cursor = self.conn.execute(
            """
            SELECT COALESCE(MAX(step), 0) + 1 AS next_step
            FROM messages
            WHERE session_id = ?
            """,
            (session_id,)
        )
        next_step = cursor.fetchone()['next_step']

        # Serialize metadata to JSON if provided
        metadata_json = json.dumps(metadata) if metadata else None

        # Insert message
        cursor = self.conn.execute(
            """
            INSERT INTO messages (session_id, role, content, step, tokens, metadata)
            VALUES (?, ?, ?, ?, ?, ?)
            """,
            (session_id, role, content, next_step, tokens, metadata_json)
        )
        self.conn.commit()
        message_id = cursor.lastrowid

        # Pretty print
        role_emoji = {"user": "👤", "assistant": "🤖", "system": "⚙️"}
        emoji = role_emoji.get(role, "💬")
        print(f"{emoji} [{role}] Message {message_id} logged (step {next_step})")

        return message_id

    def end_session(
        self,
        session_id: int,
        notes: Optional[str] = None,
        total_tokens: Optional[int] = None
    ) -> None:
        """
        End a conversation session.

        Args:
            session_id: Session ID to end
            notes: Optional summary notes
            total_tokens: Optional total token count for session
        """
        self.conn.execute(
            """
            UPDATE sessions
            SET finished_at = datetime('now'),
                notes = COALESCE(?, notes),
                total_tokens = COALESCE(?, total_tokens)
            WHERE id = ?
            """,
            (notes, total_tokens, session_id)
        )
        self.conn.commit()

        # Show summary
        session = self.conn.execute(
            """
            SELECT
                s.id,
                s.started_at,
                s.finished_at,
                s.notes,
                t.title AS topic_title,
                COUNT(m.id) AS message_count
            FROM sessions s
            LEFT JOIN topics t ON t.id = s.topic_id
            LEFT JOIN messages m ON m.session_id = s.id
            WHERE s.id = ?
            GROUP BY s.id
            """,
            (session_id,)
        ).fetchone()

        print(f"\n✓ Session {session_id} ended")
        print(f"  Duration: {session['started_at']} → {session['finished_at']}")
        print(f"  Messages: {session['message_count']}")
        if session['topic_title']:
            print(f"  Topic: {session['topic_title']}")
        if session['notes']:
            print(f"  Notes: {session['notes']}")

    def interactive_session(self, topic_id: Optional[int] = None) -> None:
        """
        Run an interactive logging session.

        User types messages line by line. Special commands:
        - /end - End session
        - /note <text> - Add note to session
        - /quit - Exit without ending session

        Args:
            topic_id: Optional topic ID for this session
        """
        print("\n" + "="*60)
        print("INTERACTIVE SESSION LOGGER")
        print("="*60)
        print("Commands:")
        print("  /end [notes]  - End session with optional notes")
        print("  /note <text>  - Add note to current session")
        print("  /quit         - Exit without ending session")
        print("="*60 + "\n")

        # Start session
        session_id = self.start_session(topic_id=topic_id)

        step_counter = 0

        while True:
            try:
                # Alternate between user and assistant
                role = "user" if step_counter % 2 == 0 else "assistant"
                prompt = "👤 You: " if role == "user" else "🤖 AI: "

                user_input = input(prompt).strip()

                # Handle commands
                if user_input.startswith("/end"):
                    notes = user_input[5:].strip() if len(user_input) > 5 else None
                    self.end_session(session_id, notes=notes)
                    print("✓ Session ended. Exiting.")
                    break

                elif user_input.startswith("/note"):
                    note_text = user_input[6:].strip()
                    self.conn.execute(
                        "UPDATE sessions SET notes = ? WHERE id = ?",
                        (note_text, session_id)
                    )
                    self.conn.commit()
                    print(f"✓ Note added: {note_text}")
                    continue

                elif user_input == "/quit":
                    print("⚠ Session not ended. Use /end to finish session.")
                    break

                # Log message
                if user_input:
                    self.log_message(session_id, role, user_input)
                    step_counter += 1

            except KeyboardInterrupt:
                print("\n⚠ Interrupted. Session not ended.")
                break
            except EOFError:
                print("\n⚠ EOF received. Session not ended.")
                break

    def list_active_sessions(self) -> None:
        """List all active (unfinished) sessions."""
        sessions = self.conn.execute(
            """
            SELECT
                s.id,
                s.started_at,
                t.title AS topic_title,
                s.model,
                COUNT(m.id) AS message_count
            FROM sessions s
            LEFT JOIN topics t ON t.id = s.topic_id
            LEFT JOIN messages m ON m.session_id = s.id
            WHERE s.finished_at IS NULL
            GROUP BY s.id
            ORDER BY s.started_at DESC
            """
        ).fetchall()

        if not sessions:
            print("No active sessions.")
            return

        print("\nActive Sessions:")
        print("-" * 80)
        for s in sessions:
            topic = s['topic_title'] or "(no topic)"
            print(f"Session {s['id']}: {topic}")
            print(f"  Started: {s['started_at']}")
            print(f"  Model: {s['model']}")
            print(f"  Messages: {s['message_count']}")
            print()


def main():
    """Main CLI entry point."""
    parser = argparse.ArgumentParser(
        description="CLI Logger for SQLite RAG Knowledge Base",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  # Interactive mode (recommended)
  python cli_logger.py interactive --topic-id 1

  # Manual logging
  python cli_logger.py start --topic-id 1
  python cli_logger.py log-user --session-id 1 "What is WAL?"
  python cli_logger.py log-assistant --session-id 1 "WAL is..."
  python cli_logger.py end --session-id 1 --notes "Covered basics"

  # List active sessions
  python cli_logger.py list
        """
    )

    parser.add_argument(
        '--db',
        default='sqlite_knowledge.db',
        help='Path to SQLite database (default: sqlite_knowledge.db)'
    )

    subparsers = parser.add_subparsers(dest='command', help='Command to execute')

    # start command
    start_parser = subparsers.add_parser('start', help='Start new session')
    start_parser.add_argument('--topic-id', type=int, help='Topic ID')
    start_parser.add_argument('--model', default='claude-sonnet-4-5-20250929', help='AI model')
    start_parser.add_argument('--notes', help='Initial notes')

    # log-user command
    user_parser = subparsers.add_parser('log-user', help='Log user message')
    user_parser.add_argument('--session-id', type=int, required=True, help='Session ID')
    user_parser.add_argument('content', help='Message content')
    user_parser.add_argument('--tokens', type=int, help='Token count')

    # log-assistant command
    assistant_parser = subparsers.add_parser('log-assistant', help='Log assistant message')
    assistant_parser.add_argument('--session-id', type=int, required=True, help='Session ID')
    assistant_parser.add_argument('content', help='Message content')
    assistant_parser.add_argument('--tokens', type=int, help='Token count')

    # end command
    end_parser = subparsers.add_parser('end', help='End session')
    end_parser.add_argument('--session-id', type=int, required=True, help='Session ID')
    end_parser.add_argument('--notes', help='Session summary notes')
    end_parser.add_argument('--total-tokens', type=int, help='Total token count')

    # interactive command
    interactive_parser = subparsers.add_parser('interactive', help='Interactive logging mode')
    interactive_parser.add_argument('--topic-id', type=int, help='Topic ID')

    # list command
    subparsers.add_parser('list', help='List active sessions')

    args = parser.parse_args()

    if not args.command:
        parser.print_help()
        sys.exit(1)

    # Execute command
    with CLILogger(args.db) as logger:
        if args.command == 'start':
            logger.start_session(
                topic_id=args.topic_id,
                model=args.model,
                notes=args.notes
            )

        elif args.command == 'log-user':
            logger.log_message(
                session_id=args.session_id,
                role='user',
                content=args.content,
                tokens=args.tokens
            )

        elif args.command == 'log-assistant':
            logger.log_message(
                session_id=args.session_id,
                role='assistant',
                content=args.content,
                tokens=args.tokens
            )

        elif args.command == 'end':
            logger.end_session(
                session_id=args.session_id,
                notes=args.notes,
                total_tokens=args.total_tokens
            )

        elif args.command == 'interactive':
            logger.interactive_session(topic_id=args.topic_id)

        elif args.command == 'list':
            logger.list_active_sessions()


if __name__ == '__main__':
    main()
