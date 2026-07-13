final class DocumentDraft {
  DocumentDraft({
    required this.id,
    required this.accountId,
    required this.warehouseId,
    required Map<String, Object?> payload,
    required this.createdAt,
    required this.updatedAt,
    this.docType = 0,
    this.observedRoleCode = '',
    List<String> attachmentStagingIds = const [],
    this.schemaVersion = 1,
    this.version = 1,
  }) : payload = _immutableMap(payload),
       attachmentStagingIds = List.unmodifiable(attachmentStagingIds);

  final String id;
  final String accountId;
  final int warehouseId;
  final Map<String, Object?> payload;
  final DateTime createdAt;
  final DateTime updatedAt;
  final int docType;
  final String observedRoleCode;
  final List<String> attachmentStagingIds;
  final int schemaVersion;
  final int version;

  DraftReview reviewAgainst({
    required String roleCode,
    required int warehouseId,
  }) {
    return DraftReview({
      if (observedRoleCode != roleCode) DraftReviewReason.roleChanged,
      if (this.warehouseId != warehouseId) DraftReviewReason.warehouseChanged,
    });
  }

  DocumentDraft copyWith({
    Map<String, Object?>? payload,
    List<String>? attachmentStagingIds,
    DateTime? updatedAt,
    int? schemaVersion,
    int? version,
  }) {
    return DocumentDraft(
      id: id,
      accountId: accountId,
      warehouseId: warehouseId,
      docType: docType,
      observedRoleCode: observedRoleCode,
      payload: payload ?? this.payload,
      attachmentStagingIds: attachmentStagingIds ?? this.attachmentStagingIds,
      schemaVersion: schemaVersion ?? this.schemaVersion,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      version: version ?? this.version,
    );
  }
}

enum DraftReviewReason { roleChanged, warehouseChanged }

final class DraftReview {
  DraftReview(Set<DraftReviewReason> reasons)
    : reasons = Set.unmodifiable(reasons);

  final Set<DraftReviewReason> reasons;
  bool get requiresReview => reasons.isNotEmpty;
}

Map<String, Object?> _immutableMap(Map<String, Object?> source) {
  return Map.unmodifiable(
    source.map((key, value) => MapEntry(key, _immutableValue(value))),
  );
}

Object? _immutableValue(Object? value) {
  if (value is Map) {
    return Map.unmodifiable(
      value.map(
        (key, nestedValue) =>
            MapEntry(key.toString(), _immutableValue(nestedValue)),
      ),
    );
  }
  if (value is List) {
    return List.unmodifiable(value.map(_immutableValue));
  }
  return value;
}
