import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../../../../core/result/result.dart';
import '../../../attachments/domain/services/attachment_staging_store.dart';
import '../../domain/entities/document_draft.dart';
import '../../domain/repositories/document_draft_repository.dart';

final class DraftListItem {
  const DraftListItem({required this.draft, required this.review});

  final DocumentDraft draft;
  final DraftReview review;

  bool get requiresReview => review.requiresReview;
  int get lineCount => (draft.payload['lines'] as List?)?.length ?? 0;
  String get remark => draft.payload['remark']?.toString() ?? '';
}

final class DraftsViewModel extends ChangeNotifier {
  DraftsViewModel({
    required this.repository,
    required this.accountId,
    required this.roleCode,
    required this.warehouseId,
    this.attachmentStagingStore,
    this.attachmentUserId,
    String Function()? draftIdFactory,
    DateTime Function()? now,
  }) : draftIdFactory = draftIdFactory ?? const Uuid().v4,
       now = now ?? DateTime.now;

  final DocumentDraftRepository repository;
  final String Function() draftIdFactory;
  final DateTime Function() now;
  final DraftAttachmentStagingStore? attachmentStagingStore;
  String? attachmentUserId;
  String accountId;
  String roleCode;
  int warehouseId;
  List<DraftListItem> _drafts = const [];
  bool _isLoading = false;
  String? _errorMessage;
  bool _isDisposed = false;
  int _loadGeneration = 0;
  int _contextGeneration = 0;

  List<DraftListItem> get drafts => List.unmodifiable(_drafts);
  bool get isLoading => _isLoading;
  String? get errorMessage => _errorMessage;

  @override
  void dispose() {
    _isDisposed = true;
    super.dispose();
  }

  Future<void> load() async {
    final generation = ++_loadGeneration;
    final requestedAccountId = accountId;
    _isLoading = true;
    _errorMessage = null;
    _notify();
    try {
      final drafts = await repository.list(requestedAccountId);
      if (_isDisposed || generation != _loadGeneration) return;
      drafts.sort((left, right) => right.updatedAt.compareTo(left.updatedAt));
      _drafts = drafts
          .map(
            (draft) => DraftListItem(
              draft: draft,
              review: draft.reviewAgainst(
                roleCode: roleCode,
                warehouseId: warehouseId,
              ),
            ),
          )
          .toList(growable: false);
    } on Object catch (error) {
      if (_isDisposed || generation != _loadGeneration) return;
      _errorMessage = error.toString();
    } finally {
      if (!_isDisposed && generation == _loadGeneration) {
        _isLoading = false;
        notifyListeners();
      }
    }
  }

  Future<void> updateContext({
    required String accountId,
    required String roleCode,
    required int warehouseId,
    String? attachmentUserId,
  }) async {
    _contextGeneration += 1;
    this.accountId = accountId;
    this.roleCode = roleCode;
    this.warehouseId = warehouseId;
    this.attachmentUserId =
        attachmentUserId ?? (attachmentStagingStore == null ? null : accountId);
    _drafts = const [];
    await load();
  }

  Future<DocumentDraft?> open(String draftId) async {
    final operationGeneration = _contextGeneration;
    final operationAccountId = accountId;
    final draft = await repository.load(
      accountId: operationAccountId,
      draftId: draftId,
    );
    if (!_isCurrentContext(operationGeneration, operationAccountId)) {
      return null;
    }
    return draft;
  }

  Future<DocumentDraft?> duplicate(String draftId) async {
    final operationGeneration = _contextGeneration;
    final operationAccountId = accountId;
    final operationRoleCode = roleCode;
    final operationAttachmentUserId = attachmentUserId;
    final source = await repository.load(
      accountId: operationAccountId,
      draftId: draftId,
    );
    if (source == null) return null;
    if (!_isCurrentContext(operationGeneration, operationAccountId)) {
      return null;
    }
    final timestamp = now().toUtc();
    final targetDraftId = draftIdFactory();
    var duplicatedAttachmentIds = const <String>[];
    if (source.attachmentStagingIds.isNotEmpty) {
      final stagingStore = attachmentStagingStore;
      final userId = operationAttachmentUserId;
      if (stagingStore == null || userId == null) {
        _errorMessage = 'Draft attachment copy is unavailable.';
        _notify();
        return null;
      }
      final duplicated = await stagingStore.duplicateDraftAttachments(
        userId: userId,
        sourceDraftId: source.id,
        targetDraftId: targetDraftId,
        requestIds: source.attachmentStagingIds,
      );
      switch (duplicated) {
        case Success(:final data):
          duplicatedAttachmentIds = data
              .map((item) => item.pending.requestId)
              .toList(growable: false);
        case FailureResult(:final failure):
          if (_isCurrentContext(operationGeneration, operationAccountId)) {
            _errorMessage = failure.message;
            _notify();
          }
          return null;
      }
    }
    if (!_isCurrentContext(operationGeneration, operationAccountId)) {
      await _cleanupDuplicatedAttachments(
        userId: operationAttachmentUserId,
        requestIds: duplicatedAttachmentIds,
      );
      return null;
    }
    final duplicate = DocumentDraft(
      id: targetDraftId,
      accountId: operationAccountId,
      warehouseId: source.warehouseId,
      docType: source.docType,
      observedRoleCode: operationRoleCode,
      payload: source.payload,
      attachmentStagingIds: duplicatedAttachmentIds,
      createdAt: timestamp,
      updatedAt: timestamp,
    );
    final result = await repository.save(duplicate, expectedVersion: 0);
    switch (result) {
      case Success(:final data):
        if (!_isCurrentContext(operationGeneration, operationAccountId)) {
          await repository.delete(
            accountId: operationAccountId,
            draftId: data.id,
          );
          await _cleanupDuplicatedAttachments(
            userId: operationAttachmentUserId,
            requestIds: duplicatedAttachmentIds,
          );
          return null;
        }
        _replaceOrAdd(data);
        return data;
      case FailureResult(:final failure):
        var errorMessage = failure.message;
        final stagingStore = attachmentStagingStore;
        final userId = operationAttachmentUserId;
        if (stagingStore != null &&
            userId != null &&
            duplicatedAttachmentIds.isNotEmpty) {
          final cleanup = await stagingStore.removeStagedAttachments(
            userId: userId,
            requestIds: duplicatedAttachmentIds,
          );
          if (cleanup case FailureResult(:final failure)) {
            errorMessage =
                '$errorMessage; attachment cleanup failed: ${failure.message}';
          }
        }
        if (_isCurrentContext(operationGeneration, operationAccountId)) {
          _errorMessage = errorMessage;
          _notify();
        }
        return null;
    }
  }

