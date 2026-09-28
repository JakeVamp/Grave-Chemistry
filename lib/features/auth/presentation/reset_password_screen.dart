import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_spacing.dart';
import '../../../shared/widgets/loading_button.dart';
import '../application/auth_providers.dart';
import '../domain/auth_validators.dart';
import 'auth_submission.dart';
import 'widgets/auth_fields.dart';
import 'widgets/auth_layout.dart';
import '../../../shared/widgets/message_banner.dart';

/// Shown after the user opens a password-reset link. The router keeps them
/// here until they set a new password or cancel.
class ResetPasswordScreen extends ConsumerStatefulWidget {
  const ResetPasswordScreen({super.key});

  @override
  ConsumerState<ResetPasswordScreen> createState() =>
      _ResetPasswordScreenState();
}

class _ResetPasswordScreenState extends ConsumerState<ResetPasswordScreen>
    with AuthSubmission {
  final _formKey = GlobalKey<FormState>();
  final _passwordController = TextEditingController();
  final _confirmController = TextEditingController();

  @override
  void dispose() {
    _passwordController.dispose();
    _confirmController.dispose();
    super.dispose();
  }

  Future<void> _updatePassword() async {
    if (!_formKey.currentState!.validate()) return;

    final messenger = ScaffoldMessenger.of(context);
    final updated = await submit(
      () => ref
          .read(authControllerProvider.notifier)
          .updatePassword(_passwordController.text),
    );
    // The router moves the user into the app once the update is confirmed.
    if (updated) {
      messenger.showSnackBar(
        const SnackBar(content: Text('Your password has been updated.')),
      );
    }
  }

  Future<void> _cancel() async {
    await submit(() => ref.read(authControllerProvider.notifier).signOut());
  }

  @override
  Widget build(BuildContext context) {
    return AuthLayout(
      heading: 'Choose a new password',
      subheading:
          'Use at least ${AuthValidators.minPasswordLength} characters.',
      child: Form(
        key: _formKey,
        child: AutofillGroup(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (failure != null) ...[
                MessageBanner(message: failure!.message),
                const SizedBox(height: AppSpacing.md),
              ],
              PasswordField(
                controller: _passwordController,
                label: 'New password',
                enabled: !isSubmitting,
                isNewPassword: true,
                textInputAction: TextInputAction.next,
                validator: AuthValidators.newPassword,
              ),
              const SizedBox(height: AppSpacing.md),
              PasswordField(
                controller: _confirmController,
                label: 'Confirm new password',
                enabled: !isSubmitting,
                isNewPassword: true,
                validator: AuthValidators.confirmPassword(
                  () => _passwordController.text,
                ),
                onSubmitted: _updatePassword,
              ),
              const SizedBox(height: AppSpacing.lg),
              LoadingButton(
                label: 'Update password',
                isLoading: isSubmitting,
                onPressed: _updatePassword,
              ),
              const SizedBox(height: AppSpacing.sm),
              TextButton(
                onPressed: isSubmitting ? null : _cancel,
                child: const Text('Cancel and sign out'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
