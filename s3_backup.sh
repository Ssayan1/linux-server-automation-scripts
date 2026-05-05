#!/usr/bin/env bash
# =============================================================================
# s3_backup.sh — Upload backups to AWS S3
# Usage: ./s3_backup.sh
# Cron:  30 2 * * * /path/to/s3_backup.sh  (30 mins after backup.sh)
# =============================================================================

set -uo pipefail

# ─── Configuration ────────────────────────────────────────────────────────────
S3_BUCKET="sayan-server-backups"
S3_REGION="ap-south-1"
BACKUP_ROOT="/var/backups/server"
LOG_FILE="/var/log/s3_backup.log"
RETENTION_DAYS=30       # Keep S3 backups for 30 days
MAX_SIZE_GB=5           # Skip upload if backup exceeds this size

# ─── Telegram Config ──────────────────────────────────────────────────────────
TELEGRAM_TOKEN="8646464628:AAE6FmGjsqdlPCfNYpwAO2AMTd06eFf9R-E"
TELEGRAM_CHAT_ID="1064546443"
TELEGRAM_ENABLED=true

# ─── Colors & Helpers ─────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

TS()    { date '+%F %T'; }
log()   { echo -e "$(TS) $*" | tee -a "$LOG_FILE"; }
ok()    { log "${GREEN}[  OK  ]${RESET} $*"; }
warn()  { log "${YELLOW}[ WARN ]${RESET} $*"; }
err()   { log "${RED}[ERROR ]${RESET} $*"; }
header(){ echo -e "\n${CYAN}${BOLD}━━━ $* ━━━${RESET}" | tee -a "$LOG_FILE"; }

mkdir -p "$(dirname "$LOG_FILE")"

# ─── Send Telegram ────────────────────────────────────────────────────────────
send_telegram() {
    local msg="$1"
    if [[ "$TELEGRAM_ENABLED" == "true" ]]; then
        curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_TOKEN}/sendMessage" \
            -d chat_id="${TELEGRAM_CHAT_ID}" \
            -d parse_mode="Markdown" \
            -d text="$msg" > /dev/null
    fi
}

# ─── Check AWS CLI ────────────────────────────────────────────────────────────
check_aws() {
    if ! command -v aws &>/dev/null; then
        err "AWS CLI not found. Install: curl 'https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip' -o awscliv2.zip && unzip awscliv2.zip && sudo ./aws/install"
        exit 1
    fi

    if ! aws s3 ls "s3://${S3_BUCKET}" &>/dev/null; then
        err "Cannot access bucket: s3://${S3_BUCKET}"
        err "Check your AWS credentials: aws configure"
        exit 1
    fi
    ok "AWS CLI ready — bucket accessible: s3://${S3_BUCKET}"
}

# ─── Upload Latest Backup ─────────────────────────────────────────────────────
upload_latest() {
    # Find the most recent backup folder
    local latest
    latest=$(find "$BACKUP_ROOT" -maxdepth 1 -mindepth 1 -type d | sort | tail -1)

    if [[ -z "$latest" ]]; then
        err "No backups found in $BACKUP_ROOT"
        err "Run backup.sh first!"
        send_telegram "☁️ *S3 Upload Failed — $(hostname)*%0ANo local backups found in ${BACKUP_ROOT}%0ARun backup.sh first!"
        exit 1
    fi

    local folder_name
    folder_name=$(basename "$latest")

    # Check size
    local size_bytes
    size_bytes=$(du -sb "$latest" | cut -f1)
    local size_human
    size_human=$(du -sh "$latest" | cut -f1)
    local max_bytes=$(( MAX_SIZE_GB * 1024 * 1024 * 1024 ))

    if (( size_bytes > max_bytes )); then
        warn "Backup size ${size_human} exceeds limit ${MAX_SIZE_GB}GB — uploading anyway"
    fi

    local s3_path="s3://${S3_BUCKET}/backups/${folder_name}/"

    ok "Uploading: $latest → $s3_path"
    ok "Size: $size_human"

    # Upload with progress
    if aws s3 sync "$latest" "$s3_path" \
        --region "$S3_REGION" \
        --storage-class STANDARD_IA \
        --no-progress 2>&1 | tee -a "$LOG_FILE"; then

        ok "Upload complete → $s3_path"

        # Verify upload
        local remote_count
        remote_count=$(aws s3 ls "$s3_path" --recursive | wc -l)
        local local_count
        local_count=$(find "$latest" -type f | wc -l)
        ok "Files: local=${local_count} remote=${remote_count}"

        send_telegram "☁️ *S3 Backup Success — $(hostname)*%0A$(date '+%Y-%m-%d %H:%M')%0A%0A✅ Uploaded: \`${folder_name}\`%0ASize: ${size_human}%0AFiles: ${remote_count} uploaded%0ABucket: ${S3_BUCKET}"
        echo "$folder_name" >> "$LOG_FILE"
    else
        err "Upload FAILED for $latest"
        send_telegram "☁️ *S3 Backup FAILED — $(hostname)*%0A$(date '+%Y-%m-%d %H:%M')%0A%0A🔴 Upload failed for: \`${folder_name}\`%0ACheck log: ${LOG_FILE}"
        exit 1
    fi
}

