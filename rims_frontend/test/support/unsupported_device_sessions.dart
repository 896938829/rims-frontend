import 'package:rims_frontend/core/result/failure.dart';
import 'package:rims_frontend/core/result/result.dart';
import 'package:rims_frontend/features/auth/domain/entities/device_session.dart';

mixin UnsupportedDeviceSessions {
  Future<Result<List<DeviceSession>>> listDeviceSessions() async =>
      const FailureResult(
        StateFailure(message: 'Device session management is unsupported.'),
      );

  Future<Result<void>> revokeDeviceSession(String sessionId) async =>
      const FailureResult(
        StateFailure(message: 'Device session management is unsupported.'),
      );

  Future<Result<int>> revokeOtherDeviceSessions() async => const FailureResult(
    StateFailure(message: 'Device session management is unsupported.'),
  );

  Future<Result<int>> revokeAllDeviceSessions() async => const FailureResult(
    StateFailure(message: 'Device session management is unsupported.'),
  );
}
