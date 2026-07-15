# RIMS M12 Production Security And Compliance Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Establish a locally provable production-security and privacy baseline with fail-closed environment/HTTPS rules, rotating device sessions, server-authoritative authorization, protected local data, redacted evidence, and autonomous security acceptance.

**Architecture:** Harden boundaries in dependency order: typed environment and transport policy, backend session authority, frontend credential coordination, authorization/data governance, then local attack-surface gates. Keep Flutter feature-first MVVM/repositories, keep backend policy in config/middleware/services, preserve M11 explicit foreground sync, and separate external production/legal approval from local PASS evidence.

**Tech Stack:** Flutter 3.44/Dart 3.12, Provider, GoRouter, Dio, secure storage, Drift/sqlite3mc, Android Emulator/Gradle, Go 1.25, Gin, GORM, PostgreSQL, JWT v5, PowerShell 5.1, WSL, Docker Compose, OpenSSL/local TLS proxy.

**Design:** `docs/superpowers/specs/2026-07-15-rims-m12-production-security-compliance-design.md`

**Frontend worktree:** `.worktrees/m12-production-security-compliance`

**Backend worktree:** `.worktrees/m12-backend-production-security-compliance/rims-goProgect`

**External boundary:** Production DNS/certificates, secret custody, legal approval, independent penetration testing, store declarations, and organizational signoff remain OPEN EXTERNAL and cannot be converted to local PASS.

---

## Program Invariants

- [ ] Non-local environments fail closed on HTTP, wildcard CORS, weak/default secrets, disabled DB TLS, public uploads, public Swagger, and auto migration.
- [ ] Credentials, OTPs, keys, DSNs, bodies, attachment bytes, personal fields, and absolute paths never appear in logs or reports.
- [ ] Database state, not JWT role text or Flutter visibility, is authorization authority.
- [ ] Refresh is single-use rotation; reuse revokes the family; account-security events invalidate affected sessions.
- [ ] M11 offline writes still require review plus explicit foreground confirmation.
- [ ] Local scripts own exact identities and restore trust, network, fixtures, and processes in `finally`.
- [ ] M12 exits with M9-M12 regression green and open P0/P1 equal to zero.

## Task 1: Baseline Security Inventory And Execution Record

**Files:**
- Create: `docs/superpowers/plans/2026-07-10-rims-m12-execution-record.md`
- Create: `docs/security/data-classification.md`
- Create: `docs/security/external-launch-checklist.md`
- Test: `rims_frontend/test/m12_architecture_test.dart`

- [x] **Step 1: Write RED architecture tests**

Require stable inventory rows for credentials, caches, drafts, outbox, attachments, scans, logs, exports, audit, providers, Android permissions, environment profiles, and external approvals. Each class must declare owner scope, encryption, backup, retention, clear trigger, export, and redaction.

Run: `flutter test --no-pub test/m12_architecture_test.dart` from `rims_frontend`.
Expected: FAIL because the M12 records do not exist.

- [x] **Step 2: Record observed baseline**

Pin frontend/backend base commits, tools, stopped state, and current JWT/config/CORS/Swagger/upload/logging/Android behavior. Mark unobserved exit rows `planned`.

- [x] **Step 3: Write classification and external records**

Use stable class IDs for access/refresh/TOTP credentials, identity, four cache groups, drafts, outbox, staged/server attachments, scans, runtime logs, server audit, account export, and test evidence. Record DNS/TLS, secret custody, DB backups, legal, penetration, signing/integrity/store, incident response, and rollout as `OPEN EXTERNAL`.

- [x] **Step 4: Run GREEN and commit**

Run architecture test and `git diff --check`. Commit: `docs: inventory M12 security boundaries`.

## Task 2: Backend Typed Environment And Fail-Closed Configuration

**Files:**
- Modify: backend `internal/config/config.go`
- Create: backend `internal/config/environment.go`
- Modify: backend `internal/config/config_test.go`
- Create: backend `internal/config/security_test.go`
- Modify: backend `.env.example`
- Modify: backend `internal/app/app.go`

