# RIMS M11 Limited Offline Sync Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Preserve useful warehouse reads and user-authored document work during weak or absent network while keeping server inventory authoritative and making every queued mutation explicit, idempotent, ordered, recoverable, and locally testable.

**Architecture:** Add an account- and warehouse-scoped offline feature built around repository decorators, a versioned Drift database on native platforms, an in-memory adapter for Web regression, and an explicit foreground outbox coordinator. Reads are network-first with bounded cache fallback; drafts never mutate stock; submitted mutations require user confirmation, query server idempotency status before uncertain retry, and preserve attachment/document/lifecycle dependencies. Android native data is encrypted with sqlite3mc using a random database key held only in secure storage; M12 inherits and hardens this boundary.

**Tech Stack:** Flutter 3.44.1, Dart 3.12, Provider/ChangeNotifier, Dio, Drift 2.34.1, drift_flutter 0.3.0, sqlite3 3.x native assets with sqlite3mc, flutter_secure_storage, connectivity_plus, Go 1.25, Gin, GORM, PostgreSQL, PowerShell, WSL, Android Emulator.

---

## 1. Fixed Scope And Safety Rules

- Android is the authoritative persistent M11 target. Web keeps the full M9/M10
  regression journey through an injected in-memory offline store; persistent Web
  SQLite/WASM activation remains M16 scope.
- Cache user identity, warehouse references, products, warehouse inventory,
  alerts, recent documents, selected document details, report summaries, and
  barcode identity. Never cache access tokens, passwords, cost price, audit
  detail, or unrestricted admin payloads in Drift.
- Every cached row carries `accountId`, nullable `warehouseId`, namespace,
  entity key, schema version, fetched time, expiry time, and source metadata.
- Cache fallback is allowed only for `NetworkFailure`, timeout, and explicit
  offline state. Authentication, authorization, validation, conflict, and server
  business failures must remain visible and must not be hidden by stale data.
- Documents may be saved as drafts without creating an outbox operation. A draft
  enters outbox only after the user presses submit and accepts the offline-risk
  confirmation.
- Stock-affecting writes never run silently when connectivity returns. Each
  queued document create, complete, confirm, settle, transfer, return,
  stocktake, or conversion operation requires a current foreground confirmation.
- An unknown result first queries the server idempotency record. Completed
  operations are replayed with the same key to recover the authoritative body;
  processing operations wait; absent operations may be retried only after user
  confirmation; request-hash conflicts become permanent conflicts.
- Attachment upload must complete before document creation when the attachment
  is draft-bound. Document creation must complete before lifecycle operations.
  Dependencies are normalized rows, not an unvalidated JSON execution order.
- Native SQLite is encrypted from first open. The random 256-bit key lives in
  `AppSecureStorage`; logout/account switch removes that account's rows and staged
  files, while full revocation may also rotate/delete the database key.
- Retention: cache default 24 hours, report summaries 6 hours, recent documents
  7 days, completed outbox evidence 7 days, cancelled/permanent failures 30 days,
  drafts 30 days since update, and a hard cap of 500 queued operations per account.
- M11 adds no background service, push provider, cloud account, or silent Android
  job. Foreground sync is deterministic and fully driven by local fault hooks.

## 2. Command Roots And Worktrees

Frontend/program worktree:

```text
E:\My Work\rims-frontend\.worktrees\m11-limited-offline-sync
```

Flutter root:

```text
E:\My Work\rims-frontend\.worktrees\m11-limited-offline-sync\rims_frontend
```

Backend worktree:

```text
E:\My Work\rims-frontend\.worktrees\m11-backend-limited-offline-sync\rims-goProgect
```

Branches in both repositories:

```text
codex/m11-limited-offline-sync
```

All acceptance services must be started through `scripts/rims_local.ps1` or the
new M11 wrapper. Do not start an unmanaged server on ports 8080, 8091, or 4444.

## 3. Core Contracts

