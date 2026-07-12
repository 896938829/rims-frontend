import 'package:flutter/foundation.dart';

import '../../../../core/result/result.dart';
import '../../../attachments/domain/entities/attachment.dart';
import '../../../attachments/domain/services/attachment_picker.dart';
import '../../../attachments/domain/services/attachment_staging_store.dart';

final class DraftAttachmentsViewModel extends ChangeNotifier {
  DraftAttachmentsViewModel({
    required this.picker,
    required this.stagingStore,
    required this.userId,
    required this.draftIdProvider,
    required this.onChanged,
    bool Function()? canMutate,
    int Function()? mutationEpochProvider,
  }) : canMutate = canMutate ?? _alwaysCanMutate,
       mutationEpochProvider = mutationEpochProvider ?? _zeroEpoch;

  final AttachmentPicker picker;
  final AttachmentStagingStore stagingStore;
  final String userId;
  final String Function() draftIdProvider;
  final ValueChanged<List<String>> onChanged;
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
    _isBusy = true;
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
            _publish();
          }
        case FailureResult(:final failure):
          if (_matchesOperation(generation, draftId, mutationEpoch)) {
            _errorMessage = failure.message;
          }
      }
    } finally {
      _isBusy = false;
      _notify();
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
    if (!isMutationAllowed) return;
    final result = await stagingStore.remove(userId, requestId);
    if (_isDisposed) return;
    result.when(
      success: (_) {
        _staged = _staged
            .where((item) => item.pending.requestId != requestId)
            .toList(growable: false);
        _publish();
      },
      failure: (failure) => _errorMessage = failure.message,
    );
    _notify();
  }

  void _publish() {
    onChanged(
      _staged.map((item) => item.pending.requestId).toList(growable: false),
    );
  }

  void _notify() {
    if (!_isDisposed) notifyListeners();
  }

  @override
  void dispose() {
    _isDisposed = true;
    _generation += 1;
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
