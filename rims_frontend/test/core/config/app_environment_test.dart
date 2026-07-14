import 'package:flutter_test/flutter_test.dart';
import 'package:rims_frontend/core/config/app_environment.dart';

void main() {
  test('parses supported application environments and dev alias', () {
    expect(AppEnvironment.parse('dev'), AppEnvironment.development);
    expect(AppEnvironment.parse('development'), AppEnvironment.development);
    expect(AppEnvironment.parse('test'), AppEnvironment.test);
    expect(AppEnvironment.parse('staging'), AppEnvironment.staging);
    expect(AppEnvironment.parse('production'), AppEnvironment.production);
  });

  test('rejects unknown application environment', () {
    expect(() => AppEnvironment.parse('prod'), throwsFormatException);
  });

  test('identifies only development and test as local', () {
    expect(AppEnvironment.development.isLocal, isTrue);
    expect(AppEnvironment.test.isLocal, isTrue);
    expect(AppEnvironment.staging.isLocal, isFalse);
    expect(AppEnvironment.production.isLocal, isFalse);
  });

  test('build configuration validates and exposes a typed API URI', () {
    final configuration = AppConfiguration.fromValues(
      environment: 'development',
      apiBaseUrl: 'http://127.0.0.1:8080/api/v1',
      allowLocalHttp: true,
      isReleaseMode: false,
    );

    expect(configuration.environment, AppEnvironment.development);
    expect(configuration.apiBaseUri, Uri.parse('http://127.0.0.1:8080/api/v1'));
    expect(configuration.allowLocalHttp, isTrue);
  });

  test('release configuration cannot carry the local HTTP override', () {
    expect(
      () => AppConfiguration.fromValues(
        environment: 'development',
        apiBaseUrl: 'http://127.0.0.1:8080/api/v1',
        allowLocalHttp: true,
        isReleaseMode: true,
      ),
      throwsFormatException,
    );
  });
}
