import 'auth_event.dart';
import 'auth_user.dart';
import 'sign_up_result.dart';

/// All methods throw `AuthFailure` on error.
abstract interface class AuthRepository {
  AuthUser? get currentUser;

  /// Auth changes. Errors from email links (expired or invalid) are
  /// delivered as `AuthFailure` stream errors.
  Stream<AuthEvent> get events;

  Future<void> signIn({required String email, required String password});

  Future<SignUpResult> signUp({
    required String email,
    required String password,
  });

  Future<void> resendConfirmationEmail(String email);

  Future<void> sendPasswordResetEmail(String email);

  Future<void> updatePassword(String newPassword);

  Future<void> signOut();
}
