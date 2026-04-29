#!/bin/bash
# MSR C1E Disable Script - Run after reboot with msr.allow_writes=1 enabled
# Requires: msr-tools package, msr.allow_writes=1 kernel parameter

set -e

echo "=== MSR C1E/HWP Configuration for HFT ==="
echo ""

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    echo "Please run as root (sudo)"
    exit 1
fi

# Check msr module
if [ ! -e /dev/cpu/0/msr ]; then
    echo "Loading msr module..."
    modprobe msr
fi

# Check if MSR writes are allowed
allow_writes=$(cat /sys/module/msr/parameters/allow_writes 2>/dev/null)
echo "MSR allow_writes: $allow_writes"
if [ "$allow_writes" != "Y" ]; then
    echo "WARNING: MSR writes not enabled. Kernel parameter msr.allow_writes=1 required."
    echo "Current kernel cmdline:"
    grep -o "msr[^ ]*" /proc/cmdline || echo "msr.allow_writes not found in cmdline"
    echo ""
    echo "To enable: reboot with msr.allow_writes=1 kernel parameter"
    exit 1
fi

echo ""
echo "[1] Disabling C1E auto-promotion via MSR 0x1FC..."
# MSR 0x1FC (IA32_POWER_CTL)
# Bit 0: C1E Auto-promotion Enable (0 = disabled)
# Current value: read, clear bit 0, write back

for cpu_dir in /dev/cpu/; do
    cpu=$(basename $cpu_dir)
    if [[ "$cpu" =~ ^[0-9]+$ ]]; then
        val=$(rdmsr -p $cpu 0x1fc 2>/dev/null)
        if [ -n "$val" ]; then
            # Convert hex to decimal, clear bit 0, convert back to hex
            val_dec=$(printf "%d" "0x$val")
            new_dec=$((val_dec & 0xFFFFFFFFFFFFFFFE))
            new_hex=$(printf "%x" $new_dec)
            wrmsr -p $cpu 0x1fc $new_hex
            verify=$(rdmsr -p $cpu 0x1fc)
            echo "  CPU $cpu: $val -> $verify (C1E bit 0: $((verify & 1)))"
        fi
    fi
done

echo ""
echo "[2] Setting HWP EPP to performance (if HWP available)..."
# HWP_REQUEST MSR 0x774 - per-core HWP settings
# EPP (Energy Performance Preference) in bits 0-7 (some CPUs use bits 24-31)
# 0 = performance, 255 = power save

# Only apply if HWP is supported (check MSR 0x774 existence)
if rdmsr -p 0 0x774 >/dev/null 2>&1; then
    for cpu_dir in /dev/cpu/; do
        cpu=$(basename $cpu_dir)
        if [[ "$cpu" =~ ^[0-9]+$ ]]; then
            # Set EPP to 0 (performance) - preserve other bits
            # HWP_REQUEST format varies by CPU, try setting EPP bits
            # Common format: bits 0-7 = EPP, bits 8-15 = Activity Window
            # For safety, set entire register to max performance
            wrmsr -p $cpu 0x774 0 2>/dev/null || true
            verify=$(rdmsr -p $cpu 0x774 2>/dev/null)
            echo "  CPU $cpu: HWP_REQUEST = $verify"
        fi
    done
else
    echo "  HWP not available (intel_pstate=passive mode)"
fi

# Package-level HWP (MSR 0x648) - if available
if rdmsr -p 0 0x648 >/dev/null 2>&1; then
    echo ""
    echo "[3] Setting Package HWP to performance..."
    for cpu_dir in /dev/cpu/; do
        cpu=$(basename $cpu_dir)
        if [[ "$cpu" =~ ^[0-9]+$ ]]; then
            wrmsr -p $cpu 0x648 0 2>/dev/null || true
            verify=$(rdmsr -p $cpu 0x648 2>/dev/null)
            echo "  CPU $cpu: PKG_HWP = $verify"
        fi
    done
fi

echo ""
echo "=== MSR Configuration Complete ==="
echo ""
echo "Verification:"
echo "  MSR 0x1FC (C1E): $(rdmsr -a 0x1FC | head -1) (bit 0 should be 0)"
echo "  MSR 0x774 (HWP): $(rdmsr -a 0x774 | head -1) (should be low value for performance)"