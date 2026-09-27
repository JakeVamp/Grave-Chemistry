/// Deep link that Supabase Auth emails (confirmation, password reset) send
/// the user back to. Must match the scheme registered in
/// `AndroidManifest.xml` / `Info.plist` and be listed under
/// Authentication → URL Configuration → Redirect URLs in Supabase.
abstract final class AuthCallback {
  static const String scheme = 'com.gravechemistry.app';
  static const String host = 'login-callback';
  static const String url = '$scheme://$host';

  static bool matches(Uri uri) => uri.scheme == scheme && uri.host == host;
}
