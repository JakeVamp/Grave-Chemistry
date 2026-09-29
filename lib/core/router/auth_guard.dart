import '../../features/auth/domain/auth_status.dart';
import '../../features/profile/application/profile_providers.dart';
import 'app_routes.dart';

/// Routes a signed-in user must be on for each onboarding step. `ready`
/// users may go anywhere in the app except these.
const _onboardingRoutes = {
  OnboardingGate.loading: AppRoutes.profileLoading,
  OnboardingGate.error: AppRoutes.profileLoading,
  OnboardingGate.profileIncomplete: AppRoutes.profileSetup,
  OnboardingGate.verificationRequired: AppRoutes.verification,
  OnboardingGate.verificationRetry: AppRoutes.verificationRetry,
  OnboardingGate.verificationPending: AppRoutes.verificationPending,
};

/// Member onboarding steps (as opposed to the profile still loading).
const _memberOnboardingGates = {
  OnboardingGate.profileIncomplete,
  OnboardingGate.verificationRequired,
  OnboardingGate.verificationRetry,
  OnboardingGate.verificationPending,
};

/// The onboarding screen for [gate], or null when onboarding is done.
String? onboardingRouteFor(OnboardingGate gate) => _onboardingRoutes[gate];

/// Decides where a user may be, given their auth status and, once signed in,
/// their onboarding step.
///
/// Returns the path to redirect to, or `null` to allow [path]. Every
/// redirect target is itself allowed for the same inputs, so applying the
/// guard twice always yields `null`, which makes redirect loops impossible.
/// `auth_guard_test.dart` checks this for every route and state.
String? authGuard(AuthStatus status, OnboardingGate onboarding, String path) {
  final onAuthRoute = AppRoutes.isAuthRoute(path);

  switch (status) {
    case PasswordRecovery():
      return path == AppRoutes.resetPassword ? null : AppRoutes.resetPassword;
    case SignedOut():
      return onAuthRoute ? null : AppRoutes.auth;
    case SignedIn(:final user):
      final required = _onboardingRoutes[onboarding];

      // Moderator tools are a separate staff path that doesn't depend on the
      // member profile, so they stay reachable while member onboarding is
      // unfinished. This is navigation only: every moderator request is
      // checked by the database (moderator role + MFA), and none of this
      // makes the account verified or visible to members.
      if (user.isModerator) {
        if (AppRoutes.isModeratorRoute(path)) return null;
        if (required != null && path != required) {
          // The dating app stays closed until onboarding is finished; land
          // on moderator tools instead. A moderator who chose to work
          // through member setup moves on to the next step as usual.
          final inMemberSetup = _memberOnboardingGates.any(
            (gate) => _onboardingRoutes[gate] == path,
          );
          return _memberOnboardingGates.contains(onboarding) && !inMemberSetup
              ? AppRoutes.moderation
              : required;
        }
      }

      if (required != null) return path == required ? null : required;

      // Navigation only: the database refuses moderator requests anyway.
      if (AppRoutes.isModeratorRoute(path) && !user.isModerator) {
        return AppRoutes.home;
      }

      final isGatingRoute =
          onAuthRoute ||
          path == AppRoutes.resetPassword ||
          _onboardingRoutes.containsValue(path);
      return isGatingRoute ? AppRoutes.home : null;
  }
}
