# RIMS APP Long-Term Completion Roadmap Design

**Date:** 2026-07-10

**Status:** Approved design, pending implementation-plan decomposition

**Baseline:** M0-M8 internal acceptance is complete. The frontend uses the real
RIMS backend, Phase A-F integration has passed, and the current smoke suite is
green.

**Goal:** Evolve the Flutter application into an Android-first, public-cloud,
production-capable inventory product while keeping every development phase
reproducible and executable in the local workspace by an AI goal loop.

**Planning Model:** Keep one master roadmap and split implementation into
independent milestone plans. Each milestone must deliver working, testable
software and must not require a production cloud account for local completion.

---

## 1. Confirmed Decisions

- Cover the long-term complete product, not only internal acceptance hardening.
- Use Android as the primary platform; treat iOS, Windows, Web, tablets,
  foldables, and desktop layouts as expansion targets.
- Target a public-cloud backend accessed through HTTPS.
- Design for 50-500 users, 10-100 warehouses, about 100,000 products, and
  millions of inventory transaction rows.
- Provide limited offline support: cached reads, scans, and drafts may work
  offline, while the server remains authoritative for stock and document state.
- Organize work as one master roadmap plus milestone-specific plans.
- Make all implementation work repeatable in local Windows, WSL, Flutter,
  backend, and Android Emulator environments.
- Let AI workers start, inspect, restart, test, and stop local services without
  waiting for a user to open terminals.

## 2. Product Boundary

### 2.1 Intended Outcome

Warehouse operators, business users, reviewers, and administrators can perform
daily inventory work from Android devices while maintaining correct warehouse
scope, role scope, stock accounting, document state, auditability, and
production diagnostics.

### 2.2 Local Completion And External Launch

Every requirement has two verification boundaries:

- **Local completion:** code, configuration interfaces, local substitutes,
  automated tests, Android Emulator verification, backend integration, failure
  injection, and release-build generation.
- **External launch:** formal domains and certificates, production cloud
  resources, production secrets, app-store organization accounts, store review,
  real messaging providers, and organizational legal approval.

External launch work is tracked but never blocks a local AI goal loop. A provider
integration is locally complete after contract tests pass against a local
substitute and production credentials remain the only missing input.

### 2.3 Priority Tiers

- **Foundation:** local autonomy and safe repeatability.
- **Production baseline:** required before public-cloud production use.
- **Business expansion:** operational depth after the baseline is stable.
- **Scale and platform expansion:** activated by volume or platform demand.
- **Long-term candidate:** retained in the catalogue but separately approved.

## 3. Roadmap M9-M16

### M9: Acceptance Hardening And Local Autonomy

**Objective:** Turn the M8 baseline into a deterministic local system that an AI
worker can start and verify from a stopped state.

**Scope:**

- Build the local service lifecycle commands defined in Section 4.
- Add pagination or infinite loading for inventory, documents, users, products,
  warehouses, alerts, non-standard inventory, and long report lists.
- Preserve query, filter, warehouse, page, scroll, and selected-item state across
  recoverable refreshes.
- Add UI integration flows for login, restore, warehouse switching, inventory,
  inbound, outbound, permission boundaries, and logout.
- Add deterministic seeds for admin, operator, multiple warehouses, low stock,
  non-standard inventory, and document workflows.
- Add Android Emulator smoke and a real-device UAT checklist.
- Add network failure, stale session, malformed response, and duplicate-submit
  regressions.
- Measure launch, first data, search, scrolling, and common document actions.

**Exit:** One command starts local services, paged datasets remain reachable,
critical UI flows pass, current smoke remains green, and P0/P1 defects are zero.

### M10: Android Field Operations

**Objective:** Make warehouse work ergonomic on Android.

**Scope:**

- Add camera barcode scanning behind a platform capability interface.
- Support single, continuous, and batch scan; duplicate suppression; torch;
  focus; sound; vibration; manual input; and unsupported-code feedback.
- Support scan-to-search, sales, inbound, stocktake, transfer, and conversion.
- Add camera, media, file, notification, and storage permission guidance.
- Add image capture, selection, compression, upload progress, retry, preview,
  download, sharing, and deletion.
- Handle backgrounding, resume, process recreation, permission revocation, low
  storage, and interrupted uploads.
