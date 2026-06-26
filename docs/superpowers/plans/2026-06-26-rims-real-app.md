# RIMS Real App Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn the current polished RIMS Flutter demo into the first usable backend-connected app loop.

**Architecture:** Preserve the current RIMS UI pages and blue raster assets from `dev`, then selectively bring in framework foundations from `codex/frontend-development-framework`. All backend traffic goes through `ApiClient`, repositories return `Result<T>`, session state owns token/user/warehouse, and pages interact only with ViewModels.

**Tech Stack:** Flutter, Dart, Provider/ChangeNotifier, GoRouter, Dio, flutter_secure_storage, shared_preferences, flutter_test.

---

## Source Context

- Spec: `docs/superpowers/specs/2026-06-26-rims-real-app-design.md`
- API contract: `docs/前端API调用文档.md`
- Project rules: `AGENTS.md`
- Current UI base: `dev`
- Framework reference: `.worktrees/frontend-development-framework`

Do not directly merge `codex/frontend-development-framework` into `dev`. That branch removes the current static RIMS screens and generated blue assets. Copy or recreate framework pieces selectively.

## File Structure

Core files to create or modify:

- Create: `rims_frontend/lib/core/result/failure.dart` - typed failures with business code and trace ID.
- Create: `rims_frontend/lib/core/result/result.dart` - success/failure wrapper.
- Create: `rims_frontend/lib/core/network/api_endpoints.dart` - base URL and endpoint constants.
- Create: `rims_frontend/lib/core/network/api_envelope.dart` - RIMS response envelope parser.
- Create: `rims_frontend/lib/core/network/api_exception_mapper.dart` - Dio and RIMS error mapping.
- Create: `rims_frontend/lib/core/network/api_client.dart` - Dio-backed request wrapper.
- Create: `rims_frontend/lib/core/network/interceptors/auth_interceptor.dart` - bearer token header.
- Create: `rims_frontend/lib/core/network/interceptors/warehouse_interceptor.dart` - `X-Warehouse-ID` header.
- Create: `rims_frontend/lib/core/storage/app_secure_storage.dart` - token storage.
- Create: `rims_frontend/lib/core/storage/app_preferences.dart` - non-sensitive preferences.
- Create: `rims_frontend/lib/core/events/app_event.dart` - cross-module event type.
- Create: `rims_frontend/lib/core/events/app_event_bus.dart` - lightweight event bus.

Auth files:

- Delete: `rims_frontend/lib/features/auth/data/repositories/demo_auth_repository.dart`
- Delete: `rims_frontend/lib/features/auth/domain/entities/demo_user.dart`
- Create: `rims_frontend/lib/features/auth/domain/entities/app_user.dart`
- Create: `rims_frontend/lib/features/auth/domain/entities/warehouse.dart`
- Modify: `rims_frontend/lib/features/auth/domain/repositories/auth_repository.dart`
- Create: `rims_frontend/lib/features/auth/domain/usecases/login_usecase.dart`
- Create: `rims_frontend/lib/features/auth/domain/usecases/logout_usecase.dart`
- Create: `rims_frontend/lib/features/auth/data/models/auth_models.dart`
- Create: `rims_frontend/lib/features/auth/data/datasources/auth_remote_datasource.dart`
- Create: `rims_frontend/lib/features/auth/data/repositories/auth_repository_impl.dart`
- Modify: `rims_frontend/lib/features/auth/presentation/view_models/auth_session_controller.dart`
- Modify: `rims_frontend/lib/features/auth/presentation/view_models/login_view_model.dart`
- Modify: `rims_frontend/lib/features/auth/presentation/pages/login_page.dart`

Feature files:

- Modify: `rims_frontend/lib/app.dart`
- Modify: `rims_frontend/lib/routes/app_router.dart`
- Modify: `rims_frontend/lib/features/shell/presentation/pages/app_shell_page.dart`
- Modify: `rims_frontend/lib/features/home/presentation/view_models/home_view_model.dart`
- Modify: `rims_frontend/lib/features/home/presentation/pages/home_page.dart`
- Modify: `rims_frontend/lib/features/inventory/presentation/view_models/inventory_view_model.dart`
- Modify: `rims_frontend/lib/features/inventory/presentation/pages/inventory_page.dart`
- Modify: `rims_frontend/lib/features/documents/presentation/view_models/documents_view_model.dart`
- Modify: `rims_frontend/lib/features/documents/presentation/pages/documents_page.dart`
- Modify: `rims_frontend/lib/features/reports/presentation/view_models/reports_view_model.dart`
- Modify: `rims_frontend/lib/features/reports/presentation/pages/reports_page.dart`
- Modify: `rims_frontend/lib/features/profile/presentation/view_models/profile_view_model.dart`
- Modify: `rims_frontend/lib/features/profile/presentation/pages/profile_page.dart`

Tests:

- Create: `rims_frontend/test/core/result/result_test.dart`
- Create: `rims_frontend/test/core/network/api_envelope_test.dart`
- Create: `rims_frontend/test/core/network/api_exception_mapper_test.dart`
- Create: `rims_frontend/test/core/network/auth_interceptor_test.dart`
- Create: `rims_frontend/test/core/network/warehouse_interceptor_test.dart`
- Modify: `rims_frontend/test/features/auth/login_view_model_test.dart`
- Modify: `rims_frontend/test/features/inventory/inventory_view_model_test.dart`
- Modify: `rims_frontend/test/features/documents/documents_view_model_test.dart`
- Modify: `rims_frontend/test/features/reports/reports_view_model_test.dart`
- Modify: `rims_frontend/test/features/profile/profile_view_model_test.dart`
- Modify: `rims_frontend/test/app_static_ui_test.dart`
- Modify: `rims_frontend/test/widget_test.dart`

## Task 1: Bring In Core Framework Foundations

**Files:**
- Create: `rims_frontend/lib/core/result/failure.dart`
- Create: `rims_frontend/lib/core/result/result.dart`
- Create: `rims_frontend/lib/core/events/app_event.dart`
- Create: `rims_frontend/lib/core/events/app_event_bus.dart`
- Create: `rims_frontend/lib/core/storage/app_secure_storage.dart`
- Create: `rims_frontend/lib/core/storage/app_preferences.dart`
- Test: `rims_frontend/test/core/result/result_test.dart`
- Test: `rims_frontend/test/core/events/app_event_bus_test.dart`

- [ ] **Step 1: Copy framework foundation files**

Run from repository root:

```powershell
Copy-Item -Recurse -Force '.worktrees/frontend-development-framework/rims_frontend/lib/core/result' 'rims_frontend/lib/core/'
Copy-Item -Recurse -Force '.worktrees/frontend-development-framework/rims_frontend/lib/core/events' 'rims_frontend/lib/core/'
Copy-Item -Recurse -Force '.worktrees/frontend-development-framework/rims_frontend/lib/core/storage' 'rims_frontend/lib/core/'
New-Item -ItemType Directory -Force 'rims_frontend/test/core' | Out-Null
Copy-Item -Recurse -Force '.worktrees/frontend-development-framework/rims_frontend/test/core/result' 'rims_frontend/test/core/'
Copy-Item -Recurse -Force '.worktrees/frontend-development-framework/rims_frontend/test/core/events' 'rims_frontend/test/core/'
```

Expected: files are created under `rims_frontend/lib/core` and `rims_frontend/test/core`.

- [ ] **Step 2: Run copied foundation tests**

Run from `rims_frontend`:

```powershell
flutter test --no-pub test/core/result/result_test.dart test/core/events/app_event_bus_test.dart
```

Expected: PASS. If imports fail because the current branch lacks copied files, re-check Step 1 paths.

- [ ] **Step 3: Commit foundation files**

Run from repository root:

```powershell
git add rims_frontend/lib/core/result rims_frontend/lib/core/events rims_frontend/lib/core/storage rims_frontend/test/core/result rims_frontend/test/core/events
git commit -m "feat: add core framework foundations"
```

Expected: one commit containing only core foundation and tests.

## Task 2: Add RIMS API Envelope And Failure Mapping

**Files:**
- Create: `rims_frontend/lib/core/network/api_envelope.dart`
- Create: `rims_frontend/lib/core/network/api_exception_mapper.dart`
- Modify: `rims_frontend/lib/core/result/failure.dart`
- Test: `rims_frontend/test/core/network/api_envelope_test.dart`
- Test: `rims_frontend/test/core/network/api_exception_mapper_test.dart`

- [ ] **Step 1: Write envelope parser tests**

Create `rims_frontend/test/core/network/api_envelope_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:rims_frontend/core/network/api_envelope.dart';

void main() {
  group('ApiEnvelope', () {
    test('parses successful RIMS envelope', () {
      final envelope = ApiEnvelope.fromJson({
        'code': 0,
        'message': 'success',
        'data': {'token': 'abc'},
        'traceId': 'trace-1',
      });

      expect(envelope.code, 0);
      expect(envelope.message, 'success');
      expect(envelope.data, {'token': 'abc'});
      expect(envelope.traceId, 'trace-1');
      expect(envelope.isSuccess, isTrue);
    });

    test('parses business failure envelope', () {
      final envelope = ApiEnvelope.fromJson({
        'code': 20001,
        'message': '库存不足',
        'data': null,
        'traceId': 'trace-2',
      });

      expect(envelope.code, 20001);
      expect(envelope.message, '库存不足');
      expect(envelope.data, isNull);
      expect(envelope.traceId, 'trace-2');
      expect(envelope.isSuccess, isFalse);
    });
  });
}
```

- [ ] **Step 2: Run envelope tests to verify red**

Run from `rims_frontend`:

```powershell
flutter test --no-pub test/core/network/api_envelope_test.dart
```

Expected: FAIL because `ApiEnvelope` does not exist.

- [ ] **Step 3: Implement envelope parser**

Create `rims_frontend/lib/core/network/api_envelope.dart`:

```dart
final class ApiEnvelope {
  const ApiEnvelope({
    required this.code,
    required this.message,
    required this.data,
    required this.traceId,
  });

  factory ApiEnvelope.fromJson(Map<dynamic, dynamic> json) {
    return ApiEnvelope(
      code: json['code'] is int ? json['code'] as int : -1,
      message: json['message'] is String
          ? json['message'] as String
          : 'Request failed',
      data: json['data'],
      traceId: json['traceId'] is String ? json['traceId'] as String : null,
    );
  }

  final int code;
  final String message;
  final Object? data;
  final String? traceId;

  bool get isSuccess => code == 0;
}
```

- [ ] **Step 4: Run envelope tests to verify green**

Run from `rims_frontend`:

```powershell
flutter test --no-pub test/core/network/api_envelope_test.dart
```

Expected: PASS.

- [ ] **Step 5: Write business failure mapper tests**

Replace `rims_frontend/test/core/network/api_exception_mapper_test.dart` with tests that include RIMS codes:

```dart
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rims_frontend/core/network/api_exception_mapper.dart';
import 'package:rims_frontend/core/result/failure.dart';

void main() {
  group('ApiExceptionMapper', () {
    DioException exceptionForStatus(int statusCode, {Object? data}) {
      return DioException(
        requestOptions: RequestOptions(path: '/test'),
        response: Response(
          requestOptions: RequestOptions(path: '/test'),
          statusCode: statusCode,
          data: data,
        ),
      );
    }

    test('maps RIMS auth code to AuthenticationFailure', () {
      final failure = const ApiExceptionMapper().map(
        exceptionForStatus(401, data: {
          'code': 10001,
          'message': '认证失败',
          'traceId': 'trace-auth',
        }),
      );

      expect(failure, isA<AuthenticationFailure>());
      expect(failure.message, '认证失败');
      expect(failure.businessCode, 10001);
      expect(failure.traceId, 'trace-auth');
    });

    test('maps RIMS inventory code to InventoryFailure', () {
      final failure = const ApiExceptionMapper().map(
        exceptionForStatus(422, data: {
          'code': 20001,
          'message': '库存不足',
          'traceId': 'trace-inventory',
        }),
      );

      expect(failure, isA<InventoryFailure>());
      expect(failure.message, '库存不足');
      expect(failure.businessCode, 20001);
      expect(failure.traceId, 'trace-inventory');
    });

    test('maps timeout to NetworkFailure', () {
      final failure = const ApiExceptionMapper().map(
        DioException(
          requestOptions: RequestOptions(path: '/test'),
          type: DioExceptionType.connectionTimeout,
        ),
      );

      expect(failure, isA<NetworkFailure>());
    });
  });
}
```

- [ ] **Step 6: Run mapper tests to verify red**

Run from `rims_frontend`:

```powershell
flutter test --no-pub test/core/network/api_exception_mapper_test.dart
```

Expected: FAIL because `businessCode`, `traceId`, `InventoryFailure`, and RIMS code mapping are not implemented.

- [ ] **Step 7: Extend failure types and mapper**

Update `rims_frontend/lib/core/result/failure.dart` so `Failure` carries `businessCode` and `traceId`, and add `ConflictFailure`, `InventoryFailure`, and `StateFailure`.

Update `rims_frontend/lib/core/network/api_exception_mapper.dart` to inspect response envelope data before falling back to HTTP status.

- [ ] **Step 8: Run mapper tests to verify green**

Run from `rims_frontend`:

```powershell
flutter test --no-pub test/core/network/api_exception_mapper_test.dart
```

Expected: PASS.

- [ ] **Step 9: Commit RIMS envelope and mapper**

Run from repository root:

```powershell
git add rims_frontend/lib/core/network/api_envelope.dart rims_frontend/lib/core/network/api_exception_mapper.dart rims_frontend/lib/core/result/failure.dart rims_frontend/test/core/network/api_envelope_test.dart rims_frontend/test/core/network/api_exception_mapper_test.dart
git commit -m "feat: map rims api envelopes"
```

Expected: one commit containing API envelope and failure mapping.

## Task 3: Add Auth And Warehouse Request Headers

**Files:**
- Create: `rims_frontend/lib/core/network/api_endpoints.dart`
- Create: `rims_frontend/lib/core/network/api_client.dart`
- Create: `rims_frontend/lib/core/network/interceptors/auth_interceptor.dart`
- Create: `rims_frontend/lib/core/network/interceptors/warehouse_interceptor.dart`
- Test: `rims_frontend/test/core/network/auth_interceptor_test.dart`
- Test: `rims_frontend/test/core/network/warehouse_interceptor_test.dart`

