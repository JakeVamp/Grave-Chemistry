import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// Longest edge of the stored photo, enough for review.
const _maxDimension = 1600;

/// Re-encodes a captured photo as a plain JPEG: orientation applied, then
/// all EXIF metadata (GPS, device model, timestamps) dropped. Runs on
/// whatever isolate it's called from; use `compute` for large photos.
///
/// Throws [FormatException] if the bytes aren't a decodable image.
Uint8List sanitizeVerificationPhoto(Uint8List input) {
  img.Image? decoded;
  try {
    decoded = img.decodeImage(input);
  } catch (_) {
    // Corrupt input can make decoders throw rather than return null.
    decoded = null;
  }
  if (decoded == null) {
    throw const FormatException('Captured image could not be decoded');
  }

  var image = img.bakeOrientation(decoded);
  final longest = image.width > image.height ? image.width : image.height;
  if (longest > _maxDimension) {
    image = image.width >= image.height
        ? img.copyResize(image, width: _maxDimension)
        : img.copyResize(image, height: _maxDimension);
  }
  image.exif.clear();
  return img.encodeJpg(image, quality: 85);
}
