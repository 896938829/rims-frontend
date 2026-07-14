# RIMS Data Classification And Security Boundary Registry

Status: M12 NORMATIVE BASELINE; enforcement remains PLANNED unless the M12
execution record cites observed evidence.

This registry defines the minimum handling contract for RIMS data. It does not
claim that a planned M12 control is implemented. Backend authorization and
warehouse scope are authoritative; Flutter visibility, cached role text, and
JWT role text are never authority.

## Classification Vocabulary

- **Restricted:** credentials, OTP material, encryption keys, or equivalent
  authentication secrets. Never export or log.
- **Confidential:** personal, warehouse, inventory, document, attachment,
  financial, or operational data. Owner and permission scope is mandatory.
- **Internal:** redacted diagnostics and test evidence that still reveal system
  shape. Keep outside user backups and public artifacts.

`Owner scope` identifies the complete isolation key. `Retention` is a maximum,
not a minimum. A clear trigger always wins unless an explicitly listed legal or
audit exception applies. "Backup excluded" means Android cloud backup and
device transfer; server backup requirements are stated separately.

## Stable Data Class Inventory

| ID | Data | Owner scope | Encryption | Backup | Retention | Clear trigger | Export eligibility | Redaction | Financial/cost permission boundary |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| `credential.access` | Restricted short-lived access JWT and metadata | account + device session + credential generation | OS-backed secure storage; TLS in transit; never Drift | Excluded | Until token expiry or replacement; target lifetime measured in minutes | logout, account switch, refresh replacement, revocation, expiry, malformed restore, or secure-store failure | Never | Drop token and authorization header; retain only hashed session reference and expiry category | No financial or cost data; a credential never grants field access by itself |
| `credential.refresh` | Restricted opaque refresh token and family metadata | account + device session + token family + credential generation | OS-backed secure storage on device; keyed hash only on server; TLS in transit | Excluded | Until rotation, family expiry, or revocation | successful rotation, reuse detection, logout, revoke one/others/all, password security event, account disable, or restore failure | Never | Drop token, hash, cookie/header value, and request body; retain safe rotation/reuse category | No financial or cost data; refresh rotation never grants field access |
| `credential.totp` | Restricted pending/active TOTP secret and recovery proofs | account + enrollment generation | Application-key encryption for TOTP secret; one-way hash for recovery codes; TLS in transit | Excluded | Active until disable/regenerate; pending enrollment expires after 10 minutes; recovery code until consumed/regenerated | enrollment expiry, activation replacement, disable, regenerate, account deletion, or key-destruction procedure | Never | Drop secret, QR seed, OTP, and recovery code; retain factor state and safe result category | No financial or cost data; factor success never grants field access |
| `identity.profile` | Confidential account profile, role/permission projection, and warehouse references | account; warehouse where a field is warehouse-specific | Encrypted sqlite3mc database on native clients; TLS in transit; provider encryption at rest on server | Excluded on device; server backup governed by provider policy | Local projection: reference-cache TTL 24 hours and stale maximum 30 days; server record follows account lifecycle and legal obligations | logout without retained drafts, account switch/revocation, account deletion completion, or permission/warehouse invalidation for affected fields | Yes, current account fields except credentials, internal security state, and unauthorized fields | Remove personal fields from logs/evidence; exports include only documented account fields | Financial capability labels may be projected, but cost fields require current server-enforced `financial:read`; profile changes cannot grant `financial:write` |
| `cache.reference` | Confidential users, warehouses, products, and permission-scoped reference projections | account + warehouse where applicable + schema + permission fingerprint | Encrypted sqlite3mc database | Excluded | Fresh 24 hours; stale maximum 30 days | clear cache, logout/account switch/revocation, account deletion, or relevant role/warehouse/permission change | Yes only as owned canonical account data; not as raw cache records | Hash entity IDs in telemetry; omit personal, cost, and unauthorized fields | Product cost fields require server-enforced `financial:read`; writes always require `financial:write` plus resource permission and never use cache authority |
| `cache.inventory` | Confidential warehouse inventory and alert projections | account + warehouse + query + page + schema + permission fingerprint | Encrypted sqlite3mc database | Excluded | Fresh 24 hours; stale maximum 30 days | clear cache, logout/account switch/revocation, warehouse unbind/change, account deletion, or permission loss | Yes for owned warehouse references only; quantities require current server authorization | Hash entity IDs; omit cost and financial fields without `financial:read` | Valuation and cost require server-enforced `financial:read`; cached data never authorizes `financial:write` |
| `cache.document` | Confidential recent document pages and selected details; transaction history is not cached | account + warehouse + query + page + schema + permission fingerprint | Encrypted sqlite3mc database | Excluded | Fresh 7 days; stale maximum 30 days | clear cache, logout/account switch/revocation, warehouse/permission change, document mutation invalidation, or account deletion | Yes for current-account owned documents after server authorization | Hash document references; omit personal and financial fields without permission | Cost fields require server-enforced `financial:read`; mutation payloads require `financial:write` plus document permission |
| `cache.report` | Confidential report projections, including separately keyed basic and financial views | account + warehouse + exact parameters + schema + financial capability | Encrypted sqlite3mc database | Excluded | Fresh 6 hours; stale maximum 14 days | clear cache, logout/account switch/revocation, warehouse/permission change, source mutation, or account deletion | Yes only from a fresh server-authorized account export; financial fields require `financial:read` | Omit cost, profit, total value, and source rows without `financial:read`; hash entity references | Financial views require server-enforced `financial:read`; source mutations require `financial:write` plus resource permission |
| `draft.document` | Confidential user-entered intent for six document types and attachment bindings; no cached stock authority | account + warehouse + draft ID + schema version | Encrypted sqlite3mc database; staged bytes follow `attachment.staged` | Excluded | 30 days since last update unless user explicitly retains same-account drafts at logout | submit success, confirmed discard, retention prune, clear offline work, revocation/account switch, or account deletion | Yes as owned draft metadata only after explicit selection; staged bytes are separate | Omit personal fields, local paths, attachment bytes, and financial fields without permission | Cost intent is visible with `financial:read` and submit-eligible only with current server-enforced `financial:write` plus document permission |
| `outbox.operation` | Confidential immutable queued mutation payload, dependency graph, review context, and safe result metadata | account + warehouse + operation ID + idempotency key + permission fingerprint | Encrypted sqlite3mc database; TLS only during explicit foreground sync | Excluded | Active until terminal; succeeded 7 days; failed/conflict/cancelled 30 days | terminal retention prune, clear offline work, revocation/account switch, or account deletion; active work is never silently pruned | No raw operational queue export; account export may include safe status/history references | Drop credentials, bodies from logs, attachment bytes, local paths, and cached stock authority; hash operation/idempotency IDs | Queued cost values require `financial:read` to review and current server-enforced `financial:write` at submission; a stale fingerprint blocks sync |
| `attachment.staged` | Confidential original file, bounded thumbnail, manifest, download, and pending cleanup evidence | account + draft/operation binding + request ID | Required M12 target: owner-bound encrypted app-private files; current M11 app-private files are not independently encrypted | Excluded | Unprotected staged/download files 7 days; active draft/outbox evidence until terminal ownership cleanup | upload/replace success, confirmed remove, stale cleanup, clear offline work, logout/account switch/revocation, or account deletion | Bytes only after explicit user selection and current attachment permission; otherwise metadata only | Never log bytes, original path, absolute staged path, multipart body, or unredacted filename | No financial or cost data is inferred from bytes; access follows attachment ACL, and extracted cost data would require `financial:read` |
| `attachment.server` | Confidential attachment object and metadata | account actor + business resource + warehouse + attachment ID | TLS in transit; production object/database encryption at rest required from infrastructure owner | Server backup per approved encrypted-backup policy; never Android backup | Active resource lifecycle; soft-deleted object purge target 30 days unless legal hold | authorized delete/replace, owning-resource deletion, account deletion procedure, or retention cleanup | Metadata eligible when owned; bytes only after explicit selection, ACL check, and current permission | Never log bytes, object key, storage path, or sensitive filename; hash attachment/resource IDs | No financial or cost access follows attachment ownership; content tied to protected fields additionally requires server-enforced `financial:read` |
| `scan.session` | Confidential barcode, quantity intent, and recent scan session state | account + warehouse + scan session | Encrypted sqlite3mc database after legacy migration; transient camera frames are memory-only | Excluded | Until explicit clear or ownership transition; maximum 7 days without activity | successful consume/clear, clear offline work, logout/account switch/revocation, warehouse change, or account deletion | No; resulting owned document intent may be eligible through its own class | Do not retain camera frames; hash barcode/entity references in telemetry | No financial or cost data; scan results cannot reveal cost without a separate server-enforced `financial:read` request |
| `log.runtime` | Internal structured client/server runtime telemetry | environment + trace ID; no direct account payload | Memory/OS-protected sink locally; TLS and approved encrypted sink for non-local environments | Excluded from device and user backups | Local console: process lifetime; approved non-local sink: maximum 30 days | process exit locally; retention prune, incident closure, or deletion request where legally applicable | No | Drop authorization/cookie headers, credentials, OTP/recovery fields, bodies, multipart data, personal fields, attachment content, absolute paths, and nested unsafe values | No financial or cost data; all cost, price, profit, and valuation fields are dropped regardless of `financial:read` |
| `audit.server` | Confidential security and business audit event with safe actor/resource references | server tenant boundary + actor + warehouse/resource where applicable | TLS to server; production database encryption at rest required | Included only in encrypted, access-controlled server backup | Security/business audit target 365 days; a documented legal hold may suspend deletion | retention job after hold check; account deletion pseudonymizes actor fields where audit retention is required | Current account may receive a safe subset of its login/session history; administrative audit export requires `audit:read` | No credentials, raw tokens, OTPs, bodies, attachment bytes, personal network address, or unredacted cost values; hash entity/network references | Cost values are never stored; any bounded financial event category requires `audit:read` plus server-enforced `financial:read` to disclose |
| `export.account` | Confidential bounded account export archive and manifest | requesting account + export request ID + permission snapshot | TLS download; encrypted protected temporary storage while generated; destination protection becomes user responsibility after handoff | Excluded | Server temporary artifact 24 hours; client temporary copy deleted immediately after handoff or failure | successful handoff, expiry, cancellation, logout/revocation, generation failure, or account deletion | This is the export container; only eligible classes and explicitly selected attachment bytes may enter | Exclude credentials, keys, unauthorized financial fields, other accounts/warehouses, raw queue payloads, and unredacted logs | Financial and cost fields require fresh server-enforced `financial:read`; export never conveys `financial:write` authority |
| `evidence.test` | Internal redacted test reports, hashes, counts, owned process identities, and defect evidence | repository + tested commit pair + environment + run ID | Ignored local `.runtime` storage; secrets never written; encrypt external transfer if explicitly approved | Excluded | Latest formal report plus local history maximum 30 days; committed summary records follow repository history | superseded-run cleanup, 30-day prune, workspace cleanup, or confirmed secret-detection incident | No user export; safe committed aggregate evidence is repository-internal | Remove credentials, DSNs, keys, certificate private material, personal fields, absolute paths, bodies, and attachment bytes | No financial or cost data; tests use synthetic values and reports retain only aggregate authorization outcomes |

