// SPDX-FileCopyrightText: 2023 The Pion community <https://pion.ly>
// SPDX-License-Identifier: MIT

//go:build !js
// +build !js

// sfu-ws is a many-to-many websocket based SFU
package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"log"
	"net/http"
	"os"
	"sync"
	"text/template"
	"time"

	"github.com/gorilla/websocket"
	"github.com/pion/interceptor"
	"github.com/pion/interceptor/pkg/cc"
	"github.com/pion/interceptor/pkg/gcc"
	"github.com/pion/interceptor/pkg/stats"
	"github.com/pion/logging"
	"github.com/pion/rtcp"
	"github.com/pion/rtp"
	"github.com/pion/webrtc/v4"
)

// nolint
var (
	addr     = flag.String("addr", ":8080", "http service address")
	upgrader = websocket.Upgrader{
		CheckOrigin: func(r *http.Request) bool { return true },
	}
	indexTemplate = &template.Template{}

	// lock for peerConnections and trackLocals
	listLock        sync.RWMutex
	peerConnections []peerConnectionState
	trackLocals     map[string]*webrtc.TrackLocalStaticRTP

	mainLogger    = logging.NewDefaultLoggerFactory().NewLogger("sfu-ws")
	bitrateLogger = logging.NewDefaultLoggerFactory().NewLogger("bitrate")
)

// Logger struct holds the log file and logger instance
type Logger struct {
	file   *os.File
	logger *log.Logger
}

// NewLogger initializes a new logger that writes to a file
func NewLogger(filename string) (*Logger, error) {
	file, err := os.OpenFile(filename, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0666)
	if err != nil {
		return nil, err
	}

	logger := log.New(file, "", 0)
	return &Logger{file: file, logger: logger}, nil
}

// Info logs an informational message
func (l *Logger) Info(message string) {
	//l.logger.SetPrefix("INFO: ")
	l.logger.Println(message)
}

// Infof logs a formatted informational message
func (l *Logger) Infof(format string, args ...interface{}) {
	message := fmt.Sprintf(format, args...)
	l.Info(message)
}

// Warning logs a warning message
func (l *Logger) Warning(message string) {
	l.logger.SetPrefix("WARNING: ")
	l.logger.Println(message)
}

// Error logs an error message
func (l *Logger) Error(message string) {
	l.logger.SetPrefix("ERROR: ")
	l.logger.Println(message)
}

// Close the log file when done
func (l *Logger) Close() {
	l.file.Close()
}

type websocketMessage struct {
	Event string `json:"event"`
	Data  string `json:"data"`
}

type peerConnectionState struct {
	peerConnection *webrtc.PeerConnection
	websocket      *threadSafeWriter
}

// BitrateTracker helps calculate bitrate for a specific track
type BitrateTracker struct {
	mu               sync.Mutex
	lastPacketTime   time.Time
	lastPacketBytes  uint64
	currentBitrate   float64
	intervalDuration time.Duration
	currentDelay     time.Duration
}

// AddPacket adds a new packet to the bitrate calculation
func (bt *BitrateTracker) AddPacket(packetSize int, packetDelayImpl *PacketDelayCalculatorImpl) {
	bt.mu.Lock()
	defer bt.mu.Unlock()

	now := time.Now()
	bt.lastPacketBytes += uint64(packetSize)

	// If more than the interval has passed, calculate bitrate
	if now.Sub(bt.lastPacketTime) >= bt.intervalDuration {
		// Calculate bitrate in bits per second
		bt.currentBitrate = float64(bt.lastPacketBytes*8) / bt.intervalDuration.Seconds()
		delay := packetDelayImpl.GetAverageDelay()
		bt.currentDelay = delay
		// Reset for next interval
		bt.lastPacketTime = now
		bt.lastPacketBytes = 0
	}
}

// GetBitrate returns the current bitrate
func (bt *BitrateTracker) GetBitrate() float64 {
	bt.mu.Lock()
	defer bt.mu.Unlock()
	return bt.currentBitrate
}

func (bt *BitrateTracker) GetDelay() time.Duration {
	bt.mu.Lock()
	defer bt.mu.Unlock()
	return bt.currentDelay
}

