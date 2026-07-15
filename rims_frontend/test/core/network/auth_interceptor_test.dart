import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rims_frontend/core/network/interceptors/auth_interceptor.dart';
import 'package:rims_frontend/core/result/result.dart';
import 'package:rims_frontend/core/storage/app_secure_storage.dart';
import 'package:rims_frontend/features/auth/domain/repositories/auth_repository.dart';
import 'package:rims_frontend/features/auth/domain/services/session_refresh_coordinator.dart';

void main() {
  test('adds bearer authorization header when token is nonempty', () async {
    final adapter = _CapturingAdapter();
    final dio = _dioWithAuthInterceptor(
      tokenReader: () async => 'token-123',
      adapter: adapter,
    );

    await dio.get<dynamic>('/test');

    expect(adapter.lastOptions?.headers['Authorization'], 'Bearer token-123');
  });

  test('continues without authorization header when token is null', () async {
    final adapter = _CapturingAdapter();
    final dio = _dioWithAuthInterceptor(
      tokenReader: () async => null,
      adapter: adapter,
    );

    await dio.get<dynamic>('/test');

    expect(adapter.lastOptions?.headers, isNot(contains('Authorization')));
  });

  test('continues without authorization header when token is empty', () async {
    final adapter = _CapturingAdapter();
    final dio = _dioWithAuthInterceptor(
      tokenReader: () async => '',
      adapter: adapter,
    );

    await dio.get<dynamic>('/test');

    expect(adapter.lastOptions?.headers, isNot(contains('Authorization')));
  });

  test('rejects with DioException when token reader throws', () async {
    final adapter = _CapturingAdapter();
    final dio = _dioWithAuthInterceptor(
      tokenReader: () async => throw StateError('token unavailable'),
      adapter: adapter,
    );

    await expectLater(
      dio.get<dynamic>('/test').timeout(const Duration(milliseconds: 250)),
      throwsA(isA<DioException>()),
    );
    expect(adapter.fetchCount, 0);
  });

  test('ten concurrent 401 responses perform one refresh and replay', () async {
    final storage = _InterceptorCredentialStorage(_credential());
    final repository = _InterceptorRefreshRepository();
    final adapter = _RotatingAdapter();
    final dio = _dioWithCoordinator(storage, repository, adapter);

    final responses = await Future.wait([
      for (var index = 0; index < 10; index += 1)
        dio.get<dynamic>('/read-$index'),
    ]);

    expect(responses.map((response) => response.statusCode), everyElement(200));
    expect(repository.calls, 1);
    expect(adapter.oldCredentialCalls, 10);
    expect(adapter.newCredentialCalls, 10);
  });

  test(
    'late-bound coordinator supports production composition order',
    () async {
      final storage = _InterceptorCredentialStorage(_credential());
      final repository = _InterceptorRefreshRepository();
      final adapter = _RotatingAdapter();
      final dio = Dio()..httpClientAdapter = adapter;
      SessionRefreshCoordinator? coordinator;
      dio.interceptors.add(
        AuthInterceptor(
          tokenReader: storage.readAccessToken,
          refreshCoordinatorReader: () => coordinator,
          requestExecutor: dio.fetch,
        ),
      );
      coordinator = SessionRefreshCoordinator(
        credentialStorage: storage,
        tokenStorage: storage,
        pendingRevocationStorage: storage,
        repository: repository,
      );

      final response = await dio.get<dynamic>('/late-bound');

      expect(response.statusCode, 200);
      expect(repository.calls, 1);
    },
  );

  test('a safe request is replayed at most once', () async {
    final storage = _InterceptorCredentialStorage(_credential());
    final repository = _InterceptorRefreshRepository();
    final adapter = _RotatingAdapter(alwaysUnauthorized: true);
    final dio = _dioWithCoordinator(storage, repository, adapter);

    await expectLater(
      dio.get<dynamic>('/still-unauthorized'),
      throwsA(isA<DioException>()),
    );

    expect(repository.calls, 1);
    expect(adapter.fetchCount, 2);
  });

  test('write replay requires a stable idempotency key', () async {
    final unsafeStorage = _InterceptorCredentialStorage(_credential());
    final unsafeRepository = _InterceptorRefreshRepository();
    final unsafeAdapter = _RotatingAdapter();
    final unsafeDio = _dioWithCoordinator(
      unsafeStorage,
      unsafeRepository,
      unsafeAdapter,
    );

    await expectLater(
      unsafeDio.post<dynamic>('/write', data: {'value': 1}),
      throwsA(isA<DioException>()),
    );
    expect(unsafeRepository.calls, 1);
    expect(unsafeAdapter.fetchCount, 1);

    final safeStorage = _InterceptorCredentialStorage(_credential());
    final safeRepository = _InterceptorRefreshRepository();
    final safeAdapter = _RotatingAdapter();
    final safeDio = _dioWithCoordinator(
      safeStorage,
      safeRepository,
      safeAdapter,
    );
    final response = await safeDio.post<dynamic>(
      '/write',
      data: {'value': 1},
      options: Options(headers: {'Idempotency-Key': 'stable-request-1'}),
    );

    expect(response.statusCode, 200);
    expect(safeRepository.calls, 1);
    expect(safeAdapter.fetchCount, 2);
  });

  test(
    'queued writes never replay and refresh only from Sync Center',
    () async {
      final backgroundStorage = _InterceptorCredentialStorage(_credential());
      final backgroundRepository = _InterceptorRefreshRepository();
      final backgroundAdapter = _RotatingAdapter();
      final backgroundDio = _dioWithCoordinator(
        backgroundStorage,
        backgroundRepository,
        backgroundAdapter,
      );
      await expectLater(
        AuthRequestPolicy.runQueuedWrite(
          () => backgroundDio.post<dynamic>(
            '/queued',
            options: Options(headers: {'Idempotency-Key': 'queued-request-1'}),
          ),
        ),
        throwsA(isA<DioException>()),
      );
      expect(backgroundRepository.calls, 0);
      expect(backgroundAdapter.fetchCount, 1);

      final syncStorage = _InterceptorCredentialStorage(_credential());
      final syncRepository = _InterceptorRefreshRepository();
      final syncAdapter = _RotatingAdapter();
      final syncDio = _dioWithCoordinator(
        syncStorage,
        syncRepository,
        syncAdapter,
      );
      await expectLater(
        AuthRequestPolicy.runExplicitSyncCenter(
          () => AuthRequestPolicy.runQueuedWrite(
            () => syncDio.post<dynamic>(
              '/queued',
              options: Options(
                headers: {'Idempotency-Key': 'queued-request-1'},
              ),
            ),
          ),
        ),
        throwsA(isA<DioException>()),
      );
      expect(syncRepository.calls, 1);
      expect(syncAdapter.fetchCount, 1);
    },
  );
}

