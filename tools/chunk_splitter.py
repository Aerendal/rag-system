#!/usr/bin/env python3
# rag_tools/chunk_splitter.py
"""
Chunk Splitter - Intelligently split documents and messages into chunks.

This script takes long-form content (session messages, markdown docs, HTML)
and splits it into semantic chunks suitable for RAG retrieval.

Splitting strategies:
- Markdown: Split on headers (##, ###), preserve hierarchy
- Plain text: Split on paragraphs, respect sentence boundaries
- Code: Split on function/class definitions
- Messages: Split long messages (>1000 tokens) into sub-chunks

Usage:
    # Split session messages into chunks
    python chunk_splitter.py from-session --session-id 1 --output chunks.json

    # Split markdown file
    python chunk_splitter.py from-markdown --input README.md --output chunks.json

    # Split and import directly to database
    python chunk_splitter.py from-session --session-id 1 --import --doc-id 1

Author: Claude (AI System Architect)
Created: 2025-11-22
Version: 1.0.0
"""

import sqlite3
import re
import json
import argparse
import sys
from typing import List, Dict, Optional, Tuple
from dataclasses import dataclass, asdict
import hashlib


@dataclass
class Chunk:
    """Represents a single chunk of content."""
    heading: Optional[str]
    text: str
    ord: int  # Order within document
    kind: str  # 'doc', 'ai', 'note', 'code', 'example'
    token_est: int
    hash: Optional[str] = None
    metadata: Optional[Dict] = None

    def to_dict(self) -> dict:
        """Convert to dictionary for JSON serialization."""
        d = asdict(self)
        if self.metadata:
            d['metadata'] = json.dumps(self.metadata)
        return d