- [x] **Step 1: Write RED profile table tests**

Cover `dev -> development`, four valid profiles, unknown rejection, non-local HTTP public URL, wildcard CORS, disabled DB TLS, auto migration, short/common JWT/data keys, public Swagger/uploads, empty/invalid trusted proxies, invalid token TTLs, and unsafe log format.

Define typed `Environment` with `IsLocal()`, `Config.ValidateSecurity()`, and a secret-free `SecuritySummary`.

- [x] **Step 2: Implement config**

Add `PUBLIC_BASE_URL`, `JWT_ISSUER`, `JWT_AUDIENCE`, `JWT_ACCESS_MINUTES`, `REFRESH_TOKEN_DAYS`, `AUTH_PEPPER`, `DATA_ENCRYPTION_KEY`, `TRUSTED_PROXY_CIDRS`, `SWAGGER_ENABLED`, `PUBLIC_UPLOADS_ENABLED`, `REQUIRE_HTTPS`, `PASSWORD_LOCK_MINUTES`, and `LOGIN_HISTORY_DAYS`. Unknown or unsafe non-local values fail before DB/router/listener creation.

- [x] **Step 3: Verify and commit**

Run `go test ./internal/config ./internal/app -count=1`, `go test ./...`, `go vet ./...`, and diff check. Commit: `feat: enforce backend environment security`.

## Task 3: Frontend Build Profile And API URL Policy

**Files:**
- Create: `rims_frontend/lib/core/config/app_environment.dart`
- Create: `rims_frontend/lib/core/network/api_url_policy.dart`
- Modify: `rims_frontend/lib/core/constants/api_constants.dart`
- Modify: `rims_frontend/lib/main.dart`
- Modify: `rims_frontend/lib/app.dart`
- Test: `rims_frontend/test/core/config/app_environment_test.dart`
- Test: `rims_frontend/test/core/network/api_url_policy_test.dart`

- [x] **Step 1: Write RED URL matrix**

Allow local HTTP only for explicit loopback/emulator/private development targets. Reject userinfo, fragments, queries, wrong API prefix, scheme-relative input, Unicode host confusion, unexpected ports, and all staging/production HTTP.

- [x] **Step 2: Implement typed bootstrap**

Read `APP_ENV`, `API_BASE_URL`, and `ALLOW_LOCAL_HTTP` once. Validate before `runApp`; inject typed config into tests and `ApiClient`. Managed scripts pass explicit development defines; release commands cannot inherit local override.

- [x] **Step 3: Verify and commit**

Run focused tests, full analyze, and diff check. Commit: `feat: enforce frontend environment policy`.

## Task 4: Trusted Proxy, HTTPS, HSTS, CORS, Swagger, And Upload Surface

**Files:**
- Create: backend `internal/middleware/transport_security.go`
- Create: backend `internal/middleware/transport_security_test.go`
- Modify: backend `internal/middleware/cors.go`
- Modify: backend `internal/app/router.go`
- Test: backend `internal/app/security_surface_test.go`
- Modify: backend `internal/modules/file/routes.go`

- [x] **Step 1: Write RED transport matrix**

Require non-local HTTP rejection, forwarded HTTPS only from trusted CIDR, spoof rejection, HTTPS-only HSTS, exact CORS origin matching, bounded preflight methods/headers, no credentialed wildcard, Swagger disabled outside local/test, no public static upload route, and authenticated file ACL.

- [x] **Step 2: Implement effective scheme and surface policy**

Parse CIDRs at startup; trust forwarding only from immediate trusted peer. Remove `r.Static("/uploads")` and keep provider object keys private. Gate Swagger by profile.

- [x] **Step 3: Verify and commit**

Run middleware/app/file tests and full Go suite. Commit: `feat: enforce backend transport boundaries`.

## Task 5: AI-Owned Local HTTPS Runtime

