import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../../../core/theme/app_spacing.dart';
import '../../../../shared/utils/context_extensions.dart';

/// One review photo, shown from memory. There is deliberately no gesture,
/// menu, save or share option, and the decoded image is evicted from
/// Flutter's image cache as soon as the widget goes away.
class ReviewPhoto extends StatefulWidget {
  const ReviewPhoto({
    super.key,
    required this.label,
    this.bytes,
    this.placeholder,
    this.loading = false,
  });

  final String label;
  final Uint8List? bytes;

  /// Shown instead of a photo, e.g. when none is on file.
  final String? placeholder;
  final bool loading;

  @override
  State<ReviewPhoto> createState() => _ReviewPhotoState();
}

class _ReviewPhotoState extends State<ReviewPhoto> {
  MemoryImage? _image;

  @override
  void initState() {
    super.initState();
    _image = _imageFor(widget.bytes);
  }

  @override
  void didUpdateWidget(ReviewPhoto oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.bytes, widget.bytes)) {
      _image?.evict();
      _image = _imageFor(widget.bytes);
    }
  }

  @override
  void dispose() {
    _image?.evict();
    _image = null;
    super.dispose();
  }

  static MemoryImage? _imageFor(Uint8List? bytes) =>
      bytes == null ? null : MemoryImage(bytes);

  @override
  Widget build(BuildContext context) {
    final image = _image;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(widget.label, style: context.textTheme.titleSmall),
        const SizedBox(height: AppSpacing.xs),
        AspectRatio(
          aspectRatio: 3 / 4,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(AppSpacing.radius),
            child: ColoredBox(
              color: context.colors.surfaceContainerHighest,
              child: switch ((image, widget.loading)) {
                (_, true) => const Center(child: CircularProgressIndicator()),
                (final MemoryImage image?, _) => Image(
                  image: image,
                  fit: BoxFit.contain,
                  gaplessPlayback: true,
                  semanticLabel: widget.label,
                ),
                _ => Center(
                  child: Padding(
                    padding: const EdgeInsets.all(AppSpacing.sm),
                    child: Text(
                      widget.placeholder ?? 'Not available',
                      textAlign: TextAlign.center,
                      style: context.textTheme.bodySmall,
                    ),
                  ),
                ),
              },
            ),
          ),
        ),
      ],
    );
  }
}
