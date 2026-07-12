// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'offline_database.dart';

// ignore_for_file: type=lint
class $OfflineCacheEntriesTable extends OfflineCacheEntries
    with TableInfo<$OfflineCacheEntriesTable, OfflineCacheEntry> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $OfflineCacheEntriesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _cacheIdMeta = const VerificationMeta(
    'cacheId',
  );
  @override
  late final GeneratedColumn<String> cacheId = GeneratedColumn<String>(
    'cache_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _accountIdMeta = const VerificationMeta(
    'accountId',
  );
  @override
  late final GeneratedColumn<String> accountId = GeneratedColumn<String>(
    'account_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _warehouseIdMeta = const VerificationMeta(
    'warehouseId',
  );
  @override
  late final GeneratedColumn<int> warehouseId = GeneratedColumn<int>(
    'warehouse_id',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _namespaceMeta = const VerificationMeta(
    'namespace',
  );
  @override
  late final GeneratedColumn<String> namespace = GeneratedColumn<String>(
    'namespace',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _entityKeyMeta = const VerificationMeta(
    'entityKey',
  );
  @override
  late final GeneratedColumn<String> entityKey = GeneratedColumn<String>(
    'entity_key',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _payloadMeta = const VerificationMeta(
    'payload',
  );
  @override
  late final GeneratedColumn<String> payload = GeneratedColumn<String>(
    'payload',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _recordSchemaVersionMeta =
      const VerificationMeta('recordSchemaVersion');
  @override
  late final GeneratedColumn<int> recordSchemaVersion = GeneratedColumn<int>(
    'record_schema_version',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _fetchedAtMeta = const VerificationMeta(
    'fetchedAt',
  );
  @override
  late final GeneratedColumn<DateTime> fetchedAt = GeneratedColumn<DateTime>(
    'fetched_at',
    aliasedName,
    false,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _expiresAtMeta = const VerificationMeta(
    'expiresAt',
  );
  @override
  late final GeneratedColumn<DateTime> expiresAt = GeneratedColumn<DateTime>(
    'expires_at',
    aliasedName,
    false,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [
    cacheId,
    accountId,
    warehouseId,
    namespace,
    entityKey,
    payload,
    recordSchemaVersion,
    fetchedAt,
    expiresAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'cache_records';
  @override
  VerificationContext validateIntegrity(
    Insertable<OfflineCacheEntry> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('cache_id')) {
      context.handle(
        _cacheIdMeta,
        cacheId.isAcceptableOrUnknown(data['cache_id']!, _cacheIdMeta),
      );
    } else if (isInserting) {
      context.missing(_cacheIdMeta);
    }
    if (data.containsKey('account_id')) {
      context.handle(
        _accountIdMeta,
        accountId.isAcceptableOrUnknown(data['account_id']!, _accountIdMeta),
      );
    } else if (isInserting) {
      context.missing(_accountIdMeta);
    }
    if (data.containsKey('warehouse_id')) {
      context.handle(
        _warehouseIdMeta,
        warehouseId.isAcceptableOrUnknown(
          data['warehouse_id']!,
          _warehouseIdMeta,
        ),
      );
    }
    if (data.containsKey('namespace')) {
      context.handle(
        _namespaceMeta,
        namespace.isAcceptableOrUnknown(data['namespace']!, _namespaceMeta),
      );
    } else if (isInserting) {
      context.missing(_namespaceMeta);
    }
    if (data.containsKey('entity_key')) {
      context.handle(
        _entityKeyMeta,
        entityKey.isAcceptableOrUnknown(data['entity_key']!, _entityKeyMeta),
      );
    } else if (isInserting) {
      context.missing(_entityKeyMeta);
    }
    if (data.containsKey('payload')) {
      context.handle(
        _payloadMeta,
        payload.isAcceptableOrUnknown(data['payload']!, _payloadMeta),
      );
    } else if (isInserting) {
      context.missing(_payloadMeta);
    }
    if (data.containsKey('record_schema_version')) {
      context.handle(
        _recordSchemaVersionMeta,
        recordSchemaVersion.isAcceptableOrUnknown(
          data['record_schema_version']!,
          _recordSchemaVersionMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_recordSchemaVersionMeta);
    }
    if (data.containsKey('fetched_at')) {
      context.handle(
        _fetchedAtMeta,
        fetchedAt.isAcceptableOrUnknown(data['fetched_at']!, _fetchedAtMeta),
      );
    } else if (isInserting) {
      context.missing(_fetchedAtMeta);
    }
    if (data.containsKey('expires_at')) {
      context.handle(
        _expiresAtMeta,
        expiresAt.isAcceptableOrUnknown(data['expires_at']!, _expiresAtMeta),
      );
    } else if (isInserting) {
      context.missing(_expiresAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {cacheId};
  @override
  OfflineCacheEntry map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return OfflineCacheEntry(
      cacheId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}cache_id'],
      )!,
      accountId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}account_id'],
      )!,
      warehouseId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}warehouse_id'],
      ),
      namespace: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}namespace'],
      )!,
      entityKey: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}entity_key'],
      )!,
      payload: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}payload'],
      )!,
      recordSchemaVersion: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}record_schema_version'],
      )!,
      fetchedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}fetched_at'],
      )!,
      expiresAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}expires_at'],
      )!,
    );
  }

  @override
  $OfflineCacheEntriesTable createAlias(String alias) {
    return $OfflineCacheEntriesTable(attachedDatabase, alias);
  }
}

