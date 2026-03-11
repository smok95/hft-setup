#!/bin/bash
# Helper script to run HFT applications with VMA
# This script should be installed to /usr/local/bin/run-with-vma.sh

if [ -z "$1" ]; then
    echo "Usage: run-with-vma.sh <command> [args...]"
    echo ""
    echo "Example:"
    echo "  run-with-vma.sh ./trading-app --config prod.conf"
    echo ""
    echo "Options (set as environment variables):"
    echo "  VMA_TRACELEVEL=3        # Enable VMA logging (default: 2)"
    echo "  VMA_CORES=2-7           # CPU cores to use (default: 2-7)"
    echo "  VMA_PRIORITY=99         # Real-time priority (default: 99)"
    exit 1
fi

# Default settings
VMA_CORES=${VMA_CORES:-2-7}
VMA_PRIORITY=${VMA_PRIORITY:-99}
VMA_TRACELEVEL=${VMA_TRACELEVEL:-2}

# Verify VMA is installed
if [ ! -f /usr/lib64/libvma.so ] && [ ! -f /usr/lib/libvma.so ]; then
    echo "Error: libvma.so not found"
    exit 1
fi

# Find libvma.so
if [ -f /usr/lib64/libvma.so ]; then
    LIBVMA=/usr/lib64/libvma.so
else
    LIBVMA=/usr/lib/libvma.so
fi

echo "=== Running with VMA ==="
echo "Command: $@"
echo "CPU cores: $VMA_CORES"
echo "RT priority: $VMA_PRIORITY"
echo "VMA log level: $VMA_TRACELEVEL"
echo "========================"
echo ""

# Run with VMA
exec chrt -f $VMA_PRIORITY taskset -c $VMA_CORES \
    env LD_PRELOAD=$LIBVMA \
    VMA_TRACELEVEL=$VMA_TRACELEVEL \
    VMA_CONFIG_FILE=/etc/libvma.conf \
    "$@"