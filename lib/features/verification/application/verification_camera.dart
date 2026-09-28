import 'dart:typed_data';

import 'package:flutter/widgets.dart';

/// A live camera used only for verification. There is deliberately no way
/// to supply an existing photo: images come only from [takePicture].
abstract interface class VerificationCamera {
  /// Opens the front camera. Throws `VerificationFailure`.
  Future<void> initialize();

  Widget buildPreview();

  /// Captures a new photo and returns its JPEG bytes. Throws
  /// `VerificationFailure`.
  Future<Uint8List> takePicture();

  Future<void> dispose();
}
