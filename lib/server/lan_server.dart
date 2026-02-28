import 'dart:io';

import 'package:flutter/foundation.dart';

import '../constants.dart';
import '../utils/network_utils.dart';
import '../web/dashboard_html.dart';

/// Callback signatures used by [LanServer] to notify the rest of the app.
typedef OnCaptureRequested = void Function();
typedef OnOcrRequested = void Function();

/// Manages the [HttpServer], MJPEG/SSE clients, and all WebSocket channels.
///
/// The server owns the network layer only.  Camera and OCR logic live in the
/// page state; they communicate with the server through the [broadcastX]
/// methods and the [onCaptureRequested] / [onOcrRequested] callbacks.
class LanServer {
  LanServer({
    required this.onCaptureRequested,
    required this.onOcrRequested,
  });

  final OnCaptureRequested onCaptureRequested;
  final OnOcrRequested onOcrRequested;

  HttpServer? _http;

  final List<WebSocket> _videoClients = [];
  final List<WebSocket> _photoClients = [];
  final List<WebSocket> _textClients = [];
  final List<HttpResponse> _mjpegClients = [];
  final List<HttpResponse> _sseClients = [];

  // Cached last OCR result – sent immediately to new /ws/text connections.
  String _latestOcrText = '';
  // Cached last photo – sent immediately to new /ws/photo connections.
  Uint8List? _latestPhoto;

  // ── Lifecycle ────────────────────────────────────────────────────────────

  /// Binds and starts listening on [AppConstants.serverPort].
  Future<void> start() async {
    _http = await HttpServer.bind(
      InternetAddress.anyIPv4,
      AppConstants.serverPort,
    );
    _http!.listen(_route);
  }

  /// Closes all connections and disposes the server.
  Future<void> dispose() async {
    for (final ws in [
      ..._videoClients,
      ..._photoClients,
      ..._textClients,
    ]) {
      try {
        ws.close();
      } catch (_) {}
    }
    _videoClients.clear();
    _photoClients.clear();
    _textClients.clear();

    for (final r in [..._mjpegClients, ..._sseClients]) {
      try {
        r.close();
      } catch (_) {}
    }
    _mjpegClients.clear();
    _sseClients.clear();

    await _http?.close(force: true);
    _http = null;
  }

  // ── Client counts (for UI badges) ────────────────────────────────────────

  int get videoClientCount => _videoClients.length + _mjpegClients.length;
  int get textClientCount => _textClients.length + _sseClients.length;

  // ── Broadcast API (called by the page state) ─────────────────────────────

  void broadcastVideoFrame(Uint8List jpeg) {
    _broadcastWs(_videoClients, jpeg);
    if (_mjpegClients.isNotEmpty) _broadcastMjpeg(jpeg);
  }

  void broadcastPhoto(Uint8List jpeg) {
    _latestPhoto = jpeg;
    _broadcastWs(_photoClients, jpeg);
  }

  void broadcastOcrText(String text) {
    _latestOcrText = text;
    _broadcastWsText(text);
    _broadcastSse(text);
  }

  // ── Request routing ──────────────────────────────────────────────────────

  Future<void> _route(HttpRequest req) async {
    req.response.headers.set('Access-Control-Allow-Origin', '*');
    final path = req.uri.path;
    final method = req.method.toUpperCase();

    // WebSocket upgrades
    if (WebSocketTransformer.isUpgradeRequest(req)) {
      switch (path) {
        case '/ws/video':
          await _upgradeWs(req, _videoClients);
          return;
        case '/ws/photo':
          await _upgradeWsPhoto(req);
          return;
        case '/ws/text':
          await _upgradeWsText(req);
          return;
      }
    }

    // Command endpoints
    if (method == 'POST') {
      switch (path) {
        case '/cmd/capture':
          onCaptureRequested();
          _respondOk(req);
          return;
        case '/cmd/ocr':
          onOcrRequested();
          _respondOk(req);
          return;
      }
    }

    // Static / streaming pages
    switch (path) {
      case '/':
        _serveHtml(req);
      case '/video':
        _serveMjpeg(req);
      case '/text':
        _serveSse(req);
      default:
        req.response
          ..statusCode = HttpStatus.notFound
          ..write('404')
          ..close();
    }
  }

  // ── WebSocket upgrade helpers ────────────────────────────────────────────

  Future<void> _upgradeWs(HttpRequest req, List<WebSocket> clients) async {
    try {
      final ws = await WebSocketTransformer.upgrade(req);
      clients.add(ws);
      ws.listen(
        null,
        onError: (_) => clients.remove(ws),
        onDone: () => clients.remove(ws),
        cancelOnError: true,
      );
    } catch (e) {
      debugPrint('WS upgrade error: $e');
    }
  }

  Future<void> _upgradeWsPhoto(HttpRequest req) async {
    try {
      final ws = await WebSocketTransformer.upgrade(req);
      _photoClients.add(ws);
      ws.listen(
        null,
        onError: (_) => _photoClients.remove(ws),
        onDone: () => _photoClients.remove(ws),
        cancelOnError: true,
      );
      // Immediately push the last captured photo if available.
      if (_latestPhoto != null) {
        try {
          ws.add(_latestPhoto!);
        } catch (_) {}
      }
    } catch (e) {
      debugPrint('WS photo upgrade error: $e');
    }
  }

