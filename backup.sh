#!/usr/bin/env bash
# =============================================================================
# backup.sh — Folder & Database Backup Script
# Usage: ./backup.sh [--dry-run]
# =============================================================================

set -euo pipefail

# ─── Configuration ────────────────────────────────────────────────────────────
BACKUP_ROOT="${BACKUP_ROOT:-/var/backups/server}"
RETENTION_DAYS="${RETENTION_DAYS:-7}"
LOG_FILE="${LOG_FILE:-/var/log/backup.log}"
TIMESTAMP=$(date +"%Y-%m-%d_%H-%M-%S")
DRY_RUN=false

# Folders to back up (space-separated)
BACKUP_DIRS=(
    "/etc"
    "/home"
    "/var/www"
)

# MySQL config (leave blank to skip)
MYSQL_ENABLED="${MYSQL_ENABLED:-false}"
MYSQL_USER="${MYSQL_USER:-root}"
MYSQL_PASS="${MYSQL_PASS:-}"
MYSQL_DATABASES="${MYSQL_DATABASES:-}"       # e.g. "mydb1 mydb2" — blank = all

# PostgreSQL config (leave blank to skip)
PSQL_ENABLED="${PSQL_ENABLED:-false}"
PSQL_USER="${PSQL_USER:-postgres}"
PSQL_DATABASES="${PSQL_DATABASES:-}"        # blank = all (pg_dumpall)

# ─── Colors & Helpers ────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

log()  { echo -e "$(date '+%F %T') [$1] $2" | tee -a "$LOG_FILE"; }
info() { log "${GREEN}INFO ${RESET}" "$*"; }
warn() { log "${YELLOW}WARN ${RESET}" "$*"; }
err()  { log "${RED}ERROR${RESET}" "$*"; }
step() { echo -e "\n${CYAN}${BOLD}▶ $*${RESET}"; }

die() { err "$*"; exit 1; }

[[ "$*" == *"--dry-run"* ]] && DRY_RUN=true && warn "DRY RUN — no files will be written."

run() {
    if $DRY_RUN; then echo "  [dry-run] $*"; else eval "$*"; fi
}

# ─── Setup ───────────────────────────────────────────────────────────────────
DEST="${BACKUP_ROOT}/${TIMESTAMP}"
mkdir -p "$DEST" || die "Cannot create backup directory: $DEST"
mkdir -p "$(dirname "$LOG_FILE")"

info "Backup started — destination: $DEST"

# ─── 1. Folder Backups ───────────────────────────────────────────────────────
step "Backing up directories"
for dir in "${BACKUP_DIRS[@]}"; do
    if [[ ! -d "$dir" ]]; then
        warn "Skipping (not found): $dir"
        continue
    fi
    archive_name="${DEST}/$(echo "$dir" | tr '/' '_' | sed 's/^_//').tar.gz"
    info "  $dir → $archive_name"
    run "tar --warning=no-file-changed -czf \"$archive_name\" \"$dir\" 2>/dev/null || true"
done

# ─── 2. MySQL Backup ─────────────────────────────────────────────────────────
if [[ "$MYSQL_ENABLED" == "true" ]]; then
    step "MySQL backup"
    command -v mysqldump &>/dev/null || die "mysqldump not found — install mysql-client."
    MYSQL_DIR="${DEST}/mysql"
    run "mkdir -p '$MYSQL_DIR'"
    PASS_ARG=""
    [[ -n "$MYSQL_PASS" ]] && PASS_ARG="-p'${MYSQL_PASS}'"

    if [[ -z "$MYSQL_DATABASES" ]]; then
        info "  Dumping all MySQL databases"
        run "mysqldump -u '$MYSQL_USER' $PASS_ARG --all-databases --single-transaction \
             | gzip > '${MYSQL_DIR}/all_databases.sql.gz'"
    else
        for db in $MYSQL_DATABASES; do
            info "  Dumping MySQL db: $db"
            run "mysqldump -u '$MYSQL_USER' $PASS_ARG --single-transaction '$db' \
                 | gzip > '${MYSQL_DIR}/${db}.sql.gz'"
        done
    fi
else
    info "MySQL backup skipped (MYSQL_ENABLED != true)"
fi

# ─── 3. PostgreSQL Backup ────────────────────────────────────────────────────
if [[ "$PSQL_ENABLED" == "true" ]]; then
    step "PostgreSQL backup"
    command -v pg_dump &>/dev/null || die "pg_dump not found — install postgresql-client."
    PSQL_DIR="${DEST}/postgresql"
    run "mkdir -p '$PSQL_DIR'"

    if [[ -z "$PSQL_DATABASES" ]]; then
        info "  Dumping all PostgreSQL databases (pg_dumpall)"
        run "sudo -u '$PSQL_USER' pg_dumpall | gzip > '${PSQL_DIR}/all_databases.sql.gz'"
    else
        for db in $PSQL_DATABASES; do
            info "  Dumping PostgreSQL db: $db"
            run "sudo -u '$PSQL_USER' pg_dump '$db' | gzip > '${PSQL_DIR}/${db}.sql.gz'"
        done
    fi
else
    info "PostgreSQL backup skipped (PSQL_ENABLED != true)"
fi

# ─── 4. Checksum Manifest ────────────────────────────────────────────────────
step "Generating checksums"
if ! $DRY_RUN; then
    (cd "$DEST" && find . -type f | sort | xargs sha256sum > SHA256SUMS)
    info "  Manifest: ${DEST}/SHA256SUMS"
fi

# ─── 5. Retention Cleanup ────────────────────────────────────────────────────
step "Pruning backups older than ${RETENTION_DAYS} days"
if ! $DRY_RUN; then
    find "$BACKUP_ROOT" -maxdepth 1 -mindepth 1 -type d \
        -mtime "+${RETENTION_DAYS}" -print -exec rm -rf {} \; \
        | while read -r old; do warn "  Removed old backup: $old"; done
fi

# ─── Done ────────────────────────────────────────────────────────────────────
BACKUP_SIZE=$(du -sh "$DEST" 2>/dev/null | cut -f1 || echo "N/A")
info "Backup complete. Size: ${BACKUP_SIZE} | Location: ${DEST}"
echo -e "\n${GREEN}${BOLD}✓ Backup finished successfully.${RESET}"
