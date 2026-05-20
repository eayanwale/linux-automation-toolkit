#!/usr/bin/env bash

set -euo pipefail

LOG_FILE="../log/scp-transfer.log"
if [ -f "$LOG_FILE" ] && [ "$(wc -l < "$LOG_FILE")" -gt 100 ]; then
    mv "$LOG_FILE" "../log/scp-transfer-$(date +%Y-%m-%d-%H%M%S).log"
    find ../log/ -name "scp-transfer-*.log" -mtime +100 -delete
fi

# Exit codes
readonly SUCCESS=0
readonly FAILURE=1
readonly BAD_ARGS=2
readonly HOST_UNREACHABLE=3
readonly EXIT_DRYRUN=4

version() { VERSION="v1.0.0"; echo $VERSION; }

usage() {
    echo "Usage: $0 [-d] -s <source> -u <user> -H <host> -p <remote_path> [options]"
    echo
    echo "Transfer files using scp with optional dry run mode."
    echo
    echo "Required:"
    echo "  -s <source>         Local file/directory to transfer."
    echo "  -u <user>           Remote user"
    echo "  -H <host>           Remote host"
    echo "  -p <remote_path>    Remote path where the file/directory will be transferred."
    echo
    echo "Options:"
    echo "  -i KEY              SSH identity file for authentication."
    echo "  -r N                Number of retries on failure (default: 3)."
    echo "  -t SECONDS          Timeout in seconds for each transfer attempt (default: 30)."
    echo "  -d / --dry-run      Perform a dry run, showing what would be done without making any changes."
    echo "  --no-progress       Disable scp progress output for cleaner logs."
    echo "  --no-verify         Disable sha256 checksum verification (for larger files)."
    echo "  -v / --version      Show version"
    echo "  -h / --help         Show this help message"
    echo
    echo "Exit codes:"
    echo "  0   Success"
    echo "  1   Transfer or verification failure"
    echo "  2   Invalid or missing arguments"
    echo "  3   Host unreachable or SSH authentication failed"
    echo "  4   Dry run completed (no files transferred)"
    echo
    echo "Examples:"
    echo "  # Basic transfer"
    echo "  $0 -s ./report.tar.gz -u deploy -H 10.0.0.5 -p /var/backups"
    echo
    echo "  # Multiple sources with an identity file"
    echo "  $0 -s ./app.conf -s ./app.service -u deploy -H host.example.com \\"
    echo "     -p /etc/app -i ~/.ssh/deploy_key"
    echo
    echo "  # Dry run with custom retries and timeout"
    echo "  $0 -d -s ./build/ -u ci -H build.internal -p /srv/artifacts -r 5 -t 60"
    echo
    echo "  # Quiet transfer of a large file, skipping checksum verification"
    echo "  $0 -s ./image.iso -u admin -H nas.local -p /volume1/iso \\"
    echo "     --no-progress --no-verify"
}

log() { 
    local TS
    TS=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$TS] $*"
    echo "[$TS] $*" >> "$LOG_FILE"
}

error() { echo "ERROR: $*"; }

success() { echo "SUCCESS: $*"; }

dry() { echo "[DRY RUN] $*"; }

list_args() {
    echo "=== scp-transfer.sh v1.0.0 ==="
    log "Source file(s):"
    for source in "${SOURCE[@]}"; do log "- $source"; done
    log "Destination:       $REMOTE_USER@$HOST:$REMOTE_PATH"
    log "Identity:          $IDENTITY_FILE"
    log "Retries:           $RETRIES"
    log "No-verify:         $NO_VERIFY"
    log "Dry run:           $DRY_RUN"
    log "No-progress:       $NO_PROGRESS"
    log "Timeout:           $TIMEOUT"
}

# Check if host is reachable and SSH authentication works
check_host() {
    log "Pinging $HOST..."
    if ! ping -c 1 -W 1 "$HOST" &> /dev/null; then
        log "ICMP ping to $HOST failed (may be blocked by firewall, continuing to SSH test)"
    fi
    
    log "Testing SSH connectivity to $REMOTE_USER@$HOST..."
    if ! ssh -q logLevel QUIET "${options[@]}" "$REMOTE_USER@$HOST" "exit 0"; then
        error "Unable to authenticate to $HOST with user $REMOTE_USER."
        return $HOST_UNREACHABLE
    else
        success "SSH connection confirmed."
        return $SUCCESS
    fi
}