# ─── Upload All Pending Backups ───────────────────────────────────────────────
upload_all_pending() {
    local count=0
    while IFS= read -r backup_dir; do
        local folder_name
        folder_name=$(basename "$backup_dir")
        local s3_path="s3://${S3_BUCKET}/backups/${folder_name}/"

        # Check if already uploaded
        if aws s3 ls "$s3_path" &>/dev/null; then
            ok "Already uploaded: $folder_name — skipping"
            continue
        fi

        ok "Uploading pending: $folder_name"
        aws s3 sync "$backup_dir" "$s3_path" \
            --region "$S3_REGION" \
            --storage-class STANDARD_IA \
            --no-progress 2>&1 | tee -a "$LOG_FILE"
        (( count++ )) || true
    done < <(find "$BACKUP_ROOT" -maxdepth 1 -mindepth 1 -type d | sort)

    ok "Uploaded $count new backup(s)"
}

# ─── List S3 Backups ──────────────────────────────────────────────────────────
list_s3_backups() {
    echo -e "\n${BOLD}S3 Backups in s3://${S3_BUCKET}/backups/:${RESET}"
    aws s3 ls "s3://${S3_BUCKET}/backups/" --region "$S3_REGION" 2>/dev/null || echo "  (none yet)"
}

# ─── Prune Old S3 Backups ─────────────────────────────────────────────────────
prune_old_s3() {
    header "Pruning S3 backups older than ${RETENTION_DAYS} days"
    local cutoff
    cutoff=$(date -d "-${RETENTION_DAYS} days" +%Y-%m-%d 2>/dev/null || \
             date -v "-${RETENTION_DAYS}d" +%Y-%m-%d)

    local pruned=0
    while IFS= read -r line; do
        local folder_date
        folder_date=$(echo "$line" | awk '{print $2}' | tr -d '/')
        if [[ "$folder_date" < "$cutoff" ]]; then
            local s3_path="s3://${S3_BUCKET}/backups/${folder_date}/"
            warn "Removing old backup: $s3_path"
            aws s3 rm "$s3_path" --recursive --region "$S3_REGION" 2>&1 | tee -a "$LOG_FILE"
            (( pruned++ )) || true
        fi
    done < <(aws s3 ls "s3://${S3_BUCKET}/backups/" --region "$S3_REGION" 2>/dev/null)

    if (( pruned == 0 )); then
        ok "No old backups to prune"
    else
        ok "Pruned $pruned old backup(s) from S3"
    fi
}

# ─── Main ─────────────────────────────────────────────────────────────────────
echo -e "\n${CYAN}${BOLD}☁️  S3 Backup Upload — $(TS)${RESET}"
log "Starting S3 upload on $(hostname)"

header "Checking AWS"
check_aws

header "Uploading Latest Backup"
upload_latest

header "Listing S3 Backups"
list_s3_backups

header "Pruning Old S3 Backups"
prune_old_s3

echo -e "\n${GREEN}${BOLD}✓ S3 backup upload complete.${RESET}"
log "S3 upload finished"
