# RIMS M8 Frontend/Backend Integration Execution Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:systematic-debugging` when investigating any failed integration step, and use `superpowers:test-driven-development` before fixing frontend-owned P0/P1 defects. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Complete M8 frontend/backend integration so the RIMS Flutter app can pass internal acceptance against the real backend.

**Architecture:** Keep fixes inside the feature-first MVVM boundaries already used by the frontend. Treat backend contract mismatches as integration defects with endpoint, role, warehouse, request, response, UI state, and reproduction evidence before changing code.

**Tech Stack:** Flutter, Dio API client, Provider/GoRouter, RIMS Go backend at `http://localhost:8080/api/v1`, PostgreSQL-backed seed/test data, PowerShell smoke script, manual UI verification.

---

## Source Plan

This runbook operationalizes:

- `docs/superpowers/plans/2026-07-07-rims-frontend-backend-integration.md`

That source document defines the M8 scope:

- Phase A: environment, login, session restore, logout
- Phase B: warehouse switching, roles, permissions
- Phase C: inventory list, detail, transactions, admin inventory settings
- Phase D: documents, lifecycle completion, stocktake, transfer, conversion, inventory effects
- Phase E: home, reports, normal-user financial restrictions
- Phase F: lightweight management for users, products, warehouses, bindings, roles, permissions
- Exit: Phase A-F pass, P0/P1 cleared, final smoke passes

## Integration Ground Rules

- Do not use demo login, demo credentials, fixed frontend data, or frontend-only fake success paths.
- Do not edit the database manually during normal verification. Use backend seed data, backend API, or the app's admin flows.
- Do not continue to the next phase when a P0 is open.
- Do not continue past the current session stop gate when a P1 affects later evidence.
- Do not batch unrelated fixes. One defect, one root cause, one focused fix, one verification record.
- Backend service should be reachable at `http://localhost:8080`; API base URL should be `http://localhost:8080/api/v1`.

## File Touch Map

Use this map when a defect is frontend-owned. Read the relevant area first, then write the failing test in the matching test path before implementation.

### Core Network And Session

- `rims_frontend/lib/core/network/api_endpoints.dart`: API base URL and endpoint constants.
- `rims_frontend/lib/core/network/api_client.dart`: Dio setup, timeouts, interceptors, result conversion.
- `rims_frontend/lib/core/network/api_exception_mapper.dart`: backend error payload and status conversion.
- `rims_frontend/lib/core/network/interceptors/auth_interceptor.dart`: bearer token header behavior.
- `rims_frontend/lib/core/network/interceptors/warehouse_interceptor.dart`: `X-Warehouse-ID` request context.
- `rims_frontend/lib/core/storage/app_secure_storage.dart`: persisted auth/session values.
- `rims_frontend/test/core/network/api_client_test.dart`: core client regression tests.
- `rims_frontend/test/core/network/api_exception_mapper_test.dart`: error conversion tests.

### Phase A-B Auth, Warehouse, Permissions

- `rims_frontend/lib/features/auth/data/datasources/auth_remote_datasource.dart`
- `rims_frontend/lib/features/auth/data/models/auth_models.dart`
- `rims_frontend/lib/features/auth/data/repositories/auth_repository_impl.dart`
- `rims_frontend/lib/features/auth/presentation/view_models/login_view_model.dart`
- `rims_frontend/lib/features/auth/presentation/view_models/auth_session_controller.dart`
- `rims_frontend/lib/features/shell/presentation/pages/app_shell_page.dart`
- `rims_frontend/test/features/auth/login_view_model_test.dart`
- `rims_frontend/test/features/auth/auth_remote_datasource_test.dart`
- `rims_frontend/test/features/auth/auth_repository_impl_test.dart`

### Phase C Inventory

- `rims_frontend/lib/features/inventory/data/datasources/inventory_remote_datasource.dart`
- `rims_frontend/lib/features/inventory/data/models/inventory_models.dart`
- `rims_frontend/lib/features/inventory/data/repositories/inventory_repository_impl.dart`
- `rims_frontend/lib/features/inventory/presentation/view_models/inventory_view_model.dart`
- `rims_frontend/lib/features/inventory/presentation/pages/inventory_page.dart`
- `rims_frontend/test/features/inventory/inventory_remote_datasource_test.dart`
- `rims_frontend/test/features/inventory/inventory_view_model_test.dart`