**Files:**
- Create: `scripts/lib/rims_local_tls.ps1`
- Modify: `scripts/lib/rims_local_common.ps1`
- Modify: `scripts/rims_local.ps1`
- Create: `scripts/test_rims_local_tls.ps1`
- Modify: `scripts/test_rims_local.ps1`
- Modify: `README.md`

- [x] **Step 1: Write RED wrapper tests**

Fake OpenSSL/ADB/process calls. Prove per-workspace CA/server cert, required SANs, ignored private-key paths, PID/start-time/port ownership, Android user-cert install/removal, pre-existing trust preservation, expired/wrong-host/untrusted rejection, first-failure cleanup, and unowned listener refusal.

- [x] **Step 2: Implement certificate/proxy lifecycle**

Use WSL OpenSSL; store secrets only under ignored `.runtime/rims-local/tls/`; record fingerprints, never key content. Own an HTTPS proxy to the verified backend and install/remove only the owned CA on an owned emulator.

- [x] **Step 3: Extend local commands**

Add `-UseLocalTls` to doctor/up/status/logs/smoke/down with safe JSON evidence. M12 requires it; older smokes retain explicit local HTTP until regression migration is proven.

- [x] **Step 4: Verify and commit**

Run both TLS and local wrapper self-tests. Commit: `feat: manage local HTTPS runtime`.

## Task 6: Backend Session Schema And Cryptographic Primitives

**Files:**
- Create: backend `migrations/000018_auth_sessions.sql`
- Create: backend `migrations/000019_login_security.sql`
- Create: backend `internal/auth/session_model.go`
- Create: backend `internal/auth/session_repository.go`
- Create: backend `internal/auth/session_repository_test.go`
- Modify: backend `internal/auth/jwt.go`
- Modify: backend `internal/auth/jwt_test.go`

- [x] **Step 1: Write RED migration/crypto tests**

Require token-family uniqueness, hashed refresh only, rotation parent, bounded device metadata, expiry/revocation/reuse, history indexes/retention, encrypted TOTP columns, hashed recovery codes, user token version, FKs, repeatable migration, and no plaintext token fixture.

- [x] **Step 2: Harden claims and refresh token**

JWT requires issuer, audience, subject, issued-at, not-before, expiry, JWT ID, session ID, token version, and exact HS256. Refresh uses 32 random bytes/base64url and stores only `HMAC-SHA256(AUTH_PEPPER, token)`.

- [x] **Step 3: Implement transactional repository**

Create/list/revoke sessions, consume-and-rotate once, detect reuse and revoke family, revoke account, update bounded safe last-use metadata, and prune. Concurrent rotation yields one successor.

- [x] **Step 4: Verify and commit**

Run focused tests, race rotation tests, migration checks, full suite, and diff check. Commit: `feat: persist rotating device sessions`.

Completed in backend commits `7f68bd5`, `dae6e34`, `c5431b4`, and `8f86fab`. Verification includes focused and race tests, repeatable real-PostgreSQL migration checks, real concurrent rotation/revocation coverage, the full Go suite, `go vet`, and diff checks.

## Task 7: Backend Login, Refresh, Logout, And Revocation APIs

**Files:**
- Modify: backend `internal/modules/user/dto.go`
- Modify: backend `internal/modules/user/service.go`
- Modify: backend `internal/modules/user/handler.go`
- Modify: backend `internal/modules/user/routes.go`
- Modify: backend `internal/middleware/auth.go`
- Create: backend `internal/modules/user/session_service_test.go`
- Create: backend `internal/modules/user/session_routes_test.go`

- [x] **Step 1: Write RED API tests**

Cover access/refresh/session login response, single-use refresh, concurrent refresh, reuse-family revocation, list/revoke one/others/all, idempotent logout, disabled/deleted account, token-version/password invalidation, expired/revoked middleware rejection, non-enumerating failures, and bounded device labels.

- [x] **Step 2: Implement routes**

Public `POST /auth/login` and `POST /auth/refresh`. Authenticated `POST /auth/logout`, `GET /auth/sessions`, `DELETE /auth/sessions/:id`, `POST /auth/sessions/revoke-others`, and `POST /auth/sessions/revoke-all`.

