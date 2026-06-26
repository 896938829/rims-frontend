# RIMS Real App Design

## Context

The RIMS Flutter frontend has two useful but separate lines of work:

- `dev` contains the polished static RIMS mobile UI and the current local-demo
  changes. It has real-looking Home, Inventory, Documents, Reports, Profile,
  login, session guard, and local interactions, but the data is still fake or
  locally generated.
- `codex/frontend-development-framework` contains framework foundations such as
  `ApiClient`, `Result`, `Failure`, secure storage, preferences, and the event
  bus, but it is based on a sample feature skeleton and removes the current RIMS
  static UI assets and pages.

The product direction is now to remove fake demo presentation and turn the
current RIMS UI into a usable application. The first real application milestone
should preserve the validated UI surfaces and replace the demo data path with a
real API-backed minimum business loop.

## Decision

Build the first usable app milestone by keeping the existing RIMS UI and
bringing in the framework foundations selectively. Do not directly merge
`codex/frontend-development-framework` into `dev`, because that branch deletes
the static RIMS screens and generated blue assets that should be retained.

The preferred implementation path is:

1. Copy or recreate the framework foundations from
   `codex/frontend-development-framework` into the current UI worktree:
   `core/result`, `core/network`, `core/storage`, `core/events`, constants, and
   relevant tests.
2. Extend those foundations for RIMS-specific API behavior:
   response envelopes, business error codes, trace IDs, token storage, token
   invalidation, and warehouse context headers.
3. Replace demo authentication with real authentication against
   `POST /auth/login`, followed by current user and warehouse loading.
4. Replace static/local ViewModel data feature by feature, starting with
   inventory, documents, reports, and profile/session data.
5. Keep generated raster assets and the polished Flutter UI as presentation
   assets, not as fake data sources.

This design chooses a real-backend minimum app loop first, not a full one-shot
implementation of every business workflow. The minimum loop must be real enough
to log in, scope data to the selected warehouse, load inventory and reports from
the backend, create or complete supported documents, handle errors, and log out.

## Goals

- Remove visible demo-only affordances such as demo account shortcuts,
  `DemoAuthRepository`, `DemoUser`, `登录 Demo`, and locally generated fake
  document numbers.
- Make authentication use the backend API, persist the access token securely,
  and restore or clear session state deterministically on app startup.
- Load the active user and warehouse context from backend responses.
- Attach `Authorization: Bearer <token>` to authenticated requests.
- Attach `X-Warehouse-ID` to warehouse-scoped requests.
- Convert backend response envelopes into typed success and failure results.
- Map RIMS business error codes to user-readable ViewModel state.
- Replace static inventory list data with backend inventory/product data.
- Replace static document list and local-only document creation with backend
  document APIs.
- Replace static report data with backend report APIs.
- Keep the current UI layout, blue asset style, bottom navigation, and existing
  feature ownership boundaries.

## Non-Goals

This milestone will not complete every future RIMS capability:

- No full scanner/camera workflow.
- No file upload/download workflow.
- No complete warehouse administration UI.
- No complete user, role, permission, product CRUD administration UI.
- No full offline cache or retry queue.
- No dark theme implementation.
- No production release signing, monitoring, or store submission.

Those items remain future milestones. This milestone establishes the real app
foundation and the first backend-connected business loop.

## Architecture

Follow the project architecture in `AGENTS.md`: feature-first MVVM with
repositories and a lightweight domain layer.

The core dependency flow is:

```text
Page
  -> ViewModel
    -> UseCase, when business logic is non-trivial
      -> Repository interface
        -> Repository implementation
          -> DataSource
            -> ApiClient / Storage
```

Simple read-only screens may use `Page -> ViewModel -> Repository` where a
use case would add no business value.

The app-level dependencies are assembled in `app.dart`:

```text
MainApp
  -> AppSecureStorage
  -> SessionStore
  -> ApiClient
  -> AuthSessionController
  -> Repositories
  -> GoRouter
```

The current UI pages should not construct Dio, parse raw response envelopes, or
read secure storage directly.

## Core Framework

### Result And Failure

Use `Result<T>` and `Failure` at repository and use-case boundaries.

Required failure types:

- Network failure for timeouts, connection errors, and unreachable backend.
- Authentication failure for code `10001` or HTTP 401.
- Authorization failure for code `10002` or HTTP 403.
- Validation failure for code `10003` and invalid request data.
- Not found failure for code `10004`.
- Conflict failure for code `10005` and code `20003`.
- Inventory failure for code `20001`.
- State failure for code `20002`.
- Server failure for code `50000` or HTTP 5xx.
- Unknown failure for unexpected response shapes.

