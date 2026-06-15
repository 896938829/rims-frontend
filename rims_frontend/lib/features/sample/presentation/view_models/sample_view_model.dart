import 'package:flutter/foundation.dart';

import '../../../../core/result/failure.dart';
import '../../domain/entities/sample_item.dart';
import '../../domain/usecases/get_sample_items_usecase.dart';

final class SampleViewModel extends ChangeNotifier {
  SampleViewModel({
    required GetSampleItemsUseCase getSampleItemsUseCase,
  }) : this._(getSampleItemsUseCase);

  SampleViewModel._(this._getSampleItemsUseCase);

  final GetSampleItemsUseCase _getSampleItemsUseCase;

  bool _isLoading = false;
  List<SampleItem> _items = const [];
  Failure? _failure;

  bool get isLoading => _isLoading;
  List<SampleItem> get items => _items;
  Failure? get failure => _failure;

  Future<void> loadItems() async {
    _isLoading = true;
    _failure = null;
    notifyListeners();

    final result = await _getSampleItemsUseCase();

    result.when(
      success: (items) {
        _items = items;
      },
      failure: (failure) {
        _items = const [];
        _failure = failure;
      },
    );

    _isLoading = false;
    notifyListeners();
  }
}
