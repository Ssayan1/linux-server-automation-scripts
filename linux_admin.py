#!/usr/bin/env python3
"""
linux_admin.py — Log Analysis & User/Group Management
======================================================
Commands:
  analyze  <logfile> [--level ERROR] [--tail N] [--report report.txt]
  adduser  <username> [--groups g1,g2] [--shell /bin/bash] [--home /home/user] [--comment "Full Name"]
  addgroup <groupname> [--gid 1500]
  usermod  <username> --add-groups g1,g2
  listusers
  listgroups
"""

import argparse
import collections
import grp
import os
import pwd
import re
import subprocess
import sys
from datetime import datetime
from pathlib import Path

# ─── ANSI colours ─────────────────────────────────────────────────────────────
class C:
    RED    = "\033[0;31m"
    GREEN  = "\033[0;32m"
    YELLOW = "\033[1;33m"
    CYAN   = "\033[0;36m"
    BOLD   = "\033[1m"
    RESET  = "\033[0m"

def info(msg):  print(f"{C.GREEN}[INFO]{C.RESET}  {msg}")
def warn(msg):  print(f"{C.YELLOW}[WARN]{C.RESET}  {msg}", file=sys.stderr)
def err(msg):   print(f"{C.RED}[ERROR]{C.RESET} {msg}", file=sys.stderr)
def die(msg, code=1):
    err(msg); sys.exit(code)

def require_root():
    if os.geteuid() != 0:
        die("This operation requires root privileges. Run with sudo.")

# ═══════════════════════════════════════════════════════════════════════════════
#  LOG ANALYSIS
# ═══════════════════════════════════════════════════════════════════════════════

# Common log patterns — covers syslog, journald, nginx, apache, python, django
LOG_PATTERNS = {
    "ERROR":   re.compile(r"\b(ERROR|error|CRITICAL|critical|FATAL|fatal|FAILED|failed)\b", re.I),
    "WARNING": re.compile(r"\b(WARNING|WARN|warn)\b", re.I),
    "INFO":    re.compile(r"\b(INFO|info|NOTICE)\b", re.I),
    "DEBUG":   re.compile(r"\b(DEBUG|debug)\b", re.I),
}

# Capture the contextual error message after the level keyword
ERROR_DETAIL = re.compile(
    r"(?:ERROR|CRITICAL|FATAL|FAILED)[:\s]+(.+?)(?:\n|$)", re.I
)


def analyze_log(args):
    log_path = Path(args.logfile)
    if not log_path.exists():
        die(f"Log file not found: {log_path}")

    level_filter = args.level.upper()
    tail_n       = args.tail
    report_path  = args.report

    print(f"\n{C.CYAN}{C.BOLD}━━━ Log Analysis: {log_path} ━━━{C.RESET}")
    info(f"Filter level : {level_filter}")
    if tail_n:
        info(f"Reading last  : {tail_n} lines")

    # Read file (all or tail)
    with open(log_path, "r", errors="replace") as fh:
        lines = fh.readlines()

    if tail_n:
        lines = lines[-tail_n:]

    total_lines     = len(lines)
    level_counts    = collections.Counter()
    error_messages  = collections.Counter()
    matched_lines   = []

    target_pattern  = LOG_PATTERNS.get(level_filter)

    for lineno, raw in enumerate(lines, 1):
        line = raw.rstrip()
        # Count all levels
        for lvl, pat in LOG_PATTERNS.items():
            if pat.search(line):
                level_counts[lvl] += 1

        # Collect lines matching the requested level
        if target_pattern and target_pattern.search(line):
            matched_lines.append((lineno, line))
            # Extract error detail for frequency analysis
            m = ERROR_DETAIL.search(line)
            if m:
                detail = m.group(1).strip()[:120]   # cap at 120 chars
                error_messages[detail] += 1

    # ── Print summary ──────────────────────────────────────────────────────────
    print(f"\n{C.BOLD}File summary{C.RESET}")
    print(f"  Total lines  : {total_lines:,}")
    for lvl in ("ERROR", "WARNING", "INFO", "DEBUG"):
        colour = C.RED if lvl == "ERROR" else (C.YELLOW if lvl == "WARNING" else C.RESET)
        print(f"  {colour}{lvl:<10}{C.RESET}: {level_counts.get(lvl, 0):,}")

    if not matched_lines:
        info(f"No {level_filter} lines found.")
    else:
        print(f"\n{C.BOLD}Matched {level_filter} lines ({len(matched_lines):,}){C.RESET}")
        # Show at most 20 lines in terminal
        display = matched_lines[:20]
        for lineno, text in display:
            print(f"  {C.CYAN}L{lineno:<6}{C.RESET} {text}")
        if len(matched_lines) > 20:
            print(f"  … {len(matched_lines) - 20} more (see report file)")

    if error_messages:
        print(f"\n{C.BOLD}Top error messages{C.RESET}")
        for msg, count in error_messages.most_common(10):
            print(f"  {C.RED}{count:>5}×{C.RESET}  {msg}")

    # ── Write report ──────────────────────────────────────────────────────────
    if report_path:
        rp = Path(report_path)
        with open(rp, "w") as rf:
            rf.write(f"Log Analysis Report\n")
            rf.write(f"Generated  : {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}\n")
            rf.write(f"Log file   : {log_path.resolve()}\n")
            rf.write(f"Filter     : {level_filter}\n")
            rf.write(f"Total lines: {total_lines:,}\n\n")
            rf.write("Level Counts\n" + "-"*40 + "\n")
            for lvl in ("ERROR", "WARNING", "INFO", "DEBUG"):
                rf.write(f"  {lvl:<10}: {level_counts.get(lvl, 0):,}\n")
            rf.write(f"\nTop Error Messages\n" + "-"*40 + "\n")
            for msg, count in error_messages.most_common(20):
                rf.write(f"  {count:>5}×  {msg}\n")
            rf.write(f"\nAll {level_filter} Lines\n" + "-"*40 + "\n")
            for lineno, text in matched_lines:
                rf.write(f"L{lineno:<6} {text}\n")
        info(f"Report written → {rp.resolve()}")


