# HFT Linux Server Optimization Guide

## Quick Start

1. **Run the main setup script** (requires root):
   ```bash
   chmod +x *.sh
   sudo ./setup-hft-optimization.sh
   ```

2. **Reboot the server** to activate CPU isolation:
   ```bash
   sudo reboot
   ```

3. **Verify the setup** after reboot (also shows detected NICs and drivers):
   ```bash
   sudo ./verify-hft-setup.sh
   ```

4. **Tune all network interfaces** with ethtool (run for every port, regardless of NIC type):
   ```bash
   # Find your interface names and drivers
   sudo ./verify-hft-setup.sh   # look at [Network Interfaces] section
   # or: ip addr

   # Tune each port (Mellanox and Intel alike)
   sudo ./tune-network-interface.sh <mlx_port1>
   sudo ./tune-network-interface.sh <mlx_port2>
   sudo ./tune-network-interface.sh <x710_port1>
   sudo ./tune-network-interface.sh <x710_port2>
   ```

5. **Install and configure VMA** (Mellanox/NVIDIA RDMA ports only):
   ```bash
   # Install VMA and dependencies
   sudo ./install-vma.sh

   # Configure VMA for the two Mellanox ports only.
   # The script validates that both interfaces use an mlx driver
   # and will reject non-RDMA NICs (e.g. Intel X710).
   sudo ./configure-vma-dual-nic.sh <mlx_port1> <mlx_port2>

   # Verify VMA installation
   vma_stats -v
   ```

## What Gets Optimized

### 1. CPU Configuration
- **Cores 2-7**: Isolated for HFT applications (no OS interference)
- **Cores 0-1**: Reserved for OS tasks and interrupts
- **Governor**: Set to performance (no frequency scaling)
- **Scheduler**: Disabled autogroup, increased migration cost

### 2. Memory
- **HugePages**: 2GB allocated (reduces TLB misses)
- **Swappiness**: Set to 0 (avoid swap)
- **THP**: Disabled (predictable latency)
- **Min free memory**: 1GB reserved

### 3. Network Stack
- **Buffer sizes**: Maximized (128MB)
- **TCP optimizations**: Disabled timestamps, SACK
- **Backlog**: Increased to 300k packets
- **Fast socket reuse**: Enabled
- **rp_filter**: Disabled on all interfaces (asymmetric routes)

### 4. Interrupts
- **IRQ affinity**: All IRQs pinned to CPUs 0-1
- **irqbalance**: Disabled (would undo the pinning)
- **Isolated from**: HFT application cores (2-7)

## Mixed NIC Setup (Mellanox + Intel X710)

If you have both Mellanox RDMA NICs and standard NICs (e.g. Intel X710), the
correct split is:

| NIC | Networking method | Setup |
|---|---|---|
| Mellanox ConnectX-4/5 (each port) | VMA kernel-bypass | `install-vma.sh` + `configure-vma-dual-nic.sh` |
| Intel X710 (each port) | Kernel stack (ethtool-tuned) | `tune-network-interface.sh` only |

- `tune-network-interface.sh` should still be run on the Mellanox ports as well;
  it sets ring buffers and coalescing that VMA also benefits from.
- `configure-vma-dual-nic.sh` validates that both passed interfaces use an `mlx`
  driver and will exit with an error if you pass an X710 port.
- Applications bind sockets to specific IPs; VMA intercepts only the sockets that
  land on the Mellanox ports. Sockets bound to X710 addresses go through the
  normal kernel stack automatically -- no special handling needed.

## VMA (NVIDIA Messaging Accelerator)

### What is VMA?
VMA provides kernel-bypass networking for ultra-low latency:
- **Bypass Linux network stack**: Direct hardware access via RDMA verbs
- **Sub-microsecond latency**: ~2-5μs round-trip on ConnectX-4; 1-2μs on ConnectX-5+
- **Zero-copy**: Data moves directly between NIC and application memory
- **Transparent**: Uses LD_PRELOAD, no code changes required
- **Driver**: Inbox `mlx5_ib` kernel module is sufficient; MLNX_OFED is optional

### ConnectX-4 vs ConnectX-5+ Feature Differences
| Feature | ConnectX-4 | ConnectX-5+ |
|---|---|---|
| VMA kernel-bypass | Yes | Yes |
| Striding RQ (`VMA_STRQ`) | No | Yes |
| Expected latency | ~2-5μs | ~1-2μs |

The scripts have `VMA_STRQ=0` by default. If you upgrade to ConnectX-5 or newer,
edit `/etc/libvma.conf` and set `VMA_STRQ=1` and `VMA_STRQ_STRIDES_NUM=2048`.

