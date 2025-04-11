// SPDX-FileCopyrightText: 2023 The Pion community <https://pion.ly>
// SPDX-License-Identifier: MIT

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

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
  late final RTCPeerConnection _peerConnection;

  var configuration = <String, dynamic>{
    'sdpSemantics': 'unified-plan',
    'iceServers': [
        {'urls': 'stun:stun.l.google.com:19302'}
    ]
    // 'codecPreferences': ['H264'],
  };

  _MyAppState();

  @override
  void initState() {
    super.initState();
    connect();
  }

  Future<void> connect() async {
    _peerConnection = await createPeerConnection({}, {});

    await _localRenderer.initialize();
    final localStream = await navigator.mediaDevices
        .getUserMedia(mediaConstraints);
    _localRenderer.srcObject = localStream;

    localStream.getTracks().forEach((track) async {
      await _peerConnection.addTrack(track, localStream);
    });
    _peerConnection.senders.then((senders) {
      senders.forEach((sender) async {
        if (sender.track?.kind == 'video'){
          var parameters = sender.parameters;
          parameters.encodings?[0].maxBitrate = 100 * 1000 * 1000; // 100 Mbps
          parameters.encodings?[0].minBitrate = 1 * 1000 * 1000;   // 1 Mbps

          print("New max bitrate is: ${parameters.encodings?[0].maxBitrate}");
          parameters.degradationPreference = degradationPreferenceforString('disabled');
          sender.setParameters(parameters);
        }
      });
    });

    Timer.periodic(const Duration(seconds: 1), (timer) async {
      // Update local resolution
      setState(() {
        localResolution = '${_localRenderer.videoWidth} x ${_localRenderer.videoHeight}';
      });
      // if (counter == 10) {
      //   print("Switching to 640x480");
      // _localRenderer.srcObject = await navigator.mediaDevices.getUserMedia(mediaConstraints1);
      //   counter = 0;
      // }
      print("Resolution:$localResolution");
        // Fetch stats for the local video track
  final senders = await _peerConnection.senders;
  for (var sender in senders) {
    if (sender.track?.kind == 'video') {
      var stats = await sender.getStats();
      stats.forEach((key) {
        var mime = key.values["mimeType"];
        if (key.id == "COT01_96"){
          print("MIME: $mime");
        }
        if (key.id == "SV1") {
          var height = key.values["height"];
          var width = key.values["width"];
          var framesPerSecond = key.values["framesPerSecond"];
          print("H: $height, W:$width, FPS: $framesPerSecond");
        }
      });
    }
  }
    });


    _peerConnection.onIceCandidate = (candidate) {
      _socket?.sink.add(jsonEncode({
        "event": "candidate",
        "data": jsonEncode({
          'sdpMLineIndex': candidate.sdpMLineIndex,
          'sdpMid': candidate.sdpMid,
          'candidate': candidate.candidate,
        })
      }));
    };

    _peerConnection.onTrack = (event) async {
      if (event.track.kind == 'video' && event.streams.isNotEmpty) {
        var renderer = RTCVideoRenderer();
        await renderer.initialize();
        renderer.srcObject = event.streams[0];

        setState(() {
          _remoteRenderers.add(renderer);
        });
      }
    };

    _peerConnection.onRemoveStream = (stream) {
      RTCVideoRenderer? rendererToRemove;
      final newRenderList = <RTCVideoRenderer>[];

      // Filter existing renderers for the stream that has been stopped
      for (final r in _remoteRenderers) {
        if (r.srcObject?.id == stream.id) {
          rendererToRemove = r;
        } else {
          newRenderList.add(r);
        }
      }

      // Set the new renderer list
      setState(() {
        _remoteRenderers = newRenderList;
      });

      // Dispose the renderer we are done with
      if (rendererToRemove != null) {
        rendererToRemove.dispose();
      }
    };

    final socket =
        WebSocketChannel.connect(Uri.parse('ws://$remoteHost:8080/websocket'));
    _socket = socket;
    socket.stream.listen((raw) async {
      Map<String, dynamic> msg = jsonDecode(raw);

      switch (msg['event']) {
        case 'candidate':
          final parsed = jsonDecode(msg['data']);
          _peerConnection
              .addCandidate(RTCIceCandidate(parsed['candidate'], '', 0));
          return;
        case 'offer':
          final offer = jsonDecode(msg['data']);
          // SetRemoteDescription and create answer
          await _peerConnection.setRemoteDescription(
              RTCSessionDescription(offer['sdp'], offer['type']));
          RTCSessionDescription answer = await _peerConnection.createAnswer({});
          await _peerConnection.setLocalDescription(answer);

          // Send answer over WebSocket
          _socket?.sink.add(jsonEncode({
            'event': 'answer',
            'data': jsonEncode({'type': answer.type, 'sdp': answer.sdp}),
          }));
          return;
      }
    }, onDone: () {
      print('Closed by server!');
    });
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'sfu-ws',
      home: Scaffold(
        appBar: AppBar(
          title: const Text('sfu-ws'),
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
                  RTCVideoView(_localRenderer, mirror: true),
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
            Row(
              children: [
                ..._remoteRenderers.map((remoteRenderer) {
                  return SizedBox(
                      width: 160,
                      height: 120,
                      child: RTCVideoView(remoteRenderer));
                }).toList(),
              ],
            ),
            const Text('Logs Video', style: _textStyle),
          ],
        ),
      ),
    );
  }
}