## Environment Profiles

| ID | Canonical value | Transport rule | Data and fixtures | Secret rule | Permitted use |
| --- | --- | --- | --- | --- | --- |
| `environment.development` | `development`; legacy `dev` maps only here | Explicit local debug may use HTTP only for loopback or Android emulator host alias; local TLS is preferred | Synthetic/local fixtures; no production copy | Workspace-local ignored secrets; deterministic test secrets only in allowlisted test scope | Developer workstation and managed local smoke |
| `environment.test` | `test` | Isolated local HTTP or local trusted TLS; no public listener | Deterministic synthetic fixtures reset between runs | Injected test keys and clocks; never accepted by staging/production | Unit, widget, integration, and security acceptance tests |
| `environment.staging` | `staging` | HTTPS and secure WebSocket only; exact origins and trusted proxies | Non-production or approved masked data only | External secret custody; default, short, or repository secrets rejected | Pre-release validation in an access-controlled environment |
| `environment.production` | `production` | HTTPS end to end, trusted proxy validation, and HSTS | Live customer/business data | External secret manager, rotation, recovery, and audit required | Approved public release only after every external checklist row is closed by its owner |

Unknown environment names fail before API client, database, router, migration, or
listener creation. Non-local profiles reject wildcard CORS, disabled database
TLS, auto migration, public Swagger/uploads, unsafe log formats, and HTTP public
URLs. These are target rules until later M12 tasks provide observed evidence.

