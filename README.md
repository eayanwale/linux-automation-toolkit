# linux-automation-toolkit

A collection of standalone shell scripts for common sysadmin and DevOps tasks: disk monitoring, backup rotation, secure file transfer, and system health reporting.

## Background

These scripts started as functions embedded in a monolithic Oracle DBA toolkit I built and maintained ([oracle-bash-toolkit](https://github.com/eayanwale/Control-Script_SH)). That script worked, but everything was coupled — backup logic depended on Oracle paths, disk checks were wired to email alerts, file transfers assumed specific server naming conventions. This repo is the result of extracting, cleaning, and generalizing the most useful pieces into standalone, portable tools that work on any Linux system.

For the reasoning behind the design choices, see [docs/design-decisions.md](docs/design-decisions.md).

## What's in the repo

| Script | What it does | Key features | Origin |
|--------|-------------|--------------|--------|
| `bash/disk-check.sh` | Check disk utilization against warning/critical thresholds | getopts, Nagios exit codes (0/1/2/3), multi-mount | Extracted from `DISK_UTILIZATION()` |
| `bash/backup-rotate.sh` | Back up a directory and rotate old backups by age | --dry-run, timestamped copies, file count verification | Extracted from `BACKUP_F_D()` + `CLEANUP()` |
| `bash/scp-transfer.sh` | Transfer files to a remote server with verification | Retry with backoff, SHA-256 checksum, --dry-run | Extracted from `SCP()` |
| `bash/system-health.sh` | Quick system health snapshot (CPU, memory, disk, load, services, network) | Selective checks (-c), short mode (-s), no dependencies | New — not extracted |

## Quick start

```bash
git clone https://github.com/eayanwale/linux-automation-toolkit.git
cd linux-automation-toolkit
chmod +x bash/*.sh

# Check disk usage on root and /var with default thresholds (warn 80%, crit 90%)
./bash/disk-check.sh -d / -d /var

# Check the exit code (0=OK, 1=WARNING, 2=CRITICAL)
echo $?
```

## Script details

### disk-check.sh

Checks one or more mount points against configurable warning and critical thresholds. Exit codes follow the Nagios plugin convention so monitoring systems can interpret the result directly.

```bash
# Defaults (warn 80%, crit 90%)
./bash/disk-check.sh -d /

# Custom thresholds, multiple mounts
./bash/disk-check.sh -d / -d /var -d /backup -w 70 -c 85

# Show help
./bash/disk-check.sh -h
```

### backup-rotate.sh

Creates a timestamped backup of a source directory, then deletes backups older than the retention period. Checks disk space on the destination before starting. Verifies the copy by comparing file counts.

```bash
# Back up /etc with 7-day retention (default)
./bash/backup-rotate.sh -s /etc -b /backup/etc

# 30-day retention, 85% disk threshold
./bash/backup-rotate.sh -s /var/log -b /backup/logs -r 30 -t 85

# Preview what would happen without making changes
./bash/backup-rotate.sh -s /etc -b /backup/etc --dry-run

# Cron job: back up /etc nightly at 2 AM, keep 14 days
# 0 2 * * * /opt/scripts/backup-rotate.sh -s /etc -b /backup/etc -r 14
```

### scp-transfer.sh

Transfers a file or directory to a remote server via SCP. Tests SSH connectivity before transferring, retries on failure with configurable backoff, and verifies single-file transfers with SHA-256 checksums.

```bash
# Basic transfer
./bash/scp-transfer.sh -s /data/export.dmp -u oracle -H dbserver -p /imports

# With SSH key and extra retries
./bash/scp-transfer.sh -s /backup/db.tar.gz -u ec2-user -H 10.0.1.5 -p /data -i ~/.ssh/aws.pem -r 5

# Test connectivity without transferring
./bash/scp-transfer.sh --dry-run -s /data/file.tar -u admin -H prod01 -p /tmp
```

### system-health.sh

Runs CPU, memory, disk, load, service, and network checks in one pass and outputs a readable report. Designed as the first thing you'd run after SSH-ing into an unfamiliar box.

```bash
# Full report
./bash/system-health.sh

# Short mode (one line per section)
./bash/system-health.sh -s

# Only check disk and memory
./bash/system-health.sh -c disk,mem
```

## Conventions

All four scripts follow consistent patterns:

- **Argument parsing** with POSIX `getopts` — self-documenting `-h` help, no positional argument guessing
- **Nagios-compatible exit codes** — 0 (OK), 1 (WARNING), 2 (CRITICAL), 3 (UNKNOWN) where applicable, so the scripts plug into monitoring systems without wrappers
- **`--dry-run`** on any script that modifies state (backup-rotate, scp-transfer) — shows what would happen without doing it
- **Timestamped log output** — every action is logged with `[YYYY-MM-DD HH:MM:SS]` for traceability in cron jobs and pipelines
- **No external dependencies** beyond coreutils — no pip installs, no apt packages, runs on any standard Linux box
- **Logic separated from notification** — scripts report status via exit codes and stdout; the caller decides how to alert (email, Slack, PagerDuty, etc.)

## Roadmap

- `python/log-analyzer.py` — Python log parser for syslog and Apache access logs (error counts, top sources, hourly distribution)
- GitHub Actions CI — ShellCheck linting and Bats unit tests on every push
- Test fixtures — sample log files and expected outputs for automated verification
- Docker packaging — run the toolkit in a container for consistent environments
- Expanded system-health checks — process monitoring, certificate expiry, open file descriptors
