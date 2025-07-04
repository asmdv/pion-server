import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:path_provider/path_provider.dart';

// ... (Keep existing code: main, remoteHost, counter, mediaConstraints, etc.) ...
void main() => runApp(const MyApp());
//String remoteHost = "192.168.1.158";
String remoteHost = "192.168.1.161";
//String remoteHost = "172.16.2.37";
//String remoteHost = "10.18.175.171";
int counter = 0;

final mediaConstraints = <String, dynamic>{
  'audio': true,
  'video': {
    'mandatory': {
      'minWidth': '1920',
      'minHeight': '1080',
      'maxWidth': '3840',
      'maxHeight': '2160',
      'minFrameRate': '5',
      'maxFrameRate': '5',
    },
    'facingMode': 'environment',
    'optional': [],
  }
};

final mediaConstraints1 = <String, dynamic>{
  'audio': true,
  'video': {
    'mandatory': {
      'minWidth': '1920',
      'minHeight': '1080',
      'maxWidth': '3840',
      'maxHeight': '2160',
      'minFrameRate': '10',
      'maxFrameRate': '60',
    },
    'facingMode': 'environment',
    'optional': [],
  }
};


class MyApp extends StatefulWidget {

  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  static const _textStyle = TextStyle(fontSize: 24);

  // Local media
  final _localRenderer = RTCVideoRenderer();
  List<RTCVideoRenderer> _remoteRenderers = [];

  String localResolution = 'N/A';

  // Add a variable to hold the data channel
  RTCDataChannel? _dataChannel;
// Add a list to hold log messages for display (optional, but good for UI)
  final List<String> _logMessages = [];

  WebSocketChannel? _socket;
  RTCPeerConnection? _peerConnection; // Make nullable for late init safety
  Timer? _statsTimer; // Add variable to hold the timer instance

  // Configuration remains the same
  var configuration = <String, dynamic>{
    'sdpSemantics': 'unified-plan',
    'iceServers': [
      {'urls': 'stun:stun.l.google.com:19302'}
    ]
  };

  _MyAppState();

  @override
  void initState() {
    super.initState();
    connect();
  }


