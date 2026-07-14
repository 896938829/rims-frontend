# RIMS M11 Execution Record

Status: COMPLETE on 2026-07-15

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
| Versioned encrypted native database | 2, 14 | migration, key, corruption, Android artifact | PASS |
| Web regression adapter | 2, 17 | Web M9 journey with in-memory store | PASS |
| Verified network reachability | 3, 16 | captive/unreachable/switch probes | PASS |
| Account/warehouse scoped cache | 4-7 | cache keys, invalidation, no cross-scope read | PASS |
| User/warehouse references | 5 | secure-token gate and cached projection | PASS |
| Product/inventory/alerts/barcode | 6 | offline read, stale source/age, no mutation authority | PASS |
| Documents/details/reports | 7 | offline read and financial field boundary | PASS |
| Six document draft types | 8, 9 | autosave, reopen, recreation, ownership | PASS |
| Explicit reviewed queueing | 11-13 | confirmation and immutable payload | PASS |
| Outbox states and legal transitions | 11 | complete state matrix | PASS |
| Operation dependency ordering | 11, 13 | attachment -> create -> lifecycle | PASS |
| Client operation/idempotency IDs | 10-13 | backend status and duplicate replay | PASS |
| Unknown-result recovery | 10, 12 | status first, replay same key, one effect | PASS |
| Conflict visibility/resolution | 12, 16 | no overwrite, replacement operation | PASS |
| Session/permission revalidation | 12, 14, 16 | 401/403/account/warehouse probes | PASS |
| Account cleanup and retention | 2, 14 | counts, files, key lifecycle | PASS |
| Offline/stale UI | 6, 7, 9, 12, 15 | source, age, queued/attention state | PASS |
| Fault recovery | 16 | airplane, latency, switch, termination, duplicate, conflict | PASS |
| M9/M10 regression | 17 | current Web/Android/M10 reports | PASS |
| M11 performance thresholds | 16, 17 | strict numeric report | PASS |
| P0/P1 zero | 17 | final defect audit | PASS: 0 open |

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

## Task 12 Confirmed Foreground Sync Evidence

| Probe | Observed result |
| --- | --- |
| RED | executor, persistent review context, stale-sync recovery, status-first unknown handling, command isolation, and Sync Center were absent |
| Foreground | connectivity changes never start work; one explicit user command owns a serialized batch and revalidates context before every operation |
| Context | account, warehouse, actual backend permission codes, and stable permission fingerprint gate review and every command |
| Dependencies | the confirmed batch re-queries ready work so newly satisfied attachment, create, and lifecycle successors continue without duplicate execution |
| Unknown | stale syncing migrates or recovers as retryable unknown and must probe status before handler activity; absent retries the same key |
| Replay | completed status acquires a bounded backend lease before same-key replay; expiry delete/create races use CAS and deterministic rereads |
| Failures | processing waits with bounded probing; 401 pauses the batch, 403 becomes permanent, 409 becomes conflict, and command errors survive reload |
| Review | review stamp persists account, warehouse, and permission fingerprint with CAS; changed context requires a new explicit confirmation |
| UI | authenticated Sync Center provides waiting, attention, and completed tabs plus scoped review, retry, cancel, discard, and conflict commands |
| Parity | Drift and Web memory paths share one outbox repository; session refresh cannot clear command busy state or expose another account's results |
| Review gate | independent specification and code-quality reviews APPROVED after all permission, lifecycle, lease, migration, and concurrency findings were fixed |
| GREEN | backend `go test ./...` and race probes PASS; frontend strict analyze PASS, offline suite PASS (272 tests), full suite PASS (849 tests); diff checks PASS |

## Task 13 Queued Document And Attachment Evidence

