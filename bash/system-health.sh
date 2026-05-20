#!/usr/bin/env bash

set -euo pipefail

LOG_FILE="../log/sys-health.log"
if [ -f "$LOG_FILE" ] && [ $(wc -l < "$LOG_FILE") -gt 100 ]; then
    mv "$LOG_FILE" "../log/sys-health-$(date +%Y-%m-%d-%H%M%S).log"
    find ../log/ -name "sys-health-*.log" -mtime +100 -delete
fi

# Exit codes
readonly EXIT_OK=0
readonly EXIT_WARNING=1
readonly EXIT_CRITICAL=2
readonly EXIT_UNKNOWN=3

readonly LOAD_WARN_MULTIPLIER=2

HOSTNAME=$(hostname -s 2>/dev/null || hostname) 
DATE=$(TZ='UTC+4' date "+%Y-%m-%d %H:%M:%S")

usage() {
    echo "Usage: $0 [-s] [-c checks] [-h]"
    echo
    echo "Run a quick system health check and output a readable report."
    echo 
    echo "Options:"
    echo "  -s            Short mode (one-line summary per section)"
    echo "  -c CHECKS     List of checks to run"
    echo "                Available: cpu, mem, disk, load, uptime, services, network, all"
    echo "                (default: all)"
    echo "  -v            Show version"
    echo "  -h            Show this help"
    echo
    echo "Examples:"
    echo "  system-health.sh                    # Full report"
    echo "  system-health.sh -s                 # One-line-per-section summary"
    echo "  system-health.sh -c disk mem        # Only disk and memory checks"
}

version() { VERSION="v1.0.0"; echo $VERSION; }

section() { echo " ==== $1 ==== "; }

worst_status=0
update_status() {
    local status="$1"
    if [[ $status -gt $worst_status ]]; then
        $worst_status=$status
    fi
}

status_label() {
    local value="$1"
    local warn="$2"
    local crit="$3"

    if [[ $value -ge $crit ]]; then
        update_status 2
        echo "CRITICAL"
    elif [[ value -ge warn ]]; then
        update_status 1
        echo "WARNING"
    else
        echo "OK"
    fi
}

check_uptime() {
    section "SYSTEM"

    local host_name=$HOSTNAME
    local kernel=$(uname -r)
    local os_name=$(grep "PRETTY_NAME=" "/etc/os-release" | sed 's/PRETTY_NAME=//g')
    local raw_up_time=$(uptime | awk '{print $2,$3,$4,$5" minutes"}' | tr -s ',' ' ' | sed 's/:/ hours, /')
    local up_time=$(uptime -p 2>/dev/null || echo "$raw_up_time")

    printf "  %-20s %s\n" "Hostname:" "$host_name"
    printf "  %-20s %s\n" "Time:" "$DATE"
    printf "  %-20s %s\n" "Kernel:" "$kernel"
    printf "  %-20s %s\n" "OS:" "$os_name"
    printf "  %-20s %s\n" "Uptime:" "$up_time"

}

check_cpu() {
    section "CPU"
    
    local cpu_cores
    cpu_cores=$(nproc 2>/dev/null || grep -c '^processor' /proc/cpuinfo)

    local cpu_line1
    cpu_line1=$(grep '^cpu ' /proc/stat)

    sleep 1

    local cpu_line2
    cpu_line2=$(grep '^cpu ' /proc/stat)

    local idle1 total1 idle2 total2

    idle1=$(awk '{print $5}' <<< $cpu_line1)
    total1=$(awk '{sum=0; for(i=2;i<=NF;i++) sum+=$i; print sum}' <<< $cpu_line1)

    idle2=$(awk '{print $5}' <<< $cpu_line2)
    total2=$(awk '{sum=0; for(i=2;i<=NF;i++) sum+=$i; print sum}' <<< $cpu_line2)

    idle_delta=$(( idle2 - idle1 ))
    total_delta=$(( total2 - total1 ))

    local cpu_pct=0

    if [[ $cpu_pct -gt 0 ]]; then
        cpu_pct=$(( 100 * ( total_delta - idle_delta ) / total_delta ))
    fi

    local label
    label=$(status_label "$cpu_pct" "$EXIT_WARNING" "$EXIT_CRITICAL")

    printf "  %-20s %s\n" "Cores:" "$cpu_cores"
    printf "  %-20s %s%% [%s]\n" "Usage:" "$cpu_pct" "$label"
}

check_load() {
    section "LOAD AVERAGE"
    
    local load1 load5 load15
    read -r load1 load5 load15 _ < /proc/loadavg

    local cpu_count
    cpu_count=$(nproc 2>/dev/null || grep -c '^processor' /proc/cpuinfo || echo 1)
    
    local warn_thresh=$(( cpu_count * LOAD_WARN_MULTIPLIER ))

    local load1_int
    load1_int=$(awk '{printf "%d", $1 * 100}' <<< "$load1")
    local warn_int=$(( warn_thresh * 100 ))

    printf "  %-20s %s\n" "1 min:" "$load1"
    printf "  %-20s %s\n" "5 min:" "$load5"
    printf "  %-20s %s\n" "15 min:" "$load15"
    printf "  %-20s %s\n" "CPUs:" "$cpu_count"

    if [[ $load1_int -gt $warn_int ]]; then
        printf "  %-20s %s\n" "Status:" "WARNING - load exceeds ${LOAD_WARN_MULTIPLIER}x CPU count"
        update_status 1
    else
        printf "  %-20s %s\n" "Status:" "OK"
    fi
}

