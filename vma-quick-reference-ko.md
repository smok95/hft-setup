# VMA 빠른 참조 가이드

> VMA는 Mellanox/NVIDIA RDMA NIC에서만 작동합니다 (드라이버 `mlx4_en` 또는 `mlx5_en`).
> Intel X710 및 기타 비-RDMA NIC은 대신 `tune-network-interface.sh`로 튜닝해야 합니다.
> 두 유형을 모두 가지고 있다면 아래 "혼합 NIC 설정" 섹션을 참조하세요.

## 설치 및 설정

```bash
# 1. VMA 설치
sudo ./install-vma.sh

# 2. Mellanox 포트에 설정 (1개 이상)
#    (스크립트가 자동으로 비-mlx 드라이버를 거부합니다)
sudo ./configure-vma-multi-nic.sh <mlx_port1> [<mlx_port2> ...]

# 3. 설치 확인
vma_stats -v
```

## VMA로 애플리케이션 실행

### 방법 1: 헬퍼 스크립트 사용 (권장)
```bash
# 기본 사용법
run-with-vma.sh ./your-hft-app

# 디버그 로깅 사용
VMA_TRACELEVEL=4 run-with-vma.sh ./your-hft-app

# 사용자 지정 CPU 코어
VMA_CORES=3,5,7 run-with-vma.sh ./your-hft-app

# 사용자 지정 RT 우선순위
VMA_PRIORITY=80 run-with-vma.sh ./your-hft-app
```

### 방법 2: 직접 LD_PRELOAD
```bash
# 운영 환경 (최소 로깅)
LD_PRELOAD=libvma.so taskset -c 2-7 ./your-hft-app

# 개발 환경 (로깅 포함)
VMA_TRACELEVEL=3 LD_PRELOAD=libvma.so taskset -c 2-7 ./your-hft-app

# 실시간 우선순위 사용
chrt -f 99 taskset -c 2-7 env LD_PRELOAD=libvma.so ./your-hft-app
```

### 방법 3: Systemd 서비스
```bash
# 설정
cp your-hft-app /opt/hft-apps/
systemctl enable vma-app@your-hft-app
systemctl start vma-app@your-hft-app

# 모니터링
systemctl status vma-app@your-hft-app
journalctl -u vma-app@your-hft-app -f
```

## 모니터링 및 디버깅

### VMA 활성화 확인
```bash
# 실행 중인 프로세스 확인
vma_stats -p $(pgrep your-hft-app)

# 다음이 표시되어야 합니다:
# - VMA 버전
# - VMA를 사용하는 소켓 수
# - 링 통계
# - 패킷 카운터
```

### 상세 통계 보기
```bash
# 통계를 파일로 저장
VMA_STATS_FILE=/tmp/vma_stats.txt LD_PRELOAD=libvma.so ./your-hft-app

# 실행 중 통계 보기
watch -n1 'vma_stats -p $(pgrep your-hft-app)'
```

### 디버그 로깅 활성화
```bash
# 로그 레벨:
# 0 = PANIC (치명적 오류만)
# 1 = ERROR
# 2 = WARN (기본값)
# 3 = INFO
# 4 = DEBUG
# 5+ = MORE DEBUG

# 환경변수로 설정
VMA_TRACELEVEL=4 LD_PRELOAD=libvma.so ./your-hft-app

# 또는 /etc/libvma.conf에 설정
echo "VMA_TRACELEVEL=4" >> /etc/libvma.conf
```

### VMA가 소켓을 가로채는지 확인
```bash
# VMA_TRACELEVEL=3으로 실행하고 다음을 찾으세요:
# "VMA INFO: <socket_fd> socket intercepted"
# "VMA INFO: using VMA for socket"

# "socket not offloaded"가 표시되면 확인하세요:
# 1. NIC이 RDMA를 지원하는지 (ibv_devices가 장치를 나열해야 함)
# 2. 애플리케이션이 TCP/UDP를 사용하는지 (UNIX 소켓이 아님)
# 3. VMA_SPEC이 트래픽 패턴과 일치하는지
```

## 일반적인 VMA 설정 튜닝

