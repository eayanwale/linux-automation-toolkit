#!/usr/bin/env bash

set -euo pipefail

LOG_FILE="../log/backup-rotate.log"
if [ -f "$LOG_FILE" ] && [ $(wc -l < "$LOG_FILE") -gt 100 ]; then
    mv "$LOG_FILE" "../log/backup-rotate-$(date +%Y-%m-%d-%H%M%S).log"
    find ../log/ -name "backup-rotate-*.log" -mtime +100 -delete
fi

# Exit codes
readonly EXIT_OK=0
readonly EXIT_SRC_FAIL=1
readonly EXIT_BACKUP_FAIL=2
readonly EXIT_ROTATE_FAIL=3
readonly EXIT_DRYRUN=4

# Usage function to display help message
usage() {
    echo "Usage: $0 [-d] -s <source> -b <backup_dir> [-r days] [-t threshold%] [-h]"
    echo "Back up a directory with timestamped copies and rotate old backups."
    echo "Required:"
    echo "  -s <source_dir>   Directory/file to back up."
    echo "  -b <backup_dir>   Directory where backups will be stored."
    echo "Optional:"
    echo "  -r <days>         Rotate backups older than this many days (default: 7)."
    echo "  -t <threshold%>   Rotate backups if disk usage exceeds this percentage (default: 80)."
    echo "  -d                Perform a dry run, showing what would be done without making any changes."
    echo "  -h                Show this help message"
}

log() { 
    echo "[$TS] $*"
    echo "[$TS] $*" >> "$LOG_FILE"
}

# Default values
declare -a SOURCE=()
ROTATE_DAYS=7
THRESHOLD=80
DRY_RUN=false
TIME=$(date +%Y-%m-%d)
TS=$(date +%Y-%m-%d-%H:%M:%S)

# Parse long options
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=true; shift ;;
        --help)    usage; exit 0 ;;
    esac
done

# Parse command-line options
while getopts "ds:b:r:t:h" opt; do
    case $opt in
        d) DRY_RUN=true ;;
        s) SOURCE+=("$OPTARG") ;;
        b) BACKUP_DIR="$OPTARG" ;;
        r) ROTATE_DAYS="$OPTARG" ;;
        t) THRESHOLD="$OPTARG" ;;
        h) usage; exit 0 ;;
        ?) echo "Invalid option"; usage; exit 1;;
    esac
done

if [ -z "$BACKUP_DIR" ]; then
    echo "Error: Backup directory is required. Use -b <backup_dir> to specify it."
    usage
    exit 1
elif [ ${#SOURCE[@]} -eq 0 ]; then
    echo "Error: At least one source directory/file is required. Use -s <source_dir> to specify it."
    usage
    exit 1
fi


# Dry run mode
if [ "$DRY_RUN" = true ]; then
    echo "${BACKUP_DIR} is $(df -P $BACKUP_DIR 2>/dev/null | awk 'NR==2 {gsub("%","",$5); print $5}')% full (threshold: ${THRESHOLD}%)."

    if [ ! -d "$BACKUP_DIR/$TIME" ]; then
        echo "[DRY RUN]: create backup directory $BACKUP_DIR/$TIME"
    else
        echo "[DRY RUN]: backup directory $BACKUP_DIR/$TIME already exists"
    fi

    echo "[DRY RUN]: archive and copy the following:"
    for input in "${SOURCE[@]}"; do
            echo "  $input -> $BACKUP_DIR/$TIME/$(basename "$input").tar.gz"
    done

    dry_run_rotate=$(find "$BACKUP_DIR" -mtime +$ROTATE_DAYS)
    if [ -z "$dry_run_rotate" ]; then
        echo "[DRY RUN]: no backups older than $ROTATE_DAYS days to rotate."
    else
        count=$(echo "$dry_run_rotate" | wc -l)

        echo "[DRY RUN]: delete $count backups older than $ROTATE_DAYS days: "
        echo "$dry_run_rotate"
    fi

    echo "Dry run complete. No changes have been made."
    exit $EXIT_DRYRUN
fi

# Disk check for backup directory
echo "Checking disk usage for backup directory $BACKUP_DIR..."

disk_check=$(df -P $BACKUP_DIR 2>/dev/null | awk 'NR==2 {gsub("%","",$5); print $5}')
if [ -z "$disk_check" ]; then
    log "Unable to determine disk usage for $BACKUP_DIR."
    exit $EXIT_BACKUP_FAIL
elif [[ "$disk_check" -gt "$THRESHOLD" ]]; then
    log "Disk usage for $BACKUP_DIR is over $THRESHOLD%."
    exit $EXIT_BACKUP_FAIL
else
    log "Disk check passed: ${disk_check}% used (threshold: ${THRESHOLD}%)."
fi

# Create backup directory if it doesn't exist
if [ ! -d "$BACKUP_DIR/$TIME" ]; then
    echo "Backup directory $BACKUP_DIR/$TIME does not exist. Creating it..."

    mkdir -p "$BACKUP_DIR/$TIME"

    if [ $? -ne 0 ]; then
        log "Failed to create backup directory $BACKUP_DIR/$TIME."
        exit $EXIT_BACKUP_FAIL
    fi
fi

# Archive source to backup directory with timestamp
for input in "${SOURCE[@]}"; do

    echo "Archiving $input to $BACKUP_DIR/$TIME/..."

    BACKUP_NAME="$(basename "$input").tar.gz"
    if ! tar -czf "$BACKUP_DIR/$TIME/$BACKUP_NAME" -C "$(dirname "$input")" "$(basename "$input")"; then
        log "Failed to create backup $BACKUP_DIR/$TIME/$BACKUP_NAME"
        exit $EXIT_BACKUP_FAIL
    fi

    log "Backup created successfully: $BACKUP_DIR/$TIME/$BACKUP_NAME"
    echo
done

echo "--- Backup complete ---"
ls -lh "$BACKUP_DIR/$TIME"

# Rotate old backups
echo "Rotating backups older than $ROTATE_DAYS days or if disk usage exceeds $THRESHOLD%..."
if ! find "$BACKUP_DIR" -maxdepth 1 -mindepth 1 -type d -mtime +$ROTATE_DAYS -exec rm -rf {} \; then
    if ! [[ "$ROTATE_DAYS" =~ ^[0-9]+$ ]] || (( ROTATE_DAYS < 1 )); then
        echo "Error: -r must be a positive integer, got '$ROTATE_DAYS'"
        exit 1
    fi
    log "Failed to rotate old backups in $BACKUP_DIR."
    exit $EXIT_ROTATE_FAIL
fi

log "Old backups rotated successfully."
exit $EXIT_OK