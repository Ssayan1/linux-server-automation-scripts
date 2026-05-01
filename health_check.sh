#!/usr/bin/env bash
# =============================================================================
# health_check.sh — Disk, Memory & Service Monitor
# Usage: ./health_check.sh [--email you@example.com] [--log /var/log/health.log]
# Cron example: */15 * * * * /opt/scripts/health_check.sh --email ops@company.com
# =============================================================================

set -euo pipefail

# ─── Defaults ─────────────────────────────────────────────────────────────────
DISK_WARN=80        # % used — warn
DISK_CRIT=90       # % used — critical
MEM_WARN=80         # % used — warn
MEM_CRIT=95         # % used — critical
LOAD_WARN=2.0       # 1-min load avg — warn
LOAD_CRIT=5.0       # 1-min load avg — critical

LOG_FILE="/var/log/server_health.log"
EMAIL_TO=""
EMAIL_FROM="healthcheck@$(hostname -f 2>/dev/null || echo localhost)"
EMAIL_SUBJECT="[ALERT] Server health issue on $(hostname)"

TELEGRAM_TOKEN="8646464628:AAE6FmGjsqdlPCfNYpwAO2AMTd06eFf9R-E"
TELEGRAM_CHAT_ID="1064546443"
TELEGRAM_ENABLED=true

# Services to verify are running (systemd units)
SERVICES_TO_CHECK=(
    # "ssh"
    "cron"
    # "nginx"
    # "mysql"
    # "postgresql"
)

# Mount points to check disk usage on
MOUNT_POINTS=(
    "/"
    # "/data"
    # "/var"
)

# ─── Colors & Helpers ─────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

TS()     { date '+%F %T'; }
log()    { echo -e "$(TS) $*" | tee -a "$LOG_FILE"; }
ok()     { log "${GREEN}[  OK  ]${RESET} $*"; }
warn()   { log "${YELLOW}[ WARN ]${RESET} $*"; WARNINGS+=("$*"); }
crit()   { log "${RED}[ CRIT ]${RESET} $*"; CRITICALS+=("$*"); }
header() { echo -e "\n${CYAN}${BOLD}━━━ $* ━━━${RESET}" | tee -a "$LOG_FILE"; }

WARNINGS=()
CRITICALS=()

# ─── Argument parsing ─────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --email) EMAIL_TO="$2"; shift 2 ;;
        --log)   LOG_FILE="$2"; shift 2 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

mkdir -p "$(dirname "$LOG_FILE")"

log "${BOLD}Health check started on $(hostname) ($(TS))${RESET}"

# ─── 1. Disk Usage ────────────────────────────────────────────────────────────
header "Disk Usage"
for mount in "${MOUNT_POINTS[@]}"; do
    if ! mountpoint -q "$mount" 2>/dev/null && [[ "$mount" != "/" ]]; then
        warn "Mount point not found: $mount"
        continue
    fi
    usage=$(df -h "$mount" | awk 'NR==2 {print $5}' | tr -d '%')
    avail=$(df -h "$mount" | awk 'NR==2 {print $4}')
    total=$(df -h "$mount" | awk 'NR==2 {print $2}')
    msg="Disk ${mount}: ${usage}% used (${avail} free of ${total})"

    if (( usage >= DISK_CRIT )); then
        crit "$msg"
    elif (( usage >= DISK_WARN )); then
        warn "$msg"
    else
        ok "$msg"
    fi
done

# ─── 2. Memory Usage ──────────────────────────────────────────────────────────
header "Memory Usage"
read -r mem_total mem_used mem_free mem_shared mem_buff mem_avail \
    < <(free -m | awk 'NR==2 {print $2, $3, $4, $5, $6, $7}')
mem_pct=$(( mem_used * 100 / mem_total ))
swap_line=$(free -m | awk '/^Swap/ {print $2, $3, $4}')
swap_total=$(echo "$swap_line" | awk '{print $1}')
swap_used=$(echo "$swap_line"  | awk '{print $2}')

msg="RAM: ${mem_used}MB / ${mem_total}MB (${mem_pct}%)"
if (( mem_pct >= MEM_CRIT )); then
    crit "$msg"
elif (( mem_pct >= MEM_WARN )); then
    warn "$msg"
else
    ok "$msg"
fi

if (( swap_total > 0 )); then
    swap_pct=$(( swap_used * 100 / swap_total ))
    ok "Swap: ${swap_used}MB / ${swap_total}MB (${swap_pct}%)"
else
    ok "Swap: not configured"
fi

