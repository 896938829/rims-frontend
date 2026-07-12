enum ScanFeedbackKind { accepted, duplicate, rejected, completed }

abstract interface class ScanFeedbackCapability {
  Future<void> play(
    ScanFeedbackKind kind, {
    required bool sound,
    required bool vibration,
  });
}

final class NoopScanFeedback implements ScanFeedbackCapability {
  const NoopScanFeedback();

  @override
  Future<void> play(
    ScanFeedbackKind kind, {
    required bool sound,
    required bool vibration,
  }) async {}
}
