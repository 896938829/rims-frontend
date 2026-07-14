import 'package:flutter_test/flutter_test.dart';
import 'package:rims_frontend/core/config/app_environment.dart';
import 'package:rims_frontend/core/network/api_url_policy.dart';

void main() {
  group('ApiUrlPolicy accepted URLs', () {
    final cases =
        <
          ({
            String name,
            AppEnvironment environment,
            String url,
            bool allowLocalHttp,
          })
        >[
          (
            name: 'development localhost',
            environment: AppEnvironment.development,
            url: 'http://localhost:8080/api/v1',
            allowLocalHttp: true,
          ),
          (
            name: 'test loopback',
            environment: AppEnvironment.test,
            url: 'http://127.0.0.1:8080/api/v1',
            allowLocalHttp: true,
          ),
          (
            name: 'Android emulator host alias',
            environment: AppEnvironment.development,
            url: 'http://10.0.2.2:8080/api/v1',
            allowLocalHttp: true,
          ),
          (
            name: 'private development target',
            environment: AppEnvironment.development,
            url: 'http://192.168.20.4:8080/api/v1',
            allowLocalHttp: true,
          ),
          (
            name: 'local HTTPS development server',
            environment: AppEnvironment.development,
            url: 'https://localhost:8443/api/v1',
            allowLocalHttp: false,
          ),
          (
            name: 'staging HTTPS',
            environment: AppEnvironment.staging,
            url: 'https://staging.rims.example/api/v1',
            allowLocalHttp: false,
          ),
          (
            name: 'production HTTPS',
            environment: AppEnvironment.production,
            url: 'https://api.rims.example/api/v1',
            allowLocalHttp: false,
          ),
        ];

    for (final entry in cases) {
      test(entry.name, () {
        expect(
          ApiUrlPolicy.validate(
            environment: entry.environment,
            rawUrl: entry.url,
            allowLocalHttp: entry.allowLocalHttp,
          ),
          Uri.parse(entry.url),
        );
      });
    }
  });

  group('ApiUrlPolicy rejected URLs', () {
    final cases =
        <
          ({
            String name,
            AppEnvironment environment,
            String url,
            bool allowLocalHttp,
          })
        >[
          (
            name: 'local HTTP without explicit override',
            environment: AppEnvironment.development,
            url: 'http://localhost:8080/api/v1',
            allowLocalHttp: false,
          ),
          (
            name: 'staging HTTP despite override',
            environment: AppEnvironment.staging,
            url: 'http://staging.rims.example:8080/api/v1',
            allowLocalHttp: true,
          ),
          (
            name: 'production HTTP despite override',
            environment: AppEnvironment.production,
            url: 'http://api.rims.example:8080/api/v1',
            allowLocalHttp: true,
          ),
          (
            name: 'public development HTTP target',
            environment: AppEnvironment.development,
            url: 'http://example.com:8080/api/v1',
            allowLocalHttp: true,
          ),
          (
            name: 'userinfo',
            environment: AppEnvironment.production,
            url: 'https://user:pass@api.rims.example/api/v1',
            allowLocalHttp: false,
          ),
          (
            name: 'query',
            environment: AppEnvironment.production,
            url: 'https://api.rims.example/api/v1?tenant=1',
            allowLocalHttp: false,
          ),
          (
            name: 'fragment',
            environment: AppEnvironment.production,
            url: 'https://api.rims.example/api/v1#token',
            allowLocalHttp: false,
          ),
          (
            name: 'wrong API prefix',
            environment: AppEnvironment.production,
            url: 'https://api.rims.example/api',
            allowLocalHttp: false,
          ),
          (
            name: 'trailing API slash',
            environment: AppEnvironment.production,
            url: 'https://api.rims.example/api/v1/',
            allowLocalHttp: false,
          ),
          (
            name: 'extra API path',
            environment: AppEnvironment.production,
            url: 'https://api.rims.example/api/v1/admin',
            allowLocalHttp: false,
          ),
          (
            name: 'scheme relative input',
            environment: AppEnvironment.production,
            url: '//api.rims.example/api/v1',
            allowLocalHttp: false,
          ),
          (
            name: 'Unicode host',
            environment: AppEnvironment.production,
            url: 'https://例子.测试/api/v1',
            allowLocalHttp: false,
          ),
          (
            name: 'unexpected production port',
            environment: AppEnvironment.production,
            url: 'https://api.rims.example:8443/api/v1',
            allowLocalHttp: false,
          ),
          (
            name: 'unexpected local HTTP port',
            environment: AppEnvironment.development,
            url: 'http://localhost:9090/api/v1',
            allowLocalHttp: true,
          ),
          (
            name: 'production loopback HTTPS',
            environment: AppEnvironment.production,
            url: 'https://127.0.0.1/api/v1',
            allowLocalHttp: false,
          ),
          (
            name: 'surrounding whitespace',
            environment: AppEnvironment.production,
            url: ' https://api.rims.example/api/v1 ',
            allowLocalHttp: false,
          ),
        ];

    for (final entry in cases) {
      test(entry.name, () {
        expect(
          () => ApiUrlPolicy.validate(
            environment: entry.environment,
            rawUrl: entry.url,
            allowLocalHttp: entry.allowLocalHttp,
          ),
          throwsFormatException,
        );
      });
    }
  });
}