- [x] **Step 3: Invalidate sessions on security mutations**

Password change/reset, account disable/delete, and critical role mutation increment token version and revoke the required scope transactionally.

- [x] **Step 4: Verify and commit**

Run user/middleware/app tests and full Go suite. Commit: `feat: add rotating session APIs`.

Completed in backend commits `41f789c`, `595b68d`, `8b4fd10`, and `0373b4b`. Verification includes focused and race tests, the full Go suite and vet, strict public-auth body-limit tests, and a real-PostgreSQL matrix covering concurrent refresh, session commands, authority invalidation, lock ordering, transactional rollback, registration, and signing failures.

## Task 8: Frontend Versioned Credentials And Serialized Refresh

**Files:**
- Modify: `rims_frontend/lib/core/storage/app_secure_storage.dart`
- Modify: `rims_frontend/lib/core/network/interceptors/auth_interceptor.dart`
- Create: `rims_frontend/lib/features/auth/domain/entities/device_session.dart`
- Create: `rims_frontend/lib/features/auth/domain/services/session_refresh_coordinator.dart`
- Modify: `rims_frontend/lib/features/auth/data/datasources/auth_remote_datasource.dart`
- Modify: `rims_frontend/lib/features/auth/data/repositories/auth_repository_impl.dart`
- Modify: `rims_frontend/lib/features/auth/domain/repositories/auth_repository.dart`
- Test: `rims_frontend/test/features/auth/session_refresh_coordinator_test.dart`
- Test: `rims_frontend/test/core/storage/app_secure_storage_test.dart`

- [x] **Step 1: Write RED credential/refresh tests**

Cover v3 migration, owner/session identity, atomic access+refresh commit, ten concurrent 401s -> one refresh, one replay per safe request, failure clearing, storage failure after rotation, logout/revoke race, stale generation, queued-write non-replay, and no credential in Drift.

- [x] **Step 2: Implement secure record v3**

Store access/refresh, account/session IDs, expiries, token version, generation, and biometric policy in one strict owner-bound record. Malformed/unsupported records produce typed restore failure and clear safely.

- [x] **Step 3: Implement serialized coordinator**

Replay only idempotent reads or requests already carrying a stable idempotency key. Offline outbox refreshes only inside an explicit Sync Center command. Preserve pending revocation and M11 cleanup ordering.

- [x] **Step 4: Verify and commit**

Run storage/auth tests, full analyze, and diff check. Commit: `feat: rotate frontend device credentials`.

Completed in frontend commits `dcf5e10`, `c7959ce`, `3f8e8a2`, `0edbf0b`, `ada7ad1`, `44e5caf`, `6a2fc50`, `54f26bf`, `413a273`, `da35fdc`, `c235953`, `de00f4f`, `12067f7`, and `3f5d91b`. The final design uses a shared reentrant auth lifecycle gate, stable token/credential/epoch leases, structured session cleanup markers with legacy migration, conditional credential cleanup, repeatable-body replay, and redacted typed transport failures. Independent verification passed 148 focused lifecycle/restart tests, `flutter analyze --no-pub`, all 1390 Flutter tests, and `git diff --check`; independent specification and quality reviews both approved the result with no remaining Critical or Important findings.

## Task 9: Device Session Management UI

**Files:**
- Create: `rims_frontend/lib/features/auth/presentation/view_models/device_sessions_view_model.dart`
- Create: `rims_frontend/lib/features/auth/presentation/pages/device_sessions_page.dart`
- Modify: `rims_frontend/lib/features/profile/presentation/pages/profile_page.dart`
- Modify: `rims_frontend/lib/routes/route_paths.dart`
- Modify: `rims_frontend/lib/routes/app_router.dart`
- Test: `rims_frontend/test/features/auth/device_sessions_view_model_test.dart`
- Test: `rims_frontend/test/features/auth/device_sessions_page_test.dart`

- [ ] **Step 1: Write RED state/widget tests**