### Phase D Documents

- `rims_frontend/lib/features/documents/data/datasources/documents_remote_datasource.dart`
- `rims_frontend/lib/features/documents/data/models/document_models.dart`
- `rims_frontend/lib/features/documents/data/repositories/documents_repository_impl.dart`
- `rims_frontend/lib/features/documents/presentation/view_models/documents_view_model.dart`
- `rims_frontend/lib/features/documents/presentation/pages/documents_page.dart`
- `rims_frontend/test/features/documents/documents_remote_datasource_test.dart`
- `rims_frontend/test/features/documents/documents_view_model_test.dart`

### Phase E Home And Reports

- `rims_frontend/lib/features/home/presentation/view_models/home_view_model.dart`
- `rims_frontend/lib/features/home/presentation/pages/home_page.dart`
- `rims_frontend/lib/features/reports/data/datasources/reports_remote_datasource.dart`
- `rims_frontend/lib/features/reports/data/models/report_models.dart`
- `rims_frontend/lib/features/reports/data/repositories/reports_repository_impl.dart`
- `rims_frontend/lib/features/reports/presentation/view_models/reports_view_model.dart`
- `rims_frontend/lib/features/reports/presentation/pages/reports_page.dart`
- `rims_frontend/test/features/home/home_view_model_test.dart`
- `rims_frontend/test/features/reports/reports_remote_datasource_test.dart`
- `rims_frontend/test/features/reports/reports_view_model_test.dart`

### Phase F Admin

- `rims_frontend/lib/features/admin/data/datasources/admin_remote_datasource.dart`
- `rims_frontend/lib/features/admin/data/models/`
- `rims_frontend/lib/features/admin/data/repositories/admin_repository_impl.dart`
- `rims_frontend/lib/features/admin/presentation/view_models/`
- `rims_frontend/lib/features/admin/presentation/widgets/`
- `rims_frontend/test/features/admin/`

## Evidence And Defect Records

Keep one running integration note for the session. Use this section as the required shape if the notes are kept in chat, issue tracker, or a markdown file.

```text
M8 Integration Session:
Date:
Frontend branch:
Backend commit:
API base URL:
Backend health result:
Frontend launch command:
Admin account:
Operator account:
Warehouse A:
Warehouse B:
Products:
Open P0:
Open P1:
Open P2:
Open P3:
```

Use one defect record per issue:

```text
ID: M8-<phase>-<number>
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
Verification:
```

Severity:

- P0: cannot log in, app crashes, inventory result is wrong, document lifecycle changes the wrong stock, protected data leaks.
- P1: role or warehouse boundary is wrong, core flow fails without useful feedback, backend error advances UI state incorrectly.
- P2: stale local refresh, unclear empty state, incomplete partial error handling, recoverable UI inconsistency.
- P3: wording, spacing, visual polish, non-core copy.

## Session Plan

Run M8 in four sessions, with a hard stop after each session for defect triage.

| Session | Scope | Stop Gate |
| --- | --- | --- |
| Session 0 | Runtime baseline and test data register | Backend health, frontend launch, admin/operator data ready |
| Session 1 | Phase A-C | Auth, warehouse, permission, inventory pass or P0/P1 fixed |
| Session 2 | Phase D | Document lifecycle and inventory effects pass or P0/P1 fixed |
| Session 3 | Phase E-F | Home, reports, admin setup pass or P0/P1 fixed |
| Session 4 | Final smoke and acceptance notes | Phase A-F pass, P0/P1 zero, smoke pass |

---

## Task 1: Runtime Baseline

**Files:**

- Read: `docs/superpowers/plans/2026-07-07-rims-frontend-backend-integration.md`
- Read: `rims_frontend/lib/core/network/api_endpoints.dart`
- Verify: `scripts/rims_smoke.ps1`

