import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../features/auth/application/auth_providers.dart';
import '../../features/auth/domain/auth_status.dart';
import '../../features/auth/presentation/auth_screen.dart';
import '../../features/auth/presentation/check_email_screen.dart';
import '../../features/auth/presentation/forgot_password_screen.dart';
import '../../features/auth/presentation/reset_password_screen.dart';
import '../../features/auth/presentation/sign_up_screen.dart';
import '../../features/discovery/presentation/discovery_screen.dart';
import '../../features/home/presentation/home_screen.dart';
import '../../features/matches/presentation/matches_screen.dart';
import '../../features/messages/presentation/messages_screen.dart';
import '../../features/moderation/presentation/moderator_home_screen.dart';
import '../../features/moderation/presentation/photo_review_queue_screen.dart';
import '../../features/moderation/presentation/photo_review_screen.dart';
import '../../features/profile/application/profile_providers.dart';
import '../../features/profile/presentation/profile_loading_screen.dart';
import '../../features/profile/presentation/profile_setup_screen.dart';
import '../../features/profile_photos/presentation/profile_photos_screen.dart';
import '../../features/settings/presentation/settings_screen.dart';
import '../../features/verification/presentation/verification_pending_screen.dart';
import '../../features/verification/presentation/verification_screen.dart';
import '../../shared/widgets/not_found_screen.dart';
import 'app_routes.dart';
import 'auth_guard.dart';
import 'back_navigation.dart';

final appRouterProvider = Provider<GoRouter>((ref) {
  // Bridges Riverpod to go_router: the router re-runs its redirect whenever
  // the auth status or profile gate changes, without being rebuilt.
  final gate = ValueNotifier<(AuthStatus, OnboardingGate)>((
    ref.read(authControllerProvider),
    ref.read(onboardingGateProvider),
  ));
  ref.listen(
    authControllerProvider,
    (_, next) => gate.value = (next, gate.value.$2),
  );
  ref.listen(
    onboardingGateProvider,
    (_, next) => gate.value = (gate.value.$1, next),
  );

  final router = GoRouter(
    initialLocation: AppRoutes.home,
    refreshListenable: gate,
    redirect: (context, state) =>
        authGuard(gate.value.$1, gate.value.$2, state.uri.path),
    routes: [
      GoRoute(
        path: AppRoutes.home,
        builder: (context, state) => _page(state, const HomeScreen()),
      ),
      GoRoute(
        path: AppRoutes.auth,
        builder: (context, state) => _page(state, const AuthScreen()),
      ),
      GoRoute(
        path: AppRoutes.signUp,
        builder: (context, state) => _page(state, const SignUpScreen()),
      ),
      GoRoute(
        path: AppRoutes.forgotPassword,
        builder: (context, state) => _page(
          state,
          ForgotPasswordScreen(
            initialEmail: state.uri.queryParameters['email'] ?? '',
          ),
        ),
      ),
      GoRoute(
        path: AppRoutes.checkEmail,
        builder: (context, state) =>
            _page(state, CheckEmailScreen.fromQuery(state.uri.queryParameters)),
      ),
      GoRoute(
        path: AppRoutes.resetPassword,
        builder: (context, state) => _page(state, const ResetPasswordScreen()),
      ),
      GoRoute(
        path: AppRoutes.profileSetup,
        builder: (context, state) => _page(state, const ProfileSetupScreen()),
      ),
      GoRoute(
        path: AppRoutes.profileLoading,
        builder: (context, state) => _page(state, const ProfileLoadingScreen()),
      ),
      GoRoute(
        path: AppRoutes.verification,
        builder: (context, state) => _page(state, const VerificationScreen()),
      ),
      GoRoute(
        path: AppRoutes.verificationRetry,
        builder: (context, state) =>
            _page(state, const VerificationScreen(isRetry: true)),
      ),
      GoRoute(
        path: AppRoutes.verificationPending,
        builder: (context, state) =>
            _page(state, const VerificationPendingScreen()),
      ),
      GoRoute(
        path: AppRoutes.discovery,
        builder: (context, state) => _page(state, const DiscoveryScreen()),
      ),
      GoRoute(
        path: AppRoutes.matches,
        builder: (context, state) => _page(state, const MatchesScreen()),
      ),
      GoRoute(
        path: AppRoutes.messages,
        builder: (context, state) => _page(state, const MessagesScreen()),
      ),
      GoRoute(
        path: AppRoutes.profilePhotos,
        builder: (context, state) => _page(state, const ProfilePhotosScreen()),
      ),
      GoRoute(
        path: AppRoutes.settings,
        builder: (context, state) => _page(state, const SettingsScreen()),
      ),
      GoRoute(
        path: AppRoutes.moderation,
        builder: (context, state) => _page(state, const ModeratorHomeScreen()),
      ),
      GoRoute(
        path: AppRoutes.photoReview,
        builder: (context, state) =>
            _page(state, const PhotoReviewQueueScreen()),
      ),
      GoRoute(
        path: '${AppRoutes.photoReview}/:photoId',
        builder: (context, state) => _page(
          state,
          PhotoReviewScreen(photoId: state.pathParameters['photoId']!),
        ),
      ),
    ],
    errorBuilder: (context, state) =>
        _page(state, NotFoundScreen(location: state.uri)),
  );
  ref.onDispose(() {
    router.dispose();
    gate.dispose();
  });
  return router;
});

/// Every page gets Back handling based on its path.
Widget _page(GoRouterState state, Widget child) =>
    ParentBackScope(path: state.uri.path, child: child);
