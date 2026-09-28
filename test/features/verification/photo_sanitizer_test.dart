import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:grave_chemistry/features/verification/data/photo_sanitizer.dart';
import 'package:image/image.dart' as img;

void main() {
  img.Image photoWithMetadata({int width = 40, int height = 30}) {
    final image = img.Image(width: width, height: height)
      ..clear(img.ColorRgb8(120, 20, 40));
    image.exif.imageIfd['Make'] = img.IfdValueAscii('SpyPhone');
    image.exif.imageIfd['Model'] = img.IfdValueAscii('Model X');
    image.exif.gpsIfd['GPSLatitude'] = img.IfdValueRational(42, 1);
    image.exif.gpsIfd['GPSLongitude'] = img.IfdValueRational(70, 1);
    return image;
  }

  test('removes EXIF metadata, including GPS', () {
    final original = img.encodeJpg(photoWithMetadata());
    expect(img.decodeJpgExif(original)!.isEmpty, isFalse);

    final cleaned = sanitizeVerificationPhoto(original);
    final exif = img.decodeJpgExif(cleaned);
    expect(exif == null || exif.isEmpty, isTrue);
    expect(img.decodeJpg(cleaned), isNotNull);
  });

  test('applies EXIF orientation before dropping it', () {
    final image = photoWithMetadata(width: 40, height: 20);
    image.exif.imageIfd.orientation = 6; // rotated 90° clockwise
    final cleaned = img.decodeJpg(
      sanitizeVerificationPhoto(img.encodeJpg(image)),
    )!;
    expect(cleaned.width, 20);
    expect(cleaned.height, 40);
  });

  test('limits the stored size', () {
    final large = img.encodeJpg(photoWithMetadata(width: 3000, height: 2000));
    final cleaned = img.decodeJpg(sanitizeVerificationPhoto(large))!;
    expect(cleaned.width, 1600);
  });

  test('rejects data that is not an image', () {
    expect(
      () => sanitizeVerificationPhoto(
        Uint8List.fromList('not an image'.codeUnits),
      ),
      throwsFormatException,
    );
  });
}
