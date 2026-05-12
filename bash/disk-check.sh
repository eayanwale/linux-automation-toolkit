#!/usr/bin/env bash

readonly EXIT_OK=0
readonly EXIT_WARNING=1
readonly EXIT_CRITICAL=2
readonly EXIT_UNKNOWN=3

usage() {
    echo "Usage: $0 -d <disk> [-w <warning>] [-c <critical>] [-h]"
    echo "Required:"
    echo "  -d <disk>      Specify a disk to check (e.g., /backup, /var). Can be used multiple times for multiple disks."
    echo "Optional:"
    echo "  -w <warning>   Set warning threshold percentage (default: 70)."
    echo "  -c <critical>  Set critical threshold percentage (default: 80)."
    echo "  -h             Show this help message."
}

declare -a DISKS=()
WARN=70
CRIT=80
while getopts "d:w:c:h" opt; do
    case $opt in
        d) DISKS+=("$OPTARG") ;;
        w) WARN="$OPTARG" ;;
        c) CRIT="$OPTARG" ;;
        h) usage; exit 0 ;;
        ?) echo "Invalid option:";;
    esac
done

if [ ${#DISKS[@]} -eq 0 ]; then
    echo "No disks specified. Use -d <disk> to specify disks."
    exit 3
fi

worst_status=$EXIT_OK
for disk in "${DISKS[@]}"; do
    disk_check=$(df -P | grep "$disk" | awk '{print $5}' | sed 's/%//g')

    if [ -z "$disk_check" ]; then
        echo "Disk $disk is not mounted."
        status=$EXIT_UNKNOWN
        if [ $status -gt $worst_status ]; then
            worst_status=$status
        fi
        continue
    fi
    
    if [[ "$disk_check" -gt "$CRIT" ]]; then
        echo "Disk $disk is over $CRIT% full."
        status=$EXIT_CRITICAL
    elif [[ "$disk_check" -gt "$WARN" ]]; then
        echo "Disk $disk is over $WARN% full."
        status=$EXIT_WARNING
    else
        echo "Disk $disk is OK."
        status=$EXIT_OK
    fi
    
    if [ $status -gt $worst_status ]; then
        worst_status=$status
    fi

done
exit $worst_status