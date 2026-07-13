import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:rims_frontend/features/offline/data/database/offline_database_factory.dart';
import 'package:rims_frontend/features/offline/domain/entities/cache_snapshot.dart';

void main() {
  test('factory creates and reuses one 256 bit secure storage key', () async {
    String? stored;
    var writes = 0;
    final factory = OfflineDatabaseFactory(
      readKey: () async => stored,
      writeKey: (value) async {
        stored = value;
        writes += 1;
      },
      randomBytes: () => List<int>.generate(32, (index) => index),
    );

    final first = await factory.loadOrCreateKey();
    final second = await factory.loadOrCreateKey();

    expect(first, hasLength(64));
    expect(first, matches(RegExp(r'^[0-9a-f]{64}$')));
    expect(second, first);
    expect(writes, 1);
  });

  test(
    'native database is encrypted and reopens with the stored key',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'rims-offline-db-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final path = '${directory.path}${Platform.pathSeparator}offline.sqlite';
      String? stored;
      final factory = OfflineDatabaseFactory(
        readKey: () async => stored,
        writeKey: (value) async => stored = value,
        randomBytes: () => List<int>.filled(32, 7),
      );
      final fetchedAt = DateTime.utc(2026, 7, 13);
      const key = CacheKey(
        accountId: '7',
        namespace: 'session',
        entityKey: 'me',
      );

      final database = await factory.openNative(path);
      await database.writeCache(
        CacheRecord(
          key: key,
          payload: const {'id': 7},
          schemaVersion: 1,
          fetchedAt: fetchedAt,
          expiresAt: fetchedAt.add(const Duration(hours: 1)),
        ),
      );
      final rotatedKey = '08' * 32;
      await database.rekey(rotatedKey);
      stored = rotatedKey;
      await database.close();

      final header = await File(path)
          .openRead(0, 16)
          .fold<List<int>>(<int>[], (bytes, chunk) => bytes..addAll(chunk));
      expect(
        utf8.decode(header, allowMalformed: true),
        isNot('SQLite format 3\u0000'),
      );

      final reopened = await factory.openNative(path);
      expect((await reopened.readCache(key))?.payload, const {'id': 7});
      await reopened.close();
    },
  );

  test('corrupt database is quarantined and recreated', () async {
    final directory = await Directory.systemTemp.createTemp('rims-corrupt-db-');
    addTearDown(() => directory.delete(recursive: true));
    final path = '${directory.path}${Platform.pathSeparator}offline.sqlite';
    await File(path).writeAsBytes(List<int>.generate(128, (index) => index));
    var keyWrites = 0;
    final quarantineTime = DateTime.utc(2026, 7, 13, 12);
    final factory = OfflineDatabaseFactory(
      readKey: () async => '11' * 32,
      writeKey: (_) async => keyWrites += 1,
      randomBytes: () => List<int>.filled(32, 9),
      now: () => quarantineTime,
    );

    final database = await factory.openNative(path);
    expect(await database.cacheRecordCount(), 0);
    await database.close();

    expect(keyWrites, 0);
    expect(
      File(
        '$path.corrupt-${quarantineTime.millisecondsSinceEpoch}',
      ).existsSync(),
      isTrue,
    );
  });

  test(
    'database key rotator persists a fresh key only after rekey succeeds',
    () async {
      var stored = '11' * 32;
      final rekeys = <String>[];
      final rotator = OfflineDatabaseKeyRotator(
        readKey: () async => stored,
        writeKey: (value) async => stored = value,
        rekey: (value) async => rekeys.add(value),
        randomBytes: () => List<int>.filled(32, 0x22),
      );

      await rotator.rotateAfterRevocation();

      expect(stored, '22' * 32);
      expect(rekeys, ['22' * 32]);
    },
  );

  test(
    'database key persistence failure rolls the live database key back',
    () async {
      final oldKey = '11' * 32;
      final rekeys = <String>[];
      final rotator = OfflineDatabaseKeyRotator(
        readKey: () async => oldKey,
        writeKey: (_) async => throw StateError('secure storage unavailable'),
        rekey: (value) async => rekeys.add(value),
        randomBytes: () => List<int>.filled(32, 0x33),
      );

      await expectLater(rotator.rotateAfterRevocation(), throwsStateError);

      expect(rekeys, ['33' * 32, oldKey]);
    },
  );
}
