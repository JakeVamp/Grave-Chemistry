import 'package:flutter/material.dart';

import '../../../../core/theme/app_spacing.dart';
import '../../../../shared/utils/context_extensions.dart';
import '../../../profile/domain/verification_status.dart';
import '../../domain/photo_review_item.dart';

/// Review-relevant facts about a photo as labelled chips. Built only from
/// the coarse flags the server returns: never hashes, paths or provider
/// data.
class ReviewFacts extends StatelessWidget {
  const ReviewFacts({super.key, required this.item});

  final PhotoReviewItem item;

  static String verificationLabel(VerificationStatus? status) =>
      switch (status) {
        VerificationStatus.verified => 'Verified',
        VerificationStatus.pending => 'Verification pending',
        VerificationStatus.rejected => 'Verification rejected',
        VerificationStatus.expired => 'Verification expired',
        VerificationStatus.reverificationRequired => 'Re-verification required',
        VerificationStatus.notStarted || null => 'Not verified',
      };

  @override
  Widget build(BuildContext context) {
    final warnings = <String>[
      if (item.duplicateMatch == DuplicateMatch.exact)
        'Same photo as another account',
      if (item.duplicateMatch == DuplicateMatch.similar)
        'Similar to another account’s photo',
      if (item.hasReviewSignals) 'Account has review signals',
      if (item.contentFlagged) 'Flagged by automated moderation',
      if (item.reviewState == ReviewState.processingFailed) 'Processing failed',
      if (item.automatedChecksIncomplete) 'Automated checks incomplete',
    ];
    return Wrap(
      spacing: AppSpacing.sm,
      runSpacing: AppSpacing.sm,
      children: [
        _Fact(
          icon: item.verificationStatus == VerificationStatus.verified
              ? Icons.verified_outlined
              : Icons.help_outline,
          label: verificationLabel(item.verificationStatus),
        ),
        for (final warning in warnings)
          _Fact(icon: Icons.flag_outlined, label: warning, warning: true),
      ],
    );
  }
}

class _Fact extends StatelessWidget {
  const _Fact({required this.icon, required this.label, this.warning = false});

  final IconData icon;
  final String label;
  final bool warning;

  @override
  Widget build(BuildContext context) {
    final color = warning ? context.colors.error : context.colors.onSurface;
    return Chip(
      avatar: Icon(icon, size: 18, color: color),
      label: Text(label),
      visualDensity: VisualDensity.compact,
    );
  }
}

/// "Alice, 36" or a neutral fallback.
String reviewSubjectTitle(PhotoReviewItem item) {
  final name = item.displayName?.trim();
  final who = name == null || name.isEmpty ? 'Unnamed member' : name;
  return item.age == null ? who : '$who, ${item.age}';
}
