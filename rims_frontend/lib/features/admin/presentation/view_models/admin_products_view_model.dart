import 'package:flutter/foundation.dart';

import '../../../../core/events/app_event.dart';
import '../../../../core/events/app_event_bus.dart';
import '../../domain/entities/admin_product.dart';
import '../../domain/repositories/admin_repository.dart';

final class AdminProductsViewModel extends ChangeNotifier {
  AdminProductsViewModel({this.repository, this.eventBus});

  final AdminRepository? repository;
  final AppEventBus? eventBus;

  List<AdminProduct> _products = const [];
  String _query = '';
  bool _isLoading = false;
  bool _isCreatingProduct = false;
  bool _isUpdatingProduct = false;
  bool _isDeletingProduct = false;
  bool _isDisposed = false;
  String? _errorMessage;
  String? _formError;
  String? _productActionError;

  List<AdminProduct> get products => _products;
  String get query => _query;
  bool get isLoading => _isLoading;
  bool get isCreatingProduct => _isCreatingProduct;
  bool get isUpdatingProduct => _isUpdatingProduct;
  bool get isDeletingProduct => _isDeletingProduct;
  bool get isEmpty => _products.isEmpty && !_isLoading && _errorMessage == null;
  String? get errorMessage => _errorMessage;
  String? get formError => _formError;
  String? get productActionError => _productActionError;

  @override
  void notifyListeners() {
    if (_isDisposed) {
      return;
    }

    super.notifyListeners();
  }

  @override
  void dispose() {
    _isDisposed = true;
    super.dispose();
  }

  Future<void> load({int page = 1}) async {
    final repository = this.repository;
    if (repository == null) {
      _products = const [];
      _errorMessage = '管理服务不可用';
      notifyListeners();
      return;
    }

    _isLoading = true;
    _errorMessage = null;
    notifyListeners();

    final result = await repository.listProducts(
      keyword: _query.trim(),
      page: page,
    );

    result.when(
      success: (products) {
        _products = products;
        _errorMessage = null;
      },
      failure: (failure) {
        _errorMessage = failure.message;
      },
    );

    _isLoading = false;
    notifyListeners();
  }

  Future<void> updateQuery(String value) async {
    if (_query == value) {
      return;
    }

    _query = value;
    await load();
  }

  Future<bool> createProduct(CreateAdminProductRequest request) async {
    if (_isCreatingProduct) {
      return false;
    }

    final normalizedRequest = CreateAdminProductRequest(
      code: request.code.trim(),
      name: request.name.trim(),
      unit: request.unit.trim(),
      category: request.category.trim(),
      spec: request.spec.trim(),
      barcode: request.barcode.trim(),
      retailPrice: request.retailPrice,
      costPrice: request.costPrice,
      imageUrl: request.imageUrl.trim(),
      status: request.status,
    );

    if (!_isValidProductIdentity(
      code: normalizedRequest.code,
      name: normalizedRequest.name,
      unit: normalizedRequest.unit,
    )) {
      _formError = '请填写商品编码、名称和单位';
      notifyListeners();
      return false;
    }

    final priceError = _validatePrices(
      retailPrice: normalizedRequest.retailPrice,
      costPrice: normalizedRequest.costPrice,
    );
    if (priceError != null) {
      _formError = priceError;
      notifyListeners();
      return false;
    }

    final repository = this.repository;
    if (repository == null) {
      _formError = '管理服务不可用';
      notifyListeners();
      return false;
    }

    _isCreatingProduct = true;
    _formError = null;
    notifyListeners();

    var created = false;
    final result = await repository.createProduct(normalizedRequest);
    result.when(
      success: (product) {
        _products = [
          product,
          ..._products.where((candidate) => candidate.id != product.id),
        ];
        _formError = null;
        created = true;
        _publishGlobalRefresh();
      },
      failure: (failure) {
        _formError = failure.message;
      },
    );

    _isCreatingProduct = false;
    notifyListeners();
    return created;
  }

  Future<bool> updateProduct(UpdateAdminProductRequest request) async {
    if (_isUpdatingProduct) {
      return false;
    }

    final normalizedRequest = UpdateAdminProductRequest(
      id: request.id,
      code: request.code.trim(),
      name: request.name.trim(),
      unit: request.unit.trim(),
      category: request.category.trim(),
      spec: request.spec.trim(),
      barcode: request.barcode.trim(),
      retailPrice: request.retailPrice,
      costPrice: request.costPrice,
      imageUrl: request.imageUrl.trim(),
      status: request.status,
    );

    if (!_isValidProductIdentity(
      code: normalizedRequest.code,
      name: normalizedRequest.name,
      unit: normalizedRequest.unit,
    )) {
      _formError = '请填写商品编码、名称和单位';
      notifyListeners();
      return false;
    }

    final priceError = _validatePrices(
      retailPrice: normalizedRequest.retailPrice,
      costPrice: normalizedRequest.costPrice,
    );
    if (priceError != null) {
      _formError = priceError;
      notifyListeners();
      return false;
    }

    final repository = this.repository;
    if (repository == null) {
      _formError = '管理服务不可用';
      notifyListeners();
      return false;
    }

    _isUpdatingProduct = true;
    _formError = null;
    notifyListeners();

    var updated = false;
    final result = await repository.updateProduct(normalizedRequest);
    result.when(
      success: (product) {
        _products = _products
            .map(
              (candidate) => candidate.id == product.id ? product : candidate,
            )
            .toList(growable: false);
        _formError = null;
        updated = true;
        _publishGlobalRefresh();
      },
      failure: (failure) {
        _formError = failure.message;
      },
    );

    _isUpdatingProduct = false;
    notifyListeners();
    return updated;
  }

  Future<bool> deleteProduct(AdminProduct product) async {
    if (_isDeletingProduct) {
      return false;
    }

    final repository = this.repository;
    if (repository == null) {
      _productActionError = '管理服务不可用';
      notifyListeners();
      return false;
    }

    _isDeletingProduct = true;
    _productActionError = null;
    notifyListeners();

    var deleted = false;
    final result = await repository.deleteProduct(product.id);
    result.when(
      success: (_) {
        _products = _products
            .where((candidate) => candidate.id != product.id)
            .toList(growable: false);
        _productActionError = null;
        deleted = true;
        _publishGlobalRefresh();
      },
      failure: (failure) {
        _productActionError = failure.message;
      },
    );

    _isDeletingProduct = false;
    notifyListeners();
    return deleted;
  }

  bool _isValidProductIdentity({
    required String code,
    required String name,
    required String unit,
  }) {
    return code.isNotEmpty && name.isNotEmpty && unit.isNotEmpty;
  }

  String? _validatePrices({double? retailPrice, double? costPrice}) {
    if ((retailPrice ?? 0) < 0 || (costPrice ?? 0) < 0) {
      return '价格不能为负数';
    }

    return null;
  }

  void _publishGlobalRefresh() {
    eventBus?.publish(const GlobalRefreshRequestedEvent());
  }
}