### 초저지연 (적극적 폴링)
```bash
# /etc/libvma.conf에 설정
VMA_RX_POLL=-1              # 무한 폴링
VMA_RX_POLL_NUM=100000000   # 높은 폴링 횟수
VMA_SELECT_POLL=-1          # select()에서 폴링
VMA_RX_SKIP_OS=1            # 커널 완전 건너뛰기
VMA_THREAD_MODE=1           # 애플리케이션 스레드 사용
```

### 균형형 (일부 CPU 절약)
```bash
VMA_RX_POLL=100000          # 100ms 동안 폴링
VMA_RX_POLL_NUM=100000
VMA_SELECT_POLL=100000
VMA_RX_SKIP_OS=1
VMA_THREAD_MODE=0           # VMA 내부 스레드 사용
```

### 높은 처리량 (큰 메시지)
```bash
VMA_RX_WRE=4096             # 더 많은 RX 디스크립터
VMA_TX_WRE=4096             # 더 많은 TX 디스크립터
VMA_STRQ=1                  # Striding RQ -- ConnectX-5+ 전용, ConnectX-4에서는 0 유지
VMA_STRQ_STRIDES_NUM=4096   # 더 많은 스트라이드 (VMA_STRQ=1일 때만 유효)
VMA_TX_BUFS_BATCH_TCP=32    # 더 많은 TX 배치
```

## 문제 해결

### 문제: VMA가 로드되지 않음
```bash
# libvma.so 존재 확인
ls -l /usr/lib64/libvma.so /usr/lib/libvma.so

# 의존성 확인
ldd /usr/lib64/libvma.so

# 누락된 의존성 설치
sudo dnf install libibverbs librdmacm rdma-core
```

### 문제: RDMA 장치를 찾을 수 없음
```bash
# RDMA 장치 나열
ibv_devices

# ibv_devices 명령이 없으면:
sudo dnf install libibverbs-utils

# Mellanox NIC이 표시되어야 함 (예: mlx5_0, mlx5_1)
# 설치 후에도 비어 있으면:
# 1. inbox 모듈이 로드되었는지 확인: lsmod | grep mlx5_ib
#    로드되지 않았으면: modprobe mlx5_ib
# 2. NIC이 감지되었는지 확인: lspci | grep -i mellanox
# 3. inbox 모듈이 로드되지 않으면 MLNX_OFED를 대안으로 설치:
#    https://network.nvidia.com/products/infiniband-drivers/linux/mlnx_ofed/에서 다운로드
```

### 문제: 성능이 좋지 않음
```bash
# 소켓이 실제로 오프로드되는지 확인
vma_stats -p $(pgrep your-app) | grep "offloaded"

# OS 폴백 확인
grep "fallback" /var/log/vma.log

# CPU 격리 확인
cat /proc/cmdline | grep isolcpus
ps -eLo pid,psr,comm | grep your-app  # CPU 2-7이 표시되어야 함

# IRQ 선호도 확인
cat /proc/interrupts | grep mlx5
# IRQ는 CPU 0-1에만 있어야 함
```

### 문제: 애플리케이션 충돌
```bash
# 일반적인 원인:
# 1. memlock 제한 부족
ulimit -l unlimited

# 2. HugePages 사용 불가
grep Huge /proc/meminfo

# 3. VMA 버전과 MLNX_OFED 불일치
rpm -qa | grep -E "libvma|mlnx"

# 디버그로 충돌 위치 확인
VMA_TRACELEVEL=4 LD_PRELOAD=libvma.so gdb ./your-app
```

## 환경변수 참조

### 주요 VMA 변수
```bash
# VMA 작동에 필수
LD_PRELOAD=/usr/lib64/libvma.so

# 설정 파일
VMA_CONFIG_FILE=/etc/libvma.conf

# 로깅
VMA_TRACELEVEL=2                    # 로그 레벨 (0-5+)
VMA_LOG_FILE=/var/log/vma.log       # 로그 파일 경로
VMA_LOG_DETAILS=0                   # 상세 로깅 (0/1)

# 소켓 사양 (어떤 소켓을 오프로드할지)
VMA_SPEC=tcp:*:*,udp:*:*           # 모든 TCP/UDP 소켓

# 성능
VMA_RX_POLL=-1                      # RX 폴링 모드 (-1 = 무한)
VMA_RX_SKIP_OS=1                    # 커널 우회 (0/1)
VMA_THREAD_MODE=1                   # 스레드 모드 (0/1/2)

# 메모리
VMA_HUGETLB=1                       # HugePages 사용 (0/1)
VMA_MEM_ALLOC_TYPE=1                # 메모리 할당 타입

# 통계
VMA_STATS_FILE=/tmp/vma_stats.txt   # 통계 출력 파일
```

