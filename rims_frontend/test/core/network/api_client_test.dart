import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rims_frontend/core/events/app_event.dart';
import 'package:rims_frontend/core/events/app_event_bus.dart';
import 'package:rims_frontend/core/config/app_environment.dart';
import 'package:rims_frontend/core/network/api_client.dart';
import 'package:rims_frontend/core/network/api_endpoints.dart';
import 'package:rims_frontend/core/network/interceptors/auth_interceptor.dart';
import 'package:rims_frontend/core/network/interceptors/logging_interceptor.dart';
import 'package:rims_frontend/core/network/interceptors/warehouse_interceptor.dart';

void main() {
  test('test client uses the explicit local test configuration', () {
    final dio = Dio();

    ApiClient.test(dio: dio, enableLogging: false);

    expect(dio.options.baseUrl, 'http://localhost:8080/api/v1');
  });

  test('derives health URI from the validated API base URI', () {
    expect(
      ApiEndpoints.healthUriFor(Uri.parse('https://api.rims.example/api/v1')),
      Uri.parse('https://api.rims.example/healthz'),
    );
  });

  test('uses an injected validated API base URI', () {
    final dio = Dio();

    ApiClient(
      dio: dio,
      configuration: AppConfiguration.fromValues(
        environment: 'production',
        apiBaseUrl: 'https://api.rims.example/api/v1',
        allowLocalHttp: false,
        isReleaseMode: true,
      ),
      enableLogging: false,
    );

    expect(dio.options.baseUrl, 'https://api.rims.example/api/v1');
  });

  test('attaches logging interceptor by default', () {
    final dio = Dio();

    ApiClient.test(dio: dio);

    expect(dio.interceptors.whereType<SafeLoggingInterceptor>(), hasLength(1));
  });

  test('does not attach logging interceptor when logging is disabled', () {
    final dio = Dio();

    ApiClient.test(dio: dio, enableLogging: false);

    expect(dio.interceptors.whereType<SafeLoggingInterceptor>(), isEmpty);
  });

  test('attaches auth interceptor when token reader is provided', () {
    final dio = Dio();

    ApiClient.test(
      dio: dio,
      tokenReader: () async => 'token',
      enableLogging: false,
    );

    expect(dio.interceptors.whereType<AuthInterceptor>(), hasLength(1));
  });

  test('attaches warehouse interceptor when warehouse reader is provided', () {
    final dio = Dio();

    ApiClient.test(
      dio: dio,
      warehouseIdReader: () async => 12,
      enableLogging: false,
    );

    expect(dio.interceptors.whereType<WarehouseInterceptor>(), hasLength(1));
  });

  test(
    'sends bearer token through requests when token reader is provided',
    () async {
      final adapter = _CapturingAdapter();
      final dio = Dio()..httpClientAdapter = adapter;
      final client = ApiClient.test(
        dio: dio,
        tokenReader: () async => 'token',
        enableLogging: false,
      );

      final result = await client.get<dynamic>('/test');

      expect(result.isSuccess, isTrue);
      expect(adapter.lastOptions?.headers['Authorization'], 'Bearer token');
    },
  );

  test(
    'sends warehouse header through requests when reader is provided',
    () async {
      final adapter = _CapturingAdapter();
      final dio = Dio()..httpClientAdapter = adapter;
      final client = ApiClient.test(
        dio: dio,
        warehouseIdReader: () async => 12,
        enableLogging: false,
      );

      final result = await client.get<dynamic>('/inventory');

      expect(result.isSuccess, isTrue);
      expect(adapter.lastOptions?.headers['X-Warehouse-ID'], '12');
    },
  );

  test(
    'publishes token expired event when request returns auth failure',
    () async {
      final eventBus = AppEventBus();
      addTearDown(eventBus.dispose);
      final eventFuture = eventBus.on<TokenExpiredEvent>().first;
      final dio = Dio()
        ..httpClientAdapter = const _StatusAdapter(
          statusCode: 401,
          body: '{"code":10001,"message":"登录已过期","traceId":"trace-auth"}',
        );
      final client = ApiClient.test(
        dio: dio,
        tokenReader: () async => 'current-token',
        eventBus: eventBus,
        enableLogging: false,
      );

      final result = await client.get<dynamic>('/users/me');
      final event = await eventFuture;

      expect(result.isFailure, isTrue);
      expect(event, isA<TokenExpiredEvent>());
    },
  );

  test(
    'does not publish token expired event for login credential failure',
    () async {
      final eventBus = AppEventBus();
      addTearDown(eventBus.dispose);
      var tokenExpiredEvents = 0;
      final subscription = eventBus.on<TokenExpiredEvent>().listen((_) {
        tokenExpiredEvents += 1;
      });
      addTearDown(subscription.cancel);
      final dio = Dio()
        ..httpClientAdapter = const _StatusAdapter(
          statusCode: 401,
          body: '{"code":10001,"message":"用户名或密码错误","traceId":"trace-login"}',
        );
      final client = ApiClient.test(
        dio: dio,
        eventBus: eventBus,
        enableLogging: false,
      );

      final result = await client.post<dynamic>(
        ApiEndpoints.login,
        data: {'username': 'admin', 'password': 'wrong-password'},
      );
      await Future<void>.delayed(Duration.zero);

      expect(result.isFailure, isTrue);
      expect(tokenExpiredEvents, 0);
    },
  );

  test('does not expire a newer session for a delayed old-token 401', () async {
    var token = 'old-token';
    final eventBus = AppEventBus();
    addTearDown(eventBus.dispose);
    var tokenExpiredEvents = 0;
    final subscription = eventBus.on<TokenExpiredEvent>().listen((_) {
      tokenExpiredEvents += 1;
    });
    addTearDown(subscription.cancel);
    final adapter = _DelayedStatusAdapter(
      statusCode: 401,
      body: '{"code":10001,"message":"登录已过期"}',
    );
    final client = ApiClient.test(
      dio: Dio()..httpClientAdapter = adapter,
      tokenReader: () async => token,
      eventBus: eventBus,
      enableLogging: false,
    );

    final request = client.get<dynamic>('/permissions');
    await adapter.requestStarted;
    expect(adapter.lastOptions?.headers['Authorization'], 'Bearer old-token');
    token = 'new-token';
    adapter.release();
    final result = await request;
    await Future<void>.delayed(Duration.zero);

    expect(result.isFailure, isTrue);
    expect(tokenExpiredEvents, 0);
  });

  test('request observer receives success after the real request', () async {
    final adapter = _CapturingAdapter();
    final outcomes = <ApiRequestOutcome>[];
    final client = ApiClient.test(
      dio: Dio()..httpClientAdapter = adapter,
      requestObserver: outcomes.add,
      enableLogging: false,
    );

    await client.get<dynamic>('/inventory');

    expect(adapter.lastOptions?.path, '/inventory');
    expect(outcomes, hasLength(1));
    expect(outcomes.single.path, '/inventory');
    expect(outcomes.single.succeeded, isTrue);
    expect(outcomes.single.failure, isNull);
  });

  test(
    'request observer receives mapped failure after the real request',
    () async {
      final outcomes = <ApiRequestOutcome>[];
      final client = ApiClient.test(
        dio: Dio()
          ..httpClientAdapter = const _StatusAdapter(
            statusCode: 503,
            body: '{"message":"unavailable"}',
          ),
        requestObserver: outcomes.add,
        enableLogging: false,
      );

      final result = await client.get<dynamic>('/inventory');

      expect(result.isFailure, isTrue);
      expect(outcomes, hasLength(1));
      expect(outcomes.single.path, '/inventory');
      expect(outcomes.single.succeeded, isFalse);
      expect(outcomes.single.failure, isNotNull);
    },
  );
}

final class _CapturingAdapter implements HttpClientAdapter {
  RequestOptions? lastOptions;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    lastOptions = options;

    return ResponseBody.fromString('ok', 200);
  }

  @override
  void close({bool force = false}) {}
}

final class _StatusAdapter implements HttpClientAdapter {
  const _StatusAdapter({required this.statusCode, required this.body});

  final int statusCode;
  final String body;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    return ResponseBody.fromString(
      body,
      statusCode,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

final class _DelayedStatusAdapter implements HttpClientAdapter {
  _DelayedStatusAdapter({required this.statusCode, required this.body});

  final int statusCode;
  final String body;
  final Completer<void> _requestStarted = Completer<void>();
  final Completer<void> _release = Completer<void>();
  RequestOptions? lastOptions;

  Future<void> get requestStarted => _requestStarted.future;

  void release() => _release.complete();

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    lastOptions = options;
    _requestStarted.complete();
    await _release.future;
    return ResponseBody.fromString(
      body,
      statusCode,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