Require current marker, safe device/platform/time display, confirm revoke, revoke others/all, current revoke -> login, retained data on refresh failure, one busy gate, no precise IP, touch/semantics/keyboard/narrow/large-text/light/dark coverage.

- [ ] **Step 2: Implement repository-driven page**

ViewModel uses auth repository only and generation guards all commands. Current/all revocation routes through session controller and M11 ownership cleanup. Add compact profile security entry.

- [ ] **Step 3: Verify and commit**

Run auth/profile widgets and analyze. Commit: `feat: manage authenticated devices`.

## Task 10: Password Policy, Login Throttling, Lockout, And History

**Files:**
- Create: backend `internal/security/password_policy.go`
- Create: backend `internal/security/login_guard.go`
- Create: backend `internal/security/password_policy_test.go`
- Create: backend `internal/security/login_guard_test.go`
- Modify: backend `internal/modules/user/service.go`
- Modify: backend `internal/modules/user/handler.go`
- Create: backend `internal/modules/user/login_history_routes_test.go`
- Modify: `rims_frontend/lib/features/auth/presentation/view_models/login_view_model.dart`
- Modify: `rims_frontend/lib/features/profile/presentation/view_models/profile_security_view_model.dart`

- [ ] **Step 1: Write RED policy/abuse tests**

Use injected clock. Cover 12-128 length, username inclusion, Unicode normalization, local seed restriction outside local/test, compromised blocklist, generic absent/wrong/locked/disabled result, bounded delay, persisted lock expiry/reset, privacy network key, history categories/retention, and no credentials.

- [ ] **Step 2: Implement server authority**

Apply policy to create/change/reset. Persist guard state for multi-process behavior. Add current-account paginated `GET /auth/login-history`; cross-account admin access requires explicit permission and audit.

- [ ] **Step 3: Add frontend ergonomic validation**

Frontend checks length/match but backend remains authority. Clear password fields on terminal submit/dispose and never persist them.

- [ ] **Step 4: Verify and commit per repository**

Backend commit: `feat: enforce login security policy`. Frontend commit: `feat: surface server password policy`.

## Task 11: Optional TOTP, Recovery Codes, And Biometric Unlock

**Files:**
- Create: backend `internal/security/totp.go`
- Create: backend `internal/security/secret_cipher.go`
- Create: backend `internal/security/totp_test.go`
- Modify: backend user auth service/handler/routes/DTOs
- Create: `rims_frontend/lib/core/security/local_authenticator.dart`
- Create: `rims_frontend/lib/features/auth/presentation/view_models/two_factor_view_model.dart`
- Create: `rims_frontend/lib/features/auth/presentation/pages/two_factor_page.dart`
- Modify: auth/profile routes and repository contracts
- Test: frontend `rims_frontend/test/features/auth/two_factor_view_model_test.dart`
- Test: frontend `rims_frontend/test/core/security/local_authenticator_test.dart`

- [ ] **Step 1: Write RED backend tests**

Cover pending enrollment, activation proof, encrypted secret, one-time recovery display, hashed recovery storage, bounded one-step skew, accepted-counter replay rejection, login challenge, recovery consumption, disable/regenerate with password+factor, account/session invalidation, and deterministic test clock/key.

- [ ] **Step 2: Implement TOTP APIs**

Add enrollment begin/confirm, recovery regenerate, disable, and challenge completion. Never log or return stored secret after activation.

- [ ] **Step 3: Write RED biometric adapter tests**

Biometric may release an owner-bound credential only after OS success. It cannot create/extend a server session, bypass TOTP, or use revoked/expired credentials. Unsupported/failure returns full-login path.

- [ ] **Step 4: Implement UI/adapters**

Keep platform API behind `LocalAuthenticator` and inject fakes. Add profile 2FA/device security controls with accessible states and no secret persistence outside secure storage.

- [ ] **Step 5: Verify and commit per repository**

Backend: `feat: add optional second factor`. Frontend: `feat: add secure local unlock`.

## Task 12: Declarative Route Authorization Inventory

