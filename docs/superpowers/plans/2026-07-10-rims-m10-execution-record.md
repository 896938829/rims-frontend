# RIMS M10 Execution Record

Status: IN PROGRESS

This record is populated only from observed local output. A test name or an
implementation claim is not acceptance evidence until its report, commit,
runtime ownership, cleanup, and business effects have been inspected.

## Workspace Identity

| Workspace | Branch | M10 base commit | Worktree |
| --- | --- | --- | --- |
| Frontend/program | `codex/m10-android-field-operations` | `93e2424` | `.worktrees/m10-android-field-operations` |
| Backend | `codex/m10-android-field-operations` | `ea1bb56` | `.worktrees/m10-backend-android-field-operations` |

## Entry Evidence

| Check | Observed result |
| --- | --- |
| Frontend dependency setup | `flutter pub get --offline` passed |
| Frontend analysis | no issues |
| Frontend tests | 398 passed |
| Backend tests | `go test ./...` passed |
| Managed runtime | stopped; no state and port 8080 not listening |
| Scanner implementation | dependency present; no scanner feature/page/adapter |
| Inventory scan icon | submits current text to global product-barcode lookup |
| Attachment frontend | absent |
| Backend file module | local storage plus upload/list/get/download/delete and dynamic ACL present |
| Android main manifest | no app-owned permission guidance/configuration beyond plugin merges |

## Requirement Matrix

| Requirement | Plan task(s) | Required direct evidence | Status |
| --- | --- | --- | --- |
| Camera capability boundary | 5, 6 | fake-adapter unit tests plus real Android initialization | adapter verified; real Android initialization pending |
| Manual barcode input | 6, 7 | widget and Android journey | pending |
| Keyboard-wedge adapter | 7 | key timing/focus tests and Android journey | pending |
| Single scan | 5-7 | domain, widget, integration result | pending |
| Continuous scan | 5, 6, 16 | duplicate-window counts and segment timing | pending |
| Batch scan | 5, 6, 14, 16 | recovered lines and one backend document | pending |
| Quantity accumulation | 5, 14, 16 | duplicate scans produce exact line quantity | pending |
| Torch, zoom, tap focus | 6, 16 | adapter tests and emulator controls | pending |
| Sound and vibration | 6 | independent feedback-capability tests | pending |
| Unsupported-code feedback | 5, 6 | format tests and visible Android state | pending |
| Unknown/disabled/wrong-warehouse errors | 2, 3, 5, 16 | backend contract plus operator journey | backend contract verified; Android journey pending |
| Wrong-batch constraint | 5 | domain constraint test; inactive until batch module exists | pending |
| Scan-to-search | 3, 7 | authoritative current-warehouse detail | route and detail flow verified; Android journey pending |
| Scan-to-inbound/outbound | 14, 16 | multi-line stock and transaction effects | pending |
| Scan-to-return/transfer/stocktake/conversion | 14, 16 | request shape, permission, and lifecycle tests | pending |
| Bounded offline scan identity | 5 | schema/TTL/warehouse/logout tests | verified |
| Camera permission explanation/revocation | 6, 15, 16 | deny/grant/revoke/resume evidence | adapter/widget verified; Android journey pending |
| Gallery/file/storage guidance | 11, 15 | system-picker and explanation tests | pending |
| Notification guidance without premature permission | 15 | manifest and UI tests | pending |
| Camera capture/gallery/file selection | 11, 12 | adapter/widget/Android journey | pending |
| Compression/orientation/metadata/thumbnail | 11 | rotated fixture and bounds evidence | pending |
| Attachment type/size/count validation | 8, 11 | backend and frontend boundary tests | backend verified; frontend pending |
| Upload progress/cancel/retry | 4, 12, 16 | first-progress/total timing and same request ID | transport primitives verified; attachment journey pending |
| Interrupted upload/process recreation | 11, 12, 16 | staged manifest recovery and one server object | pending |
| Preview/download/share | 10-12, 16 | authenticated bytes/hash and UI action evidence | pending |
| Replace/reorder/delete | 9, 12, 16 | contract, ACL, rollback, and object evidence | backend and real API verified; UI pending |
| Product image relationship | 13, 16 | upload, product URL, render, replace/delete | pending |
| Document attachment relationship | 12, 16 | current/wrong warehouse ACL journey | pending |
| Approval/audit/feedback relationships | 9-12 | contract inheritance only; modules not activated | pending |
| Local provider ownership/reset | 2, 17 | exact runtime path, reset, no residual objects | implementation verified; final audit pending |
| Background/resume | 6, 12, 16 | HOME/resume and transfer state evidence | scanner lifecycle verified; Android/transfer journey pending |
| Low storage | 11, 12, 16 | injected disk failure preserves recoverable state | pending |
| Portrait/landscape/tablet/font/dark/keyboard/back | 15-17 | compatibility tests and screenshots/report | pending |
| Server authorization remains authoritative | 3, 8, 9, 16 | direct API and UI permission-denial evidence | pending |
| Sensitive logging redaction | 4 | token/multipart/path/password redaction tests | verified |
| M9 regression preserved | 16, 17 | Web and Android M9 reports on current commits | pending |
| M10 performance thresholds | 16, 17 | strict numeric report and threshold result | pending |
| P0/P1 zero | 17 | final defect audit | pending |

