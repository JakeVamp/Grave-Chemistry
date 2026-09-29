import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/router/app_routes.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../shared/utils/context_extensions.dart';
import '../application/moderation_providers.dart';
import '../domain/photo_review_item.dart';
import 'widgets/review_facts.dart';
import '../../../core/router/back_navigation.dart';

/// Photos waiting for a moderator, oldest first. Child-safety matters never
/// appear here; the server leaves them out.
class PhotoReviewQueueScreen extends ConsumerWidget {
  const PhotoReviewQueueScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final queue = ref.watch(photoReviewQueueProvider);
    return Scaffold(
      appBar: AppBar(
        leading: appBackButton(context),
        automaticallyImplyLeading: false,
        title: const Text('Photo review'),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh),
            onPressed: () => ref.invalidate(photoReviewQueueProvider),
          ),
        ],
      ),
      body: SafeArea(
        child: switch (queue) {
          AsyncData(value: final items) when items.isEmpty => const _Empty(),
          AsyncData(value: final items) => ListView.builder(
            padding: const EdgeInsets.all(AppSpacing.md),
            itemCount: items.length,
            itemBuilder: (context, index) => _QueueTile(item: items[index]),
          ),
          AsyncError(:final error) => Center(
            child: Padding(
              padding: const EdgeInsets.all(AppSpacing.lg),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(moderationMessage(error), textAlign: TextAlign.center),
                  const SizedBox(height: AppSpacing.md),
                  FilledButton(
                    onPressed: () => ref.invalidate(photoReviewQueueProvider),
                    child: const Text('Try again'),
                  ),
                ],
              ),
            ),
          ),
          _ => const Center(child: CircularProgressIndicator()),
        },
      ),
    );
  }
}

class _QueueTile extends StatelessWidget {
  const _QueueTile({required this.item});

  final PhotoReviewItem item;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(AppSpacing.radius),
        onTap: () => context.push(AppRoutes.photoReviewItem(item.photoId)),
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.md),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      reviewSubjectTitle(item),
                      style: context.textTheme.titleMedium,
                    ),
                  ),
                  Text(
                    item.reviewState == ReviewState.processingFailed
                        ? 'Retry available'
                        : 'Needs review',
                    style: context.textTheme.labelMedium?.copyWith(
                      color: context.colors.onSurfaceVariant,
                    ),
                  ),
                  const Icon(Icons.chevron_right),
                ],
              ),
              const SizedBox(height: AppSpacing.sm),
              ReviewFacts(item: item),
            ],
          ),
        ),
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.task_alt,
              size: 48,
              color: context.colors.onSurfaceVariant,
            ),
            const SizedBox(height: AppSpacing.md),
            Text('All caught up', style: context.textTheme.titleMedium),
            const SizedBox(height: AppSpacing.xs),
            const Text(
              'No photos are waiting for review.',
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}