```dart
enum DataSourceKind { network, cache }

final class CacheSnapshot<T> {
  const CacheSnapshot({
    required this.value,
    required this.source,
    required this.fetchedAt,
    required this.expiresAt,
  });

  final T value;
  final DataSourceKind source;
  final DateTime fetchedAt;
  final DateTime expiresAt;
  bool get isStale => DateTime.now().isAfter(expiresAt);
}

enum OutboxState {
  queued,
  syncing,
  succeeded,
  retryableFailure,
  conflict,
  permanentFailure,
  cancelled,
}

enum OutboxOperationKind {
  attachmentUpload,
  documentCreate,
  documentComplete,
  stocktakeConfirm,
  stocktakeSettle,
}

final class OutboxOperation {
  const OutboxOperation({
    required this.operationId,
    required this.idempotencyKey,
    required this.accountId,
    required this.warehouseId,
    required this.kind,
    required this.payload,
    required this.state,
    required this.createdAt,
    this.confirmedAt,
    this.nextAttemptAt,
    this.attemptCount = 0,
    this.lastFailureCode,
  });
}

abstract interface class OfflineStore {
  Future<void> writeCache(CacheRecord record);
  Future<CacheRecord?> readCache(CacheKey key);
  Future<void> saveDraft(DocumentDraft draft);
  Future<List<DocumentDraft>> listDrafts(String accountId);
  Future<void> enqueue(OutboxOperation operation, Set<String> dependencies);
  Future<List<OutboxOperation>> readyOperations(String accountId);
  Future<void> transition(String operationId, OutboxState next, {Failure? failure});
  Future<void> clearAccount(String accountId);
  Future<void> prune(DateTime now);
}

abstract interface class NetworkStatusService {
  NetworkReachability get current;
  Stream<NetworkReachability> get changes;
  Future<NetworkReachability> verify();
}
```

Connectivity type is only a hint. Repository requests and `/healthz` verification
remain authoritative because connectivity_plus explicitly does not guarantee
Internet access.

## Task 1: Freeze M11 Contracts And Evidence Skeleton

**Files:**
- Create: `docs/superpowers/plans/2026-07-10-rims-m11-execution-record.md`
- Modify: `docs/superpowers/plans/2026-07-10-rims-app-long-term-completion-master-plan.md`
- Create: `rims_frontend/test/m11_architecture_test.dart`
- Create: `rims_frontend/lib/features/offline/domain/entities/cache_snapshot.dart`
- Create: `rims_frontend/lib/features/offline/domain/entities/document_draft.dart`
- Create: `rims_frontend/lib/features/offline/domain/entities/network_reachability.dart`
- Create: `rims_frontend/lib/features/offline/domain/entities/outbox_operation.dart`
- Create: `rims_frontend/lib/features/offline/domain/services/offline_store.dart`
- Create: `rims_frontend/lib/features/offline/domain/services/network_status_service.dart`

- [x] **Step 1: Record exact frontend/backend commits, tool versions, stopped runtime status, current storage implementations, current dependencies, and M10 inherited reports.**

- [x] **Step 2: Add a requirement matrix mapping every M11 and frontend requirement 6.1-6.4 row to a task and direct evidence source.**

- [x] **Step 3: Write architecture tests that fail until cache, draft, outbox, network, encryption-key, and account-cleanup boundaries exist under feature-first ownership.**

Run:

```powershell
Set-Location rims_frontend
flutter test --no-pub test/m11_architecture_test.dart
```

Expected: FAIL because M11 contracts do not exist.

- [x] **Step 4: Add the minimal typed domain contracts from Section 3 and verify the architecture test passes without adding persistence or sync behavior.**

