import '../../../../core/result/result.dart';
import '../entities/second_factor.dart';

abstract interface class SecondFactorRepository {
  Future<Result<SecondFactorStatus>> getStatus();

  Future<Result<TOTPEnrollment>> beginEnrollment();

  Future<Result<RecoveryCodeSet>> confirmEnrollment(String code);

  Future<Result<RecoveryCodeSet>> regenerateRecoveryCodes(
    SecondFactorProof proof,
  );

  Future<Result<void>> disable(SecondFactorProof proof);
}

abstract interface class SecondFactorLoginChallenge {
  DateTime get expiresAt;

  Future<Result<void>> complete({String? code, String? recoveryCode});

  Future<void> cancel();
}