| Probe | Observed result |
| --- | --- |
| RED | immutable document graphs, typed dependency outputs, lifecycle status recovery, durable attachment ownership, and coordinated cleanup were absent or failed controlled unknown-response and restart cases |
| Snapshot | document, lifecycle, reference, and attachment operations persist recursively immutable versioned DTO snapshots without tokens or cached stock authority |
| Graph | transactional create, serial attachment, complete/confirm/settle graphs enforce account, warehouse, permission, document-type, status, and dependency-output boundaries |
| Idempotency | unknown lifecycle outcomes probe status first; 404 accepts only the authoritative pre-state, while completed plus a valid replay lease supplies runtime-only proof for the unique post-state and same-key replay |
| Attachments | verified bounded staging snapshots transfer durable ownership to the outbox; restart recovery blocks direct retry and cleanup runs only after a scope-matched succeeded transition |
| Cleanup | draft and staging cleanup intents persist with the operation, protect active evidence from pruning, and are consumed idempotently after authoritative success |
| Fast path | successful online document and attachment requests retain the existing immediate path; validation, permission, conflict, and insufficient-stock failures remain visible and are not queued |
| Review | independent specification and code-quality reviews APPROVED after all P0/P1/P2 findings covering lifecycle provenance, dependency parsing, staging TOCTOU, replay evidence, and restart ownership were fixed |
| GREEN | strict analyze PASS; full Flutter suite PASS (973 tests); diff check PASS |

## Task 14 Offline Ownership And Retention Evidence

| Probe | Observed result |
| --- | --- |
| RED | ownership transition, exact preview, revocation recovery, key rotation, and command-specific scan cleanup tests exposed missing or over-broad behavior before implementation |
| Ownership | logout, account switch, warehouse switch, permission refresh, token expiry, and revocation run through serialized ownership transitions with account-scoped physical barriers and orphan recovery |
| Authentication | pending and committed token-owner generations prevent partially committed login or restore state; scoped reauthentication permits unblock only the matching account transaction |
| Revocation | a durable pending-revocation journal preserves failed cleanup intent across restart and participates in database-key rotation without exposing another account's data |
| Retention | explicit logout choice may retain encrypted user drafts for the same account; cache, outbox, downloads, scan data, and staged transfers follow reason-specific cleanup rules |
| Commands | clear-cache and clear-offline-work use command-specific content revisions, exact count previews, mandatory reconfirmation after change, and visible partial-failure recovery |
| Scan scope | clear-offline-work removes scan sessions only; clear-cache removes current and legacy lookup cache only; logout, account switch, and revocation remove both; warehouse and permission changes invalidate lookup only |
| Parity | Memory and real Drift adapters plus legacy SharedPreferences paths assert retained and deleted physical state, preview counts, revision changes, cleanup retry, and key rotation |
| Review | independent specification and code-quality reviews APPROVED with no open P0/P1/P2 after ownership, authentication, revocation, supersede, and scan-scope findings were fixed |
| GREEN | strict analyze PASS; full Flutter suite PASS (1157 tests); diff check PASS |

## Task 15 Global Offline And Stale Experience Evidence

| Probe | Observed result |
| --- | --- |
| RED | tests exposed missing global reachability UI, direct offline authoritative requests, stale-age scheduling, warehouse freshness leakage, stale review authority, overlapping Home loads, graph-classification cost, touch-target, and semantics gaps |
| Reachability | one full-width SafeArea band distinguishes checking, offline, API unreachable, and verified online without treating connectivity hints as backend reachability or covering five-tab content |
| Freshness | Home captures five data-slice metadata results per load generation; conservative aggregation uses the oldest fetch and earliest expiry, reports partial results as unknown, and binds updates to account, warehouse, and permission scope |
| Time | injected clock and scheduler update cache age and fresh-to-stale transitions without real waits; scope change and dispose cancel timers and reject late completions |
| Counts | status and Sync Center share current-account/current-warehouse permission classification; denied-empty loads skip graph reads, denied graphs use one O(V+E) multi-source traversal, and terminal history remains completed |
| Review safety | permission changes invalidate the full reviewed connected graph while classifying only permission-relevant active nodes, so A-to-denied-to-A never revives an old review stamp |
| Writes | known offline or unreachable create and lifecycle commands make zero authoritative requests; drafts remain editable and outbox writes require an immutable, scope-bound, explicit reviewed confirmation |
| Concurrency | enqueue uses a unified busy gate; account, warehouse, permission, context generation, submission epoch, and disposal checks reject stale dialogs, duplicate requests, mutable payloads, and late notifications |
| Home | latest-request-wins prevents overlapping loads from mixing generations or clearing loading early; retry and global refresh paths use one freshness-reporting helper |
| UI | queued and attention controls open Sync Center, refresh on return, retain 48-by-48 touch targets, and pass narrow phone, tablet, 2x text, component light/dark, keyboard, SafeArea, and non-duplicated semantics tests |
| Review | independent specification and code-quality reviews APPROVED after all P0/P1/P2 findings across freshness, scope, review authority, concurrency, graph performance, layout, and accessibility were fixed |
| GREEN | offline dependency resolution PASS; strict analyze PASS; full Flutter suite PASS (1208 tests); diff check PASS |