- [ ] **Step 1: Copy base network files without overwriting RIMS mapper**

Run from repository root:

```powershell
New-Item -ItemType Directory -Force 'rims_frontend/lib/core/network/interceptors' | Out-Null
New-Item -ItemType Directory -Force 'rims_frontend/test/core/network' | Out-Null
Copy-Item -Force '.worktrees/frontend-development-framework/rims_frontend/lib/core/network/api_client.dart' 'rims_frontend/lib/core/network/api_client.dart'
Copy-Item -Force '.worktrees/frontend-development-framework/rims_frontend/lib/core/network/api_endpoints.dart' 'rims_frontend/lib/core/network/api_endpoints.dart'
Copy-Item -Force '.worktrees/frontend-development-framework/rims_frontend/lib/core/network/interceptors/auth_interceptor.dart' 'rims_frontend/lib/core/network/interceptors/auth_interceptor.dart'
Copy-Item -Force '.worktrees/frontend-development-framework/rims_frontend/lib/core/network/interceptors/logging_interceptor.dart' 'rims_frontend/lib/core/network/interceptors/logging_interceptor.dart'
Copy-Item -Force '.worktrees/frontend-development-framework/rims_frontend/test/core/network/api_client_test.dart' 'rims_frontend/test/core/network/api_client_test.dart'
Copy-Item -Force '.worktrees/frontend-development-framework/rims_frontend/test/core/network/auth_interceptor_test.dart' 'rims_frontend/test/core/network/auth_interceptor_test.dart'
```

Expected: base `ApiClient`, endpoint constants, auth interceptor, logging interceptor, and selected tests are copied. `api_exception_mapper.dart` and `api_envelope.dart` from Task 2 remain unchanged.

- [ ] **Step 2: Write warehouse interceptor test**

Create `rims_frontend/test/core/network/warehouse_interceptor_test.dart`:

```dart
import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rims_frontend/core/network/interceptors/warehouse_interceptor.dart';

void main() {
  test('adds X-Warehouse-ID when a warehouse id is available', () async {
    final adapter = _CapturingAdapter();
    final dio = Dio()
      ..httpClientAdapter = adapter
      ..interceptors.add(
        WarehouseInterceptor(warehouseIdReader: () async => 12),
      );

    await dio.get<dynamic>('/inventory');

    expect(adapter.lastOptions?.headers['X-Warehouse-ID'], '12');
  });
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
```

- [ ] **Step 3: Run warehouse interceptor test to verify red**

Run from `rims_frontend`:

```powershell
flutter test --no-pub test/core/network/warehouse_interceptor_test.dart
```

Expected: FAIL because `WarehouseInterceptor` does not exist.

- [ ] **Step 4: Implement warehouse interceptor**

Create `rims_frontend/lib/core/network/interceptors/warehouse_interceptor.dart`:

```dart
import 'dart:async';

import 'package:dio/dio.dart';

typedef WarehouseIdReader = Future<int?> Function();

final class WarehouseInterceptor extends Interceptor {
  const WarehouseInterceptor({required WarehouseIdReader warehouseIdReader})
    : _warehouseIdReader = warehouseIdReader;

  final WarehouseIdReader _warehouseIdReader;

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    unawaited(_handleRequest(options, handler));
  }

  Future<void> _handleRequest(
    RequestOptions options,
    RequestInterceptorHandler handler,
  ) async {
    try {
      final warehouseId = await _warehouseIdReader();
      if (warehouseId != null) {
        options.headers['X-Warehouse-ID'] = warehouseId.toString();
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
}
```

- [ ] **Step 5: Update endpoint defaults**

Modify `rims_frontend/lib/core/network/api_endpoints.dart`:

```dart
abstract final class ApiEndpoints {
  static const String baseUrl = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: 'http://127.0.0.1:8080/api/v1',
  );

  static const String login = '/auth/login';
  static const String currentUser = '/users/me';
  static const String currentUserWarehouses = '/users/me/warehouses';
  static const String inventory = '/inventory';
  static const String inventoryAlerts = '/inventory/alerts';
  static const String documents = '/documents';
  static const String salesStats = '/reports/sales/stats';
  static const String salesTrend = '/reports/sales/trend';
  static const String salesRanking = '/reports/sales/ranking';
  static const String inventoryOverview = '/reports/inventory/overview';
}
```

- [ ] **Step 6: Run network tests**

Run from `rims_frontend`:

```powershell
flutter test --no-pub test/core/network/auth_interceptor_test.dart test/core/network/warehouse_interceptor_test.dart test/core/network/api_client_test.dart
```

Expected: PASS after any copied network tests are adjusted to the local `API_BASE_URL` default.

- [ ] **Step 7: Commit network headers**

Run from repository root:

```powershell
git add rims_frontend/lib/core/network rims_frontend/test/core/network
git commit -m "feat: add rims api client headers"
```

