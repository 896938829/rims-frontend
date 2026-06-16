# RIMS Static UI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a polished UI-only RIMS Flutter app with a static login screen, 5-tab shell, and static Home, Inventory, Documents, Reports, and Profile pages based on the blue design overview.

**Architecture:** Use feature-first MVVM at the presentation layer. Pages render widgets, static ViewModels expose immutable mock display data, and shared RIMS UI primitives live under `core/widgets` and `core/theme`. No real API, authentication, permission enforcement, scanner, warehouse switching, document submission, or report calculation is implemented in this plan.

**Tech Stack:** Flutter, Dart, Provider, existing generated PNG assets through `AppImages` and `AppIcons`, widget tests with `flutter_test`.

---

## Source Spec

Implement the approved design in:

```text
docs/superpowers/specs/2026-06-16-rims-static-ui-design.md
```

Use the existing agent guide:

```text
AGENTS.md
```

The implementation must run from:

```powershell
cd rims_frontend
```

Baseline verification commands:

```powershell
flutter pub get --offline
flutter analyze --no-pub
flutter test --no-pub
git diff --check
```

## File Structure

Create or modify these files under `rims_frontend`:

```text
lib/
  app.dart
  main.dart
  core/
    theme/
      app_colors.dart
      app_text_styles.dart
      app_theme.dart
    widgets/
      rims_bottom_navigation.dart
      rims_card.dart
      rims_metric_card.dart
      rims_mini_charts.dart
      rims_page_scaffold.dart
      rims_quick_action_button.dart
      rims_section_header.dart
      rims_status_chip.dart
  features/
    auth/
      presentation/
        pages/
          login_page.dart
        view_models/
          login_view_model.dart
    shell/
      presentation/
        pages/
          app_shell_page.dart
        view_models/
          app_tab.dart
    home/
      presentation/
        pages/
          home_page.dart
        view_models/
          home_view_model.dart
        widgets/
          home_hero_card.dart
          inventory_warning_card.dart
          recent_document_tile.dart
    inventory/
      presentation/
        pages/
          inventory_page.dart
        view_models/
          inventory_view_model.dart
        widgets/
          inventory_product_tile.dart
    documents/
      presentation/
        pages/
          documents_page.dart
        view_models/
          documents_view_model.dart
        widgets/
          document_action_card.dart
          document_flow_strip.dart
    reports/
      presentation/
        pages/
          reports_page.dart
        view_models/
          reports_view_model.dart
        widgets/
          report_ranking_bar.dart
    profile/
      presentation/
        pages/
          profile_page.dart
        view_models/
          profile_view_model.dart
        widgets/
          api_guard_chip_group.dart
          permission_group_card.dart
  routes/
    app_router.dart
    route_paths.dart
test/
  app_static_ui_test.dart
  core/
    widgets/
      rims_status_chip_test.dart
  features/
    home/
      home_view_model_test.dart
    inventory/
      inventory_view_model_test.dart
    documents/
      documents_view_model_test.dart
    reports/
      reports_view_model_test.dart
    profile/
      profile_view_model_test.dart
```

Keep feature data/domain folders out of this UI-only implementation unless later
business logic needs them.

## Task 0: Baseline And Worktree Hygiene

**Files:**
- Inspect: `rims_frontend/pubspec.yaml`
- Inspect: `rims_frontend/lib/app.dart`
- Inspect: `rims_frontend/lib/core/resources/app_images.dart`
- Inspect: `rims_frontend/lib/core/resources/app_icons.dart`

- [ ] **Step 1: Check git state**

Run from the repo root:

```powershell
git status --short --branch
```

Expected: only unrelated local files may be dirty. Do not stage `.superpowers/`.

- [ ] **Step 2: Check Flutter dependencies offline**

Run:

```powershell
cd rims_frontend
flutter pub get --offline
```

Expected: dependencies resolve from the existing lockfile.

- [ ] **Step 3: Run baseline tests**

Run:

```powershell
flutter analyze --no-pub
flutter test --no-pub
```

Expected: record current failures if any. Do not fix unrelated failures in this task.

- [ ] **Step 4: Commit**

No commit is required for this inspection task.

## Task 1: Theme And Shared UI Foundation

**Files:**
- Create: `rims_frontend/lib/core/theme/app_colors.dart`
- Create: `rims_frontend/lib/core/theme/app_text_styles.dart`
- Create: `rims_frontend/lib/core/theme/app_theme.dart`
- Create: `rims_frontend/lib/core/widgets/rims_card.dart`
- Create: `rims_frontend/lib/core/widgets/rims_page_scaffold.dart`
- Create: `rims_frontend/lib/core/widgets/rims_section_header.dart`
- Create: `rims_frontend/lib/core/widgets/rims_status_chip.dart`
- Test: `rims_frontend/test/core/widgets/rims_status_chip_test.dart`