  Future<void> connect() async {
    // Ensure peer connection is created before use
    _peerConnection = await createPeerConnection(configuration, {}); // Pass configuration here
    final pc = _peerConnection!; // Use non-nullable reference after creation

    // --- Create Data Channel ---
    try {
      _dataChannel = await pc.createDataChannel(
        "chat", // Label must match if server expects a specific label, otherwise arbitrary
        RTCDataChannelInit() // Basic configuration is usually sufficient
          ..ordered = true, // Ensure message order
      );
      if (_dataChannel != null) {
        _addLog("✅ CLIENT: Data channel created.");
        _registerDataChannelHandlers(); // Register handlers after creation
      } else {
        _addLog("❌ CLIENT: Failed to create data channel.");
      }
    } catch (e) {
      _addLog("❌ CLIENT: Error creating data channel: $e");
    }
    // --- End Data Channel Creation ---


    await _localRenderer.initialize();
    final localStream = await navigator.mediaDevices
        .getUserMedia(mediaConstraints1);
    _localRenderer.srcObject = localStream;

    // Add tracks
    localStream.getTracks().forEach((track) async {
      await pc.addTrack(track, localStream);
      print("Added track: ${track.kind}");
    });

    // --- Bitrate/Degradation Settings using 'parameters' property ---
    pc.senders.then((senders) {
      senders.forEach((sender) async {
        if (sender.track?.kind == 'video'){
          try {
            var parameters = sender.parameters;
            if (parameters.encodings == null || parameters.encodings!.isEmpty) {
              parameters.encodings = [RTCRtpEncoding()];
              print("Initialized parameters.encodings as it was null or empty.");
            }
            if (parameters.encodings!.isNotEmpty) {
              parameters.encodings![0].maxBitrate = 100 * 1000 * 1000; // 100 Mbps
              parameters.encodings![0].minBitrate = 1 * 1000 * 1000;   // 1 Mbps
              parameters.degradationPreference = RTCDegradationPreference.BALANCED;
              print("Attempting to set sender parameters: Max Bitrate=${parameters.encodings![0].maxBitrate}, Min Bitrate=${parameters.encodings![0].minBitrate}, Degradation=${parameters.degradationPreference}");
              await sender.setParameters(parameters);
              print("Successfully set sender parameters.");
            } else {
              print("Warning: Could not set bitrate/degradation - parameters.encodings is still empty after initialization attempt.");
            }
          } catch (e) {
            print("Error getting/setting sender parameters: $e");
            if (e.toString().contains('setParameters')) {
              print("It seems 'setParameters' might also be unavailable or incorrect.");
            }
          }
        }
      });
    });
  
    // --- End Bitrate/Degradation Block ---

    // --- Adaptive Bitrate Controller Using Target Bitrate Reference ---

    // Cache variables for previous stats
    int? _lastBytesSent;
    DateTime? _lastTimestamp;
    int? _lastAllocatedBitrate;
    DateTime _lastAllocationTime = DateTime.now();

    const int bitrateChangeThresholdBps = 10000; // Trigger reallocation if delta > 10 kbps
    const int allocationCooldownSec = 60;         // Reallocate at most once every 60 seconds

    // Periodic stats collection and strategy-based encoder control
    _statsTimer = Timer.periodic(const Duration(seconds: 1), (timer) async {
      if (!mounted || _peerConnection == null) return;

      final pc = _peerConnection!;
      final now = DateTime.now();
      final senders = await pc.senders;

      num? targetBitrate;
      num? currentBitrate;
      num? width;
      num? height;
      num? fps;

      for (var sender in senders) {
        if (sender.track?.kind == 'video') {
          final stats = await sender.getStats();
          for (var report in stats) {
            /*print('📊 Report Type: ${report.type}');
            report.values.forEach((key, value) {
              print('   - $key: $value');
            });
            */
            if (report.type == 'outbound-rtp') {
              if (report.values['targetBitrate'] != null) {
                targetBitrate = report.values['targetBitrate'];
              }

              if (report.values['bytesSent'] != null) {
                final bytesSent = report.values['bytesSent'];
                if (_lastBytesSent != null && _lastTimestamp != null) {
                  final elapsedMs = now.difference(_lastTimestamp!).inMilliseconds;
                  if (elapsedMs > 0) {
                    currentBitrate = ((bytesSent - _lastBytesSent!) * 8) / elapsedMs;
                  }
                }
                _lastBytesSent = bytesSent;
                _lastTimestamp = now;
              }
            }

            if (report.type == 'media-source') {
              width = report.values['width'];
              height = report.values['height'];
              fps = report.values['framesPerSecond'];
            }

          }


          // Strategy-based reallocation logic
          /*if (targetBitrate != null && targetBitrate > 0) {
            final int newBitrate = targetBitrate.toInt();
            final int nowMs = now.millisecondsSinceEpoch;

            final bool shouldReallocate =
                _lastAllocatedBitrate == null ||
                (newBitrate - _lastAllocatedBitrate!).abs() > bitrateChangeThresholdBps ||
                now.difference(_lastAllocationTime).inSeconds > allocationCooldownSec;

            if (shouldReallocate) {
              _lastAllocatedBitrate = newBitrate;
              _lastAllocationTime = now;

              try {
                final parameters = sender.parameters;
                if (parameters.encodings == null || parameters.encodings!.isEmpty) {
                  parameters.encodings = [RTCRtpEncoding()];
                }

                // Apply updated max bitrate (scale as needed), degradation preference
                parameters.encodings![0].maxBitrate = (newBitrate * 1.2).toInt();
                parameters.degradationPreference = RTCDegradationPreference.BALANCED;

                await sender.setParameters(parameters);
                print("✅ Bitrate cap set to ${(newBitrate * 1.2 / 1000).toStringAsFixed(1)} kbps");
              } catch (e) {
                print("⚠️ Failed to apply sender parameters: $e");
              }
            } else {
              print("⏩ Skipped bitrate update (same or too soon)");
            }
          }*/

          // Print bitrate info
          final timestamp = DateTime.now().toIso8601String();
          //print(' Target Bitrate: ${(targetBitrate ?? 0) / 1000} kbps |  Current Bitrate: ${currentBitrate?.toStringAsFixed(2) ?? 'N/A'} kbps');
          //visualize target bitrate and current bitrate
          print('$timestamp,${(targetBitrate ?? 0) / 1000},${currentBitrate?.toStringAsFixed(2) ?? 'N/A'},${width ?? 'N/A'}x${height ?? 'N/A'},${fps?.toStringAsFixed(1) ?? 'N/A'}');
          break; // Assume only one video sender is managed
        }
      }
    });
    // --- End Adaptive Bitrate Block ---



    // ... (onIceCandidate, onTrack, onRemoveStream, state handlers remain the same) ...
    pc.onIceCandidate = (candidate) {
      if (candidate != null) {
        _addLog("✅ CLIENT: Sending ICE candidate");
        _socket?.sink.add(jsonEncode({
          "event": "candidate",
          "data": jsonEncode({
            'sdpMLineIndex': candidate.sdpMLineIndex,
            'sdpMid': candidate.sdpMid,
            'candidate': candidate.candidate,
          })
        }));
      } else {
        print("Received null ICE candidate (end of candidates)");
      }
    };

    pc.onTrack = (event) async {
      print("Track received: ${event.track.kind}, Stream IDs: ${event.streams.map((s) => s.id).join(', ')}");
      if (event.track.kind == 'video' && event.streams.isNotEmpty) {
        var renderer = RTCVideoRenderer();
        await renderer.initialize();
        renderer.srcObject = event.streams[0];

        if (mounted) {
          setState(() {
            _remoteRenderers.add(renderer);
          });
        } else {
          renderer.dispose();
        }
      }
      if (event.track.kind == 'audio') {
        print("Audio track received: ${event.track.id}");
        event.streams[0].getAudioTracks().forEach((track) {
          print("Attaching audio track ${track.id} to stream ${event.streams[0].id}");
        });
      }
    };

    pc.onRemoveStream = (stream) {
      print("Stream removed: ${stream.id}");
      RTCVideoRenderer? rendererToRemove;
      final newRenderList = <RTCVideoRenderer>[];
      for (final r in _remoteRenderers) {
        if (r.srcObject?.id == stream.id) {
          print("Found renderer to remove for stream ${stream.id}");
          rendererToRemove = r;
        } else {
          newRenderList.add(r);
        }
      }
      if (mounted) {
        setState(() {
          _remoteRenderers = newRenderList;
        });
      }
      if (rendererToRemove != null) {
        print("Disposing renderer for stream ${stream.id}");
        rendererToRemove.srcObject = null;
        rendererToRemove.dispose();
      }
    };

    pc.onConnectionState = (state) {
      print("Connection state changed: $state");
    };

    pc.onIceConnectionState = (state) {
      print("ICE connection state changed: $state");
    };

    pc.onIceGatheringState = (state) {
      print("ICE gathering state changed: $state");
    };


    // ... (WebSocket listener logic remains the same, including SDP manipulation) ...
    final socket =
    WebSocketChannel.connect(Uri.parse('ws://$remoteHost:8080/websocket?client=client'));
    _socket = socket;
    socket.stream.listen((raw) async {
      Map<String, dynamic> msg = jsonDecode(raw);

      switch (msg['event']) {
        case 'candidate':
          final parsed = jsonDecode(msg['data']);
          if (parsed['candidate'] != null) {
            print("Received remote ICE candidate");
            try {
              await pc.addCandidate(
                RTCIceCandidate(
                  parsed['candidate'],
                  parsed['sdpMid'],
                  parsed['sdpMLineIndex'],
                ),
              );
            } catch (e) {
              print("Error adding remote ICE candidate: $e");
            }
          }
          return;
        case 'offer':
          final offer = jsonDecode(msg['data']);
          print("Received offer");
          try {
            await pc.setRemoteDescription(
                RTCSessionDescription(offer['sdp'], offer['type']));
            print("Remote description (offer) set successfully.");

            RTCSessionDescription answer = await pc.createAnswer({});
            print("Created answer.");

            // --- SDP Manipulation to prefer H264 ---
            String? originalSdp = answer.sdp;
            String modifiedSdp = originalSdp ?? '';

            if (originalSdp != null && originalSdp.isNotEmpty) {
              print("Original Answer SDP:\n$originalSdp");
              modifiedSdp = preferVideoCodec(originalSdp, 'h264');
              if (modifiedSdp != originalSdp) {
                print("Applying modified SDP to prefer H264.");
                answer = RTCSessionDescription(modifiedSdp, answer.type);
                print("Modified Answer SDP:\n$modifiedSdp");
              } else {
                print("SDP modification for H264 preference failed or was not needed.");
                modifiedSdp = ensurePacketizationMode(originalSdp, 'h264');
                if (modifiedSdp != originalSdp) {
                  print("Applying modified SDP for packetization-mode only.");
                  answer = RTCSessionDescription(modifiedSdp, answer.type);
                  print("Modified Answer SDP (packetization-mode only):\n$modifiedSdp");
                }
              }
            } else {
              print("Warning: Created answer SDP was null or empty.");
            }
            // --- End SDP Manipulation ---

            await pc.setLocalDescription(answer);
            print("Local description (answer) set successfully.");

            _socket?.sink.add(jsonEncode({
              'event': 'answer',
              'data': jsonEncode({'type': answer.type, 'sdp': answer.sdp}),
            }));
            print("Sent answer to remote peer.");
          } catch (e) {
            print("Error handling offer: $e");
          }
          return;
        default:
          print("Received unknown WebSocket event: ${msg['event']}");
          break;
      }
    }, onError: (error) {
      print('WebSocket error: $error');
      _dispose();
    }, onDone: () {
      print('WebSocket closed by server!');
      _dispose();
    });
  }

