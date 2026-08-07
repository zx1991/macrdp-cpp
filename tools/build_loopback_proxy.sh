#!/bin/bash

set -eu

output=${1:-/tmp/macrdp-loopback-proxy}
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

clang -std=c11 -O2 -Wall -Wextra -Wpedantic -pthread \
	"$script_dir/rdp_loopback_proxy.c" \
	-o "$output"

echo "built $output"
