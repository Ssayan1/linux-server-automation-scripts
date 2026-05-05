#!/usr/bin/env python3
"""
generate_dashboard.py — Server Health HTML Dashboard Generator
Usage: python3 generate_dashboard.py [--output /var/www/html/dashboard.html]
Cron:  */5 * * * * python3 /path/to/generate_dashboard.py
"""

import argparse
import datetime
import os
import re
import shutil
import subprocess
import sys

# ─── Helpers ──────────────────────────────────────────────────────────────────

def run(cmd):
    try:
        return subprocess.check_output(cmd, shell=True, stderr=subprocess.DEVNULL, text=True).strip()
    except Exception:
        return ""

def pct_color(pct, warn=70, crit=90):
    if pct >= crit:   return "#ff4d4d"
    if pct >= warn:   return "#ffa500"
    return "#00e5a0"

def status_icon(ok):
    return "✓" if ok else "✗"

# ─── Data Collection ──────────────────────────────────────────────────────────

def get_disk():
    out = run("df -h / | awk 'NR==2 {print $2, $3, $4, $5}'")
    if not out: return {"total":"?","used":"?","free":"?","pct":0}
    parts = out.split()
    pct = int(parts[3].replace('%','')) if len(parts) >= 4 else 0
    return {"total":parts[0],"used":parts[1],"free":parts[2],"pct":pct}

def get_memory():
    out = run("free -m | awk 'NR==2 {print $2, $3, $4}'")
    if not out: return {"total":0,"used":0,"free":0,"pct":0}
    parts = out.split()
    total, used = int(parts[0]), int(parts[1])
    pct = round(used * 100 / total) if total > 0 else 0
    return {"total":total,"used":used,"free":int(parts[2]),"pct":pct}

def get_load():
    out = run("uptime | awk -F'load average:' '{print $2}'")
    parts = [x.strip() for x in out.split(',')] if out else ["?","?","?"]
    cores = run("nproc") or "?"
    return {"load1":parts[0],"load5":parts[1] if len(parts)>1 else "?",
            "load15":parts[2] if len(parts)>2 else "?","cores":cores}

def get_uptime():
    return run("uptime -p") or "unknown"

def get_services():
    services = ["cron","nginx","mysql","postgresql","ssh","sshd"]
    results = []
    for svc in services:
        status = run(f"systemctl is-active {svc} 2>/dev/null")
        if status:
            results.append({"name": svc, "status": status, "ok": status == "active"})
    return results

def get_ssl_status():
    domains = [
        "d61zgekfhvg0k.cloudfront.net",
        "google.com",
        "github.com",
        "anthropic.com",
    ]
    results = []
    for domain in domains:
        cmd = f"echo | timeout 5 openssl s_client -servername {domain} -connect {domain}:443 2>/dev/null | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2"
        expiry = run(cmd)
        if expiry:
            try:
                exp_dt = datetime.datetime.strptime(expiry.strip(), "%b %d %H:%M:%S %Y %Z")
                days = (exp_dt - datetime.datetime.utcnow()).days
                ok = days > 14
                results.append({"domain": domain, "days": days, "ok": ok, "expiry": exp_dt.strftime("%Y-%m-%d")})
            except Exception:
                results.append({"domain": domain, "days": -1, "ok": False, "expiry": "parse error"})
        else:
            results.append({"domain": domain, "days": -1, "ok": False, "expiry": "unreachable"})
    return results

def get_recent_alerts(log_file="/var/log/server_health.log"):
    alerts = []
    if not os.path.exists(log_file):
        return alerts
    with open(log_file) as f:
        lines = f.readlines()
    for line in reversed(lines[-200:]):
        if "CRIT" in line or "WARN" in line:
            alerts.append(line.strip())
        if len(alerts) >= 8:
            break
    return alerts

# ─── HTML Generation ──────────────────────────────────────────────────────────

