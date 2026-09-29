import 'package:flutter/material.dart';

import '../../../../core/theme/app_spacing.dart';
import '../../../../shared/utils/context_extensions.dart';
import '../../../../core/router/back_navigation.dart';

/// Shared frame for auth screens: app title, screen heading and content,
/// centred and width-limited so it reads well on phones and tablets.
class AuthLayout extends StatelessWidget {
  const AuthLayout({
    super.key,
    required this.heading,
    this.subheading,
    required this.child,
  });

  final String heading;
  final String? subheading;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final back = appBackButton(context);

    return Scaffold(
      appBar: back == null
          ? null
          : AppBar(leading: back, automaticallyImplyLeading: false),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.lg,
              vertical: AppSpacing.xl,
            ),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'Grave Chemistry',
                    textAlign: TextAlign.center,
                    style: context.textTheme.headlineMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                      letterSpacing: 1.5,
                    ),
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  Center(
                    child: Container(
                      width: 48,
                      height: 2,
                      color: context.colors.primary,
                    ),
                  ),
                  const SizedBox(height: AppSpacing.xl),
                  Text(heading, style: context.textTheme.titleLarge),
                  if (subheading != null) ...[
                    const SizedBox(height: AppSpacing.xs),
                    Text(
                      subheading!,
                      style: context.textTheme.bodyMedium?.copyWith(
                        color: context.colors.onSurfaceVariant,
                      ),
                    ),
                  ],
                  const SizedBox(height: AppSpacing.lg),
                  child,
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
