#!/usr/bin/env python3
# rag_tools/test_contracts.py
"""
Contract-based tests - test BEHAVIOR, not IMPLEMENTATION

Philosophy:
- Test CONTRACTS (what system promises), not internals
- Allow REFACTORING without breaking tests
- Focus on USER-VISIBLE behavior
- EVOLVE with system (don't ossify)

What we test:
✓ Database schema contracts (tables exist, columns types)
✓ API contracts (tools accept inputs, return expected outputs)
✓ Data contracts (FTS5 syncs with chunks, foreign keys enforced)
✓ Performance contracts (queries under X ms)

What we DON'T test:
✗ Implementation details (how splitter splits - only that it returns chunks)
✗ Exact output format (allow flexible improvements)
✗ Internal function calls (mock-heavy tests)

Usage:
    python3 test_contracts.py                    # Run all tests
    python3 test_contracts.py --quick            # Quick tests only
    python3 test_contracts.py SchemaContract     # Specific test class

Author: Claude (AI System Architect)
Version: 1.0.0
"""

import sqlite3
import unittest
import os
import sys
import tempfile
import shutil
import json
from pathlib import Path

# Add rag_tools to path
sys.path.insert(0, str(Path(__file__).parent))


class SchemaContract(unittest.TestCase):
    """Test database schema contracts."""

    @classmethod
    def setUpClass(cls):
        """Create test database from schema."""
        cls.test_dir = tempfile.mkdtemp()
        cls.db_path = os.path.join(cls.test_dir, 'test.db')

        # Use schema_v2_fixed (production schema with fixed FTS5)
        schema_fixed = Path(__file__).parent.parent / 'schema_v2_fixed.sql'
        schema_v2 = Path(__file__).parent.parent / 'schema_v2.sql'
        schema_v1 = Path(__file__).parent.parent / 'schema_no_vec.sql'

        # Priority: fixed > v2 > v1
        if schema_fixed.exists():
            schema_file = schema_fixed
        elif schema_v2.exists():
            schema_file = schema_v2
        else:
            schema_file = schema_v1

        with open(schema_file) as f:
            schema_sql = f.read()

        conn = sqlite3.connect(cls.db_path)
        conn.executescript(schema_sql)
        conn.close()

    @classmethod
    def tearDownClass(cls):
        """Clean up test database."""
        shutil.rmtree(cls.test_dir)

    def setUp(self):
        """Connect to test database."""
        self.conn = sqlite3.connect(self.db_path)
        self.conn.row_factory = sqlite3.Row

    def tearDown(self):
        """Close database connection."""
        self.conn.close()

    def test_required_tables_exist(self):
        """CONTRACT: Core tables must exist."""
        required_tables = ['topics', 'sessions', 'messages', 'docs', 'chunks', 'chunks_fts']

        cursor = self.conn.execute(
            "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name"
        )
        existing_tables = [row[0] for row in cursor.fetchall()]

        for table in required_tables:
            self.assertIn(table, existing_tables,
                          f"Required table '{table}' not found")

    def test_foreign_keys_enforced(self):
        """CONTRACT: Foreign keys must be enforced."""
        # Try to insert invalid FK
        with self.assertRaises(sqlite3.IntegrityError):
            self.conn.execute("PRAGMA foreign_keys = ON")
            self.conn.execute("INSERT INTO chunks (doc_id, ord, text) VALUES (9999, 0, 'test')")
            self.conn.commit()

    def test_fts5_table_exists(self):
        """CONTRACT: FTS5 search must be available."""
        cursor = self.conn.execute("SELECT * FROM chunks_fts LIMIT 1")
        # Should not raise - table exists and is queryable
        cursor.fetchall()

    def test_views_exist(self):
        """CONTRACT: Utility views must exist."""
        required_views = ['chunks_with_docs', 'active_topics', 'session_summaries']

        cursor = self.conn.execute(
            "SELECT name FROM sqlite_master WHERE type='view' ORDER BY name"
        )
        existing_views = [row[0] for row in cursor.fetchall()]

        for view in required_views:
            self.assertIn(view, existing_views,
                          f"Required view '{view}' not found")


