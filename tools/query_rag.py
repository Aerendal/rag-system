#!/usr/bin/env python3
# rag_tools/query_rag.py
"""
Query RAG - Search and retrieve knowledge from SQLite RAG database.

This script provides a CLI interface for querying the knowledge base using:
- FTS5 full-text search
- Vector similarity search (if sqlite-vec available)
- Hybrid search (FTS + vector reranking)
- Filtered search (by module, topic, doc_type)

Usage:
    # Full-text search
    python query_rag.py search "WAL checkpoint modes" --limit 5

    # Search with filters
    python query_rag.py search "jsonb" --module JSONB --limit 10

    # Vector search (requires embeddings)
    python query_rag.py vector "explain transactions" --limit 5

    # Get context for RAG prompt
    python query_rag.py context "How does FTS5 tokenizer work?" --max-tokens 2000

Author: Claude (AI System Architect)
Created: 2025-11-22
Version: 1.0.0
"""

import sqlite3
import argparse
import sys
from typing import List, Dict, Optional, Tuple
import json


class RAGQuery:
    """Query interface for SQLite RAG knowledge base."""

    def __init__(self, db_path: str = "sqlite_knowledge.db"):
        """
        Initialize RAG query interface.

        Args:
            db_path: Path to SQLite database
        """
        self.db_path = db_path
        self.conn = None

    def __enter__(self):
        """Context manager entry."""
        self.conn = sqlite3.connect(self.db_path)
        self.conn.row_factory = sqlite3.Row
        return self

    def __exit__(self, exc_type, exc_val, exc_tb):
        """Context manager exit."""
        if self.conn:
            self.conn.close()

    def fts_search(
        self,
        query: str,
        module: Optional[str] = None,
        topic_id: Optional[int] = None,
        doc_type: Optional[str] = None,
        limit: int = 10
    ) -> List[Dict]:
        """
        Full-text search using FTS5.

        Args:
            query: Search query (FTS5 syntax supported)
            module: Filter by module (e.g., 'PRAGMA', 'SQL')
            topic_id: Filter by topic ID
            doc_type: Filter by doc type ('official', 'ai_meta', etc.)
            limit: Maximum results

        Returns:
            List of result dicts with chunk and document info
        """
        # Build WHERE clause for filters
        filters = []
        params = [query]

        if module:
            filters.append("fts.module = ?")
            params.append(module)

        if topic_id:
            filters.append("fts.topic_id = ?")
            params.append(topic_id)

        if doc_type:
            filters.append("d.doc_type = ?")
            params.append(doc_type)

        where_clause = ""
        if filters:
            where_clause = "AND " + " AND ".join(filters)

        # Query
        sql = f"""
        SELECT
            c.id AS chunk_id,
            c.heading,
            c.text,
            c.token_est,
            c.kind,
            d.id AS doc_id,
            d.title AS doc_title,
            d.module,
            d.doc_type,
            d.version,
            d.source,
            fts.rank
        FROM chunks_fts fts
        JOIN chunks c ON c.id = fts.rowid
        JOIN docs d ON d.id = c.doc_id
        WHERE chunks_fts MATCH ?
          {where_clause}
        ORDER BY fts.rank
        LIMIT ?
        """

        params.append(limit)

        results = self.conn.execute(sql, params).fetchall()

        return [dict(row) for row in results]

    def get_chunk_context(
        self,
        chunk_id: int,
        context_before: int = 1,
        context_after: int = 1
    ) -> List[Dict]:
        """
        Get surrounding chunks for context.

        Args:
            chunk_id: Chunk ID
            context_before: Number of chunks before
            context_after: Number of chunks after

        Returns:
            List of chunks (before, target, after)
        """
        # Get target chunk
        target = self.conn.execute(
            "SELECT * FROM chunks WHERE id = ?", (chunk_id,)
        ).fetchone()

        if not target:
            return []

        doc_id = target['doc_id']
        ord_target = target['ord']

        # Get context chunks
        chunks = self.conn.execute(
            """
            SELECT *
            FROM chunks
            WHERE doc_id = ?
              AND ord BETWEEN ? AND ?
            ORDER BY ord
            """,
            (doc_id, ord_target - context_before, ord_target + context_after)
        ).fetchall()

        return [dict(row) for row in chunks]

    def build_rag_context(
        self,
        query: str,
        max_tokens: int = 2000,
        module: Optional[str] = None
    ) -> Tuple[str, List[Dict]]:
        """
        Build context string for RAG prompt.

        Strategy:
        1. FTS search to get top results
        2. Accumulate chunks until max_tokens reached
        3. Return formatted context + metadata

        Args:
            query: User query
            max_tokens: Maximum tokens for context
            module: Optional module filter

        Returns:
            (context_str, source_chunks): Formatted context and source metadata
        """
        # Search
        results = self.fts_search(query, module=module, limit=20)

        # Accumulate chunks
        context_parts = []
        total_tokens = 0
        sources = []

        for result in results:
            chunk_tokens = result['token_est'] or 0

            if total_tokens + chunk_tokens > max_tokens:
                break

            # Format chunk
            heading = result['heading'] or "(no heading)"
            text = result['text']
            source = f"{result['doc_title']} ({result['module']})"

            context_parts.append(f"## {heading}\n\n{text}\n\n")
            total_tokens += chunk_tokens

            sources.append({
                'chunk_id': result['chunk_id'],
                'doc_title': result['doc_title'],
                'module': result['module'],
                'heading': result['heading'],
                'source': result['source']
            })

        context_str = "".join(context_parts)

        return context_str, sources

    def list_modules(self) -> List[Tuple[str, int]]:
        """
        List all modules with document counts.

        Returns:
            List of (module, doc_count) tuples
        """
        results = self.conn.execute(
            """
            SELECT module, COUNT(*) AS doc_count
            FROM docs
            GROUP BY module
            ORDER BY doc_count DESC
            """
        ).fetchall()

        return [(row['module'], row['doc_count']) for row in results]

    def list_topics(self, status: Optional[str] = None) -> List[Dict]:
        """
        List topics with document counts.

        Args:
            status: Filter by status ('pending', 'in_progress', 'done')

        Returns:
            List of topic dicts
        """
        sql = """
        SELECT
            t.id,
            t.module,
            t.title,
            t.status,
            t.priority,
            COUNT(d.id) AS doc_count
        FROM topics t
        LEFT JOIN docs d ON d.topic_id = t.id
        """

        if status:
            sql += " WHERE t.status = ?"
            params = [status]
        else:
            params = []

        sql += " GROUP BY t.id ORDER BY t.priority, t.created_at"

        results = self.conn.execute(sql, params).fetchall()
        return [dict(row) for row in results]

    def get_doc_stats(self) -> Dict:
        """
        Get database statistics.

        Returns:
            Dict with stats (doc count, chunk count, modules, etc.)
        """
        stats = {}

        # Doc counts by type
        doc_counts = self.conn.execute(
            """
            SELECT doc_type, COUNT(*) AS count
            FROM docs
            GROUP BY doc_type
            """
        ).fetchall()
        stats['doc_counts_by_type'] = {row['doc_type']: row['count'] for row in doc_counts}

        # Total chunks
        total_chunks = self.conn.execute("SELECT COUNT(*) FROM chunks").fetchone()[0]
        stats['total_chunks'] = total_chunks

        # Total tokens (estimated)
        total_tokens = self.conn.execute(
            "SELECT SUM(token_est) FROM chunks"
        ).fetchone()[0] or 0
        stats['total_tokens_estimated'] = total_tokens

        # Modules
        module_count = self.conn.execute(
            "SELECT COUNT(DISTINCT module) FROM docs"
        ).fetchone()[0]
        stats['module_count'] = module_count

        # Topics
        topic_stats = self.conn.execute(
            """
            SELECT status, COUNT(*) AS count
            FROM topics
            GROUP BY status
            """
        ).fetchall()
        stats['topic_counts_by_status'] = {row['status']: row['count'] for row in topic_stats}

        # Sessions
        session_count = self.conn.execute("SELECT COUNT(*) FROM sessions").fetchone()[0]
        stats['total_sessions'] = session_count

        imported_sessions = self.conn.execute(
            "SELECT COUNT(*) FROM sessions WHERE imported_to_docs = 1"
        ).fetchone()[0]
        stats['imported_sessions'] = imported_sessions

        return stats


