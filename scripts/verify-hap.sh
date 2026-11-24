#!/usr/bin/env bash
set -euo pipefail
HAP="${1:?usage: verify-hap.sh path/to/app.hap}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
unzip -q "$HAP" -d "$TMP"
fail=0
need() { if [ ! -e "$TMP/$1" ]; then echo "MISSING $1"; fail=1; else echo "OK $1"; fi; }
need libs/arm64-v8a/libqemu-x86_64.so
need libs/arm64-v8a/libqemu-jit-x86_64.so
need libs/arm64-v8a/libprobe.so
need resources/rawfile/qemu/bash
need resources/rawfile/qemu/git
need resources/rawfile/qemu/rg
need resources/rawfile/qemu/busybox
echo "---"
sha256sum "$HAP"
du -h "$HAP"
if [ "$fail" -ne 0 ]; then echo "HAP verification FAILED"; exit 1; fi
echo "HAP verification OK"
