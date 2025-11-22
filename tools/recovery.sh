#!/usr/bin/env bash
# rag_tools/recovery.sh
#
# Recovery script - naprawiaj bazę kiedy się sypie
#
# Philosophy:
# - Auto-repair SAFE issues (FTS rebuild, checkpoints)
# - ASK before DESTRUCTIVE operations (delete data, recreate schema)
# - ALWAYS backup before changes
# - Support manual overrides (--force, --yes)
#
# Usage:
#   ./recovery.sh                       # Interactive repair
#   ./recovery.sh --auto                # Auto-fix safe issues
#   ./recovery.sh --rebuild-fts         # Specific fix
#   ./recovery.sh --check-integrity     # SQLite integrity check
#   ./recovery.sh --yes                 # No confirmation prompts
#
# Author: Claude (AI System Architect)
# Version: 1.0.0

set -u

# ==============================================================================
# CONFIGURATION
# ==============================================================================

DB_PATH="${DB_PATH:-sqlite_knowledge.db}"
AUTO_MODE=0
YES_MODE=0
BACKUP_CREATED=0

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# ==============================================================================
# HELPERS
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

confirm() {
    if [ $YES_MODE -eq 1 ]; then
        return 0
    fi

    echo -ne "${YELLOW}$1 (y/N):${NC} "
    read -r response
    [[ "$response" =~ ^[Yy]$ ]]
}

create_backup() {
    if [ $BACKUP_CREATED -eq 1 ]; then
        return 0
    fi

    local backup_path="${DB_PATH}.backup.$(date +%Y%m%d_%H%M%S)"
    log_warn "Creating backup: $backup_path"

    if cp "$DB_PATH" "$backup_path" 2>/dev/null; then
        # Backup WAL and SHM if they exist
        [ -f "$DB_PATH-wal" ] && cp "$DB_PATH-wal" "$backup_path-wal" 2>/dev/null
        [ -f "$DB_PATH-shm" ] && cp "$DB_PATH-shm" "$backup_path-shm" 2>/dev/null
        log_ok "Backup created"
        BACKUP_CREATED=1
    else
        log_error "Backup failed!"
        return 1
    fi
}

# ==============================================================================
# RECOVERY OPERATIONS
# ==============================================================================

check_integrity() {
    log_warn "Running SQLite integrity check..."

    local result=$(sqlite3 "$DB_PATH" "PRAGMA integrity_check;" 2>&1)

    if [ "$result" = "ok" ]; then
        log_ok "Database integrity OK"
        return 0
    else
        log_error "Integrity check failed:"
        echo "$result"
        return 1
    fi
}

rebuild_fts() {
    log_warn "Rebuilding FTS5 index..."

    create_backup || return 1

    if confirm "Rebuild chunks_fts index?"; then
        # Rebuild using FTS5 special command
        if sqlite3 "$DB_PATH" "INSERT INTO chunks_fts(chunks_fts) VALUES('rebuild');" 2>&1; then
            log_ok "FTS5 index rebuilt"

            # Verify sync
            local chunks=$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM chunks;")
            local fts=$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM chunks_fts;")

            if [ "$chunks" -eq "$fts" ]; then
                log_ok "FTS5 now in sync ($chunks chunks)"
            else
                log_warn "FTS5 still out of sync: chunks=$chunks, fts=$fts"
            fi
        else
            log_error "FTS5 rebuild failed"
            return 1
        fi
    fi
}

optimize_fts() {
    log_warn "Optimizing FTS5 index..."

    if sqlite3 "$DB_PATH" "INSERT INTO chunks_fts(chunks_fts) VALUES('optimize');" 2>&1; then
        log_ok "FTS5 optimized"
    else
        log_warn "FTS5 optimization failed (non-critical)"
    fi
}

checkpoint_wal() {
    log_warn "Checkpointing WAL..."

    if sqlite3 "$DB_PATH" "PRAGMA wal_checkpoint(TRUNCATE);" > /dev/null 2>&1; then
        log_ok "WAL checkpointed"

        # Check if WAL file is gone/small
        if [ -f "$DB_PATH-wal" ]; then
            local wal_size=$(stat -f%z "$DB_PATH-wal" 2>/dev/null || stat -c%s "$DB_PATH-wal" 2>/dev/null)
            if [ $wal_size -lt 10000 ]; then
                log_ok "WAL file truncated"
            fi
        fi
    else
        log_error "WAL checkpoint failed"
        return 1
    fi
}

vacuum_database() {
    log_warn "Vacuuming database (reclaim space)..."

    if confirm "Run VACUUM? (may take time for large databases)"; then
        create_backup || return 1

        local size_before=$(stat -f%z "$DB_PATH" 2>/dev/null || stat -c%s "$DB_PATH" 2>/dev/null)

        if sqlite3 "$DB_PATH" "VACUUM;" 2>&1; then
            local size_after=$(stat -f%z "$DB_PATH" 2>/dev/null || stat -c%s "$DB_PATH" 2>/dev/null)
            local saved=$((size_before - size_after))
            local saved_mb=$((saved / 1024 / 1024))

            log_ok "VACUUM complete (saved ${saved_mb}MB)"
        else
            log_error "VACUUM failed"
            return 1
        fi
    fi
}