Expected: one commit containing network client and interceptors.

## Task 4: Replace Demo Auth With Backend Auth

**Files:**
- Delete: `rims_frontend/lib/features/auth/data/repositories/demo_auth_repository.dart`
- Delete: `rims_frontend/lib/features/auth/domain/entities/demo_user.dart`
- Create: `rims_frontend/lib/features/auth/domain/entities/app_user.dart`
- Create: `rims_frontend/lib/features/auth/domain/entities/warehouse.dart`
- Modify: `rims_frontend/lib/features/auth/domain/repositories/auth_repository.dart`
- Create: `rims_frontend/lib/features/auth/data/models/auth_models.dart`
- Create: `rims_frontend/lib/features/auth/data/datasources/auth_remote_datasource.dart`
- Create: `rims_frontend/lib/features/auth/data/repositories/auth_repository_impl.dart`
- Modify: `rims_frontend/lib/features/auth/presentation/view_models/auth_session_controller.dart`
- Modify: `rims_frontend/lib/features/auth/presentation/view_models/login_view_model.dart`
- Modify: `rims_frontend/lib/features/auth/presentation/pages/login_page.dart`
- Test: `rims_frontend/test/features/auth/login_view_model_test.dart`

- [ ] **Step 1: Write auth ViewModel tests**

Replace `rims_frontend/test/features/auth/login_view_model_test.dart` with tests that use a fake repository returning `Result<AuthSession>` instead of demo users.

Required test cases:

- Empty credentials return `请输入账号和密码`.
- Successful login starts session with backend user and warehouse.
- Failed login shows backend message.
- Logout clears session.

- [ ] **Step 2: Run auth tests to verify red**

Run from `rims_frontend`:

```powershell
flutter test --no-pub test/features/auth/login_view_model_test.dart
```

Expected: FAIL because `AppUser`, `Warehouse`, `AuthSession`, and the new repository API do not exist.

- [ ] **Step 3: Add auth domain entities**

Create `app_user.dart` with `id`, `username`, `realName`, `roleCode`, and `roleName`.

Create `warehouse.dart` with `id`, `code`, `name`, and `isDefault`.

Change `AuthRepository.login` to return `Future<Result<AuthSession>>`.

- [ ] **Step 4: Add backend auth data source and repository**

Create `AuthRemoteDataSource` to call:

- `POST /auth/login`
- `GET /users/me/warehouses`

Create `AuthRepositoryImpl` to:

- Save access token in `AppSecureStorage`.
- Convert login user model to `AppUser`.
- Select the default or first warehouse.
- Return `Success<AuthSession>`.
- Return `FailureResult<AuthSession>` when any request fails.

- [ ] **Step 5: Update session and login ViewModel**

Update `AuthSessionController` to hold `AuthSession?`, expose `currentUser`,
`currentWarehouse`, `accessToken`, and `isAuthenticated`, and clear all state on
logout.

Update `LoginViewModel` to call `AuthRepository.login`, map failures to
`errorMessage`, and remove pasted `admin/admin123` parsing.

- [ ] **Step 6: Remove demo UI affordances**

Update `LoginPage`:

- Remove demo account hint text.
- Remove `管理员 Demo` and `普通用户 Demo` buttons.
- Change `登录 Demo` to `登录`.
- Keep username and password fields.

- [ ] **Step 7: Run auth tests to verify green**

Run from `rims_frontend`:

```powershell
flutter test --no-pub test/features/auth/login_view_model_test.dart
```

Expected: PASS.

- [ ] **Step 8: Verify demo auth symbols are gone from auth feature**

Run from repository root:

```powershell
rg -n "DemoAuthRepository|DemoUser|登录 Demo|管理员 Demo|普通用户 Demo|admin123|user123" rims_frontend/lib/features/auth rims_frontend/test/features/auth
```

Expected: no matches.

- [ ] **Step 9: Commit backend auth**

Run from repository root:

```powershell
git add rims_frontend/lib/features/auth rims_frontend/test/features/auth
git rm --ignore-unmatch rims_frontend/lib/features/auth/data/repositories/demo_auth_repository.dart rims_frontend/lib/features/auth/domain/entities/demo_user.dart
git commit -m "feat: replace demo auth with api auth"
```

Expected: one commit replacing demo auth with backend auth.

## Task 5: Wire App Dependencies And Route Guard

**Files:**
- Modify: `rims_frontend/lib/app.dart`
- Modify: `rims_frontend/lib/routes/app_router.dart`
- Modify: `rims_frontend/lib/features/shell/presentation/pages/app_shell_page.dart`
- Test: `rims_frontend/test/app_static_ui_test.dart`
- Test: `rims_frontend/test/widget_test.dart`

- [ ] **Step 1: Update app smoke tests for real login labels**

Change app smoke expectations from `登录 Demo` to `登录`. Use fake repositories where needed so tests do not require a real backend.