- [x] **Step 5: Verify stopped ownership before implementation.**

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\rims_local.ps1 -Command status
```

Expected: no managed state, listener, emulator, or bridge.

- [x] **Step 6: Commit the evidence skeleton and contracts.**

```text
docs: freeze M11 offline sync contracts
```

## Task 2: Add Encrypted Versioned Drift Storage

**Files:**
- Modify: `rims_frontend/pubspec.yaml`
- Modify: `rims_frontend/pubspec.lock`
- Modify: `rims_frontend/lib/main.dart`
- Modify: `rims_frontend/lib/app.dart`
- Modify: `rims_frontend/lib/core/storage/app_secure_storage.dart`
- Create: `rims_frontend/lib/features/offline/data/database/offline_database.dart`
- Create: `rims_frontend/lib/features/offline/data/database/offline_database.g.dart`
- Create: `rims_frontend/lib/features/offline/data/database/offline_database_factory.dart`
- Create: `rims_frontend/lib/features/offline/data/database/offline_tables.dart`
- Modify: `rims_frontend/lib/features/offline/domain/entities/cache_snapshot.dart`
- Modify: `rims_frontend/lib/features/offline/domain/entities/outbox_operation.dart`
- Modify: `rims_frontend/lib/features/offline/domain/services/offline_store.dart`
- Test: `rims_frontend/test/features/offline/offline_database_test.dart`
- Test: `rims_frontend/test/features/offline/offline_database_factory_test.dart`

- [x] **Step 1: Add pinned compatible dependencies and native sqlite3mc hook.**

Use `drift: ^2.34.1`, `drift_flutter: ^0.3.0`, and
`drift_dev: ^2.34.1`. Configure sqlite3 native assets with
`hooks.user_defines.sqlite3.source: sqlite3mc`. Do not add obsolete
`sqlite3_flutter_libs` or `sqlcipher_flutter_libs` directly.

- [x] **Step 2: Write failing in-memory migration, uniqueness, foreign-key, state-transition, retention, and 500-operation-cap tests.**

Required tables are `cache_records`, `document_drafts`, `outbox_operations`,
and `outbox_dependencies`. Composite cache uniqueness is account, warehouse,
namespace, entity key, and record schema. Dependencies use cascading foreign
keys and reject self-dependency.

- [x] **Step 3: Implement Drift schema version 1 and generated accessors.**

Payloads are canonical JSON text. Timestamps are UTC integer milliseconds.
Outbox state and operation kind use stable wire strings, never enum indexes.

- [x] **Step 4: Add secure key bootstrap.**

`main()` must call `WidgetsFlutterBinding.ensureInitialized()`, read or create a
32-byte random key through `AppSecureStorage`, open the native database with
`PRAGMA key`, then pass an `OfflineStore` into `MainApp`. Tests inject an
in-memory executor. Web injects `MemoryOfflineStore` and never attempts native
SQLite/WASM initialization.

- [x] **Step 5: Test corruption and migration failure.**

An unreadable database is quarantined with a timestamped filename and recreated
only after preserving staged attachment files. Authentication tokens and secure
storage are never deleted by cache recovery.

- [x] **Step 6: Run generation and focused tests.**

```powershell
dart run build_runner build --delete-conflicting-outputs
flutter test --no-pub test/features/offline/offline_database_test.dart test/features/offline/offline_database_factory_test.dart
```

Expected: PASS.

- [x] **Step 7: Commit.**

```text
feat: add encrypted offline database
```

## Task 3: Add Verified Network Reachability

**Files:**
- Modify: `rims_frontend/lib/features/offline/domain/entities/network_reachability.dart`
- Modify: `rims_frontend/lib/features/offline/domain/services/network_status_service.dart`
- Create: `rims_frontend/lib/features/offline/data/services/connectivity_network_status_service.dart`
- Modify: `rims_frontend/lib/core/network/api_client.dart`
- Modify: `rims_frontend/lib/app.dart`
- Test: `rims_frontend/test/features/offline/network_status_service_test.dart`

- [x] **Step 1: Write failing tests for offline, connectivity-only, verified online, timeout, captive/unreachable Wi-Fi, network switch, and stale probe completion.**

- [x] **Step 2: Implement `ConnectivityNetworkStatusService`.**

Map plugin results to a hint, then perform a bounded `/healthz` request through
an injected probe. Expose `offline`, `checking`, `online`, and `unreachable`.
Ignore probe completions whose generation predates the newest connectivity event.

- [x] **Step 3: Add an ApiClient request observer without treating connectivity hints as authorization to skip a real request.**

- [x] **Step 4: Run tests and commit.**

```powershell
flutter test --no-pub test/features/offline/network_status_service_test.dart test/core/network/api_client_test.dart
```

```text
feat: add verified network reachability
```

## Task 4: Implement Cache Codec, Policy, And Repository Decorator Primitives

**Files:**
- Create: `rims_frontend/lib/features/offline/data/models/cache_record_model.dart`
- Create: `rims_frontend/lib/features/offline/data/services/cache_policy.dart`
- Create: `rims_frontend/lib/features/offline/data/repositories/cache_fallback.dart`
- Create: `rims_frontend/lib/features/offline/domain/entities/cache_snapshot.dart`
- Test: `rims_frontend/test/features/offline/cache_policy_test.dart`
- Test: `rims_frontend/test/features/offline/cache_fallback_test.dart`

- [x] **Step 1: Write failing tests for canonical JSON, account/warehouse keys, TTL, stale-but-visible fallback, expiry, bounded namespace eviction, schema mismatch, and forbidden failure fallback.**

- [x] **Step 2: Implement `CachePolicy`.**

Defaults: references 24 hours, reports 6 hours, recent documents 7 days. Keep a
stale record for explicit stale display until retention pruning; never present
it as fresh.

- [x] **Step 3: Implement one generic network-first helper.**

It writes successful network results atomically. It reads cache only for network
or timeout failures. It returns the original authentication, permission,
validation, conflict, and server failures unchanged.

- [x] **Step 4: Run tests and commit.**

```text
feat: add scoped offline cache primitives
```

## Task 5: Cache Session And Warehouse References

**Files:**
- Modify: `rims_frontend/lib/features/auth/data/repositories/auth_repository_impl.dart`
- Modify: `rims_frontend/lib/features/auth/domain/repositories/auth_repository.dart`
- Modify: `rims_frontend/lib/features/auth/presentation/view_models/auth_session_controller.dart`
- Create: `rims_frontend/lib/features/offline/data/repositories/cached_auth_repository.dart`
- Test: `rims_frontend/test/features/offline/cached_auth_repository_test.dart`
- Modify: `rims_frontend/test/features/auth/auth_repository_impl_test.dart`

- [x] **Step 1: Write failing tests for cached user/warehouse read, age metadata, account mismatch, warehouse switch invalidation, permission refresh invalidation, and offline login rejection.**

- [x] **Step 2: Cache only an already authenticated session projection.**

Offline startup may show cached identity and references only after secure token
presence is confirmed. It must not create a new authenticated session or extend
token expiry. Login always requires the backend.

- [x] **Step 3: Publish account and warehouse ownership changes to offline cleanup/invalidation services.**

- [x] **Step 4: Run tests and commit.**

```text
feat: cache session warehouse references
```

## Task 6: Cache Products, Inventory, Alerts, And Barcode Identity

**Files:**
- Create: `rims_frontend/lib/features/offline/data/repositories/cached_inventory_repository.dart`
- Modify: `rims_frontend/lib/features/inventory/domain/repositories/inventory_repository.dart`
- Modify: `rims_frontend/lib/features/inventory/presentation/view_models/inventory_view_model.dart`
- Modify: `rims_frontend/lib/features/inventory/presentation/pages/inventory_page.dart`
- Modify: `rims_frontend/lib/features/scanner/domain/services/scan_lookup_cache.dart`
- Test: `rims_frontend/test/features/offline/cached_inventory_repository_test.dart`
- Modify: `rims_frontend/test/features/inventory/inventory_view_model_test.dart`
- Modify: `rims_frontend/test/features/scanner/scan_session_view_model_test.dart`

- [x] **Step 1: Write failing tests for page snapshots, exact query keys, warehouse isolation, barcode fallback, stale quantity labels, disabled products, pagination gaps, and successful refresh replacement.**

- [x] **Step 2: Implement cached inventory repository decoration.**

Cache each authoritative page plus query/filter identity. Offline pagination may
return only contiguous cached pages and must expose `hasMore=false` at the first
gap. Barcode cache reuses Drift instead of shared preferences after migration.

- [x] **Step 3: Render explicit source and age.**

Cached stock must show `离线缓存 · 更新于 <time>` and must never enable a stock
mutation solely because cached quantity appears sufficient.

- [x] **Step 4: Migrate and remove old barcode preference keys only after Drift write succeeds.**

- [x] **Step 5: Run focused tests and commit.**

```text
feat: add offline inventory reads
```

## Task 7: Cache Recent Documents, Details, And Report Summaries

**Files:**
- Create: `rims_frontend/lib/features/offline/data/repositories/cached_documents_repository.dart`
- Create: `rims_frontend/lib/features/offline/data/repositories/cached_reports_repository.dart`
- Modify: `rims_frontend/lib/features/documents/presentation/view_models/documents_view_model.dart`
- Modify: `rims_frontend/lib/features/reports/presentation/view_models/reports_view_model.dart`
- Modify: `rims_frontend/lib/features/documents/presentation/pages/documents_page.dart`
- Modify: `rims_frontend/lib/features/reports/presentation/pages/reports_page.dart`
- Test: `rims_frontend/test/features/offline/cached_documents_repository_test.dart`
- Test: `rims_frontend/test/features/offline/cached_reports_repository_test.dart`

- [ ] **Step 1: Write failing tests for recent-page and selected-detail fallback, query-specific report summaries, source/age, no cached financial leakage, and non-network error preservation.**

- [ ] **Step 2: Implement decorators with typed model codecs.**

Do not cache transaction history beyond the recent document summary needed by
the app. Ordinary-user report cache must contain only fields returned by that
ordinary-user request; never reuse an admin cache namespace.

- [ ] **Step 3: Add stale/offline status to document and report screens without replacing authoritative business status chips.**

- [ ] **Step 4: Run tests and commit.**

```text
feat: cache recent documents and reports
```

## Task 8: Add Versioned Document Drafts

**Files:**
- Modify: `rims_frontend/lib/features/offline/domain/entities/document_draft.dart`
- Create: `rims_frontend/lib/features/offline/domain/repositories/document_draft_repository.dart`
- Create: `rims_frontend/lib/features/offline/data/repositories/drift_document_draft_repository.dart`
- Modify: `rims_frontend/lib/features/documents/domain/entities/document_data.dart`
- Test: `rims_frontend/test/features/offline/document_draft_repository_test.dart`

- [ ] **Step 1: Write failing tests for all six document types, lines, target/source IDs, stocktake zero, non-standard source, attachment staging IDs, role/warehouse ownership, optimistic draft version, retention, and migration.**

- [ ] **Step 2: Implement immutable versioned draft records.**

Store user-entered intent, never cached stock authorization. A draft records the
role and warehouse observed at save time so reopening can require revalidation.

- [ ] **Step 3: Reject cross-account load and mark stale-role/stale-warehouse drafts as requiring review.**

- [ ] **Step 4: Run tests and commit.**

```text
feat: persist versioned document drafts
```

## Task 9: Integrate Draft Autosave And Draft Management UI

**Files:**
- Modify: `rims_frontend/lib/features/documents/presentation/view_models/documents_view_model.dart`
- Modify: `rims_frontend/lib/features/documents/presentation/pages/documents_page.dart`
- Create: `rims_frontend/lib/features/offline/presentation/view_models/drafts_view_model.dart`
- Create: `rims_frontend/lib/features/offline/presentation/widgets/draft_manager.dart`
- Modify: `rims_frontend/lib/features/profile/presentation/pages/profile_page.dart`
- Modify: `rims_frontend/lib/routes/app_router.dart`
- Modify: `rims_frontend/lib/routes/route_paths.dart`
- Test: `rims_frontend/test/features/offline/drafts_view_model_test.dart`
- Modify: `rims_frontend/test/features/documents/documents_view_model_test.dart`

- [ ] **Step 1: Write failing tests for debounced autosave, explicit save, reopen, duplicate, rename remark, discard confirmation, account switch, process recreation, and submit-success cleanup.**

- [ ] **Step 2: Integrate one-flight 300 ms autosave into document form changes.**

Autosave failures remain visible but do not destroy the in-memory form. A new
stable draft ID is created before attachment staging binds to it.

- [ ] **Step 3: Add a work-focused draft manager under Profile > Data and Cache.**

Use a dense list with type, warehouse, line count, update time, and review state.
Commands are open, duplicate, and discard; no marketing card or explanatory
feature prose.

- [ ] **Step 4: Run tests and commit.**

```text
feat: add recoverable document drafts
```

## Task 10: Expose Safe Backend Idempotency Status

**Files:**
- Create: backend `internal/idempotency/handler.go`
- Create: backend `internal/idempotency/routes.go`
- Modify: backend `internal/idempotency/service.go`
- Modify: backend `internal/idempotency/repository.go`
- Modify: backend `internal/app/router.go`
- Create: backend `internal/idempotency/handler_test.go`
- Modify: backend `internal/idempotency/service_test.go`
- Modify: `rims_frontend/lib/core/network/api_endpoints.dart`
- Create: `rims_frontend/lib/features/offline/data/datasources/operation_status_remote_datasource.dart`
- Test: `rims_frontend/test/features/offline/operation_status_remote_datasource_test.dart`

- [ ] **Step 1: Write failing backend tests for current-user isolation, allowed scope validation, absent, processing, completed, expired, and no response-body leakage.**

Endpoint:

```text
GET /api/v1/operations/idempotency/:key?scope=<METHOD%20route-template>
```

Response contains only `state`, `status_code`, and `expires_at`. It never returns
request hashes or stored response bodies. The client recovers a completed body
by replaying the original request with the same idempotency key.

- [ ] **Step 2: Implement service and authenticated route.**

Allow only registered idempotent mutation scopes. Repository lookup always uses
the JWT user ID. Missing/expired is 404, processing/completed is 200.

- [ ] **Step 3: Write frontend parsing and failure-mapping tests, then implement the datasource.**

- [ ] **Step 4: Run Go and Flutter tests.**

```bash
~/local/go/bin/go test ./internal/idempotency ./internal/app
```

```powershell
flutter test --no-pub test/features/offline/operation_status_remote_datasource_test.dart
```

- [ ] **Step 5: Commit frontend and backend separately.**

```text
feat: expose idempotency operation status
feat: query idempotency operation status
```

## Task 11: Implement Outbox State Machine And Dependency Graph

**Files:**
- Modify: `rims_frontend/lib/features/offline/domain/entities/outbox_operation.dart`
- Create: `rims_frontend/lib/features/offline/domain/repositories/outbox_repository.dart`
- Create: `rims_frontend/lib/features/offline/data/repositories/drift_outbox_repository.dart`
- Create: `rims_frontend/lib/features/offline/domain/services/outbox_state_machine.dart`
- Test: `rims_frontend/test/features/offline/outbox_repository_test.dart`
- Test: `rims_frontend/test/features/offline/outbox_state_machine_test.dart`

- [ ] **Step 1: Write failing tests for every state transition, illegal regression, dependency cycle, dependency failure propagation, FIFO readiness, retry schedule, cap, cancellation, and pruning.**

- [ ] **Step 2: Implement explicit transition matrix.**

Only queued/retryable may enter syncing. Syncing may become succeeded,
retryable, conflict, permanent, or cancelled. Succeeded is terminal. Conflict
requires a user resolution that creates a new operation/key; it never mutates
the original payload in place.

- [ ] **Step 3: Implement normalized dependency queries and transactional enqueue.**

- [ ] **Step 4: Run tests and commit.**

```text
feat: add deterministic offline outbox
```

## Task 12: Add Foreground Confirmed Sync Coordinator

**Files:**
- Create: `rims_frontend/lib/features/offline/domain/services/outbox_executor.dart`
- Create: `rims_frontend/lib/features/offline/presentation/view_models/sync_center_view_model.dart`
- Create: `rims_frontend/lib/features/offline/presentation/pages/sync_center_page.dart`
- Modify: `rims_frontend/lib/features/profile/presentation/pages/profile_page.dart`
- Modify: `rims_frontend/lib/routes/app_router.dart`
- Modify: `rims_frontend/lib/app.dart`
- Test: `rims_frontend/test/features/offline/outbox_executor_test.dart`
- Test: `rims_frontend/test/features/offline/sync_center_view_model_test.dart`

- [ ] **Step 1: Write failing tests for current account/warehouse/permission revalidation, explicit confirmation, unknown-result status probe, completed replay, processing wait, absent retry, 401 pause, 403 permanent failure, 409 conflict, bounded backoff, and duplicate delivery.**

- [ ] **Step 2: Implement foreground-only executor.**

The executor receives typed operation handlers. It processes one operation at a
time, checks dependencies, verifies connectivity and active session, and writes
every state transition before network activity. It never starts merely because
connectivity changed.

- [ ] **Step 3: Implement Sync Center.**

Tabs: waiting, attention, completed. Commands: review and sync, retry selected,
retry all reviewed, cancel, discard, and resolve conflict. Inventory mutation
confirmation summarizes warehouse, document type, lines, and stale assumptions.

- [ ] **Step 4: Run tests and commit.**

```text
feat: add confirmed foreground synchronization
```

## Task 13: Queue Document And Attachment Operations Safely

**Files:**
- Modify: `rims_frontend/lib/features/documents/data/repositories/documents_repository_impl.dart`
- Modify: `rims_frontend/lib/features/documents/presentation/view_models/documents_view_model.dart`
- Modify: `rims_frontend/lib/features/attachments/presentation/view_models/attachments_view_model.dart`
- Modify: `rims_frontend/lib/features/attachments/data/services/file_attachment_staging_store.dart`
- Create: `rims_frontend/lib/features/offline/data/services/document_outbox_handler.dart`
- Create: `rims_frontend/lib/features/offline/data/services/attachment_outbox_handler.dart`
- Test: `rims_frontend/test/features/offline/document_outbox_handler_test.dart`
- Test: `rims_frontend/test/features/offline/attachment_outbox_handler_test.dart`
- Modify: `rims_frontend/test/features/documents/documents_view_model_test.dart`

- [ ] **Step 1: Write failing tests for offline submit confirmation, stable request key, staged attachment dependency, create-before-complete ordering, unknown result, replay, server validation, and success cleanup.**

- [ ] **Step 2: Queue immutable request DTO snapshots.**

Document operations retain the existing request ID as idempotency key. Never
serialize token or cached stock into the operation. Lifecycle operations refer
to the authoritative document ID produced by their dependency.

- [ ] **Step 3: Bind draft attachments to a local aggregate ID and rebind only after authoritative document creation succeeds.**

- [ ] **Step 4: Keep online fast path unchanged when the request succeeds.**

Only network/timeout/unknown outcomes offer queueing. Validation, permission,
conflict, and insufficient-stock errors remain immediate and are not queued.

- [ ] **Step 5: Run tests and commit.**

```text
feat: queue reviewed document operations
```

## Task 14: Enforce Account, Warehouse, Permission, And Retention Cleanup

**Files:**
- Create: `rims_frontend/lib/features/offline/domain/services/offline_ownership_service.dart`
- Modify: `rims_frontend/lib/features/auth/presentation/view_models/auth_session_controller.dart`
- Modify: `rims_frontend/lib/app.dart`
- Modify: `rims_frontend/lib/features/profile/presentation/pages/profile_page.dart`
- Test: `rims_frontend/test/features/offline/offline_ownership_service_test.dart`

- [ ] **Step 1: Write failing tests for logout, account switch, warehouse switch, role/permission refresh, token expiry, revocation, cache clear, draft retention choice, staged files, and database-key rotation.**

- [ ] **Step 2: Implement ownership rules.**

Logout clears cache, outbox, downloads, scan sessions, and staged transfers for
the prior account. User-authored drafts may be retained only when the user
explicitly chooses local retention before logout; they remain encrypted and
cannot be opened by another account. Token expiry defaults to preserving drafts
but blocks sync until the same account reauthenticates.

- [ ] **Step 3: Add clear-cache and clear-offline-work commands with exact count previews and confirmation.**

- [ ] **Step 4: Run tests and commit.**

```text
feat: enforce offline data ownership
```

## Task 15: Add Global Offline And Stale Experience

**Files:**
- Create: `rims_frontend/lib/features/offline/presentation/view_models/offline_status_view_model.dart`
- Create: `rims_frontend/lib/features/offline/presentation/widgets/offline_status_bar.dart`
- Modify: `rims_frontend/lib/features/shell/presentation/pages/app_shell_page.dart`
- Modify: `rims_frontend/lib/features/home/presentation/pages/home_page.dart`
- Modify: `rims_frontend/lib/core/theme/app_theme.dart`
- Test: `rims_frontend/test/features/offline/offline_status_bar_test.dart`
- Modify: `rims_frontend/test/app_static_ui_test.dart`

- [ ] **Step 1: Write failing tests for checking, offline, unreachable, stale cache, queued count, conflict count, narrow phone, tablet, text scale 2.0, light/dark, keyboard, and semantics.**

- [ ] **Step 2: Implement a compact full-width status band.**

It shows network state and data age without covering app content. Tapping queued
or attention counts opens Sync Center. It is not a floating card and does not
claim that connectivity implies API reachability.

- [ ] **Step 3: Disable authoritative submit commands offline until the user saves a draft or enters the reviewed queue flow.**

- [ ] **Step 4: Run UI tests and commit.**

```text
feat: surface offline and stale state
```

## Task 16: Extend Local Fault Harness And Android Acceptance

**Files:**
- Create: `rims_frontend/integration_test/m11_offline_sync_test.dart`
- Modify: `rims_frontend/integration_test/support/rims_e2e_config.dart`
- Modify: `scripts/rims_android_smoke.ps1`
- Create: `scripts/rims_m11_smoke.ps1`
- Create: `scripts/test_rims_m11_smoke.ps1`
- Modify: `scripts/test_rims_android_smoke.ps1`

- [ ] **Step 1: Write wrapper self-tests for airplane mode, latency, packet loss/unreachable API, Wi-Fi switch, process recreation, stale session, stale permission, duplicate delivery, server conflict, database corruption, and first-failure cleanup.**

- [ ] **Step 2: Add deterministic local-only fault hooks.**

Hooks are enabled only by explicit M11 test defines. Production builds retain
real connectivity and persistence. Network faults operate on the owned host
bridge/backend fault proxy and are always restored in `finally`.

- [ ] **Step 3: Implement Android journey.**

```text
online seed -> cache reads -> airplane mode -> cached inventory/report/detail
offline scan -> draft autosave -> process recreation -> draft recovery
reviewed submit -> queued operation -> reconnect -> explicit sync
unknown response -> status probe -> idempotent replay -> one document effect
attachment dependency -> upload -> document create -> lifecycle completion
stale permission/session -> blocked attention state -> reauthenticate/review
server conflict -> visible conflict -> discard or create replacement operation
logout -> account cache/outbox/staging cleanup -> baseline restore
```

- [ ] **Step 4: Emit strict result evidence.**

Record cache read latency, draft save latency, process recovery latency, outbox
enqueue latency, sync total, operation IDs, idempotency keys (hashed in logs),
stock before/after, server document count, attachment hash/count, database size,
cleanup Booleans, and frontend/backend commits.

Thresholds: cached first content <= 500 ms; draft save <= 250 ms; recovered
draft visible <= 1,000 ms after app frame; enqueue <= 250 ms; local confirmed
sync <= 10,000 ms excluding intentional fault delay; database <= 25 MiB for M11
fixtures; zero duplicate documents or inventory transactions.

- [ ] **Step 5: Run self-tests and commit.**

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\test_rims_m11_smoke.ps1
```

