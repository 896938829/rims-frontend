# RIMS M8 Integration Session 1 Notes

**Date:** 2026-07-07

**Scope:** Phase A-F from `2026-07-07-rims-m8-integration-execution-runbook.md`.

## Runtime Baseline

- Frontend branch: `dev`
- Backend path: `E:\My Work\RIMS\rims-goProgect`
- Backend API used by browser/frontend: `http://localhost:8080/api/v1`
- Backend health:
  - `http://localhost:8080/healthz` returns `200` with `{"status":"ok"}`
  - `http://127.0.0.1:8080/healthz` fails from Windows curl in this environment
- Admin login smoke:
  - `POST /api/v1/auth/login` with `admin / admin123` returns `200`
- Frontend smoke:
  - `powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\rims_smoke.ps1`
  - Result: pass
  - `flutter analyze --no-pub`: pass
  - `flutter test --no-pub`: 339 tests pass
  - Demo residual scan: pass
  - `git diff --check`: pass with line-ending warnings only

## Test Data

### Accounts

- Admin:
  - Username: `admin`
  - Password: `admin123`
  - Role: `admin`
- Operator:
  - Username: `m8_operator_20260707164313`
  - Password: `M8Pass123`
  - User ID: `92`
  - Role: `user`

### Warehouses

- Warehouse A:
  - ID: `1`
  - Code: `WH001`
  - Name: `默认仓库`
  - Bound users for this session: `admin`, `m8_operator_20260707164313`
- Warehouse B:
  - ID: `2`
  - Code: `wh_1776335729379`
  - Name: `测试仓库_1776335729379`
  - Bound users for this session: `admin`

### Inventory Samples

- Warehouse A inventory total before UI integration: `42`
- Low-stock sample:
  - Inventory ID: `30`
  - Product code: `sale_1776407432915`
  - Product name: `销售测试商品_1776407432915`
  - Quantity: `8`
  - Alert threshold: `13`

## Phase Evidence

### Phase A

- Wrong-password login now shows only backend credential error.
- Admin login reaches `#/app`.
- Browser reload restores authenticated shell coherently.
- Logout clears persisted token; reopening `#/app` stays on login.

### Phase B

- Admin `/users/me/warehouses` returns `默认仓库` and `测试仓库_1776335729379`.
- Operator `/users/me/warehouses` returns only `默认仓库`.
- Frontend hides operator-only prohibited workflows and financial report metrics.

### Phase C

- `GET /inventory/alerts` returns the low-stock sample inventory ID `30`.
- `GET /non-std-inventory` returns non-standard inventory rows.
- Admin `PUT /inventory/30` updates alert threshold.
- Operator `PUT /inventory/30` returns `403 权限不足`.
- `GET /transactions?page=1&pageSize=5` returns recent inventory transaction rows.

### Phase D

- Purchase inbound + sales outbound around product ID `34`:
  - Before quantity: `8`
  - Inbound document `RK20260707001`: quantity `8 -> 9`
  - Sales document `XS20260707001`: quantity `9 -> 8`
  - Transactions added with before/after quantities `8 -> 9` and `9 -> 8`.
- Stocktake document `PD20260707001`:
  - Created as status `1`
  - Confirmed and settled to status `3 / 已结转`
  - Quantity remained `8` because actual quantity matched system quantity.
- Transfer documents:
  - `DB20260707001`: warehouse 1 `8 -> 7`, warehouse 2 `0 -> 1`
  - `DB20260707002`: warehouse 1 `7 -> 8`, warehouse 2 `1 -> 0`
- Non-standard conversion:
  - Created non-standard inventory `M8_NS_20260707174925`, quantity `2`
  - Conversion document `ZH20260707001`: standard quantity `8 -> 10`, non-standard remaining `0`, status `3`
  - Sales document `XS20260707002`: standard quantity restored `10 -> 8`
- Frontend document tests pass:
  - `flutter test --no-pub test/features/documents/documents_view_model_test.dart test/features/documents/documents_remote_datasource_test.dart test/features/documents/document_models_test.dart test/features/documents/document_status_kind_test.dart`

### Phase E