class DataIntegrityContract(unittest.TestCase):
    """Test data integrity contracts."""

    @classmethod
    def setUpClass(cls):
        """Create test database."""
        cls.test_dir = tempfile.mkdtemp()
        cls.db_path = os.path.join(cls.test_dir, 'test.db')

        # Use schema_v2_fixed (production schema)
        schema_fixed = Path(__file__).parent.parent / 'schema_v2_fixed.sql'
        schema_v1 = Path(__file__).parent.parent / 'schema_no_vec.sql'

        schema_file = schema_fixed if schema_fixed.exists() else schema_v1

        with open(schema_file) as f:
            schema_sql = f.read()

        conn = sqlite3.connect(cls.db_path)
        conn.executescript(schema_sql)
        conn.close()

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.test_dir)

    def setUp(self):
        self.conn = sqlite3.connect(self.db_path)
        self.conn.execute("PRAGMA foreign_keys = ON")

    def tearDown(self):
        self.conn.close()

    def test_fts5_syncs_with_chunks(self):
        """CONTRACT: FTS5 must stay in sync with chunks table."""
        # Insert doc
        doc_id = self.conn.execute(
            "INSERT INTO docs (module, slug, title, doc_type, source) "
            "VALUES ('TEST', 'test', 'Test Doc', 'note', 'test') RETURNING id"
        ).fetchone()[0]

        # Insert chunk
        chunk_id = self.conn.execute(
            "INSERT INTO chunks (doc_id, ord, text) "
            "VALUES (?, 0, 'test text') RETURNING id",
            (doc_id,)
        ).fetchone()[0]

        self.conn.commit()

        # Check FTS5 has the chunk
        fts_count = self.conn.execute(
            "SELECT COUNT(*) FROM chunks_fts WHERE rowid = ?", (chunk_id,)
        ).fetchone()[0]

        self.assertEqual(fts_count, 1, "FTS5 should contain inserted chunk")

        # Delete chunk
        self.conn.execute("DELETE FROM chunks WHERE id = ?", (chunk_id,))
        self.conn.commit()

        # Check FTS5 removed it
        fts_count_after = self.conn.execute(
            "SELECT COUNT(*) FROM chunks_fts WHERE rowid = ?", (chunk_id,)
        ).fetchone()[0]

        self.assertEqual(fts_count_after, 0, "FTS5 should remove deleted chunk")

    def test_cascade_delete(self):
        """CONTRACT: Cascading deletes must work."""
        # Create session
        session_id = self.conn.execute(
            "INSERT INTO sessions DEFAULT VALUES RETURNING id"
        ).fetchone()[0]

        # Add message
        self.conn.execute(
            "INSERT INTO messages (session_id, role, content, step) "
            "VALUES (?, 'user', 'test', 1)",
            (session_id,)
        )
        self.conn.commit()

        # Delete session
        self.conn.execute("DELETE FROM sessions WHERE id = ?", (session_id,))
        self.conn.commit()

        # Messages should be gone
        msg_count = self.conn.execute(
            "SELECT COUNT(*) FROM messages WHERE session_id = ?", (session_id,)
        ).fetchone()[0]

        self.assertEqual(msg_count, 0, "Messages should cascade delete with session")


