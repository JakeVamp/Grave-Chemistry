import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../../shared/utils/app_logger.dart';

/// Blocks screenshots and screen recording while sensitive review photos
/// are on screen (Android FLAG_SECURE). iOS offers no supported API for
/// this; there the app simply offers no way to save or share the photos.
abstract interface class ScreenSecurity {
  Future<void> enable();

  Future<void> disable();
}

class PlatformScreenSecurity implements ScreenSecurity {
  static const _channel = MethodChannel(
    'com.gravechemistry.app/screen_security',
  );

  bool get _supported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  @override
  Future<void> enable() => _invoke('enable');

  @override
  Future<void> disable() => _invoke('disable');

  Future<void> _invoke(String method) async {
    if (!_supported) return;
    try {
      await _channel.invokeMethod<void>(method);
    } catch (error) {
      AppLogger.error('Screen security unavailable (${error.runtimeType})');
    }
  }
}
