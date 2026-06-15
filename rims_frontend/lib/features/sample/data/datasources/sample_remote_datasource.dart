import '../../../../core/network/api_client.dart';
import '../../../../core/network/api_endpoints.dart';
import '../../../../core/result/result.dart';
import '../models/sample_item_model.dart';

final class SampleRemoteDataSource {
  const SampleRemoteDataSource(this._apiClient);

  final ApiClient _apiClient;

  Future<Result<List<SampleItemModel>>> getItems() async {
    final result = await _apiClient.get<List<dynamic>>(ApiEndpoints.sampleItems);

    return result.when(
      success: (response) {
        final data = response.data ?? <dynamic>[];
        final items = data
            .whereType<Map<String, dynamic>>()
            .map(SampleItemModel.fromJson)
            .toList(growable: false);

        return Success<List<SampleItemModel>>(items);
      },
      failure: FailureResult<List<SampleItemModel>>.new,
    );
  }
}
