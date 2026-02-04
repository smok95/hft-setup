#!/bin/bash
# VMA (NVIDIA Messaging Accelerator) Installation and Configuration
# For use with Mellanox/NVIDIA NICs in HFT environments

set -e

echo "=== VMA Installation and Configuration ==="
echo ""

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    echo "Please run as root (sudo)"
    exit 1
fi

# Detect OS version
if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS_VERSION=$VERSION_ID
    OS_NAME=$ID
else
    echo "Cannot detect OS version"
    exit 1
fi

echo "[1/6] Installing dependencies..."
dnf install -y \
    gcc \
    gcc-c++ \
    make \
    automake \
    autoconf \
    libtool \
    libstdc++-devel \
    kernel-devel \
    numactl-devel \
    libibverbs \
    libibverbs-devel \
    librdmacm \
    librdmacm-devel \
    rdma-core \
    rdma-core-devel \
    libibverbs-utils

echo ""
echo "[2/6] Checking for Mellanox NICs..."
if lspci | grep -i mellanox; then
    echo "  ✓ Mellanox NICs detected"
else
    echo "  ⚠ No Mellanox NICs detected - VMA may not provide benefits"
fi

echo ""
echo "[3/6] Checking RDMA backend..."
# Inbox mlx5_ib is sufficient for VMA on most systems.
# MLNX_OFED provides additional features but is optional.
if lsmod | grep -q mlx5_ib; then
    echo "  ✓ Inbox mlx5_ib module loaded - RDMA backend ready"
    if rpm -qa | grep -q mlnx-ofed; then
        echo "  ✓ MLNX_OFED also installed: $(rpm -qa | grep mlnx-ofed-all)"
    else
        echo "  ℹ MLNX_OFED not installed (inbox driver is sufficient)"
    fi
elif rpm -qa | grep -q mlnx-ofed; then
    echo "  ✓ MLNX_OFED installed"
else
    echo "  ⚠ No RDMA backend found (no mlx5_ib module, no MLNX_OFED)"
    echo "  Try loading the inbox module: modprobe mlx5_ib"
    echo "  Or install MLNX_OFED from: https://network.nvidia.com/products/infiniband-drivers/linux/mlnx_ofed/"
    echo ""
    read -p "Continue anyway? (y/n) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 1
    fi
fi

echo ""
echo "[4/6] Installing libvma..."
# Try to install from repository
if dnf list libvma &>/dev/null; then
    dnf install -y libvma libvma-devel libvma-utils
    echo "  ✓ libvma installed from repository"
else
    echo "  ⚠ libvma not found in repositories"
    echo "  Please download VMA from: https://github.com/Mellanox/libvma/releases"
    echo "  Or install MLNX_OFED which includes VMA"
    exit 1
fi

echo ""
echo "[5/6] Configuring VMA for HFT..."
# Create VMA configuration file
cat > /etc/libvma.conf << 'EOF'
# VMA Configuration for HFT Low Latency

# Enable VMA for TCP and UDP
VMA_SPEC=tcp:*:*,udp:*:*

# CPU affinity - use isolated cores (2-7)
VMA_CPU_USAGE_STATS=0
VMA_RX_POLL=-1
VMA_RX_POLL_INIT=-1
VMA_RX_POLL_NUM=100000000

# Use isolated cores for VMA threads
VMA_THREAD_MODE=1
VMA_RX_SKIP_OS=1
VMA_RX_WRE=256
VMA_TX_WRE=256

# Ring allocation
VMA_RING_ALLOCATION_LOGIC_RX=10
VMA_RING_ALLOCATION_LOGIC_TX=10

# Striding RQ - only supported on ConnectX-5 and newer
# Disabled here for ConnectX-4 compatibility; enable in libvma.conf if upgraded
VMA_STRQ=0

# Disable TCP timestamps (already done in sysctl but VMA override)
VMA_TCP_TIMESTAMP_OPTION=0

# Memory registration
VMA_MEM_ALLOC_TYPE=1
VMA_FORK_SAFE=0

# HugePages support
VMA_HUGETLB=1

# Disable internal thread (use application threads)
VMA_INTERNAL_THREAD_AFFINITY=-1

# Zero-copy
VMA_RX_BYTES_MIN=65536
VMA_TX_BUFS_BATCH_UDP=8
VMA_TX_BUFS_BATCH_TCP=16

# Logging (disable for production)
VMA_TRACELEVEL=2
EOF

echo "  ✓ VMA configuration created: /etc/libvma.conf"

echo ""
echo "[6/6] Detecting network interfaces..."
echo "Available NICs:"
for iface in $(ip link show | grep -E '^[0-9]+:' | awk -F': ' '{print $2}' | grep -v lo); do
    driver=$(ethtool -i $iface 2>/dev/null | grep driver | awk '{print $2}')
    echo "  - $iface (driver: $driver)"
done

echo ""
echo "=== VMA Installation Complete ==="
echo ""
echo "To verify VMA installation:"
echo "  vma_stats -v"
echo ""
echo "To run your HFT application with VMA:"
echo "  VMA_TRACELEVEL=3 LD_PRELOAD=libvma.so taskset -c 2-7 ./your-hft-app"
echo ""
echo "For production (no logging):"
echo "  LD_PRELOAD=libvma.so taskset -c 2-7 ./your-hft-app"
echo ""
echo "To check VMA is loaded:"
echo "  VMA_STATS_FILE=/tmp/vma_stats.txt LD_PRELOAD=libvma.so ./your-hft-app"
echo "  cat /tmp/vma_stats.txt"
echo ""
echo "⚠️  Important:"
echo "  - Ensure MLNX_OFED drivers are installed for best performance"
echo "  - VMA works best with Mellanox ConnectX-4 or newer NICs"
echo "  - Configure your NICs with tune-network-interface.sh"
echo ""
