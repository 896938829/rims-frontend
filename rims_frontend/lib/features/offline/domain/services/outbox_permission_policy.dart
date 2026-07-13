import '../../../auth/domain/entities/app_user.dart';
import '../entities/outbox_operation.dart';
import 'outbox_executor.dart';

final class OutboxPermissionPolicy {
  const OutboxPermissionPolicy();

  static const Map<OutboxOperationKind, Set<String>> _requiredCodes = {
    OutboxOperationKind.attachmentUpload: {
      'attachment.upload',
      'document.attachment.upload',
    },
    OutboxOperationKind.documentCreate: {'document.create'},
    OutboxOperationKind.documentComplete: {'document.complete'},
    OutboxOperationKind.stocktakeConfirm: {'stocktake.confirm'},
    OutboxOperationKind.stocktakeSettle: {'stocktake.settle'},
  };

  OutboxExecutionContext contextFor({
    required AppUser user,
    required int warehouseId,
  }) {
    final permissions = user.permissionCodes
        .map((code) => code.trim().toLowerCase())
        .where((code) => code.isNotEmpty)
        .toSet();
    final sortedPermissions = permissions.toList()..sort();
    final roleCode = user.roleCode.trim().toLowerCase();
    final allowedKinds = <OutboxOperationKind>{
      for (final entry in _requiredCodes.entries)
        if (entry.value.any(permissions.contains)) entry.key,
    };
    return OutboxExecutionContext(
      accountId: user.id.toString(),
      warehouseId: warehouseId,
      permissionStamp:
          'role:${roleCode.length}:$roleCode|permissions:'
          '${sortedPermissions.map((code) => '${code.length}:$code').join(',')}',
      allowedKinds: Set.unmodifiable(allowedKinds),
    );
  }
}