- [ ] **Step 1: Write the failing status chip test**

Create `test/core/widgets/rims_status_chip_test.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rims_frontend/core/widgets/rims_status_chip.dart';

void main() {
  testWidgets('RimsStatusChip renders label and semantic kind', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: RimsStatusChip(
            label: '低库存',
            kind: RimsStatusKind.warning,
          ),
        ),
      ),
    );

    expect(find.text('低库存'), findsOneWidget);
    expect(find.byType(RimsStatusChip), findsOneWidget);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```powershell
flutter test --no-pub test/core/widgets/rims_status_chip_test.dart
```

Expected: FAIL because `RimsStatusChip` does not exist.

- [ ] **Step 3: Add theme tokens**

Create these public APIs:

```dart
// lib/core/theme/app_colors.dart
import 'package:flutter/material.dart';

abstract final class AppColors {
  static const Color primary = Color(0xFF0F6BFF);
  static const Color primaryDark = Color(0xFF0A3D91);
  static const Color primaryLight = Color(0xFFEAF3FF);
  static const Color background = Color(0xFFF4F8FF);
  static const Color surface = Colors.white;
  static const Color border = Color(0xFFD8E5F8);
  static const Color textPrimary = Color(0xFF102A56);
  static const Color textSecondary = Color(0xFF61708A);
  static const Color success = Color(0xFF12A87A);
  static const Color warning = Color(0xFFF59E0B);
  static const Color error = Color(0xFFE5484D);
  static const Color info = Color(0xFF2563EB);
}
```

```dart
// lib/core/theme/app_text_styles.dart
import 'package:flutter/material.dart';

import 'app_colors.dart';

abstract final class AppTextStyles {
  static const TextStyle headingLarge = TextStyle(
    fontSize: 24,
    fontWeight: FontWeight.w700,
    color: AppColors.textPrimary,
  );

  static const TextStyle headingMedium = TextStyle(
    fontSize: 18,
    fontWeight: FontWeight.w700,
    color: AppColors.textPrimary,
  );

  static const TextStyle titleMedium = TextStyle(
    fontSize: 15,
    fontWeight: FontWeight.w700,
    color: AppColors.textPrimary,
  );

  static const TextStyle bodyMedium = TextStyle(
    fontSize: 14,
    fontWeight: FontWeight.w500,
    color: AppColors.textPrimary,
  );

  static const TextStyle bodySmall = TextStyle(
    fontSize: 12,
    fontWeight: FontWeight.w500,
    color: AppColors.textSecondary,
  );

  static const TextStyle metric = TextStyle(
    fontSize: 22,
    fontWeight: FontWeight.w800,
    color: AppColors.textPrimary,
  );
}
```

```dart
// lib/core/theme/app_theme.dart
import 'package:flutter/material.dart';

import 'app_colors.dart';

abstract final class AppTheme {
  static ThemeData get light {
    return ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(
        seedColor: AppColors.primary,
        brightness: Brightness.light,
      ),
      scaffoldBackgroundColor: AppColors.background,
      fontFamily: 'Roboto',
      appBarTheme: const AppBarTheme(
        backgroundColor: AppColors.background,
        foregroundColor: AppColors.textPrimary,
        elevation: 0,
        centerTitle: false,
      ),
    );
  }
}
```

- [ ] **Step 4: Add shared widget APIs**

Create widgets with these constructors:

```dart
// lib/core/widgets/rims_status_chip.dart
import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import '../theme/app_text_styles.dart';

enum RimsStatusKind { success, warning, error, info, pending }

final class RimsStatusChip extends StatelessWidget {
  const RimsStatusChip({
    required this.label,
    required this.kind,
    super.key,
  });

  final String label;
  final RimsStatusKind kind;

  @override
  Widget build(BuildContext context) {
    final color = switch (kind) {
      RimsStatusKind.success => AppColors.success,
      RimsStatusKind.warning => AppColors.warning,
      RimsStatusKind.error => AppColors.error,
      RimsStatusKind.info => AppColors.info,
      RimsStatusKind.pending => AppColors.textSecondary,
    };

    return DecoratedBox(
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Text(
          label,
          style: AppTextStyles.bodySmall.copyWith(color: color),
        ),
      ),
    );
  }
}
```

```dart
// lib/core/widgets/rims_card.dart
import 'package:flutter/material.dart';

import '../theme/app_colors.dart';

