import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../../core/result/result.dart';
import '../../domain/entities/device_session.dart';
import '../../domain/entities/terminal_session_revocation.dart';
import '../../domain/repositories/auth_repository.dart';
import '../device_session_display_sanitizer.dart';

enum DeviceSessionsCommandOutcome {
  completed,
  terminal,
  terminalWithCleanupDebt,
  failed,
  ignored,
}

typedef TerminalSessionRevocationRunner =
    Future<TerminalSessionRevocationResult> Function(
      Future<Result<void>> Function() command,
    );

final class DeviceSessionsViewModel extends ChangeNotifier {
  DeviceSessionsViewModel({
    required this.repository,
    required this.runTerminalRevocation,
    DateTime Function()? now,
  }) : now = now ?? DateTime.now;

  final AuthRepository repository;
  final TerminalSessionRevocationRunner runTerminalRevocation;
  final DateTime Function() now;
  List<DeviceSession> _sessions = const [];
  bool _isBusy = false;
  bool _hasLoaded = false;
  bool _isTerminal = false;
  bool _disposed = false;
  int _generation = 0;
  int _expiryScheduleGeneration = 0;
  Timer? _expiryTimer;
  String? _errorMessage;
  String? _successMessage;

  List<DeviceSession> get sessions => _sessions;
  bool get isBusy => _isBusy;
  bool get isInitialLoading => _isBusy && !_hasLoaded && _sessions.isEmpty;
  bool get isEmpty => _hasLoaded && !_isBusy && _sessions.isEmpty;
  bool get hasRetainedDataError =>
      _sessions.isNotEmpty && _errorMessage != null;
  bool get isTerminal => _isTerminal;
  String? get errorMessage => _errorMessage;
  String? get successMessage => _successMessage;
  bool get canRevokeOthers {
    final timestamp = now();
    return _hasActiveNonCurrentAt(timestamp);
  }

  bool canRevokeSession(DeviceSession session) => _isActiveAt(session, now());

  String deviceLabelFor(DeviceSession session) =>
      DeviceSessionDisplaySanitizer.deviceLabel(session.deviceLabel);

  String platformLabelFor(DeviceSession session) =>
      DeviceSessionDisplaySanitizer.platformLabel(session.platform);

  String userAgentLabelFor(DeviceSession session) =>
      DeviceSessionDisplaySanitizer.userAgentLabel(session.userAgentFamily);

  String createdLabelFor(DeviceSession session) =>
      _formatDateTime(session.createdAt);

  String lastUsedLabelFor(DeviceSession session) =>
      _formatDateTime(session.lastUsedAt);

  String expiresLabelFor(DeviceSession session) =>
      _formatDateTime(session.expiresAt);

  String? revokedLabelFor(DeviceSession session) {
    final revokedAt = session.revokedAt;
    return revokedAt == null ? null : _formatDateTime(revokedAt);
  }

  Future<void> load() => _load(isRefresh: false);

  Future<void> refresh() => _load(isRefresh: true);

  Future<void> _load({required bool isRefresh}) async {
    final generation = _beginOperation();
    if (generation == null) return;
    try {
      final result = await repository.listDeviceSessions();
      if (!_isCurrent(generation)) return;
      _hasLoaded = true;
      result.when(
        success: (sessions) {
          _sessions = List.unmodifiable(sessions);
          _errorMessage = null;
          _scheduleExpiryNotification();
        },
        failure: (_) {
          _errorMessage = isRefresh || _sessions.isNotEmpty
              ? '刷新登录设备失败，请重试'
              : '加载登录设备失败，请重试';
        },
      );
    } on Object {
      if (!_isCurrent(generation)) return;
      _hasLoaded = true;
      _errorMessage = isRefresh || _sessions.isNotEmpty
          ? '刷新登录设备失败，请重试'
          : '加载登录设备失败，请重试';
    } finally {
      _finishOperation(generation);
    }
  }

  Future<DeviceSessionsCommandOutcome> revokeSession(
    DeviceSession session,
  ) async {
    final timestamp = now();
    if (!_isActiveAt(session, timestamp)) {
      return DeviceSessionsCommandOutcome.ignored;
    }
    final generation = _beginOperation();
    if (generation == null) return DeviceSessionsCommandOutcome.ignored;
    try {
      if (session.current) {
        final result = await runTerminalRevocation(
          () => repository.revokeDeviceSession(session.id),
        );
        if (!_isCurrent(generation)) {
          return DeviceSessionsCommandOutcome.ignored;
        }
        return _terminalOutcome(result, revokeAll: false);
      }
      final result = await repository.revokeDeviceSession(session.id);
      if (!_isCurrent(generation)) return DeviceSessionsCommandOutcome.ignored;
      return result.when(
        success: (_) {
          _sessions = List.unmodifiable(
            _sessions.where((candidate) => candidate.id != session.id),
          );
          _scheduleExpiryNotification();
          _errorMessage = null;
          _successMessage =
              '已撤销 ${DeviceSessionDisplaySanitizer.deviceLabel(session.deviceLabel)}';
          return DeviceSessionsCommandOutcome.completed;
        },
        failure: (_) => _commandFailure('撤销设备失败，请重试'),
      );
    } on Object {
      if (!_isCurrent(generation)) return DeviceSessionsCommandOutcome.ignored;
      return _commandFailure('撤销设备失败，请重试');
    } finally {
      _finishOperation(generation);
    }
  }