- Validate portrait, landscape, tablet, font scaling, dark mode, keyboard, and
  system back behavior.
- Keep industrial scanner keyboard-wedge input as an optional adapter.

**Exit:** Scan and attachment flows pass locally on Android Emulator or a
connected test device without external cloud accounts.

### M11: Limited Offline And Synchronization

**Objective:** Preserve useful reads and drafts during weak or absent network
without allowing the client to invent authoritative stock.

**Scope:**

- Add a versioned local database for cached and queued data.
- Cache user, warehouses, products, recent inventory, alerts, recent documents,
  report summaries, and selected details.
- Show data age, source, and offline state.
- Support offline product/barcode lookup, document drafts, scan collections,
  comments, and attachment staging.
- Add outbox states: queued, syncing, succeeded, retryable failure, conflict,
  permanent failure, and cancelled.
- Add client operation IDs and idempotency keys.
- Revalidate authentication and warehouse before synchronization.
- Preserve ordering between attachment upload, document creation, and lifecycle
  action.
- Add retry, retry-all, cancel, discard, and conflict-resolution entry points.
- Encrypt sensitive local records and clear account data on logout/revocation.
- Test airplane mode, latency, network switching, process termination, duplicate
  delivery, stale permissions, and server conflict.

**Exit:** Cached reads and drafts work offline, queued writes are idempotent, and
conflicts never silently overwrite the server.

### M12: Production Security And Compliance

**Objective:** Establish controls required for public-cloud use.

**Scope:**

- Separate development, test, staging, and production configuration.
- Require HTTPS outside explicit local profiles.
- Use short-lived access tokens and refresh-token rotation when supported.
- Add device/session listing, revocation, password policy, lockout, login history,
  and optional second-factor authentication.
- Add optional biometric local unlock without replacing server authentication.
- Enforce server-side role, warehouse, field, and financial authorization.
- Add permission-boundary regression suites for protected capabilities.
- Encrypt sensitive local storage and define cache-clearing behavior.
- Redact logs, crashes, analytics, exports, and attachments.
- Add privacy policy, permission explanation, SDK inventory, retention rules,
  and account-data export/deletion procedures.
- Add dependency, secret, static-analysis, and mobile-security checks.
- Keep screenshot protection, integrity, and anti-debugging configurable.

**Exit:** Controls are locally testable, logs contain no secrets, authorization
tests pass, and the external legal checklist is explicit.

### M13: Release Engineering And Observability

**Objective:** Make Android builds reproducible, diagnosable, upgradable, and
safe to roll out.

**Scope:**

- Define semantic versioning and build-number rules.
- Produce deterministic debug, test, staging, and release variants.
- Inject signing secrets without committing keys.
- Define shrinking/obfuscation and symbol retention.
- Validate build contents and environment configuration.
- Add structured logs, crashes, ANRs, traces, metrics, and business diagnostics
  behind provider interfaces.
- Track login/API/sync/document failures, crash rate, version adoption, and
  workflow latency.
- Validate alert rules locally and document production thresholds.
- Add optional/required upgrades, minimum version, release notes, rollout
  percentage, feature flags, and emergency kill switches.
- Define rollback and API/cache/data migration compatibility.
- Generate a local release candidate and run release smoke.

**Exit:** A release candidate passes locally and store submission is the only
remaining publication action.

### M14: Business Depth

**Objective:** Expand the core inventory product without weakening accounting
rules.

**Scope:**

- Expand product master data, barcodes, packaging, categories, brands, images,
  tax, and custom attributes.
- Add suppliers, customers, contacts, addresses, and carriers.
- Add batch, serial, production/expiry date, shelf life, FIFO, near-expiry, and
  traceability.
- Add areas, bins, and stock by location.
- Add purchase return, damage, surplus, miscellaneous inbound/outbound,
  reservation, release, freeze, unfreeze, and adjustment.
- Add multi-line documents, partial completion, copy, edit, cancel, reverse,
  relationships, comments, attachments, and timelines.
- Add configurable multi-stage approval, delegation, transfer, countersign,
  reminders, withdrawal, and rejection reasons.
- Add audit search/details, report drill-down, saved filters, asynchronous
  export, CSV/Excel/PDF, print, share, and scheduled reports.
- Add imports with preview, validation, failure reports, idempotency, and safe
  rollback rules.
