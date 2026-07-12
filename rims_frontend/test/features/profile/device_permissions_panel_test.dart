import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rims_frontend/features/profile/presentation/pages/profile_page.dart';

void main() {
  test(
    'Android permissions stay minimal and local cleartext stays debug-only',
    () {
      final mainManifest = File(
        'android/app/src/main/AndroidManifest.xml',
      ).readAsStringSync();
      final debugManifest = File(
        'android/app/src/debug/AndroidManifest.xml',
      ).readAsStringSync();
      final gradle = File('android/app/build.gradle.kts').readAsStringSync();

      expect(mainManifest, contains('android.permission.INTERNET'));
      expect(mainManifest, contains('android.permission.CAMERA'));
      expect(mainManifest, contains('android.hardware.camera.any'));
      expect(mainManifest, contains('android:required="false"'));
      expect(mainManifest, contains('android:usesCleartextTraffic="false"'));
      expect(debugManifest, contains('android:usesCleartextTraffic="true"'));
    expect(gradle, contains('minSdk = 24'));

      for (final broadPermission in const [
        'READ_EXTERNAL_STORAGE',
        'WRITE_EXTERNAL_STORAGE',
        'MANAGE_EXTERNAL_STORAGE',
        'POST_NOTIFICATIONS',
      ]) {
        expect(mainManifest, isNot(contains(broadPermission)));
        expect(debugManifest, isNot(contains(broadPermission)));
      }
    },
  );

  testWidgets('profile explains device capabilities without claiming grants', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: ProfilePage())),
    );

    expect(find.text('设备与权限'), findsOneWidget);
    expect(find.textContaining('扫码和拍照'), findsOneWidget);
    expect(find.textContaining('系统选择器'), findsNWidgets(2));
    expect(find.textContaining('通知功能尚未启用'), findsOneWidget);
    expect(find.textContaining('空间不足'), findsOneWidget);
    expect(find.textContaining('待处理'), findsWidgets);
    expect(find.textContaining('已授权'), findsNothing);
  });
}
