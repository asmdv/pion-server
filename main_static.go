package main

import (
	"fmt"
	"os/exec"

	"github.com/pion/webrtc/v4"
)

// createVideoTrack creates a track that streams video from a file
func createVideoTrack() (*webrtc.TrackLocalStaticRTP, error) {
	track, err := webrtc.NewTrackLocalStaticRTP(webrtc.RTPCodecCapability{
		MimeType:  webrtc.MimeTypeH264,
		ClockRate: 90000,
	}, "video", "pion")
	if err != nil {
		return nil, err
	}

	// Use ffmpeg to read the video file and stream RTP
	cmd := exec.Command("ffmpeg", "-re", "-i", "video.mp4", "-c:v", "libx264", "-f", "rtp", "rtp://127.0.0.1:5004")
	if err := cmd.Start(); err != nil {
		return nil, fmt.Errorf("failed to start ffmpeg: %w", err)
	}

	go func() {
		if err := cmd.Wait(); err != nil {
			fmt.Printf("ffmpeg error: %v\n", err)
		}
	}()

	return track, nil
}
