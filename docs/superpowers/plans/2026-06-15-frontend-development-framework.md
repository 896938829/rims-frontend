# Frontend Development Framework Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the first project framework skeleton for the RIMS Flutter frontend using feature-first MVVM, repository boundaries, shared core utilities, routing, networking, events, resources, and tests.

**Architecture:** The implementation follows feature-first MVVM with Repository and a lightweight Domain layer. Shared framework code lives under `lib/core`, app navigation under `lib/routes`, and feature code under `lib/features/<feature_name>`.

**Tech Stack:** Flutter, Dart 3.12, Provider, GoRouter, Dio, flutter_secure_storage, shared_preferences, flutter_test.

---

## File Structure

Create or modify these files under `rims_frontend`:

```text
lib/
  app.dart
  main.dart
  core/
    constants/
      app_constants.dart
    events/
      app_event.dart
      app_event_bus.dart
    network/
      api_client.dart
      api_endpoints.dart
      api_exception_mapper.dart
      interceptors/
        auth_interceptor.dart
        logging_interceptor.dart
    resources/
      app_icons.dart
      app_images.dart
      app_strings.dart
    result/
      failure.dart
      result.dart
    storage/
      app_preferences.dart
      app_secure_storage.dart
    theme/
      app_colors.dart
      app_text_styles.dart
      app_theme.dart
  features/
    sample/
      data/
        datasources/
          sample_remote_datasource.dart
        models/
          sample_item_model.dart
        repositories/
          sample_repository_impl.dart
      domain/
        entities/
          sample_item.dart
        repositories/
          sample_repository.dart
        usecases/
          get_sample_items_usecase.dart
      presentation/
        pages/
          sample_page.dart
        view_models/
          sample_view_model.dart
        widgets/
          sample_item_tile.dart
  routes/
    app_router.dart
    route_paths.dart

assets/
  icons/
    .gitkeep
  images/
    .gitkeep

test/
  core/
    events/
      app_event_bus_test.dart
    network/
      api_exception_mapper_test.dart
    result/
      result_test.dart
  features/
    sample/
      presentation/
        sample_view_model_test.dart
  routes/
    route_paths_test.dart
```

## Task 0: Dependency Baseline

**Files:**
- Modify: `rims_frontend/pubspec.yaml`
- Modify: `rims_frontend/pubspec.lock`

- [ ] **Step 1: Add framework dependencies**

Modify `rims_frontend/pubspec.yaml`:

```yaml
name: rims_frontend
description: "A RIMS project."
publish_to: 'none'
version: 0.1.0+1

environment:
  sdk: ^3.12.1

dependencies:
  connectivity_plus: ^7.1.1
  dio: ^5.9.2
  file_picker: ^11.0.2
  fl_chart: ^1.2.0
  flutter:
    sdk: flutter
  flutter_secure_storage: ^10.3.1
  go_router: ^17.3.0
  image_picker: ^1.2.2
  intl: ^0.20.2
  json_annotation: ^4.12.0
  mobile_scanner: ^7.2.0
  path_provider: ^2.1.5
  provider: ^6.1.5+1
  share_plus: ^12.0.0
  shared_preferences: ^2.5.5
  uuid: ^4.5.3

dev_dependencies:
  build_runner: ^2.15.0
  flutter_lints: ^6.0.0
  flutter_test:
    sdk: flutter
  json_serializable: ^6.14.0

flutter:
  uses-material-design: true
```

- [ ] **Step 2: Resolve dependencies**

Run:

```powershell
flutter pub get
```

Expected: dependencies resolve and `pubspec.lock` updates.

- [ ] **Step 3: Run baseline verification**

Run:

```powershell
flutter analyze
flutter test
```

Expected: analyzer PASS and generated Flutter test PASS before architecture files are added.

- [ ] **Step 4: Commit**

Run:

```powershell
git add pubspec.yaml pubspec.lock
git commit -m "chore: add frontend framework dependencies"
```

## Task 1: Result And Failure Foundation

**Files:**
- Create: `rims_frontend/lib/core/result/failure.dart`
- Create: `rims_frontend/lib/core/result/result.dart`
- Create: `rims_frontend/test/core/result/result_test.dart`

- [ ] **Step 1: Write the failing tests**

Create `rims_frontend/test/core/result/result_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:rims_frontend/core/result/failure.dart';
import 'package:rims_frontend/core/result/result.dart';

void main() {
  group('Result', () {
    test('Success exposes data', () {
      const result = Success<int>(42);

      expect(result.data, 42);
    });

    test('FailureResult exposes failure', () {
      const failure = NetworkFailure(message: 'No connection');
      const result = FailureResult<int>(failure);

      expect(result.failure, failure);
      expect(result.failure.message, 'No connection');
    });
  });

  group('Failure', () {
    test('failures with same type and message are equal', () {
      const first = ServerFailure(message: 'Server error', statusCode: 500);
      const second = ServerFailure(message: 'Server error', statusCode: 500);

      expect(first, second);
    });

    test('unknown failure has default message', () {
      const failure = UnknownFailure();

      expect(failure.message, 'Unexpected error');
    });
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```powershell
flutter test test/core/result/result_test.dart
```

Expected: FAIL because `Failure`, `Result`, `Success`, and `FailureResult` do not exist.

- [ ] **Step 3: Write minimal implementation**

Create `rims_frontend/lib/core/result/failure.dart`:

```dart
sealed class Failure {
  const Failure({
    required this.message,
    this.statusCode,
    this.cause,
  });

