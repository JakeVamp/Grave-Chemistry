import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/router/app_routes.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../shared/utils/context_extensions.dart';
import '../../../shared/widgets/message_banner.dart';
import '../application/moderation_providers.dart';
import '../data/screen_security.dart';
import '../domain/moderation_failure.dart';
import '../domain/moderator_note.dart';
import '../domain/photo_review_item.dart';
import '../domain/review_media.dart';
import 'widgets/review_dialogs.dart';
import 'widgets/review_facts.dart';
import 'widgets/review_photo.dart';
import '../../../core/router/back_navigation.dart';

/// Side-by-side review of one profile photo against the owner's approved
/// verification photo, by eye only: no face matching or scoring of any
/// kind. Screenshots are blocked where the platform allows it.
class PhotoReviewScreen extends ConsumerStatefulWidget {
  const PhotoReviewScreen({super.key, required this.photoId});

  final String photoId;

  @override
  ConsumerState<PhotoReviewScreen> createState() => _PhotoReviewScreenState();
}

class _PhotoReviewScreenState extends ConsumerState<PhotoReviewScreen> {
  late final ScreenSecurity _screenSecurity;
  ({String text, bool isError})? _message;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _screenSecurity = ref.read(screenSecurityProvider)..enable();
  }

  @override
  void dispose() {
    _screenSecurity.disable();
    super.dispose();
  }

  PhotoReviewController get _controller =>
      ref.read(photoReviewProvider(widget.photoId).notifier);

  /// Confirmation for consequential actions; approve and retry need none
  /// (the database still enforces every safety condition).
  Future<ConfirmedAction?> _confirm(ReviewAction action) => switch (action) {
    ReviewAction.approve ||
    ReviewAction.retry => Future.value(const ConfirmedAction()),
    ReviewAction.reject => confirmAction(
      context,
      title: 'Reject this photo?',
      message:
          'It will never be shown. The member sees only that it wasn’t '
          'approved.',
      confirmLabel: 'Reject',
    ),
    ReviewAction.remove => confirmAction(
      context,
      title: 'Remove this photo?',
      message:
          'It will be taken off the member’s profile and the file '
          'deleted.',
      confirmLabel: 'Remove',
    ),
    ReviewAction.requireReverification => confirmAction(
      context,
      title: 'Require re-verification?',
      message:
          'The member loses their verified status until they complete a '
          'new live photo verification.',
      confirmLabel: 'Require',
    ),
    ReviewAction.escalate => confirmEscalation(context),
  };

  Future<void> _perform(ReviewAction action) async {
    final confirmed = await _confirm(action);
    if (confirmed == null || !mounted) return;

    setState(() {
      _busy = true;
      _message = null;
    });
    final result = await _controller.perform(
      action,
      reason: confirmed.reason,
      category: confirmed.category,
    );
    if (!mounted) return;
    setState(() => _busy = false);

    switch (result) {
      case ReviewAdvanced(:final nextPhotoId):
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(_doneMessage(action))));
        if (nextPhotoId != null) {
          context.pushReplacement(AppRoutes.photoReviewItem(nextPhotoId));
        } else if (context.canPop()) {
          context.pop();
        } else {
          context.go(AppRoutes.photoReview);
        }
      case ReviewStayed(:final message, :final isError):
        setState(() => _message = (text: message, isError: isError));
    }
  }

  static String _doneMessage(ReviewAction action) => switch (action) {
    ReviewAction.approve => 'Photo approved.',
    ReviewAction.reject => 'Photo rejected.',
    ReviewAction.remove => 'Photo removed.',
    ReviewAction.retry => 'Processing restarted.',
    ReviewAction.escalate => 'Sent to child-safety review.',
    ReviewAction.requireReverification => 'Re-verification required.',
  };

  void _reload() {
    ref.invalidate(photoReviewProvider(widget.photoId));
    ref.invalidate(reviewMediaProvider(widget.photoId));
  }

  @override
  Widget build(BuildContext context) {
    final detail = ref.watch(photoReviewProvider(widget.photoId));

    return Scaffold(
      appBar: AppBar(
        leading: appBackButton(context),
        automaticallyImplyLeading: false,
        title: const Text('Review photo'),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh),
            onPressed: _busy ? null : _reload,
          ),
        ],
      ),
      body: SafeArea(
        child: switch (detail) {
          AsyncData(value: PhotoReviewDetail(item: null)) => _Unavailable(
            onBack: () {
              ref.invalidate(photoReviewQueueProvider);
              context.canPop()
                  ? context.pop()
                  : context.go(AppRoutes.photoReview);
            },
          ),
          AsyncData(value: PhotoReviewDetail(:final item?, :final notes)) =>
            _buildReview(context, item, notes),
          AsyncError(:final error) => _ErrorView(
            message: moderationMessage(error),
            onRetry: _reload,
          ),
          _ => const Center(child: CircularProgressIndicator()),
        },
      ),
    );
  }

  Widget _buildReview(
    BuildContext context,
    PhotoReviewItem item,
    List<ModeratorNote> notes,
  ) {
    final message = _message;
    return ListView(
      padding: const EdgeInsets.all(AppSpacing.md),
      children: [
        if (message != null) ...[
          MessageBanner(
            message: message.text,
            tone: message.isError ? MessageTone.error : MessageTone.info,
          ),
          const SizedBox(height: AppSpacing.md),
        ],
        if (!item.isOpen) ...[
          MessageBanner(
            message: item.reviewState == ReviewState.processing
                ? 'This photo is being processed again. It will return to '
                      'the queue if it needs a decision.'
                : 'This photo has already been handled.',
            tone: MessageTone.info,
          ),
          const SizedBox(height: AppSpacing.md),
        ],
        Text(reviewSubjectTitle(item), style: context.textTheme.titleLarge),
        const SizedBox(height: AppSpacing.md),
        if (item.isOpen) ...[
          _SideBySide(photoId: item.photoId),
          const SizedBox(height: AppSpacing.sm),
          Text(
            'Compare the photos by eye. No automated face matching is used.',
            style: context.textTheme.bodySmall?.copyWith(
              color: context.colors.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: AppSpacing.md),
        ],
        ReviewFacts(item: item),
        if (item.isOpen) ...[
          const SizedBox(height: AppSpacing.lg),
          _Actions(item: item, busy: _busy, onAction: _perform),
        ],
        const SizedBox(height: AppSpacing.lg),
        _Notes(photoId: item.photoId, notes: notes, enabled: !_busy),
      ],
    );
  }
}

