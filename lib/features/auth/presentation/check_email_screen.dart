import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/router/app_routes.dart';
import '../../../core/theme/app_spacing.dart';
import '../application/auth_providers.dart';
import 'auth_submission.dart';
import 'widgets/auth_layout.dart';
import 'widgets/auth_message.dart';

enum CheckEmailReason { confirmSignUp, passwordReset }

/// Tells the user an email is on its way and lets them request it again.
class CheckEmailScreen extends ConsumerStatefulWidget {
  const CheckEmailScreen({
    super.key,
    required this.email,
    required this.reason,
  });

  factory CheckEmailScreen.fromQuery(Map<String, String> query) {
    return CheckEmailScreen(
      email: query['email'] ?? '',
      reason: CheckEmailReason.values.firstWhere(
        (reason) => reason.name == query['reason'],
        orElse: () => CheckEmailReason.confirmSignUp,
      ),
    );
  }

  /// Location for this screen with its parameters encoded.
  static String location({
    required String email,
    required CheckEmailReason reason,
  }) {
    return Uri(
      path: AppRoutes.checkEmail,
      queryParameters: {'email': email.trim(), 'reason': reason.name},
    ).toString();
  }

  final String email;
  final CheckEmailReason reason;

  @override
  ConsumerState<CheckEmailScreen> createState() => _CheckEmailScreenState();
}

class _CheckEmailScreenState extends ConsumerState<CheckEmailScreen>
    with AuthSubmission {
  bool _resent = false;

  bool get _isSignUp => widget.reason == CheckEmailReason.confirmSignUp;

  Future<void> _resend() async {
    setState(() => _resent = false);
    final auth = ref.read(authControllerProvider.notifier);
    final sent = await submit(
      () => _isSignUp
          ? auth.resendConfirmationEmail(widget.email)
          : auth.sendPasswordResetEmail(widget.email),
    );
    if (sent && mounted) setState(() => _resent = true);
  }

  @override
  Widget build(BuildContext context) {
    final email = widget.email.isEmpty ? 'your email' : widget.email;
    final message = _isSignUp
        ? 'We sent a confirmation link to $email. Open it on this device to '
              'finish creating your account. If you already have an account, '
              'sign in instead.'
        : 'If an account exists for $email, we sent a link to reset your '
              'password. Open it on this device to continue.';

    return AuthLayout(
      heading: 'Check your email',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AuthMessage(message: message, tone: AuthMessageTone.info),
          const SizedBox(height: AppSpacing.md),
          Text(
            "Didn't get it? Check your spam folder, or send it again.",
            style: Theme.of(context).textTheme.bodySmall,
          ),
          if (failure != null) ...[
            const SizedBox(height: AppSpacing.md),
            AuthMessage(message: failure!.message),
          ],
          if (_resent) ...[
            const SizedBox(height: AppSpacing.md),
            const AuthMessage(
              message: 'Email sent again.',
              tone: AuthMessageTone.info,
            ),
          ],
          const SizedBox(height: AppSpacing.lg),
          OutlinedButton(
            onPressed: isSubmitting || widget.email.isEmpty ? null : _resend,
            child: isSubmitting
                ? const SizedBox.square(
                    dimension: 22,
                    child: CircularProgressIndicator(strokeWidth: 2.5),
                  )
                : const Text('Resend email'),
          ),
          const SizedBox(height: AppSpacing.sm),
          TextButton(
            onPressed: () => context.go(AppRoutes.auth),
            child: const Text('Back to sign in'),
          ),
        ],
      ),
    );
  }
}
