# HFT Linux Server Optimization Guide

## Quick Start

1. **Run the main setup script** (requires root):
   ```bash
   cd /tmp/claude-0/-root/86566e05-2b7e-468c-b366-b33eb9c25cc9/scratchpad
   chmod +x *.sh
   sudo ./setup-hft-optimization.sh
   ```

2. **Reboot the server** to activate CPU isolation:
   ```bash
   sudo reboot
   ```

3. **Verify the setup** after reboot:
   ```bash
   sudo ./verify-hft-setup.sh
   ```

4. **Tune network interface** (optional but recommended):
   ```bash
   # Find your network interface name
   ip addr

   # Run tuning script
   sudo ./tune-network-interface.sh <interface_name>
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

### 4. Interrupts
- **IRQ affinity**: All IRQs pinned to CPUs 0-1
- **Isolated from**: HFT application cores (2-7)

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