## Environment

| Tool/device | Observed version |
| --- | --- |
| Windows PowerShell | pending final capture |
| Flutter/Dart | Flutter 3.44.1 at entry; pending final capture |
| Go | go1.25.0 at entry; pending final capture |
| Android AVD/API | `Medium_Phone_API_36.1` at entry; pending final capture |
| Chrome/ChromeDriver | pending final capture |
| PostgreSQL/Docker | pending final capture |

## Fixture Evidence

| Fixture | Expected purpose | Observed result |
| --- | --- | --- |
| `M10-ACTIVE-001` | active current-warehouse scan | `M9-PAGE-0001`, active, both fixture warehouses |
| `M10-DISABLED-001` | disabled product feedback | `M9-PAGE-0002`, product status 0 |
| `M10-WH001-ONLY-001` | wrong-warehouse feedback | inventory status 1 in `WH001`, 0 in `M9-WH-02` |
| `M10-PRODUCT-IMAGE-001` | product attachment lifecycle | `M9-PAGE-0004`, active |
| `M9DOC0001` / `M9DOC0002` M10 target remarks | cross-warehouse document ACL and attachment lifecycle | `WH001` / `M9-WH-02`, deterministic remarks |

## Task 2 Runtime Evidence

| Probe | Observed result |
| --- | --- |
| RED lifecycle test | failed because `attachmentStorage` was absent |
| Aggregate lifecycle after implementation | passed |
| Managed `up -Target none -IncludeDependencies` | passed; backend healthy at port 8080 |
| Runtime state | recorded `.runtime/rims-local/providers/files` |
| Managed `down` | passed; state/listener removed |
| Provider reset probe | owned file removed, provider recreated, sibling preserved |
| Backend full tests | `go test ./...` passed |
| Seed idempotency/reset | passed with fingerprint `45|1|1|2|90|25|15|15|15` |

## Task 3 Barcode Lookup Evidence

| Probe | Observed result |
| --- | --- |
| Backend RED | focused test failed because `GetInventoryByBarcode` did not exist |
| Frontend RED | focused test observed the legacy `/products/barcode/:barcode` request |
| Focused tests | backend barcode suite and 10 frontend DataSource tests passed |
| Full regression | `go test ./... -count=1`, Flutter analysis, and all 398 Flutter tests passed |
| Active WH001 lookup | `M10-ACTIVE-001` returned HTTP 200/code 0, inventory 6753, product `M9-PAGE-0001`, quantity 2 |
| Disabled product | `M10-DISABLED-001` returned HTTP 422/code 20002 with no inventory payload |
| Warehouse isolation | `M10-WH001-ONLY-001` returned quantity 2 in WH001 and HTTP 422/code 20002 in `M9-WH-02` |
| Unknown barcode | `M10-UNKNOWN-001` returned HTTP 404/code 10004 with no inventory payload |
| Runtime cleanup | exactly owned backend stopped; pre-existing healthy PostgreSQL remained user-managed |

## Task 4 Transfer Primitive Evidence

| Probe | Observed result |
| --- | --- |
| RED | tests failed for absent failure types, cancellation/progress parameters, and safe interceptor |
| Cancellation | cancelled Dio request mapped to `CancellationFailure`, not authentication |
| Transfer callbacks | upload and byte-response download progress callbacks both observed |
| Response bytes | `ResponseType.bytes` preserved exact response bytes `[4,5,6]` |
| Safe logging | method/path/status/duration/trace ID/sizes retained; bearer token, query token, password, multipart filename, and local path absent |
| Core verification | Flutter analysis clean; all 48 `test/core` tests passed |

## Task 5 Scan Domain Evidence