  final String message;
  final int? statusCode;
  final Object? cause;

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other.runtimeType == runtimeType &&
            other is Failure &&
            other.message == message &&
            other.statusCode == statusCode;
  }

  @override
  int get hashCode => Object.hash(runtimeType, message, statusCode);

  @override
  String toString() {
    return '$runtimeType(message: $message, statusCode: $statusCode)';
  }
}

final class NetworkFailure extends Failure {
  const NetworkFailure({
    super.message = 'Network unavailable',
    super.statusCode,
    super.cause,
  });
}

final class AuthenticationFailure extends Failure {
  const AuthenticationFailure({
    super.message = 'Authentication required',
    super.statusCode,
    super.cause,
  });
}

final class AuthorizationFailure extends Failure {
  const AuthorizationFailure({
    super.message = 'Permission denied',
    super.statusCode,
    super.cause,
  });
}

final class ValidationFailure extends Failure {
  const ValidationFailure({
    super.message = 'Invalid request',
    super.statusCode,
    super.cause,
  });
}

final class NotFoundFailure extends Failure {
  const NotFoundFailure({
    super.message = 'Resource not found',
    super.statusCode,
    super.cause,
  });
}

final class ServerFailure extends Failure {
  const ServerFailure({
    super.message = 'Server error',
    super.statusCode,
    super.cause,
  });
}

final class UnknownFailure extends Failure {
  const UnknownFailure({
    super.message = 'Unexpected error',
    super.statusCode,
    super.cause,
  });
}
```

Create `rims_frontend/lib/core/result/result.dart`:

```dart
import 'failure.dart';

sealed class Result<T> {
  const Result();

  bool get isSuccess => this is Success<T>;
  bool get isFailure => this is FailureResult<T>;

  R when<R>({
    required R Function(T data) success,
    required R Function(Failure failure) failure,
  }) {
    return switch (this) {
      Success<T>(:final data) => success(data),
      FailureResult<T>(:final failure) => failure(failure),
    };
  }
}

final class Success<T> extends Result<T> {
  const Success(this.data);

  final T data;
}

final class FailureResult<T> extends Result<T> {
  const FailureResult(this.failure);

  final Failure failure;
}
```

- [ ] **Step 4: Run test to verify it passes**

Run:

```powershell
flutter test test/core/result/result_test.dart
```

Expected: PASS.

- [ ] **Step 5: Commit**

Run:

```powershell
git add lib/core/result/failure.dart lib/core/result/result.dart test/core/result/result_test.dart
git commit -m "feat: add result and failure primitives"
```

## Task 2: Application Event Bus

**Files:**
- Create: `rims_frontend/lib/core/events/app_event.dart`
- Create: `rims_frontend/lib/core/events/app_event_bus.dart`
- Create: `rims_frontend/test/core/events/app_event_bus_test.dart`

- [ ] **Step 1: Write the failing tests**

Create `rims_frontend/test/core/events/app_event_bus_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:rims_frontend/core/events/app_event.dart';
import 'package:rims_frontend/core/events/app_event_bus.dart';

final class TestEvent extends AppEvent {
  const TestEvent(this.value);

  final String value;
}

final class OtherEvent extends AppEvent {
  const OtherEvent();
}

