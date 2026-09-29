import 'dart:typed_data';

/// Chooses an image for a public profile photo. Returns null if the user
/// cancels.
abstract interface class PhotoPicker {
  Future<Uint8List?> pickFromLibrary();
}
