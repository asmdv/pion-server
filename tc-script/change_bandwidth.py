import os
import time
from datetime import datetime

# ✅ 根据你网卡名修改
IFACE = "enp0s1"

# 带宽变化序列（每阶段 2 分钟）
bandwidth_sequence = ["20mbit", "30mbit", "50mbit", "30mbit", "10mbit", "5mbit"]

def run(cmd):
    ret = os.system(cmd)
    if ret != 0:
        print(f"[!] Command failed: {cmd}")

def apply_tc(bw):
    print(f"[{datetime.now().isoformat()}] [+] Switching bandwidth to: {bw}")

    # 延迟设置
    latency = "50ms"
    burst_map = {
        "20mbit": "125k",
        "30mbit": "187k",
        "50mbit": "312k",
        "10mbit": "62k",
        "5mbit":  "31k",
    }
    burst = burst_map.get(bw, "100k")

    # 清除旧设置
    run(f"sudo tc qdisc del dev {IFACE} root || true")
    time.sleep(0.2)  # 确保清理完成

    # 正确顺序挂载 TBF + NetEm
    run(f"sudo tc qdisc add dev {IFACE} root handle 1: tbf rate {bw} burst {burst} latency {latency}")
    run(f"sudo tc qdisc add dev {IFACE} parent 1:1 handle 10: netem delay 50ms limit 1000")

def main():
    while True:
        for bw in bandwidth_sequence:
            apply_tc(bw)
            time.sleep(120)  # 每个阶段持续 2 分钟

if __name__ == "__main__":
    main()