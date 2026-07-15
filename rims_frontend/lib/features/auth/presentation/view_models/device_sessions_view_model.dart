import 'package:flutter/foundation.dart';

import '../../../../core/result/result.dart';
import '../../domain/entities/device_session.dart';
import '../../domain/repositories/auth_repository.dart';
import '../device_session_display_sanitizer.dart';

enum DeviceSessionsCommandOutcome { completed, terminal, failed, ignored }

typedef TerminalSessionRevocationRunner =
    Future<Result<void>> Function(Future<Result<void>> Function() command);

final class DeviceSessionsViewModel extends ChangeNotifier {
  DeviceSessionsViewModel({
    required this.repository,
    required this.runTerminalRevocation,
  });

  final AuthRepository repository;
  final TerminalSessionRevocationRunner runTerminalRevocation;
  List<DeviceSession> _sessions = const [];
  bool _isBusy = false;
  bool _hasLoaded = false;
  bool _isTerminal = false;
  bool _disposed = false;
  int _generation = 0;
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
    final generation = _beginOperation();
    if (generation == null) return DeviceSessionsCommandOutcome.ignored;
    try {
      final result = session.current
          ? await runTerminalRevocation(
              () => repository.revokeDeviceSession(session.id),
            )
          : await repository.revokeDeviceSession(session.id);
      if (!_isCurrent(generation)) return DeviceSessionsCommandOutcome.ignored;
      return result.when(
        success: (_) {
          _sessions = List.unmodifiable(
            _sessions.where((candidate) => candidate.id != session.id),
          );
          _errorMessage = null;
          if (session.current) {
            _isTerminal = true;
            return DeviceSessionsCommandOutcome.terminal;
          }
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
    final generation = _beginOperation();
    if (generation == null) return DeviceSessionsCommandOutcome.ignored;
    try {
      final result = await repository.revokeOtherDeviceSessions();
      if (!_isCurrent(generation)) return DeviceSessionsCommandOutcome.ignored;
      return result.when(
        success: (_) {
          _sessions = List.unmodifiable(
            _sessions.where((session) => session.current),
          );
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
      return result.when(
        success: (_) {
          _sessions = const [];
          _errorMessage = null;
          _isTerminal = true;
          return DeviceSessionsCommandOutcome.terminal;
        },
        failure: (_) => _commandFailure('撤销全部设备失败，请重试'),
      );
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

  bool _isCurrent(int generation) => !_disposed && generation == _generation;

  void _finishOperation(int? generation) {
    if (generation == null || !_isCurrent(generation)) return;
    _isBusy = false;
    notifyListeners();
  }

  String _formatDateTime(DateTime value) {
    String twoDigits(int part) => part.toString().padLeft(2, '0');
    return '${value.year.toString().padLeft(4, '0')}-'
        '${twoDigits(value.month)}-${twoDigits(value.day)} '
        '${twoDigits(value.hour)}:${twoDigits(value.minute)}';
  }

  @override
  void dispose() {
    _disposed = true;
    _generation += 1;
    super.dispose();
  }
}
