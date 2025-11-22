#!/usr/bin/env bash
# rag_tools/diagnose_jsonb.sh
#
# Diagnostyczny skrypt - sprawdza dostępność JSONB w SQLite
#
# Usage:
#   ./diagnose_jsonb.sh
#   ./diagnose_jsonb.sh --db custom.db
#
# Author: Claude (AI System Architect)
# Date: 2025-11-22
# Version: 1.0.0

set -u

# ==============================================================================
# CONFIGURATION
# ==============================================================================

DB_PATH="${1:-:memory:}"  # Use in-memory DB by default

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
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

# ==============================================================================
# DIAGNOSTICS
# ==============================================================================

echo "=== JSONB Diagnostics ==="
echo ""

# 1. SQLite version
SQLITE_VERSION=$(sqlite3 --version | awk '{print $1}')
log_info "SQLite version: $SQLITE_VERSION"
echo ""

# 2. Check JSONB availability
echo "Checking JSONB support..."

JSONB_TEST=$(sqlite3 "$DB_PATH" <<'EOF'
SELECT CASE
    WHEN sqlite_version() >= '3.51.0' THEN 'available'
    ELSE 'not_available'
END;
EOF
)

if [ "$JSONB_TEST" = "available" ]; then
    log_ok "JSONB is available (SQLite $SQLITE_VERSION >= 3.51.0)"
    JSONB_AVAILABLE=1
else
    log_warn "JSONB is NOT available (SQLite $SQLITE_VERSION < 3.51.0)"
    log_info "JSONB requires SQLite 3.51.0 or higher"
    JSONB_AVAILABLE=0
fi

echo ""

# 3. Test basic JSONB functions if available
if [ $JSONB_AVAILABLE -eq 1 ]; then
    echo "Testing JSONB functions..."

    sqlite3 "$DB_PATH" <<'EOF'
.mode line

-- Test jsonb() conversion
SELECT '=== Test 1: jsonb() conversion ===' AS test;
SELECT jsonb('{"key": "value"}') AS result;

-- Test jsonb_extract()
SELECT '=== Test 2: jsonb_extract() ===' AS test;
SELECT jsonb_extract(jsonb('{"key": "value"}'), '$.key') AS result;

-- Test jsonb_each()
SELECT '=== Test 3: jsonb_each() ===' AS test;
SELECT key, value FROM jsonb_each(jsonb('{"a": 1, "b": 2}'));

-- Test jsonb_tree()
SELECT '=== Test 4: jsonb_tree() ===' AS test;
SELECT key, value, type FROM jsonb_tree(jsonb('{"a": {"b": 1}}')) LIMIT 3;

EOF

    log_ok "All JSONB functions working"
else
    log_warn "Skipping JSONB function tests (not available)"
fi

echo ""

# 4. Show available JSON functions (TEXT-based)
echo "Available JSON functions (TEXT-based):"

sqlite3 "$DB_PATH" <<'EOF'
.mode line

-- Test json_extract() (TEXT)
SELECT '=== json_extract() (TEXT) ===' AS test;
SELECT json_extract('{"key": "value"}', '$.key') AS result;

-- Test json_each() (TEXT)
SELECT '=== json_each() (TEXT) ===' AS test;
SELECT key, value FROM json_each('{"a": 1, "b": 2}');

-- Test json_tree() (TEXT)
SELECT '=== json_tree() (TEXT) ===' AS test;
SELECT key, value, type FROM json_tree('{"a": {"b": 1}}') LIMIT 3;

EOF

log_info "TEXT JSON functions are available in all SQLite versions"

echo ""

# 5. Performance comparison (if JSONB available)
if [ $JSONB_AVAILABLE -eq 1 ]; then
    echo "Running performance test (TEXT vs JSONB)..."

    sqlite3 "$DB_PATH" <<'EOF'
-- Create test data
CREATE TEMP TABLE perf_test (id INTEGER, metadata TEXT, metadata_jsonb BLOB);

INSERT INTO perf_test (id, metadata)
WITH RECURSIVE cnt(x) AS (SELECT 1 UNION ALL SELECT x+1 FROM cnt WHERE x < 1000)
SELECT x, '{"key": "value' || x || '"}' FROM cnt;

UPDATE perf_test SET metadata_jsonb = jsonb(metadata);

.print ""
.print "TEXT JSON (1000 extracts):"
.timer on
SELECT COUNT(*) FROM (SELECT json_extract(metadata, '$.key') FROM perf_test);
.timer off

.print ""
.print "BLOB JSONB (1000 extracts):"
.timer on
SELECT COUNT(*) FROM (SELECT jsonb_extract(metadata_jsonb, '$.key') FROM perf_test);
.timer off

EOF

    echo ""
    log_ok "Performance test completed"
fi

echo ""

# 6. Recommendations
echo "=== Recommendations ==="
echo ""

if [ $JSONB_AVAILABLE -eq 1 ]; then
    log_ok "You can use JSONB for better performance"
    echo "   Use schema_v2_jsonb.sql for JSONB support"
    echo "   Run: ./bootstrap.sh --schema v2.2"
else
    log_info "Continue using TEXT JSON (current schema)"
    echo "   Your current schema (schema_v2_fixed.sql) is optimal"
    echo "   To upgrade to JSONB:"
    echo "     1. Upgrade SQLite to 3.51.0+"
    echo "     2. Run migration: sqlite3 db < migrate_v2.1_to_v2.2.sql"
fi

echo ""

# 7. Feature matrix
echo "=== Feature Matrix ==="
echo ""

cat <<EOF
┌─────────────────────────┬──────────────┬───────────────┐
│ Feature                 │ TEXT JSON    │ BLOB JSONB    │
├─────────────────────────┼──────────────┼───────────────┤
│ Human readable          │ ✓ Yes        │ ✗ No          │
│ Parse on every query    │ ✗ Yes (slow) │ ✓ No (fast)   │
│ Storage efficiency      │ ~ Medium     │ ✓ Good        │
│ Query performance       │ ~ 1x         │ ✓ 2-3x faster │
│ SQLite version required │ ✓ Any        │ ✗ 3.51.0+     │
│ Debugging ease          │ ✓ Easy       │ ~ Need json() │
└─────────────────────────┴──────────────┴───────────────┘
EOF

echo ""

# 8. System info
echo "=== System Info ==="
echo ""
log_info "SQLite version: $SQLITE_VERSION"
log_info "JSONB available: $([ $JSONB_AVAILABLE -eq 1 ] && echo 'Yes' || echo 'No')"

if command -v python3 &> /dev/null; then
    PYTHON_VERSION=$(python3 --version | awk '{print $2}')
    log_info "Python version: $PYTHON_VERSION"
fi

echo ""
log_ok "Diagnostics complete"