- Add in-app notifications and locally testable push contracts.

**Exit:** Each activated module has contracts, permissions, lifecycle tests,
inventory-effect tests, audit evidence, and UI UAT.

### M15: Medium-Scale Performance And Capacity

**Objective:** Verify the selected medium-scale target.

**Scope:**

- Generate deterministic data for 500 users, 100 warehouses, 100,000 products,
  and millions of transactions.
- Use server-side filters, stable sorting, pagination/cursors, and bounded pages.
- Add debounced search, cancellation, stale-response protection, and indexed
  barcode/product lookup.
- Add incremental sync and cache eviction.
- Bound memory, disk, images, logs, and outbox growth.
- Benchmark backend queries, APIs, rendering, launch, scrolling, battery, and
  network usage.
- Add asynchronous jobs for large exports/reports.
- Add load, soak, concurrency, duplicate request, and retry-storm tests.

**Exit:** Target datasets remain usable and performance budgets pass locally.

### M16: Platform And Experience Expansion

**Objective:** Extend the stable Android product to additional platforms and
broader user needs.

**Scope:**

- Adapt iOS camera, storage, notification, security, lifecycle, and release.
- Adapt Windows/Web keyboard, pointer, download, print, and session behavior.
- Replace the fixed mobile-width assumption with responsive phone, tablet,
  foldable, and desktop layouts.
- Add localization, Simplified Chinese, English, date/time, number, currency,
  unit, and timezone handling.
- Add screen reader, contrast, font scaling, keyboard, touch-target, and reduced
  motion support.
- Add theme, message preferences, diagnostics, help, feedback, version, and
  cache management.
- Evaluate multi-organization, multi-tenant, licensing, PDA, Bluetooth printing,
  scales, ERP/e-commerce, and public APIs as separate candidates.

**Exit:** Every activated platform has its own build, compatibility matrix,
smoke suite, and release checklist without forking business rules.

## 4. Local AI Execution Contract

### 4.1 Local Topology

- Windows hosts the frontend workspace and PowerShell orchestration.
- WSL hosts the Go backend and backend commands.
- Android Emulator is the default Android target.
- `RIMS_BACKEND_DIR` supplies the backend path; the known current path is only a
  documented default.
- Local substitutes provide storage, messaging, notifications, observability,
  and HTTPS behavior.
- Production credentials are not required for implementation loops.

### 4.2 Lifecycle Commands

- `doctor`: verify Flutter, Dart, WSL, Go, Android, database, ports, paths,
  providers, and required variables.
- `up`: start dependencies, migrate and seed the backend, start backend and
  frontend, and wait for readiness.
- `status`: report state, PID, time, port, health, path, commit, and profile in
  machine-readable and human-readable forms.
- `logs`: return recent logs or follow one component.
- `restart`: restart one component or the managed stack after ownership checks.
- `reset`: reset only an explicitly marked development/test environment.
- `smoke`: run selected frontend, backend, integration, Android, and provider
  gates and return one combined result.
- `down`: stop only processes created by the orchestration layer.

### 4.3 Process Safety

- Record managed PIDs, paths, commits, ports, profiles, and logs under a
  gitignored runtime directory.
- Do not kill a port listener until executable, command line, working directory,
  and managed state match the expected component.
- Keep commands idempotent and prevent duplicate instances.
- Refuse reset against production-like hosts, databases, or profiles.
- Redact secrets, tokens, passwords, attachments, and personal data.
- Use health probes and bounded timeouts rather than fixed sleeps.
- Return nonzero status, failed component, health, and log path on failure.

### 4.4 Local Provider Equivalents

- Object storage: MinIO or filesystem provider behind one attachment interface.
- Push: fake provider plus a local in-app message inbox.
- Email/SMS: local capture providers without external delivery.
- Observability: lightweight structured-log collector by default and an optional
  full local metrics/traces profile.
- HTTPS: local reverse proxy and development certificate profile.
- Time: injectable clock for expiry, retry, and reporting tests.
- Network faults: test adapters or a local proxy for latency, disconnects,
  malformed responses, and retry behavior.

### 4.5 Goal-Loop Sequence

