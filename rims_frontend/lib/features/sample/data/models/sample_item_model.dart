import '../../domain/entities/sample_item.dart';

final class SampleItemModel {
  const SampleItemModel({
    required this.id,
    required this.title,
  });

  factory SampleItemModel.fromJson(Map<String, dynamic> json) {
    return SampleItemModel(
      id: json['id'] as String,
      title: json['title'] as String,
    );
  }

  final String id;
  final String title;

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'title': title,
    };
  }

  SampleItem toEntity() {
    return SampleItem(id: id, title: title);
  }
}
