import 'package:flutter_test/flutter_test.dart';
import 'package:rims_frontend/core/result/result.dart';
import 'package:rims_frontend/features/auth/domain/repositories/local_unlock_repository.dart';
import 'package:rims_frontend/features/auth/presentation/view_models/biometric_unlock_view_model.dart';

void main() {
  test('loads and updates biometric policy with generation guards', () async {
    final repository = _BiometricSettingsRepository();
    final viewModel = BiometricUnlockViewModel(repository: repository);

    await viewModel.load();
    expect(viewModel.enabled, isFalse);
    expect(await viewModel.setEnabled(true), isTrue);
    expect(viewModel.enabled, isTrue);
    expect(repository.setCalls, 1);

    viewModel.dispose();
    expect(await viewModel.setEnabled(false), isFalse);
  });
}

final class _BiometricSettingsRepository
    implements BiometricSettingsRepository {
  bool enabled = false;
  int setCalls = 0;

  @override
  Future<Result<bool>> isEnabled() async => Success(enabled);

  @override
  Future<Result<void>> setEnabled(bool value) async {
    setCalls += 1;
    enabled = value;
    return const Success(null);
  }
}
