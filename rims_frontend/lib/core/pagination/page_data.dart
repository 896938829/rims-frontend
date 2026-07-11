final class PageData<T> {
  PageData({
    required List<T> items,
    required this.total,
    required this.page,
    required this.pageSize,
  }) : items = List<T>.unmodifiable(items);

  final List<T> items;
  final int total;
  final int page;
  final int pageSize;

  bool get hasNextPage => page * pageSize < total;

  int get nextPage => page + 1;

  PageData<R> map<R>(R Function(T item) convert) {
    return PageData<R>(
      items: items.map(convert).toList(growable: false),
      total: total,
      page: page,
      pageSize: pageSize,
    );
  }
}