1. Read plan and current defect/state record.
2. Run `doctor`, then `up`, then verify health.
3. Establish a failing test.
4. Implement the smallest correct change.
5. Run targeted tests.
6. Run frontend/backend integration and fault scenarios.
7. Run milestone and repository smoke.
8. Record defects, evidence, migrations, seeds, and external checks.
9. Fix P0/P1 before completion.
10. Commit atomically and leave services in a documented state.

## 5. Functional Requirement Catalogue

### 5.1 Account And Identity

- Login, logout, restoration, expiry handling, and token refresh.
- Own-password change, administrator reset, and first-login password change.
- Password strength, history, expiry, lockout, unlock, and failed-attempt notice.
- Optional MFA enrollment, challenge, recovery, and reset.
- Device/session list, naming, last activity, and remote revocation.
- Login history and optional biometric local unlock.

### 5.2 Organization, Warehouse, And Authorization

- Current organization/warehouse, visible/default warehouses, and switch history.
- Membership, area, zone, aisle, shelf, bin, and location hierarchy.
- Role lifecycle and permission assignment.
- Warehouse-, action-, field-, and financial-data permissions.
- Temporary authorization with expiry and revocation.
- Immediate permission refresh and server enforcement.

### 5.3 Home Workbench

- Warehouse identity, data timestamp, product/quantity/alert/in-transit metrics.
- Low stock, no stock, overstock, non-standard, slow-moving, and expiry warnings.
- Approvals, failed sync, drafts, notices, recent documents, and quick actions.
- Role-filtered and eventually configurable widgets.
- Independent loading, empty, stale, permission, and error states.

### 5.4 Product Master Data

- SKU, names, category, brand, specification, status, units, packaging, and
  conversion factors.
- Primary/multiple/supplier/package barcodes.
- Images, prices, tax, valuation metadata, dimensions, origin, and custom fields.
- Batch, serial, expiry, and tracking strategy.
- Duplicate prevention, search normalization, import/export, and audit.

### 5.5 Inventory Query And Control

- Server-side pagination/cursors with total/count metadata.
- Infinite loading or page controls with page-level retry.
- Search, barcode, category, status, warehouse, location, batch, supplier, date,
  and stable sort filters.
- On-hand, available, occupied, frozen, in-transit, standard, and non-standard
  quantity detail.
- Transactions with document, actor, before/delta/after, time, batch, location,
  and reason.
- Min/max/safety/reorder thresholds and stock alerts.
- Freeze, reserve, release, adjust, damage, surplus, status, snapshot, aging,
  valuation, traceability, and cross-warehouse comparison.

### 5.6 Documents And Inventory Workflows

- Purchase inbound, sales outbound/return, purchase return, transfer, stocktake,
  conversion, adjustment, damage, surplus, and miscellaneous inbound/outbound.
- Multi-line product/unit/quantity/price/batch/serial/location details.
- Draft, autosave, edit, delete, copy, source/related documents, attachments,
  comments, and totals.
- Submit, approve, reject, withdraw, cancel, complete, settle, reverse, partially
  complete, and close when business rules allow.
- Status, actor, inventory effect, and audit timelines.
- Duplicate protection, idempotency, preserved state on failure, and visible
  resulting transactions.

### 5.7 Approval Workflow

- Rules by document type, amount, warehouse, category, risk, role, and requester.
- Single/multi-stage, countersign, conditional routing, delegation, transfer,
  added reviewer, and proxy.
- Comments, rejection reason, attachments, timestamps, reminders, escalation,
  withdrawal, and rule-version audit.

### 5.8 Android Scanning And Device Work

- Camera, manual barcode, and keyboard-wedge input.
- Single, continuous, batch, and quantity accumulation modes.
- Torch, focus, sound, vibration, duplicate control, and visible feedback.
- Unknown, disabled, wrong-warehouse, wrong-batch, and permission errors.
- Scan to search, inbound, outbound, return, transfer, stocktake, and conversion.
- Offline scan lookup and lifecycle-safe permission handling.

### 5.9 Attachments And Media

- Camera, gallery, file selection, compression, orientation correction,
  metadata policy, thumbnails, type/size/count validation.
- Progress, cancel, retry, resumable strategy candidate, preview, download,
  share, replace, reorder, and delete.
- Product, document, approval, audit, feedback, and offline draft relationships.

### 5.10 Suppliers, Customers, And Partners

- Supplier, customer, carrier, contact, address, tax, credit, and status data.
- Product relationships, preferred suppliers, and transaction history.
- Search, pagination, import/export, enable/disable, and audit.

