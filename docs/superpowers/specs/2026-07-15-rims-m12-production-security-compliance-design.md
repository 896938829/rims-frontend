# RIMS M12 Production Security And Compliance Design

Status: APPROVED PROGRAM DESIGN REFINEMENT

This design refines the already approved long-term completion design for M12.
It preserves the program rule that an AI worker must be able to implement and
verify every local control without a cloud account. Production certificates,
secret custody, legal approval, penetration testing, and organizational signoff
remain explicit external launch actions and are never represented as locally
complete.

## 1. Objective And Exit

M12 establishes a locally provable security and privacy baseline for a RIMS APP
that will later connect to a public-cloud deployment.

M12 exits when:

- development, test, staging, and production profiles have fail-closed rules;
- HTTP is accepted only by explicit local/debug profiles and non-local profiles
  require HTTPS end to end;
- access credentials are short-lived, refresh credentials rotate, sessions can
  be listed and revoked, and replay/reuse is detected;
- password policy, login throttling, lockout, login history, and optional TOTP
  second factor have server-authoritative behavior;
- optional biometric unlock releases only a locally stored credential and never
  substitutes for server authentication or an expired/revoked session;
- every protected backend route has explicit authentication, permission,
  warehouse, field, and financial-data rules;
- local records, attachments, logs, reports, exports, and support evidence obey
  data classification, redaction, retention, and deletion contracts;
- dependency, secret, static, authorization, replay, abuse, and Android security
  gates run locally from a stopped state;
- M9, M10, and M11 acceptance remains green and open P0/P1 is zero; and
- external legal and production-security actions are recorded separately.

## 2. Approach

Three approaches were considered:

1. **Boundary-first incremental hardening (selected).** Establish environment,
   transport, configuration, and route inventories before changing sessions,
   then add privacy and gates. This keeps each security invariant independently
   testable and limits regressions to one boundary at a time.
2. **Authentication-first replacement.** Replace JWT behavior immediately, then
   retrofit environment and authorization. This reduces token risk early but can
   accidentally test new sessions through an unsafe transport/configuration
   surface.
3. **Single security rewrite.** Change transport, sessions, authorization,
   storage, and UI together. This has the shortest apparent schedule but gives
   poor defect attribution and an unacceptable rollback surface.

The selected sequence is M12-A environment and transport, M12-B session and
device security, M12-C authorization and privacy, then M12-D automated security
acceptance. Each phase is usable and testable before the next begins.

## 3. Security Boundaries

### 3.1 Environment Identity

The backend owns a typed environment profile: `development`, `test`, `staging`,
or `production`. Legacy `dev` maps only to `development`. Unknown values fail
startup. A non-local profile rejects wildcard CORS, disabled database TLS,
default/short secrets, auto migration, public Swagger, public upload serving,
and an HTTP public base URL.

The frontend receives a typed build profile and API URL through compile-time
defines. Debug local builds may use loopback or the Android emulator host alias
over HTTP only when the local profile explicitly allows it. Staging and
production builds reject HTTP, userinfo, fragments, unexpected path prefixes,
and non-HTTPS WebSocket endpoints before constructing `ApiClient`.

Configuration reports expose only safe facts: environment name, feature state,
host category, and hashed configuration identity. They never include passwords,
JWT keys, refresh tokens, database DSNs, local file paths, or certificate keys.

### 3.2 Transport

The application server remains capable of running plain HTTP behind a trusted
local reverse proxy, but forwarded scheme and client address are accepted only
from configured proxy CIDRs. Non-local profiles require an observed HTTPS
scheme and emit HSTS on HTTPS responses. CORS uses an exact origin allowlist;
credentials and wildcard origins cannot be combined.

The managed local controller owns a development certificate authority,
certificate, HTTPS proxy, Android trust installation, ports, and cleanup. Keys
live below ignored `.runtime/`, are generated per local workspace, and are never
committed. M12 acceptance proves a successful trusted HTTPS path and rejection
of direct HTTP, spoofed forwarded headers, wrong host, expired/untrusted
certificate, and unowned listeners.

