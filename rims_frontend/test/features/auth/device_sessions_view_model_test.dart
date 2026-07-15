import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:rims_frontend/core/result/failure.dart';
import 'package:rims_frontend/core/result/result.dart';
import 'package:rims_frontend/features/auth/domain/entities/auth_session.dart';
import 'package:rims_frontend/features/auth/domain/entities/device_session.dart';
import 'package:rims_frontend/features/auth/domain/entities/warehouse.dart';
import 'package:rims_frontend/features/auth/domain/repositories/auth_repository.dart';
import 'package:rims_frontend/features/auth/presentation/view_models/device_sessions_view_model.dart';

void main() {
  group('DeviceSessionsViewModel', () {
    test('loads backend current marker without guessing from labels', () async {
      final repository = _FakeAuthRepository(
        sessionsResult: Success([_currentSession, _otherSession]),
      );
      final viewModel = DeviceSessionsViewModel(repository: repository);

      await viewModel.load();

      expect(viewModel.sessions, hasLength(2));
      expect(viewModel.sessions.singleWhere((item) => item.current).id, 's-1');
      expect(viewModel.errorMessage, isNull);
      expect(viewModel.isBusy, isFalse);
    });

    test('builds safe device platform and time display values', () {
      final viewModel = DeviceSessionsViewModel(
        repository: _FakeAuthRepository(sessionsResult: const Success([])),
      );
      final untrusted = DeviceSession(
        id: 's-unsafe',
        deviceLabel: '   ',
        platform: 'android <10.24.16.8>',
        userAgentFamily: 'unknown',
        createdAt: DateTime.utc(2026, 7, 1, 8),
        lastUsedAt: DateTime.utc(2026, 7, 15, 9, 30),
        expiresAt: DateTime.utc(2026, 8, 1, 8),
        revokedAt: DateTime.utc(2026, 7, 15, 10),
        current: false,
      );

      expect(viewModel.deviceLabelFor(untrusted), '未知设备');
      expect(viewModel.platformLabelFor(untrusted), '未知平台');
      expect(viewModel.createdLabelFor(untrusted), '2026-07-01 08:00');
      expect(viewModel.lastUsedLabelFor(untrusted), '2026-07-15 09:30');
      expect(viewModel.expiresLabelFor(untrusted), '2026-08-01 08:00');
      expect(viewModel.revokedLabelFor(untrusted), '2026-07-15 10:00');
    });

    test('refresh failure retains previously loaded sessions', () async {
      final repository = _FakeAuthRepository(
        sessionsResult: Success([_currentSession, _otherSession]),
      );
      final viewModel = DeviceSessionsViewModel(repository: repository);
      await viewModel.load();
      repository.sessionsResult = const FailureResult(
        NetworkFailure(message: 'private upstream detail'),
      );

      await viewModel.refresh();

      expect(viewModel.sessions, hasLength(2));
      expect(viewModel.hasRetainedDataError, isTrue);
      expect(viewModel.errorMessage, '刷新登录设备失败，请重试');
    });

    test('one busy gate rejects every conflicting command', () async {
      final repository = _FakeAuthRepository(
        sessionsResult: Success([_currentSession, _otherSession]),
      );
      final viewModel = DeviceSessionsViewModel(repository: repository);
      await viewModel.load();
      final refresh = Completer<Result<List<DeviceSession>>>();
      repository.pendingSessionsResult = refresh;

      final pendingRefresh = viewModel.refresh();
      final outcome = await viewModel.revokeSession(_otherSession);

      expect(outcome, DeviceSessionsCommandOutcome.ignored);
      expect(repository.revokeSessionCalls, isEmpty);
      refresh.complete(Success([_currentSession, _otherSession]));
      await pendingRefresh;
      expect(viewModel.isBusy, isFalse);
    });

    test('disposed load completion cannot write state or notify', () async {
      final pending = Completer<Result<List<DeviceSession>>>();
      final repository = _FakeAuthRepository(
        sessionsResult: const Success([]),
        pendingSessionsResult: pending,
      );
      final viewModel = DeviceSessionsViewModel(repository: repository);
      var notifications = 0;
      viewModel.addListener(() => notifications += 1);

      final load = viewModel.load();
      expect(notifications, 1);
      viewModel.dispose();
      pending.complete(Success([_currentSession]));
      await load;

      expect(viewModel.sessions, isEmpty);
      expect(notifications, 1);
    });

    test('revoke one removes a remote device and reports success', () async {
      final repository = _FakeAuthRepository(
        sessionsResult: Success([_currentSession, _otherSession]),
      );
      final viewModel = DeviceSessionsViewModel(repository: repository);
      await viewModel.load();

      final outcome = await viewModel.revokeSession(_otherSession);

      expect(outcome, DeviceSessionsCommandOutcome.completed);
      expect(viewModel.sessions, [_currentSession]);
      expect(viewModel.successMessage, '已撤销 Warehouse tablet');
    });

    test('current and all revocations produce terminal outcomes', () async {
      final repository = _FakeAuthRepository(
        sessionsResult: Success([_currentSession, _otherSession]),
      );
      final currentViewModel = DeviceSessionsViewModel(repository: repository);
      await currentViewModel.load();

      expect(
        await currentViewModel.revokeSession(_currentSession),
        DeviceSessionsCommandOutcome.terminal,
      );
      expect(currentViewModel.isTerminal, isTrue);

      final allViewModel = DeviceSessionsViewModel(repository: repository);
      await allViewModel.load();
      expect(
        await allViewModel.revokeAll(),
        DeviceSessionsCommandOutcome.terminal,
      );
      expect(allViewModel.sessions, isEmpty);
    });

    test(
      'revoke others keeps only the backend-marked current session',
      () async {
        final repository = _FakeAuthRepository(
          sessionsResult: Success([_currentSession, _otherSession]),
        );
        final viewModel = DeviceSessionsViewModel(repository: repository);
        await viewModel.load();

        final outcome = await viewModel.revokeOthers();

        expect(outcome, DeviceSessionsCommandOutcome.completed);
        expect(viewModel.sessions, [_currentSession]);
        expect(viewModel.successMessage, '已撤销其他登录设备');
      },
    );
  });
}

