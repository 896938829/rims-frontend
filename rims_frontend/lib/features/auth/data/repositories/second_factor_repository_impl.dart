import '../../../../core/result/failure.dart';
import '../../../../core/result/result.dart';
import '../../domain/entities/second_factor.dart';
import '../../domain/repositories/second_factor_repository.dart';
import '../datasources/auth_remote_datasource.dart';

final class SecondFactorRepositoryImpl implements SecondFactorRepository {
  const SecondFactorRepositoryImpl(this._remote);

  final SecondFactorAuthRemoteDataSource _remote;

  @override
  Future<Result<SecondFactorStatus>> getStatus() async =>
      _map(await _remote.getSecondFactorStatus(), (model) => model.toEntity());

  @override
  Future<Result<TOTPEnrollment>> beginEnrollment() async => _map(
    await _remote.beginSecondFactorEnrollment(),
    (model) => model.toEntity(),
  );

  @override
  Future<Result<RecoveryCodeSet>> confirmEnrollment(String code) async {
    if (!_validCode(code)) return _invalidProof();
    return _map(
      await _remote.confirmSecondFactorEnrollment(code: code),
      (model) => model.toEntity(),
    );
  }

  @override
  Future<Result<RecoveryCodeSet>> regenerateRecoveryCodes(
    SecondFactorProof proof,
  ) async {
    if (!_validProof(proof)) return _invalidProof();
    return _map(
      await _remote.regenerateSecondFactorRecoveryCodes(
        password: proof.password,
        code: proof.code.isEmpty ? null : proof.code,
        recoveryCode: proof.recoveryCode.isEmpty ? null : proof.recoveryCode,
      ),
      (model) => model.toEntity(),
    );
  }

  @override
  Future<Result<void>> disable(SecondFactorProof proof) {
    if (!_validProof(proof)) return Future.value(_invalidProof());
    return _remote.disableSecondFactor(
      password: proof.password,
      code: proof.code.isEmpty ? null : proof.code,
      recoveryCode: proof.recoveryCode.isEmpty ? null : proof.recoveryCode,
    );
  }

  Result<T> _map<M, T>(Result<M> result, T Function(M model) convert) =>
      result.when(
        success: (model) => Success(convert(model)),
        failure: FailureResult<T>.new,
      );

  FailureResult<T> _invalidProof<T>() => const FailureResult(
    StateFailure(message: 'Invalid second-factor proof.'),
  );

  bool _validProof(SecondFactorProof proof) {
    final hasCode = _validCode(proof.code);
    final normalizedRecovery = proof.recoveryCode.replaceAll(
      RegExp(r'[\s-]'),
      '',
    );
    final hasRecovery = normalizedRecovery.length == 26;
    return proof.password.isNotEmpty && hasCode != hasRecovery;
  }

  bool _validCode(String value) => RegExp(r'^\d{6}$').hasMatch(value);
}
