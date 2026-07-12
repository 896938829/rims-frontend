import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../../core/result/failure.dart';
import '../../domain/entities/attachment.dart';
import '../../domain/repositories/attachments_repository.dart';
import '../../domain/services/attachment_picker.dart';
import '../../domain/services/attachment_share_service.dart';
import '../../domain/services/attachment_staging_store.dart';

enum AttachmentTransferState {
  staged,
  uploading,
  failed,
  interrupted,
  cancelled,
}

final class AttachmentQueueItem {
  const AttachmentQueueItem({
    required this.staged,
    required this.state,
    required this.sent,
    required this.total,
    required this.failure,
    required this.cancellation,
  });

  factory AttachmentQueueItem.interrupted(StagedAttachment staged) {
    return AttachmentQueueItem(
      staged: staged,
      state: AttachmentTransferState.interrupted,
      sent: 0,
      total: staged.pending.fileSize,
      failure: null,
      cancellation: TransferCancellation(),
    );
  }

  final StagedAttachment staged;
  final AttachmentTransferState state;
  final int sent;
  final int total;
  final Failure? failure;
  final TransferCancellation cancellation;

  String get requestId => staged.pending.requestId;

  AttachmentQueueItem copyWith({
    AttachmentTransferState? state,
    int? sent,
    int? total,
    Failure? failure,
    bool clearFailure = false,
    TransferCancellation? cancellation,
  }) {
    return AttachmentQueueItem(
      staged: staged,
      state: state ?? this.state,
      sent: sent ?? this.sent,
      total: total ?? this.total,
      failure: clearFailure ? null : failure ?? this.failure,
      cancellation: cancellation ?? this.cancellation,
    );
  }
}

final class AttachmentsViewModel extends ChangeNotifier {
  AttachmentsViewModel({
    required this.repository,
    required this.picker,
    required this.stagingStore,
    required this.shareService,
    required this.binding,
    required this.userId,
  });

  final AttachmentsRepository repository;
  final AttachmentPicker picker;
  final AttachmentStagingStore stagingStore;
  final AttachmentShareService shareService;
  final AttachmentBinding binding;
  final String userId;

  final List<Attachment> _attachments = [];
  final List<AttachmentQueueItem> _queue = [];
  final Map<int, String> _downloadedPaths = {};
  bool _isLoading = false;
  bool _isPickingOrTransferring = false;
  bool _paused = false;
  bool _disposed = false;
  String? _errorMessage;

  List<Attachment> get attachments => List.unmodifiable(_attachments);
  List<AttachmentQueueItem> get queue => List.unmodifiable(_queue);
  bool get isLoading => _isLoading;
  bool get isBusy => _isPickingOrTransferring;
  String? get errorMessage => _errorMessage;
  String? downloadedPathFor(int attachmentId) => _downloadedPaths[attachmentId];

  Future<void> load() async {
    _isLoading = true;
    _errorMessage = null;
    _notify();
    final result = await repository.list(binding: binding);
    if (_disposed) return;
    result.when(
      success: (page) {
        _attachments
          ..clear()
          ..addAll(page.items);
        _sortAttachments();
      },
      failure: (failure) => _errorMessage = failure.message,
    );
    _isLoading = false;
    _notify();
  }

  Future<void> pickAndUpload(AttachmentPickSource source) async {
    if (_isPickingOrTransferring || _paused) return;
    _isPickingOrTransferring = true;
    _errorMessage = null;
    _notify();
    try {
      final picked = await picker.pick(source);
      if (_disposed) return;
      final selection = picked.when(
        success: (value) => value,
        failure: (failure) {
          _errorMessage = failure.message;
          return null;
        },
      );
      if (selection == null) return;
      final stagedResult = await stagingStore.stage(
        userId: userId,
        binding: binding,
        selection: selection,
        existingCount: _attachments.length + _queue.length,
      );
      if (_disposed) return;
      final staged = stagedResult.when(
        success: (value) => value,
        failure: (failure) {
          _errorMessage = failure.message;
          return null;
        },
      );
      if (staged == null) return;
      final item = AttachmentQueueItem(
        staged: staged,
        state: AttachmentTransferState.staged,
        sent: 0,
        total: staged.pending.fileSize,
        failure: null,
        cancellation: TransferCancellation(),
      );
      _queue.add(item);
      _notify();
      await _upload(item.requestId);
    } finally {
      _isPickingOrTransferring = false;
      _notify();
    }
  }

