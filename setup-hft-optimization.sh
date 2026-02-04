#!/bin/bash
# HFT Linux Server Optimization Setup Script

set -e

echo "=== HFT Server Optimization Setup ==="
echo ""

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    echo "Please run as root (sudo)"
    exit 1
fi

# 1. Apply sysctl parameters
echo "[1/7] Applying kernel parameters..."
cp hft-sysctl.conf /etc/sysctl.d/99-hft.conf
sysctl -p /etc/sysctl.d/99-hft.conf

# 2. Configure HugePages (2GB total, using 2MB pages = 1024 pages)
echo "[2/7] Configuring HugePages..."
echo 1024 > /proc/sys/vm/nr_hugepages
echo "vm.nr_hugepages = 1024" >> /etc/sysctl.d/99-hft.conf

# Add memlock and rtprio limits for VMA and real-time scheduling
if ! grep -q "HFT:" /etc/security/limits.conf; then
    cat >> /etc/security/limits.conf << EOF
# HFT: VMA requires unlimited memlock for DMA buffers and HugePages
*               -       memlock         unlimited
# HFT: Allow real-time scheduling (chrt -f 99)
*               -       rtprio          99
EOF
fi

# 3. CPU Isolation (isolate cores 2-7, leave 0-1 for OS)
echo "[3/7] Setting up CPU isolation..."
GRUB_FILE="/etc/default/grub"
if ! grep -q "isolcpus" $GRUB_FILE; then
    sed -i 's/GRUB_CMDLINE_LINUX="/GRUB_CMDLINE_LINUX="isolcpus=2-7 nohz_full=2-7 rcu_nocbs=2-7 intel_idle.max_cstate=0 processor.max_cstate=0 intel_pstate=disable /' $GRUB_FILE
    echo "  - Isolated CPUs 2-7 for HFT applications"
    echo "  - CPUs 0-1 reserved for OS/interrupts"
    grub2-mkconfig -o /boot/grub2/grub.cfg
    REBOOT_REQUIRED=true
fi

# 4. Disable transparent hugepages
echo "[4/7] Disabling transparent hugepages..."
echo never > /sys/kernel/mm/transparent_hugepage/enabled
echo never > /sys/kernel/mm/transparent_hugepage/defrag

# Make persistent
cat > /etc/systemd/system/disable-thp.service << EOF
[Unit]
Description=Disable Transparent Huge Pages (THP)
DefaultDependencies=no
After=sysinit.target local-fs.target
Before=basic.target

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'echo never > /sys/kernel/mm/transparent_hugepage/enabled'
ExecStart=/bin/sh -c 'echo never > /sys/kernel/mm/transparent_hugepage/defrag'
RemainAfterExit=yes

[Install]
WantedBy=basic.target
EOF
systemctl daemon-reload
systemctl enable disable-thp.service

# 5. Set CPU governor to performance
echo "[5/7] Setting CPU governor to performance..."
for cpu in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
    if [ -f "$cpu" ]; then
        echo performance > $cpu
    fi
done

# Make persistent
cat > /etc/systemd/system/cpu-performance.service << EOF
[Unit]
Description=Set CPU Governor to Performance
After=network.target

[Service]
Type=oneshot
ExecStart=/bin/bash -c 'for cpu in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do [ -f \$cpu ] && echo performance > \$cpu; done'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable cpu-performance.service

# 6. Disable unnecessary services
echo "[6/7] Disabling unnecessary services..."
SERVICES_TO_DISABLE=(
    "firewalld"
    "bluetooth"
    "cups"
    "avahi-daemon"
    "ModemManager"
    "irqbalance"
)

for service in "${SERVICES_TO_DISABLE[@]}"; do
    if systemctl is-enabled $service 2>/dev/null | grep -q enabled; then
        systemctl disable $service
        systemctl stop $service 2>/dev/null || true
        echo "  - Disabled $service"
    fi
done

# 7. IRQ Affinity (bind to CPUs 0-1)
echo "[7/7] Configuring IRQ affinity..."
cat > /usr/local/bin/set-irq-affinity.sh << 'EOF'
#!/bin/bash
# Set IRQ affinity to CPUs 0-1 (leaving 2-7 for HFT apps)
CPUS="0,1"
for irq in $(ls /proc/irq/ | grep -E '^[0-9]+$'); do
    if [ -f "/proc/irq/$irq/smp_affinity_list" ]; then
        echo $CPUS > /proc/irq/$irq/smp_affinity_list 2>/dev/null || true
    fi
done
EOF
chmod +x /usr/local/bin/set-irq-affinity.sh

# Create systemd service for IRQ affinity
cat > /etc/systemd/system/irq-affinity.service << EOF
[Unit]
Description=Set IRQ Affinity for HFT
After=network-online.target
Wants=network-online.target
Conflicts=irqbalance.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/set-irq-affinity.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable irq-affinity.service
/usr/local/bin/set-irq-affinity.sh

echo ""
echo "=== HFT Optimization Complete ==="
echo ""
echo "Configuration Summary:"
echo "  - Kernel parameters tuned for low latency"
echo "  - HugePages: 2GB allocated (2MB pages)"
echo "  - CPU Isolation: Cores 2-7 isolated for HFT apps"
echo "  - OS/Interrupts: Cores 0-1"
echo "  - CPU Governor: Performance mode"
echo "  - Transparent HugePages: Disabled"
echo "  - Unnecessary services: Disabled"
echo ""

if [ "$REBOOT_REQUIRED" = true ]; then
    echo "⚠️  REBOOT REQUIRED to activate CPU isolation"
    echo ""
    echo "After reboot, run your HFT application with CPU affinity:"
    echo "  taskset -c 2-7 ./your-hft-app"
else
    echo "✓ All optimizations applied"
    echo ""
    echo "Run your HFT application with CPU affinity:"
    echo "  taskset -c 2-7 ./your-hft-app"
fi
echo ""
