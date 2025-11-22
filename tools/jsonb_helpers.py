#!/usr/bin/env python3
# tools/jsonb_helpers.py
# JSONB query helpers - High-performance metadata queries
#
# Provides Python wrappers for JSONB operations with SQLite 3.51.0+
# - search_by_metadata(): Find docs/sessions/chunks by JSONB field
# - extract_jsonb_field(): Extract single field from JSONB
# - aggregate_jsonb(): Aggregate JSONB fields (AVG, SUM, COUNT)
# - filter_by_jsonb_array(): Filter rows by JSONB array membership
#
# Author: Claude (AI System Architect)
# Date: 2025-11-22
# Version: 1.0.0

import sqlite3
from typing import Any, Dict, List, Optional, Tuple, Union
import json


class JSONBQueryHelper:
    """
    High-performance JSONB query helpers for RAG system.

    Uses JSONB binary format (2-3x faster than TEXT JSON).
    All queries use partial indexes for optimal performance.

    Usage:
        db = sqlite3.connect('sqlite_knowledge.db')
        helper = JSONBQueryHelper(db)

        # Search by metadata field
        results = helper.search_docs_by_metadata('author', 'Claude')

        # Aggregate telemetry
        stats = helper.aggregate_session_telemetry('total_tokens', 'AVG')
    """

    def __init__(self, conn: sqlite3.Connection):
        """Initialize with SQLite connection."""
        self.conn = conn
        self.conn.row_factory = sqlite3.Row

    # ==========================================================================
    # SEARCH BY METADATA (uses JSONB partial indexes)
    # ==========================================================================

    def search_docs_by_metadata(
        self,
        key: str,
        value: Any,
        module: Optional[str] = None
    ) -> List[Dict[str, Any]]:
        """
        Search docs by JSONB metadata field.

        Uses idx_docs_metadata_jsonb partial index.

        Args:
            key: JSON key (e.g., 'author', 'priority', 'tags[0]')
            value: Value to match
            module: Optional module filter

        Returns:
            List of matching docs with metadata

        Example:
            # Find all docs by author
            docs = helper.search_docs_by_metadata('author', 'Claude')

            # Find high-priority docs in specific module
            docs = helper.search_docs_by_metadata(
                'priority',
                10,
                module='ai-core'
            )
        """
        sql = """
            SELECT
                id,
                module,
                slug,
                title,
                doc_type,
                json(metadata_jsonb) AS metadata
            FROM docs
            WHERE metadata_jsonb IS NOT NULL
              AND jsonb_extract(metadata_jsonb, ?) = ?
        """
        params: List[Any] = [f'$.{key}', value]

        if module:
            sql += " AND module = ?"
            params.append(module)

        sql += " ORDER BY created_at DESC"

        cursor = self.conn.execute(sql, params)
        return [dict(row) for row in cursor.fetchall()]

    def search_sessions_by_telemetry(
        self,
        key: str,
        operator: str,
        value: Any
    ) -> List[Dict[str, Any]]:
        """
        Search sessions by JSONB telemetry field with operator.

        Uses idx_sessions_telemetry_jsonb partial index.

        Args:
            key: Telemetry key (e.g., 'total_tokens', 'user_satisfaction')
            operator: SQL operator ('>', '<', '>=', '<=', '=', '!=')
            value: Value to compare

        Returns:
            List of matching sessions with telemetry

        Example:
            # Find sessions with >10k tokens
            sessions = helper.search_sessions_by_telemetry(
                'total_tokens', '>', 10000
            )

            # Find highly satisfied sessions
            sessions = helper.search_sessions_by_telemetry(
                'user_satisfaction', '>=', 8
            )
        """
        allowed_operators = {'>', '<', '>=', '<=', '=', '!='}
        if operator not in allowed_operators:
            raise ValueError(f"Invalid operator: {operator}")

        sql = f"""
            SELECT
                id,
                topic_id,
                model,
                started_at,
                finished_at,
                jsonb_extract(telemetry_jsonb, ?) AS telemetry_field,
                json(telemetry_jsonb) AS telemetry
            FROM sessions
            WHERE telemetry_jsonb IS NOT NULL
              AND jsonb_extract(telemetry_jsonb, ?) {operator} ?
            ORDER BY started_at DESC
        """

        cursor = self.conn.execute(sql, [f'$.{key}', f'$.{key}', value])
        return [dict(row) for row in cursor.fetchall()]

    def search_chunks_by_metadata(
        self,
        key: str,
        value: Any,
        kind: Optional[str] = None
    ) -> List[Dict[str, Any]]:
        """
        Search chunks by JSONB metadata field.

        Uses idx_chunks_metadata_jsonb partial index.

        Args:
            key: Metadata key (e.g., 'source_file', 'language')
            value: Value to match
            kind: Optional kind filter ('doc', 'ai', 'code', etc.)

        Returns:
            List of matching chunks with doc info

        Example:
            # Find chunks from specific source file
            chunks = helper.search_chunks_by_metadata(
                'source_file', 'pragma.md'
            )

            # Find code chunks in Python
            chunks = helper.search_chunks_by_metadata(
                'language', 'python', kind='code'
            )
        """
        sql = """
            SELECT
                c.id,
                c.doc_id,
                c.heading,
                c.text,
                c.kind,
                d.title AS doc_title,
                d.module,
                json(c.metadata_jsonb) AS metadata
            FROM chunks c
            JOIN docs d ON d.id = c.doc_id
            WHERE c.metadata_jsonb IS NOT NULL
              AND jsonb_extract(c.metadata_jsonb, ?) = ?
        """
        params: List[Any] = [f'$.{key}', value]

        if kind:
            sql += " AND c.kind = ?"
            params.append(kind)

        sql += " ORDER BY c.doc_id, c.ord"

        cursor = self.conn.execute(sql, params)
        return [dict(row) for row in cursor.fetchall()]

    # ==========================================================================
    # EXTRACT JSONB FIELDS
    # ==========================================================================

    def extract_session_field(
        self,
        session_id: int,
        key: str
    ) -> Optional[Any]:
        """
        Extract single field from session telemetry JSONB.

        Args:
            session_id: Session ID
            key: Telemetry key path (e.g., 'total_tokens', 'tools[0].name')

        Returns:
            Extracted value or None

        Example:
            tokens = helper.extract_session_field(1, 'total_tokens')
            # Returns: 15234
        """
        cursor = self.conn.execute(
            """
            SELECT jsonb_extract(telemetry_jsonb, ?) AS field
            FROM sessions
            WHERE id = ? AND telemetry_jsonb IS NOT NULL
            """,
            [f'$.{key}', session_id]
        )
        row = cursor.fetchone()
        return row['field'] if row else None

    def extract_doc_field(
        self,
        doc_id: int,
        key: str
    ) -> Optional[Any]:
        """
        Extract single field from doc metadata JSONB.

        Args:
            doc_id: Doc ID
            key: Metadata key path (e.g., 'author', 'tags[0]')

        Returns:
            Extracted value or None
        """
        cursor = self.conn.execute(
            """
            SELECT jsonb_extract(metadata_jsonb, ?) AS field
            FROM docs
            WHERE id = ? AND metadata_jsonb IS NOT NULL
            """,
            [f'$.{key}', doc_id]
        )
        row = cursor.fetchone()
        return row['field'] if row else None

    # ==========================================================================
    # AGGREGATIONS (uses JSONB for 2-3x speedup)
    # ==========================================================================

    def aggregate_session_telemetry(
        self,
        key: str,
        agg_func: str = 'AVG',
        group_by: Optional[str] = None
    ) -> Union[float, List[Dict[str, Any]]]:
        """
        Aggregate telemetry field across sessions.

        Uses idx_sessions_telemetry_jsonb + idx_sessions_model.

        Args:
            key: Telemetry key (e.g., 'total_tokens')
            agg_func: Aggregation function ('AVG', 'SUM', 'COUNT', 'MIN', 'MAX')
            group_by: Optional grouping column ('model', 'topic_id')

        Returns:
            Single value if no group_by, else list of dicts

        Example:
            # Average tokens across all sessions
            avg = helper.aggregate_session_telemetry('total_tokens', 'AVG')
            # Returns: 8432.5

            # Average tokens per model
            stats = helper.aggregate_session_telemetry(
                'total_tokens', 'AVG', group_by='model'
            )
            # Returns: [
            #   {'model': 'gpt-4', 'avg_total_tokens': 12340},
            #   {'model': 'claude-3', 'avg_total_tokens': 8765}
            # ]
        """
        allowed_funcs = {'AVG', 'SUM', 'COUNT', 'MIN', 'MAX'}
        if agg_func.upper() not in allowed_funcs:
            raise ValueError(f"Invalid aggregation: {agg_func}")

        if group_by:
            sql = f"""
                SELECT
                    {group_by},
                    {agg_func.upper()}(jsonb_extract(telemetry_jsonb, ?)) AS {agg_func.lower()}_{key}
                FROM sessions
                WHERE telemetry_jsonb IS NOT NULL
                  AND {group_by} IS NOT NULL
                GROUP BY {group_by}
                ORDER BY {agg_func.lower()}_{key} DESC
            """
            cursor = self.conn.execute(sql, [f'$.{key}'])
            return [dict(row) for row in cursor.fetchall()]
        else:
            sql = f"""
                SELECT {agg_func.upper()}(jsonb_extract(telemetry_jsonb, ?)) AS result
                FROM sessions
                WHERE telemetry_jsonb IS NOT NULL
            """
            cursor = self.conn.execute(sql, [f'$.{key}'])
            row = cursor.fetchone()
            return row['result'] if row else 0.0

    # ==========================================================================
    # ARRAY QUERIES (jsonb_each)
    # ==========================================================================

    def filter_by_jsonb_array(
        self,
        table: str,
        array_path: str,
        array_value: str
    ) -> List[Dict[str, Any]]:
        """
        Filter rows where JSONB array contains a value.

        Uses jsonb_each() to iterate array elements.

        Args:
            table: Table name ('docs', 'sessions', 'chunks', 'messages')
            array_path: JSON array path (e.g., 'tags', 'tool_calls')
            array_value: Value to search in array

        Returns:
            List of matching rows

        Example:
            # Find docs with tag "AI"
            docs = helper.filter_by_jsonb_array('docs', 'tags', 'AI')

            # Find sessions using specific tool
            sessions = helper.filter_by_jsonb_array(
                'sessions', 'tool_calls', 'WebSearch'
            )
        """
        jsonb_col = 'telemetry_jsonb' if table == 'sessions' else 'metadata_jsonb'

        sql = f"""
            SELECT DISTINCT
                t.id,
                json(t.{jsonb_col}) AS metadata
            FROM {table} t,
                 jsonb_each(jsonb_extract(t.{jsonb_col}, ?)) arr
            WHERE t.{jsonb_col} IS NOT NULL
              AND arr.value = ?
        """

        cursor = self.conn.execute(sql, [f'$.{array_path}', array_value])
        return [dict(row) for row in cursor.fetchall()]

    # ==========================================================================
    # ACTIVE SESSIONS (uses idx_sessions_active partial index)
    # ==========================================================================

    def get_active_sessions(self) -> List[Dict[str, Any]]:
        """
        Get all active sessions (finished_at IS NULL).

        Uses idx_sessions_active partial index.

        Returns:
            List of active sessions with telemetry

        Example:
            sessions = helper.get_active_sessions()
            # Returns: [
            #   {'id': 42, 'model': 'gpt-4', 'started_at': '...', ...}
            # ]
        """
        sql = """
            SELECT
                id,
                topic_id,
                model,
                started_at,
                jsonb_extract(telemetry_jsonb, '$.total_tokens') AS tokens,
                json(telemetry_jsonb) AS telemetry
            FROM sessions
            WHERE finished_at IS NULL
            ORDER BY started_at DESC
        """
        cursor = self.conn.execute(sql)
        return [dict(row) for row in cursor.fetchall()]

    # ==========================================================================
    # VALIDATION
    # ==========================================================================

    def validate_json(self, json_text: str) -> Tuple[bool, Optional[str]]:
        """
        Validate JSON string before INSERT.

        Args:
            json_text: JSON string to validate

        Returns:
            (is_valid, error_message)

        Example:
            valid, error = helper.validate_json('{"key": "value"}')
            if not valid:
                print(f"Invalid JSON: {error}")
        """
        try:
            json.loads(json_text)
            return (True, None)
        except json.JSONDecodeError as e:
            return (False, str(e))


