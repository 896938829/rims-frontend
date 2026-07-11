# RIMS M9 Local Autonomy And Acceptance Hardening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give an AI worker a deterministic local RIMS environment it can start, inspect, test, reset, and stop by itself, then close the first-page-only acceptance gap with real pagination and Web/Android end-to-end evidence.

**Architecture:** A PowerShell lifecycle controller owns only the processes it starts and records them under an ignored runtime directory. It coordinates PostgreSQL in Docker through WSL, the Go API, and either Flutter Web or an Android emulator. The Flutter data boundary introduces a typed `PageData<T>` contract so repositories retain backend pagination metadata; ViewModels own append, deduplication, retry, and filter reset behavior. Local-only fixtures make multi-page, multi-warehouse, and permission scenarios repeatable without production seed migrations.

**Tech Stack:** PowerShell 7/Windows PowerShell 5.1, WSL, Bash, Docker Compose, PostgreSQL 16, Go, Gin, GORM, Flutter, Dart, Provider, Dio, `integration_test`, Chrome/Web Server, Android Emulator.

---

## 1. Scope And Exit Contract

This plan is the first executable child of
`docs/superpowers/plans/2026-07-10-rims-app-long-term-completion-master-plan.md`.
Run commands from `E:\My Work\rims-frontend` unless a step names another
working directory.

M9 is complete only when all of the following are true:

- [ ] `scripts/rims_local.ps1 -Command doctor -Target web` reports every
  required Web dependency healthy.
- [ ] `scripts/rims_local.ps1 -Command up -Target web` starts or reuses only
  managed local dependencies and reaches API and frontend readiness.
- [ ] `scripts/rims_local.ps1 -Command smoke -Target web` passes frontend,
  backend, fixture, and real-browser checks.
- [ ] `scripts/rims_local.ps1 -Command smoke -Target android` passes on the
  configured Android emulator.
- [ ] Inventory, documents, transactions, users, products, warehouses, alerts,
  and non-standard inventory can access records beyond the first server page.
- [ ] Pagination preserves filters and warehouse scope, deduplicates appended
  rows, and exposes retry/end states.
- [ ] The E2E suite proves login, session restore, warehouse switching,
  pagination, document completion and stock impact, permission denial, and
  logout against the real local backend.
- [ ] Re-running fixture setup and environment startup is idempotent.
- [ ] `down` stops only controller-owned processes; an unmanaged process on a
  required port is reported and left untouched.
- [ ] P0/P1 defects are zero and the M9 execution record contains fresh command
  evidence.

Use these local identities only for M9:

| Identity | Password | Role | Warehouses |
| --- | --- | --- | --- |
| `admin` | `admin123` | administrator | `WH001`, `M9-WH-02` |
| `m9_operator` | `admin123` | ordinary user | `WH001`, `M9-WH-02` |

The controller must reject `APP_ENV` values other than `dev`, `development`, or
`test` before applying M9 fixtures or destructive reset operations.

## 2. Runtime State Contract

All generated state lives under `.runtime/rims-local/` and is ignored by Git:

```text
.runtime/rims-local/
  state.json
  logs/
    backend.stdout.log
    backend.stderr.log
    frontend.stdout.log
    frontend.stderr.log
  reports/
    latest-smoke.json
    latest-e2e.json
```

`state.json` records `schemaVersion`, workspace paths, target, ports, start
time, frontend/backend Git commits, process IDs, process start times, health
URLs, emulator ID, and log paths. A PID is considered owned only when both PID
and process start time still match. Never kill a process based on port number
alone.

## Task 1: Establish The Lifecycle CLI Contract

**Files:**
- Create: `scripts/rims_local.ps1`
- Create: `scripts/lib/rims_local_common.ps1`
- Create: `scripts/test_rims_local.ps1`
- Modify: `.gitignore`

- [ ] **Step 1: Write a failing help-contract test**

Add a child-process test to `scripts/test_rims_local.ps1` so exit codes are
verified rather than masked by the test shell:

```powershell
$result = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File `
  "$PSScriptRoot\rims_local.ps1" -Command help -Output Json 2>&1
if ($LASTEXITCODE -ne 0) { throw "help exited $LASTEXITCODE`n$result" }
$help = $result | ConvertFrom-Json
Assert-Equal 1 $help.schemaVersion 'help schema version'
Assert-Contains $help.commands 'up' 'help commands'
Assert-Contains $help.commands 'down' 'help commands'
Assert-Contains $help.targets 'android' 'help targets'
```

- [ ] **Step 2: Run the test and confirm it fails**

Run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/test_rims_local.ps1
```

Expected: FAIL because `scripts/rims_local.ps1` does not exist.

- [ ] **Step 3: Implement the command surface and shared result helpers**

Use this public parameter contract in `scripts/rims_local.ps1`:

```powershell
param(
  [ValidateSet('help', 'doctor', 'up', 'status', 'logs', 'restart',
    'reset', 'smoke', 'down')]
  [string]$Command = 'status',
  [ValidateSet('none', 'web', 'android')]
  [string]$Target = 'none',
  [ValidateSet('Text', 'Json')]
  [string]$Output = 'Text',
  [string]$BackendDir = $env:RIMS_BACKEND_DIR,
  [string]$BackendWorkspaceRoot = $env:RIMS_BACKEND_WORKSPACE_ROOT,
  [int]$BackendPort = 8080,
  [int]$FrontendPort = 8091,
  [string]$AndroidDevice = $env:RIMS_ANDROID_DEVICE,
  [switch]$IncludeDependencies
)
```

Define result objects in `scripts/lib/rims_local_common.ps1` with these stable
fields: `schemaVersion`, `command`, `ok`, `exitCode`, `startedAt`,
`finishedAt`, `components`, and `errors`. JSON mode writes exactly one JSON
document to stdout; diagnostic text goes to stderr or log files.

- [ ] **Step 4: Ignore runtime output without hiding source fixtures**

Append this exact entry to `.gitignore`:

```gitignore
/.runtime/
```

- [ ] **Step 5: Re-run the contract test**

Run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/test_rims_local.ps1
git diff --check
```

Expected: PASS and no whitespace errors.

- [ ] **Step 6: Commit the CLI contract**

```powershell
git add .gitignore scripts/rims_local.ps1 scripts/lib/rims_local_common.ps1 scripts/test_rims_local.ps1
git commit -m "feat: add local runtime command contract"
```

## Task 2: Implement Environment Diagnosis

**Files:**
- Modify: `rims_frontend/android/gradle.properties`
- Modify: `scripts/rims_local.ps1`
- Modify: `scripts/lib/rims_local_common.ps1`
- Modify: `scripts/test_rims_local.ps1`

- [ ] **Step 1: Add failing doctor tests**

Cover both a valid environment and an invalid backend override. Parse JSON and
assert component names, not human-readable prose:

```powershell
$invalidBackendDir = Join-Path `
  ([IO.Path]::GetTempPath()) `
  ('rims-local-missing-' + [guid]::NewGuid().ToString('N'))
$bad = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File `
  "$PSScriptRoot\rims_local.ps1" -Command doctor -Target web -Output Json `
  -BackendDir $invalidBackendDir 2>&1
Assert-NotEqual 0 $LASTEXITCODE 'invalid backend directory exit code'
$badResult = $bad | ConvertFrom-Json
Assert-False $badResult.ok 'invalid backend directory result'
Assert-ComponentFailed $badResult 'backendWorkspace'
```

The valid test must assert these components: `powershell`, `wsl`, `git`,
`flutter`, `frontendWorkspace`, `backendWorkspace`, `workspaceEnv`, `go`,
`docker`, `dockerCompose`, and `webDevice`. Android diagnosis additionally
requires `adb`, `emulator`, and the requested emulator/device.

- [ ] **Step 2: Run the self-test and confirm the new assertions fail**

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/test_rims_local.ps1
```

Expected: FAIL because `doctor` has no component checks.

- [ ] **Step 3: Implement path resolution and dependency checks**

Resolve the backend source directory in this order:

1. Explicit `-BackendDir`.
2. `RIMS_BACKEND_DIR`.
3. `E:\My Work\RIMS\rims-goProgect`.

Resolve the backend runtime workspace root independently in this order:

1. Explicit `-BackendWorkspaceRoot`.
2. `RIMS_BACKEND_WORKSPACE_ROOT`.
3. The nearest ancestor of `BackendDir` containing both `deploy` and `.env`.
4. `E:\My Work\RIMS` when it contains both required entries.

This separation is required for Git worktrees: Go source may run from an
isolated worktree while Compose and the ignored local `.env` remain in the main
backend workspace. Record both resolved paths in state and reports.
Run Go and Docker checks through WSL, including the configured Go binary:

```powershell
wsl.exe -e bash -lc "test -x ~/local/go/bin/go && ~/local/go/bin/go version"
wsl.exe -e bash -lc "docker version --format '{{.Server.Version}}'"
wsl.exe -e bash -lc "docker compose version"
```

Convert Windows paths with `wslpath -a` through a single quoted-argument helper;
do not concatenate unescaped user input into Bash commands.

- [ ] **Step 4: Add actionable remediation to failed components**

Each component result contains `name`, `ok`, `required`, `detail`, and
`remediation`. Android checks are optional for `Target=web` and required for
`Target=android`. `doctor` exits `0` only when all required checks pass.

- [ ] **Step 5: Verify both paths**

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/test_rims_local.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/rims_local.ps1 -Command doctor -Target web
```

Expected: self-test PASS; local doctor either passes or names a precise missing
dependency without a stack trace.

- [ ] **Step 6: Commit environment diagnosis**

```powershell
git add scripts/rims_local.ps1 scripts/lib/rims_local_common.ps1 scripts/test_rims_local.ps1
git commit -m "feat: diagnose local runtime dependencies"
```

## Task 3: Own PostgreSQL And Backend Lifecycles Safely

**Files:**
- Modify: `scripts/rims_local.ps1`
- Modify: `scripts/lib/rims_local_common.ps1`
- Modify: `scripts/test_rims_local.ps1`

- [ ] **Step 1: Add failing process-ownership and state tests**

Use harmless long-running PowerShell child processes in the self-test to prove:

- matching PID plus start time is owned;
- reused PID or mismatched start time is stale;
- unmanaged occupied ports cause `up` to fail without stopping the process;
- `down` removes stale state but stops only a matching owned process;
- malformed `state.json` is quarantined with the filename pattern
  `state.invalid.20260710T153000Z.json`.

Tests set `RIMS_RUNTIME_DIR` to a unique temporary directory and restore the
previous value in `finally`; production defaults remain `.runtime/rims-local`.
Allocate test ports from an ephemeral listener instead of assuming 8080 is
free. Every spawned test process is tracked and stopped in `finally`, even when
an assertion fails.

- [ ] **Step 2: Run the self-test and observe the ownership failure**

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/test_rims_local.ps1
```

Expected: FAIL because process identity and state persistence are absent.

- [ ] **Step 3: Implement atomic state and port inspection**

Write state to `state.json.tmp`, then replace `state.json`. Store process start
time in UTC ISO-8601. Use `Get-NetTCPConnection` only for diagnosis; port
ownership never grants permission to terminate a process.

- [ ] **Step 4: Start dependencies and migrations through WSL**

For `up -IncludeDependencies`, run Docker Compose from
`E:\My Work\RIMS\deploy\docker-compose.yml`, wait until PostgreSQL reports
healthy, then run:

```bash
~/local/go/bin/go run ./cmd/migrate up
```

Run Compose with the resolved runtime workspace `.env`. For Go migrations and
server startup, export that `.env` into the WSL child environment, change to the
resolved backend source worktree, and set `MIGRATIONS_DIR` to that source
worktree's `migrations` directory. Pass runtime/source WSL paths as process
arguments or safely quoted literals; never embed an unescaped Windows path or
secret value into Bash source. This ensures the executed Go code comes from the
M9 branch while local secrets and Compose remain outside Git.

Do not mark the Docker daemon or a pre-existing healthy PostgreSQL container as
controller-owned. Record whether Compose was already running so `down` leaves
pre-existing dependencies intact.

- [ ] **Step 5: Start the Go API as a hidden managed process**

Use `Start-Process` with `-WindowStyle Hidden`, `-PassThru`, and separate stdout
and stderr redirects. Start WSL in the backend project path and run:

```bash
APP_PORT=8080 ~/local/go/bin/go run ./cmd/server
```

Poll `http://localhost:8080/healthz` with a bounded timeout and include the tail
of backend stderr when readiness fails. Record PID, process start time, command,
backend commit, health URL, and log paths only after readiness succeeds.

- [ ] **Step 6: Implement `status`, `logs`, `restart`, and `down`**

`status` reconciles state with process identity and health. `logs` tails the
selected managed component. `restart` performs managed stop/start while leaving
pre-existing dependencies alone. `down` sends a normal termination first,
waits, then force-stops only the still-matching owned process.

- [ ] **Step 7: Run lifecycle verification**

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/test_rims_local.ps1
$backendSource = 'E:\My Work\rims-frontend\.worktrees\m9-backend-local-autonomy-acceptance\rims-goProgect'
$backendRuntime = 'E:\My Work\RIMS'
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/rims_local.ps1 -Command up -Target none -IncludeDependencies -BackendDir $backendSource -BackendWorkspaceRoot $backendRuntime -BackendPort 18080
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/rims_local.ps1 -Command status -BackendPort 18080 -Output Json | ConvertFrom-Json | Format-List
Invoke-RestMethod http://localhost:18080/healthz
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/rims_local.ps1 -Command down -Target none -BackendPort 18080
```

Expected: API reaches healthy state, status reports a matching owned backend,
and down removes only its managed process.

- [ ] **Step 8: Commit backend lifecycle support**

```powershell
git add scripts/rims_local.ps1 scripts/lib/rims_local_common.ps1 scripts/test_rims_local.ps1
git commit -m "feat: manage local backend lifecycle"
```

## Task 4: Add Managed Web And Android Frontend Targets

**Files:**
- Modify: `scripts/rims_local.ps1`
- Modify: `scripts/lib/rims_local_common.ps1`
- Modify: `scripts/lib/rims_local_doctor.ps1`
- Create: `scripts/lib/rims_local_frontend.ps1`
- Modify: `scripts/lib/rims_local_lifecycle.ps1`
- Modify: `scripts/lib/rims_local_state_lock.ps1`
- Modify: `scripts/test_rims_local.ps1`
- Modify: `scripts/tests/test_rims_local_cli.ps1`
- Create: `scripts/tests/test_rims_local_frontend.ps1`
- Modify: `scripts/tests/test_rims_local_lock.ps1`
- Modify: `scripts/tests/test_rims_local_support.ps1`

- [ ] **Step 1: Add failing command-builder tests**

Assert the exact target-specific API origins:

```powershell
$web = New-FlutterLaunchSpec -Target web -FrontendPort 8091 -BackendPort 8080
Assert-Contains $web.Arguments '--web-hostname=127.0.0.1' 'web hostname'
Assert-Contains $web.Arguments '--dart-define=API_BASE_URL=http://localhost:8080/api/v1' 'web API URL'

$android = New-FlutterLaunchSpec -Target android -AndroidDevice 'rims_api_35' -BackendPort 8080
Assert-Contains $android.Arguments '--dart-define=API_BASE_URL=http://10.0.2.2:8080/api/v1' 'emulator API URL'
```

Also verify the command builder rejects `Target=none` for frontend startup and
does not insert shell metacharacters into arguments.

- [ ] **Step 2: Run the self-test and confirm failure**

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/test_rims_local.ps1
```

Expected: FAIL because frontend launch specifications do not exist.

- [ ] **Step 3: Implement Web startup and readiness**

Launch from `rims_frontend` as a hidden managed process:

```text
flutter run --no-pub -d web-server --web-hostname=127.0.0.1
  --web-port=$FrontendPort
  --dart-define=API_BASE_URL=http://localhost:$BackendPort/api/v1
```

Preserve arguments as an array until `Start-Process`. Poll the frontend URL for
HTTP success and verify the process remains alive. Save frontend PID/start time,
commit, URL, target, and logs to state.

- [ ] **Step 4: Implement emulator discovery and Android startup**

For Android:

