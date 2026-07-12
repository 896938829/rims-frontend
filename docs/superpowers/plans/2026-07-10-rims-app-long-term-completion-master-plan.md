# RIMS APP Long-Term Completion Master Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Advance the M8 internal-acceptance application through M9-M16 into an Android-first, public-cloud, production-capable inventory product using locally executable AI goal loops.

**Architecture:** This is the program-level controller for eight independently testable milestone plans. It preserves the existing Flutter feature-first MVVM and Go service boundaries, requires every milestone to start from a locally autonomous runtime, and delays each future code-level plan until preceding milestones establish the interfaces that plan must use.

**Tech Stack:** Flutter, Dart, Provider, GoRouter, Dio, Go, Gin, GORM, PostgreSQL, WSL, Docker Compose, PowerShell, Bash, Android Emulator, local provider substitutes.

---

## 1. Source Of Truth

- Product and architecture design:
  `docs/superpowers/specs/2026-07-10-rims-app-long-term-completion-design.md`
- Current acceptance baseline:
  `docs/superpowers/plans/2026-07-08-rims-m8-integration-session-2.md`
- First executable milestone plan:
  `docs/superpowers/plans/2026-07-10-rims-m9-local-autonomy-acceptance-hardening.md`
- Frontend workspace: `E:\My Work\rims-frontend`
- Flutter application: `E:\My Work\rims-frontend\rims_frontend`
- Backend workspace default: `E:\My Work\RIMS\rims-goProgect`
- Backend workspace override: `RIMS_BACKEND_DIR`

## 2. Program Rules

- [ ] Execute milestones in dependency order M9, M10, M11, M12, M13, M14,
  M15, M16.
- [ ] Do not call a milestone complete because code exists; run its local exit
  commands and read their output.
- [ ] Keep P0/P1 at zero before crossing a milestone boundary.
- [ ] Record P2/P3 with reproduction, affected version, owner milestone, and
  rationale.
- [ ] Use local substitutes for storage, push, email/SMS, observability, HTTPS,
  and fault injection before production providers.
- [ ] Never require store review, production credentials, production domains,
  or organizational approval to complete a local milestone.
- [ ] Add code-level plans only after entry criteria are met and current files,
  types, tests, and APIs have been remapped.
- [ ] Use a dedicated `codex/` branch or worktree for each milestone execution.
- [ ] Preserve user changes and unrelated dirty files.
- [ ] Commit implementation in small verified units and keep phase records in
  `docs/superpowers/plans/`.

## 3. Dependency Graph

```text
M8 accepted baseline
  -> M9 local autonomy + pagination + E2E
    -> M10 Android scanner + attachments
      -> M11 cache + drafts + outbox
        -> M12 security + privacy + environment isolation
          -> M13 release + observability + upgrade
            -> M14 activated business-depth modules
              -> M15 medium-scale capacity proof
                -> M16 activated platforms + accessibility + i18n
```

M14 business modules may be split into independent child plans after M13. M16
platform plans are activated separately; Android remains authoritative until a
new platform passes its own build, compatibility, smoke, and release gates.

## 4. Goal-Loop Contract

Use this structure when creating a Codex goal for a milestone:

```text
Objective: Execute the named milestone plan from its absolute path end to end.

Constraints:
- Work only in the listed frontend/backend workspaces.
- Start local services through the managed lifecycle command.
- Follow plan checkboxes in order and use TDD for non-trivial behavior.
- Run targeted verification after each task and milestone smoke at the end.
- Record defects as P0/P1/P2/P3; fix P0/P1 before completion.
- Commit atomic verified changes; do not push unless explicitly requested.
- Stop only when exit criteria pass or a genuine external/user decision blocks
  progress.
```

The goal loop must leave a phase record containing commit IDs, commands, pass/
fail results, services left running, test data created, migrations applied,
defects, and external launch checks.

## 5. Milestone Controller

### Task 1: Execute M9 Local Autonomy And Acceptance Hardening

**Status:** COMPLETE on 2026-07-12. Evidence:
[`2026-07-10-rims-m9-execution-record.md`](2026-07-10-rims-m9-execution-record.md).

**Plan:**
`docs/superpowers/plans/2026-07-10-rims-m9-local-autonomy-acceptance-hardening.md`

**Entry:**

- [x] Frontend `main` includes the M8 integration baseline.
- [x] Backend health can be established locally from the documented workspace.
- [x] Current frontend smoke passes before M9 code changes.

**Exit:**

- [x] `doctor`, `up`, `status`, `logs`, `restart`, `smoke`, and `down` are
  non-interactive and tested.
