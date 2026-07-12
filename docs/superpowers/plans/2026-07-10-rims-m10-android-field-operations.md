# RIMS M10 Android Field Operations Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make barcode-driven warehouse work and product/document attachments reliable on Android, fully testable with the local RIMS backend and local filesystem storage, without external cloud accounts.

**Architecture:** Add platform capability boundaries for scanning, media picking, feedback, and local attachment staging. Keep product lookup, scan-session state, attachment transfer state, and document draft state in ViewModels/domain services; keep `mobile_scanner`, `image_picker`, `file_picker`, Dio, and filesystem mechanics in adapters/DataSources. Extend the existing Go file module for bounded, ordered, replaceable attachments while retaining dynamic business-object ACL and the local `Storage` interface. The managed M9 runtime remains the only service owner and supplies deterministic barcode, document, permission, and attachment fixtures.

**Tech Stack:** Flutter, Dart, Provider/ChangeNotifier, Dio, `mobile_scanner` 7.2.0, `image_picker` 1.2.2, `file_picker` 11.0.2, `share_plus` 12.0.0, `path_provider`, Go, Gin, GORM, PostgreSQL, local filesystem storage, PowerShell, WSL, Android Emulator.

---

## Observed Baseline And Decisions

M9 is merged and pushed. M10 starts from frontend `93e2424` and backend
`ea1bb56`. The isolated branches are both
`codex/m10-android-field-operations`.

| Area | Observed M10 entry state | M10 decision |
| --- | --- | --- |
| Product lookup | `InventoryRepository.findProductByBarcode` calls global `/products/barcode/:barcode`, which is not warehouse-scoped and can return disabled products | Add authoritative `/inventory/barcode/:barcode` under warehouse scope; retain the global endpoint for catalog/admin use only |
| Inventory scan UI | The scan icon submits the current search text; no camera exists | Replace with an injected scanner route while retaining manual input |
| Document workflow | Backend accepts multiple lines; frontend creates one line | Introduce typed draft lines and scan accumulation without changing backend stock authority |
| Scanner package | Dependency exists but is unused | Wrap `MobileScannerController`; never expose it to ViewModels |
| Camera permission | Plugin manifest contributes optional camera permission | Handle `permissionDenied`/revocation in the adapter and show contextual guidance |
| Media/file permission | Android system photo picker and SAF require no broad storage permission | Do not request legacy storage permission; explain system-picker behavior |
| Notifications | No notification provider is activated before M14 | Do not request `POST_NOTIFICATIONS`; show that notification permission is not currently needed |
| Attachments frontend | No endpoint, repository, ViewModel, or widget exists | Add a feature-first `attachments` module and inject it into product/document surfaces |
| Attachments backend | Upload/list/get/download/delete and dynamic ACL exist | Add count/order/replace contracts, atomic local writes, cancellation handling, and contract tests |
| Storage provider | `Storage` plus `LocalStorage` exist; default path can dirty a checkout | Point managed local runs at an owned runtime directory and reset it exactly |
| Process recreation | No scan session or upload staging restoration | Persist non-authoritative scan drafts and staged upload manifests with schema/user/warehouse ownership |
| Offline boundary | M11 owns full offline drafts/outbox | M10 caches barcode identity only; cached stock is visibly stale and cannot create an offline stock mutation |

Only product images and document attachments are activated in M10. Approval,
audit, feedback, and M11 offline-draft attachment relationships inherit the same
contracts when those modules are activated; M10 must not add empty UI for them.

### Command Roots

PowerShell/frontend commands run from:

```text
E:\My Work\rims-frontend\.worktrees\m10-android-field-operations
```

Go/backend commands run from:

```text
E:\My Work\rims-frontend\.worktrees\m10-backend-android-field-operations\rims-goProgect
```

Agents must pass those matching worktrees to `scripts/rims_local.ps1`; they must
not run M10 against an older backend checkout with the same ports.

### Fixed Local Limits And Performance Gates

- Accepted attachment extensions remain `.jpg`, `.jpeg`, `.png`, `.gif`,
  `.pdf`, `.csv`, and `.xlsx`.
- Maximum source upload is 10 MiB; maximum attachment count is 9 per business
  object; image picker target is 1920 x 1920 at quality 82 with full metadata
  disabled.
- Staged files live under app support storage, never shared preferences. The
  manifest contains paths and operational metadata only, not file bytes.
- Cached barcode identities are warehouse-scoped, schema-versioned, limited to
  500 entries, expire after 24 hours, and are cleared on logout.
- Injected scan-to-visible-feedback p95 must be <= 250 ms excluding backend
  lookup. Local barcode lookup p95 must remain <= 2,000 ms.
- A local 5 MiB attachment upload must emit progress within 1,000 ms and finish
  within 10,000 ms. These are regression thresholds, not production capacity
  claims.
- Existing M9 Web/Android business durations remain observation baselines and
  may not regress by more than 20% without an explicit defect record.

## Target Contracts

The scan boundary uses domain values only:

```dart
enum ScanMode { single, continuous, batch, quantityAccumulation }

final class NormalizedPoint {
  const NormalizedPoint(this.x, this.y)
    : assert(x >= 0 && x <= 1),
      assert(y >= 0 && y <= 1);

  final double x;
  final double y;
}

abstract interface class BarcodeScannerCapability {
  Stream<DetectedBarcode> get detections;
  Stream<ScannerCapabilityState> get states;
  Future<void> start();
  Future<void> stop();
  Future<void> toggleTorch();
  Future<void> setFocusPoint(NormalizedPoint point);
  Future<void> setZoom(double value);
  Future<void> dispose();
}

abstract interface class ScanFeedbackCapability {
  Future<void> success();
  Future<void> warning();
  Future<void> error();
}
```

The attachment boundary carries a stable request ID across retries:

```dart
abstract interface class AttachmentsRepository {
  Future<Result<PageData<Attachment>>> list({
    required AttachmentBinding binding,
    int page = 1,
  });
  Future<Result<Attachment>> upload(
    PendingAttachment pending, {
    required void Function(int sent, int total) onProgress,
    required TransferCancellation cancellation,
  });
  Future<Result<Attachment>> replace(
    Attachment existing,
    PendingAttachment pending, {
    required void Function(int sent, int total) onProgress,
    required TransferCancellation cancellation,
  });
  Future<Result<void>> reorder(AttachmentBinding binding, List<int> fileIds);
  Future<Result<String>> download(Attachment attachment);
  Future<Result<void>> delete(int id);
}
```

## Task 1: Freeze The M10 Contract And Evidence Skeleton

**Files:**
- Create: `docs/superpowers/plans/2026-07-10-rims-m10-execution-record.md`
- Modify: `docs/superpowers/plans/2026-07-10-rims-app-long-term-completion-master-plan.md`
- Test: repository searches and worktree status

- [x] **Step 1: Record the observed frontend/backend identities, tool versions, Android AVD, current dependencies, current manifest, scanner gap, attachment gap, and M9 inherited gates.**

The execution record starts as `Status: IN PROGRESS` and contains empty tables
for environment, fixtures, scanner modes, attachment scenarios, lifecycle
faults, compatibility, performance, defects, deviations, and final commands.

- [x] **Step 2: Add a requirement matrix mapping every M10, 5.8, 5.9, and relevant Section 6 requirement to an implementation task and evidence row.**

- [x] **Step 3: Verify there are no unowned runtime processes before M10 changes.**

Run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\rims_local.ps1 -Command status
git status --short
```

Expected: no managed state/listeners and only the two M10 plan documents are
modified.

- [x] **Step 4: Commit the planning baseline.**

```powershell
git add docs/superpowers/plans/2026-07-10-rims-m10-android-field-operations.md docs/superpowers/plans/2026-07-10-rims-m10-execution-record.md docs/superpowers/plans/2026-07-10-rims-app-long-term-completion-master-plan.md
git commit -m "docs: plan M10 Android field operations"
```

## Task 2: Extend The Managed Runtime For Local Attachment Storage

**Files:**
- Modify: `scripts/lib/rims_local_core.ps1`
- Modify: `scripts/lib/rims_local_wsl_execution.ps1`
- Modify: `scripts/lib/rims_local_fixtures.ps1`
- Modify: `scripts/tests/test_rims_local_wsl.ps1`
- Modify: `scripts/tests/test_rims_local_fixtures.ps1`
- Modify: `scripts/tests/test_rims_local_reset.ps1`
- Modify: backend `rims-goProgect/scripts/m9_dev_seed.sql`
- Modify: backend `rims-goProgect/scripts/test_m9_dev_seed.sh`

- [x] **Step 1: Write failing lifecycle tests for an owned upload directory.**

Assert that launch context exports a WSL path for
`.runtime/rims-local/providers/files`, state records it, reset removes only that
owned directory, and a path outside runtime is rejected.

- [x] **Step 2: Run the focused tests and verify RED.**

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\test_rims_local.ps1
```

Expected: FAIL because `UPLOAD_DIR` ownership is not represented.

- [x] **Step 3: Add the runtime path and export `UPLOAD_DIR`, `MAX_UPLOAD_MB=10`, `MAX_ATTACHMENTS_PER_OBJECT=9`, and the existing extension allow-list through the safe WSL environment path.**

The backend must never default to a source-worktree `uploads` directory during
managed runs.

- [x] **Step 4: Extend deterministic fixtures with active and disabled barcodes, a product image target, document attachment targets in both warehouses, and ordinary-user access/non-access cases.**

Use stable codes such as `M10-ACTIVE-001`, `M10-DISABLED-001`, and attachment
target remarks on `M9DOC0001`/`M9DOC0002`; keep seed/reset idempotent without
changing the M9 `45/90/15` count baseline.

