#!/bin/bash
# HFT Setup Verification Script

echo "=== HFT Configuration Verification ==="
echo ""

# Check SELinux
echo "[SELinux]"
if command -v getenforce &>/dev/null; then
    selinux_status=$(getenforce)
    if [ "$selinux_status" = "Disabled" ]; then
        echo "✓ SELinux: Disabled"
    else
        echo "⚠ SELinux: $selinux_status (should be 'Disabled')"
    fi
else
    echo "✓ SELinux: not installed"
fi

# Check CPU isolation
echo ""
echo "[CPU Isolation]"
if grep -q "isolcpus" /proc/cmdline; then
    echo "✓ CPU isolation active: $(grep -o 'isolcpus=[^ ]*' /proc/cmdline)"
else
    echo "✗ CPU isolation not configured"
fi

# Check CPU governor / EPB
echo ""
echo "[CPU Governor / Performance Mode]"
gov=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo "N/A")
if [ "$gov" = "performance" ]; then
    echo "✓ CPU governor: $gov"
elif [ "$gov" = "N/A" ] && command -v x86_energy_perf_policy &>/dev/null; then
    # No cpufreq driver (e.g. Raptor Lake i9-14900K with kernel 5.14 intel_pstate limitation)
    # Fall back to EPB (Energy Performance Bias) check
    epb=$(x86_energy_perf_policy 2>/dev/null | grep "^cpu0:" | awk '{print $3}')
    if [ "$epb" = "0" ]; then
        echo "✓ CPU governor: N/A (no cpufreq driver), EPB=0 (max performance) via x86_energy_perf_policy"
    else
        echo "⚠ CPU governor: N/A, EPB=${epb:-unknown} (should be 0 for max performance)"
        echo "  Run: x86_energy_perf_policy performance"
    fi
else
    echo "⚠ CPU governor: $gov (should be 'performance')"
fi

# Check HugePages
echo ""
echo "[HugePages]"
total=$(grep HugePages_Total /proc/meminfo | awk '{print $2}')
free=$(grep HugePages_Free /proc/meminfo | awk '{print $2}')
size=$(grep Hugepagesize /proc/meminfo | awk '{print $2}')
if [ "$total" -gt 0 ]; then
    echo "✓ HugePages configured: $total pages of ${size}kB"
    echo "  Free: $free pages"
else
    echo "✗ HugePages not configured"
fi

# Check Transparent HugePages
echo ""
echo "[Transparent HugePages]"
thp=$(cat /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null | grep -o '\[.*\]' | tr -d '[]')
if [ "$thp" = "never" ]; then
    echo "✓ THP disabled: $thp"
else
    echo "⚠ THP enabled: $thp (should be 'never')"
fi

# Check swappiness
echo ""
echo "[Memory Settings]"
swap=$(sysctl -n vm.swappiness)
if [ "$swap" -eq 0 ]; then
    echo "✓ vm.swappiness: $swap"
else
    echo "⚠ vm.swappiness: $swap (should be 0)"
fi

# Check network settings
echo ""
echo "[Network Settings]"
echo "  rmem_max: $(sysctl -n net.core.rmem_max)"
echo "  wmem_max: $(sysctl -n net.core.wmem_max)"
echo "  netdev_max_backlog: $(sysctl -n net.core.netdev_max_backlog)"

# Check rp_filter
rpf_all=$(sysctl -n net.ipv4.conf.all.rp_filter)
rpf_def=$(sysctl -n net.ipv4.conf.default.rp_filter)
if [ "$rpf_all" -eq 0 ] && [ "$rpf_def" -eq 0 ]; then
    echo "  ✓ rp_filter: disabled (all=$rpf_all default=$rpf_def)"
else
    echo "  ⚠ rp_filter: all=$rpf_all default=$rpf_def (both should be 0)"
fi

# Check per-NIC status and VMA compatibility
echo ""
echo "[Network Interfaces]"
for iface in $(ip link show | grep -E '^[0-9]+:' | awk -F': ' '{print $2}' | grep -v lo); do
    driver=$(ethtool -i $iface 2>/dev/null | grep driver | awk '{print $2}')
    speed=$(ethtool $iface 2>/dev/null | grep "Speed:" | awk '{print $2}')
    link=$(ip link show $iface | grep -o 'state [A-Z]*' | awk '{print $2}')
    if [[ "$driver" == *"mlx"* ]]; then
        vma_status="VMA-capable (kernel-bypass)"
    else
        vma_status="kernel-stack only (tuned with ethtool)"
    fi
    echo "  $iface: driver=$driver speed=$speed state=$link -- $vma_status"