- [ ] **Step 2: Run app smoke tests to verify red**

Run from `rims_frontend`:

```powershell
flutter test --no-pub test/app_static_ui_test.dart test/widget_test.dart
```

Expected: FAIL while `MainApp` still wires demo repository or tests still import demo auth.

- [ ] **Step 3: Compose production dependencies in app.dart**

Update `MainApp` to create:

- `AppSecureStorage`
- `AppPreferences`
- `AuthSessionController`
- `ApiClient` with token reader and warehouse reader
- `AuthRepositoryImpl`
- `GoRouter`

Keep constructor injection hooks for tests.

- [ ] **Step 4: Update router guard**

Update `createAppRouter` to accept `sessionController` and `authRepository`, and keep these redirects:

- Unauthenticated `/app` redirects to `/`.
- Authenticated `/` redirects to `/app`.

- [ ] **Step 5: Pass session into shell**

Update `AppShellPage` to receive `AuthSessionController` and pass session-derived user/warehouse data to child pages or their ViewModels.

- [ ] **Step 6: Run app smoke tests to verify green**

Run from `rims_frontend`:

```powershell
flutter test --no-pub test/app_static_ui_test.dart test/widget_test.dart
```

Expected: PASS.

- [ ] **Step 7: Commit app wiring**

Run from repository root:

```powershell
git add rims_frontend/lib/app.dart rims_frontend/lib/routes/app_router.dart rims_frontend/lib/features/shell/presentation/pages/app_shell_page.dart rims_frontend/test/app_static_ui_test.dart rims_frontend/test/widget_test.dart
git commit -m "feat: wire real app session"
```

Expected: one commit containing dependency and route wiring.

## Task 6: Convert Profile And Home Away From Fake Session Data

**Files:**
- Modify: `rims_frontend/lib/features/profile/presentation/view_models/profile_view_model.dart`
- Modify: `rims_frontend/lib/features/profile/presentation/pages/profile_page.dart`
- Modify: `rims_frontend/lib/features/home/presentation/view_models/home_view_model.dart`
- Modify: `rims_frontend/lib/features/home/presentation/pages/home_page.dart`
- Test: `rims_frontend/test/features/profile/profile_view_model_test.dart`
- Test: `rims_frontend/test/features/home/home_view_model_test.dart`

- [ ] **Step 1: Write profile tests for session-backed fields**

Update profile tests so they construct `ProfileViewModel` with an `AppUser` and `Warehouse`.

Assertions:

- `userName` equals backend `realName`.
- `roleName` equals backend `roleName`.
- `warehouseName` equals backend warehouse name.
- fake work ID such as `U10086` is not used.

- [ ] **Step 2: Run profile tests to verify red**

Run from `rims_frontend`:

```powershell
flutter test --no-pub test/features/profile/profile_view_model_test.dart
```

Expected: FAIL while profile still imports `DemoUser`.

- [ ] **Step 3: Update profile ViewModel and page**

Make `ProfileViewModel` require `AppUser` and `Warehouse`. Use `user.id` or omit the work ID row if no backend field exists. Keep permission guidance cards as static product guidance only.

- [ ] **Step 4: Run profile tests to verify green**

Run from `rims_frontend`:

```powershell
flutter test --no-pub test/features/profile/profile_view_model_test.dart
```

Expected: PASS.

- [ ] **Step 5: Convert home fixed user and warehouse labels**

Update `HomeViewModel` to receive session user and warehouse. Replace hard-coded `上海仓` and `Good morning, 张三` with session values.

- [ ] **Step 6: Run home tests**

Run from `rims_frontend`:

```powershell
flutter test --no-pub test/features/home/home_view_model_test.dart
```

Expected: PASS with session-backed labels.

- [ ] **Step 7: Commit profile and home session data**

Run from repository root:

```powershell
git add rims_frontend/lib/features/profile rims_frontend/lib/features/home rims_frontend/test/features/profile rims_frontend/test/features/home
git commit -m "feat: use session data in home profile"
```

Expected: one commit removing fake session data from Profile and Home.

## Task 7: Convert Inventory To Backend Data

**Files:**
- Create: `rims_frontend/lib/features/inventory/domain/entities/inventory_item.dart`
- Create: `rims_frontend/lib/features/inventory/domain/repositories/inventory_repository.dart`
- Create: `rims_frontend/lib/features/inventory/data/models/inventory_models.dart`
- Create: `rims_frontend/lib/features/inventory/data/datasources/inventory_remote_datasource.dart`
- Create: `rims_frontend/lib/features/inventory/data/repositories/inventory_repository_impl.dart`
- Modify: `rims_frontend/lib/features/inventory/presentation/view_models/inventory_view_model.dart`
- Modify: `rims_frontend/lib/features/inventory/presentation/pages/inventory_page.dart`
- Test: `rims_frontend/test/features/inventory/inventory_view_model_test.dart`