class OfflineCacheEntry extends DataClass
    implements Insertable<OfflineCacheEntry> {
  final String cacheId;
  final String accountId;
  final int? warehouseId;
  final String namespace;
  final String entityKey;
  final String payload;
  final int recordSchemaVersion;
  final DateTime fetchedAt;
  final DateTime expiresAt;
  const OfflineCacheEntry({
    required this.cacheId,
    required this.accountId,
    this.warehouseId,
    required this.namespace,
    required this.entityKey,
    required this.payload,
    required this.recordSchemaVersion,
    required this.fetchedAt,
    required this.expiresAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['cache_id'] = Variable<String>(cacheId);
    map['account_id'] = Variable<String>(accountId);
    if (!nullToAbsent || warehouseId != null) {
      map['warehouse_id'] = Variable<int>(warehouseId);
    }
    map['namespace'] = Variable<String>(namespace);
    map['entity_key'] = Variable<String>(entityKey);
    map['payload'] = Variable<String>(payload);
    map['record_schema_version'] = Variable<int>(recordSchemaVersion);
    map['fetched_at'] = Variable<DateTime>(fetchedAt);
    map['expires_at'] = Variable<DateTime>(expiresAt);
    return map;
  }

  OfflineCacheEntriesCompanion toCompanion(bool nullToAbsent) {
    return OfflineCacheEntriesCompanion(
      cacheId: Value(cacheId),
      accountId: Value(accountId),
      warehouseId: warehouseId == null && nullToAbsent
          ? const Value.absent()
          : Value(warehouseId),
      namespace: Value(namespace),
      entityKey: Value(entityKey),
      payload: Value(payload),
      recordSchemaVersion: Value(recordSchemaVersion),
      fetchedAt: Value(fetchedAt),
      expiresAt: Value(expiresAt),
    );
  }

  factory OfflineCacheEntry.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return OfflineCacheEntry(
      cacheId: serializer.fromJson<String>(json['cacheId']),
      accountId: serializer.fromJson<String>(json['accountId']),
      warehouseId: serializer.fromJson<int?>(json['warehouseId']),
      namespace: serializer.fromJson<String>(json['namespace']),
      entityKey: serializer.fromJson<String>(json['entityKey']),
      payload: serializer.fromJson<String>(json['payload']),
      recordSchemaVersion: serializer.fromJson<int>(
        json['recordSchemaVersion'],
      ),
      fetchedAt: serializer.fromJson<DateTime>(json['fetchedAt']),
      expiresAt: serializer.fromJson<DateTime>(json['expiresAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'cacheId': serializer.toJson<String>(cacheId),
      'accountId': serializer.toJson<String>(accountId),
      'warehouseId': serializer.toJson<int?>(warehouseId),
      'namespace': serializer.toJson<String>(namespace),
      'entityKey': serializer.toJson<String>(entityKey),
      'payload': serializer.toJson<String>(payload),
      'recordSchemaVersion': serializer.toJson<int>(recordSchemaVersion),
      'fetchedAt': serializer.toJson<DateTime>(fetchedAt),
      'expiresAt': serializer.toJson<DateTime>(expiresAt),
    };
  }

  OfflineCacheEntry copyWith({
    String? cacheId,
    String? accountId,
    Value<int?> warehouseId = const Value.absent(),
    String? namespace,
    String? entityKey,
    String? payload,
    int? recordSchemaVersion,
    DateTime? fetchedAt,
    DateTime? expiresAt,
  }) => OfflineCacheEntry(
    cacheId: cacheId ?? this.cacheId,
    accountId: accountId ?? this.accountId,
    warehouseId: warehouseId.present ? warehouseId.value : this.warehouseId,
    namespace: namespace ?? this.namespace,
    entityKey: entityKey ?? this.entityKey,
    payload: payload ?? this.payload,
    recordSchemaVersion: recordSchemaVersion ?? this.recordSchemaVersion,
    fetchedAt: fetchedAt ?? this.fetchedAt,
    expiresAt: expiresAt ?? this.expiresAt,
  );
  OfflineCacheEntry copyWithCompanion(OfflineCacheEntriesCompanion data) {
    return OfflineCacheEntry(
      cacheId: data.cacheId.present ? data.cacheId.value : this.cacheId,
      accountId: data.accountId.present ? data.accountId.value : this.accountId,
      warehouseId: data.warehouseId.present
          ? data.warehouseId.value
          : this.warehouseId,
      namespace: data.namespace.present ? data.namespace.value : this.namespace,
      entityKey: data.entityKey.present ? data.entityKey.value : this.entityKey,
      payload: data.payload.present ? data.payload.value : this.payload,
      recordSchemaVersion: data.recordSchemaVersion.present
          ? data.recordSchemaVersion.value
          : this.recordSchemaVersion,
      fetchedAt: data.fetchedAt.present ? data.fetchedAt.value : this.fetchedAt,
      expiresAt: data.expiresAt.present ? data.expiresAt.value : this.expiresAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('OfflineCacheEntry(')
          ..write('cacheId: $cacheId, ')
          ..write('accountId: $accountId, ')
          ..write('warehouseId: $warehouseId, ')
          ..write('namespace: $namespace, ')
          ..write('entityKey: $entityKey, ')
          ..write('payload: $payload, ')
          ..write('recordSchemaVersion: $recordSchemaVersion, ')
          ..write('fetchedAt: $fetchedAt, ')
          ..write('expiresAt: $expiresAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    cacheId,
    accountId,
    warehouseId,
    namespace,
    entityKey,
    payload,
    recordSchemaVersion,
    fetchedAt,
    expiresAt,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is OfflineCacheEntry &&
          other.cacheId == this.cacheId &&
          other.accountId == this.accountId &&
          other.warehouseId == this.warehouseId &&
          other.namespace == this.namespace &&
          other.entityKey == this.entityKey &&
          other.payload == this.payload &&
          other.recordSchemaVersion == this.recordSchemaVersion &&
          other.fetchedAt == this.fetchedAt &&
          other.expiresAt == this.expiresAt);
}

class OfflineCacheEntriesCompanion extends UpdateCompanion<OfflineCacheEntry> {
  final Value<String> cacheId;
  final Value<String> accountId;
  final Value<int?> warehouseId;
  final Value<String> namespace;
  final Value<String> entityKey;
  final Value<String> payload;
  final Value<int> recordSchemaVersion;
  final Value<DateTime> fetchedAt;
  final Value<DateTime> expiresAt;
  final Value<int> rowid;
  const OfflineCacheEntriesCompanion({
    this.cacheId = const Value.absent(),
    this.accountId = const Value.absent(),
    this.warehouseId = const Value.absent(),
    this.namespace = const Value.absent(),
    this.entityKey = const Value.absent(),
    this.payload = const Value.absent(),
    this.recordSchemaVersion = const Value.absent(),
    this.fetchedAt = const Value.absent(),
    this.expiresAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  OfflineCacheEntriesCompanion.insert({
    required String cacheId,
    required String accountId,
    this.warehouseId = const Value.absent(),
    required String namespace,
    required String entityKey,
    required String payload,
    required int recordSchemaVersion,
    required DateTime fetchedAt,
    required DateTime expiresAt,
    this.rowid = const Value.absent(),
  }) : cacheId = Value(cacheId),
       accountId = Value(accountId),
       namespace = Value(namespace),
       entityKey = Value(entityKey),
       payload = Value(payload),
       recordSchemaVersion = Value(recordSchemaVersion),
       fetchedAt = Value(fetchedAt),
       expiresAt = Value(expiresAt);
  static Insertable<OfflineCacheEntry> custom({
    Expression<String>? cacheId,
    Expression<String>? accountId,
    Expression<int>? warehouseId,
    Expression<String>? namespace,
    Expression<String>? entityKey,
    Expression<String>? payload,
    Expression<int>? recordSchemaVersion,
    Expression<DateTime>? fetchedAt,
    Expression<DateTime>? expiresAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (cacheId != null) 'cache_id': cacheId,
      if (accountId != null) 'account_id': accountId,
      if (warehouseId != null) 'warehouse_id': warehouseId,
      if (namespace != null) 'namespace': namespace,
      if (entityKey != null) 'entity_key': entityKey,
      if (payload != null) 'payload': payload,
      if (recordSchemaVersion != null)
        'record_schema_version': recordSchemaVersion,
      if (fetchedAt != null) 'fetched_at': fetchedAt,
      if (expiresAt != null) 'expires_at': expiresAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  OfflineCacheEntriesCompanion copyWith({
    Value<String>? cacheId,
    Value<String>? accountId,
    Value<int?>? warehouseId,
    Value<String>? namespace,
    Value<String>? entityKey,
    Value<String>? payload,
    Value<int>? recordSchemaVersion,
    Value<DateTime>? fetchedAt,
    Value<DateTime>? expiresAt,
    Value<int>? rowid,
  }) {
    return OfflineCacheEntriesCompanion(
      cacheId: cacheId ?? this.cacheId,
      accountId: accountId ?? this.accountId,
      warehouseId: warehouseId ?? this.warehouseId,
      namespace: namespace ?? this.namespace,
      entityKey: entityKey ?? this.entityKey,
      payload: payload ?? this.payload,
      recordSchemaVersion: recordSchemaVersion ?? this.recordSchemaVersion,
      fetchedAt: fetchedAt ?? this.fetchedAt,
      expiresAt: expiresAt ?? this.expiresAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (cacheId.present) {
      map['cache_id'] = Variable<String>(cacheId.value);
    }
    if (accountId.present) {
      map['account_id'] = Variable<String>(accountId.value);
    }
    if (warehouseId.present) {
      map['warehouse_id'] = Variable<int>(warehouseId.value);
    }
    if (namespace.present) {
      map['namespace'] = Variable<String>(namespace.value);
    }
    if (entityKey.present) {
      map['entity_key'] = Variable<String>(entityKey.value);
    }
    if (payload.present) {
      map['payload'] = Variable<String>(payload.value);
    }
    if (recordSchemaVersion.present) {
      map['record_schema_version'] = Variable<int>(recordSchemaVersion.value);
    }
    if (fetchedAt.present) {
      map['fetched_at'] = Variable<DateTime>(fetchedAt.value);
    }
    if (expiresAt.present) {
      map['expires_at'] = Variable<DateTime>(expiresAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('OfflineCacheEntriesCompanion(')
          ..write('cacheId: $cacheId, ')
          ..write('accountId: $accountId, ')
          ..write('warehouseId: $warehouseId, ')
          ..write('namespace: $namespace, ')
          ..write('entityKey: $entityKey, ')
          ..write('payload: $payload, ')
          ..write('recordSchemaVersion: $recordSchemaVersion, ')
          ..write('fetchedAt: $fetchedAt, ')
          ..write('expiresAt: $expiresAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $OfflineDocumentDraftsTable extends OfflineDocumentDrafts
    with TableInfo<$OfflineDocumentDraftsTable, OfflineDocumentDraft> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $OfflineDocumentDraftsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _draftIdMeta = const VerificationMeta(
    'draftId',
  );
  @override
  late final GeneratedColumn<String> draftId = GeneratedColumn<String>(
    'draft_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _accountIdMeta = const VerificationMeta(
    'accountId',
  );
  @override
  late final GeneratedColumn<String> accountId = GeneratedColumn<String>(
    'account_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _warehouseIdMeta = const VerificationMeta(
    'warehouseId',
  );
  @override
  late final GeneratedColumn<int> warehouseId = GeneratedColumn<int>(
    'warehouse_id',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _payloadMeta = const VerificationMeta(
    'payload',
  );
  @override
  late final GeneratedColumn<String> payload = GeneratedColumn<String>(
    'payload',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _draftVersionMeta = const VerificationMeta(
    'draftVersion',
  );
  @override
  late final GeneratedColumn<int> draftVersion = GeneratedColumn<int>(
    'draft_version',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _createdAtMeta = const VerificationMeta(
    'createdAt',
  );
  @override
  late final GeneratedColumn<DateTime> createdAt = GeneratedColumn<DateTime>(
    'created_at',
    aliasedName,
    false,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _updatedAtMeta = const VerificationMeta(
    'updatedAt',
  );
  @override
  late final GeneratedColumn<DateTime> updatedAt = GeneratedColumn<DateTime>(
    'updated_at',
    aliasedName,
    false,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [
    draftId,
    accountId,
    warehouseId,
    payload,
    draftVersion,
    createdAt,
    updatedAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'document_drafts';
  @override
  VerificationContext validateIntegrity(
    Insertable<OfflineDocumentDraft> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('draft_id')) {
      context.handle(
        _draftIdMeta,
        draftId.isAcceptableOrUnknown(data['draft_id']!, _draftIdMeta),
      );
    } else if (isInserting) {
      context.missing(_draftIdMeta);
    }
    if (data.containsKey('account_id')) {
      context.handle(
        _accountIdMeta,
        accountId.isAcceptableOrUnknown(data['account_id']!, _accountIdMeta),
      );
    } else if (isInserting) {
      context.missing(_accountIdMeta);
    }
    if (data.containsKey('warehouse_id')) {
      context.handle(
        _warehouseIdMeta,
        warehouseId.isAcceptableOrUnknown(
          data['warehouse_id']!,
          _warehouseIdMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_warehouseIdMeta);
    }
    if (data.containsKey('payload')) {
      context.handle(
        _payloadMeta,
        payload.isAcceptableOrUnknown(data['payload']!, _payloadMeta),
      );
    } else if (isInserting) {
      context.missing(_payloadMeta);
    }
    if (data.containsKey('draft_version')) {
      context.handle(
        _draftVersionMeta,
        draftVersion.isAcceptableOrUnknown(
          data['draft_version']!,
          _draftVersionMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_draftVersionMeta);
    }
    if (data.containsKey('created_at')) {
      context.handle(
        _createdAtMeta,
        createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta),
      );
    } else if (isInserting) {
      context.missing(_createdAtMeta);
    }
    if (data.containsKey('updated_at')) {
      context.handle(
        _updatedAtMeta,
        updatedAt.isAcceptableOrUnknown(data['updated_at']!, _updatedAtMeta),
      );
    } else if (isInserting) {
      context.missing(_updatedAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {draftId};
  @override
  OfflineDocumentDraft map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return OfflineDocumentDraft(
      draftId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}draft_id'],
      )!,
      accountId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}account_id'],
      )!,
      warehouseId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}warehouse_id'],
      )!,
      payload: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}payload'],
      )!,
      draftVersion: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}draft_version'],
      )!,
      createdAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}created_at'],
      )!,
      updatedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}updated_at'],
      )!,
    );
  }

  @override
  $OfflineDocumentDraftsTable createAlias(String alias) {
    return $OfflineDocumentDraftsTable(attachedDatabase, alias);
  }
}

class OfflineDocumentDraft extends DataClass
    implements Insertable<OfflineDocumentDraft> {
  final String draftId;
  final String accountId;
  final int warehouseId;
  final String payload;
  final int draftVersion;
  final DateTime createdAt;
  final DateTime updatedAt;
  const OfflineDocumentDraft({
    required this.draftId,
    required this.accountId,
    required this.warehouseId,
    required this.payload,
    required this.draftVersion,
    required this.createdAt,
    required this.updatedAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['draft_id'] = Variable<String>(draftId);
    map['account_id'] = Variable<String>(accountId);
    map['warehouse_id'] = Variable<int>(warehouseId);
    map['payload'] = Variable<String>(payload);
    map['draft_version'] = Variable<int>(draftVersion);
    map['created_at'] = Variable<DateTime>(createdAt);
    map['updated_at'] = Variable<DateTime>(updatedAt);
    return map;
  }

  OfflineDocumentDraftsCompanion toCompanion(bool nullToAbsent) {
    return OfflineDocumentDraftsCompanion(
      draftId: Value(draftId),
      accountId: Value(accountId),
      warehouseId: Value(warehouseId),
      payload: Value(payload),
      draftVersion: Value(draftVersion),
      createdAt: Value(createdAt),
      updatedAt: Value(updatedAt),
    );
  }

  factory OfflineDocumentDraft.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return OfflineDocumentDraft(
      draftId: serializer.fromJson<String>(json['draftId']),
      accountId: serializer.fromJson<String>(json['accountId']),
      warehouseId: serializer.fromJson<int>(json['warehouseId']),
      payload: serializer.fromJson<String>(json['payload']),
      draftVersion: serializer.fromJson<int>(json['draftVersion']),
      createdAt: serializer.fromJson<DateTime>(json['createdAt']),
      updatedAt: serializer.fromJson<DateTime>(json['updatedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'draftId': serializer.toJson<String>(draftId),
      'accountId': serializer.toJson<String>(accountId),
      'warehouseId': serializer.toJson<int>(warehouseId),
      'payload': serializer.toJson<String>(payload),
      'draftVersion': serializer.toJson<int>(draftVersion),
      'createdAt': serializer.toJson<DateTime>(createdAt),
      'updatedAt': serializer.toJson<DateTime>(updatedAt),
    };
  }

  OfflineDocumentDraft copyWith({
    String? draftId,
    String? accountId,
    int? warehouseId,
    String? payload,
    int? draftVersion,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) => OfflineDocumentDraft(
    draftId: draftId ?? this.draftId,
    accountId: accountId ?? this.accountId,
    warehouseId: warehouseId ?? this.warehouseId,
    payload: payload ?? this.payload,
    draftVersion: draftVersion ?? this.draftVersion,
    createdAt: createdAt ?? this.createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
  );
  OfflineDocumentDraft copyWithCompanion(OfflineDocumentDraftsCompanion data) {
    return OfflineDocumentDraft(
      draftId: data.draftId.present ? data.draftId.value : this.draftId,
      accountId: data.accountId.present ? data.accountId.value : this.accountId,
      warehouseId: data.warehouseId.present
          ? data.warehouseId.value
          : this.warehouseId,
      payload: data.payload.present ? data.payload.value : this.payload,
      draftVersion: data.draftVersion.present
          ? data.draftVersion.value
          : this.draftVersion,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
      updatedAt: data.updatedAt.present ? data.updatedAt.value : this.updatedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('OfflineDocumentDraft(')
          ..write('draftId: $draftId, ')
          ..write('accountId: $accountId, ')
          ..write('warehouseId: $warehouseId, ')
          ..write('payload: $payload, ')
          ..write('draftVersion: $draftVersion, ')
          ..write('createdAt: $createdAt, ')
          ..write('updatedAt: $updatedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    draftId,
    accountId,
    warehouseId,
    payload,
    draftVersion,
    createdAt,
    updatedAt,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is OfflineDocumentDraft &&
          other.draftId == this.draftId &&
          other.accountId == this.accountId &&
          other.warehouseId == this.warehouseId &&
          other.payload == this.payload &&
          other.draftVersion == this.draftVersion &&
          other.createdAt == this.createdAt &&
          other.updatedAt == this.updatedAt);
}

class OfflineDocumentDraftsCompanion
    extends UpdateCompanion<OfflineDocumentDraft> {
  final Value<String> draftId;
  final Value<String> accountId;
  final Value<int> warehouseId;
  final Value<String> payload;
  final Value<int> draftVersion;
  final Value<DateTime> createdAt;
  final Value<DateTime> updatedAt;
  final Value<int> rowid;
  const OfflineDocumentDraftsCompanion({
    this.draftId = const Value.absent(),
    this.accountId = const Value.absent(),
    this.warehouseId = const Value.absent(),
    this.payload = const Value.absent(),
    this.draftVersion = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.updatedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  OfflineDocumentDraftsCompanion.insert({
    required String draftId,
    required String accountId,
    required int warehouseId,
    required String payload,
    required int draftVersion,
    required DateTime createdAt,
    required DateTime updatedAt,
    this.rowid = const Value.absent(),
  }) : draftId = Value(draftId),
       accountId = Value(accountId),
       warehouseId = Value(warehouseId),
       payload = Value(payload),
       draftVersion = Value(draftVersion),
       createdAt = Value(createdAt),
       updatedAt = Value(updatedAt);
  static Insertable<OfflineDocumentDraft> custom({
    Expression<String>? draftId,
    Expression<String>? accountId,
    Expression<int>? warehouseId,
    Expression<String>? payload,
    Expression<int>? draftVersion,
    Expression<DateTime>? createdAt,
    Expression<DateTime>? updatedAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (draftId != null) 'draft_id': draftId,
      if (accountId != null) 'account_id': accountId,
      if (warehouseId != null) 'warehouse_id': warehouseId,
      if (payload != null) 'payload': payload,
      if (draftVersion != null) 'draft_version': draftVersion,
      if (createdAt != null) 'created_at': createdAt,
      if (updatedAt != null) 'updated_at': updatedAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  OfflineDocumentDraftsCompanion copyWith({
    Value<String>? draftId,
    Value<String>? accountId,
    Value<int>? warehouseId,
    Value<String>? payload,
    Value<int>? draftVersion,
    Value<DateTime>? createdAt,
    Value<DateTime>? updatedAt,
    Value<int>? rowid,
  }) {
    return OfflineDocumentDraftsCompanion(
      draftId: draftId ?? this.draftId,
      accountId: accountId ?? this.accountId,
      warehouseId: warehouseId ?? this.warehouseId,
      payload: payload ?? this.payload,
      draftVersion: draftVersion ?? this.draftVersion,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (draftId.present) {
      map['draft_id'] = Variable<String>(draftId.value);
    }
    if (accountId.present) {
      map['account_id'] = Variable<String>(accountId.value);
    }
    if (warehouseId.present) {
      map['warehouse_id'] = Variable<int>(warehouseId.value);
    }
    if (payload.present) {
      map['payload'] = Variable<String>(payload.value);
    }
    if (draftVersion.present) {
      map['draft_version'] = Variable<int>(draftVersion.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<DateTime>(createdAt.value);
    }
    if (updatedAt.present) {
      map['updated_at'] = Variable<DateTime>(updatedAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('OfflineDocumentDraftsCompanion(')
          ..write('draftId: $draftId, ')
          ..write('accountId: $accountId, ')
          ..write('warehouseId: $warehouseId, ')
          ..write('payload: $payload, ')
          ..write('draftVersion: $draftVersion, ')
          ..write('createdAt: $createdAt, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $OfflineOutboxOperationsTable extends OfflineOutboxOperations
    with TableInfo<$OfflineOutboxOperationsTable, OfflineOutboxOperation> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $OfflineOutboxOperationsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _operationIdMeta = const VerificationMeta(
    'operationId',
  );
  @override
  late final GeneratedColumn<String> operationId = GeneratedColumn<String>(
    'operation_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _idempotencyKeyMeta = const VerificationMeta(
    'idempotencyKey',
  );
  @override
  late final GeneratedColumn<String> idempotencyKey = GeneratedColumn<String>(
    'idempotency_key',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _accountIdMeta = const VerificationMeta(
    'accountId',
  );
  @override
  late final GeneratedColumn<String> accountId = GeneratedColumn<String>(
    'account_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _warehouseIdMeta = const VerificationMeta(
    'warehouseId',
  );
  @override
  late final GeneratedColumn<int> warehouseId = GeneratedColumn<int>(
    'warehouse_id',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _operationKindMeta = const VerificationMeta(
    'operationKind',
  );
  @override
  late final GeneratedColumn<String> operationKind = GeneratedColumn<String>(
    'operation_kind',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _payloadMeta = const VerificationMeta(
    'payload',
  );
  @override
  late final GeneratedColumn<String> payload = GeneratedColumn<String>(
    'payload',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _operationStateMeta = const VerificationMeta(
    'operationState',
  );
  @override
  late final GeneratedColumn<String> operationState = GeneratedColumn<String>(
    'operation_state',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _createdAtMeta = const VerificationMeta(
    'createdAt',
  );
  @override
  late final GeneratedColumn<DateTime> createdAt = GeneratedColumn<DateTime>(
    'created_at',
    aliasedName,
    false,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _confirmedAtMeta = const VerificationMeta(
    'confirmedAt',
  );
  @override
  late final GeneratedColumn<DateTime> confirmedAt = GeneratedColumn<DateTime>(
    'confirmed_at',
    aliasedName,
    true,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _nextAttemptAtMeta = const VerificationMeta(
    'nextAttemptAt',
  );
  @override
  late final GeneratedColumn<DateTime> nextAttemptAt =
      GeneratedColumn<DateTime>(
        'next_attempt_at',
        aliasedName,
        true,
        type: DriftSqlType.dateTime,
        requiredDuringInsert: false,
      );
  static const VerificationMeta _attemptCountMeta = const VerificationMeta(
    'attemptCount',
  );
  @override
  late final GeneratedColumn<int> attemptCount = GeneratedColumn<int>(
    'attempt_count',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _lastFailureCodeMeta = const VerificationMeta(
    'lastFailureCode',
  );
  @override
  late final GeneratedColumn<String> lastFailureCode = GeneratedColumn<String>(
    'last_failure_code',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  @override
  List<GeneratedColumn> get $columns => [
    operationId,
    idempotencyKey,
    accountId,
    warehouseId,
    operationKind,
    payload,
    operationState,
    createdAt,
    confirmedAt,
    nextAttemptAt,
    attemptCount,
    lastFailureCode,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'outbox_operations';
  @override
  VerificationContext validateIntegrity(
    Insertable<OfflineOutboxOperation> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('operation_id')) {
      context.handle(
        _operationIdMeta,
        operationId.isAcceptableOrUnknown(
          data['operation_id']!,
          _operationIdMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_operationIdMeta);
    }
    if (data.containsKey('idempotency_key')) {
      context.handle(
        _idempotencyKeyMeta,
        idempotencyKey.isAcceptableOrUnknown(
          data['idempotency_key']!,
          _idempotencyKeyMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_idempotencyKeyMeta);
    }
    if (data.containsKey('account_id')) {
      context.handle(
        _accountIdMeta,
        accountId.isAcceptableOrUnknown(data['account_id']!, _accountIdMeta),
      );
    } else if (isInserting) {
      context.missing(_accountIdMeta);
    }
    if (data.containsKey('warehouse_id')) {
      context.handle(
        _warehouseIdMeta,
        warehouseId.isAcceptableOrUnknown(
          data['warehouse_id']!,
          _warehouseIdMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_warehouseIdMeta);
    }
    if (data.containsKey('operation_kind')) {
      context.handle(
        _operationKindMeta,
        operationKind.isAcceptableOrUnknown(
          data['operation_kind']!,
          _operationKindMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_operationKindMeta);
    }
    if (data.containsKey('payload')) {
      context.handle(
        _payloadMeta,
        payload.isAcceptableOrUnknown(data['payload']!, _payloadMeta),
      );
    } else if (isInserting) {
      context.missing(_payloadMeta);
    }
    if (data.containsKey('operation_state')) {
      context.handle(
        _operationStateMeta,
        operationState.isAcceptableOrUnknown(
          data['operation_state']!,
          _operationStateMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_operationStateMeta);
    }
    if (data.containsKey('created_at')) {
      context.handle(
        _createdAtMeta,
        createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta),
      );
    } else if (isInserting) {
      context.missing(_createdAtMeta);
    }
    if (data.containsKey('confirmed_at')) {
      context.handle(
        _confirmedAtMeta,
        confirmedAt.isAcceptableOrUnknown(
          data['confirmed_at']!,
          _confirmedAtMeta,
        ),
      );
    }
    if (data.containsKey('next_attempt_at')) {
      context.handle(
        _nextAttemptAtMeta,
        nextAttemptAt.isAcceptableOrUnknown(
          data['next_attempt_at']!,
          _nextAttemptAtMeta,
        ),
      );
    }
    if (data.containsKey('attempt_count')) {
      context.handle(
        _attemptCountMeta,
        attemptCount.isAcceptableOrUnknown(
          data['attempt_count']!,
          _attemptCountMeta,
        ),
      );
    }
    if (data.containsKey('last_failure_code')) {
      context.handle(
        _lastFailureCodeMeta,
        lastFailureCode.isAcceptableOrUnknown(
          data['last_failure_code']!,
          _lastFailureCodeMeta,
        ),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {operationId};
  @override
  List<Set<GeneratedColumn>> get uniqueKeys => [
    {accountId, idempotencyKey},
  ];
  @override
  OfflineOutboxOperation map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return OfflineOutboxOperation(
      operationId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}operation_id'],
      )!,
      idempotencyKey: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}idempotency_key'],
      )!,
      accountId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}account_id'],
      )!,
      warehouseId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}warehouse_id'],
      )!,
      operationKind: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}operation_kind'],
      )!,
      payload: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}payload'],
      )!,
      operationState: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}operation_state'],
      )!,
      createdAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}created_at'],
      )!,
      confirmedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}confirmed_at'],
      ),
      nextAttemptAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}next_attempt_at'],
      ),
      attemptCount: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}attempt_count'],
      )!,
      lastFailureCode: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}last_failure_code'],
      ),
    );
  }

  @override
  $OfflineOutboxOperationsTable createAlias(String alias) {
    return $OfflineOutboxOperationsTable(attachedDatabase, alias);
  }
}

class OfflineOutboxOperation extends DataClass
    implements Insertable<OfflineOutboxOperation> {
  final String operationId;
  final String idempotencyKey;
  final String accountId;
  final int warehouseId;
  final String operationKind;
  final String payload;
  final String operationState;
  final DateTime createdAt;
  final DateTime? confirmedAt;
  final DateTime? nextAttemptAt;
  final int attemptCount;
  final String? lastFailureCode;
  const OfflineOutboxOperation({
    required this.operationId,
    required this.idempotencyKey,
    required this.accountId,
    required this.warehouseId,
    required this.operationKind,
    required this.payload,
    required this.operationState,
    required this.createdAt,
    this.confirmedAt,
    this.nextAttemptAt,
    required this.attemptCount,
    this.lastFailureCode,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['operation_id'] = Variable<String>(operationId);
    map['idempotency_key'] = Variable<String>(idempotencyKey);
    map['account_id'] = Variable<String>(accountId);
    map['warehouse_id'] = Variable<int>(warehouseId);
    map['operation_kind'] = Variable<String>(operationKind);
    map['payload'] = Variable<String>(payload);
    map['operation_state'] = Variable<String>(operationState);
    map['created_at'] = Variable<DateTime>(createdAt);
    if (!nullToAbsent || confirmedAt != null) {
      map['confirmed_at'] = Variable<DateTime>(confirmedAt);
    }
    if (!nullToAbsent || nextAttemptAt != null) {
      map['next_attempt_at'] = Variable<DateTime>(nextAttemptAt);
    }
    map['attempt_count'] = Variable<int>(attemptCount);
    if (!nullToAbsent || lastFailureCode != null) {
      map['last_failure_code'] = Variable<String>(lastFailureCode);
    }
    return map;
  }

  OfflineOutboxOperationsCompanion toCompanion(bool nullToAbsent) {
    return OfflineOutboxOperationsCompanion(
      operationId: Value(operationId),
      idempotencyKey: Value(idempotencyKey),
      accountId: Value(accountId),
      warehouseId: Value(warehouseId),
      operationKind: Value(operationKind),
      payload: Value(payload),
      operationState: Value(operationState),
      createdAt: Value(createdAt),
      confirmedAt: confirmedAt == null && nullToAbsent
          ? const Value.absent()
          : Value(confirmedAt),
      nextAttemptAt: nextAttemptAt == null && nullToAbsent
          ? const Value.absent()
          : Value(nextAttemptAt),
      attemptCount: Value(attemptCount),
      lastFailureCode: lastFailureCode == null && nullToAbsent
          ? const Value.absent()
          : Value(lastFailureCode),
    );
  }

  factory OfflineOutboxOperation.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return OfflineOutboxOperation(
      operationId: serializer.fromJson<String>(json['operationId']),
      idempotencyKey: serializer.fromJson<String>(json['idempotencyKey']),
      accountId: serializer.fromJson<String>(json['accountId']),
      warehouseId: serializer.fromJson<int>(json['warehouseId']),
      operationKind: serializer.fromJson<String>(json['operationKind']),
      payload: serializer.fromJson<String>(json['payload']),
      operationState: serializer.fromJson<String>(json['operationState']),
      createdAt: serializer.fromJson<DateTime>(json['createdAt']),
      confirmedAt: serializer.fromJson<DateTime?>(json['confirmedAt']),
      nextAttemptAt: serializer.fromJson<DateTime?>(json['nextAttemptAt']),
      attemptCount: serializer.fromJson<int>(json['attemptCount']),
      lastFailureCode: serializer.fromJson<String?>(json['lastFailureCode']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'operationId': serializer.toJson<String>(operationId),
      'idempotencyKey': serializer.toJson<String>(idempotencyKey),
      'accountId': serializer.toJson<String>(accountId),
      'warehouseId': serializer.toJson<int>(warehouseId),
      'operationKind': serializer.toJson<String>(operationKind),
      'payload': serializer.toJson<String>(payload),
      'operationState': serializer.toJson<String>(operationState),
      'createdAt': serializer.toJson<DateTime>(createdAt),
      'confirmedAt': serializer.toJson<DateTime?>(confirmedAt),
      'nextAttemptAt': serializer.toJson<DateTime?>(nextAttemptAt),
      'attemptCount': serializer.toJson<int>(attemptCount),
      'lastFailureCode': serializer.toJson<String?>(lastFailureCode),
    };
  }

  OfflineOutboxOperation copyWith({
    String? operationId,
    String? idempotencyKey,
    String? accountId,
    int? warehouseId,
    String? operationKind,
    String? payload,
    String? operationState,
    DateTime? createdAt,
    Value<DateTime?> confirmedAt = const Value.absent(),
    Value<DateTime?> nextAttemptAt = const Value.absent(),
    int? attemptCount,
    Value<String?> lastFailureCode = const Value.absent(),
  }) => OfflineOutboxOperation(
    operationId: operationId ?? this.operationId,
    idempotencyKey: idempotencyKey ?? this.idempotencyKey,
    accountId: accountId ?? this.accountId,
    warehouseId: warehouseId ?? this.warehouseId,
    operationKind: operationKind ?? this.operationKind,
    payload: payload ?? this.payload,
    operationState: operationState ?? this.operationState,
    createdAt: createdAt ?? this.createdAt,
    confirmedAt: confirmedAt.present ? confirmedAt.value : this.confirmedAt,
    nextAttemptAt: nextAttemptAt.present
        ? nextAttemptAt.value
        : this.nextAttemptAt,
    attemptCount: attemptCount ?? this.attemptCount,
    lastFailureCode: lastFailureCode.present
        ? lastFailureCode.value
        : this.lastFailureCode,
  );
  OfflineOutboxOperation copyWithCompanion(
    OfflineOutboxOperationsCompanion data,
  ) {
    return OfflineOutboxOperation(
      operationId: data.operationId.present
          ? data.operationId.value
          : this.operationId,
      idempotencyKey: data.idempotencyKey.present
          ? data.idempotencyKey.value
          : this.idempotencyKey,
      accountId: data.accountId.present ? data.accountId.value : this.accountId,
      warehouseId: data.warehouseId.present
          ? data.warehouseId.value
          : this.warehouseId,
      operationKind: data.operationKind.present
          ? data.operationKind.value
          : this.operationKind,
      payload: data.payload.present ? data.payload.value : this.payload,
      operationState: data.operationState.present
          ? data.operationState.value
          : this.operationState,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
      confirmedAt: data.confirmedAt.present
          ? data.confirmedAt.value
          : this.confirmedAt,
      nextAttemptAt: data.nextAttemptAt.present
          ? data.nextAttemptAt.value
          : this.nextAttemptAt,
      attemptCount: data.attemptCount.present
          ? data.attemptCount.value
          : this.attemptCount,
      lastFailureCode: data.lastFailureCode.present
          ? data.lastFailureCode.value
          : this.lastFailureCode,
    );
  }

  @override
  String toString() {
    return (StringBuffer('OfflineOutboxOperation(')
          ..write('operationId: $operationId, ')
          ..write('idempotencyKey: $idempotencyKey, ')
          ..write('accountId: $accountId, ')
          ..write('warehouseId: $warehouseId, ')
          ..write('operationKind: $operationKind, ')
          ..write('payload: $payload, ')
          ..write('operationState: $operationState, ')
          ..write('createdAt: $createdAt, ')
          ..write('confirmedAt: $confirmedAt, ')
          ..write('nextAttemptAt: $nextAttemptAt, ')
          ..write('attemptCount: $attemptCount, ')
          ..write('lastFailureCode: $lastFailureCode')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    operationId,
    idempotencyKey,
    accountId,
    warehouseId,
    operationKind,
    payload,
    operationState,
    createdAt,
    confirmedAt,
    nextAttemptAt,
    attemptCount,
    lastFailureCode,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is OfflineOutboxOperation &&
          other.operationId == this.operationId &&
          other.idempotencyKey == this.idempotencyKey &&
          other.accountId == this.accountId &&
          other.warehouseId == this.warehouseId &&
          other.operationKind == this.operationKind &&
          other.payload == this.payload &&
          other.operationState == this.operationState &&
          other.createdAt == this.createdAt &&
          other.confirmedAt == this.confirmedAt &&
          other.nextAttemptAt == this.nextAttemptAt &&
          other.attemptCount == this.attemptCount &&
          other.lastFailureCode == this.lastFailureCode);
}

class OfflineOutboxOperationsCompanion
    extends UpdateCompanion<OfflineOutboxOperation> {
  final Value<String> operationId;
  final Value<String> idempotencyKey;
  final Value<String> accountId;
  final Value<int> warehouseId;
  final Value<String> operationKind;
  final Value<String> payload;
  final Value<String> operationState;
  final Value<DateTime> createdAt;
  final Value<DateTime?> confirmedAt;
  final Value<DateTime?> nextAttemptAt;
  final Value<int> attemptCount;
  final Value<String?> lastFailureCode;
  final Value<int> rowid;
  const OfflineOutboxOperationsCompanion({
    this.operationId = const Value.absent(),
    this.idempotencyKey = const Value.absent(),
    this.accountId = const Value.absent(),
    this.warehouseId = const Value.absent(),
    this.operationKind = const Value.absent(),
    this.payload = const Value.absent(),
    this.operationState = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.confirmedAt = const Value.absent(),
    this.nextAttemptAt = const Value.absent(),
    this.attemptCount = const Value.absent(),
    this.lastFailureCode = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  OfflineOutboxOperationsCompanion.insert({
    required String operationId,
    required String idempotencyKey,
    required String accountId,
    required int warehouseId,
    required String operationKind,
    required String payload,
    required String operationState,
    required DateTime createdAt,
    this.confirmedAt = const Value.absent(),
    this.nextAttemptAt = const Value.absent(),
    this.attemptCount = const Value.absent(),
    this.lastFailureCode = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : operationId = Value(operationId),
       idempotencyKey = Value(idempotencyKey),
       accountId = Value(accountId),
       warehouseId = Value(warehouseId),
       operationKind = Value(operationKind),
       payload = Value(payload),
       operationState = Value(operationState),
       createdAt = Value(createdAt);
  static Insertable<OfflineOutboxOperation> custom({
    Expression<String>? operationId,
    Expression<String>? idempotencyKey,
    Expression<String>? accountId,
    Expression<int>? warehouseId,
    Expression<String>? operationKind,
    Expression<String>? payload,
    Expression<String>? operationState,
    Expression<DateTime>? createdAt,
    Expression<DateTime>? confirmedAt,
    Expression<DateTime>? nextAttemptAt,
    Expression<int>? attemptCount,
    Expression<String>? lastFailureCode,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (operationId != null) 'operation_id': operationId,
      if (idempotencyKey != null) 'idempotency_key': idempotencyKey,
      if (accountId != null) 'account_id': accountId,
      if (warehouseId != null) 'warehouse_id': warehouseId,
      if (operationKind != null) 'operation_kind': operationKind,
      if (payload != null) 'payload': payload,
      if (operationState != null) 'operation_state': operationState,
      if (createdAt != null) 'created_at': createdAt,
      if (confirmedAt != null) 'confirmed_at': confirmedAt,
      if (nextAttemptAt != null) 'next_attempt_at': nextAttemptAt,
      if (attemptCount != null) 'attempt_count': attemptCount,
      if (lastFailureCode != null) 'last_failure_code': lastFailureCode,
      if (rowid != null) 'rowid': rowid,
    });
  }

  OfflineOutboxOperationsCompanion copyWith({
    Value<String>? operationId,
    Value<String>? idempotencyKey,
    Value<String>? accountId,
    Value<int>? warehouseId,
    Value<String>? operationKind,
    Value<String>? payload,
    Value<String>? operationState,
    Value<DateTime>? createdAt,
    Value<DateTime?>? confirmedAt,
    Value<DateTime?>? nextAttemptAt,
    Value<int>? attemptCount,
    Value<String?>? lastFailureCode,
    Value<int>? rowid,
  }) {
    return OfflineOutboxOperationsCompanion(
      operationId: operationId ?? this.operationId,
      idempotencyKey: idempotencyKey ?? this.idempotencyKey,
      accountId: accountId ?? this.accountId,
      warehouseId: warehouseId ?? this.warehouseId,
      operationKind: operationKind ?? this.operationKind,
      payload: payload ?? this.payload,
      operationState: operationState ?? this.operationState,
      createdAt: createdAt ?? this.createdAt,
      confirmedAt: confirmedAt ?? this.confirmedAt,
      nextAttemptAt: nextAttemptAt ?? this.nextAttemptAt,
      attemptCount: attemptCount ?? this.attemptCount,
      lastFailureCode: lastFailureCode ?? this.lastFailureCode,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (operationId.present) {
      map['operation_id'] = Variable<String>(operationId.value);
    }
    if (idempotencyKey.present) {
      map['idempotency_key'] = Variable<String>(idempotencyKey.value);
    }
    if (accountId.present) {
      map['account_id'] = Variable<String>(accountId.value);
    }
    if (warehouseId.present) {
      map['warehouse_id'] = Variable<int>(warehouseId.value);
    }
    if (operationKind.present) {
      map['operation_kind'] = Variable<String>(operationKind.value);
    }
    if (payload.present) {
      map['payload'] = Variable<String>(payload.value);
    }
    if (operationState.present) {
      map['operation_state'] = Variable<String>(operationState.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<DateTime>(createdAt.value);
    }
    if (confirmedAt.present) {
      map['confirmed_at'] = Variable<DateTime>(confirmedAt.value);
    }
    if (nextAttemptAt.present) {
      map['next_attempt_at'] = Variable<DateTime>(nextAttemptAt.value);
    }
    if (attemptCount.present) {
      map['attempt_count'] = Variable<int>(attemptCount.value);
    }
    if (lastFailureCode.present) {
      map['last_failure_code'] = Variable<String>(lastFailureCode.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('OfflineOutboxOperationsCompanion(')
          ..write('operationId: $operationId, ')
          ..write('idempotencyKey: $idempotencyKey, ')
          ..write('accountId: $accountId, ')
          ..write('warehouseId: $warehouseId, ')
          ..write('operationKind: $operationKind, ')
          ..write('payload: $payload, ')
          ..write('operationState: $operationState, ')
          ..write('createdAt: $createdAt, ')
          ..write('confirmedAt: $confirmedAt, ')
          ..write('nextAttemptAt: $nextAttemptAt, ')
          ..write('attemptCount: $attemptCount, ')
          ..write('lastFailureCode: $lastFailureCode, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $OfflineOutboxDependenciesTable extends OfflineOutboxDependencies
    with TableInfo<$OfflineOutboxDependenciesTable, OfflineOutboxDependency> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $OfflineOutboxDependenciesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _operationIdMeta = const VerificationMeta(
    'operationId',
  );
  @override
  late final GeneratedColumn<String> operationId = GeneratedColumn<String>(
    'operation_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'REFERENCES outbox_operations (operation_id) ON DELETE CASCADE',
    ),
  );
  static const VerificationMeta _dependencyIdMeta = const VerificationMeta(
    'dependencyId',
  );
  @override
  late final GeneratedColumn<String> dependencyId = GeneratedColumn<String>(
    'dependency_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'REFERENCES outbox_operations (operation_id) ON DELETE CASCADE',
    ),
  );
  @override
  List<GeneratedColumn> get $columns => [operationId, dependencyId];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'outbox_dependencies';
  @override
  VerificationContext validateIntegrity(
    Insertable<OfflineOutboxDependency> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('operation_id')) {
      context.handle(
        _operationIdMeta,
        operationId.isAcceptableOrUnknown(
          data['operation_id']!,
          _operationIdMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_operationIdMeta);
    }
    if (data.containsKey('dependency_id')) {
      context.handle(
        _dependencyIdMeta,
        dependencyId.isAcceptableOrUnknown(
          data['dependency_id']!,
          _dependencyIdMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_dependencyIdMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {operationId, dependencyId};
  @override
  OfflineOutboxDependency map(
    Map<String, dynamic> data, {
    String? tablePrefix,
  }) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return OfflineOutboxDependency(
      operationId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}operation_id'],
      )!,
      dependencyId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}dependency_id'],
      )!,
    );
  }

  @override
  $OfflineOutboxDependenciesTable createAlias(String alias) {
    return $OfflineOutboxDependenciesTable(attachedDatabase, alias);
  }
}

class OfflineOutboxDependency extends DataClass
    implements Insertable<OfflineOutboxDependency> {
  final String operationId;
  final String dependencyId;
  const OfflineOutboxDependency({
    required this.operationId,
    required this.dependencyId,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['operation_id'] = Variable<String>(operationId);
    map['dependency_id'] = Variable<String>(dependencyId);
    return map;
  }

  OfflineOutboxDependenciesCompanion toCompanion(bool nullToAbsent) {
    return OfflineOutboxDependenciesCompanion(
      operationId: Value(operationId),
      dependencyId: Value(dependencyId),
    );
  }

  factory OfflineOutboxDependency.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return OfflineOutboxDependency(
      operationId: serializer.fromJson<String>(json['operationId']),
      dependencyId: serializer.fromJson<String>(json['dependencyId']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'operationId': serializer.toJson<String>(operationId),
      'dependencyId': serializer.toJson<String>(dependencyId),
    };
  }

  OfflineOutboxDependency copyWith({
    String? operationId,
    String? dependencyId,
  }) => OfflineOutboxDependency(
    operationId: operationId ?? this.operationId,
    dependencyId: dependencyId ?? this.dependencyId,
  );
  OfflineOutboxDependency copyWithCompanion(
    OfflineOutboxDependenciesCompanion data,
  ) {
    return OfflineOutboxDependency(
      operationId: data.operationId.present
          ? data.operationId.value
          : this.operationId,
      dependencyId: data.dependencyId.present
          ? data.dependencyId.value
          : this.dependencyId,
    );
  }

  @override
  String toString() {
    return (StringBuffer('OfflineOutboxDependency(')
          ..write('operationId: $operationId, ')
          ..write('dependencyId: $dependencyId')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(operationId, dependencyId);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is OfflineOutboxDependency &&
          other.operationId == this.operationId &&
          other.dependencyId == this.dependencyId);
}

class OfflineOutboxDependenciesCompanion
    extends UpdateCompanion<OfflineOutboxDependency> {
  final Value<String> operationId;
  final Value<String> dependencyId;
  final Value<int> rowid;
  const OfflineOutboxDependenciesCompanion({
    this.operationId = const Value.absent(),
    this.dependencyId = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  OfflineOutboxDependenciesCompanion.insert({
    required String operationId,
    required String dependencyId,
    this.rowid = const Value.absent(),
  }) : operationId = Value(operationId),
       dependencyId = Value(dependencyId);
  static Insertable<OfflineOutboxDependency> custom({
    Expression<String>? operationId,
    Expression<String>? dependencyId,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (operationId != null) 'operation_id': operationId,
      if (dependencyId != null) 'dependency_id': dependencyId,
      if (rowid != null) 'rowid': rowid,
    });
  }

  OfflineOutboxDependenciesCompanion copyWith({
    Value<String>? operationId,
    Value<String>? dependencyId,
    Value<int>? rowid,
  }) {
    return OfflineOutboxDependenciesCompanion(
      operationId: operationId ?? this.operationId,
      dependencyId: dependencyId ?? this.dependencyId,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (operationId.present) {
      map['operation_id'] = Variable<String>(operationId.value);
    }
    if (dependencyId.present) {
      map['dependency_id'] = Variable<String>(dependencyId.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('OfflineOutboxDependenciesCompanion(')
          ..write('operationId: $operationId, ')
          ..write('dependencyId: $dependencyId, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

abstract class _$OfflineDatabase extends GeneratedDatabase {
  _$OfflineDatabase(QueryExecutor e) : super(e);
  $OfflineDatabaseManager get managers => $OfflineDatabaseManager(this);
  late final $OfflineCacheEntriesTable offlineCacheEntries =
      $OfflineCacheEntriesTable(this);
  late final $OfflineDocumentDraftsTable offlineDocumentDrafts =
      $OfflineDocumentDraftsTable(this);
  late final $OfflineOutboxOperationsTable offlineOutboxOperations =
      $OfflineOutboxOperationsTable(this);
  late final $OfflineOutboxDependenciesTable offlineOutboxDependencies =
      $OfflineOutboxDependenciesTable(this);
  @override
  Iterable<TableInfo<Table, Object?>> get allTables =>
      allSchemaEntities.whereType<TableInfo<Table, Object?>>();
  @override
  List<DatabaseSchemaEntity> get allSchemaEntities => [
    offlineCacheEntries,
    offlineDocumentDrafts,
    offlineOutboxOperations,
    offlineOutboxDependencies,
  ];
  @override
  StreamQueryUpdateRules get streamUpdateRules => const StreamQueryUpdateRules([
    WritePropagation(
      on: TableUpdateQuery.onTableName(
        'outbox_operations',
        limitUpdateKind: UpdateKind.delete,
      ),
      result: [TableUpdate('outbox_dependencies', kind: UpdateKind.delete)],
    ),
    WritePropagation(
      on: TableUpdateQuery.onTableName(
        'outbox_operations',
        limitUpdateKind: UpdateKind.delete,
      ),
      result: [TableUpdate('outbox_dependencies', kind: UpdateKind.delete)],
    ),
  ]);
}

typedef $$OfflineCacheEntriesTableCreateCompanionBuilder =
    OfflineCacheEntriesCompanion Function({
      required String cacheId,
      required String accountId,
      Value<int?> warehouseId,
      required String namespace,
      required String entityKey,
      required String payload,
      required int recordSchemaVersion,
      required DateTime fetchedAt,
      required DateTime expiresAt,
      Value<int> rowid,
    });
typedef $$OfflineCacheEntriesTableUpdateCompanionBuilder =
    OfflineCacheEntriesCompanion Function({
      Value<String> cacheId,
      Value<String> accountId,
      Value<int?> warehouseId,
      Value<String> namespace,
      Value<String> entityKey,
      Value<String> payload,
      Value<int> recordSchemaVersion,
      Value<DateTime> fetchedAt,
      Value<DateTime> expiresAt,
      Value<int> rowid,
    });

class $$OfflineCacheEntriesTableFilterComposer
    extends Composer<_$OfflineDatabase, $OfflineCacheEntriesTable> {
  $$OfflineCacheEntriesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get cacheId => $composableBuilder(
    column: $table.cacheId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get accountId => $composableBuilder(
    column: $table.accountId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get warehouseId => $composableBuilder(
    column: $table.warehouseId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get namespace => $composableBuilder(
    column: $table.namespace,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get entityKey => $composableBuilder(
    column: $table.entityKey,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get payload => $composableBuilder(
    column: $table.payload,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get recordSchemaVersion => $composableBuilder(
    column: $table.recordSchemaVersion,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get fetchedAt => $composableBuilder(
    column: $table.fetchedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get expiresAt => $composableBuilder(
    column: $table.expiresAt,
    builder: (column) => ColumnFilters(column),
  );
}

class $$OfflineCacheEntriesTableOrderingComposer
    extends Composer<_$OfflineDatabase, $OfflineCacheEntriesTable> {
  $$OfflineCacheEntriesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get cacheId => $composableBuilder(
    column: $table.cacheId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get accountId => $composableBuilder(
    column: $table.accountId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get warehouseId => $composableBuilder(
    column: $table.warehouseId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get namespace => $composableBuilder(
    column: $table.namespace,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get entityKey => $composableBuilder(
    column: $table.entityKey,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get payload => $composableBuilder(
    column: $table.payload,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get recordSchemaVersion => $composableBuilder(
    column: $table.recordSchemaVersion,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get fetchedAt => $composableBuilder(
    column: $table.fetchedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get expiresAt => $composableBuilder(
    column: $table.expiresAt,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$OfflineCacheEntriesTableAnnotationComposer
    extends Composer<_$OfflineDatabase, $OfflineCacheEntriesTable> {
  $$OfflineCacheEntriesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get cacheId =>
      $composableBuilder(column: $table.cacheId, builder: (column) => column);

  GeneratedColumn<String> get accountId =>
      $composableBuilder(column: $table.accountId, builder: (column) => column);

  GeneratedColumn<int> get warehouseId => $composableBuilder(
    column: $table.warehouseId,
    builder: (column) => column,
  );

  GeneratedColumn<String> get namespace =>
      $composableBuilder(column: $table.namespace, builder: (column) => column);

  GeneratedColumn<String> get entityKey =>
      $composableBuilder(column: $table.entityKey, builder: (column) => column);

  GeneratedColumn<String> get payload =>
      $composableBuilder(column: $table.payload, builder: (column) => column);

  GeneratedColumn<int> get recordSchemaVersion => $composableBuilder(
    column: $table.recordSchemaVersion,
    builder: (column) => column,
  );

  GeneratedColumn<DateTime> get fetchedAt =>
      $composableBuilder(column: $table.fetchedAt, builder: (column) => column);

  GeneratedColumn<DateTime> get expiresAt =>
      $composableBuilder(column: $table.expiresAt, builder: (column) => column);
}

class $$OfflineCacheEntriesTableTableManager
    extends
        RootTableManager<
          _$OfflineDatabase,
          $OfflineCacheEntriesTable,
          OfflineCacheEntry,
          $$OfflineCacheEntriesTableFilterComposer,
          $$OfflineCacheEntriesTableOrderingComposer,
          $$OfflineCacheEntriesTableAnnotationComposer,
          $$OfflineCacheEntriesTableCreateCompanionBuilder,
          $$OfflineCacheEntriesTableUpdateCompanionBuilder,
          (
            OfflineCacheEntry,
            BaseReferences<
              _$OfflineDatabase,
              $OfflineCacheEntriesTable,
              OfflineCacheEntry
            >,
          ),
          OfflineCacheEntry,
          PrefetchHooks Function()
        > {
  $$OfflineCacheEntriesTableTableManager(
    _$OfflineDatabase db,
    $OfflineCacheEntriesTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$OfflineCacheEntriesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$OfflineCacheEntriesTableOrderingComposer(
                $db: db,
                $table: table,
              ),
          createComputedFieldComposer: () =>
              $$OfflineCacheEntriesTableAnnotationComposer(
                $db: db,
                $table: table,
              ),
          updateCompanionCallback:
              ({
                Value<String> cacheId = const Value.absent(),
                Value<String> accountId = const Value.absent(),
                Value<int?> warehouseId = const Value.absent(),
                Value<String> namespace = const Value.absent(),
                Value<String> entityKey = const Value.absent(),
                Value<String> payload = const Value.absent(),
                Value<int> recordSchemaVersion = const Value.absent(),
                Value<DateTime> fetchedAt = const Value.absent(),
                Value<DateTime> expiresAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => OfflineCacheEntriesCompanion(
                cacheId: cacheId,
                accountId: accountId,
                warehouseId: warehouseId,
                namespace: namespace,
                entityKey: entityKey,
                payload: payload,
                recordSchemaVersion: recordSchemaVersion,
                fetchedAt: fetchedAt,
                expiresAt: expiresAt,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String cacheId,
                required String accountId,
                Value<int?> warehouseId = const Value.absent(),
                required String namespace,
                required String entityKey,
                required String payload,
                required int recordSchemaVersion,
                required DateTime fetchedAt,
                required DateTime expiresAt,
                Value<int> rowid = const Value.absent(),
              }) => OfflineCacheEntriesCompanion.insert(
                cacheId: cacheId,
                accountId: accountId,
                warehouseId: warehouseId,
                namespace: namespace,
                entityKey: entityKey,
                payload: payload,
                recordSchemaVersion: recordSchemaVersion,
                fetchedAt: fetchedAt,
                expiresAt: expiresAt,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$OfflineCacheEntriesTableProcessedTableManager =
    ProcessedTableManager<
      _$OfflineDatabase,
      $OfflineCacheEntriesTable,
      OfflineCacheEntry,
      $$OfflineCacheEntriesTableFilterComposer,
      $$OfflineCacheEntriesTableOrderingComposer,
      $$OfflineCacheEntriesTableAnnotationComposer,
      $$OfflineCacheEntriesTableCreateCompanionBuilder,
      $$OfflineCacheEntriesTableUpdateCompanionBuilder,
      (
        OfflineCacheEntry,
        BaseReferences<
          _$OfflineDatabase,
          $OfflineCacheEntriesTable,
          OfflineCacheEntry
        >,
      ),
      OfflineCacheEntry,
      PrefetchHooks Function()
    >;
typedef $$OfflineDocumentDraftsTableCreateCompanionBuilder =
    OfflineDocumentDraftsCompanion Function({
      required String draftId,
      required String accountId,
      required int warehouseId,
      required String payload,
      required int draftVersion,
      required DateTime createdAt,
      required DateTime updatedAt,
      Value<int> rowid,
    });
typedef $$OfflineDocumentDraftsTableUpdateCompanionBuilder =
    OfflineDocumentDraftsCompanion Function({
      Value<String> draftId,
      Value<String> accountId,
      Value<int> warehouseId,
      Value<String> payload,
      Value<int> draftVersion,
      Value<DateTime> createdAt,
      Value<DateTime> updatedAt,
      Value<int> rowid,
    });

class $$OfflineDocumentDraftsTableFilterComposer
    extends Composer<_$OfflineDatabase, $OfflineDocumentDraftsTable> {
  $$OfflineDocumentDraftsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get draftId => $composableBuilder(
    column: $table.draftId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get accountId => $composableBuilder(
    column: $table.accountId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get warehouseId => $composableBuilder(
    column: $table.warehouseId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get payload => $composableBuilder(
    column: $table.payload,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get draftVersion => $composableBuilder(
    column: $table.draftVersion,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnFilters(column),
  );
}

class $$OfflineDocumentDraftsTableOrderingComposer
    extends Composer<_$OfflineDatabase, $OfflineDocumentDraftsTable> {
  $$OfflineDocumentDraftsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get draftId => $composableBuilder(
    column: $table.draftId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get accountId => $composableBuilder(
    column: $table.accountId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get warehouseId => $composableBuilder(
    column: $table.warehouseId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get payload => $composableBuilder(
    column: $table.payload,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get draftVersion => $composableBuilder(
    column: $table.draftVersion,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$OfflineDocumentDraftsTableAnnotationComposer
    extends Composer<_$OfflineDatabase, $OfflineDocumentDraftsTable> {
  $$OfflineDocumentDraftsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get draftId =>
      $composableBuilder(column: $table.draftId, builder: (column) => column);

  GeneratedColumn<String> get accountId =>
      $composableBuilder(column: $table.accountId, builder: (column) => column);

  GeneratedColumn<int> get warehouseId => $composableBuilder(
    column: $table.warehouseId,
    builder: (column) => column,
  );

  GeneratedColumn<String> get payload =>
      $composableBuilder(column: $table.payload, builder: (column) => column);

  GeneratedColumn<int> get draftVersion => $composableBuilder(
    column: $table.draftVersion,
    builder: (column) => column,
  );

  GeneratedColumn<DateTime> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);

  GeneratedColumn<DateTime> get updatedAt =>
      $composableBuilder(column: $table.updatedAt, builder: (column) => column);
}

class $$OfflineDocumentDraftsTableTableManager
    extends
        RootTableManager<
          _$OfflineDatabase,
          $OfflineDocumentDraftsTable,
          OfflineDocumentDraft,
          $$OfflineDocumentDraftsTableFilterComposer,
          $$OfflineDocumentDraftsTableOrderingComposer,
          $$OfflineDocumentDraftsTableAnnotationComposer,
          $$OfflineDocumentDraftsTableCreateCompanionBuilder,
          $$OfflineDocumentDraftsTableUpdateCompanionBuilder,
          (
            OfflineDocumentDraft,
            BaseReferences<
              _$OfflineDatabase,
              $OfflineDocumentDraftsTable,
              OfflineDocumentDraft
            >,
          ),
          OfflineDocumentDraft,
          PrefetchHooks Function()
        > {
  $$OfflineDocumentDraftsTableTableManager(
    _$OfflineDatabase db,
    $OfflineDocumentDraftsTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$OfflineDocumentDraftsTableFilterComposer(
                $db: db,
                $table: table,
              ),
          createOrderingComposer: () =>
              $$OfflineDocumentDraftsTableOrderingComposer(
                $db: db,
                $table: table,
              ),
          createComputedFieldComposer: () =>
              $$OfflineDocumentDraftsTableAnnotationComposer(
                $db: db,
                $table: table,
              ),
          updateCompanionCallback:
              ({
                Value<String> draftId = const Value.absent(),
                Value<String> accountId = const Value.absent(),
                Value<int> warehouseId = const Value.absent(),
                Value<String> payload = const Value.absent(),
                Value<int> draftVersion = const Value.absent(),
                Value<DateTime> createdAt = const Value.absent(),
                Value<DateTime> updatedAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => OfflineDocumentDraftsCompanion(
                draftId: draftId,
                accountId: accountId,
                warehouseId: warehouseId,
                payload: payload,
                draftVersion: draftVersion,
                createdAt: createdAt,
                updatedAt: updatedAt,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String draftId,
                required String accountId,
                required int warehouseId,
                required String payload,
                required int draftVersion,
                required DateTime createdAt,
                required DateTime updatedAt,
                Value<int> rowid = const Value.absent(),
              }) => OfflineDocumentDraftsCompanion.insert(
                draftId: draftId,
                accountId: accountId,
                warehouseId: warehouseId,
                payload: payload,
                draftVersion: draftVersion,
                createdAt: createdAt,
                updatedAt: updatedAt,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$OfflineDocumentDraftsTableProcessedTableManager =
    ProcessedTableManager<
      _$OfflineDatabase,
      $OfflineDocumentDraftsTable,
      OfflineDocumentDraft,
      $$OfflineDocumentDraftsTableFilterComposer,
      $$OfflineDocumentDraftsTableOrderingComposer,
      $$OfflineDocumentDraftsTableAnnotationComposer,
      $$OfflineDocumentDraftsTableCreateCompanionBuilder,
      $$OfflineDocumentDraftsTableUpdateCompanionBuilder,
      (
        OfflineDocumentDraft,
        BaseReferences<
          _$OfflineDatabase,
          $OfflineDocumentDraftsTable,
          OfflineDocumentDraft
        >,
      ),
      OfflineDocumentDraft,
      PrefetchHooks Function()
    >;
typedef $$OfflineOutboxOperationsTableCreateCompanionBuilder =
    OfflineOutboxOperationsCompanion Function({
      required String operationId,
      required String idempotencyKey,
      required String accountId,
      required int warehouseId,
      required String operationKind,
      required String payload,
      required String operationState,
      required DateTime createdAt,
      Value<DateTime?> confirmedAt,
      Value<DateTime?> nextAttemptAt,
      Value<int> attemptCount,
      Value<String?> lastFailureCode,
      Value<int> rowid,
    });
typedef $$OfflineOutboxOperationsTableUpdateCompanionBuilder =
    OfflineOutboxOperationsCompanion Function({
      Value<String> operationId,
      Value<String> idempotencyKey,
      Value<String> accountId,
      Value<int> warehouseId,
      Value<String> operationKind,
      Value<String> payload,
      Value<String> operationState,
      Value<DateTime> createdAt,
      Value<DateTime?> confirmedAt,
      Value<DateTime?> nextAttemptAt,
      Value<int> attemptCount,
      Value<String?> lastFailureCode,
      Value<int> rowid,
    });

final class $$OfflineOutboxOperationsTableReferences
    extends
        BaseReferences<
          _$OfflineDatabase,
          $OfflineOutboxOperationsTable,
          OfflineOutboxOperation
        > {
  $$OfflineOutboxOperationsTableReferences(
    super.$_db,
    super.$_table,
    super.$_typedResult,
  );

  static MultiTypedResultKey<
    $OfflineOutboxDependenciesTable,
    List<OfflineOutboxDependency>
  >
  _dependentOperationTable(
    _$OfflineDatabase db,
  ) => MultiTypedResultKey.fromTable(
    db.offlineOutboxDependencies,
    aliasName:
        'outbox_operations__operation_id__outbox_dependencies__operation_id',
  );

  $$OfflineOutboxDependenciesTableProcessedTableManager get dependentOperation {
    final manager =
        $$OfflineOutboxDependenciesTableTableManager(
          $_db,
          $_db.offlineOutboxDependencies,
        ).filter(
          (f) => f.operationId.operationId.sqlEquals(
            $_itemColumn<String>('operation_id')!,
          ),
        );

    final cache = $_typedResult.readTableOrNull(_dependentOperationTable($_db));
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: cache),
    );
  }

  static MultiTypedResultKey<
    $OfflineOutboxDependenciesTable,
    List<OfflineOutboxDependency>
  >
  _requiredOperationTable(
    _$OfflineDatabase db,
  ) => MultiTypedResultKey.fromTable(
    db.offlineOutboxDependencies,
    aliasName:
        'outbox_operations__operation_id__outbox_dependencies__dependency_id',
  );

  $$OfflineOutboxDependenciesTableProcessedTableManager get requiredOperation {
    final manager =
        $$OfflineOutboxDependenciesTableTableManager(
          $_db,
          $_db.offlineOutboxDependencies,
        ).filter(
          (f) => f.dependencyId.operationId.sqlEquals(
            $_itemColumn<String>('operation_id')!,
          ),
        );

    final cache = $_typedResult.readTableOrNull(_requiredOperationTable($_db));
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: cache),
    );
  }
}

class $$OfflineOutboxOperationsTableFilterComposer
    extends Composer<_$OfflineDatabase, $OfflineOutboxOperationsTable> {
  $$OfflineOutboxOperationsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get operationId => $composableBuilder(
    column: $table.operationId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get idempotencyKey => $composableBuilder(
    column: $table.idempotencyKey,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get accountId => $composableBuilder(
    column: $table.accountId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get warehouseId => $composableBuilder(
    column: $table.warehouseId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get operationKind => $composableBuilder(
    column: $table.operationKind,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get payload => $composableBuilder(
    column: $table.payload,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get operationState => $composableBuilder(
    column: $table.operationState,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get confirmedAt => $composableBuilder(
    column: $table.confirmedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get nextAttemptAt => $composableBuilder(
    column: $table.nextAttemptAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get attemptCount => $composableBuilder(
    column: $table.attemptCount,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get lastFailureCode => $composableBuilder(
    column: $table.lastFailureCode,
    builder: (column) => ColumnFilters(column),
  );

  Expression<bool> dependentOperation(
    Expression<bool> Function($$OfflineOutboxDependenciesTableFilterComposer f)
    f,
  ) {
    final $$OfflineOutboxDependenciesTableFilterComposer composer =
        $composerBuilder(
          composer: this,
          getCurrentColumn: (t) => t.operationId,
          referencedTable: $db.offlineOutboxDependencies,
          getReferencedColumn: (t) => t.operationId,
          builder:
              (
                joinBuilder, {
                $addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer,
              }) => $$OfflineOutboxDependenciesTableFilterComposer(
                $db: $db,
                $table: $db.offlineOutboxDependencies,
                $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
                joinBuilder: joinBuilder,
                $removeJoinBuilderFromRootComposer:
                    $removeJoinBuilderFromRootComposer,
              ),
        );
    return f(composer);
  }

  Expression<bool> requiredOperation(
    Expression<bool> Function($$OfflineOutboxDependenciesTableFilterComposer f)
    f,
  ) {
    final $$OfflineOutboxDependenciesTableFilterComposer composer =
        $composerBuilder(
          composer: this,
          getCurrentColumn: (t) => t.operationId,
          referencedTable: $db.offlineOutboxDependencies,
          getReferencedColumn: (t) => t.dependencyId,
          builder:
              (
                joinBuilder, {
                $addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer,
              }) => $$OfflineOutboxDependenciesTableFilterComposer(
                $db: $db,
                $table: $db.offlineOutboxDependencies,
                $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
                joinBuilder: joinBuilder,
                $removeJoinBuilderFromRootComposer:
                    $removeJoinBuilderFromRootComposer,
              ),
        );
    return f(composer);
  }
}

class $$OfflineOutboxOperationsTableOrderingComposer
    extends Composer<_$OfflineDatabase, $OfflineOutboxOperationsTable> {
  $$OfflineOutboxOperationsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get operationId => $composableBuilder(
    column: $table.operationId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get idempotencyKey => $composableBuilder(
    column: $table.idempotencyKey,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get accountId => $composableBuilder(
    column: $table.accountId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get warehouseId => $composableBuilder(
    column: $table.warehouseId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get operationKind => $composableBuilder(
    column: $table.operationKind,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get payload => $composableBuilder(
    column: $table.payload,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get operationState => $composableBuilder(
    column: $table.operationState,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get confirmedAt => $composableBuilder(
    column: $table.confirmedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get nextAttemptAt => $composableBuilder(
    column: $table.nextAttemptAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get attemptCount => $composableBuilder(
    column: $table.attemptCount,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get lastFailureCode => $composableBuilder(
    column: $table.lastFailureCode,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$OfflineOutboxOperationsTableAnnotationComposer
    extends Composer<_$OfflineDatabase, $OfflineOutboxOperationsTable> {
  $$OfflineOutboxOperationsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get operationId => $composableBuilder(
    column: $table.operationId,
    builder: (column) => column,
  );

  GeneratedColumn<String> get idempotencyKey => $composableBuilder(
    column: $table.idempotencyKey,
    builder: (column) => column,
  );

  GeneratedColumn<String> get accountId =>
      $composableBuilder(column: $table.accountId, builder: (column) => column);

  GeneratedColumn<int> get warehouseId => $composableBuilder(
    column: $table.warehouseId,
    builder: (column) => column,
  );

  GeneratedColumn<String> get operationKind => $composableBuilder(
    column: $table.operationKind,
    builder: (column) => column,
  );

  GeneratedColumn<String> get payload =>
      $composableBuilder(column: $table.payload, builder: (column) => column);

  GeneratedColumn<String> get operationState => $composableBuilder(
    column: $table.operationState,
    builder: (column) => column,
  );

  GeneratedColumn<DateTime> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);

  GeneratedColumn<DateTime> get confirmedAt => $composableBuilder(
    column: $table.confirmedAt,
    builder: (column) => column,
  );

  GeneratedColumn<DateTime> get nextAttemptAt => $composableBuilder(
    column: $table.nextAttemptAt,
    builder: (column) => column,
  );

  GeneratedColumn<int> get attemptCount => $composableBuilder(
    column: $table.attemptCount,
    builder: (column) => column,
  );

  GeneratedColumn<String> get lastFailureCode => $composableBuilder(
    column: $table.lastFailureCode,
    builder: (column) => column,
  );

  Expression<T> dependentOperation<T extends Object>(
    Expression<T> Function($$OfflineOutboxDependenciesTableAnnotationComposer a)
    f,
  ) {
    final $$OfflineOutboxDependenciesTableAnnotationComposer composer =
        $composerBuilder(
          composer: this,
          getCurrentColumn: (t) => t.operationId,
          referencedTable: $db.offlineOutboxDependencies,
          getReferencedColumn: (t) => t.operationId,
          builder:
              (
                joinBuilder, {
                $addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer,
              }) => $$OfflineOutboxDependenciesTableAnnotationComposer(
                $db: $db,
                $table: $db.offlineOutboxDependencies,
                $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
                joinBuilder: joinBuilder,
                $removeJoinBuilderFromRootComposer:
                    $removeJoinBuilderFromRootComposer,
              ),
        );
    return f(composer);
  }

  Expression<T> requiredOperation<T extends Object>(
    Expression<T> Function($$OfflineOutboxDependenciesTableAnnotationComposer a)
    f,
  ) {
    final $$OfflineOutboxDependenciesTableAnnotationComposer composer =
        $composerBuilder(
          composer: this,
          getCurrentColumn: (t) => t.operationId,
          referencedTable: $db.offlineOutboxDependencies,
          getReferencedColumn: (t) => t.dependencyId,
          builder:
              (
                joinBuilder, {
                $addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer,
              }) => $$OfflineOutboxDependenciesTableAnnotationComposer(
                $db: $db,
                $table: $db.offlineOutboxDependencies,
                $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
                joinBuilder: joinBuilder,
                $removeJoinBuilderFromRootComposer:
                    $removeJoinBuilderFromRootComposer,
              ),
        );
    return f(composer);
  }
}

class $$OfflineOutboxOperationsTableTableManager
    extends
        RootTableManager<
          _$OfflineDatabase,
          $OfflineOutboxOperationsTable,
          OfflineOutboxOperation,
          $$OfflineOutboxOperationsTableFilterComposer,
          $$OfflineOutboxOperationsTableOrderingComposer,
          $$OfflineOutboxOperationsTableAnnotationComposer,
          $$OfflineOutboxOperationsTableCreateCompanionBuilder,
          $$OfflineOutboxOperationsTableUpdateCompanionBuilder,
          (OfflineOutboxOperation, $$OfflineOutboxOperationsTableReferences),
          OfflineOutboxOperation,
          PrefetchHooks Function({
            bool dependentOperation,
            bool requiredOperation,
          })
        > {
  $$OfflineOutboxOperationsTableTableManager(
    _$OfflineDatabase db,
    $OfflineOutboxOperationsTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$OfflineOutboxOperationsTableFilterComposer(
                $db: db,
                $table: table,
              ),
          createOrderingComposer: () =>
              $$OfflineOutboxOperationsTableOrderingComposer(
                $db: db,
                $table: table,
              ),
          createComputedFieldComposer: () =>
              $$OfflineOutboxOperationsTableAnnotationComposer(
                $db: db,
                $table: table,
              ),
          updateCompanionCallback:
              ({
                Value<String> operationId = const Value.absent(),
                Value<String> idempotencyKey = const Value.absent(),
                Value<String> accountId = const Value.absent(),
                Value<int> warehouseId = const Value.absent(),
                Value<String> operationKind = const Value.absent(),
                Value<String> payload = const Value.absent(),
                Value<String> operationState = const Value.absent(),
                Value<DateTime> createdAt = const Value.absent(),
                Value<DateTime?> confirmedAt = const Value.absent(),
                Value<DateTime?> nextAttemptAt = const Value.absent(),
                Value<int> attemptCount = const Value.absent(),
                Value<String?> lastFailureCode = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => OfflineOutboxOperationsCompanion(
                operationId: operationId,
                idempotencyKey: idempotencyKey,
                accountId: accountId,
                warehouseId: warehouseId,
                operationKind: operationKind,
                payload: payload,
                operationState: operationState,
                createdAt: createdAt,
                confirmedAt: confirmedAt,
                nextAttemptAt: nextAttemptAt,
                attemptCount: attemptCount,
                lastFailureCode: lastFailureCode,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String operationId,
                required String idempotencyKey,
                required String accountId,
                required int warehouseId,
                required String operationKind,
                required String payload,
                required String operationState,
                required DateTime createdAt,
                Value<DateTime?> confirmedAt = const Value.absent(),
                Value<DateTime?> nextAttemptAt = const Value.absent(),
                Value<int> attemptCount = const Value.absent(),
                Value<String?> lastFailureCode = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => OfflineOutboxOperationsCompanion.insert(
                operationId: operationId,
                idempotencyKey: idempotencyKey,
                accountId: accountId,
                warehouseId: warehouseId,
                operationKind: operationKind,
                payload: payload,
                operationState: operationState,
                createdAt: createdAt,
                confirmedAt: confirmedAt,
                nextAttemptAt: nextAttemptAt,
                attemptCount: attemptCount,
                lastFailureCode: lastFailureCode,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable(table),
                  $$OfflineOutboxOperationsTableReferences(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback:
              ({dependentOperation = false, requiredOperation = false}) {
                return PrefetchHooks(
                  db: db,
                  explicitlyWatchedTables: [
                    if (dependentOperation) db.offlineOutboxDependencies,
                    if (requiredOperation) db.offlineOutboxDependencies,
                  ],
                  addJoins: null,
                  getPrefetchedDataCallback: (items) async {
                    return [
                      if (dependentOperation)
                        await $_getPrefetchedData<
                          OfflineOutboxOperation,
                          $OfflineOutboxOperationsTable,
                          OfflineOutboxDependency
                        >(
                          currentTable: table,
                          referencedTable:
                              $$OfflineOutboxOperationsTableReferences
                                  ._dependentOperationTable(db),
                          managerFromTypedResult: (p0) =>
                              $$OfflineOutboxOperationsTableReferences(
                                db,
                                table,
                                p0,
                              ).dependentOperation,
                          referencedItemsForCurrentItem:
                              (item, referencedItems) => referencedItems.where(
                                (e) => e.operationId == item.operationId,
                              ),
                          typedResults: items,
                        ),
                      if (requiredOperation)
                        await $_getPrefetchedData<
                          OfflineOutboxOperation,
                          $OfflineOutboxOperationsTable,
                          OfflineOutboxDependency
                        >(
                          currentTable: table,
                          referencedTable:
                              $$OfflineOutboxOperationsTableReferences
                                  ._requiredOperationTable(db),
                          managerFromTypedResult: (p0) =>
                              $$OfflineOutboxOperationsTableReferences(
                                db,
                                table,
                                p0,
                              ).requiredOperation,
                          referencedItemsForCurrentItem:
                              (item, referencedItems) => referencedItems.where(
                                (e) => e.dependencyId == item.operationId,
                              ),
                          typedResults: items,
                        ),
                    ];
                  },
                );
              },
        ),
      );
}

typedef $$OfflineOutboxOperationsTableProcessedTableManager =
    ProcessedTableManager<
      _$OfflineDatabase,
      $OfflineOutboxOperationsTable,
      OfflineOutboxOperation,
      $$OfflineOutboxOperationsTableFilterComposer,
      $$OfflineOutboxOperationsTableOrderingComposer,
      $$OfflineOutboxOperationsTableAnnotationComposer,
      $$OfflineOutboxOperationsTableCreateCompanionBuilder,
      $$OfflineOutboxOperationsTableUpdateCompanionBuilder,
      (OfflineOutboxOperation, $$OfflineOutboxOperationsTableReferences),
      OfflineOutboxOperation,
      PrefetchHooks Function({bool dependentOperation, bool requiredOperation})
    >;
typedef $$OfflineOutboxDependenciesTableCreateCompanionBuilder =
    OfflineOutboxDependenciesCompanion Function({
      required String operationId,
      required String dependencyId,
      Value<int> rowid,
    });
typedef $$OfflineOutboxDependenciesTableUpdateCompanionBuilder =
    OfflineOutboxDependenciesCompanion Function({
      Value<String> operationId,
      Value<String> dependencyId,
      Value<int> rowid,
    });

final class $$OfflineOutboxDependenciesTableReferences
    extends
        BaseReferences<
          _$OfflineDatabase,
          $OfflineOutboxDependenciesTable,
          OfflineOutboxDependency
        > {
  $$OfflineOutboxDependenciesTableReferences(
    super.$_db,
    super.$_table,
    super.$_typedResult,
  );

  static $OfflineOutboxOperationsTable _operationIdTable(
    _$OfflineDatabase db,
  ) => db.offlineOutboxOperations.createAlias(
    'outbox_dependencies__operation_id__outbox_operations__operation_id',
  );

  $$OfflineOutboxOperationsTableProcessedTableManager get operationId {
    final $_column = $_itemColumn<String>('operation_id')!;

    final manager = $$OfflineOutboxOperationsTableTableManager(
      $_db,
      $_db.offlineOutboxOperations,
    ).filter((f) => f.operationId.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_operationIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: [item]),
    );
  }

  static $OfflineOutboxOperationsTable _dependencyIdTable(
    _$OfflineDatabase db,
  ) => db.offlineOutboxOperations.createAlias(
    'outbox_dependencies__dependency_id__outbox_operations__operation_id',
  );

  $$OfflineOutboxOperationsTableProcessedTableManager get dependencyId {
    final $_column = $_itemColumn<String>('dependency_id')!;

    final manager = $$OfflineOutboxOperationsTableTableManager(
      $_db,
      $_db.offlineOutboxOperations,
    ).filter((f) => f.operationId.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_dependencyIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: [item]),
    );
  }
}

class $$OfflineOutboxDependenciesTableFilterComposer
    extends Composer<_$OfflineDatabase, $OfflineOutboxDependenciesTable> {
  $$OfflineOutboxDependenciesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  $$OfflineOutboxOperationsTableFilterComposer get operationId {
    final $$OfflineOutboxOperationsTableFilterComposer composer =
        $composerBuilder(
          composer: this,
          getCurrentColumn: (t) => t.operationId,
          referencedTable: $db.offlineOutboxOperations,
          getReferencedColumn: (t) => t.operationId,
          builder:
              (
                joinBuilder, {
                $addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer,
              }) => $$OfflineOutboxOperationsTableFilterComposer(
                $db: $db,
                $table: $db.offlineOutboxOperations,
                $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
                joinBuilder: joinBuilder,
                $removeJoinBuilderFromRootComposer:
                    $removeJoinBuilderFromRootComposer,
              ),
        );
    return composer;
  }

  $$OfflineOutboxOperationsTableFilterComposer get dependencyId {
    final $$OfflineOutboxOperationsTableFilterComposer composer =
        $composerBuilder(
          composer: this,
          getCurrentColumn: (t) => t.dependencyId,
          referencedTable: $db.offlineOutboxOperations,
          getReferencedColumn: (t) => t.operationId,
          builder:
              (
                joinBuilder, {
                $addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer,
              }) => $$OfflineOutboxOperationsTableFilterComposer(
                $db: $db,
                $table: $db.offlineOutboxOperations,
                $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
                joinBuilder: joinBuilder,
                $removeJoinBuilderFromRootComposer:
                    $removeJoinBuilderFromRootComposer,
              ),
        );
    return composer;
  }
}

class $$OfflineOutboxDependenciesTableOrderingComposer
    extends Composer<_$OfflineDatabase, $OfflineOutboxDependenciesTable> {
  $$OfflineOutboxDependenciesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  $$OfflineOutboxOperationsTableOrderingComposer get operationId {
    final $$OfflineOutboxOperationsTableOrderingComposer composer =
        $composerBuilder(
          composer: this,
          getCurrentColumn: (t) => t.operationId,
          referencedTable: $db.offlineOutboxOperations,
          getReferencedColumn: (t) => t.operationId,
          builder:
              (
                joinBuilder, {
                $addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer,
              }) => $$OfflineOutboxOperationsTableOrderingComposer(
                $db: $db,
                $table: $db.offlineOutboxOperations,
                $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
                joinBuilder: joinBuilder,
                $removeJoinBuilderFromRootComposer:
                    $removeJoinBuilderFromRootComposer,
              ),
        );
    return composer;
  }

  $$OfflineOutboxOperationsTableOrderingComposer get dependencyId {
    final $$OfflineOutboxOperationsTableOrderingComposer composer =
        $composerBuilder(
          composer: this,
          getCurrentColumn: (t) => t.dependencyId,
          referencedTable: $db.offlineOutboxOperations,
          getReferencedColumn: (t) => t.operationId,
          builder:
              (
                joinBuilder, {
                $addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer,
              }) => $$OfflineOutboxOperationsTableOrderingComposer(
                $db: $db,
                $table: $db.offlineOutboxOperations,
                $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
                joinBuilder: joinBuilder,
                $removeJoinBuilderFromRootComposer:
                    $removeJoinBuilderFromRootComposer,
              ),
        );
    return composer;
  }
}

class $$OfflineOutboxDependenciesTableAnnotationComposer
    extends Composer<_$OfflineDatabase, $OfflineOutboxDependenciesTable> {
  $$OfflineOutboxDependenciesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  $$OfflineOutboxOperationsTableAnnotationComposer get operationId {
    final $$OfflineOutboxOperationsTableAnnotationComposer composer =
        $composerBuilder(
          composer: this,
          getCurrentColumn: (t) => t.operationId,
          referencedTable: $db.offlineOutboxOperations,
          getReferencedColumn: (t) => t.operationId,
          builder:
              (
                joinBuilder, {
                $addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer,
              }) => $$OfflineOutboxOperationsTableAnnotationComposer(
                $db: $db,
                $table: $db.offlineOutboxOperations,
                $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
                joinBuilder: joinBuilder,
                $removeJoinBuilderFromRootComposer:
                    $removeJoinBuilderFromRootComposer,
              ),
        );
    return composer;
  }

  $$OfflineOutboxOperationsTableAnnotationComposer get dependencyId {
    final $$OfflineOutboxOperationsTableAnnotationComposer composer =
        $composerBuilder(
          composer: this,
          getCurrentColumn: (t) => t.dependencyId,
          referencedTable: $db.offlineOutboxOperations,
          getReferencedColumn: (t) => t.operationId,
          builder:
              (
                joinBuilder, {
                $addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer,
              }) => $$OfflineOutboxOperationsTableAnnotationComposer(
                $db: $db,
                $table: $db.offlineOutboxOperations,
                $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
                joinBuilder: joinBuilder,
                $removeJoinBuilderFromRootComposer:
                    $removeJoinBuilderFromRootComposer,
              ),
        );
    return composer;
  }
}

class $$OfflineOutboxDependenciesTableTableManager
    extends
        RootTableManager<
          _$OfflineDatabase,
          $OfflineOutboxDependenciesTable,
          OfflineOutboxDependency,
          $$OfflineOutboxDependenciesTableFilterComposer,
          $$OfflineOutboxDependenciesTableOrderingComposer,
          $$OfflineOutboxDependenciesTableAnnotationComposer,
          $$OfflineOutboxDependenciesTableCreateCompanionBuilder,
          $$OfflineOutboxDependenciesTableUpdateCompanionBuilder,
          (OfflineOutboxDependency, $$OfflineOutboxDependenciesTableReferences),
          OfflineOutboxDependency,
          PrefetchHooks Function({bool operationId, bool dependencyId})
        > {
  $$OfflineOutboxDependenciesTableTableManager(
    _$OfflineDatabase db,
    $OfflineOutboxDependenciesTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$OfflineOutboxDependenciesTableFilterComposer(
                $db: db,
                $table: table,
              ),
          createOrderingComposer: () =>
              $$OfflineOutboxDependenciesTableOrderingComposer(
                $db: db,
                $table: table,
              ),
          createComputedFieldComposer: () =>
              $$OfflineOutboxDependenciesTableAnnotationComposer(
                $db: db,
                $table: table,
              ),
          updateCompanionCallback:
              ({
                Value<String> operationId = const Value.absent(),
                Value<String> dependencyId = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => OfflineOutboxDependenciesCompanion(
                operationId: operationId,
                dependencyId: dependencyId,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String operationId,
                required String dependencyId,
                Value<int> rowid = const Value.absent(),
              }) => OfflineOutboxDependenciesCompanion.insert(
                operationId: operationId,
                dependencyId: dependencyId,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable(table),
                  $$OfflineOutboxDependenciesTableReferences(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: ({operationId = false, dependencyId = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [],
              addJoins:
                  <
                    T extends TableManagerState<
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic
                    >
                  >(state) {
                    if (operationId) {
                      state =
                          state.withJoin(
                                currentTable: table,
                                currentColumn: table.operationId,
                                referencedTable:
                                    $$OfflineOutboxDependenciesTableReferences
                                        ._operationIdTable(db),
                                referencedColumn:
                                    $$OfflineOutboxDependenciesTableReferences
                                        ._operationIdTable(db)
                                        .operationId,
                              )
                              as T;
                    }
                    if (dependencyId) {
                      state =
                          state.withJoin(
                                currentTable: table,
                                currentColumn: table.dependencyId,
                                referencedTable:
                                    $$OfflineOutboxDependenciesTableReferences
                                        ._dependencyIdTable(db),
                                referencedColumn:
                                    $$OfflineOutboxDependenciesTableReferences
                                        ._dependencyIdTable(db)
                                        .operationId,
                              )
                              as T;
                    }

                    return state;
                  },
              getPrefetchedDataCallback: (items) async {
                return [];
              },
            );
          },
        ),
      );
}

typedef $$OfflineOutboxDependenciesTableProcessedTableManager =
    ProcessedTableManager<
      _$OfflineDatabase,
      $OfflineOutboxDependenciesTable,
      OfflineOutboxDependency,
      $$OfflineOutboxDependenciesTableFilterComposer,
      $$OfflineOutboxDependenciesTableOrderingComposer,
      $$OfflineOutboxDependenciesTableAnnotationComposer,
      $$OfflineOutboxDependenciesTableCreateCompanionBuilder,
      $$OfflineOutboxDependenciesTableUpdateCompanionBuilder,
      (OfflineOutboxDependency, $$OfflineOutboxDependenciesTableReferences),
      OfflineOutboxDependency,
      PrefetchHooks Function({bool operationId, bool dependencyId})
    >;

class $OfflineDatabaseManager {
  final _$OfflineDatabase _db;
  $OfflineDatabaseManager(this._db);
  $$OfflineCacheEntriesTableTableManager get offlineCacheEntries =>
      $$OfflineCacheEntriesTableTableManager(_db, _db.offlineCacheEntries);
  $$OfflineDocumentDraftsTableTableManager get offlineDocumentDrafts =>
      $$OfflineDocumentDraftsTableTableManager(_db, _db.offlineDocumentDrafts);
  $$OfflineOutboxOperationsTableTableManager get offlineOutboxOperations =>
      $$OfflineOutboxOperationsTableTableManager(
        _db,
        _db.offlineOutboxOperations,
      );
  $$OfflineOutboxDependenciesTableTableManager get offlineOutboxDependencies =>
      $$OfflineOutboxDependenciesTableTableManager(
        _db,
        _db.offlineOutboxDependencies,
      );
}
