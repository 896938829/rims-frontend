import '../../../../core/result/result.dart';
import '../entities/sample_item.dart';
import '../repositories/sample_repository.dart';

final class GetSampleItemsUseCase {
  const GetSampleItemsUseCase(this._repository);

  final SampleRepository _repository;

  Future<Result<List<SampleItem>>> call() {
    return _repository.getItems();
  }
}