- Admin report API evidence for `2026-04-01` to `2026-07-07`, warehouse `1`:
  - `GET /reports/sales/stats` returns revenue `11900`, order count `28`, SKU count `17`, quantity `141`, cost amount `7060`, gross profit `4840`.
  - `GET /reports/sales/trend` without `bucket` returns `400`; with `bucket=day` returns two points: `2026-04-17` and `2026-07-07`.
  - `GET /reports/sales/ranking?metric=amount&limit=5` returns product ID `34` as the top item with amount `1500`.
  - `GET /reports/inventory/overview` returns SKU count `42`, total quantity `1349`, low stock count `1`, total value `25345`.
  - `GET /reports/inventory/turnover` returns product ID `34` with outbound quantity `15` and turnover rate `1.327433628318584`.
  - `GET /reports/inventory/slow-moving` returns paged slow-moving inventory rows.
- Operator report API evidence:
  - `GET /reports/sales/stats` returns revenue/order/quantity but omits `costAmount` and `grossProfit`.
  - `GET /reports/sales/ranking` returns amount but omits `grossProfit`.
  - `GET /reports/inventory/overview` omits `totalValue`.
- Frontend report/home tests pass:
  - `flutter test --no-pub test/features/reports/reports_remote_datasource_test.dart`
  - `flutter test --no-pub test/features/reports/reports_view_model_test.dart test/features/home/home_view_model_test.dart`
- Frontend fixes verified:
  - Sales trend requests now include `bucket=day`.
  - Regular-user report ViewModel skips sales stats, trend, and ranking endpoints when financial metrics are hidden.
  - Home metrics use inventory overview, alerts, non-standard inventory, and recent documents repositories with scoped partial failures.

### Phase F

- Created API test data through admin APIs:
  - User ID `93`, username `m8_f_user_0707232747`, reset password `M8Pass456`, final role `user`.
  - Product ID `51`, code `m8p0707232747`, name `M8联调商品0707232747`.
  - Warehouse ID `39`, code `m8w20707232747`, name `M8联调仓2_0707232747`, bound to user ID `93`.
- User management evidence:
  - `POST /users` created user ID `93`.
  - Duplicate `POST /users` for the same username returns `409` with `用户名已存在`.
  - `PUT /users/93/password` resets password, and the user can log in with the reset password.
- Role/permission evidence:
  - Temporary role ID `5` was created.
  - Test user with role ID `5` received `403 权限不足` for `GET /users`.
  - `PUT /roles/5/permissions` with permission ID `25` (`user:list`) succeeded.
  - Re-login as the test user then allowed `GET /users` with `200`.
  - Test user was restored to role `user`; temporary role ID `5` was deleted with `204`.
- Product management evidence:
  - `POST /products` created product ID `51`.
  - Duplicate `POST /products` for the same code returns `409` with `商品编码已存在`.
  - `GET /products?keyword=m8p0707232747&page=1&pageSize=20` returns only the created product with `total: 1`.
- Warehouse/binding evidence:
  - `POST /warehouses` created warehouse ID `39`.
  - `POST /warehouses/39/users` bound user ID `93`.
  - Re-login as `m8_f_user_0707232747` returns `/users/me/warehouses` with warehouse ID `39` as default.
- Frontend admin tests pass:
  - `flutter test --no-pub test/features/admin`

## Final Smoke

- Command:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\rims_smoke.ps1
```

- Result: pass.
- `flutter pub get --offline`: pass.
- `flutter analyze --no-pub`: pass with no issues.
- `flutter test --no-pub`: pass, `350` tests.
- Demo residual scan: pass.
- `git diff --check`: pass with line-ending warnings only.
- Backend verification after P1 fixes:
  - `go test ./internal/modules/user ./internal/modules/warehouse ./internal/modules/product`: pass.
  - `go test ./...`: pass.
  - `go build ./...`: pass.
- Backend service was restarted after applying migration `000013_role_read_permission_seed.sql`.
- Final frontend smoke after backend restart:
  - `powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\rims_smoke.ps1`: pass, `350` tests.

## Acceptance Status

- Phase A: frontend pass after fixes.
- Phase B: pass after backend current-warehouse persistence and role/permission read authorization fixes.
- Phase C: pass after backend inventory keyword search list filtering fix.
- Phase D: pass by API evidence and frontend document tests.
- Phase E: frontend pass after sales-trend `bucket=day` fix; backend hides admin-only cost/profit/stock value fields for ordinary users.
- Phase F: pass after backend rejects deletion of warehouses with active user bindings.
- Open P0: `0`.
- Open P1: `0`.
- Internal acceptance status: pass for the M8 internal acceptance integration scope.

## Defects

### M8-A-001

Severity: P1

Module: local environment / frontend default configuration

Role: any

Warehouse: n/a

Endpoint: `GET /healthz`, frontend API base URL

Request:

```text
curl.exe http://127.0.0.1:8080/healthz
```

Response:

```text
curl: (7) Failed to connect to 127.0.0.1 port 8080
```

Frontend state: app default API base URL was `http://127.0.0.1:8080/api/v1`.