class _SideBySide extends ConsumerWidget {
  const _SideBySide({required this.photoId});

  final String photoId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Only built for open items, so decided photos are never fetched.
    final media = ref.watch(reviewMediaProvider(photoId));
    // If the photos can't be loaded (e.g. the item was escalated or the
    // session lost MFA), re-check the item so the screen shows its state.
    ref.listen(reviewMediaProvider(photoId), (_, next) async {
      if (next case AsyncError(:final error)) {
        if (error is ModerationFailure &&
            error.type == ModerationFailureType.notAuthorized) {
          ref.invalidate(moderatorMfaProvider);
        }
        try {
          await ref.read(photoReviewProvider(photoId).notifier).refresh();
        } on ModerationFailure {
          // The media error is already shown.
        }
      }
    });
    return switch (media) {
      AsyncData(value: final media) => _photos(media: media),
      // Fail closed: no photos at all, only the error and a reload.
      AsyncError(:final error) => MessageBanner(
        message: moderationMessage(error),
        action: TextButton(
          onPressed: () => ref.invalidate(reviewMediaProvider(photoId)),
          child: const Text('Reload photos'),
        ),
      ),
      _ => _photos(loading: true),
    };
  }

  Widget _photos({ReviewMedia? media, bool loading = false}) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: ReviewPhoto(
            label: 'Profile photo',
            bytes: media?.profilePhoto,
            loading: loading,
          ),
        ),
        const SizedBox(width: AppSpacing.sm),
        Expanded(
          child: ReviewPhoto(
            label: 'Verification photo',
            bytes: media?.verificationPhoto,
            loading: loading,
            placeholder: switch (media?.verification) {
              VerificationPhotoAvailability.none =>
                'No approved verification photo on file',
              _ => 'Verification photo couldn’t be loaded',
            },
          ),
        ),
      ],
    );
  }
}

class _Actions extends StatelessWidget {
  const _Actions({
    required this.item,
    required this.busy,
    required this.onAction,
  });

