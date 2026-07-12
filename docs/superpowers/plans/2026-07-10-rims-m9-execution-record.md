# RIMS M9 Execution Record

Status: PASS

This record is populated only from observed local output. Final environment,
smoke, baseline, defect, and pass/fail evidence will be appended during the M9
acceptance run.

## Pagination Endpoint Audit

| Frontend operation | Backend contract | Classification | Consumer behavior |
| --- | --- | --- | --- |
| Current-user warehouses | `GET /users/me/warehouses` returns a complete array | Unpaged reference data | Session warehouse selector consumes the complete list |
| Inventory | `GET /inventory` returns `PageResult` | Paged | `PageData<InventoryItem>` with reset, append, retry, and total |
| Inventory alerts | `GET /inventory/alerts` returns `PageResult` | Paged preview | Home uses server `total`; inventory UI does not infer totals from page items |
| Non-standard inventory | `GET /non-std-inventory` returns `PageResult` | Paged | Home uses server `total`; conversion selector traverses all pages |
| Documents | `GET /documents` returns `PageResult` | Paged | Documents UI paginates; home renders a bounded preview with server total |
| Inventory transactions | `GET /transactions` returns `PageResult` | Paged | Documents UI paginates; inventory detail traverses all pages before product filtering |
| Admin users | `GET /users` returns `PageResult` | Paged | Admin panel uses `PageData<AdminUser>` |
| Admin products | `GET /products` returns `PageResult` | Paged | Admin panel uses `PageData<AdminProduct>` |
| Admin warehouses | `GET /warehouses` returns `PageResult` | Paged | Admin panel uses `PageData<AdminWarehouse>` |
| Warehouse-bound users | `GET /warehouses/{id}/users` returns `PageResult` | Paged | Binding editor traverses all pages and deduplicates by user ID |
| Roles | `GET /roles` returns a complete array | Unpaged reference data | Role editor consumes the complete list |
| Permissions | `GET /permissions` returns a complete array | Unpaged reference data | Permission editor consumes the complete list |
| Sales trend | `GET /reports/sales/trend` returns an aggregate response | Unpaged aggregate | Chart consumes all server-produced buckets |
| Sales ranking | `GET /reports/sales/ranking` accepts `limit` | Server-bounded ranking | UI requests and renders the server top 5 |
| Inventory overview | `GET /reports/inventory/overview` returns a summary object | Unpaged aggregate | Dashboard consumes summary buckets |
| Inventory turnover | `GET /reports/inventory/turnover` accepts `limit` | Server-bounded ranking | UI requests and renders the server top 5 |
| Slow-moving inventory | `GET /reports/inventory/slow-moving` returns `PageResult` | Paged preview | Repository preserves `PageData`; report exposes preview items and server total |

## Workspace Identity

| Workspace | Branch | Evidence commit |
| --- | --- | --- |
| Frontend/program | `codex/m9-local-autonomy-acceptance` | `b84d4b58d66686acd3898adcd8763eb5f2a1580c` |
| Backend | `codex/m9-local-autonomy-acceptance` | `0916479058e5908c9614f455af1fe763d829d44c` |

The frontend evidence commit is the last implementation commit before this
record and the baseline collector changes. The final documentation commit is
recorded by Git history immediately after this file.

## Environment

| Tool | Observed version |
| --- | --- |
| Windows PowerShell | `5.1.26100.8655` |
| Flutter | `3.44.1 stable` |
| Git | `2.49.0.windows.1` |
| WSL kernel | `6.18.33.2-microsoft-standard-WSL2` |
| Go | `go1.25.0 linux/amd64` |
| Chrome | `149.0.7827.201` |
| ChromeDriver | `149.0.7827.155` |
| Android AVD | `Medium_Phone_API_36.1` as `emulator-5554` |

Backend runtime root was `E:\My Work\RIMS`; backend source was the matching
branch worktree at
`E:\My Work\rims-frontend\.worktrees\m9-backend-local-autonomy-acceptance\rims-goProgect`.

