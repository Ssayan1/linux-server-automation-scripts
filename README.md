# linux-server-automation-scripts

Practical Linux sysadmin automation — backup, health monitoring, log analysis, and user management.

```
linux-server-automation-scripts/
├── backup.sh          # Folder + MySQL/PostgreSQL backup with retention
├── health_check.sh    # Disk / memory / CPU / service monitor with email alerts
├── linux_admin.py     # Log analyser + user/group management CLI
└── README.md
```

---

## backup.sh

Backs up directories and databases, writes SHA-256 checksums, and prunes old backups.

**Quick start**

```bash
chmod +x backup.sh

# Back up /etc and /home (defaults)
sudo ./backup.sh

# With MySQL enabled
MYSQL_ENABLED=true MYSQL_USER=root MYSQL_PASS=secret \
  MYSQL_DATABASES="myapp wordpress" sudo ./backup.sh

# With PostgreSQL enabled
PSQL_ENABLED=true PSQL_DATABASES="myapp" sudo ./backup.sh

# Preview without writing anything
sudo ./backup.sh --dry-run
```

**Key environment variables**

| Variable | Default | Description |
|---|---|---|
| `BACKUP_ROOT` | `/var/backups/server` | Where backups are stored |
| `RETENTION_DAYS` | `7` | Days to keep old backups |
| `LOG_FILE` | `/var/log/backup.log` | Log output path |
| `MYSQL_ENABLED` | `false` | Enable MySQL dumps |
| `MYSQL_DATABASES` | *(blank = all)* | Space-separated DB names |
| `PSQL_ENABLED` | `false` | Enable PostgreSQL dumps |
| `PSQL_DATABASES` | *(blank = all)* | Space-separated DB names |

**Cron example** (nightly at 02:00)

```cron
0 2 * * * MYSQL_ENABLED=true MYSQL_PASS=secret /opt/scripts/backup.sh >> /var/log/backup.log 2>&1
```

---

## health_check.sh

Checks disk usage, memory, CPU load average, systemd service status, and zombie processes.
Logs every run and optionally emails alerts.

**Quick start**

```bash
chmod +x health_check.sh
sudo ./health_check.sh
sudo ./health_check.sh --email ops@company.com
sudo ./health_check.sh --log /var/log/myserver_health.log
```

**Thresholds (edit at top of file)**

| Metric | Warn | Critical |
|---|---|---|
| Disk usage | 80 % | 90 % |
| Memory usage | 80 % | 95 % |
| 1-min load avg | 2.0 | 5.0 |

**Exit codes**

| Code | Meaning |
|---|---|
| `0` | All healthy |
| `1` | Warnings only |
| `2` | At least one critical |

**Cron example** (every 15 minutes)

```cron
*/15 * * * * /opt/scripts/health_check.sh --email ops@company.com
```

---

## linux_admin.py

A Python CLI with two capabilities: **log analysis** and **user/group management**.

```bash
chmod +x linux_admin.py
python3 linux_admin.py --help
```

### Log analysis

```bash
# Count ERROR lines in a log
python3 linux_admin.py analyze /var/log/syslog

# Filter for WARNINGS, look at last 1000 lines, save a report
python3 linux_admin.py analyze /var/log/nginx/error.log \
    --level WARNING --tail 1000 --report /tmp/nginx_report.txt

# Works with any log: syslog, journald, nginx, apache, python apps…
python3 linux_admin.py analyze /var/log/auth.log --level ERROR
```

Sample output:

```
━━━ Log Analysis: /var/log/syslog ━━━
  Total lines  : 48,291
  ERROR        : 12
  WARNING      : 204
  INFO         : 47,801
  DEBUG        : 274

Top error messages
    5×  Connection refused: 127.0.0.1:3306
    4×  Failed password for invalid user admin
    3×  Out of memory: Kill process 1821
```

### User & group management (requires root / sudo)

```bash
# Add a user with home directory, shell, and groups
sudo python3 linux_admin.py adduser alice \
    --comment "Alice Smith" --shell /bin/bash --groups sudo,docker

# Create a group with a specific GID
sudo python3 linux_admin.py addgroup developers --gid 1500

# Add an existing user to more groups
sudo python3 linux_admin.py usermod alice --add-groups developers,www-data

# List all human users (UID ≥ 1000)
python3 linux_admin.py listusers --min-uid 1000

# List all groups
python3 linux_admin.py listgroups
```

---

## Requirements

| Script | Requirements |
|---|---|
| `backup.sh` | bash ≥ 4, `tar`, `gzip`; `mysqldump` for MySQL; `pg_dump` for PostgreSQL |
| `health_check.sh` | bash ≥ 4, `systemctl`, `bc`, `df`, `free`; `mail` or `sendmail` for email alerts |
| `linux_admin.py` | Python 3.8+, stdlib only (no pip installs needed) |

---

## License

MIT
