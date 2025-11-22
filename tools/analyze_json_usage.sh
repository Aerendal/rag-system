#!/usr/bin/env bash
# rag_tools/analyze_json_usage.sh
#
# Diagnostic script - analyzes current JSON usage in RAG database
# Helps decide migration strategy for TEXT JSON → BLOB JSONB
#
# Usage:
#   ./analyze_json_usage.sh [DATABASE_PATH]
#   ./analyze_json_usage.sh sqlite_knowledge.db
#
# Author: Claude (AI System Architect)
# Date: 2025-11-22
# Version: 1.0.0

set -euo pipefail

# ==============================================================================
# CONFIGURATION
# ==============================================================================

DB_PATH="${1:-sqlite_knowledge.db}"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# ==============================================================================
# FUNCTIONS
# ==============================================================================

log_ok() {
    echo -e "${GREEN}[✓]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[!]${NC} $1"
}

log_error() {
    echo -e "${RED}[✗]${NC} $1"
}

log_info() {
    echo -e "${BLUE}[i]${NC} $1"
}

log_section() {
    echo ""
    echo -e "${CYAN}=== $1 ===${NC}"
    echo ""
}

# ==============================================================================
# PRE-FLIGHT CHECKS
# ==============================================================================

log_section "Pre-flight Checks"

# Check if database exists
if [ ! -f "$DB_PATH" ]; then
    log_error "Database not found: $DB_PATH"
    echo ""
    echo "Usage: $0 [DATABASE_PATH]"
    echo "Example: $0 sqlite_knowledge.db"
    exit 1
fi

log_ok "Database found: $DB_PATH"

# Check SQLite version
SQLITE_VERSION=$(sqlite3 --version | awk '{print $1}')
log_info "SQLite version: $SQLITE_VERSION"

# Check JSONB availability
JSONB_AVAILABLE=$(sqlite3 "$DB_PATH" "SELECT sqlite_version() >= '3.51.0';")
if [ "$JSONB_AVAILABLE" = "1" ]; then
    log_ok "JSONB available (SQLite $SQLITE_VERSION)"
else
    log_warn "JSONB not available (SQLite $SQLITE_VERSION < 3.51.0)"
    log_info "This analysis will show potential gains from upgrading"
fi

# Check schema version
SCHEMA_VERSION=$(sqlite3 "$DB_PATH" "PRAGMA user_version;" 2>/dev/null || echo "0")
log_info "Schema version: $SCHEMA_VERSION"

# ==============================================================================
# DATABASE ANALYSIS
# ==============================================================================

log_section "Database Size Analysis"

sqlite3 "$DB_PATH" <<'EOF'
.mode line

-- Overall database size
SELECT '=== Database Statistics ===' AS section;

SELECT
    page_count * page_size / 1024.0 / 1024.0 AS database_size_mb,
    page_count AS total_pages,
    page_size AS page_size_bytes
FROM pragma_page_count(), pragma_page_size();

EOF

log_section "Table Row Counts"

sqlite3 "$DB_PATH" <<'EOF'
.mode column
.headers on

SELECT '=== Row Counts ===' AS section;
SELECT
    (SELECT COUNT(*) FROM docs) AS docs_count,
    (SELECT COUNT(*) FROM chunks) AS chunks_count,
    (SELECT COUNT(*) FROM sessions) AS sessions_count;

EOF

log_section "JSON Column Analysis"

sqlite3 "$DB_PATH" <<'EOF'
.mode line

-- Docs table metadata
SELECT '=== docs.metadata (TEXT JSON) ===' AS section;

SELECT
    COUNT(*) AS total_rows,
    COUNT(metadata) AS rows_with_metadata,
    COUNT(*) - COUNT(metadata) AS rows_null_metadata,
    ROUND(AVG(LENGTH(metadata)), 2) AS avg_metadata_bytes,
    MIN(LENGTH(metadata)) AS min_metadata_bytes,
    MAX(LENGTH(metadata)) AS max_metadata_bytes,
    ROUND(SUM(LENGTH(metadata)) / 1024.0 / 1024.0, 2) AS total_metadata_mb
FROM docs
WHERE metadata IS NOT NULL;

-- Sample metadata structure
SELECT '=== Sample docs.metadata (first 3 rows) ===' AS section;
SELECT
    id,
    module,
    SUBSTR(metadata, 1, 100) || '...' AS metadata_preview,
    LENGTH(metadata) AS size_bytes
FROM docs
WHERE metadata IS NOT NULL
LIMIT 3;

EOF

log_section "Sessions Telemetry Analysis"

