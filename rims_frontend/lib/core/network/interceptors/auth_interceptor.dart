import 'dart:async';

import 'package:dio/dio.dart';

import '../../../features/auth/domain/services/session_refresh_coordinator.dart';
import '../../result/result.dart';
import '../../storage/app_secure_storage.dart';
import '../auth_request_policy.dart';

export '../auth_request_policy.dart';

typedef TokenReader = Future<String?> Function();
typedef AuthRequestExecutor =
    Future<Response<dynamic>> Function(RequestOptions options);
typedef SessionRefreshCoordinatorReader = SessionRefreshCoordinator? Function();

final class AuthInterceptor extends Interceptor {
  const AuthInterceptor({
    required TokenReader tokenReader,
    SessionRefreshCoordinator? refreshCoordinator,
    SessionRefreshCoordinatorReader? refreshCoordinatorReader,
    AuthRequestExecutor? requestExecutor,
  }) : this._(
         tokenReader,
         refreshCoordinator,
         refreshCoordinatorReader,
         requestExecutor,
       );

  const AuthInterceptor._(
    this._tokenReader,
    this._refreshCoordinator,
    this._refreshCoordinatorReader,
    this._requestExecutor,
  );

  final TokenReader _tokenReader;
  final SessionRefreshCoordinator? _refreshCoordinator;
  final SessionRefreshCoordinatorReader? _refreshCoordinatorReader;
  final AuthRequestExecutor? _requestExecutor;

  SessionRefreshCoordinator? get _coordinator =>
      _refreshCoordinator ?? _refreshCoordinatorReader?.call();

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    unawaited(_handleRequest(options, handler));
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) {
    unawaited(_handleError(err, handler));
  }

  Future<void> _handleRequest(
    RequestOptions options,
    RequestInterceptorHandler handler,
  ) async {
    try {
      if (AuthRequestPolicy.isQueuedWrite) {
        options.extra.putIfAbsent(AuthRequestPolicy.queuedWrite, () => true);
      }
      if (AuthRequestPolicy.isExplicitSyncCenter) {
        options.extra.putIfAbsent(
          AuthRequestPolicy.explicitSyncCenter,
          () => true,
        );
      }
      final coordinator = _coordinator;
      if (coordinator != null &&
          options.extra[AuthRequestPolicy.credentialSnapshot] == null) {
        final credential = await coordinator.readCurrentCredential();
        if (credential != null) {
          options.extra[AuthRequestPolicy.credentialSnapshot] = credential;
        }
      }
      if (options.headers.containsKey('Authorization')) {
        handler.next(options);
        return;
      }
      final token = await _tokenReader();

      if (token != null && token.isNotEmpty) {
        options.headers['Authorization'] = 'Bearer $token';
      }

      handler.next(options);
    } catch (error, stackTrace) {
      handler.reject(
        DioException(
          requestOptions: options,
          type: DioExceptionType.unknown,
          error: error,
          stackTrace: stackTrace,
        ),
      );
    }
  }

  Future<void> _handleError(
    DioException error,
    ErrorInterceptorHandler handler,
  ) async {
    final options = error.requestOptions;
    final coordinator = _coordinator;
    final executor = _requestExecutor;
    if (error.response?.statusCode != 401 ||
        coordinator == null ||
        executor == null ||
        options.extra[AuthRequestPolicy.skipRefresh] == true ||
        options.extra[AuthRequestPolicy.replayed] == true) {
      handler.next(error);
      return;
    }

    final failedCredential =
        options.extra[AuthRequestPolicy.credentialSnapshot];
    if (failedCredential is! DeviceCredential) {
      handler.next(error);
      return;
    }

    final queuedWrite = options.extra[AuthRequestPolicy.queuedWrite] == true;
    final explicitSync =
        options.extra[AuthRequestPolicy.explicitSyncCenter] == true;
    final origin = queuedWrite
        ? (explicitSync
              ? SessionRefreshOrigin.syncCenter
              : SessionRefreshOrigin.queuedWrite)
        : SessionRefreshOrigin.request;

    try {
      final refreshed = await coordinator.refreshAfterUnauthorized(
        failedCredential: failedCredential,
        origin: origin,
      );
      if (refreshed is! Success<DeviceCredential>) {
        handler.next(error);
        return;
      }
      final credential = refreshed.data;
      if (queuedWrite || !_canReplay(options)) {
        handler.next(error);
        return;
      }

      final replay = options.copyWith(
        headers: {
          ...options.headers,
          'Authorization': 'Bearer ${credential.accessToken}',
        },
        extra: {
          ...options.extra,
          AuthRequestPolicy.credentialSnapshot: credential,
          AuthRequestPolicy.replayed: true,
        },
      );
      handler.resolve(await executor(replay));
    } on Object {
      handler.next(error);
    }
  }

  bool _canReplay(RequestOptions options) {
    switch (options.method.toUpperCase()) {
      case 'GET':
      case 'HEAD':
      case 'OPTIONS':
        return true;
    }
    for (final entry in options.headers.entries) {
      if (entry.key.toLowerCase() == 'idempotency-key' &&
          entry.value is String &&
          (entry.value as String).trim().isNotEmpty) {
        return true;
      }
    }
    return false;
  }
}
