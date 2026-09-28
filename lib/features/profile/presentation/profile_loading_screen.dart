import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_spacing.dart';
import '../../../shared/utils/context_extensions.dart';
import '../../auth/application/auth_providers.dart';
import '../application/profile_providers.dart';
import '../domain/profile_failure.dart';

/// Shown to signed-in users while their profile loads, or if it can't be
/// loaded, so the router never has to guess where to send them.
class ProfileLoadingScreen extends ConsumerWidget {
  const ProfileLoadingScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profile = ref.watch(profileControllerProvider);
    final error = profile.isLoading ? null : profile.error;

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(AppSpacing.lg),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: error == null
                  ? Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const CircularProgressIndicator(),
                        const SizedBox(height: AppSpacing.md),
                        Text(
                          'Loading your profile…',
                          style: context.textTheme.bodyLarge,
                          textAlign: TextAlign.center,
                        ),
                      ],
                    )
                  : Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Icon(
                          Icons.cloud_off_outlined,
                          size: 48,
                          color: context.colors.primary,
                        ),
                        const SizedBox(height: AppSpacing.md),
                        Text(
                          "We couldn't load your profile",
                          style: context.textTheme.titleLarge,
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: AppSpacing.sm),
                        Text(
                          error is ProfileFailure
                              ? error.message
                              : 'Something went wrong. Please try again.',
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: AppSpacing.lg),
                        FilledButton(
                          onPressed: () => ref
                              .read(profileControllerProvider.notifier)
                              .reload(),
                          child: const Text('Try again'),
                        ),
                        const SizedBox(height: AppSpacing.sm),
                        TextButton(
                          onPressed: () => ref
                              .read(authControllerProvider.notifier)
                              .signOut(),
                          child: const Text('Sign out'),
                        ),
                      ],
                    ),
            ),
          ),
        ),
      ),
    );
  }
}