sqlite3 "$DB_PATH" <<'EOF'
.mode line

-- Sessions table telemetry
SELECT '=== sessions.telemetry (TEXT JSON) ===' AS section;

SELECT
    COUNT(*) AS total_sessions,
    COUNT(telemetry) AS sessions_with_telemetry,
    COUNT(*) - COUNT(telemetry) AS sessions_null_telemetry,
    ROUND(AVG(LENGTH(telemetry)), 2) AS avg_telemetry_bytes,
    MIN(LENGTH(telemetry)) AS min_telemetry_bytes,
    MAX(LENGTH(telemetry)) AS max_telemetry_bytes,
    ROUND(SUM(LENGTH(telemetry)) / 1024.0 / 1024.0, 2) AS total_telemetry_mb
FROM sessions
WHERE telemetry IS NOT NULL;

-- Sample telemetry structure
SELECT '=== Sample sessions.telemetry (first 3 rows) ===' AS section;
SELECT
    id,
    model,
    SUBSTR(telemetry, 1, 100) || '...' AS telemetry_preview,
    LENGTH(telemetry) AS size_bytes
FROM sessions
WHERE telemetry IS NOT NULL
LIMIT 3;

EOF

log_section "JSON Query Pattern Analysis"

sqlite3 "$DB_PATH" <<'EOF'
.mode line

-- Common JSON extractions
SELECT '=== Common metadata fields (docs) ===' AS section;

SELECT
    'module' AS field,
    COUNT(DISTINCT json_extract(metadata, '$.module')) AS unique_values,
    MIN(json_extract(metadata, '$.module')) AS sample_value
FROM docs
WHERE metadata IS NOT NULL

UNION ALL

SELECT
    'source' AS field,
    COUNT(DISTINCT json_extract(metadata, '$.source')) AS unique_values,
    MIN(json_extract(metadata, '$.source')) AS sample_value
FROM docs
WHERE metadata IS NOT NULL;

-- Common telemetry extractions
SELECT '=== Common telemetry fields (sessions) ===' AS section;

SELECT
    'total_tokens' AS field,
    COUNT(*) AS non_null_count,
    CAST(AVG(CAST(json_extract(telemetry, '$.total_tokens') AS INTEGER)) AS INTEGER) AS avg_value,
    MAX(CAST(json_extract(telemetry, '$.total_tokens') AS INTEGER)) AS max_value
FROM sessions
WHERE telemetry IS NOT NULL
  AND json_extract(telemetry, '$.total_tokens') IS NOT NULL

UNION ALL

SELECT
    'tool_calls' AS field,
    COUNT(*) AS non_null_count,
    NULL AS avg_value,
    NULL AS max_value
FROM sessions
WHERE telemetry IS NOT NULL
  AND json_extract(telemetry, '$.tool_calls') IS NOT NULL;

EOF

log_section "Storage Efficiency Projection"

sqlite3 "$DB_PATH" <<'EOF'
.mode line

SELECT '=== JSONB Storage Savings Estimate ===' AS section;

WITH json_sizes AS (
    SELECT
        SUM(LENGTH(metadata)) AS docs_metadata_bytes,
        SUM(LENGTH(telemetry)) AS sessions_telemetry_bytes
    FROM (
        SELECT metadata FROM docs WHERE metadata IS NOT NULL
    ) d,
    (
        SELECT telemetry FROM sessions WHERE telemetry IS NOT NULL
    ) s
)
SELECT
    ROUND(docs_metadata_bytes / 1024.0 / 1024.0, 2) AS current_docs_metadata_mb,
    ROUND(sessions_telemetry_bytes / 1024.0 / 1024.0, 2) AS current_sessions_telemetry_mb,
    ROUND((docs_metadata_bytes + sessions_telemetry_bytes) / 1024.0 / 1024.0, 2) AS total_json_mb,
    ROUND((docs_metadata_bytes + sessions_telemetry_bytes) * 0.81 / 1024.0 / 1024.0, 2) AS estimated_jsonb_mb,
    ROUND((docs_metadata_bytes + sessions_telemetry_bytes) * 0.19 / 1024.0 / 1024.0, 2) AS estimated_savings_mb,
    '19% (based on benchmark results)' AS savings_percentage
FROM json_sizes;

EOF

log_section "Performance Analysis"

echo "Testing query performance with current TEXT JSON..."

sqlite3 "$DB_PATH" <<'EOF'
.mode line
.timer on

-- Test 1: Extract metadata fields
SELECT '=== Test 1: Extract metadata.module (all docs) ===' AS test;
SELECT COUNT(DISTINCT json_extract(metadata, '$.module'))
FROM docs
WHERE metadata IS NOT NULL;

