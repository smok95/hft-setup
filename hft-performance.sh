#!/bin/bash
# HFT Performance Mode Control - ON/OFF dynamic switching
# Method: cpuidle sysfs (preferred) + MSR 0x1FC (fallback)

set -e

MODE="${1:-status}"

if [ "$EUID" -ne 0 ]; then
    echo "Run as root (sudo)"
    exit 1
fi

# Disable all C-states via cpuidle sysfs (CPU stays in POLL state only)
disable_cstates_sysfs() {
    for state in /sys/devices/system/cpu/cpu*/cpuidle/state*; do
        [ -f "$state/disable" ] && echo 1 > "$state/disable" 2>/dev/null
    done
}

# Enable C-states via cpuidle sysfs
enable_cstates_sysfs() {
    for state in /sys/devices/system/cpu/cpu*/cpuidle/state*; do
        [ -f "$state/disable" ] && echo 0 > "$state/disable" 2>/dev/null
    done
}

# Check if C-states are disabled
check_cstates_disabled() {
    for state in /sys/devices/system/cpu/cpu0/cpuidle/state*; do
        [ -f "$state/name" ] && [ "$(cat "$state/name")" != "POLL" ] && {
            [ -f "$state/disable" ] && [ "$(cat "$state/disable")" != "1" ] && return 1
        }
    done
    return 0
}

on_mode() {
    echo "=== HFT Performance Mode: ON ==="

    # CPU Governor: performance
    for cpu in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
        [ -f "$cpu" ] && echo performance > "$cpu"
    done
    echo "  - Governor: performance"

    # Lock frequency: min = max
    for cpu in /sys/devices/system/cpu/cpu*/cpufreq/scaling_max_freq; do
        [ -f "$cpu" ] && cat "$cpu" > "$(dirname "$cpu")/scaling_min_freq"
    done
    echo "  - Frequency locked at max"

    # Disable C-states via cpuidle sysfs (POLL only - no sleep states)
    disable_cstates_sysfs
    if check_cstates_disabled; then
        echo "  - C-states: DISABLED (POLL only)"
    else
        echo "  - C-states: FAILED to disable"
    fi

    # HWP EPP = 0 (performance) for 12th+ gen Intel
    if command -v x86_energy_perf_policy &>/dev/null; then
        x86_energy_perf_policy --pkg 0 --hwp-epp 0 --force 2>/dev/null
        echo "  - HWP EPP: 0 (performance)"
    fi

    echo ""
    echo "Performance mode active. Ready for HFT."
}

off_mode() {
    echo "=== HFT Performance Mode: OFF (Rest) ==="

    # CPU Governor: powersave
    for cpu in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
        [ -f "$cpu" ] && echo powersave > "$cpu"
    done
    echo "  - Governor: powersave"

    # Unlock frequency: restore min_freq
    for cpu in /sys/devices/system/cpu/cpu*/cpufreq; do
        if [ -f "$cpu/cpuinfo_min_freq" ] && [ -f "$cpu/scaling_min_freq" ]; then
            cat "$cpu/cpuinfo_min_freq" > "$cpu/scaling_min_freq"
        fi
    done
    echo "  - Frequency unlocked"

    # Enable C-states via cpuidle sysfs
    enable_cstates_sysfs
    echo "  - C-states: ENABLED"

    # HWP EPP = 255 (max power saving) for 12th+ gen Intel
    if command -v x86_energy_perf_policy &>/dev/null; then
        x86_energy_perf_policy --pkg 0 --hwp-epp 255 --force 2>/dev/null
        echo "  - HWP EPP: 255 (powersave)"
    fi

    echo ""
    echo "Rest mode active. Power saving enabled."
}

status() {
    echo "=== HFT Performance Status ==="

    # Governor
    gov=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null)
    echo "  - Governor: ${gov:-N/A}"

    # Frequency range
    if [ -f /sys/devices/system/cpu/cpu0/cpufreq/scaling_min_freq ]; then
        min=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_min_freq)
        max=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_max_freq)
        if [ "$min" = "$max" ]; then
            echo "  - Frequency: LOCKED at $max kHz"
        else
            echo "  - Frequency: $min - $max kHz (unlocked)"
        fi
    fi

    # C-states via cpuidle sysfs
    cstates_disabled=true
    echo "  - C-states:"
    for state in /sys/devices/system/cpu/cpu0/cpuidle/state*; do
        [ -f "$state/name" ] && {
            name=$(cat "$state/name")
            dis=$(cat "$state/disable" 2>/dev/null || echo "0")
            if [ "$name" = "POLL" ]; then
                echo "    $name: always active"
            else
                if [ "$dis" = "1" ]; then
                    echo "    $name: DISABLED"
                else
                    echo "    $name: ENABLED"
                    cstates_disabled=false
                fi
            fi
        }
    done

    # HWP EPP
    if command -v x86_energy_perf_policy &>/dev/null && [ -f /sys/devices/system/cpu/intel_pstate/status ]; then
        pstate=$(cat /sys/devices/system/cpu/intel_pstate/status)
        if [ "$pstate" = "active" ] || [ "$pstate" = "passive" ]; then
            epp=$(x86_energy_perf_policy --pkg 0 --read 2>/dev/null | grep -i epp || echo "N/A")
            echo "  - HWP EPP: $epp"
        fi
    fi

    echo ""
    if [ "$gov" = "performance" ] && $cstates_disabled; then
        echo "Status: ON (Performance mode)"
    elif [ "$gov" = "powersave" ] && ! $cstates_disabled; then
        echo "Status: OFF (Rest mode)"
    else
        echo "Status: MIXED"
    fi
}

case "$MODE" in
    on)    on_mode ;;
    off)   off_mode ;;
    status) status ;;
    *)
        echo "Usage: $0 {on|off|status}"
        echo ""
        status
        exit 1
        ;;
esac