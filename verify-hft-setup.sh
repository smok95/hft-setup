#!/bin/bash
# HFT Setup Verification Script

echo "=== HFT Configuration Verification ==="
echo ""

# Check CPU isolation
echo "[CPU Isolation]"
if grep -q "isolcpus" /proc/cmdline; then
    echo "✓ CPU isolation active: $(grep -o 'isolcpus=[^ ]*' /proc/cmdline)"
else
    echo "✗ CPU isolation not configured"
fi

# Check CPU governor
echo ""
echo "[CPU Governor]"
gov=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo "N/A")
if [ "$gov" = "performance" ]; then
    echo "✓ CPU governor: $gov"
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
echo ""
echo "[IRQ Affinity - Sample]"
for irq in $(ls /proc/irq/ | grep -E '^[0-9]+$' | head -5); do
    if [ -f "/proc/irq/$irq/smp_affinity_list" ]; then
        aff=$(cat /proc/irq/$irq/smp_affinity_list)
        echo "  IRQ $irq: CPUs $aff"
    fi
done

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
echo "  CPU cores: $(nproc)"
echo "  Memory: $(free -h | grep Mem | awk '{print $3 "/" $2}')"

echo ""
echo "=== End Verification ==="
