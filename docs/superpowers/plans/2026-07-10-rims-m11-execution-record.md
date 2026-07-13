# RIMS M11 Execution Record

Status: IN PROGRESS

This record accepts only observed local output. Test names and implementation
claims are not exit evidence until report identities, state effects, duplicate
counts, encrypted storage ownership, cleanup, and baseline restore are read.

## Workspace Identity

| Workspace | Branch | M11 base commit | Worktree |
| --- | --- | --- | --- |
| Frontend/program | `codex/m11-limited-offline-sync` | `0e56f51` | `.worktrees/m11-limited-offline-sync` |
| Backend | `codex/m11-limited-offline-sync` | `946da39` | `.worktrees/m11-backend-limited-offline-sync` |

## Requirement Matrix

| Requirement | Plan task(s) | Required direct evidence | Status |
| --- | --- | --- | --- |
| Versioned encrypted native database | 2, 14 | migration, key, corruption, Android artifact | foundation PASS; Android acceptance pending |
| Web regression adapter | 2, 17 | Web M9 journey with in-memory store | adapter/build PASS; M9 journey pending |
| Verified network reachability | 3, 16 | captive/unreachable/switch probes | service PASS; fault harness pending |
| Account/warehouse scoped cache | 4-7 | cache keys, invalidation, no cross-scope read | primitives PASS; repositories pending |
| User/warehouse references | 5 | secure-token gate and cached projection | PASS |
| Product/inventory/alerts/barcode | 6 | offline read, stale source/age, no mutation authority | PASS |
| Documents/details/reports | 7 | offline read and financial field boundary | PASS |
| Six document draft types | 8, 9 | autosave, reopen, recreation, ownership | PASS |
| Explicit reviewed queueing | 11-13 | confirmation and immutable payload | immutable outbox PASS; UI pending |
| Outbox states and legal transitions | 11 | complete state matrix | PASS |
| Operation dependency ordering | 11, 13 | attachment -> create -> lifecycle | graph PASS; workflow wiring pending |
| Client operation/idempotency IDs | 10-13 | backend status and duplicate replay | status API PASS; replay pending |
| Unknown-result recovery | 10, 12 | status first, replay same key, one effect | status API PASS; coordinator pending |
| Conflict visibility/resolution | 12, 16 | no overwrite, replacement operation | planned |
| Session/permission revalidation | 12, 14, 16 | 401/403/account/warehouse probes | planned |
| Account cleanup and retention | 2, 14 | counts, files, key lifecycle | planned |
| Offline/stale UI | 6, 7, 9, 12, 15 | source, age, queued/attention state | planned |
| Fault recovery | 16 | airplane, latency, switch, termination, duplicate, conflict | planned |
| M9/M10 regression | 17 | current Web/Android/M10 reports | planned |
| M11 performance thresholds | 16, 17 | strict numeric report | planned |
| P0/P1 zero | 17 | final defect audit | planned |

## Environment And Entry Evidence

| Check | Observed result |
| --- | --- |
| Frontend base | M10 PASS commit `0e56f51` |
| Backend base | M10 PASS commit `946da39` |
| Existing persistence | secure storage, preferences, scan cache/session, attachment staging; no structured database |
| Existing connectivity | `connectivity_plus` dependency present but unused |
| Existing idempotency | document create and attachment upload/replace send stable keys; backend stores processing/completed responses |
| Managed runtime | no state, port 8080 not listening, no emulator/device |
| Tool versions | Flutter 3.44.1, Dart 3.12.1, Go 1.25.0, Docker 29.4.0, Compose 5.1.1, ADB 1.0.41 |

## Task 1 Contract Evidence

| Probe | Observed result |
| --- | --- |
| RED | architecture test failed because all five M11 contract imports were absent |
| Cache contract | typed network/cache source, deterministic expiry, account/warehouse cache key |
| Network contract | stable offline/checking/online/unreachable states and verified service interface |
| Draft contract | account/warehouse-owned versioned payload boundary |
| Outbox contract | seven stable states, five operation kinds, stable wire strings, confirmation boundary |
| Storage contract | cache, draft, dependency enqueue, ready query, transition, account clear, and prune methods |
| GREEN | 4 architecture tests passed; focused analysis reported no issues |

## Task 2 Encrypted Storage Evidence

| Probe | Observed result |
| --- | --- |
| Dependencies | Drift 2.34.1, drift_flutter 0.3.0, drift_dev 2.34.1; sqlite3 source is sqlite3mc |
| Schema | version 1; stable cache_records, document_drafts, outbox_operations, and outbox_dependencies names |
| Versioning | same cache identity retains distinct schema rows and reads the newest schema |
| Serialization | canonical sorted JSON, UTC timestamps, stable state/kind wire strings |
| Constraints | account/idempotency uniqueness, cascading dependency foreign keys, self/missing dependency rejection, 500-operation account cap |
| State machine | invalid skipped and terminal transitions rejected |
| Encryption | generated 32-byte key reused; native file header differs from plaintext SQLite; encrypted reopen preserves data |
| Recovery | unreadable database renamed with UTC timestamp and recreated without deleting secure key or staged files |
| Bootstrap | native app support directory plus secure storage; Web and widget tests inject MemoryOfflineStore |
| GREEN | build_runner PASS; strict analyze PASS; 17 focused tests PASS; release Web and Android debug APK builds PASS |

