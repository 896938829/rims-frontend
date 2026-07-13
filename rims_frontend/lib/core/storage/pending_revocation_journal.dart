import 'package:shared_preferences/shared_preferences.dart';

abstract interface class PendingRevocationJournal {
  Future<Set<String>> readAccountIds();

  Future<void> addAccountId(String accountId);

  Future<void> clear();
}

final class MemoryPendingRevocationJournal implements PendingRevocationJournal {
  final Set<String> _accountIds = {};

  @override
  Future<void> addAccountId(String accountId) async {
    _accountIds.add(accountId);
  }

  @override
  Future<void> clear() async => _accountIds.clear();

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
    final ids = await readAccountIds()
      ..add(accountId);
    await _delegate.setStringList(key, ids.toList()..sort());
  }

  @override
  Future<void> clear() => _delegate.remove(key);
}