final class RimsCard extends StatelessWidget {
  const RimsCard({
    required this.child,
    this.padding = const EdgeInsets.all(14),
    super.key,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.border),
        boxShadow: [
          BoxShadow(
            color: AppColors.primaryDark.withValues(alpha: 0.05),
            blurRadius: 18,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Padding(padding: padding, child: child),
    );
  }
}
```

```dart
// lib/core/widgets/rims_page_scaffold.dart
import 'package:flutter/material.dart';

import '../theme/app_colors.dart';

final class RimsPageScaffold extends StatelessWidget {
  const RimsPageScaffold({
    required this.child,
    this.padding = const EdgeInsets.fromLTRB(16, 12, 16, 24),
    super.key,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: AppColors.background,
      child: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: Padding(padding: padding, child: child),
          ),
        ),
      ),
    );
  }
}
```

```dart
// lib/core/widgets/rims_section_header.dart
import 'package:flutter/material.dart';

import '../theme/app_text_styles.dart';

final class RimsSectionHeader extends StatelessWidget {
  const RimsSectionHeader({
    required this.title,
    this.trailing,
    super.key,
  });

  final String title;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(child: Text(title, style: AppTextStyles.titleMedium)),
        if (trailing != null) trailing!,
      ],
    );
  }
}
```

- [ ] **Step 5: Run the widget test**

Run:

```powershell
flutter test --no-pub test/core/widgets/rims_status_chip_test.dart
```

Expected: PASS.

- [ ] **Step 6: Run analyzer**

Run:

```powershell
flutter analyze --no-pub
```

Expected: PASS for newly added files.

- [ ] **Step 7: Commit**

Run:

```powershell
git add lib/core/theme lib/core/widgets test/core/widgets/rims_status_chip_test.dart
git commit -m "feat: add static ui theme foundation"
```

## Task 2: Shell And Static Login Entry

**Files:**
- Create: `rims_frontend/lib/features/shell/presentation/view_models/app_tab.dart`
- Create: `rims_frontend/lib/features/shell/presentation/pages/app_shell_page.dart`
- Create: `rims_frontend/lib/core/widgets/rims_bottom_navigation.dart`
- Create: `rims_frontend/lib/features/auth/presentation/view_models/login_view_model.dart`
- Create: `rims_frontend/lib/features/auth/presentation/pages/login_page.dart`
- Create: `rims_frontend/lib/routes/route_paths.dart`
- Create: `rims_frontend/lib/routes/app_router.dart`
- Modify: `rims_frontend/lib/app.dart`
- Test: `rims_frontend/test/app_static_ui_test.dart`

- [ ] **Step 1: Write the failing app smoke tests**

Create `test/app_static_ui_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:rims_frontend/main.dart';

