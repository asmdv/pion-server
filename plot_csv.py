import pandas as pd
import matplotlib.pyplot as plt

def plot_bitrate(csv_file):
    # Read CSV file
    df = pd.read_csv(csv_file, parse_dates=['Timestamp'])
    df['Timestamp'] = (df['Timestamp'] - df['Timestamp'].min()).dt.total_seconds()

    # Filter only video data
    video_df = df[df['Kind'] == 'video']
    fig, ax1 = plt.subplots(figsize=(12,6))


#     # Plot CurrentBitrate and TargetBitrate for Video on primary y-axis
    ax1.plot(video_df['Timestamp'], video_df['CurrentBitrate'], label='CurrentBitrate (Video)', color='green')
    ax1.plot(video_df['Timestamp'], video_df['TargetBitrate'], label='TargetBitrate (Video)', linestyle='--', color='red')

#     ax1.hlines(y=50_000, xmin=0, xmax=120, colors='grey', linestyles='solid', label="bandwidth cap", alpha=0.8)
#     ax1.vlines(x=120, ymin=10_000, ymax=50_000, colors='grey', linestyles='solid', alpha=0.8)
#     ax1.hlines(y=10_000, xmin=120, xmax=240, colors='grey', linestyles='solid', alpha=0.8)
#     ax1.vlines(x=240, ymin=3000, ymax=10_000, colors='grey', linestyles='solid', alpha=0.8)
#     ax1.hlines(y=3000, xmin=240, xmax=360, colors='grey', linestyles='solid', alpha=0.8)
#     ax1.vlines(x=360, ymin=300, ymax=3000, colors='grey', linestyles='solid', alpha=0.8)
#     ax1.hlines(y=300, xmin=360, xmax=480, colors='grey', linestyles='solid', alpha=0.8)
#     ax1.vlines(x=480, ymin=300, ymax=3000, colors='grey', linestyles='solid', alpha=0.8)
#     ax1.hlines(y=3000, xmin=480, xmax=600, colors='grey', linestyles='solid', alpha=0.8)
#     ax1.vlines(x=600, ymin=3000, ymax=10_000, colors='grey', linestyles='solid', alpha=0.8)
#     ax1.hlines(y=10_000, xmin=600, xmax=720, colors='grey', linestyles='solid', alpha=0.8)
#     ax1.vlines(x=720, ymin=10_000, ymax=50_000, colors='grey', linestyles='solid', alpha=0.8)
#     ax1.hlines(y=50000, xmin=720, xmax=840, colors='grey', linestyles='solid', alpha=0.8)

    ax1.set_xlabel('Timestamp')
    ax1.set_ylabel('Bitrate (Kbps)')
    ax1.tick_params(axis='y')


    ax2 = ax1.twinx()
    ax2.plot(video_df['Timestamp'], video_df['PacketsReceived'], label='PacketsReceived', color='blue', linestyle='solid', alpha=0.2)
    ax2.set_ylabel('PacketsReceived')
    ax2.tick_params(axis='y')
    ax2.set_ylim(0, 15000)



    # Collect all legend handles and labels
    handles, labels = ax1.get_legend_handles_labels()
    handles2, labels2 = ax2.get_legend_handles_labels()

    # Merge legends and display a single combined legend
    plt.legend(handles + handles2, labels + labels2, loc='upper right')

#     ax1.hlines(y=5000, xmin=10, xmax=20, colors='purple', linestyles='dashed')
#     ax1.vlines(x=10, ymin=5000, ymax=10000, colors='black', linestyles='dotted')
#     ax1.vlines(x=20, ymin=0, ymax=5000, colors='black', linestyles='dotted')

    # Formatting
    plt.xlabel('Timestamp (seconds)')
    plt.title('CurrentBitrate vs TargetBitrate - 360p 30FPS')
    plt.xticks(rotation=45)
#     plt.legend()
    plt.grid()

#     plt.xticks(rotation=45)

    # Show plot
    plt.tight_layout()
    plt.show()

# Example usage
plot_bitrate('app.csv')