Expected: documented default local URL works for Windows Flutter/browser integration.

Actual: Windows can reach `http://localhost:8080`, but not `http://127.0.0.1:8080`; `netstat` shows the WSL port proxy listening on `[::1]:8080`.

Reproduction steps:

1. Start backend in WSL.
2. Run `curl.exe -sS -o NUL -w "%{http_code}\n" http://127.0.0.1:8080/healthz`.
3. Run `curl.exe -sS -o NUL -w "%{http_code}\n" http://localhost:8080/healthz`.

Owner: frontend/config/docs or local environment

Status: fixed/verified

Verification:

- Added failing regression test in `rims_frontend/test/core/network/api_client_test.dart`.
- Targeted test failed before fix with actual base URL `http://127.0.0.1:8080/api/v1`.
- Fixed `ApiEndpoints.baseUrl` default to `http://localhost:8080/api/v1`.
- Updated current integration runbook and frontend README startup commands to use `localhost`.
- Targeted tests pass:
  - `flutter test --no-pub test/core/network/api_client_test.dart test/features/reports/reports_remote_datasource_test.dart`

### M8-A-002

Severity: P1

Module: frontend auth/session

Role: unauthenticated

Warehouse: n/a

Endpoint: `POST /api/v1/auth/login`

Request:

```json
{"username":"admin","password":"wrong-password"}
```

Response:

```json
{"code":10001,"message":"用户名或密码错误"}
```

Frontend state: login page.

Expected: login remains on the login page and shows only the backend credential error.

Actual: before fix, login page showed both `用户名或密码错误` and global `登录已过期，请重新登录`.

Reproduction steps:

1. Open frontend with `API_BASE_URL=http://localhost:8080/api/v1`.
2. Enter `admin` with an incorrect password.
3. Submit login form.

Owner: frontend

Status: fixed/verified

Verification:

- Added failing regression test in `rims_frontend/test/core/network/api_client_test.dart`.
- Targeted test failed before fix with `Actual: <1>` token-expired events.
- Fixed `ApiClient` so `ApiEndpoints.login` authentication failures do not publish `TokenExpiredEvent`.
- Targeted test now passes: `flutter test --no-pub test/core/network/api_client_test.dart`.
- Browser retest shows only `用户名或密码错误`.

### M8-A-003

Severity: P1

Module: frontend auth/router

Role: admin

Warehouse: `默认仓库`

Endpoint: session restore from local storage

Frontend state: reload browser on authenticated shell route `#/app`.

Expected: after refresh, authenticated session is restored before shell content is shown; user name and selected warehouse remain coherent.

Actual: before fix, refresh could show the shell with `你好，未登录用户` and `未选择仓库` while authenticated inventory data was still visible.

Reproduction steps:

1. Open frontend with `API_BASE_URL=http://localhost:8080/api/v1`.
2. Log in as `admin / admin123`.
3. Refresh browser while on `#/app`.

Owner: frontend

Status: fixed/verified

Verification:

- Added router regression tests in `rims_frontend/test/app_static_ui_test.dart`.
- Targeted restore test failed before fix because shell content rendered while session restore was still in progress.
- Fixed `AppRouter` redirect logic so unauthenticated non-login routes redirect to login during restore.
- Targeted and file-level tests pass:
  - `flutter test --no-pub test/app_static_ui_test.dart --plain-name "shell route shows login restore state while restoring session"`
  - `flutter test --no-pub test/app_static_ui_test.dart`
- Browser retest after reload shows `你好，系统管理员` and `默认仓库`.

### M8-A-004

Severity: P1

Module: frontend admin/profile

