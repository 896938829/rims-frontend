# RIMS Static UI Design

## Context

The RIMS Flutter frontend currently contains the Flutter app shell, dependency
baseline, and generated blue visual assets. `lib/app.dart` is still near the
default `Hello World` state, while `AppImages` and `AppIcons` already expose the
generated UI assets required by the design overview.

This work is intentionally UI-only. It should implement the page surfaces shown
in the design direction without wiring real authentication, API calls, warehouse
switching, permissions, scanning, form submission, or business workflows.

## Decision

Build a static, polished Flutter UI using feature-first MVVM boundaries:

- Pages render UI.
- ViewModels expose fixed mock display data.
- Shared UI primitives live in a small reusable component layer.
- Existing raster assets are used for illustrations, icons, product thumbnails,
  navigation symbols, status marks, and module identifiers.
- Text, labels, numbers, charts, chips, cards, tabs, and workflows remain Flutter
  widgets so the interface stays responsive and can later be connected to data.

The selected scope is:

- A static login/entry page.
- A 5-tab app shell.
- Home, inventory, documents, reports, and profile pages.
- Role, warehouse, permission, API guard, and backend-module display surfaces.

The selected visual fidelity is design-led but app-realistic: keep the blue RIMS
brand feeling from the design overview, while using maintainable Flutter widgets
and practical mobile information density.

## Non-Goals

This UI phase will not implement:

- Real login, session persistence, or token handling.
- Real API integration or repository data loading.
- Real role-based permission enforcement.
- Real warehouse switching behavior.
- Real scanning, camera, upload, export, or share flows.
- Real inventory mutation, document submission, or report calculation.

Those capabilities belong to later business-logic milestones after the static
UI is validated.

## Architecture

Use the existing project direction from `AGENTS.md`: feature-first MVVM with
repositories and domain layers reserved for real business logic.

For this UI-only phase, each page feature may use a lightweight presentation
structure:

```text
lib/
  core/
    theme/
    resources/
    widgets/
  features/
    auth/
      presentation/
        pages/
        view_models/
        widgets/
    shell/
      presentation/
        pages/
        widgets/
    home/
      presentation/
        pages/
        view_models/
        widgets/
    inventory/
      presentation/
        pages/
        view_models/
        widgets/
    documents/
      presentation/
        pages/
        view_models/
        widgets/
    reports/
      presentation/
        pages/
        view_models/
        widgets/
    profile/
      presentation/
        pages/
        view_models/
        widgets/
```

No data or domain directories are required for these static UI modules unless a
page needs local typed display models. When used, those models should remain
presentation-only and should not pretend to be API DTOs.

## Page Scope

### Login

The login page presents the RIMS brand, a blue warehouse/product visual, and
static account/password or verification-code entry controls. The primary action
may navigate into the static app shell, but it does not authenticate.

### Shell

The shell provides the persistent 5-tab navigation shown in the design overview:

- Home.
- Inventory.
- Documents.
- Reports.
- Profile.

It should use the generated bottom navigation icons exposed through `AppIcons`.

### Home

The home page should communicate the role-aware inventory dashboard:

- Current warehouse context such as "Shanghai Warehouse".
- Greeting hero using the generated warehouse hero asset.
- Metric cards for product count, total inventory, and warning quantity.
- Quick actions for scan sale, return, inbound, and transfer.
- Inventory warning summary.
- Recent document list.

### Inventory

The inventory page should communicate inventory lookup and status scanning:

- Warehouse context and notification affordance.
- Search and filter controls.
- Segmented view for standard, product, and non-standard inventory.
- Inventory overview metrics.
- Product rows using generated product thumbnails.
- Status chips for low stock, available quantity, standard, and non-standard
  states.

### Documents

The documents page should communicate operational document workflows:

- Static cards for sale outbound, purchase inbound, transfer, stocktake, return,
  and non-standard conversion.
- A simple workflow progress strip for document creation, confirmation,
  submission, and completion.
- Recent document rows with status chips.

### Reports

The reports page should communicate analysis without real chart data:

- Date range selector.
- Static sales trend line chart.
- Product sales ranking bars.
- Inventory status ring or donut visualization.
- Warehouse-scoped summary cards.

Charts may be drawn with `CustomPaint` or small Flutter widget compositions. No
real chart data source is needed in this phase.

### Profile

The profile page absorbs the right-side design overview content into an app page:

- User avatar, name, work ID, and current role.
- Current warehouse and notification settings rows.
- API guard tags such as JWT, warehouse ID, permission, idempotency key, and
  trace ID.
- Backend module tags such as user, warehouse, product, document, report, file,
  and audit.
- Permission display for administrator and normal user capabilities.

## Visual System

The visual language should be calm, data-first, and blue-branded:

- Use a light blue-gray page background.
- Use white cards with restrained borders and shadows.
- Use blue for selected navigation, primary actions, hero areas, and important
  metrics.
- Keep status colors semantic and consistent across pages.
- Avoid making every surface blue; operational screens should stay readable and
  scannable.
- Keep card radius modest and consistent with the existing mobile design.

Assets should follow the project resource rule:

- Use `AppImages` for hero, illustrations, and product thumbnails.
- Use `AppIcons` for action, navigation, hint, module, and status icons.
- Do not repeat raw asset paths inside pages.

## Shared Components

Create or evolve a small component set only where reuse is clear:

- `RimsScaffold`: common safe area, background, and horizontal page padding.
- `RimsBottomNavigation`: 5-tab bottom navigation using generated nav icons.
- `RimsMetricCard`: numeric cards for product count, inventory total, warning
  count, revenue, or document totals.
- `RimsQuickActionButton`: icon and label buttons for common operations.
- `RimsSectionHeader`: section title plus optional trailing action.
- `RimsStatusChip`: compact state display for success, warning, pending, error,
  and info states.
- `RimsInfoCard`: generic content card for modules, settings rows, and
  permission displays.
- `RimsMiniChart`: static chart primitives for line, bar, and ring visuals.

Components should stay UI-focused. They should not fetch data, parse API errors,
or own business decisions.

## Static ViewModels

Each page ViewModel may expose immutable display data:

- Home metrics, quick actions, warnings, and recent documents.
- Inventory tabs, metrics, and product rows.
- Document action cards, workflow steps, and recent documents.
- Report filters, chart points, ranking rows, and inventory status buckets.
- Profile user rows, API guard tags, backend module tags, and permission groups.

These ViewModels can be synchronous and static. They exist to keep pages from
embedding large literal lists directly in widget build methods and to make later
data replacement easier.

## Error And Empty States

Because this phase is UI-only, errors are represented as static samples rather
than real failures. Include representative empty, warning, and pending states
where they help validate the design:

- Inventory warning cards.
- Pending document chips.
- Empty or low-quantity inventory state.
- Permission explanation rows in profile.

Do not implement real retry, offline, or authentication-expired behavior in this
phase.

## Testing And Verification

Verification should focus on UI wiring and regression safety:

- `flutter analyze --no-pub`.
- `flutter test --no-pub`.
- `git diff --check`.
- Widget tests for the app starting, login entry rendering, shell tabs rendering,
  and key static labels appearing.

If possible, run the app in a browser or emulator for visual inspection after
implementation. The acceptance criteria should include screenshots or manual
inspection notes for the login page and the 5-tab shell.

## M0-MN Plan

### M0: UI Foundation

Establish theme tokens, text styles, common scaffold, cards, chips, metric cards,
quick actions, mini chart primitives, and the 5-tab shell. Replace `Hello World`
with the RIMS static UI entry.

Acceptance:

- The app launches into the static RIMS UI path.
- Shared resources are referenced through `AppImages` and `AppIcons`.
- Analyzer and widget smoke tests pass.

### M1: Home UI

Implement the warehouse context, blue hero, key metrics, quick actions, inventory
warnings, and recent documents.

Acceptance:

- Home visually resembles the primary phone screen in the design overview.
- Home content is driven by static ViewModel display data.

### M2: Inventory UI

Implement search, filter, segmented inventory views, overview metrics, product
rows, thumbnails, and inventory status chips.

Acceptance:

- Inventory communicates product lookup, warehouse scope, stock quantity, and
  standard/non-standard state.

### M3: Documents UI

Implement document action cards, workflow progress, recent document rows, and
document status chips.

Acceptance:

- Documents communicates sale, return, inbound, transfer, stocktake, and
  conversion entry points without real submission logic.

### M4: Reports UI

Implement date range display, static trend chart, product ranking bars, inventory
status ring, and summary cards.

Acceptance:

- Reports communicates analysis structure without real report calculation.

### M5: Profile, Role, Permission, API Guard UI

Implement personal info, current role, current warehouse, settings rows, API
guard tags, backend module tags, and role permission summaries.

Acceptance:

- The design overview's role, permission, API, and backend-module story is
  represented inside the app UI.

### M6: Login UI And Polish

Implement the static login page and entry path into the shell. Polish spacing,
responsive constraints, empty states, tests, and visual inspection.

Acceptance:

- A user can start at the login UI and enter the static 5-tab app.
- `flutter analyze --no-pub`, `flutter test --no-pub`, and `git diff --check`
  pass.

### MN: Business Logic Integration

After the static UI is accepted, plan separate logic milestones for
authentication, warehouse switching, permissions, API integration, scanner
flows, document forms, report data, error mapping, and cache/offline behavior.