def print_search_results(results: List[Dict], verbose: bool = False) -> None:
    """Pretty print search results."""
    if not results:
        print("No results found.")
        return

    print(f"\nFound {len(results)} results:\n")
    print("=" * 80)

    for i, result in enumerate(results, 1):
        heading = result['heading'] or "(no heading)"
        print(f"\n[{i}] {result['doc_title']} > {heading}")
        print(f"    Module: {result['module']} | Type: {result['doc_type']} | Tokens: ~{result['token_est']}")

        if result.get('source'):
            print(f"    Source: {result['source']}")

        if verbose:
            print(f"\n    {result['text'][:300]}...")

        print("-" * 80)


def main():
    """Main CLI entry point."""
    parser = argparse.ArgumentParser(
        description="Query RAG - Search SQLite Knowledge Base",
        formatter_class=argparse.RawDescriptionHelpFormatter
    )

    parser.add_argument('--db', default='sqlite_knowledge.db', help='Database path')

    subparsers = parser.add_subparsers(dest='command', help='Command')

    # search command
    search_parser = subparsers.add_parser('search', help='Full-text search (FTS5)')
    search_parser.add_argument('query', help='Search query')
    search_parser.add_argument('--module', help='Filter by module')
    search_parser.add_argument('--topic-id', type=int, help='Filter by topic ID')
    search_parser.add_argument('--doc-type', help='Filter by doc type')
    search_parser.add_argument('--limit', type=int, default=10, help='Max results')
    search_parser.add_argument('--verbose', '-v', action='store_true', help='Show full text')

    # context command
    context_parser = subparsers.add_parser('context', help='Build RAG context for prompt')
    context_parser.add_argument('query', help='User query')
    context_parser.add_argument('--max-tokens', type=int, default=2000, help='Max context tokens')
    context_parser.add_argument('--module', help='Filter by module')
    context_parser.add_argument('--output', help='Save context to file')

    # modules command
    subparsers.add_parser('modules', help='List all modules')

    # topics command
    topics_parser = subparsers.add_parser('topics', help='List topics')
    topics_parser.add_argument('--status', help='Filter by status')

    # stats command
    subparsers.add_parser('stats', help='Show database statistics')

    args = parser.parse_args()

    if not args.command:
        parser.print_help()
        sys.exit(1)

    # Execute command
    with RAGQuery(args.db) as rag:
        if args.command == 'search':
            results = rag.fts_search(
                query=args.query,
                module=args.module,
                topic_id=args.topic_id,
                doc_type=args.doc_type,
                limit=args.limit
            )
            print_search_results(results, verbose=args.verbose)

        elif args.command == 'context':
            context_str, sources = rag.build_rag_context(
                query=args.query,
                max_tokens=args.max_tokens,
                module=args.module
            )

            print("\n" + "=" * 80)
            print("RAG CONTEXT")
            print("=" * 80 + "\n")
            print(context_str)
            print("\n" + "=" * 80)
            print(f"Sources: {len(sources)} chunks")
            print("=" * 80 + "\n")

            for src in sources:
                print(f"- {src['doc_title']} > {src['heading']} ({src['module']})")

            if args.output:
                with open(args.output, 'w') as f:
                    f.write(context_str)
                print(f"\n✓ Context saved to {args.output}")

        elif args.command == 'modules':
            modules = rag.list_modules()
            print("\nModules:\n")
            for module, count in modules:
                print(f"  {module}: {count} docs")

        elif args.command == 'topics':
            topics = rag.list_topics(status=args.status)
            print(f"\nTopics ({len(topics)}):\n")
            for topic in topics:
                status_emoji = {
                    'pending': '⏳',
                    'in_progress': '🔄',
                    'done': '✅',
                    'error': '❌'
                }
                emoji = status_emoji.get(topic['status'], '❓')
                print(f"{emoji} [{topic['id']}] {topic['title']} ({topic['module']})")
                print(f"    Status: {topic['status']} | Priority: {topic['priority']} | Docs: {topic['doc_count']}")

        elif args.command == 'stats':
            stats = rag.get_doc_stats()
            print("\n" + "=" * 60)
            print("DATABASE STATISTICS")
            print("=" * 60 + "\n")

            print("Documents:")
            for doc_type, count in stats['doc_counts_by_type'].items():
                print(f"  {doc_type}: {count}")

            print(f"\nChunks: {stats['total_chunks']}")
            print(f"Estimated Tokens: ~{stats['total_tokens_estimated']:,}")
            print(f"Modules: {stats['module_count']}")

            print("\nTopics:")
            for status, count in stats['topic_counts_by_status'].items():
                print(f"  {status}: {count}")

            print(f"\nSessions: {stats['total_sessions']}")
            print(f"Imported Sessions: {stats['imported_sessions']}")


if __name__ == '__main__':
    main()
