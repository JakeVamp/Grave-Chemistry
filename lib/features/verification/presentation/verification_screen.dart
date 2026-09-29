import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_spacing.dart';
import '../../../shared/utils/context_extensions.dart';
import '../../../shared/widgets/loading_button.dart';
import '../../../shared/widgets/message_banner.dart';
import '../../auth/application/auth_providers.dart';
import '../../profile/application/profile_providers.dart';
import '../../profile/domain/verification_status.dart';
import '../application/verification_flow_controller.dart';
import '../application/verification_flow_state.dart';
import '../application/verification_providers.dart';
import '../domain/camera_permission.dart';
import '../../../core/router/back_navigation.dart';

/// Live photo verification, the last onboarding step. Photos come only from
/// the live camera; there is no photo-library option.
class VerificationScreen extends ConsumerStatefulWidget {
  const VerificationScreen({super.key, this.isRetry = false});

  /// True after a rejected, expired or revoked verification.
  final bool isRetry;

  @override
  ConsumerState<VerificationScreen> createState() => _VerificationScreenState();
}

class _VerificationScreenState extends ConsumerState<VerificationScreen>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState lifecycle) {
    final controller = ref.read(verificationFlowProvider.notifier);
    switch (lifecycle) {
      case AppLifecycleState.inactive || AppLifecycleState.paused:
        controller.onAppPaused();
      case AppLifecycleState.resumed:
        controller.onAppResumed();
      case AppLifecycleState.detached || AppLifecycleState.hidden:
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    final flow = ref.watch(verificationFlowProvider);
    final controller = ref.read(verificationFlowProvider.notifier);

    if (flow is VerificationCapturing) {
      return _CaptureView(state: flow, controller: controller);
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Verify your account'),
        leading: appBackButton(context),
        automaticallyImplyLeading: false,
        actions: [
          TextButton(
            onPressed: () =>
                ref.read(authControllerProvider.notifier).signOut(),
            child: const Text('Sign out'),
          ),
        ],
      ),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(AppSpacing.lg),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: switch (flow) {
                VerificationIntro() => _IntroView(
                  isRetry: widget.isRetry,
                  status: ref
                      .watch(profileControllerProvider)
                      .value
                      ?.verificationStatus,
                  onStart: controller.begin,
                ),
                VerificationWorking(:final message) => _ProgressView(
                  message: message,
                ),
                VerificationSubmitted() => const _ProgressView(
                  message: 'Photo submitted…',
                ),
                VerificationPermissionBlocked(:final status) => _PermissionView(
                  status: status,
                  controller: controller,
                ),
                VerificationReviewing() || VerificationSubmitting() =>
                  _ReviewView(state: flow, controller: controller),
                VerificationFailed() => _FailureView(
                  state: flow,
                  controller: controller,
                ),
                VerificationCapturing() => const SizedBox.shrink(),
              },
            ),
          ),
        ),
      ),
    );
  }
}

class _IntroView extends StatelessWidget {
  const _IntroView({
    required this.isRetry,
    required this.status,
    required this.onStart,
  });

  final bool isRetry;
  final VerificationStatus? status;
  final VoidCallback onStart;

  String? get _retryMessage {
    if (!isRetry) return null;
    return switch (status) {
      VerificationStatus.expired =>
        'Your verification has expired. Please take a new live photo.',
      VerificationStatus.reverificationRequired =>
        'We need you to verify your account again.',
      _ =>
        "Your last verification photo couldn't be approved. Please try "
            'again, making sure your face is clearly visible and well lit.',
    };
  }

  @override
  Widget build(BuildContext context) {
    final retryMessage = _retryMessage;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (retryMessage != null) ...[
          MessageBanner(message: retryMessage),
          const SizedBox(height: AppSpacing.lg),
        ],
        Icon(
          Icons.verified_user_outlined,
          size: 56,
          color: context.colors.primary,
        ),
        const SizedBox(height: AppSpacing.md),
        Text(
          'A quick live photo',
          style: context.textTheme.headlineSmall,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: AppSpacing.sm),
        Text(
          'Grave Chemistry requires a live photo to help reduce fake profiles '
          'and impersonation.',
          style: context.textTheme.bodyLarge,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: AppSpacing.lg),
        const _Point(
          icon: Icons.photo_camera_front_outlined,
          text:
              "You'll take one photo with your camera, right now. Photos from "
              'your library can’t be used.',
        ),
        const _Point(
          icon: Icons.face_retouching_natural_outlined,
          text: "We'll show a simple instruction, like turning your head.",
        ),
        const _Point(
          icon: Icons.lock_outline,
          text:
              'Your verification photo is private. It is never shown on your '
              'profile.',
        ),
        const _Point(
          icon: Icons.hourglass_empty,
          text:
              "We'll review your photo. Your account is verified only once "
              "it's approved.",
        ),
        const SizedBox(height: AppSpacing.lg),
        FilledButton(
          onPressed: onStart,
          child: const Text('Start verification'),
        ),
        const SizedBox(height: AppSpacing.sm),
        Text(
          "We'll ask for camera access when you start.",
          style: context.textTheme.bodySmall,
          textAlign: TextAlign.center,
        ),
      ],
    );
  }
}

class _Point extends StatelessWidget {
  const _Point({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.md),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: context.colors.onSurfaceVariant),
          const SizedBox(width: AppSpacing.md),
          Expanded(child: Text(text)),
        ],
      ),
    );
  }
}