### 5.11 Reports And Output

- Sales summary/trend/ranking/revenue/cost/profit under permissions.
- Inventory overview/value/turnover/aging/slow/shortage/overstock/expiry/batch and
  cross-warehouse analysis.
- Date, warehouse, product, category, partner, batch, and status filters.
- Drill-down, saved filters, CSV/Excel/PDF, print/share, asynchronous export,
  progress, history, expiry, and scheduled definitions.

### 5.12 Notifications

- Stock, expiry, approval, document, sync, security, release, and system events.
- In-app inbox, unread count, categories, archive/delete, and retention.
- Push abstraction, authorized deep links, preferences, and quiet periods.

### 5.13 Limited Offline

- Versioned account/warehouse-isolated cache.
- Offline product/barcode search, drafts, scans, comments, and attachments.
- Outbox state, ordering, retry, cancel, discard, and conflict entry.
- Data age, source, last sync, connectivity, and explicit prohibition of
  client-only authoritative stock completion.

### 5.14 Search, Administration, Profile, And Support

- Global permission-filtered search for products, barcodes, documents, batches,
  serials, partners, and locations.
- Administration for users, passwords, sessions, products, warehouses,
  locations, partners, roles, permissions, dictionaries, numbering, thresholds,
  approvals, notifications, retention, flags, and minimum version.
- Profile, security devices, warehouses, preferences, language, theme, privacy,
  cache, app/build version, legal documents, help, release notes, feedback,
  diagnostics, and user-triggered redacted log export.

### 5.15 Internationalization And Accessibility

- Resource-based strings; Simplified Chinese first and English next.
- Locale-correct date, time, timezone, currency, number, quantity, and units.
- Screen reader, focus order, keyboard, contrast, touch targets, font scaling,
  and reduced motion.

### 5.16 Long-Term Candidates

- Multi-organization, multi-tenant, subscription licensing, industrial PDA,
  Bluetooth printing, electronic scales, ERP/accounting/e-commerce/carrier
  integrations, public API, webhooks, integration keys, and rate limits.

Candidates remain inactive until separately approved.

## 6. Non-Functional Requirements

### 6.1 Architecture And Maintainability

- Continue feature-first MVVM with repository and DataSource boundaries.
- UI does not parse Dio errors, construct endpoints, or access raw persistence.
- Remote, local, sync, device, and provider concerns use explicit interfaces.
- Shared utilities stay generic; business rules remain feature-owned.
- Split large pages and ViewModels only when active work touches them and the
  split reduces concrete complexity.
- Give API models, domain entities, and cached records explicit conversion and
  schema-version ownership.
- Review dependencies, retain a lockfile, and remove unused packages.

### 6.2 API Contract

- Stable success/error envelope, business code, message, trace ID, and HTTP
  behavior.
- Stable page/cursor metadata, sort order, and filter semantics.
- Explicit API version and compatibility policy.
- UTC transport timestamps with explicit local display conversion.
- Decimal money and quantity handling without binary-floating accounting errors.
- Idempotency support for create and lifecycle mutations.
- Optimistic concurrency version or equivalent server conflict token.
- Attachment and asynchronous-job status contracts.

### 6.3 Performance And Resources

- Measure cold/warm launch, login, first content, search, page load, scan
  feedback, document submission, and report render.
- Verify smooth scrolling with representative inventory and document rows.
- Bound requests and cancel obsolete searches where useful.
- Limit memory, disk cache, attachment staging, logs, and outbox growth.
- Respect Android battery and network constraints in background work.
- Remain usable at the medium-scale target.

M9 establishes measured baselines. Each later milestone defines its threshold
before implementation and does not hide regressions by relaxing the threshold.

### 6.4 Reliability And Integrity

- Duplicate requests do not duplicate documents or inventory effects.
- Lifecycle operations are atomic according to backend contracts.
- Recoverable refresh failure preserves valid existing data.
- Process termination does not lose saved drafts or corrupt the outbox.
- Retry uses bounded exponential backoff and avoids retry storms.
- Cache corruption and migration failure have safe recovery behavior.
- The server remains authoritative for inventory and protected document state.

### 6.5 Security