1. Reuse an online requested device from `adb devices`.
2. Otherwise start the requested AVD hidden with the Android emulator CLI.
3. Wait for `sys.boot_completed=1` with a bounded timeout.
4. Run Flutter with `-d $AndroidDevice` and the `10.0.2.2` API origin.
5. Treat an emulator that was already running as unmanaged and leave it alive
   during `down`.
6. Disable Kotlin incremental compilation, use in-process compilation, disable
   persistent Gradle daemons, and bound Gradle workers at the project level to
   avoid the Kotlin 2.3.20 cache-registration failure and worker/daemon deadlock
   observed during a clean local Android build.

- [ ] **Step 5: Verify target lifecycle behavior**

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/test_rims_local.ps1
$backendSource = 'E:\My Work\rims-frontend\.worktrees\m9-backend-local-autonomy-acceptance\rims-goProgect'
$backendRuntime = 'E:\My Work\RIMS'
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/rims_local.ps1 -Command up -Target web -IncludeDependencies -BackendDir $backendSource -BackendWorkspaceRoot $backendRuntime -BackendPort 18080 -FrontendPort 18091
Invoke-WebRequest http://127.0.0.1:18091 -UseBasicParsing | Select-Object StatusCode
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/rims_local.ps1 -Command down -Target web -BackendDir $backendSource -BackendWorkspaceRoot $backendRuntime -BackendPort 18080 -FrontendPort 18091
```

Expected: tests PASS, frontend returns HTTP 200, and managed processes stop.

- [ ] **Step 6: Commit frontend target support**

```powershell
git add scripts/rims_local.ps1 scripts/lib scripts/test_rims_local.ps1 scripts/tests/test_rims_local_frontend.ps1
git commit -m "feat: manage web and android targets"
```

## Task 5: Create Idempotent Local Acceptance Fixtures

**Files:**
- Create: `E:\My Work\RIMS\rims-goProgect\scripts\m9_dev_seed.sql`
- Create: `E:\My Work\RIMS\rims-goProgect\scripts\m9_dev_seed.sh`
- Create: `E:\My Work\RIMS\rims-goProgect\scripts\test_m9_dev_seed.sh`
- Modify: `scripts/rims_local.ps1`
- Modify: `scripts/test_rims_local.ps1`

- [ ] **Step 1: Write a failing seed idempotency test**

The Bash test must apply the seed twice through `psql`, then assert exact stable
counts:

```bash
test "$(sql "SELECT count(*) FROM products WHERE code LIKE 'M9-PAGE-%'")" = "45"
test "$(sql "SELECT count(*) FROM users WHERE username = 'm9_operator' AND deleted_at IS NULL")" = "1"
test "$(sql "SELECT count(*) FROM warehouses WHERE code = 'M9-WH-02' AND deleted_at IS NULL")" = "1"
test "$(sql "SELECT count(*) FROM user_warehouses uw JOIN users u ON u.id=uw.user_id WHERE u.username='m9_operator' AND uw.deleted_at IS NULL")" = "2"
test "$(sql "SELECT count(*) FROM documents WHERE doc_no LIKE 'M9DOC%'")" = "15"
test "$(sql "SELECT count(*) FROM inventory_transactions WHERE doc_no LIKE 'M9DOC%'")" = "15"
```

The test also verifies at least five low-stock rows and 25 rows in each fixture
warehouse, enough to cross the frontend page size.

- [ ] **Step 2: Run the seed test and confirm it fails**

From `E:\My Work\RIMS\rims-goProgect`:

```powershell
$backendWsl = (wsl.exe -e wslpath -a 'E:\My Work\RIMS\rims-goProgect').Trim()
wsl.exe -e bash -lc "cd '$backendWsl' && bash scripts/test_m9_dev_seed.sh"
```

Expected: FAIL because the seed scripts do not exist.

- [ ] **Step 3: Add the environment guard**

Both shell files and the SQL file begin with the repository SPDX/copyright
header. `m9_dev_seed.sh` loads the normal local `.env`, then rejects the run
unless:

- `APP_ENV` is `dev`, `development`, or `test`;
- `DB_HOST` is `localhost`, `127.0.0.1`, `postgres`, or the local Compose
  service name;
- the database name is the configured local RIMS database;
- the caller passes `RIMS_ALLOW_DEV_SEED=1`.

- [ ] **Step 4: Implement deterministic upserts**

`m9_dev_seed.sql` must:

- revive or create `M9-WH-02`;
- bind `admin` to both fixture warehouses;
- revive or create `m9_operator` using the known local-only `admin123` bcrypt
  hash already documented in `migrations/000001_init.sql`;
- bind the operator to `WH001` and `M9-WH-02`, with `WH001` as default;
- create products `M9-PAGE-0001` through `M9-PAGE-0045` using
  `generate_series(1, 45)`;
- create/update inventory in both warehouses with deterministic quantity,
  threshold, and status values;
- create at least 25 deterministic non-standard inventory rows;
- create 15 completed read-only fixture documents named `M9DOC0001` through
  `M9DOC0015`, with one matching line and transaction each, so document and
  transaction page 2 are deterministic without changing current inventory;
- update matching active rows and restore soft-deleted fixture rows rather than
  adding duplicates;
- leave all non-`M9-` business data untouched.

- [ ] **Step 5: Wire fixtures into `up`, `reset`, and `smoke`**

`up -IncludeDependencies` applies migrations and the seed after PostgreSQL is
healthy. `reset` requires managed local dependencies, prints the selected
database and fixture prefix, removes M9 fixture rows and E2E documents whose
remark begins `M9-E2E:` in foreign-key-safe order, and reapplies the seed. JSON
output records fixture counts.

- [ ] **Step 6: Run fixture verification twice**

```powershell
$backendWsl = (wsl.exe -e wslpath -a 'E:\My Work\RIMS\rims-goProgect').Trim()
wsl.exe -e bash -lc "cd '$backendWsl' && RIMS_ALLOW_DEV_SEED=1 bash scripts/test_m9_dev_seed.sh"
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/rims_local.ps1 -Command reset -Target none -Output Json | ConvertFrom-Json
```

Expected: PASS, identical counts across both applications, and no rows outside
the `M9-` fixture namespace are removed.

- [ ] **Step 7: Commit fixture changes in their owning repositories**

Backend:

```powershell
git add scripts/m9_dev_seed.sql scripts/m9_dev_seed.sh scripts/test_m9_dev_seed.sh
git commit -m "test: add deterministic M9 acceptance fixtures"
```

Frontend controller:

```powershell
git add scripts/rims_local.ps1 scripts/test_rims_local.ps1
git commit -m "feat: manage local M9 fixtures"
```

## Task 6: Introduce A Typed Pagination Boundary

**Files:**
- Create: `rims_frontend/lib/core/pagination/page_data.dart`
- Create: `rims_frontend/lib/core/network/api_page_parser.dart`
- Create: `rims_frontend/test/core/pagination/page_data_test.dart`
- Create: `rims_frontend/test/core/network/api_page_parser_test.dart`

- [ ] **Step 1: Write failing value-object tests**

Cover immutable items, `hasNextPage`, `nextPage`, empty pages, and mapping while
retaining metadata:

```dart
test('maps items without losing server metadata', () {
  final page = PageData<int>(items: [1, 2], total: 5, page: 2, pageSize: 2);

  final mapped = page.map((value) => 'item-$value');

  expect(mapped.items, ['item-1', 'item-2']);
  expect(mapped.total, 5);
  expect(mapped.page, 2);
  expect(mapped.pageSize, 2);
  expect(mapped.hasNextPage, isTrue);
  expect(mapped.nextPage, 3);
});
```

- [ ] **Step 2: Write failing API parser tests**

Use the backend payload shape exactly:

```dart
final page = parseApiPage<Item>(
  <String, Object?>{
    'list': <Object?>[<String, Object?>{'id': 7}],
    'total': 21,
    'page': 2,
    'pageSize': 20,
  },
  (json) => Item.fromJson(json),
);
```

Assert `FormatException` for missing/non-list `list`, non-numeric metadata,
`page < 1`, `pageSize < 1`, negative total, and an item that is not a JSON map.

- [ ] **Step 3: Run tests and confirm compile failure**

From `rims_frontend`:

```powershell
flutter test --no-pub test/core/pagination/page_data_test.dart test/core/network/api_page_parser_test.dart
```

Expected: FAIL because the production types do not exist.

- [ ] **Step 4: Implement `PageData<T>`**

Use this public API:

```dart
final class PageData<T> {
  PageData({
    required List<T> items,
    required this.total,
    required this.page,
    required this.pageSize,
  }) : items = List<T>.unmodifiable(items);

