import 'package:flutter/foundation.dart';

import '../../../../core/result/result.dart';
import '../../../../core/result/failure.dart';
import '../../../attachments/domain/entities/attachment.dart';
import '../../../attachments/domain/services/attachment_picker.dart';
import '../../../attachments/domain/services/attachment_staging_store.dart';
import '../../domain/repositories/document_draft_repository.dart';

final class DraftAttachmentsViewModel extends ChangeNotifier {
  DraftAttachmentsViewModel({
    required this.picker,
    required this.stagingStore,
    required this.userId,
    required this.draftIdProvider,
    required this.onChanged,
    this.draftRepository,
    this.draftAccountId,
    this.onChangedForDraft,
    this.onBusyChanged,
    bool Function()? canMutate,
    int Function()? mutationEpochProvider,
  }) : canMutate = canMutate ?? _alwaysCanMutate,
       mutationEpochProvider = mutationEpochProvider ?? _zeroEpoch;

  final AttachmentPicker picker;
  final AttachmentStagingStore stagingStore;
  final String userId;
  final String Function() draftIdProvider;
  final ValueChanged<List<String>> onChanged;
  final DocumentDraftRepository? draftRepository;
  final String? draftAccountId;
  final void Function(String draftId, List<String> requestIds)?
  onChangedForDraft;
  final ValueChanged<bool>? onBusyChanged;
  final bool Function() canMutate;
  final int Function() mutationEpochProvider;
  List<StagedAttachment> _staged = const [];
  bool _isBusy = false;
  bool _isDisposed = false;
  int _generation = 0;
  String? _errorMessage;

  List<StagedAttachment> get staged => List.unmodifiable(_staged);
  bool get isBusy => _isBusy;
  bool get isMutationAllowed => !_isDisposed && canMutate();
  String? get errorMessage => _errorMessage;

  Future<void> pick(AttachmentPickSource source) async {
    if (_isBusy || _staged.length >= 9 || !isMutationAllowed) return;
    final generation = ++_generation;
    final draftId = draftIdProvider();
    final mutationEpoch = mutationEpochProvider();
    _setBusy(true);
    _errorMessage = null;
    _notify();
    try {
      final picked = await picker.pick(source);
      if (!_matchesOperation(generation, draftId, mutationEpoch)) return;
      final selection = picked.when(
        success: (value) => value,
        failure: (failure) {
          _errorMessage = failure.message;
          return null;
        },
      );
      if (selection == null) return;
      final result = await stagingStore.stage(
        userId: userId,
        binding: AttachmentBinding.documentDraft(draftId),
        selection: selection,
        existingCount: _staged.length,
      );
      switch (result) {
        case Success(:final data):
          if (!_matchesOperation(generation, draftId, mutationEpoch)) {
            await stagingStore.remove(userId, data.pending.requestId);
            return;
          }
          {
            final item = data;
            _staged = List.unmodifiable([..._staged, item]);
            _publish(draftId);
          }
        case FailureResult(:final failure):
          if (_matchesOperation(generation, draftId, mutationEpoch)) {
            _errorMessage = failure.message;
          }
      }
    } finally {
      _setBusy(false);
    }
  }

  Future<void> recover(List<String> requestIds) async {
    if (!isMutationAllowed) return;
    final generation = ++_generation;
    final draftId = draftIdProvider();
    final mutationEpoch = mutationEpochProvider();
    if (requestIds.isEmpty) {
      if (!_matchesOperation(generation, draftId, mutationEpoch)) return;
      _staged = const [];
      _notify();
      return;
    }
    final expected = requestIds.toSet();
    final result = await stagingStore.recoverForUser(userId);
    if (!_matchesOperation(generation, draftId, mutationEpoch)) return;
    result.when(
      success: (items) {
        _staged = items
            .where(
              (item) =>
                  item.pending.binding.localDraftId == draftId &&
                  expected.contains(item.pending.requestId),
            )
            .toList(growable: false);
      },
      failure: (failure) => _errorMessage = failure.message,
    );
    _notify();
  }

