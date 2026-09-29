import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../../../shared/utils/app_logger.dart';
import '../domain/review_media.dart';
import 'moderation_error_mapper.dart';

/// Loads the two review photos. The Edge Function returns 60-second signed
/// URLs only after the database has re-checked the moderator; this class
/// downloads each one immediately and drops the URL. Anything unexpected
/// fails closed.
class ReviewMediaLoader {
  /// [_requestSignedUrls] calls the Edge Function as the moderator.
  ReviewMediaLoader(this._requestSignedUrls, this._http);

  static const maxBytes = 10 * 1024 * 1024;
  static const _timeout = Duration(seconds: 20);

  final Future<Map<String, dynamic>> Function(String photoId)
  _requestSignedUrls;
  final http.Client _http;

  /// Throws `ModerationFailure`.
  Future<ReviewMedia> load(String photoId) async {
    final urls = await _requestSignedUrls(photoId);
    final profileUrl = urls['profile_photo_url'];
    if (profileUrl is! String) throw mediaUnavailableFailure;
    final profile = await _download(profileUrl);
    if (profile == null) throw mediaUnavailableFailure;

    final verificationUrl = urls['verification_photo_url'];
    Uint8List? verification;
    var availability = switch (urls['verification']) {
      'available' => VerificationPhotoAvailability.available,
      'none' => VerificationPhotoAvailability.none,
      _ => VerificationPhotoAvailability.unavailable,
    };
    if (verificationUrl is String) {
      verification = await _download(verificationUrl);
    }
    if (verification == null &&
        availability == VerificationPhotoAvailability.available) {
      availability = VerificationPhotoAvailability.unavailable;
    }
    return ReviewMedia(
      profilePhoto: profile,
      verificationPhoto: verification,
      verification: availability,
    );
  }

  /// JPEG bytes, or null for an expired/invalid link or unexpected content.
  Future<Uint8List?> _download(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null || uri.scheme != 'https') return null;
    try {
      final response = await _http.get(uri).timeout(_timeout);
      final bytes = response.bodyBytes;
      if (response.statusCode != 200 ||
          bytes.length < 3 ||
          bytes.length > maxBytes ||
          bytes[0] != 0xFF ||
          bytes[1] != 0xD8 ||
          bytes[2] != 0xFF) {
        AppLogger.error('Review photo unavailable (${response.statusCode})');
        return null;
      }
      return bytes;
    } catch (error) {
      // Never log the URL.
      AppLogger.error('Review photo download failed (${error.runtimeType})');
      return null;
    }
  }
}