do_transfer() {
    local attempt=1

    while (( attempt < RETRIES )); do
        log "Transfer attempt $attempt of $RETRIES..." 
        
        local -a scp_cmd+=(scp -r)
        [[ "$NO_PROGRESS" == true ]] && scp_cmd+=( -q )
        scp_cmd+=("${options[@]}" "${SOURCE[@]}" "$REMOTE_USER@$HOST:$REMOTE_PATH")

        if "${scp_cmd[@]}"; then
            success "Transfer successful."
            return $SUCCESS
        fi

        error "Transfer failed."
        if (( attempt <= RETRIES )); then
            local wait=$(( 5 * attempt ))
            log "Retrying in ${wait}s..."
            sleep "$wait"
        fi
        (( attempt ++ ))
    done

    error "Transfer failed after ${RETRIES} attempts."
    return $FAILURE
}

verify_transfer() {
    for file in "${SOURCE[@]}"; do
        [[ -d "$file" ]] && log "Skipping checksum for directory: $file"; continue
       
        local local_checksum
        local_checksum=$(sha256sum "$file" | awk '{print $1}')
        local remote_checksum
        remote_checksum=$(ssh "${options[@]}" "$REMOTE_USER@$HOST" \
            "sha256sum '$REMOTE_PATH/$(basename "$file")'" 2>/dev/null | awk '{print $1}')

        if [ "$local_checksum" != "$remote_checksum" ]; then
            log; error "Checksum mismatch (local: $local_checksum remote: $remote_checksum)"
            return $FAILURE
        fi
        log "Verified: $(basename "$file") - $local_checksum"
    done
    success "All checksums verified"
    return $SUCCESS
}

# Variable initialization
declare -a SOURCE=()
RETRIES=3
TIMEOUT=30
DRY_RUN=false
NO_PROGRESS=false
NO_VERIFY=false
IDENTITY_FILE=""

# SSH options builder
declare -ga options=()
options+=( -o "ConnectTimeout=$TIMEOUT" -o BatchMode=yes )
[[ -n "${IDENTITY_FILE}" ]] && options+=( -i "${IDENTITY_FILE}" )

# Parse long options
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=true; shift ;;
        --no-progress) NO_PROGRESS=true; shift ;;
        --no-verify) NO_VERIFY=true; shift ;;
        --version) version; exit 0 ;;
        --help)    usage; exit 0 ;;
    esac
done

# Parse command-line options
while getopts "dvs:u:H:p:i:r:t:h" opt; do
    case $opt in
        d) DRY_RUN=true ;;
        s) SOURCE+=("$OPTARG") ;;
        u) REMOTE_USER="$OPTARG" ;;
        H) HOST="$OPTARG" ;;
        p) REMOTE_PATH="$OPTARG" ;;
        i) IDENTITY_FILE="$OPTARG" ;;
        r) RETRIES="$OPTARG" ;;
        t) TIMEOUT="$OPTARG" ;;
        v) version; exit 0 ;;
        h) usage; exit 0 ;;
        ?) echo "Invalid option:";;
    esac
done

# Validate required arguments
if [ -z "${SOURCE[*]:-}" ] || [ -z "${REMOTE_USER:-}" ] || [ -z "${HOST:-}" ] || [ -z "${REMOTE_PATH:-}" ]; then
    log; error "Error: Missing required arguments."
    usage
    exit $BAD_ARGS
fi

# Dry run mode
# shellcheck disable=SC2029
if [ $DRY_RUN == true ]; then
    list_args; echo; check_host

    dry "Connectivity confirmed. Would transfer:"
    for source in "${SOURCE[@]}"; do
        dry "   $source -> $REMOTE_USER@$HOST:$REMOTE_PATH"
    done
    
    dry "scp ${options[*]} ${SOURCE[*]} ${REMOTE_USER}@${HOST}:${REMOTE_PATH}"

    for source in "${SOURCE[@]}"; do
        if [ $NO_VERIFY == false ]; then
            dry "Local checksum ($source): $(sha256sum "$source" | awk '{print $1}')"
        fi
    done

    dry "No files were transferred."
    exit $EXIT_DRYRUN
fi

check_host || exit $HOST_UNREACHABLE
do_transfer || exit $FAILURE
if [ $NO_VERIFY == false ]; then verify_transfer; fi