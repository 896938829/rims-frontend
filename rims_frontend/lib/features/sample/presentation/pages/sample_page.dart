import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../../core/network/api_client.dart';
import '../../../../core/resources/app_strings.dart';
import '../../data/datasources/sample_remote_datasource.dart';
import '../../data/repositories/sample_repository_impl.dart';
import '../../domain/usecases/get_sample_items_usecase.dart';
import '../view_models/sample_view_model.dart';
import '../widgets/sample_item_tile.dart';

final class SamplePage extends StatelessWidget {
  const SamplePage({super.key});

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider<SampleViewModel>(
      create: (_) {
        final apiClient = ApiClient();
        final dataSource = SampleRemoteDataSource(apiClient);
        final repository = SampleRepositoryImpl(dataSource);
        final useCase = GetSampleItemsUseCase(repository);

        return SampleViewModel(getSampleItemsUseCase: useCase)..loadItems();
      },
      child: const _SampleView(),
    );
  }
}

final class _SampleView extends StatelessWidget {
  const _SampleView();

  @override
  Widget build(BuildContext context) {
    final viewModel = context.watch<SampleViewModel>();

    return Scaffold(
      appBar: AppBar(title: const Text(AppStrings.sampleTitle)),
      body: switch (viewModel) {
        SampleViewModel(isLoading: true) => const Center(
            child: CircularProgressIndicator(),
          ),
        SampleViewModel(failure: final failure?) => Center(
            child: Text(failure.message),
          ),
        SampleViewModel(items: final items) when items.isEmpty => const Center(
            child: Text('No sample items'),
          ),
        SampleViewModel(items: final items) => ListView.builder(
            itemCount: items.length,
            itemBuilder: (context, index) => SampleItemTile(
              item: items[index],
            ),
          ),
      },
    );
  }
}
