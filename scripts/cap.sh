#!/bin/bash

# Trap SIGINT (Ctrl+C) to exit cleanly
trap "echo -e '\nStopping bandwidth control'; exit" SIGINT

# Loop through bandwidth values
while true; do
    for pipe in 200 60 30 60; do
        echo "Applying bandwidth limit: ${pipe} Mbit/s"

        # Configure the dummynet pipe
        sudo dnctl pipe 1 config delay 0ms bw ${pipe}Mbit/s plr 0

        # Countdown timer
        seconds_left=240
        while [ $seconds_left -gt 0 ]; do
            echo -ne "Time left: ${seconds_left}s\r"
            sleep 1
            ((seconds_left--))
        done
    done

done

# Usage:
# Make the script executable with: chmod +x script.sh
# Run with: ./script.sh
