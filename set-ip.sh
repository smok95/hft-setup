#!/bin/bash
# NIC IP Address Configuration Script
# Usage: ./set-ip.sh <interface> <ip/cidr> [gateway] [dns]

set -e

IFACE=$1
IP_CIDR=$2
GATEWAY=$3
DNS=$4

print_usage() {
    echo "Usage: $0 <interface> <ip/cidr> [gateway] [dns]"
    echo ""
    echo "Examples:"
    echo "  $0 ens1f0 192.168.1.100                      # /24 is default"
    echo "  $0 ens1f0 192.168.1.100 192.168.1.1          # with gateway"
    echo "  $0 ens1f0 192.168.1.100 192.168.1.1 8.8.8.8  # with gateway + dns"
    echo "  $0 ens1f0 10.0.0.50/16 10.0.0.1              # custom prefix"
    echo ""
    echo "Available interfaces:"
    echo "-------------------------------------------------------------------"
    printf "%-15s %-10s %-18s %s\n" "INTERFACE" "STATE" "MAC" "CURRENT IP"
    echo "-------------------------------------------------------------------"
    for iface in $(ls /sys/class/net/ | grep -v lo); do
        state=$(cat /sys/class/net/$iface/operstate 2>/dev/null || echo "unknown")
        mac=$(cat /sys/class/net/$iface/address 2>/dev/null || echo "N/A")
        current_ip=$(ip -4 addr show $iface 2>/dev/null | awk '/inet / {print $2}' | head -1)
        [ -z "$current_ip" ] && current_ip="-"
        printf "%-15s %-10s %-18s %s\n" "$iface" "$state" "$mac" "$current_ip"
    done
    echo "-------------------------------------------------------------------"
}

if [ "$EUID" -ne 0 ]; then
    echo "Error: This script must be run as root"
    exit 1
fi

if [ -z "$IFACE" ] || [ -z "$IP_CIDR" ]; then
    print_usage
    exit 1
fi

# Validate interface exists
if ! ip link show "$IFACE" &>/dev/null; then
    echo "Error: Interface $IFACE not found"
    echo ""
    print_usage
    exit 1
fi

# Add default /24 if no prefix specified
if ! echo "$IP_CIDR" | grep -q '/'; then
    IP_CIDR="${IP_CIDR}/24"
fi

# Validate IP/CIDR format
if ! echo "$IP_CIDR" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$'; then
    echo "Error: Invalid IP format: $IP_CIDR"
    echo "Expected format: x.x.x.x or x.x.x.x/prefix"
    exit 1
fi

IP_ADDR=$(echo "$IP_CIDR" | cut -d'/' -f1)
PREFIX=$(echo "$IP_CIDR" | cut -d'/' -f2)

echo "=== Configuring IP for: $IFACE ==="
echo ""
echo "  IP Address: $IP_ADDR"
echo "  Prefix:     /$PREFIX"
[ -n "$GATEWAY" ] && echo "  Gateway:    $GATEWAY"
[ -n "$DNS" ] && echo "  DNS:        $DNS"
echo ""

# Check if NetworkManager is running
if ! systemctl is-active --quiet NetworkManager; then
    echo "Error: NetworkManager is not running"
    echo "Starting NetworkManager..."
    systemctl start NetworkManager
fi

# Get or create connection name
CONN_NAME=$(nmcli -t -f NAME,DEVICE con show | grep ":${IFACE}$" | cut -d':' -f1 | head -1)

if [ -z "$CONN_NAME" ]; then
    CONN_NAME="$IFACE"
    echo "[1/4] Creating new connection: $CONN_NAME"
    nmcli con add type ethernet ifname "$IFACE" con-name "$CONN_NAME"
else
    echo "[1/4] Using existing connection: $CONN_NAME"
fi

# Configure IP address
echo "[2/4] Setting IP address..."
nmcli con mod "$CONN_NAME" ipv4.addresses "$IP_CIDR"
nmcli con mod "$CONN_NAME" ipv4.method manual

# Configure gateway if provided
if [ -n "$GATEWAY" ]; then
    echo "[3/4] Setting gateway..."
    nmcli con mod "$CONN_NAME" ipv4.gateway "$GATEWAY"
else
    echo "[3/4] No gateway specified (skipping)"
    nmcli con mod "$CONN_NAME" ipv4.gateway ""
fi

# Configure DNS if provided
if [ -n "$DNS" ]; then
    echo "[4/4] Setting DNS..."
    nmcli con mod "$CONN_NAME" ipv4.dns "$DNS"
else
    echo "[4/4] No DNS specified (skipping)"
fi

# Apply configuration
echo ""
echo "Applying configuration..."
nmcli con up "$CONN_NAME"

# Verify
echo ""
echo "=== Configuration Applied ==="
echo ""
echo "Interface: $IFACE"
echo "Connection: $CONN_NAME"
ip -4 addr show "$IFACE" | grep inet
echo ""

# Show routing if gateway was set
if [ -n "$GATEWAY" ]; then
    echo "Default route:"
    ip route show default | grep "$IFACE" || echo "  (no default route via $IFACE)"
    echo ""
fi

echo "To view: nmcli con show \"$CONN_NAME\""
echo "To delete: nmcli con delete \"$CONN_NAME\""
echo ""
