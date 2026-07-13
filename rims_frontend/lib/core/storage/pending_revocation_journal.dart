import 'dart:async';

import 'package:shared_preferences/shared_preferences.dart';

abstract interface class PendingRevocationJournal {
  Future<Set<String>> readAccountIds();

  Future<void> addAccountId(String accountId);

  Future<void> removeAccountId(String accountId);
}

final class MemoryPendingRevocationJournal implements PendingRevocationJournal {
  final Set<String> _accountIds = {};

  @override
  Future<void> addAccountId(String accountId) async {
    _accountIds.add(accountId);
  }

  @override
  Future<void> removeAccountId(String accountId) async {
    _accountIds.remove(accountId);
  }

  @override
  Future<Set<String>> readAccountIds() async => Set.unmodifiable(_accountIds);
}

final class SharedPreferencesPendingRevocationJournal
    implements PendingRevocationJournal {
  SharedPreferencesPendingRevocationJournal([
    SharedPreferencesAsync? preferences,
  ]) : _preferences = preferences;

  static const String key = 'rims.auth.pending_revocation_journal.v1';
  SharedPreferencesAsync? _preferences;

  SharedPreferencesAsync get _delegate =>
      _preferences ??= SharedPreferencesAsync();

  @override
  Future<Set<String>> readAccountIds() async =>
      (await _delegate.getStringList(key) ?? const <String>[])
          .map((value) => value.trim())
          .where((value) => value.isNotEmpty)
          .toSet();

  @override
  Future<void> addAccountId(String accountId) async {
    await _PendingRevocationJournalMutex.run(key, () async {
      final ids = await readAccountIds()
        ..add(accountId);
      await _delegate.setStringList(key, ids.toList()..sort());
    });
  }

  @override
  Future<void> removeAccountId(String accountId) =>
      _PendingRevocationJournalMutex.run(key, () async {
        final ids = await readAccountIds()
          ..remove(accountId);
        if (ids.isEmpty) {
          await _delegate.remove(key);
        } else {
          await _delegate.setStringList(key, ids.toList()..sort());
        }
      });
}

abstract final class _PendingRevocationJournalMutex {
  static final Map<String, Future<void>> _tails = {};

  static Future<T> run<T>(String key, Future<T> Function() operation) {
    final previous = _tails[key] ?? Future<void>.value();
    final released = Completer<void>();
    _tails[key] = released.future;
    return previous.catchError((Object _) {}).then((_) async {
      try {
        return await operation();
      } finally {
        released.complete();
        if (identical(_tails[key], released.future)) _tails.remove(key);
      }
    });
  }
}
