# RIMS M12 Execution Record

Status: IN PROGRESS

This record separates observations from planned controls. An `OBSERVED` row is
a local baseline fact read from the named commit or command. Every unimplemented
M12 control remains `PLANNED - NOT YET EVIDENCE`; no planned row is launch or
production PASS evidence.

## Baseline Identity

| Item | Observed value | Evidence state |
| --- | --- | --- |
| Frontend base | `2bc1287290f8e09c8b0a4fed8bbfaa7ebb45ded5` (`2bc1287`) | OBSERVED from repository history |
| Backend base | `5ba6e1f68927e5bdab1e9dd2b42abaeb9a16b763` (`5ba6e1f`) | OBSERVED from backend repository history |
| Frontend toolchain | Flutter 3.44.1; Dart 3.12.1 | OBSERVED from `flutter --version` |
| Backend toolchain | Go 1.25.0 linux/amd64 | OBSERVED from `~/local/go/bin/go version` in WSL |
| Record worktree head before Task 1 | `3ea94079d8ebeb89816a2d0f122ddae4176daf12` | OBSERVED from `git rev-parse HEAD`; this is not the inherited frontend base |

## Stopped-State Observation

Observed on 2026-07-15 before Task 1 implementation:

| Probe | Observed result | Evidence state |
| --- | --- | --- |
| Managed local runtime | No managed backend state exists; port 8080 is not listening. | OBSERVED from `scripts/rims_local.ps1 -Command status -Output Json`; stopped status intentionally returned exit 1 |
| Android target | No Android device or emulator attached. | OBSERVED from `adb devices`; only the header was present |
| Production infrastructure | No production DNS, TLS, secret manager, database, signing, store, legal, penetration-test, incident, or rollout evidence was inspected locally. | OPEN EXTERNAL in `docs/security/external-launch-checklist.md` |

## Observed Pre-M12 Backend Surface

These rows describe the backend base commit. They are gaps to be addressed by
later tasks, not statements that an M12 control is already implemented.

| Boundary | Observed base behavior | M12 disposition |
| --- | --- | --- |
| Environment/config | `APP_ENV` is an untyped string defaulting to `dev`; DB TLS defaults to `disable`; auto migration defaults true; no complete non-local fail-closed validation exists. | PLANNED - NOT YET EVIDENCE |
| JWT/session | HS256 access JWT contains user/role fields plus issued-at and expiry; default lifetime is 24 hours. It has no issuer, audience, subject, not-before, JWT ID, session ID, token version, rotating refresh family, or reuse response. Middleware does reload current user and role from the database after token parsing. | PLANNED - NOT YET EVIDENCE |
| Secret validation | `DB_PASSWORD` and `JWT_SECRET` must be non-empty, but weak/default-value rejection, external custody, rotation, recovery, refresh pepper, and data-encryption key policy are absent. | PLANNED - NOT YET EVIDENCE |
| CORS/transport | CORS defaults to wildcard and permits a fixed method/header set. The app has no typed HTTPS requirement, trusted-proxy policy, forwarded-scheme validation, redirect, or HSTS control. | PLANNED - NOT YET EVIDENCE |
| Swagger | `/swagger/*any` is registered without an environment gate. | PLANNED - NOT YET EVIDENCE |
| Uploads | `/uploads` is served as a public static directory even though authenticated file handlers also exist. | PLANNED - NOT YET EVIDENCE |
| Runtime logging | Request logging emits trace ID, method, URL path, status, latency, and current user ID. It does not log query/body in this middleware, but there is no centralized recursive sensitive-data redactor or structured fail-closed sink policy. | PLANNED - NOT YET EVIDENCE |

## Observed Pre-M12 Android Surface

| Boundary | Observed base behavior | M12 disposition |
| --- | --- | --- |
| Runtime permissions | Main manifest declarations are `android.permission.INTERNET` and `android.permission.CAMERA`; effective merged permissions are those two plus `android.permission.ACCESS_NETWORK_STATE` contributed by locked `connectivity_plus` 7.1.1; camera hardware is optional. | OBSERVED inventory; purpose and denial rules are recorded in the classification registry |
| Backup and transport | Main application declares `android:allowBackup="false"`, `android:fullBackupContent="false"`, data extraction rules, and `android:usesCleartextTraffic="false"`. | OBSERVED baseline; artifact verification remains PLANNED - NOT YET EVIDENCE |
| Screenshot/debug/integrity/store | No M12 `FLAG_SECURE` policy, production integrity provider, anti-debug decision, signing custody evidence, or store approval was established by this task. | PLANNED - NOT YET EVIDENCE; signing, integrity activation, and store review remain OPEN EXTERNAL |

