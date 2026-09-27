import 'package:flutter/material.dart';

import '../../../../core/theme/app_spacing.dart';
import '../../../../shared/utils/context_extensions.dart';

enum AuthMessageTone { error, info }

/// Inline banner for errors and confirmations on auth screens.
class AuthMessage extends StatelessWidget {
  const AuthMessage({
    super.key,
    required this.message,
    this.tone = AuthMessageTone.error,
    this.action,
  });

  final String message;
  final AuthMessageTone tone;

  /// Optional follow-up, e.g. a "Resend email" button.
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final isError = tone == AuthMessageTone.error;
    final accent = isError ? context.colors.error : context.colors.primary;

    return Semantics(
      liveRegion: true,
      child: Container(
        padding: const EdgeInsets.all(AppSpacing.md),
        decoration: BoxDecoration(
          color: accent.withValues(alpha: 0.12),
          border: Border.all(color: accent.withValues(alpha: 0.6)),
          borderRadius: BorderRadius.circular(AppSpacing.radius),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  isError
                      ? Icons.error_outline
                      : Icons.mark_email_read_outlined,
                  color: accent,
                  size: 20,
                ),
                const SizedBox(width: AppSpacing.sm),
                Expanded(child: Text(message)),
              ],
            ),
            if (action != null)
              Align(alignment: Alignment.centerRight, child: action),
          ],
        ),
      ),
    );
  }
}
