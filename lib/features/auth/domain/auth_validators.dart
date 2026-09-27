abstract final class AuthValidators {
  /// Keep in sync with Supabase → Authentication → Providers → Email →
  /// Minimum password length.
  static const int minPasswordLength = 8;

  static final RegExp _emailPattern = RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$');

  static String? email(String? value) {
    final email = value?.trim() ?? '';
    if (email.isEmpty) return 'Email is required.';
    if (!_emailPattern.hasMatch(email)) return 'Enter a valid email address.';
    return null;
  }

  /// For sign-in: existing passwords are only checked for presence.
  static String? requiredPassword(String? value) {
    if (value == null || value.isEmpty) return 'Password is required.';
    return null;
  }

  /// For choosing a new password (sign-up, reset).
  static String? newPassword(String? value) {
    if (value == null || value.isEmpty) return 'Password is required.';
    if (value.length < minPasswordLength) {
      return 'Password must be at least $minPasswordLength characters.';
    }
    return null;
  }

  static String? Function(String?) confirmPassword(String Function() password) {
    return (value) {
      if (value == null || value.isEmpty) {
        return 'Please confirm your password.';
      }
      if (value != password()) return 'Passwords do not match.';
      return null;
    };
  }
}