  // --- ✅ Add Helper Function to Register Data Channel Handlers ---
  void _registerDataChannelHandlers() {
    _dataChannel?.onDataChannelState = (state) {
      _addLog("✅ CLIENT: DataChannel state: $state");
      if (state == RTCDataChannelState.RTCDataChannelOpen) {
        _addLog("✅ CLIENT: DataChannel open. Sending 'hello world'.");
        try {
          _dataChannel?.send(RTCDataChannelMessage("hello world"));
        } catch (e) {
          _addLog("❌ CLIENT: Error sending message: $e");
        }
      }
    };

    _dataChannel?.onMessage = (message) {
      if (message.type == MessageType.text) {
        _addLog("✅ CLIENT: Received message: ${message.text}");
        // You could check here if message.text == "hello world accepted"
      } else {
        _addLog("✅ CLIENT: Received binary message (length: ${message.binary.length})");
      }
    };

  }
// --- End Helper Function ---

  // --- ✅ Add Helper Function for Logging ---
  void _addLog(String log) {
    print(log); // Print to console
    if (mounted) { // Check if the widget is still in the tree
      setState(() {
        _logMessages.insert(0, "${DateTime.now().toIso8601String()}: $log"); // Add to list for UI
      });
    }
  }
// --- End Logging Helper ---


