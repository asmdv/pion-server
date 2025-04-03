import matplotlib.pyplot as plt
import pandas as pd

csv_file = "data/exp3/bitrate_data.csv"
# Read the CSV file into a Pandas DataFrame
df = pd.read_csv(csv_file, parse_dates=["Timestamp"])

# Optional
df["Timestamp"] = (df["Timestamp"] - df["Timestamp"].min()).dt.total_seconds()

# Plot the bitrate data
groups = df.groupby("Stream ID")
plt.figure(figsize=(10, 5))

for stream_id, group in groups:
    plt.plot(group["Timestamp"], group["Current Bitrate (kbps)"], label=f"Current - {stream_id}")
    plt.plot(group["Timestamp"], group["Target Bitrate (kbps)"], linestyle="dashed", label=f"Target - {stream_id}")


vlines = ["50mbps", "10mbps", "3mbps", "10mbps", "300kbps", "3mbps", "10mbps", "50mbps"]
for i, vline in enumerate(vlines):
    plt.axvline(x=30*(i), color='red', linestyle='--', linewidth=1)
    plt.text(30*(i), plt.ylim()[1] * 0.9, vline, color='red', fontsize=12, verticalalignment='top')


plt.xlabel("Time (s)")
plt.ylabel("Bitrate (kbps)")
plt.title("Current vs Target Bitrate Over Time")
plt.legend()
plt.xticks(rotation=45)
plt.tight_layout()
plt.show()