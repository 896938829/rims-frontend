import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

typedef SafeLogWriter = void Function(String message);

final class SafeLoggingInterceptor extends Interceptor {
  SafeLoggingInterceptor({SafeLogWriter? log}) : _log = log ?? _debugLog;

  static const _startedAtKey = 'rims.safeLog.startedAt';
  final SafeLogWriter _log;

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    options.extra[_startedAtKey] = DateTime.now().microsecondsSinceEpoch;
    _log(
      'HTTP request method=${options.method} path=${options.uri.path} '
      'requestBytes=${_requestBytes(options.data)}',
    );
    handler.next(options);
  }

  @override
  void onResponse(
    Response<dynamic> response,
    ResponseInterceptorHandler handler,
  ) {
    final options = response.requestOptions;
    _log(
      'HTTP response method=${options.method} path=${options.uri.path} '
      'status=${response.statusCode ?? 0} durationMs=${_durationMs(options)} '
      'traceId=${_traceId(response.data, response.headers)} '
      'responseBytes=${_responseBytes(response)}',
    );
    handler.next(response);
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) {
    final options = err.requestOptions;
    _log(
      'HTTP error method=${options.method} path=${options.uri.path} '
      'status=${err.response?.statusCode ?? 0} '
      'durationMs=${_durationMs(options)} '
      'traceId=${_traceId(err.response?.data, err.response?.headers)}',
    );
    handler.next(err);
  }

  static int _requestBytes(Object? data) {
    if (data is FormData) return data.length;
    if (data is List<int>) return data.length;
    return 0;
  }

  static int _responseBytes(Response<dynamic> response) {
    final length = response.headers.value(Headers.contentLengthHeader);
    if (length != null) return int.tryParse(length) ?? 0;
    final data = response.data;
    if (data is List<int>) return data.length;
    return 0;
  }

  static int _durationMs(RequestOptions options) {
    final startedAt = options.extra[_startedAtKey];
    if (startedAt is! int) return 0;
    return ((DateTime.now().microsecondsSinceEpoch - startedAt) / 1000).round();
  }

  static String _traceId(Object? data, Headers? headers) {
    final header = headers?.value('X-Trace-ID');
    if (header != null && header.isNotEmpty) return header;
    if (data is Map && data['traceId'] is String) {
      return data['traceId'] as String;
    }
    return '-';
  }

  static void _debugLog(String message) {
    if (kDebugMode) debugPrint(message);
  }
}

Interceptor buildLoggingInterceptor() => SafeLoggingInterceptor();
