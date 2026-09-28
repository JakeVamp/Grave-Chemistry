import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../core/router/app_routes.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../shared/utils/context_extensions.dart';

/// Temporary hub that links to every placeholder screen during early
/// development. Will be replaced once real navigation flows are designed.
class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  static const _destinations = <_Destination>[
    _Destination('Discovery', Icons.explore_outlined, AppRoutes.discovery),
    _Destination('Matches', Icons.favorite_border, AppRoutes.matches),
    _Destination('Messages', Icons.chat_bubble_outline, AppRoutes.messages),
    _Destination('Settings', Icons.settings_outlined, AppRoutes.settings),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Grave Chemistry')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(AppSpacing.md),
          children: [
            Text(
              'Foundation build',
              style: context.textTheme.titleMedium?.copyWith(
                color: context.colors.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: AppSpacing.md),
            for (final destination in _destinations)
              Card(
                child: ListTile(
                  leading: Icon(destination.icon),
                  title: Text(destination.label),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => context.push(destination.path),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _Destination {
  const _Destination(this.label, this.icon, this.path);

  final String label;
  final IconData icon;
  final String path;
}