Each failure should carry a user-facing message, optional HTTP status, optional
business code, and optional trace ID.

### API Client

All HTTP traffic goes through `ApiClient`, backed by Dio.

`ApiClient` responsibilities:

- Base URL from `--dart-define=API_BASE_URL`, defaulting to
  `http://127.0.0.1:8080/api/v1` for local development.
- Common JSON headers and timeouts.
- Auth token interceptor.
- Warehouse context interceptor for warehouse-scoped requests.
- Response envelope parsing.
- Dio and RIMS error mapping.
- Optional logging in debug builds.

The backend envelope is:

```json
{
  "code": 0,
  "message": "success",
  "data": {},
  "traceId": "..."
}
```

Only `code == 0` is business success. HTTP status alone is not sufficient.

### Session And Storage

Create a session layer that owns:

- Access token.
- Current user.
- Visible warehouses.
- Current warehouse.
- Session restore state.

Secure storage stores the access token. Shared preferences may store
non-sensitive current warehouse ID and user preferences. Plain local storage must
not store passwords, tokens, cost details, or sensitive audit data.

When the backend returns authentication failure, the app must clear the token,
clear active session state, and route back to login.

### Events

Use the app event bus only for cross-module events:

- Session expired.
- Login state changed.
- Warehouse changed.
- Global refresh requested.

Do not use it for parent-child widget communication or ordinary ViewModel
state updates.

## Authentication

Replace local demo auth with:

```text
auth/
  data/
    datasources/auth_remote_datasource.dart
    models/auth_models.dart
    repositories/auth_repository_impl.dart
  domain/
    entities/app_user.dart
    entities/warehouse.dart
    repositories/auth_repository.dart
    usecases/login_usecase.dart
    usecases/load_session_usecase.dart
    usecases/logout_usecase.dart
  presentation/
    pages/login_page.dart
    view_models/auth_session_controller.dart
    view_models/login_view_model.dart
```

Login flow:

1. User enters username and password.
2. `LoginViewModel` validates non-empty input.
3. `LoginUseCase` calls `AuthRepository.login`.
4. `AuthRemoteDataSource` posts to `/auth/login`.
5. Repository saves the access token.
6. Repository loads current warehouses with `/users/me/warehouses`.
7. Session controller stores current user and current warehouse.
8. Router redirects to the shell.

The login screen must remove demo account shortcut buttons and demo credential
copy. The primary button should read `登录`.

The backend login response provides user identity fields such as `id`,
`username`, `realName`, `roleCode`, and `roleName`. UI fields that currently use
fake work IDs must either render a real backend field or omit the row. The app
must not invent values such as `U10086` after the demo layer is removed.

## Warehouse Context

After login, the app must know the current warehouse before loading
warehouse-scoped data.

Rules:

- If the backend provides a default or current warehouse, use it.
- If only one warehouse is visible, select it automatically.
- If multiple warehouses are visible, select the first backend-provided default
  for this milestone and expose current warehouse text in the UI.
- Admin warehouse switching can be added in a later milestone, but the internal
  session shape must support switching now.

All `/inventory/**`, `/non-std-inventory/**`, `/documents/**`,
`/transactions`, and `/reports/**` requests must include `X-Warehouse-ID`.

## Feature Data

### Home

Home should stop showing fixed numbers such as `1,268`, `18,732`, and fixed
document numbers. It should compose data from real repositories:

- Current warehouse from session.
- Inventory overview from `/reports/inventory/overview`.
- Low-stock count or alerts from `/inventory/alerts`.
- Recent documents from `/documents`.

If any section fails, the page should show a scoped error or empty state without
breaking the whole shell.

### Inventory

Inventory should load standard inventory from `/inventory` with pagination and
keyword filtering.

For the first milestone:

- Keep the current search field.
- Map keyword input to backend query.
- Keep tabs for product, standard, and non-standard views, but only load
  non-standard inventory for admin users.
- Hide or explain admin-only non-standard actions for ordinary users.
- Avoid displaying cost or total-value fields for ordinary users when the
  backend omits them.

### Documents

Documents should load recent documents from `/documents`.

Document creation should call `POST /documents`, not insert local fake rows.
The first milestone supports a compact create form for document types that the
current user is allowed to create:

- Sales outbound, available to all users.
- Return inbound, available to all users when a reference sale document is
  provided.
- Inbound, transfer, stocktake, and conversion only for admin users.