// NewBitrateTracker creates a new BitrateTracker
func NewBitrateTracker() *BitrateTracker {
	return &BitrateTracker{
		intervalDuration: time.Second * 1, // Calculate bitrate every second
	}
}

// Packet Delay Calculator
type PacketDelayCalculator interface {
	CalculateDelay(packet *rtp.Packet) time.Duration
}

type PacketDelayCalculatorImpl struct {
	totalDelay  time.Duration
	packetCount int
}

// NewPacketDelayCalculator creates a new PacketDelayCalculator
func NewPacketDelayCalculator() *PacketDelayCalculatorImpl {
	return &PacketDelayCalculatorImpl{}
}

// CalculateDelay calculates the delay of a packet
func (p *PacketDelayCalculatorImpl) CalculateDelay(packet *rtp.Packet) time.Duration {
	// arrivalTime := time.Now().Unix()
	// rtpTimestamp := packet.Timestamp / 90000
	// mainLogger.Infof("Arrival Time: %v, RTP Timestamp: %v\n", arrivalTime, rtpTimestamp)
	delay := time.Duration(0) //arrivalTime.Sub(time.Unix(int64(rtpTimestamp), 0))
	p.totalDelay += delay
	p.packetCount++
	return delay
}

// GetAverageDelay returns the average delay over the last second
func (p *PacketDelayCalculatorImpl) GetAverageDelay() time.Duration {
	if p.packetCount == 0 {
		return 0
	}
	averageDelay := p.totalDelay / time.Duration(p.packetCount)
	p.totalDelay = 0
	p.packetCount = 0
	return averageDelay
}

func main() {
	// Parse the flags passed to program
	flag.Parse()

	// Init other state
	trackLocals = map[string]*webrtc.TrackLocalStaticRTP{}

	// Read index.html from disk into memory, serve whenever anyone requests /
	indexHTML, err := os.ReadFile("index.html")
	if err != nil {
		panic(err)
	}
	indexTemplate = template.Must(template.New("").Parse(string(indexHTML)))

	// websocket handler
	http.HandleFunc("/websocket", websocketHandler)

	// index.html handler
	http.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		if err = indexTemplate.Execute(w, "ws://"+r.Host+"/websocket"); err != nil {
			mainLogger.Errorf("Failed to parse index template: %v", err)
		}
	})

	// request a keyframe every 3 seconds
	go func() {
		for range time.NewTicker(time.Second * 3).C {
			dispatchKeyFrame()
		}
	}()

	// start HTTP server
	if err = http.ListenAndServe(*addr, nil); err != nil { //nolint: gosec
		mainLogger.Errorf("Failed to start http server: %v", err)
	}
}

// Add to list of tracks and fire renegotation for all PeerConnections
func addTrack(t *webrtc.TrackRemote) *webrtc.TrackLocalStaticRTP {
	listLock.Lock()
	defer func() {
		listLock.Unlock()
		signalPeerConnections()
	}()

	// Create a new TrackLocal with the same codec as our incoming
	trackLocal, err := webrtc.NewTrackLocalStaticRTP(t.Codec().RTPCodecCapability, t.ID(), t.StreamID())
	if err != nil {
		panic(err)
	}

	trackLocals[t.ID()] = trackLocal
	return trackLocal
}

// Remove from list of tracks and fire renegotation for all PeerConnections
func removeTrack(t *webrtc.TrackLocalStaticRTP) {
	listLock.Lock()
	defer func() {
		listLock.Unlock()
		signalPeerConnections()
	}()

	delete(trackLocals, t.ID())
}