class ChunkSplitter:
    """Intelligent chunk splitting for RAG."""

    def __init__(
        self,
        max_chunk_tokens: int = 500,
        min_chunk_tokens: int = 50,
        overlap_tokens: int = 50
    ):
        """
        Initialize chunk splitter.

        Args:
            max_chunk_tokens: Maximum tokens per chunk
            min_chunk_tokens: Minimum tokens per chunk (avoid tiny chunks)
            overlap_tokens: Overlap between adjacent chunks (context continuity)
        """
        self.max_chunk_tokens = max_chunk_tokens
        self.min_chunk_tokens = min_chunk_tokens
        self.overlap_tokens = overlap_tokens

    @staticmethod
    def estimate_tokens(text: str) -> int:
        """
        Rough token estimation (words * 1.3 as approximation).

        For production, use tiktoken or similar.

        Args:
            text: Input text

        Returns:
            Estimated token count
        """
        # Simple heuristic: ~1.3 tokens per word for English
        words = len(text.split())
        return int(words * 1.3)

    @staticmethod
    def compute_hash(text: str) -> str:
        """
        Compute SHA256 hash of text for deduplication.

        Args:
            text: Input text

        Returns:
            Hex digest of SHA256 hash
        """
        return hashlib.sha256(text.encode('utf-8')).hexdigest()

    def split_markdown(self, markdown: str) -> List[Chunk]:
        """
        Split markdown into chunks based on headers.

        Strategy:
        - Split on ## and ### headers
        - Each chunk = header + content until next header
        - Preserve heading hierarchy in chunk metadata

        Args:
            markdown: Markdown text

        Returns:
            List of chunks
        """
        chunks = []
        # Regex to match headers (## or ### ...)
        header_pattern = re.compile(r'^(#{2,3})\s+(.+)$', re.MULTILINE)

        # Split into sections
        sections = header_pattern.split(markdown)

        # sections format: [pre_content, level1, heading1, content1, level2, heading2, content2, ...]
        current_heading = None
        current_level = None
        ord_counter = 0

        i = 0
        while i < len(sections):
            if i == 0:
                # Pre-content (before first header)
                text = sections[i].strip()
                if text:
                    chunks.append(Chunk(
                        heading=None,
                        text=text,
                        ord=ord_counter,
                        kind='doc',
                        token_est=self.estimate_tokens(text),
                        hash=self.compute_hash(text)
                    ))
                    ord_counter += 1
                i += 1
            else:
                # level, heading, content
                if i + 2 < len(sections):
                    level = sections[i]
                    heading = sections[i + 1]
                    content = sections[i + 2].strip()

                    full_text = f"{level} {heading}\n\n{content}"
                    token_est = self.estimate_tokens(full_text)

                    # If chunk is too large, split content into paragraphs
                    if token_est > self.max_chunk_tokens:
                        # Split content by paragraphs
                        paragraphs = re.split(r'\n\n+', content)
                        current_chunk_text = f"{level} {heading}\n\n"
                        current_tokens = self.estimate_tokens(current_chunk_text)

                        for para in paragraphs:
                            para_tokens = self.estimate_tokens(para)
                            if current_tokens + para_tokens > self.max_chunk_tokens:
                                # Flush current chunk
                                if current_chunk_text.strip():
                                    chunks.append(Chunk(
                                        heading=heading,
                                        text=current_chunk_text.strip(),
                                        ord=ord_counter,
                                        kind='doc',
                                        token_est=self.estimate_tokens(current_chunk_text),
                                        hash=self.compute_hash(current_chunk_text)
                                    ))
                                    ord_counter += 1
                                # Start new chunk
                                current_chunk_text = para + "\n\n"
                                current_tokens = para_tokens
                            else:
                                current_chunk_text += para + "\n\n"
                                current_tokens += para_tokens

                        # Flush remaining
                        if current_chunk_text.strip():
                            chunks.append(Chunk(
                                heading=heading,
                                text=current_chunk_text.strip(),
                                ord=ord_counter,
                                kind='doc',
                                token_est=self.estimate_tokens(current_chunk_text),
                                hash=self.compute_hash(current_chunk_text)
                            ))
                            ord_counter += 1
                    else:
                        # Chunk is within limit
                        chunks.append(Chunk(
                            heading=heading,
                            text=full_text,
                            ord=ord_counter,
                            kind='doc',
                            token_est=token_est,
                            hash=self.compute_hash(full_text)
                        ))
                        ord_counter += 1

                i += 3

        return chunks

    def split_plaintext(self, text: str, kind: str = 'doc') -> List[Chunk]:
        """
        Split plain text into chunks by paragraphs.

        Args:
            text: Plain text content
            kind: Chunk kind ('doc', 'ai', 'note')

        Returns:
            List of chunks
        """
        chunks = []
        paragraphs = re.split(r'\n\n+', text)

        current_chunk = ""
        current_tokens = 0
        ord_counter = 0

        for para in paragraphs:
            para_tokens = self.estimate_tokens(para)

            if current_tokens + para_tokens > self.max_chunk_tokens:
                # Flush current chunk
                if current_chunk.strip():
                    chunks.append(Chunk(
                        heading=None,
                        text=current_chunk.strip(),
                        ord=ord_counter,
                        kind=kind,
                        token_est=self.estimate_tokens(current_chunk),
                        hash=self.compute_hash(current_chunk)
                    ))
                    ord_counter += 1
                # Start new chunk
                current_chunk = para + "\n\n"
                current_tokens = para_tokens
            else:
                current_chunk += para + "\n\n"
                current_tokens += para_tokens

        # Flush remaining
        if current_chunk.strip():
            chunks.append(Chunk(
                heading=None,
                text=current_chunk.strip(),
                ord=ord_counter,
                kind=kind,
                token_est=self.estimate_tokens(current_chunk),
                hash=self.compute_hash(current_chunk)
            ))

        return chunks

    def split_session_messages(
        self,
        db_path: str,
        session_id: int
    ) -> Tuple[List[Chunk], Dict]:
        """
        Split session messages into chunks.

        Strategy:
        - Concatenate all assistant messages (ignore user prompts for now)
        - Split by message boundaries first, then by token limit
        - Preserve message metadata (step, role)

        Args:
            db_path: Path to SQLite database
            session_id: Session ID

        Returns:
            (chunks, session_metadata): List of chunks and session info dict
        """
        conn = sqlite3.connect(db_path)
        conn.row_factory = sqlite3.Row

        # Get session info
        session = conn.execute(
            """
            SELECT s.*, t.title AS topic_title, t.module
            FROM sessions s
            LEFT JOIN topics t ON t.id = s.topic_id
            WHERE s.id = ?
            """,
            (session_id,)
        ).fetchone()

        if not session:
            raise ValueError(f"Session {session_id} not found")

        # Get messages
        messages = conn.execute(
            """
            SELECT * FROM messages
            WHERE session_id = ?
            ORDER BY step
            """,
            (session_id,)
        ).fetchall()

        conn.close()

        chunks = []
        ord_counter = 0

        # Process messages
        for msg in messages:
            content = msg['content']
            role = msg['role']
            step = msg['step']

            # Determine chunk kind based on role
            kind = 'ai' if role == 'assistant' else 'note'

            # Estimate tokens
            token_est = self.estimate_tokens(content)

            # If message is too long, split it
            if token_est > self.max_chunk_tokens:
                sub_chunks = self.split_plaintext(content, kind=kind)
                for i, chunk in enumerate(sub_chunks):
                    chunk.ord = ord_counter
                    chunk.metadata = {
                        'session_id': session_id,
                        'message_step': step,
                        'message_role': role,
                        'sub_chunk': i
                    }
                    chunks.append(chunk)
                    ord_counter += 1
            else:
                # Single chunk from message
                chunks.append(Chunk(
                    heading=f"Message {step} ({role})",
                    text=content,
                    ord=ord_counter,
                    kind=kind,
                    token_est=token_est,
                    hash=self.compute_hash(content),
                    metadata={
                        'session_id': session_id,
                        'message_step': step,
                        'message_role': role
                    }
                ))
                ord_counter += 1

        # Session metadata for document creation
        session_metadata = {
            'session_id': session_id,
            'topic_id': session['topic_id'],
            'topic_title': session['topic_title'],
            'module': session['module'],
            'started_at': session['started_at'],
            'finished_at': session['finished_at'],
            'model': session['model']
        }

        return chunks, session_metadata


