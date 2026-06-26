final class Warehouse {
  const Warehouse({
    required this.id,
    required this.code,
    required this.name,
    required this.isDefault,
  });

  final int id;
  final String code;
  final String name;
  final bool isDefault;
}