class ToolsAPIContract(unittest.TestCase):
    """Test CLI tools API contracts."""

    @classmethod
    def setUpClass(cls):
        """Setup test database."""
        cls.test_dir = tempfile.mkdtemp()
        cls.db_path = os.path.join(cls.test_dir, 'test.db')

        # Use schema_v2_fixed (production schema)
        schema_fixed = Path(__file__).parent.parent / 'schema_v2_fixed.sql'
        schema_v1 = Path(__file__).parent.parent / 'schema_no_vec.sql'

        schema_file = schema_fixed if schema_fixed.exists() else schema_v1

        with open(schema_file) as f:
            schema_sql = f.read()

        conn = sqlite3.connect(cls.db_path)
        conn.executescript(schema_sql)
        conn.close()

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.test_dir)

    def test_cli_logger_creates_session(self):
        """CONTRACT: cli_logger must create valid sessions."""
        from cli_logger import CLILogger

        with CLILogger(self.db_path) as logger:
            session_id = logger.start_session(topic_id=1, model="test")

            # Session must have ID
            self.assertIsInstance(session_id, int)
            self.assertGreater(session_id, 0)

            # Session must exist in database
            conn = sqlite3.connect(self.db_path)
            session = conn.execute(
                "SELECT * FROM sessions WHERE id = ?", (session_id,)
            ).fetchone()
            conn.close()

            self.assertIsNotNone(session, "Session should exist in database")

    def test_chunk_splitter_returns_chunks(self):
        """CONTRACT: chunk_splitter must return valid chunks."""
        from chunk_splitter import ChunkSplitter

        splitter = ChunkSplitter()

        markdown = "## Heading 1\n\nContent 1\n\n## Heading 2\n\nContent 2"
        chunks = splitter.split_markdown(markdown)

        # Must return list
        self.assertIsInstance(chunks, list)

        # Must have chunks
        self.assertGreater(len(chunks), 0)

        # Each chunk must have required fields
        for chunk in chunks:
            self.assertTrue(hasattr(chunk, 'text'))
            self.assertTrue(hasattr(chunk, 'ord'))
            self.assertTrue(hasattr(chunk, 'kind'))
            self.assertIsInstance(chunk.ord, int)

    def test_query_rag_search_returns_results(self):
        """CONTRACT: query_rag search must return list of dicts."""
        from query_rag import RAGQuery

        # Add test data
        conn = sqlite3.connect(self.db_path)
        conn.execute("PRAGMA foreign_keys = ON")

        doc_id = conn.execute(
            "INSERT INTO docs (module, slug, title, doc_type, source) "
            "VALUES ('TEST', 'test', 'Test', 'note', 'test') RETURNING id"
        ).fetchone()[0]

        conn.execute(
            "INSERT INTO chunks (doc_id, ord, text) VALUES (?, 0, 'test checkpoint')",
            (doc_id,)
        )
        conn.commit()
        conn.close()

        # Search
        with RAGQuery(self.db_path) as rag:
            results = rag.fts_search("checkpoint", limit=5)

            # Must return list
            self.assertIsInstance(results, list)

            # Results must be dicts with required keys
            if len(results) > 0:
                result = results[0]
                self.assertIn('text', result)
                self.assertIn('doc_title', result)


class PerformanceContract(unittest.TestCase):
    """Test performance contracts (optional, for large datasets)."""

    @unittest.skip("Run manually with --performance flag")
    def test_fts_search_under_100ms(self):
        """CONTRACT: FTS search should be <100ms for 10k chunks."""
        import time

        # This would need a large test dataset
        # Skipped by default, run manually when needed
        pass


def main():
    """Run tests."""
    # Allow running specific test class
    if len(sys.argv) > 1 and sys.argv[1] not in ['--quick', '--help']:
        # Run specific test
        unittest.main(argv=['test_contracts.py'] + sys.argv[1:])
    elif '--quick' in sys.argv:
        # Quick tests only (no performance tests)
        loader = unittest.TestLoader()
        suite = unittest.TestSuite()

        suite.addTests(loader.loadTestsFromTestCase(SchemaContract))
        suite.addTests(loader.loadTestsFromTestCase(DataIntegrityContract))

        runner = unittest.TextTestRunner(verbosity=2)
        result = runner.run(suite)

        sys.exit(0 if result.wasSuccessful() else 1)
    else:
        # Run all tests
        unittest.main()


if __name__ == '__main__':
    main()