| Probe | Observed result |
| --- | --- |
| Session modes | single, continuous cooldown, batch uniqueness, and quantity accumulation verified |
| Boundary rules | empty/unsupported input, max lines, quantity controls, stale request suppression, submit/clear verified |
| Server failures | unknown, disabled, real Chinese wrong-warehouse, wrong-batch, permission, and network states classified |
| Recovery | schema/owner validation, TTL, 500-entry bound, corrupt JSON recovery, restart and warehouse-scoped drafts verified |
| Offline boundary | cache restores identity only with zero quantities and `isStale=true`; submission remains server-backed |
| Logout | app root clears prior user's cache and drafts while warehouse scopes remain independent |
| Integration defect | platform preferences initialization made lazy after focused widget failure |
| Full verification | Flutter analysis clean; all 433 Flutter tests passed |

## Task 6 Scanner Adapter And Page Evidence

| Probe | Observed result |
| --- | --- |
| Plugin adapter | required controller configuration, barcode mapping, state mapping, and serialized lifecycle verified |
| Hardware controls | torch, clamped zoom, and normalized native focus verified against plugin adapter |
| Lifecycle safety | revoke/retry, late stop, dispose idempotence, and scan/access stream closure verified |
| Feedback | sound and vibration independently toggleable and failure-tolerant |
| Page | stable 4:3 viewport, four modes, manual input, batch rows, visible failures, permission actions, back navigation verified |
| Compatibility | narrow viewport and large text rendered without overflow |
| Real device gate | deferred to Task 16 Android smoke as planned |

## Task 7 Scan-To-Search Evidence

| Probe | Observed result |
| --- | --- |
| Inventory entry | scan icon launches injected single-mode scanner and opens returned authoritative detail |
| Manual fallback | manual barcode remains usable during camera denial and follows the same lookup state machine |
| Scanner result | non-stale single result returns to inventory; stale cached identity cannot masquerade as authoritative detail |
| Keyboard wedge | printable ASCII plus Enter emits exactly one code within bounded inter-key timeout |
| Focus boundary | editable fields, disabled tabs, non-printable keys, and Back/Escape are not globally captured |
| Shell activation | switching from Home to Inventory explicitly focuses the opt-in wedge listener |
| Focused regression | all 103 inventory/scanner tests passed including post-mount activation |
| Full verification | Flutter analysis clean; all 463 Flutter tests passed |

## Task 8 Backend Attachment Hardening Evidence

| Probe | Observed result |
| --- | --- |
| Count limit | ninth-bound attachment rejected before reader, storage, or metadata mutation |
| MIME families | image/PDF/CSV/XLSX allow families verified; HTML and executable disguises rejected |
| Atomic storage | owner-only sibling temp, context-aware copy, sync/close/rename, and cleanup verified |
| Failure preservation | cancellation and source errors leave an existing target unchanged with no temp residue |
| Configuration | default 9 wired to production router; non-positive value rejected by direct config test |
| Backend regression | `go test ./... -count=1`, temporary server build, and M9 seed/reset passed |

## Task 9 Ordered And Replaceable Attachment Evidence

| Probe | Observed result |
| --- | --- |
| Migration | real DB reports `position|0|NO` and `idx_file_business_position` |
| Upload ordering | real document uploads IDs 19/20 received positions 0/1 |
| Reorder | exact reverse set returned IDs 20/19 with positions 0/1; list matched |
| Replace | ID 19, binding, creator and position 1 preserved; object/hash/name changed |
| Download integrity | replacement metadata SHA-256 equaled authenticated download SHA-256 |
| ACL | non-owner operator reorder returned HTTP 403/code 10002 with no mutation |
| Rollback/contracts | duplicate/missing/foreign sets, DB update rollback, route idempotency, and audit payload covered by Go tests |
| Authorized pagination | service paginates after dynamic ACL and reports authorized total only |
| Cleanup | test rows soft-deleted; managed backend stopped; exactly owned provider reset |
| Regression | full Go tests, temporary server build, and M9 seed/reset passed |

## Task 10 Frontend Attachment Data Boundary Evidence

| Probe | Observed result |
| --- | --- |
| Domain boundary | typed product/document bindings keep backend business strings out of presentation code |
| Strict parsing | required IDs, sizes, timestamps, positions, pages, envelopes, and attachment objects reject malformed values |
| URL safety | only relative same-origin paths without query or fragment resolve against the configured API origin |
| Multipart contract | upload binding fields and replace-only file payload match backend routes |
| Retry/cancel | stable `Idempotency-Key`, progress callback, pre-cancel, and in-flight Dio cancellation verified |
| Mutations | reorder exact ID payload, authenticated byte download, and delete endpoints verified |
| Storage boundary | repository hands authenticated bytes to injected local storage and maps storage failures |
| Focused regression | all 13 attachment boundary tests passed |
| Full verification | Flutter analysis clean; all 476 Flutter tests passed |

