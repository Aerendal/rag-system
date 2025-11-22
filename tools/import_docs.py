#!/usr/bin/env python3
# rag_tools/import_docs.py
"""
Import Docs - Import external documentation into SQLite RAG database.

This script fetches and imports documentation from external sources:
- SQLite official docs (HTML scraping)
- Markdown files (local or URLs)
- Plain text files
- JSON dumps

Workflow:
1. Fetch document (URL or file)
2. Parse/convert to text
3. Create doc entry in database
4. Split into chunks using chunk_splitter
5. Import chunks to database

Usage:
    # Import from URL (HTML)
    python import_docs.py from-url https://sqlite.org/pragma.html \\
        --module PRAGMA --title "PRAGMA Statements" --doc-type official

    # Import markdown file
    python import_docs.py from-file docs/fts5.md \\
        --module FTS5 --title "FTS5 Guide" --doc-type note

    # Import entire SQLite doc section
    python import_docs.py sqlite-docs --section pragma

Author: Claude (AI System Architect)
Created: 2025-11-22
Version: 1.0.0
"""

import sqlite3
import argparse
import sys
import re
from typing import Optional, List, Dict, Tuple
from pathlib import Path
import urllib.request
import urllib.parse
from html.parser import HTMLParser
import json


class HTMLToText(HTMLParser):
    """Simple HTML to text converter."""

    def __init__(self):
        super().__init__()
        self.text_parts = []
        self.skip_tags = {'script', 'style', 'head'}
        self.current_tag = None

    def handle_starttag(self, tag, attrs):
        self.current_tag = tag

    def handle_endtag(self, tag):
        if tag in ('p', 'div', 'br', 'h1', 'h2', 'h3', 'h4', 'h5', 'h6'):
            self.text_parts.append('\n\n')
        self.current_tag = None

    def handle_data(self, data):
        if self.current_tag not in self.skip_tags:
            # Clean whitespace
            cleaned = ' '.join(data.split())
            if cleaned:
                self.text_parts.append(cleaned + ' ')

    def get_text(self) -> str:
        return ''.join(self.text_parts).strip()