### Running Applications with VMA
```bash
# Basic usage (VMA intercepts sockets on Mellanox ports automatically)
run-with-vma.sh ./your-hft-app

# With debug logging
VMA_TRACELEVEL=3 run-with-vma.sh ./your-hft-app

# Check VMA statistics
vma_stats -p $(pgrep your-hft-app)
```

See `VMA-QUICK-REFERENCE.md` for comprehensive VMA usage guide.

## Running HFT Applications

### CPU Affinity
Always run your HFT application on isolated cores:

```bash
# Run on all isolated cores (2-7)
taskset -c 2-7 ./your-hft-app

# Run on specific core (e.g., core 3)
taskset -c 3 ./your-hft-app

# Set thread priority
chrt -f 99 taskset -c 2-7 ./your-hft-app
```

### Using HugePages in Your Application

**C/C++ Example:**
```c
#include <sys/mman.h>

void* buffer = mmap(NULL, size, PROT_READ | PROT_WRITE,
                    MAP_PRIVATE | MAP_ANONYMOUS | MAP_HUGETLB, -1, 0);
```

**Check HugePage usage:**
```bash
grep Huge /proc/meminfo
cat /proc/sys/vm/nr_hugepages
```

## Network Tuning Details

The `tune-network-interface.sh` script:
- Increases RX/TX ring buffers to 4096
- Disables GRO, LRO, TSO, GSO (reduces latency)
- Sets interrupt coalescing to 0 (immediate interrupts)
- Enables hardware timestamping (if available)

## Monitoring

### Check Latency
```bash
# Measure network latency
ping -c 100 <target_ip> | tail -1

# Check context switches
vmstat 1

# Monitor CPU usage per core
mpstat -P ALL 1
```

### Check IRQ Distribution
```bash
watch -n1 'cat /proc/interrupts'
```

### Memory Statistics
```bash
numastat
cat /proc/buddyinfo
```

## Advanced Tuning

### Kernel Boot Parameters
Manually edit `/etc/default/grub` and add:
```
GRUB_CMDLINE_LINUX="isolcpus=2-7 nohz_full=2-7 rcu_nocbs=2-7 intel_idle.max_cstate=0 processor.max_cstate=0 intel_pstate=disable"
```

Then run:
```bash
grub2-mkconfig -o /boot/grub2/grub.cfg
reboot
```

### Real-Time Kernel
For even lower latency, consider installing RT kernel:
```bash
sudo dnf install kernel-rt kernel-rt-devel
```

### Disable SMT/Hyper-Threading
If you need predictable performance:
```bash
echo off > /sys/devices/system/cpu/smt/control
```

## Troubleshooting

### CPU isolation not working?
```bash
# Check if cores are isolated
cat /proc/cmdline | grep isolcpus

# Check CPU usage
mpstat -P ALL 1
```

### HugePages not allocated?
```bash
# Check current allocation
cat /proc/meminfo | grep Huge

# Try allocating more
echo 2048 > /proc/sys/vm/nr_hugepages
```

### High context switches?
```bash
# Monitor context switches
vmstat 1

# Check for processes on isolated cores
ps -eLo pid,tid,class,rtprio,ni,pri,psr,pcpu,stat,wchan:14,comm | grep -E ' [2-7] '
```

## Performance Testing

### Measure latency variance
```bash
# Install rt-tests
sudo dnf install rt-tests

# Run cyclictest
sudo cyclictest -p 99 -t1 -n -a 3 -D 60
```

### Network benchmark
```bash
# Install sockperf
sudo dnf install sockperf

# Server
sockperf sr -p 5001

# Client (from another machine)
sockperf ping-pong -i <server_ip> -p 5001 -t 60
```

## Rollback

To undo optimizations:
```bash
# Remove sysctl config
sudo rm /etc/sysctl.d/99-hft.conf

# Remove CPU isolation from grub
sudo vi /etc/default/grub  # Remove isolcpus, nohz_full, rcu_nocbs
sudo grub2-mkconfig -o /boot/grub2/grub.cfg

# Disable services
sudo systemctl disable disable-thp.service cpu-performance.service irq-affinity.service

# Reboot
sudo reboot
```

## References
- [Red Hat Low Latency Tuning Guide](https://access.redhat.com/documentation/en-us/red_hat_enterprise_linux_for_real_time/)
- [Intel Network Optimization](https://www.intel.com/content/www/us/en/developer/articles/guide/network-performance-optimization.html)
- [Linux Foundation Real-Time](https://wiki.linuxfoundation.org/realtime/start)
