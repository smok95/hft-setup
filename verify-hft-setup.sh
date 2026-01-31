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

# Check IRQ affinity
echo ""
echo "[IRQ Affinity - Sample]"
for irq in $(ls /proc/irq/ | grep -E '^[0-9]+$' | head -5); do
    if [ -f "/proc/irq/$irq/smp_affinity_list" ]; then
        aff=$(cat /proc/irq/$irq/smp_affinity_list)
        echo "  IRQ $irq: CPUs $aff"
    fi
done

# System load
echo ""
echo "[System Status]"
echo "  Load average: $(cat /proc/loadavg | awk '{print $1, $2, $3}')"
echo "  CPU cores: $(nproc)"
echo "  Memory: $(free -h | grep Mem | awk '{print $3 "/" $2}')"

echo ""
echo "=== End Verification ==="
