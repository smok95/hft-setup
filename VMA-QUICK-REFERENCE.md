# VMA Quick Reference Guide

> VMA only works with Mellanox/NVIDIA RDMA NICs (driver `mlx4_en` or `mlx5_en`).
> Intel X710 and other non-RDMA NICs must be tuned with `tune-network-interface.sh` instead.
> See the "Mixed NIC Setup" section below if you have both types.

## Installation and Setup

```bash
# 1. Install VMA
sudo ./install-vma.sh

# 2. Configure for the two Mellanox ports only
#    (the script rejects non-mlx drivers automatically)
sudo ./configure-vma-dual-nic.sh <mlx_port1> <mlx_port2>

# 3. Verify installation
vma_stats -v
```

## Running Applications with VMA

### Method 1: Using Helper Script (Recommended)
```bash
# Basic usage
run-with-vma.sh ./your-hft-app

# With debug logging
VMA_TRACELEVEL=4 run-with-vma.sh ./your-hft-app

# Custom CPU cores
VMA_CORES=3,5,7 run-with-vma.sh ./your-hft-app

# Custom RT priority
VMA_PRIORITY=80 run-with-vma.sh ./your-hft-app
```

### Method 2: Direct LD_PRELOAD
```bash
# Production (minimal logging)
LD_PRELOAD=libvma.so taskset -c 2-7 ./your-hft-app

# Development (with logging)
VMA_TRACELEVEL=3 LD_PRELOAD=libvma.so taskset -c 2-7 ./your-hft-app

# With real-time priority
chrt -f 99 taskset -c 2-7 env LD_PRELOAD=libvma.so ./your-hft-app
```

### Method 3: Systemd Service
```bash
# Setup
cp your-hft-app /opt/hft-apps/
systemctl enable vma-app@your-hft-app
systemctl start vma-app@your-hft-app

# Monitor
systemctl status vma-app@your-hft-app
journalctl -u vma-app@your-hft-app -f
```

## Monitoring and Debugging

### Check VMA is Active
```bash
# For running process
vma_stats -p $(pgrep your-hft-app)

# Should show:
# - VMA version
# - Number of sockets using VMA
# - Ring statistics
# - Packet counters
```

### View Detailed Statistics
```bash
# Save stats to file
VMA_STATS_FILE=/tmp/vma_stats.txt LD_PRELOAD=libvma.so ./your-hft-app

# View stats while running
watch -n1 'vma_stats -p $(pgrep your-hft-app)'
```

### Enable Debug Logging
```bash
# Log levels:
# 0 = PANIC (fatal errors only)
# 1 = ERROR
# 2 = WARN (default)
# 3 = INFO
# 4 = DEBUG
# 5+ = MORE DEBUG

# Set in environment
VMA_TRACELEVEL=4 LD_PRELOAD=libvma.so ./your-hft-app

# Or in /etc/libvma.conf
echo "VMA_TRACELEVEL=4" >> /etc/libvma.conf
```

### Check VMA is Intercepting Sockets
```bash
# Run with VMA_TRACELEVEL=3 and look for:
# "VMA INFO: <socket_fd> socket intercepted"
# "VMA INFO: using VMA for socket"

# If you see "socket not offloaded", check:
# 1. NIC supports RDMA (ibv_devices should list devices)
# 2. Application is using TCP/UDP (not UNIX sockets)
# 3. VMA_SPEC matches your traffic pattern
```

## Common VMA Configuration Tuning

### Ultra-Low Latency (Aggressive Polling)
```bash
# In /etc/libvma.conf
VMA_RX_POLL=-1              # Infinite polling
VMA_RX_POLL_NUM=100000000   # High poll count
VMA_SELECT_POLL=-1          # Poll on select()
VMA_RX_SKIP_OS=1            # Skip kernel completely
VMA_THREAD_MODE=1           # Use application threads
```

### Balanced (Some CPU Savings)
```bash
VMA_RX_POLL=100000          # Poll for 100ms
VMA_RX_POLL_NUM=100000
VMA_SELECT_POLL=100000
VMA_RX_SKIP_OS=1
VMA_THREAD_MODE=0           # Use VMA internal thread
```

### High Throughput (Large Messages)
```bash
VMA_RX_WRE=4096             # More RX descriptors
VMA_TX_WRE=4096             # More TX descriptors
VMA_STRQ=1                  # Striding RQ -- ConnectX-5+ ONLY, leave 0 on ConnectX-4
VMA_STRQ_STRIDES_NUM=4096   # More strides (only effective when VMA_STRQ=1)
VMA_TX_BUFS_BATCH_TCP=32    # Batch more TX
```

## Troubleshooting

### Issue: VMA Not Loading
```bash
# Check libvma.so exists
ls -l /usr/lib64/libvma.so /usr/lib/libvma.so

# Check dependencies
ldd /usr/lib64/libvma.so

# Install missing dependencies
sudo dnf install libibverbs librdmacm rdma-core
```

### Issue: No RDMA Devices Found
```bash
# List RDMA devices
ibv_devices

# If ibv_devices command is missing:
sudo dnf install libibverbs-utils

# Should show your Mellanox NICs (e.g. mlx5_0, mlx5_1)
# If empty after install:
# 1. Check inbox module is loaded: lsmod | grep mlx5_ib
#    If not loaded: modprobe mlx5_ib
# 2. Verify NIC is detected: lspci | grep -i mellanox
# 3. If inbox module won't load, install MLNX_OFED as fallback:
#    Download from https://network.nvidia.com/products/infiniband-drivers/linux/mlnx_ofed/
```