## 성능 검증

### 지연 시간 테스트
```bash
# sockperf 설치 (VMA에 포함됨)
which sockperf

# 서버
taskset -c 2 sockperf sr -p 11111

# 클라이언트 (다른 머신에서)
taskset -c 2 sockperf ping-pong -i <server_ip> -p 11111 -t 60

# Mellanox 포트에서 VMA 사용 (ConnectX-4에서 ~2-5us, ConnectX-5+에서 ~1-2us 예상)
taskset -c 2 LD_PRELOAD=libvma.so sockperf ping-pong -i <server_ip> -p 11111 -t 60
```

### 처리량 테스트
```bash
# 서버
taskset -c 2-7 LD_PRELOAD=libvma.so sockperf sr -p 11111

# 클라이언트
taskset -c 2-7 LD_PRELOAD=libvma.so sockperf throughput -i <server_ip> -p 11111 -t 60 -m 1024
```

## 모범 사례

1. **항상 CPU 격리 사용**: VMA 앱은 코어 2-7에서만 실행
2. **HugePages 사용**: VMA_HUGETLB=1이 성능을 크게 향상
3. **IRQ 고정**: NIC 인터럽트를 코어 0-1에 유지 (설정 스크립트에서 수행)
4. **오프로드 비활성화**: GRO, LRO, TSO, GSO 모두 비활성화 (tune-network-interface.sh에서 수행)
5. **실시간 우선순위 사용**: 최저 지연을 위해 chrt -f 99
6. **통계 모니터링**: 오프로드 확인을 위한 정기적 vma_stats 확인
7. **보수적 설정으로 시작**: CPU 예산에 따라 VMA_RX_POLL 튜닝
8. **먼저 VMA 없이 테스트**: VMA 활성화 전에 베이스라인 설정
9. **MLNX_OFED 버전 확인**: NIC에 맞는 최신 안정 MLNX_OFED 사용
10. **SocketXtreme API 사용**: 최소 지연을 위해 (코드 변경 필요)
11. **NIC 세대 알기**: ConnectX-4는 Striding RQ(`VMA_STRQ`)를 지원하지 않음. ConnectX-5+로 업그레이드 후에만 활성화.

## 혼합 NIC 설정 (Mellanox + Intel X710)

서버에 Mellanox RDMA NIC과 표준 NIC(예: Intel X710)이 모두 있는 경우,
먼저 Mellanox 포트에서 VMA 커널 바이패스가 작동하도록 한 다음,
나머지 포트를 ethtool로 튜닝합니다.

| NIC | VMA? | 단계 |
|---|---|---|
| Mellanox ConnectX-4/5 | 예 | `tune-network-interface.sh` + `install-vma.sh` + `configure-vma-multi-nic.sh` |
| Intel X710 | 아니오 | `tune-network-interface.sh`만 |

- `tune-network-interface.sh`는 모든 포트(Mellanox 포함)에서 실행해야 합니다.
- `configure-vma-multi-nic.sh`는 하나 이상의 Mellanox 포트 이름을 받습니다. 비-mlx 인터페이스를
  전달하면 드라이버를 검증하고 오류와 함께 종료합니다.
- 런타임에 VMA는 인터페이스별로 소켓을 투명하게 가로챕니다. X710 주소에 바인딩된
  소켓은 자동으로 커널 스택을 사용합니다 -- 앱 코드에 분기가 필요 없습니다.

## 추가 자료

- VMA GitHub: https://github.com/Mellanox/libvma
- NVIDIA 네트워킹 문서: https://docs.nvidia.com/networking/
- MLNX_OFED 다운로드: https://network.nvidia.com/products/infiniband-drivers/linux/mlnx_ofed/
- VMA 튜닝 가이드: 설치 후 `/usr/share/doc/libvma/` 확인