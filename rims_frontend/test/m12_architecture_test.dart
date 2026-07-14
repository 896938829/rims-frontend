import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const _classificationPath = '../docs/security/data-classification.md';
const _executionRecordPath =
    '../docs/superpowers/plans/2026-07-10-rims-m12-execution-record.md';
const _externalChecklistPath =
    '../docs/security/external-launch-checklist.md';

const _dataClassIds = <String>{
  'credential.access',
  'credential.refresh',
  'credential.totp',
  'identity.profile',
  'cache.reference',
  'cache.inventory',
  'cache.document',
  'cache.report',
  'draft.document',
  'outbox.operation',
  'attachment.staged',
  'attachment.server',
  'scan.session',
  'log.runtime',
  'audit.server',
  'export.account',
  'evidence.test',
};

const _environmentIds = <String>{
  'environment.development',
  'environment.test',
  'environment.staging',
  'environment.production',
};

const _androidPermissionIds = <String>{
  'android.permission.INTERNET',
  'android.permission.ACCESS_NETWORK_STATE',
  'android.permission.CAMERA',
};

const _providerIds = <String>{
  'provider.backend_api',
  'provider.postgresql',
  'provider.android_os',
  'provider.device_storage',
  'provider.app_store',
};

const _sdkIds = <String>{
  'sdk.flutter',
  'sdk.dio',
  'sdk.flutter_secure_storage',
  'sdk.drift_sqlite3mc',
  'sdk.mobile_scanner',
  'sdk.image_picker',
  'sdk.file_picker',
  'sdk.share_plus',
  'sdk.connectivity_plus',
  'sdk.crypto',
  'sdk.drift_flutter',
  'sdk.fl_chart',
  'sdk.go_router',
  'sdk.intl',
  'sdk.json_annotation',
  'sdk.path_provider',
  'sdk.provider',
  'sdk.shared_preferences',
  'sdk.uuid',
};

const _financialFieldIds = <String>{
  'field.product.cost_price',
  'field.document.cost_price',
  'field.report.cost_amount',
  'field.report.gross_profit',
  'field.inventory.total_value',
};

const _externalApprovalIds = <String>{
  'external.dns_tls',
  'external.secret_custody',
  'external.database_tls_backup',
  'external.legal_privacy',
  'external.penetration_test',
  'external.android_release',
  'external.incident_response',
  'external.rollout_approval',
};