## Inherited M11 Facts

These are inherited observed facts from the completed M11 execution record. M12
must preserve them while adding controls; Task 1 does not reclassify them as new
M12 evidence.

| Inherited boundary | Observed M11 fact | M12 treatment |
| --- | --- | --- |
| M11 inherited encrypted storage | Native structured records use the encrypted Drift/sqlite3mc database with a generated 32-byte key held through secure storage; native file headers differ from plaintext SQLite; Android backup is excluded. | Preserve and regression-test in later M12 tasks |
| M11 inherited key/ownership behavior | Account transitions serialize cleanup, pending revocation survives restart, and database-key rotation prevents a new owner from reading prior owner state. | Preserve and extend to versioned access/refresh credentials |
| M11 inherited offline behavior | Cached reads and drafts remain available within account/warehouse/permission scope; queued mutations require review and explicit foreground confirmation; connectivity alone never authorizes sync. | Preserve as a program invariant |
| M11 inherited unknown-result behavior | Status is checked before same-key replay, one authoritative effect is required, conflicts stay visible, and failed session/permission revalidation pauses or rejects work. | Preserve while adding refresh/session authority |
| M11 inherited staging limitation | Active staging is app-private and backup-excluded, but staged/download files are not independently encrypted. | Owner-bound staged-file encryption is PLANNED - NOT YET EVIDENCE |

## Task 1 TDD Evidence

| Gate | Observed result | Evidence state |
| --- | --- | --- |
| RED architecture test | 3 tests passed and 2 failed: stable classification rows had 9 rather than 10 columns, and this execution record was absent. | OBSERVED expected RED |
| GREEN architecture test | 5 tests passed; 0 failed in `test/m12_architecture_test.dart`. | OBSERVED GREEN |
| Flutter analysis | `flutter analyze --no-pub` completed with no issues. | OBSERVED GREEN |
| Diff and placeholder audit | `git diff --check` returned exit 0; the scoped placeholder/status scan found no unresolved placeholder value or contradiction in the Task 1 artifacts. | OBSERVED GREEN |

## Planned M12 Control Register

All rows below are design commitments only. Their status remains unchanged until
a later task records direct observed evidence against exact tested identities.

| Planned M12 control | Required future evidence | Status |
| --- | --- | --- |
| Typed environment and frontend API URL policy | Fail-closed profile/config and URL matrices | PLANNED - NOT YET EVIDENCE |
| Trusted proxy, HTTPS, HSTS, exact CORS, gated Swagger, and private uploads | Transport and route-surface tests plus managed local TLS observation | PLANNED - NOT YET EVIDENCE |
| Rotating refresh families and device-session revocation | Transactional rotation/reuse tests and authenticated journey | PLANNED - NOT YET EVIDENCE |
| Password abuse controls, TOTP, recovery, and optional biometric release | Deterministic policy, replay, recovery, and adapter tests | PLANNED - NOT YET EVIDENCE |
| Declarative route and financial-field authorization | Complete route matrix and cross-role/warehouse attack probes | PLANNED - NOT YET EVIDENCE |
| Structured recursive redaction and security audit events | Property tests and zero-sensitive-value report scans | PLANNED - NOT YET EVIDENCE |
| Retention, account export/deletion, and provider governance | Clock-injected jobs, allowlisted export, procedures, and external approvals | PLANNED - NOT YET EVIDENCE |
| Android screenshot, backup, integrity, signing, and store controls | Unit/static tests, APK inspection, and externally owned release evidence | PLANNED - NOT YET EVIDENCE |
| Aggregate M12 acceptance and M9-M12 regression | Strict stopped-state report, defect audit, cleanup, and exact commit/artifact identities | PLANNED - NOT YET EVIDENCE |

## External Boundary

Every action in `docs/security/external-launch-checklist.md` remains
`OPEN EXTERNAL`. Local substitutes may validate contract shape and failure
behavior, but they cannot close production DNS/TLS, secret custody, database
backup, legal/privacy, independent penetration test, Android release,
incident-response, or rollout approval.
