import os
import time
from datetime import datetime
import pytz  # ✅ 时区支持

# 网络接口和 IFB 虚拟设备
IFACE = 'enp0s1'
IFB_DEV = 'ifb0'

# 带宽变化序列（每阶段持续 2 分钟）
bandwidth_sequence = ['20mbit', '30mbit', '50mbit', '30mbit', '10mbit', '5mbit']
burst_map = {
    '20mbit': '125k',
    '30mbit': '187k',
    '50mbit': '312k',
    '10mbit': '62k',
    '5mbit': '31k'
}
latency = '50ms'

def run(cmd):
    ret = os.system(cmd)
    if ret != 0:
        print(f'[!] Command failed: {cmd}')

def setup_ifb():
    run('sudo modprobe ifb numifbs=1')
    run(f'sudo ip link set dev {IFB_DEV} up')
    run(f'sudo tc qdisc del dev {IFACE} ingress || true')
    run(f'sudo tc qdisc del dev {IFB_DEV} root || true')
    run(f'sudo tc qdisc add dev {IFACE} handle ffff: ingress')

    # Redirect ingress traffic to IFB
    run(f'sudo tc filter add dev {IFACE} parent ffff: protocol ip u32 match u32 0 0 action mirred egress redirect dev {IFB_DEV}')
    run(f'sudo tc filter add dev {IFACE} parent ffff: protocol ipv6 u32 match u32 0 0 action mirred egress redirect dev {IFB_DEV}')

    # ✅ 初始化 tbf qdisc，一开始就加上 handle 1: 以便后续 change
    default_bw = '20mbit'
    burst = burst_map[default_bw]
    run(f'sudo tc qdisc add dev {IFB_DEV} root handle 1: tbf rate {default_bw} burst {burst} latency {latency}')
    run(f'sudo tc qdisc add dev {IFB_DEV} parent 1:1 handle 10: netem delay 50ms limit 1000')

def apply_ingress_shaping(bw):
    burst = burst_map.get(bw, '100k')

    # 美东时间戳
    tz = pytz.timezone("America/New_York")
    timestamp = datetime.now(tz).isoformat()
    print(f'[{timestamp}] [~] Smooth change to {bw} (burst {burst})')

    # ✅ 平滑更改而不是清除再添加，避免清空队列
    run(f'sudo tc qdisc change dev {IFB_DEV} root handle 1: tbf rate {bw} burst {burst} latency {latency}')

def main():
    setup_ifb()
    while True:
        for bw in bandwidth_sequence:
            apply_ingress_shaping(bw)
            time.sleep(120)

if __name__ == '__main__':
    main()