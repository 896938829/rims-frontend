import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rims_frontend/features/scanner/presentation/widgets/scanner_viewport.dart';

void main() {
  for (final configuration in const [
    (name: 'phone portrait', size: Size(360, 800)),
    (name: 'phone landscape', size: Size(800, 360)),
    (name: 'tablet portrait', size: Size(800, 1280)),
    (name: 'tablet landscape', size: Size(1280, 800)),
  ]) {
    testWidgets('scanner viewport supports ${configuration.name}', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(configuration.size);
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(brightness: Brightness.dark),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(2)),
            child: child!,
          ),
          home: const Scaffold(
            body: SingleChildScrollView(
              child: ScannerViewport(
                camera: ColoredBox(color: Colors.black),
                overlayMessage: '需要相机权限才能扫描条码',
              ),
            ),
          ),
        ),
      );

      final viewport = tester.getSize(
        find.byKey(const Key('scanner-viewport')),
      );
      expect(viewport.width / viewport.height, closeTo(4 / 3, 0.001));
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('system back leaves a scanner route', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        routes: {
          '/': (_) => const Scaffold(body: Text('库存')),
          '/scanner': (_) => const Scaffold(
            body: ScannerViewport(camera: ColoredBox(color: Colors.black)),
          ),
        },
        initialRoute: '/scanner',
      ),
    );

    expect(await tester.binding.handlePopRoute(), isTrue);
    await tester.pumpAndSettle();
    expect(find.text('库存'), findsOneWidget);
  });
}
