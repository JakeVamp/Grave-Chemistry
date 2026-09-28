import 'package:permission_handler/permission_handler.dart';

import '../domain/camera_permission.dart';

/// Camera permission only. Microphone, photos, contacts and location are
/// never requested.
class DeviceCameraPermissionService implements CameraPermissionService {
  @override
  Future<CameraPermissionStatus> request() async {
    final status = await Permission.camera.request();
    if (status.isGranted || status.isLimited) {
      return CameraPermissionStatus.granted;
    }
    if (status.isPermanentlyDenied) {
      return CameraPermissionStatus.permanentlyDenied;
    }
    if (status.isRestricted) return CameraPermissionStatus.restricted;
    return CameraPermissionStatus.denied;
  }

  @override
  Future<bool> openSettings() => openAppSettings();
}