## Fixture Evidence

The fresh Android smoke at `2026-07-12T18:18:55+08:00` observed database
`appdb` and these deterministic counts:

| Products | Operator users | Warehouses | Bindings | Inventories | Non-standard | Documents | Transactions |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 45 | 1 | 1 | 2 | 90 | 25 | 15 | 15 |

The two warehouses expose 45 fixture inventory rows each. `WH001` uses fixture
quantity 2 and five low-stock rows; `M9-WH-02` uses quantity 12 and zero
low-stock rows.

## Scenario Evidence

| Target | Started | Result | Business duration | Segments (ms) | Report |
| --- | --- | --- | ---: | --- | --- |
| Web | `2026-07-12T18:38:23+08:00` | PASS | 23,644 ms | admin 12,539; stock 5,666; operator 5,085; logout 354 | `.runtime/rims-local/reports/latest-smoke.json` |
| Android | `2026-07-12T18:40:20+08:00` | PASS | 40,297 ms | admin 19,357; stock 10,386; operator 9,149; logout 1,403 | `.runtime/rims-local/reports/latest-android-smoke.json` |

Both targets ran `integration_test/app_e2e_test.dart` without weakened Android
assertions. They proved admin login, session restoration, inventory pagination,
warehouse-specific quantities, completed inbound and sales documents with stock
and transaction effects, ordinary-user warehouse visibility and permission
denial, ordinary-user report restrictions, and logged-out restart behavior.

The Android host required an owned loopback bridge from `127.0.0.1:8080` to
WSL `[::1]:8080` after Hyper-V removed IPv4 localhost forwarding. The bridge,
emulator, backend, and runtime state were all absent after smoke cleanup.

## Regression Baseline

Source: `.runtime/rims-local/reports/m9-baseline.json`, collected from
`2026-07-12T18:46:58+08:00` to `18:47:37+08:00`.

| Measurement | Result | M9 threshold |
| --- | ---: | ---: |
| Backend cold-start readiness | 16,738 ms | observation only |
| Web cold-start readiness | 14,129 ms | observation only |
| `/healthz` min / median / p95 / max | 0.81 / 1.01 / 28.43 / 110.27 ms | p95 <= 1,000 ms |
| Inventory page 1 min / median / p95 / max | 3.19 / 3.93 / 5.45 / 8.06 ms | p95 <= 2,000 ms |
| Health requests | 20 success / 0 failure | no failures |
| Inventory page requests | 20 success / 0 failure | no failures |
| Inventory traversal | 87 items, 5 pages, 36.14 ms | complete traversal |
| Web E2E business duration | 23,644 ms | observation only |
| Android E2E business duration | 40,297 ms | observation only |
| Go backend peak working set | unavailable in WSL process model | observation only |

No baseline threshold was breached. This is a local regression baseline, not a
capacity or production certification.

## Defect Record

| ID | Severity | Status | Reproducer / evidence | Resolution |
| --- | --- | --- | --- | --- |
| M9-01 | P1 | FIXED | Android preparation used `up -Target android`; `flutter run` and integration install competed for ADB | Prepare backend with target `none`, then use the exact-ownership emulator helper |
| M9-02 | P1 | FIXED | AVD startup left WSL forwarding on `::1`; Windows `127.0.0.1` and emulator `10.0.2.2` could not reach API | Start an owned loopback-only IPv4-to-IPv6 bridge and verify both health paths |
| M9-03 | P0 | FIXED | Review showed failure before ownership acquisition could still execute unconditional `down/reset` | Track runtime ownership per run; preserve pre-existing state and add regression coverage |
| M9-04 | P1 | FIXED | Web and Android used different locks while sharing runtime and fixture data | Use the shared `acceptance-smoke.lock` |
| M9-05 | P1 | FIXED | Initial bridge listened on all interfaces | Bind only `127.0.0.1` and retain PID/start-time cleanup |
| M9-06 | P2 | FIXED | Failure artifacts used a fixed directory and could reference old files | Use a unique run directory and explicit artifact collection status |
| M9-07 | P2 | FIXED | Baseline collector used IPv4 loopback while lifecycle health used `localhost` | Align sampling with lifecycle `localhost` routing |

