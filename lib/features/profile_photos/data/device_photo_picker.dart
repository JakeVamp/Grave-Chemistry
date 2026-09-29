import 'dart:typed_data';

import 'package:image_picker/image_picker.dart';

import '../application/photo_picker.dart';

/// System photo picker. Library only: no camera, microphone or broad
/// storage permission.
class DevicePhotoPicker implements PhotoPicker {
  final _picker = ImagePicker();

  @override
  Future<Uint8List?> pickFromLibrary() async {
    final file = await _picker.pickImage(
      source: ImageSource.gallery,
      maxWidth: 2400,
      maxHeight: 2400,
      requestFullMetadata: false,
    );
    return file?.readAsBytes();
  }
}
