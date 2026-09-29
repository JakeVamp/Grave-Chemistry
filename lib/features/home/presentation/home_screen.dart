import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/router/app_routes.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../shared/utils/context_extensions.dart';
import '../../auth/application/auth_providers.dart';
import '../../auth/domain/auth_status.dart';

/// Temporary hub that links to every placeholder screen during early
/// development. Will be replaced once real navigation flows are designed.
class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  static const _destinations = <_Destination>[
    _Destination(
      'Profile photos',
      Icons.photo_library_outlined,
      AppRoutes.profilePhotos,
    ),
    _Destination('Discovery', Icons.explore_outlined, AppRoutes.discovery),
    _Destination('Matches', Icons.favorite_border, AppRoutes.matches),
    _Destination('Messages', Icons.chat_bubble_outline, AppRoutes.messages),
    _Destination('Settings', Icons.settings_outlined, AppRoutes.settings),
  ];

  /// Shown only to moderators. Navigation only: the database checks the
  /// moderator role and MFA on every moderator request.
  static const _moderatorDestination = _Destination(
    'Moderator tools',
    Icons.admin_panel_settings_outlined,
    AppRoutes.moderation,
  );

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isModerator = switch (ref.watch(authControllerProvider)) {
      SignedIn(:final user) => user.isModerator,
      _ => false,
    };
    final destinations = [
      ..._destinations,
      if (isModerator) _moderatorDestination,
    ];
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
            for (final destination in destinations)
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