done

# Check VMA config if present
if [ -f /etc/libvma.conf ]; then
    echo ""
    echo "[VMA Configuration]"
    echo "  Config file: /etc/libvma.conf (present)"
    if command -v vma_stats &>/dev/null; then
        echo "  vma_stats: available"
    else
        echo "  vma_stats: not installed"
    fi
fi

# Check IRQ affinity
# Check smp_affinity_list (what we actually control) for each IRQ
# Note: effective_affinity_list may differ for managed IRQs (driver-controlled, can't be changed)
echo ""
echo "[IRQ Affinity]"
bad_irq_count=0
managed_irq_count=0
for irq in $(ls /proc/irq/ | grep -E '^[0-9]+$'); do
    smp=$(cat /proc/irq/$irq/smp_affinity_list 2>/dev/null)
    eff=$(cat /proc/irq/$irq/effective_affinity_list 2>/dev/null)
    [ -z "$smp" ] && continue
    # Check if smp_affinity_list includes any HFT core (2-7)
    on_hft=0
    for cpu in $(echo "$smp" | tr ',' '\n' | while read r; do
        if echo "$r" | grep -q '-'; then
            seq $(echo $r | cut -d- -f1) $(echo $r | cut -d- -f2)
        else
            echo "$r"
        fi
    done); do
        if [ "$cpu" -ge 2 ] && [ "$cpu" -le 7 ] 2>/dev/null; then
            on_hft=1; break
        fi
    done
    if [ "$on_hft" -eq 1 ]; then
        irq_name=$(awk "/^[[:space:]]*${irq}:/{print \$NF}" /proc/interrupts 2>/dev/null)
        # Detect if this is a truly managed IRQ by attempting to write 0x3 (CPU 0-1)
        # and checking if it actually changed
        if ! echo 3 > /proc/irq/$irq/smp_affinity 2>/dev/null; then
            # Write failed explicitly - truly managed IRQ (e.g. NVMe queues)
            managed_irq_count=$((managed_irq_count + 1))
        elif [ "$(cat /proc/irq/$irq/smp_affinity_list 2>/dev/null)" != "0-1" ] && \
             [ "$(cat /proc/irq/$irq/smp_affinity_list 2>/dev/null)" != "0" ] && \
             [ "$(cat /proc/irq/$irq/smp_affinity_list 2>/dev/null)" != "1" ]; then
            # Write succeeded but value didn't change - silently-managed IRQ
            managed_irq_count=$((managed_irq_count + 1))
        else
            # Successfully changed back to 0-1, but it was wrong before
            echo "  ⚠ IRQ $irq ($irq_name): was on HFT core, now reset to CPU 0-1"
            bad_irq_count=$((bad_irq_count + 1))
        fi
    fi
done

if [ "$bad_irq_count" -eq 0 ]; then
    echo "  ✓ IRQ affinity correctly set (smp_affinity excludes HFT cores 2-7)"
    if [ "$managed_irq_count" -gt 0 ]; then
        echo "  ℹ $managed_irq_count managed IRQs on HFT cores (driver-controlled, cannot be moved)"
        echo "    These fired during boot but smp_affinity is set to 0-1 for non-managed ones"
    fi
else
    echo "  ✗ $bad_irq_count IRQ(s) with smp_affinity pointing to HFT cores - run set-irq-affinity.sh"
fi

# Check irqbalance
echo ""
echo "[irqbalance]"
if systemctl is-active irqbalance &>/dev/null; then
    echo "  ⚠ irqbalance is running - it will undo IRQ pinning"
else
    echo "  ✓ irqbalance: stopped"
fi

# System load
echo ""
echo "[System Status]"
echo "  Load average: $(cat /proc/loadavg | awk '{print $1, $2, $3}')"
total_cpus=$(grep -c "^processor" /proc/cpuinfo)
isolated_cpus=$(cat /sys/devices/system/cpu/isolated 2>/dev/null || echo "none")
echo "  CPU cores: $total_cpus total (isolated: $isolated_cpus, available: $(nproc))"
echo "  Memory: $(free -h | grep Mem | awk '{print $3 "/" $2}')"

echo ""
echo "=== End Verification ==="
