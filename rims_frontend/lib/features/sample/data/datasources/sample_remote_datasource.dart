import '../../../../core/network/api_client.dart';
import '../../../../core/network/api_endpoints.dart';
import '../../../../core/result/failure.dart';
import '../../../../core/result/result.dart';
import '../models/sample_item_model.dart';

final class SampleRemoteDataSource {
  const SampleRemoteDataSource(this._apiClient);

  final ApiClient _apiClient;

  Future<Result<List<SampleItemModel>>> getItems() async {
    final result = await _apiClient.get<dynamic>(ApiEndpoints.sampleItems);

    return result.when(
      success: (response) {
        final data = response.data;

        if (data == null) {
          return const Success<List<SampleItemModel>>([]);
        }

        if (data is! List<dynamic>) {
          return const FailureResult<List<SampleItemModel>>(
            ValidationFailure(message: 'Sample items response must be a list'),
          );
        }

        final items = <SampleItemModel>[];

        for (final item in data) {
          if (item is! Map<String, dynamic>) {
            return const FailureResult<List<SampleItemModel>>(
              ValidationFailure(message: 'Sample item must be an object'),
            );
          }

          final id = item['id'];
          final title = item['title'];

          if (id is! String || title is! String) {
            return const FailureResult<List<SampleItemModel>>(
              ValidationFailure(
                message: 'Sample item requires string id and title',
              ),
            );
          }

          items.add(SampleItemModel(id: id, title: title));
        }

        return Success<List<SampleItemModel>>(items);
      },
      failure: FailureResult<List<SampleItemModel>>.new,
    );
  }
}