  Future<DeviceSessionsCommandOutcome> revokeOthers() async {
    final timestamp = now();
    if (!_hasActiveNonCurrentAt(timestamp)) {
      return DeviceSessionsCommandOutcome.ignored;
    }
    final generation = _beginOperation();
    if (generation == null) return DeviceSessionsCommandOutcome.ignored;
    try {
      final result = await repository.revokeOtherDeviceSessions();
      if (!_isCurrent(generation)) return DeviceSessionsCommandOutcome.ignored;
      return result.when(
        success: (_) {
          final timestamp = now();
          _sessions = List.unmodifiable(
            _sessions.where(
              (session) => session.current || !_isActiveAt(session, timestamp),
            ),
          );
          _scheduleExpiryNotification();
          _errorMessage = null;
          _successMessage = '已撤销其他登录设备';
          return DeviceSessionsCommandOutcome.completed;
        },
        failure: (_) => _commandFailure('撤销其他设备失败，请重试'),
      );
    } on Object {
      if (!_isCurrent(generation)) return DeviceSessionsCommandOutcome.ignored;
      return _commandFailure('撤销其他设备失败，请重试');
    } finally {
      _finishOperation(generation);
    }
  }

  Future<DeviceSessionsCommandOutcome> revokeAll() async {
    final generation = _beginOperation();
    if (generation == null) return DeviceSessionsCommandOutcome.ignored;
    try {
      final result = await runTerminalRevocation(() async {
        final result = await repository.revokeAllDeviceSessions();
        return switch (result) {
          Success<int>() => const Success<void>(null),
          FailureResult<int>(failure: final failure) => FailureResult<void>(
            failure,
          ),
        };
      });
      if (!_isCurrent(generation)) return DeviceSessionsCommandOutcome.ignored;
      return _terminalOutcome(result, revokeAll: true);
    } on Object {
      if (!_isCurrent(generation)) return DeviceSessionsCommandOutcome.ignored;
      return _commandFailure('撤销全部设备失败，请重试');
    } finally {
      _finishOperation(generation);
    }
  }

  int? _beginOperation() {
    if (_disposed || _isBusy || _isTerminal) return null;
    final generation = ++_generation;
    _isBusy = true;
    _errorMessage = null;
    _successMessage = null;
    notifyListeners();
    return generation;
  }

  DeviceSessionsCommandOutcome _commandFailure(String message) {
    _errorMessage = message;
    return DeviceSessionsCommandOutcome.failed;
  }

  DeviceSessionsCommandOutcome _terminalOutcome(
    TerminalSessionRevocationResult result, {
    required bool revokeAll,
  }) {
    return switch (result.status) {
      TerminalSessionRevocationStatus.remoteRejected => _commandFailure(
        revokeAll ? '撤销全部设备失败，请重试' : '撤销设备失败，请重试',
      ),
      TerminalSessionRevocationStatus.completed => _markTerminal(
        revokeAll: revokeAll,
        cleanupDebt: false,
      ),
      TerminalSessionRevocationStatus.terminalWithCleanupDebt => _markTerminal(
        revokeAll: revokeAll,
        cleanupDebt: true,
      ),
    };
  }

  DeviceSessionsCommandOutcome _markTerminal({
    required bool revokeAll,
    required bool cleanupDebt,
  }) {
    if (revokeAll) _sessions = const [];
    _cancelExpiryNotification();
    _isTerminal = true;
    _errorMessage = cleanupDebt ? '登录已撤销，本机安全清理将在下次登录前继续' : null;
    return cleanupDebt
        ? DeviceSessionsCommandOutcome.terminalWithCleanupDebt
        : DeviceSessionsCommandOutcome.terminal;
  }

  bool _isCurrent(int generation) => !_disposed && generation == _generation;

  bool _isActiveAt(DeviceSession session, DateTime timestamp) =>
      session.revokedAt == null && session.expiresAt.isAfter(timestamp);

  bool _hasActiveNonCurrentAt(DateTime timestamp) => _sessions.any(
    (session) => !session.current && _isActiveAt(session, timestamp),
  );

  void _scheduleExpiryNotification() {
    _expiryTimer?.cancel();
    _expiryTimer = null;
    final scheduleGeneration = ++_expiryScheduleGeneration;
    if (_disposed || _isTerminal) return;

    final timestamp = now();
    DateTime? nextExpiry;
    for (final session in _sessions) {
      if (!_isActiveAt(session, timestamp)) continue;
      if (nextExpiry == null || session.expiresAt.isBefore(nextExpiry)) {
        nextExpiry = session.expiresAt;
      }
    }
    if (nextExpiry == null) return;

    _expiryTimer = Timer(nextExpiry.difference(timestamp), () {
      if (_disposed || scheduleGeneration != _expiryScheduleGeneration) return;
      _expiryTimer = null;
      notifyListeners();
      _scheduleExpiryNotification();
    });
  }

  void _cancelExpiryNotification() {
    _expiryScheduleGeneration += 1;
    _expiryTimer?.cancel();
    _expiryTimer = null;
  }

  void _finishOperation(int? generation) {
    if (generation == null || !_isCurrent(generation)) return;
    _isBusy = false;
    notifyListeners();
  }

  String _formatDateTime(DateTime value) {
    final local = value.toLocal();
    String twoDigits(int part) => part.toString().padLeft(2, '0');
    return '${local.year.toString().padLeft(4, '0')}-'
        '${twoDigits(local.month)}-${twoDigits(local.day)} '
        '${twoDigits(local.hour)}:${twoDigits(local.minute)}';
  }

  @override
  void dispose() {
    _disposed = true;
    _generation += 1;
    _cancelExpiryNotification();
    super.dispose();
  }
}
