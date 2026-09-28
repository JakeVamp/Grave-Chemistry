import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/theme/app_spacing.dart';
import '../../../shared/widgets/loading_button.dart';
import '../application/auth_providers.dart';
import 'auth_submission.dart';
import 'check_email_screen.dart';
import 'widgets/auth_fields.dart';
import 'widgets/auth_layout.dart';
import '../../../shared/widgets/message_banner.dart';

class ForgotPasswordScreen extends ConsumerStatefulWidget {
  const ForgotPasswordScreen({super.key, this.initialEmail = ''});

  final String initialEmail;

  @override
  ConsumerState<ForgotPasswordScreen> createState() =>
      _ForgotPasswordScreenState();
}

class _ForgotPasswordScreenState extends ConsumerState<ForgotPasswordScreen>
    with AuthSubmission {
  final _formKey = GlobalKey<FormState>();
  late final _emailController = TextEditingController(
    text: widget.initialEmail,
  );

  @override
  void dispose() {
    _emailController.dispose();
    super.dispose();
  }

  Future<void> _sendResetLink() async {
    if (!_formKey.currentState!.validate()) return;

    final email = _emailController.text.trim();
    final sent = await submit(
      () => ref
          .read(authControllerProvider.notifier)
          .sendPasswordResetEmail(email),
    );
    if (sent && mounted) {
      context.go(
        CheckEmailScreen.location(
          email: email,
          reason: CheckEmailReason.passwordReset,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return AuthLayout(
      heading: 'Reset your password',
      subheading: "Enter your account's email and we'll send you a reset link.",
      child: Form(
        key: _formKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (failure != null) ...[
              MessageBanner(message: failure!.message),
              const SizedBox(height: AppSpacing.md),
            ],
            EmailField(
              controller: _emailController,
              enabled: !isSubmitting,
              textInputAction: TextInputAction.done,
              onSubmitted: _sendResetLink,
            ),
            const SizedBox(height: AppSpacing.lg),
            LoadingButton(
              label: 'Send reset link',
              isLoading: isSubmitting,
              onPressed: _sendResetLink,
            ),
          ],
        ),
      ),
    );
  }
}