  final List<T> items;
  final int total;
  final int page;
  final int pageSize;

  bool get hasNextPage => page * pageSize < total;
  int get nextPage => page + 1;

  PageData<R> map<R>(R Function(T item) convert) => PageData<R>(
        items: items.map(convert).toList(growable: false),
        total: total,
        page: page,
        pageSize: pageSize,
      );
}
```

The constructor shown above makes the page contents unmodifiable; callers must
not mutate page contents.

- [ ] **Step 5: Implement strict page parsing**

`parseApiPage<T>` accepts the unwrapped API `data` object and an item converter.
It does not silently turn malformed paged responses into empty lists. Direct
list parsing remains in endpoint-specific code only for truly unpaged endpoints
such as roles and permissions.

- [ ] **Step 6: Run targeted and framework tests**

```powershell
flutter test --no-pub test/core/pagination/page_data_test.dart test/core/network/api_page_parser_test.dart
flutter analyze --no-pub
```

Expected: all targeted tests pass; analyzer reports no issues.

- [ ] **Step 7: Commit the pagination primitive**

```powershell
git add rims_frontend/lib/core/pagination rims_frontend/lib/core/network/api_page_parser.dart rims_frontend/test/core/pagination rims_frontend/test/core/network/api_page_parser_test.dart
git commit -m "feat: preserve API pagination metadata"
```

## Task 7: Carry Pagination Through Inventory Boundaries

**Files:**
- Modify: `rims_frontend/lib/features/inventory/data/datasources/inventory_remote_datasource.dart`
- Modify: `rims_frontend/lib/features/inventory/data/repositories/inventory_repository_impl.dart`
- Modify: `rims_frontend/lib/features/inventory/domain/repositories/inventory_repository.dart`
- Modify: `rims_frontend/test/features/inventory/inventory_remote_datasource_test.dart`
- Modify: `rims_frontend/test/features/inventory/inventory_view_model_test.dart`

- [ ] **Step 1: Change datasource tests to require server metadata**

Replace direct-list expectations for `listInventory`, `listInventoryAlerts`,
and `listNonStandardInventory` with `PageData<Model>` assertions. Include a
case with `total=45`, `page=2`, `pageSize=20` and verify the item converter still
parses the nested product.

- [ ] **Step 2: Change repository fakes and contract tests first**

Update test fakes to return:

```dart
Result<PageData<InventoryItem>> inventoryPage({
  required List<InventoryItem> items,
  required int total,
  int page = 1,
}) => Success(
      PageData<InventoryItem>(
        items: items,
        total: total,
        page: page,
        pageSize: 20,
      ),
    );
```

Do not modify production signatures until tests express the new contract.

- [ ] **Step 3: Run the inventory tests and confirm type failures**

```powershell
flutter test --no-pub test/features/inventory/inventory_remote_datasource_test.dart test/features/inventory/inventory_view_model_test.dart
```

Expected: FAIL because production methods still return `List<T>`.

- [ ] **Step 4: Update the inventory repository contract**

Change only paged methods:

```dart
Future<Result<PageData<InventoryItem>>> listInventory({
  String? keyword,
  int page = 1,
});
Future<Result<PageData<InventoryItem>>> listInventoryAlerts({int page = 1});
Future<Result<PageData<NonStandardInventoryItem>>> listNonStandardInventory({
  int page = 1,
});
```

Leave single-item and mutation methods unchanged.

- [ ] **Step 5: Parse and map complete pages**

Use `parseApiPage` in `InventoryRemoteDataSourceImpl`. In
`InventoryRepositoryImpl`, call `page.map((model) => model.toEntity())` so no
metadata is reconstructed or discarded.

- [ ] **Step 6: Run boundary tests**

```powershell
flutter test --no-pub test/features/inventory/inventory_remote_datasource_test.dart
```

Expected: datasource tests pass. Full analysis is intentionally deferred until
Task 8 adapts all inventory callers; do not commit the intermediate signature
change by itself.

## Task 8: Add Inventory Append, Retry, And End States

**Files:**
- Modify: `rims_frontend/lib/features/inventory/presentation/view_models/inventory_view_model.dart`
- Modify: `rims_frontend/lib/features/inventory/presentation/pages/inventory_page.dart`
- Modify: `rims_frontend/lib/features/inventory/presentation/widgets/inventory_product_tile.dart`
- Modify: `rims_frontend/lib/features/documents/presentation/view_models/documents_view_model.dart`
- Modify: `rims_frontend/lib/features/home/presentation/view_models/home_view_model.dart`
- Modify: `rims_frontend/test/features/inventory/inventory_view_model_test.dart`
- Create: `rims_frontend/test/features/inventory/inventory_page_pagination_test.dart`
- Modify: `rims_frontend/test/features/documents/documents_view_model_test.dart`
- Modify: `rims_frontend/test/features/home/home_view_model_test.dart`

- [ ] **Step 1: Add failing ViewModel paging tests**

Test these state transitions independently:

- initial `load()` replaces stale rows and sets `total`/`hasMore`;
- `loadMore()` requests `page + 1` and appends in server order;
- repeated IDs are replaced in place or ignored, never duplicated;
- a load-more failure preserves existing rows and exposes
  `loadMoreFailure` without replacing the full-page error;
- retrying load-more requests the same failed page;
- changing keyword or warehouse performs a page-1 reset;
- a concurrent second `loadMore()` is ignored;
- an empty final page ends pagination even if stale server metadata says more.

Use a queued fake repository and assert exact requested pages.

- [ ] **Step 2: Add failing page-widget tests**

Assert stable keys and states:

```dart
expect(find.byKey(const Key('inventory-load-more-button')), findsOneWidget);
await tester.tap(find.byKey(const Key('inventory-load-more-button')));
await tester.pump();
expect(viewModel.requestedPages, [1, 2]);

expect(find.byKey(const Key('inventory-load-more-retry')), findsOneWidget);
expect(find.byKey(const Key('inventory-page-end')), findsNothing);
```

Also verify controls do not appear for an empty first page or when page 1
failed.

- [ ] **Step 3: Run tests and confirm behavioral failures**

```powershell
flutter test --no-pub test/features/inventory/inventory_view_model_test.dart test/features/inventory/inventory_page_pagination_test.dart
```

Expected: FAIL because load-more state and controls do not exist.

- [ ] **Step 4: Implement explicit ViewModel state**

Add read-only state with this shape:

```dart
int _page = 0;
int _total = 0;
bool _isLoadingMore = false;
Failure? _loadMoreFailure;