## Task 11 Media Staging And Recovery Evidence

| Probe | Observed result |
| --- | --- |
| Media options | camera/gallery enforce 1920 x 1920, quality 82, and full metadata disabled |
| Picker behavior | camera/gallery/file, neutral cancellation, permission mapping, and lost-data retention verified |
| Validation | extension/MIME family, actual 10 MiB size, and maximum count checks run before queueing |
| Owned staging | source copied under account-scoped application support storage with stable request ID |
| Collision/failure | request-ID collision cannot overwrite; copy/no-space failures leave no manifest entry or partial file |
| Manifest | versioned path/metadata-only JSON is replaced atomically and recovered without source bytes or tokens |
| Thumbnail | Flutter decoder produces orientation-preserving PNG with longest side bounded to 512 pixels |
| Cleanup | stale staged, thumbnail, and download files cleaned; logout removes only the prior account directory |
| Sharing | only an existing local authenticated download is handed to the platform share sheet |
| Startup | app starts lost-image recovery and stale cleanup before session restore completes |
| Focused regression | all 27 attachment tests passed, including 14 Task 11 service tests |
| Full verification | Flutter analysis clean; all 490 Flutter tests passed |

## Task 12 Document Attachment Workflow Evidence

| Probe | Observed result |
| --- | --- |
| Queue state | load/empty/error, progress, one-flight, cancel, stable-ID retry, interruption, pause, and resume verified |
| Recovery | manifest entries and retained Android lost selections enter the document-bound interrupted queue |
| Mutations | delete, replace, and exact-set reorder restore the prior UI list on backend failure |
| Download/share | authenticated repository bytes persist locally before the platform share sheet receives a path |
| Panel ergonomics | icon tools with tooltips, fixed 76-pixel transfer rows, preview, progress, and confirmation controls verified |
| Document detail | `GET /documents/:id` strictly parses authoritative header and every line; missing/malformed lines fail visibly |
| Injection | repository, picker, staging, and share capabilities flow through app/router/shell into document detail |
| Compatibility | legacy summary fallback remains when a test or host does not provide detail/attachment capabilities |
| Focused regression | attachment, document, and app-entry suites passed together (148 tests) |
| Full verification | Flutter analysis clean; all 503 Flutter tests passed |

## Task 13 Product Image Integration Evidence

| Probe | Observed result |
| --- | --- |
| Shared workflow | admin product editor embeds the same attachment panel with `product_image` binding and count 1 |
| Sources/mutations | shared camera, gallery, upload, replace, delete, retry, and staging paths are reused without duplication |
| Product synchronization | upload/replace publishes the public same-origin URL through existing admin update API |
| Clear semantics | nullable update `imageUrl` distinguishes omitted from explicit empty-string clear at the wire boundary |
| Delete rollback | product URL clears before file deletion and restores when backend file deletion fails |
| Inventory thumbnail | root-relative/absolute API same-origin URLs render; empty or external URLs use a visible fallback |
| Focused regression | product image synchronization/admin/inventory tests passed (92 tests) |
| Full verification | Flutter analysis clean; all 508 Flutter tests passed |

## Task 14 Scan-Driven Multi-Line Document Evidence

| Probe | Observed result |
| --- | --- |
| Typed wire contract | document request carries typed line list and one stable `Idempotency-Key` |
| Batch submission | multiple draft lines serialize into one backend document request, never one document per line |
| Duplicate/edit/remove | repeated scans accumulate quantity; quantity update and line removal operate on the draft |
| Lifecycle | failed submit retains lines/request ID; authoritative success atomically clears both |
| Business variants | sales/inbound/transfer/stocktake retain multi-line support; zero stocktake remains valid |
| Restrictions | return source/product/quantity and single-target non-standard conversion constraints remain enforced |
| Scan entry | document form exposes scan icon; returned authoritative product enters draft immediately |
| Home entry | `扫码销售` routes to sales with scanner requested instead of opening only text input |
| Focused regression | document and static UI suites passed together (118 tests) |
| Full verification | Flutter analysis clean; all 513 Flutter tests passed |

## Task 15 Android Permission And Compatibility Evidence

