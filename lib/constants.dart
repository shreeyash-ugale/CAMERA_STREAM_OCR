/// Application-wide constants.
class AppConstants {
  AppConstants._();

  static const int serverPort = 8080;

  // ── Video stream ─────────────────────────────────────────────────────────
  /// JPEG quality for streamed preview frames (lower = faster, smaller).
  static const int streamJpegQuality = 50;

  /// Max width (px) to which stream frames are downscaled before encoding.
  /// The aspect ratio is preserved.  Full-res photos are unaffected.
  static const int streamTargetWidth = 640;

  /// Minimum milliseconds between two encoded stream frames (~10 fps cap).
  static const int streamFrameIntervalMs = 100;

  static const String mjpegBoundary = 'mjpegframe';
}