int get loadedCount => _items.length;
int get total => _total;
bool get hasMore => _page > 0 && loadedCount < _total;
bool get isLoadingMore => _isLoadingMore;
Failure? get loadMoreFailure => _loadMoreFailure;
```

Use one private page-merge function keyed by inventory ID. Ignore responses
whose captured keyword or warehouse generation no longer matches current state.
Never infer all-warehouse inventory value from the currently loaded rows; show
`loadedCount/total` for list coverage and keep aggregate cards sourced from
report endpoints.

Adapt every inventory repository caller in `DocumentsViewModel` and
`HomeViewModel` in the same change. Product-selection search consumes
`page.items`; Home preview cards retain a bounded `page.items` list and expose
`page.total`. Update their repository fakes to compile against `PageData<T>` and
add assertions that Home counts come from `total`.

- [ ] **Step 5: Add accessible load-more UI**

Use a full-width text button with progress state, a retry control on incremental
failure, and a quiet end indicator after at least one row has loaded. Keep fixed
control height so loading text does not shift the list. Add semantic labels for
screen readers.

- [ ] **Step 6: Run inventory verification**

```powershell
flutter test --no-pub test/features/inventory
flutter test --no-pub test/features/documents/documents_view_model_test.dart test/features/home/home_view_model_test.dart
flutter analyze --no-pub
git diff --check
```

Expected: all inventory tests pass and analyzer reports no issues.

- [ ] **Step 7: Commit inventory pagination atomically**

```powershell
git add rims_frontend/lib/features/inventory rims_frontend/test/features/inventory
git commit -m "feat: paginate inventory results"
```

## Task 9: Paginate Documents And Transactions Independently

**Files:**
- Modify: `rims_frontend/lib/features/documents/data/datasources/documents_remote_datasource.dart`
- Modify: `rims_frontend/lib/features/documents/data/repositories/documents_repository_impl.dart`
- Modify: `rims_frontend/lib/features/documents/domain/repositories/documents_repository.dart`
- Modify: `rims_frontend/lib/features/documents/presentation/view_models/documents_view_model.dart`
- Modify: `rims_frontend/lib/features/documents/presentation/pages/documents_page.dart`
- Modify: `rims_frontend/lib/features/inventory/presentation/view_models/inventory_view_model.dart`
- Modify: `rims_frontend/lib/features/home/presentation/view_models/home_view_model.dart`
- Modify: `rims_frontend/test/features/documents/documents_remote_datasource_test.dart`
- Modify: `rims_frontend/test/features/documents/documents_view_model_test.dart`
- Create: `rims_frontend/test/features/documents/documents_page_pagination_test.dart`
- Modify: `rims_frontend/test/features/inventory/inventory_view_model_test.dart`
- Modify: `rims_frontend/test/features/home/home_view_model_test.dart`

- [ ] **Step 1: Write failing datasource contract tests**

Require `PageData<DocumentRecordModel>` and `PageData<TransactionRecordModel>`
from paged endpoints. Verify `docType`, status/date filters, `page`, and
`pageSize=10` remain in the request for page 2.

- [ ] **Step 2: Write failing dual-stream ViewModel tests**

Documents and transactions maintain separate `page`, `total`, loading, and
incremental-failure state. Prove:

- loading more documents does not reload or mutate transactions;
- loading more transactions does not change document filters;
- a filter change resets only the affected document query before the normal
  page refresh;
- creation/completion refreshes page 1 and does not concatenate obsolete rows;
- duplicate IDs are not displayed twice;
- return-source document lookup explicitly iterates all pages or uses a
  dedicated complete lookup, so valid sources beyond page 1 remain selectable.

- [ ] **Step 3: Run tests and observe contract failures**

```powershell
flutter test --no-pub test/features/documents/documents_remote_datasource_test.dart test/features/documents/documents_view_model_test.dart test/features/documents/documents_page_pagination_test.dart
```

Expected: FAIL because both streams currently return and replace lists.

- [ ] **Step 4: Carry page metadata through datasource and repository**

Change the two public list signatures to `Result<PageData<...>>`, parse the
backend page, and map models without losing metadata. Keep mutation and detail
signatures unchanged. Adapt `InventoryViewModel` and `HomeViewModel` in this
same step so every production caller consumes `page.items`/`page.total` and the
full workspace remains analyzable. Task 11 strengthens inventory-history
completeness after this signature migration.

- [ ] **Step 5: Implement separate append methods**

Expose:

```dart
Future<void> loadMoreDocuments();
Future<void> retryLoadMoreDocuments();
Future<void> loadMoreTransactions();
Future<void> retryLoadMoreTransactions();
```

Capture a query generation before every request and discard stale responses.
After a successful create or completion, call the existing reset load path so
server ordering and totals stay authoritative.

- [ ] **Step 6: Add controls to both tabs/sections**

Use stable keys:

```text
documents-load-more-button
documents-load-more-retry
documents-page-end
transactions-load-more-button
transactions-load-more-retry
transactions-page-end
```

Controls appear inside their owning list and do not change tab height while a
request is active.

- [ ] **Step 7: Verify and commit documents pagination**

```powershell
flutter test --no-pub test/features/documents
flutter test --no-pub test/features/inventory/inventory_view_model_test.dart test/features/home/home_view_model_test.dart
flutter analyze --no-pub
git diff --check
git add rims_frontend/lib/features/documents rims_frontend/test/features/documents
git commit -m "feat: paginate documents and transactions"
```

Expected: all document tests pass and analyzer reports no issues.

## Task 10: Paginate Administrative Collections

**Files:**
- Modify: `rims_frontend/lib/features/admin/data/datasources/admin_remote_datasource.dart`
- Modify: `rims_frontend/lib/features/admin/data/repositories/admin_repository_impl.dart`
- Modify: `rims_frontend/lib/features/admin/domain/repositories/admin_repository.dart`
- Modify: `rims_frontend/lib/features/admin/presentation/view_models/admin_users_view_model.dart`
- Modify: `rims_frontend/lib/features/admin/presentation/view_models/admin_products_view_model.dart`
- Modify: `rims_frontend/lib/features/admin/presentation/view_models/admin_warehouses_view_model.dart`
- Modify: `rims_frontend/lib/features/admin/presentation/widgets/admin_users_panel.dart`
- Modify: `rims_frontend/lib/features/admin/presentation/widgets/admin_products_panel.dart`
- Modify: `rims_frontend/lib/features/admin/presentation/widgets/admin_warehouses_panel.dart`
- Modify: `rims_frontend/test/features/admin/admin_remote_datasource_test.dart`
- Modify: `rims_frontend/test/features/admin/admin_users_view_model_test.dart`
- Modify: `rims_frontend/test/features/admin/admin_products_view_model_test.dart`
- Modify: `rims_frontend/test/features/admin/admin_warehouses_view_model_test.dart`
- Modify: `rims_frontend/test/features/admin/admin_users_panel_test.dart`
- Modify: `rims_frontend/test/features/admin/admin_products_panel_test.dart`
- Modify: `rims_frontend/test/features/admin/admin_warehouses_panel_test.dart`
- Modify: `rims_frontend/test/features/admin/admin_roles_panel_test.dart`
- Modify: `rims_frontend/test/features/admin/admin_roles_view_model_test.dart`
- Modify: `rims_frontend/test/features/profile/profile_security_view_model_test.dart`
- Modify: `rims_frontend/test/features/profile/profile_view_model_test.dart`

- [ ] **Step 1: Write failing data-boundary tests**

Require page metadata for `listUsers`, `listProducts`, and `listWarehouses`.
Keep `listRoles`, `listPermissions`, and the users bound to one selected
warehouse as unpaged only if their backend endpoints are documented as complete
lists; otherwise page them in the same change.

- [ ] **Step 2: Write reusable paging-state behavior tests**

For all three ViewModels, assert reset, append, dedupe, final page, stale query,
incremental failure, retry, and mutation refresh. Products additionally retain
keyword/status filters. Users retain role/status filters. Warehouses retain
keyword/status filters.

- [ ] **Step 3: Run tests and confirm failures**

```powershell
flutter test --no-pub test/features/admin
```

Expected: FAIL because admin list contracts discard server totals.

- [ ] **Step 4: Change only the three paged repository methods**

Use `PageData<AdminUser>`, `PageData<AdminProduct>`, and
`PageData<AdminWarehouse>`. Map pages in the repository implementation and keep
role/permission mutations unchanged.

- [ ] **Step 5: Implement consistent ViewModel paging semantics**

Use the same public names across all three ViewModels:

```dart
int get total;
bool get hasMore;
bool get isLoadingMore;
Failure? get loadMoreFailure;
Future<void> loadMore();
Future<void> retryLoadMore();
```

Do not extract a shared generic ViewModel unless the three implementations show
meaningful duplication after tests pass. A small private list-merge helper is
acceptable; feature-specific mutation state remains local.

- [ ] **Step 6: Add stable panel controls**

Keys are `admin-users-load-more`, `admin-products-load-more`, and
`admin-warehouses-load-more`, with `-retry` and `-end` suffixes for the other
states. Keep create/edit controls available while a load-more request runs.

- [ ] **Step 7: Run admin verification and commit**

```powershell
flutter test --no-pub test/features/admin
flutter analyze --no-pub
git diff --check
git add rims_frontend/lib/features/admin rims_frontend/test/features/admin
git commit -m "feat: paginate administration lists"
```

Expected: all admin tests pass and analyzer reports no issues.

## Task 11: Close Secondary First-Page Data Gaps

**Files:**
- Modify: `rims_frontend/lib/features/home/presentation/view_models/home_view_model.dart`
- Modify: `rims_frontend/test/features/home/home_view_model_test.dart`
- Modify: `rims_frontend/lib/features/inventory/presentation/view_models/inventory_view_model.dart`
- Modify: `rims_frontend/test/features/inventory/inventory_view_model_test.dart`
- Modify: `rims_frontend/lib/features/documents/presentation/view_models/documents_view_model.dart`
- Modify: `rims_frontend/test/features/documents/documents_view_model_test.dart`
- Modify: `rims_frontend/lib/features/reports/presentation/view_models/reports_view_model.dart`
- Modify: `rims_frontend/test/features/reports/reports_view_model_test.dart`
- Modify: endpoint-specific files found by the audit only when the endpoint is paged

- [ ] **Step 1: Inventory every list response against backend contracts**

Run:

```powershell
rg -n "Future<Result<List<|parseList|\['list'\]|pageSize|page'" rims_frontend/lib
rg -n "PageResult|pageSize|page_size|Paginate|Offset\(" internal
```

Run the second command from `E:\My Work\RIMS\rims-goProgect`. Record every
frontend list endpoint in the M9 execution record as one of:

- paged and migrated to `PageData<T>`;
- deliberately bounded preview, with the server `total` shown separately;
- documented unpaged reference data;
- detail/mutation endpoint and not applicable.

No paged endpoint may remain represented as a bare repository `List<T>`.

- [ ] **Step 2: Add failing preview and selection tests**

At minimum, prove:

- Home inventory alert counts use page `total`, while the card renders a
  bounded preview list;
- Home recent-document count/summary does not claim the preview is complete;
- Home non-standard count uses page `total`;
- document non-standard conversion selection can locate an item beyond page 1;
- return-source selection can locate a valid document beyond page 1;
- report ranking endpoints are either server-bounded rankings or page-aware,
  never silently truncated client aggregates.
- inventory detail history can reach all matching transactions or requests a
  product-filtered paged history instead of filtering only page 1 locally.

- [ ] **Step 3: Run targeted tests and confirm old assumptions fail**

```powershell
flutter test --no-pub test/features/home/home_view_model_test.dart test/features/inventory/inventory_view_model_test.dart test/features/documents/documents_view_model_test.dart test/features/reports/reports_view_model_test.dart
```

Expected: at least the page-total and beyond-page selection assertions fail
before production changes.

- [ ] **Step 4: Implement bounded previews and complete selectors**

For dashboards, retain only the requested preview items and expose the server
total. For selectors that must be exhaustive, fetch successive pages until
`hasNextPage` is false, provide server-side search, or add a dedicated paged
picker. Do not request an arbitrarily huge page size.

- [ ] **Step 5: Run the complete list-contract audit again**

```powershell
rg -n "Future<Result<List<" rims_frontend/lib/features
flutter test --no-pub test/features/home test/features/inventory test/features/documents test/features/reports
flutter analyze --no-pub
```

Expected: remaining bare lists are only explicitly unpaged reference/detail
collections, and all targeted tests pass.

- [ ] **Step 6: Commit secondary pagination fixes**

```powershell
git add rims_frontend/lib rims_frontend/test
git commit -m "fix: remove secondary first-page data gaps"
```

## Task 12: Add Stable E2E Semantics And Test Infrastructure

**Files:**
- Modify: `rims_frontend/pubspec.yaml`
- Modify: `rims_frontend/pubspec.lock`
- Modify: `rims_frontend/lib/core/widgets/rims_bottom_navigation.dart`
- Modify: `rims_frontend/lib/features/inventory/presentation/widgets/inventory_product_tile.dart`
- Modify: `rims_frontend/lib/features/documents/presentation/pages/documents_page.dart`
- Modify: `rims_frontend/lib/features/profile/presentation/pages/profile_page.dart`
- Create: `rims_frontend/integration_test/support/rims_e2e_config.dart`
- Create: `rims_frontend/integration_test/support/rims_e2e_driver.dart`
- Create: `rims_frontend/integration_test/app_e2e_test.dart`
- Modify: affected widget tests under `rims_frontend/test/`

- [ ] **Step 1: Add the Flutter SDK integration-test dependency**

Add under `dev_dependencies`:

```yaml
integration_test:
  sdk: flutter
