import 'package:flutter/foundation.dart';

import '../../domain/entities/device_session.dart';
import '../../domain/repositories/auth_repository.dart';

enum DeviceSessionsCommandOutcome { completed, terminal, failed, ignored }

final class DeviceSessionsViewModel extends ChangeNotifier {
  DeviceSessionsViewModel({required this.repository});

  final AuthRepository repository;
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
      _safeDeviceLabel(session.deviceLabel);

  String platformLabelFor(DeviceSession session) {
    return switch (session.platform.trim().toLowerCase()) {
      'android' => 'Android',
      'ios' || 'iphone' || 'ipad' => 'iOS',
      'windows' => 'Windows',
      'macos' || 'macintosh' => 'macOS',
      'linux' => 'Linux',
      'web' => 'Web',
      _ => '未知平台',
    };
  }

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
      final result = await repository.revokeDeviceSession(session.id);
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
          _successMessage = '已撤销 ${_safeDeviceLabel(session.deviceLabel)}';
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
      final result = await repository.revokeAllDeviceSessions();
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

  String _safeDeviceLabel(String value) {
    final label = value.trim();
    return label.isEmpty || label.toLowerCase() == 'unknown device'
        ? '未知设备'
        : label;
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
