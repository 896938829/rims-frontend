import 'package:flutter/foundation.dart';

import '../../../../core/result/failure.dart';
import '../../../../core/result/result.dart';
import '../../../inventory/domain/entities/inventory_item.dart';
import '../../../inventory/domain/repositories/inventory_repository.dart';
import '../../domain/entities/scan_data.dart';
import '../../domain/services/scan_feedback_capability.dart';
import '../../domain/services/scan_lookup_cache.dart';
import '../../domain/services/scan_session_store.dart';

typedef ScanSubmitter = Future<Result<void>> Function(List<ScanLine> lines);

final class ScanSessionViewModel extends ChangeNotifier {
  ScanSessionViewModel({
    required this.inventoryRepository,
    required this.userId,
    required this.warehouseId,
    this.feedback = const NoopScanFeedback(),
    ScanLookupCache? cache,
    ScanSessionStore? store,
    this.mode = ScanMode.single,
    this.maxLines = 100,
    this.duplicateCooldown = const Duration(seconds: 2),
    this.soundEnabled = true,
    this.vibrationEnabled = true,
    DateTime Function()? now,
  }) : _cache = cache ?? ScanLookupCache(),
       _store = store ?? ScanSessionStore(),
       _now = now ?? DateTime.now;

  final InventoryRepository inventoryRepository;
  final ScanFeedbackCapability feedback;
  final ScanLookupCache _cache;
  final ScanSessionStore _store;
  final DateTime Function() _now;
  final String userId;
  final int warehouseId;
  final int maxLines;
  final Duration duplicateCooldown;
  final bool soundEnabled;
  final bool vibrationEnabled;
  final List<ScanLine> _lines = [];
  final Map<int, DateTime> _lastAccepted = {};
  int _requestGeneration = 0;

  ScanMode mode;
  ScanIssue? issue;
  String? message;
  bool isLookingUp = false;
  bool isSubmitting = false;
  bool isComplete = false;

  List<ScanLine> get lines => List.unmodifiable(_lines);

  Future<void> restore() async {
    final snapshot = await _store.restore(
      userId: userId,
      warehouseId: warehouseId,
    );
    if (snapshot == null) return;
    mode = snapshot.mode;
    _lines
      ..clear()
      ..addAll(snapshot.lines);
    notifyListeners();
  }

  void setMode(ScanMode value) {
    if (mode == value) return;
    mode = value;
    isComplete = false;
    notifyListeners();
  }

  Future<void> accept(ScanData scan) async {
    final barcode = scan.value.trim();
    if (barcode.isEmpty) return _reject(ScanIssue.empty, 'Barcode is empty');
    if (!scan.isSupported) {
      return _reject(ScanIssue.unsupported, 'Unsupported barcode format');
    }
    if (isComplete && mode == ScanMode.single) return;

    final generation = ++_requestGeneration;
    isLookingUp = true;
    issue = null;
    message = null;
    notifyListeners();
    final result = await inventoryRepository.findProductByBarcode(barcode);
    if (generation != _requestGeneration) return;
    isLookingUp = false;
    await result.when(
      success: (item) async {
        await _cache.put(
          userId: userId,
          warehouseId: warehouseId,
          barcode: barcode,
          item: item,
        );
        await _acceptItem(item, isStale: false);
      },
      failure: (failure) async {
        if (failure is NetworkFailure) {
          final cached = await _cache.get(
            userId: userId,
            warehouseId: warehouseId,
            barcode: barcode,
          );
          if (generation != _requestGeneration) return;
          if (cached != null) {
            await _acceptItem(
              cached.identity.toNonAuthoritativeItem(),
              isStale: true,
            );
            return;
          }
        }
        await _reject(_issueFor(failure), failure.message);
      },
    );
  }

