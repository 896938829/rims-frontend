import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

Interceptor buildLoggingInterceptor() {
  return LogInterceptor(
    requestBody: kDebugMode,
    responseBody: kDebugMode,
    requestHeader: kDebugMode,
    responseHeader: false,
    error: kDebugMode,
    logPrint: (object) {
      if (kDebugMode) {
        debugPrint(object.toString());
      }
    },
  );
}
