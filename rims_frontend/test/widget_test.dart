import 'package:flutter_test/flutter_test.dart';
import 'package:rims_frontend/main.dart';

void main() {
  testWidgets('renders the starter home screen', (tester) async {
    await tester.pumpWidget(const MainApp());

    expect(find.text('Hello World!'), findsOneWidget);
  });
}