### 3.3 Authentication And Sessions

Access tokens remain signed JWTs but become short-lived and include issuer,
audience, subject, issued-at, not-before, expiry, JWT ID, session ID, and token
version. The backend accepts only the configured algorithm and current signing
key identity. Role and permissions continue to be refreshed from the database;
JWT role text is not authorization authority.

Refresh tokens are opaque 256-bit random values. Only a keyed hash is stored.
Each login creates a device session with account, device label, platform, token
family, creation/use/expiry/revocation timestamps, safe network metadata, and a
server-generated ID. Refresh is single-use rotation in one transaction. Reuse
revokes the token family and records a security event. Logout revokes the active
session before local credentials are cleared. Password change, admin reset,
account disable, and explicit "revoke all" invalidate existing sessions.

The APP stores access and refresh credentials in secure storage as one versioned
owner-bound transaction. Refresh is serialized and generation-guarded. Requests
that receive an authentication failure may attempt at most one refresh and one
replay when the request is replay-safe. Offline queued writes do not refresh or
submit automatically; Sync Center revalidates the session after explicit user
confirmation.

### 3.4 Password, Abuse, And Second Factor

The backend enforces one password policy for login-related mutations: minimum
length 12, maximum length 128, no username inclusion, no known local seed value
outside local/test profiles, and rejection of a small versioned compromised
password blocklist. Password material is never logged or persisted outside the
existing adaptive password hash.

Failed login attempts are counted by normalized account and a privacy-preserving
network key. Bounded exponential delay and temporary account lockout apply with
test-injected clocks. Responses do not disclose whether an account exists.
Successful and failed attempts create redacted login-history records with reason
categories, not passwords or raw tokens.

TOTP is optional per account. Enrollment creates a pending secret, requires one
valid code before activation, and returns recovery codes once. Secrets and
recovery codes are encrypted at rest with an injected application key; recovery
codes are stored hashed. Disabling or regenerating requires password plus a
current TOTP/recovery proof. Local development can use a deterministic clock and
test key, never a hard-coded production key.

Biometric unlock is optional and adapter-based. It may release the owner-bound
secure credential record after OS authentication. It cannot create a session,
extend expiry, bypass TOTP, or recover a revoked refresh family. Unsupported or
failed biometric checks fall back to full server login.

### 3.5 Authorization And Data Exposure

All routes are registered through a contract inventory that declares public,
authenticated, permission, warehouse, and idempotency requirements. Tests fail
when a new route lacks a declaration. Public routes are limited to health and
enabled authentication entry points. Swagger is disabled outside local/test.

`/uploads` is removed as a public static route. Files are downloaded only
through the authenticated file handler after resource and warehouse checks.
Backend serializers omit cost, financial, secret, session, and audit fields
unless the caller has the explicit capability. UI hiding remains ergonomic only;
server middleware and services remain authoritative.

Permission refresh, warehouse rebinding, role mutation, account disable, token
version change, and session revocation invalidate stale authority. Regression
tests cover ordinary user, warehouse crossing, disabled entity, guessed ID,
field-level financial access, attachment access, idempotency status, audit logs,
and admin configuration endpoints.

### 3.6 Local Data, Logs, And Privacy

The M11 encrypted Drift database and secure-storage key lifecycle remain the
local persistence foundation. M12 adds a versioned data-classification registry
for secure credentials, cached references, inventory, documents, reports,
drafts, outbox payloads, staged attachments, scans, logs, exports, and runtime
evidence. Each class defines owner scope, encryption, backup exclusion,
retention, clear trigger, export eligibility, and redaction.

Logs use structured safe fields. Redactors cover authorization/cookie headers,
password and OTP fields, JWT/refresh patterns, query secrets, multipart bodies,
personal fields, attachment content, absolute paths, and nested maps/lists.
Trace IDs, safe operation categories, status, duration, environment, and hashed
entity references remain available. Debug logging cannot weaken redaction.