  // ... (Keep helper functions: preferVideoCodec, ensurePacketizationMode) ...
  String preferVideoCodec(String sdp, String codecMimeType) {
    List<String> lines = sdp.split('\r\n');
    int mLineIndex = -1;
    String? h264PayloadType;
    List<String> h264RtpmapLines = [];
    List<String> h264FmtpLines = [];
    List<String> h264RtcpFbLines = [];

    // Find the video media line and H264 payload type/lines
    for (int i = 0; i < lines.length; i++) {
      if (lines[i].startsWith('m=video')) {
        mLineIndex = i;
        // Look for H264 rtpmap within this media section
        for (int j = i + 1; j < lines.length; j++) {
          // Stop if we hit the next media section or end of SDP
          if (lines[j].startsWith('m=')) break;

          if (lines[j].startsWith('a=rtpmap:') && lines[j].toLowerCase().contains(codecMimeType)) {
            var parts = lines[j].substring(9).split(' ');
            h264PayloadType = parts[0];
            h264RtpmapLines.add(lines[j]); // Store the line
            print("Found H264 ($codecMimeType) payload type: $h264PayloadType");

            // Now find associated fmtp and rtcp-fb lines for this payload type
            String fmtpPrefix = 'a=fmtp:$h264PayloadType';
            String rtcpFbPrefix = 'a=rtcp-fb:$h264PayloadType';
            for (int k = i + 1; k < lines.length; k++) {
              if (lines[k].startsWith('m=')) break; // Stop at next m-line
              if (lines[k].startsWith(fmtpPrefix)) {
                // --- Apply packetization-mode=1 fix here ---
                if (!lines[k].contains('packetization-mode=1')) {
                  lines[k] = '${lines[k]};packetization-mode=1';
                  print("Added packetization-mode=1 to: ${lines[k]}");
                }
                // --- End fix ---
                h264FmtpLines.add(lines[k]); // Store the (potentially modified) line
              } else if (lines[k].startsWith(rtcpFbPrefix)) {
                h264RtcpFbLines.add(lines[k]); // Store the line
              }
            }
            // If no fmtp line found, add a default one with packetization-mode=1
            if (h264FmtpLines.isEmpty && h264PayloadType != null) {
              String newFmtpLine = 'a=fmtp:$h264PayloadType packetization-mode=1;profile-level-id=42e01f;level-asymmetry-allowed=1';
              h264FmtpLines.add(newFmtpLine);
              print("Added default H264 fmtp line: $newFmtpLine");
            }

            break; // Found H264, stop searching rtpmap lines in this section
          }
        }
        break; // Found video m-line, stop searching m-lines
      }
    }

    // If H264 wasn't found or no video line, return original SDP
    if (mLineIndex == -1 || h264PayloadType == null) {
      print("Could not find H264 payload type or video m-line. No SDP modification.");
      return sdp;
    }

    // Reorder payload types in the m=video line
    List<String> mLineParts = lines[mLineIndex].split(' ');
    List<String> payloadTypes = mLineParts.sublist(3); // Format is "m=video port proto fmt ..."
    payloadTypes.remove(h264PayloadType);
    payloadTypes.insert(0, h264PayloadType); // Put H264 first
    lines[mLineIndex] = '${mLineParts.sublist(0, 3).join(' ')} ${payloadTypes.join(' ')}';
    print("Modified m-line: ${lines[mLineIndex]}");


    // Remove original H264 lines from their positions
    List<String> newLines = [];
    List<String> h264LinesToRemove = [...h264RtpmapLines, ...h264FmtpLines, ...h264RtcpFbLines];
    bool inVideoSection = false;
    for(int i=0; i<lines.length; ++i) {
      if (i == mLineIndex) {
        inVideoSection = true;
        newLines.add(lines[i]); // Add the modified m-line
      } else if (lines[i].startsWith('m=')) {
        inVideoSection = false; // Exited video section
        newLines.add(lines[i]);
      } else if (inVideoSection && h264LinesToRemove.contains(lines[i])) {
        // Skip this line, we will re-insert H264 lines later
        print("Removing original H264 line: ${lines[i]}");
      } else {
        newLines.add(lines[i]); // Keep other lines
      }
    }


    // Insert H264 lines right after the m=video line
    int insertIndex = newLines.indexOf(lines[mLineIndex]) + 1;
    List<String> h264LinesToInsert = [...h264RtpmapLines, ...h264FmtpLines, ...h264RtcpFbLines];
    newLines.insertAll(insertIndex, h264LinesToInsert);
    print("Inserted H264 lines after m-line.");


    return newLines.join('\r\n');
  }