void main() {
  testWidgets('app starts on static login page', (tester) async {
    await tester.pumpWidget(const MainApp());
    await tester.pump();

    expect(find.text('RIMS'), findsWidgets);
    expect(find.text('登录'), findsOneWidget);
    expect(find.text('进入静态演示'), findsOneWidget);
  });

  testWidgets('login entry opens static 5-tab shell', (tester) async {
    await tester.pumpWidget(const MainApp());
    await tester.pump();

    await tester.tap(find.text('进入静态演示'));
    await tester.pumpAndSettle();

    expect(find.text('首页'), findsWidgets);
    expect(find.text('库存'), findsWidgets);
    expect(find.text('单据'), findsWidgets);
    expect(find.text('报表'), findsWidgets);
    expect(find.text('我的'), findsWidgets);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```powershell
flutter test --no-pub test/app_static_ui_test.dart
```

Expected: FAIL because the app still renders the old startup page.

- [ ] **Step 3: Implement static routes and app shell**

Create these public APIs:

```dart
// lib/routes/route_paths.dart
abstract final class RoutePaths {
  static const String login = '/';
  static const String shell = '/app';
}
```

```dart
// lib/features/shell/presentation/view_models/app_tab.dart
import '../../../../core/resources/app_icons.dart';

enum AppTab {
  home(
    label: '首页',
    activeIcon: AppIcons.navHomeActive,
    inactiveIcon: AppIcons.navHomeInactive,
  ),
  inventory(
    label: '库存',
    activeIcon: AppIcons.navInventoryActive,
    inactiveIcon: AppIcons.navInventoryInactive,
  ),
  documents(
    label: '单据',
    activeIcon: AppIcons.navDocumentsActive,
    inactiveIcon: AppIcons.navDocumentsInactive,
  ),
  reports(
    label: '报表',
    activeIcon: AppIcons.navReportsActive,
    inactiveIcon: AppIcons.navReportsInactive,
  ),
  profile(
    label: '我的',
    activeIcon: AppIcons.navProfileActive,
    inactiveIcon: AppIcons.navProfileInactive,
  );

  const AppTab({
    required this.label,
    required this.activeIcon,
    required this.inactiveIcon,
  });

  final String label;
  final String activeIcon;
  final String inactiveIcon;
}
```

`RimsBottomNavigation` must accept:

```dart
const RimsBottomNavigation({
  required AppTab currentTab,
  required ValueChanged<AppTab> onTabSelected,
  Key? key,
});
```

`AppShellPage` must be a `StatefulWidget` that owns the selected `AppTab` and
renders page widgets for each tab.

- [ ] **Step 4: Implement static login**

`LoginViewModel` exposes:

```dart
final class LoginViewModel {
  const LoginViewModel();

  String get title => 'RIMS';
  String get subtitle => '零售端智能库存管理系统';
  String get warehouseHint => '登录后查看当前仓库、库存预警和业务单据';
}
```

`LoginPage` must render:

- `RIMS`.
- `零售端智能库存管理系统`.
- Text fields labeled `账号` and `密码`.
- A primary button labeled `进入静态演示`.
- The generated `AppImages.homeWarehouseHero` asset.

Button behavior:

```dart
context.go(RoutePaths.shell);
```

- [ ] **Step 5: Wire `MaterialApp.router`**

`app.dart` must use:

```dart
return MaterialApp.router(
  title: 'RIMS',
  theme: AppTheme.light,
  routerConfig: createAppRouter(),
);
```

`createAppRouter()` must route `RoutePaths.login` to `LoginPage` and
`RoutePaths.shell` to `AppShellPage`.

- [ ] **Step 6: Add temporary tab page bodies**

Until M1-M5 replace them, `AppShellPage` may render centered labels:

```dart
const Center(child: Text('首页'));
const Center(child: Text('库存'));
const Center(child: Text('单据'));
const Center(child: Text('报表'));
const Center(child: Text('我的'));
```

- [ ] **Step 7: Run tests**

Run:

```powershell
flutter test --no-pub test/app_static_ui_test.dart
```

Expected: PASS.

- [ ] **Step 8: Run analyzer**

Run:

```powershell
flutter analyze --no-pub
```

Expected: PASS.

- [ ] **Step 9: Commit**

Run:

```powershell
git add lib/app.dart lib/routes lib/features/auth lib/features/shell lib/core/widgets/rims_bottom_navigation.dart test/app_static_ui_test.dart
git commit -m "feat: add static login and app shell"
```

## Task 3: Home UI

**Files:**
- Create: `rims_frontend/lib/core/widgets/rims_metric_card.dart`
- Create: `rims_frontend/lib/core/widgets/rims_quick_action_button.dart`
- Create: `rims_frontend/lib/features/home/presentation/view_models/home_view_model.dart`
- Create: `rims_frontend/lib/features/home/presentation/pages/home_page.dart`
- Create: `rims_frontend/lib/features/home/presentation/widgets/home_hero_card.dart`
- Create: `rims_frontend/lib/features/home/presentation/widgets/inventory_warning_card.dart`
- Create: `rims_frontend/lib/features/home/presentation/widgets/recent_document_tile.dart`
- Modify: `rims_frontend/lib/features/shell/presentation/pages/app_shell_page.dart`
- Test: `rims_frontend/test/features/home/home_view_model_test.dart`
- Modify: `rims_frontend/test/app_static_ui_test.dart`

- [ ] **Step 1: Write the failing Home ViewModel test**

Create `test/features/home/home_view_model_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:rims_frontend/features/home/presentation/view_models/home_view_model.dart';

void main() {
  test('HomeViewModel exposes static dashboard data', () {
    const viewModel = HomeViewModel();

    expect(viewModel.warehouseName, '上海仓');
    expect(viewModel.metrics, hasLength(3));
    expect(viewModel.quickActions, hasLength(4));
    expect(viewModel.warnings, hasLength(3));
    expect(viewModel.recentDocuments, hasLength(3));
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```powershell
flutter test --no-pub test/features/home/home_view_model_test.dart
```

Expected: FAIL because `HomeViewModel` does not exist.

- [ ] **Step 3: Implement Home display models**

Create `HomeViewModel` and presentation records:

```dart
import '../../../../core/resources/app_icons.dart';

final class HomeMetric {
  const HomeMetric({
    required this.label,
    required this.value,
    required this.delta,
  });

  final String label;
  final String value;
  final String delta;
}

final class HomeQuickAction {
  const HomeQuickAction({
    required this.label,
    required this.icon,
  });

  final String label;
  final String icon;
}

final class InventoryWarning {
  const InventoryWarning({
    required this.label,
    required this.count,
    required this.level,
  });

  final String label;
  final int count;
  final String level;
}

final class RecentDocument {
  const RecentDocument({
    required this.title,
    required this.number,
    required this.status,
  });

  final String title;
  final String number;
  final String status;
}

final class HomeViewModel {
  const HomeViewModel();

  String get warehouseName => '上海仓';
  String get greeting => 'Good morning, 张三';

  List<HomeMetric> get metrics => const [
        HomeMetric(label: '商品数', value: '1,268', delta: '+12%'),
        HomeMetric(label: '库存总量', value: '18,732', delta: '+8%'),
        HomeMetric(label: '预警数量', value: '23', delta: '+15%'),
      ];

  List<HomeQuickAction> get quickActions => const [
        HomeQuickAction(label: '扫码销售', icon: AppIcons.actionScan),
        HomeQuickAction(label: '退货', icon: AppIcons.actionReturn),
        HomeQuickAction(label: '入库', icon: AppIcons.actionInbound),
        HomeQuickAction(label: '调拨', icon: AppIcons.actionTransfer),
      ];

  List<InventoryWarning> get warnings => const [
        InventoryWarning(label: '低库存', count: 23, level: 'warning'),
        InventoryWarning(label: '超储商品', count: 15, level: 'warning'),
        InventoryWarning(label: '滞销预警', count: 18, level: 'info'),
      ];

  List<RecentDocument> get recentDocuments => const [
        RecentDocument(title: '销售出库单', number: 'SO-20240518-0012', status: '已完成'),
        RecentDocument(title: '采购入库单', number: 'PO-20240518-0008', status: '待确认'),
        RecentDocument(title: '库存盘点单', number: 'ST-20240517-0003', status: '待结转'),
      ];
}
```

- [ ] **Step 4: Add reusable metric and quick action widgets**

`RimsMetricCard` constructor:

```dart
const RimsMetricCard({
  required String label,
  required String value,
  String? delta,
  Key? key,
});
```

`RimsQuickActionButton` constructor:

```dart
const RimsQuickActionButton({
  required String label,
  required String iconPath,
  VoidCallback? onPressed,
  Key? key,
});
```

Both widgets should use `RimsCard`, `AppTextStyles`, and existing PNG icons.

- [ ] **Step 5: Implement `HomePage`**

`HomePage` must render:

- `上海仓`.
- `Good morning, 张三`.
- `商品数`, `库存总量`, `预警数量`.
- `扫码销售`, `退货`, `入库`, `调拨`.
- `库存预警`.
- `最近单据`.
- Generated hero image from `AppImages.homeWarehouseHero`.

- [ ] **Step 6: Wire Home into shell**

Replace the temporary home body in `AppShellPage` with:

```dart
const HomePage()
```

- [ ] **Step 7: Extend app smoke test**

Add this assertion after entering the shell:

```dart
expect(find.text('Good morning, 张三'), findsOneWidget);
expect(find.text('库存预警'), findsOneWidget);
```

- [ ] **Step 8: Run tests**

Run:

```powershell
flutter test --no-pub test/features/home/home_view_model_test.dart test/app_static_ui_test.dart
```

Expected: PASS.

- [ ] **Step 9: Run analyzer**

Run:

```powershell
flutter analyze --no-pub
```

Expected: PASS.

- [ ] **Step 10: Commit**

Run:

```powershell
git add lib/core/widgets/rims_metric_card.dart lib/core/widgets/rims_quick_action_button.dart lib/features/home lib/features/shell/presentation/pages/app_shell_page.dart test/features/home test/app_static_ui_test.dart
git commit -m "feat: add static home dashboard ui"
```

## Task 4: Inventory UI

**Files:**
- Create: `rims_frontend/lib/features/inventory/presentation/view_models/inventory_view_model.dart`
- Create: `rims_frontend/lib/features/inventory/presentation/pages/inventory_page.dart`
- Create: `rims_frontend/lib/features/inventory/presentation/widgets/inventory_product_tile.dart`
- Modify: `rims_frontend/lib/features/shell/presentation/pages/app_shell_page.dart`
- Test: `rims_frontend/test/features/inventory/inventory_view_model_test.dart`

- [ ] **Step 1: Write the failing Inventory ViewModel test**

Create `test/features/inventory/inventory_view_model_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:rims_frontend/features/inventory/presentation/view_models/inventory_view_model.dart';

void main() {
  test('InventoryViewModel exposes static inventory data', () {
    const viewModel = InventoryViewModel();

    expect(viewModel.warehouseName, '上海仓');
    expect(viewModel.tabs, ['标准', '商品', '非标']);
    expect(viewModel.metrics, hasLength(3));
    expect(viewModel.products, hasLength(4));
    expect(viewModel.products.first.name, '矿泉水 550ml');
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```powershell
flutter test --no-pub test/features/inventory/inventory_view_model_test.dart
```

Expected: FAIL because `InventoryViewModel` does not exist.

- [ ] **Step 3: Implement Inventory display models**

Create model records with this public shape:

```dart
final class InventoryMetric {
  const InventoryMetric({
    required this.label,
    required this.value,
  });

  final String label;
  final String value;
}

final class InventoryProduct {
  const InventoryProduct({
    required this.name,
    required this.sku,
    required this.imagePath,
    required this.available,
    required this.stock,
    required this.status,
  });

  final String name;
  final String sku;
  final String imagePath;
  final int available;
  final int stock;
  final String status;
}
```

`InventoryViewModel` must expose:

- `warehouseName => '上海仓'`.
- `tabs => const ['标准', '商品', '非标']`.
- Three metrics: `SKU数`, `总库存`, `库存金额(元)`.
- Four products using the generated product images.

- [ ] **Step 4: Implement `InventoryPage`**

The page must render:

- `上海仓`.
- Search hint `搜索商品 / 条码 / 编码`.
- Filter affordance.
- Tabs `标准`, `商品`, `非标`.
- Metric labels.
- Product list with thumbnails.
- Status chips for `标准`, `低库存`, or `非标`.

- [ ] **Step 5: Wire Inventory into shell**

Replace the temporary inventory body in `AppShellPage` with:

```dart
const InventoryPage()
```

- [ ] **Step 6: Run tests**

Run:

```powershell
flutter test --no-pub test/features/inventory/inventory_view_model_test.dart test/app_static_ui_test.dart
```

Expected: PASS.

- [ ] **Step 7: Run analyzer**

Run:

```powershell
flutter analyze --no-pub
```

Expected: PASS.

- [ ] **Step 8: Commit**

Run:

```powershell
git add lib/features/inventory lib/features/shell/presentation/pages/app_shell_page.dart test/features/inventory
git commit -m "feat: add static inventory ui"
```

## Task 5: Documents UI

**Files:**
- Create: `rims_frontend/lib/features/documents/presentation/view_models/documents_view_model.dart`
- Create: `rims_frontend/lib/features/documents/presentation/pages/documents_page.dart`
- Create: `rims_frontend/lib/features/documents/presentation/widgets/document_action_card.dart`
- Create: `rims_frontend/lib/features/documents/presentation/widgets/document_flow_strip.dart`
- Modify: `rims_frontend/lib/features/shell/presentation/pages/app_shell_page.dart`
- Test: `rims_frontend/test/features/documents/documents_view_model_test.dart`

- [ ] **Step 1: Write the failing Documents ViewModel test**

Create `test/features/documents/documents_view_model_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:rims_frontend/features/documents/presentation/view_models/documents_view_model.dart';

void main() {
  test('DocumentsViewModel exposes static document workflow data', () {
    const viewModel = DocumentsViewModel();

    expect(viewModel.actions, hasLength(6));
    expect(viewModel.flowSteps, ['创建', '确认', '提交', '完成']);
    expect(viewModel.recentDocuments, hasLength(3));
    expect(viewModel.actions.first.label, '销售出库');
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```powershell
flutter test --no-pub test/features/documents/documents_view_model_test.dart
```

Expected: FAIL because `DocumentsViewModel` does not exist.

- [ ] **Step 3: Implement Documents display models**

`DocumentsViewModel` must expose:

- Six action cards: `销售出库`, `采购入库`, `调拨单`, `盘点单`, `退货入库`, `转标准`.
- `flowSteps => const ['创建', '确认', '提交', '完成']`.
- Three recent documents with numbers and statuses.

Use action icons from `AppIcons.actionInbound`, `actionTransfer`,
`actionStocktake`, `actionReturn`, `actionScan`, and `actionReport`.

- [ ] **Step 4: Implement `DocumentsPage`**

The page must render:

- Title `单据`.
- A 2-column action grid.
- Section `单据流程`.
- Flow strip with four steps.
- Section `最近单据`.
- Status chips for `已完成`, `待提交`, and `已取消`.

- [ ] **Step 5: Wire Documents into shell**

Replace the temporary documents body in `AppShellPage` with:

```dart
const DocumentsPage()
```

- [ ] **Step 6: Run tests**

Run:

```powershell
flutter test --no-pub test/features/documents/documents_view_model_test.dart test/app_static_ui_test.dart
```

Expected: PASS.

- [ ] **Step 7: Run analyzer**

Run:

```powershell
flutter analyze --no-pub
```

Expected: PASS.

- [ ] **Step 8: Commit**

Run:

```powershell
git add lib/features/documents lib/features/shell/presentation/pages/app_shell_page.dart test/features/documents
git commit -m "feat: add static documents ui"
```

## Task 6: Reports UI

**Files:**
- Create: `rims_frontend/lib/core/widgets/rims_mini_charts.dart`
- Create: `rims_frontend/lib/features/reports/presentation/view_models/reports_view_model.dart`
- Create: `rims_frontend/lib/features/reports/presentation/pages/reports_page.dart`
- Create: `rims_frontend/lib/features/reports/presentation/widgets/report_ranking_bar.dart`
- Modify: `rims_frontend/lib/features/shell/presentation/pages/app_shell_page.dart`
- Test: `rims_frontend/test/features/reports/reports_view_model_test.dart`

- [ ] **Step 1: Write the failing Reports ViewModel test**

Create `test/features/reports/reports_view_model_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:rims_frontend/features/reports/presentation/view_models/reports_view_model.dart';

void main() {
  test('ReportsViewModel exposes static report data', () {
    const viewModel = ReportsViewModel();

    expect(viewModel.dateRangeLabel, '2024-05-12 ~ 2024-05-18');
    expect(viewModel.trendPoints, hasLength(7));
    expect(viewModel.rankings, hasLength(5));
    expect(viewModel.inventoryBuckets, hasLength(4));
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```powershell
flutter test --no-pub test/features/reports/reports_view_model_test.dart
```

Expected: FAIL because `ReportsViewModel` does not exist.

- [ ] **Step 3: Implement Reports display models**

`ReportsViewModel` must expose:

- `dateRangeLabel => '2024-05-12 ~ 2024-05-18'`.
- Seven `trendPoints`.
- Five ranking rows: `矿泉水 550ml`, `纸巾抽纸 3层`, `洗衣液 2kg`, `洗发水 400ml`, `牙膏 120g`.
- Four inventory buckets: `正常库存`, `低库存`, `超储`, `无库存`.

- [ ] **Step 4: Implement static mini chart widgets**

`rims_mini_charts.dart` must expose:

```dart
import 'package:flutter/material.dart';

final class RimsLineChart extends StatelessWidget {
  const RimsLineChart({
    required this.values,
    this.color = const Color(0xFF0F6BFF),
    super.key,
  });

  final List<double> values;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: const Size(double.infinity, 120),
      painter: _RimsLineChartPainter(values: values, color: color),
    );
  }
}

final class RimsRingChart extends StatelessWidget {
  const RimsRingChart({
    required this.segments,
    required this.centerLabel,
    super.key,
  });

  final List<RimsRingSegment> segments;
  final String centerLabel;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 132,
      height: 132,
      child: Stack(
        alignment: Alignment.center,
        children: [
          CustomPaint(
            size: const Size.square(132),
            painter: _RimsRingChartPainter(segments: segments),
          ),
          Text(centerLabel, textAlign: TextAlign.center),
        ],
      ),
    );
  }
}

final class RimsRingSegment {
  const RimsRingSegment({
    required this.label,
    required this.value,
    required this.color,
  });

  final String label;
  final double value;
  final Color color;
}
```

Each widget accepts static values and paints with `CustomPainter`. The line chart
does not need axes; the ring chart must render colored arcs and a center label.

- [ ] **Step 5: Implement `ReportsPage`**

The page must render:

- `报表`.
- `2024-05-12 ~ 2024-05-18`.
- `销售趋势（元）`.
- `商品排行（销售额）`.
- `库存概览`.
- Ranking bars with values.
- Inventory bucket legend.

- [ ] **Step 6: Wire Reports into shell**

Replace the temporary reports body in `AppShellPage` with:

```dart
const ReportsPage()
```

- [ ] **Step 7: Run tests**

Run:

```powershell
flutter test --no-pub test/features/reports/reports_view_model_test.dart test/app_static_ui_test.dart
```

Expected: PASS.

- [ ] **Step 8: Run analyzer**

Run:

```powershell
flutter analyze --no-pub
```

Expected: PASS.

- [ ] **Step 9: Commit**

Run:

```powershell
git add lib/core/widgets/rims_mini_charts.dart lib/features/reports lib/features/shell/presentation/pages/app_shell_page.dart test/features/reports
git commit -m "feat: add static reports ui"
```

## Task 7: Profile, Permissions, And API Guard UI

**Files:**
- Create: `rims_frontend/lib/features/profile/presentation/view_models/profile_view_model.dart`
- Create: `rims_frontend/lib/features/profile/presentation/pages/profile_page.dart`
- Create: `rims_frontend/lib/features/profile/presentation/widgets/api_guard_chip_group.dart`
- Create: `rims_frontend/lib/features/profile/presentation/widgets/permission_group_card.dart`
- Modify: `rims_frontend/lib/features/shell/presentation/pages/app_shell_page.dart`
- Test: `rims_frontend/test/features/profile/profile_view_model_test.dart`

- [ ] **Step 1: Write the failing Profile ViewModel test**

Create `test/features/profile/profile_view_model_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:rims_frontend/features/profile/presentation/view_models/profile_view_model.dart';

void main() {
  test('ProfileViewModel exposes static permission and API guard data', () {
    const viewModel = ProfileViewModel();

    expect(viewModel.userName, '张三');
    expect(viewModel.roleName, '普通用户');
    expect(viewModel.apiGuards, contains('JWT'));
    expect(viewModel.backendModules, contains('warehouse'));
    expect(viewModel.permissionGroups, hasLength(2));
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```powershell
flutter test --no-pub test/features/profile/profile_view_model_test.dart
```

Expected: FAIL because `ProfileViewModel` does not exist.

- [ ] **Step 3: Implement Profile display models**

`ProfileViewModel` must expose:

- `userName => '张三'`.
- `workId => 'U10086'`.
- `roleName => '普通用户'`.
- `warehouseName => '上海仓'`.
- API guards: `JWT`, `X-Warehouse-ID`, `Permission`, `Idempotency-Key`, `traceId`.
- Backend modules: `user`, `warehouse`, `product`, `document`, `report`, `file`, `audit`.
- Two permission groups: `管理员` and `普通用户`, each with visible capability labels.

- [ ] **Step 4: Implement `ProfilePage`**

The page must render:

- User identity card with `张三`, `普通用户`, and `U10086`.
- Setting rows: `个人信息`, `当前角色`, `切换仓库`, `通知设置`.
- Section `API 守卫`.
- Section `后端模块`.
- Section `角色与权限`.
- Administrator and normal user permission summaries.

- [ ] **Step 5: Wire Profile into shell**

Replace the temporary profile body in `AppShellPage` with:

```dart
const ProfilePage()
```

- [ ] **Step 6: Run tests**

Run:

```powershell
flutter test --no-pub test/features/profile/profile_view_model_test.dart test/app_static_ui_test.dart
```

Expected: PASS.

- [ ] **Step 7: Run analyzer**

Run:

```powershell
flutter analyze --no-pub
```

Expected: PASS.

- [ ] **Step 8: Commit**

Run:

```powershell
git add lib/features/profile lib/features/shell/presentation/pages/app_shell_page.dart test/features/profile
git commit -m "feat: add static profile permissions ui"
```

## Task 8: Polish, Widget Coverage, And Final Verification

**Files:**
- Modify: `rims_frontend/test/widget_test.dart`
- Modify: `rims_frontend/test/app_static_ui_test.dart`
- Inspect: all files changed in Tasks 1-7

- [ ] **Step 1: Replace generated widget test**

Update `test/widget_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:rims_frontend/main.dart';

void main() {
  testWidgets('RIMS static UI app renders login entry', (tester) async {
    await tester.pumpWidget(const MainApp());
    await tester.pump();

    expect(find.text('RIMS'), findsWidgets);
    expect(find.text('进入静态演示'), findsOneWidget);
  });
}
```

- [ ] **Step 2: Extend tab navigation smoke coverage**

In `test/app_static_ui_test.dart`, add a test that enters the shell and taps each
bottom tab label:

```dart
testWidgets('static shell can switch across all tabs', (tester) async {
  await tester.pumpWidget(const MainApp());
  await tester.pump();

  await tester.tap(find.text('进入静态演示'));
  await tester.pumpAndSettle();

  for (final label in ['库存', '单据', '报表', '我的', '首页']) {
    await tester.tap(find.text(label).last);
    await tester.pumpAndSettle();
    expect(find.text(label), findsWidgets);
  }
});
```

- [ ] **Step 3: Run full verification**

Run:

```powershell
flutter analyze --no-pub
flutter test --no-pub
git diff --check
```

Expected: all commands PASS.

- [ ] **Step 4: Optional visual run**

Run one local visual check:

```powershell
flutter run -d chrome
```

Expected: login page opens; clicking `进入静态演示` shows the 5-tab static app.

If Chrome is unavailable, use the available Flutter device and record the device
used in the final implementation summary.

- [ ] **Step 5: Review changed files**

Run:

```powershell
git status --short
git diff --stat
```

Expected: only planned source and test files are changed. `.superpowers/` remains
unstaged.

- [ ] **Step 6: Commit**

Run:

```powershell
git add test/widget_test.dart test/app_static_ui_test.dart
git commit -m "test: cover static ui shell smoke flows"
```

## Final Acceptance Criteria

- Static login page exists and starts the app.
- Login entry can navigate to the static 5-tab app shell.
- Home, Inventory, Documents, Reports, and Profile tabs render static UI.
- Profile includes role, warehouse, permission, API guard, and backend module
  display surfaces.
- Existing generated image and icon assets are referenced through `AppImages`
  and `AppIcons`.
- Pages do not make network calls, access storage, invoke camera/scanner APIs, or
  submit business forms.
- Static display data is exposed by presentation ViewModels instead of being
  buried entirely in page build methods.
- `flutter analyze --no-pub` passes.
- `flutter test --no-pub` passes.
- `git diff --check` passes.

## Self-Review

- Spec coverage: M0 maps to Tasks 1-2, M1 maps to Task 3, M2 maps to Task 4, M3
  maps to Task 5, M4 maps to Task 6, M5 maps to Task 7, and M6 maps to Task 8.
- Non-goals preserved: no task asks for real authentication, API calls,
  permission enforcement, scanner behavior, warehouse switching, document
  submission, report calculation, caching, or offline behavior.
- Type consistency: shared widgets and ViewModels define stable public names
  before later tasks reference them.
- Verification coverage: every feature ViewModel has a focused unit test, the app
  has startup and shell smoke tests, and final verification uses analyzer, tests,
  and whitespace checks.
