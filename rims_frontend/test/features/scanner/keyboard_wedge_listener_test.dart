import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rims_frontend/features/scanner/presentation/widgets/keyboard_wedge_listener.dart';

void main() {
  testWidgets('printable keys ending in Enter emit exactly one barcode', (
    tester,
  ) async {
    final codes = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: KeyboardWedgeListener(
          onBarcode: codes.add,
          child: const SizedBox.expand(),
        ),
      ),
    );
    await tester.pump();

    await _key(tester, LogicalKeyboardKey.keyA, 'A');
    await _key(tester, LogicalKeyboardKey.keyB, 'B');
    await _key(tester, LogicalKeyboardKey.digit1, '1');
    await _key(tester, LogicalKeyboardKey.enter, null);

    expect(codes, ['AB1']);
  });

  testWidgets('inter-key timeout drops an incomplete prefix', (tester) async {
    final codes = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: KeyboardWedgeListener(
          interKeyTimeout: const Duration(milliseconds: 50),
          onBarcode: codes.add,
          child: const SizedBox.expand(),
        ),
      ),
    );
    await tester.pump();

    await _key(tester, LogicalKeyboardKey.keyA, 'A');
    await tester.pump(const Duration(milliseconds: 51));
    await _key(tester, LogicalKeyboardKey.keyB, 'B');
    await _key(tester, LogicalKeyboardKey.enter, null);

    expect(codes, ['B']);
  });

  testWidgets('editable focus owns keys and global Back remains untrapped', (
    tester,
  ) async {
    final codes = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: KeyboardWedgeListener(
          onBarcode: codes.add,
          child: const Scaffold(body: TextField(autofocus: true)),
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.byType(TextField));
    await tester.pump();

    await _key(tester, LogicalKeyboardKey.keyA, 'A');
    await _key(tester, LogicalKeyboardKey.enter, null);
    await _key(tester, LogicalKeyboardKey.escape, null);

    expect(codes, isEmpty);
  });

  testWidgets('disabled listener never captures scanner keys', (tester) async {
    final codes = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: KeyboardWedgeListener(
          enabled: false,
          onBarcode: codes.add,
          child: const SizedBox.expand(),
        ),
      ),
    );
    await tester.pump();
    await _key(tester, LogicalKeyboardKey.keyA, 'A');
    await _key(tester, LogicalKeyboardKey.enter, null);
    expect(codes, isEmpty);
  });

  testWidgets('enabling after mount requests focus and captures one code', (
    tester,
  ) async {
    final codes = <String>[];
    final enabled = ValueNotifier(false);
    addTearDown(enabled.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: ValueListenableBuilder<bool>(
          valueListenable: enabled,
          builder: (context, value, _) => KeyboardWedgeListener(
            enabled: value,
            onBarcode: codes.add,
            child: const SizedBox.expand(),
          ),
        ),
      ),
    );
    enabled.value = true;
    await tester.pump();
    await tester.pump();

    await _key(tester, LogicalKeyboardKey.keyA, 'A');
    await _key(tester, LogicalKeyboardKey.enter, null);
    expect(codes, ['A']);
  });
}

Future<void> _key(
  WidgetTester tester,
  LogicalKeyboardKey key,
  String? character,
) async {
  await tester.sendKeyDownEvent(key, character: character);
  await tester.sendKeyUpEvent(key);
  await tester.pump();
}
