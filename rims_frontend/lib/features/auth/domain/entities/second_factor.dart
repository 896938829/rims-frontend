final class SecondFactorStatus {
  const SecondFactorStatus({
    required this.enabled,
    required this.pending,
    required this.recoveryCodesRemaining,
    this.pendingUntil,
  });

  final bool enabled;
  final bool pending;
  final int recoveryCodesRemaining;
  final DateTime? pendingUntil;
}

final class TOTPEnrollment {
  const TOTPEnrollment({
    required this.secret,
    required this.otpAuthUri,
    required this.expiresAt,
  });

  final String secret;
  final Uri otpAuthUri;
  final DateTime expiresAt;
}

final class RecoveryCodeSet {
  const RecoveryCodeSet(this.codes);
  final List<String> codes;
}

final class SecondFactorProof {
  const SecondFactorProof({
    required this.password,
    this.code = '',
    this.recoveryCode = '',
  });

  final String password;
  final String code;
  final String recoveryCode;
}

final class SecondFactorChallenge {
  const SecondFactorChallenge({required this.value, required this.expiresAt});
  final String value;
  final DateTime expiresAt;
}
