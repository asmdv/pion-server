import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

// ... (Keep existing code: main, remoteHost, counter, mediaConstraints, etc.) ...
void main() => runApp(const MyApp());
String remoteHost = "192.168.1.185";
// String remoteHost = "10.33.92.6";
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
      'minWidth': '640',
      'minHeight': '480',
      'maxWidth': '3840',
      'maxHeight': '2160',
      'minFrameRate': '30',
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

    await _localRenderer.initialize();
    final localStream = await navigator.mediaDevices
        .getUserMedia(mediaConstraints);
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
              parameters.degradationPreference = RTCDegradationPreference.MAINTAIN_RESOLUTION;
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


    // --- Timer for Stats and Codec Printing ---
    _statsTimer = Timer.periodic(const Duration(seconds: 1), (timer) async { // Store timer instance
      if (mounted) {
        setState(() {
          localResolution = '${_localRenderer.videoWidth} x ${_localRenderer.videoHeight}';
        });
      }
      try {
        if (_peerConnection == null) return;
        final pc = _peerConnection!;
        final senders = await pc.senders;
        String? currentCodec; // Variable to hold the codec for this second interval

        for (var sender in senders) {
          if (sender.track?.kind == 'video') {
            var stats = await sender.getStats();

            stats.forEach((report) {
              var reportId = report.id;
              if (report.type == 'outbound-rtp' && report.values['mediaType'] == 'video') {
                var mime = report.values["mimeType"];
                // *** Store the codec found in this report ***
                if (mime != null) {
                  currentCodec = mime;
                }
                // Optional: Keep detailed stats print for debugging
                print("Stats (ID: $reportId) - MimeType: $mime, CodecId: ${report.values['codecId']}, FrameWidth: ${report.values['frameWidth']}, FrameHeight: ${report.values['frameHeight']}, FramesPerSecond: ${report.values['framesPerSecond']}, QualityLimitationReason: ${report.values['qualityLimitationReason']}");
              }
            });
            // If we found a codec for this sender, break (assuming one main video sender)
            if (currentCodec != null) break;
          }
        }
        // *** Print the codec found in this interval (or N/A if none found) ***
        print('Current sending codec: ${currentCodec ?? 'N/A'}');

      } catch (e) {
        print("Error getting stats: $e");
      }
    });
    // --- End Timer ---


    // ... (onIceCandidate, onTrack, onRemoveStream, state handlers remain the same) ...
    pc.onIceCandidate = (candidate) {
      if (candidate != null) {
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
    WebSocketChannel.connect(Uri.parse('ws://$remoteHost:8080/websocket'));
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

  // --- Updated _dispose method ---
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
  // --- End Updated _dispose method ---


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

// ... (Keep commented out helper function if needed) ...
