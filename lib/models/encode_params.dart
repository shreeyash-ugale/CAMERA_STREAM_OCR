import 'package:camera/camera.dart';

/// Parameters passed to the frame-encoding isolate.
/// Bundled into a single object because `compute()` accepts only one argument.
class EncodeParams {
  const EncodeParams({
    required this.image,
    required this.sensorOrientation,
    required this.isFrontCamera,
    this.targetWidth,
  });

  final CameraImage image;

  /// The camera sensor's native rotation in degrees (0, 90, 180, 270).
  /// Back cameras on Android are usually 90°.
  final int sensorOrientation;

  /// Front-facing cameras require a horizontal flip after rotation.
  final bool isFrontCamera;

  /// If set, the encoded frame is downscaled so its width equals this value
  /// (height is scaled proportionally).  `null` means no downscaling.
  final int? targetWidth;
}