# ─── 3. CPU Load Average ──────────────────────────────────────────────────────
header "CPU Load Average"
load1=$(uptime | awk -F'load average:' '{print $2}' | awk -F',' '{print $1}' | xargs)
load5=$(uptime | awk -F'load average:' '{print $2}' | awk -F',' '{print $2}' | xargs)
load15=$(uptime | awk -F'load average:' '{print $2}' | awk -F',' '{print $3}' | xargs)
cpu_cores=$(nproc)
msg="Load avg: ${load1} (1m) ${load5} (5m) ${load15} (15m) | Cores: ${cpu_cores}"

# Compare using bc for float comparison
if (( $(echo "$load1 >= $LOAD_CRIT" | bc -l) )); then
    crit "$msg"
elif (( $(echo "$load1 >= $LOAD_WARN" | bc -l) )); then
    warn "$msg"
else
    ok "$msg"
fi

# ─── 4. Service Health ────────────────────────────────────────────────────────
header "Service Status"
for svc in "${SERVICES_TO_CHECK[@]}"; do
    if systemctl is-active --quiet "$svc" 2>/dev/null; then
        ok "Service running: $svc"
    else
        status=$(systemctl is-active "$svc" 2>/dev/null || echo "unknown")
        crit "Service NOT running: ${svc} (status: ${status})"
    fi
done

# ─── 5. Zombie Processes ──────────────────────────────────────────────────────
header "Zombie Processes"
zombies=$(ps aux | awk '{print $8}' | grep -c '^Z$' || true)
if (( zombies > 0 )); then
    warn "Zombie processes detected: ${zombies}"
else
    ok "No zombie processes"
fi

# ─── 6. Failed Systemd Units ──────────────────────────────────────────────────
header "Failed Systemd Units"
failed_units=$(systemctl list-units --state=failed --no-legend --no-pager 2>/dev/null | wc -l)
if (( failed_units > 0 )); then
    failed_list=$(systemctl list-units --state=failed --no-legend --no-pager 2>/dev/null | awk '{print $1}' | tr '\n' ' ')
    warn "Failed systemd units (${failed_units}): ${failed_list}"
else
    ok "No failed systemd units"
fi

# ─── 7. Summary & Alert ───────────────────────────────────────────────────────
header "Summary"
total_issues=$(( ${#CRITICALS[@]} + ${#WARNINGS[@]} ))
log "Criticals: ${#CRITICALS[@]} | Warnings: ${#WARNINGS[@]}"

if (( total_issues == 0 )); then
    ok "All systems nominal ✓"
fi

# Build report body
build_report() {
    echo "Server Health Report — $(hostname) — $(TS)"
    echo "=================================================="
    if (( ${#CRITICALS[@]} > 0 )); then
        echo ""
        echo "🔴 CRITICAL ISSUES:"
        for c in "${CRITICALS[@]}"; do echo "  • $c"; done
    fi
    if (( ${#WARNINGS[@]} > 0 )); then
        echo ""
        echo "🟡 WARNINGS:"
        for w in "${WARNINGS[@]}"; do echo "  • $w"; done
    fi
    echo ""
    echo "Full log: $LOG_FILE"
}

# Send Telegram alert if issues found
if [[ "$TELEGRAM_ENABLED" == "true" && $total_issues -gt 0 ]]; then
    MSG="⚠️ *Server Alert — $(hostname)*%0A$(date)%0A%0A"
    for c in "${CRITICALS[@]}"; do MSG+="🔴 $c%0A"; done
    for w in "${WARNINGS[@]}"; do MSG+="🟡 $w%0A"; done
    curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_TOKEN}/sendMessage" \
        -d chat_id="${TELEGRAM_CHAT_ID}" \
        -d parse_mode="Markdown" \
        -d text="$MSG" > /dev/null
    log "Telegram alert sent"
fi

# Send email if issues found and email configured
if [[ -n "$EMAIL_TO" && $total_issues -gt 0 ]]; then
    if command -v mail &>/dev/null; then
        build_report | mail -s "$EMAIL_SUBJECT" -r "$EMAIL_FROM" "$EMAIL_TO"
        log "Alert email sent to $EMAIL_TO"
    elif command -v sendmail &>/dev/null; then
        { echo "Subject: $EMAIL_SUBJECT"; echo "From: $EMAIL_FROM"; echo "To: $EMAIL_TO"; echo ""; build_report; } \
            | sendmail "$EMAIL_TO"
        log "Alert email sent via sendmail to $EMAIL_TO"
    else
        warn "No mail command found — cannot send alert email."
    fi
fi

# Exit code reflects severity
if (( ${#CRITICALS[@]} > 0 )); then exit 2; fi
if (( ${#WARNINGS[@]} > 0 )); then exit 1; fi
exit 0
