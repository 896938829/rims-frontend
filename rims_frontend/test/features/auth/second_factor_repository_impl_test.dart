import 'package:flutter_test/flutter_test.dart';
import 'package:rims_frontend/core/result/result.dart';
import 'package:rims_frontend/features/auth/data/datasources/auth_remote_datasource.dart';
import 'package:rims_frontend/features/auth/data/models/auth_models.dart';
import 'package:rims_frontend/features/auth/data/repositories/second_factor_repository_impl.dart';
import 'package:rims_frontend/features/auth/domain/entities/second_factor.dart';

void main() {
  test('maps management models and forwards exactly one factor', () async {
    final remote = _FakeSecondFactorRemote();
    final repository = SecondFactorRepositoryImpl(remote);

    final status = await repository.getStatus();
    expect((status as Success<SecondFactorStatus>).data.enabled, isTrue);

    final enrollment = await repository.beginEnrollment();
    expect(
      (enrollment as Success<TOTPEnrollment>).data.secret,
      'JBSWY3DPEHPK3PXP',
    );

    final recovered = await repository.regenerateRecoveryCodes(
      const SecondFactorProof(
        password: 'Password-2026',
        code: '123456',
        recoveryCode: '',
      ),
    );
    expect(recovered.isSuccess, isTrue);
    expect(remote.lastCode, '123456');
    expect(remote.lastRecoveryCode, isNull);
  });

  test('rejects malformed mutation proof before reaching transport', () async {
    final remote = _FakeSecondFactorRemote();
    final repository = SecondFactorRepositoryImpl(remote);

    final result = await repository.disable(
      const SecondFactorProof(
        password: 'Password-2026',
        code: '123456',
        recoveryCode: 'AAAAA-BBBBB-CCCCC-DDDDD-EEEEEE',
      ),
    );

    expect(result.isFailure, isTrue);
    expect(remote.disableCalls, 0);
  });
}

final class _FakeSecondFactorRemote
    implements SecondFactorAuthRemoteDataSource {
  String? lastCode;
  String? lastRecoveryCode;
  int disableCalls = 0;

  @override
  Future<Result<SecondFactorStatusModel>> getSecondFactorStatus() async =>
      const Success(
        SecondFactorStatusModel(
          enabled: true,
          pending: false,
          recoveryCodesRemaining: 8,
        ),
      );

  @override
  Future<Result<TOTPEnrollmentModel>> beginSecondFactorEnrollment() async =>
      Success(
        TOTPEnrollmentModel(
          secret: 'JBSWY3DPEHPK3PXP',
          otpAuthUri: Uri.parse(
            'otpauth://totp/RIMS:alice?secret=JBSWY3DPEHPK3PXP',
          ),
          expiresAt: DateTime.utc(2026, 7, 16, 12, 10),
        ),
      );

  @override
  Future<Result<RecoveryCodeSetModel>> confirmSecondFactorEnrollment({
    required String code,
  }) async =>
      const Success(RecoveryCodeSetModel(['AAAAA-BBBBB-CCCCC-DDDDD-EEEEEE']));

  @override
  Future<Result<RecoveryCodeSetModel>> regenerateSecondFactorRecoveryCodes({
    required String password,
    String? code,
    String? recoveryCode,
  }) async {
    lastCode = code;
    lastRecoveryCode = recoveryCode;
    return const Success(
      RecoveryCodeSetModel(['AAAAA-BBBBB-CCCCC-DDDDD-EEEEEE']),
    );
  }

  @override
  Future<Result<void>> disableSecondFactor({
    required String password,
    String? code,
    String? recoveryCode,
  }) async {
    disableCalls += 1;
    return const Success(null);
  }

  @override
  Future<Result<LoginStartResponseModel>> beginLogin({
    required String username,
    required String password,
  }) => throw UnimplementedError();

  @override
  Future<Result<LoginResponseModel>> completeSecondFactorChallenge({
    required String challenge,
    String? code,
    String? recoveryCode,
  }) => throw UnimplementedError();
}
