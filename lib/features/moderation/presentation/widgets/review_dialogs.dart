import 'package:flutter/material.dart';

import '../../../../core/theme/app_spacing.dart';
import '../../domain/moderation_repository.dart';

/// Result of a confirmation dialog: the optional internal reason.
class ConfirmedAction {
  const ConfirmedAction({this.reason, this.category});

  final String? reason;
  final ChildSafetyCategory? category;
}

/// Asks the moderator to confirm a consequential action. Returns null when
/// cancelled.
Future<ConfirmedAction?> confirmAction(
  BuildContext context, {
  required String title,
  required String message,
  required String confirmLabel,
}) {
  return showDialog<ConfirmedAction>(
    context: context,
    builder: (context) => _ConfirmDialog(
      title: title,
      message: message,
      confirmLabel: confirmLabel,
    ),
  );
}

class _ConfirmDialog extends StatefulWidget {
  const _ConfirmDialog({
    required this.title,
    required this.message,
    required this.confirmLabel,
  });

  final String title;
  final String message;
  final String confirmLabel;

  @override
  State<_ConfirmDialog> createState() => _ConfirmDialogState();
}

class _ConfirmDialogState extends State<_ConfirmDialog> {
  final _reason = TextEditingController();

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(widget.message),
            const SizedBox(height: AppSpacing.md),
            TextField(
              controller: _reason,
              maxLength: 500,
              decoration: const InputDecoration(
                labelText: 'Reason (optional, moderators only)',
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () =>
              Navigator.pop(context, ConfirmedAction(reason: _reason.text)),
          child: Text(widget.confirmLabel),
        ),
      ],
    );
  }
}

/// Escalation to child-safety review, with the category.
Future<ConfirmedAction?> confirmEscalation(BuildContext context) {
  return showDialog<ConfirmedAction>(
    context: context,
    builder: (context) => const _EscalationDialog(),
  );
}

class _EscalationDialog extends StatefulWidget {
  const _EscalationDialog();

  @override
  State<_EscalationDialog> createState() => _EscalationDialogState();
}

class _EscalationDialogState extends State<_EscalationDialog> {
  ChildSafetyCategory? _category;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Escalate to child safety?'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'The photo will be hidden immediately, the account will be '
              'held, and the case goes to child-safety reviewers. It will '
              'leave your queue and you won’t be able to open it again.',
            ),
            const SizedBox(height: AppSpacing.md),
            RadioGroup<ChildSafetyCategory>(
              groupValue: _category,
              onChanged: (value) => setState(() => _category = value),
              child: Column(
                children: [
                  for (final category in ChildSafetyCategory.values)
                    RadioListTile<ChildSafetyCategory>(
                      value: category,
                      title: Text(category.label),
                      contentPadding: EdgeInsets.zero,
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: _category == null
              ? null
              : () => Navigator.pop(
                  context,
                  ConfirmedAction(category: _category),
                ),
          child: const Text('Escalate'),
        ),
      ],
    );
  }
}
