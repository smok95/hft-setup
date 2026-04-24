#!/bin/bash
# Server Preparation Script - Pre-HFT Setup
# Performs basic Linux server configuration before HFT optimization
#
# Usage: sudo ./prepare-server.sh
#
# This script handles:
#   1. NetworkManager autoconnect configuration (fixes RHEL/Rocky Server default)
#   2. (Future: other basic server prep tasks)

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

print_header() {
    echo ""
    echo "==================================================================="
    echo "  $1"
    echo "==================================================================="
    echo ""
}

print_status() {
    printf "${GREEN}[OK]${NC} %s\n" "$1"
}

print_warning() {
    printf "${YELLOW}[WARN]${NC} %s\n" "$1"
}

print_error() {
    printf "${RED}[ERROR]${NC} %s\n" "$1"
}

# Check root privileges
if [ "$EUID" -ne 0 ]; then
    print_error "This script must be run as root"
    echo "Usage: sudo ./prepare-server.sh"
    exit 1
fi

print_header "Server Preparation Script"

echo "This script prepares basic server configuration before HFT optimization."
echo ""

# ============================================================================
# STEP 1: NetworkManager Autoconnect Configuration
# ============================================================================
echo "[Step 1] NetworkManager Autoconnect Configuration"
echo ""

# Check if NetworkManager is running
if ! systemctl is-active --quiet NetworkManager; then
    print_warning "NetworkManager is not running"
    echo "Starting NetworkManager..."
    systemctl start NetworkManager
    sleep 2
fi

# Check for NetworkManager-config-server package (causes autoconnect=false)
if rpm -q NetworkManager-config-server &>/dev/null; then
    echo "Detected: NetworkManager-config-server package installed"
    echo "  This package sets 'no-auto-default=*' in NetworkManager config"
    echo "  causing connections to be created with autoconnect=false"
    echo ""
fi

# Find connections with autoconnect=false
DISABLED_CONNS=$(nmcli -t -f NAME,AUTOCONNECT connection show | grep ':no$' | cut -d':' -f1)

if [ -z "$DISABLED_CONNS" ]; then
    print_status "All connections already have autoconnect=yes"
else
    echo "Found connections with autoconnect=false:"
    echo ""
    for conn in $DISABLED_CONNS; do
        echo "  - $conn"
    done
    echo ""
    echo "Enabling autoconnect for all connections..."
    echo ""

    for conn in $DISABLED_CONNS; do
        nmcli connection modify "$conn" connection.autoconnect yes && \
            print_status "$conn: autoconnect enabled" || \
            print_error "$conn: failed to enable autoconnect"
    done
fi

echo ""
echo "Current autoconnect status:"
echo ""
nmcli -f NAME,AUTOCONNECT,AUTOCONNECT-PRIORITY connection show
echo ""

print_header "Server Preparation Complete"
echo "Next steps:"
echo "  1. Run: sudo ./setup-hft-optimization.sh"
echo "  2. Reboot: sudo reboot"
echo "  3. After reboot: sudo ./verify-hft-setup.sh"
echo ""