# ═══════════════════════════════════════════════════════════════════════════════
#  USER MANAGEMENT
# ═══════════════════════════════════════════════════════════════════════════════

def user_exists(username: str) -> bool:
    try:
        pwd.getpwnam(username)
        return True
    except KeyError:
        return False

def group_exists(groupname: str) -> bool:
    try:
        grp.getgrnam(groupname)
        return True
    except KeyError:
        return False

def run_cmd(cmd: list[str], check=True) -> subprocess.CompletedProcess:
    """Run a system command, print it, and return the result."""
    info(f"Running: {' '.join(cmd)}")
    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.stdout.strip():
        print(f"  stdout: {result.stdout.strip()}")
    if result.stderr.strip():
        print(f"  stderr: {result.stderr.strip()}")
    if check and result.returncode != 0:
        die(f"Command failed (exit {result.returncode}): {' '.join(cmd)}")
    return result


def cmd_adduser(args):
    require_root()
    username = args.username
    if user_exists(username):
        die(f"User '{username}' already exists.")

    cmd = ["useradd"]
    if args.home:
        cmd += ["-d", args.home, "-m"]
    else:
        cmd += ["-m"]                          # create home by default
    if args.shell:
        cmd += ["-s", args.shell]
    if args.comment:
        cmd += ["-c", args.comment]
    cmd.append(username)

    run_cmd(cmd)
    info(f"User '{username}' created.")

    # Add to supplementary groups
    if args.groups:
        groups = [g.strip() for g in args.groups.split(",") if g.strip()]
        for g in groups:
            if not group_exists(g):
                warn(f"Group '{g}' does not exist — creating it first.")
                run_cmd(["groupadd", g])
        run_cmd(["usermod", "-aG", ",".join(groups), username])
        info(f"Added '{username}' to groups: {', '.join(groups)}")

    print(f"\n{C.GREEN}{C.BOLD}✓ User '{username}' ready.{C.RESET}")
    # Show the new user entry
    entry = pwd.getpwnam(username)
    print(f"  UID  : {entry.pw_uid}")
    print(f"  GID  : {entry.pw_gid}")
    print(f"  Home : {entry.pw_dir}")
    print(f"  Shell: {entry.pw_shell}")


def cmd_addgroup(args):
    require_root()
    groupname = args.groupname
    if group_exists(groupname):
        die(f"Group '{groupname}' already exists.")

    cmd = ["groupadd"]
    if args.gid:
        cmd += ["-g", str(args.gid)]
    cmd.append(groupname)

    run_cmd(cmd)
    g = grp.getgrnam(groupname)
    info(f"Group '{groupname}' created with GID {g.gr_gid}.")


def cmd_usermod(args):
    require_root()
    username = args.username
    if not user_exists(username):
        die(f"User '{username}' does not exist.")

    if args.add_groups:
        groups = [g.strip() for g in args.add_groups.split(",") if g.strip()]
        for g in groups:
            if not group_exists(g):
                die(f"Group '{g}' does not exist. Create it first with: addgroup {g}")
        run_cmd(["usermod", "-aG", ",".join(groups), username])
        info(f"Added '{username}' to: {', '.join(groups)}")