- [x] **Step 5: Run lifecycle and seed tests, then commit frontend and backend changes separately.**

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\test_rims_local.ps1
wsl.exe -e bash -lc 'export PATH="$HOME/local/go/bin:$PATH"; go test ./... && bash scripts/test_m9_dev_seed.sh'
```

Commits:

```text
test: provision local M10 attachment fixtures
test: add deterministic M10 field fixtures
```

## Task 3: Add An Authoritative Warehouse Barcode Lookup

**Files:**
- Modify: backend `rims-goProgect/internal/modules/product/repository.go`
- Modify: backend `rims-goProgect/internal/modules/product/service.go`
- Modify: backend `rims-goProgect/internal/modules/product/handler.go`
- Modify: backend `rims-goProgect/internal/modules/product/routes.go`
- Create: backend `rims-goProgect/internal/modules/product/inventory_barcode_test.go`
- Modify: `rims_frontend/lib/core/network/api_endpoints.dart`
- Modify: `rims_frontend/lib/features/inventory/data/datasources/inventory_remote_datasource.dart`
- Modify: `rims_frontend/test/features/inventory/inventory_remote_datasource_test.dart`

- [x] **Step 1: Write failing backend tests for `GET /api/v1/inventory/barcode/:barcode`.**

The route must require authentication and warehouse scope, return the inventory
row plus active product data for the current warehouse, return not-found for an
unknown barcode, return a safe business-state failure for a disabled product or
for a known product absent from the current warehouse, and never return another
warehouse's quantity.

- [x] **Step 2: Write a failing frontend DataSource test requiring the new endpoint and strict inventory-shaped response.**

- [x] **Step 3: Run focused tests and verify RED.**

```powershell
wsl.exe -e bash -lc 'export PATH="$HOME/local/go/bin:$PATH"; go test ./internal/modules/product -run Barcode -count=1'
flutter test --no-pub test/features/inventory/inventory_remote_datasource_test.dart
```

- [x] **Step 4: Implement the minimal repository/service/handler route and switch only `InventoryRepository.findProductByBarcode` to it.**

Keep `/products/barcode/:barcode` unchanged for global catalog/admin lookup.
Wrong-batch remains an optional `ScanWorkflowConstraint` until a batch module is
activated; it must not be simulated as a server field that does not exist.

- [x] **Step 5: Run full product/inventory tests and commit frontend and backend changes.**

```text
feat: add warehouse-scoped barcode lookup
```

## Task 4: Add Transfer Failures, Cancellation, Progress, And Safe Logging

**Files:**
- Modify: `rims_frontend/lib/core/result/failure.dart`
- Modify: `rims_frontend/lib/core/network/api_exception_mapper.dart`
- Modify: `rims_frontend/lib/core/network/api_client.dart`
- Modify: `rims_frontend/lib/core/network/interceptors/logging_interceptor.dart`
- Modify: `rims_frontend/test/core/network/api_exception_mapper_test.dart`
- Create: `rims_frontend/test/core/network/api_transfer_test.dart`
- Create: `rims_frontend/test/core/network/logging_interceptor_test.dart`

- [x] **Step 1: Write failing tests for transfer cancellation, local storage/media failures, upload progress forwarding, response-byte downloads, and log redaction.**

Required new failures:

```dart
final class CancellationFailure extends Failure {
  const CancellationFailure({super.message = 'Operation cancelled', super.cause});
}

final class DevicePermissionFailure extends Failure {
  const DevicePermissionFailure({required super.message, super.cause});
}

final class LocalStorageFailure extends Failure {
  const LocalStorageFailure({required super.message, super.cause});
}

