import 'package:flutter/material.dart';

import '../core/theme/app_spacing.dart';
import '../core/theme/app_theme.dart';

/// Shown instead of the real app when required build-time configuration is
/// missing, so a misconfigured build fails loudly rather than crashing.
class ConfigurationErrorApp extends StatelessWidget {
  const ConfigurationErrorApp({super.key, required this.errors});

  final List<String> errors;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Grave Chemistry',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.dark,
      home: Builder(
        builder: (context) {
          final textTheme = Theme.of(context).textTheme;
          return Scaffold(
            body: SafeArea(
              child: ListView(
                padding: const EdgeInsets.all(AppSpacing.lg),
                children: [
                  Text('Configuration error', style: textTheme.headlineSmall),
                  const SizedBox(height: AppSpacing.md),
                  for (final error in errors)
                    Padding(
                      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                      child: Text('• $error'),
                    ),
                  const SizedBox(height: AppSpacing.md),
                  Text(
                    'Run the app with '
                    '--dart-define-from-file=env/dev.json. '
                    'See README.md for setup instructions.',
                    style: textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}
