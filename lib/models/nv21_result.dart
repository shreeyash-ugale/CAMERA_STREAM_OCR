import 'dart:typed_data';

/// Holds the NV21-encoded bytes and dimensions of a decoded JPEG.
/// Used when converting a captured photo for ML Kit OCR.
class Nv21Result {
  const Nv21Result(this.nv21, this.width, this.height);

  final Uint8List nv21;
  final int width;
  final int height;
}