def generate_html(disk, mem, load, uptime_str, services, ssl_certs, alerts, hostname):
    now = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    disk_col  = pct_color(disk["pct"])
    mem_col   = pct_color(mem["pct"])

    # Services HTML
    svc_html = ""
    for s in services:
        col = "#00e5a0" if s["ok"] else "#ff4d4d"
        icon = status_icon(s["ok"])
        svc_html += f'<div class="svc-badge" style="border-color:{col}"><span style="color:{col}">{icon}</span> {s["name"]}</div>\n'
    if not svc_html:
        svc_html = '<div class="svc-badge" style="border-color:#555"><span style="color:#aaa">—</span> no services tracked</div>'

    # SSL HTML
    ssl_html = ""
    for cert in ssl_certs:
        col = "#00e5a0" if cert["ok"] else "#ff4d4d"
        bar_w = max(0, min(100, cert["days"])) if cert["days"] > 0 else 0
        ssl_html += f"""
        <div class="ssl-row">
            <div class="ssl-domain">{cert['domain']}</div>
            <div class="ssl-bar-wrap"><div class="ssl-bar" style="width:{bar_w}%;background:{col}"></div></div>
            <div class="ssl-days" style="color:{col}">{cert['days']}d</div>
            <div class="ssl-date">{cert['expiry']}</div>
        </div>"""

    # Alerts HTML
    alert_html = ""
    if alerts:
        for a in alerts:
            col = "#ff4d4d" if "CRIT" in a else "#ffa500"
            alert_html += f'<div class="alert-row" style="border-left-color:{col}">{a}</div>\n'
    else:
        alert_html = '<div class="alert-row" style="border-left-color:#00e5a0;color:#00e5a0">No recent alerts — all systems nominal ✓</div>'

    return f"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta http-equiv="refresh" content="60">
