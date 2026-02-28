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

/// **Fast** frame encoder: samples only [EncodeParams.targetWidth] × computed
/// height pixels directly from the raw YUV / BGRA buffer **without** decoding
/// the entire source frame first.  For a 4 K source → 640 px output this
/// processes ~97 % fewer pixels than [encodeRawToJpeg], giving a ~20-50 ×
/// speed-up and enabling 25-30 fps streams on mid-range Android hardware.
///
/// Rotation correction ([_applyRotation]) is still applied after sampling.
/// Falls back to [encodeRawToJpeg] for any unrecognised format.
Uint8List? encodeRawToJpegFast(EncodeParams params) {
  try {
    final cam = params.image;
    final srcW = cam.width;
    final srcH = cam.height;
    final targetW = params.targetWidth ?? AppConstants.streamTargetWidth;
    final targetH = (srcH * targetW / srcW).round().clamp(1, srcH);

    img.Image? frame;

    // ── Multi-plane NV21 / YUV_420_888 (Android) ──────────────────────────
    if (cam.planes.length >= 2) {
      frame = _yuvSampleFast(cam, srcW, srcH, targetW, targetH);
    }
    // ── Single-plane paths ─────────────────────────────────────────────────
    else if (cam.planes.length == 1) {
      final bytes = cam.planes[0].bytes;
      if (bytes.length >= 2 && bytes[0] == 0xFF && bytes[1] == 0xD8) {
        // Already JPEG (iOS fast path): decode then downscale.
        final decoded = img.decodeJpg(bytes);
        if (decoded == null) return null;
        frame = img.copyResize(decoded,
            width: targetW,
            height: targetH,
            interpolation: img.Interpolation.average);
      } else {
        // Single-plane NV21 (interleaved Y then VU in one buffer).
        frame = _nv21SinglePlaneSampleFast(
            cam.planes[0].bytes, srcW, srcH, targetW, targetH);
      }
    }
    // ── BGRA_8888 (iOS startImageStream without JPEG) ──────────────────────
    else if (cam.format.group == ImageFormatGroup.bgra8888) {
      frame = _bgraSampleFast(
          cam.planes[0].bytes, srcW, srcH, targetW, targetH);
    }

    if (frame == null) return encodeRawToJpeg(params); // fallback

    frame = _applyRotation(
        frame, params.sensorOrientation, params.isFrontCamera);
    return Uint8List.fromList(
        img.encodeJpg(frame, quality: AppConstants.streamJpegQuality));
  } catch (e) {
    print('encodeRawToJpegFast error: $e');
    return null;
  }
}

// ---------------------------------------------------------------------------
// Fast direct-sampling helpers
// ---------------------------------------------------------------------------

/// Samples a multi-plane NV21 / YUV_420_888 [CameraImage] at [targetW] ×
/// [targetH] without decoding all source pixels.
img.Image _yuvSampleFast(
    CameraImage cam, int srcW, int srcH, int targetW, int targetH) {
  final out = img.Image(width: targetW, height: targetH);

  final yBuf = cam.planes[0].bytes;
  final uvBuf = cam.planes[1].bytes;
  final yStride = cam.planes[0].bytesPerRow;
  final uvStride = cam.planes[1].bytesPerRow;
  // NV21 on Android CameraX: bytesPerPixel == 2 (V,U interleaved).
  // Fall back to 2 if the camera driver reports null.
  final uvPixStep = cam.planes[1].bytesPerPixel ?? 2;

  for (int ty = 0; ty < targetH; ty++) {
    final sy = ty * srcH ~/ targetH;
    final yRowOff = sy * yStride;
    final uvRowOff = (sy >> 1) * uvStride;

    for (int tx = 0; tx < targetW; tx++) {
      final sx = tx * srcW ~/ targetW;

      final yVal = yBuf[yRowOff + sx];
      final uvIdx = uvRowOff + (sx >> 1) * uvPixStep;
      // NV21 → planes[1] = V first, then U.
      final vf = uvBuf[uvIdx] - 128;
      final uf = (uvIdx + 1 < uvBuf.length) ? uvBuf[uvIdx + 1] - 128 : 0;

      out.setPixelRgba(
        tx, ty,
        (yVal + vf * 1.402).round().clamp(0, 255),
        (yVal - uf * 0.34414 - vf * 0.71414).round().clamp(0, 255),
        (yVal + uf * 1.772).round().clamp(0, 255),
        255,
      );
    }
  }
  return out;
}

/// Samples a single-plane NV21 buffer (packed Y then VU) directly.
img.Image _nv21SinglePlaneSampleFast(
    Uint8List buf, int srcW, int srcH, int targetW, int targetH) {
  final out = img.Image(width: targetW, height: targetH);
  final uvOffset = srcW * srcH;

  for (int ty = 0; ty < targetH; ty++) {
    final sy = ty * srcH ~/ targetH;
    final yRowOff = sy * srcW;
    final uvRowOff = uvOffset + (sy >> 1) * srcW;

    for (int tx = 0; tx < targetW; tx++) {
      final sx = tx * srcW ~/ targetW;
      final y = buf[yRowOff + sx].toDouble();
      final uvIdx = uvRowOff + (sx & ~1);
      final vf = buf[uvIdx].toDouble() - 128.0;
      final uf = (uvIdx + 1 < buf.length)
          ? buf[uvIdx + 1].toDouble() - 128.0
          : 0.0;

      out.setPixelRgba(
        tx, ty,
        (y + vf * 1.402).round().clamp(0, 255),
        (y - uf * 0.34414 - vf * 0.71414).round().clamp(0, 255),
        (y + uf * 1.772).round().clamp(0, 255),
        255,
      );
    }
  }
  return out;
}

/// Samples a BGRA_8888 plane directly at target resolution.
img.Image _bgraSampleFast(
    Uint8List buf, int srcW, int srcH, int targetW, int targetH) {
  final out = img.Image(width: targetW, height: targetH);

  for (int ty = 0; ty < targetH; ty++) {
    final sy = ty * srcH ~/ targetH;
    final rowOff = sy * srcW * 4;

    for (int tx = 0; tx < targetW; tx++) {
      final sx = tx * srcW ~/ targetW;
      final idx = rowOff + sx * 4;
      // BGRA layout: B=idx, G=idx+1, R=idx+2, A=idx+3
      out.setPixelRgba(tx, ty, buf[idx + 2], buf[idx + 1], buf[idx], 255);
    }
  }
  return out;
}

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
