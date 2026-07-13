import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../../core/result/failure.dart';
import '../../../../core/result/result.dart';
import '../../domain/entities/attachment.dart';
import '../../domain/repositories/attachments_repository.dart';
import '../../domain/services/attachment_picker.dart';
import '../../domain/services/attachment_share_service.dart';
import '../../domain/services/attachment_staging_store.dart';
import '../../../offline/domain/entities/outbox_operation.dart';
import '../../../offline/domain/entities/outbox_graph.dart';
import '../../../offline/domain/repositories/outbox_repository.dart';
import '../../../offline/domain/services/outbox_executor.dart';

enum AttachmentTransferState {
  staged,
  uploading,
  failed,
  interrupted,
  cancelled,
  queuedForSync,
}

typedef AttachmentSynchronization =
    Future<Result<void>> Function(Attachment attachment);

final class OfflineAttachmentReview {
  const OfflineAttachmentReview({
    required this.originalName,
    required this.fileSize,
    required this.bindingType,
  });

  final String originalName;
  final int fileSize;
  final String bindingType;
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
    this.warehouseId,
    this.outboxRepository,
    this.allowedOutboxKindsReader,
    this.outboxContextReader,
    this.outboxContextGenerationReader,
    this.onAttachmentPublished,
    this.beforeAttachmentDelete,
    this.restoreAfterDeleteFailure,
  });

  final AttachmentsRepository repository;
  final AttachmentPicker picker;
  final AttachmentStagingStore stagingStore;
  final AttachmentShareService shareService;
  final AttachmentBinding binding;
  final String userId;
  final int? warehouseId;
  final OutboxRepository? outboxRepository;
  final Set<OutboxOperationKind> Function()? allowedOutboxKindsReader;
  final OutboxExecutionContext? Function()? outboxContextReader;
  final int Function()? outboxContextGenerationReader;
  final AttachmentSynchronization? onAttachmentPublished;
  final AttachmentSynchronization? beforeAttachmentDelete;
  final AttachmentSynchronization? restoreAfterDeleteFailure;

  final List<Attachment> _attachments = [];
  final List<AttachmentQueueItem> _queue = [];
  final Map<int, String> _downloadedPaths = {};
  bool _isLoading = false;
  bool _isPickingOrTransferring = false;
  bool _paused = false;
  bool _disposed = false;
  String? _errorMessage;
  final Map<String, bool> _offlineUploadUnknown = {};
  bool _offlineEnqueueInFlight = false;
  Failure? _offlineUploadFailure;

  List<Attachment> get attachments => List.unmodifiable(_attachments);
  List<AttachmentQueueItem> get queue => List.unmodifiable(_queue);
  bool get isLoading => _isLoading;
  bool get isBusy => _isPickingOrTransferring;
  String? get errorMessage => _errorMessage;
  Failure? get offlineUploadFailure => _offlineUploadFailure;
  String? downloadedPathFor(int attachmentId) => _downloadedPaths[attachmentId];
  OfflineAttachmentReview? offlineUploadReviewFor(String requestId) {
    if (!_offlineUploadUnknown.containsKey(requestId)) return null;
    final index = _queue.indexWhere((item) => item.requestId == requestId);
    if (index < 0) return null;
    final pending = _queue[index].staged.pending;
    return OfflineAttachmentReview(
      originalName: pending.originalName,
      fileSize: pending.fileSize,
      bindingType: pending.binding.businessType,
    );
  }

  Future<bool> confirmOfflineUpload(String requestId) async {
    if (_offlineEnqueueInFlight ||
        !_offlineUploadUnknown.containsKey(requestId) ||
        outboxRepository == null ||
        warehouseId == null ||
        stagingStore is! OutboxAttachmentStagingStore) {
      return false;
    }
    if (!_isOutboxKindAllowed(OutboxOperationKind.attachmentUpload)) {
      _denyOfflineUpload(requestId);
      return false;
    }
    final contextAtStart = outboxContextReader?.call();
    final generationAtStart = outboxContextGenerationReader?.call();
    if (!_matchesOfflineScope(contextAtStart)) {
      _failOfflineUpload(const StateFailure(message: '账号或仓库上下文已变化，附件未加入待同步'));
      return false;
    }
    final index = _queue.indexWhere((item) => item.requestId == requestId);
    if (index < 0) return false;
    _offlineEnqueueInFlight = true;
    try {
      final loaded = await (stagingStore as OutboxAttachmentStagingStore)
          .loadStaged(userId: userId, requestId: requestId);
      if (loaded case FailureResult<StagedAttachment>(:final failure)) {
        _errorMessage = failure.message;
        _notify();
        return false;
      }
      final staged = (loaded as Success<StagedAttachment>).data;
      if (staged.pending.binding != binding || staged.sha256.isEmpty) {
        _errorMessage = '附件暂存归属或内容快照已变化，请重新复核';
        _notify();
        return false;
      }
      final currentContext = outboxContextReader?.call();
      final currentGeneration = outboxContextGenerationReader?.call();
      if (!_isOutboxKindAllowed(OutboxOperationKind.attachmentUpload)) {
        _denyOfflineUpload(requestId);
        return false;
      }
      if (!_matchesOfflineScope(currentContext) ||
          generationAtStart != currentGeneration ||
          contextAtStart?.reviewStamp != currentContext?.reviewStamp) {
        _failOfflineUpload(
          const StateFailure(message: '账号、仓库或权限上下文已变化，附件未加入待同步'),
        );
        return false;
      }
      final operation = OutboxOperation(
        operationId: 'attachment-upload-$requestId',
        idempotencyKey: requestId,
        accountId: userId,
        warehouseId: warehouseId!,
        kind: OutboxOperationKind.attachmentUpload,
        payload: {
          'version': 1,
          'requestId': requestId,
          'expectedSize': staged.pending.fileSize,
          'expectedSha256': staged.sha256,
        },
        state: OutboxState.queued,
        createdAt: DateTime.now().toUtc(),
        requiresStatusProbe: _offlineUploadUnknown[requestId]!,
      );
      final result = await outboxRepository!.enqueueGraph(
        OutboxGraph(operations: [operation]),
      );
      if (result case FailureResult<List<OutboxOperation>>(:final failure)) {
        _errorMessage = failure.message;
        _notify();
        return false;
      }
      final current = _queue.indexWhere((item) => item.requestId == requestId);
      if (current >= 0) {
        _queue[current] = _queue[current].copyWith(
          state: AttachmentTransferState.queuedForSync,
          clearFailure: true,
        );
      }
      _offlineUploadUnknown.remove(requestId);
      _errorMessage = '附件已保存到待同步';
      _notify();
      return true;
    } finally {
      _offlineEnqueueInFlight = false;
    }
  }

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
    final beforeDelete = beforeAttachmentDelete;
    if (beforeDelete != null) {
      final synchronized = await beforeDelete(attachment);
      final canDelete = synchronized.when(
        success: (_) => true,
        failure: (failure) {
          _errorMessage = failure.message;
          _notify();
          return false;
        },
      );
      if (!canDelete) return false;
    }
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
        final restore = restoreAfterDeleteFailure;
        if (restore != null) unawaited(restore(attachment));
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
          final synchronize = onAttachmentPublished;
          if (synchronize != null) {
            final synchronized = await synchronize(replacement);
            final succeeded = synchronized.when(
              success: (_) => true,
              failure: (failure) {
                _errorMessage = failure.message;
                return false;
              },
            );
            if (!succeeded) {
              _notify();
              return false;
            }
          }
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
        _offlineUploadUnknown.remove(requestId);
        _offlineUploadFailure = null;
        final synchronize = onAttachmentPublished;
        if (synchronize != null) {
          final synchronized = await synchronize(attachment);
          final succeeded = synchronized.when(
            success: (_) => true,
            failure: (failure) {
              _queue[index] = item.copyWith(
                state: AttachmentTransferState.failed,
                failure: failure,
              );
              _errorMessage = failure.message;
              return false;
            },
          );
          if (!succeeded) {
            await repository.delete(attachment.id);
            return;
          }
        }
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
        if ((failure is NetworkFailure || failure is TransportUnknownFailure) &&
            outboxRepository != null &&
            warehouseId != null &&
            stagingStore is OutboxAttachmentStagingStore) {
          if (_isOutboxKindAllowed(OutboxOperationKind.attachmentUpload)) {
            _offlineUploadFailure = null;
            _offlineUploadUnknown[requestId] =
                failure is TransportUnknownFailure;
          } else {
            _denyOfflineUpload(requestId, notify: false);
          }
        } else {
          _offlineUploadUnknown.remove(requestId);
          _offlineUploadFailure = null;
        }
        if (_offlineUploadFailure == null) _errorMessage = failure.message;
      },
    );
    _notify();
  }

  void _sortAttachments() {
    _attachments.sort((left, right) => left.position.compareTo(right.position));
  }

  bool _isOutboxKindAllowed(OutboxOperationKind kind) =>
      outboxContextReader?.call()?.allowedKinds.contains(kind) ??
      allowedOutboxKindsReader?.call().contains(kind) ??
      true;

  bool _matchesOfflineScope(OutboxExecutionContext? context) =>
      context == null ||
      (context.accountId == userId && context.warehouseId == warehouseId);

  void _denyOfflineUpload(String requestId, {bool notify = true}) {
    const failure = AuthorizationFailure(message: '当前账号没有附件待同步权限，未保存任何操作');
    _failOfflineUpload(failure, notify: notify);
  }

  void _failOfflineUpload(Failure failure, {bool notify = true}) {
    _offlineUploadFailure = failure;
    _errorMessage = failure.message;
    if (notify) _notify();
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
