import 'package:rims_frontend/core/pagination/page_data.dart';
import 'package:rims_frontend/core/result/result.dart';

PageData<T> adminPage<T>(
  List<T> items, {
  int? total,
  int page = 1,
  int pageSize = 20,
}) {
  return PageData(
    items: items,
    total: total ?? items.length,
    page: page,
    pageSize: pageSize,
  );
}

Result<PageData<T>> adminPageResult<T>(Result<List<T>> result, {int page = 1}) {
  return result.when(
    success: (items) => Success(adminPage(items, page: page)),
    failure: FailureResult<PageData<T>>.new,
  );
}

Future<Result<PageData<T>>> adminPageFuture<T>(
  Future<Result<List<T>>> result, {
  int page = 1,
}) async {
  return adminPageResult(await result, page: page);
}