check_mem() {
    section "MEMORY"

    local all_mem=""
    if command -v free >/dev/null 2>&1; then
        all_mem=$(free -m | awk '
            /^Mem:/ {
                printf "%d %d %d %d", $2, $3, $4, $7
            }
        ' 2>/dev/null || true)
    else
        echo "free command not available (likely Git Bash/Windows)" >&2
        return 1
    fi

    local total used free_mem available
    read -r total used free_mem available <<< "$all_mem"

    local pct=$(( 100 * ( total - available ) / total ))

    local label
    label=$(status_label "$pct" "$EXIT_WARNING" "$EXIT_CRITICAL")

    local swap_info swap_pct
    swap_info=$(free -m | awk '/^Swap:/ {printf "%d %d", $2, $3}')
    read -r swap_total swap_used <<< "$swap_info"

    local swap_pct=0

    if [[ $swap_total > 0 ]]; then
        swap_pct=$(( 100 * ( swap_used / swap_total ) ))
    fi

    printf "  %-20s %s\n" "Total:" "$total"
    printf "  %-20s %s\n" "Used:" "$used"
    printf "  %-20s %s\n" "Available:" "$available"
    printf "  %-20s %3s%% [%s]\n" "Usage:" "$pct" "$label"
    printf "  %-20s %s\n" "Swap:" "${swap_used}/${swap_total} MB (${swap_pct}%)"
}

check_disk() {
    section "DISKS"

    while read -r _ _ _ _ pct mount; do
        usage="${pct%\%}"
        label=$(status_label "${usage}" "${DISK_WARN}" "${DISK_CRIT}")
        printf "  %-20s %3s%% [%s]\n" "${mount}" "${usage}" "${label}"
    done < <(df -P -x tmpfs -x devtmpfs -x overlay | awk 'NR>1')
}

systemd_services() {
    local -n key_services=$1
    local -n checked=$2

    local failed
    failed=$(systemctl --state=failed --no-legend 2>/dev/null)

    if [[ -n "$failed" ]]; then
        echo "  Failed units:"
        awk '{print "   ✗ " $1}' <<< "$failed"
        update_status 1
    else
        echo "All units healthy"
    fi

    local svc 
    for svc in "${key_services[@]}"; do
        if systemctl status "${svc}.service" &>/dev/null; then 
            ((checked ++))

            if systemctl is-active --quiet "$svc"; then
                echo "  ✓ $svc"
            else
                echo "  ✗ $svc"
                update_status 1
            fi
        fi
    done
}

sysv_services() {
    local -n key_services=$1
    local -n checked=$2

    local svc
    for svc in "${key_services[@]}"; do
        [[ -f /etc/init.d/$svc ]] || continue

        ((checked ++))

        if service "$svc" status &>/dev/null; then
            echo "  ✓ $svc"
        else
            echo "  ✗ $svc"
            update_status 1
        fi
    done
}

check_services() {
    section "SERVICES"

    local key_services=("sshd" "crond" "cron" "rsyslog" "syslog")
    local checked=0

    if command -v systemctl >/dev/null 2>&1; then
        systemd_services key_services checked
    elif command -v service >/dev/null 2>&1; then
        sysv_services key_services checked
    else
        echo "  No service manager found"
        return
    fi

    [[ $checked -eq 0 ]] && echo "  (no matching services found)"
}

check_network() {
    section "NETWORK"

    if command -v ip >/dev/null 2>&1; then
        ip -4 addr show 2>/dev/null | awk '/inet / && !/127.0.0.1/ {
            gsub(/\/.*/, "", $2)
            printf "    %-12s %s\n", $NF, $2
        }'
    fi

    if ping -q -c 1 -W 3 8.8.8.8 >/dev/null 2>&1; then
        echo "  Internet:       reachable (via 8.8.8.8)"
    else
        echo "  Internet;       unreachable or ICMP blocked"
    fi

    if command -v host >/dev/null 2>&1; then
        if host -W 3 dns.google >/dev/null 2>&1; then
            echo "  DNS:        resolving"
        else
            echo "  DNS:        resolution failed"
            update_status 1
        fi
    elif command -v nslookup >/dev/null 2>&1; then
        if nslookup -timeout=3 dns.google >/dev/null 2>&1; then
            echo "  DNS:       resolving"
        else
            echo "  DNS:       resolution failed"
            update_status 1
        fi
    else
        echo "  DNS:        no resolver too available"
        update_status 1
    fi
}

run_check() {
    local name="$1"
    for c in "${CHECKS[@]}"; do
        if [[ "$c" == "all" ]] || [[ "$c" == "$name" ]]; then
            return 0
        fi
    done
    return 1
}

declare -a CHECKS=()

while getopts ":sc:vh" opt; do
    case $opt in
        s) SHORT_MODE=true ;;
        c) CHECKS+=("$OPTARG") ;;
        v) version; exit 0 ;;
        h) usage; exit 0 ;;
        ?) echo "Invalid option"; usage ;;
    esac
done

for arg in "$@"; do
    case "$arg" in
        --version) version; exit 0 ;;
        --help)    usage; exit 0 ;;
    esac
done

if [[ ${#CHECKS[@]} -eq 0 ]]; then
    CHECKS=("all")
fi

printf '\n'
printf '╔══════════════════════════════════════════════╗\n'
printf '║ %-44s ║\n' "SYSTEM HEALTH REPORT"
printf '║ %-44s ║\n' "$HOSTNAME"
printf '║ %-44s ║\n' "$DATE"
printf '╚══════════════════════════════════════════════╝\n'
printf '\n'

run_check uptime && check_uptime
run_check cpu && check_cpu
run_check load && check_load
run_check mem && check_mem
run_check disk && check_disk
run_check services && check_services
run_check network && check_network