void main() {
  test('data classes declare complete stable governance rows', () {
    final document = _readRequiredFile(_classificationPath);
    final rows = _markdownRowsById(document);

    expect(rows.keys.toSet().intersection(_dataClassIds), _dataClassIds);
    for (final id in _dataClassIds) {
      final row = rows[id]!;
      expect(
        row,
        hasLength(10),
        reason:
            '$id must declare ID, data, owner scope, encryption, backup, '
            'retention, clear trigger, export eligibility, redaction, and '
            'financial/cost permission boundary.',
      );
      _expectConcreteCells(id, row.skip(1));
      expect(
        row.last.toLowerCase(),
        anyOf(contains('financial:'), contains('no financial or cost data')),
        reason: '$id must explicitly declare its financial/cost boundary.',
      );
    }
  });

  test('security boundary inventories use stable environment and provider IDs', () {
    final document = _readRequiredFile(_classificationPath);
    final rows = _markdownRowsById(document);

    _expectIds(rows, _environmentIds, minimumColumns: 6);
    _expectIds(rows, _androidPermissionIds, minimumColumns: 6);
    _expectIds(rows, _providerIds, minimumColumns: 6);
    _expectIds(rows, _sdkIds, minimumColumns: 6);
  });

  test('financial fields require explicit read and write capabilities', () {
    final document = _readRequiredFile(_classificationPath);
    final rows = _markdownRowsById(document);

    _expectIds(rows, _financialFieldIds, minimumColumns: 6);
    for (final id in _financialFieldIds) {
      final cells = rows[id]!.join(' ');
      expect(cells, contains('financial:read'), reason: '$id read boundary');
      expect(cells, contains('financial:write'), reason: '$id write boundary');
      expect(cells, contains('server enforced'), reason: '$id authority');
    }
  });

  test('execution record pins observed baselines without planned PASS claims', () {
    final document = _readRequiredFile(_executionRecordPath);

    expect(document, contains('Status: IN PROGRESS'));
    expect(document, contains('2bc1287290f8e09c8b0a4fed8bbfaa7ebb45ded5'));
    expect(document, contains('5ba6e1f68927e5bdab1e9dd2b42abaeb9a16b763'));
    expect(document, contains('Flutter 3.44.1'));
    expect(document, contains('Dart 3.12.1'));
    expect(document, contains('Go 1.25.0'));
    expect(document, contains('No managed backend state exists'));
    expect(document, contains('port 8080 is not listening'));
    expect(document, contains('No Android device or emulator attached'));
    expect(document, contains('M11 inherited encrypted storage'));
    expect(document, contains('Drift/sqlite3mc'));
    expect(document, contains('M11 inherited offline behavior'));
    expect(document, contains('explicit foreground confirmation'));
    expect(document, contains('PLANNED - NOT YET EVIDENCE'));
    expect(
      RegExp(r'\|[^\n]*planned[^\n]*\|\s*PASS(?:\s*:[^|]*)?\s*\|',
              caseSensitive: false)
          .hasMatch(document),
      isFalse,
      reason: 'A planned control cannot be represented as PASS evidence.',
    );
  });

  test('external launch actions stay open and name evidence owners', () {
    final document = _readRequiredFile(_externalChecklistPath);
    final rows = _markdownRowsById(document);

    _expectIds(rows, _externalApprovalIds, minimumColumns: 6);
    for (final id in _externalApprovalIds) {
      final row = rows[id]!;
      expect(row, hasLength(6));
      _expectConcreteCells(id, row.skip(1).take(4));
      expect(row.last, 'OPEN EXTERNAL', reason: '$id must remain external');
    }
  });
}

String _readRequiredFile(String path) {
  final file = File(path);
  if (!file.existsSync()) {
    fail('Missing required M12 record: $path');
  }
  return file.readAsStringSync();
}

Map<String, List<String>> _markdownRowsById(String document) {
  final rows = <String, List<String>>{};
  for (final line in document.split(RegExp(r'\r?\n'))) {
    final trimmed = line.trim();
    if (!trimmed.startsWith('|') || !trimmed.endsWith('|')) continue;
    final cells = trimmed
        .substring(1, trimmed.length - 1)
        .split('|')
        .map((cell) => cell.trim().replaceAll('`', ''))
        .toList(growable: false);
    if (cells.isEmpty || !RegExp(r'^[a-z][A-Za-z0-9_.-]+$').hasMatch(cells[0])) {
      continue;
    }
    expect(rows.containsKey(cells[0]), isFalse, reason: 'Duplicate ${cells[0]}');
    rows[cells[0]] = cells;
  }
  return rows;
}

void _expectIds(
  Map<String, List<String>> rows,
  Set<String> expectedIds, {
  required int minimumColumns,
}) {
  expect(rows.keys.toSet().intersection(expectedIds), expectedIds);
  for (final id in expectedIds) {
    final row = rows[id]!;
    expect(row.length, greaterThanOrEqualTo(minimumColumns), reason: id);
    _expectConcreteCells(id, row.skip(1));
  }
}

void _expectConcreteCells(String id, Iterable<String> cells) {
  for (final cell in cells) {
    expect(cell, isNotEmpty, reason: '$id contains an empty field');
    expect(
      RegExp(r'\b(TBD|TODO|UNKNOWN)\b', caseSensitive: false).hasMatch(cell),
      isFalse,
      reason: '$id contains a placeholder: $cell',
    );
  }
}
