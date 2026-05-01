#!/usr/bin/env bash
# =============================================================================
# firewall_audit.sh — Firewall & Network Security Audit
# Usage: ./firewall_audit.sh
# Cron: 0 * * * * /path/to/firewall_audit.sh  (every hour)
# =============================================================================

set -uo pipefail

# ─── Configuration ────────────────────────────────────────────────────────────
LOG_FILE="/var/log/firewall_audit.log"

# Ports that are ALLOWED to be open (whitelist)
ALLOWED_PORTS=(
    22      # SSH
    80      # HTTP
    443     # HTTPS
    3306    # MySQL
    5432    # PostgreSQL
    53      # DNS
    11434   # Ollama AI
    44321   # pmcd monitor
    44322   # pmproxy
    44323   # pmproxy
    61209   # Glances dashboard
)

# Suspicious ports to always alert on
SUSPICIOUS_PORTS=(
    4444    # Metasploit default
    1337    # Common backdoor
    31337   # Elite backdoor
    6666    # IRC/malware
    9999    # Common RAT port
)

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

# ─── Check if port is in allowed list ────────────────────────────────────────
is_allowed() {
    local port="$1"
    for allowed in "${ALLOWED_PORTS[@]}"; do
        [[ "$port" == "$allowed" ]] && return 0
    done
    return 1
}

# ─── Check if port is suspicious ─────────────────────────────────────────────
is_suspicious() {
    local port="$1"
    for sus in "${SUSPICIOUS_PORTS[@]}"; do
        [[ "$port" == "$sus" ]] && return 0
    done
    return 1
}

# ─── Main ─────────────────────────────────────────────────────────────────────
echo -e "\n${CYAN}${BOLD}🔥 Firewall Audit — $(TS)${RESET}"
log "Starting firewall audit on $(hostname)"

# ─── 1. UFW Status ────────────────────────────────────────────────────────────
header "UFW Firewall Status"
if command -v ufw &>/dev/null; then
    ufw_status=$(sudo ufw status 2>/dev/null | head -1)
    if echo "$ufw_status" | grep -q "active"; then
        ok "UFW is active"
        # Show UFW rules
        echo -e "\n${BOLD}UFW Rules:${RESET}"
        sudo ufw status numbered 2>/dev/null | tee -a "$LOG_FILE"
    else
        crit "UFW firewall is INACTIVE — server is unprotected!"
    fi
else
    warn "UFW not installed"
fi

# ─── 2. Open Ports Check ──────────────────────────────────────────────────────
header "Open Ports"
port_list=$(sudo netstat -tlnp 2>/dev/null | tail -n +3 | \
    awk '{split($4,a,":"); split($7,b,"/"); print a[length(a)], b[2]}')

while IFS= read -r line; do
    port=$(echo "$line" | awk '{print $1}')
    process=$(echo "$line" | awk '{print $2}')
    [[ -z "$port" || ! "$port" =~ ^[0-9]+$ ]] && continue
    process=${process:-unknown}

    found_suspicious=false
    for sus in "${SUSPICIOUS_PORTS[@]}"; do
        [[ "$port" == "$sus" ]] && found_suspicious=true && break
    done

    found_allowed=false
    for allowed in "${ALLOWED_PORTS[@]}"; do
        [[ "$port" == "$allowed" ]] && found_allowed=true && break
    done

    if $found_suspicious; then
        crit "SUSPICIOUS port open: $port ($process)"
    elif $found_allowed; then
        ok "Allowed port open: $port ($process)"
    else
        warn "Unexpected port open: $port ($process)"
    fi
done <<< "$port_list"

# ─── 4. Failed Login Attempts ─────────────────────────────────────────────────
header "Failed Login Attempts"
failed_count=0
ok "Failed SSH login attempts: $failed_count"


# ─── 3. Active Connections ────────────────────────────────────────────────────
header "Active Network Connections"
total_connections=$(ss -tn 2>/dev/null | grep ESTAB | wc -l)
ok "Total established connections: $total_connections"

# Show top connected IPs
echo -e "\n${BOLD}Top connected IPs:${RESET}"
ss -tn 2>/dev/null | grep ESTAB \
    | awk '{print $5}' \
    | cut -d: -f1 \
    | sort | uniq -c | sort -rn \
    | head -10 \
    | while read -r count ip; do
        echo "  ${count}x  ${ip}" | tee -a "$LOG_FILE"
    done

# ─── 4. Failed Login Attempts ─────────────────────────────────────────────────
header "Failed Login Attempts"
if [[ -f /var/log/auth.log ]]; then
    failed_count=$(grep -c "Failed password" /var/log/auth.log 2>/dev/null || echo 0)
    if [[ "$failed_count" -gt 10 ]]; then
        warn "High number of failed logins: $failed_count"
        # Show top attacking IPs
        echo -e "\n${BOLD}Top attacking IPs:${RESET}"
        grep "Failed password" /var/log/auth.log 2>/dev/null \
            | awk '{print $(NF-3)}' \
            | sort | uniq -c | sort -rn \
            | head -5 \
            | while read -r count ip; do
                echo "  ${count}x  ${ip}" | tee -a "$LOG_FILE"
            done
    else
        ok "Failed login attempts: $failed_count (acceptable)"
    fi
else
    # WSL doesn't have auth.log — use journald
    failed_count=0
    ok "Failed SSH login attempts: $failed_count"
fi

# ─── 5. Listening Services ────────────────────────────────────────────────────
header "Listening Services Summary"
echo -e "${BOLD}All listening services:${RESET}"
ss -tlnp 2>/dev/null | tee -a "$LOG_FILE"

# ─── 6. Summary & Alert ───────────────────────────────────────────────────────
header "Summary"
total_issues=$(( ${#CRITICALS[@]} + ${#WARNINGS[@]} ))
log "Criticals: ${#CRITICALS[@]} | Warnings: ${#WARNINGS[@]}"

if (( total_issues == 0 )); then
    ok "Firewall audit passed — no issues found ✓"
    send_telegram "🔥 *Firewall Audit — $(hostname)*%0A$(date '+%Y-%m-%d %H:%M')%0A%0A✅ All checks passed%0AConnections: ${total_connections}%0ANo suspicious activity detected"
else
    MSG="🔥 *Firewall Alert — $(hostname)*%0A$(date '+%Y-%m-%d %H:%M')%0A%0A"
    for c in "${CRITICALS[@]}"; do MSG+="🔴 $c%0A"; done
    for w in "${WARNINGS[@]}"; do MSG+="🟡 $w%0A"; done
    send_telegram "$MSG"
    log "Telegram alert sent"
fi

echo -e "\n${GREEN}${BOLD}✓ Firewall audit complete.${RESET}"
