import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:rims_frontend/core/result/failure.dart';
import 'package:rims_frontend/core/result/result.dart';
import 'package:rims_frontend/features/auth/domain/entities/auth_session.dart';
import 'package:rims_frontend/features/auth/domain/entities/device_session.dart';
import 'package:rims_frontend/features/auth/domain/entities/terminal_session_revocation.dart';
import 'package:rims_frontend/features/auth/domain/entities/warehouse.dart';
import 'package:rims_frontend/features/auth/domain/repositories/auth_repository.dart';
import 'package:rims_frontend/features/auth/presentation/view_models/device_sessions_view_model.dart';

void main() {
  group('DeviceSessionsViewModel', () {
    test('loads backend current marker without guessing from labels', () async {
      final repository = _FakeAuthRepository(
        sessionsResult: Success([_currentSession, _otherSession]),
      );
      final viewModel = _viewModel(repository);

      await viewModel.load();

      expect(viewModel.sessions, hasLength(2));
      expect(viewModel.sessions.singleWhere((item) => item.current).id, 's-1');
      expect(viewModel.errorMessage, isNull);
      expect(viewModel.isBusy, isFalse);
    });

    test('builds safe device platform and time display values', () {
      final viewModel = _viewModel(
        _FakeAuthRepository(sessionsResult: const Success([])),
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
      expect(
        viewModel.createdLabelFor(untrusted),
        _localTimeLabel(untrusted.createdAt),
      );
      expect(
        viewModel.lastUsedLabelFor(untrusted),
        _localTimeLabel(untrusted.lastUsedAt),
      );
      expect(
        viewModel.expiresLabelFor(untrusted),
        _localTimeLabel(untrusted.expiresAt),
      );
      expect(
        viewModel.revokedLabelFor(untrusted),
        _localTimeLabel(untrusted.revokedAt!),
      );
      expect(viewModel.userAgentLabelFor(untrusted), '未知客户端');
    });

    test('redacts an entire device label containing IPv4 or IPv6', () {
      final viewModel = _viewModel(
        _FakeAuthRepository(sessionsResult: const Success([])),
      );
      final unsafeLabels = [
        'Scanner 10.24.16.8:8443 primary',
        'Scanner [2001:db8::1]:443 primary',
        'Scanner 2001:db8:85a3::8a2e:370:7334 primary',
      ];

      for (var index = 0; index < unsafeLabels.length; index += 1) {
        final session = DeviceSession(
          id: 'unsafe-$index',
          deviceLabel: unsafeLabels[index],
          platform: 'android',
          userAgentFamily: 'Chrome',
          createdAt: DateTime.utc(2026, 7, 1),
          lastUsedAt: DateTime.utc(2026, 7, 1),
          expiresAt: DateTime.utc(2026, 8, 1),
          current: false,
        );
        expect(viewModel.deviceLabelFor(session), '未知设备');
      }
    });

    test('redacts control surrogate bidi and invisible format characters', () {
      final viewModel = _viewModel(
        _FakeAuthRepository(sessionsResult: const Success([])),
      );
      final unsafeLabels = [
        'Scanner\u0007 alert',
        'Scanner\u0085 alert',
        'Scanner ${String.fromCharCode(0xd800)} alert',
        'Scanner\u202e alert',
        'Scanner\u2067 alert',
        'Scanner\u200d alert',
        'Scanner\u200c alert',
        'Scanner\u200b alert',
        'Scanner\ufeff alert',
      ];

      for (var index = 0; index < unsafeLabels.length; index += 1) {
        final session = DeviceSession(
          id: 'format-$index',
          deviceLabel: unsafeLabels[index],
          platform: 'android',
          userAgentFamily: 'Chrome',
          createdAt: DateTime.utc(2026, 7, 1),
          lastUsedAt: DateTime.utc(2026, 7, 1),
          expiresAt: DateTime.utc(2026, 8, 1),
          current: false,
        );
        expect(viewModel.deviceLabelFor(session), '未知设备');
      }
    });

    test('maps platform and client family through fixed allowlists', () {
      final viewModel = _viewModel(
        _FakeAuthRepository(sessionsResult: const Success([])),
      );

      expect(viewModel.platformLabelFor(_currentSession), 'Android');
      expect(viewModel.userAgentLabelFor(_currentSession), 'RIMS Android 客户端');
      expect(viewModel.userAgentLabelFor(_otherSession), 'Chrome 浏览器');
      expect(viewModel.userAgentLabelFor(_unknownSessionForDisplay), '未知客户端');
    });

    test('formats UTC timestamps with local timezone components', () {
      final viewModel = _viewModel(
        _FakeAuthRepository(sessionsResult: const Success([])),
      );
      final utc = DateTime.utc(2026, 1, 2, 3, 4);
      final session = DeviceSession(
        id: 'local-time',
        deviceLabel: 'Scanner',
        platform: 'android',
        userAgentFamily: 'Chrome',
        createdAt: utc,
        lastUsedAt: utc,
        expiresAt: utc,
        current: false,
      );

      expect(viewModel.createdLabelFor(session), _localTimeLabel(utc));
    });

    test(
      'revoked history is not actionable and survives revoke others',
      () async {
        final repository = _FakeAuthRepository(
          sessionsResult: Success([
            _currentSession,
            _otherSession,
            _revokedSession,
          ]),
        );
        final viewModel = _viewModel(repository);
        await viewModel.load();

        expect(viewModel.canRevokeSession(_revokedSession), isFalse);
        expect(
          await viewModel.revokeSession(_revokedSession),
          DeviceSessionsCommandOutcome.ignored,
        );
        expect(repository.revokeSessionCalls, isEmpty);
        expect(viewModel.canRevokeOthers, isTrue);

        expect(
          await viewModel.revokeOthers(),
          DeviceSessionsCommandOutcome.completed,
        );
        expect(viewModel.sessions, [_currentSession, _revokedSession]);
        expect(viewModel.canRevokeOthers, isFalse);
      },
    );

    test('refresh failure retains previously loaded sessions', () async {
      final repository = _FakeAuthRepository(
        sessionsResult: Success([_currentSession, _otherSession]),
      );
      final viewModel = _viewModel(repository);
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
      final viewModel = _viewModel(repository);
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
      final viewModel = _viewModel(repository);
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
      final viewModel = _viewModel(repository);
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
      final currentViewModel = _viewModel(repository);
      await currentViewModel.load();

      expect(
        await currentViewModel.revokeSession(_currentSession),
        DeviceSessionsCommandOutcome.terminal,
      );
      expect(currentViewModel.isTerminal, isTrue);

      final allViewModel = _viewModel(repository);
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
        final viewModel = _viewModel(repository);
        await viewModel.load();

        final outcome = await viewModel.revokeOthers();

        expect(outcome, DeviceSessionsCommandOutcome.completed);
        expect(viewModel.sessions, [_currentSession]);
        expect(viewModel.successMessage, '已撤销其他登录设备');
      },
    );
  });
}

DeviceSessionsViewModel _viewModel(AuthRepository repository) {
  return DeviceSessionsViewModel(
    repository: repository,
    runTerminalRevocation: (command) async {
      final result = await command();
      return switch (result) {
        Success<void>() => const TerminalSessionRevocationResult.completed(),
        FailureResult<void>(failure: final failure) =>
          TerminalSessionRevocationResult.remoteRejected(failure),
      };
    },
  );
}

String _localTimeLabel(DateTime value) {
  final local = value.toLocal();
  String twoDigits(int part) => part.toString().padLeft(2, '0');
  return '${local.year.toString().padLeft(4, '0')}-'
      '${twoDigits(local.month)}-${twoDigits(local.day)} '
      '${twoDigits(local.hour)}:${twoDigits(local.minute)}';
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

final _unknownSessionForDisplay = DeviceSession(
  id: 's-unknown-display',
  deviceLabel: 'Safe label',
  platform: 'plan9',
  userAgentFamily: 'PrivateCrawler/10.24.16.8',
  createdAt: DateTime.utc(2026, 7, 2, 8),
  lastUsedAt: DateTime.utc(2026, 7, 14, 10, 45),
  expiresAt: DateTime.utc(2026, 8, 2, 8),
  current: false,
);

final _revokedSession = DeviceSession(
  id: 's-revoked',
  deviceLabel: 'Retired scanner',
  platform: 'android',
  userAgentFamily: 'RIMS Android',
  createdAt: DateTime.utc(2026, 7, 2, 8),
  lastUsedAt: DateTime.utc(2026, 7, 14, 10, 45),
  expiresAt: DateTime.utc(2026, 8, 2, 8),
  revokedAt: DateTime.utc(2026, 7, 14, 11),
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