Dio _dioWithAuthInterceptor({
  required TokenReader tokenReader,
  required _CapturingAdapter adapter,
}) {
  return Dio()
    ..httpClientAdapter = adapter
    ..interceptors.add(AuthInterceptor(tokenReader: tokenReader));
}

Dio _dioWithCoordinator(
  _InterceptorCredentialStorage storage,
  _InterceptorRefreshRepository repository,
  HttpClientAdapter adapter,
) {
  final dio = Dio()..httpClientAdapter = adapter;
  final coordinator = SessionRefreshCoordinator(
    credentialStorage: storage,
    tokenStorage: storage,
    pendingRevocationStorage: storage,
    repository: repository,
  );
  dio.interceptors.add(
    AuthInterceptor(
      tokenReader: storage.readAccessToken,
      refreshCoordinator: coordinator,
      requestExecutor: dio.fetch,
    ),
  );
  return dio;
}

final class _InterceptorRefreshRepository
    implements SessionCredentialRepository {
  int calls = 0;

  @override
  Future<Result<DeviceCredential>> refreshCredential(
    DeviceCredential current,
  ) async {
    calls += 1;
    await Future<void>.delayed(const Duration(milliseconds: 10));
    return Success(
      _credential(
        accessToken: 'access-2',
        refreshToken: 'refresh-2',
        generation: current.generation + 1,
      ),
    );
  }
}

