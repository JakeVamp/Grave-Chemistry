import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:grave_chemistry/features/verification/data/verification_error_mapper.dart';
import 'package:grave_chemistry/features/verification/domain/verification_failure.dart';
import 'package:http/http.dart' as http;

void main() {
  test('maps server outcomes to user-facing failures', () {
    const expected = {
      'session_expired': VerificationFailureType.sessionExpired,
      'session_not_open': VerificationFailureType.sessionExpired,
      'session_not_found': VerificationFailureType.sessionExpired,
      'media_missing': VerificationFailureType.uploadFailed,
      'already_submitted': VerificationFailureType.alreadySubmitted,
      'profile_incomplete': VerificationFailureType.notEligible,
      'rate_limited': VerificationFailureType.rateLimited,
      'too_many_attempts': VerificationFailureType.tooManyAttempts,
      'something_new': VerificationFailureType.unknown,
    };
    for (final MapEntry(key: outcome, value: type) in expected.entries) {
      expect(failureForOutcome(outcome).type, type, reason: outcome);
    }
  });

  test('maps network errors', () {
    expect(
      mapVerificationError(http.ClientException('offline')).type,
      VerificationFailureType.network,
    );
    expect(
      mapVerificationError(TimeoutException('slow')).type,
      VerificationFailureType.network,
    );
  });

  test('upload errors stay upload errors', () {
    expect(
      mapVerificationError(
        Exception('storage said no'),
        fallback: VerificationFailureType.uploadFailed,
      ).type,
      VerificationFailureType.uploadFailed,
    );
  });

  test('messages never include raw server text', () {
    final failure = mapVerificationError(Exception('bucket xyz path abc/def'));
    expect(failure.message, isNot(contains('abc')));
    expect(failure.toString(), isNot(contains('abc')));
  });
}
