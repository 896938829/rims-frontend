enum AppEnvironment {
  development,
  test,
  staging,
  production;

  static AppEnvironment parse(String value) {
    return switch (value.trim().toLowerCase()) {
      'dev' || 'development' => AppEnvironment.development,
      'test' => AppEnvironment.test,
      'staging' => AppEnvironment.staging,
      'production' => AppEnvironment.production,
      _ => throw const FormatException(
        'APP_ENV must be development, test, staging, or production.',
      ),
    };
  }

  bool get isLocal =>
      this == AppEnvironment.development || this == AppEnvironment.test;
}