// signalPeerConnections updates each PeerConnection so that it is getting all the expected media tracks
func signalPeerConnections() {
	listLock.Lock()
	defer func() {
		listLock.Unlock()
		dispatchKeyFrame()
	}()

	attemptSync := func() (tryAgain bool) {
		for i := range peerConnections {
			if peerConnections[i].peerConnection.ConnectionState() == webrtc.PeerConnectionStateClosed {
				peerConnections = append(peerConnections[:i], peerConnections[i+1:]...)
				return true // We modified the slice, start from the beginning
			}

			// map of sender we already are seanding, so we don't double send
			existingSenders := map[string]bool{}

			for _, sender := range peerConnections[i].peerConnection.GetSenders() {
				if sender.Track() == nil {
					continue
				}

				existingSenders[sender.Track().ID()] = true

				// If we have a RTPSender that doesn't map to a existing track remove and signal
				if _, ok := trackLocals[sender.Track().ID()]; !ok {
					if err := peerConnections[i].peerConnection.RemoveTrack(sender); err != nil {
						return true
					}
				}
			}

			// Don't receive videos we are sending, make sure we don't have loopback
			for _, receiver := range peerConnections[i].peerConnection.GetReceivers() {
				if receiver.Track() == nil {
					continue
				}

				existingSenders[receiver.Track().ID()] = true
			}

			// Add all track we aren't sending yet to the PeerConnection
			for trackID := range trackLocals {
				if _, ok := existingSenders[trackID]; !ok {
					if _, err := peerConnections[i].peerConnection.AddTrack(trackLocals[trackID]); err != nil {
						return true
					}
				}
			}

			offer, err := peerConnections[i].peerConnection.CreateOffer(nil)
			if err != nil {
				return true
			}

			if err = peerConnections[i].peerConnection.SetLocalDescription(offer); err != nil {
				return true
			}

			offerString, err := json.Marshal(offer)
			if err != nil {
				mainLogger.Errorf("Failed to marshal offer to json: %v", err)
				return true
			}

			mainLogger.Infof("Send offer to client: %v", offer)

			if err = peerConnections[i].websocket.WriteJSON(&websocketMessage{
				Event: "offer",
				Data:  string(offerString),
			}); err != nil {
				return true
			}
		}

		return
	}

	for syncAttempt := 0; ; syncAttempt++ {
		if syncAttempt == 25 {
			// Release the lock and attempt a sync in 3 seconds. We might be blocking a RemoveTrack or AddTrack
			go func() {
				time.Sleep(time.Second * 3)
				signalPeerConnections()
			}()
			return
		}

		if !attemptSync() {
			break
		}
	}
}

// dispatchKeyFrame sends a keyframe to all PeerConnections, used everytime a new user joins the call
func dispatchKeyFrame() {
	listLock.Lock()
	defer listLock.Unlock()

	for i := range peerConnections {
		for _, receiver := range peerConnections[i].peerConnection.GetReceivers() {
			if receiver.Track() == nil {
				continue
			}

			_ = peerConnections[i].peerConnection.WriteRTCP([]rtcp.Packet{
				&rtcp.PictureLossIndication{
					MediaSSRC: uint32(receiver.Track().SSRC()),
				},
			})
		}
	}
}

func getInboundRTPStreamStats(peerConnection *webrtc.PeerConnection) {
	stats := peerConnection.GetStats()
	for k, stat := range stats {
		mainLogger.Infof("Stats %v:: %v\n", k, stats)
		if inboundStat, ok := stat.(webrtc.InboundRTPStreamStats); ok {
			mainLogger.Infof("Bytes Received: %d, Packets Lost: %d\n",
				inboundStat.BytesReceived, inboundStat.PacketsLost)
		}
	}
}

