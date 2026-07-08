# RIMS M8 Integration Session 2 Notes

**Date:** 2026-07-08

**Scope:** Regression integration after backend optimization. This run re-verifies the M8 internal acceptance integration scope against the current backend service and current frontend worktree.

## Runtime Baseline

- Frontend path: `E:\My Work\rims-frontend`
- Backend path: `E:\My Work\RIMS\rims-goProgect`
- Backend API: `http://localhost:8080/api/v1`
- Backend health:
  - `GET http://localhost:8080/healthz`
  - Result: `200`, `{"status":"ok"}`
- Backend process after restart:
  - WSL `go run ./cmd/server`
  - Listening on `*:8080`

## Backend Verification

Run from `E:\My Work\rims-frontend` against backend path `E:\My Work\RIMS\rims-goProgect`.

### Code Gates

```powershell
wsl -e bash -lc 'cd "/mnt/e/My Work/RIMS/rims-goProgect" && ~/local/go/bin/go test ./internal/modules/user ./internal/modules/warehouse ./internal/modules/product'
```

Result: pass.

```powershell
wsl -e bash -lc 'cd "/mnt/e/My Work/RIMS/rims-goProgect" && ~/local/go/bin/go test ./...'
```

Result: pass.

```powershell
wsl -e bash -lc 'cd "/mnt/e/My Work/RIMS/rims-goProgect" && ~/local/go/bin/go build ./...'
```

Result: pass.

```powershell
wsl -e bash -lc 'cd "/mnt/e/My Work/RIMS/rims-goProgect" && ~/local/go/bin/go run ./cmd/migrate up'
```

Result: pass.

### Backend API Smoke

Initial run:

```powershell
wsl -e bash -lc 'cd "/mnt/e/My Work/RIMS/rims-goProgect" && BASE_URL=http://localhost:8080 ./scripts/m8_backend_smoke.sh'
```

Initial result: failed on current warehouse restore.

Evidence:

```text
FAIL: current warehouse visible after restore
selected warehouse was not marked isCurrent/isDefault
```

Root cause: port `8080` was served by an older WSL `go run ./cmd/server` process. Current code has `UserWarehouseResponse.isCurrent`, but the running response omitted the `isCurrent` field. The service was restarted from `E:\My Work\RIMS\rims-goProgect`.

Final run:

```powershell
wsl -e bash -lc 'cd "/mnt/e/My Work/RIMS/rims-goProgect" && BASE_URL=http://localhost:8080 ./scripts/m8_backend_smoke.sh'
```

Final result:

```text
All M8 backend smoke probes passed.
```

Covered contracts:

- Admin can list roles.
- Operator cannot list roles.
- Operator cannot list permissions.
- Current warehouse switch is visible after session restore.
- Inventory keyword search has matching `total` and returned rows.
- Warehouse delete with active binding returns invalid-state conflict.

## Phase A-F Lightweight API Probe

Executed an ad-hoc no-file API probe against `http://localhost:8080`.

Result:

```text
Phase A-F lightweight API probes passed. warehouse=1 inventory=46 product=50 before=15 after=15 inbound=144 sales=145 productCode=rpt_inv_1776407517283
```

Coverage:

- Phase A:
  - Health endpoint returns OK.
  - Wrong-password admin login returns authentication failure.
  - Admin login succeeds.
  - `/users/me` and `/users/me/warehouses` restore session and warehouse state.
- Phase B:
  - Operator login succeeds.
  - Operator `GET /roles` returns `403`.
  - Operator `GET /permissions` returns `403`.
- Phase C:
  - Inventory list returns real backend inventory.
  - Inventory detail returns the selected item.
- Phase D:
  - Created inbound document `144`.
  - Completed inbound document and verified inventory quantity increased `15 -> 16`.
  - Created sales document `145`.
  - Completed sales document and verified inventory quantity returned `16 -> 15`.
  - Transactions endpoint returns data.
- Phase E:
  - Admin sales stats, sales trend with `bucket=day`, and inventory overview return success.
  - Operator sales stats return success without financial fields.
- Phase F:
  - Admin users/products/warehouses/roles/permissions list endpoints return success.

## Frontend Verification

Command:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\rims_smoke.ps1
```

Result:

```text
RIMS smoke checks passed.
```

Included gates:

- `flutter pub get --offline`: pass.
- `flutter analyze --no-pub`: pass with `No issues found`.
- `flutter test --no-pub`: pass, `350` tests.
- Demo residual scan: pass.
- `git diff --check`: pass.

## Current Defect Status

- New P0 defects found in Session 2: `0`.
- New P1 defects found in Session 2: `0`.
- Backend API smoke final status: pass.
- Phase A-F lightweight API probe status: pass.
- Frontend smoke final status: pass.

## Acceptance Status

M8 frontend/backend integration remains pass after backend optimization.

This Session 2 run does not replace the full Session 1 manual/API phase evidence. It verifies that the current optimized backend and current frontend still satisfy the internal acceptance gates and the repaired backend contracts.