Privacy artifacts include a permission-purpose inventory, third-party SDK and
license inventory, data-flow and retention matrix, account export/deletion
procedure, backup/restore ownership, and an external approval checklist. Local
export tests prove only eligible user data is exported and the archive contains
no credentials, encryption keys, cost fields without permission, attachment
bytes without explicit selection, or unredacted logs.

Android backup rules continue to exclude the offline database, secure storage,
staging, and support evidence. Screenshot protection is controlled by a
production-default-on policy for sensitive screens. Integrity and anti-debug
signals are provider interfaces: local fakes prove policy decisions, while real
store/device attestation activation remains an external release action.

## 4. Components And Ownership

Frontend additions remain under `core/config`, `core/network`, `core/security`,
`core/privacy`, and feature-first auth/profile presentation. Authentication
repositories own session API calls; a session coordinator owns refresh
serialization; pages render state and invoke ViewModels. No page reads secure
storage, constructs URLs, or interprets Dio failures.

Backend additions remain under `internal/config`, `internal/auth`,
`internal/security`, `internal/middleware`, and the user module. Database schema
owns device sessions, refresh rotation, login history, TOTP enrollment, recovery
codes, and token-version invalidation. Route declarations are centralized enough
for contract inspection without moving feature business logic out of modules.

Local orchestration extends the existing ownership model. M12 scripts own only
their generated CA/certificates, proxy, backend, AVD, trust changes, fixtures,
reports, and exact PID/start-time identities. Cleanup restores trust/network and
baseline data in `finally` and refuses ambiguous ownership.

## 5. Error And Recovery Rules

- Configuration violations fail startup/build before accepting requests.
- Refresh rotation uses one database transaction and never returns two valid
  descendants for the same token.
- Secure-storage commit failure leaves the old credential usable only when the
  server has not rotated it; otherwise the APP clears local auth and requires
  login rather than guessing.
- Authentication and lockout responses are deliberately non-enumerating.
- TOTP clock skew is bounded to one adjacent time step and replay of an accepted
  counter is rejected.
- Authorization denial never falls back to cache for protected financial or
  administrative fields.
- Redaction failure drops the unsafe field/event instead of logging raw data.
- HTTPS proxy or trust cleanup failure is a failed acceptance result with exact
  recovery instructions; unrelated certificates and listeners are untouched.

## 6. Verification Strategy

TDD covers typed configuration, URL policy, forwarded-header trust, CORS/HSTS,
JWT claims, refresh rotation/reuse, session revocation, password policy,
lockout, login history, TOTP/recovery codes, biometric adapter behavior, route
inventory, financial fields, attachment ACLs, classification, redaction,
retention, export, Android manifests, and script ownership.

The M12 local smoke starts from stopped state and records Boolean/numeric evidence
for HTTPS, environment rejection, session rotation, replay detection, revocation,
lockout recovery, optional TOTP, permission boundaries, log/secret scans,
encrypted local data, export redaction, Android backup/screenshot policy,
baseline restore, and exact cleanup. It then runs M9 Web/Android, M10, and M11
regression against the same frontend/backend identities.

Required final gates include Flutter format/analyze/test/build, Go test/vet/build,
migration upgrade/repeat/rollback checks where supported, deterministic seed
tests, secret and generated-artifact scans, dependency inventory/policy checks,
Android manifest and APK inspection, `git diff --check`, clean repository scope,
and stopped runtime status.

## 7. External Launch Checklist

The following remain OPEN EXTERNAL after local M12 completion:

- production domain, DNS, CA-issued certificate, load balancer, and HSTS preload;
- production secret manager custody, signing/encryption key rotation, escrow, and
  recovery approval;
- production database TLS identity, encrypted backups, restore drill, and data
  residency approval;
- legal privacy notice, terms, processor/subprocessor, retention, export, and
  deletion approval;
- production SAST/DAST, independent penetration test, risk acceptance, and
  incident-response ownership;
- Android signing identity, Play Integrity activation, store data-safety and
  account-deletion declarations; and
- organizational MFA policy, support verification, on-call, and breach
  communication approval.

These actions are evidence requirements for external launch, not blockers for
the local autonomous M12 loop.