  Future<void> remove(String requestId) async {
    if (_isBusy || !isMutationAllowed) return;
    final generation = ++_generation;
    final draftId = draftIdProvider();
    final accountId = draftAccountId;
    final mutationEpoch = mutationEpochProvider();
    final requestIdsBefore = _staged
        .map((item) => item.pending.requestId)
        .toList(growable: false);
    _setBusy(true);
    _errorMessage = null;
    try {
      final result = await stagingStore.remove(userId, requestId);
      switch (result) {
        case Success<void>():
          final reconciledIds = requestIdsBefore
              .where((id) => id != requestId)
              .toList(growable: false);
          final isCurrentDraft =
              !_isDisposed &&
              generation == _generation &&
              draftIdProvider() == draftId;
          if (!isCurrentDraft) {
            await _persistRemovedAttachment(
              accountId: accountId,
              draftId: draftId,
              requestId: requestId,
            );
            onChangedForDraft?.call(draftId, reconciledIds);
            return;
          }
          _staged = _staged
              .where((item) => item.pending.requestId != requestId)
              .toList(growable: false);
          _publish(
            draftId,
            preferScoped:
                mutationEpochProvider() != mutationEpoch || !canMutate(),
          );
        case FailureResult<void>(:final failure):
          if (!_isDisposed &&
              generation == _generation &&
              draftIdProvider() == draftId) {
            _errorMessage = failure.message;
          }
      }
    } finally {
      _setBusy(false);
    }
  }

  void _publish(String draftId, {bool preferScoped = false}) {
    final requestIds = _staged
        .map((item) => item.pending.requestId)
        .toList(growable: false);
    final scopedCallback = onChangedForDraft;
    if (preferScoped && scopedCallback != null) {
      scopedCallback(draftId, requestIds);
    } else {
      onChanged(requestIds);
    }
  }

  void _setBusy(bool value) {
    if (_isBusy == value) return;
    _isBusy = value;
    onBusyChanged?.call(value);
    _notify();
  }

  Future<Result<void>> _persistRemovedAttachment({
    required String? accountId,
    required String draftId,
    required String requestId,
  }) async {
    final repository = draftRepository;
    if (repository == null || accountId == null) {
      return const Success(null);
    }
    for (var attempt = 0; attempt < 3; attempt += 1) {
      try {
        final draft = await repository.load(
          accountId: accountId,
          draftId: draftId,
        );
        if (draft == null || !draft.attachmentStagingIds.contains(requestId)) {
          return const Success(null);
        }
        final result = await repository.save(
          draft.copyWith(
            attachmentStagingIds: draft.attachmentStagingIds
                .where((id) => id != requestId)
                .toList(growable: false),
          ),
          expectedVersion: draft.version,
        );
        switch (result) {
          case Success():
            return const Success(null);
          case FailureResult(:final failure):
            if (failure is ConflictFailure && attempt < 2) continue;
            return FailureResult(failure);
        }
      } on Object catch (error) {
        return FailureResult(
          LocalStorageFailure(
            message: 'Unable to reconcile document draft attachments.',
            cause: error,
          ),
        );
      }
    }
    return const FailureResult(
      ConflictFailure(message: 'Document draft attachment conflict.'),
    );
  }

  void _notify() {
    if (!_isDisposed) notifyListeners();
  }

  @override
  void dispose() {
    _isDisposed = true;
    _generation += 1;
    if (_isBusy) {
      _isBusy = false;
      onBusyChanged?.call(false);
    }
    super.dispose();
  }

  bool _matchesOperation(int generation, String draftId, int mutationEpoch) =>
      !_isDisposed &&
      generation == _generation &&
      canMutate() &&
      mutationEpochProvider() == mutationEpoch &&
      draftIdProvider() == draftId;
}

bool _alwaysCanMutate() => true;

int _zeroEpoch() => 0;
