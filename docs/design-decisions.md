# Design Decisions

This document explains the technical choices behind the scripts in this repo — what changed from the original code, why, and what tradeoffs were made.

## Where these scripts came from

The scripts in `bash/` were extracted from a single 500+ line bash script I built for Oracle DBA work: [Control-Script_SH v1.19](https://github.com/eayanwale/Control-Script_SH). That script handled everything — disk monitoring, file backups, SCP transfers, Oracle Data Pump exports/imports, local and cloud database migrations, and cleanup. It worked, but it had structural problems:

- Every function depended on environment variables sourced from a secrets file at a hardcoded path
- Backup logic was tied to Oracle-specific directory structures (`/backup/${RUNNER}/$TS/backup_dir`)
- Alerts were inline `mailx` calls — if you didn't have `mailx` configured, the script still ran but silently failed to notify
- The SCP function detected cloud vs on-prem servers by string-matching hostnames for "amazon", "ec2", or "aws"
- No argument validation beyond checking `$#` — wrong argument order produced wrong behavior with no error message
- No way to test individual functions without sourcing the entire script and setting up the full environment

The goal of this repo was to take the most broadly useful functions, strip out the Oracle coupling, and make each one a standalone tool that works on any Linux system.

## Decision 1: Standalone scripts instead of a multi-tool

The original used a case-statement dispatcher: you ran `./script.sh backup_f_d` or `./script.sh cleanup` and the case block routed to the right function. That pattern has a real problem — every invocation loads every function, every variable, every dependency. If you just want to check disk space, you're still sourcing Oracle credentials and defining database import logic.

Standalone scripts fix this. Each one is self-contained: its own argument parsing, its own help text, its own exit codes. This means:

- Cron can call `disk-check.sh` without loading backup or transfer code
- A monitoring system can run `system-health.sh` without SSH keys or database credentials on the box
- Each script can be copied to a different server independently
- Testing is simpler — you test one script in isolation, not a monolith

This follows the Unix philosophy for a practical reason, not an ideological one: small tools that do one thing are easier to deploy, test, and debug.

## Decision 2: getopts over positional arguments

The original functions used positional arguments:

```bash
DISK_UTILIZATION "${DISKS}" "${THRESHOLD}" "${RUNNER}"
BACKUP_F_D ${SRC} ${RUNNER}
SCP ${SRC} ${DST_USER} ${DST_SERV} ${DST_PATH} ${RUNNER}
```

This works when you're the only person calling the function and you wrote it yesterday. It breaks when:

- You come back in 3 months and forget whether the threshold or the disk path comes first
- You want to add an optional parameter (like `--dry-run`) without breaking every existing call
- Someone else tries to use your script and has to read the source to understand the argument order

`getopts` solves all three. `-d /backup -w 80 -c 90` is self-documenting. Adding `-v` for verbose doesn't break existing callers. And `-h` generates help text automatically.

I chose POSIX `getopts` over GNU `getopt` because `getopts` is built into bash and works identically on Linux, macOS, and any POSIX system. GNU `getopt` supports long options (`--warning` instead of `-w`) but its behavior differs between Linux and macOS, which creates portability bugs. The one exception is `--dry-run` — I pre-process it out of the argument list before `getopts` runs, which is a common pattern when you need one or two long options but don't want to pull in GNU `getopt`.

## Decision 3: Nagios-compatible exit codes

The original used two exit codes: 0 for success, 1 for failure. The portfolio versions use:

| Code | Meaning |
|------|---------|
| 0 | OK — everything is fine |
| 1 | WARNING — something needs attention but isn't critical |
| 2 | CRITICAL — immediate action required |
| 3 | UNKNOWN — bad input, missing mount point, or unexpected error |

This convention comes from the [Nagios Plugin Development Guidelines](https://nagios-plugins.org/doc/guidelines.html). Most monitoring systems — Nagios, Icinga, Zabbix, Sensu, and Prometheus (via the blackbox exporter) — interpret these exit codes directly. Using them means `disk-check.sh` can be registered as a Nagios check command with zero wrapper code:

```
command[check_disk]=/opt/scripts/disk-check.sh -d / -w 80 -c 95
```

I learned this convention through research, not job experience. But it's the kind of thing that signals "this person understands how ops tooling fits together" rather than "this person wrote a script that works on their laptop."

## Decision 4: Separating logic from notification

The original script had inline `mailx` calls after every significant action:

```bash
mailx -s "WARNING: [${RUNNER}] Disk Utilization Exceeded!" ${stack_email} <<EOF
-------ALERT-------
RUNNER: ${RUNNER}
Disk Utilization on ${disk} is ${disk_check}
EOF
```

This created two problems. First, `mailx` is a dependency — if the server doesn't have it configured (which is increasingly common in cloud environments), the alert silently fails. Second, it hardcodes the notification method. What if the team uses Slack? PagerDuty? A webhook? You'd have to edit the script itself.

The portfolio versions separate the decision ("is the disk full?") from the action ("tell someone"). The script reports status through exit codes and stdout. The caller decides how to alert:

```bash
# Cron + email
./disk-check.sh -d / -w 80 | mail -s "Disk Report" ops@company.com

# Monitoring system reads exit code directly
# No wrapper needed

# Custom wrapper for Slack
if ! ./disk-check.sh -d / -w 80 -c 95; then
    curl -X POST "$SLACK_WEBHOOK" -d '{"text":"Disk warning on prod01"}'
fi
```

This is the same principle behind Unix pipes — small tools that output text, connected by the caller.

## Decision 5: --dry-run on destructive scripts

`backup-rotate.sh` deletes old backup directories. `scp-transfer.sh` pushes files to remote servers. Both of these modify state — once they run, you can't easily undo the result.

A `--dry-run` flag shows what *would* happen without doing it. This isn't a nice-to-have; it's a safety mechanism that every state-modifying ops tool should have. The pattern exists across the industry:

- `terraform plan` before `terraform apply`
- `ansible-playbook --check` before the real run
- `rsync -n` (or `--dry-run`) before the actual sync
- `rm -i` for interactive confirmation (a weaker version of the same idea)

The implementation is straightforward — wrap every side-effecting call (mkdir, cp, rm, scp) in an `if [[ "${DRY_RUN}" == "true" ]]` guard that logs the action instead of executing it. The exit code for a dry run is 2, distinct from success (0) and failure (1), so calling scripts can distinguish "completed successfully" from "would have completed successfully."

## Decision 6: cp -a instead of cp -r in backup-rotate

The original used `cp -r` to copy directories. The portfolio version uses `cp -a`.

The difference: `-r` copies recursively but may change file permissions and doesn't preserve symlinks, timestamps, or ownership. `-a` preserves everything — permissions, timestamps, ownership, symlinks, extended attributes.

This matters for configuration backups. If you back up `/etc` with `cp -r` and later restore it, files like `/etc/shadow` might end up with wrong permissions (world-readable instead of 640), which breaks authentication or creates a security vulnerability. `-a` ensures the backup is a faithful copy, not just a content copy.

Small detail, but it's the kind of thing a code reviewer notices.

## Decision 7: SSH connectivity test, not just ping

The original `SCP()` function checked reachability with `ping -q -c 1 -W 3`. This proves ICMP connectivity but not SSH availability — a host can respond to ping but have:

- `sshd` stopped or crashed
- A firewall blocking port 22
- Key authentication misconfigured
- An expired or rejected host key

The portfolio version does both: a quick ICMP ping (non-fatal if it fails, since some networks drop ICMP) followed by `ssh -o BatchMode=yes user@host "exit 0"`, which tests the full authentication chain. If the SSH test fails, the script reports the failure and suggests what to check (hostname, SSH key, user permissions, firewall rules) instead of waiting 3 minutes for `scp` to time out with a cryptic error.

## Decision 8: Removing the cloud/on-prem hostname detection

The original SCP function had this logic:

```bash
if [[ ${DST_SERV} == *"amazon"* || ${DST_SERV} == *"ec2"* || ${DST_SERV} == *"aws"* ]]
then
    # cloud path: use -i pem_key
else
    # on-prem path: use -o HostKeyAlgorithms=+ssh-rsa
fi
```

This worked for my specific lab setup where cloud servers had AWS-style hostnames and on-prem servers used internal DNS names. It breaks everywhere else: GCP instances, Azure VMs, custom DNS, or AWS servers behind a bastion with an internal hostname.

The portfolio version eliminates the branch entirely. If you need a key, pass `-i keyfile`. If you don't, SSH uses its default agent or key lookup. One code path instead of two, and it works with any server regardless of hostname.

The `HostKeyAlgorithms=+ssh-rsa` override was also removed. That's a workaround for older servers that only support RSA host keys — it belongs in `~/.ssh/config` for that specific host, not hardcoded in a transfer script.

## What I'd do differently

- **backup-rotate.sh should support compression.** Right now it copies directories as-is. Adding `tar -czf` before the copy would save significant disk space, especially for log backups. I skipped it to keep the script focused on backup + rotation, but it's the obvious next feature.

- **scp-transfer.sh should offer an rsync mode.** `rsync` does delta transfers (only sending changed bytes), has built-in verification, and can resume interrupted transfers. It's better than `scp` for almost every real-world use case. I kept `scp` because that's what the original used and the point was to show iterative improvement, not a full rewrite.

- **system-health.sh's CPU measurement blocks for 1 second.** It reads `/proc/stat` twice with a `sleep 1` between snapshots. That's fine for a standalone health check, but if you're running dozens of checks in sequence (or calling this from a monitoring loop), the blocking sleep adds up. A non-blocking approach would read `/proc/stat` once and compare against a cached previous reading, but that requires persistent state between runs.

- **No tests yet.** Each script should have a Bats test file that verifies argument parsing, exit codes, and output format. That's in the roadmap — the CI pipeline will run ShellCheck linting and Bats tests on every push.