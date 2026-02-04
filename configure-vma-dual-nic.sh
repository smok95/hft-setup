#!/bin/bash
# Configure VMA for Dual-NIC Setup
# Usage: ./configure-vma-dual-nic.sh <nic1> <nic2>

NIC1=$1
NIC2=$2

if [ -z "$NIC1" ] || [ -z "$NIC2" ]; then
    echo "Usage: $0 <nic1> <nic2>"
    echo ""
    echo "Both arguments must be Mellanox/NVIDIA RDMA-capable interfaces."
    echo "Intel X710 and other non-RDMA NICs should be tuned separately"
    echo "with tune-network-interface.sh instead."
    echo ""
    echo "Available interfaces (with drivers):"
    for iface in $(ip link show | grep -E '^[0-9]+:' | awk -F': ' '{print $2}' | grep -v lo); do
        driver=$(ethtool -i $iface 2>/dev/null | grep driver | awk '{print $2}')
        echo "  $iface (driver: $driver)"
    done
    exit 1
fi

# Validate that both NICs are Mellanox/NVIDIA RDMA NICs
for NIC in $NIC1 $NIC2; do
    DRIVER=$(ethtool -i $NIC 2>/dev/null | grep driver | awk '{print $2}')
    if [[ "$DRIVER" != *"mlx"* ]]; then
        echo "Error: $NIC uses driver '$DRIVER', which is not a Mellanox/NVIDIA RDMA driver."
        echo "  VMA kernel-bypass requires mlx4_en or mlx5_en."
        echo "  Use tune-network-interface.sh for non-RDMA NICs like Intel X710."
        exit 1
    fi
done

echo "=== VMA Dual-NIC Configuration ==="
echo ""
echo "NIC 1: $NIC1"
echo "NIC 2: $NIC2"
echo ""

# Check if VMA is installed
if ! command -v vma_stats &> /dev/null; then
    echo "Error: VMA not installed. Run ./install-vma.sh first"
    exit 1
fi

# Get IPs and interface info
NIC1_IP=$(ip addr show $NIC1 | grep "inet " | awk '{print $2}' | cut -d/ -f1)
NIC2_IP=$(ip addr show $NIC2 | grep "inet " | awk '{print $2}' | cut -d/ -f1)

echo "NIC 1 IP: ${NIC1_IP:-Not configured}"
echo "NIC 2 IP: ${NIC2_IP:-Not configured}"
echo ""

# Create advanced VMA configuration for dual-NIC
cat > /etc/libvma.conf << EOF
# VMA Configuration for Dual-NIC HFT Setup
# NIC1: $NIC1 (${NIC1_IP:-unconfigured})
# NIC2: $NIC2 (${NIC2_IP:-unconfigured})

# Enable VMA for all TCP/UDP traffic
VMA_SPEC=tcp:*:*,udp:*:*

# Ultra-low latency mode
VMA_RX_POLL=-1
VMA_RX_POLL_INIT=-1
VMA_RX_POLL_NUM=100000000
VMA_SELECT_POLL=-1
VMA_SELECT_POLL_NUM=100000000

# Thread mode - use application threads
VMA_THREAD_MODE=1
VMA_INTERNAL_THREAD_AFFINITY=-1

# Skip OS for RX (kernel bypass)
VMA_RX_SKIP_OS=1

# Ring buffers
VMA_RX_WRE=2048
VMA_TX_WRE=2048
VMA_RX_WRE_BATCHING=64

# Ring allocation per interface
VMA_RING_ALLOCATION_LOGIC_RX=20
VMA_RING_ALLOCATION_LOGIC_TX=20
VMA_RING_MIGRATION_RATIO_RX=-1
VMA_RING_MIGRATION_RATIO_TX=-1

# Striding RQ - only supported on ConnectX-5 and newer
# Disabled for ConnectX-4; re-enable if you upgrade hardware
VMA_STRQ=0

# HugePages (must be configured in system)
VMA_HUGETLB=1

# Memory allocation
VMA_MEM_ALLOC_TYPE=1
VMA_FORK_SAFE=0

# TCP optimizations
VMA_TCP_TIMESTAMP_OPTION=0
VMA_TCP_NODELAY=1
VMA_TCP_QUICKACK=1
VMA_TCP_ABORT_ON_CLOSE=1

# Zero-copy
VMA_RX_BYTES_MIN=1
VMA_TX_BUFS_BATCH_UDP=16
VMA_TX_BUFS_BATCH_TCP=16

# Disable statistics collection for lowest latency
VMA_CPU_USAGE_STATS=0
VMA_STATS_FD_NUM=0

# Socketxtreme API support
VMA_SOCKETXTREME=1

# Multi-ring support for dual NIC
VMA_RING_DEV_MEM_TX=2097152

# Logging (set to 2 for errors only, 3 for info, 4+ for debug)
VMA_TRACELEVEL=2
VMA_LOG_FILE=/var/log/vma.log
VMA_LOG_DETAILS=0

# Disable GRO receive
VMA_GRO_STREAMS_MAX=0
EOF

echo "✓ Created /etc/libvma.conf with dual-NIC optimizations"
echo ""

# Create helper script for running apps with VMA
cat > /usr/local/bin/run-with-vma.sh << 'EOF'
#!/bin/bash
# Helper script to run HFT applications with VMA

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
EOF

chmod +x /usr/local/bin/run-with-vma.sh
echo "✓ Created helper script: /usr/local/bin/run-with-vma.sh"
echo ""

# Create systemd service template for VMA apps
cat > /etc/systemd/system/vma-app@.service << 'EOF'
[Unit]
Description=VMA-enabled HFT Application: %i
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=/opt/hft-apps
Environment="LD_PRELOAD=/usr/lib64/libvma.so"
Environment="VMA_CONFIG_FILE=/etc/libvma.conf"
Environment="VMA_TRACELEVEL=2"
ExecStart=/usr/local/bin/run-with-vma.sh /opt/hft-apps/%i
Restart=on-failure
RestartSec=5s

# CPU isolation
CPUAffinity=2-7

# Real-time priority
CPUSchedulingPolicy=fifo
CPUSchedulingPriority=99

# Memory locking
LimitMEMLOCK=infinity
LimitSTACK=infinity

[Install]
WantedBy=multi-user.target
EOF

echo "✓ Created systemd service template: vma-app@.service"
echo ""

echo "=== Configuration Complete ==="
echo ""
echo "Usage examples:"
echo ""
echo "1. Run application with VMA (quick test):"
echo "   run-with-vma.sh ./your-hft-app"
echo ""
echo "2. Run with debug logging:"
echo "   VMA_TRACELEVEL=4 run-with-vma.sh ./your-hft-app"
echo ""
echo "3. Check VMA statistics:"
echo "   vma_stats -p \$(pgrep your-hft-app)"
echo ""
echo "4. Setup as systemd service:"
echo "   cp your-hft-app /opt/hft-apps/"
echo "   systemctl enable vma-app@your-hft-app"
echo "   systemctl start vma-app@your-hft-app"
echo ""
echo "Next steps:"
echo "  1. Tune both NICs: ./tune-network-interface.sh $NIC1"
echo "                     ./tune-network-interface.sh $NIC2"
echo "  2. Test VMA: vma_stats -v"
echo "  3. Run your application with run-with-vma.sh"
echo ""
