# RIMS Frontend Development Framework Design

## Context

The RIMS frontend is a Flutter application in `rims_frontend`. The current app is still near its baseline state, with dependencies already selected for a medium-sized Flutter project:

- `provider` for MVVM-style presentation state.
- `go_router` for declarative routing.
- `dio` for HTTP networking.
- `json_serializable` and `build_runner` for API model serialization.
- `flutter_secure_storage` and `shared_preferences` for local persistence.

The project should establish a development framework before feature work grows. The framework must be clear enough for team practice, but not so heavy that every screen requires excessive boilerplate.

## Decision

Use a feature-first MVVM architecture with Repository and a lightweight Domain layer.

MCP is not the primary application architecture for this Flutter frontend. Its useful ideas, such as explicit context, capability boundaries, and event-style coordination, can inform tooling and cross-module communication, but the app code should follow Flutter-native MVVM conventions.

## Architecture

The project will use this top-level structure:

```text
lib/
  main.dart
  app.dart

  core/
    constants/
    events/
    network/
    result/
    storage/
    resources/
    theme/
    utils/

  routes/
    app_router.dart
    route_paths.dart

  features/
    <feature_name>/
      data/
        datasources/
        models/
        repositories/
      domain/
        entities/
        repositories/
        usecases/
      presentation/
        pages/
        view_models/
        widgets/
```

Feature modules are the main ownership boundary. Shared infrastructure belongs in `core`, routing belongs in `routes`, and business functionality belongs under `features`.

## Dependency Direction

The normal call flow is:

```text
Page
  -> ViewModel
    -> UseCase, when business logic is non-trivial
      -> Repository interface
        -> Repository implementation
          -> DataSource
            -> ApiClient / Storage
```

Rules:

- Pages render UI and forward user actions to a ViewModel.
- ViewModels coordinate page state, loading state, validation, and user actions.
- Repositories are the feature's data boundary.
- DataSources handle remote or local data details.
- `ApiClient` owns Dio configuration and HTTP mechanics.
- Storage wrappers own secure storage and preferences mechanics.

For complex business flows, use `Page -> ViewModel -> UseCase -> Repository`. For simple CRUD flows, `Page -> ViewModel -> Repository` is acceptable.

Pages must not call Dio, storage, or DataSources directly. ViewModels must not build endpoint URLs or parse low-level HTTP exceptions.

## Naming Rules

Use Dart and Flutter naming conventions with the following project rules:

| Kind | Rule | Example |
| --- | --- | --- |
| Class | UpperCamelCase | `MyHomePage` |
| Function | lowerCamelCase | `getData` |
| Variable | lowerCamelCase | `userName` |
| Constant | `k` prefix + UpperCamelCase | `kMaxCount` |
| File | lowercase with underscores | `my_home_page.dart` |

Examples:

```dart
class LoginPage {}
class LoginViewModel {}

final String userName = 'Tom';
Future<void> getUserProfile() async {}

const int kMaxRetryCount = 3;
const Duration kRequestTimeout = Duration(seconds: 15);
```

Repository implementation files use the `_impl` suffix:

```text
auth_repository.dart
auth_repository_impl.dart
login_view_model.dart
api_client.dart
app_event_bus.dart
```

## Core Code

`core` contains framework code and general-purpose utilities:

```text
core/
  constants/
    app_constants.dart
  events/
    app_event.dart
    app_event_bus.dart
  network/
    api_client.dart
    api_endpoints.dart
    api_exception.dart
    interceptors/
      auth_interceptor.dart
      logging_interceptor.dart
  result/
    result.dart
    failure.dart
  storage/
    app_secure_storage.dart
    app_preferences.dart
  resources/
    app_images.dart
    app_icons.dart
    app_strings.dart
  theme/
    app_colors.dart
    app_text_styles.dart
    app_theme.dart
  utils/
```

`utils` must stay small and generic. Business rules should live in feature domain or presentation code, not in global utility files.

## Network Framework

Network access is centralized through `ApiClient`, backed by Dio.

Responsibilities:

- Configure `baseUrl`.
- Configure timeouts.
- Apply common headers.
- Attach auth and logging interceptors.
- Expose typed `get`, `post`, `put`, `patch`, and `delete` helpers.
- Convert Dio errors into project failures.

Feature code should depend on repositories, not directly on `ApiClient`, except inside DataSource implementations.

## Result And Failure

Use a unified result model for repository and use case boundaries:

```dart
sealed class Result<T> {}

final class Success<T> extends Result<T> {
  const Success(this.data);

  final T data;
}

final class FailureResult<T> extends Result<T> {
  const FailureResult(this.failure);

  final Failure failure;
}
```

`Failure` should represent user-meaningful failure categories:

- Network failure.
- Authentication failure.
- Authorization failure.
- Validation failure.
- Not found failure.
- Server failure.
- Unknown failure.

UI code displays failures through ViewModel state. UI code should not inspect Dio exceptions directly.

## Events

Use a lightweight application event bus for cross-module events:

```text
AppEventBus
  - publish(AppEvent event)
  - Stream<T> on<T extends AppEvent>()
```

Good uses:

- Login state changed.
- Token expired.
- User profile updated.
- Global refresh requested.

Avoid using the event bus for:

- Parent-child widget communication.
- Normal route arguments.
- ViewModel internal state updates.

## Resource Management

Assets are organized by type:

```text
assets/
  images/
  icons/
  fonts/
```

Resource references are exposed through typed constants:

```dart
abstract final class AppImages {
  static const String logo = 'assets/images/logo.png';
}

abstract final class AppIcons {
  static const String scan = 'assets/icons/scan.svg';
}

abstract final class AppStrings {
  static const String appName = 'RIMS';
}
```

Screens should use these resource entry points instead of repeating raw asset paths.

## Routing

Routing is centralized under `routes`:

```text
routes/
  app_router.dart
  route_paths.dart
```

`route_paths.dart` stores route constants. `app_router.dart` builds the `GoRouter`, including authentication redirects once authentication exists.

Screens should use route names or path constants rather than inline route strings.

## Testing Strategy

Prioritize tests around boundaries and state:

```text
test/
  core/
    network/
    result/
  features/
    auth/
      data/
      domain/
      presentation/
```

Test priority:

- `Result` and `Failure` behavior.
- API error conversion.
- Repository behavior.
- UseCase behavior when present.
- ViewModel state transitions.

Widget tests are added for important flows after feature UI stabilizes.

## Initial Implementation Scope

The first implementation should add the framework skeleton and one example feature shape without building real business screens:

- Core result and failure classes.
- Core event bus.
- Network client wrapper.
- Storage wrappers.
- Resource entry classes.
- Theme entry classes.
- App router skeleton.
- Example feature directory with placeholders or minimal sample classes.
- Documentation for development practice.

This gives the project a stable structure for future feature work without prematurely implementing business-specific behavior.