## Android Runtime Permissions

| ID | Protection level | Purpose and data | Request timing | Denial behavior | Environment |
| --- | --- | --- | --- | --- | --- |
| `android.permission.INTERNET` | Normal install-time permission | Connect to the configured RIMS API and download/upload explicitly requested business data | Declared in manifest; no runtime prompt | App remains unable to reach backend; cached read-only state may remain visible under existing ownership rules | All Android profiles; non-local traffic must use HTTPS |
| `android.permission.ACCESS_NETWORK_STATE` | Normal install-time permission contributed by locked `connectivity_plus` 7.1.1 | Read Android network connectivity state as a hint before bounded backend health verification; no network payload is read | Merged from the plugin manifest at build time; no runtime prompt | Missing or unavailable state is treated as an indeterminate hint and never as proof of backend reachability or authorization | All Android profiles; only the verified health probe may establish backend reachability |
| `android.permission.CAMERA` | Dangerous runtime permission | Decode barcodes locally for inventory/document workflows; camera frames are not persisted or transmitted | Request only when the user enters scanner/camera capture | Show denied state and allow keyboard/file alternatives where supported; no repeated background prompt | Android scanner and camera attachment flows only |

The effective merged Android permission baseline is `INTERNET`,
`ACCESS_NETWORK_STATE` from locked `connectivity_plus` 7.1.1, and `CAMERA`.
No contacts, location, microphone, phone, SMS, broad media-library, or storage
permission is approved. `image_picker` and `file_picker` must use Android system
pickers or scoped grants. Any new manifest permission requires a new stable row,
purpose, denial path, and architecture-test update before merge.

