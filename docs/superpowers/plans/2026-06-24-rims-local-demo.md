# RIMS Local Demo Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn the current static RIMS Flutter UI into a usable local demo with complete login, session handling, role-aware display, and interactive feature flows that do not require a live backend.

**Architecture:** Keep the existing feature-first MVVM shape. Authentication uses a local demo repository with hard-coded accounts, a session controller, and route guards; business pages keep presentation ViewModels and add local interactions for search, filtering, document creation, report period switching, and logout.

**Tech Stack:** Flutter, Dart, Provider, GoRouter, existing generated PNG assets, `flutter_test`.

---

## Scope

The demo runs entirely on local mock data. It proves the front-end product flow:

- Login with `admin/admin123` or `user/user123`.
- Reject empty or invalid credentials with visible messages.
- Protect the app shell from unauthenticated access.
- Show current user, role, and warehouse context in the app.
- Provide interactive inventory search and status filtering.
- Provide a usable document creation demo with form validation and recent-list insertion.
- Provide report period switching with visible data changes.
- Provide logout from the profile page.

No real API integration, scanner camera, file upload, document submission, or persistent token storage is added in this plan.

## Task 1: Local Authentication And Session

**Files:**
- Create: `rims_frontend/lib/features/auth/domain/entities/demo_user.dart`
- Create: `rims_frontend/lib/features/auth/domain/repositories/auth_repository.dart`
- Create: `rims_frontend/lib/features/auth/data/repositories/demo_auth_repository.dart`
- Create: `rims_frontend/lib/features/auth/presentation/view_models/auth_session_controller.dart`
- Modify: `rims_frontend/lib/features/auth/presentation/view_models/login_view_model.dart`
- Modify: `rims_frontend/lib/features/auth/presentation/pages/login_page.dart`
- Modify: `rims_frontend/lib/routes/app_router.dart`
- Modify: `rims_frontend/lib/app.dart`
- Test: `rims_frontend/test/features/auth/login_view_model_test.dart`
- Test: `rims_frontend/test/app_static_ui_test.dart`

- [ ] Write failing tests for empty credentials, invalid credentials, successful demo login, shell guard, and logout.
- [ ] Implement local demo users, repository, session controller, login ViewModel, guarded router, and login form state.
- [ ] Verify auth tests and app smoke tests pass.

## Task 2: Inventory Interaction

**Files:**
- Modify: `rims_frontend/lib/features/inventory/presentation/view_models/inventory_view_model.dart`
- Modify: `rims_frontend/lib/features/inventory/presentation/pages/inventory_page.dart`
- Test: `rims_frontend/test/features/inventory/inventory_view_model_test.dart`

- [ ] Write failing tests for keyword search and status tab filtering.
- [ ] Convert the inventory ViewModel into a local state model with `query`, `selectedTab`, and filtered products.
- [ ] Wire the page search field and segmented tabs to the ViewModel.
- [ ] Verify inventory tests and smoke tests pass.

## Task 3: Document Creation Demo

**Files:**
- Modify: `rims_frontend/lib/features/documents/presentation/view_models/documents_view_model.dart`
- Modify: `rims_frontend/lib/features/documents/presentation/pages/documents_page.dart`
- Modify: `rims_frontend/lib/features/documents/presentation/widgets/document_action_card.dart`
- Test: `rims_frontend/test/features/documents/documents_view_model_test.dart`

- [ ] Write failing tests for selecting a document type, rejecting empty quantity, creating a demo document, and inserting it into recent documents.
- [ ] Add ViewModel state for selected action, product name, quantity, validation error, and recent document insertion.
- [ ] Add a compact form under the action grid and make action cards tappable.
- [ ] Verify document tests and smoke tests pass.

## Task 4: Report Period Switching And Logout Surface

**Files:**
- Modify: `rims_frontend/lib/features/reports/presentation/view_models/reports_view_model.dart`
- Modify: `rims_frontend/lib/features/reports/presentation/pages/reports_page.dart`
- Modify: `rims_frontend/lib/features/profile/presentation/view_models/profile_view_model.dart`
- Modify: `rims_frontend/lib/features/profile/presentation/pages/profile_page.dart`
- Test: `rims_frontend/test/features/reports/reports_view_model_test.dart`
- Test: `rims_frontend/test/features/profile/profile_view_model_test.dart`

- [ ] Write failing tests for report period switching and profile values coming from the active session.
- [ ] Add report period options and visible selection controls.
- [ ] Pass the active user into Profile and add a logout button.
- [ ] Verify report, profile, and app smoke tests pass.

## Task 5: Final Verification

**Files:**
- Inspect all changed source and test files.

- [ ] Run `flutter pub get --offline`.
- [ ] Run `flutter analyze --no-pub`.
- [ ] Run `flutter test --no-pub`.
- [ ] Run `git diff --check`.
- [ ] Review `git status --short` and keep `.superpowers/` unstaged.