  Future<void> recoverInterrupted() async {
    for (final selection in picker.takeRecovered()) {
      final staged = await stagingStore.stage(
        userId: userId,
        binding: binding,
        selection: selection,
        existingCount: _attachments.length + _queue.length,
      );
      if (_disposed) return;
      staged.when(
        success: (item) {
          if (!_queue.any(
            (queued) => queued.requestId == item.pending.requestId,
          )) {
            _queue.add(AttachmentQueueItem.interrupted(item));
          }
        },
        failure: (failure) => _errorMessage = failure.message,
      );
    }
    final result = await stagingStore.recoverForUser(userId);
    if (_disposed) return;
    result.when(
      success: (items) {
        final known = _queue.map((item) => item.requestId).toSet();
        for (final staged in items) {
          if (staged.pending.binding == binding &&
              known.add(staged.pending.requestId)) {
            _queue.add(AttachmentQueueItem.interrupted(staged));
          }
        }
      },
      failure: (failure) => _errorMessage = failure.message,
    );
    _notify();
  }

  Future<void> retry(String requestId) async {
    if (_isPickingOrTransferring || _paused) return;
    final index = _queue.indexWhere((item) => item.requestId == requestId);
    if (index < 0) return;
    _queue[index] = _queue[index].copyWith(
      state: AttachmentTransferState.staged,
      sent: 0,
      clearFailure: true,
      cancellation: TransferCancellation(),
    );
    _isPickingOrTransferring = true;
    _notify();
    try {
      await _upload(requestId);
    } finally {
      _isPickingOrTransferring = false;
      _notify();
    }
  }

  void cancel(String requestId) {
    final index = _queue.indexWhere((item) => item.requestId == requestId);
    if (index < 0) return;
    final item = _queue[index];
    item.cancellation.cancel();
    _queue[index] = item.copyWith(state: AttachmentTransferState.cancelled);
    _notify();
  }

  void pause() {
    _paused = true;
    for (var index = 0; index < _queue.length; index++) {
      final item = _queue[index];
      if (item.state == AttachmentTransferState.uploading) {
        item.cancellation.cancel();
        _queue[index] = item.copyWith(
          state: AttachmentTransferState.interrupted,
        );
      }
    }
    _notify();
  }

  Future<void> resume() async {
    _paused = false;
    final interrupted = _queue
        .where((item) => item.state == AttachmentTransferState.interrupted)
        .map((item) => item.requestId)
        .toList(growable: false);
    for (final requestId in interrupted) {
      await retry(requestId);
    }
  }

  Future<void> downloadAndShare(Attachment attachment) async {
    _errorMessage = null;
    final download = await repository.download(attachment);
    if (_disposed) return;
    final path = download.when(
      success: (value) => value,
      failure: (failure) {
        _errorMessage = failure.message;
        return null;
      },
    );
    if (path == null) {
      _notify();
      return;
    }
    _downloadedPaths[attachment.id] = path;
    _notify();
    final shared = await shareService.share(
      path: path,
      originalName: attachment.originalName,
      mimeType: attachment.mimeType,
    );
    if (_disposed) return;
    shared.when(
      success: (_) {},
      failure: (failure) => _errorMessage = failure.message,
    );
    _notify();
  }

  Future<bool> delete(Attachment attachment) async {
    final original = List<Attachment>.of(_attachments);
    _attachments.removeWhere((item) => item.id == attachment.id);
    _errorMessage = null;
    _notify();
    final result = await repository.delete(attachment.id);
    if (_disposed) return false;
    return result.when(
      success: (_) => true,
      failure: (failure) {
        _attachments
          ..clear()
          ..addAll(original);
        _errorMessage = failure.message;
        _notify();
        return false;
      },
    );
  }

