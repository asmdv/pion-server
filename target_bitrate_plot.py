import pandas as pd
import matplotlib.pyplot as plt

# 1. 读取并清洗 CSV 内容（去除 'flutter: ' 前缀）
df = pd.read_csv("target_bitrate_6.csv")
df.columns = ["timestamp", "target_bitrate", "current_bitrate"]
df["timestamp"] = df["timestamp"].str.replace("flutter: ", "", regex=False)
df["timestamp"] = pd.to_datetime(df["timestamp"])
df["target_bitrate"] = df["target_bitrate"].astype(float)
df["current_bitrate"] = df["current_bitrate"].astype(float)

# 构造带宽变化曲线
bandwidth_marks = [
    ("2025-06-19T02:04:40", 20000),
    ("2025-06-19T02:06:40", 30000),
    ("2025-06-19T02:08:40", 50000),
    ("2025-06-19T02:10:40", 30000),
    ("2025-06-19T02:12:40", 10000),
    ("2025-06-19T02:14:40", 5000),
]

bw_times = pd.date_range(start=df["timestamp"].min(), end=df["timestamp"].max(), freq="S")
bandwidth_kbps = []
bw_index = 0
current_bw = bandwidth_marks[0][1]

for t in bw_times:
    if bw_index + 1 < len(bandwidth_marks) and t >= pd.to_datetime(bandwidth_marks[bw_index + 1][0]):
        bw_index += 1
        current_bw = bandwidth_marks[bw_index][1]
    bandwidth_kbps.append(current_bw)

bw_df = pd.DataFrame({"timestamp": bw_times, "bandwidth_kbps": bandwidth_kbps})

# 3. 合并三条数据线
merged = pd.merge_asof(df.sort_values("timestamp"), bw_df, on="timestamp")

# 4. 绘图
plt.figure(figsize=(14, 7))
plt.plot(merged["timestamp"], merged["target_bitrate"], label="Target Bitrate", color='green')
plt.plot(merged["timestamp"], merged["current_bitrate"], label="Current Bitrate", color='red')
plt.plot(merged["timestamp"], merged["bandwidth_kbps"], label="Bandwidth Limit", color='blue', linestyle='dashed')

plt.xlabel("Time")
plt.ylabel("Bitrate (kbps)")
plt.title("Target vs Current Bitrate with Bandwidth Limitations")
plt.legend()
plt.grid(True)
plt.xticks(rotation=45)
plt.tight_layout()
plt.show()