fix_fk_violations() {
    log_warn "Checking foreign key violations..."

    local violations=$(sqlite3 "$DB_PATH" "PRAGMA foreign_key_check;")

    if [ -z "$violations" ]; then
        log_ok "No FK violations"
        return 0
    fi

    log_error "FK violations found:"
    echo "$violations"

    if confirm "Attempt auto-fix (delete orphaned rows)?"; then
        create_backup || return 1

        # This is a simplified fix - real implementation would need to parse violations
        log_warn "Manual FK fix required - automatic fix not yet implemented"
        log_warn "Backup created. Please fix manually or recreate database."
        return 1
    fi
}

analyze_database() {
    log_warn "Analyzing database (update statistics)..."

    if sqlite3 "$DB_PATH" "ANALYZE;" 2>&1; then
        log_ok "ANALYZE complete (query planner updated)"
    else
        log_warn "ANALYZE failed (non-critical)"
    fi
}

# ==============================================================================
# AUTO REPAIR
# ==============================================================================

auto_repair() {
    log_warn "Running automatic repairs (safe operations only)..."

    # Safe operations that can run automatically
    checkpoint_wal
    optimize_fts
    analyze_database

    # Check if FTS is out of sync
    local chunks=$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM chunks;" 2>/dev/null || echo "0")
    local fts=$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM chunks_fts;" 2>/dev/null || echo "0")

    if [ "$chunks" -ne "$fts" ]; then
        log_warn "FTS out of sync detected"
        if [ $YES_MODE -eq 1 ]; then
            rebuild_fts
        else
            log_warn "Run with --rebuild-fts to fix"
        fi
    fi

    log_ok "Auto-repair complete"
}

# ==============================================================================
# MAIN
# ==============================================================================

main() {
    # Parse arguments
    local specific_action=""

    while [[ $# -gt 0 ]]; do
        case $1 in
            --auto)
                AUTO_MODE=1
                shift
                ;;
            --yes)
                YES_MODE=1
                shift
                ;;
            --check-integrity)
                specific_action="integrity"
                shift
                ;;
            --rebuild-fts)
                specific_action="rebuild_fts"
                shift
                ;;
            --checkpoint)
                specific_action="checkpoint"
                shift
                ;;
            --vacuum)
                specific_action="vacuum"
                shift
                ;;
            --fix-fk)
                specific_action="fix_fk"
                shift
                ;;
            --db)
                DB_PATH="$2"
                shift 2
                ;;
            --help)
                echo "Usage: $0 [OPTIONS]"
                echo ""
                echo "Options:"
                echo "  --auto              Auto-fix safe issues"
                echo "  --yes               No confirmation prompts"
                echo "  --check-integrity   Run SQLite integrity check"
                echo "  --rebuild-fts       Rebuild FTS5 index"
                echo "  --checkpoint        Checkpoint WAL"
                echo "  --vacuum            Vacuum database"
                echo "  --fix-fk            Fix foreign key violations"
                echo "  --db PATH           Database path"
                echo "  --help              Show this help"
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                exit 1
                ;;
        esac
    done

    echo "=== RAG System Recovery ==="
    echo "Database: $DB_PATH"
    echo ""

    # Check database exists
    if [ ! -f "$DB_PATH" ]; then
        log_error "Database not found: $DB_PATH"
        exit 1
    fi

    # Specific action
    if [ -n "$specific_action" ]; then
        case $specific_action in
            integrity)
                check_integrity
                ;;
            rebuild_fts)
                rebuild_fts
                ;;
            checkpoint)
                checkpoint_wal
                ;;
            vacuum)
                vacuum_database
                ;;
            fix_fk)
                fix_fk_violations
                ;;
        esac
        exit 0
    fi

    # Auto mode
    if [ $AUTO_MODE -eq 1 ]; then
        auto_repair
        exit 0
    fi

    # Interactive mode
    echo "Select recovery operation:"
    echo "  1) Check integrity"
    echo "  2) Rebuild FTS5 index"
    echo "  3) Checkpoint WAL"
    echo "  4) Vacuum database"
    echo "  5) Fix FK violations"
    echo "  6) Auto-repair (safe operations)"
    echo "  0) Exit"
    echo ""
    echo -n "Choice: "
    read -r choice

    case $choice in
        1) check_integrity ;;
        2) rebuild_fts ;;
        3) checkpoint_wal ;;
        4) vacuum_database ;;
        5) fix_fk_violations ;;
        6) auto_repair ;;
        0) exit 0 ;;
        *) log_error "Invalid choice"; exit 1 ;;
    esac
}

main "$@"
