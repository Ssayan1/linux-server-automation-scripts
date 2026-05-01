#!/usr/bin/env bash
# =============================================================================
# ssl_checker.sh — SSL Certificate Expiry Monitor
# Usage: ./ssl_checker.sh
# Cron: 0 9 * * * /path/to/ssl_checker.sh   (daily at 9 AM)
# =============================================================================

set -euo pipefail

# ─── Configuration ────────────────────────────────────────────────────────────
WARN_DAYS=30        # Warn if cert expires within 30 days
CRIT_DAYS=7         # Critical if cert expires within 7 days
LOG_FILE="/var/log/ssl_checker.log"

# ─── Telegram Config ──────────────────────────────────────────────────────────
TELEGRAM_TOKEN="8646464628:AAE6FmGjsqdlPCfNYpwAO2AMTd06eFf9R-E"
TELEGRAM_CHAT_ID="1064546443"
TELEGRAM_ENABLED=true

# ─── Domains to Check ─────────────────────────────────────────────────────────
DOMAINS=(
    "d61zgekfhvg0k.cloudfront.net"   # Sayan's portfolio (AWS CloudFront)
    "google.com"
    "github.com"
    "anthropic.com"
)

# ─── Colors & Helpers ─────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

TS()    { date '+%F %T'; }
log()   { echo -e "$(TS) $*" | tee -a "$LOG_FILE"; }
ok()    { log "${GREEN}[  OK  ]${RESET} $*"; }
warn()  { log "${YELLOW}[ WARN ]${RESET} $*"; WARNINGS+=("$*"); }
crit()  { log "${RED}[ CRIT ]${RESET} $*"; CRITICALS+=("$*"); }
header(){ echo -e "\n${CYAN}${BOLD}━━━ $* ━━━${RESET}" | tee -a "$LOG_FILE"; }

WARNINGS=()
CRITICALS=()

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

# ─── Check Single Domain ──────────────────────────────────────────────────────
check_domain() {
    local domain="$1"

    # Get cert expiry date
    local expiry
    expiry=$(echo | timeout 10 openssl s_client \
        -servername "$domain" \
        -connect "$domain:443" 2>/dev/null \
        | openssl x509 -noout -enddate 2>/dev/null \
        | cut -d= -f2)

    if [[ -z "$expiry" ]]; then
        crit "Could not retrieve SSL cert for: $domain"
        return
    fi

    # Convert expiry to seconds since epoch
    local expiry_epoch
    expiry_epoch=$(date -d "$expiry" +%s 2>/dev/null || date -j -f "%b %d %T %Y %Z" "$expiry" +%s)

    local now_epoch
    now_epoch=$(date +%s)

    local days_left
    days_left=$(( (expiry_epoch - now_epoch) / 86400 ))

    local expiry_fmt
    expiry_fmt=$(date -d "$expiry" '+%Y-%m-%d' 2>/dev/null || echo "$expiry")

    local msg="${domain} — expires in ${days_left} days (${expiry_fmt})"

    if (( days_left <= CRIT_DAYS )); then
        crit "$msg"
    elif (( days_left <= WARN_DAYS )); then
        warn "$msg"
    else
        ok "$msg"
    fi
}

# ─── Main ─────────────────────────────────────────────────────────────────────
echo -e "\n${CYAN}${BOLD}🔐 SSL Certificate Checker — $(TS)${RESET}"
log "Checking ${#DOMAINS[@]} domains..."

header "SSL Certificate Status"
for domain in "${DOMAINS[@]}"; do
    check_domain "$domain"
done

# ─── Summary ──────────────────────────────────────────────────────────────────
header "Summary"
total_issues=$(( ${#CRITICALS[@]} + ${#WARNINGS[@]} ))
log "Criticals: ${#CRITICALS[@]} | Warnings: ${#WARNINGS[@]}"

if (( total_issues == 0 )); then
    ok "All SSL certificates are healthy ✓"
    # Send a daily OK summary to Telegram
    send_telegram "✅ *SSL Check — $(hostname)*%0A$(date '+%Y-%m-%d')%0AAll ${#DOMAINS[@]} certificates are healthy 🔐"
else
    # Build alert message
    MSG="🔐 *SSL Alert — $(hostname)*%0A$(date '+%Y-%m-%d')%0A%0A"
    for c in "${CRITICALS[@]}"; do MSG+="🔴 $c%0A"; done
    for w in "${WARNINGS[@]}"; do MSG+="🟡 $w%0A"; done
    send_telegram "$MSG"
    log "Telegram alert sent"
fi

echo -e "\n${GREEN}${BOLD}✓ SSL check complete.${RESET}"
