import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme/app_spacing.dart';
import '../../../../shared/utils/context_extensions.dart';
import '../../application/profile_photo_providers.dart';
import '../../domain/profile_photo.dart';

enum PhotoAction { makePrimary, moveUp, moveDown, delete }

class ProfilePhotoTile extends StatelessWidget {
  const ProfilePhotoTile({
    super.key,
    required this.photo,
    required this.index,
    required this.count,
    required this.enabled,
    required this.onAction,
  });

  final ProfilePhoto photo;
  final int index;
  final int count;
  final bool enabled;
  final ValueChanged<PhotoAction> onAction;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: AppSpacing.sm),
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.sm),
        child: Row(
          children: [
            _Thumbnail(photo: photo),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Photo ${index + 1}',
                    style: context.textTheme.titleSmall,
                  ),
                  const SizedBox(height: AppSpacing.xs),
                  Wrap(
                    spacing: AppSpacing.xs,
                    runSpacing: AppSpacing.xs,
                    children: [
                      if (photo.isPrimary) const _Badge(label: 'Primary'),
                      _StatusBadge(status: photo.status),
                    ],
                  ),
                ],
              ),
            ),
            PopupMenuButton<PhotoAction>(
              enabled: enabled,
              tooltip: 'Photo ${index + 1} options',
              onSelected: onAction,
              itemBuilder: (context) => [
                if (!photo.isPrimary)
                  const PopupMenuItem(
                    value: PhotoAction.makePrimary,
                    child: Text('Make primary'),
                  ),
                if (index > 0)
                  const PopupMenuItem(
                    value: PhotoAction.moveUp,
                    child: Text('Move up'),
                  ),
                if (index < count - 1)
                  const PopupMenuItem(
                    value: PhotoAction.moveDown,
                    child: Text('Move down'),
                  ),
                const PopupMenuItem(
                  value: PhotoAction.delete,
                  child: Text('Delete'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _Thumbnail extends ConsumerWidget {
  const _Thumbnail({required this.photo});

  final ProfilePhoto photo;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final path = photo.objectPath;
    final url = path == null ? null : ref.watch(profilePhotoUrlProvider(path));
    final placeholder = ColoredBox(
      color: context.colors.surfaceContainerHighest,
      child: Icon(
        path == null ? Icons.hourglass_empty : Icons.image_outlined,
        color: context.colors.onSurfaceVariant,
      ),
    );

    return ClipRRect(
      borderRadius: BorderRadius.circular(AppSpacing.radius),
      child: SizedBox.square(
        dimension: 72,
        child: switch (url) {
          AsyncData(:final value?) => Image.network(
            value,
            fit: BoxFit.cover,
            semanticLabel: 'Profile photo',
            errorBuilder: (_, _, _) => placeholder,
          ),
          _ => placeholder,
        },
      ),
    );
  }
}

class _StatusBadge extends StatelessWidget {
  const _StatusBadge({required this.status});

  final PhotoReviewStatus status;

  @override
  Widget build(BuildContext context) {
    return switch (status) {
      PhotoReviewStatus.inReview => const _Badge(
        label: 'In review',
        icon: Icons.hourglass_top,
      ),
      PhotoReviewStatus.live => const _Badge(
        label: 'Live',
        icon: Icons.check_circle_outline,
      ),
      PhotoReviewStatus.notApproved => const _Badge(
        label: 'Not approved',
        icon: Icons.block,
        isWarning: true,
      ),
    };
  }
}

class _Badge extends StatelessWidget {
  const _Badge({required this.label, this.icon, this.isWarning = false});

  final String label;
  final IconData? icon;
  final bool isWarning;

  @override
  Widget build(BuildContext context) {
    final color = isWarning ? context.colors.error : context.colors.onSurface;
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.sm,
        vertical: AppSpacing.xs,
      ),
      decoration: BoxDecoration(
        border: Border.all(color: context.colors.outline),
        borderRadius: BorderRadius.circular(AppSpacing.radius),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 16, color: color),
            const SizedBox(width: AppSpacing.xs),
          ],
          Text(
            label,
            style: context.textTheme.labelMedium?.copyWith(color: color),
          ),
        ],
      ),
    );
  }
}