  Future<bool> reorder(List<int> fileIds) async {
    if (fileIds.length != _attachments.length ||
        fileIds.toSet().length != fileIds.length ||
        !fileIds.toSet().containsAll(_attachments.map((item) => item.id))) {
      _errorMessage = 'Attachment order must contain the exact current set.';
      _notify();
      return false;
    }
    final original = List<Attachment>.of(_attachments);
    final byId = {for (final item in _attachments) item.id: item};
    _attachments
      ..clear()
      ..addAll(fileIds.map((id) => byId[id]!));
    _notify();
    final result = await repository.reorder(binding, fileIds);
    if (_disposed) return false;
    return result.when(
      success: (_) => true,
      failure: (failure) {
        _attachments
          ..clear()
          ..addAll(original);
        _errorMessage = failure.message;
        _notify();
        return false;
      },
    );
  }

  Future<bool> replace(Attachment existing, AttachmentPickSource source) async {
    if (_isPickingOrTransferring || _paused) return false;
    _isPickingOrTransferring = true;
    _errorMessage = null;
    _notify();
    try {
      final picked = await picker.pick(source);
      final selection = picked.when(
        success: (value) => value,
        failure: (failure) {
          _errorMessage = failure.message;
          return null;
        },
      );
      if (selection == null) return false;
      final stagedResult = await stagingStore.stage(
        userId: userId,
        binding: binding,
        selection: selection,
        existingCount: _attachments.length - 1,
      );
      final staged = stagedResult.when(
        success: (value) => value,
        failure: (failure) {
          _errorMessage = failure.message;
          return null;
        },
      );
      if (staged == null) return false;
      final cancellation = TransferCancellation();
      final result = await repository.replace(
        existing,
        staged.pending,
        onProgress: (_, _) {},
        cancellation: cancellation,
      );
      if (_disposed) return false;
      return await result.when(
        success: (replacement) async {
          final index = _attachments.indexWhere(
            (item) => item.id == existing.id,
          );
          if (index >= 0) _attachments[index] = replacement;
          await stagingStore.remove(userId, staged.pending.requestId);
          _notify();
          return true;
        },
        failure: (failure) async {
          _errorMessage = failure.message;
          _notify();
          return false;
        },
      );
    } finally {
      _isPickingOrTransferring = false;
      _notify();
    }
  }

  Future<void> _upload(String requestId) async {
    var index = _queue.indexWhere((item) => item.requestId == requestId);
    if (index < 0) return;
    var item = _queue[index];
    _queue[index] = item.copyWith(
      state: AttachmentTransferState.uploading,
      clearFailure: true,
    );
    _notify();
    final result = await repository.upload(
      item.staged.pending,
      onProgress: (sent, total) {
        if (_disposed) return;
        final progressIndex = _queue.indexWhere(
          (candidate) => candidate.requestId == requestId,
        );
        if (progressIndex < 0) return;
        _queue[progressIndex] = _queue[progressIndex].copyWith(
          sent: sent,
          total: total,
        );
        _notify();
      },
      cancellation: item.cancellation,
    );
    if (_disposed) return;
    index = _queue.indexWhere((candidate) => candidate.requestId == requestId);
    if (index < 0) return;
    item = _queue[index];
    await result.when(
      success: (attachment) async {
        _attachments.removeWhere((existing) => existing.id == attachment.id);
        _attachments.add(attachment);
        _sortAttachments();
        _queue.removeAt(index);
        await stagingStore.remove(userId, requestId);
      },
      failure: (failure) async {
        final state = item.state == AttachmentTransferState.cancelled
            ? AttachmentTransferState.cancelled
            : _paused || failure is CancellationFailure
            ? AttachmentTransferState.interrupted
            : AttachmentTransferState.failed;
        _queue[index] = item.copyWith(state: state, failure: failure);
        _errorMessage = failure.message;
      },
    );
    _notify();
  }

  void _sortAttachments() {
    _attachments.sort((left, right) => left.position.compareTo(right.position));
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    for (final item in _queue) {
      item.cancellation.cancel();
    }
    super.dispose();
  }
}
