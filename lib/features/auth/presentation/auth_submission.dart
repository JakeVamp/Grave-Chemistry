import 'package:flutter/widgets.dart';

import '../domain/auth_failure.dart';

/// Loading and error state for a screen that submits one auth request at a
/// time.
mixin AuthSubmission<T extends StatefulWidget> on State<T> {
  bool isSubmitting = false;
  AuthFailure? failure;

  /// Runs [action], tracking loading state. Returns whether it succeeded.
  Future<bool> submit(Future<void> Function() action) async {
    if (isSubmitting) return false;
    setState(() {
      isSubmitting = true;
      failure = null;
    });
    try {
      await action();
      return true;
    } on AuthFailure catch (error) {
      if (mounted) setState(() => failure = error);
      return false;
    } finally {
      if (mounted) setState(() => isSubmitting = false);
    }
  }
}