**Files:**
- Create: backend `internal/app/route_security.go`
- Modify: backend feature `routes.go` files
- Create: backend `internal/app/route_security_test.go`
- Modify: backend `internal/middleware/permission.go`
- Test: backend permission route suites

- [ ] **Step 1: Write RED complete-route inventory test**

Every Gin route declares public/authenticated, permission code, warehouse scope, idempotency, and sensitive-field class. Public allowlist is health plus enabled auth entry routes. A synthetic undeclared route must fail.

- [ ] **Step 2: Implement declarations without moving business logic**

Feature route files register through typed helpers. Runtime middleware still enforces checks; inventory supports tests and safe diagnostics only.

- [ ] **Step 3: Add stale-authority regression**

Cover role mutation, permission removal/re-add, warehouse unbind, account disable, session revoke, token version, guessed IDs, audit/idempotency/admin endpoints, and ordinary-user denial.

- [ ] **Step 4: Verify and commit**

Run app/middleware/all module tests and full suite. Commit: `feat: declare route security contracts`.

## Task 13: Financial Field And Attachment Data Protection

**Files:**
- Modify: backend report/product/document/file DTOs, services, and routes
- Create: backend `internal/security/field_policy.go`
- Create: backend `internal/security/field_policy_test.go`
- Test: backend module field/ACL suites
- Modify: frontend report/inventory/admin model parsing tests

- [ ] **Step 1: Write RED matrix**

Test admin, financial-capability user, ordinary user, cross-warehouse user, disabled resource, guessed attachment/document IDs, list/detail/download, idempotency status, and export. Denied fields must be omitted, not zero-valued as if authoritative.

- [ ] **Step 2: Implement centralized field policy**

Server serializers use actual permission context. Remove public object URLs and expose authenticated download endpoints only. Cache keys/fingerprints include financial capability so stale privileged data cannot cross permission changes.

- [ ] **Step 3: Tighten frontend strict parsing**

Models accept explicit omission for denied fields but reject malformed partial financial payloads. Permission loss invalidates protected cache/report/UI state.

- [ ] **Step 4: Verify and commit per repository**

Backend: `feat: protect financial and attachment data`. Frontend: `fix: enforce protected field boundaries`.

## Task 14: Structured Redaction And Security Audit Events

**Files:**
- Create: backend `internal/security/redactor.go`
- Create: backend `internal/security/redactor_test.go`
- Modify: backend `internal/middleware/logger.go`
- Modify: backend audit constants/services
- Create: `rims_frontend/lib/core/security/sensitive_data_redactor.dart`
- Modify: frontend network logging interceptor
- Test: frontend `rims_frontend/test/core/security/sensitive_data_redactor_test.dart`

- [ ] **Step 1: Write recursive/property tests**

Redact auth/cookie headers, password/OTP/recovery names, JWT/refresh patterns, query secrets, multipart/body bytes, personal fields, attachment content, paths, nested maps/lists, exceptions, and malformed values. Preserve trace ID, safe category, status, duration, environment, and hashed entity reference.

- [ ] **Step 2: Implement fail-closed redactors**

Unsafe or unrecognized structured fields are dropped. Debug mode cannot bypass. Backend login/session/TOTP/reuse/lockout/revoke events use safe reason categories and transaction/audit rules.

- [ ] **Step 3: Verify and commit per repository**

Run logging/security/audit suites plus scans for raw logging calls. Backend commit: `feat: redact security telemetry`. Frontend: `feat: centralize sensitive data redaction`.

## Task 15: Privacy, Retention, Export, And Deletion Procedures

**Files:**
- Create: `docs/security/privacy-notice-draft.md`
- Create: `docs/security/permission-purpose.md`
- Create: `docs/security/sdk-inventory.md`
- Create: `docs/security/retention-and-deletion.md`
- Create: `docs/security/account-export-deletion-procedure.md`
- Add backend retention/export services and tests
- Add frontend profile privacy ViewModel/page and tests

- [ ] **Step 1: Write RED document/registry tests**

