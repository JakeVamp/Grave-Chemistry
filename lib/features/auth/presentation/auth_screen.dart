import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/router/app_routes.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../shared/widgets/loading_button.dart';
import '../application/auth_providers.dart';
import '../domain/auth_failure.dart';
import '../domain/auth_validators.dart';
import 'auth_submission.dart';
import 'check_email_screen.dart';
import 'widgets/auth_fields.dart';
import 'widgets/auth_layout.dart';
import '../../../shared/widgets/message_banner.dart';

/// Sign-in screen; the entry point for signed-out users.
class AuthScreen extends ConsumerStatefulWidget {
  const AuthScreen({super.key});

  @override
  ConsumerState<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends ConsumerState<AuthScreen> with AuthSubmission {
  final _formKey = GlobalKey<FormState>();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _signIn() async {
    ref.read(authLinkFailureProvider.notifier).clear();
    if (!_formKey.currentState!.validate()) return;

    TextInput.finishAutofillContext();
    // On success the router redirects to the app.
    await submit(
      () => ref
          .read(authControllerProvider.notifier)
          .signIn(
            email: _emailController.text,
            password: _passwordController.text,
          ),
    );
  }

  Future<void> _resendConfirmation() async {
    final email = _emailController.text.trim();
    final sent = await submit(
      () => ref
          .read(authControllerProvider.notifier)
          .resendConfirmationEmail(email),
    );
    if (sent && mounted) {
      context.go(
        CheckEmailScreen.location(
          email: email,
          reason: CheckEmailReason.confirmSignUp,
        ),
      );
    }
  }

  void _openForgotPassword() {
    final email = _emailController.text.trim();
    context.push(
      Uri(
        path: AppRoutes.forgotPassword,
        queryParameters: email.isEmpty ? null : {'email': email},
      ).toString(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final linkFailure = ref.watch(authLinkFailureProvider);
    final error = failure ?? linkFailure;

    return AuthLayout(
      heading: 'Sign in',
      subheading: 'Welcome back.',
      child: Form(
        key: _formKey,
        child: AutofillGroup(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (error != null) ...[
                MessageBanner(
                  message: error.message,
                  action: error.type == AuthFailureType.emailNotConfirmed
                      ? TextButton(
                          onPressed: isSubmitting ? null : _resendConfirmation,
                          child: const Text('Resend confirmation email'),
                        )
                      : null,
                ),
                const SizedBox(height: AppSpacing.md),
              ],
              EmailField(controller: _emailController, enabled: !isSubmitting),
              const SizedBox(height: AppSpacing.md),
              PasswordField(
                controller: _passwordController,
                enabled: !isSubmitting,
                validator: AuthValidators.requiredPassword,
                onSubmitted: _signIn,
              ),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: isSubmitting ? null : _openForgotPassword,
                  child: const Text('Forgot password?'),
                ),
              ),
              const SizedBox(height: AppSpacing.sm),
              LoadingButton(
                label: 'Sign in',
                isLoading: isSubmitting,
                onPressed: _signIn,
              ),
              const SizedBox(height: AppSpacing.lg),
              Wrap(
                alignment: WrapAlignment.center,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  const Text('New here?'),
                  TextButton(
                    onPressed: isSubmitting
                        ? null
                        : () => context.push(AppRoutes.signUp),
                    child: const Text('Create an account'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