final class AttachmentFailure extends Failure {
  const AttachmentFailure({required super.message, super.cause});
}
```

The logger test must prove bearer tokens, multipart bytes, passwords, and local
file paths are absent while method, sanitized path, status, duration, trace ID,
and safe sizes remain available.

- [x] **Step 2: Run focused tests and verify RED.**

```powershell
flutter test --no-pub test/core/network/api_exception_mapper_test.dart test/core/network/api_transfer_test.dart test/core/network/logging_interceptor_test.dart
```

- [x] **Step 3: Extend `ApiClient` with optional `CancelToken`, send/receive progress callbacks, per-request timeouts, and response options.**

Keep Dio types in `core/network` and DataSources only. Map
`DioExceptionType.cancel` to `CancellationFailure`; never publish token expiry
for cancellation.

- [x] **Step 4: Replace debug `LogInterceptor` body/header dumping with a redacting interceptor.**

- [x] **Step 5: Run all core tests and commit.**

```powershell
flutter test --no-pub test/core
git commit -m "feat: add safe cancellable transfer primitives"
```

## Task 5: Build Scan Session Domain Rules And Local Recovery

**Files:**
- Modify: `rims_frontend/lib/app.dart`
- Create: `rims_frontend/lib/features/scanner/domain/entities/scan_data.dart`
- Create: `rims_frontend/lib/features/scanner/domain/services/barcode_scanner_capability.dart`
- Create: `rims_frontend/lib/features/scanner/domain/services/scan_feedback_capability.dart`
- Create: `rims_frontend/lib/features/scanner/domain/services/scan_lookup_cache.dart`
- Create: `rims_frontend/lib/features/scanner/domain/services/scan_session_store.dart`
- Create: `rims_frontend/lib/features/scanner/presentation/view_models/scan_session_view_model.dart`
- Create: `rims_frontend/test/features/scanner/scan_session_view_model_test.dart`
- Create: `rims_frontend/test/features/scanner/scan_session_store_test.dart`

- [x] **Step 1: Write failing tests for single/continuous/batch/quantity modes, duplicate window, quantity increment/decrement, max lines, empty/unsupported codes, unknown/disabled/wrong-warehouse/wrong-batch/permission errors, feedback calls, stale request suppression, and submit/clear.**

Duplicate policy: single closes after first accepted result; continuous reports
each product once per configurable cooldown; batch keeps one line per product;
quantity accumulation increments an existing line for every accepted scan.

- [x] **Step 2: Write failing cache/store tests for schema, user, warehouse, TTL, 500-entry bound, corruption recovery, restart restoration, warehouse switch, logout, and network-failure fallback.**

Cached lookup may supply product identity only and must set `isStale=true`.
Document submission still calls the server and cannot succeed offline.

- [x] **Step 3: Run focused tests and verify RED.**

```powershell
flutter test --no-pub test/features/scanner
```

- [x] **Step 4: Implement domain-only rules and commit.**

```powershell
git commit -m "feat: add recoverable barcode scan sessions"
```

## Task 6: Implement The Android Scanner Adapter And Lifecycle-Safe Page

**Files:**
- Create: `rims_frontend/lib/features/scanner/data/mobile_scanner_capability.dart`
- Create: `rims_frontend/lib/features/scanner/data/system_scan_feedback.dart`
- Create: `rims_frontend/lib/features/scanner/presentation/pages/scanner_page.dart`
- Create: `rims_frontend/lib/features/scanner/presentation/widgets/scanner_viewport.dart`
- Create: `rims_frontend/test/features/scanner/mobile_scanner_capability_test.dart`
- Create: `rims_frontend/test/features/scanner/scanner_page_test.dart`

- [x] **Step 1: Write failing adapter tests for plugin barcode mapping, `permissionDenied`, unsupported camera, start/stop serialization, revoke/resume, controller-disposed safety, torch, zoom, normalized tap-to-focus, and stream cleanup.**

- [x] **Step 2: Write failing widget tests for mode segmented control, stable full-bleed viewport, torch/focus controls, visible feedback, batch lines, manual input, unsupported-code text, permission explanation/retry/settings guidance, system back, and narrow/large-font layouts.**

- [x] **Step 3: Run tests and verify RED.**

```powershell
flutter test --no-pub test/features/scanner
```

- [x] **Step 4: Implement with `MobileScannerController(autoStart: false, detectionSpeed: DetectionSpeed.unrestricted)`.**

Serialize all start/stop calls. Subscribe only while resumed. On inactive,
cancel detection and await stop; on resumed, re-check state and restart. A
permission dialog can cause lifecycle callbacks before initialization, so never
start or stop based only on widget visibility.

- [x] **Step 5: Implement sound/vibration through `SystemSound` and `HapticFeedback`, both independently toggleable and failure-tolerant.**

- [x] **Step 6: Commit.**

```powershell
git commit -m "feat: add lifecycle-safe Android scanner"
```

## Task 7: Integrate Scan-To-Search And Keyboard-Wedge Input

**Files:**
- Modify: `rims_frontend/lib/features/inventory/presentation/pages/inventory_page.dart`
- Modify: `rims_frontend/lib/features/inventory/presentation/view_models/inventory_view_model.dart`
- Create: `rims_frontend/lib/features/scanner/presentation/widgets/keyboard_wedge_listener.dart`
- Modify: `rims_frontend/lib/features/shell/presentation/pages/app_shell_page.dart`
- Modify: `rims_frontend/test/features/inventory/inventory_page_pagination_test.dart`
- Create: `rims_frontend/test/features/scanner/keyboard_wedge_listener_test.dart`

- [x] **Step 1: Write failing tests that the inventory scan icon opens scanner single mode, accepted scan opens the authoritative detail, manual input behaves identically, denied camera leaves manual input usable, and repeated keyboard-wedge keys ending in Enter produce exactly one code.**

- [x] **Step 2: Verify RED, implement route/capability injection, and retain ordinary text search.**

Keyboard-wedge capture is opt-in, ignores events while an editable field owns
focus, has a bounded inter-key timeout, accepts printable ASCII only, and never
globally traps Back/System navigation.

- [x] **Step 3: Run inventory/scanner tests and commit.**

```powershell
flutter test --no-pub test/features/inventory test/features/scanner
git commit -m "feat: connect scanning to inventory lookup"
```

## Task 8: Harden Backend Attachment Validation And Local Storage Writes

**Files:**
- Modify: backend `rims-goProgect/internal/config/config.go`
- Modify: backend `rims-goProgect/internal/modules/file/storage.go`
- Modify: backend `rims-goProgect/internal/modules/file/service.go`
- Modify: backend `rims-goProgect/internal/modules/file/repository.go`
- Create: backend `rims-goProgect/internal/modules/file/storage_atomic_test.go`
- Create: backend `rims-goProgect/internal/modules/file/service_validation_test.go`
- Modify: backend `.env.example`

- [x] **Step 1: Write failing Go tests for maximum attachment count, extension/MIME mismatch, cancellation during copy, temporary-file cleanup, atomic rename, and partial-write preservation.**

`LocalStorage.Save` must write an owner-only temporary file beside the target,
honor `ctx.Done()`, sync/close, then rename. Failure must remove the temporary
file and leave an existing target untouched.

- [x] **Step 2: Run focused tests and verify RED.**

```bash
go test ./internal/modules/file -run 'Test(LocalStorage|FileServiceUpload)' -count=1
```

- [x] **Step 3: Add `MAX_ATTACHMENTS_PER_OBJECT` with default 9, validate it is positive, add repository binding count, and enforce the limit before storage.**

`MaxPositionByBinding` lands in Task 9 together with the `position` column and
migration; querying a column before that schema exists would break Task 8
deployability.

- [x] **Step 4: Validate detected MIME against extension families and preserve current 10 MiB bounded read.**

JPEG/PNG/GIF must match image MIME; PDF must match PDF; CSV permits text/CSV;
XLSX permits ZIP/Office MIME. Do not accept executable or HTML content under an
allowed extension.

- [x] **Step 5: Run backend tests/build and commit.**

```bash
go test ./...
go build -o "$(mktemp /tmp/rims-server.XXXXXX)" ./cmd/server
git commit -m "fix: harden local attachment storage"
```

## Task 9: Add Ordered And Replaceable Backend Attachment Contracts

**Files:**
- Create: backend `rims-goProgect/migrations/000014_file_attachment_position.sql`
- Modify: backend `rims-goProgect/internal/modules/file/model.go`
- Modify: backend `rims-goProgect/internal/modules/file/dto.go`
- Modify: backend `rims-goProgect/internal/modules/file/repository.go`
- Modify: backend `rims-goProgect/internal/modules/file/service.go`
- Modify: backend `rims-goProgect/internal/modules/file/handler.go`
- Modify: backend `rims-goProgect/internal/modules/file/routes.go`
- Create: backend `rims-goProgect/internal/modules/file/service_mutation_test.go`
- Create: backend `rims-goProgect/internal/modules/file/handler_contract_test.go`
- Modify: backend `docs/前端API调用文档.md`

- [x] **Step 1: Write failing contract tests for stable `position`, ordered list, batch reorder, replacement, ACL, binding mismatch, rollback, and audit data.**

Target endpoints:

```text
PUT  /api/v1/files/reorder       JSON {businessType,businessId,fileIds}
POST /api/v1/files/:id/replace   multipart file + stable Idempotency-Key
```

Reorder requires the exact visible attachment set for one binding and rejects
duplicates/missing/foreign IDs. Replace preserves ID, binding, position, and
creator; updates hash/name/size/MIME/object key; removes the old object only
after metadata update succeeds. Owner/admin may replace/reorder; server ACL is
authoritative.

- [x] **Step 2: Run focused tests and verify RED.**

```bash
go test ./internal/modules/file ./internal/app -count=1
```

- [x] **Step 3: Add migration/model/repository/service/handler behavior and register routes behind auth plus idempotency where a multipart mutation occurs.**

- [x] **Step 4: Fix authorized pagination so `total` and page metadata represent authorized results for a requested binding, not merely the filtered candidate page.**

- [x] **Step 5: Run migration, full backend tests, seed verification, and commit.**

```bash
go test ./...
bash scripts/test_m9_dev_seed.sh
git commit -m "feat: add ordered replaceable attachments"
```

## Task 10: Build The Frontend Attachment Data Boundary

**Files:**
- Modify: `rims_frontend/lib/core/network/api_endpoints.dart`
- Create: `rims_frontend/lib/features/attachments/domain/entities/attachment.dart`
- Create: `rims_frontend/lib/features/attachments/domain/repositories/attachments_repository.dart`
- Create: `rims_frontend/lib/features/attachments/data/models/attachment_models.dart`
- Create: `rims_frontend/lib/features/attachments/data/datasources/attachments_remote_datasource.dart`
- Create: `rims_frontend/lib/features/attachments/data/repositories/attachments_repository_impl.dart`
- Create: `rims_frontend/test/features/attachments/attachment_models_test.dart`
- Create: `rims_frontend/test/features/attachments/attachments_remote_datasource_test.dart`
- Create: `rims_frontend/test/features/attachments/attachments_repository_test.dart`

- [x] **Step 1: Write failing model/DataSource/repository tests for strict envelopes, pages, multipart fields, stable idempotency key, progress, cancel, reorder, replace, authorized byte download, delete, and malformed responses.**

Use `AttachmentBinding.productImage(productId)` and
`AttachmentBinding.document(documentId)` so raw backend strings do not leak
into presentation code.

- [x] **Step 2: Run focused tests and verify RED.**

```powershell
flutter test --no-pub test/features/attachments
```

- [x] **Step 3: Implement strict models and remote DataSource.**

Resolve relative `fileUrl` against the API origin only after validating it is a
same-origin path. Download private files through authenticated Dio and never
hand bearer tokens to an external browser.

- [x] **Step 4: Implement repository mapping and commit.**

```powershell
flutter test --no-pub test/features/attachments
git commit -m "feat: add attachment repository contracts"
```

## Task 11: Add Media Picking, Staging, Recovery, And Cache Cleanup

**Files:**
- Modify: `rims_frontend/lib/app.dart`
- Create: `rims_frontend/lib/features/attachments/domain/services/attachment_picker.dart`
- Create: `rims_frontend/lib/features/attachments/domain/services/attachment_staging_store.dart`
- Create: `rims_frontend/lib/features/attachments/data/services/android_attachment_picker.dart`
- Create: `rims_frontend/lib/features/attachments/data/services/file_attachment_staging_store.dart`
- Create: `rims_frontend/lib/features/attachments/data/services/attachment_share_service.dart`
- Create: `rims_frontend/test/features/attachments/attachment_picker_test.dart`
- Create: `rims_frontend/test/features/attachments/attachment_staging_store_test.dart`
- Create: `rims_frontend/test/features/attachments/attachment_share_service_test.dart`

- [x] **Step 1: Write failing tests for camera/gallery/file selection, cancellation, permission errors, 1920/quality-82 picker options, metadata disabled, EXIF-rotated image preview orientation, bounded thumbnails, size/type/count validation, collision-safe staging, no-space failure, manifest recovery, lost image-picker data, stale cache cleanup, and share/download behavior.**

- [x] **Step 2: Run tests and verify RED.**

```powershell
flutter test --no-pub test/features/attachments/attachment_picker_test.dart test/features/attachments/attachment_staging_store_test.dart
```

- [x] **Step 3: Implement adapters using existing dependencies only.**

Copy every accepted source into app support storage before upload. Image picker
resizing must preserve the orientation tag and the preview must honor it; create
a bounded local thumbnail and verify it with a rotated fixture. Store a
versioned JSON manifest atomically. Never persist source bytes or bearer tokens
in preferences. Treat Android system picker/SAF cancellation as a neutral user
action, not an error.

- [x] **Step 4: Recover `ImagePicker.retrieveLostData()` at application startup and make logout delete staged/downloaded attachment files owned by the session.**

- [x] **Step 5: Commit.**

```powershell
git commit -m "feat: stage and recover Android attachments"
```

## Task 12: Implement Attachment Queue State And Document Attachment UI

**Files:**
- Create: `rims_frontend/lib/features/attachments/presentation/view_models/attachments_view_model.dart`
- Create: `rims_frontend/lib/features/attachments/presentation/widgets/attachment_panel.dart`
- Create: `rims_frontend/lib/features/attachments/presentation/widgets/attachment_preview.dart`
- Modify: `rims_frontend/lib/app.dart`
- Modify: `rims_frontend/lib/routes/app_router.dart`
- Modify: `rims_frontend/lib/features/shell/presentation/pages/app_shell_page.dart`
- Modify: `rims_frontend/lib/features/documents/domain/entities/document_data.dart`
- Modify: `rims_frontend/lib/features/documents/domain/repositories/documents_repository.dart`
- Modify: `rims_frontend/lib/features/documents/data/datasources/documents_remote_datasource.dart`
- Modify: `rims_frontend/lib/features/documents/data/repositories/documents_repository_impl.dart`
- Modify: `rims_frontend/lib/features/documents/presentation/pages/documents_page.dart`
- Create: `rims_frontend/test/features/attachments/attachments_view_model_test.dart`
- Create: `rims_frontend/test/features/attachments/attachment_panel_test.dart`
- Modify: `rims_frontend/test/features/documents/documents_view_model_test.dart`

- [ ] **Step 1: Write failing ViewModel tests for load/empty/error, upload progress, one-flight guard, cancel, retry with the same request ID, interrupted upload recovery, background cancellation, resume, preview/download/share, delete confirmation, replace rollback feedback, and reorder rollback.**

- [ ] **Step 2: Write failing document-detail tests that load authoritative lines and an attachment panel for the selected document.**

- [ ] **Step 3: Run focused tests and verify RED.**

```powershell
flutter test --no-pub test/features/attachments test/features/documents
```

- [ ] **Step 4: Implement queue state and an ergonomic un-nested panel.**

Use icon buttons with tooltips for camera, gallery, file, retry, cancel,
download/share, replace, reorder, and delete. Give every transfer a stable
height/progress area so rows do not jump. Image preview uses local/downloaded
bytes; other types show metadata and share/open actions.

- [ ] **Step 5: Add authoritative document detail/line loading and inject the attachment repository/picker/staging/share capabilities through `AppShellPage`.**

- [ ] **Step 6: Commit.**

```powershell
git commit -m "feat: add document attachment workflow"
```

## Task 13: Integrate Product Images Without Duplicating Attachment Logic

**Files:**
- Modify: `rims_frontend/lib/features/admin/presentation/widgets/admin_products_panel.dart`
- Modify: `rims_frontend/lib/features/admin/presentation/view_models/admin_products_view_model.dart`
- Modify: `rims_frontend/lib/features/profile/presentation/pages/profile_page.dart`
- Modify: `rims_frontend/lib/features/inventory/presentation/widgets/inventory_product_tile.dart`
- Modify: `rims_frontend/test/features/admin/admin_products_panel_test.dart`
- Modify: `rims_frontend/test/features/admin/admin_products_view_model_test.dart`
- Modify: `rims_frontend/test/features/inventory/inventory_view_model_test.dart`

- [ ] **Step 1: Write failing tests for admin product image capture/select/upload/replace/delete, product `imageUrl` update, and visible inventory thumbnail fallback.**

- [ ] **Step 2: Verify RED, then embed the shared `AttachmentPanel` in product edit detail with `product_image` binding and maximum count 1.**

After upload/replace, update the product through the existing admin repository so
the public same-origin image URL is the product image. On delete, clear the
product image URL before deleting the object or restore it if deletion fails.

- [ ] **Step 3: Run admin/inventory tests and commit.**

```powershell
flutter test --no-pub test/features/admin test/features/inventory
git commit -m "feat: connect product image attachments"
```

## Task 14: Add Multi-Line Scan-Driven Document Drafts

**Files:**
- Modify: `rims_frontend/lib/features/documents/domain/entities/document_data.dart`
- Modify: `rims_frontend/lib/features/documents/data/models/document_models.dart`
- Modify: `rims_frontend/lib/features/documents/data/datasources/documents_remote_datasource.dart`
- Modify: `rims_frontend/lib/features/documents/presentation/view_models/documents_view_model.dart`
- Modify: `rims_frontend/lib/features/documents/presentation/pages/documents_page.dart`
- Modify: `rims_frontend/lib/features/home/presentation/view_models/home_view_model.dart`
- Modify: `rims_frontend/lib/features/shell/presentation/pages/app_shell_page.dart`
- Modify: `rims_frontend/test/features/documents/document_models_test.dart`
- Modify: `rims_frontend/test/features/documents/documents_remote_datasource_test.dart`
- Modify: `rims_frontend/test/features/documents/documents_view_model_test.dart`
- Modify: `rims_frontend/test/app_static_ui_test.dart`

- [ ] **Step 1: Write failing tests for typed `CreateDocumentLineRequest` lists and strict detail-line parsing.**

```dart
final class CreateDocumentRequest {
  const CreateDocumentRequest({required this.docType, required this.lines, ...});
  final List<CreateDocumentLineRequest> lines;
}
```

- [ ] **Step 2: Write failing ViewModel/widget tests for scan-to-sales, inbound, return, transfer, stocktake, and conversion; batch lines; duplicate quantity accumulation; line edit/remove; zero stocktake quantity; wrong source/batch; permission denial; and one-flight submit.**

Sales/inbound/transfer/stocktake support multiple product lines. Return lines
must belong to the selected source document and cannot exceed source quantity.
Conversion retains one non-standard source plus one scanned standard target.

- [ ] **Step 3: Verify RED, implement typed lines, and send one backend document request with all lines.**

Do not create one server document per scanned line. Preserve the same
idempotency key across a retry and atomically clear the draft only after the
authoritative create succeeds.

- [ ] **Step 4: Add a scan icon to the document form and make home `扫码销售` open sales with scanner requested, not just a plain text form.**

- [ ] **Step 5: Run document/static UI tests and commit.**

```powershell
flutter test --no-pub test/features/documents test/app_static_ui_test.dart
git commit -m "feat: add scan-driven multi-line documents"
```

## Task 15: Add Permission Guidance And Android Compatibility Coverage

**Files:**
- Modify: `rims_frontend/android/app/src/main/AndroidManifest.xml`
- Modify: `rims_frontend/android/app/src/debug/AndroidManifest.xml`
- Modify: `rims_frontend/android/app/build.gradle.kts`
- Create: `rims_frontend/lib/features/profile/presentation/widgets/device_permissions_panel.dart`
- Modify: `rims_frontend/lib/features/profile/presentation/pages/profile_page.dart`
- Create: `rims_frontend/test/features/profile/device_permissions_panel_test.dart`
- Create: `rims_frontend/test/features/scanner/scanner_compatibility_test.dart`
- Create: `rims_frontend/test/features/attachments/attachment_compatibility_test.dart`

- [ ] **Step 1: Write failing manifest/static tests for optional camera feature, camera permission, no broad storage permission, no premature notification permission, explicit minimum API evidence, and cleartext limited to debug/local behavior.**

- [ ] **Step 2: Write failing UI tests for camera, gallery, file, notification, and storage explanations.**

The UI must explain why camera is requested, that gallery/file use Android
system pickers, that notifications are not activated yet, and how low storage
or revoked permission affects pending work. It must not claim a permission is
granted without platform evidence.

- [ ] **Step 3: Add compatibility tests at phone/tablet widths, portrait/landscape, text scale 1.0/2.0, light/dark mode, keyboard insets, and system back.**

- [ ] **Step 4: Run tests, build a debug APK offline, inspect merged manifest, and commit.**

```powershell
flutter test --no-pub test/features/profile test/features/scanner test/features/attachments
flutter build apk --debug --no-pub
git commit -m "test: cover Android field compatibility"
```

## Task 16: Extend Real-Backend And Android Fault Acceptance

**Files:**
- Modify: `rims_frontend/integration_test/app_e2e_test.dart`
- Create: `rims_frontend/integration_test/m10_field_operations_test.dart`
- Modify: `rims_frontend/integration_test/support/rims_e2e_config.dart`
- Modify: `scripts/rims_android_smoke.ps1`
- Modify: `scripts/test_rims_android_smoke.ps1`
- Create: `scripts/rims_m10_smoke.ps1`
- Create: `scripts/test_rims_m10_smoke.ps1`

- [ ] **Step 1: Write wrapper self-tests for a new `field-operations` phase, camera grant/deny setup, HOME/resume hook, process recreation, network interruption, upload artifact capture, provider cleanup, and first-failure propagation.**

- [ ] **Step 2: Verify RED, then add deterministic test capability injection for barcode detections and picked local files.**

Injection is enabled only by explicit integration-test defines. Production
paths still initialize the real camera/pickers. Android acceptance must include
one real camera initialization/permission/lifecycle probe in addition to
deterministic barcode delivery.

- [ ] **Step 3: Implement the real-backend journey.**

Required scenarios:

```text
admin login -> camera deny guidance -> manual fallback
camera grant -> background -> resume -> deterministic detection
single lookup -> continuous duplicate suppression -> batch quantity accumulation
multi-line inbound create/complete -> stock and transaction effects
multi-line sales create/complete -> stock and transaction effects
document image upload -> progress -> list -> download/preview/share -> reorder
interrupt upload -> persisted failed state -> retry same request ID -> one object
replace -> old object unavailable/new content available -> delete
process recreation -> scan draft and staged upload recover
operator own-warehouse document attachment allowed
operator wrong-warehouse file list/get/download denied
logout -> scanner stopped and staged/download cache cleared
```

- [ ] **Step 4: Emit `RIMS_E2E_RESULT` M10 segments for camera lifecycle, scan feedback, document submission, upload first-progress, upload total, and permission boundary.**

- [ ] **Step 5: Run script self-tests and commit.**

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\test_rims_android_smoke.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\test_rims_m10_smoke.ps1
git commit -m "test: automate M10 Android field operations"
```

