import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rims_frontend/features/reports/presentation/pages/reports_page.dart';
import 'package:rims_frontend/features/reports/presentation/view_models/reports_view_model.dart';
import 'package:rims_frontend/features/reports/presentation/widgets/report_ranking_bar.dart';

void main() {
  test('ReportsViewModel exposes static report data', () {
    const viewModel = ReportsViewModel();

    expect(viewModel.dateRangeLabel, '2024-05-12 ~ 2024-05-18');
    expect(viewModel.trendPoints, hasLength(7));
    expect(viewModel.rankings, hasLength(5));
    expect(viewModel.inventoryBuckets, hasLength(4));
  });

  testWidgets('ReportsPage does not overflow at narrow width', (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await tester.pumpWidget(const MaterialApp(home: ReportsPage()));
    await tester.pump();

    expect(tester.takeException(), isNull);
  });

  testWidgets('ReportRankingBar constrains long amount labels', (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 180,
            child: ReportRankingBar(
              ranking: ReportRanking(
                name: '超长商品名称',
                value: 100,
                amountLabel: '人民币 123,456,789.00 元',
              ),
              maxValue: 100,
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(tester.takeException(), isNull);
  });
}