## Final Android State Evidence

| Evidence | Observed result |
| --- | --- |
| Aggregate report | `.runtime/reports/latest-m11-smoke.json`; `ok=true`; no failed step or evidence errors |
| Tested identities | frontend `b232fca2bd4c909bc40dc3a8378103239278c2d8`; backend `64826d23d302cc1627c23f156b6dac6dbece321c` |
| Owned route | `emulator -> owned fault proxy -> owned host bridge -> verified WSL backend`; route validation true and no unowned listener reached |
| Performance | cache 386 ms; draft save 11 ms; full autosave 651 ms; process recovery 649 ms; enqueue 225 ms; confirmed sync 7,101 ms; database 102,400 bytes |
| Idempotency | one unknown-status probe, two same-target replay requests, stable hashed key/fingerprint, one server document, zero duplicate documents, zero duplicate inventory transactions |
| Inventory | stock 48 -> 44; expected and observed decrease both 4 |
| Attachment | staged and uploaded SHA-256 both `d513664bb193a75493bd9597bb18f5190a2b49d86d89a968d5cc0a7cd2d8177f`; server attachment count 1 |
| Journey | every Boolean true: cached reads, draft/scanner/autosave/reopen, queued/attention, explicit sync, unknown replay, attachment/lifecycle, stale session/permission, conflict replacement, logout cleanup, corruption quarantine |
| Cleanup | account cache, outbox, staging and baseline cleanup all true; network restored; owned processes stopped; ports 8080/8081 not listening after exit |
| Regression | M9 Web and Android reports are `ok=true` and bind frontend `b232fca2` plus backend `64826d23`; M10 is `ok=true` from the same checked worktrees |

## Task 16 Local Fault Harness And Android Acceptance Evidence

| Probe | Observed result |
| --- | --- |
| RED | wrapper, review, and quality probes exposed missing process recreation, narrowed latency windows, unverified status replay, network-route spoofing, non-default-port loss, reset data loss, stale cleanup ownership, and storage rollback orphan races before the final implementation |
| Fault matrix | M11-only hooks cover airplane mode, latency, unreachable/packet loss, Wi-Fi restoration, process recreation, stale session/permission, unknown delivery, duplicate replay, conflict, database corruption, and first-failure cleanup |
| Process recovery | Android stages use real force-stop/relaunch boundaries, reopen Drift, drive scanner callback and 300 ms autosave, then measure recovery from the integration entry through navigation until the draft is visible |
| Network chain | dynamic owned fault proxy and host bridge prove `emulator -> 127.0.0.1 proxy -> 127.0.0.1 bridge -> ::1 verified WSL backend`; child and aggregate reports share strict address, PID/start-time, port, route, and backend-identity validation |
| Idempotency | the proxy observes the real status probe and replay request; evidence binds HTTP method, normalized target, body fingerprint, operation ID, and hashed idempotency key and requires exactly one document and inventory transaction |
| Performance | evidence enforces cached content <= 500 ms, full debounced draft persistence <= 250 ms, process recovery <= 1,000 ms, enqueue <= 250 ms, confirmed sync <= 10,000 ms excluding injected delay, and database size <= 25 MiB |
| Evidence types | child and aggregate validators reject fractional/string counts, malformed commits/hashes, missing cleanup Booleans, wrong network addresses, swapped routes, and duplicate document/transaction effects |
| Baseline reset | backend fixture reset is namespace-scoped, serialized, and failure-safe; DB rows and physical attachments use durable claim/version leases, completed tombstones, path/active-reference guards, and strict zero pending cleanup evidence |
| Storage cleanup | uploads and replacements register durable cleanup before storage writes; prepare tokens gate metadata commits, maintenance uses atomic `SKIP LOCKED` claims with leases/version fencing, and completed tombstones prevent stale workers from deleting newly bound objects |
| Capacity | M9 fixture and generic storage tombstones emit counts and configured limits; any incomplete generic storage cleanup causes reset failure rather than a false clean baseline |
| Backend | final Task 16 backend HEAD `64826d2`; `bash scripts/test_m9_dev_seed.sh` PASS against PostgreSQL; `go test ./... -count=1` PASS; migrations 15-17 upgrade and repeat safely |
| Frontend | final Task 16 frontend HEAD `2624cf4`; M11, Android, and M10 wrapper self-tests PASS; strict analyze PASS; full Flutter suite PASS (1208 tests); M11 integration debug APK builds |
| Review | repeated specification and quality reviews drove all reported P0/P1/P2 fixes; final main-agent code audit and fresh gates found no remaining Task 16 P0/P1/P2 |
| Boundary | Task 17 stopped-state acceptance and report inspection are recorded above; wrapper self-tests and APK compilation remain supporting, not substitute, evidence |

