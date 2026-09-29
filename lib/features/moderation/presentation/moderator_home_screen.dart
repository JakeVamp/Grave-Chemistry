import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/router/app_routes.dart';
import '../../../core/router/auth_guard.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../shared/utils/context_extensions.dart';
import '../../../shared/widgets/loading_button.dart';
import '../../../shared/widgets/message_banner.dart';
import '../../auth/application/auth_providers.dart';
import '../../profile/application/profile_providers.dart';
import '../application/moderation_providers.dart';
import '../domain/moderation_failure.dart';
import '../domain/moderator_mfa.dart';
import '../../../core/router/back_navigation.dart';

/// Entry point for moderators. Tools unlock only once this session has
/// passed two-factor verification, which the database also requires.
///
/// Reachable without a finished member profile: moderator tools are a
/// separate staff path. That grants nothing in the dating app; the account
/// stays unverified and invisible to members until it finishes onboarding
/// like anyone else.
class ModeratorHomeScreen extends ConsumerWidget {
  const ModeratorHomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mfa = ref.watch(moderatorMfaProvider);
    final memberSetupRoute = switch (ref.watch(onboardingGateProvider)) {
      OnboardingGate.loading || OnboardingGate.error => null,
      final gate => onboardingRouteFor(gate),
    };
    return Scaffold(
      appBar: AppBar(
        leading: appBackButton(context),
        automaticallyImplyLeading: false,
        title: const Text('Moderator tools'),
        actions: [
          // Settings (and its sign-out) are part of the member app, which
          // stays closed until member onboarding is done.
          if (memberSetupRoute != null)
            IconButton(
              tooltip: 'Sign out',
              icon: const Icon(Icons.logout),
              onPressed: () =>
                  ref.read(authControllerProvider.notifier).signOut(),
            ),
        ],
      ),
      bottomNavigationBar: memberSetupRoute == null
          ? null
          : SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(AppSpacing.md),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'Your member profile isn’t finished, so the dating app '
                      'stays closed and members can’t see you. Moderator '
                      'tools don’t need it.',
                      textAlign: TextAlign.center,
                      style: context.textTheme.bodySmall?.copyWith(
                        color: context.colors.onSurfaceVariant,
                      ),
                    ),
                    TextButton(
                      onPressed: () => context.go(memberSetupRoute),
                      child: const Text('Set up member profile'),
                    ),
                  ],
                ),
              ),
            ),
      body: SafeArea(
        child: switch (mfa) {
          AsyncData(value: MfaVerified()) => const _Tools(),
          AsyncData(value: MfaCodeRequired(:final factorId)) => _MfaCodeForm(
            factorId: factorId,
            intro:
                'Enter the 6-digit code from your authenticator app to use '
                'moderator tools.',
          ),
          AsyncData(value: MfaEnrollmentRequired()) => const _MfaEnrollment(),
          AsyncError() => _Retry(
            message: "We couldn't check your verification.",
            onRetry: () => ref.invalidate(moderatorMfaProvider),
          ),
          _ => const Center(child: CircularProgressIndicator()),
        },
      ),
    );
  }
}

class _Tools extends StatelessWidget {
  const _Tools();

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(AppSpacing.md),
      children: [
        Text(
          'Every action you take here is recorded with your account.',
          style: context.textTheme.bodyMedium?.copyWith(
            color: context.colors.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: AppSpacing.md),
        Card(
          child: ListTile(
            leading: const Icon(Icons.photo_library_outlined),
            title: const Text('Photo review'),
            subtitle: const Text('Photos waiting for a human decision'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push(AppRoutes.photoReview),
          ),
        ),
      ],
    );
  }
}

class _MfaEnrollment extends ConsumerStatefulWidget {
  const _MfaEnrollment();

  @override
  ConsumerState<_MfaEnrollment> createState() => _MfaEnrollmentState();
}

class _MfaEnrollmentState extends ConsumerState<_MfaEnrollment> {
  TotpEnrollment? _enrollment;
  String? _error;
  bool _working = false;

