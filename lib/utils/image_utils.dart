// ignore_for_file: avoid_print

import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:image/image.dart' as img;

import '../constants.dart';
import '../models/encode_params.dart';
import '../models/nv21_result.dart';

// ---------------------------------------------------------------------------
// Public isolate-safe helpers (top-level so `compute()` can use them)
// ---------------------------------------------------------------------------

/// Converts a raw [CameraImage] (YUV / NV21 / BGRA) to a JPEG byte array,
/// applying a rotation correction so the image is always upright in portrait.
///
/// When [EncodeParams.targetWidth] is set the frame is downscaled to that
/// width (aspect-ratio preserved) before encoding – dramatically reducing
/// encoding time for stream preview frames.
///
/// Returns `null` when encoding fails.
Uint8List? encodeRawToJpeg(EncodeParams params) {
  try {
    final image = params.image;
    img.Image? frame = _decodeFrame(image);
    if (frame == null) return null;

    frame = _applyRotation(frame, params.sensorOrientation, params.isFrontCamera);

    // Downscale if a target width is requested (stream preview path).
    final targetWidth = params.targetWidth;
    if (targetWidth != null && frame.width > targetWidth) {
      final targetHeight = (frame.height * targetWidth / frame.width).round();
      frame = img.copyResize(
        frame,
        width: targetWidth,
        height: targetHeight,
        interpolation: img.Interpolation.average,
      );
    }

    return Uint8List.fromList(
      img.encodeJpg(frame, quality: AppConstants.streamJpegQuality),
    );
  } catch (e) {
    print('encodeRawToJpeg error: $e');
    return null;
  }
}

/// Decodes a JPEG [Uint8List] into NV21 bytes for ML Kit OCR.
/// Respects embedded EXIF orientation via [img.bakeOrientation].
///
/// Returns `null` when decoding fails.
Nv21Result? decodeJpegToNv21(Uint8List jpegBytes) {
  try {
    if (!_isJpeg(jpegBytes)) {
      print('decodeJpegToNv21: not a JPEG buffer');
      return null;
    }
    final decoded = img.decodeJpg(jpegBytes);
    if (decoded == null) return null;

    final baked = img.bakeOrientation(decoded);
    return _imageToNv21(baked);
  } catch (e) {
    print('decodeJpegToNv21 error: $e');
    return null;
  }
}

// ---------------------------------------------------------------------------
// Private helpers
// ---------------------------------------------------------------------------

bool _isJpeg(Uint8List bytes) =>
    bytes.length >= 2 && bytes[0] == 0xFF && bytes[1] == 0xD8;

/// Attempts to decode the raw camera frame into an [img.Image].
img.Image? _decodeFrame(CameraImage image) {
  if (image.planes.isEmpty) return null;

  // ── Single-plane path (may already be JPEG on iOS) ─────────────────────
  if (image.planes.length == 1) {
    final bytes = image.planes[0].bytes;
    if (_isJpeg(bytes)) {
      return img.decodeJpg(bytes);
    }
    return _nv21PlaneToImage(bytes, image.width, image.height);
  }

  // ── Multi-plane YUV path (Android NV21 / YUV_420_888) ─────────────────
  return _yuvPlanesToImage(image);
}

img.Image _nv21PlaneToImage(Uint8List bytes, int w, int h) {
  final out = img.Image(width: w, height: h);
  final uvOffset = w * h;

  for (int row = 0; row < h; row++) {
    for (int col = 0; col < w; col++) {
      final y = bytes[row * w + col].toDouble();
      final uvIdx = uvOffset + (row ~/ 2) * w + (col & ~1);
      final vf = bytes[uvIdx].toDouble() - 128.0;
      final uf = bytes[uvIdx + 1].toDouble() - 128.0;
      out.setPixelRgba(
        col, row,
        (y + vf * 1.402).clamp(0.0, 255.0).toInt(),
        (y - uf * 0.34414 - vf * 0.71414).clamp(0.0, 255.0).toInt(),
        (y + uf * 1.772).clamp(0.0, 255.0).toInt(),
        255,
      );
    }
  }
  return out;
}

img.Image _yuvPlanesToImage(CameraImage image) {
  final w = image.width;
  final h = image.height;
  final out = img.Image(width: w, height: h);

  final yPlane = image.planes[0];
  final uvPlane = image.planes.length > 1 ? image.planes[1] : null;
  final uvPixelStride = uvPlane?.bytesPerPixel ?? 2;

  for (int row = 0; row < h; row++) {
    final yRowStart = row * yPlane.bytesPerRow;
    final uvRowStart = uvPlane != null ? (row ~/ 2) * uvPlane.bytesPerRow : 0;

    for (int col = 0; col < w; col++) {
      final yIdx = yRowStart + col;
      if (yIdx >= yPlane.bytes.length) continue;

      final y = yPlane.bytes[yIdx].toDouble();
      double vf = 0, uf = 0;

      if (uvPlane != null) {
        final uvIdx = uvRowStart + (col ~/ 2) * uvPixelStride;
        if (uvIdx + 1 < uvPlane.bytes.length) {
          vf = uvPlane.bytes[uvIdx].toDouble() - 128.0;
          uf = uvPlane.bytes[uvIdx + 1].toDouble() - 128.0;
        }
      }

      out.setPixelRgba(
        col, row,
        (y + vf * 1.402).clamp(0.0, 255.0).toInt(),
        (y - uf * 0.34414 - vf * 0.71414).clamp(0.0, 255.0).toInt(),
        (y + uf * 1.772).clamp(0.0, 255.0).toInt(),
        255,
      );
    }
  }
  return out;
}

/// Rotates [frame] so the image is portrait-upright, matching what the user
/// sees through the viewfinder.
///
/// Android back cameras have [sensorOrientation] = 90, meaning the sensor data
/// is in landscape; rotating +90° makes it portrait.
img.Image _applyRotation(
  img.Image frame,
  int sensorOrientation,
  bool isFrontCamera,
) {
  if (sensorOrientation == 0) return frame;

  img.Image rotated;
  switch (sensorOrientation) {
    case 90:
      rotated = img.copyRotate(frame, angle: 90);
    case 180:
      rotated = img.copyRotate(frame, angle: 180);
    case 270:
      rotated = img.copyRotate(frame, angle: 270);
    default:
      rotated = frame;
  }

  // Front cameras are mirrored; flip horizontally to un-mirror.
  if (isFrontCamera) {
    return img.flipHorizontal(rotated);
  }
  return rotated;
}

/// Converts a decoded [img.Image] to the NV21 (YCbCr 4:2:0) layout that
/// ML Kit's text recognizer expects.
Nv21Result _imageToNv21(img.Image image) {
  final w = image.width;
  final h = image.height;
  final out = Uint8List(w * h * 3 ~/ 2);

  int yIdx = 0;
  int uvIdx = w * h;

  for (int row = 0; row < h; row++) {
    for (int col = 0; col < w; col++) {
      final pixel = image.getPixel(col, row);
      final r = pixel.r.toInt();
      final g = pixel.g.toInt();
      final b = pixel.b.toInt();

      out[yIdx++] =
          (((66 * r + 129 * g + 25 * b + 128) >> 8) + 16).clamp(0, 255);

      if (row.isEven && col.isEven) {
        out[uvIdx++] =
            (((112 * r - 94 * g - 18 * b + 128) >> 8) + 128).clamp(0, 255);
        out[uvIdx++] =
            (((-38 * r - 74 * g + 112 * b + 128) >> 8) + 128).clamp(0, 255);
      }
    }
  }
  return Nv21Result(out, w, h);
}
