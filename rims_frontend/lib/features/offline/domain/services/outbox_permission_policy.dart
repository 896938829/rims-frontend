import '../../../auth/domain/entities/app_user.dart';
import '../entities/outbox_operation.dart';
import 'outbox_executor.dart';

abstract final class OutboxPermissionCodes {
  static const String fileUpload = 'file:upload';
  static const String documentCreate = 'document:create';
  static const String documentComplete = 'document:complete';
  static const String stocktakeConfirm = 'stocktake:confirm';
  static const String stocktakeSettle = 'stocktake:settle';
}

final class OutboxPermissionPolicy {
  const OutboxPermissionPolicy();

  static const Map<OutboxOperationKind, Set<String>> _requiredCodes = {
    OutboxOperationKind.documentReference: {
      OutboxPermissionCodes.documentComplete,
      OutboxPermissionCodes.stocktakeConfirm,
      OutboxPermissionCodes.stocktakeSettle,
    },
    OutboxOperationKind.attachmentUpload: {OutboxPermissionCodes.fileUpload},
    OutboxOperationKind.documentCreate: {OutboxPermissionCodes.documentCreate},
    OutboxOperationKind.documentComplete: {
      OutboxPermissionCodes.documentComplete,
    },
    OutboxOperationKind.stocktakeConfirm: {
      OutboxPermissionCodes.stocktakeConfirm,
    },
    OutboxOperationKind.stocktakeSettle: {
      OutboxPermissionCodes.stocktakeSettle,
    },
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
