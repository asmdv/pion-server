import re
import csv

import matplotlib.pyplot as plt
import pandas as pd


# Define the log file and output CSV file
log_file = "output.txt"
csv_file = "data/2025-03-07/exp1/bitrate_data.csv"

# Regular expression to extract relevant data
log_pattern = re.compile(
    r"bitrate INFO: (\d{4}/\d{2}/\d{2} \d{2}:\d{2}:\d{2}) Stream ([\w-]+): Current Bitrate (\d+) kbps \| Target: (\d+) kbps"
)

# Read and parse the log file
data = []
with open(log_file, "r") as file:
    for line in file:
        match = log_pattern.search(line)
        if match:
            timestamp, stream_id, current_bitrate, target_bitrate = match.groups()
            data.append([timestamp, stream_id, int(current_bitrate), int(target_bitrate)])

# Write the extracted data to a CSV file
with open(csv_file, "w", newline="") as file:
    writer = csv.writer(file)
    writer.writerow(["Timestamp", "Stream ID", "Current Bitrate (kbps)", "Target Bitrate (kbps)"])
    writer.writerows(data)

print(f"CSV file '{csv_file}' has been created successfully.")

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

plt.xlabel("Time (s)")
plt.ylabel("Bitrate (kbps)")
plt.title("Current vs Target Bitrate Over Time")
plt.legend()
plt.xticks(rotation=45)
plt.tight_layout()
plt.show()