### Issue: Poor Performance
```bash
# Check if sockets are actually offloaded
vma_stats -p $(pgrep your-app) | grep "offloaded"

# Check for OS fallback
grep "fallback" /var/log/vma.log

# Verify CPU isolation
cat /proc/cmdline | grep isolcpus
ps -eLo pid,psr,comm | grep your-app  # Should show CPUs 2-7

# Check IRQ affinity
cat /proc/interrupts | grep mlx5
# IRQs should be on CPUs 0-1 only
```

### Issue: Application Crashes
```bash
# Common causes:
# 1. Insufficient memlock limit
ulimit -l unlimited

# 2. No HugePages available
grep Huge /proc/meminfo

# 3. VMA version mismatch with MLNX_OFED
rpm -qa | grep -E "libvma|mlnx"

# Run with debug to see crash location
VMA_TRACELEVEL=4 LD_PRELOAD=libvma.so gdb ./your-app
```

## Environment Variables Reference

### Key VMA Variables
```bash
# Must-have for VMA to work
LD_PRELOAD=/usr/lib64/libvma.so

# Configuration file
VMA_CONFIG_FILE=/etc/libvma.conf

# Logging
VMA_TRACELEVEL=2                    # Log level (0-5+)
VMA_LOG_FILE=/var/log/vma.log       # Log file path
VMA_LOG_DETAILS=0                   # Detailed logging (0/1)

# Socket specification (which sockets to offload)
VMA_SPEC=tcp:*:*,udp:*:*           # All TCP/UDP sockets

# Performance
VMA_RX_POLL=-1                      # RX poll mode (-1 = infinite)
VMA_RX_SKIP_OS=1                    # Bypass kernel (0/1)
VMA_THREAD_MODE=1                   # Thread mode (0/1/2)

# Memory
VMA_HUGETLB=1                       # Use HugePages (0/1)
VMA_MEM_ALLOC_TYPE=1                # Memory allocation type

# Statistics
VMA_STATS_FILE=/tmp/vma_stats.txt   # Stats output file
```

## Performance Verification

### Latency Test
```bash
# Install sockperf (included with VMA)
which sockperf

# Server
taskset -c 2 sockperf sr -p 11111

# Client (from another machine)
taskset -c 2 sockperf ping-pong -i <server_ip> -p 11111 -t 60

# With VMA on Mellanox port (expect ~2-5us on ConnectX-4, ~1-2us on ConnectX-5+)
taskset -c 2 LD_PRELOAD=libvma.so sockperf ping-pong -i <server_ip> -p 11111 -t 60
```

### Throughput Test
```bash
# Server
taskset -c 2-7 LD_PRELOAD=libvma.so sockperf sr -p 11111

# Client
taskset -c 2-7 LD_PRELOAD=libvma.so sockperf throughput -i <server_ip> -p 11111 -t 60 -m 1024
```

## Best Practices

1. **Always use CPU isolation**: Run VMA apps on cores 2-7 only
2. **Use HugePages**: VMA_HUGETLB=1 significantly improves performance
3. **Pin IRQs**: Keep NIC interrupts on cores 0-1 (done by setup scripts)
4. **Disable offloads**: GRO, LRO, TSO, GSO all disabled (done by tune-network-interface.sh)
5. **Use real-time priority**: chrt -f 99 for lowest latency
6. **Monitor statistics**: Regular vma_stats checks to verify offload
7. **Start with conservative config**: Then tune VMA_RX_POLL based on CPU budget
8. **Test without VMA first**: Establish baseline before enabling VMA
9. **Check MLNX_OFED version**: Use latest stable MLNX_OFED for your NIC
10. **Use SocketXtreme API**: For absolute minimum latency (requires code changes)
11. **Know your NIC generation**: ConnectX-4 does not support Striding RQ (`VMA_STRQ`). Enable only after upgrading to ConnectX-5+.

## Mixed NIC Setup (Mellanox + Intel X710)

If your server has both Mellanox RDMA NICs and standard NICs (e.g. Intel X710),
the priority is to get VMA kernel-bypass working on the Mellanox ports first,
then tune the remaining ports with ethtool.

| NIC | VMA? | Steps |
|---|---|---|
| Mellanox ConnectX-4/5 | Yes | `tune-network-interface.sh` + `install-vma.sh` + `configure-vma-dual-nic.sh` |
| Intel X710 | No | `tune-network-interface.sh` only |

- `tune-network-interface.sh` should be run on every port (Mellanox included).
- `configure-vma-dual-nic.sh` takes only the two Mellanox port names. It validates
  the driver and exits with an error if you pass a non-mlx interface.
- At runtime VMA intercepts sockets transparently by interface. Sockets bound to
  X710 addresses use the kernel stack automatically -- no branching in app code.

## Additional Resources

- VMA GitHub: https://github.com/Mellanox/libvma
- NVIDIA Networking Docs: https://docs.nvidia.com/networking/
- MLNX_OFED Downloads: https://network.nvidia.com/products/infiniband-drivers/linux/mlnx_ofed/
- VMA Tuning Guide: Check `/usr/share/doc/libvma/` after installation
