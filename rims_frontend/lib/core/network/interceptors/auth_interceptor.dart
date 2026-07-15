import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';

import '../../../features/auth/domain/services/session_refresh_coordinator.dart';
import '../../../features/auth/domain/services/authenticated_request_lease.dart';
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
    TokenReader? tokenReader,
    AuthenticatedRequestLeaseReader? authenticatedRequestLeaseReader,
    SessionRefreshCoordinator? refreshCoordinator,
    SessionRefreshCoordinatorReader? refreshCoordinatorReader,
    AuthRequestExecutor? requestExecutor,
  }) : this._(
         tokenReader,
         authenticatedRequestLeaseReader,
         refreshCoordinator,
         refreshCoordinatorReader,
         requestExecutor,
       );

  const AuthInterceptor._(
    this._tokenReader,
    this._authenticatedRequestLeaseReader,
    this._refreshCoordinator,
    this._refreshCoordinatorReader,
    this._requestExecutor,
  ) : assert(_tokenReader != null || _authenticatedRequestLeaseReader != null);

  final TokenReader? _tokenReader;
  final AuthenticatedRequestLeaseReader? _authenticatedRequestLeaseReader;
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
      options.extra
        ..remove(AuthRequestPolicy.credentialSnapshot)
        ..remove(AuthRequestPolicy.authenticationEpoch)
        ..remove(AuthRequestPolicy.authenticatedRequestLease)
        ..remove(AuthRequestPolicy.repeatableBodyTemplate);
      if (options.data case final FormData formData) {
        options.extra[AuthRequestPolicy.repeatableBodyTemplate] = formData
            .clone();
      }
      if (AuthRequestPolicy.isQueuedWrite) {
        options.extra.putIfAbsent(AuthRequestPolicy.queuedWrite, () => true);
      }
      if (AuthRequestPolicy.isExplicitSyncCenter) {
        options.extra.putIfAbsent(
          AuthRequestPolicy.explicitSyncCenter,
          () => true,
        );
      }
      if (_hasAuthorizationHeader(options)) {
        handler.next(options);
        return;
      }
      final lease = await _authenticatedRequestLeaseReader?.call();
      if (lease != null) {
        _coordinator?.observeStableLease(lease);
        options.headers['Authorization'] = 'Bearer ${lease.token}';
        options.extra[AuthRequestPolicy.authenticatedRequestLease] = lease;
      } else if (_authenticatedRequestLeaseReader == null) {
        final token = await _tokenReader?.call();
        if (token != null && token.isNotEmpty) {
          options.headers['Authorization'] = 'Bearer $token';
        }
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

    final failedLease =
        options.extra[AuthRequestPolicy.authenticatedRequestLease];
    if (failedLease is! AuthenticatedRequestLease) {
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
      final activeBeforeRefresh = await _authenticatedRequestLeaseReader
          ?.call();
      if (activeBeforeRefresh == null ||
          activeBeforeRefresh.authEpoch != failedLease.authEpoch ||
          activeBeforeRefresh.token != failedLease.token ||
          !_sameCredential(
            activeBeforeRefresh.credential,
            failedLease.credential,
          )) {
        handler.next(error);
        return;
      }
      coordinator.observeStableLease(activeBeforeRefresh);
      final refreshed = await coordinator.refreshAfterUnauthorized(
        failedCredential: failedLease.credential,
        failedAuthEpoch: failedLease.authEpoch,
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
      final activeLease = await _authenticatedRequestLeaseReader?.call();
      if (activeLease == null ||
          activeLease.authEpoch != failedLease.authEpoch ||
          activeLease.token != credential.accessToken ||
          !_sameCredential(activeLease.credential, credential)) {
        handler.next(error);
        return;
      }
      coordinator.observeStableLease(activeLease);

      final replay = options.copyWith(
        data: _cloneReplayBody(options),
        headers: {
          ...options.headers,
          'Authorization': 'Bearer ${credential.accessToken}',
        },
        extra: {
          ...options.extra,
          AuthRequestPolicy.authenticatedRequestLease: failedLease
              .withCredential(credential),
          AuthRequestPolicy.replayed: true,
        },
      );
      try {
        handler.resolve(await executor(replay));
      } on DioException catch (replayError) {
        handler.next(replayError);
      } on Object catch (replayError, stackTrace) {
        handler.next(
          DioException(
            requestOptions: replay,
            type: DioExceptionType.unknown,
            error: replayError,
            stackTrace: stackTrace,
          ),
        );
      }
    } on Object {
      handler.next(error);
    }
  }

  bool _canReplay(RequestOptions options) {
    if (!_hasRepeatableBody(options)) return false;
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

  bool _hasRepeatableBody(RequestOptions options) {
    final data = options.data;
    if (data == null || data is String || data is num || data is bool) {
      return true;
    }
    if (data is Uint8List || data is Map || data is List) return true;
    if (data is FormData) {
      return options.extra[AuthRequestPolicy.repeatableBodyTemplate]
          is FormData;
    }
    return false;
  }

  Object? _cloneReplayBody(RequestOptions options) {
    final data = options.data;
    if (data is FormData) {
      return (options.extra[AuthRequestPolicy.repeatableBodyTemplate]
              as FormData)
          .clone();
    }
    if (data is Uint8List) return Uint8List.fromList(data);
    if (data is Map) return Map<Object?, Object?>.from(data);
    if (data is List) return List<Object?>.from(data);
    return data;
  }

  bool _hasAuthorizationHeader(RequestOptions options) =>
      options.headers.keys.any((name) => name.toLowerCase() == 'authorization');

  bool _sameCredential(DeviceCredential? active, DeviceCredential expected) =>
      active?.accountId == expected.accountId &&
      active?.sessionId == expected.sessionId &&
      active?.generation == expected.generation &&
      active?.accessToken == expected.accessToken;
}