  Future<void> _acceptItem(InventoryItem item, {required bool isStale}) async {
    final index = _lines.indexWhere(
      (line) => line.item.productId == item.productId,
    );
    final now = _now();
    if (mode == ScanMode.continuous &&
        _lastAccepted[item.productId]?.add(duplicateCooldown).isAfter(now) ==
            true) {
      return _duplicate();
    }
    if (index < 0 && _lines.length >= maxLines) {
      return _reject(ScanIssue.maxLines, 'Maximum scan lines reached');
    }
    switch (mode) {
      case ScanMode.single:
        _lines
          ..clear()
          ..add(ScanLine(item: item, quantity: 1, isStale: isStale));
        isComplete = true;
        break;
      case ScanMode.continuous:
        if (index < 0) {
          _lines.add(ScanLine(item: item, quantity: 1, isStale: isStale));
        }
        break;
      case ScanMode.batch:
        if (index >= 0) return _duplicate();
        _lines.add(ScanLine(item: item, quantity: 1, isStale: isStale));
        break;
      case ScanMode.quantity:
        if (index >= 0) {
          _lines[index] = _lines[index].copyWith(
            quantity: _lines[index].quantity + 1,
          );
        } else {
          _lines.add(ScanLine(item: item, quantity: 1, isStale: isStale));
        }
        break;
    }
    _lastAccepted[item.productId] = now;
    await _persist();
    await _play(ScanFeedbackKind.accepted);
    notifyListeners();
  }

  Future<void> increment(int productId) => _changeQuantity(productId, 1);
  Future<void> decrement(int productId) => _changeQuantity(productId, -1);

  Future<void> _changeQuantity(int productId, int delta) async {
    final index = _lines.indexWhere((line) => line.item.productId == productId);
    if (index < 0) return;
    final quantity = _lines[index].quantity + delta;
    if (quantity <= 0) {
      _lines.removeAt(index);
    } else {
      _lines[index] = _lines[index].copyWith(quantity: quantity);
    }
    await _persist();
    notifyListeners();
  }

  Future<Result<void>> submit(ScanSubmitter submitter) async {
    isSubmitting = true;
    notifyListeners();
    final result = await submitter(lines);
    isSubmitting = false;
    if (result.isSuccess) {
      await clear();
      await _play(ScanFeedbackKind.completed);
    } else {
      result.when(
        success: (_) {},
        failure: (failure) => message = failure.message,
      );
      notifyListeners();
    }
    return result;
  }

  Future<void> clear() async {
    _requestGeneration++;
    _lines.clear();
    _lastAccepted.clear();
    issue = null;
    message = null;
    isComplete = false;
    isLookingUp = false;
    await _store.clear(userId: userId, warehouseId: warehouseId);
    notifyListeners();
  }

  Future<void> _persist() => _store.save(
    userId: userId,
    warehouseId: warehouseId,
    session: ScanSessionSnapshot(mode: mode, lines: lines),
  );

  Future<void> _duplicate() async {
    message = 'Duplicate scan';
    await _play(ScanFeedbackKind.duplicate);
    notifyListeners();
  }

  Future<void> _reject(ScanIssue value, String text) async {
    isLookingUp = false;
    issue = value;
    message = text;
    await _play(ScanFeedbackKind.rejected);
    notifyListeners();
  }

  ScanIssue _issueFor(Failure failure) {
    if (failure is AuthorizationFailure) {
      return ScanIssue.permissionDenied;
    }
    if (failure is NotFoundFailure) {
      return ScanIssue.unknown;
    }
    if (failure is NetworkFailure) {
      return ScanIssue.network;
    }
    final lower = failure.message.toLowerCase();
    if (lower.contains('批次') || lower.contains('batch')) {
      return ScanIssue.wrongBatch;
    }
    if (lower.contains('仓库') || lower.contains('warehouse')) {
      return ScanIssue.wrongWarehouse;
    }
    if (lower.contains('停用') || lower.contains('disabled')) {
      return ScanIssue.disabled;
    }
    return ScanIssue.unknown;
  }

  Future<void> _play(ScanFeedbackKind kind) =>
      feedback.play(kind, sound: soundEnabled, vibration: vibrationEnabled);
}