  final PhotoReviewItem item;
  final bool busy;
  final void Function(ReviewAction action) onAction;

  @override
  Widget build(BuildContext context) {
    VoidCallback? on(ReviewAction action, {bool enabled = true}) =>
        busy || !enabled ? null : () => onAction(action);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Decision', style: context.textTheme.titleMedium),
        const SizedBox(height: AppSpacing.sm),
        if (busy) const LinearProgressIndicator(),
        Wrap(
          spacing: AppSpacing.sm,
          runSpacing: AppSpacing.sm,
          children: [
            FilledButton(
              onPressed: on(ReviewAction.approve, enabled: item.canApprove),
              child: const Text('Approve'),
            ),
            OutlinedButton(
              onPressed: on(ReviewAction.reject),
              child: const Text('Reject'),
            ),
            OutlinedButton(
              onPressed: on(ReviewAction.remove),
              child: const Text('Remove'),
            ),
            if (item.canRetry)
              OutlinedButton(
                onPressed: on(ReviewAction.retry),
                child: const Text('Retry processing'),
              ),
            OutlinedButton(
              onPressed: on(ReviewAction.requireReverification),
              child: const Text('Require re-verification'),
            ),
            TextButton.icon(
              style: TextButton.styleFrom(
                foregroundColor: context.colors.error,
              ),
              onPressed: on(ReviewAction.escalate),
              icon: const Icon(Icons.shield_outlined),
              label: const Text('Escalate to child safety'),
            ),
          ],
        ),
        if (!item.canApprove)
          Padding(
            padding: const EdgeInsets.only(top: AppSpacing.sm),
            child: Text(
              item.reviewState == ReviewState.processingFailed
                  ? 'Processing failed, so this photo can’t be approved. '
                        'Retry processing or reject it.'
                  : 'This photo can’t be approved.',
              style: context.textTheme.bodySmall,
            ),
          ),
      ],
    );
  }
}

class _Notes extends ConsumerStatefulWidget {
  const _Notes({
    required this.photoId,
    required this.notes,
    required this.enabled,
  });

  final String photoId;
  final List<ModeratorNote> notes;
  final bool enabled;

  @override
  ConsumerState<_Notes> createState() => _NotesState();
}

class _NotesState extends ConsumerState<_Notes> {
  final _note = TextEditingController();
  String? _error;
  bool _saving = false;

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  Future<void> _add() async {
    final body = _note.text.trim();
    if (body.isEmpty) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await ref
          .read(photoReviewProvider(widget.photoId).notifier)
          .addNote(body);
      _note.clear();
    } on ModerationFailure catch (failure) {
      if (mounted) setState(() => _error = failure.message);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  static String _timestamp(DateTime time) {
    final local = time.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${local.year}-${two(local.month)}-${two(local.day)} '
        '${two(local.hour)}:${two(local.minute)}';
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Moderator notes', style: context.textTheme.titleMedium),
        const SizedBox(height: AppSpacing.xs),
        Text(
          'Only moderators can see notes, and they can’t be edited. Don’t '
          'add links or child-safety details: escalate instead.',
          style: context.textTheme.bodySmall?.copyWith(
            color: context.colors.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: AppSpacing.sm),
        if (widget.notes.isEmpty) const Text('No notes yet.'),
        for (final note in widget.notes)
          Card(
            child: ListTile(
              title: Text(note.body),
              subtitle: Text('Moderator · ${_timestamp(note.createdAt)}'),
            ),
          ),
        const SizedBox(height: AppSpacing.sm),
        TextField(
          controller: _note,
          maxLength: ModeratorNote.maxLength,
          minLines: 1,
          maxLines: 4,
          decoration: const InputDecoration(labelText: 'Add a note'),
        ),
        if (_error != null) MessageBanner(message: _error!),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton(
            onPressed: widget.enabled && !_saving ? _add : null,
            child: const Text('Save note'),
          ),
        ),
      ],
    );
  }
}

class _Unavailable extends StatelessWidget {
  const _Unavailable({required this.onBack});

  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'This photo is no longer available for review.',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: AppSpacing.md),
            FilledButton(onPressed: onBack, child: const Text('Back to queue')),
          ],
        ),
      ),
    );
  }
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.message, required this.onRetry});

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