- [x] AI can start backend and frontend from a stopped state.
- [x] Inventory, document, transaction, alert, non-standard, user, product, and
  warehouse lists expose reachable subsequent pages.
- [x] Critical UI integration flows and Android Emulator smoke pass.
- [x] M9 baseline timings and phase evidence are recorded.
- [x] P0/P1 are zero.

### Task 2: Generate And Execute M10 Android Field Operations Plan

**Status:** COMPLETE on 2026-07-13. Plan:
[`2026-07-10-rims-m10-android-field-operations.md`](2026-07-10-rims-m10-android-field-operations.md).
Evidence:
[`2026-07-10-rims-m10-execution-record.md`](2026-07-10-rims-m10-execution-record.md).

**Target plan path:**
`docs/superpowers/plans/2026-07-10-rims-m10-android-field-operations.md`

**Entry:** M9 exit is verified by the linked execution record. M10 must remap
the current scanner, attachment, Android manifest, permission, backend file, and
storage-provider code before planning implementation. It must inherit:

- `scripts/rims_local.ps1` as the only local service controller;
- deterministic M9 fixtures and the shared `acceptance-smoke.lock`;
- Web and Android `app_e2e_test.dart` smoke as regression gates;
- feature-first MVVM and paged repository contracts;
- `RIMS_E2E_RESULT` total/segment reporting and the M9 performance baseline.

- [x] Create the M10 plan from design Sections M10, 5.8, 5.9, and Android parts
  of Section 6.
- [x] Include exact scanner capability interfaces, permission flows, attachment
  contracts, Android configuration, emulator/device tests, and local storage
  provider commands.
- [x] Execute scan-to-search before scan-to-document workflows.
- [x] Execute attachments after camera lifecycle and permission tests pass.
- [x] Run Android compatibility and lifecycle fault tests.
- [x] Record M10 evidence and keep P0/P1 at zero.

### Task 3: Generate And Execute M11 Limited Offline Plan

**Status:** IN PROGRESS on 2026-07-13. Plan:
[`2026-07-10-rims-m11-limited-offline-sync.md`](2026-07-10-rims-m11-limited-offline-sync.md).
Evidence:
[`2026-07-10-rims-m11-execution-record.md`](2026-07-10-rims-m11-execution-record.md).

**Target plan path:**
`docs/superpowers/plans/2026-07-10-rims-m11-limited-offline-sync.md`

**Entry:** M10 online scan and attachment contracts are stable and current local
persistence options have been evaluated against supported platforms.

- [ ] Define versioned cache records, draft records, outbox operations, operation
  dependencies, migration ownership, encryption boundary, and retention.
- [ ] Implement cached reads before queued writes.
- [ ] Implement drafts before outbox processing.
- [ ] Add idempotency and conflict handling before automatic retry.
- [ ] Test airplane mode, latency, network switching, app termination, stale
  session, stale permission, duplicate delivery, and server conflict.
- [ ] Record M11 evidence and keep P0/P1 at zero.

### Task 4: Generate And Execute M12 Security And Compliance Plan

**Target plan path:**
`docs/superpowers/plans/2026-07-10-rims-m12-production-security-compliance.md`

**Entry:** M11 defines every locally persisted sensitive record and every queued
operation that security controls must protect.

- [ ] Map authentication, tokens, permissions, warehouse scope, local data,
  logs, attachments, providers, and runtime permissions.
- [ ] Implement environment isolation and HTTPS enforcement first.
- [ ] Implement session/token/device controls next.
- [ ] Implement local encryption, redaction, privacy, and retention controls.
- [ ] Add permission-boundary, replay, secret, dependency, static-analysis, and
  mobile-security gates.
- [ ] Record external legal/security approvals separately.
- [ ] Record M12 evidence and keep P0/P1 at zero.

### Task 5: Generate And Execute M13 Release And Observability Plan

**Target plan path:**
`docs/superpowers/plans/2026-07-10-rims-m13-release-observability.md`

**Entry:** M12 defines environment, secret, redaction, and provider security
rules that release and telemetry must obey.

- [ ] Define build variants, versioning, signing injection, obfuscation, symbols,
  and artifact inspection.
- [ ] Implement local observability providers and provider contract tests.
- [ ] Add crash, ANR, request, sync, workflow, version, and rollout diagnostics.
- [ ] Add optional/required upgrade, minimum version, feature flags, and kill
  switches.
- [ ] Generate and smoke-test a local Android release candidate.
- [ ] Record store/production activation separately.
- [ ] Record M13 evidence and keep P0/P1 at zero.

