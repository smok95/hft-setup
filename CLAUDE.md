# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository Purpose

This repository contains scripts for configuring Linux servers for High-Frequency Trading (HFT) applications with ultra-low latency optimizations. The setup targets 8-core systems (isolating cores 2-7 for HFT apps while reserving cores 0-1 for OS tasks) with dual-NIC support and VMA (NVIDIA Messaging Accelerator) for kernel-bypass networking.

## Key Commands

### Initial Setup
```bash
# Run main optimization script (requires root and reboot)
sudo ./setup-hft-optimization.sh
sudo reboot

# Verify configuration after reboot (shows per-NIC driver and VMA status)
sudo ./verify-hft-setup.sh

# Tune ALL network interfaces with ethtool (every port, every NIC type)
sudo ./tune-network-interface.sh <mlx_port1>
sudo ./tune-network-interface.sh <mlx_port2>
sudo ./tune-network-interface.sh <x710_port1>
sudo ./tune-network-interface.sh <x710_port2>

# Install VMA for Mellanox/NVIDIA NICs (optional but recommended)
sudo ./install-vma.sh

# Configure VMA for the two Mellanox ports only (script validates mlx driver)
sudo ./configure-vma-dual-nic.sh <mlx_port1> <mlx_port2>
```

### Testing Scripts
```bash
# Check all optimizations are applied
sudo ./verify-hft-setup.sh

# View IRQ distribution in real-time
watch -n1 'cat /proc/interrupts'

# Monitor CPU usage per core
mpstat -P ALL 1

# Check HugePage allocation
grep Huge /proc/meminfo

# Verify VMA installation and version
vma_stats -v

# Run application with VMA
run-with-vma.sh ./your-hft-app

# Check VMA statistics for running process
vma_stats -p $(pgrep your-hft-app)
```

## Architecture Overview

### Script Hierarchy

1. **setup-hft-optimization.sh** - Main orchestration script that:
   - Applies kernel parameters from `hft-sysctl.conf`
   - Configures CPU isolation via GRUB boot parameters
   - Sets up HugePages (2GB using 2MB pages = 1024 pages)
   - Creates systemd services for persistent configuration
   - Configures IRQ affinity to pin interrupts to CPUs 0-1

2. **hft-sysctl.conf** - Kernel tuning parameters for:
   - Network stack (128MB buffers, disabled TCP timestamps/SACK, rp_filter=0)
   - Memory management (swappiness=0, min free memory=1GB)
   - Scheduler tuning (disabled autogroup, RT scheduling)

3. **tune-network-interface.sh** - NIC-specific optimizations:
   - Ring buffer sizes (4096 rx/tx)
   - Disabled offloading (GRO, LRO, TSO, GSO) for lower latency
   - Zero interrupt coalescing for immediate interrupts
   - Creates per-interface systemd service for persistence

4. **verify-hft-setup.sh** - Validation script that checks:
   - CPU isolation via `/proc/cmdline`
   - CPU governor (should be 'performance')
   - HugePage allocation
   - THP disabled status
   - Network buffer sizes and IRQ affinity
   - Per-NIC driver, link speed, and VMA compatibility (mlx = VMA-capable)

5. **install-vma.sh** - VMA (NVIDIA Messaging Accelerator) setup:
   - Installs libvma and dependencies (libibverbs, libibverbs-utils, librdmacm, rdma-core)
   - Checks inbox `mlx5_ib` module first; MLNX_OFED is optional fallback
   - Creates initial `/etc/libvma.conf` with HFT-optimized settings
   - Configures kernel-bypass networking for ultra-low latency

6. **configure-vma-dual-nic.sh** - Dual-NIC VMA configuration:
   - Validates both interfaces use an mlx driver (rejects non-RDMA NICs like Intel X710)
   - Creates optimized `/etc/libvma.conf` for dual-NIC setup
   - Generates `/usr/local/bin/run-with-vma.sh` helper script
   - Creates `vma-app@.service` systemd template for VMA applications
   - Configures ring allocation, zero-copy, and SocketXtreme API
   - `VMA_STRQ` disabled by default (ConnectX-4 compatible); enable manually for ConnectX-5+

### Systemd Services Created

The setup creates these persistent services:
- `disable-thp.service` - Disables Transparent Huge Pages
- `cpu-performance.service` - Sets CPU governor to performance mode
- `irq-affinity.service` - Runs `/usr/local/bin/set-irq-affinity.sh` to pin IRQs; conflicts irqbalance
- `tune-nic-<interface>.service` - Applies NIC tuning on boot
- `vma-app@.service` - Template for running HFT applications with VMA (created by configure-vma-dual-nic.sh)

### CPU Isolation Strategy

