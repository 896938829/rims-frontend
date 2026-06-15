import 'package:flutter_test/flutter_test.dart';
import 'package:rims_frontend/core/result/failure.dart';
import 'package:rims_frontend/core/result/result.dart';
import 'package:rims_frontend/features/sample/domain/entities/sample_item.dart';
import 'package:rims_frontend/features/sample/domain/repositories/sample_repository.dart';
import 'package:rims_frontend/features/sample/domain/usecases/get_sample_items_usecase.dart';
import 'package:rims_frontend/features/sample/presentation/view_models/sample_view_model.dart';

final class FakeSampleRepository implements SampleRepository {
  FakeSampleRepository(this.result);

  final Result<List<SampleItem>> result;

  @override
  Future<Result<List<SampleItem>>> getItems() async {
    return result;
  }
}

void main() {
  test('loadItems publishes loaded items', () async {
    final viewModel = SampleViewModel(
      getSampleItemsUseCase: GetSampleItemsUseCase(
        FakeSampleRepository(
          const Success<List<SampleItem>>([
            SampleItem(id: '1', title: 'Inventory'),
          ]),
        ),
      ),
    );

    await viewModel.loadItems();

    expect(viewModel.isLoading, isFalse);
    expect(viewModel.items, hasLength(1));
    expect(viewModel.items.first.title, 'Inventory');
    expect(viewModel.failure, isNull);
  });

  test('loadItems publishes failure', () async {
    final viewModel = SampleViewModel(
      getSampleItemsUseCase: GetSampleItemsUseCase(
        FakeSampleRepository(
          const FailureResult<List<SampleItem>>(
            NetworkFailure(message: 'Offline'),
          ),
        ),
      ),
    );

    await viewModel.loadItems();

    expect(viewModel.isLoading, isFalse);
    expect(viewModel.items, isEmpty);
    expect(viewModel.failure, isA<NetworkFailure>());
  });
}
