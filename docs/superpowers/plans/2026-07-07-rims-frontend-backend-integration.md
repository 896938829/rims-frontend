# RIMS Frontend/Backend Integration Plan

> **For agentic workers:** This is an M8 integration execution plan for the internally usable APP target. Do not expand scope into app-store release, production monitoring, offline sync, push notifications, or full admin-console replacement.

**Goal:** Prove the Flutter frontend works against the real RIMS backend for the internal acceptance business flow.

**Architecture:** Keep the Flutter app on feature-first MVVM. Frontend issues should be fixed in Page/ViewModel/Repository/DataSource boundaries as appropriate; backend contract issues should be recorded with endpoint, request, response, role, warehouse, and exact reproduction steps.

**Tech Stack:** Flutter Web or desktop, RIMS backend at `http://localhost:8080/api/v1`, Dio API client, Provider/GoRouter, local smoke script, backend seed data.

---

## 1. Why Integration Is Required

Current frontend automation proves local logic is healthy:

- `scripts/rims_smoke.ps1` passes.
- `flutter analyze --no-pub` has no issues.
- Full `flutter test --no-pub` passes.
- Demo residual scan over business code passes.

This is not enough for final internal acceptance because the remaining risks depend on real backend behavior:

- Real response field names, envelopes, status codes, and error payloads.
- Real token/session expiration behavior.
- Real role and warehouse permission boundaries.
- Real inventory changes after document lifecycle actions.
- Real reports after business data changes.
- Real admin-created users, products, warehouses, bindings, and permissions.

Therefore, frontend/backend integration is mandatory before calling the APP internally usable.

## 2. Preconditions

### Backend

- Backend runs locally or in a stable test environment.
- API base URL is confirmed, default target: `http://localhost:8080/api/v1`.
- Database contains, or can create, these records:
  - one admin account
  - one normal operator account
  - at least two warehouses for admin switching
  - one warehouse-bound normal user
  - at least three products: normal stock, low stock, insufficient stock
  - at least one non-standard inventory record if conversion flow is supported

### Frontend

- Flutter dependencies are available offline or via current pub cache.
- Frontend starts with backend URL configured:

```powershell
cd rims_frontend
flutter run -d chrome --dart-define=API_BASE_URL=http://localhost:8080/api/v1
```

If Chrome is unavailable, use the project-supported web/desktop target that can reach the backend.

### Baseline