```

Then run from `rims_frontend`:

```powershell
flutter pub get --offline
```

Expected: dependency resolution succeeds without network access and updates the
lockfile only as required.

- [ ] **Step 2: Add failing widget assertions for navigation semantics**

Require these stable keys:

```text
bottom-nav-home
bottom-nav-inventory
bottom-nav-documents
bottom-nav-reports
bottom-nav-profile
inventory-item-{inventoryId}
inventory-item-code-{inventoryId}
document-action-inbound
document-action-sales
document-list-item-{documentId}
profile-admin-users
profile-admin-products
profile-admin-warehouses
```

Existing keys such as `login-username-field`, `login-password-field`,
`profile-warehouse-selector`, `profile-logout-button`, document form controls,
and document completion actions remain stable.

- [ ] **Step 3: Run affected widget tests and confirm missing keys fail**

```powershell
flutter test --no-pub test/core/widgets test/features/inventory test/features/documents test/features/profile
```

If `test/core/widgets` does not yet exist, create the focused bottom-navigation
test there before running. Expected: FAIL on the newly required keys.

- [ ] **Step 4: Add keys and semantics without changing visible copy**

Derive bottom-navigation keys from the `AppTab` enum rather than translated
labels. Add `Semantics(button: true, selected: ...)` to navigation targets and
descriptive labels to paging/action controls. Do not expose credentials, fixture
names, test instructions, or test-only buttons in the visible app.

- [ ] **Step 5: Implement E2E configuration**

Use compile-time values with local defaults:

```dart
abstract final class RimsE2eConfig {
  static const adminUsername = String.fromEnvironment(
    'RIMS_E2E_ADMIN_USERNAME',
    defaultValue: 'admin',
  );
  static const adminPassword = String.fromEnvironment(
    'RIMS_E2E_ADMIN_PASSWORD',
    defaultValue: 'admin123',
  );
  static const operatorUsername = String.fromEnvironment(
    'RIMS_E2E_OPERATOR_USERNAME',
    defaultValue: 'm9_operator',
  );
  static const operatorPassword = String.fromEnvironment(
    'RIMS_E2E_OPERATOR_PASSWORD',
    defaultValue: 'admin123',
  );
  static const fixtureProductCode = 'M9-PAGE-0001';
  static const secondWarehouseName = 'M9 验收二号仓';
}
```

The committed config contains only local development credentials. Production
credentials are never accepted through source changes; later environments use
secret injection.

- [ ] **Step 6: Add reusable integration helpers**

`rims_e2e_driver.dart` provides bounded helpers for `waitForKey`, `tapAndSettle`,
`enterText`, `scrollUntilVisible`, `expectText`, and screenshot-on-failure.
Every wait has a timeout and reports the last visible route/key state. Avoid
unbounded `pumpAndSettle()` around progress indicators.

- [ ] **Step 7: Add a compiling skeleton suite**

Initialize the real binding and construct the real application:

```dart
final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

testWidgets('local acceptance journey', (tester) async {
  await tester.pumpWidget(const MainApp());
  await waitForKey(tester, const Key('login-username-field'));
});
```

Do not add a mocked repository or `DioAdapter`; this suite exists specifically
to cross the real HTTP boundary.

- [ ] **Step 8: Verify infrastructure and commit**

```powershell
flutter test --no-pub test/core/widgets test/features/inventory test/features/documents test/features/profile
flutter analyze --no-pub
git diff --check
git add rims_frontend/pubspec.yaml rims_frontend/pubspec.lock rims_frontend/lib rims_frontend/test rims_frontend/integration_test
git commit -m "test: add stable app E2E surface"
```

Expected: widget tests pass and the integration suite compiles during analyzer.

## Task 13: Implement The Real-Backend Acceptance Journey

**Files:**
- Modify: `rims_frontend/integration_test/app_e2e_test.dart`
- Modify: `rims_frontend/integration_test/support/rims_e2e_driver.dart`
- Modify: `rims_frontend/lib/main.dart` only if reusable app startup is required
- Modify: `rims_frontend/test/` only for any app-startup seam introduced

- [ ] **Step 1: Start a clean managed backend and fixtures**

From the frontend workspace:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/rims_local.ps1 -Command up -Target none -IncludeDependencies
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/rims_local.ps1 -Command reset -Target none
```