class _ProgressView extends StatelessWidget {
  const _ProgressView({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox(height: AppSpacing.xl),
        const CircularProgressIndicator(),
        const SizedBox(height: AppSpacing.md),
        Semantics(
          liveRegion: true,
          child: Text(message, textAlign: TextAlign.center),
        ),
      ],
    );
  }
}

class _PermissionView extends StatelessWidget {
  const _PermissionView({required this.status, required this.controller});

  final CameraPermissionStatus status;
  final VerificationFlowController controller;

  @override
  Widget build(BuildContext context) {
    final (message, buttons) = switch (status) {
      CameraPermissionStatus.permanentlyDenied => (
        'Camera access is turned off for Grave Chemistry. To verify your '
            'account, turn on Camera for Grave Chemistry in Settings, then '
            'come back and try again.',
        [
          FilledButton(
            onPressed: controller.openSettings,
            child: const Text('Open Settings'),
          ),
          OutlinedButton(
            onPressed: controller.begin,
            child: const Text('Try again'),
          ),
        ],
      ),
      CameraPermissionStatus.restricted => (
        'Camera access is restricted on this device, for example by parental '
            'controls or a device policy. Verification needs the camera.',
        [
          OutlinedButton(
            onPressed: controller.begin,
            child: const Text('Try again'),
          ),
        ],
      ),
      _ => (
        'Camera access is needed to take your live verification photo. It is '
            'used only for account verification.',
        [
          FilledButton(
            onPressed: controller.begin,
            child: const Text('Allow camera access'),
          ),
        ],
      ),
    };

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Icon(
          Icons.no_photography_outlined,
          size: 48,
          color: context.colors.primary,
        ),
        const SizedBox(height: AppSpacing.md),
        Text(
          'Camera access needed',
          style: context.textTheme.titleLarge,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: AppSpacing.sm),
        Text(message, textAlign: TextAlign.center),
        const SizedBox(height: AppSpacing.lg),
        for (final button in buttons) ...[
          button,
          const SizedBox(height: AppSpacing.sm),
        ],
      ],
    );
  }
}

class _CaptureView extends StatelessWidget {
  const _CaptureView({required this.state, required this.controller});

  final VerificationCapturing state;
  final VerificationFlowController controller;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Take your photo'),
        leading: IconButton(
          tooltip: 'Cancel',
          icon: const Icon(Icons.close),
          onPressed: state.takingPhoto ? null : controller.cancel,
        ),
      ),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(AppSpacing.md),
              child: Semantics(
                liveRegion: true,
                label: 'Instruction',
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(AppSpacing.md),
                  decoration: BoxDecoration(
                    color: context.colors.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(AppSpacing.radius),
                  ),
                  child: Text(
                    state.session.instruction,
                    style: context.textTheme.titleMedium,
                    textAlign: TextAlign.center,
                  ),
                ),
              ),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(AppSpacing.radius),
                  child: Center(child: state.camera.buildPreview()),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(AppSpacing.lg),
              child: LoadingButton(
                label: 'Take photo',
                isLoading: state.takingPhoto,
                onPressed: controller.capture,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ReviewView extends StatelessWidget {
  const _ReviewView({required this.state, required this.controller});

  final VerificationFlowState state;
  final VerificationFlowController controller;

  @override
  Widget build(BuildContext context) {
    final (photo, submitting) = switch (state) {
      VerificationReviewing(:final photo) => (photo, false),
      VerificationSubmitting(:final photo) => (photo, true),
      _ => throw StateError('not reviewing'),
    };

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Use this photo?',
          style: context.textTheme.titleLarge,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: AppSpacing.sm),
        Text(
          'Make sure your face is clearly visible and well lit.',
          textAlign: TextAlign.center,
          style: context.textTheme.bodyMedium?.copyWith(
            color: context.colors.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: AppSpacing.md),
        ClipRRect(
          borderRadius: BorderRadius.circular(AppSpacing.radius),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 420),
            child: Image.memory(
              photo,
              fit: BoxFit.contain,
              semanticLabel: 'Your verification photo',
              gaplessPlayback: true,
            ),
          ),
        ),
        const SizedBox(height: AppSpacing.lg),
        LoadingButton(
          label: 'Submit photo',
          isLoading: submitting,
          onPressed: controller.submit,
        ),
        const SizedBox(height: AppSpacing.sm),
        OutlinedButton(
          onPressed: submitting ? null : controller.retake,
          child: const Text('Retake'),
        ),
      ],
    );
  }
}

class _FailureView extends StatelessWidget {
  const _FailureView({required this.state, required this.controller});

  final VerificationFailed state;
  final VerificationFlowController controller;

  @override
  Widget build(BuildContext context) {
    final buttons = <Widget>[
      if (state.photo != null) ...[
        FilledButton(
          onPressed: controller.submit,
          child: const Text('Try again'),
        ),
        OutlinedButton(
          onPressed: controller.retake,
          child: const Text('Retake photo'),
        ),
      ] else if (state.session != null)
        FilledButton(
          onPressed: controller.retake,
          child: const Text('Try again'),
        )
      else ...[
        FilledButton(
          onPressed: controller.begin,
          child: const Text('Start again'),
        ),
        OutlinedButton(onPressed: controller.cancel, child: const Text('Back')),
      ],
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        MessageBanner(message: state.failure.message),
        const SizedBox(height: AppSpacing.lg),
        for (final button in buttons) ...[
          button,
          const SizedBox(height: AppSpacing.sm),
        ],
      ],
    );
  }
}