- Require HTTPS outside explicit local profiles.
- Store tokens in secure platform storage and exclude them from logs.
- Use short-lived access and rotating refresh tokens when supported.
- Require server authorization even when the UI hides a control.
- Encrypt sensitive caches/drafts according to data classification.
- Redact logs, traces, crashes, analytics, exports, and attachments.
- Run dependency, secret, static-analysis, and authorization checks locally.
- Include replay, privilege, abuse, and data-leak tests for sensitive changes.

### 6.6 Privacy And Data Governance

- Collect only operationally required data and diagnostics.
- Explain camera, file, notification, and storage permissions.
- Maintain third-party SDK and privacy impact records.
- Define retention/deletion for sessions, logs, messages, exports, caches,
  drafts, attachments, and audits.
- Define account-data export/deletion procedures where applicable.
- Define soft deletion, archival, immutable audit, backup, and restore.

### 6.7 Observability And Supportability

- Structured logs include trace ID, operation category, safe entity ID, version,
  and environment without sensitive payloads.
- Capture crashes, ANRs, API/sync failures, and critical business failures behind
  provider interfaces.
- Measure login, request, document, scan, upload, sync, and report latency.
- Provide diagnostics and a user-triggered redacted support bundle.
- Validate local alert rules for elevated failure, crash, and outbox backlog.

### 6.8 User Experience

- Use consistent design tokens, components, validation, state labels, and error
  wording.
- Provide loading, empty, stale, offline, permission, error, submitting, success,
  and conflict states for primary workflows.
- Confirm dangerous actions and preserve context on failure.
- Preserve list search, filter, page, and selection where useful.
- Expand phone-first design responsively instead of stretching mobile cards.
- Keep user terminology aligned with backend business state.

### 6.9 Compatibility And Upgrade

- Define/test minimum Android API level before release implementation.
- Cover representative size, density, font scale, orientation, dark mode, camera,
  and OEM background restrictions.
- Give local schema/cache migrations rollback or safe-reset behavior.
- Define an old-client support window for backend API evolution.
- Reuse domain rules on later platforms and replace platform capabilities only.

### 6.10 Backup, Recovery, Cost, And Documentation

- Back up and restore backend database, attachments, provider configuration, and
  audit data.
- Exercise restore and verify referential integrity and attachment availability.
- Decide production RPO/RTO before launch and validate them by rehearsal.
- Preserve client drafts/outbox through normal process loss and app upgrades.
- Compress images, sample high-volume diagnostics, cache reference data, merge
  duplicate refreshes, cancel obsolete searches, and use async reports/exports.
- Track storage, egress, push, logging, and observability cost drivers.
- Keep architecture, setup, API, permissions, data, tests, release, rollback,
  incident, and user documentation aligned with verified behavior.

### 6.11 AI Executability

- Keep local commands non-interactive, idempotent, and explicit about exit code.
- Give each task preconditions, exact files, failing test, implementation action,
  commands, expected output, acceptance evidence, and atomic commit boundary.
- Keep milestone checkpoints and state records sufficient for context recovery.
- Do not treat production-account operations as autonomous local tasks.

## 7. Data Flow And Synchronization

### 7.1 Online Read

```text
Page
  -> ViewModel
    -> Repository
      -> RemoteDataSource
        -> ApiClient
```

After caching is introduced, a repository may return a valid local snapshot,
request current server data, compare versions, update the cache, and notify the
ViewModel. The UI exposes freshness when data may be stale.

### 7.2 Online Write

```text
User action
  -> ViewModel validation and duplicate guard
    -> Repository
      -> RemoteDataSource
        -> ApiClient with auth, warehouse, trace, idempotency, and version
          -> Backend transaction
```

The backend returns authoritative entity state. The frontend publishes scoped
refresh events and updates caches only after confirmed success.

### 7.3 Offline Draft And Outbox

```text
Form or scan
  -> Local draft
    -> Outbox operation graph
      -> Connectivity and session revalidation
        -> Ordered idempotent submission
          -> Server validation
            -> Local cache and draft reconciliation
```

The operation graph preserves dependencies such as attachment upload before
document submission or document creation before lifecycle completion.

### 7.4 Conflict Policy

- Network or transient server failure is retryable.
- Authentication failure pauses the queue until the session is restored.
- Permission failure becomes permanent unless authorization changes.
- Validation failure returns the user to an editable draft.
- Shortage, document-state change, warehouse change, and version conflict require
  explicit user resolution.