Role: admin

Warehouse: `默认仓库`

Endpoint: admin list APIs loaded by profile management panels

Frontend state: open `我的` / admin management area after login or refresh.

Expected: navigating to or away from profile/admin panels does not emit uncaught Flutter errors.

Actual: browser console showed disposed `ChangeNotifier` errors after async admin panel loads completed:

```text
A AdminProductsViewModel was used after being disposed.
A AdminWarehousesViewModel was used after being disposed.
A AdminRolesViewModel was used after being disposed.
```

Reproduction steps:

1. Log in as `admin / admin123`.
2. Refresh the authenticated shell.
3. Open `我的`.
4. Observe browser console while admin panels finish loading.

Owner: frontend

Status: fixed/verified

Verification:

- Added failing disposal timing tests for admin Products/Warehouses/Roles/Users ViewModels.
- Targeted tests failed before fix with `ChangeNotifier.notifyListeners` after disposal.
- Fixed admin ViewModels so notifications after disposal are no-ops.
- Targeted tests now pass:
  - `flutter test --no-pub test/features/admin/admin_products_view_model_test.dart test/features/admin/admin_warehouses_view_model_test.dart test/features/admin/admin_roles_view_model_test.dart test/features/admin/admin_users_view_model_test.dart`
- Browser retest after frontend restart:
  - Reloaded authenticated shell; no new console errors after reload.
  - Opened `我的`; admin panel APIs completed with no new disposed `ChangeNotifier` errors.

### M8-A-005

Severity: P0

Module: frontend auth/session logout

Role: admin

Warehouse: `默认仓库`

Endpoint: local persisted session / secure token storage

Frontend state: authenticated shell, then `我的 -> 退出登录`.

Expected: logout clears both in-memory session and persisted access token; refreshing `#/app` after logout stays on login.

Actual: before fix, logout returned to the login page, but refreshing `http://localhost:61345/#/app` restored the admin session and showed the home dashboard again.

Reproduction steps:

1. Log in as `admin / admin123`.
2. Open `我的`.
3. Scroll to the bottom and click `退出登录`.
4. Reload `http://localhost:61345/#/app`.

Owner: frontend

Status: fixed/verified

Verification:

- Added failing shell regression test in `rims_frontend/test/app_static_ui_test.dart`.
- Targeted test failed before fix with `logoutCallCount` `0`.
- Fixed `AppShellPage` logout flow so profile logout calls `AuthRepository.logout()` before clearing `AuthSessionController`.
- Targeted and file-level tests pass:
  - `flutter test --no-pub test/app_static_ui_test.dart --plain-name "profile logout clears persisted auth session"`
  - `flutter test --no-pub test/app_static_ui_test.dart`
- Browser retest after frontend restart:
  - Existing persisted admin token restored `#/app` before logout, confirming the retest started from an authenticated persisted session.
  - `我的 -> 退出登录` returned to login with no new console errors.
  - Re-opening `http://localhost:61345/#/app` stayed on login and did not restore the admin shell.

### M8-B-001

Severity: P1

Module: frontend session refresh / backend warehouse context contract

Role: admin

Warehouse: switch from `默认仓库` to `测试仓库_1776335729379`

Endpoint:

- `PUT /api/v1/users/me/warehouses/current`
- `GET /api/v1/users/me`
- `GET /api/v1/users/me/warehouses`

Request:

```json
{"warehouseId":2}
```

Response:

```json
{
  "code": 0,
  "message": "success",
  "data": {
    "id": 2,
    "code": "wh_1776335729379",
    "name": "测试仓库_1776335729379"
  }
}
```

Expected: after switching current warehouse, frontend stays on selected warehouse during refresh; backend restore/session APIs expose enough current-warehouse state for full reload and cross-device consistency.

Actual: switch endpoint returns warehouse 2, but subsequent `GET /users/me/warehouses` still only marks warehouse 1 as `isDefault=true` and exposes no current marker. Before frontend fix, the global refresh rebuilt the session from default warehouse and immediately reverted the UI to `默认仓库`.

Reproduction steps:

1. Log in as `admin / admin123`.
2. Open `我的`.
3. Switch warehouse from `默认仓库` to `测试仓库_1776335729379`.
4. Observe `PUT /users/me/warehouses/current` succeeds.
5. Observe frontend refresh calls `GET /users/me` and `GET /users/me/warehouses`.