### Task 6: Generate And Execute M14 Business-Depth Plans

**Plan index path:**
`docs/superpowers/plans/2026-07-10-rims-m14-business-depth-index.md`

**Entry:** M13 establishes production-safe provider, release, and audit patterns.

- [ ] Prioritize activated modules with business acceptance criteria before
  writing child plans.
- [ ] Create separate child plans for product master and partners; batch/serial/
  expiry and location; additional inventory documents; approval; attachment and
  audit completion; import/export/print; notifications.
- [ ] Require permission, lifecycle, inventory-effect, audit, integration, and UI
  evidence for each child plan.
- [ ] Do not activate multi-tenant, subscription, or external integration
  candidates without a new design approval.
- [ ] Record M14 evidence and keep P0/P1 at zero after each child plan.

### Task 7: Generate And Execute M15 Capacity Plan

**Target plan path:**
`docs/superpowers/plans/2026-07-10-rims-m15-medium-scale-capacity.md`

**Entry:** Activated M14 data models and workflows are stable enough to generate
representative datasets.

- [ ] Generate deterministic 500-user, 100-warehouse, 100,000-product, and
  million-transaction fixtures locally.
- [ ] Define measurable query, API, render, launch, scroll, memory, disk, battery,
  and network budgets from M9 baselines.
- [ ] Optimize only measured bottlenecks.
- [ ] Run load, soak, concurrency, duplicate, and retry-storm tests.
- [ ] Add asynchronous jobs for exports/reports that exceed synchronous budgets.
- [ ] Record capacity evidence and keep P0/P1 at zero.

### Task 8: Generate And Execute M16 Platform And Experience Plans

**Plan index path:**
`docs/superpowers/plans/2026-07-10-rims-m16-platform-experience-index.md`

**Entry:** Android business behavior and medium-scale budgets are stable.

- [ ] Create independent plans for responsive layout, iOS, Windows, Web,
  localization, accessibility, and user support/preferences.
- [ ] Keep domain rules shared and isolate platform capabilities.
- [ ] Require each activated platform to pass build, compatibility, smoke, and
  release gates.
- [ ] Keep inactive long-term candidates in the design catalogue only.
- [ ] Record M16 evidence and keep P0/P1 at zero.

## 6. Cross-Milestone Invariants

- [ ] Authentication failure never publishes a false success or leaks secrets.
- [ ] Warehouse context is included and verified for warehouse-scoped requests.
- [ ] UI permission controls never replace server authorization.
- [ ] Stock quantity changes only through authoritative backend transactions.
- [ ] Create/lifecycle requests remain duplicate-safe.
- [ ] Existing valid data is preserved on recoverable refresh failure.
- [ ] Offline state is never presented as current authoritative server state.
- [ ] Production providers remain replaceable by local contract-tested providers.
- [ ] Migration, rollback/safe reset, seed, and compatibility evidence accompanies
  every persistent-data change.
- [ ] Logs, diagnostics, screenshots, exports, and test output do not reveal
  production secrets or personal data.

## 7. Program Verification

Run after each milestone from the frontend root:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\rims_local.ps1 -Command doctor -Target web -Output Json
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\rims_local.ps1 -Command up -Target web -IncludeDependencies -Output Json
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\rims_local.ps1 -Command smoke -Target web -Output Json
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\rims_local.ps1 -Command status -Output Json
```

Expected: every command exits `0`; JSON reports healthy managed components and
the milestone smoke reports no failed gate.

Run the current frontend baseline gate:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\rims_smoke.ps1
```

Expected: `RIMS smoke checks passed.`

Run backend gates through WSL:

```powershell
wsl -e bash -lc 'cd "/mnt/e/My Work/RIMS/rims-goProgect" && ~/local/go/bin/go test ./... && ~/local/go/bin/go build ./...'
```

Expected: exit `0` with no failed Go package.

When a milestone does not yet implement a later provider or platform, its plan
must omit that provider/platform gate rather than report an unexecuted gate as
passed.

## 8. Program Completion

- [ ] M9-M16 activated milestone exits pass in order.
- [ ] Android production workflows pass public-cloud staging and production
  activation checks.
- [ ] Inventory/document correctness survives concurrency, retry, app restart,
  offline drafts, and permission change.
- [ ] Medium-scale capacity evidence passes.
- [ ] Security, privacy, observability, release, rollback, recovery, and support
  controls are active.
- [ ] Activated providers and platforms pass local contracts and production
  verification.
- [ ] External store, legal, security, recovery, and operational approvals are
  recorded as complete.
- [ ] Documentation and operational ownership match delivered behavior.
