enum AppEnvironment {
  development,
  staging,
  production;

  static AppEnvironment fromName(String name) {
    return AppEnvironment.values.firstWhere(
      (env) => env.name == name.trim().toLowerCase(),
      orElse: () => AppEnvironment.development,
    );
  }
}
