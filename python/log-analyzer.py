#!/usr/bin/env python3

import argparse, re, sys, datetime

from collections import Counter
from pathlib import Path

def parse_args():
    parser = argparse.ArgumentParser(
        description='Parse and summarize log files.')
    parser.add_argument('--file', required=True, help='File to be analyzed.')
    return parser.parse_args()

def validate_input(file):
    if not file:
        print("File cannot be empty")
        sys.exit(2)
    elif not Path(file).is_file():
        print("File does not exist")
        sys.exit(2)


def parse_log(file):
    results = []
    PATTERN = re.compile(
        r'(?P<month>\w+)\s+(?P<day>\d+)\s+(?P<time>\S+)\s+'
        r'(?P<host>\S+)\s+(?P<process>\w+).*?:\s+(?P<message>.+)'
    )

    with open(file, 'r') as f:
        for line in f:
            match = PATTERN.search(line)
            if match:
                results.append(match.groupdict())
    return results

def analyze(parsed_lines):
    error_counts = Counter()
    hourly_counts = Counter()

    for line in parsed_lines:
        msg = line.get('message', '')
        for keyword in ('error', 'fail', 'critical', 'warn'):
            if keyword in msg.lower():
                error_counts[keyword] += 1
        hour = line.get('time', '00:00:00').split(':')[0]
        hourly_counts[hour] += 1

    return {
        'error_counts': error_counts,
        'hourly_counts': hourly_counts
    }

def report(analyzed_data):
    print("Error Counts:")
    if not analyzed_data['error_counts']:
        print("  No errors found.")
    else:
        for error, count in analyzed_data['error_counts'].most_common():
            print(f"  {error}: {count}")

    print("\nHourly Counts:")
    if not analyzed_data['hourly_counts']:
        print("  No hourly data available.")
    else:
        for hour, count in analyzed_data['hourly_counts'].most_common():
            print(f"  {hour}: {count}")

if __name__ == "__main__":
    args = parse_args()
    validate_input(args.file)
    parsed_lines = parse_log(args.file)
    analyzed_data = analyze(parsed_lines)
    report(analyzed_data)