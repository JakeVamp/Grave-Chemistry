enum SignUpResult {
  /// Email confirmation is disabled in Supabase; the user is signed in.
  signedIn,

  /// The user must open the confirmation link sent to their email.
  confirmationRequired,
}
