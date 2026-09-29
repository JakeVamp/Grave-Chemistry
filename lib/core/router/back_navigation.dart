import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../features/auth/application/auth_providers.dart';
import '../../features/auth/domain/auth_status.dart';
import '../../features/profile/application/profile_providers.dart';
import 'app_routes.dart';
import 'auth_guard.dart';

/// Where Back leads from [path]: its parent screen, but only if the router
/// would let this user in there right now. Back therefore can't skip
/// onboarding, verification, moderator checks or account restrictions, and
/// can't start a redirect loop. Null means no Back (a root screen, or the
/// parent is gated).
String? backTargetFor(AuthStatus status, OnboardingGate gate, String path) {
  final parent = AppRoutes.parentOf(path);
  if (parent == null || parent == path) return null;
  return authGuard(status, gate, parent) == null ? parent : null;
}

/// Wraps every routed page. Provides the Back target to [appBackButton] and
/// handles the system back button (Android) when there is no page to pop:
/// it goes to the parent instead of closing the app. With pages to pop,
/// normal back and iOS swipe-back behave as usual.
class ParentBackScope extends ConsumerWidget {
  const ParentBackScope({super.key, required this.path, required this.child});

  final String path;
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final target = backTargetFor(
      ref.watch(authControllerProvider),
      ref.watch(onboardingGateProvider),
      path,
    );
    final canPop = Navigator.of(context).canPop();
    return _BackTarget(
      target: target,
      child: PopScope(
        canPop: canPop || target == null,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop && target != null) context.go(target);
        },
        child: child,
      ),
    );
  }
}

class _BackTarget extends InheritedWidget {
  const _BackTarget({required this.target, required super.child});

  final String? target;

  @override
  bool updateShouldNotify(_BackTarget oldWidget) => target != oldWidget.target;
}

/// The app-bar Back button for the current page, or null when Back isn't
/// allowed. Pops to the previous page when there is one; otherwise goes to
/// the parent screen. Use with `automaticallyImplyLeading: false` so no
/// other implicit back button appears.
Widget? appBackButton(BuildContext context) {
  final target = context
      .dependOnInheritedWidgetOfExactType<_BackTarget>()
      ?.target;
  if (target == null) return null;
  return BackButton(
    onPressed: () {
      final navigator = Navigator.of(context);
      if (navigator.canPop()) {
        navigator.maybePop();
      } else {
        context.go(target);
      }
    },
  );
}