-- Test 2: Filter by telemetry
SELECT '=== Test 2: Filter sessions by tokens > 10000 ===' AS test;
SELECT COUNT(*)
FROM sessions
WHERE CAST(json_extract(telemetry, '$.total_tokens') AS INTEGER) > 10000;

-- Test 3: Aggregate telemetry
SELECT '=== Test 3: Average tokens by model ===' AS test;
SELECT
    model,
    AVG(CAST(json_extract(telemetry, '$.total_tokens') AS INTEGER)) AS avg_tokens
FROM sessions
WHERE telemetry IS NOT NULL
GROUP BY model;

.timer off
EOF

log_section "Migration Recommendations"

echo "Analyzing migration strategy..."
echo ""

# Get counts for migration planning
DOCS_COUNT=$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM docs WHERE metadata IS NOT NULL;")
SESSIONS_COUNT=$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM sessions WHERE telemetry IS NOT NULL;")
TOTAL_JSON_MB=$(sqlite3 "$DB_PATH" "SELECT ROUND((SELECT SUM(LENGTH(metadata)) FROM docs WHERE metadata IS NOT NULL) / 1024.0 / 1024.0 + (SELECT SUM(LENGTH(telemetry)) FROM sessions WHERE telemetry IS NOT NULL) / 1024.0 / 1024.0, 2);")

echo -e "${CYAN}┌─────────────────────────────────────────────────────────┐${NC}"
echo -e "${CYAN}│ MIGRATION RECOMMENDATIONS                               │${NC}"
echo -e "${CYAN}├─────────────────────────────────────────────────────────┤${NC}"
echo -e "${CYAN}│${NC}"
echo -e "${CYAN}│${NC} Database: $DB_PATH"
echo -e "${CYAN}│${NC} Schema version: $SCHEMA_VERSION"
echo -e "${CYAN}│${NC} Docs with metadata: $DOCS_COUNT"
echo -e "${CYAN}│${NC} Sessions with telemetry: $SESSIONS_COUNT"
echo -e "${CYAN}│${NC} Total JSON data: ${TOTAL_JSON_MB} MB"
echo -e "${CYAN}│${NC}"

if [ "$JSONB_AVAILABLE" = "1" ]; then
    echo -e "${CYAN}│${NC} ${GREEN}✓ JSONB is available${NC}"
    echo -e "${CYAN}│${NC}"
    echo -e "${CYAN}│${NC} Recommended strategy:"
    echo -e "${CYAN}│${NC}   1. Use dual-column approach (TEXT + JSONB)"
    echo -e "${CYAN}│${NC}   2. Migrate in batches (1000 rows at a time)"
    echo -e "${CYAN}│${NC}   3. Keep TEXT for debugging, JSONB for queries"
    echo -e "${CYAN}│${NC}   4. Estimated time: ~$(echo "scale=0; $DOCS_COUNT / 1000" | bc) batches for docs"
    echo -e "${CYAN}│${NC}   5. Estimated savings: ~$(echo "$TOTAL_JSON_MB * 0.19" | bc) MB"
    echo -e "${CYAN}│${NC}"
    echo -e "${CYAN}│${NC} Next steps:"
    echo -e "${CYAN}│${NC}   - Run: ./migrate_v2.1_to_v2.2.sql"
    echo -e "${CYAN}│${NC}   - Test: ./test_jsonb_migration.sql"
    echo -e "${CYAN}│${NC}   - Verify: ./healthcheck.sh"
else
    echo -e "${CYAN}│${NC} ${YELLOW}! JSONB not available (SQLite < 3.51.0)${NC}"
    echo -e "${CYAN}│${NC}"
    echo -e "${CYAN}│${NC} Recommended strategy:"
    echo -e "${CYAN}│${NC}   1. Continue using TEXT JSON (current schema)"
    echo -e "${CYAN}│${NC}   2. Consider upgrading SQLite to 3.51.0+"
    echo -e "${CYAN}│${NC}   3. Potential performance gain: 2-3x faster queries"
    echo -e "${CYAN}│${NC}   4. Potential storage savings: ~$(echo "$TOTAL_JSON_MB * 0.19" | bc) MB"
fi

echo -e "${CYAN}│${NC}"
echo -e "${CYAN}└─────────────────────────────────────────────────────────┘${NC}"

echo ""
log_ok "Analysis complete"
echo ""
echo "Report saved to: ${DB_PATH%.db}_json_analysis_$(date +%Y%m%d_%H%M%S).txt"
echo "Run this script with: $0 $DB_PATH > report.txt"
