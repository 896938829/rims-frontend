import 'package:flutter/widgets.dart';
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

  testWidgets('shell bottom navigation switches tab body', (tester) async {
    await tester.pumpWidget(const MainApp());
    await tester.pump();

    await tester.tap(find.text('进入静态演示'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('库存'));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('tab-body-inventory')), findsOneWidget);
  });
}