Require every runtime permission, SDK/license/data purpose, data class, retention clock, deletion trigger, immutable audit exception, backup/provider owner, export eligibility, external approver, and local evidence.

- [ ] **Step 2: Implement retention jobs**

Prune login history, sessions, idempotency, deleted files, generic storage cleanup, and audit only according to configured policy. Inject clock; serialize cleanup; preserve legal/audit exceptions explicitly.

- [ ] **Step 3: Implement current-account export**

Generate a bounded archive/JSON with eligible profile, session/login history, and owned business references. Exclude credentials, keys, unauthorized financial fields, attachment bytes unless explicitly selected, other accounts/warehouses, and unredacted logs. Deletion remains a verified request/procedure when business/audit constraints prevent immediate erasure.

- [ ] **Step 4: Add privacy UI**

Profile exposes privacy/data controls, export progress/result, clear-local-data links, and deletion-request status. No explanatory marketing panels or nested cards.

- [ ] **Step 5: Verify and commit docs/backend/frontend separately**

Use commits `docs: define privacy governance`, `feat: enforce security retention`, and `feat: add privacy data controls`.

## Task 16: Android Screenshot, Backup, Integrity, And Debug Policy

**Files:**
- Modify: Android manifests and XML security resources
- Create: Android Kotlin policy plugin/channel files
- Create: `rims_frontend/lib/core/security/device_security_policy.dart`
- Modify: sensitive auth/profile/sync pages
- Modify: `rims_frontend/test/m12_architecture_test.dart`
- Create: `rims_frontend/test/core/security/device_security_policy_test.dart`

- [ ] **Step 1: Write RED static/unit tests**

Require backup exclusions for secure/offline/staging/evidence data, release cleartext false, minimal permissions, production screenshot protection default-on for login/session/TOTP/export/sync conflict, local debug configurability, provider-based integrity/anti-debug signals, and no production bypass define.

- [ ] **Step 2: Implement platform policy**

Use `FLAG_SECURE` through a narrow channel and lifecycle-safe reference counting. Integrity/anti-debug are provider interfaces with local fakes; policy can block sensitive operations but real store attestation remains OPEN EXTERNAL.

- [ ] **Step 3: Verify Android artifacts**

Run architecture/security widgets, analyze, debug and release APK builds, `apkanalyzer` manifest inspection, and unzip/string scans for local URLs, secrets, debug bypasses, and backup mistakes.

- [ ] **Step 4: Commit**

Commit: `feat: enforce Android security policy`.

## Task 17: Local Secret, Dependency, Static, And Abuse Gates

**Files:**
- Create: `scripts/rims_security_gate.ps1`
- Create: `scripts/test_rims_security_gate.ps1`
- Create: `scripts/security/allowlisted_test_secrets.json`
- Create: backend `scripts/security_gate.sh`
- Modify: `scripts/rims_smoke.ps1`
- Modify: both READMEs

- [ ] **Step 1: Write RED wrapper self-tests**

Fixtures must prove secret-pattern detection, entropy candidate review, tracked key/certificate rejection, known test-secret allowlist scoping, generated-file scan, dependency inventory output, disallowed dependency/license detection, `go vet`/Flutter analyze failure propagation, route inventory, Android manifest/APK checks, redacted report, and first-failure exit/cleanup.

- [ ] **Step 2: Implement offline-capable gates**

Use repository-native tools and pinned local metadata. Never auto-ignore a finding. Reports include hashes/package versions and safe paths, not secret values. Online vulnerability databases may augment but cannot be the only local gate.

- [ ] **Step 3: Integrate smoke**

`rims_smoke` runs format/analyze/tests/demo scan/security gate/diff check. Backend gate runs test/vet/build/migration/seed/secret/dependency/route checks.

- [ ] **Step 4: Verify and commit per repository**

Run self-tests twice from clean stopped state. Commits: `test: add local security gates` and backend `test: enforce backend security gate`.

## Task 18: M12 HTTPS Security Acceptance And Milestone Exit

