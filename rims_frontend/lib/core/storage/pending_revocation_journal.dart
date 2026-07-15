import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'app_secure_storage.dart';

abstract interface class PendingRevocationJournal {
  Future<Set<String>> readAccountIds();

  Future<void> addAccountId(String accountId);

  Future<void> removeAccountId(String accountId);
}

abstract interface class SessionPendingRevocationJournal {
  Future<Set<SessionRevocationLease>> readLeases();

  Future<void> addLease(SessionRevocationLease lease);

  Future<void> removeLease(SessionRevocationLease lease);
}

final class MemoryPendingRevocationJournal
    implements PendingRevocationJournal, SessionPendingRevocationJournal {
  final Set<String> _accountIds = {};
  final Set<SessionRevocationLease> _leases = {};

  @override
  Future<void> addLease(SessionRevocationLease lease) async {
    _leases.add(lease);
  }

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

  @override
  Future<Set<SessionRevocationLease>> readLeases() async =>
      Set.unmodifiable(_leases);

  @override
  Future<void> removeLease(SessionRevocationLease lease) async {
    _leases.remove(lease);
  }
}

final class SharedPreferencesPendingRevocationJournal
    implements PendingRevocationJournal, SessionPendingRevocationJournal {
  SharedPreferencesPendingRevocationJournal([
    SharedPreferencesAsync? preferences,
  ]) : _preferences = preferences;

  static const String key = 'rims.auth.pending_revocation_journal.v1';
  static const String leaseKey = 'rims.auth.pending_revocation_journal.v2';
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
  Future<void> addLease(SessionRevocationLease lease) async {
    await _PendingRevocationJournalMutex.run(leaseKey, () async {
      final leases = await readLeases()
        ..add(lease);
      await _delegate.setStringList(
        leaseKey,
        leases.map(_encodeJournalLease).toList()..sort(),
      );
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

  @override
  Future<Set<SessionRevocationLease>> readLeases() async =>
      (await _delegate.getStringList(leaseKey) ?? const <String>[])
          .map(_decodeJournalLease)
          .whereType<SessionRevocationLease>()
          .toSet();

  @override
  Future<void> removeLease(SessionRevocationLease lease) =>
      _PendingRevocationJournalMutex.run(leaseKey, () async {
        final leases = await readLeases()
          ..remove(lease);
        if (leases.isEmpty) {
          await _delegate.remove(leaseKey);
        } else {
          await _delegate.setStringList(
            leaseKey,
            leases.map(_encodeJournalLease).toList()..sort(),
          );
        }
      });
}

String _encodeJournalLease(SessionRevocationLease lease) => jsonEncode({
  'account_id': lease.accountId,
  'session_id': lease.sessionId,
  'generation': lease.generation,
  'auth_epoch': lease.authEpoch,
});

SessionRevocationLease? _decodeJournalLease(String raw) {
  try {
    final decoded = jsonDecode(raw);
    if (decoded is! Map ||
        decoded['account_id'] is! String ||
        decoded['session_id'] is! String ||
        decoded['generation'] is! int ||
        decoded['auth_epoch'] is! int) {
      return null;
    }
    return SessionRevocationLease(
      accountId: decoded['account_id'] as String,
      sessionId: decoded['session_id'] as String,
      generation: decoded['generation'] as int,
      authEpoch: decoded['auth_epoch'] as int,
    );
  } on FormatException {
    return null;
  }
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