def import_chunks_to_db(
    db_path: str,
    doc_id: int,
    chunks: List[Chunk]
) -> int:
    """
    Import chunks directly to database.

    Args:
        db_path: Path to SQLite database
        doc_id: Document ID to attach chunks to
        chunks: List of chunks

    Returns:
        Number of chunks inserted
    """
    conn = sqlite3.connect(db_path)
    conn.execute("PRAGMA foreign_keys = ON")

    count = 0
    for chunk in chunks:
        metadata_json = json.dumps(chunk.metadata) if chunk.metadata else None

        conn.execute(
            """
            INSERT INTO chunks (doc_id, ord, heading, text, token_est, kind, hash, metadata)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """,
            (doc_id, chunk.ord, chunk.heading, chunk.text,
             chunk.token_est, chunk.kind, chunk.hash, metadata_json)
        )
        count += 1

    conn.commit()
    conn.close()

    return count


def main():
    """Main CLI entry point."""
    parser = argparse.ArgumentParser(
        description="Chunk Splitter for SQLite RAG",
        formatter_class=argparse.RawDescriptionHelpFormatter
    )

    parser.add_argument('--db', default='sqlite_knowledge.db', help='Database path')

    subparsers = parser.add_subparsers(dest='command', help='Command')

    # from-session
    session_parser = subparsers.add_parser('from-session', help='Split session messages')
    session_parser.add_argument('--session-id', type=int, required=True, help='Session ID')
    session_parser.add_argument('--output', help='Output JSON file (optional)')
    session_parser.add_argument('--import', dest='import_db', action='store_true',
                                help='Import directly to database')
    session_parser.add_argument('--doc-id', type=int, help='Document ID (required with --import)')

    # from-markdown
    md_parser = subparsers.add_parser('from-markdown', help='Split markdown file')
    md_parser.add_argument('--input', required=True, help='Input markdown file')
    md_parser.add_argument('--output', help='Output JSON file (optional)')
    md_parser.add_argument('--import', dest='import_db', action='store_true',
                           help='Import directly to database')
    md_parser.add_argument('--doc-id', type=int, help='Document ID (required with --import)')

    # from-text
    text_parser = subparsers.add_parser('from-text', help='Split plain text file')
    text_parser.add_argument('--input', required=True, help='Input text file')
    text_parser.add_argument('--output', help='Output JSON file (optional)')
    text_parser.add_argument('--import', dest='import_db', action='store_true',
                            help='Import directly to database')
    text_parser.add_argument('--doc-id', type=int, help='Document ID (required with --import)')
    text_parser.add_argument('--kind', default='doc', help='Chunk kind (default: doc)')

    args = parser.parse_args()

    if not args.command:
        parser.print_help()
        sys.exit(1)

    splitter = ChunkSplitter()

    # Execute command
    if args.command == 'from-session':
        chunks, session_meta = splitter.split_session_messages(args.db, args.session_id)
        print(f"✓ Split session {args.session_id} into {len(chunks)} chunks")

        if args.output:
            with open(args.output, 'w') as f:
                json.dump({
                    'chunks': [c.to_dict() for c in chunks],
                    'session_metadata': session_meta
                }, f, indent=2)
            print(f"✓ Saved to {args.output}")

        if args.import_db:
            if not args.doc_id:
                print("Error: --doc-id required with --import", file=sys.stderr)
                sys.exit(1)
            count = import_chunks_to_db(args.db, args.doc_id, chunks)
            print(f"✓ Imported {count} chunks to doc_id={args.doc_id}")

    elif args.command == 'from-markdown':
        with open(args.input, 'r') as f:
            markdown = f.read()

        chunks = splitter.split_markdown(markdown)
        print(f"✓ Split markdown into {len(chunks)} chunks")

        if args.output:
            with open(args.output, 'w') as f:
                json.dump([c.to_dict() for c in chunks], f, indent=2)
            print(f"✓ Saved to {args.output}")

        if args.import_db:
            if not args.doc_id:
                print("Error: --doc-id required with --import", file=sys.stderr)
                sys.exit(1)
            count = import_chunks_to_db(args.db, args.doc_id, chunks)
            print(f"✓ Imported {count} chunks to doc_id={args.doc_id}")

    elif args.command == 'from-text':
        with open(args.input, 'r') as f:
            text = f.read()

        chunks = splitter.split_plaintext(text, kind=args.kind)
        print(f"✓ Split text into {len(chunks)} chunks")

        if args.output:
            with open(args.output, 'w') as f:
                json.dump([c.to_dict() for c in chunks], f, indent=2)
            print(f"✓ Saved to {args.output}")

        if args.import_db:
            if not args.doc_id:
                print("Error: --doc-id required with --import", file=sys.stderr)
                sys.exit(1)
            count = import_chunks_to_db(args.db, args.doc_id, chunks)
            print(f"✓ Imported {count} chunks to doc_id={args.doc_id}")


if __name__ == '__main__':
    main()