final class _InterceptorCredentialStorage
    implements DeviceCredentialStorage, TokenStorage, PendingRevocationStorage {
  _InterceptorCredentialStorage(this.credential);

  DeviceCredential? credential;
  String? pendingAccountId;

  @override
  Future<void> clearAccessToken() async => credential = null;

  @override
  Future<bool> clearDeviceCredentialIfMatches({
    required String accountId,
    required String sessionId,
    required int generation,
  }) async {
    final current = credential;
    if (current?.accountId != accountId ||
        current?.sessionId != sessionId ||
        current?.generation != generation) {
      return false;
    }
    credential = null;
    return true;
  }

  @override
  Future<void> clearPendingRevocationAccountId() async =>
      pendingAccountId = null;

  @override
  Future<String?> readAccessToken() async => credential?.accessToken;

  @override
  Future<DeviceCredential?> readDeviceCredential() async => credential;

  @override
  Future<String?> readPendingRevocationAccountId() async => pendingAccountId;

  @override
  Future<bool> rotateDeviceCredential({
    required DeviceCredential credential,
    required String expectedAccountId,
    required String expectedSessionId,
    required int expectedGeneration,
  }) async {
    final current = this.credential;
    if (current?.accountId != expectedAccountId ||
        current?.sessionId != expectedSessionId ||
        current?.generation != expectedGeneration) {
      return false;
    }
    this.credential = credential;
    return true;
  }

  @override
  Future<void> saveAccessToken(String token) async =>
      throw UnsupportedError('device credentials only');

  @override
  Future<void> savePendingRevocationAccountId(String accountId) async =>
      pendingAccountId = accountId;

  @override
  Future<bool> savePendingDeviceCredentialForOwner({
    required DeviceCredential credential,
    required String ownerId,
    required int attemptVersion,
  }) async => throw UnsupportedError('not used');
}

final class _RotatingAdapter implements HttpClientAdapter {
  _RotatingAdapter({this.alwaysUnauthorized = false});

  final bool alwaysUnauthorized;
  int fetchCount = 0;
  int oldCredentialCalls = 0;
  int newCredentialCalls = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    fetchCount += 1;
    final authorization = options.headers['Authorization'];
    if (authorization == 'Bearer access-1') oldCredentialCalls += 1;
    if (authorization == 'Bearer access-2') newCredentialCalls += 1;
    final status = alwaysUnauthorized || authorization != 'Bearer access-2'
        ? 401
        : 200;
    return ResponseBody.fromString('response', status);
  }

  @override
  void close({bool force = false}) {}
}

DeviceCredential _credential({
  String accessToken = 'access-1',
  String refreshToken = 'refresh-1',
  int generation = 1,
}) => DeviceCredential(
  accessToken: accessToken,
  refreshToken: refreshToken,
  accountId: '7',
  sessionId: 'session-7',
  accessExpiresAt: DateTime.utc(2026, 7, 15, 3),
  refreshExpiresAt: DateTime.utc(2026, 8, 15, 3),
  tokenVersion: 5,
  generation: generation,
  biometricPolicy: BiometricCredentialPolicy.disabled,
);

final class _CapturingAdapter implements HttpClientAdapter {
  RequestOptions? lastOptions;
  int fetchCount = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    fetchCount += 1;
    lastOptions = options;

    return ResponseBody.fromString('ok', 200);
  }

  @override
  void close({bool force = false}) {}
}