  Future<void> _start() async {
    setState(() {
      _working = true;
      _error = null;
    });
    try {
      final enrollment = await ref.read(moderatorMfaProvider.notifier).enroll();
      if (mounted) setState(() => _enrollment = enrollment);
    } on ModerationFailure catch (failure) {
      if (mounted) setState(() => _error = failure.message);
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final enrollment = _enrollment;
    if (enrollment != null) {
      return _MfaCodeForm(
        factorId: enrollment.factorId,
        intro:
            'Add this key to your authenticator app, then enter the 6-digit '
            'code it shows.',
        setupKey: enrollment.secret,
      );
    }
    return ListView(
      padding: const EdgeInsets.all(AppSpacing.lg),
      children: [
        Text(
          'Set up two-factor verification',
          style: context.textTheme.titleLarge,
        ),
        const SizedBox(height: AppSpacing.sm),
        const Text(
          'Moderator tools need an authenticator app (such as 1Password, '
          'Google Authenticator or Authy) in addition to your password.',
        ),
        if (_error != null) ...[
          const SizedBox(height: AppSpacing.md),
          MessageBanner(message: _error!),
        ],
        const SizedBox(height: AppSpacing.lg),
        LoadingButton(
          label: 'Set up authenticator',
          isLoading: _working,
          onPressed: _start,
        ),
      ],
    );
  }
}

class _MfaCodeForm extends ConsumerStatefulWidget {
  const _MfaCodeForm({
    required this.factorId,
    required this.intro,
    this.setupKey,
  });

  final String factorId;
  final String intro;
  final String? setupKey;

  @override
  ConsumerState<_MfaCodeForm> createState() => _MfaCodeFormState();
}

class _MfaCodeFormState extends ConsumerState<_MfaCodeForm> {
  final _code = TextEditingController();
  String? _error;
  bool _working = false;

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  Future<void> _verify() async {
    final code = _code.text.trim();
    if (!RegExp(r'^\d{6}$').hasMatch(code)) {
      setState(() => _error = 'Enter the 6-digit code.');
      return;
    }
    setState(() {
      _working = true;
      _error = null;
    });
    try {
      await ref
          .read(moderatorMfaProvider.notifier)
          .verify(factorId: widget.factorId, code: code);
    } on ModerationFailure catch (failure) {
      if (mounted) setState(() => _error = failure.message);
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(AppSpacing.lg),
      children: [
        Text('Two-factor verification', style: context.textTheme.titleLarge),
        const SizedBox(height: AppSpacing.sm),
        Text(widget.intro),
        if (widget.setupKey != null) ...[
          const SizedBox(height: AppSpacing.md),
          Text('Setup key', style: context.textTheme.titleSmall),
          const SizedBox(height: AppSpacing.xs),
          SelectableText(
            widget.setupKey!,
            style: context.textTheme.bodyLarge?.copyWith(
              fontFamily: 'monospace',
              letterSpacing: 1.5,
            ),
          ),
        ],
        const SizedBox(height: AppSpacing.md),
        TextField(
          controller: _code,
          decoration: const InputDecoration(labelText: 'Verification code'),
          keyboardType: TextInputType.number,
          autofillHints: const [AutofillHints.oneTimeCode],
          inputFormatters: [
            FilteringTextInputFormatter.digitsOnly,
            LengthLimitingTextInputFormatter(6),
          ],
          onSubmitted: (_) => _verify(),
        ),
        if (_error != null) ...[
          const SizedBox(height: AppSpacing.md),
          MessageBanner(message: _error!),
        ],
        const SizedBox(height: AppSpacing.lg),
        LoadingButton(label: 'Verify', isLoading: _working, onPressed: _verify),
      ],
    );
  }
}

class _Retry extends StatelessWidget {
  const _Retry({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(message, textAlign: TextAlign.center),
            const SizedBox(height: AppSpacing.md),
            FilledButton(onPressed: onRetry, child: const Text('Try again')),
          ],
        ),
      ),
    );
  }
}