**Files:**
- Create: `rims_frontend/integration_test/m12_security_test.dart`
- Create: `scripts/rims_m12_smoke.ps1`
- Create: `scripts/test_rims_m12_smoke.ps1`
- Modify: Android smoke/local scripts
- Modify: M12 execution record, plan, master plan, READMEs, backend README

- [ ] **Step 1: Write RED aggregate validator self-tests**

Reject wrong/missing Boolean types, malformed commits/fingerprints/hashes, HTTP success in non-local profile, unowned proxy/cert/listener, duplicate refresh successor, reuse not revoking family, stale session accepted, lockout bypass, TOTP replay, authorization/field/attachment leak, log secret, export leak, backup/screenshot violation, missing external item, failed baseline restore, or cleanup residue.

- [ ] **Step 2: Implement real stopped-state journey**

AI starts PostgreSQL/backend, local CA/HTTPS proxy, named AVD, installs trust, seeds fixtures, and runs: trusted HTTPS; direct/spoofed/untrusted rejection; login/refresh/concurrent reuse; session list/revoke/logout; password/lockout/history; optional TOTP/recovery; biometric fake boundary; role/warehouse/financial/file attacks; log/export redaction; encrypted local records; screenshot/backup policy; process recreation; and exact cleanup.

- [ ] **Step 3: Record strict evidence**

Report exact frontend/backend commits, environment/config hashes, CA fingerprint, owned PID/start times/ports, access/refresh TTLs, rotation/reuse counts, lockout timing, TOTP replay result, authorization matrix counts, redaction/export scan counts, dependency inventory hashes, Android artifact hashes, fixture counts, baseline restore, and cleanup. Never report raw credentials or keys.

- [ ] **Step 4: Run regression and final gates**

From stopped state run wrapper self-tests, M9 Web/Android, M10, M11, M12, Flutter pub/build_runner/format/analyze/test/debug+release builds, backend test/vet/temp build/migration/seed/security gate, diff checks, clean statuses, and stopped runtime status.

- [ ] **Step 5: Defect audit and docs**

Record every P0/P1/P2/P3 with reproducer, tested commits, owner, resolution, and retest. M12 exits only with open P0/P1 zero. External checklist remains OPEN EXTERNAL and is linked, not marked PASS.

- [ ] **Step 6: Commit, fast-forward merge, and push**

After all gates pass, commit evidence in both repositories, verify main ancestry and clean workspaces, fast-forward both mains, rerun merged tests, push, and mark Task 18 complete.

---

## Final Gate Commands

Frontend root:

    powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\test_rims_local.ps1
    powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\test_rims_local_tls.ps1
    powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\test_rims_security_gate.ps1
    powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\test_rims_m12_smoke.ps1
    powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\rims_m12_smoke.ps1 -AndroidDevice $env:RIMS_ANDROID_DEVICE -BackendDir $env:RIMS_BACKEND_DIR -BackendWorkspaceRoot $env:RIMS_BACKEND_WORKSPACE_ROOT -Output Json

Flutter root:

    flutter pub get --offline
    dart run build_runner build --delete-conflicting-outputs
    dart format --output=none --set-exit-if-changed lib test integration_test test_driver
    flutter analyze --no-pub
    flutter test --no-pub
    flutter build apk --debug --no-pub
    flutter build apk --release --no-pub

Backend WSL:

    ~/local/go/bin/go test ./...
    ~/local/go/bin/go vet ./...
    build_output=$(mktemp /tmp/rims-server.XXXXXX)
    trap 'rm -f -- "$build_output"' EXIT
    ~/local/go/bin/go build -o "$build_output" ./cmd/server
    bash scripts/test_m9_dev_seed.sh
    bash scripts/security_gate.sh

Repository/runtime:

    git diff --check
    git status --short
    powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\rims_local.ps1 -Command status -Output Json

M12 is locally complete only when these commands and the real M12 report pass, P0/P1 is zero, services are stopped, repository scope is clean, and all remaining production/legal actions are explicitly OPEN EXTERNAL.
