import 'dart:async';

abstract final class AuthRequestPolicy {
  static const String queuedWrite = 'rims.auth.queued_write';
  static const String explicitSyncCenter = 'rims.auth.explicit_sync_center';
  static const String skipRefresh = 'rims.auth.skip_refresh';

  static const String credentialSnapshot = 'rims.auth.credential_snapshot';
  static const String replayed = 'rims.auth.replayed';

  static final Object _queuedWriteZoneKey = Object();
  static final Object _explicitSyncCenterZoneKey = Object();

  static bool get isQueuedWrite => Zone.current[_queuedWriteZoneKey] == true;

  static bool get isExplicitSyncCenter =>
      Zone.current[_explicitSyncCenterZoneKey] == true;

  static Future<T> runQueuedWrite<T>(Future<T> Function() operation) {
    return runZoned(operation, zoneValues: {_queuedWriteZoneKey: true});
  }

  static Future<T> runExplicitSyncCenter<T>(Future<T> Function() operation) {
    return runZoned(operation, zoneValues: {_explicitSyncCenterZoneKey: true});
  }
}
