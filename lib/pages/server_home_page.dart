import 'dart:async';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../constants.dart';
import '../models/encode_params.dart';
import '../server/lan_server.dart';
import '../services/ocr_service.dart';
import '../utils/image_utils.dart';
import '../widgets/info_card.dart';
import '../widgets/status_badge.dart';

class ServerHomePage extends StatefulWidget {
  const ServerHomePage({super.key, required this.cameras});

  final List<CameraDescription> cameras;

  @override
  State<ServerHomePage> createState() => _ServerHomePageState();
}

class _ServerHomePageState extends State<ServerHomePage> {
  // ── Camera ───────────────────────────────────────────────────────────────
  late CameraController _camera;
  bool _cameraReady = false;
  bool _streaming = false;
  bool _isCapturing = false;
  bool _isOcring = false;

  // ── Server ───────────────────────────────────────────────────────────────
  LanServer? _server;
  bool _serverStarted = false;
  String _localIp = 'Detecting…';

  // ── OCR ──────────────────────────────────────────────────────────────────
  final OcrService _ocr = OcrService();
  Uint8List? _capturedPhoto;
  String _latestText = '';

  // ── FPS counter ──────────────────────────────────────────────────────────
  int _streamFps = 0;
  int _frameCount = 0;
  Timer? _fpsTimer;

  // ── Stream throttle ───────────────────────────────────────────────────────
  /// Wall-clock time of the last frame that was actually encoded & broadcast.
  /// Frames arriving sooner than [AppConstants.streamFrameIntervalMs] are
  /// dropped so the encoding isolate is not overloaded.
  int _lastFrameMs = 0;

  /// Guards against spawning a new encode isolate while the previous one is
  /// still running.  Without this, slow encoding floods the isolate pool and
  /// stalls the Dart event loop, causing the perceived FPS to drop as soon as
  /// a client connects.
  bool _isEncoding = false;

  // ── Sensor info (needed for rotation correction) ─────────────────────────
  int _sensorOrientation = 90;
  bool _isFrontCamera = false;