<title>Server Dashboard — {hostname}</title>
<link href="https://fonts.googleapis.com/css2?family=JetBrains+Mono:wght@400;700&family=Syne:wght@700;800&display=swap" rel="stylesheet">
<style>
  :root {{
    --bg: #0a0c10;
    --panel: #111318;
    --border: #1e2130;
    --accent: #00e5a0;
    --warn: #ffa500;
    --crit: #ff4d4d;
    --text: #c8d0e0;
    --muted: #556070;
    --font-mono: 'JetBrains Mono', monospace;
    --font-display: 'Syne', sans-serif;
  }}

  * {{ box-sizing: border-box; margin: 0; padding: 0; }}

  body {{
    background: var(--bg);
    color: var(--text);
    font-family: var(--font-mono);
    min-height: 100vh;
    padding: 2rem;
  }}

  /* ── Scanline overlay ── */
  body::before {{
    content: '';
    position: fixed;
    inset: 0;
    background: repeating-linear-gradient(0deg, transparent, transparent 2px, rgba(0,229,160,0.015) 2px, rgba(0,229,160,0.015) 4px);
    pointer-events: none;
    z-index: 999;
  }}

  header {{
    display: flex;
    justify-content: space-between;
    align-items: flex-end;
    margin-bottom: 2.5rem;
    padding-bottom: 1rem;
    border-bottom: 1px solid var(--border);
  }}

  .logo {{ font-family: var(--font-display); font-size: 2rem; font-weight: 800; color: var(--accent); letter-spacing: -1px; }}
  .logo span {{ color: var(--text); }}
  .meta {{ text-align: right; font-size: 0.72rem; color: var(--muted); line-height: 1.8; }}
  .meta strong {{ color: var(--accent); }}

  .grid {{
    display: grid;
    grid-template-columns: repeat(auto-fit, minmax(300px, 1fr));
    gap: 1.25rem;
    margin-bottom: 1.25rem;
  }}

  .panel {{
    background: var(--panel);
    border: 1px solid var(--border);
    border-radius: 8px;
    padding: 1.5rem;
    position: relative;
    overflow: hidden;
  }}

  .panel::after {{
    content: '';
    position: absolute;
    top: 0; left: 0; right: 0;
    height: 2px;
    background: linear-gradient(90deg, var(--accent), transparent);
  }}

  .panel-title {{
    font-size: 0.65rem;
    letter-spacing: 0.2em;
    text-transform: uppercase;
    color: var(--muted);
    margin-bottom: 1rem;
  }}

  /* ── Gauge ── */
  .gauge-wrap {{ position: relative; width: 130px; height: 130px; margin: 0 auto 1rem; }}
  .gauge-wrap svg {{ transform: rotate(-90deg); }}
  .gauge-bg {{ fill: none; stroke: var(--border); stroke-width: 10; }}
  .gauge-fill {{ fill: none; stroke-width: 10; stroke-linecap: round; transition: stroke-dashoffset 1s ease; }}
  .gauge-label {{
    position: absolute; inset: 0;
    display: flex; flex-direction: column;
    align-items: center; justify-content: center;
    font-family: var(--font-display);
  }}
  .gauge-pct {{ font-size: 1.8rem; font-weight: 800; }}
  .gauge-sub {{ font-size: 0.6rem; color: var(--muted); margin-top: 2px; }}
  .gauge-detail {{ text-align: center; font-size: 0.72rem; color: var(--muted); line-height: 1.9; }}

  /* ── Load ── */
  .load-grid {{ display: grid; grid-template-columns: repeat(3,1fr); gap: 0.5rem; margin-top: 0.5rem; }}
  .load-item {{ text-align: center; padding: 0.75rem 0.5rem; background: var(--bg); border-radius: 6px; }}
  .load-val {{ font-family: var(--font-display); font-size: 1.4rem; font-weight: 800; color: var(--accent); }}
  .load-lbl {{ font-size: 0.6rem; color: var(--muted); margin-top: 4px; }}
  .uptime-str {{ font-size: 0.75rem; color: var(--muted); margin-top: 1rem; text-align: center; }}

  /* ── Services ── */
  .svc-grid {{ display: flex; flex-wrap: wrap; gap: 0.5rem; }}
  .svc-badge {{
    font-size: 0.72rem; padding: 0.35rem 0.75rem;
    border: 1px solid; border-radius: 20px;
    background: rgba(255,255,255,0.03);
  }}

  /* ── SSL ── */
  .ssl-row {{ display: grid; grid-template-columns: 1fr 120px 44px 80px; gap: 0.75rem; align-items: center; margin-bottom: 0.75rem; font-size: 0.72rem; }}
  .ssl-bar-wrap {{ background: var(--bg); border-radius: 3px; height: 5px; }}
  .ssl-bar {{ height: 5px; border-radius: 3px; transition: width 1s ease; }}
  .ssl-days {{ font-weight: 700; text-align: right; }}
  .ssl-date {{ color: var(--muted); }}

  /* ── Alerts ── */
  .alert-row {{
    border-left: 3px solid;
    padding: 0.5rem 0.75rem;
    margin-bottom: 0.5rem;
    font-size: 0.7rem;
    background: rgba(255,255,255,0.02);
    border-radius: 0 4px 4px 0;
    word-break: break-all;
  }}

  footer {{
    margin-top: 2rem;
    text-align: center;
    font-size: 0.65rem;
    color: var(--muted);
    border-top: 1px solid var(--border);
    padding-top: 1rem;
  }}

  @keyframes blink {{ 0%,100%{{opacity:1}} 50%{{opacity:0.3}} }}
  .live-dot {{ display: inline-block; width: 6px; height: 6px; border-radius: 50%; background: var(--accent); animation: blink 1.5s infinite; margin-right: 6px; }}
</style>
</head>
<body>

<header>
  <div>
    <div class="logo">SYS<span>WATCH</span></div>
    <div style="font-size:0.7rem;color:var(--muted);margin-top:4px"><span class="live-dot"></span>live dashboard · auto-refresh 60s</div>
  </div>
  <div class="meta">
    <strong>{hostname}</strong><br>
    Updated: {now}<br>
    Uptime: {uptime_str}
  </div>
</header>