# ==============================================================================
# CLI USAGE EXAMPLES
# ==============================================================================

def main():
    """Example usage of JSONB query helpers."""
    import sys

    if len(sys.argv) < 2:
        print("Usage: python jsonb_helpers.py <db_path>")
        print("\nExamples:")
        print("  python jsonb_helpers.py sqlite_knowledge.db")
        sys.exit(1)

    db_path = sys.argv[1]
    conn = sqlite3.connect(db_path)
    helper = JSONBQueryHelper(conn)

    print("=== JSONB Query Helper Demo ===\n")

    # Example 1: Active sessions
    print("1. Active sessions:")
    active = helper.get_active_sessions()
    print(f"   Found {len(active)} active sessions")
    for s in active[:3]:
        print(f"   - Session {s['id']}: {s['model']} ({s['tokens']} tokens)")
    print()

    # Example 2: Aggregate telemetry by model
    print("2. Average tokens per model:")
    stats = helper.aggregate_session_telemetry('total_tokens', 'AVG', group_by='model')
    for stat in stats[:5]:
        print(f"   - {stat['model']}: {stat['avg_total_tokens']:.0f} tokens")
    print()

    # Example 3: Search docs by metadata
    print("3. Search docs by author:")
    docs = helper.search_docs_by_metadata('author', 'Claude')
    print(f"   Found {len(docs)} docs by Claude")
    for doc in docs[:3]:
        print(f"   - {doc['module']}/{doc['slug']}: {doc['title']}")
    print()

    conn.close()


if __name__ == '__main__':
    main()
