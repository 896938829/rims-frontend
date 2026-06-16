# RIMS Frontend Agent Guide

## Project Scope

This repository contains the RIMS Flutter frontend. The Flutter project lives in
`rims_frontend`, and application code should be organized under
`rims_frontend/lib`.

The current engineering direction is to establish a medium-sized frontend
development framework before feature work grows. Keep changes scoped, follow the
project architecture, and avoid broad refactors unless they are required by the
current task.

## Architecture Decision

Use feature-first MVVM with repositories and a lightweight domain layer.

MCP is not the application architecture for this Flutter app. MCP ideas such as
explicit context, capability boundaries, and event-style coordination can inform
tooling and cross-module communication, but Flutter code should stay aligned
with MVVM, Provider, GoRouter, Dio, and the repository pattern.

The normal dependency flow is:

```text
Page
  -> ViewModel
    -> UseCase, when business logic is non-trivial
      -> Repository interface
        -> Repository implementation
          -> DataSource
            -> ApiClient / Storage
```

Simple CRUD features may use `Page -> ViewModel -> Repository` when a use case
would only add boilerplate.

## Target Structure

Use this structure for app code:

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

Feature directories are the main ownership boundary. Shared framework code goes
in `core`, routing goes in `routes`, and business functionality goes under
`features/<feature_name>`.

## Naming Rules

Follow Dart conventions plus these project rules:

| Kind | Rule | Example |
| --- | --- | --- |
| Class | UpperCamelCase | `MyHomePage` |
| Function | lowerCamelCase | `getData` |
| Variable | lowerCamelCase | `userName` |
| Constant | `k` prefix + UpperCamelCase | `kMaxCount` |
| File | lowercase with underscores | `my_home_page.dart` |

Repository interfaces and implementations should be easy to pair:

```text
auth_repository.dart
auth_repository_impl.dart
login_view_model.dart
api_client.dart
app_event_bus.dart
```

## Boundary Rules

Pages render UI and forward user actions to ViewModels.

ViewModels coordinate page state, loading state, validation, and user actions.
They should not build endpoint URLs, parse `DioException`, or access raw storage
APIs.

Repositories are the feature data boundary. Feature presentation code should
depend on repository contracts, not on Dio, storage, or DataSources.

DataSources own remote or local data mechanics. They may use `ApiClient`,
`AppSecureStorage`, or `AppPreferences`.

`core/utils` must stay small and generic. Business rules belong in feature
domain or presentation code, not in global utility files.

## Core Framework

Use these shared framework areas consistently:

- `core/result`: `Result<T>` and `Failure` primitives for repository and use
  case boundaries.
- `core/network`: `ApiClient`, endpoints, exceptions, and Dio interceptors.
- `core/events`: lightweight app event bus for cross-module events only.
- `core/storage`: wrappers around secure storage and shared preferences.
- `core/resources`: typed resource entry points such as `AppImages`,
  `AppIcons`, and `AppStrings`.
- `core/theme`: colors, text styles, and app theme setup.

## Networking

All HTTP access should go through `ApiClient`, backed by Dio.

`ApiClient` is responsible for base URL, timeouts, common headers, auth/logging
interceptors, typed HTTP helpers, and converting Dio failures into project
failures.

Feature code should not call Dio directly except inside DataSource
implementations.

## Events

Use the application event bus for cross-module events such as:

- login state changed
- token expired
- user profile updated
- global refresh requested

Do not use the event bus for parent-child widget communication, route
arguments, or normal ViewModel state updates.

## Resources

Organize assets by type:

```text
assets/
  images/
  icons/
  fonts/
```

Expose asset paths through typed constants rather than repeating raw strings in
screens:

```dart
abstract final class AppImages {
  static const String logo = 'assets/images/logo.png';
}
```

Register assets in `rims_frontend/pubspec.yaml` when adding new files.

Generated blue-style UI assets based on
`garden-gpt-image-2/image/rims-frontend-design-overview-blue-style-20260611.png`
live under:

```text
rims_frontend/assets/images/home_warehouse_hero.png
rims_frontend/assets/images/illustrations/api_backend_modules.png
rims_frontend/assets/images/illustrations/empty_inventory.png
rims_frontend/assets/images/illustrations/scan_inventory.png
rims_frontend/assets/images/illustrations/security_permission.png
rims_frontend/assets/images/products/product_dark_bottle.png
rims_frontend/assets/images/products/product_laundry_detergent.png
rims_frontend/assets/images/products/product_tissue_pack.png
rims_frontend/assets/images/products/product_water_bottle.png
rims_frontend/assets/icons/actions/action_filter.png
rims_frontend/assets/icons/actions/action_inbound.png
rims_frontend/assets/icons/actions/action_report.png
rims_frontend/assets/icons/actions/action_return.png
rims_frontend/assets/icons/actions/action_scan.png
rims_frontend/assets/icons/actions/action_search.png
rims_frontend/assets/icons/actions/action_stocktake.png
rims_frontend/assets/icons/actions/action_transfer.png
rims_frontend/assets/icons/hints/badge_new_marker.png
rims_frontend/assets/icons/hints/bottom_home_indicator.png
rims_frontend/assets/icons/hints/bottom_nav_active_pill.png
rims_frontend/assets/icons/hints/hint_scan_frame.png
rims_frontend/assets/icons/hints/hint_tip_bulb.png
rims_frontend/assets/icons/hints/status_online_dot.png
rims_frontend/assets/icons/modules/module_api.png
rims_frontend/assets/icons/modules/module_backend.png
rims_frontend/assets/icons/modules/module_permission.png
rims_frontend/assets/icons/modules/module_role.png
rims_frontend/assets/icons/modules/module_warehouse.png
rims_frontend/assets/icons/nav/nav_documents_active.png
rims_frontend/assets/icons/nav/nav_documents_inactive.png
rims_frontend/assets/icons/nav/nav_home_active.png
rims_frontend/assets/icons/nav/nav_home_inactive.png
rims_frontend/assets/icons/nav/nav_inventory_active.png
rims_frontend/assets/icons/nav/nav_inventory_inactive.png
rims_frontend/assets/icons/nav/nav_profile_active.png
rims_frontend/assets/icons/nav/nav_profile_inactive.png
rims_frontend/assets/icons/nav/nav_reports_active.png
rims_frontend/assets/icons/nav/nav_reports_inactive.png
rims_frontend/assets/icons/status/status_error.png
rims_frontend/assets/icons/status/status_info.png
rims_frontend/assets/icons/status/status_pending.png
rims_frontend/assets/icons/status/status_success.png
rims_frontend/assets/icons/status/status_warning.png
```

Expose those paths through `AppImages` in
`rims_frontend/lib/core/resources/app_images.dart` and `AppIcons` in
`rims_frontend/lib/core/resources/app_icons.dart`. Use generated raster assets
for reusable illustrations, empty states, hero artwork, demo product thumbnails,
button pictograms, bottom navigation symbols, status marks, hint marks, and
module identifiers. Keep actual app screens, cards, charts, buttons, tabs,
workflow steps, labels, status chip text, and route text as Flutter widgets so
the interface stays responsive, localizable, and data-driven.

## Routing

Keep routing centralized under `lib/routes`.

`route_paths.dart` stores path constants. `app_router.dart` builds the
`GoRouter`, including authentication redirects once authentication exists.
Screens should use route constants instead of inline route strings.

## Testing And Verification

Use test-driven development for new framework behavior and non-trivial feature
logic. Focus tests around boundaries and state:

- result and failure behavior
- API error conversion
- repository behavior
- use case behavior when present
- ViewModel state transitions

Run verification commands from `rims_frontend`:

```powershell
flutter pub get --offline
flutter analyze --no-pub
flutter test --no-pub
git diff --check
```

Prefer injected fakes or mock adapters in tests. Do not rely on real network
calls for stable test coverage.

## Git And Workspace Rules

Use the `codex/` branch prefix for agent-created branches unless the user asks
for a different name.

Prefer isolated worktrees for larger implementation tasks. The current frontend
framework implementation branch is:

```text
codex/frontend-development-framework
```

Its worktree path is:

```text
.worktrees/frontend-development-framework
```

Never revert user changes unless the user explicitly asks for that operation.
If unrelated dirty files exist, leave them alone.

## Planning References

Canonical planning documents:

- `docs/superpowers/specs/2026-06-15-frontend-development-framework-design.md`
- `docs/superpowers/plans/2026-06-15-frontend-development-framework.md`

After the framework branch is merged, project practice notes should also be
available under:

```text
rims_frontend/docs/development_practice.md
```