Expected: API healthy and fixture counts match Task 5.

- [ ] **Step 2: Write the failing admin/session scenario**

The first segment must:

1. normalize precondition by logging out if a prior local session is present;
2. log in as `admin` through the visible form;
3. assert the Home shell and current warehouse;
4. dispose the whole `MainApp`, pump a fresh `MainApp` with a different key,
   and assert the session restores from secure storage without showing login;
5. open Inventory, load until `M9-PAGE-0001` is visible, and prove more than 20
   distinct fixture rows were rendered;
6. open Profile, switch to `M9 验收二号仓`, return to Inventory, and assert the
   fixture product quantity changes to the seeded warehouse-specific value.

Re-pumping a fresh `MainApp` is the minimum acceptable restart seam: it must
dispose and recreate session controller, router, API client, repositories, and
event bus while retaining the platform secure-storage implementation.

- [ ] **Step 3: Run the scenario and confirm the first unmet behavior**

From `rims_frontend`:

```powershell
flutter test --no-pub integration_test/app_e2e_test.dart -d chrome --dart-define=API_BASE_URL=http://localhost:8080/api/v1
```

Expected before completing the test: FAIL at the first missing paging,
restart, or warehouse assertion. Treat backend 4xx/5xx as test failures with
request IDs in diagnostics.

- [ ] **Step 4: Add the stock-impact segment**

Still as admin and on the second warehouse:

1. read and store `M9-PAGE-0001` quantity;
2. create an inbound document for quantity `3` with remark
   `M9-E2E:{runId}:inbound`;
3. complete it and verify quantity is `before + 3`;
4. find the matching transaction beyond/within paged transaction results;
5. create and complete a sales/outbound document for quantity `2` with remark
   `M9-E2E:{runId}:sales`;
6. verify quantity is now `before + 1` and both completed documents remain
   discoverable after a page reset.

Use unique run IDs for diagnostics, but fixture `reset` must remove these
tagged E2E documents before the next run.

- [ ] **Step 5: Add the ordinary-user boundary segment**

Log out and log in as `m9_operator`. Prove through the UI that:

- both assigned warehouses are available;
- inventory and ordinary document workflows remain reachable;
- cost/financial values forbidden to the ordinary role are absent or masked;
- user/product/warehouse/role management controls are absent;
- invoking any still-reachable privileged action yields a handled authorization
  state, not a crash or silent success.

Use an API request only to corroborate a UI denial when there is no legitimate
UI path; send the operator token and assert HTTP 403 plus the backend request ID.

- [ ] **Step 6: End with logout and clean state**

Log out through `profile-logout-button`, assert the login form returns, and
rebuild `MainApp` once more to prove the session does not restore after logout.
The test writes its segment durations and created document numbers to the
integration binding report data.

- [ ] **Step 7: Run the complete Web journey twice**

```powershell
flutter test --no-pub integration_test/app_e2e_test.dart -d chrome --dart-define=API_BASE_URL=http://localhost:8080/api/v1
powershell -NoProfile -ExecutionPolicy Bypass -File ..\scripts\rims_local.ps1 -Command reset -Target none
flutter test --no-pub integration_test/app_e2e_test.dart -d chrome --dart-define=API_BASE_URL=http://localhost:8080/api/v1
```

Run these from `rims_frontend`; the reset path is relative to that directory.
Expected: both runs PASS and produce equivalent business assertions.

- [ ] **Step 8: Commit the acceptance journey**

```powershell
git add rims_frontend/integration_test rims_frontend/lib/main.dart rims_frontend/test
git commit -m "test: cover real backend acceptance journey"
```

## Task 14: Aggregate Deterministic Web Smoke

**Files:**
- Modify: `scripts/rims_local.ps1`
- Modify: `scripts/lib/rims_local_common.ps1`
- Modify: `scripts/test_rims_local.ps1`
- Create: `scripts/rims_web_e2e.ps1`
- Create: `scripts/test_rims_web_e2e.ps1`
- Modify: `scripts/rims_smoke.ps1` only to expose machine-readable step results
- Modify: `scripts/test_rims_smoke.ps1`

- [ ] **Step 1: Add failing smoke-plan tests**

`test_rims_web_e2e.ps1` runs in `-ListSteps` mode and asserts this order:

```text
doctor-web
up-backend
reset-fixtures
frontend-smoke
backend-go-test
backend-build
backend-m8-smoke
web-integration-test
runtime-status
write-report
```

The test also proves that a failing child exit code stops dependent E2E steps,
still writes a report, and leaves services running only when `-KeepRunning` was
explicitly passed.

- [ ] **Step 2: Run script tests and confirm failure**

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/test_rims_smoke.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/test_rims_web_e2e.ps1
```

Expected: existing smoke self-test passes; new Web E2E test fails because the
wrapper does not exist.

- [ ] **Step 3: Expose structured frontend smoke results**

Preserve current `scripts/rims_smoke.ps1` behavior. Add `-Output Json` or a
report path so the orchestrator can collect step names, commands, durations,
exit codes, and tool versions without parsing display text. Keep
`flutter pub get --offline`, `flutter analyze --no-pub`, `flutter test --no-pub`,
demo-residual scan, and `git diff --check` as existing gates.

- [ ] **Step 4: Implement the Web wrapper**

`rims_web_e2e.ps1` calls the lifecycle script rather than independently starting
servers. Backend commands run through WSL from the backend repository:

```bash
~/local/go/bin/go test ./...
~/local/go/bin/go build ./cmd/server
bash scripts/m8_backend_smoke.sh
```

Then run the Flutter integration command from Task 13. Always restore the
fixture baseline after the E2E journey. On failure, copy the tails of managed
logs and the integration failure details into the JSON report.

- [ ] **Step 5: Wire `rims_local smoke -Target web`**

The lifecycle command delegates to `rims_web_e2e.ps1`, writes
`.runtime/rims-local/reports/latest-smoke.json` atomically, and returns the first
nonzero required-step exit code. A passing report contains workspace commits,
tool versions, target, fixture counts, all step durations, E2E report data, and
`p0Count`/`p1Count`.

- [ ] **Step 6: Verify Web smoke end to end**

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/test_rims_local.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/test_rims_smoke.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/test_rims_web_e2e.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/rims_local.ps1 -Command smoke -Target web -IncludeDependencies
Get-Content .runtime/rims-local/reports/latest-smoke.json | ConvertFrom-Json | Format-List
```

Expected: all script tests and smoke steps pass; the report is valid JSON.

- [ ] **Step 7: Commit Web smoke aggregation**

```powershell
git add scripts
git commit -m "test: aggregate managed Web acceptance smoke"
```

## Task 15: Prove The Android Emulator Journey

**Files:**
- Create: `scripts/rims_android_smoke.ps1`
- Create: `scripts/test_rims_android_smoke.ps1`
- Modify: `scripts/rims_local.ps1`
- Modify: `scripts/lib/rims_local_common.ps1`
- Modify: `rims_frontend/integration_test/support/rims_e2e_driver.dart`
- Modify: `rims_frontend/integration_test/app_e2e_test.dart`

- [ ] **Step 1: Add failing Android command tests**

In list/dry-run mode, assert:

- the device is explicit, never `-d all`;
- API URL is built as `http://10.0.2.2:$BackendPort/api/v1` for an emulator;
- backend readiness is checked from Windows and from the emulator;
- screenshots and filtered `adb logcat` are captured after failure;
- an emulator already online is not stopped by cleanup;
- a controller-started emulator is stopped only when PID/start time still match.

- [ ] **Step 2: Run the test and confirm failure**

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/test_rims_android_smoke.ps1
```

Expected: FAIL because the Android wrapper does not exist.

- [ ] **Step 3: Implement Android preparation**

Use `RIMS_ANDROID_DEVICE` or `-AndroidDevice`; fail with available AVD/device
names when neither is configured. Wait for boot completion, unlock the screen,
verify:

```powershell
adb -s $env:RIMS_ANDROID_DEVICE shell curl -fsS http://10.0.2.2:8080/healthz
```

If the image lacks `curl`, use `adb shell toybox wget` or a small app-side
health request; do not silently skip emulator-to-host connectivity.

- [ ] **Step 4: Run the same business suite on Android**

From `rims_frontend`:

```powershell
flutter test --no-pub integration_test/app_e2e_test.dart -d $env:RIMS_ANDROID_DEVICE --dart-define=API_BASE_URL=http://10.0.2.2:8080/api/v1
```

No Android-only weakened assertions are allowed. Device-specific helper code may
handle keyboard dismissal, scroll physics, and viewport differences while
retaining the same business checks.

- [ ] **Step 5: Wire and run Android smoke**

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/test_rims_android_smoke.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/rims_local.ps1 -Command smoke -Target android -IncludeDependencies -AndroidDevice $env:RIMS_ANDROID_DEVICE
```

