#!/bin/bash
# Network Interface Tuning for HFT
# Usage: ./tune-network-interface.sh <interface_name>

IFACE=$1

if [ -z "$IFACE" ]; then
    echo "Usage: $0 <interface_name>"
    echo ""
    echo "Available interfaces:"
    ip link show | grep -E '^[0-9]+:' | awk -F': ' '{print "  " $2}'
    exit 1
fi

if ! ip link show $IFACE &>/dev/null; then
    echo "Error: Interface $IFACE not found"
    exit 1
fi

echo "=== Tuning Network Interface: $IFACE ==="
echo ""

# Increase ring buffer sizes
echo "[1/5] Increasing ring buffer sizes..."
ethtool -G $IFACE rx 4096 tx 4096 2>/dev/null || echo "  (not supported or already at max)"

# Disable offloading features (reduce latency at cost of CPU)
echo "[2/5] Disabling offloading features..."
ethtool -K $IFACE gro off
ethtool -K $IFACE lro off
ethtool -K $IFACE tso off
ethtool -K $IFACE gso off
ethtool -K $IFACE ufo off 2>/dev/null || true

# Enable hardware timestamping if available
echo "[3/5] Checking hardware timestamping..."
if ethtool -T $IFACE 2>/dev/null | grep -q "hardware-transmit"; then
    echo "  ✓ Hardware timestamping available"
else
    echo "  ⚠ Hardware timestamping not available"
fi

# Set interrupt coalescing for low latency
echo "[4/5] Setting interrupt coalescing..."
ethtool -C $IFACE rx-usecs 0 tx-usecs 0 2>/dev/null || echo "  (not supported)"

# Set to 10Gbps if available
echo "[5/5] Checking link speed..."
SPEED=$(ethtool $IFACE | grep "Speed:" | awk '{print $2}')
echo "  Current speed: $SPEED"

# Create systemd service to make changes persistent
cat > /etc/systemd/system/tune-nic-${IFACE}.service << EOF
[Unit]
Description=Network Interface Tuning for HFT ($IFACE)
After=network.target

[Service]
Type=oneshot
ExecStart=/usr/sbin/ethtool -G $IFACE rx 4096 tx 4096
ExecStart=/usr/sbin/ethtool -K $IFACE gro off lro off tso off gso off
ExecStart=/usr/sbin/ethtool -C $IFACE rx-usecs 0 tx-usecs 0
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable tune-nic-${IFACE}.service

echo ""
echo "✓ Network interface $IFACE tuned for low latency"
echo "  Changes will persist across reboots"
echo ""