Owner: frontend + backend contract

Status: fixed/verified

Verification:

- Added failing frontend regression test in `rims_frontend/test/features/auth/login_view_model_test.dart`.
- Targeted test failed before fix with current warehouse `1` instead of `2`.
- Fixed `AuthSessionController.refreshSession` to preserve the active warehouse when the restored warehouse list still contains it but lacks a current marker.
- Targeted and file-level tests pass:
  - `flutter test --no-pub test/features/auth/login_view_model_test.dart --plain-name "refreshSession preserves active warehouse when backend omits current marker"`
  - `flutter test --no-pub test/features/auth/login_view_model_test.dart`
- Backend follow-up remains: expose persisted current warehouse in restore/session data, or document that current warehouse is client-local and provide a frontend persistence contract.
- Backend fix:
  - `SwitchCurrentWarehouse` now persists the selected warehouse by clearing the old default binding and setting the selected warehouse as default.
  - Migration/state evidence after service restart:
    - `PUT /users/me/warehouses/current` with warehouse ID `2` returns `200`.
    - Subsequent `GET /users/me/warehouses` returns warehouse ID `2` with `isDefault: true` and warehouse ID `1` with `isDefault: false`.
    - Switching back to warehouse ID `1` returns `200`, and `GET /users/me/warehouses` restores warehouse ID `1` with `isDefault: true`.
  - Backend tests pass:
    - `go test ./internal/modules/warehouse`

### M8-B-002

Severity: P1

Module: backend role/permission authorization

Role: `m8_operator_20260707164313` / `user`

Warehouse: `默认仓库`

Endpoint:

- `GET /api/v1/roles`
- `GET /api/v1/permissions`

Expected: ordinary users cannot read role and permission management configuration unless explicitly granted.

Actual: ordinary user token can read full role list and full permission list. For comparison, `GET /api/v1/users` correctly returns `403 权限不足`.

Evidence:

```text
GET /api/v1/users        => 403 {"code":10002,"message":"权限不足"}
GET /api/v1/roles        => 200, includes admin role and all permissions
GET /api/v1/permissions  => 200, includes user/role/warehouse/product/inventory permissions
```

Reproduction steps:

1. Log in as `m8_operator_20260707164313 / M8Pass123`.
2. Use the returned bearer token to call `/roles` and `/permissions`.

Owner: backend

Status: fixed/verified

Verification:

- Backend API confirms operator identity:
  - User ID `92`
  - Role code `user`
  - Bound warehouse list contains only `默认仓库`.
- Frontend permission tests pass:
  - `flutter test --no-pub test/app_static_ui_test.dart --plain-name "documents tab hides admin-only workflows for operator"`
  - `flutter test --no-pub test/app_static_ui_test.dart --plain-name "regular user reports hide financial metrics"`
- Backend fix:
  - Added route permissions for `GET /roles`, `GET /roles/:id`, and `GET /permissions`.
  - Added migration `000013_role_read_permission_seed.sql` to seed `role:list`, `role:read`, and `permission:list` for admin.
  - After migration and service restart:
    - Operator `GET /roles` returns `403 权限不足`.
    - Operator `GET /permissions` returns `403 权限不足`.
    - Admin `GET /roles` returns `200`.
    - Admin `GET /permissions` returns `200`.
  - Backend tests pass:
    - `go test ./internal/modules/user`

### M8-C-001

Severity: P1

Module: backend inventory list/search

Role: admin

Warehouse: `默认仓库`

Endpoint: `GET /api/v1/inventory?keyword=sale_1776407432915&page=1&pageSize=20`

Expected: inventory list is filtered by keyword, and `list.length`/items are consistent with `total`.

Actual: response `total` is `1`, but `data.list` contains many unrelated inventory rows such as `rpt_inv_1776407517283`, `rpt_sale_1776407516702`, `stk_1776407515728`, etc. The target item `sale_1776407432915` appears inside the oversized list, but filtering is not applied to the returned page.

Reproduction steps:

1. Log in as `admin / admin123`.
2. Call `GET /api/v1/inventory?keyword=sale_1776407432915&page=1&pageSize=20`.
3. Compare `data.total` with the returned `data.list`.