Run before manual integration:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\rims_smoke.ps1
```

Expected: smoke checks passed.

## 3. Roles And Test Accounts

Record actual accounts before starting:

| Role | Username | Password Source | Expected Access |
| --- | --- | --- | --- |
| Admin | backend-provided | seed/admin-created | all app tabs, management panels, admin document actions |
| Operator | backend-provided | admin-created | business tabs only, no management panels, no transfer/conversion actions |

Do not add frontend demo credentials. If no account exists, create it through backend seed data or admin management flow.

## 4. Integration Execution Order

### Phase A: Environment And Auth

1. Open backend health endpoint or API root.
2. Start frontend with the confirmed `API_BASE_URL`.
3. Log in with wrong password.
4. Confirm backend error is shown and no session is created.
5. Log in with admin account.
6. Confirm shell opens with current user, role, current warehouse, and available warehouses.
7. Refresh browser/app.
8. Confirm session restores through `/users/me` and `/users/me/warehouses`.
9. Log out.
10. Confirm protected pages return to login.

Pass criteria:

- no demo login path
- no fake user/warehouse fallback
- token and user restore work
- failed auth never enters shell

### Phase B: Warehouse And Permissions

1. As admin, switch from warehouse A to warehouse B.
2. Confirm frontend requests use the new warehouse context.
3. Confirm home, inventory, documents, and reports refresh.
4. As operator, confirm warehouse switcher is hidden or constrained.
5. As operator, confirm management panels are not visible.
6. As operator, confirm transfer and conversion actions are not visible.

Pass criteria:

- admin can switch allowed warehouses
- operator cannot access admin-only entry points
- switch failure keeps old warehouse and shows error

### Phase C: Inventory

1. Search by product keyword.
2. Search by SKU or barcode-equivalent input if backend supports it.
3. Open inventory detail.
4. Confirm detail quantity, status, warning threshold, and warehouse match backend.
5. Load inventory transactions for the selected product.
6. As admin, update warning threshold or inventory status.
7. As operator, confirm inventory settings are not visible or cannot submit.

Pass criteria:

- no fixed inventory cards or fake product data
- detail and list agree
- transaction area failure does not clear inventory list
- admin-only settings are enforced

### Phase D: Documents And Inventory Effects

Run in this order so each later check can observe previous data:

1. Create purchase inbound document.
2. Complete purchase inbound document.
3. Confirm stock increases and transaction appears.
4. Create sales outbound document with available stock.
5. Complete sales outbound document.
6. Confirm stock decreases and transaction appears.
7. Create sales outbound document with insufficient stock.
8. Confirm backend error is shown and document state is not falsely advanced.
9. Create return inbound document from a completed sales document.
10. Complete return inbound document.
11. Create stocktake document.
12. Confirm stocktake difference if backend supports it.
13. Settle stocktake.
14. If backend supports transfer, create and complete transfer document.
15. If backend supports non-standard conversion, create and complete conversion document.

Pass criteria:

- create success requires real backend document payload
- lifecycle failures keep original state
- stock and transaction changes match backend
- home recent documents refresh after lifecycle actions

### Phase E: Home And Reports

1. Confirm home metrics come from backend inventory/report endpoints or documented fallback.
2. Confirm recent documents match documents page.
3. Confirm low-stock and non-standard reminders match backend.
4. Trigger one endpoint failure if possible and confirm only the affected block shows error.
5. Open reports as admin.
6. Check sales summary, trend, ranking, inventory overview, turnover, and slow-moving sections.
7. Change period between `近7天`, `近30天`, and `本月`.
8. Log in as operator.
9. Confirm financial report fields are hidden and sensitive endpoints are skipped.

Pass criteria:

- no fixed KPI or fixed date data
- report date ranges use current date
- operator cannot see financial data
- partial report failure does not break the whole page

### Phase F: Lightweight Management

Run as admin:

1. Create a test user.
2. Reset the test user's password.
3. Log out and log in as the new user.
4. Confirm the new user has expected role and warehouse visibility.
5. Create a product.
6. Confirm the product appears in inventory or document product search.
7. Create a warehouse.
8. Bind user to warehouse.
9. Confirm user can access the warehouse according to role.
10. Update role permissions.
11. Confirm app capabilities change for affected role after re-login/session refresh.
12. Try deleting a user/product/warehouse that backend should reject because of business data.
13. Confirm frontend shows the backend conflict reason.

Pass criteria:

- internal setup does not require manual database edits
- dangerous actions require confirmation
- duplicate submits do not create duplicate backend records
- backend conflicts and authorization failures are visible

## 5. Defect Recording Template

Use one record per issue:

```text
ID:
Severity: P0/P1/P2/P3
Module:
Role:
Warehouse:
Endpoint:
Request:
Response:
Frontend state:
Expected:
Actual:
Reproduction steps:
Owner: frontend/backend/contract/unknown
Status: open/fixed/verified/deferred
```

Severity rules:

- P0: cannot log in, app crashes, inventory/document result is wrong.
- P1: role/warehouse boundary wrong, core action fails without useful feedback.
- P2: local state refresh, empty state, or error message is unclear but core flow can continue.
- P3: visual polish or non-core wording issue.

## 6. Fix Loop

For each defect:

1. Classify severity.
2. Decide owner.
3. If frontend-owned, write a failing test first.
4. Fix minimally in the correct MVVM layer.
5. Run targeted tests.
6. Run full smoke if P0/P1 or shared behavior changed.
7. Re-test manually against backend.
8. Update defect status and milestone notes.

Do not batch unrelated fixes.

## 7. Exit Criteria

Integration can be considered complete when:

- All Phase A-F pass, or any unsupported backend feature is explicitly documented.
- P0 and P1 defects are zero.
- P2 defects are documented and do not block internal acceptance.
- `scripts/rims_smoke.ps1` passes after the final fix.
- Demo residual scan has no hit in `rims_frontend/lib` or active `rims_frontend/test` paths.
- `rims_frontend/README.md` and milestone notes state that this is an internal acceptance APP, not a release build.

## 8. Recommended First Session

First联调 session should be limited to Phase A-C:

1. Start backend and frontend.
2. Validate admin/operator login.
3. Validate session restore and logout.
4. Validate warehouse switching.
5. Validate inventory list/detail/transaction.

Stop after Phase C, classify defects, fix P0/P1, then continue to documents. This keeps the first session small enough to debug cleanly.
