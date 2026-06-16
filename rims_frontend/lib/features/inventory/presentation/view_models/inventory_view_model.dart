import '../../../../core/resources/app_images.dart';

final class InventoryMetric {
  const InventoryMetric({required this.label, required this.value});

  final String label;
  final String value;
}

final class InventoryProduct {
  const InventoryProduct({
    required this.name,
    required this.sku,
    required this.imagePath,
    required this.available,
    required this.stock,
    required this.status,
  });

  final String name;
  final String sku;
  final String imagePath;
  final int available;
  final int stock;
  final String status;
}

final class InventoryViewModel {
  const InventoryViewModel();

  String get warehouseName => '上海仓';

  List<String> get tabs => const ['标准', '商品', '非标'];

  List<InventoryMetric> get metrics => const [
    InventoryMetric(label: 'SKU数', value: '1,286'),
    InventoryMetric(label: '总库存', value: '48,920'),
    InventoryMetric(label: '库存金额(元)', value: '¥326k'),
  ];

  List<InventoryProduct> get products => const [
    InventoryProduct(
      name: '矿泉水 550ml',
      sku: 'SKU-WA-550',
      imagePath: AppImages.productWaterBottle,
      available: 1280,
      stock: 1460,
      status: '标准',
    ),
    InventoryProduct(
      name: '抽纸 3包装',
      sku: 'SKU-TI-003',
      imagePath: AppImages.productTissuePack,
      available: 312,
      stock: 480,
      status: '标准',
    ),
    InventoryProduct(
      name: '洗衣液 2kg',
      sku: 'SKU-LD-200',
      imagePath: AppImages.productLaundryDetergent,
      available: 28,
      stock: 44,
      status: '低库存',
    ),
    InventoryProduct(
      name: '深色瓶装样品',
      sku: 'SKU-SP-DARK',
      imagePath: AppImages.productDarkBottle,
      available: 16,
      stock: 20,
      status: '非标',
    ),
  ];
}