Owner: backend

Status: fixed/verified

Verification:

- `GET /inventory/alerts` returns the low-stock sample:
  - Inventory ID `30`
  - Product code `sale_1776407432915`
  - Quantity `8`
  - Alert threshold `13`
- `GET /non-std-inventory` returns non-standard inventory rows.
- `PUT /inventory/30` as admin succeeds and updates `alertThreshold`.
- `PUT /inventory/30` as ordinary user returns `403 权限不足`.
- Frontend inventory tests pass:
  - `flutter test --no-pub test/features/inventory/inventory_view_model_test.dart test/features/inventory/inventory_remote_datasource_test.dart test/features/inventory/non_standard_inventory_models_test.dart`
- General transaction endpoint returns recent inventory transaction rows:
  - `GET /api/v1/transactions?page=1&pageSize=5` returned 5 rows from total `83`.
- Backend fix:
  - `inventoryRepo.ListByWarehouse` now reuses the keyword-filtered query for both `Count` and `Find`.
  - After service restart:
    - `GET /inventory?keyword=sale_1776407432915&page=1&pageSize=20` returns `total: 1`, `listCount: 1`, and product code `sale_1776407432915`.
  - Backend tests pass:
    - `go test ./internal/modules/product`

### M8-E-001

Severity: P1

Module: frontend reports datasource / backend report contract

Role: admin

Warehouse: `默认仓库`

Endpoint: `GET /api/v1/reports/sales/trend`

Request:

```text
GET /reports/sales/trend?startDate=2026-04-01&endDate=2026-07-07
```

Response:

```text
400 Bad Request
```

Expected: frontend sends all required backend query parameters for sales trend.

Actual: before fix, frontend sent only `startDate` and `endDate`; backend requires `bucket=day|week|month`.

Reproduction steps:

1. Log in as `admin / admin123`.
2. Open reports through the frontend or call the datasource path.
3. Observe sales trend request missing `bucket`.

Owner: frontend

Status: fixed/verified

Verification:

- Added failing regression assertion in `rims_frontend/test/features/reports/reports_remote_datasource_test.dart`.
- Targeted test failed before fix with query `bucket` equal to `null`.
- Fixed `ApiReportsRemoteDataSource.loadSalesTrend` to send `bucket=day`.
- Targeted report/home tests pass:
  - `flutter test --no-pub test/features/reports/reports_remote_datasource_test.dart`
  - `flutter test --no-pub test/features/reports/reports_view_model_test.dart test/features/home/home_view_model_test.dart`

### M8-F-001

Severity: P1

Module: backend warehouse management

Role: admin

Warehouse: `M8联调仓0707232747`

Endpoint:

- `POST /api/v1/warehouses`
- `POST /api/v1/warehouses/38/users`
- `DELETE /api/v1/warehouses/38`
- `GET /api/v1/users/me/warehouses`

Request:

```json
{"userIds":[93]}
```

Then:

```text
DELETE /api/v1/warehouses/38
```

Expected: deleting a warehouse with active user bindings is rejected with a conflict or validation error, and bound users keep their warehouse access.

Actual: backend returned `204` for deleting bound warehouse ID `38`; subsequent login as user ID `93` returned an empty `/users/me/warehouses` list.

Reproduction steps:

1. Create a warehouse through `POST /warehouses`.
2. Bind a user through `POST /warehouses/{id}/users`.
3. Delete the same warehouse through `DELETE /warehouses/{id}`.
4. Log in as the bound user and call `GET /users/me/warehouses`.

Owner: backend

Status: fixed/verified

Verification:

- To preserve continued Phase F testing, created replacement warehouse ID `39` and rebound user ID `93`.
- Re-login as `m8_f_user_0707232747` now returns warehouse ID `39` in `/users/me/warehouses`.
- Backend fix:
  - `WarehouseService.Delete` now checks active warehouse-user bindings before deleting and returns invalid-state when bindings exist.
  - After service restart:
    - Created warehouse ID `40`, bound admin user ID `1`, then `DELETE /warehouses/40` returned `422` with `仓库已绑定用户，无法删除`.
    - After `DELETE /warehouses/40/users/1`, `DELETE /warehouses/40` returned `204`.
  - Backend tests pass:
    - `go test ./internal/modules/warehouse`
