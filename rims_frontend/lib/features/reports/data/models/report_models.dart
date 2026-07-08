import '../../domain/entities/report_data.dart';

final class SalesStatsModel {
  const SalesStatsModel({
    required this.revenue,
    required this.orderCount,
    required this.skuCount,
    required this.quantity,
    this.costAmount,
    this.grossProfit,
  });

  factory SalesStatsModel.fromJson(Map<dynamic, dynamic> json) {
    return SalesStatsModel(
      revenue:
          _readDouble(json, const ['revenue', 'amount', 'salesAmount']) ?? 0,
      orderCount: _readInt(json, const ['orderCount', 'orders']) ?? 0,
      skuCount: _readInt(json, const ['skuCount', 'productCount']) ?? 0,
      quantity: _readInt(json, const ['quantity', 'qty', 'salesQuantity']) ?? 0,
      costAmount: _readDouble(json, const ['costAmount', 'cost']),
      grossProfit: _readDouble(json, const ['grossProfit', 'profit']),
    );
  }

  final double revenue;
  final int orderCount;
  final int skuCount;
  final int quantity;
  final double? costAmount;
  final double? grossProfit;

  SalesStats toEntity() {
    return SalesStats(
      revenue: revenue,
      orderCount: orderCount,
      skuCount: skuCount,
      quantity: quantity,
      costAmount: costAmount,
      grossProfit: grossProfit,
    );
  }
}

final class SalesTrendPointModel {
  const SalesTrendPointModel({required this.date, required this.amount});

  factory SalesTrendPointModel.fromJson(Map<dynamic, dynamic> json) {
    return SalesTrendPointModel(
      date:
          _readString(json, const [
            'period',
            'date',
            'day',
            'label',
            'statDate',
          ]) ??
          '',
      amount:
          _readDouble(json, const [
            'revenue',
            'amount',
            'salesAmount',
            'value',
          ]) ??
          0,
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
            'revenue',
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

final class InventoryTurnoverItemModel {
  const InventoryTurnoverItemModel({
    required this.productName,
    required this.sku,
    required this.soldQuantity,
    required this.averageStockQuantity,
    required this.turnoverRate,
  });

  factory InventoryTurnoverItemModel.fromJson(Map<dynamic, dynamic> json) {
    return InventoryTurnoverItemModel(
      productName:
          _readString(json, const [
            'productName',
            'name',
            'skuName',
            'goodsName',
          ]) ??
          '',
      sku: _readString(json, const ['sku', 'productCode', 'code']) ?? '',
      soldQuantity:
          _readInt(json, const [
            'soldQty',
            'soldQuantity',
            'salesQty',
            'quantity',
          ]) ??
          0,
      averageStockQuantity:
          _readDouble(json, const [
            'avgStockQty',
            'averageStockQty',
            'averageStock',
            'avgStock',
          ]) ??
          0,
      turnoverRate:
          _readDouble(json, const ['turnoverRate', 'turnover', 'rate']) ?? 0,
    );
  }

  final String productName;
  final String sku;
  final int soldQuantity;
  final double averageStockQuantity;
  final double turnoverRate;

  InventoryTurnoverItem toEntity() {
    return InventoryTurnoverItem(
      productName: productName,
      sku: sku,
      soldQuantity: soldQuantity,
      averageStockQuantity: averageStockQuantity,
      turnoverRate: turnoverRate,
    );
  }
}

final class SlowMovingInventoryItemModel {
  const SlowMovingInventoryItemModel({
    required this.productName,
    required this.sku,
    required this.stockQuantity,
    required this.salesQuantity,
    this.lastSaleAt,
  });

  factory SlowMovingInventoryItemModel.fromJson(Map<dynamic, dynamic> json) {
    return SlowMovingInventoryItemModel(
      productName:
          _readString(json, const [
            'productName',
            'name',
            'skuName',
            'goodsName',
          ]) ??
          '',
      sku: _readString(json, const ['sku', 'productCode', 'code']) ?? '',
      stockQuantity:
          _readInt(json, const [
            'stockQty',
            'stockQuantity',
            'quantity',
            'availableQuantity',
          ]) ??
          0,
      salesQuantity:
          _readInt(json, const [
            'salesQty',
            'salesQuantity',
            'soldQty',
            'soldQuantity',
          ]) ??
          0,
      lastSaleAt: _readString(json, const ['lastSaleAt', 'lastSoldAt']),
    );
  }

  final String productName;
  final String sku;
  final int stockQuantity;
  final int salesQuantity;
  final String? lastSaleAt;

  SlowMovingInventoryItem toEntity() {
    return SlowMovingInventoryItem(
      productName: productName,
      sku: sku,
      stockQuantity: stockQuantity,
      salesQuantity: salesQuantity,
      lastSaleAt: lastSaleAt,
    );
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

  add('商品数', const ['skuCount', 'productCount', 'itemCount']);
  add('库存总量', const ['totalQty', 'totalQuantity', 'stockQuantity']);
  add('预警数量', const ['lowStockCount', 'alertCount', 'warningCount']);
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

int? _readInt(Map<dynamic, dynamic> json, List<String> keys) {
  for (final key in keys) {
    final value = json[key];
    if (value is num) {
      return value.round();
    }
    if (value is String) {
      return int.tryParse(value.replaceAll(',', ''));
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