- [ ] **Step 1: Write inventory ViewModel tests**

Update tests to use a fake `InventoryRepository`.

Assertions:

- `load()` sets loading then exposes backend items.
- `updateQuery('water')` reloads with keyword `water`.
- repository failure sets user-facing error message.
- empty repository result exposes an empty state.

- [ ] **Step 2: Run inventory tests to verify red**

Run from `rims_frontend`:

```powershell
flutter test --no-pub test/features/inventory/inventory_view_model_test.dart
```

Expected: FAIL because `InventoryRepository` and backend-backed load state do not exist.

- [ ] **Step 3: Add inventory domain and repository**

Create `InventoryItem` with real backend fields used by the UI:

- `id`
- `productId`
- `productName`
- `sku`
- `availableQuantity`
- `stockQuantity`
- `statusLabel`
- `imageUrl`

Create `InventoryRepository.listInventory({String keyword = '', int page = 1})`.

- [ ] **Step 4: Add inventory data source**

Call `GET /inventory` with `page`, `pageSize`, and `keyword`. Map response list into `InventoryItem`. Use generated product thumbnail as a UI fallback only when backend image is absent.

- [ ] **Step 5: Update ViewModel and page**

`InventoryViewModel` should:

- own `isLoading`, `errorMessage`, `items`, `query`, and `selectedTab`;
- call repository on `load()` and query changes;
- keep tab filtering local for standard/non-standard display when data has status labels.

`InventoryPage` should:

- call `load()` in `initState`;
- show loading, empty, and error states;
- continue rendering existing tiles for loaded items.

- [ ] **Step 6: Run inventory tests to verify green**

Run from `rims_frontend`:

```powershell
flutter test --no-pub test/features/inventory/inventory_view_model_test.dart
```

Expected: PASS.

- [ ] **Step 7: Commit inventory backend data**

Run from repository root:

```powershell
git add rims_frontend/lib/features/inventory rims_frontend/test/features/inventory
git commit -m "feat: load inventory from api"
```

Expected: one commit converting inventory to repository-backed data.

## Task 8: Convert Documents To Backend List And Create

**Files:**
- Create: `rims_frontend/lib/features/documents/domain/entities/document_summary.dart`
- Create: `rims_frontend/lib/features/documents/domain/entities/document_request.dart`
- Create: `rims_frontend/lib/features/documents/domain/repositories/documents_repository.dart`
- Create: `rims_frontend/lib/features/documents/data/models/document_models.dart`
- Create: `rims_frontend/lib/features/documents/data/datasources/documents_remote_datasource.dart`
- Create: `rims_frontend/lib/features/documents/data/repositories/documents_repository_impl.dart`
- Modify: `rims_frontend/lib/features/documents/presentation/view_models/documents_view_model.dart`
- Modify: `rims_frontend/lib/features/documents/presentation/pages/documents_page.dart`
- Test: `rims_frontend/test/features/documents/documents_view_model_test.dart`

- [ ] **Step 1: Write documents ViewModel tests**

Update tests with a fake `DocumentsRepository`.

Assertions:

- `load()` exposes backend recent documents.
- empty product selection disables create with clear message.
- create uses a real `productId` and quantity.
- inventory failure code maps to visible `库存不足` message.
- successful create reloads or prepends the backend document number.

- [ ] **Step 2: Run documents tests to verify red**

Run from `rims_frontend`:

```powershell
flutter test --no-pub test/features/documents/documents_view_model_test.dart
```

Expected: FAIL because backend document repository and request model do not exist.

- [ ] **Step 3: Add document domain and data source**

Create repository methods:

- `Future<Result<List<DocumentSummary>>> listDocuments()`
- `Future<Result<DocumentSummary>> createDocument(DocumentCreateRequest request)`
- `Future<Result<void>> completeDocument(int id)`

Data source endpoints:

- `GET /documents`
- `POST /documents`
- `POST /documents/:id/complete`

- [ ] **Step 4: Update ViewModel create flow**

Replace locally generated `DM-000x` numbers with backend `docNo` or equivalent document number. The ViewModel must reject create attempts unless it has a real `productId`.

- [ ] **Step 5: Update page create controls**

Use selected inventory/product data for document lines. If a real product ID is unavailable, show a clear disabled state instead of accepting a plain text product name.

- [ ] **Step 6: Run documents tests to verify green**

Run from `rims_frontend`:

```powershell
flutter test --no-pub test/features/documents/documents_view_model_test.dart
```

Expected: PASS.

- [ ] **Step 7: Commit document backend flow**

Run from repository root:

```powershell
git add rims_frontend/lib/features/documents rims_frontend/test/features/documents
git commit -m "feat: connect documents to api"
```

Expected: one commit replacing local document demo flow.

## Task 9: Convert Reports To Backend Data And Real Dates

