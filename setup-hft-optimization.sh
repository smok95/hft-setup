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

# 1. Disable SELinux
echo "[1/8] Disabling SELinux..."
if command -v getenforce &>/dev/null; then
    CURRENT_SELINUX=$(getenforce)
    if [ "$CURRENT_SELINUX" != "Disabled" ]; then
        # Set to permissive immediately (no reboot needed)
        setenforce 0
        # Disable permanently
        sed -i 's/^SELINUX=.*/SELINUX=disabled/' /etc/selinux/config
        echo "  - SELinux: $CURRENT_SELINUX -> Disabled (permanent)"
        REBOOT_REQUIRED=true
    else
        echo "  - SELinux already disabled"
    fi
else
    echo "  - SELinux not installed, skipping"
fi

# 2. Apply sysctl parameters
echo "[2/8] Applying kernel parameters..."
cp hft-sysctl.conf /etc/sysctl.d/99-hft.conf
sysctl -p /etc/sysctl.d/99-hft.conf

# 3. Configure HugePages (2GB total, using 2MB pages = 1024 pages)
echo "[3/8] Configuring HugePages..."
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
echo "[4/8] Setting up CPU isolation..."
# CPU generation detection for proper intel_pstate mode
# 12th+ gen Intel (Alder Lake, model 0xB7, stepping 1) requires intel_pstate=passive on older kernels
# kernel 5.14 doesn't fully support Alder Lake HWP, so use passive mode
CPU_FAMILY=$(cat /proc/cpuinfo | grep "cpu family" | head -1 | awk '{print $3}')
CPU_MODEL=$(cat /proc/cpuinfo | grep "model" | head -1 | awk '{print $3}')
# Alder Lake: family 6, model 0xB7 (183), stepping 1
# Raptor Lake: family 6, model 0xB7 (183), stepping 2-4 or model 0xBA (186)
# Sapphire Rapids: family 6, model 0x8F (143)
IS_12TH_GEN=false
if [ "$CPU_FAMILY" = "6" ]; then
    case "$CPU_MODEL" in
        183|186|143) IS_12TH_GEN=true ;;
    esac
fi

if [ "$IS_12TH_GEN" = "true" ]; then
    # 12th+ gen Intel: use passive mode (allows acpi-cpufreq fallback if intel_pstate unsupported)
    PSTATE_MODE="passive"
    echo "  - Detected 12th+ gen Intel CPU (model $CPU_MODEL), using intel_pstate=passive"
else
    PSTATE_MODE="active"
    echo "  - Using intel_pstate=active for HWP support"
fi

# msr.allow_writes=1: Enable MSR writes for C1E/HWP control (required for HFT MSR tuning)
# idle=poll removed: allows OS dynamic control of C-states via BIOS enabled settings
HFT_ARGS="isolcpus=2-7 nohz_full=2-7 rcu_nocbs=2-7 intel_idle.max_cstate=1 processor.max_cstate=1 intel_pstate=$PSTATE_MODE nosoftlockup skew_tick=1 msr.allow_writes=1"
GRUB_FILE="/etc/default/grub"
if ! grep -q "isolcpus" $GRUB_FILE; then
    sed -i 's/GRUB_CMDLINE_LINUX="/GRUB_CMDLINE_LINUX="'"$HFT_ARGS"' /' $GRUB_FILE
    echo "  - Isolated CPUs 2-7 for HFT applications"
    echo "  - CPUs 0-1 reserved for OS/interrupts"
    grub2-mkconfig -o /boot/grub2/grub.cfg

    # Rocky Linux 9 / RHEL 9 uses BLS (Boot Loader Specification).
    # grub2-mkconfig updates grub.cfg but BLS entry files in
    # /boot/loader/entries/ control the actual kernel cmdline.
    # Use grubby to update BLS entries directly (DEFAULT kernel only,
    # skip rescue entries).
    if command -v grubby &>/dev/null; then
        grubby --update-kernel=DEFAULT --args="$HFT_ARGS"
        echo "  - BLS entry updated via grubby"
    fi

    REBOOT_REQUIRED=true
fi

# 4. Disable transparent hugepages
echo "[5/8] Disabling transparent hugepages..."
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

# 5. Set CPU governor to performance and lock frequencies
echo "[6/8] Setting CPU governor to performance and locking frequencies..."
for cpu in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
    if [ -f "$cpu" ]; then
        echo performance > $cpu
    fi
done