```text
test: automate M11 offline synchronization
```

## Task 17: Run M11 Acceptance And Close The Milestone

**Files:**
- Modify: `README.md`
- Modify: `rims_frontend/README.md`
- Modify: backend `rims-goProgect/README.md`
- Modify: `docs/superpowers/plans/2026-07-10-rims-m11-execution-record.md`
- Modify: `docs/superpowers/plans/2026-07-10-rims-app-long-term-completion-master-plan.md`

- [ ] **Step 1: Run deterministic gates from stopped state.**

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\test_rims_local.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\test_rims_smoke.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\test_rims_web_e2e.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\test_rims_android_smoke.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\test_rims_m10_smoke.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\test_rims_m11_smoke.ps1
```

```powershell
Set-Location rims_frontend
flutter pub get --offline
dart run build_runner build --delete-conflicting-outputs
dart format --output=none --set-exit-if-changed lib test integration_test test_driver
flutter analyze --no-pub
flutter test --no-pub
flutter build apk --debug --no-pub
```

```bash
~/local/go/bin/go test ./...
build_output=$(mktemp /tmp/rims-server.XXXXXX)
trap 'rm -f -- "$build_output"' EXIT
~/local/go/bin/go build -o "$build_output" ./cmd/server
bash scripts/test_m9_dev_seed.sh
```

- [ ] **Step 2: Run M9 Web/Android regression, M10 field acceptance, and M11 offline acceptance with AI-owned services.**

- [ ] **Step 3: Read reports and verify Boolean result types, commits, thresholds, fixture counts, stock effects, duplicate counts, hashes, database size, ownership cleanup, and baseline restore.**

- [ ] **Step 4: Record P0/P1/P2/P3 defects.**

M11 exits only with open P0/P1 zero. Performance variance over threshold is at
least P2 and requires an explicit owner milestone; correctness, duplicate stock,
cross-account leakage, or silent conflict overwrite is P0/P1 and blocks exit.

- [ ] **Step 5: Update local docs.**

Document AI-owned startup, Android AVD, offline cache age/source, draft behavior,
manual sync, conflict handling, data clearing, database/provider locations,
fault hooks, and the no-cloud local path.

- [ ] **Step 6: Verify stopped cleanup and repository scope.**

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\rims_local.ps1 -Command status
git diff --check
git status --short
```

- [ ] **Step 7: Commit evidence in both repositories, fast-forward merge, and push only after all gates pass.**

```text
docs: record M11 offline sync acceptance
```

M12 may then inherit the exact encrypted-record inventory, key lifecycle,
outbox payload inventory, permission revalidation rules, and redacted sync
evidence. M12 must not weaken M11's explicit-confirmation boundary.
