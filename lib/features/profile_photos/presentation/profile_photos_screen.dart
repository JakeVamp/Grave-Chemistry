import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_spacing.dart';
import '../../../shared/utils/context_extensions.dart';
import '../../../shared/widgets/message_banner.dart';
import '../application/profile_photo_providers.dart';
import '../domain/profile_photo.dart';
import '../domain/profile_photo_failure.dart';
import 'widgets/profile_photo_tile.dart';
import '../../../core/router/back_navigation.dart';

/// Manage public profile photos: add, order, choose the primary, delete.
/// Every photo is reviewed before anyone else can see it.
class ProfilePhotosScreen extends ConsumerStatefulWidget {
  const ProfilePhotosScreen({super.key});

  @override
  ConsumerState<ProfilePhotosScreen> createState() =>
      _ProfilePhotosScreenState();
}

class _ProfilePhotosScreenState extends ConsumerState<ProfilePhotosScreen> {
  String? _actionError;
  bool _working = false;

  Future<void> _run(Future<void> Function() action) async {
    setState(() {
      _working = true;
      _actionError = null;
    });
    try {
      await action();
    } on ProfilePhotoFailure catch (failure) {
      if (mounted) setState(() => _actionError = failure.message);
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _onAction(
    List<ProfilePhoto> photos,
    int index,
    PhotoAction action,
  ) async {
    final controller = ref.read(profilePhotosProvider.notifier);
    final photo = photos[index];
    switch (action) {
      case PhotoAction.makePrimary:
        await _run(() => controller.setPrimary(photo.id));
      case PhotoAction.moveUp:
        await _run(() => controller.move(index, index - 1));
      case PhotoAction.moveDown:
        await _run(() => controller.move(index, index + 1));
      case PhotoAction.delete:
        final confirmed = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Delete this photo?'),
            content: const Text('It will be removed from your profile.'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Delete'),
              ),
            ],
          ),
        );
        if (confirmed ?? false) await _run(() => controller.delete(photo.id));
    }
  }

  @override
  Widget build(BuildContext context) {
    final photos = ref.watch(profilePhotosProvider);
    final upload = ref.watch(photoUploadProvider);
    final uploader = ref.read(photoUploadProvider.notifier);

    return Scaffold(
      appBar: AppBar(
        leading: appBackButton(context),
        automaticallyImplyLeading: false,
        title: const Text('Profile photos'),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh),
            onPressed: _working
                ? null
                : () => _run(
                    () => ref.read(profilePhotosProvider.notifier).refresh(),
                  ),
          ),
        ],
      ),
      body: SafeArea(
        child: switch (photos) {
          AsyncData(value: final list) => _buildList(
            context,
            list,
            upload,
            uploader,
          ),
          AsyncError() => Center(
            child: Padding(
              padding: const EdgeInsets.all(AppSpacing.lg),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text("We couldn't load your photos."),
                  const SizedBox(height: AppSpacing.md),
                  FilledButton(
                    onPressed: () => ref.invalidate(profilePhotosProvider),
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

  Widget _buildList(
    BuildContext context,
    List<ProfilePhoto> photos,
    PhotoUploadState upload,
    PhotoUploadController uploader,
  ) {
    final atLimit = photos.length >= ProfilePhotoLimits.maxPhotos;
    final busy = _working || upload.isBusy;

    return ReorderableListView.builder(
      padding: const EdgeInsets.all(AppSpacing.md),
      buildDefaultDragHandles: !busy,
      header: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Add up to ${ProfilePhotoLimits.maxPhotos} photos. Each one is '
            'reviewed before anyone else can see it. Your verification photo '
            'is never used here.',
            style: context.textTheme.bodyMedium?.copyWith(
              color: context.colors.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(
            '${photos.length} of ${ProfilePhotoLimits.maxPhotos} photos',
            style: context.textTheme.titleSmall,
          ),
          if (upload.isBusy) ...[
            const SizedBox(height: AppSpacing.md),
            Semantics(
              liveRegion: true,
              label: upload.label,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(upload.label),
                  const SizedBox(height: AppSpacing.xs),
                  LinearProgressIndicator(value: upload.progress),
                ],
              ),
            ),
          ],
          if (upload.failure != null) ...[
            const SizedBox(height: AppSpacing.md),
            MessageBanner(
              message: upload.failure!.message,
              action: Wrap(
                alignment: WrapAlignment.end,
                children: [
                  if (upload.canRetry)
                    TextButton(
                      onPressed: uploader.retry,
                      child: const Text('Try again'),
                    ),
                  TextButton(
                    onPressed: uploader.dismissFailure,
                    child: const Text('Dismiss'),
                  ),
                ],
              ),
            ),
          ],
          if (_actionError != null) ...[
            const SizedBox(height: AppSpacing.md),
            MessageBanner(message: _actionError!),
          ],
          if (photos.isEmpty) ...[
            const SizedBox(height: AppSpacing.xl),
            Text(
              'No photos yet.',
              textAlign: TextAlign.center,
              style: context.textTheme.bodyLarge,
            ),
          ],
          const SizedBox(height: AppSpacing.md),
        ],
      ),
      itemCount: photos.length,
      onReorderItem: (from, to) {
        if (busy) return;
        _run(() => ref.read(profilePhotosProvider.notifier).move(from, to));
      },
      itemBuilder: (context, index) => ProfilePhotoTile(
        key: ValueKey(photos[index].id),
        photo: photos[index],
        index: index,
        count: photos.length,
        enabled: !busy,
        onAction: (action) => _onAction(photos, index, action),
      ),
      footer: Padding(
        padding: const EdgeInsets.only(top: AppSpacing.md),
        child: FilledButton.icon(
          onPressed: busy || atLimit ? null : uploader.pickAndUpload,
          icon: const Icon(Icons.add_photo_alternate_outlined),
          label: Text(atLimit ? 'Photo limit reached' : 'Add photo'),
        ),
      ),
    );
  }
}