Document lines must use real backend identifiers. Product selection should come
from loaded inventory/product data, barcode lookup, or an explicit backend
product selector. If no real product ID is available, the create action must stay
disabled with a clear message instead of submitting a locally invented product
name.

Completing a document should call `POST /documents/:id/complete` when the user
explicitly confirms. The app must lock the submit button while a request is in
flight and show backend business errors such as insufficient inventory or
invalid state.

### Reports

Reports should load:

- Sales stats from `/reports/sales/stats`.
- Sales trend from `/reports/sales/trend`.
- Sales ranking from `/reports/sales/ranking`.
- Inventory overview from `/reports/inventory/overview`.

The period controls should compute real dates from the current device date and
send `startDate` and `endDate` in `YYYY-MM-DD` format. The UI must no longer
show fixed 2024 date ranges.

Cost, profit, and total-value fields should render only when present.

### Profile

Profile should use the active session user and warehouse. Static permission
explanation cards may remain as product guidance, but user name, role, work ID,
warehouse, and logout must come from session state.

The profile page must include logout. Logout clears token and session state and
returns to login.

## Routing

Keep routing under `lib/routes`.

Routes:

- `/` login.
- `/app` shell.

Route guard behavior:

- Unauthenticated access to `/app` redirects to `/`.
- Authenticated access to `/` redirects to `/app`.
- Session restore should complete before final redirect where possible.

## UI Behavior

The existing polished UI is retained, but fake-specific labels and values are
removed.

Required state coverage:

- Initial loading.
- Empty data.
- Network error with retry.
- Validation error.
- Permission error.
- Session expired.
- Submit in progress.
- Submit succeeded.

The current generated blue raster assets remain valid for:

- Hero artwork.
- Empty states.
- Product thumbnails when the backend has no product image.
- Navigation and action symbols.

Screens, cards, charts, buttons, tabs, workflow labels, status chips, and route
text remain Flutter widgets.

## Testing

Use test-driven development for framework behavior and non-trivial feature
logic.

Core tests:

- Result and failure behavior.
- API response envelope parsing.
- RIMS business error code mapping.
- Auth interceptor attaches token.
- Warehouse interceptor attaches `X-Warehouse-ID`.
- Session expiration clears session.

Auth tests:

- Empty credentials rejected.
- Successful login saves token and session data.
- Invalid login shows backend error.
- Logout clears session and token.
- Route guard redirects correctly.

Feature tests:

- Inventory ViewModel loads data, filters keyword, and handles empty/error
  states.
- Documents ViewModel creates a document through repository and prepends or
  reloads the real result.
- Documents ViewModel maps inventory and state failures to user messages.
- Reports ViewModel computes date ranges from current date and loads real
  report results.
- Profile ViewModel uses active session data.

Smoke tests:

- App starts on login.
- Login success enters shell.
- Shell tabs remain navigable.
- Logout returns to login.

Verification commands from `rims_frontend`:

```powershell
flutter pub get --offline
flutter analyze --no-pub
flutter test --no-pub
git diff --check
```

## Migration Strategy

Work in small commits or implementation phases:

1. Bring in framework foundation files while preserving current RIMS UI assets
   and pages.
2. Replace demo auth with real auth and route guard.
3. Add RIMS envelope and business failure mapping.
4. Add warehouse context and request header behavior.
5. Convert profile and home session-bound data.
6. Convert inventory to backend data.
7. Convert documents to backend list/create/complete.
8. Convert reports to backend data and real date ranges.
9. Remove remaining demo names, tests, and local fake data.
10. Run final verification.

Each phase should keep the app analyzable and tests focused. If a phase must
temporarily leave a feature in a loading or empty state, it should be visible as
unfinished in tests or UI state rather than disguised as fake success.

## Acceptance Criteria

The milestone is accepted when:

- Searching `lib` and `test` finds no active `DemoAuthRepository`, `DemoUser`,
  demo shortcut, `登录 Demo`, or locally generated fake document-number flow.
- The app can be run against a backend base URL configured by `API_BASE_URL`.
- Login calls `POST /auth/login`.
- Authenticated requests include the stored bearer token.
- Warehouse-scoped requests include `X-Warehouse-ID`.
- Inventory, documents, reports, profile, and home no longer rely on fixed
  static business values as their primary data source.
- User-visible failures come from typed failure state, not thrown Dio errors or
  raw stack traces.
- Admin-only and ordinary-user-only surfaces respect role information from the
  backend session.
- `flutter analyze --no-pub`, `flutter test --no-pub`, and `git diff --check`
  pass from `rims_frontend`.
