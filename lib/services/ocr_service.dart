import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';

import '../models/nv21_result.dart';
import '../utils/image_utils.dart';

/// Thin wrapper around [TextRecognizer].
/// Decodes a JPEG in an isolate then runs ML Kit recognition.
class OcrService {
  OcrService() : _recognizer = TextRecognizer();

  final TextRecognizer _recognizer;

  /// Runs OCR on [jpegBytes].  Returns the extracted text or an empty string.
  Future<String> recognizeFromJpeg(Uint8List jpegBytes) async {
    final Nv21Result? decoded = await compute(decodeJpegToNv21, jpegBytes);
    if (decoded == null) {
      debugPrint('OcrService: JPEG decode returned null');
      return '';
    }

    final metadata = InputImageMetadata(
      size: Size(decoded.width.toDouble(), decoded.height.toDouble()),
      rotation: InputImageRotation.rotation0deg,
      format: InputImageFormat.nv21,
      bytesPerRow: decoded.width,
    );
    final inputImage = InputImage.fromBytes(
      bytes: decoded.nv21,
      metadata: metadata,
    );
    final result = await _recognizer.processImage(inputImage);
    return result.text;
  }

  /// Releases ML Kit resources.
  void dispose() => _recognizer.close();
}
