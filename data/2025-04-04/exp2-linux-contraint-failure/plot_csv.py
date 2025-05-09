import pandas as pd
import matplotlib.pyplot as plt
import numpy as np

def plot_bitrate(csv_file, reference_bitrate_file):
    # Read the main CSV file
    df = pd.read_csv(csv_file, parse_dates=['Timestamp'])
    df['Timestamp'] = (df['Timestamp'] - df['Timestamp'].min()).dt.total_seconds()

    # Read the reference bitrate CSV file
    ref_df = pd.read_csv(reference_bitrate_file)

    # Filter only video data
    video_df = df[df['Kind'] == 'video']
    fig, ax1 = plt.subplots(figsize=(12, 6))

    # Repeat the reference bitrate values to match the length of the CurrentBitrate plot
    repeated_ref_bitrate = np.tile(ref_df['Bitrate (kbps)'], int(np.ceil(len(video_df) / len(ref_df))))
    repeated_ref_bitrate = repeated_ref_bitrate[:len(video_df)]  # Trim to match the exact length

    # Plot the repeated reference bitrate
    ax1.plot(video_df['Timestamp'], repeated_ref_bitrate, label='Reference Bitrate', linestyle='-.', color='#601A4A', alpha=0.5)

    # Plot CurrentBitrate and TargetBitrate for Video on primary y-axis
    ax1.plot(video_df['Timestamp'], video_df['CurrentBitrate'], label='CurrentBitrate (Video)', color='#63ACBE')
    ax1.plot(video_df['Timestamp'], video_df['TargetBitrate'], label='TargetBitrate (Video)', linestyle='--', color='#EE442F')


    ax1.set_xlabel('Timestamp')
    ax1.set_ylabel('Bitrate (Kbps)')
    ax1.tick_params(axis='y')

    # ax1.hlines(y=100_000, xmin=0, xmax=240, colors='grey', linestyles='solid', label="bandwidth cap", alpha=0.8)
    # ax1.vlines(x=240, ymin=30_000, ymax=100_000, colors='grey', linestyles='solid', alpha=0.8)
    # ax1.hlines(y=30_000, xmin=240, xmax=480, colors='grey', linestyles='solid', alpha=0.8)
    # ax1.vlines(x=480, ymin=15_000, ymax=30_000, colors='grey', linestyles='solid', alpha=0.8)
    # ax1.hlines(y=15_000, xmin=480, xmax=720, colors='grey', linestyles='solid', alpha=0.8)
    # ax1.vlines(x=720, ymin=15_000, ymax=30_000, colors='grey', linestyles='solid', alpha=0.8)
    # ax1.hlines(y=30_000, xmin=720, xmax=960, colors='grey', linestyles='solid', alpha=0.8)
    # ax1.vlines(x=960, ymin=30_000, ymax=100_000, colors='grey', linestyles='solid', alpha=0.8)
    # ax1.hlines(y=100_000, xmin=960, xmax=video_df['Timestamp'].max(), colors='grey', linestyles='solid', alpha=0.8)
    # ax1.vlines(x=960, ymin=10_000, ymax=30_000, colors='grey', linestyles='solid', alpha=0.8)
    # ax1.hlines(y=30_000, xmin=960, xmax=video_df['Timestamp'].max(), colors='grey', linestyles='solid', alpha=0.8)
        # ax1.vlines(x=600, ymin=3000, ymax=10_000, colors='grey', linestyles='solid', alpha=0.8)
        # ax1.hlines(y=10_000, xmin=600, xmax=720, colors='grey', linestyles='solid', alpha=0.8)
        # ax1.vlines(x=720, ymin=10_000, ymax=50_000, colors='grey', linestyles='solid', alpha=0.8)
        # ax1.hlines(y=50000, xmin=720, xmax=840, colors='grey', linestyles='solid', alpha=0.8)

    # Secondary y-axis for PacketsReceived
    ax2 = ax1.twinx()
    ax2.plot(video_df['Timestamp'], video_df['Jitter'], label='Jitter', color='#131a78', linestyle='solid', alpha=0.2)
    ax2.set_ylabel('Jitter (ms)')
    ax2.tick_params(axis='y')
    ax2.set_ylim(0, 400)

    # Collect all legend handles and labels
    handles, labels = ax1.get_legend_handles_labels()
    handles2, labels2 = ax2.get_legend_handles_labels()

    # Merge legends and display a single combined legend
    plt.legend(handles + handles2, labels + labels2, loc='upper right')

    # Formatting
    plt.xlabel('Timestamp (seconds)')
    plt.title('CurrentBitrate vs TargetBitrate - With Constraint')
    plt.xticks(rotation=45)
    plt.grid()

    # Show plot
    plt.tight_layout()
    plt.show()

# Example usage
plot_bitrate('app.csv', 'bitrate_data_nyu.csv')