  Future<void> _upgradeWsText(HttpRequest req) async {
    try {
      final ws = await WebSocketTransformer.upgrade(req);
      _textClients.add(ws);
      ws.listen(
        null,
        onError: (_) => _textClients.remove(ws),
        onDone: () => _textClients.remove(ws),
        cancelOnError: true,
      );
      // Immediately push the last OCR result.
      if (_latestOcrText.isNotEmpty) {
        try {
          ws.add(_latestOcrText);
        } catch (_) {}
      }
    } catch (e) {
      debugPrint('WS text upgrade error: $e');
    }
  }

  // ── Page / stream helpers ────────────────────────────────────────────────

  void _serveHtml(HttpRequest req) {
    req.response
      ..statusCode = HttpStatus.ok
      ..headers.contentType = ContentType.html
      ..headers.set('Cache-Control', 'no-cache')
      ..write(dashboardHtml)
      ..close();
  }

  void _serveMjpeg(HttpRequest req) {
    final res = req.response;
    res.statusCode = HttpStatus.ok;
    res.headers
      ..set(
        'Content-Type',
        'multipart/x-mixed-replace; boundary=${AppConstants.mjpegBoundary}',
      )
      ..set('Cache-Control', 'no-cache')
      ..set('Connection', 'keep-alive')
      ..set('Pragma', 'no-cache');
    _mjpegClients.add(res);
    res.done.whenComplete(() => _mjpegClients.remove(res));
  }

  void _serveSse(HttpRequest req) {
    final res = req.response;
    res.statusCode = HttpStatus.ok;
    res.headers
      ..set('Content-Type', 'text/event-stream; charset=utf-8')
      ..set('Cache-Control', 'no-cache')
      ..set('Connection', 'keep-alive')
      ..set('X-Accel-Buffering', 'no');
    res.write('retry: 1000\n\n');
    if (_latestOcrText.isNotEmpty) {
      res.write('data: ${sseEscape(_latestOcrText)}\n\n');
    }
    _sseClients.add(res);
    res.done.whenComplete(() => _sseClients.remove(res));
  }

  void _respondOk(HttpRequest req) {
    req.response
      ..statusCode = HttpStatus.ok
      ..headers.contentType = ContentType.json
      ..write('{"status":"ok"}')
      ..close();
  }

  // ── Broadcast helpers ────────────────────────────────────────────────────

  void _broadcastWs(List<WebSocket> clients, Uint8List bytes) {
    if (clients.isEmpty) return;
    final dead = <WebSocket>[];
    for (final ws in List<WebSocket>.from(clients)) {
      try {
        ws.add(bytes);
      } catch (_) {
        dead.add(ws);
      }
    }
    dead.forEach(clients.remove);
  }

  void _broadcastWsText(String text) {
    if (_textClients.isEmpty) return;
    final dead = <WebSocket>[];
    for (final ws in List<WebSocket>.from(_textClients)) {
      try {
        ws.add(text);
      } catch (_) {
        dead.add(ws);
      }
    }
    dead.forEach(_textClients.remove);
  }

  void _broadcastMjpeg(Uint8List bytes) {
    if (_mjpegClients.isEmpty) return;

    // Build a single contiguous buffer: boundary header + JPEG payload + CRLF.
    // One socket write is significantly cheaper than three, and avoids partial
    // frame delivery which would corrupt the MJPEG stream.
    final headerStr = '--${AppConstants.mjpegBoundary}\r\n'
        'Content-Type: image/jpeg\r\n'
        'Content-Length: ${bytes.length}\r\n'
        '\r\n';
    final headerBytes = Uint8List.fromList(headerStr.codeUnits);
    const trailer = [0x0D, 0x0A]; // \r\n
    final frame = Uint8List(headerBytes.length + bytes.length + 2)
      ..setAll(0, headerBytes)
      ..setAll(headerBytes.length, bytes)
      ..setAll(headerBytes.length + bytes.length, trailer);

    final dead = <HttpResponse>[];
    for (final c in List<HttpResponse>.from(_mjpegClients)) {
      try {
        c.add(frame);
        // Fire-and-forget flush — pushes the frame out of Dart's IOSink
        // buffer into the OS network stack without blocking the event loop.
        c.flush().ignore();
      } catch (_) {
        dead.add(c);
      }
    }
    dead.forEach(_mjpegClients.remove);
  }

  void _broadcastSse(String text) {
    if (_sseClients.isEmpty) return;
    final payload = 'data: ${sseEscape(text)}\n\n';
    final dead = <HttpResponse>[];
    for (final c in List<HttpResponse>.from(_sseClients)) {
      try {
        c.write(payload);
      } catch (_) {
        dead.add(c);
      }
    }
    dead.forEach(_sseClients.remove);
  }
}

/// Convenience wrapper that also resolves the local IP address.
Future<({LanServer server, String ip})> startLanServer({
  required OnCaptureRequested onCaptureRequested,
  required OnOcrRequested onOcrRequested,
}) async {
  final server = LanServer(
    onCaptureRequested: onCaptureRequested,
    onOcrRequested: onOcrRequested,
  );
  final results = await Future.wait([
    server.start(),
    detectLocalIp(),
  ]);
  final ip = (results[1] as String?) ?? 'Unavailable';
  return (server: server, ip: ip);
}
