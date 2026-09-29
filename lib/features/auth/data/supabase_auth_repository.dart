import 'dart:async';

import 'package:supabase_flutter/supabase_flutter.dart' hide AuthUser;

import '../../../core/supabase/auth_callback.dart';
import '../../../shared/utils/app_logger.dart';
import '../domain/auth_event.dart';
import '../domain/auth_repository.dart';
import '../domain/auth_user.dart';
import '../domain/sign_up_result.dart';
import 'auth_error_mapper.dart';

class SupabaseAuthRepository implements AuthRepository {
  SupabaseAuthRepository(this._auth);

  /// Upper bound so a stalled request can't leave a screen loading forever.
  static const _requestTimeout = Duration(seconds: 20);

  final GoTrueClient _auth;

  @override
  AuthUser? get currentUser => _toAuthUser(_auth.currentSession?.user);

  @override
  Stream<AuthEvent> get events {
    return _auth.onAuthStateChange.transform(
      StreamTransformer<AuthState, AuthEvent>.fromHandlers(
        handleData: (state, sink) {
          sink.add(
            AuthEvent(
              _toEventType(state.event),
              _toAuthUser(state.session?.user),
            ),
          );
        },
        handleError: (error, stackTrace, sink) {
          final failure = mapAuthError(error);
          // Only email-link problems are relevant to the user. Others, such
          // as a background token refresh failing while offline, are logged.
          if (failure.isLinkFailure) {
            sink.addError(failure, stackTrace);
          } else {
            AppLogger.error(
              'Auth state error',
              error: error,
              stackTrace: stackTrace,
            );
          }
        },
      ),
    );
  }

  @override
  Future<void> signIn({required String email, required String password}) {
    return _guard(
      () => _auth.signInWithPassword(email: email.trim(), password: password),
    );
  }

  @override
  Future<SignUpResult> signUp({
    required String email,
    required String password,
  }) {
    return _guard(() async {
      final response = await _auth.signUp(
        email: email.trim(),
        password: password,
        emailRedirectTo: AuthCallback.url,
      );
      // With email confirmation on, Supabase returns no session — including
      // for already-registered emails, so account existence isn't revealed.
      return response.session == null
          ? SignUpResult.confirmationRequired
          : SignUpResult.signedIn;
    });
  }

  @override
  Future<void> resendConfirmationEmail(String email) {
    return _guard(
      () => _auth.resend(
        type: OtpType.signup,
        email: email.trim(),
        emailRedirectTo: AuthCallback.url,
      ),
    );
  }

  @override
  Future<void> sendPasswordResetEmail(String email) {
    return _guard(
      () => _auth.resetPasswordForEmail(
        email.trim(),
        redirectTo: AuthCallback.url,
      ),
    );
  }

  @override
  Future<void> updatePassword(String newPassword) {
    return _guard(
      () => _auth.updateUser(UserAttributes(password: newPassword)),
    );
  }

  @override
  Future<void> signOut() async {
    try {
      await _auth.signOut();
    } catch (error, stackTrace) {
      // The local session is cleared before the server call, so the user is
      // signed out on this device even if revoking the token fails.
      AppLogger.error(
        'Server sign-out failed',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  Future<T> _guard<T>(Future<T> Function() action) async {
    try {
      return await action().timeout(_requestTimeout);
    } catch (error, stackTrace) {
      AppLogger.error(
        'Auth request failed',
        error: error,
        stackTrace: stackTrace,
      );
      throw mapAuthError(error);
    }
  }

  static AuthUser? _toAuthUser(User? user) {
    if (user == null) return null;
    final role = user.appMetadata['role'];
    return AuthUser(
      id: user.id,
      email: user.email,
      role: role is String ? role : null,
    );
  }

  static AuthEventType _toEventType(AuthChangeEvent event) {
    return switch (event) {
      AuthChangeEvent.signedIn => AuthEventType.signedIn,
      AuthChangeEvent.signedOut => AuthEventType.signedOut,
      AuthChangeEvent.passwordRecovery => AuthEventType.passwordRecovery,
      AuthChangeEvent.userUpdated => AuthEventType.userUpdated,
      _ => AuthEventType.sessionRefreshed,
    };
  }
}