- [ ] **Step 1: Confirm backend health**

Run from PowerShell:

```powershell
curl.exe -sS http://localhost:8080/healthz
```

Expected:

```json
{"status":"ok"}
```

- [ ] **Step 2: Confirm Swagger is reachable**

Run:

```powershell
curl.exe -sS -o NUL -w "%{http_code}`n" http://localhost:8080/swagger/index.html
```

Expected:

```text
200
```

- [ ] **Step 3: Confirm admin login against real backend**

Run:

```powershell
curl.exe -sS -i -X POST http://localhost:8080/api/v1/auth/login `
  -H "Content-Type: application/json" `
  -d "{\"username\":\"admin\",\"password\":\"admin123\"}"
```

Expected:

```text
HTTP/1.1 200 OK
```

Response body must include `code: 0`, a non-empty `data.token`, and `data.user.roleCode` equal to `admin`.

- [ ] **Step 4: Run frontend baseline smoke**

Run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\rims_smoke.ps1
```

Expected:

```text
RIMS smoke checks passed.
```

- [ ] **Step 5: Start frontend against backend**

Run:

```powershell
cd .\rims_frontend
flutter run -d chrome --dart-define=API_BASE_URL=http://localhost:8080/api/v1
```

Expected: login page opens. Browser devtools/network should show requests targeting `localhost:8080`, not demo/local fake endpoints.

## Task 2: Test Data Register

**Files:**

- Verify through UI/API: backend users, warehouses, products, inventory, non-standard inventory.
- Modify only if missing and frontend-owned setup tooling exists: admin feature files under `rims_frontend/lib/features/admin/`.

- [ ] **Step 1: Record admin account**

Record:

```text
Admin username: admin
Admin password source: backend .env DEMO_PASSWORD or test seed
Expected role: admin
```

- [ ] **Step 2: Prepare operator account**

Requirement:

```text
Operator account exists, is active, is not admin, and is bound to exactly the warehouse set required for Phase B.
```

If no operator exists, create one through the backend API or admin UI before Phase B. Record username, role, warehouse bindings, and creation evidence.

- [ ] **Step 3: Prepare warehouse data**

Requirement:

```text
Warehouse A: active, accessible by admin
Warehouse B: active, accessible by admin
Operator warehouse: accessible by operator
```

If only one warehouse exists, create a second warehouse through backend API or admin UI before Phase B. Do not edit PostgreSQL directly.

- [ ] **Step 4: Prepare product and inventory data**

Requirement:

```text
Product 1: normal stock, enough for sales outbound
Product 2: low stock, should appear in warning/alert flow
Product 3: insufficient stock, should fail sales outbound completion
Optional product/non-standard item: available for conversion flow
```

Record product IDs, names, SKUs/barcodes, warehouse IDs, initial quantities, thresholds, and whether each item is used in Phase C, D, or E.

- [ ] **Step 5: Freeze starting numbers**

Before Phase C, record:

```text
Inventory quantity before document tests:
Transaction count before document tests:
Document count before document tests:
Report period used for tests:
```

These starting numbers are the baseline for proving stock and report changes later.

## Task 3: Phase A - Environment, Login, Session Restore, Logout

**Files if frontend-owned defects appear:**

- `rims_frontend/lib/features/auth/data/datasources/auth_remote_datasource.dart`
- `rims_frontend/lib/features/auth/data/models/auth_models.dart`
- `rims_frontend/lib/features/auth/data/repositories/auth_repository_impl.dart`
- `rims_frontend/lib/features/auth/presentation/view_models/login_view_model.dart`
- `rims_frontend/lib/features/auth/presentation/view_models/auth_session_controller.dart`
- `rims_frontend/lib/core/storage/app_secure_storage.dart`
- `rims_frontend/test/features/auth/`

- [ ] **Step 1: Wrong-password login**

Action: enter admin username with an intentionally wrong password.

Expected:

```text
Login is rejected.
Backend error message is visible.
No app shell opens.
No token/session is persisted.
```

Evidence: record endpoint, HTTP status, response body, and visible UI message.

- [ ] **Step 2: Admin login**

Action: log in with admin credentials.

Expected:

```text
App shell opens.
Current user is admin.
Role is admin.
Current warehouse is shown.
Available warehouses are loaded from backend.
```

- [ ] **Step 3: Session restore**

Action: refresh browser/app after successful login.

Expected:

```text
App remains authenticated.
Frontend calls /users/me and /users/me/warehouses.
Current user and warehouse are restored from backend data.
No demo user or fake warehouse appears.
```

- [ ] **Step 4: Logout**

Action: log out.

Expected:

```text
Token/session is cleared.
Protected pages redirect or return to login.
Refreshing after logout stays on login.
```

- [ ] **Step 5: Token expiry behavior**

Action: if practical, remove/alter token in storage or wait for an auth failure from a protected request.

Expected:

```text
Authentication failure publishes token-expired behavior.
User is returned to login or shown a clear session-expired state.
No protected data remains usable.
```

Phase A pass requires all five steps to pass with P0/P1 zero.

## Task 4: Phase B - Warehouse Switching, Roles, Permissions

**Files if frontend-owned defects appear:**

- `rims_frontend/lib/core/network/interceptors/warehouse_interceptor.dart`
- `rims_frontend/lib/features/auth/presentation/view_models/auth_session_controller.dart`
- `rims_frontend/lib/features/shell/presentation/pages/app_shell_page.dart`
- `rims_frontend/lib/features/auth/data/repositories/auth_repository_impl.dart`
- `rims_frontend/test/features/auth/auth_repository_impl_test.dart`

- [ ] **Step 1: Admin warehouse switch**

Action: log in as admin and switch from Warehouse A to Warehouse B.

Expected:

```text
Switch request succeeds.
UI shows Warehouse B as current.
Subsequent inventory/document/report requests include X-Warehouse-ID for Warehouse B.
Home, inventory, documents, and reports refresh.
```

- [ ] **Step 2: Failed warehouse switch protection**

Action: attempt to switch to a warehouse that the backend should reject, if such an account/data combination exists.

Expected:

```text
Backend rejection is visible.
Old warehouse remains selected.
No follow-up business requests use the rejected warehouse ID.
```

- [ ] **Step 3: Operator visibility**

Action: log in as operator.

Expected:

```text
Operator cannot access management panels.
Operator warehouse switcher is hidden or constrained to allowed warehouses.
Operator cannot see transfer/conversion actions if backend role does not allow them.
```

- [ ] **Step 4: Direct route/refresh permission check**

Action: try browser refresh or direct navigation to admin/profile management surfaces while logged in as operator.

Expected:

```text
Admin-only surface does not render actionable controls.
Any backend 403 is shown clearly and does not crash the app.
```

Phase B pass requires warehouse headers, UI state, and permissions to agree with backend behavior.

## Task 5: Phase C - Inventory List, Detail, Transactions, Admin Settings

**Files if frontend-owned defects appear:**

- `rims_frontend/lib/features/inventory/data/datasources/inventory_remote_datasource.dart`
- `rims_frontend/lib/features/inventory/data/models/inventory_models.dart`
- `rims_frontend/lib/features/inventory/data/repositories/inventory_repository_impl.dart`
- `rims_frontend/lib/features/inventory/presentation/view_models/inventory_view_model.dart`
- `rims_frontend/lib/features/inventory/presentation/pages/inventory_page.dart`
- `rims_frontend/test/features/inventory/`

- [ ] **Step 1: Inventory list loads from backend**

Action: open inventory page as admin.

Expected:

```text
Inventory list shows backend products for current warehouse.
Empty/loading/error states are real endpoint states.
No fixed inventory cards or demo products appear.
```

- [ ] **Step 2: Search by product keyword**

Action: search using Product 1 name keyword.

Expected:

```text
List filters according to backend behavior or documented frontend query behavior.
The selected product remains consistent with backend ID and warehouse.
```

- [ ] **Step 3: Search by SKU/barcode-equivalent input**

Action: search using Product 1 SKU or barcode when backend data supports it.

Expected:

```text
Matching product appears.
If barcode endpoint is used, request path matches /products/barcode/:barcode.
No false positive from local fake data.
```

- [ ] **Step 4: Inventory detail**

Action: open Product 1 inventory detail.

Expected:

```text
Detail quantity, status, threshold, product fields, and warehouse agree with backend response.
List and detail quantities agree.
```

- [ ] **Step 5: Inventory transactions**

Action: open transactions for selected product or warehouse-scoped transaction area.

Expected:

```text
Transactions load from /transactions.
Transaction failure does not clear the inventory list.
Empty transaction state is distinguishable from endpoint failure.
```

- [ ] **Step 6: Admin inventory setting**

Action: as admin, update warning threshold or inventory status.

Expected:

```text
Update request succeeds.
Updated value appears after refresh.
Backend response drives UI state.
```

- [ ] **Step 7: Operator inventory restriction**

Action: repeat settings check as operator.

Expected:

```text
Operator cannot see or submit admin-only inventory settings.
If backend returns 403, UI shows a clear authorization message.
```

Phase C pass requires list/detail/transaction/settings to be backend-backed and warehouse-correct.

## Task 6: Session 1 Stop Gate And Fix Loop

**Files:**

- Modify only defect-owned files from Task 3-5.
- Test only matching test files first; run full smoke after P0/P1 fixes.

- [ ] **Step 1: Classify all Phase A-C defects**

For every defect, fill:

```text
Severity:
Owner:
Blocking phase:
Reproduction:
Next verification:
```

- [ ] **Step 2: Stop on P0**

If any P0 exists, do not begin Phase D. Fix and verify the P0 first.

- [ ] **Step 3: Fix P1 that blocks Phase D evidence**

Examples:

```text
Warehouse header wrong.
Operator can access admin-only flow.
Inventory quantity/detail mismatches backend.
Auth restore fails after refresh.
```

- [ ] **Step 4: Frontend-owned fix protocol**

For each frontend-owned P0/P1:

```text
1. Write a failing focused test in the matching test path.
2. Run the test and confirm the expected failure.
3. Fix the smallest MVVM layer that owns the defect.
4. Run the focused test and confirm pass.
5. Run scripts/rims_smoke.ps1 if shared behavior changed.
6. Re-test manually against backend.
7. Mark defect verified with evidence.
```

- [ ] **Step 5: Backend/contract-owned fix protocol**

For backend or contract defects:

```text
1. Preserve request and response evidence.
2. Identify expected contract from backend Swagger/source behavior.
3. Record whether frontend must adapt or backend must change.
4. Do not hide the issue with frontend fake data.
```

Session 1 is complete when Phase A-C pass or all remaining defects are P2/P3 and explicitly accepted for later.

## Task 7: Phase D - Documents And Inventory Effects

**Files if frontend-owned defects appear:**

- `rims_frontend/lib/features/documents/data/datasources/documents_remote_datasource.dart`
- `rims_frontend/lib/features/documents/data/models/document_models.dart`
- `rims_frontend/lib/features/documents/data/repositories/documents_repository_impl.dart`
- `rims_frontend/lib/features/documents/presentation/view_models/documents_view_model.dart`
- `rims_frontend/lib/features/documents/presentation/pages/documents_page.dart`
- `rims_frontend/lib/features/inventory/presentation/view_models/inventory_view_model.dart`
- `rims_frontend/test/features/documents/`

- [ ] **Step 1: Purchase inbound create**

Action: create purchase inbound document using Product 1.

Expected:

```text
Backend returns a real document ID/docNo.
Document appears in list/detail with created status.
No local fake ID is used.
```

- [ ] **Step 2: Purchase inbound complete**

Action: complete the purchase inbound document.

Expected:

```text
Document status advances according to backend.
Inventory quantity increases by line quantity.
Transaction log includes inbound effect.
Home recent documents can show the completed document after refresh.
```

- [ ] **Step 3: Sales outbound create and complete**

Action: create sales outbound document with available stock and complete it.

Expected:

```text
Document completes.
Inventory quantity decreases by line quantity.
Transaction log includes outbound effect.
```

- [ ] **Step 4: Insufficient-stock failure**

Action: create or complete sales outbound document using Product 3 with insufficient stock.

Expected:

```text
Backend error is visible.
Document state is not falsely advanced.
Inventory quantity is unchanged.
No success toast appears.
```

- [ ] **Step 5: Return inbound**

Action: create and complete return inbound document based on completed sales flow if backend supports the relationship.

Expected:

```text
Returned quantity increases stock.
Transaction log identifies the return effect.
```

- [ ] **Step 6: Stocktake**

Action: create stocktake document, confirm if required, then settle.

Expected:

```text
Stocktake status follows backend lifecycle.
Settled stock quantity matches backend-calculated adjustment.
Invalid lifecycle actions are blocked or show backend error.
```

- [ ] **Step 7: Transfer**

Action: if backend supports transfer, create and complete transfer document between Warehouse A and Warehouse B.

Expected:

```text
Source warehouse stock decreases.
Target warehouse stock increases.
Warehouse switch shows each side correctly.
```

- [ ] **Step 8: Non-standard conversion**

Action: if backend supports non-standard inventory conversion, create/complete conversion flow.

Expected:

```text
Non-standard inventory decreases.
Standard inventory increases.
Transaction or document evidence appears according to backend behavior.
```

Phase D pass requires every successful lifecycle action to match inventory and transaction evidence, and every failed action to preserve original UI/backend state.

## Task 8: Phase E - Home And Reports

**Files if frontend-owned defects appear:**

- `rims_frontend/lib/features/home/presentation/view_models/home_view_model.dart`
- `rims_frontend/lib/features/home/presentation/pages/home_page.dart`
- `rims_frontend/lib/features/reports/data/datasources/reports_remote_datasource.dart`
- `rims_frontend/lib/features/reports/data/models/report_models.dart`
- `rims_frontend/lib/features/reports/data/repositories/reports_repository_impl.dart`
- `rims_frontend/lib/features/reports/presentation/view_models/reports_view_model.dart`
- `rims_frontend/lib/features/reports/presentation/pages/reports_page.dart`
- `rims_frontend/test/features/home/`
- `rims_frontend/test/features/reports/`

- [ ] **Step 1: Home metrics**

Action: open home after Phase D changes.

Expected:

```text
Home inventory metrics reflect backend inventory/report endpoints or a documented backend-backed fallback.
Recent documents match documents page.
Low-stock and non-standard reminders match backend data.
```

- [ ] **Step 2: Home partial failure**

Action: if practical, trigger one home-related endpoint failure.

Expected:

```text
Only affected block shows error.
Unaffected blocks remain visible.
No fixed KPI fallback appears as real data.
```

- [ ] **Step 3: Admin reports**

Action: as admin, open reports and check sales stats, trend, ranking, inventory overview, turnover, and slow-moving sections.

Expected:

```text
Data is loaded from report endpoints.
Date ranges match selected period.
Financial fields are visible to admin when backend returns them.
```

- [ ] **Step 4: Report period switching**

Action: switch between `近7天`, `近30天`, and `本月`.

Expected:

```text
Requests use current-date-based ranges.
Charts/cards refresh.
Old period data does not remain after loading completes.
```

- [ ] **Step 5: Operator financial restrictions**

Action: log in as operator and open reports.

Expected:

```text
Sensitive financial fields are hidden.
Frontend does not expose cost/profit/stock-value values if backend omits them.
403 or omitted fields do not crash the report page.
```

Phase E pass requires home/report data to be backend-backed, date-correct, and role-safe.

## Task 9: Phase F - Lightweight Management

**Files if frontend-owned defects appear:**

- `rims_frontend/lib/features/admin/data/datasources/admin_remote_datasource.dart`
- `rims_frontend/lib/features/admin/data/models/`
- `rims_frontend/lib/features/admin/data/repositories/admin_repository_impl.dart`
- `rims_frontend/lib/features/admin/presentation/view_models/`
- `rims_frontend/lib/features/admin/presentation/widgets/`
- `rims_frontend/lib/features/profile/presentation/`
- `rims_frontend/test/features/admin/`

- [ ] **Step 1: Create test user**

Action: as admin, create a uniquely named test user.

Expected:

```text
User appears in user list.
Duplicate submit does not create duplicate records.
Validation errors are visible.
```

- [ ] **Step 2: Reset password and log in**

Action: reset the user's password, log out, and log in as that user.

Expected:

```text
New password works.
Role and warehouse visibility match admin configuration.
Session restore works for the new user.
```

- [ ] **Step 3: Create product**

Action: as admin, create a product.

Expected:

```text
Product appears in product list and business product search.
Backend duplicate/conflict errors are visible.
```

- [ ] **Step 4: Create warehouse and bind user**

Action: create warehouse, bind test user, refresh/re-login as needed.

Expected:

```text
Warehouse appears in admin list.
User binding appears in warehouse users.
User warehouse access changes after session refresh/re-login.
```

- [ ] **Step 5: Role permissions**

Action: update a role's permission set and re-login affected user.

Expected:

```text
Frontend capabilities change according to backend permissions.
Admin-only controls do not remain visible due to stale local state.
```

- [ ] **Step 6: Rejected deletes and conflicts**

Action: try deleting user/product/warehouse records that backend should reject because they have business data or bindings.

Expected:

```text
Backend conflict reason is visible.
Frontend does not remove the record locally unless backend confirms deletion.
Dangerous actions require confirmation.
```

Phase F pass requires internal setup to be possible through the app/API without direct database edits.

## Task 10: Final Acceptance Smoke

**Files:**

- Verify: `scripts/rims_smoke.ps1`
- Verify/update if needed: `rims_frontend/README.md`
- Verify/update if needed: milestone notes under `docs/superpowers/`

- [ ] **Step 1: Re-run targeted manual checks**

Re-run the shortest path through:

```text
Admin login -> warehouse switch -> inventory list -> create/complete one document -> report refresh -> logout.
Operator login -> restricted UI check -> inventory/report read check -> logout.
```

Expected: no P0/P1 behavior appears.

- [ ] **Step 2: Run final smoke**

Run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\rims_smoke.ps1
```