  String ensurePacketizationMode(String sdp, String codecMimeType) {
    List<String> lines = sdp.split('\r\n');
    String? h264PayloadType;
    int fmtpLineIndex = -1;
    bool packetizationModePresent = false;
    int rtpmapIndex = -1; // To insert fmtp if missing

    // Find H264 payload type
    for (int i = 0; i < lines.length; i++) {
      if (lines[i].startsWith('a=rtpmap:') && lines[i].toLowerCase().contains(codecMimeType)) {
        var parts = lines[i].substring(9).split(' ');
        h264PayloadType = parts[0];
        rtpmapIndex = i;
        break;
      }
    }

    if (h264PayloadType == null) return sdp; // H264 not found

    // Find existing fmtp line and check/add packetization-mode=1
    String fmtpPrefix = 'a=fmtp:$h264PayloadType';
    for (int i = 0; i < lines.length; i++) {
      if (lines[i].startsWith(fmtpPrefix)) {
        fmtpLineIndex = i;
        if (!lines[i].contains('packetization-mode=1')) {
          lines[i] = '${lines[i]};packetization-mode=1';
          print("Added packetization-mode=1 to existing fmtp line (fallback).");
          return lines.join('\r\n'); // Return modified SDP
        } else {
          packetizationModePresent = true; // Already present
        }
        break;
      }
    }

    // If fmtp line exists and mode is present, or if fmtp line doesn't exist but we couldn't find rtpmap, return original
    if (packetizationModePresent || (fmtpLineIndex == -1 && rtpmapIndex == -1)) {
      return sdp;
    }

    // If fmtp line doesn't exist, add it after rtpmap
    if (fmtpLineIndex == -1 && rtpmapIndex != -1) {
      String newFmtpLine = 'a=fmtp:$h264PayloadType packetization-mode=1;profile-level-id=42e01f;level-asymmetry-allowed=1';
      lines.insert(rtpmapIndex + 1, newFmtpLine);
      print("Added default H264 fmtp line with packetization-mode=1 (fallback).");
      return lines.join('\r\n'); // Return modified SDP
    }

    return sdp; // Should not happen, but return original just in case
  }

