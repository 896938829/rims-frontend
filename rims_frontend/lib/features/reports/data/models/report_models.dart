import '../../domain/entities/report_data.dart';

final class SalesTrendPointModel {
  const SalesTrendPointModel({required this.date, required this.amount});

  factory SalesTrendPointModel.fromJson(Map<dynamic, dynamic> json) {
    return SalesTrendPointModel(
      date: _readString(json, const ['date', 'day', 'label', 'statDate']) ?? '',
      amount: _readDouble(json, const ['amount', 'salesAmount', 'value']) ?? 0,
    );
  }

  final String date;
  final double amount;

  SalesTrendPoint toEntity() {
    return SalesTrendPoint(date: date, amount: amount);
  }
}

final class SalesRankingItemModel {
  const SalesRankingItemModel({
    required this.productName,
    required this.amount,
  });

  factory SalesRankingItemModel.fromJson(Map<dynamic, dynamic> json) {
    return SalesRankingItemModel(
      productName:
          _readString(json, const [
            'productName',
            'name',
            'skuName',
            'goodsName',
          ]) ??
          '',
      amount:
          _readDouble(json, const [
            'amount',
            'salesAmount',
            'value',
            'totalAmount',
          ]) ??
          0,
    );
  }

  final String productName;
  final double amount;

  SalesRankingItem toEntity() {
    return SalesRankingItem(productName: productName, amount: amount);
  }
}

final class InventoryOverviewItemModel {
  const InventoryOverviewItemModel({required this.label, required this.value});

  factory InventoryOverviewItemModel.fromJson(Map<dynamic, dynamic> json) {
    return InventoryOverviewItemModel(
      label: _readString(json, const ['label', 'name', 'statusName']) ?? '',
      value:
          _readDouble(json, const ['value', 'count', 'quantity', 'rate']) ?? 0,
    );
  }

  final String label;
  final double value;

  InventoryOverviewItem toEntity() {
    return InventoryOverviewItem(label: label, value: value);
  }
}

List<InventoryOverviewItemModel> overviewItemsFromSummary(
  Map<dynamic, dynamic> json,
) {
  final items = <InventoryOverviewItemModel>[];

  void add(String label, List<String> keys) {
    final value = _readDouble(json, keys);
    if (value != null) {
      items.add(InventoryOverviewItemModel(label: label, value: value));
    }
  }

  add('正常库存', const ['normal', 'normalStock', 'normalCount', 'standard']);
  add('低库存', const ['low', 'lowStock', 'lowStockCount']);
  add('超储', const ['over', 'overStock', 'overStockCount']);
  add('无库存', const ['empty', 'outOfStock', 'outOfStockCount', 'zeroStock']);

  return items;
}

double? _readDouble(Map<dynamic, dynamic> json, List<String> keys) {
  for (final key in keys) {
    final value = json[key];
    if (value is num) {
      return value.toDouble();
    }
    if (value is String) {
      return double.tryParse(value.replaceAll(',', ''));
    }
  }

  return null;
}

String? _readString(Map<dynamic, dynamic> json, List<String> keys) {
  for (final key in keys) {
    final value = json[key];
    if (value is String && value.trim().isNotEmpty) {
      return value.trim();
    }
    if (value is num) {
      return value.toString();
    }
  }

  return null;
}