- The client never chooses its own stock quantity over the server.

## 8. Error Model

Classify errors as authentication, authorization, validation, business state,
concurrency conflict, network/timeout/cancellation, server/malformed response,
local storage/cache migration/disk, attachment/media, or synchronization error.

Every application failure carries a safe message, business code, HTTP status
when applicable, trace ID, retryability, session impact, and diagnostic cause.
ViewModels decide UI state and action; pages do not interpret transport errors.

## 9. Verification Strategy

### 9.1 Test Layers

- Unit tests for parsing, validation, domain rules, pagination, retry, and sync.
- DataSource tests for request shape, variants, malformed data, and failures.
- Repository tests for remote/local/cache/sync behavior.
- ViewModel tests for loading, stale, offline, conflict, success, and duplicate
  guards.
- Widget tests for controls, forms, permissions, dialogs, responsive layouts,
  and semantics.
- Golden tests for stable high-value phone/tablet layouts.
- Backend contract tests for fields, permissions, pagination, idempotency,
  concurrency, document state, and inventory effects.
- UI integration tests for login, restore, warehouse switch, search, scan,
  inbound, outbound, stocktake, permission boundaries, sync, and logout.
- Performance, capacity, security, fault, migration, and release-build tests.

### 9.2 Local Gates

- Dependency resolution under the intended local profile.
- Formatting, static analysis, and full Flutter tests.
- Backend tests, build, migration, and seed verification.
- Backend smoke and frontend/backend integration smoke.
- Android Emulator smoke for Android milestones.
- Demo/static-placeholder scan.
- Secret/dependency-risk checks from M12.
- Release build/artifact inspection from M13.
- `git diff --check` and explicit worktree status.

## 10. Defect And Acceptance Model

- **P0:** cannot start/login, crash, data loss, wrong stock, duplicate stock
  effect, security breach, or unusable core workflow.
- **P1:** wrong permission/warehouse, blocked core action, silent sync failure,
  unrecoverable draft, or severe regression without useful feedback.
- **P2:** important non-core, scale, compatibility, or UX issue with workaround.
- **P3:** polish, low-risk consistency, diagnostics, or documentation gap.

Milestone exit requires activated use cases to pass, local startup from stopped
state, all targeted/full gates to pass, P0/P1 to be zero, P2/P3 to be recorded,
migrations/seeds/provider contracts to be verified, external checks to be
explicit, and worktree/services/test data to be documented.

## 11. Implementation-Plan Decomposition

This design produces independent plans in this order:

1. M9 local autonomous environment and acceptance hardening.
2. M10 Android field operations.
3. M11 limited offline and synchronization.
4. M12 production security and compliance.
5. M13 release engineering and observability.
6. M14 business depth, further split by activated module.
7. M15 medium-scale performance and capacity.
8. M16 platform/experience expansion, further split by platform.

Each plan uses TDD for non-trivial behavior, exact local paths and commands,
small verified tasks, frequent atomic commits, and checkpointed execution.

## 12. External Launch Boundary

The following are tracked but do not block local AI completion:

- Production cloud, network, database, object storage, and backup setup.
- Formal domain, DNS, and TLS certificate issuance.
- Production secret custody, rotation, and recovery approval.
- Production push, email, SMS, crash, metric, and log accounts.
- Legal privacy, terms, processing, and retention approval.
- Android application ID ownership, signing-key custody, store organization,
  listing, declarations, and review.
- Production penetration testing and organizational security approval.
- Production disaster-recovery rehearsal and on-call ownership.
- Rollout approval, support readiness, and incident communication.

Local work is complete only after provider contracts pass with local substitutes
and the remaining external action is explicitly recorded.

## 13. Final Definition Of Done

- Android users securely perform all activated warehouse workflows against the
  public-cloud backend.
- Inventory/document state remains correct across concurrency, retry, offline
  drafts, app restart, and permission change.
- Medium-scale capacity and usability evidence passes.
- Production security, privacy, observability, release, rollback, and support
  controls are active.
- Activated providers pass local contracts and production verification.
- Required Android distribution and organizational approvals are complete.
- Additional platforms pass their own build, compatibility, smoke, and release
  gates before being called complete.
- Documentation and operational ownership match delivered behavior.