- **Cores 0-1**: OS tasks, interrupts, system services
- **Cores 2-7**: Isolated for HFT applications (via isolcpus, nohz_full, rcu_nocbs)
- Applications must use `taskset -c 2-7 ./app` to run on isolated cores
- Optional: Use `chrt -f 99` for real-time priority

### Memory Configuration

- **HugePages**: 1024 x 2MB pages = 2GB total
  - Reduces TLB misses for better performance
  - Applications use `MAP_HUGETLB` flag with mmap()
- **THP (Transparent HugePages)**: Disabled for predictable latency
- **Swappiness**: 0 (avoid swapping)
- **Min free memory**: 1GB reserved

### VMA (NVIDIA Messaging Accelerator) Architecture

VMA provides kernel-bypass networking for Mellanox/NVIDIA NICs:

- **Kernel Bypass**: Uses RDMA verbs to bypass kernel networking stack
  - Direct hardware access via libibverbs
  - Eliminates system calls and context switches
  - Achieves sub-microsecond latencies

- **LD_PRELOAD Mechanism**: VMA intercepts socket API calls transparently
  - Applications use standard socket APIs (socket, bind, send, recv)
  - VMA redirects to RDMA-based implementation at runtime
  - No code changes required (unless using SocketXtreme API)

- **Ring Buffer Architecture**: Per-socket or per-thread completion queues
  - RX/TX rings allocated based on `VMA_RING_ALLOCATION_LOGIC`
  - Default config uses 2048 WREs (Work Request Entries) per ring
  - Striding RQ (`VMA_STRQ`) is ConnectX-5+ only; disabled by default for ConnectX-4 compatibility

- **Dual-NIC Strategy**:
  - Each Mellanox NIC gets independent ring allocations via VMA
  - Non-RDMA NICs (e.g. Intel X710) are tuned with ethtool but do not use VMA
  - IRQs already pinned to CPUs 0-1 by setup scripts
  - VMA threads use isolated cores 2-7 (via taskset in run-with-vma.sh)
  - Applications bind sockets to specific IPs; VMA intercepts only sockets on RDMA-capable ports

- **HugePages Integration**: VMA configured with `VMA_HUGETLB=1`
  - Uses system HugePages for DMA buffers
  - Reduces TLB misses in data path
  - Requires HugePages configured by setup-hft-optimization.sh

- **Running Applications with VMA**:
  ```bash
  # Basic usage
  LD_PRELOAD=libvma.so taskset -c 2-7 ./app

  # Using helper script (recommended)
  run-with-vma.sh ./app

  # As systemd service
  systemctl start vma-app@my-trading-app
  ```

## Modification Guidelines

When modifying scripts:
- All scripts require root privileges (check `$EUID -ne 0`)
- Changes to GRUB require `grub2-mkconfig -o /boot/grub2/grub.cfg` and reboot
- Systemd services need `systemctl daemon-reload` after modification
- The setup is idempotent - rerunning won't duplicate configurations
- CPU core numbers (0-1 for OS, 2-7 for HFT) are hardcoded throughout scripts

### Important File Locations
- `/etc/sysctl.d/99-hft.conf` - Applied kernel parameters
- `/etc/default/grub` - CPU isolation boot parameters
- `/usr/local/bin/set-irq-affinity.sh` - IRQ affinity script
- `/etc/security/limits.conf` - Memlock limits for HugePages
- `/etc/libvma.conf` - VMA configuration (created by configure-vma-dual-nic.sh)
- `/usr/local/bin/run-with-vma.sh` - Helper script to run apps with VMA
- `/usr/lib64/libvma.so` or `/usr/lib/libvma.so` - VMA library for LD_PRELOAD
- `/var/log/vma.log` - VMA runtime logs (if VMA_TRACELEVEL > 2)

## Platform Assumptions

- **OS**: Red Hat Enterprise Linux / Rocky Linux / AlmaLinux (uses `grub2-mkconfig`, `dnf`)
- **CPU**: Intel processors (references intel_idle, intel_pstate)
- **Cores**: 8-core system (0-7), but adaptable
- **Network**: Mixed NIC setups are supported and common:
  - Mellanox/NVIDIA ConnectX-4+ for VMA kernel-bypass (RDMA-capable, driver `mlx4_en`/`mlx5_en`)
  - Intel X710 or other standard NICs tuned via ethtool only (driver `ixgbe`)
  - VMA requires RDMA-capable NICs; inbox `mlx5_ib` module is usually sufficient, MLNX_OFED is optional
  - `configure-vma-dual-nic.sh` validates mlx driver and rejects non-RDMA interfaces
  - `VMA_STRQ` (Striding RQ) requires ConnectX-5+; disabled by default for ConnectX-4
