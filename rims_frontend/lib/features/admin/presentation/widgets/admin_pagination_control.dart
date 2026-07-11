import 'dart:async';

import 'package:flutter/material.dart';

final class AdminPaginationControl extends StatelessWidget {
  const AdminPaginationControl({
    required this.keyPrefix,
    required this.loaded,
    required this.total,
    required this.hasMore,
    required this.isLoadingMore,
    required this.hasFailure,
    required this.onLoadMore,
    required this.onRetry,
    super.key,
  });

  final String keyPrefix;
  final int loaded;
  final int total;
  final bool hasMore;
  final bool isLoadingMore;
  final bool hasFailure;
  final Future<void> Function() onLoadMore;
  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    if (hasFailure) {
      return SizedBox(
        height: 48,
        width: double.infinity,
        child: OutlinedButton.icon(
          key: Key('$keyPrefix-retry'),
          onPressed: isLoadingMore ? null : () => unawaited(onRetry()),
          icon: const Icon(Icons.refresh, size: 18),
          label: const Text('加载失败，重试'),
        ),
      );
    }
    if (hasMore) {
      return SizedBox(
        height: 48,
        width: double.infinity,
        child: TextButton.icon(
          key: Key(keyPrefix),
          onPressed: isLoadingMore ? null : () => unawaited(onLoadMore()),
          icon: isLoadingMore
              ? const SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.keyboard_arrow_down, size: 20),
          label: Text(isLoadingMore ? '正在加载...' : '加载更多 ($loaded/$total)'),
        ),
      );
    }
    return SizedBox(
      key: Key('$keyPrefix-end'),
      height: 48,
      width: double.infinity,
      child: Center(child: Text('已加载全部 $loaded 条')),
    );
  }
}
