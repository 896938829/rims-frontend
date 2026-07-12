import 'dart:async';

import 'package:flutter/services.dart';

import '../domain/services/scan_feedback_capability.dart';

typedef ScanSoundPlayer = Future<void> Function(SystemSoundType type);
typedef ScanVibrator = Future<void> Function(ScanFeedbackKind kind);

final class SystemScanFeedback implements ScanFeedbackCapability {
  SystemScanFeedback({ScanSoundPlayer? playSound, ScanVibrator? vibrate})
    : _playSound = playSound ?? SystemSound.play,
      _vibrate = vibrate ?? _defaultVibrate;

  final ScanSoundPlayer _playSound;
  final ScanVibrator _vibrate;

  @override
  Future<void> play(
    ScanFeedbackKind kind, {
    required bool sound,
    required bool vibration,
  }) async {
    await Future.wait([
      if (sound) _ignoreFailure(_playSound(_soundFor(kind))),
      if (vibration) _ignoreFailure(_vibrate(kind)),
    ]);
  }

  static SystemSoundType _soundFor(ScanFeedbackKind kind) =>
      kind == ScanFeedbackKind.rejected
      ? SystemSoundType.alert
      : SystemSoundType.click;

  static Future<void> _defaultVibrate(ScanFeedbackKind kind) => switch (kind) {
    ScanFeedbackKind.accepted => HapticFeedback.lightImpact(),
    ScanFeedbackKind.duplicate => HapticFeedback.selectionClick(),
    ScanFeedbackKind.rejected => HapticFeedback.mediumImpact(),
    ScanFeedbackKind.completed => HapticFeedback.heavyImpact(),
  };

  static Future<void> _ignoreFailure(Future<void> operation) async {
    try {
      await operation;
    } on Object {
      // Feedback is best-effort and must never interrupt scan processing.
    }
  }
}