| Probe | Observed result |
| --- | --- |
| Minimum platform | source and merged debug manifest agree on Android API 24 |
| Camera boundary | `CAMERA` declared with camera hardware optional; manual and picker fallbacks remain available |
| Storage/notification | no read/write/manage external storage or notification permission appears in source or merged manifest |
| Network boundary | release manifest denies cleartext; debug overlay alone enables local HTTP development |
| User guidance | profile explains camera, gallery, file, notification, and low-storage effects without claiming unknown grant state |
| Responsive coverage | phone/tablet, portrait/landscape, text scale 2.0, light/dark, keyboard inset, and system back tests passed |
| Full verification | Flutter analysis clean; all 524 Flutter tests passed |
| Android artifact | offline debug build produced `build/app/outputs/flutter-apk/app-debug.apk` |

## Task 16 M10 Android Acceptance Automation Evidence

| Probe | Observed result |
| --- | --- |
| Local ownership | M10 wrapper delegates to the Android wrapper that starts backend/emulator, owns the host bridge, resets fixtures, and restores baseline |
| Fault hooks | camera revoke/grant, HOME, old-process stop, Wi-Fi disable/enable, and provider cleanup are explicit field-operation actions |
| First failure | injected network-interruption failure exits 23, stops later scenarios, still runs provider cleanup, and preserves the first failed step |
| Injection boundary | barcode and picked-file providers require `RIMS_E2E_FIELD_OPERATIONS=true`; normal builds retain real camera and Android pickers |
| Real camera | M10 journey mounts the real camera capability for initialization/permission/lifecycle probing before deterministic delivery |
| Scan lifecycle | permission guidance, manual fallback, pause/resume retry, duplicate accumulation, and consumed-session cleanup are automated |
| Documents | two-product sales and inbound documents are created, completed, and matched to inventory transactions |
| Attachments | deterministic file upload, list, replace, delete, process recreation, and owned provider cleanup are automated |
| Result contract | six required timing segments plus document IDs, permission boundary, camera state, and recreation state emit in `RIMS_E2E_RESULT` |
| Deterministic gates | Flutter analysis clean; all 528 Flutter tests and both PowerShell wrapper self-tests passed |
| Runtime status | Android and real-backend execution remains pending Task 17; no acceptance PASS is claimed here |

## Scanner Scenario Evidence

| Scenario | Web/unit | Android | Real backend effect | Result |
| --- | --- | --- | --- | --- |
| Single/manual/wedge | pending | pending | lookup only | pending |
| Continuous duplicate control | pending | pending | lookup only | pending |
| Batch/quantity | pending | pending | one multi-line document | pending |
| Camera deny/grant/revoke | pending | pending | none | pending |
| HOME/resume/recreation | pending | pending | draft recovery only | pending |

## Attachment Scenario Evidence

| Scenario | Binding | Hash/count evidence | Permission evidence | Result |
| --- | --- | --- | --- | --- |
| Capture/select/stage | document | pending | pending | pending |
| Upload/cancel/retry | document | pending | pending | pending |
| Preview/download/share | document | pending | pending | pending |
| Replace/reorder/delete | document | pending | pending | pending |
| Product image lifecycle | product | pending | admin only | pending |
| Wrong warehouse | document | unchanged | 403/no leak | pending |

## Performance Evidence

| Measurement | Threshold | Observed | Result |
| --- | ---: | ---: | --- |
| Injected scan feedback p95 | <= 250 ms | pending | pending |
| Local online barcode lookup p95 | <= 2,000 ms | pending | pending |
| 5 MiB first upload progress | <= 1,000 ms | pending | pending |
| 5 MiB local upload total | <= 10,000 ms | pending | pending |
| M9 Web duration regression | <= 20% | pending | pending |
| M9 Android duration regression | <= 20% | pending | pending |

## Defect Record

| ID | Severity | Status | Reproducer/evidence | Resolution |
| --- | --- | --- | --- | --- |

Entry open counts are not exit evidence. Final P0/P1 counts remain pending.

## Plan Deviations

| Task | Observed constraint | Decision | Verification impact |
| --- | --- | --- | --- |
| 8 | `position` does not exist before Task 9 migration | Keep count enforcement in Task 8; add max-position query atomically with Task 9 schema | None for Task 8 count/MIME/atomic-write gates; Task 9 tests must directly cover max position |

## Final Verification

| Started (+08:00) | Command | Duration | Exit | Evidence |
| --- | --- | ---: | ---: | --- |

## M10 Decision

**PENDING.** M10 may be marked PASS only after every activated requirement row
has direct evidence, all final gates pass, local providers and processes are
clean, and open P0/P1 counts are zero.