## Defect Record

| ID | Severity | Status | Reproducer/evidence | Resolution |
| --- | --- | --- | --- | --- |
| M11-17-01 | P1 | FIXED | confirmed profile logout could dispose the page before invoking the captured callback | capture callback before dialog; invoke after confirmation; guard only local `setState`; widget regression |
| M11-17-02 | P1 | FIXED | logout could clear in-memory session before durable credential cleanup completed | await repository credential cleanup before clearing session; lifecycle tests |
| M11-17-03 | P1 | FIXED | ownership preview could wait forever for quiescence | bounded quiescence timeout with diagnostics and regression coverage |
| M11-17-04 | P1 | FIXED | Android helper could tap a disabled/offscreen offline submit action | wait for an enabled hit-testable action before tapping |
| M11-17-05 | P1 | FIXED | proxy disconnect mapped to transport-unknown and did not reverify health | `ApiReachabilityObserver` verifies unknown transport failures while excluding business failures; 33 network tests |
| M11-17-06 | P2 | FIXED | first formal enqueue measured 282 ms against a 250 ms limit | merge Drift operation/idempotency lookups; final observed enqueue 225 ms |
| M11-17-07 | P1 | FIXED | acceptance helper treated unknown-response submission as known-offline | pass authoritative start state explicitly; same-key status/replay evidence retained |
| M11-17-08 | P1 | FIXED | reachability context notification during retained overlay build raised `markNeedsBuild` | defer generation-guarded context notifications post-frame; realistic shared-ViewModel widget regression |

Final open counts: P0 = 0, P1 = 0, P2 = 0, P3 = 0.

## Final Verification

| Started (+08:00) | Command | Duration | Exit | Evidence |
| --- | --- | ---: | ---: | --- |
| 2026-07-15 00:27 | `scripts/rims_m11_smoke.ps1` | 337.9 s device step | 0 | current formal M11 report; all 12 steps and cleanup PASS |
| 2026-07-15 00:35 | six PowerShell wrapper self-tests | about 4 min | 0 | each isolated process returned 0 |
| 2026-07-15 00:38 | managed M9 Web smoke | 136.4 s | 0 | A-F journey, fixture counts, baseline and driver cleanup PASS |
| 2026-07-15 00:41 | managed M9 Android smoke | 141.7 s | 0 | A-F journey, bridge/AVD ownership and baseline cleanup PASS |
| 2026-07-15 00:43 | `scripts/rims_m10_smoke.ps1` | about 2 min | 0 | all field-operation scenarios and provider cleanup PASS |
| 2026-07-15 00:47 | Flutter final gates | about 1 min | 0 | format 296/0 changed; analyze clean; 1,232 tests; debug APK built |
| 2026-07-15 00:49 | backend Go/build/seed gates | about 1 min | 0 | `go test ./...`, temp build, M9 seed/reset idempotency PASS |

## M11 Decision

**PASS.** M11 is complete. Cached reads and drafts work offline; queued writes
require explicit review and confirmation; unknown results are idempotent;
conflicts remain visible and never silently overwrite server state; M9, M10,
M11 and all local gates pass; cleanup is exact; open P0/P1 counts are zero.

The post-acceptance commit `cdb4cb2` changes Dart formatting in tests only. No
production code changed after the formal report identity above. M12 inherits the
encrypted-record inventory, key lifecycle, outbox payloads, permission
revalidation, redacted evidence, and the foreground explicit-confirmation rule.
