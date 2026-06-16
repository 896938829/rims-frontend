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
