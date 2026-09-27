import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/supabase/supabase_providers.dart';
import '../data/supabase_auth_repository.dart';
import '../domain/auth_failure.dart';
import '../domain/auth_repository.dart';
import '../domain/auth_status.dart';
import '../domain/auth_status_reducer.dart';
import '../domain/sign_up_result.dart';

final authRepositoryProvider = Provider<AuthRepository>(
  (ref) => SupabaseAuthRepository(ref.watch(supabaseClientProvider).auth),
);

final authControllerProvider = NotifierProvider<AuthController, AuthStatus>(
  AuthController.new,
);

/// The most recent email-link failure (e.g. an expired confirmation link),
/// shown once on the sign-in screen.
final authLinkFailureProvider =
    NotifierProvider<AuthLinkFailureController, AuthFailure?>(
      AuthLinkFailureController.new,
    );

/// Single source of truth for the current auth status, and the entry point
/// for auth actions. Actions throw [AuthFailure]; the resulting state change
/// arrives through the repository's event stream.
class AuthController extends Notifier<AuthStatus> {
  AuthRepository get _repository => ref.read(authRepositoryProvider);

  @override
  AuthStatus build() {
    final repository = ref.watch(authRepositoryProvider);
    final subscription = repository.events.listen(
      (event) => state = reduceAuthStatus(state, event),
      onError: (Object error) {
        if (error is AuthFailure) {
          ref.read(authLinkFailureProvider.notifier).report(error);
        }
      },
    );
    ref.onDispose(subscription.cancel);

    final user = repository.currentUser;
    return user == null ? const SignedOut() : SignedIn(user);
  }

  Future<void> signIn({required String email, required String password}) =>
      _repository.signIn(email: email, password: password);

  Future<SignUpResult> signUp({
    required String email,
    required String password,
  }) => _repository.signUp(email: email, password: password);

  Future<void> resendConfirmationEmail(String email) =>
      _repository.resendConfirmationEmail(email);

  Future<void> sendPasswordResetEmail(String email) =>
      _repository.sendPasswordResetEmail(email);

  Future<void> updatePassword(String newPassword) =>
      _repository.updatePassword(newPassword);

  Future<void> signOut() => _repository.signOut();
}

class AuthLinkFailureController extends Notifier<AuthFailure?> {
  @override
  AuthFailure? build() => null;

  void report(AuthFailure failure) => state = failure;

  void clear() => state = null;
}
