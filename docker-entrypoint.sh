#!/usr/bin/env bash
# =============================================================================
# docker-entrypoint.sh — Container command router
# Usage: docker run linux-automation [command]
# Commands: health, ssl, backup, firewall, admin, test, dashboard, help
# =============================================================================

set -e

RED='\033[0;31m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'
BOLD='\033[1m'; RESET='\033[0m'

banner() {
    echo -e "${CYAN}${BOLD}"
    echo "  ╔══════════════════════════════════════╗"
    echo "  ║   Linux Server Automation Scripts    ║"
    echo "  ║   github.com/Ssayan1                 ║"
    echo "  ╚══════════════════════════════════════╝"
    echo -e "${RESET}"
}

case "${1:-help}" in

    health)
        banner
        echo -e "${GREEN}Running health check...${RESET}\n"
        bash health_check.sh
        ;;

    ssl)
        banner
        echo -e "${GREEN}Running SSL checker...${RESET}\n"
        bash ssl_checker.sh
        ;;

    backup)
        banner
        echo -e "${GREEN}Running backup...${RESET}\n"
        bash backup.sh "${@:2}"
        ;;

    firewall)
        banner
        echo -e "${GREEN}Running firewall audit...${RESET}\n"
        bash firewall_audit.sh
        ;;

    admin)
        banner
        python3 linux_admin.py "${@:2}"
        ;;

    test)
        banner
        echo -e "${GREEN}Running unit tests...${RESET}\n"
        python3 -m pytest tests/ -v
        ;;

    dashboard)
        banner
        echo -e "${GREEN}Generating dashboard...${RESET}\n"
        python3 generate_dashboard.py --output /tmp/dashboard.html
        echo -e "\n${GREEN}Dashboard saved to /tmp/dashboard.html${RESET}"
        ;;

    all)
        banner
        echo -e "${GREEN}Running all checks...${RESET}\n"
        bash health_check.sh
        echo ""
        bash ssl_checker.sh
        echo ""
        bash firewall_audit.sh
        ;;

    help|*)
        banner
        echo -e "${BOLD}Available commands:${RESET}\n"
        echo "  docker run linux-automation health      → Run health check"
        echo "  docker run linux-automation ssl         → Check SSL certificates"
        echo "  docker run linux-automation backup      → Run backup"
        echo "  docker run linux-automation firewall    → Run firewall audit"
        echo "  docker run linux-automation test        → Run unit tests"
        echo "  docker run linux-automation dashboard   → Generate HTML dashboard"
        echo "  docker run linux-automation all         → Run all checks"
        echo "  docker run linux-automation admin <cmd> → Python admin tool"
        echo ""
        echo -e "${CYAN}Examples:${RESET}"
        echo "  docker run linux-automation admin listusers"
        echo "  docker run linux-automation admin analyze /var/log/syslog"
        echo "  docker run --rm -v /var/log:/var/log linux-automation health"
        echo ""
        ;;
esac