## Provider And Data Flow Inventory

| ID | Owner/provider category | Data purpose | Data classes | Environments | Credential and external boundary |
| --- | --- | --- | --- | --- | --- |
| `provider.backend_api` | RIMS backend owner | Authentication, authorization, inventory, documents, reports, files, export, and audit | All server-bound classes except local-only test evidence | development, test, staging, production | TLS outside explicit local profiles; server session authority; production hosting approval is external |
| `provider.postgresql` | Platform/database owner | Authoritative identity, session, business, idempotency, and audit persistence | identity.profile, credential.refresh hashes, credential.totp ciphertext/hashes, attachment.server metadata, audit.server | development, test, staging, production | Application credential from secret custody; production TLS, backup, restore, and residency are external |
| `provider.android_os` | User device and Android platform | Runtime sandbox, camera permission, secure keystore, picker grants, and optional biometric gate | credential.access, credential.refresh, identity.profile, scan.session, attachment.staged | development, test, staging, production | OS authentication may release local credentials but cannot create or extend a server session |
| `provider.device_storage` | RIMS APP inside OS sandbox | Secure storage, encrypted sqlite3mc database, staging, downloads, and temporary exports | All local classes | development, test, staging, production | Owner-bound keys; backup excluded; clear triggers are serialized across account transitions |
| `provider.app_store` | Android release/store owner | Signed distribution, integrity verdict, store declarations, and account-deletion link | Binary metadata and declared data practices; no application credentials | production | Signing keys, Play Integrity activation, data-safety declaration, and store approval remain OPEN EXTERNAL |

No advertising, analytics, crash-reporting, social-login, payment, or remote-push
provider is approved in the observed baseline. Adding one requires provider,
SDK/license, purpose, data-class, retention, credential, and external-approval
records before code integration.

## Runtime SDK And License Baseline

Versions are the observed locked/direct baseline where shown. License labels are
from the package `LICENSE` files and are inventory facts, not legal approval.
Transitive-license policy and notice generation remain a later M12 gate.