def cmd_listusers(args):
    print(f"\n{C.CYAN}{C.BOLD}━━━ System Users ━━━{C.RESET}")
    min_uid = args.min_uid
    all_groups = {g.gr_gid: g.gr_name for g in grp.getgrall()}
    user_group_map = collections.defaultdict(list)
    for g in grp.getgrall():
        for member in g.gr_mem:
            user_group_map[member].append(g.gr_name)

    header = f"{'Username':<20} {'UID':>6} {'GID':>6} {'Home':<28} {'Shell'}"
    print(f"\n{C.BOLD}{header}{C.RESET}")
    print("─" * 80)
    for p in sorted(pwd.getpwall(), key=lambda x: x.pw_uid):
        if p.pw_uid < min_uid:
            continue
        groups_str = ",".join(user_group_map.get(p.pw_name, []))[:30]
        print(f"{p.pw_name:<20} {p.pw_uid:>6} {p.pw_gid:>6} {p.pw_dir:<28} {p.pw_shell}")
        if groups_str:
            print(f"  {C.CYAN}↳ groups: {groups_str}{C.RESET}")


def cmd_listgroups(args):
    print(f"\n{C.CYAN}{C.BOLD}━━━ System Groups ━━━{C.RESET}")
    header = f"{'Group':<25} {'GID':>6}  {'Members'}"
    print(f"\n{C.BOLD}{header}{C.RESET}")
    print("─" * 70)
    for g in sorted(grp.getgrall(), key=lambda x: x.gr_gid):
        members = ", ".join(g.gr_mem) or "(none)"
        print(f"{g.gr_name:<25} {g.gr_gid:>6}  {members}")


# ═══════════════════════════════════════════════════════════════════════════════
#  ARGUMENT PARSER
# ═══════════════════════════════════════════════════════════════════════════════

def build_parser():
    parser = argparse.ArgumentParser(
        description="Linux Admin Toolkit — log analysis & user/group management",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    sub = parser.add_subparsers(dest="command", required=True)

    # ── analyze ───────────────────────────────────────────────────────────────
    p_analyze = sub.add_parser("analyze", help="Analyse a log file")
    p_analyze.add_argument("logfile", help="Path to log file")
    p_analyze.add_argument("--level",  default="ERROR",
                           choices=["ERROR", "WARNING", "INFO", "DEBUG"],
                           help="Level to filter/count (default: ERROR)")
    p_analyze.add_argument("--tail",   type=int, metavar="N",
                           help="Only read the last N lines")
    p_analyze.add_argument("--report", metavar="FILE",
                           help="Write full report to this file")

    # ── adduser ───────────────────────────────────────────────────────────────
    p_adduser = sub.add_parser("adduser", help="Create a new system user")
    p_adduser.add_argument("username")
    p_adduser.add_argument("--groups",  help="Comma-separated supplementary groups")
    p_adduser.add_argument("--shell",   default="/bin/bash")
    p_adduser.add_argument("--home",    help="Home directory (created automatically)")
    p_adduser.add_argument("--comment", help="GECOS full name / description")

    # ── addgroup ──────────────────────────────────────────────────────────────
    p_addgroup = sub.add_parser("addgroup", help="Create a new system group")
    p_addgroup.add_argument("groupname")
    p_addgroup.add_argument("--gid", type=int, help="Specific GID to use")

    # ── usermod ───────────────────────────────────────────────────────────────
    p_usermod = sub.add_parser("usermod", help="Modify an existing user")
    p_usermod.add_argument("username")
    p_usermod.add_argument("--add-groups", metavar="GROUPS",
                           help="Comma-separated groups to add user to")

    # ── listusers ─────────────────────────────────────────────────────────────
    p_list = sub.add_parser("listusers", help="List system users")
    p_list.add_argument("--min-uid", type=int, default=0,
                        help="Minimum UID to display (e.g. 1000 for human users)")

    # ── listgroups ────────────────────────────────────────────────────────────
    sub.add_parser("listgroups", help="List all system groups")

    return parser


def main():
    parser = build_parser()
    args   = parser.parse_args()

    dispatch = {
        "analyze":    analyze_log,
        "adduser":    cmd_adduser,
        "addgroup":   cmd_addgroup,
        "usermod":    cmd_usermod,
        "listusers":  cmd_listusers,
        "listgroups": cmd_listgroups,
    }
    dispatch[args.command](args)


if __name__ == "__main__":
    main()
