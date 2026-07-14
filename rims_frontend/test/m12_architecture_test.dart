import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const _classificationPath = '../docs/security/data-classification.md';
const _executionRecordPath =
    '../docs/superpowers/plans/2026-07-10-rims-m12-execution-record.md';
const _externalChecklistPath = '../docs/security/external-launch-checklist.md';
const _pubspecLockPath = 'pubspec.lock';
const _mainAndroidManifestPath = 'android/app/src/main/AndroidManifest.xml';
const _androidBuildPath = 'build/app/intermediates';

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

const _allowedAndroidPermissions = <String>{
  'android.permission.INTERNET',
  'android.permission.ACCESS_NETWORK_STATE',
  'android.permission.CAMERA',
  'com.example.rims_frontend.DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION',
};

const _mainManifestPermissions = <String>{
  'android.permission.INTERNET',
  'android.permission.CAMERA',
};

const _providerIds = <String>{
  'provider.backend_api',
  'provider.postgresql',
  'provider.android_os',
  'provider.device_storage',
  'provider.app_store',
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
  test(
    'checked subprocess times out and terminates within a bound',
    () async {
      final directory = Directory.systemTemp.createTempSync(
        'rims-m12-timeout-child-',
      );
      final script = File('${directory.path}/sleep.dart')
        ..writeAsStringSync('''
import 'dart:async';

Future<void> main() => Future<void>.delayed(const Duration(seconds: 30));
''');
      addTearDown(() => directory.deleteSync(recursive: true));
      final stopwatch = Stopwatch()..start();

      await expectLater(
        _runCheckedProcess(_dartExecutableForFixture(), [
          script.path,
        ], timeout: const Duration(milliseconds: 200)),
        throwsA(isA<TimeoutException>()),
      );
      stopwatch.stop();
      expect(stopwatch.elapsed, lessThan(const Duration(seconds: 5)));
    },
    timeout: const Timeout(Duration(seconds: 10)),
  );

  test('source permission union is not accepted as merged evidence', () {
    const appManifest = '''
<manifest xmlns:android="http://schemas.android.com/apk/res/android"
    xmlns:tools="http://schemas.android.com/tools">
  <uses-permission
      android:name="android.permission.POST_NOTIFICATIONS"
      tools:node="remove" />
</manifest>
''';
    const pluginManifest = '''
<manifest xmlns:android="http://schemas.android.com/apk/res/android">
  <uses-permission android:name="android.permission.POST_NOTIFICATIONS" />
</manifest>
''';
    const mergedManifest = '''
<manifest xmlns:android="http://schemas.android.com/apk/res/android" />
''';
    final sourceUnion = _permissionsFromManifestDocuments([
      appManifest,
      pluginManifest,
    ]);
    final mergedPermissions = _permissionsFromManifestDocuments([
      mergedManifest,
    ]);

    expect(sourceUnion, contains('android.permission.POST_NOTIFICATIONS'));
    expect(mergedPermissions, isNot(sourceUnion));
    expect(
      mergedPermissions,
      isNot(contains('android.permission.POST_NOTIFICATIONS')),
    );
  });

  test('missing release merged manifest is an acceptance failure', () {
    final directory = Directory.systemTemp.createTempSync(
      'rims-m12-missing-manifest-',
    );
    addTearDown(() => directory.deleteSync(recursive: true));

    expect(() => _locateSingleReleaseMainManifest(directory), throwsStateError);
  });

  test('markdown table parsing does not accept rows from another section', () {
    const document = '''
## Expected

| ID | Value |
| --- | --- |
| `fixture.expected` | present |

## Other

| ID | Value |
| --- | --- |
| `fixture.moved` | misplaced |
''';

    final table = _parseMarkdownTable(
      document,
      sectionTitle: 'Expected',
      expectedHeaders: const ['ID', 'Value'],
    );

    expect(_rowsById(table).keys, {'fixture.expected'});
  });

  test('markdown table parsing rejects an unescaped extra pipe', () {
    const document = '''
## Expected

| ID | Value |
| --- | --- |
| `fixture.row` | malformed | value |
''';

    expect(
      () => _parseMarkdownTable(
        document,
        sectionTitle: 'Expected',
        expectedHeaders: const ['ID', 'Value'],
      ),
      throwsFormatException,
    );
  });

  test('data classes declare complete stable governance rows', () {
    final document = _readRequiredFile(_classificationPath);
    final rows = _rowsById(
      _parseMarkdownTable(
        document,
        sectionTitle: 'Stable Data Class Inventory',
        expectedHeaders: const [
          'ID',
          'Data',
          'Owner scope',
          'Encryption',
          'Backup',
          'Retention',
          'Clear trigger',
          'Export eligibility',
          'Redaction',
          'Financial/cost permission boundary',
        ],
      ),
    );

    expect(rows.keys.toSet(), _dataClassIds);
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

  test(
    'security boundary inventories use stable environment and provider IDs',
    () async {
      final document = _readRequiredFile(_classificationPath);
      final environments = _rowsById(
        _parseMarkdownTable(
          document,
          sectionTitle: 'Environment Profiles',
          expectedHeaders: const [
            'ID',
            'Canonical value',
            'Transport rule',
            'Data and fixtures',
            'Secret rule',
            'Permitted use',
          ],
        ),
      );
      final permissions = _rowsById(
        _parseMarkdownTable(
          document,
          sectionTitle: 'Android Runtime Permissions',
          expectedHeaders: const [
            'ID',
            'Protection level',
            'Purpose and data',
            'Request timing',
            'Denial behavior',
            'Environment',
          ],
        ),
      );
      final providers = _rowsById(
        _parseMarkdownTable(
          document,
          sectionTitle: 'Provider And Data Flow Inventory',
          expectedHeaders: const [
            'ID',
            'Owner/provider category',
            'Data purpose',
            'Data classes',
            'Environments',
            'Credential and external boundary',
          ],
        ),
      );
      final sdks = _rowsById(
        _parseMarkdownTable(
          document,
          sectionTitle: 'Runtime SDK And License Baseline',
          expectedHeaders: const [
            'ID',
            'Package',
            'Component',
            'License',
            'Purpose',
            'Data handled',
            'Network/provider behavior',
          ],
        ),
      );
      final directPackages = _directRuntimePackages(
        _readRequiredFile(_pubspecLockPath),
      );
      final expectedSdkIds = directPackages.keys.map(_sdkIdForPackage).toSet();
      final mainPermissions = _permissionsFromManifestDocuments([
        _readRequiredFile(_mainAndroidManifestPath),
      ]);
      final generatedManifest = await _generateReleaseMainMergedManifest();
      final effectivePermissions = _permissionsFromManifestDocuments([
        generatedManifest.file.readAsStringSync(),
      ]);
      // ignore: avoid_print
      print(
        'Generated release merged manifest in '
        '${generatedManifest.duration.inMilliseconds} ms: '
        '${generatedManifest.file.path}',
      );

      _expectIds(environments, _environmentIds);
      expect(mainPermissions, _mainManifestPermissions);
      expect(effectivePermissions, _allowedAndroidPermissions);
      _expectIds(permissions, effectivePermissions);
      _expectIds(providers, _providerIds);
      _expectIds(sdks, expectedSdkIds);
      expect(
        sdks.values.map((row) => row[1]).toSet(),
        directPackages.keys.toSet(),
      );
      for (final package in directPackages.keys) {
        final row = sdks[_sdkIdForPackage(package)]!;
        expect(row[1], package);
        if (package != 'flutter') {
          expect(
            row[2],
            contains(directPackages[package]),
            reason: '$package must document its locked runtime version.',
          );
        }
      }
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test('financial fields require explicit read and write capabilities', () {
    final document = _readRequiredFile(_classificationPath);
    final rows = _rowsById(
      _parseMarkdownTable(
        document,
        sectionTitle: 'Financial And Cost Field Policy',
        expectedHeaders: const [
          'ID',
          'Fields',
          'Read requirement',
          'Write requirement',
          'Cache/export rule',
          'Authority',
        ],
      ),
    );

    _expectIds(rows, _financialFieldIds);
    for (final id in _financialFieldIds) {
      final cells = rows[id]!.join(' ');
      expect(cells, contains('financial:read'), reason: '$id read boundary');
      expect(cells, contains('financial:write'), reason: '$id write boundary');
      expect(cells, contains('server enforced'), reason: '$id authority');
    }
  });

  test(
    'execution record pins observed baselines without planned PASS claims',
    () {
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
      _validatePlannedControlRegister(document);
    },
  );

  test('planned control register rejects every non-planned status', () {
    final document = _readRequiredFile(_executionRecordPath);
    final malformed = document.replaceFirst(
      'PLANNED - NOT YET EVIDENCE',
      'BLOCKED',
      document.indexOf('## Planned M12 Control Register'),
    );

    expect(() => _validatePlannedControlRegister(document), returnsNormally);
    expect(
      () => _validatePlannedControlRegister(malformed),
      throwsFormatException,
    );
  });

  test('execution record distinguishes declared and merged permissions', () {
    final document = _readRequiredFile(_executionRecordPath);
    final table = _parseMarkdownTable(
      document,
      sectionTitle: 'Observed Pre-M12 Android Surface',
      expectedHeaders: const [
        'Boundary',
        'Observed base behavior',
        'M12 disposition',
      ],
    );
    final runtimePermissions = table.rows.singleWhere(
      (row) => row.first == 'Runtime permissions',
    );

    final behavior = runtimePermissions[1].toLowerCase();
    expect(behavior, contains('main manifest'));
    expect(behavior, contains('effective merged permissions'));
    expect(behavior, contains('processreleasemainmanifest'));
    for (final permission in _allowedAndroidPermissions) {
      expect(runtimePermissions[1], contains(permission));
    }
  });

  test('external launch actions stay open and name evidence owners', () {
    final document = _readRequiredFile(_externalChecklistPath);
    final rows = _rowsById(
      _parseMarkdownTable(
        document,
        sectionTitle: 'RIMS External Launch Checklist',
        expectedHeaders: const [
          'ID',
          'Launch action',
          'Owner',
          'Required evidence',
          'Local substitute',
          'Status',
        ],
      ),
    );

    _expectIds(rows, _externalApprovalIds);
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

Future<({File file, Duration duration})>
_generateReleaseMainMergedManifest() async {
  final buildDirectory = Directory(_androidBuildPath);
  _deleteReleaseMainManifestOutputs(buildDirectory);

  final javaHome = await _flutterAndroidJavaHome();
  final stopwatch = Stopwatch()..start();
  await _runCheckedProcess(
    Platform.isWindows ? 'gradlew.bat' : './gradlew',
    const [':app:processReleaseMainManifest', '--no-daemon', '--console=plain'],
    workingDirectory: Directory('android').absolute.path,
    environment: {...Platform.environment, 'JAVA_HOME': javaHome},
    runInShell: Platform.isWindows,
    timeout: const Duration(minutes: 2),
  );
  stopwatch.stop();

  return (
    file: _locateSingleReleaseMainManifest(buildDirectory),
    duration: stopwatch.elapsed,
  );
}

Future<String> _flutterAndroidJavaHome() async {
  final override = Platform.environment['RIMS_ANDROID_JAVA_HOME'];
  if (override != null && override.trim().isNotEmpty) {
    return _validatedJavaHome(override.trim());
  }

  final result = await _runCheckedProcess(
    'flutter',
    const ['doctor', '-v'],
    runInShell: Platform.isWindows,
    timeout: const Duration(seconds: 20),
  );
  final output = '${result.stdout}\n${result.stderr}';
  final match = RegExp(r'Java binary at:\s*(.+)').firstMatch(output);
  if (match == null) {
    throw StateError('Flutter doctor did not report an Android Java binary.');
  }
  var javaBinary = File(match.group(1)!.trim());
  if (Platform.isWindows && !javaBinary.existsSync()) {
    javaBinary = File('${javaBinary.path}.exe');
  }
  if (!javaBinary.existsSync()) {
    throw StateError('Flutter Android Java binary does not exist: $javaBinary');
  }
  return _validatedJavaHome(javaBinary.parent.parent.path);
}

Future<({String stdout, String stderr})> _runCheckedProcess(
  String executable,
  List<String> arguments, {
  required Duration timeout,
  String? workingDirectory,
  Map<String, String>? environment,
  bool runInShell = false,
}) async {
  final stopwatch = Stopwatch()..start();
  final process = await Process.start(
    executable,
    arguments,
    workingDirectory: workingDirectory,
    environment: environment,
    runInShell: runInShell,
  ).timeout(const Duration(seconds: 10));
  stderr.writeln(
    '[m12-process] start pid=${process.pid} timeout=${timeout.inMilliseconds}ms '
    'command=$executable ${arguments.join(' ')}',
  );

  final stdoutBuffer = StringBuffer();
  final stderrBuffer = StringBuffer();
  final stdoutDone = Completer<void>();
  final stderrDone = Completer<void>();
  final stdoutSubscription = process.stdout
      .transform(utf8.decoder)
      .listen(
        stdoutBuffer.write,
        onError: stdoutDone.completeError,
        onDone: stdoutDone.complete,
      );
  final stderrSubscription = process.stderr
      .transform(utf8.decoder)
      .listen(
        stderrBuffer.write,
        onError: stderrDone.completeError,
        onDone: stderrDone.complete,
      );

  int exitCode;
  try {
    exitCode = await process.exitCode.timeout(timeout);
  } on TimeoutException {
    stderr.writeln(
      '[m12-process] timeout pid=${process.pid} after '
      '${stopwatch.elapsedMilliseconds}ms',
    );
    await _terminateProcessTree(process);
    await _settleProcessIo(
      process,
      stdoutDone.future,
      stderrDone.future,
      stdoutSubscription,
      stderrSubscription,
    );
    throw TimeoutException(
      'Timed out after ${timeout.inMilliseconds} ms: '
      '$executable ${arguments.join(' ')}',
      timeout,
    );
  }

  try {
    await Future.wait([
      stdoutDone.future,
      stderrDone.future,
    ]).timeout(const Duration(seconds: 5));
  } on TimeoutException {
    await _terminateProcessTree(process);
    await _settleProcessIo(
      process,
      stdoutDone.future,
      stderrDone.future,
      stdoutSubscription,
      stderrSubscription,
    );
    throw TimeoutException(
      'Process exited but output pipes did not close: '
      '$executable ${arguments.join(' ')}',
      const Duration(seconds: 5),
    );
  }
  stopwatch.stop();
  stderr.writeln(
    '[m12-process] exit pid=${process.pid} code=$exitCode '
    'duration=${stopwatch.elapsedMilliseconds}ms',
  );
  final stdout = stdoutBuffer.toString();
  final processStderr = stderrBuffer.toString();
  if (exitCode != 0) {
    throw ProcessException(
      executable,
      arguments,
      '$stdout\n$processStderr',
      exitCode,
    );
  }
  return (stdout: stdout, stderr: processStderr);
}

String _dartExecutableForFixture() {
  final executableName = Platform.isWindows ? 'dart.exe' : 'dart';
  var directory = File(Platform.resolvedExecutable).absolute.parent;
  for (var depth = 0; depth < 8; depth++) {
    final candidate = File.fromUri(
      directory.uri.resolve('bin/cache/dart-sdk/bin/$executableName'),
    );
    if (candidate.existsSync()) return candidate.path;
    if (directory.parent.path == directory.path) break;
    directory = directory.parent;
  }
  throw StateError(
    'Could not locate Flutter cached Dart from '
    '${Platform.resolvedExecutable}.',
  );
}

Future<void> _terminateProcessTree(Process process) async {
  if (Platform.isWindows) {
    final killer = await Process.start('taskkill.exe', [
      '/PID',
      '${process.pid}',
      '/T',
      '/F',
    ]).timeout(const Duration(seconds: 2));
    await Future.wait<void>([
      killer.stdout.drain<void>(),
      killer.stderr.drain<void>(),
      killer.exitCode.then<void>((_) {}),
    ]).timeout(const Duration(seconds: 3));
  } else {
    process.kill(ProcessSignal.sigkill);
  }
  process.kill(ProcessSignal.sigkill);
}

Future<void> _settleProcessIo(
  Process process,
  Future<void> stdoutDone,
  Future<void> stderrDone,
  StreamSubscription<String> stdoutSubscription,
  StreamSubscription<String> stderrSubscription,
) async {
  try {
    await Future.wait<void>([
      process.exitCode.then<void>((_) {}),
      stdoutDone,
      stderrDone,
    ]).timeout(const Duration(seconds: 2));
  } on TimeoutException {
    process.kill(ProcessSignal.sigkill);
  }
  try {
    await Future.wait<void>([
      stdoutSubscription.cancel(),
      stderrSubscription.cancel(),
    ]).timeout(const Duration(seconds: 2));
  } on TimeoutException {
    // The outer test timeout remains the final guard if the runtime cannot
    // cancel a broken stream subscription.
  }
}

String _validatedJavaHome(String path) {
  final executable = File(
    '$path${Platform.pathSeparator}bin${Platform.pathSeparator}'
    '${Platform.isWindows ? 'java.exe' : 'java'}',
  );
  if (!executable.existsSync()) {
    throw StateError('Android JAVA_HOME has no Java executable: $path');
  }
  return Directory(path).absolute.path;
}

void _deleteReleaseMainManifestOutputs(Directory buildDirectory) {
  if (!buildDirectory.existsSync()) return;
  final directories =
      buildDirectory
          .listSync(recursive: true, followLinks: false)
          .whereType<Directory>()
          .where((directory) {
            final segments = _pathSegments(directory.path);
            return segments.isNotEmpty &&
                segments.last == 'processReleaseMainManifest' &&
                segments.contains('release') &&
                segments.any(
                  (segment) =>
                      segment == 'merged_manifest' ||
                      segment == 'merged_manifests',
                );
          })
          .toList()
        ..sort((left, right) => right.path.length.compareTo(left.path.length));
  for (final directory in directories) {
    if (directory.existsSync()) directory.deleteSync(recursive: true);
  }
}

File _locateSingleReleaseMainManifest(Directory buildDirectory) {
  if (!buildDirectory.existsSync()) {
    throw StateError(
      'Release merged-manifest build directory is missing: '
      '${buildDirectory.path}',
    );
  }
  final manifests = buildDirectory
      .listSync(recursive: true, followLinks: false)
      .whereType<File>()
      .where((file) {
        final segments = _pathSegments(file.path);
        return segments.isNotEmpty &&
            segments.last == 'AndroidManifest.xml' &&
            segments.contains('release') &&
            segments.contains('processReleaseMainManifest') &&
            segments.any(
              (segment) =>
                  segment == 'merged_manifest' || segment == 'merged_manifests',
            );
      })
      .toList(growable: false);
  if (manifests.length != 1) {
    throw StateError(
      'Expected exactly one release main merged manifest under '
      '${buildDirectory.path}, found ${manifests.length}: '
      '${manifests.map((file) => file.path).join(', ')}',
    );
  }
  return manifests.single;
}

List<String> _pathSegments(String path) => path
    .replaceAll('\\', '/')
    .split('/')
    .where((segment) => segment.isNotEmpty)
    .toList(growable: false);

Set<String> _permissionsFromManifestDocuments(Iterable<String> manifests) {
  final permissions = <String>{};
  final tagPattern = RegExp(
    r'<uses-permission(?:-sdk-\d+)?\b[^>]*>',
    multiLine: true,
  );
  final namePattern = RegExp(r'''android:name\s*=\s*["']([^"']+)["']''');
  for (final manifest in manifests) {
    for (final tag in tagPattern.allMatches(manifest)) {
      final name = namePattern.firstMatch(tag.group(0)!)?.group(1);
      if (name == null || name.isEmpty) {
        throw FormatException('Permission tag has no android:name: ${tag[0]}');
      }
      permissions.add(name);
    }
  }
  return permissions;
}

Map<String, String> _directRuntimePackages(String lockDocument) {
  final packages = <String, String>{};
  String? package;
  var isDirectRuntime = false;
  String? version;

  void finishPackage() {
    if (package != null && isDirectRuntime) {
      if (version == null) {
        throw FormatException(
          'Direct runtime package "$package" has no version.',
        );
      }
      packages[package] = version;
    }
  }

  for (final line in lockDocument.split(RegExp(r'\r?\n'))) {
    final packageMatch = RegExp(r'^  ([A-Za-z0-9_]+):$').firstMatch(line);
    if (packageMatch != null) {
      finishPackage();
      package = packageMatch.group(1)!;
      isDirectRuntime = false;
      version = null;
      continue;
    }
    if (package == null) continue;
    final dependencyMatch = RegExp(
      r'^    dependency: "?([^"\r\n]+)"?$',
    ).firstMatch(line);
    if (dependencyMatch != null) {
      isDirectRuntime = dependencyMatch.group(1) == 'direct main';
      continue;
    }
    final versionMatch = RegExp(r'^    version: "([^"]+)"$').firstMatch(line);
    if (versionMatch != null) version = versionMatch.group(1)!;
  }
  finishPackage();
  if (packages.isEmpty) {
    throw const FormatException('No direct runtime packages in pubspec.lock.');
  }
  return packages;
}

String _sdkIdForPackage(String package) =>
    package == 'drift' ? 'sdk.drift_sqlite3mc' : 'sdk.$package';

void _validatePlannedControlRegister(String document) {
  final table = _parseMarkdownTable(
    document,
    sectionTitle: 'Planned M12 Control Register',
    expectedHeaders: const [
      'Planned M12 control',
      'Required future evidence',
      'Status',
    ],
  );
  for (final row in table.rows) {
    if (row.last != 'PLANNED - NOT YET EVIDENCE') {
      throw FormatException(
        'Planned control "${row.first}" has invalid status "${row.last}".',
      );
    }
  }
}

final class _MarkdownTable {
  const _MarkdownTable(this.headers, this.rows);

  final List<String> headers;
  final List<List<String>> rows;
}

_MarkdownTable _parseMarkdownTable(
  String document, {
  required String sectionTitle,
  required List<String> expectedHeaders,
}) {
  final lines = document.split(RegExp(r'\r?\n'));
  final headings = <({int index, int level})>[];
  final headingPattern = RegExp(
    '^(#{1,6})\\s+${RegExp.escape(sectionTitle)}\\s*\$',
  );
  for (var index = 0; index < lines.length; index++) {
    final match = headingPattern.firstMatch(lines[index].trim());
    if (match != null) {
      headings.add((index: index, level: match.group(1)!.length));
    }
  }
  if (headings.length != 1) {
    throw FormatException(
      'Expected one "$sectionTitle" section, found ${headings.length}.',
    );
  }

  final heading = headings.single;
  var sectionEnd = lines.length;
  final anyHeadingPattern = RegExp(r'^(#{1,6})\s+');
  for (var index = heading.index + 1; index < lines.length; index++) {
    final match = anyHeadingPattern.firstMatch(lines[index].trim());
    if (match != null && match.group(1)!.length <= heading.level) {
      sectionEnd = index;
      break;
    }
  }

  final tableGroups = <List<String>>[];
  List<String>? currentGroup;
  for (var index = heading.index + 1; index < sectionEnd; index++) {
    final line = lines[index].trim();
    if (line.startsWith('|')) {
      currentGroup ??= <String>[];
      currentGroup.add(line);
    } else if (currentGroup != null) {
      tableGroups.add(currentGroup);
      currentGroup = null;
    }
  }
  if (currentGroup != null) tableGroups.add(currentGroup);
  if (tableGroups.length != 1) {
    throw FormatException(
      'Expected one table in "$sectionTitle", found ${tableGroups.length}.',
    );
  }

  final rawRows = tableGroups.single.map(_splitMarkdownRow).toList();
  if (rawRows.length < 3) {
    throw FormatException('Table in "$sectionTitle" has no data rows.');
  }
  final headers = rawRows.first;
  if (!_listsEqual(headers, expectedHeaders)) {
    throw FormatException(
      'Unexpected headers in "$sectionTitle": ${headers.join(', ')}.',
    );
  }
  final separators = rawRows[1];
  if (separators.length != headers.length ||
      separators.any((cell) => !RegExp(r'^:?-{3,}:?$').hasMatch(cell))) {
    throw FormatException('Malformed separator row in "$sectionTitle".');
  }

  final rows = <List<String>>[];
  for (final row in rawRows.skip(2)) {
    if (row.length != headers.length) {
      throw FormatException(
        'Expected ${headers.length} cells in "$sectionTitle", '
        'found ${row.length}: ${row.join(' | ')}.',
      );
    }
    rows.add(
      row.map((cell) => cell.replaceAll('`', '')).toList(growable: false),
    );
  }
  return _MarkdownTable(headers, rows);
}

List<String> _splitMarkdownRow(String line) {
  if (!line.startsWith('|') || !line.endsWith('|')) {
    throw FormatException('Malformed Markdown row: $line');
  }
  final cells = <String>[];
  final cell = StringBuffer();
  final body = line.substring(1, line.length - 1);
  for (var index = 0; index < body.length; index++) {
    final character = body[index];
    if (character == '\\' && index + 1 < body.length) {
      final escaped = body[index + 1];
      if (escaped == '|' || escaped == '\\') {
        cell.write(escaped);
        index++;
        continue;
      }
    }
    if (character == '|') {
      cells.add(cell.toString().trim());
      cell.clear();
    } else {
      cell.write(character);
    }
  }
  cells.add(cell.toString().trim());
  return cells;
}

bool _listsEqual(List<String> left, List<String> right) {
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index++) {
    if (left[index] != right[index]) return false;
  }
  return true;
}

Map<String, List<String>> _rowsById(_MarkdownTable table) {
  final rows = <String, List<String>>{};
  for (final row in table.rows) {
    final id = row.first;
    if (!RegExp(r'^[a-z][A-Za-z0-9_.-]+$').hasMatch(id)) {
      throw FormatException('Invalid stable ID "$id".');
    }
    if (rows.containsKey(id)) {
      throw FormatException('Duplicate stable ID "$id".');
    }
    rows[id] = row;
  }
  return rows;
}

void _expectIds(Map<String, List<String>> rows, Set<String> expectedIds) {
  expect(rows.keys.toSet(), expectedIds);
  for (final id in expectedIds) {
    final row = rows[id]!;
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