| ID | Component | License | Purpose | Data handled | Network/provider behavior |
| --- | --- | --- | --- | --- | --- |
| `sdk.flutter` | Flutter 3.44.1 / Dart 3.12.1 | BSD-3-Clause | Android/Web UI and runtime | Rendered application state | No independent RIMS data recipient |
| `sdk.dio` | dio 5.9.2 | MIT | Typed HTTP client and interceptors | API request/response metadata and authorized payloads | Sends only to configured RIMS API |
| `sdk.flutter_secure_storage` | flutter_secure_storage 10.3.1 | BSD-3-Clause | OS-backed credential/key storage | credential.access, credential.refresh, local database key | Device keystore only; no independent network transfer |
| `sdk.drift_sqlite3mc` | drift 2.34.1 + sqlite3mc source | MIT plus SQLite public-domain/sqlite3mc terms | Encrypted local relational persistence | identity, caches, drafts, outbox, scans | Device storage only; backup excluded |
| `sdk.mobile_scanner` | mobile_scanner 7.2.0 | BSD-3-Clause | Camera barcode decoding | Transient camera frames and decoded barcode | Local decoding; no approved third-party transfer |
| `sdk.image_picker` | image_picker 1.2.2 | BSD-3-Clause | User-selected camera/gallery attachment | Explicitly selected attachment source | Android picker/camera only; upload uses RIMS API after user action |
| `sdk.file_picker` | file_picker 11.0.2 | MIT | User-selected document attachment | Explicitly selected file and metadata | System picker only; upload uses RIMS API after user action |
| `sdk.share_plus` | share_plus 12.0.0 | BSD-3-Clause | Hand account export to user-selected target | export.account after generation | OS share sheet; destination chosen by user |
| `sdk.connectivity_plus` | connectivity_plus 7.1.1 | BSD-3-Clause | Connectivity hint before bounded backend health verification | Network-type hint only | Does not establish backend reachability or authorize sync |
| `sdk.crypto` | crypto 3.0.7 | BSD-3-Clause | Hashes and integrity fingerprints | Safe hashes of bytes/identifiers | Local computation only |
| `sdk.drift_flutter` | drift_flutter 0.3.0 | MIT | Flutter lifecycle/bootstrap for Drift | Local database connection | Device storage only |
| `sdk.fl_chart` | fl_chart 1.2.0 | MIT | Local report visualization | Already-authorized report values | No independent network transfer |
| `sdk.go_router` | go_router 17.3.0 | BSD-3-Clause | In-app routing | Route names and arguments | No independent network transfer |
| `sdk.intl` | intl 0.20.2 | BSD-3-Clause | Date/number localization | Display values | Local formatting only |
| `sdk.json_annotation` | json_annotation 4.12.0 | BSD-3-Clause | Typed model serialization | Authorized API/local model fields | No independent transfer |
| `sdk.path_provider` | path_provider 2.1.5 | BSD-3-Clause | Resolve app-private directories | Local path handles | Absolute paths must never enter logs/evidence |
| `sdk.provider` | provider 6.1.5+1 | MIT | ViewModel and dependency state | In-memory application state | No independent transfer |
| `sdk.shared_preferences` | shared_preferences 2.5.5 | BSD-3-Clause | Non-secret preferences and migration journals | Non-secret settings; no credentials | Device storage only; sensitive records prohibited |
| `sdk.uuid` | uuid 4.5.3 | MIT | Client operation/request identifiers | Random identifiers, never credentials | Sent to RIMS API only where protocol requires |

## Financial And Cost Field Policy

`financial:read` and `financial:write` are explicit target capabilities. Admin
role text is not a substitute. The backend checks current database permissions,
warehouse/resource scope, and session validity on every request. Denied fields
are omitted, not returned as authoritative zero values. Cache namespaces and
export snapshots include the current financial capability.

| ID | Fields | Read requirement | Write requirement | Cache/export rule | Authority |
| --- | --- | --- | --- | --- | --- |
| `field.product.cost_price` | Product `costPrice` | `financial:read` plus product/resource access | `financial:write` plus `product:create` or `product:update` | Omit from basic cache/export; invalidate privileged cache on permission loss | server enforced from current permission relations |
| `field.document.cost_price` | Document-line `costPrice` and cost-derived totals | `financial:read` plus document and warehouse access | `financial:write` plus the applicable `document:create`, `document:complete`, `stocktake:confirm`, or `stocktake:settle` permission | Omit from basic document cache/export and queued payload unless required by an authorized mutation | server enforced from current permission relations |
| `field.report.cost_amount` | Report `costAmount` | `financial:read` plus report and warehouse access | `financial:write` plus source-mutation permission; report value itself is server-derived and not client-writable | Financial cache key only; omit from basic export | server enforced from current permission relations |
| `field.report.gross_profit` | Report `grossProfit` | `financial:read` plus report and warehouse access | `financial:write` plus source-mutation permission; report value itself is server-derived and not client-writable | Financial cache key only; omit from basic export | server enforced from current permission relations |
| `field.inventory.total_value` | Inventory total value and cost-derived valuation | `financial:read` plus inventory and warehouse access | `financial:write` plus source-mutation permission; valuation itself is server-derived and not client-writable | Financial cache key only; omit from basic export | server enforced from current permission relations |

## Clear And Export Rules

1. Account switch, revocation, token expiry, and account deletion run through the
   serialized ownership barrier before a new owner can read local state.
2. Explicit foreground confirmation remains mandatory for outbox submission.
   Connectivity changes never authorize refresh or queued writes.
3. Account export is allowlist-based. It excludes credentials, encryption keys,
   unauthorized financial fields, other accounts/warehouses, raw outbox payloads,
   attachment bytes without explicit selection, and unredacted logs.
4. A legal hold may affect only the named server record and must identify owner,
   authority, start/end, and deletion review. It never justifies retaining local
   credentials, staging, cache, or runtime logs.
5. Backup/restore ownership is external for production infrastructure and must
   close `external.database_tls_backup`; Android backup remains excluded locally.