  Future<void> _dispose() async {
    print("Disposing resources...");
    // Cancel the stats timer
    _statsTimer?.cancel(); // Use await if cancel returns a Future, otherwise remove await
    _statsTimer = null;
    print("Stats timer cancelled.");

    // Close WebSocket
    await _socket?.sink.close();
    _socket = null;

    // Clean up local renderer
    await _localRenderer.dispose();

    // Clean up remote renderers
    for (var renderer in _remoteRenderers) {
      renderer.srcObject = null;
      await renderer.dispose();
    }
    _remoteRenderers.clear();

    // Clean up local stream tracks
    _localRenderer.srcObject?.getTracks().forEach((track) async {
      try {
        await track.stop();
        print("Stopped track: ${track.id} (${track.kind})");
      } catch (e) {
        print("Error stopping track ${track.id}: $e");
      }
    });
    _localRenderer.srcObject = null;


    // Close peer connection
    if (_peerConnection != null) {
      await _peerConnection?.close();
      _peerConnection = null;
      print("Peer connection closed.");
    } else {
      print("Peer connection was already null.");
    }
    print("Resources disposed.");
  }


  @override
  void dispose() {
    _dispose(); // Call the async dispose method
    super.dispose();
  }

  // ... (Keep build method) ...
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'sfu-ws',
      home: Scaffold(
        appBar: AppBar(
          title: const Text('sfu-ws (H264 Preferred - SDP)'),
        ),
        body: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Local Video', style: _textStyle),
            SizedBox(
              width: 160,
              height: 120,
              child: Stack(
                children: [
                  if (_localRenderer.textureId != null)
                    RTCVideoView(_localRenderer, mirror: true, objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover),
                  Positioned(
                    bottom: 5,
                    left: 5,
                    child: Text(
                      localResolution,
                      style: const TextStyle(color: Colors.white, backgroundColor: Colors.black54),
                    ),
                  ),
                ],
              ),
            ),
            const Text('Remote Video', style: _textStyle),
            Expanded(
              child: Wrap(
                spacing: 8.0,
                runSpacing: 8.0,
                children: [
                  ..._remoteRenderers.map((remoteRenderer) {
                    return (remoteRenderer.textureId != null) ? SizedBox(
                        width: 160,
                        height: 120,
                        child: RTCVideoView(remoteRenderer, objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover))
                        : Container(width: 160, height: 120, color: Colors.black, child: Center(child: CircularProgressIndicator()));
                  }).toList(),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}