<div class="grid">

  <!-- Disk -->
  <div class="panel">
    <div class="panel-title">Disk Usage</div>
    <div class="gauge-wrap">
      <svg width="130" height="130" viewBox="0 0 130 130">
        <circle class="gauge-bg" cx="65" cy="65" r="55"/>
        <circle class="gauge-fill" cx="65" cy="65" r="55"
          stroke="{disk_col}"
          stroke-dasharray="{round(2*3.14159*55*disk['pct']/100)} {round(2*3.14159*55*(1-disk['pct']/100))}"/>
      </svg>
      <div class="gauge-label">
        <div class="gauge-pct" style="color:{disk_col}">{disk['pct']}%</div>
        <div class="gauge-sub">used</div>
      </div>
    </div>
    <div class="gauge-detail">
      Total: {disk['total']} &nbsp;|&nbsp; Used: {disk['used']} &nbsp;|&nbsp; Free: {disk['free']}
    </div>
  </div>

  <!-- Memory -->
  <div class="panel">
    <div class="panel-title">Memory Usage</div>
    <div class="gauge-wrap">
      <svg width="130" height="130" viewBox="0 0 130 130">
        <circle class="gauge-bg" cx="65" cy="65" r="55"/>
        <circle class="gauge-fill" cx="65" cy="65" r="55"
          stroke="{mem_col}"
          stroke-dasharray="{round(2*3.14159*55*mem['pct']/100)} {round(2*3.14159*55*(1-mem['pct']/100))}"/>
      </svg>
      <div class="gauge-label">
        <div class="gauge-pct" style="color:{mem_col}">{mem['pct']}%</div>
        <div class="gauge-sub">used</div>
      </div>
    </div>
    <div class="gauge-detail">
      Total: {mem['total']}MB &nbsp;|&nbsp; Used: {mem['used']}MB &nbsp;|&nbsp; Free: {mem['free']}MB
    </div>
  </div>

  <!-- CPU Load -->
  <div class="panel">
    <div class="panel-title">CPU Load Average</div>
    <div class="load-grid">
      <div class="load-item"><div class="load-val">{load['load1']}</div><div class="load-lbl">1 min</div></div>
      <div class="load-item"><div class="load-val">{load['load5']}</div><div class="load-lbl">5 min</div></div>
      <div class="load-item"><div class="load-val">{load['load15']}</div><div class="load-lbl">15 min</div></div>
    </div>
    <div class="uptime-str">CPU Cores: {load['cores']}</div>
  </div>

</div>

<div class="grid">

  <!-- Services -->
  <div class="panel">
    <div class="panel-title">Service Status</div>
    <div class="svc-grid">
      {svc_html}
    </div>
  </div>

  <!-- SSL -->
  <div class="panel" style="grid-column: span 2">
    <div class="panel-title">SSL Certificate Expiry</div>
    {ssl_html}
  </div>

</div>

<!-- Alerts -->
<div class="panel">
  <div class="panel-title">Recent Alerts</div>
  {alert_html}
</div>

<footer>
  SYSWATCH · linux-server-automation-scripts · generated {now}
</footer>

</body>
</html>"""


# ─── Main ─────────────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(description="Generate server health dashboard")
    parser.add_argument("--output", default="/tmp/dashboard.html", help="Output HTML file path")
    args = parser.parse_args()

    hostname = run("hostname") or "server"

    print("Collecting system data...")
    disk     = get_disk()
    mem      = get_memory()
    load     = get_load()
    uptime_s = get_uptime()
    services = get_services()
    ssl      = get_ssl_status()
    alerts   = get_recent_alerts()

    print("Generating dashboard...")
    html = generate_html(disk, mem, load, uptime_s, services, ssl, alerts, hostname)

    os.makedirs(os.path.dirname(os.path.abspath(args.output)), exist_ok=True)
    with open(args.output, "w") as f:
        f.write(html)

    print(f"✓ Dashboard saved → {args.output}")
    print(f"  Open: file://{os.path.abspath(args.output)}")

if __name__ == "__main__":
    main()
