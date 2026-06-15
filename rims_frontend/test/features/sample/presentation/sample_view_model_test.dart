import 'dart:async';

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

final class FutureSampleRepository implements SampleRepository {
  FutureSampleRepository(this.result);

  final Future<Result<List<SampleItem>>> result;

  @override
  Future<Result<List<SampleItem>>> getItems() {
    return result;
  }
}

final class SequencedSampleRepository implements SampleRepository {
  SequencedSampleRepository(this.results);

  final List<Result<List<SampleItem>>> results;
  int _index = 0;

  @override
  Future<Result<List<SampleItem>>> getItems() async {
    return results[_index++];
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

  test('loadItems publishes loading notifications in order', () async {
    final viewModel = SampleViewModel(
      getSampleItemsUseCase: GetSampleItemsUseCase(
        FakeSampleRepository(
          const Success<List<SampleItem>>([
            SampleItem(id: '1', title: 'Inventory'),
          ]),
        ),
      ),
    );
    final loadingStates = <bool>[];
    viewModel.addListener(() => loadingStates.add(viewModel.isLoading));

    await viewModel.loadItems();

    expect(loadingStates, <bool>[true, false]);
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

  test('loadItems clears stale items on failure', () async {
    final viewModel = SampleViewModel(
      getSampleItemsUseCase: GetSampleItemsUseCase(
        SequencedSampleRepository(
          const <Result<List<SampleItem>>>[
            Success<List<SampleItem>>([
              SampleItem(id: '1', title: 'Inventory'),
            ]),
            FailureResult<List<SampleItem>>(
              NetworkFailure(message: 'Offline'),
            ),
          ],
        ),
      ),
    );

    await viewModel.loadItems();
    await viewModel.loadItems();

    expect(viewModel.items, isEmpty);
    expect(viewModel.failure, isA<NetworkFailure>());
  });

  test('loadItems does not notify after disposal', () async {
    final result = Completer<Result<List<SampleItem>>>();
    final viewModel = SampleViewModel(
      getSampleItemsUseCase: GetSampleItemsUseCase(
        FutureSampleRepository(result.future),
      ),
    );
    var notifications = 0;
    viewModel.addListener(() => notifications += 1);

    final loadFuture = viewModel.loadItems();
    expect(notifications, 1);

    viewModel.dispose();
    result.complete(
      const Success<List<SampleItem>>([
        SampleItem(id: '1', title: 'Inventory'),
      ]),
    );

    await expectLater(loadFuture, completes);
    expect(notifications, 1);
  });
}
