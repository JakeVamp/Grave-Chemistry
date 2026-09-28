enum CameraPermissionStatus {
  granted,
  denied,

  /// The OS won't show the prompt again; only Settings can grant it.
  permanentlyDenied,

  /// Blocked by parental controls or device policy.
  restricted,
}

abstract interface class CameraPermissionService {
  /// Requests camera access, showing the system prompt if allowed.
  Future<CameraPermissionStatus> request();

  /// Opens the app's page in system Settings.
  Future<bool> openSettings();
}