Expected:

```text
RIMS smoke checks passed.
```

- [ ] **Step 3: Confirm demo residual scan remains clean**

The smoke script includes the residual scan. If it fails, remove real demo residue from active `rims_frontend/lib` or active `rims_frontend/test` paths and re-run smoke.

- [ ] **Step 4: Confirm P0/P1 zero**

Acceptance requires:

```text
Open P0: 0
Open P1: 0
P2: documented and accepted for internal use
P3: documented or deferred
Unsupported backend features: explicitly documented
```

- [ ] **Step 5: Update acceptance notes**

Record:

```text
Phase A: pass/fail
Phase B: pass/fail
Phase C: pass/fail
Phase D: pass/fail
Phase E: pass/fail
Phase F: pass/fail
Final smoke: pass/fail
Internal acceptance status:
Known deferred issues:
```

## Fix Policy

When a defect is frontend-owned:

1. Reproduce it against the real backend.
2. Write a failing focused test in the matching frontend test path.
3. Fix the smallest owning layer:
   - response/envelope mismatch: data model or remote datasource
   - wrong request URL or method: datasource or `api_endpoints.dart`
   - missing auth/warehouse header: interceptor or session controller
   - wrong loading/error/UI state: ViewModel or Page
   - role visibility bug: session/user entity, shell/page visibility logic
4. Run the focused test.
5. Run `scripts/rims_smoke.ps1` for P0/P1 or shared behavior changes.
6. Re-test manually against backend and close the defect only with evidence.

When a defect is backend-owned:

1. Keep exact request and response.
2. Confirm frontend sent the expected token and warehouse header.
3. Record expected backend behavior from Swagger/source or product requirement.
4. Do not mask backend failure with fake frontend success.

## Recommended Immediate Next Step

Start with Session 1 only:

```text
Task 1 -> Task 2 -> Task 3 -> Task 4 -> Task 5 -> Task 6
```

That covers Phase A-C and creates a clean stop before the more stateful document tests in Phase D.
