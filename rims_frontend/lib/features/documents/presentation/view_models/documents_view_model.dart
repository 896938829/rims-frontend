import 'package:flutter/foundation.dart';

import '../../../../core/resources/app_icons.dart';
import '../../domain/entities/document_data.dart';
import '../../domain/repositories/documents_repository.dart';

final class DocumentAction {
  const DocumentAction({
    required this.label,
    required this.typeCode,
    required this.iconPath,
  });

  final String label;
  final String typeCode;
  final String iconPath;
}

final class DocumentsViewModel extends ChangeNotifier {
  DocumentsViewModel({this.repository})
    : _selectedAction = _actions.first,
      _recentDocuments = const [];

  static const List<DocumentAction> _actions = [
    DocumentAction(
      label: '销售出库',
      typeCode: 'SO',
      iconPath: AppIcons.actionInbound,
    ),
    DocumentAction(
      label: '采购入库',
      typeCode: 'PI',
      iconPath: AppIcons.actionReport,
    ),
    DocumentAction(
      label: '调拨单',
      typeCode: 'TR',
      iconPath: AppIcons.actionTransfer,
    ),
    DocumentAction(
      label: '盘点单',
      typeCode: 'ST',
      iconPath: AppIcons.actionStocktake,
    ),
    DocumentAction(
      label: '退货入库',
      typeCode: 'RT',
      iconPath: AppIcons.actionReturn,
    ),
    DocumentAction(label: '转标准', typeCode: 'CV', iconPath: AppIcons.actionScan),
  ];

  final DocumentsRepository? repository;
  List<DocumentRecord> _recentDocuments;
  DocumentAction _selectedAction;
  String _productName = '';
  String _quantityText = '';
  String? _formError;
  String? _errorMessage;
  bool _isLoading = false;
  bool _isSubmitting = false;

  List<DocumentAction> get actions => _actions;
  List<String> get flowSteps => const ['创建', '确认', '提交', '完成'];
  List<DocumentRecord> get recentDocuments =>
      List<DocumentRecord>.unmodifiable(_recentDocuments);
  DocumentAction get selectedAction => _selectedAction;
  String get productName => _productName;
  String get quantityText => _quantityText;
  String? get formError => _formError;
  String? get errorMessage => _errorMessage;
  bool get isLoading => _isLoading;
  bool get isSubmitting => _isSubmitting;

  void selectAction(DocumentAction action) {
    _selectedAction = action;
    _formError = null;
    notifyListeners();
  }

  void selectActionByLabel(String label) {
    selectAction(
      _actions.firstWhere(
        (action) => action.label == label,
        orElse: () => _selectedAction,
      ),
    );
  }

  void updateProductName(String value) {
    _productName = value;
    _formError = null;
    notifyListeners();
  }

  void updateQuantity(String value) {
    _quantityText = value;
    _formError = null;
    notifyListeners();
  }

  Future<void> load() async {
    final repository = this.repository;
    if (repository == null) {
      _recentDocuments = const [];
      _errorMessage = null;
      notifyListeners();
      return;
    }

    _isLoading = true;
    _errorMessage = null;
    notifyListeners();

    final result = await repository.listRecentDocuments();

    result.when(
      success: (documents) {
        _recentDocuments = documents;
        _errorMessage = null;
      },
      failure: (failure) {
        _recentDocuments = const [];
        _errorMessage = failure.message;
      },
    );

    _isLoading = false;
    notifyListeners();
  }

  Future<bool> createDocument() async {
    final normalizedProduct = _productName.trim();
    final quantity = int.tryParse(_quantityText.trim());

    if (normalizedProduct.isEmpty || quantity == null || quantity <= 0) {
      _formError = '请输入商品和数量';
      notifyListeners();
      return false;
    }

    final repository = this.repository;
    if (repository == null) {
      _formError = '单据服务未配置';
      notifyListeners();
      return false;
    }

    _isSubmitting = true;
    _formError = null;
    notifyListeners();

    final result = await repository.createDocument(
      CreateDocumentRequest(
        typeCode: _selectedAction.typeCode,
        typeLabel: _selectedAction.label,
        productName: normalizedProduct,
        quantity: quantity,
      ),
    );

    var created = false;
    result.when(
      success: (document) {
        _recentDocuments = [document, ..._recentDocuments];
        _productName = '';
        _quantityText = '';
        _formError = null;
        created = true;
      },
      failure: (failure) {
        _formError = failure.message;
      },
    );

    _isSubmitting = false;
    notifyListeners();
    return created;
  }
}
