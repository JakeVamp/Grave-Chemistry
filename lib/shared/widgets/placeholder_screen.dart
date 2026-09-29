import 'package:flutter/material.dart';

import '../../core/theme/app_spacing.dart';
import '../utils/context_extensions.dart';
import '../../core/router/back_navigation.dart';

/// Temporary scaffold for screens whose features are not built yet.
class PlaceholderScreen extends StatelessWidget {
  const PlaceholderScreen({
    super.key,
    required this.title,
    required this.icon,
    required this.message,
    this.actions = const [],
  });

  final String title;
  final IconData icon;
  final String message;

  /// Optional widgets (usually buttons) shown below the message.
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: appBackButton(context),
        automaticallyImplyLeading: false,
        title: Text(title),
      ),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(AppSpacing.lg),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 64, color: context.colors.primary),
                const SizedBox(height: AppSpacing.md),
                Text(
                  title,
                  style: context.textTheme.headlineSmall,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: AppSpacing.sm),
                Text(
                  message,
                  style: context.textTheme.bodyMedium?.copyWith(
                    color: context.colors.onSurfaceVariant,
                  ),
                  textAlign: TextAlign.center,
                ),
                if (actions.isNotEmpty) ...[
                  const SizedBox(height: AppSpacing.xl),
                  for (final action in actions) ...[
                    action,
                    const SizedBox(height: AppSpacing.sm),
                  ],
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