  // ── Init ─────────────────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    _fpsTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() { _streamFps = _frameCount; _frameCount = 0; });
    });
    _initAll();
  }

  Future<void> _initAll() async {
    await Future.wait([_initCamera(), _initServer()]);
  }

  Future<void> _initCamera() async {
    final desc = widget.cameras.first;
    _sensorOrientation = desc.sensorOrientation;
    _isFrontCamera = desc.lensDirection == CameraLensDirection.front;

    _camera = CameraController(
      desc,
      ResolutionPreset.max,
      imageFormatGroup: Platform.isAndroid
          ? ImageFormatGroup.nv21
          : ImageFormatGroup.bgra8888,
      enableAudio: false,
    );

    try {
      await _camera.initialize();
      await _camera.lockCaptureOrientation(DeviceOrientation.landscapeRight);
      await _camera.setFocusMode(FocusMode.auto);
      await _camera.setExposureMode(ExposureMode.auto);
    } catch (e) {
      debugPrint('Camera init error: $e');
    }

    if (!mounted) return;
    setState(() => _cameraReady = true);
    _startImageStream();
  }

  Future<void> _initServer() async {
    try {
      final result = await startLanServer(
        onCaptureRequested: _capturePhoto,
        onOcrRequested: _runOcr,
      );
      _server = result.server;
      if (mounted) {
        setState(() {
          _serverStarted = true;
          _localIp = result.ip;
        });
      }
    } catch (e) {
      debugPrint('Server start error: $e');
    }
  }

  // ── Camera stream ────────────────────────────────────────────────────────

  void _startImageStream() {
    if (_streaming || !_cameraReady) return;
    _streaming = true;
    _camera.startImageStream(_onCameraFrame);
  }

  void _onCameraFrame(CameraImage image) {
    if (image.planes.isEmpty) return;
    _frameCount++;

    // ── Throttle: drop frames that arrive faster than the stream cap ────────
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    if (nowMs - _lastFrameMs < AppConstants.streamFrameIntervalMs) return;
    _lastFrameMs = nowMs;

    if (_server == null || _server!.videoClientCount == 0) return;

    // Fast path: some iOS cameras hand us a JPEG directly.
    final plane0 = image.planes[0].bytes;
    if (plane0.length >= 2 && plane0[0] == 0xFF && plane0[1] == 0xD8) {
      // iOS JPEGs are already compressed; just broadcast them as-is.
      // No resize needed here — they are typically already a reasonable size.
      _server?.broadcastVideoFrame(plane0);
      return;
    }

    // Raw path: encode & downscale in an isolate so the UI thread is free.
    unawaited(_encodeAndBroadcast(image));
  }

  Future<void> _encodeAndBroadcast(CameraImage image) async {
    if (_isEncoding) return; // drop frame — previous encode still running
    _isEncoding = true;
    try {
      final params = EncodeParams(
        image: image,
        sensorOrientation: _sensorOrientation,
        isFrontCamera: _isFrontCamera,
        targetWidth: AppConstants.streamTargetWidth, // downscale for stream
      );
      final jpeg = await compute(encodeRawToJpegFast, params);
      if (jpeg != null) _server?.broadcastVideoFrame(jpeg);
    } catch (e) {
      debugPrint('Frame encode error: $e');
    } finally {
      _isEncoding = false;
    }
  }

  // ── Photo capture ────────────────────────────────────────────────────────

  Future<void> _capturePhoto() async {
    if (!_cameraReady || _isCapturing) return;
    if (mounted) setState(() => _isCapturing = true);

    try {
      final wasStreaming = _camera.value.isStreamingImages;
      if (wasStreaming) {
        await _camera.stopImageStream();
        _streaming = false;
      }

      final xFile = await _camera.takePicture();
      final raw = await xFile.readAsBytes();
      final bytes = await compute(rotateJpeg180, raw);

      if (mounted) setState(() => _capturedPhoto = bytes);
      _server?.broadcastPhoto(bytes);

      if (wasStreaming && mounted) {
        await _camera.startImageStream(_onCameraFrame);
        _streaming = true;
      }
    } catch (e) {
      debugPrint('Capture error: $e');
    } finally {
      if (mounted) setState(() => _isCapturing = false);
    }
  }

  // ── OCR ──────────────────────────────────────────────────────────────────

  Future<void> _runOcr() async {
    if (_capturedPhoto == null || _isOcring) return;
    if (mounted) setState(() => _isOcring = true);

    try {
      final text = await _ocr.recognizeFromJpeg(_capturedPhoto!);
      final result = text.isEmpty ? '(No text detected)' : text;
      if (mounted) setState(() => _latestText = result);
      _server?.broadcastOcrText(result);
    } catch (e) {
      debugPrint('OCR error: $e');
    } finally {
      if (mounted) setState(() => _isOcring = false);
    }
  }

  // ── Lifecycle ────────────────────────────────────────────────────────────

  @override
  void dispose() {
    _fpsTimer?.cancel();
    _streaming = false;
    if (_camera.value.isStreamingImages) {
      _camera.stopImageStream().ignore();
    }
    _server?.dispose();
    _camera.dispose();
    _ocr.dispose();
    super.dispose();
  }

  // ── UI ───────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final hasPhoto = _capturedPhoto != null;
    final videoCount = _server?.videoClientCount ?? 0;
    final textCount = _server?.textClientCount ?? 0;

    return Scaffold(
      appBar: AppBar(
        title: const Text('LAN Video & OCR Server'),
        actions: [
          if (_serverStarted)
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: Chip(
                avatar: const Icon(Icons.wifi, size: 16, color: Color(0xFF3FB950)),
                label: Text(
                  'Port ${AppConstants.serverPort}  •  $_streamFps fps',
                  style: const TextStyle(fontSize: 12),
                ),
                backgroundColor: const Color(0xFF1A3A22),
                side: BorderSide.none,
              ),
            ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // ── Server URL ───────────────────────────────────────────────
            InfoCard(
              icon: Icons.link_rounded,
              title: 'Web Dashboard',
              value: 'http://$_localIp:${AppConstants.serverPort}',
              subtitle: 'Open this URL in any browser on the same Wi-Fi',
              accent: const Color(0xFF58A6FF),
            ),
            const SizedBox(height: 16),

            // ── Camera preview ───────────────────────────────────────────
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: Container(
                color: Colors.black,
                height: 280,
                child: _cameraReady
                    ? CameraPreview(_camera)
                    : const Center(
                        child: CircularProgressIndicator(
                          color: Color(0xFF58A6FF),
                        ),
                      ),
              ),
            ),
            const SizedBox(height: 12),

            // ── Action buttons ───────────────────────────────────────────
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed:
                        (_cameraReady && !_isCapturing && !_isOcring)
                            ? _capturePhoto
                            : null,
                    icon: _isCapturing
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : const Icon(Icons.camera_alt_rounded),
                    label:
                        Text(_isCapturing ? 'Capturing…' : 'Capture Photo'),
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFF238636),
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: FilledButton.icon(
                    onPressed:
                        (hasPhoto && !_isOcring && !_isCapturing)
                            ? _runOcr
                            : null,
                    icon: _isOcring
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : const Icon(Icons.search_rounded),
                    label: Text(_isOcring ? 'Running OCR…' : 'Run OCR'),
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFF1F6FEB),
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),

            // ── Captured photo preview ───────────────────────────────────
            if (hasPhoto) ...[
              ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Container(
                  color: Colors.black,
                  constraints: const BoxConstraints(maxHeight: 300),
                  child: Image.memory(_capturedPhoto!, fit: BoxFit.contain),
                ),
              ),
              const SizedBox(height: 16),
            ],

            // ── Status badges ────────────────────────────────────────────
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                StatusBadge(label: 'Camera',         active: _cameraReady),
                StatusBadge(label: 'Server',          active: _serverStarted),
                StatusBadge(label: 'Streaming',       active: _streaming),
                StatusBadge(label: 'Photo Captured',  active: hasPhoto),
                StatusBadge(label: '$videoCount video', active: videoCount > 0),
                StatusBadge(label: '$textCount text',   active: textCount > 0),
              ],
            ),
            const SizedBox(height: 16),

            // ── OCR output ───────────────────────────────────────────────
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: const Color(0xFF161B22),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: const Color(0xFF30363D)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'OCR OUTPUT',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: Color(0xFF8B949E),
                      letterSpacing: 1,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    _latestText.isEmpty
                        ? 'Press "Run OCR" after capturing a photo…'
                        : _latestText,
                    style: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 13,
                      height: 1.6,
                      color: _latestText.isEmpty
                          ? const Color(0xFF8B949E)
                          : const Color(0xFFE6EDF3),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