**Files:**
- Create: `rims_frontend/lib/features/reports/domain/entities/report_models.dart`
- Create: `rims_frontend/lib/features/reports/domain/repositories/reports_repository.dart`
- Create: `rims_frontend/lib/features/reports/data/datasources/reports_remote_datasource.dart`
- Create: `rims_frontend/lib/features/reports/data/repositories/reports_repository_impl.dart`
- Modify: `rims_frontend/lib/features/reports/presentation/view_models/reports_view_model.dart`
- Modify: `rims_frontend/lib/features/reports/presentation/pages/reports_page.dart`
- Test: `rims_frontend/test/features/reports/reports_view_model_test.dart`

- [ ] **Step 1: Write reports ViewModel tests**

Update tests with a fake `ReportsRepository`.

Assertions:

- `近7天` computes an end date from the injected clock.
- `近30天` computes a 30-day date range.
- `本月` starts at day 1 of the current month.
- `load()` exposes backend trend, ranking, and inventory overview data.
- failure exposes an error message.

- [ ] **Step 2: Run reports tests to verify red**

Run from `rims_frontend`:

```powershell
flutter test --no-pub test/features/reports/reports_view_model_test.dart
```

Expected: FAIL because repository-backed reports and injected clock do not exist.

- [ ] **Step 3: Add reports repository**

Create repository methods for:

- `/reports/sales/stats`
- `/reports/sales/trend`
- `/reports/sales/ranking`
- `/reports/inventory/overview`

Use `startDate`, `endDate`, `bucket`, `metric`, and `limit` query parameters from the API contract.

- [ ] **Step 4: Update ViewModel and page**

Remove fixed 2024 date ranges and static ranking values. Use backend values and hide cost/profit/total-value fields when absent.

- [ ] **Step 5: Run reports tests to verify green**

Run from `rims_frontend`:

```powershell
flutter test --no-pub test/features/reports/reports_view_model_test.dart
```

Expected: PASS.

- [ ] **Step 6: Commit report backend data**

Run from repository root:

```powershell
git add rims_frontend/lib/features/reports rims_frontend/test/features/reports
git commit -m "feat: load reports from api"
```

Expected: one commit replacing static report data.

## Task 10: Remove Remaining Demo And Static-Business Residue

**Files:**
- Inspect all files under `rims_frontend/lib`
- Inspect all files under `rims_frontend/test`

- [ ] **Step 1: Search for demo residue**

Run from repository root:

```powershell
rg -n "DemoAuthRepository|DemoUser|登录 Demo|管理员 Demo|普通用户 Demo|admin123|user123|DM-|2024-05|Good morning, 张三|U10086" rims_frontend/lib rims_frontend/test
```

Expected: no matches in active app or tests.

- [ ] **Step 2: Search for static business claims**

Run from repository root:

```powershell
rg -n "1,268|18,732|48,920|326k|SO-202405|PO-202405|ST-202405" rims_frontend/lib rims_frontend/test
```

Expected: no matches in active app or tests.

- [ ] **Step 3: Update or delete obsolete static tests**

Tests named only around static UI should be renamed to app smoke tests or replaced with backend-fake ViewModel tests.

- [ ] **Step 4: Run focused test suite**

Run from `rims_frontend`:

```powershell
flutter test --no-pub test/core test/features test/app_static_ui_test.dart test/widget_test.dart
```

Expected: PASS.

- [ ] **Step 5: Commit cleanup**

Run from repository root:

```powershell
git add rims_frontend/lib rims_frontend/test
git commit -m "chore: remove demo residue"
```

Expected: one commit containing cleanup only.

## Task 11: Final Verification

**Files:**
- Inspect repository status and all changed Flutter files.

- [ ] **Step 1: Fetch dependencies offline**

Run from `rims_frontend`:

```powershell
flutter pub get --offline
```

Expected: succeeds using `pubspec.lock`.

- [ ] **Step 2: Analyze**

Run from `rims_frontend`:

```powershell
flutter analyze --no-pub
```

Expected: no analyzer issues.

- [ ] **Step 3: Run tests**

Run from `rims_frontend`:

```powershell
flutter test --no-pub
```

Expected: all tests pass.

- [ ] **Step 4: Check whitespace**

Run from repository root:

```powershell
git diff --check
```

Expected: no whitespace errors.

- [ ] **Step 5: Confirm accepted demo removal**

Run from repository root:

```powershell
rg -n "DemoAuthRepository|DemoUser|登录 Demo|管理员 Demo|普通用户 Demo|admin123|user123|DM-|2024-05|Good morning, 张三|U10086" rims_frontend/lib rims_frontend/test
```

Expected: no matches.

- [ ] **Step 6: Inspect status**

Run from repository root:

```powershell
git status --short --branch
```

Expected: branch is ahead by the implementation commits. Unrelated `.superpowers/` files remain unstaged unless intentionally committed by a separate planning workflow.
