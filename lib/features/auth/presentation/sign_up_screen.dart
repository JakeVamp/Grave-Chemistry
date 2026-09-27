import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/router/app_routes.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../shared/widgets/loading_button.dart';
import '../application/auth_providers.dart';
import '../domain/auth_validators.dart';
import '../domain/sign_up_result.dart';
import 'auth_submission.dart';
import 'check_email_screen.dart';
import 'widgets/auth_fields.dart';
import 'widgets/auth_layout.dart';
import 'widgets/auth_message.dart';

class SignUpScreen extends ConsumerStatefulWidget {
  const SignUpScreen({super.key});

  @override
  ConsumerState<SignUpScreen> createState() => _SignUpScreenState();
}

class _SignUpScreenState extends ConsumerState<SignUpScreen>
    with AuthSubmission {
  final _formKey = GlobalKey<FormState>();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _confirmController = TextEditingController();

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    _confirmController.dispose();
    super.dispose();
  }

  Future<void> _signUp() async {
    if (!_formKey.currentState!.validate()) return;

    TextInput.finishAutofillContext();
    final email = _emailController.text.trim();
    SignUpResult? result;
    await submit(() async {
      result = await ref
          .read(authControllerProvider.notifier)
          .signUp(email: email, password: _passwordController.text);
    });

    // If confirmation is disabled the user is signed in and the router
    // redirects to the app on its own.
    if (result == SignUpResult.confirmationRequired && mounted) {
      context.go(
        CheckEmailScreen.location(
          email: email,
          reason: CheckEmailReason.confirmSignUp,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return AuthLayout(
      heading: 'Create an account',
      subheading:
          'Use at least ${AuthValidators.minPasswordLength} characters '
          'for your password.',
      child: Form(
        key: _formKey,
        child: AutofillGroup(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (failure != null) ...[
                AuthMessage(message: failure!.message),
                const SizedBox(height: AppSpacing.md),
              ],
              EmailField(controller: _emailController, enabled: !isSubmitting),
              const SizedBox(height: AppSpacing.md),
              PasswordField(
                controller: _passwordController,
                enabled: !isSubmitting,
                isNewPassword: true,
                textInputAction: TextInputAction.next,
                validator: AuthValidators.newPassword,
              ),
              const SizedBox(height: AppSpacing.md),
              PasswordField(
                controller: _confirmController,
                label: 'Confirm password',
                enabled: !isSubmitting,
                isNewPassword: true,
                validator: AuthValidators.confirmPassword(
                  () => _passwordController.text,
                ),
                onSubmitted: _signUp,
              ),
              const SizedBox(height: AppSpacing.lg),
              LoadingButton(
                label: 'Create account',
                isLoading: isSubmitting,
                onPressed: _signUp,
              ),
              const SizedBox(height: AppSpacing.lg),
              Wrap(
                alignment: WrapAlignment.center,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  const Text('Already have an account?'),
                  TextButton(
                    onPressed: isSubmitting
                        ? null
                        : () => context.go(AppRoutes.auth),
                    child: const Text('Sign in'),
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