final _currentSession = DeviceSession(
  id: 's-1',
  deviceLabel: 'Current tablet',
  platform: 'android',
  userAgentFamily: 'RIMS Android',
  createdAt: DateTime.utc(2026, 7, 1, 8),
  lastUsedAt: DateTime.utc(2026, 7, 15, 9, 30),
  expiresAt: DateTime.utc(2026, 8, 1, 8),
  current: true,
);

final _otherSession = DeviceSession(
  id: 's-2',
  deviceLabel: 'Warehouse tablet',
  platform: 'windows',
  userAgentFamily: 'Chrome',
  createdAt: DateTime.utc(2026, 7, 2, 8),
  lastUsedAt: DateTime.utc(2026, 7, 14, 10, 45),
  expiresAt: DateTime.utc(2026, 8, 2, 8),
  current: false,
);

final class _FakeAuthRepository implements AuthRepository {
  _FakeAuthRepository({
    required this.sessionsResult,
    this.pendingSessionsResult,
  });

  Result<List<DeviceSession>> sessionsResult;
  Completer<Result<List<DeviceSession>>>? pendingSessionsResult;
  final List<String> revokeSessionCalls = [];

  @override
  Future<Result<List<DeviceSession>>> listDeviceSessions() {
    final pending = pendingSessionsResult;
    pendingSessionsResult = null;
    return pending?.future ?? Future.value(sessionsResult);
  }

  @override
  Future<Result<void>> revokeDeviceSession(String sessionId) async {
    revokeSessionCalls.add(sessionId);
    return const Success(null);
  }

  @override
  Future<Result<int>> revokeOtherDeviceSessions() async => const Success(1);

  @override
  Future<Result<int>> revokeAllDeviceSessions() async => const Success(2);

  @override
  Future<Result<AuthSession?>> restoreSession() async => const Success(null);

  @override
  Future<Result<Warehouse>> switchCurrentWarehouse(Warehouse warehouse) async =>
      Success(warehouse);

  @override
  Future<Result<AuthSession>> login({
    required String username,
    required String password,
  }) async => const FailureResult(AuthenticationFailure());

  @override
  Future<void> logout() async {}
}