class DocImporter:
    """Handles importing external documentation."""

    def __init__(self, db_path: str = "sqlite_knowledge.db"):
        """
        Initialize doc importer.

        Args:
            db_path: Path to SQLite database
        """
        self.db_path = db_path
        self.conn = None

    def __enter__(self):
        """Context manager entry."""
        self.conn = sqlite3.connect(self.db_path)
        self.conn.row_factory = sqlite3.Row
        self.conn.execute("PRAGMA foreign_keys = ON")
        return self

    def __exit__(self, exc_type, exc_val, exc_tb):
        """Context manager exit."""
        if self.conn:
            self.conn.close()

    def fetch_url(self, url: str) -> str:
        """
        Fetch content from URL.

        Args:
            url: URL to fetch

        Returns:
            Response content (text)
        """
        print(f"Fetching {url}...")
        req = urllib.request.Request(
            url,
            headers={'User-Agent': 'Mozilla/5.0 (RAG Documentation Importer)'}
        )

        with urllib.request.urlopen(req) as response:
            content = response.read().decode('utf-8')

        print(f"✓ Fetched {len(content)} bytes")
        return content

    def html_to_text(self, html: str) -> str:
        """
        Convert HTML to plain text.

        Args:
            html: HTML content

        Returns:
            Plain text
        """
        parser = HTMLToText()
        parser.feed(html)
        return parser.get_text()

    def create_doc(
        self,
        module: str,
        slug: str,
        title: str,
        doc_type: str,
        source: str,
        topic_id: Optional[int] = None,
        version: Optional[str] = None,
        summary: Optional[str] = None
    ) -> int:
        """
        Create document entry in database.

        Args:
            module: Module name (e.g., 'PRAGMA', 'SQL', 'FTS5')
            slug: Unique slug (e.g., 'pragma_reference')
            title: Document title
            doc_type: 'official', 'ai_meta', 'note', 'example', 'conversation'
            source: Source URL or file path
            topic_id: Optional topic ID
            version: Optional SQLite version
            summary: Optional summary

        Returns:
            doc_id: ID of created document
        """
        cursor = self.conn.execute(
            """
            INSERT INTO docs (topic_id, module, slug, title, doc_type, source, version, summary)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(slug, doc_type, version) DO UPDATE SET
                updated_at = datetime('now'),
                title = excluded.title,
                source = excluded.source,
                summary = excluded.summary
            RETURNING id
            """,
            (topic_id, module, slug, title, doc_type, source, version, summary)
        )
        doc_id = cursor.fetchone()['id']
        self.conn.commit()

        print(f"✓ Created doc: {title} (id={doc_id})")
        return doc_id

    def import_chunks(self, doc_id: int, chunks: List[Dict]) -> int:
        """
        Import chunks for a document.

        Args:
            doc_id: Document ID
            chunks: List of chunk dicts (from chunk_splitter)

        Returns:
            Number of chunks imported
        """
        count = 0
        for chunk in chunks:
            metadata_json = None
            if 'metadata' in chunk and chunk['metadata']:
                if isinstance(chunk['metadata'], str):
                    metadata_json = chunk['metadata']
                else:
                    metadata_json = json.dumps(chunk['metadata'])

            self.conn.execute(
                """
                INSERT INTO chunks (doc_id, ord, heading, text, token_est, kind, hash, metadata)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    doc_id,
                    chunk['ord'],
                    chunk.get('heading'),
                    chunk['text'],
                    chunk.get('token_est'),
                    chunk.get('kind', 'doc'),
                    chunk.get('hash'),
                    metadata_json
                )
            )
            count += 1

        self.conn.commit()
        print(f"✓ Imported {count} chunks")
        return count

    def import_from_url(
        self,
        url: str,
        module: str,
        title: str,
        doc_type: str = 'official',
        topic_id: Optional[int] = None,
        version: Optional[str] = None
    ) -> Tuple[int, int]:
        """
        Import document from URL (HTML).

        Args:
            url: Source URL
            module: Module name
            title: Document title
            doc_type: Document type
            topic_id: Optional topic ID
            version: Optional SQLite version

        Returns:
            (doc_id, chunk_count)
        """
        # Fetch content
        html = self.fetch_url(url)

        # Convert to text
        text = self.html_to_text(html)

        # Generate slug from URL
        parsed = urllib.parse.urlparse(url)
        slug = Path(parsed.path).stem or 'index'
        slug = f"{module.lower()}_{slug}"

        # Create doc
        doc_id = self.create_doc(
            module=module,
            slug=slug,
            title=title,
            doc_type=doc_type,
            source=url,
            topic_id=topic_id,
            version=version
        )

        # Split into chunks (using chunk_splitter logic inline)
        from chunk_splitter import ChunkSplitter
        splitter = ChunkSplitter()
        chunks = splitter.split_plaintext(text, kind='doc')

        # Import chunks
        chunk_count = self.import_chunks(doc_id, [c.to_dict() for c in chunks])

        return doc_id, chunk_count

    def import_from_file(
        self,
        file_path: str,
        module: str,
        title: str,
        doc_type: str = 'note',
        topic_id: Optional[int] = None,
        version: Optional[str] = None,
        file_format: str = 'auto'
    ) -> Tuple[int, int]:
        """
        Import document from local file.

        Args:
            file_path: Path to file
            module: Module name
            title: Document title
            doc_type: Document type
            topic_id: Optional topic ID
            version: Optional SQLite version
            file_format: 'auto', 'markdown', 'text', 'html'

        Returns:
            (doc_id, chunk_count)
        """
        path = Path(file_path)

        if not path.exists():
            raise FileNotFoundError(f"File not found: {file_path}")

        # Auto-detect format
        if file_format == 'auto':
            suffix = path.suffix.lower()
            if suffix in ('.md', '.markdown'):
                file_format = 'markdown'
            elif suffix in ('.html', '.htm'):
                file_format = 'html'
            else:
                file_format = 'text'

        # Read content
        with open(path, 'r', encoding='utf-8') as f:
            content = f.read()

        # Convert if needed
        if file_format == 'html':
            content = self.html_to_text(content)

        # Generate slug
        slug = f"{module.lower()}_{path.stem}"

        # Create doc
        doc_id = self.create_doc(
            module=module,
            slug=slug,
            title=title,
            doc_type=doc_type,
            source=str(path.absolute()),
            topic_id=topic_id,
            version=version
        )

        # Split into chunks
        from chunk_splitter import ChunkSplitter
        splitter = ChunkSplitter()

        if file_format == 'markdown':
            chunks = splitter.split_markdown(content)
        else:
            chunks = splitter.split_plaintext(content, kind='doc')

        # Import chunks
        chunk_count = self.import_chunks(doc_id, [c.to_dict() for c in chunks])

        return doc_id, chunk_count

    def import_sqlite_docs_section(
        self,
        section: str,
        version: str = '3.51.0'
    ) -> List[Tuple[int, int]]:
        """
        Import a section of official SQLite documentation.

        Args:
            section: Section name ('pragma', 'lang', 'c3ref', etc.)
            version: SQLite version

        Returns:
            List of (doc_id, chunk_count) tuples
        """
        # SQLite docs URL map
        docs_urls = {
            'pragma': ('https://sqlite.org/pragma.html', 'PRAGMA', 'PRAGMA Statements'),
            'lang': ('https://sqlite.org/lang.html', 'SQL', 'SQL Language Reference'),
            'fts5': ('https://sqlite.org/fts5.html', 'FTS5', 'FTS5 Full-Text Search'),
            'json1': ('https://sqlite.org/json1.html', 'JSONB', 'JSON Functions'),
            'wal': ('https://sqlite.org/wal.html', 'WAL', 'Write-Ahead Logging'),
            'vtab': ('https://sqlite.org/vtab.html', 'VTAB', 'Virtual Tables'),
            'window': ('https://sqlite.org/windowfunctions.html', 'SQL', 'Window Functions'),
        }

        if section not in docs_urls:
            raise ValueError(f"Unknown section: {section}. Available: {', '.join(docs_urls.keys())}")

        url, module, title = docs_urls[section]

        print(f"\nImporting {section} docs from {url}...")
        doc_id, chunk_count = self.import_from_url(
            url=url,
            module=module,
            title=title,
            doc_type='official',
            version=version
        )

        return [(doc_id, chunk_count)]


def main():
    """Main CLI entry point."""
    parser = argparse.ArgumentParser(
        description="Import Docs - Import external documentation to SQLite RAG",
        formatter_class=argparse.RawDescriptionHelpFormatter
    )

    parser.add_argument('--db', default='sqlite_knowledge.db', help='Database path')

    subparsers = parser.add_subparsers(dest='command', help='Command')

    # from-url command
    url_parser = subparsers.add_parser('from-url', help='Import from URL (HTML)')
    url_parser.add_argument('url', help='Source URL')
    url_parser.add_argument('--module', required=True, help='Module name (e.g., PRAGMA)')
    url_parser.add_argument('--title', required=True, help='Document title')
    url_parser.add_argument('--doc-type', default='official', help='Document type')
    url_parser.add_argument('--topic-id', type=int, help='Topic ID')
    url_parser.add_argument('--version', help='SQLite version (e.g., 3.51.0)')

    # from-file command
    file_parser = subparsers.add_parser('from-file', help='Import from local file')
    file_parser.add_argument('file', help='File path')
    file_parser.add_argument('--module', required=True, help='Module name')
    file_parser.add_argument('--title', required=True, help='Document title')
    file_parser.add_argument('--doc-type', default='note', help='Document type')
    file_parser.add_argument('--topic-id', type=int, help='Topic ID')
    file_parser.add_argument('--version', help='SQLite version')
    file_parser.add_argument('--format', default='auto', help='File format (auto, markdown, text, html)')

    # sqlite-docs command
    sqlite_parser = subparsers.add_parser('sqlite-docs', help='Import SQLite official docs')
    sqlite_parser.add_argument(
        '--section',
        required=True,
        choices=['pragma', 'lang', 'fts5', 'json1', 'wal', 'vtab', 'window'],
        help='Documentation section'
    )
    sqlite_parser.add_argument('--version', default='3.51.0', help='SQLite version')

    args = parser.parse_args()

    if not args.command:
        parser.print_help()
        sys.exit(1)

    # Execute command
    with DocImporter(args.db) as importer:
        if args.command == 'from-url':
            doc_id, chunk_count = importer.import_from_url(
                url=args.url,
                module=args.module,
                title=args.title,
                doc_type=args.doc_type,
                topic_id=args.topic_id,
                version=args.version
            )
            print(f"\n✓ Imported doc_id={doc_id} with {chunk_count} chunks")

        elif args.command == 'from-file':
            doc_id, chunk_count = importer.import_from_file(
                file_path=args.file,
                module=args.module,
                title=args.title,
                doc_type=args.doc_type,
                topic_id=args.topic_id,
                version=args.version,
                file_format=args.format
            )
            print(f"\n✓ Imported doc_id={doc_id} with {chunk_count} chunks")

        elif args.command == 'sqlite-docs':
            results = importer.import_sqlite_docs_section(
                section=args.section,
                version=args.version
            )
            for doc_id, chunk_count in results:
                print(f"✓ doc_id={doc_id}, chunks={chunk_count}")


if __name__ == '__main__':
    main()
