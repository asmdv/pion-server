import subprocess
import json
import matplotlib.pyplot as plt
import numpy as np
import pandas as pd


def get_bitrate_over_time(video_path, interval=1):
    """
    Calculate the bitrate of a video over time using ffprobe.

    Args:
        video_path (str): Path to the video file.
        interval (int): Time interval (in seconds) to calculate the bitrate.

    Returns:
        list: A list of tuples containing (time, bitrate_in_kbps).
    """
    # Run ffprobe to get frame-level metadata
    cmd = [
        "ffprobe",
        "-show_frames",
        "-select_streams", "v",  # Select video stream
        "-show_entries", "frame=pkt_size,pkt_dts_time",  # Get frame size and DTS timestamp
        "-of", "json",  # Output in JSON format
        video_path
    ]

    result = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    if result.returncode != 0:
        raise RuntimeError(f"ffprobe error: {result.stderr}")

    # Parse the JSON output
    frames = json.loads(result.stdout).get("frames", [])

    # Calculate bitrate over time
    bitrate_data = []
    current_time = 0
    total_bits = 0
    for frame in frames:
        pkt_size = int(frame.get("pkt_size", 0))  # Packet size in bytes
        pkt_dts_time = float(frame.get("pkt_dts_time", 0))  # Packet DTS timestamp in seconds

        # Accumulate bits
        total_bits += pkt_size * 8  # Convert bytes to bits

        # Check if the interval has passed
        if pkt_dts_time >= current_time + interval:
            bitrate_kbps = total_bits / interval / 1000  # Convert to kbps
            bitrate_data.append((current_time, bitrate_kbps))
            current_time += interval
            total_bits = 0  # Reset for the next interval

    return bitrate_data

def repeat_bitrate_curve(bitrate_data, repeats=10):
    """
    Repeat the bitrate curve multiple times.

    Args:
        bitrate_data (list): A list of tuples containing (time, bitrate_in_kbps).
        repeats (int): Number of times to repeat the curve.

    Returns:
        list: A list of tuples containing the repeated (time, bitrate_in_kbps).
    """
    repeated_bitrate_data = []
    original_duration = bitrate_data[-1][0]  # Get the duration of the original curve
    for i in range(repeats):
        for time, bitrate in bitrate_data:
            repeated_bitrate_data.append((time + i * (original_duration + 1), bitrate))
    return repeated_bitrate_data

def plot_bitrate(bitrate_data):
    """
    Plot the bitrate over time.

    Args:
        bitrate_data (list): A list of tuples containing (time, bitrate_in_kbps).
    """
    times, bitrates = zip(*bitrate_data)
    plt.figure(figsize=(10, 6))
    plt.plot(times, bitrates, label="Bitrate (kbps)", color="blue")
    plt.xlabel("Time (s)")
    plt.ylabel("Bitrate (kbps)")
    plt.title("Repeated Bitrate Curve")
    plt.grid(True)
    plt.legend()
    plt.show()

def export_bitrate_to_csv(bitrate_data, output_file):
    """
    Export the bitrate data to a CSV file.

    Args:
        bitrate_data (list): A list of tuples containing (time, bitrate_in_kbps).
        output_file (str): Path to the output CSV file.
    """
    # Convert the data to a pandas DataFrame
    df = pd.DataFrame(bitrate_data, columns=["Time (s)", "Bitrate (kbps)"])

    # Export to CSV
    df.to_csv(output_file, index=False)
    print(f"Bitrate data exported to {output_file}")


# Example usage
video_path = "/Users/asif/Desktop/nyu-video/78_res2k_qp16.mp4"  # Replace with your video file path
bitrate_data = get_bitrate_over_time(video_path, interval=1)

# Repeat the bitrate curve 10 times
repeated_bitrate_data = repeat_bitrate_curve(bitrate_data, repeats=10)

# Plot the repeated bitrate curve
plot_bitrate(repeated_bitrate_data)

output_csv = "bitrate_data.csv"
export_bitrate_to_csv(bitrate_data, output_csv)

