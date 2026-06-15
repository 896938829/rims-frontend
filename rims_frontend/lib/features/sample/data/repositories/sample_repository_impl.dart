import '../../../../core/result/result.dart';
import '../../domain/entities/sample_item.dart';
import '../../domain/repositories/sample_repository.dart';
import '../datasources/sample_remote_datasource.dart';

final class SampleRepositoryImpl implements SampleRepository {
  const SampleRepositoryImpl(this._remoteDataSource);

  final SampleRemoteDataSource _remoteDataSource;

  @override
  Future<Result<List<SampleItem>>> getItems() async {
    final result = await _remoteDataSource.getItems();

    return result.when(
      success: (models) => Success<List<SampleItem>>(
        models.map((model) => model.toEntity()).toList(growable: false),
      ),
      failure: FailureResult<List<SampleItem>>.new,
    );
  }
}
