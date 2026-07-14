import '../network/api_url_policy.dart';
import 'environment_profile.dart';

export 'environment_profile.dart';

final class AppConfiguration {
  const AppConfiguration._({
    required this.environment,
    required this.apiBaseUri,
    required this.allowLocalHttp,
  });

  factory AppConfiguration.fromValues({
    required String environment,
    required String apiBaseUrl,
    required bool allowLocalHttp,
    required bool isReleaseMode,
  }) {
    final parsedEnvironment = AppEnvironment.parse(environment);
    if (isReleaseMode && allowLocalHttp) {
      throw const FormatException(
        'ALLOW_LOCAL_HTTP cannot be enabled in a release build.',
      );
    }
    return AppConfiguration._(
      environment: parsedEnvironment,
      apiBaseUri: ApiUrlPolicy.validate(
        environment: parsedEnvironment,
        rawUrl: apiBaseUrl,
        allowLocalHttp: allowLocalHttp,
      ),
      allowLocalHttp: allowLocalHttp,
    );
  }

  factory AppConfiguration.fromCompileTimeDefines({
    required bool isReleaseMode,
  }) {
    const environment = String.fromEnvironment(
      'APP_ENV',
      defaultValue: 'development',
    );
    const apiBaseUrl = String.fromEnvironment(
      'API_BASE_URL',
      defaultValue: 'http://localhost:8080/api/v1',
    );
    const allowLocalHttp = bool.fromEnvironment(
      'ALLOW_LOCAL_HTTP',
      defaultValue: false,
    );
    return AppConfiguration.fromValues(
      environment: environment,
      apiBaseUrl: apiBaseUrl,
      allowLocalHttp: allowLocalHttp,
      isReleaseMode: isReleaseMode,
    );
  }

  factory AppConfiguration.localTest() {
    return AppConfiguration.fromValues(
      environment: 'test',
      apiBaseUrl: 'http://localhost:8080/api/v1',
      allowLocalHttp: true,
      isReleaseMode: false,
    );
  }

  final AppEnvironment environment;
  final Uri apiBaseUri;
  final bool allowLocalHttp;
}