Open counts at M9 exit candidate: **P0 = 0, P1 = 0, P2 = 0, P3 = 0**.

## Plan Deviations

- Backend source was auto-selected from the matching branch worktree rather than
  the default main checkout, so frontend and backend evidence used aligned code.
- Web automation uses official `flutter drive -d web-server` with a managed
  ChromeDriver. `-d chrome` created two application instances in this test
  topology and was rejected by the real journey.
- Android preparation starts backend and emulator separately to avoid a second
  normal `flutter run` competing with the integration test.
- Android uses a loopback-only host bridge only when Hyper-V/WSL exposes the Go
  service on `[::1]` but not IPv4. Its identity and cleanup are report data.
- The backend worktree retains a pre-existing untracked `server` build artifact.
  It was not staged, modified intentionally, or deleted by this work.
- The plan set `RIMS_ALLOW_DEV_SEED=1` while invoking
  `test_m9_dev_seed.sh`. That test intentionally proves the seed refuses an
  unguarded run, so the variable makes its negative case invalid. Final
  verification ran the test script without the pre-set variable; the script
  then exercised its own guarded seed/reset cases and passed.

## Final Verification

| Started (+08:00) | Command | Duration | Exit | Evidence |
| --- | --- | ---: | ---: | --- |
| `2026-07-12 18:37:03` | `scripts/test_rims_local.ps1` | 60,543 ms | 0 | aggregate lifecycle output |
| `2026-07-12 18:38:03` | `scripts/test_rims_smoke.ps1` | 329 ms | 0 | structured smoke self-test |
| `2026-07-12 18:38:04` | `scripts/test_rims_web_e2e.ps1` | 3,095 ms | 0 | failure/cleanup/lock self-test |
| `2026-07-12 18:38:07` | `scripts/test_rims_android_smoke.ps1` | 4,962 ms | 0 | ownership/artifact/restore self-test |
| `2026-07-12 18:38:12` | `scripts/test_rims_m9_baseline.ps1` | 806 ms | 0 | strict 20-sample calculation test |
| `2026-07-12 18:38:23` | `rims_local smoke -Target web -IncludeDependencies` | 105,436 ms | 0 | `latest-smoke.json` |
| `2026-07-12 18:40:20` | `rims_local smoke -Target android -IncludeDependencies` | 143,885 ms | 0 | `latest-android-smoke.json` |
| `2026-07-12 18:43:09` | `flutter analyze --no-pub && flutter test --no-pub` | 17,772 ms | 0 | no analyzer issues; 398 tests passed |
| `2026-07-12 18:43:42` | `go test ./... && go build ./cmd/server && bash scripts/test_m9_dev_seed.sh` | 9,963 ms | 0 | Go packages and seed idempotency/reset passed |
| `2026-07-12 18:46:58` | `scripts/rims_m9_baseline.ps1` | 39,228 ms | 0 | `m9-baseline.json` |

Final repository checks passed: frontend and backend `git diff --check` returned
zero; no listener remained on 8080, 8091, or 4444; no managed state, emulator,
or host bridge remained. The backend worktree status contains only the
pre-existing untracked `server` build artifact. Frontend status contains only
the intended Task 16 source and documentation changes before commit.

## M9 Decision

**PASS.** Phase evidence, deterministic Web and Android journeys, pagination,
local lifecycle, baseline thresholds, and cleanup gates passed. Open P0 and P1
counts are zero. M10 may inherit the managed lifecycle, deterministic fixtures,
shared acceptance lock, Web/Android smoke gates, paged repository contracts,
and `RIMS_E2E_RESULT` segment format.
