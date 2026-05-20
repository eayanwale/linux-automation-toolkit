#!/usr/bin/env bash

set -euo pipefail

LOG_FILE="../log/backup-rotate.log"
if [ -f "$LOG_FILE" ] && [ "$(wc -l < "$LOG_FILE")" -gt 100 ]; then
    mv "$LOG_FILE" "../log/backup-rotate-$(date +%Y-%m-%d-%H%M%S).log"
    find ../log/ -name "backup-rotate-*.log" -mtime +100 -delete
fi

# Exit codes
readonly EXIT_OK=0
readonly EXIT_SRC_FAIL=1
readonly EXIT_BACKUP_FAIL=2
readonly EXIT_ROTATE_FAIL=3
readonly EXIT_DRYRUN=4

version() { VERSION="v1.0.0"; echo $VERSION; }

# Usage function to display help message
usage() {
    echo "Usage: $0 [-d] -s <source> -b <backup_dir> [-r days] [-t threshold%] [-h]"
    echo
    echo "Back up a directory with timestamped copies and rotate old backups."
    echo
    echo "Required:"
    echo "  -s <source_dir>     Directory/file to back up."
    echo "  -b <backup_dir>     Directory where backups will be stored."
    echo
    echo "Optional:"
    echo "  -r <days>           Rotate backups older than this many days (default: 7)."
    echo "  -t <threshold%>     Rotate backups if disk usage exceeds this percentage (default: 80)."
    echo "  -d / --dry-run      Perform a dry run, showing what would be done without making any changes."
    echo "  -v / --version      Show version"
    echo "  -h / --help         Show this help message"
    echo
    echo "Exit codes:"
    echo "  0   Success"
    echo "  1   Source missing or invalid arguments"
    echo "  2   Backup failure (disk threshold exceeded, mkdir or tar failed)"
    echo "  3   Rotation failure"
    echo "  4   Dry run completed (no changes made)"
    echo
    echo "Examples:"
    echo "  # Basic backup with defaults (7 days retention, 80% disk threshold)"
    echo "  $0 -s /etc/nginx -b /var/backups"
    echo
    echo "  # Multiple sources with custom retention"
    echo "  $0 -s /etc/nginx -s /var/www/html -b /mnt/backup -r 30"
    echo
    echo "  # Dry run to preview what would happen"
    echo "  $0 -d -s /home/deploy -b /mnt/backup -r 14 -t 90"
    echo
    echo "  # Tighter disk threshold for a small volume"
    echo "  $0 -s /opt/app/data -b /backup -t 60"
}

log() { 
    echo "[$TS] $*"
    echo "[$TS] $*" >> "$LOG_FILE"
}

error() { echo "ERROR: $*"; }

success() { echo "SUCCESS: $*"; }

dry() { echo "[DRY RUN] $*"; }

list_args() {
    echo "=== backup-rotate.sh $(version) ==="
    log "Source(s):"
    for source in "${SOURCE[@]}"; do log "- $source"; done
    log "Backup dir:        $BACKUP_DIR"
    log "Timestamp dir:     $BACKUP_DIR/$TIME"
    log "Rotate days:       $ROTATE_DAYS"
    log "Disk threshold:    ${THRESHOLD}%"
    log "Dry run:           $DRY_RUN"
}

# Default values
declare -a SOURCE=()
BACKUP_DIR=""
ROTATE_DAYS=7
THRESHOLD=80
DRY_RUN=false
TIME=$(date +%Y-%m-%d)
TS=$(date +%Y-%m-%d-%H:%M:%S)

# Parse long options
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=true; shift ;;
        --version) version; exit 0 ;;
        --help)    usage; exit 0 ;;
    esac
done

# Parse command-line options
while getopts "dvs:b:r:t:h" opt; do
    case $opt in
        d) DRY_RUN=true ;;
        s) SOURCE+=("$OPTARG") ;;
        b) BACKUP_DIR="$OPTARG" ;;
        r) ROTATE_DAYS="$OPTARG" ;;
        t) THRESHOLD="$OPTARG" ;;
        v) version; exit 0 ;;
        h) usage; exit 0 ;;
        ?) error "Invalid option"; usage; exit 1;;
    esac