  Future<bool> renameRemark(String draftId, String remark) async {
    final operationGeneration = _contextGeneration;
    final operationAccountId = accountId;
    final source = await repository.load(
      accountId: operationAccountId,
      draftId: draftId,
    );
    if (source == null) return false;
    if (!_isCurrentContext(operationGeneration, operationAccountId)) {
      return false;
    }
    final payload = Map<String, Object?>.from(source.payload)
      ..['remark'] = remark;
    final result = await repository.save(
      source.copyWith(payload: payload, updatedAt: now().toUtc()),
      expectedVersion: source.version,
    );
    if (!_isCurrentContext(operationGeneration, operationAccountId)) {
      return false;
    }
    return result.when(
      success: (saved) {
        _replaceOrAdd(saved);
        return true;
      },
      failure: (failure) {
        _errorMessage = failure.message;
        _notify();
        return false;
      },
    );
  }

  Future<bool> discard(String draftId, {required bool confirmed}) async {
    if (!confirmed) return false;
    final operationGeneration = _contextGeneration;
    final operationAccountId = accountId;
    final operationAttachmentUserId = attachmentUserId;
    final source = await repository.load(
      accountId: operationAccountId,
      draftId: draftId,
    );
    if (source == null ||
        !_isCurrentContext(operationGeneration, operationAccountId)) {
      return false;
    }
    if (source.attachmentStagingIds.isNotEmpty &&
        (attachmentStagingStore == null || operationAttachmentUserId == null)) {
      _errorMessage = '草稿附件清理服务不可用，未丢弃草稿';
      _notify();
      return false;
    }
    try {
      await repository.delete(accountId: operationAccountId, draftId: draftId);
    } on Object catch (error) {
      if (_isCurrentContext(operationGeneration, operationAccountId)) {
        _errorMessage = error.toString();
        _notify();
      }
      return false;
    }
    Result<void>? cleanup;
    if (source.attachmentStagingIds.isNotEmpty) {
      cleanup = await attachmentStagingStore!.removeStagedAttachments(
        userId: operationAttachmentUserId!,
        requestIds: source.attachmentStagingIds,
      );
    }
    if (!_isCurrentContext(operationGeneration, operationAccountId)) {
      return false;
    }
    _drafts = _drafts
        .where((item) => item.draft.id != draftId)
        .toList(growable: false);
    if (cleanup case FailureResult(:final failure)) {
      _errorMessage = '草稿已删除；附件清理待重试: ${failure.message}';
    } else {
      _errorMessage = null;
    }
    _notify();
    return true;
  }

  Future<void> _cleanupDuplicatedAttachments({
    required String? userId,
    required List<String> requestIds,
  }) async {
    final stagingStore = attachmentStagingStore;
    if (stagingStore == null || userId == null || requestIds.isEmpty) return;
    await stagingStore.removeStagedAttachments(
      userId: userId,
      requestIds: requestIds,
    );
  }

  bool _isCurrentContext(int generation, String requestedAccountId) =>
      !_isDisposed &&
      generation == _contextGeneration &&
      accountId == requestedAccountId;

  void _replaceOrAdd(DocumentDraft draft) {
    final next =
        _drafts
            .where((item) => item.draft.id != draft.id)
            .toList(growable: true)
          ..add(
            DraftListItem(
              draft: draft,
              review: draft.reviewAgainst(
                roleCode: roleCode,
                warehouseId: warehouseId,
              ),
            ),
          );
    next.sort(
      (left, right) => right.draft.updatedAt.compareTo(left.draft.updatedAt),
    );
    _drafts = List.unmodifiable(next);
    _errorMessage = null;
    _notify();
  }

  void _notify() {
    if (!_isDisposed) notifyListeners();
  }
}