## Task 17: Run M10 Acceptance, Record Evidence, And Close The Milestone

**Files:**
- Modify: `README.md`
- Modify: `rims_frontend/README.md`
- Modify: backend `rims-goProgect/README.md`
- Modify: `docs/superpowers/plans/2026-07-10-rims-m10-execution-record.md`
- Modify: `docs/superpowers/plans/2026-07-10-rims-app-long-term-completion-master-plan.md`

- [ ] **Step 1: From stopped state, run frontend and backend deterministic gates.**

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\test_rims_local.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\test_rims_smoke.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\test_rims_web_e2e.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\test_rims_android_smoke.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\test_rims_m10_smoke.ps1
```

```powershell
Set-Location rims_frontend
flutter pub get --offline
dart format --output=none --set-exit-if-changed lib test integration_test test_driver
flutter analyze --no-pub
flutter test --no-pub
flutter build apk --debug --no-pub
```

```bash
go test ./...
build_output=$(mktemp /tmp/rims-server.XXXXXX)
trap 'rm -f -- "$build_output"' EXIT
go build -o "$build_output" ./cmd/server
bash scripts/test_m9_dev_seed.sh
```

- [ ] **Step 2: Run the aggregate M9 regression and M10 Android acceptance with AI-owned services.**

```powershell
$env:RIMS_ANDROID_DEVICE = 'Medium_Phone_API_36.1'
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\rims_local.ps1 -Command smoke -Target web -IncludeDependencies
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\rims_m10_smoke.ps1 -AndroidDevice $env:RIMS_ANDROID_DEVICE -IncludeDependencies
```

- [ ] **Step 3: Run explicit fault/compatibility probes.**

Cover camera denial/revocation, HOME/resume, process recreation, interrupted
upload, low-storage injection, duplicate detection, wrong warehouse, stale
permission, orientation, text scale, dark mode, keyboard, and system back.

- [ ] **Step 4: Record exact commits, timestamps, durations, report paths, fixture counts, attachment hashes/counts, stock effects, cleanup status, and P0/P1/P2/P3 defects.**

Do not mark PASS from test names alone. Read JSON reports and verify frontend and
backend commit identities, Boolean result types, Android integration exit code,
provider cleanup, and performance thresholds.

- [ ] **Step 5: Update local usage docs.**

Document how AI starts M10 services, which AVD is used, where local provider
files/reports live, test accounts/barcodes, permission behavior, reset safety,
and how to run scanner/attachment acceptance without cloud accounts.

- [ ] **Step 6: Verify no managed state, listeners, emulator, bridge, staged test files, or provider objects remain.**

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\rims_local.ps1 -Command status
git diff --check
git status --short
```

- [ ] **Step 7: Mark M10 complete only when all requirement rows have direct evidence, P0/P1 are zero, full gates pass, and final smoke is green. Commit frontend and backend evidence.**

```text
docs: record M10 Android field acceptance
```

The master plan may then activate M11. M11 inherits the scanner lookup cache,
scan-session schema, attachment staging manifest, stable transfer request ID,
local provider ownership, and Android lifecycle/fault harness; it must not reuse
M10 attachment staging as an authoritative offline outbox without adding the
M11 conflict and synchronization contracts.