done

if [ -z "$BACKUP_DIR" ]; then
    error "Backup directory is required. Use -b <backup_dir> to specify it."
    usage
    exit $EXIT_SRC_FAIL
elif [ ${#SOURCE[@]} -eq 0 ]; then
    error "At least one source directory/file is required. Use -s <source_dir> to specify it."
    usage
    exit $EXIT_SRC_FAIL
fi


# Dry run mode
if [ "$DRY_RUN" = true ]; then
    list_args; echo
    log "${BACKUP_DIR} is $(df -P $BACKUP_DIR 2>/dev/null | awk 'NR==2 {gsub("%","",$5); print $5}')% full (threshold: ${THRESHOLD}%)."

    if [ ! -d "$BACKUP_DIR/$TIME" ]; then
        dry "create backup directory $BACKUP_DIR/$TIME"
    else
        dry "backup directory $BACKUP_DIR/$TIME already exists"
    fi

    dry "archive and copy the following:"
    for input in "${SOURCE[@]}"; do
            echo "  $input -> $BACKUP_DIR/$TIME/$(basename "$input").tar.gz"
    done

    dry_run_rotate=$(find "$BACKUP_DIR" -mtime +$ROTATE_DAYS)
    if [ -z "$dry_run_rotate" ]; then
        dry "no backups older than $ROTATE_DAYS days to rotate."
    else
        count=$(echo "$dry_run_rotate" | wc -l)

        dry "delete $count backups older than $ROTATE_DAYS days: "
        echo "  $dry_run_rotate"
    fi

    log "Dry run complete. No changes have been made."
    exit $EXIT_DRYRUN
fi

# Disk check for backup directory
log "Checking disk usage for backup directory $BACKUP_DIR..."

disk_check=$(df -P $BACKUP_DIR 2>/dev/null | awk 'NR==2 {gsub("%","",$5); print $5}')
if [ -z "$disk_check" ]; then
    error "Unable to determine disk usage for $BACKUP_DIR."
    exit $EXIT_BACKUP_FAIL
elif [[ "$disk_check" -gt "$THRESHOLD" ]]; then
    error "Disk usage for $BACKUP_DIR is over $THRESHOLD%."
    exit $EXIT_BACKUP_FAIL
else
    success "Disk check passed: ${disk_check}% used (threshold: ${THRESHOLD}%)."
fi

# Create backup directory if it doesn't exist
if [ ! -d "$BACKUP_DIR/$TIME" ]; then
    log "Backup directory $BACKUP_DIR/$TIME does not exist. Creating it..."

    mkdir -p "$BACKUP_DIR/$TIME"

    if [ $? -ne 0 ]; then
        error "Failed to create backup directory $BACKUP_DIR/$TIME."
        exit $EXIT_BACKUP_FAIL
    fi
fi

# Archive source to backup directory with timestamp
for input in "${SOURCE[@]}"; do

    log "Archiving $input to $BACKUP_DIR/$TIME/..."

    BACKUP_NAME="$(basename "$input").tar.gz"
    if ! tar -czf "$BACKUP_DIR/$TIME/$BACKUP_NAME" -C "$(dirname "$input")" "$(basename "$input")"; then
        error "Failed to create backup $BACKUP_DIR/$TIME/$BACKUP_NAME"
        exit $EXIT_BACKUP_FAIL
    fi

    success "Backup created: $BACKUP_DIR/$TIME/$BACKUP_NAME"
    echo
done

log "--- Backup complete ---"
ls -lh "$BACKUP_DIR/$TIME"

# Rotate old backups
log "Rotating backups older than $ROTATE_DAYS days or if disk usage exceeds $THRESHOLD%..."
old_dirs=$(find "$BACKUP_DIR" -maxdepth 1 -mindepth 1 -type d -mtime +"$ROTATE_DAYS")
if [[ -n "$old_dirs" ]]; then
    echo "$old_dirs" | while read -r dir; do
        rm -rf "$dir"
    done
else
    exit $EXIT_ROTATE_FAIL

success "Old backups rotated."
exit $EXIT_OK