// Handle incoming websockets
func websocketHandler(w http.ResponseWriter, r *http.Request) {

	// Upgrade HTTP request to Websocket
	unsafeConn, err := upgrader.Upgrade(w, r, nil)
	if err != nil {
		mainLogger.Errorf("Failed to upgrade HTTP to Websocket: ", err)
		return
	}

	statsLogger, err := NewLogger("app.csv")
	if err != nil {
		log.Fatalf("Could not create statsLogger: %v", err)
	}
	defer statsLogger.Close()
	statsLogger.Infof("Timestamp,Kind,PacketsReceived,PacketsLost,LossRation,Jitter,CurrentBitrate,TargetBitrate")

	c := &threadSafeWriter{unsafeConn, sync.Mutex{}}

	// When this frame returns close the Websocket
	defer c.Close() //nolint

	bitrateTrackers := map[string]*BitrateTracker{}

	interceptorRegistry := &interceptor.Registry{}

	statsInterceptorFactory, err := stats.NewInterceptor()

	var statsGetter stats.Getter
	statsInterceptorFactory.OnNewPeerConnection(func(_ string, g stats.Getter) {
		statsGetter = g
	})
	interceptorRegistry.Add(statsInterceptorFactory)

	if err != nil {
		panic(err)
	}

	m := &webrtc.MediaEngine{}

	// --- Explicitly Register  Codecs to Prioritize H264 ---
	// Register Opus Audio
	if err := m.RegisterCodec(webrtc.RTPCodecParameters{
		RTPCodecCapability: webrtc.RTPCodecCapability{MimeType: webrtc.MimeTypeOpus, ClockRate: 48000, Channels: 2, SDPFmtpLine: "minptime=10;useinbandfec=1", RTCPFeedback: nil},
		PayloadType:        111, // Standard PT for Opus
	}, webrtc.RTPCodecTypeAudio); err != nil {
		panic(err)
	}

	// Register H264 Video (PRIORITY 1)
	// Make sure to include packetization-mode=1 for compatibility
	if err := m.RegisterCodec(webrtc.RTPCodecParameters{
		RTPCodecCapability: webrtc.RTPCodecCapability{
			MimeType:     webrtc.MimeTypeH264,
			ClockRate:    90000,
			Channels:     0,
			SDPFmtpLine:  "level-asymmetry-allowed=1;packetization-mode=1;profile-level-id=42e01f", // Baseline profile, packetization-mode=1
			RTCPFeedback: []webrtc.RTCPFeedback{{Type: "goog-remb", Parameter: ""}, {Type: "ccm", Parameter: "fir"}, {Type: "nack", Parameter: ""}, {Type: "nack", Parameter: "pli"}},
		},
		PayloadType: 102, // Example Payload Type for H264 (ensure it doesn't clash)
	}, webrtc.RTPCodecTypeVideo); err != nil {
		panic(err)
	}

	// Register VP8 Video (PRIORITY 2)
	if err := m.RegisterCodec(webrtc.RTPCodecParameters{
		RTPCodecCapability: webrtc.RTPCodecCapability{
			MimeType:     webrtc.MimeTypeVP8,
			ClockRate:    90000,
			Channels:     0,
			SDPFmtpLine:  "", // VP8 typically doesn't need fmtp lines like H264
			RTCPFeedback: []webrtc.RTCPFeedback{{Type: "goog-remb", Parameter: ""}, {Type: "ccm", Parameter: "fir"}, {Type: "nack", Parameter: ""}, {Type: "nack", Parameter: "pli"}},
		},
		PayloadType: 96, // Example Payload Type for VP8
	}, webrtc.RTPCodecTypeVideo); err != nil {
		panic(err)
	}
	// --- End Explicit Codec Registration ---

	// Create a new PacketDelayCalculator
	packetDelayCalculator := NewPacketDelayCalculator()

	// Create a Congestion Controller. This analyzes inbound and outbound data and provides
	// suggestions on how much we should be sending.
	//
	// Passing `nil` means we use the default Estimation Algorithm which is Google Congestion Control.
	// You can use the other ones that Pion provides, or write your own!
	congestionController, err := cc.NewInterceptor(func() (cc.BandwidthEstimator, error) {
		return gcc.NewSendSideBWE(gcc.SendSideBWEInitialBitrate(500_000))
	})
	if err != nil {
		panic(err)
	}

	estimatorChan := make(chan cc.BandwidthEstimator, 1)
	congestionController.OnNewPeerConnection(func(id string, estimator cc.BandwidthEstimator) { //nolint: revive
		estimatorChan <- estimator
	})

	interceptorRegistry.Add(congestionController)
	if err = webrtc.ConfigureTWCCHeaderExtensionSender(m, interceptorRegistry); err != nil {
		panic(err)
	}

	if err = webrtc.RegisterDefaultInterceptors(m, interceptorRegistry); err != nil {
		panic(err)
	}

	// api := webrtc.NewAPI()
	peerConnection, err := webrtc.NewAPI(webrtc.WithInterceptorRegistry(interceptorRegistry), webrtc.WithMediaEngine(m)).NewPeerConnection(webrtc.Configuration{
		ICEServers: []webrtc.ICEServer{
			{
				URLs: []string{"stun:stun.l.google.com:19302"},
			},
		},
		ICETransportPolicy: webrtc.ICETransportPolicyAll,
	})
	if err != nil {
		panic(err)
	}
	defer func() {
		if cErr := peerConnection.Close(); cErr != nil {
			mainLogger.Infof("cannot close peerConnection: %v\n", cErr)
		}
	}()

	// ✅ Add Data Channel Handler (UNCOMMENTED AND IMPLEMENTED)
	peerConnection.OnDataChannel(func(d *webrtc.DataChannel) {
		mainLogger.Infof("✅ SERVER: New DataChannel '%s'-%d created by remote peer\n", d.Label(), d.ID())

		// Handle when the data channel is opened
		d.OnOpen(func() {
			mainLogger.Infof("✅ SERVER: DataChannel '%s'-%d is open\n", d.Label(), d.ID())
		})

		// Handle incoming messages on the data channel
		d.OnMessage(func(msg webrtc.DataChannelMessage) {
			receivedMsg := string(msg.Data)
			mainLogger.Infof("✅ SERVER: Received message on DataChannel '%s': %s\n", d.Label(), receivedMsg) // Log received message

			// Check if the message is "hello world" and send reply
			if receivedMsg == "hello world" {
				replyMsg := "hello world accepted"
				mainLogger.Infof("✅ SERVER: Sending reply: '%s'\n", replyMsg) // Log sending reply
				if err := d.SendText(replyMsg); err != nil {
					mainLogger.Errorf("❌ SERVER: Failed to send message on DataChannel '%s': %v", d.Label(), err)
				}
			} else {
				mainLogger.Infof("✅ SERVER: Received unexpected message: '%s'\n", receivedMsg)
			}
		})

		// Handle when the data channel is closed
		d.OnClose(func() {
			mainLogger.Infof("❌ SERVER: DataChannel '%s'-%d is closed\n", d.Label(), d.ID())
		})

		// Handle errors on the data channel
		d.OnError(func(err error) {
			mainLogger.Errorf("❌ SERVER: DataChannel '%s'-%d Error: %v\n", d.Label(), d.ID(), err)
		})
	})
	// --- End Data Channel Handler ---

	// Wait until our Bandwidth Estimator has been created
	estimator := <-estimatorChan
	bitrateTicker := time.NewTicker(500 * time.Millisecond)
	defer bitrateTicker.Stop() // Ensure the ticker is stopped when done

	// // Create new PeerConnection
	// peerConnection, err := api.NewPeerConnection(webrtc.Configuration{
	// 	RTCPMuxPolicy:      webrtc.RTCPMuxPolicyRequire,
	// 	ICETransportPolicy: webrtc.ICETransportPolicyAll,
	// 	BundlePolicy:       webrtc.BundlePolicyBalanced,
	// 	SDPSemantics:       webrtc.SDPSemanticsUnifiedPlan,
	// })
	// if err != nil {
	// 	mainLogger.Errorf("Failed to creates a PeerConnection: %v", err)
	// 	return
	// }

	// When this frame returns close the PeerConnection
	defer peerConnection.Close() //nolint

	// Accept one audio and one video track incoming
	for _, typ := range []webrtc.RTPCodecType{webrtc.RTPCodecTypeVideo, webrtc.RTPCodecTypeAudio} {
		if _, err := peerConnection.AddTransceiverFromKind(typ, webrtc.RTPTransceiverInit{
			Direction: webrtc.RTPTransceiverDirectionRecvonly,
		}); err != nil {
			mainLogger.Errorf("Failed to add transceiver: %v", err)
			return
		}
	}

	// Add our new PeerConnection to global list
	listLock.Lock()
	peerConnections = append(peerConnections, peerConnectionState{peerConnection, c})
	listLock.Unlock()

	// Trickle ICE. Emit server candidate to client
	peerConnection.OnICECandidate(func(i *webrtc.ICECandidate) {
		if i == nil {
			return
		}
		// If you are serializing a candidate make sure to use ToJSON
		// Using Marshal will result in errors around `sdpMid`
		candidateString, err := json.Marshal(i.ToJSON())
		if err != nil {
			mainLogger.Errorf("Failed to marshal candidate to json: %v", err)
			return
		}

		mainLogger.Infof("Send candidate to client: %s", candidateString)

		if writeErr := c.WriteJSON(&websocketMessage{
			Event: "candidate",
			Data:  string(candidateString),
		}); writeErr != nil {
			mainLogger.Errorf("Failed to write JSON: %v", writeErr)
		}
	})

	// If PeerConnection is closed remove it from global list
	peerConnection.OnConnectionStateChange(func(p webrtc.PeerConnectionState) {
		mainLogger.Infof("Connection state change: %s", p)

		switch p {
		case webrtc.PeerConnectionStateFailed:
			if err := peerConnection.Close(); err != nil {
				mainLogger.Errorf("Failed to close PeerConnection: %v", err)
			}
		case webrtc.PeerConnectionStateClosed:
			signalPeerConnections()
		default:
		}
	})

	peerConnection.OnTrack(func(t *webrtc.TrackRemote, receiver *webrtc.RTPReceiver) {
		codec := t.Codec()
		mainLogger.Infof("Got remote track: Kind=%s, ID=%s, StreamID=%s, Codec=%s, PayloadType=%d, SSRC=%d", t.Kind(), t.ID(), t.StreamID(), codec.MimeType, codec.PayloadType, t.SSRC())
		// Create a track to fan out our incoming video to all peers
		trackLocal := addTrack(t)

		// a, b := peerConnection.GetStats().GetConnectionStats(peerConnection)
		bitrateTrackers[trackLocal.Kind().String()] = NewBitrateTracker()

		defer removeTrack(trackLocal)

		rtpSender, err := peerConnection.AddTrack(trackLocal)
		if err != nil {
			panic(err)
		}

		// Read incoming RTCP packets
		// Before these packets are returned they are processed by interceptors. For things
		// like NACK this needs to be called.
		go func() {
			rtcpBuf := make([]byte, 1500)
			for {
				if _, _, rtcpErr := rtpSender.Read(rtcpBuf); rtcpErr != nil {
					return
				}
			}
		}()

		buf := make([]byte, 1500)
		rtpPkt := &rtp.Packet{}

		go func() {
			var oldBytes int64 = 0
			var oldPacketsReceived uint64 = 0
			var oldPacketsLost int64 = 0
			_ = oldBytes
			for {
				select {
				case <-bitrateTicker.C: // Wait for the next tick
					if t.Kind().String() == "video" {
						targetBitrate := estimator.GetTargetBitrate()
						_ = targetBitrate
						//inter := estimator.GetStats()
						//mainLogger.Infof("Inter: %v\n", inter)
						//for rid, tracker := range bitrateTrackers {
						//	bitrate := tracker.GetBitrate()
						//delay := tracker.GetDelay()
						//bitrateLogger.Infof("Stream %s: Current Bitrate %v kbps | Target: %v kbps\n", rid, int(bitrate)/1000, targetBitrate/1000)
						// mainLogger.Infof("Stream %s: Delay: %v\n", rid, delay)
						//}
						stats := statsGetter.Get(uint32(t.SSRC()))

						tracker := bitrateTrackers[trackLocal.Kind().String()]
						bitrate := tracker.GetBitrate()
						_ = bitrate
						bitrateLogger.Infof("t.SSRC: %v, t.Kind: %v, Received: %v, Lost: %v, Ratio: %.2f, Jitter: %.2f, Bitrate: %v, Target: %v, LastPacket: %v", uint32(t.SSRC()), t.Kind(), stats.InboundRTPStreamStats.PacketsReceived-oldPacketsReceived, stats.InboundRTPStreamStats.PacketsLost-oldPacketsLost, float64(stats.InboundRTPStreamStats.PacketsLost-oldPacketsLost)/float64(stats.InboundRTPStreamStats.PacketsReceived-oldPacketsReceived), stats.InboundRTPStreamStats.Jitter, (int64(stats.InboundRTPStreamStats.BytesReceived/1000)-oldBytes)*8, targetBitrate/1000, stats.InboundRTPStreamStats.LastPacketReceivedTimestamp)
						statsLogger.Infof("%v,%v,%v,%v,%.2f,%.2f,%v,%v", time.Now().Format("2006-01-02T15:04:05Z07:00"), t.Kind(), stats.InboundRTPStreamStats.PacketsReceived-oldPacketsReceived, stats.InboundRTPStreamStats.PacketsLost-oldPacketsLost, float64(stats.InboundRTPStreamStats.PacketsLost-oldPacketsLost)/float64(stats.InboundRTPStreamStats.PacketsReceived-oldPacketsReceived), stats.InboundRTPStreamStats.Jitter, (int64(stats.InboundRTPStreamStats.BytesReceived/1000)-oldBytes)*8, targetBitrate/1000)
						//bitrateLogger.Infof("Old before: %v", oldBytes)
						oldBytes = int64(stats.InboundRTPStreamStats.BytesReceived / 1000)
						oldPacketsReceived = stats.InboundRTPStreamStats.PacketsReceived
						oldPacketsLost = stats.InboundRTPStreamStats.PacketsLost

						//bitrateLogger.Infof("Old now: %v", oldBytes)
					}
				}
			}
		}()

		//go func() {
		//	// Print the stats for this individual track
		//	for {
		//		stats := statsGetter.Get(uint32(t.SSRC()))
		//
		//		mainLogger.Infof("Stats for: %v\n", t.SSRC())
		//		mainLogger.Infof(": %v", stats.InboundRTPStreamStats)
		//
		//		time.Sleep(time.Second * 5)
		//	}
		//}()

		//go func() {
		//	for {
		//		time.Sleep(1 * time.Second)
		//		getInboundRTPStreamStats(peerConnection)
		//	}
		//}()

		for {
			i, _, err := t.Read(buf)
			if err != nil {
				return
			}

			packetDelayCalculator.CalculateDelay(rtpPkt)

			bitrateTrackers[t.Kind().String()].AddPacket(i, packetDelayCalculator)

			if err = rtpPkt.Unmarshal(buf[:i]); err != nil {
				mainLogger.Errorf("Failed to unmarshal incoming RTP packet: %v", err)
				return
			}

			rtpPkt.Extension = false
			rtpPkt.Extensions = nil

			if err = trackLocal.WriteRTP(rtpPkt); err != nil {
				return
			}
		}
	})

	peerConnection.OnICEConnectionStateChange(func(is webrtc.ICEConnectionState) {
		mainLogger.Infof("ICE connection state changed: %s", is)
	})

	// Signal for the new PeerConnection
	signalPeerConnections()

	message := &websocketMessage{}
	for {
		_, raw, err := c.ReadMessage()
		if err != nil {
			mainLogger.Errorf("Failed to read message: %v", err)
			return
		}

		mainLogger.Infof("Got message: %s", raw)

		if err := json.Unmarshal(raw, &message); err != nil {
			mainLogger.Errorf("Failed to unmarshal json to message: %v", err)
			return
		}

		switch message.Event {
		case "candidate":
			candidate := webrtc.ICECandidateInit{}
			if err := json.Unmarshal([]byte(message.Data), &candidate); err != nil {
				mainLogger.Errorf("Failed to unmarshal json to candidate: %v", err)
				return
			}

			mainLogger.Infof("Got candidate: %v", candidate)

			if err := peerConnection.AddICECandidate(candidate); err != nil {
				mainLogger.Errorf("Failed to add ICE candidate: %v", err)
				return
			}
		case "answer":
			answer := webrtc.SessionDescription{}
			if err := json.Unmarshal([]byte(message.Data), &answer); err != nil {
				mainLogger.Errorf("Failed to unmarshal json to answer: %v", err)
				return
			}

			mainLogger.Infof("Got answer: %v", answer)

			if err := peerConnection.SetRemoteDescription(answer); err != nil {
				mainLogger.Errorf("Failed to set remote description: %v", err)
				return
			}
		default:
			mainLogger.Errorf("unknown message: %+v", message)
		}
	}
}

// Helper to make Gorilla Websockets threadsafe
type threadSafeWriter struct {
	*websocket.Conn
	sync.Mutex
}

func (t *threadSafeWriter) WriteJSON(v interface{}) error {
	t.Lock()
	defer t.Unlock()

	return t.Conn.WriteJSON(v)
}
