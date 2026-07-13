import 'package:drift/drift.dart';

class OfflineCacheEntries extends Table {
  @override
  String get tableName => 'cache_records';

  TextColumn get cacheId => text()();
  TextColumn get accountId => text()();
  IntColumn get warehouseId => integer().nullable()();
  TextColumn get namespace => text()();
  TextColumn get entityKey => text()();
  TextColumn get payload => text()();
  IntColumn get recordSchemaVersion => integer()();
  DateTimeColumn get fetchedAt => dateTime()();
  DateTimeColumn get expiresAt => dateTime()();

  @override
  Set<Column<Object>> get primaryKey => {cacheId};
}

class OfflineDocumentDrafts extends Table {
  @override
  String get tableName => 'document_drafts';

  TextColumn get draftId => text()();
  TextColumn get accountId => text()();
  IntColumn get warehouseId => integer()();
  TextColumn get payload => text()();
  IntColumn get draftVersion => integer()();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column<Object>> get primaryKey => {draftId};
}

class OfflineOutboxOperations extends Table {
  @override
  String get tableName => 'outbox_operations';

  TextColumn get operationId => text()();
  TextColumn get idempotencyKey => text()();
  TextColumn get accountId => text()();
  IntColumn get warehouseId => integer()();
  TextColumn get operationKind => text()();
  TextColumn get payload => text()();
  TextColumn get operationState => text()();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime().nullable()();
  DateTimeColumn get confirmedAt => dateTime().nullable()();
  DateTimeColumn get nextAttemptAt => dateTime().nullable()();
  IntColumn get attemptCount => integer().withDefault(const Constant(0))();
  TextColumn get lastFailureCode => text().nullable()();
  TextColumn get replacementOf => text().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {operationId};

  @override
  List<Set<Column<Object>>> get uniqueKeys => [
    {accountId, idempotencyKey},
    {operationId, accountId},
  ];
}

class OfflineOutboxDependencies extends Table {
  @override
  String get tableName => 'outbox_dependencies';

  @ReferenceName('dependentOperation')
  TextColumn get operationId => text().references(
    OfflineOutboxOperations,
    #operationId,
    onDelete: KeyAction.cascade,
  )();
  @ReferenceName('requiredOperation')
  TextColumn get dependencyId => text().references(
    OfflineOutboxOperations,
    #operationId,
    onDelete: KeyAction.cascade,
  )();

  @override
  Set<Column<Object>> get primaryKey => {operationId, dependencyId};
}

class OfflineOutboxResolutions extends Table {
  @override
  String get tableName => 'outbox_resolutions';

  TextColumn get originalOperationId => text()();
  TextColumn get replacementOperationId => text()();
  TextColumn get accountId => text()();
  TextColumn get dependencyFingerprint => text()();

  @override
  Set<Column<Object>> get primaryKey => {originalOperationId};

  @override
  List<Set<Column<Object>>> get uniqueKeys => [
    {replacementOperationId},
  ];

  @override
  List<String> get customConstraints => [
    'FOREIGN KEY (original_operation_id, account_id) '
        'REFERENCES outbox_operations (operation_id, account_id)',
    'FOREIGN KEY (replacement_operation_id, account_id) '
        'REFERENCES outbox_operations (operation_id, account_id)',
  ];
}
