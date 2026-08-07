#!/bin/bash

set -eu

if [ "$#" -lt 2 ] || [ "$#" -gt 3 ]; then
	echo "usage: $0 <freerdp-build-dir> <freerdp-source-dir> [output]" >&2
	exit 2
fi

freerdp_build=$1
freerdp_source=$2
output=${3:-/tmp/macrdp-loopback-client}

for required_path in \
	"$freerdp_build/include/freerdp/config.h" \
	"$freerdp_build/winpr/include/winpr/config.h" \
	"$freerdp_build/client/common/libfreerdp-client3.dylib" \
	"$freerdp_build/libfreerdp/libfreerdp3.dylib" \
	"$freerdp_build/winpr/libwinpr/libwinpr3.dylib" \
	"$freerdp_source/include/freerdp/client.h" \
	"$freerdp_source/winpr/include/winpr/assert.h"; do
	if [ ! -e "$required_path" ]; then
		echo "missing FreeRDP build/source path: $required_path" >&2
		exit 2
	fi
done

clang -std=c11 -O2 -Wall -Wextra -Wpedantic \
	-I"$freerdp_build/include" \
	-I"$freerdp_build/winpr/include" \
	-I"$freerdp_source/include" \
	-I"$freerdp_source/winpr/include" \
	"$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/rdp_loopback_client.c" \
	-L"$freerdp_build/client/common" \
	-L"$freerdp_build/libfreerdp" \
	-L"$freerdp_build/winpr/libwinpr" \
	-lfreerdp-client3 \
	-lfreerdp3 \
	-lwinpr3 \
	-Wl,-rpath,"$freerdp_build/client/common" \
	-Wl,-rpath,"$freerdp_build/libfreerdp" \
	-Wl,-rpath,"$freerdp_build/winpr/libwinpr" \
	-o "$output"

echo "built $output"