## Task 3 Verified Reachability Evidence

| Probe | Observed result |
| --- | --- |
| RED | tests failed because reachability service and passive ApiClient observer did not exist |
| Connectivity boundary | none maps to offline without a probe; Wi-Fi/mobile remain hints only |
| Health verification | root `/healthz` probe is bounded to 3 seconds; success maps online, false/timeout maps unreachable |
| Ordering | generation invalidates stale health completions after loss, switch, or successful API response |
| Request behavior | ApiClient always executes the real request before reporting success or mapped failure |
| Lifecycle | MainApp starts and disposes the service; widget tests inject a platform-free implementation |
| GREEN | strict analyze PASS; 19 network/API/widget tests PASS; release Web build PASS |

## Task 4 Cache Primitive Evidence

| Probe | Observed result |
| --- | --- |
| RED | tests failed because codec, policy, fallback, schema read, and scoped eviction did not exist |
| Codec | nested object keys serialize canonically while array order is preserved |
| Policy | references 24h, reports 6h, recent documents 7d; stale retention and namespace counts are bounded |
| Fallback | network-first success writes cache; only NetworkFailure reads fresh or explicitly stale retained data |
| Failure boundary | authentication, authorization, validation, conflict, and server failures remain unchanged |
| Scope | schema-specific reads and oldest-first eviction preserve other accounts and warehouses in memory and Drift |
| GREEN | strict analyze PASS; all offline plus architecture tests PASS (32 tests) |

## Task 5 Session Reference Evidence

| Probe | Observed result |
| --- | --- |
| RED | decorator and secure account reference were absent; base restore deleted token on NetworkFailure |
| Token gate | cached projection is readable only with a non-empty secure token and matching secure account ID |
| Payload | projection stores user and warehouse references but never stores the access token |
| Login | login always delegates to the backend; NetworkFailure never returns an existing session cache |
| Refresh | successful role/permission refresh replaces the projection; controller exposes source and age |
| Failure | network restore preserves token; authentication/authorization failures clear account cache/reference |
| Ownership | account and warehouse events drive account cleanup and old-warehouse cache invalidation |
| GREEN | strict analyze PASS; auth, cached auth, widget, and Drift regression tests PASS (53 tests) |

## Task 6 Inventory Read Evidence

| Probe | Observed result |
| --- | --- |
| RED | cached inventory repository, metadata, pagination-gap handling, and Drift scan migration were absent |
| Scope | exact keyword/page keys are isolated by secure account and current warehouse |
| Pagination | cached pages remain contiguous; a missing next page clamps total and disables hasMore |
| Inventory | successful refresh replaces quantities and preserves disabled/status fields; alerts and non-standard pages use separate namespaces |
| Barcode | cached barcode data preserves identity only and forces available/stock quantities to zero |
| UI/authority | page renders `离线缓存 · 更新于 <time>`; cached data cannot authorize inventory-setting mutation |
| Migration | complete legacy scan envelope is written to Drift before old key deletion; write failure preserves legacy data |
| Scanner | repository cache success remains visibly stale and is not rewritten as authoritative scan data |
| GREEN | strict analyze PASS; inventory, scanner, offline, and widget regression suites PASS (163 tests); release Web build PASS |

## Task 7 Document And Report Evidence

| Probe | Observed result |
| --- | --- |
| RED | document/report decorators and read metadata were absent |
| Documents | recent pages and selected details use typed codecs and scoped fallback; transaction history is never cached |
| Mutations | create and lifecycle calls always use backend and invalidate current warehouse cache only after success |
| Reports | all six report queries include exact parameters, account, warehouse, and financial/basic view namespace |
| Financial boundary | ordinary users cannot read financial/admin cache and render no sales financial sections |
| Error boundary | authorization and other non-network failures remain visible despite matching cache |
| UI | document and report pages show explicit cache source/time without replacing business status labels |
| GREEN | strict analyze PASS; document, report, offline, and widget suites PASS (169 tests); release Web build PASS |

## Task 8 Versioned Document Draft Evidence