Expected: script test and full Android acceptance journey pass. On failure,
report paths point to screenshot, logcat, backend logs, and Flutter output.

- [ ] **Step 6: Commit Android acceptance support**

```powershell
git add scripts rims_frontend/integration_test
git commit -m "test: verify Android emulator acceptance flow"
```

## Task 16: Record Baselines, Documentation, And M9 Exit Evidence

**Files:**
- Create: `scripts/rims_m9_baseline.ps1`
- Create: `scripts/test_rims_m9_baseline.ps1`
- Modify: `README.md`
- Modify: `rims_frontend/README.md` if it contains app-run instructions
- Create: `docs/superpowers/plans/2026-07-10-rims-m9-execution-record.md`
- Modify: `docs/superpowers/plans/2026-07-10-rims-app-long-term-completion-master-plan.md`

- [ ] **Step 1: Add a failing baseline-script test**

Dry-run/sample-data mode must calculate min, median, p95, max, success count,
failure count, and threshold result for named operations. Verify percentile
calculation with a deterministic 20-sample input.

- [ ] **Step 2: Implement the local baseline collector**

Against a managed seeded environment, record:

- backend cold-start readiness duration;
- Web cold-start readiness duration;
- 20 `/healthz` requests;
- 20 authenticated inventory page-1 requests;
- inventory page 1 through final page traversal duration;
- Web E2E total and segment durations;
- Android E2E total and segment durations;
- peak backend working set when available.

This is a regression baseline, not M15 capacity certification. Mark health p95
above 1 second, inventory-page p95 above 2 seconds, or any request failure as an
M9 defect requiring investigation. Preserve raw samples in the smoke report.

- [ ] **Step 3: Verify baseline calculation and collect fresh data**

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/test_rims_m9_baseline.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/rims_m9_baseline.ps1 -OutputPath .runtime/rims-local/reports/m9-baseline.json
Get-Content .runtime/rims-local/reports/m9-baseline.json | ConvertFrom-Json | Format-List
```

Expected: calculation test passes, all requests succeed, and any threshold
breach is either fixed or logged with reproduction and severity.

- [ ] **Step 4: Document the autonomous local workflow**

Update README commands for:

```powershell
scripts/rims_local.ps1 -Command doctor -Target web
scripts/rims_local.ps1 -Command up -Target web -IncludeDependencies
scripts/rims_local.ps1 -Command status
scripts/rims_local.ps1 -Command logs
scripts/rims_local.ps1 -Command reset
scripts/rims_local.ps1 -Command smoke -Target web
scripts/rims_local.ps1 -Command smoke -Target android -AndroidDevice $env:RIMS_ANDROID_DEVICE
scripts/rims_local.ps1 -Command down
```

Explain managed-process ownership, `.runtime` logs/reports, WSL prerequisites,
environment overrides, default local identities, port conflict behavior, and
the prohibition on fixture/reset use outside local dev/test.

- [ ] **Step 5: Create the execution record from actual output**

`2026-07-10-rims-m9-execution-record.md` must contain:

- frontend and backend commits/branches;
- environment and tool versions;
- fixture counts;
- each required command with timestamp, duration, exit code, and report path;
- Web and Android scenario outcomes;
- pagination endpoint audit table from Task 11;
- baseline summary;
- P0/P1/P2/P3 defect table with status and reproducer;
- deviations from this plan and rationale;
- explicit M9 pass/fail decision.

Do not prefill a success claim. Copy values from generated JSON reports and
retain concise failure evidence for any rerun.

- [ ] **Step 6: Run the final fresh verification sequence**

From `E:\My Work\rims-frontend`:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/test_rims_local.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/test_rims_smoke.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/test_rims_web_e2e.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/test_rims_android_smoke.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/test_rims_m9_baseline.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/rims_local.ps1 -Command smoke -Target web -IncludeDependencies
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/rims_local.ps1 -Command smoke -Target android -IncludeDependencies -AndroidDevice $env:RIMS_ANDROID_DEVICE
Push-Location rims_frontend
flutter analyze --no-pub
flutter test --no-pub
Pop-Location
git diff --check
git status --short
```

From `E:\My Work\RIMS\rims-goProgect`:

```powershell
$backendWsl = (wsl.exe -e wslpath -a 'E:\My Work\RIMS\rims-goProgect').Trim()
wsl.exe -e bash -lc "cd '$backendWsl' && ~/local/go/bin/go test ./... && ~/local/go/bin/go build ./cmd/server && RIMS_ALLOW_DEV_SEED=1 bash scripts/test_m9_dev_seed.sh"
git diff --check
git status --short
```

Expected: every required test and smoke exits `0`; P0/P1 are zero; only intended
changes are present.

- [ ] **Step 7: Update the master milestone status**

Mark M9 complete in the master plan only after Step 6 passes and link the actual
execution record. Add the exact entry criteria and current interfaces that M10
must inherit; do not write the detailed M10 plan until this point.

- [ ] **Step 8: Commit records in each repository**

Backend verification-driven fixes are committed immediately with their owning
task or defect. At finalization, require a clean backend worktree:

```powershell
git status --short
```

Frontend/program repository:

```powershell
git add README.md rims_frontend/README.md scripts docs/superpowers/plans
git commit -m "docs: record M9 autonomous acceptance"
```

## 3. Defect Policy During Execution

Classify every newly observed defect in the execution record:

| Severity | M9 meaning | Required action |
| --- | --- | --- |
| P0 | data loss/corruption, security bypass, environment script can affect non-local data, or destructive process ownership bug | stop the affected flow, fix, and rerun all impacted gates |
| P1 | acceptance flow blocked, wrong stock result, permission leakage, unrecoverable lifecycle failure, or a required paged dataset is inaccessible | fix before M9 exit and add regression coverage |
| P2 | recoverable workflow or usability defect with a practical workaround | fix in M9 when scoped; otherwise assign an explicit later milestone |
| P3 | cosmetic or low-impact polish issue | record with evidence and target milestone |

Each row includes ID, severity, summary, frontend/backend commit, environment,
reproduction, expected/actual result, owner, status, regression test, and target
milestone. Reclassification requires rationale.

## 4. Implementation Guardrails

- Keep Flutter feature-first MVVM boundaries; pages do not parse pagination
  payloads or call Dio.
- Use `PageData<T>` only for real paged contracts. Do not wrap single resources
  or finite role/permission reference lists without backend evidence.
- A page-1 refresh is authoritative and replaces accumulated rows.
- A load-more failure never destroys already loaded content.
- Warehouse/filter generations invalidate stale in-flight page responses.
- Local seed SQL is not a production migration and cannot run without an
  explicit local environment guard.
- The lifecycle controller never kills by port and never adopts an unmanaged
  process merely because its health endpoint responds.
- JSON output remains machine-readable; human progress is sent separately.
- Logs, tokens, passwords, and `.env` contents are never committed or embedded
  in reports. Local default passwords may be named in developer documentation,
  but authentication headers and tokens are redacted.
- The same E2E business assertions run on Web and Android; platform helpers may
  differ only for interaction mechanics.
- Do not push either repository unless the user explicitly requests it.

## 5. M9 Handoff To M10

After M9 passes, generate the M10 scanner-and-attachments implementation plan
from the then-current codebase. Its entry package must include:

- the M9 execution record and latest Web/Android smoke report;
- lifecycle commands that can start the required local environment unaided;
- the final `PageData<T>` and ViewModel pagination contracts;
- the deterministic products, warehouses, identities, and permissions available
  to scanner/file E2E tests;
- all open P2/P3 items assigned to M10;
- current Android emulator/API configuration and observed timing baseline.

M10 must preserve M9 smoke as a regression gate before adding scanner,
attachment, compression, upload, and permission behavior.
