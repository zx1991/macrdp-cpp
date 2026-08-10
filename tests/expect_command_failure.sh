#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 2 ]]; then
    printf 'usage: %s <expected-text> <command> [arguments...]\n' "$0" >&2
    exit 2
fi

expected_text=$1
shift

set +e
output=$("$@" 2>&1)
status=$?
set -e

if [[ $status -eq 0 ]]; then
    printf 'command unexpectedly succeeded: %s\n' "$*" >&2
    exit 1
fi
if [[ $output != *"$expected_text"* ]]; then
    printf 'command failed without expected text: %s\n' "$expected_text" >&2
    printf '%s\n' "$output" >&2
    exit 1
fi