| Probe | Observed result |
| --- | --- |
| RED | repository contract, six-type intent codec, immutable snapshot, review, retention, migration, and conflict behavior were absent |
| Intent | all six document types preserve lines, zero stocktake counts, target/source IDs, non-standard source IDs, remarks, and attachment staging IDs |
| Authority | recursive validation rejects cached stock authority fields; draft payloads contain user-entered intent only |
| Ownership | account-scoped reads reject cross-account access; role or warehouse changes produce explicit review reasons |
| Versioning | optimistic expected-version writes increment deterministically and map stale writes to conflict failures |
| Immutability | document requests produce unmodifiable payloads and draft construction snapshots nested maps, lists, and attachment IDs |
| Lifecycle | 30-day retention keeps the exact boundary; schema-zero product/quantity payloads migrate to version one lines on read |
| GREEN | strict analyze PASS; offline and document regression suites PASS (153 tests) |

## Task 9 Recoverable Draft UI Evidence

| Probe | Observed result |
| --- | --- |
| RED | autosave, management UI, process recovery, attachment binding, submit barriers, and async isolation APIs were absent or failed controlled races |
| Autosave | all form intent uses a 300 ms debounce and one-flight worker; draft identity and request generations reject stale completions |
| Recovery | six document types restore lines, transient inputs, warehouse/source intent, non-standard source, role review state, and independent attachments |
| Attachments | stable draft bindings use account-scoped paths, canonical root validation, per-account serialization, independent duplication, and persistent cleanup compensation |
| Safety | role downgrade cannot open or submit admin-only drafts; account/warehouse/session changes reject stale async results and cross-scope reads |
| Submit | form and attachment mutations are barred while submitting; queued saves drain before delete and late attachment operations reconcile by draft CAS |
| Management | Profile > Data and Cache exposes a dense authenticated draft list with review state and open, duplicate, rename, and confirmed discard workflows |
| Review | independent specification and code-quality reviews APPROVED after all P0/P1/P2 findings were fixed |
| GREEN | strict analyze PASS; full Flutter suite PASS (658 tests); diff check PASS |

## Task 10 Idempotency Status Evidence

| Probe | Observed result |
| --- | --- |
| RED | authenticated status handler, safe projection, shared route scopes, typed frontend parser, and key contract were absent |
| Isolation | repository status reads always include JWT user ID, scope, and key and project only state, status code, and expiry |
| Route | authenticated GET status returns processing/completed only; missing and expired records return 404 without stored response bodies |
| Scope | five idempotent mutation routes and the status allowlist share one registry with contract tests against actual Gin routes |
| Key | write middleware, status handler, and Flutter enforce the same 1-255 URL-safe contract and reject slash, Unicode, and dot segments |
| Client | key paths remain encoded, scope is a query parameter, known states and exact fields parse strictly, and ApiClient failures pass through unchanged |
| Review | independent specification and code-quality reviews APPROVED after key reachability and route-registry findings were fixed |
| GREEN | backend `go test ./...` PASS; frontend strict analyze and full suite PASS (680 tests); both diff checks PASS |

## Task 11 Deterministic Outbox Evidence

| Probe | Observed result |
| --- | --- |
| RED | repository contract, explicit transition matrix, transactional dependency graph, CAS, retry readiness, and adapter parity were absent |
| State | queued/retryable enter syncing; syncing reaches five explicit outcomes; illegal and terminal regressions are rejected with CAS |
| Graph | transactional enqueue rejects self, missing, cross-account, and cyclic dependencies; parent failures propagate visibly |
| Ordering | created time plus operation ID gives stable FIFO; injected clock/backoff controls retry readiness without busy loops |
| Conflict | schema v4 resolution ownership is one-to-one with composite FKs; replay compares immutable payload and actual dependency edges |
| Storage | active cap is 500 per account; expired terminal history prunes safely without pinning long chains or changing active readiness |
| Parity | Drift and Memory repositories pass one shared contract for state, dependency, retry, cancellation, conflict, prune, and cleanup behavior |
| Migration | real file fixtures prove v1, v2, and v3 upgrades to v4 with data, foreign keys, backfills, and repository behavior preserved |
| Safety | payloads are recursively immutable; account cleanup removes resolutions and graph rows atomically; programming errors are not disguised as storage failures |
| Review | independent specification and code-quality reviews APPROVED after all concurrency, lifecycle, and legacy-bypass findings were fixed |
| GREEN | strict analyze PASS; offline suite PASS (219 tests); full Flutter suite PASS (792 tests); diff check PASS |

## Final Android State Evidence

| Evidence | Observed result |
| --- | --- |

## Defect Record

| ID | Severity | Status | Reproducer/evidence | Resolution |
| --- | --- | --- | --- | --- |

Entry counts are not exit evidence. Final P0/P1 counts remain open until Task 17.

## Final Verification

| Started (+08:00) | Command | Duration | Exit | Evidence |
| --- | --- | ---: | ---: | --- |

## M11 Decision

**PLANNED.** M11 is not complete until cached reads and drafts work offline,
queued writes are explicitly confirmed and idempotent, conflicts never silently
overwrite server state, all local gates pass, cleanup is exact, and open P0/P1
counts are zero.