# Lock min_freq = max_freq to prevent frequency scaling
# Critical for HFT: all cores must run at max frequency consistently
for cpu in /sys/devices/system/cpu/cpu*/cpufreq/scaling_max_freq; do
    if [ -f "$cpu" ]; then
        max_freq=$(cat "$cpu")
        cpu_dir=$(dirname "$cpu")
        min_freq_file="$cpu_dir/scaling_min_freq"
        if [ -f "$min_freq_file" ]; then
            echo "$max_freq" > "$min_freq_file"
            echo "  - $(basename $cpu_dir): locked at $max_freq kHz"
        fi
    fi
done

# Set Package-level HWP EPP to performance (0)
# Required for 12th+ gen Intel CPUs (Alder Lake, Raptor Lake) where HWP overrides governor
# Works only when intel_pstate=active and HWP is available
if command -v x86_energy_perf_policy &>/dev/null; then
    pstate_status=$(cat /sys/devices/system/cpu/intel_pstate/status 2>/dev/null)
    if [ "$pstate_status" = "active" ]; then
        x86_energy_perf_policy --pkg 0 --hwp-epp 0 --force 2>/dev/null
        echo "  - Package HWP EPP set to 0 (performance mode)"
    else
        # intel_pstate=passive or unsupported: governor-based control works
        echo "  - intel_pstate mode: $pstate_status (governor-based frequency control)"
    fi
fi

# Make persistent
cat > /usr/local/bin/disable-c1e-msr.sh << 'EOFMSR'
#!/bin/bash
# Disable C1E auto-promotion via MSR 0x1FC
# This prevents CPU from dropping to C1E state during idle periods
# For HFT: bit 0 = 0 disables C1E auto-promotion
if [ -e /dev/cpu/0/msr ] && command -v rdmsr >/dev/null && command -v wrmsr >/dev/null; then
    # Read current MSR 0x1FC value and clear bit 0
    for cpu in $(ls /dev/cpu/ | grep -E '^[0-9]+$'); do
        val=$(rdmsr -p $cpu 0x1fc 2>/dev/null)
        if [ -n "$val" ]; then
            # Convert hex to decimal, clear bit 0, convert back to hex
            val_dec=$(printf "%d" "0x$val")
            new_dec=$((val_dec & 0xFFFFFFFFFFFFFFFE))
            new_hex=$(printf "%x" $new_dec)
            wrmsr -p $cpu 0x1fc $new_hex 2>/dev/null || true
        fi
    done
    echo "MSR 0x1FC C1E auto-promotion disabled on all CPUs"
fi
EOFMSR
chmod +x /usr/local/bin/disable-c1e-msr.sh

cat > /etc/systemd/system/cpu-performance.service << EOF
[Unit]
Description=Set CPU Governor to Performance and Lock Frequencies
After=network.target

[Service]
Type=oneshot
# Set performance governor (works with acpi-cpufreq or intel_pstate=passive)
ExecStart=/bin/bash -c 'for cpu in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do [ -f \$cpu ] && echo performance > \$cpu; done'
# Lock min_freq = max_freq to prevent frequency scaling
ExecStart=/bin/bash -c 'for cpu in /sys/devices/system/cpu/cpu*/cpufreq/scaling_max_freq; do [ -f \$cpu ] && cat \$cpu > \$(dirname \$cpu)/scaling_min_freq; done'
# Set Package HWP EPP for 12th+ gen Intel CPUs (only when intel_pstate=active)
ExecStart=/bin/bash -c 'command -v x86_energy_perf_policy >/dev/null && [ "\$(cat /sys/devices/system/cpu/intel_pstate/status 2>/dev/null)" = "active" ] && x86_energy_perf_policy --pkg 0 --hwp-epp 0 --force'
# Disable C1E auto-promotion via MSR 0x1FC (requires msr.allow_writes=1 kernel param)
ExecStart=/usr/local/bin/disable-c1e-msr.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable cpu-performance.service

# 6. Disable unnecessary services
echo "[7/8] Disabling unnecessary services..."
SERVICES_TO_DISABLE=(
    "firewalld"
    "bluetooth"
    "cups"
    "avahi-daemon"
    "ModemManager"
    "irqbalance"
    "dnf-makecache.timer"  # Prevents network timeouts on offline servers
)

for service in "${SERVICES_TO_DISABLE[@]}"; do
    if systemctl is-enabled $service 2>/dev/null | grep -q enabled; then
        systemctl disable $service
        systemctl stop $service 2>/dev/null || true
        echo "  - Disabled $service"
    fi
done

# 7. IRQ Affinity (bind to CPUs 0-1)
echo "[8/8] Configuring IRQ affinity..."
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
echo "  - SELinux: Disabled"
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