void main() {
  test('publishes events to typed subscribers', () async {
    final eventBus = AppEventBus();
    addTearDown(eventBus.dispose);

    final future = eventBus.on<TestEvent>().first;

    eventBus.publish(const TestEvent('ready'));

    final event = await future;
    expect(event.value, 'ready');
  });

  test('typed stream ignores other event types', () async {
    final eventBus = AppEventBus();
    addTearDown(eventBus.dispose);

    final events = <TestEvent>[];
    final subscription = eventBus.on<TestEvent>().listen(events.add);
    addTearDown(subscription.cancel);

    eventBus.publish(const OtherEvent());
    await Future<void>.delayed(Duration.zero);

    expect(events, isEmpty);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```powershell
flutter test test/core/events/app_event_bus_test.dart
```

Expected: FAIL because `AppEvent` and `AppEventBus` do not exist.

- [ ] **Step 3: Write minimal implementation**

Create `rims_frontend/lib/core/events/app_event.dart`:

```dart
abstract class AppEvent {
  const AppEvent();
}

final class AuthStateChangedEvent extends AppEvent {
  const AuthStateChangedEvent({required this.isAuthenticated});

  final bool isAuthenticated;
}

final class TokenExpiredEvent extends AppEvent {
  const TokenExpiredEvent();
}

final class UserProfileUpdatedEvent extends AppEvent {
  const UserProfileUpdatedEvent();
}

final class GlobalRefreshRequestedEvent extends AppEvent {
  const GlobalRefreshRequestedEvent();
}
```

Create `rims_frontend/lib/core/events/app_event_bus.dart`:

```dart
import 'dart:async';

import 'app_event.dart';

final class AppEventBus {
  AppEventBus();

  final StreamController<AppEvent> _controller =
      StreamController<AppEvent>.broadcast();

  void publish(AppEvent event) {
    if (_controller.isClosed) {
      return;
    }

    _controller.add(event);
  }

  Stream<T> on<T extends AppEvent>() {
    return _controller.stream.where((event) => event is T).cast<T>();
  }

  Future<void> dispose() async {
    await _controller.close();
  }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run:

```powershell
flutter test test/core/events/app_event_bus_test.dart
```

Expected: PASS.

- [ ] **Step 5: Commit**

Run:

```powershell
git add lib/core/events/app_event.dart lib/core/events/app_event_bus.dart test/core/events/app_event_bus_test.dart
git commit -m "feat: add app event bus"
```

## Task 3: Network Client And Error Mapping

**Files:**
- Create: `rims_frontend/lib/core/network/api_client.dart`
- Create: `rims_frontend/lib/core/network/api_endpoints.dart`
- Create: `rims_frontend/lib/core/network/api_exception_mapper.dart`
- Create: `rims_frontend/lib/core/network/interceptors/auth_interceptor.dart`
- Create: `rims_frontend/lib/core/network/interceptors/logging_interceptor.dart`
- Create: `rims_frontend/test/core/network/api_exception_mapper_test.dart`

- [ ] **Step 1: Write the failing tests**

Create `rims_frontend/test/core/network/api_exception_mapper_test.dart`:

```dart
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rims_frontend/core/network/api_exception_mapper.dart';
import 'package:rims_frontend/core/result/failure.dart';

void main() {
  late ApiExceptionMapper mapper;

  setUp(() {
    mapper = const ApiExceptionMapper();
  });

  DioException exceptionForStatus(int statusCode) {
    return DioException(
      requestOptions: RequestOptions(path: '/test'),
      response: Response<dynamic>(
        requestOptions: RequestOptions(path: '/test'),
        statusCode: statusCode,
        data: {'message': 'Mapped message'},
      ),
    );
  }

  test('maps timeout to NetworkFailure', () {
    final failure = mapper.map(
      DioException(
        requestOptions: RequestOptions(path: '/test'),
        type: DioExceptionType.connectionTimeout,
      ),
    );

    expect(failure, isA<NetworkFailure>());
  });

  test('maps 401 to AuthenticationFailure', () {
    final failure = mapper.map(exceptionForStatus(401));

    expect(failure, isA<AuthenticationFailure>());
    expect(failure.statusCode, 401);
    expect(failure.message, 'Mapped message');
  });

  test('maps 403 to AuthorizationFailure', () {
    final failure = mapper.map(exceptionForStatus(403));

    expect(failure, isA<AuthorizationFailure>());
  });

  test('maps 404 to NotFoundFailure', () {
    final failure = mapper.map(exceptionForStatus(404));

    expect(failure, isA<NotFoundFailure>());
  });

  test('maps 422 to ValidationFailure', () {
    final failure = mapper.map(exceptionForStatus(422));

    expect(failure, isA<ValidationFailure>());
  });

  test('maps 500 to ServerFailure', () {
    final failure = mapper.map(exceptionForStatus(500));

    expect(failure, isA<ServerFailure>());
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```powershell
flutter test test/core/network/api_exception_mapper_test.dart
```

Expected: FAIL because network mapper files do not exist.

- [ ] **Step 3: Write minimal implementation**

Create `rims_frontend/lib/core/network/api_endpoints.dart`:

```dart
abstract final class ApiEndpoints {
  static const String baseUrl = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: 'https://api.example.com',
  );

  static const String sampleItems = '/sample/items';
}
```

Create `rims_frontend/lib/core/network/api_exception_mapper.dart`:

```dart
import 'package:dio/dio.dart';

import '../result/failure.dart';

final class ApiExceptionMapper {
  const ApiExceptionMapper();

  Failure map(Object error) {
    if (error is! DioException) {
      return UnknownFailure(cause: error);
    }

    final statusCode = error.response?.statusCode;
    final message = _messageFrom(error);

    if (_isNetworkError(error)) {
      return NetworkFailure(message: message, statusCode: statusCode, cause: error);
    }

    return switch (statusCode) {
      401 => AuthenticationFailure(
          message: message,
          statusCode: statusCode,
          cause: error,
        ),
      403 => AuthorizationFailure(
          message: message,
          statusCode: statusCode,
          cause: error,
        ),
      404 => NotFoundFailure(
          message: message,
          statusCode: statusCode,
          cause: error,
        ),
      422 => ValidationFailure(
          message: message,
          statusCode: statusCode,
          cause: error,
        ),
      >= 500 && < 600 => ServerFailure(
          message: message,
          statusCode: statusCode,
          cause: error,
        ),
      _ => UnknownFailure(
          message: message,
          statusCode: statusCode,
          cause: error,
        ),
    };
  }

  bool _isNetworkError(DioException error) {
    return switch (error.type) {
      DioExceptionType.connectionTimeout ||
      DioExceptionType.sendTimeout ||
      DioExceptionType.receiveTimeout ||
      DioExceptionType.connectionError =>
        true,
      _ => false,
    };
  }

  String _messageFrom(DioException error) {
    final data = error.response?.data;

    if (data is Map<String, dynamic>) {
      final message = data['message'];
      if (message is String && message.isNotEmpty) {
        return message;
      }
    }

    if (error.message case final message? when message.isNotEmpty) {
      return message;
    }

    return 'Request failed';
  }
}
```

Create `rims_frontend/lib/core/network/api_client.dart`:

```dart
import 'package:dio/dio.dart';

import '../result/result.dart';
import 'api_endpoints.dart';
import 'api_exception_mapper.dart';

final class ApiClient {
  ApiClient({
    Dio? dio,
    ApiExceptionMapper exceptionMapper = const ApiExceptionMapper(),
  })  : _dio = dio ?? Dio(),
        _exceptionMapper = exceptionMapper {
    _dio.options = BaseOptions(
      baseUrl: ApiEndpoints.baseUrl,
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 15),
      sendTimeout: const Duration(seconds: 15),
      headers: const {
        'Accept': 'application/json',
        'Content-Type': 'application/json',
      },
    );
  }

  final Dio _dio;
  final ApiExceptionMapper _exceptionMapper;

  Dio get dio => _dio;

  Future<Result<Response<T>>> get<T>(
    String path, {
    Map<String, dynamic>? queryParameters,
    Options? options,
  }) {
    return _request(
      () => _dio.get<T>(
        path,
        queryParameters: queryParameters,
        options: options,
      ),
    );
  }

  Future<Result<Response<T>>> post<T>(
    String path, {
    Object? data,
    Map<String, dynamic>? queryParameters,
    Options? options,
  }) {
    return _request(
      () => _dio.post<T>(
        path,
        data: data,
        queryParameters: queryParameters,
        options: options,
      ),
    );
  }

  Future<Result<Response<T>>> put<T>(
    String path, {
    Object? data,
    Map<String, dynamic>? queryParameters,
    Options? options,
  }) {
    return _request(
      () => _dio.put<T>(
        path,
        data: data,
        queryParameters: queryParameters,
        options: options,
      ),
    );
  }

  Future<Result<Response<T>>> patch<T>(
    String path, {
    Object? data,
    Map<String, dynamic>? queryParameters,
    Options? options,
  }) {
    return _request(
      () => _dio.patch<T>(
        path,
        data: data,
        queryParameters: queryParameters,
        options: options,
      ),
    );
  }

  Future<Result<Response<T>>> delete<T>(
    String path, {
    Object? data,
    Map<String, dynamic>? queryParameters,
    Options? options,
  }) {
    return _request(
      () => _dio.delete<T>(
        path,
        data: data,
        queryParameters: queryParameters,
        options: options,
      ),
    );
  }

  Future<Result<Response<T>>> _request<T>(
    Future<Response<T>> Function() request,
  ) async {
    try {
      return Success<Response<T>>(await request());
    } catch (error) {
      return FailureResult<Response<T>>(_exceptionMapper.map(error));
    }
  }
}
```

Create `rims_frontend/lib/core/network/interceptors/auth_interceptor.dart`:

```dart
import 'package:dio/dio.dart';

typedef TokenReader = Future<String?> Function();

final class AuthInterceptor extends Interceptor {
  const AuthInterceptor({required TokenReader tokenReader})
      : _tokenReader = tokenReader;

  final TokenReader _tokenReader;

  @override
  void onRequest(
    RequestOptions options,
    RequestInterceptorHandler handler,
  ) async {
    final token = await _tokenReader();

    if (token != null && token.isNotEmpty) {
      options.headers['Authorization'] = 'Bearer $token';
    }

    handler.next(options);
  }
}
```

Create `rims_frontend/lib/core/network/interceptors/logging_interceptor.dart`:

```dart
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
```

- [ ] **Step 4: Run test to verify it passes**

Run:

```powershell
flutter test test/core/network/api_exception_mapper_test.dart
```

Expected: PASS.

- [ ] **Step 5: Commit**

Run:

```powershell
git add lib/core/network test/core/network
git commit -m "feat: add network client foundation"
```

## Task 4: Storage, Resources, Theme, And Constants

**Files:**
- Create: `rims_frontend/lib/core/constants/app_constants.dart`
- Create: `rims_frontend/lib/core/resources/app_icons.dart`
- Create: `rims_frontend/lib/core/resources/app_images.dart`
- Create: `rims_frontend/lib/core/resources/app_strings.dart`
- Create: `rims_frontend/lib/core/storage/app_preferences.dart`
- Create: `rims_frontend/lib/core/storage/app_secure_storage.dart`
- Create: `rims_frontend/lib/core/theme/app_colors.dart`
- Create: `rims_frontend/lib/core/theme/app_text_styles.dart`
- Create: `rims_frontend/lib/core/theme/app_theme.dart`
- Create: `rims_frontend/assets/icons/.gitkeep`
- Create: `rims_frontend/assets/images/.gitkeep`
- Modify: `rims_frontend/pubspec.yaml`

- [ ] **Step 1: Add framework constants, resource entries, and theme files**

Create `rims_frontend/lib/core/constants/app_constants.dart`:

```dart
abstract final class AppConstants {
  static const int kMaxRetryCount = 3;
  static const Duration kRequestTimeout = Duration(seconds: 15);
}
```

Create `rims_frontend/lib/core/resources/app_images.dart`:

```dart
abstract final class AppImages {
  static const String logo = 'assets/images/logo.png';
}
```

Create `rims_frontend/lib/core/resources/app_icons.dart`:

```dart
abstract final class AppIcons {
  static const String scan = 'assets/icons/scan.svg';
}
```

Create `rims_frontend/lib/core/resources/app_strings.dart`:

```dart
abstract final class AppStrings {
  static const String appName = 'RIMS';
  static const String sampleTitle = 'RIMS Framework';
}
```

Create `rims_frontend/lib/core/theme/app_colors.dart`:

```dart
import 'package:flutter/material.dart';

abstract final class AppColors {
  static const Color primary = Color(0xFF1565C0);
  static const Color secondary = Color(0xFF00897B);
  static const Color background = Color(0xFFF7F9FC);
  static const Color surface = Color(0xFFFFFFFF);
  static const Color textPrimary = Color(0xFF1F2937);
  static const Color textSecondary = Color(0xFF6B7280);
  static const Color error = Color(0xFFD32F2F);
}
```

Create `rims_frontend/lib/core/theme/app_text_styles.dart`:

```dart
import 'package:flutter/material.dart';

import 'app_colors.dart';

abstract final class AppTextStyles {
  static const TextStyle titleLarge = TextStyle(
    color: AppColors.textPrimary,
    fontSize: 22,
    fontWeight: FontWeight.w700,
  );

  static const TextStyle bodyMedium = TextStyle(
    color: AppColors.textPrimary,
    fontSize: 14,
    fontWeight: FontWeight.w400,
  );

  static const TextStyle labelMedium = TextStyle(
    color: AppColors.textSecondary,
    fontSize: 12,
    fontWeight: FontWeight.w500,
  );
}
```

Create `rims_frontend/lib/core/theme/app_theme.dart`:

```dart
import 'package:flutter/material.dart';

import 'app_colors.dart';

abstract final class AppTheme {
  static ThemeData get light {
    final colorScheme = ColorScheme.fromSeed(
      seedColor: AppColors.primary,
      primary: AppColors.primary,
      secondary: AppColors.secondary,
      error: AppColors.error,
      surface: AppColors.surface,
    );

    return ThemeData(
      useMaterial3: true,
      colorScheme: colorScheme,
      scaffoldBackgroundColor: AppColors.background,
      appBarTheme: const AppBarTheme(
        centerTitle: false,
        backgroundColor: AppColors.surface,
        foregroundColor: AppColors.textPrimary,
        elevation: 0,
      ),
    );
  }
}
```

- [ ] **Step 2: Add storage wrappers**

Create `rims_frontend/lib/core/storage/app_secure_storage.dart`:

```dart
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

final class AppSecureStorage {
  const AppSecureStorage({
    FlutterSecureStorage storage = const FlutterSecureStorage(),
  }) : _storage = storage;

  static const String kAccessTokenKey = 'access_token';

  final FlutterSecureStorage _storage;

  Future<void> saveAccessToken(String token) {
    return _storage.write(key: kAccessTokenKey, value: token);
  }

  Future<String?> readAccessToken() {
    return _storage.read(key: kAccessTokenKey);
  }

  Future<void> clearAccessToken() {
    return _storage.delete(key: kAccessTokenKey);
  }
}
```

Create `rims_frontend/lib/core/storage/app_preferences.dart`:

```dart
import 'package:shared_preferences/shared_preferences.dart';

final class AppPreferences {
  const AppPreferences(this._preferences);

  static const String kLocaleKey = 'locale';
  static const String kThemeModeKey = 'theme_mode';

  final SharedPreferences _preferences;

  String? get locale => _preferences.getString(kLocaleKey);

  Future<bool> setLocale(String locale) {
    return _preferences.setString(kLocaleKey, locale);
  }

  String? get themeMode => _preferences.getString(kThemeModeKey);

  Future<bool> setThemeMode(String themeMode) {
    return _preferences.setString(kThemeModeKey, themeMode);
  }
}
```

- [ ] **Step 3: Add asset directories and pubspec entries**

Create empty files:

```text
rims_frontend/assets/icons/.gitkeep
rims_frontend/assets/images/.gitkeep
```

Modify the bottom of `rims_frontend/pubspec.yaml` so the Flutter section reads:

```yaml
flutter:
  uses-material-design: true
  assets:
    - assets/icons/
    - assets/images/
```

- [ ] **Step 4: Run analyzer**

Run:

```powershell
flutter analyze
```

Expected: PASS with no new errors from the added framework files.

- [ ] **Step 5: Commit**

Run:

```powershell
git add lib/core/constants lib/core/resources lib/core/storage lib/core/theme assets pubspec.yaml
git commit -m "feat: add resources storage and theme foundation"
```

## Task 5: Router And App Shell

**Files:**
- Create: `rims_frontend/lib/routes/route_paths.dart`
- Create: `rims_frontend/lib/routes/app_router.dart`
- Modify: `rims_frontend/lib/app.dart`
- Modify: `rims_frontend/lib/main.dart`
- Create: `rims_frontend/test/routes/route_paths_test.dart`

- [ ] **Step 1: Write the failing route test**

Create `rims_frontend/test/routes/route_paths_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:rims_frontend/routes/route_paths.dart';

void main() {
  test('route paths expose root and sample routes', () {
    expect(RoutePaths.root, '/');
    expect(RoutePaths.sample, '/sample');
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```powershell
flutter test test/routes/route_paths_test.dart
```

Expected: FAIL because `RoutePaths` does not exist.

- [ ] **Step 3: Add router files**

Create `rims_frontend/lib/routes/route_paths.dart`:

```dart
abstract final class RoutePaths {
  static const String root = '/';
  static const String sample = '/sample';
}
```

Create `rims_frontend/lib/routes/app_router.dart`:

```dart
import 'package:go_router/go_router.dart';

import '../features/sample/presentation/pages/sample_page.dart';
import 'route_paths.dart';

GoRouter createAppRouter() {
  return GoRouter(
    initialLocation: RoutePaths.root,
    routes: [
      GoRoute(
        path: RoutePaths.root,
        builder: (context, state) => const SamplePage(),
      ),
      GoRoute(
        path: RoutePaths.sample,
        builder: (context, state) => const SamplePage(),
      ),
    ],
  );
}
```

- [ ] **Step 4: Update app shell**

Modify `rims_frontend/lib/app.dart`:

```dart
import 'package:flutter/material.dart';

import 'core/resources/app_strings.dart';
import 'core/theme/app_theme.dart';
import 'routes/app_router.dart';

class MainApp extends StatelessWidget {
  const MainApp({super.key});

  @override
  Widget build(BuildContext context) {
    final router = createAppRouter();

    return MaterialApp.router(
      title: AppStrings.appName,
      theme: AppTheme.light,
      routerConfig: router,
    );
  }
}
```

Modify `rims_frontend/lib/main.dart`:

```dart
import 'package:flutter/material.dart';

import 'app.dart';

export 'app.dart' show MainApp;

void main() {
  runApp(const MainApp());
}
```

- [ ] **Step 5: Run route test and analyzer**

Run:

```powershell
flutter test test/routes/route_paths_test.dart
flutter analyze
```

Expected: route test PASS and analyzer PASS after the sample feature from Task 6 exists. If running Task 5 before Task 6, analyzer may fail because `SamplePage` is not yet defined; run Task 6 next before committing.

- [ ] **Step 6: Commit after Task 6 sample page exists**

Run after Task 6 implementation has been added:

```powershell
git add lib/app.dart lib/main.dart lib/routes test/routes
git commit -m "feat: add router and app shell"
```

## Task 6: Sample Feature Skeleton

**Files:**
- Create: `rims_frontend/lib/features/sample/domain/entities/sample_item.dart`
- Create: `rims_frontend/lib/features/sample/domain/repositories/sample_repository.dart`
- Create: `rims_frontend/lib/features/sample/domain/usecases/get_sample_items_usecase.dart`
- Create: `rims_frontend/lib/features/sample/data/models/sample_item_model.dart`
- Create: `rims_frontend/lib/features/sample/data/datasources/sample_remote_datasource.dart`
- Create: `rims_frontend/lib/features/sample/data/repositories/sample_repository_impl.dart`
- Create: `rims_frontend/lib/features/sample/presentation/view_models/sample_view_model.dart`
- Create: `rims_frontend/lib/features/sample/presentation/pages/sample_page.dart`
- Create: `rims_frontend/lib/features/sample/presentation/widgets/sample_item_tile.dart`
- Create: `rims_frontend/test/features/sample/presentation/sample_view_model_test.dart`

- [ ] **Step 1: Write the failing ViewModel tests**

Create `rims_frontend/test/features/sample/presentation/sample_view_model_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:rims_frontend/core/result/failure.dart';
import 'package:rims_frontend/core/result/result.dart';
import 'package:rims_frontend/features/sample/domain/entities/sample_item.dart';
import 'package:rims_frontend/features/sample/domain/repositories/sample_repository.dart';
import 'package:rims_frontend/features/sample/domain/usecases/get_sample_items_usecase.dart';
import 'package:rims_frontend/features/sample/presentation/view_models/sample_view_model.dart';

final class FakeSampleRepository implements SampleRepository {
  FakeSampleRepository(this.result);

  final Result<List<SampleItem>> result;

  @override
  Future<Result<List<SampleItem>>> getItems() async {
    return result;
  }
}

void main() {
  test('loadItems publishes loaded items', () async {
    final viewModel = SampleViewModel(
      getSampleItemsUseCase: GetSampleItemsUseCase(
        FakeSampleRepository(
          const Success<List<SampleItem>>([
            SampleItem(id: '1', title: 'Inventory'),
          ]),
        ),
      ),
    );

    await viewModel.loadItems();

    expect(viewModel.isLoading, isFalse);
    expect(viewModel.items, hasLength(1));
    expect(viewModel.items.first.title, 'Inventory');
    expect(viewModel.failure, isNull);
  });

  test('loadItems publishes failure', () async {
    final viewModel = SampleViewModel(
      getSampleItemsUseCase: GetSampleItemsUseCase(
        FakeSampleRepository(
          const FailureResult<List<SampleItem>>(
            NetworkFailure(message: 'Offline'),
          ),
        ),
      ),
    );

    await viewModel.loadItems();

    expect(viewModel.isLoading, isFalse);
    expect(viewModel.items, isEmpty);
    expect(viewModel.failure, isA<NetworkFailure>());
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```powershell
flutter test test/features/sample/presentation/sample_view_model_test.dart
```

Expected: FAIL because sample feature files do not exist.

- [ ] **Step 3: Add domain files**

Create `rims_frontend/lib/features/sample/domain/entities/sample_item.dart`:

```dart
final class SampleItem {
  const SampleItem({
    required this.id,
    required this.title,
  });

  final String id;
  final String title;
}
```

Create `rims_frontend/lib/features/sample/domain/repositories/sample_repository.dart`:

```dart
import '../../../../core/result/result.dart';
import '../entities/sample_item.dart';

abstract interface class SampleRepository {
  Future<Result<List<SampleItem>>> getItems();
}
```

Create `rims_frontend/lib/features/sample/domain/usecases/get_sample_items_usecase.dart`:

```dart
import '../../../../core/result/result.dart';
import '../entities/sample_item.dart';
import '../repositories/sample_repository.dart';

final class GetSampleItemsUseCase {
  const GetSampleItemsUseCase(this._repository);

  final SampleRepository _repository;

  Future<Result<List<SampleItem>>> call() {
    return _repository.getItems();
  }
}
```

- [ ] **Step 4: Add data files**

Create `rims_frontend/lib/features/sample/data/models/sample_item_model.dart`:

```dart
import '../../domain/entities/sample_item.dart';

final class SampleItemModel {
  const SampleItemModel({
    required this.id,
    required this.title,
  });

  factory SampleItemModel.fromJson(Map<String, dynamic> json) {
    return SampleItemModel(
      id: json['id'] as String,
      title: json['title'] as String,
    );
  }

  final String id;
  final String title;

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'title': title,
    };
  }

  SampleItem toEntity() {
    return SampleItem(id: id, title: title);
  }
}
```

Create `rims_frontend/lib/features/sample/data/datasources/sample_remote_datasource.dart`:

```dart
import '../../../../core/network/api_client.dart';
import '../../../../core/network/api_endpoints.dart';
import '../../../../core/result/failure.dart';
import '../../../../core/result/result.dart';
import '../models/sample_item_model.dart';

final class SampleRemoteDataSource {
  const SampleRemoteDataSource(this._apiClient);

  final ApiClient _apiClient;

  Future<Result<List<SampleItemModel>>> getItems() async {
    final result = await _apiClient.get<List<dynamic>>(ApiEndpoints.sampleItems);

    return result.when(
      success: (response) {
        final data = response.data ?? <dynamic>[];
        final items = data
            .whereType<Map<String, dynamic>>()
            .map(SampleItemModel.fromJson)
            .toList(growable: false);

        return Success<List<SampleItemModel>>(items);
      },
      failure: FailureResult<List<SampleItemModel>>.new,
    );
  }
}
```

Create `rims_frontend/lib/features/sample/data/repositories/sample_repository_impl.dart`:

```dart
import '../../../../core/result/result.dart';
import '../../domain/entities/sample_item.dart';
import '../../domain/repositories/sample_repository.dart';
import '../datasources/sample_remote_datasource.dart';

final class SampleRepositoryImpl implements SampleRepository {
  const SampleRepositoryImpl(this._remoteDataSource);

  final SampleRemoteDataSource _remoteDataSource;

  @override
  Future<Result<List<SampleItem>>> getItems() async {
    final result = await _remoteDataSource.getItems();

    return result.when(
      success: (models) => Success<List<SampleItem>>(
        models.map((model) => model.toEntity()).toList(growable: false),
      ),
      failure: FailureResult<List<SampleItem>>.new,
    );
  }
}
```

- [ ] **Step 5: Add presentation files**

Create `rims_frontend/lib/features/sample/presentation/view_models/sample_view_model.dart`:

```dart
import 'package:flutter/foundation.dart';

import '../../../../core/result/failure.dart';
import '../../domain/entities/sample_item.dart';
import '../../domain/usecases/get_sample_items_usecase.dart';

final class SampleViewModel extends ChangeNotifier {
  SampleViewModel({required GetSampleItemsUseCase getSampleItemsUseCase})
      : _getSampleItemsUseCase = getSampleItemsUseCase;

  final GetSampleItemsUseCase _getSampleItemsUseCase;

  bool _isLoading = false;
  List<SampleItem> _items = const [];
  Failure? _failure;

  bool get isLoading => _isLoading;
  List<SampleItem> get items => _items;
  Failure? get failure => _failure;

  Future<void> loadItems() async {
    _isLoading = true;
    _failure = null;
    notifyListeners();

    final result = await _getSampleItemsUseCase();

    result.when(
      success: (items) {
        _items = items;
      },
      failure: (failure) {
        _items = const [];
        _failure = failure;
      },
    );

    _isLoading = false;
    notifyListeners();
  }
}
```

Create `rims_frontend/lib/features/sample/presentation/widgets/sample_item_tile.dart`:

```dart
import 'package:flutter/material.dart';

import '../../../../core/theme/app_text_styles.dart';
import '../../domain/entities/sample_item.dart';

final class SampleItemTile extends StatelessWidget {
  const SampleItemTile({
    required this.item,
    super.key,
  });

  final SampleItem item;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      title: Text(
        item.title,
        style: AppTextStyles.bodyMedium,
      ),
      subtitle: Text(
        item.id,
        style: AppTextStyles.labelMedium,
      ),
    );
  }
}
```

Create `rims_frontend/lib/features/sample/presentation/pages/sample_page.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../../core/network/api_client.dart';
import '../../../../core/resources/app_strings.dart';
import '../../data/datasources/sample_remote_datasource.dart';
import '../../data/repositories/sample_repository_impl.dart';
import '../../domain/usecases/get_sample_items_usecase.dart';
import '../view_models/sample_view_model.dart';
import '../widgets/sample_item_tile.dart';

final class SamplePage extends StatelessWidget {
  const SamplePage({super.key});

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider<SampleViewModel>(
      create: (_) {
        final apiClient = ApiClient();
        final dataSource = SampleRemoteDataSource(apiClient);
        final repository = SampleRepositoryImpl(dataSource);
        final useCase = GetSampleItemsUseCase(repository);

        return SampleViewModel(getSampleItemsUseCase: useCase)..loadItems();
      },
      child: const _SampleView(),
    );
  }
}

final class _SampleView extends StatelessWidget {
  const _SampleView();

  @override
  Widget build(BuildContext context) {
    final viewModel = context.watch<SampleViewModel>();

    return Scaffold(
      appBar: AppBar(title: const Text(AppStrings.sampleTitle)),
      body: switch (viewModel) {
        SampleViewModel(isLoading: true) => const Center(
            child: CircularProgressIndicator(),
          ),
        SampleViewModel(failure: final failure?) => Center(
            child: Text(failure.message),
          ),
        SampleViewModel(items: final items) when items.isEmpty => const Center(
            child: Text('No sample items'),
          ),
        SampleViewModel(items: final items) => ListView.builder(
            itemCount: items.length,
            itemBuilder: (context, index) => SampleItemTile(
              item: items[index],
            ),
          ),
      },
    );
  }
}
```

- [ ] **Step 6: Run sample tests**

Run:

```powershell
flutter test test/features/sample/presentation/sample_view_model_test.dart
```

Expected: PASS.

- [ ] **Step 7: Run analyzer and all framework tests**

Run:

```powershell
flutter analyze
flutter test test/core/result/result_test.dart test/core/events/app_event_bus_test.dart test/core/network/api_exception_mapper_test.dart test/features/sample/presentation/sample_view_model_test.dart test/routes/route_paths_test.dart
```

Expected: analyzer PASS and tests PASS.

- [ ] **Step 8: Commit**

Run:

```powershell
git add lib/features/sample test/features/sample
git commit -m "feat: add sample feature skeleton"
```

## Task 7: Final Verification And Development Practice Notes

**Files:**
- Create: `rims_frontend/docs/development_practice.md`
- Modify: `rims_frontend/README.md`
- Modify: `rims_frontend/test/widget_test.dart`

- [ ] **Step 1: Add development practice document**

Create `rims_frontend/docs/development_practice.md`:

````markdown
# RIMS Frontend Development Practice

## Architecture

Use feature-first MVVM with Repository and a lightweight Domain layer.

Normal flow:

```text
Page -> ViewModel -> UseCase -> Repository -> DataSource -> ApiClient / Storage
```

For simple CRUD, `Page -> ViewModel -> Repository` is acceptable.

## Naming

| Kind | Rule | Example |
| --- | --- | --- |
| Class | UpperCamelCase | `MyHomePage` |
| Function | lowerCamelCase | `getData` |
| Variable | lowerCamelCase | `userName` |
| Constant | `k` prefix + UpperCamelCase | `kMaxCount` |
| File | lowercase with underscores | `my_home_page.dart` |

## Boundaries

- Pages render UI and forward user actions to ViewModels.
- ViewModels own presentation state.
- Repositories are feature data boundaries.
- DataSources own remote or local data mechanics.
- `ApiClient` owns Dio configuration and request helpers.
- App-wide events use `AppEventBus` only for cross-module events.

## Testing

Prioritize tests for:

- Result and failure behavior.
- API exception mapping.
- Repository behavior.
- UseCase behavior.
- ViewModel state transitions.
````

- [ ] **Step 2: Update README link**

Modify `rims_frontend/README.md`:

```markdown
# rims_frontend

Flutter frontend for RIMS.

## Development Practice

See [docs/development_practice.md](docs/development_practice.md) for architecture, naming, networking, event, resource, and testing conventions.
```

- [ ] **Step 3: Update generated widget test**

Modify `rims_frontend/test/widget_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:rims_frontend/main.dart';

void main() {
  testWidgets('app starts with sample framework screen', (tester) async {
    await tester.pumpWidget(const MainApp());
    await tester.pump();

    expect(find.text('RIMS Framework'), findsOneWidget);
  });
}
```

- [ ] **Step 4: Run full verification**

Run:

```powershell
flutter analyze
flutter test
```

Expected: analyzer PASS and all tests PASS.

- [ ] **Step 5: Review git diff**

Run:

```powershell
git diff --stat
git diff --check
```

Expected: no whitespace errors from `git diff --check`.

- [ ] **Step 6: Commit**

Run:

```powershell
git add docs/development_practice.md README.md test/widget_test.dart
git commit -m "docs: add frontend development practice"
```

## Final Acceptance Criteria

- `flutter analyze` passes.
- `flutter test` passes.
- `lib/core` contains result, event, network, storage, resource, theme, and constant foundations.
- `lib/routes` contains centralized GoRouter setup and route path constants.
- `lib/features/sample` demonstrates feature-first MVVM with data, domain, and presentation layers.
- No app page calls Dio, storage, or DataSource directly except through the planned sample wiring boundary.
- Naming follows the agreed project rules.
- Development practice documentation exists and links from `rims_frontend/README.md`.

## Self-Review

- Spec coverage: The plan covers naming rules, MVVM choice, core architecture code, event tooling, network wrapper, resource management, routing, and tests.
- Scope check: The plan builds framework skeleton and a sample feature only; it does not implement business-specific RIMS workflows.
- Type consistency: `Failure`, `Result`, `AppEventBus`, `ApiClient`, `SampleRepository`, `GetSampleItemsUseCase`, and `SampleViewModel` signatures are consistent across tasks.
