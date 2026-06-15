import '../../../../core/result/result.dart';
import '../entities/sample_item.dart';

abstract interface class SampleRepository {
  Future<Result<List<SampleItem>>> getItems();
}
