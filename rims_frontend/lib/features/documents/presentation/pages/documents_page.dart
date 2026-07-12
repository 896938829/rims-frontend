import 'dart:async';

import 'package:flutter/material.dart';

import '../../../../core/events/app_event.dart';
import '../../../../core/events/app_event_bus.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_text_styles.dart';
import '../../../../core/widgets/rims_card.dart';
import '../../../../core/widgets/rims_page_scaffold.dart';
import '../../../../core/widgets/rims_section_header.dart';
import '../../../../core/widgets/rims_status_chip.dart';
import '../../../auth/domain/entities/warehouse.dart';
import '../../../attachments/domain/repositories/attachments_repository.dart';
import '../../../attachments/domain/services/attachment_picker.dart';
import '../../../attachments/domain/services/attachment_share_service.dart';
import '../../../attachments/domain/services/attachment_staging_store.dart';
import '../../../attachments/domain/entities/attachment.dart';
import '../../../attachments/presentation/view_models/attachments_view_model.dart';
import '../../../attachments/presentation/widgets/attachment_panel.dart';
import '../../domain/entities/document_data.dart';
import '../../domain/repositories/documents_repository.dart';
import '../../../inventory/domain/entities/inventory_item.dart';
import '../../../inventory/domain/repositories/inventory_repository.dart';
import '../../../offline/domain/repositories/document_draft_repository.dart';
import '../../../offline/presentation/view_models/draft_attachments_view_model.dart';
import '../../../offline/presentation/widgets/draft_attachment_panel.dart';
import '../view_models/documents_view_model.dart';
import '../widgets/document_action_card.dart';
import '../widgets/document_flow_strip.dart';
import '../widgets/document_status_kind.dart';

final class DocumentsPage extends StatefulWidget {
  const DocumentsPage({
    this.viewModel,
    this.repository,
    this.inventoryRepository,
    this.currentWarehouse,
    this.warehouses = const [],
    this.canManageAdminDocumentActions = true,
    this.initialActionLabel,
    this.eventBus,
    this.attachmentsRepository,
    this.attachmentPicker,
    this.attachmentStagingStore,
    this.attachmentShareService,
    this.attachmentUserId,
    this.onScanRequested,
    this.requestScannerOnOpen = false,
    this.draftRepository,
    this.accountId,
    this.observedRoleCode = '',
    this.initialDraftId,
    super.key,
  });

  final DocumentsViewModel? viewModel;
  final DocumentsRepository? repository;
  final InventoryRepository? inventoryRepository;
  final Warehouse? currentWarehouse;
  final List<Warehouse> warehouses;
  final bool canManageAdminDocumentActions;
  final String? initialActionLabel;
  final AppEventBus? eventBus;
  final AttachmentsRepository? attachmentsRepository;
  final AttachmentPicker? attachmentPicker;
  final AttachmentStagingStore? attachmentStagingStore;
  final AttachmentShareService? attachmentShareService;
  final String? attachmentUserId;
  final Future<InventoryItem?> Function(BuildContext context)? onScanRequested;
  final bool requestScannerOnOpen;
  final DocumentDraftRepository? draftRepository;
  final String? accountId;
  final String observedRoleCode;
  final String? initialDraftId;

  @override
  State<DocumentsPage> createState() => _DocumentsPageState();
}

final class _DocumentsPageState extends State<DocumentsPage> {
  late final DocumentsViewModel viewModel;
  late final bool _ownsViewModel;
  StreamSubscription<GlobalRefreshRequestedEvent>? _refreshSubscription;

  @override
  void initState() {
    super.initState();
    _ownsViewModel = widget.viewModel == null;
    viewModel =
        widget.viewModel ??
        DocumentsViewModel(
          repository: widget.repository,
          inventoryRepository: widget.inventoryRepository,
          currentWarehouse: widget.currentWarehouse,
          warehouses: widget.warehouses,
          canManageAdminDocumentActions: widget.canManageAdminDocumentActions,
          draftRepository: widget.draftRepository,
          accountId: widget.accountId,
          observedRoleCode: widget.observedRoleCode,
        );

    _selectInitialAction();
    if (widget.initialDraftId case final draftId?) {
      unawaited(_openDraft(draftId));
    }
    if (widget.requestScannerOnOpen) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _requestScan());
    }

    if (_ownsViewModel) {
      unawaited(viewModel.load());
    }
    _subscribeToRefreshEvents();
  }

  @override
  void didUpdateWidget(covariant DocumentsPage oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (widget.initialActionLabel != oldWidget.initialActionLabel) {
      _selectInitialAction();
    }
    final nextDraftId = widget.initialDraftId;
    if (nextDraftId != null && nextDraftId != oldWidget.initialDraftId) {
      unawaited(_openDraft(nextDraftId));
    }
    if (widget.requestScannerOnOpen && !oldWidget.requestScannerOnOpen) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _requestScan());
    }
    if (widget.eventBus != oldWidget.eventBus) {
      unawaited(_refreshSubscription?.cancel());
      _subscribeToRefreshEvents();
    }
  }

  @override
  void dispose() {
    unawaited(_refreshSubscription?.cancel());
    if (_ownsViewModel) {
      viewModel.dispose();
    }

    super.dispose();
  }

  void _subscribeToRefreshEvents() {
    _refreshSubscription = widget.eventBus
        ?.on<GlobalRefreshRequestedEvent>()
        .listen((_) => unawaited(viewModel.load()));
  }

  void _selectInitialAction() {
    final initialActionLabel = widget.initialActionLabel;
    if (initialActionLabel != null) {
      viewModel.selectActionByLabel(initialActionLabel);
      _loadNonStandardInventoryIfNeeded();
      _loadReturnSourceDocumentsIfNeeded();
    }
  }

  void _selectAction(DocumentAction action) {
    viewModel.selectAction(action);
    _loadNonStandardInventoryIfNeeded();
    _loadReturnSourceDocumentsIfNeeded();
  }

  Future<void> _openDraft(String draftId) async {
    final opened = await viewModel.openDraft(draftId);
    if (!mounted || !opened) return;
    _loadNonStandardInventoryIfNeeded();
    _loadReturnSourceDocumentsIfNeeded();
  }

  Future<void> _requestScan() async {
    final scan = widget.onScanRequested;
    if (scan == null || !mounted) return;
    final product = await scan(context);
    if (product != null) viewModel.addScannedProduct(product);
  }

  void _loadNonStandardInventoryIfNeeded() {
    if (viewModel.isConversionAction) {
      unawaited(viewModel.loadNonStandardInventory());
    }
  }

  void _loadReturnSourceDocumentsIfNeeded() {
    if (viewModel.isReturnAction) {
      unawaited(viewModel.loadReturnSourceDocuments());
    }
  }

  Future<void> _openDocumentDetail(DocumentRecord document) async {
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.surface,
      isScrollControlled: true,
      builder: (context) {
        return AnimatedBuilder(
          animation: viewModel,
          builder: (context, _) {
            final currentDocument = viewModel.recentDocuments.firstWhere(
              (item) => item.id == document.id,
              orElse: () => document,
            );

            return _DocumentDetailSheet(
              document: currentDocument,
              viewModel: viewModel,
              eventBus: widget.eventBus,
              documentsRepository: widget.repository,
              attachmentsRepository: widget.attachmentsRepository,
              attachmentPicker: widget.attachmentPicker,
              attachmentStagingStore: widget.attachmentStagingStore,
              attachmentShareService: widget.attachmentShareService,
              attachmentUserId: widget.attachmentUserId,
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: viewModel,
      builder: (context, _) {
        final visibleDocuments = viewModel.visibleDocuments;

        return RimsPageScaffold(
          key: const Key('tab-body-documents'),
          child: ListView(
            key: const Key('documents-scroll-view'),
            children: [
              Text('单据', style: AppTextStyles.headingLarge),
              if (viewModel.cacheStatusLabel case final label?) ...[
                const SizedBox(height: 8),
                _OfflineReadStatus(
                  key: const Key('documents-cache-status'),
                  label: label,
                ),
              ],
              const SizedBox(height: 14),
              GridView.count(
                crossAxisCount: 2,
                crossAxisSpacing: 10,
                mainAxisSpacing: 10,
                mainAxisExtent: 72,
                physics: const NeverScrollableScrollPhysics(),
                shrinkWrap: true,
                children: [
                  for (final action in viewModel.actions)
                    Semantics(
                      key: _documentActionKey(action),
                      label: action.label,
                      button: true,
                      selected: action == viewModel.selectedAction,
                      child: DocumentActionCard(
                        action: action,
                        isSelected: action == viewModel.selectedAction,
                        onTap: viewModel.isSubmitting
                            ? null
                            : () => _selectAction(action),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 14),
              _DocumentForm(
                viewModel: viewModel,
                eventBus: widget.eventBus,
                attachmentPicker: widget.attachmentPicker,
                attachmentStagingStore: widget.attachmentStagingStore,
                attachmentUserId: widget.attachmentUserId,
                onScanRequested: widget.onScanRequested == null
                    ? null
                    : _requestScan,
              ),
              const SizedBox(height: 20),
              const RimsSectionHeader(title: '单据流程'),
              const SizedBox(height: 10),
              DocumentFlowStrip(steps: viewModel.flowSteps),
              const SizedBox(height: 20),
              const RimsSectionHeader(title: '最近单据'),
              const SizedBox(height: 10),
              if (viewModel.recentDocuments.isNotEmpty) ...[
                _DocumentFilters(viewModel: viewModel),
                const SizedBox(height: 10),
              ],
              if (viewModel.documentActionError != null) ...[
                RimsCard(
                  child: Text(
                    viewModel.documentActionError!,
                    textAlign: TextAlign.center,
                    style: AppTextStyles.bodySmall.copyWith(
                      color: AppColors.error,
                    ),
                  ),
                ),
                const SizedBox(height: 10),
              ],
              if (viewModel.isLoading && viewModel.recentDocuments.isEmpty)
                RimsCard(
                  child: Text(
                    '正在加载单据...',
                    textAlign: TextAlign.center,
                    style: AppTextStyles.bodySmall,
                  ),
                )
              else if (viewModel.errorMessage != null)
                _DocumentsRetryCard(
                  message: viewModel.errorMessage!,
                  isLoading: viewModel.isLoading,
                  onRetry: () => unawaited(viewModel.load()),
                )
              else if (viewModel.recentDocuments.isEmpty)
                RimsCard(
                  child: Text(
                    '暂无最近单据',
                    textAlign: TextAlign.center,
                    style: AppTextStyles.bodySmall,
                  ),
                )
              else if (visibleDocuments.isEmpty) ...[
                RimsCard(
                  child: Text(
                    '没有匹配的单据',
                    textAlign: TextAlign.center,
                    style: AppTextStyles.bodySmall,
                  ),
                ),
                if (viewModel.recentDocuments.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  _DocumentsPageControl(
                    prefix: 'documents',
                    hasMore: viewModel.hasMoreDocuments,
                    isLoading: viewModel.isLoadingMoreDocuments,
                    failure: viewModel.documentLoadMoreFailure?.message,
                    loaded: viewModel.recentDocuments.length,
                    total: viewModel.documentTotal,
                    onLoadMore: viewModel.loadMoreDocuments,
                    onRetry: viewModel.retryLoadMoreDocuments,
                  ),
                ],
              ] else ...[
                for (final document in visibleDocuments) ...[
                  _RecentDocumentCard(
                    document: document,
                    viewModel: viewModel,
                    eventBus: widget.eventBus,
                    onOpenDetail: () =>
                        unawaited(_openDocumentDetail(document)),
                  ),
                  if (document != visibleDocuments.last)
                    const SizedBox(height: 10),
                ],
                const SizedBox(height: 10),
                _DocumentsPageControl(
                  prefix: 'documents',
                  hasMore: viewModel.hasMoreDocuments,
                  isLoading: viewModel.isLoadingMoreDocuments,
                  failure: viewModel.documentLoadMoreFailure?.message,
                  loaded: viewModel.recentDocuments.length,
                  total: viewModel.documentTotal,
                  onLoadMore: viewModel.loadMoreDocuments,
                  onRetry: viewModel.retryLoadMoreDocuments,
                ),
              ],
              const SizedBox(height: 20),
              const RimsSectionHeader(title: '库存流水'),
              const SizedBox(height: 10),
              if (viewModel.isLoading && viewModel.transactions.isEmpty)
                RimsCard(
                  child: Text(
                    '正在加载流水...',
                    textAlign: TextAlign.center,
                    style: AppTextStyles.bodySmall,
                  ),
                )
              else if (viewModel.transactionError != null)
                _DocumentsRetryCard(
                  message: viewModel.transactionError!,
                  isLoading: viewModel.isLoading,
                  onRetry: () => unawaited(viewModel.load()),
                )
              else if (viewModel.transactions.isEmpty)
                RimsCard(
                  child: Text(
                    '暂无库存流水',
                    textAlign: TextAlign.center,
                    style: AppTextStyles.bodySmall,
                  ),
                )
              else ...[
                for (final transaction in viewModel.transactions) ...[
                  _TransactionRecordCard(transaction: transaction),
                  if (transaction != viewModel.transactions.last)
                    const SizedBox(height: 10),
                ],
                const SizedBox(height: 10),
                _DocumentsPageControl(
                  prefix: 'transactions',
                  hasMore: viewModel.hasMoreTransactions,
                  isLoading: viewModel.isLoadingMoreTransactions,
                  failure: viewModel.transactionLoadMoreFailure?.message,
                  loaded: viewModel.transactions.length,
                  total: viewModel.transactionTotal,
                  onLoadMore: viewModel.loadMoreTransactions,
                  onRetry: viewModel.retryLoadMoreTransactions,
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}

final class _OfflineReadStatus extends StatelessWidget {
  const _OfflineReadStatus({required this.label, super.key});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        const Icon(
          Icons.cloud_off_outlined,
          size: 16,
          color: AppColors.warning,
        ),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            label,
            style: AppTextStyles.bodySmall.copyWith(
              color: AppColors.textSecondary,
            ),
          ),
        ),
      ],
    );
  }
}

final class _DocumentsPageControl extends StatelessWidget {
  const _DocumentsPageControl({
    required this.prefix,
    required this.hasMore,
    required this.isLoading,
    required this.failure,
    required this.loaded,
    required this.total,
    required this.onLoadMore,
    required this.onRetry,
  });

  final String prefix;
  final bool hasMore;
  final bool isLoading;
  final String? failure;
  final int loaded;
  final int total;
  final Future<void> Function() onLoadMore;
  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    if (failure != null) {
      return Semantics(
        label: '重试加载更多$_contentLabel',
        button: true,
        child: SizedBox(
          height: 48,
          width: double.infinity,
          child: OutlinedButton.icon(
            key: Key('$prefix-load-more-retry'),
            onPressed: isLoading ? null : () => unawaited(onRetry()),
            icon: const Icon(Icons.refresh, size: 18),
            label: const Text('加载失败，重试'),
          ),
        ),
      );
    }
    if (hasMore) {
      return Semantics(
        label: isLoading ? '正在加载更多$_contentLabel' : '加载更多$_contentLabel',
        button: true,
        child: SizedBox(
          height: 48,
          width: double.infinity,
          child: TextButton.icon(
            key: Key('$prefix-load-more-button'),
            onPressed: isLoading ? null : () => unawaited(onLoadMore()),
            icon: isLoading
                ? const SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.keyboard_arrow_down, size: 20),
            label: Text(isLoading ? '正在加载...' : '加载更多 ($loaded/$total)'),
          ),
        ),
      );
    }
    return Semantics(
      label: '$_contentLabel已全部加载',
      child: SizedBox(
        key: Key('$prefix-page-end'),
        height: 48,
        width: double.infinity,
        child: Center(child: Text('已加载全部 $loaded 条')),
      ),
    );
  }

  String get _contentLabel => prefix == 'documents' ? '单据' : '库存流水';
}

final class _DocumentsRetryCard extends StatelessWidget {
  const _DocumentsRetryCard({
    required this.message,
    required this.isLoading,
    required this.onRetry,
  });

  final String message;
  final bool isLoading;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return RimsCard(
      child: Column(
        children: [
          Text(
            message,
            textAlign: TextAlign.center,
            style: AppTextStyles.bodySmall.copyWith(color: AppColors.error),
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: isLoading ? null : onRetry,
            icon: const Icon(Icons.refresh, size: 18),
            label: const Text('重试'),
          ),
        ],
      ),
    );
  }
}

final class _DocumentDetailSheet extends StatefulWidget {
  const _DocumentDetailSheet({
    required this.document,
    required this.viewModel,
    this.eventBus,
    this.documentsRepository,
    this.attachmentsRepository,
    this.attachmentPicker,
    this.attachmentStagingStore,
    this.attachmentShareService,
    this.attachmentUserId,
  });

  final DocumentRecord document;
  final DocumentsViewModel viewModel;
  final AppEventBus? eventBus;
  final DocumentsRepository? documentsRepository;
  final AttachmentsRepository? attachmentsRepository;
  final AttachmentPicker? attachmentPicker;
  final AttachmentStagingStore? attachmentStagingStore;
  final AttachmentShareService? attachmentShareService;
  final String? attachmentUserId;

  @override
  State<_DocumentDetailSheet> createState() => _DocumentDetailSheetState();
}

final class _DocumentDetailSheetState extends State<_DocumentDetailSheet> {
  DocumentDetail? _detail;
  String? _detailError;
  bool _isLoadingDetail = false;
  AttachmentsViewModel? _attachmentsViewModel;

  DocumentRecord get document => _detail?.record ?? widget.document;
  DocumentsViewModel get viewModel => widget.viewModel;
  AppEventBus? get eventBus => widget.eventBus;

  @override
  void initState() {
    super.initState();
    final repository = widget.documentsRepository;
    if (repository case final DocumentDetailsRepository detailsRepository) {
      _isLoadingDetail = true;
      unawaited(_loadDetail(detailsRepository));
    }
    final attachmentsRepository = widget.attachmentsRepository;
    final picker = widget.attachmentPicker;
    final stagingStore = widget.attachmentStagingStore;
    final shareService = widget.attachmentShareService;
    final userId = widget.attachmentUserId;
    if (attachmentsRepository != null &&
        picker != null &&
        stagingStore != null &&
        shareService != null &&
        userId != null) {
      _attachmentsViewModel = AttachmentsViewModel(
        repository: attachmentsRepository,
        picker: picker,
        stagingStore: stagingStore,
        shareService: shareService,
        binding: AttachmentBinding.document(widget.document.id),
        userId: userId,
      );
    }
  }

  Future<void> _loadDetail(DocumentDetailsRepository repository) async {
    final result = await repository.getDocument(widget.document.id);
    if (!mounted) return;
    result.when(
      success: (detail) => _detail = detail,
      failure: (failure) => _detailError = failure.message,
    );
    setState(() => _isLoadingDetail = false);
  }

  @override
  void dispose() {
    _attachmentsViewModel?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          20,
          18,
          20,
          20 + MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text('单据详情', style: AppTextStyles.headingMedium),
                  ),
                  IconButton(
                    tooltip: '关闭',
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      document.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppTextStyles.titleMedium,
                    ),
                  ),
                  const SizedBox(width: 10),
                  RimsStatusChip(
                    label: document.status,
                    kind: documentStatusKind(document.status),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              _DocumentDetailRow(label: '单号', value: document.number),
              const SizedBox(height: 8),
              _DocumentDetailRow(label: '类型', value: document.title),
              if (document.createdAt.isNotEmpty) ...[
                const SizedBox(height: 8),
                _DocumentDetailRow(label: '创建时间', value: document.createdAt),
              ],
              if (_isLoadingDetail) ...[
                const SizedBox(height: 12),
                const LinearProgressIndicator(
                  key: Key('document-detail-loading'),
                ),
              ],
              if (_detailError != null) ...[
                const SizedBox(height: 12),
                Text(
                  _detailError!,
                  key: const Key('document-detail-error'),
                  style: AppTextStyles.bodySmall.copyWith(
                    color: AppColors.error,
                  ),
                ),
              ],
              const SizedBox(height: 18),
              Text('商品明细', style: AppTextStyles.titleMedium),
              const SizedBox(height: 8),
              _DocumentLineItem(
                document: document,
                lines: _detail?.lines ?? const [],
              ),
              if (_attachmentsViewModel != null) ...[
                const SizedBox(height: 18),
                AttachmentPanel(viewModel: _attachmentsViewModel!),
              ],
              const SizedBox(height: 18),
              Text('可执行动作', style: AppTextStyles.titleMedium),
              const SizedBox(height: 8),
              _DocumentDetailActions(
                document: document,
                viewModel: viewModel,
                eventBus: eventBus,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

final class _DocumentDetailRow extends StatelessWidget {
  const _DocumentDetailRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(width: 72, child: Text(label, style: AppTextStyles.bodySmall)),
        Expanded(
          child: Text(
            value,
            textAlign: TextAlign.right,
            style: AppTextStyles.bodyMedium,
          ),
        ),
      ],
    );
  }
}

final class _DocumentLineItem extends StatelessWidget {
  const _DocumentLineItem({required this.document, required this.lines});

  final DocumentRecord document;
  final List<DocumentLine> lines;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: AppColors.background,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppColors.border),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: lines.isNotEmpty
            ? Column(
                children: [
                  for (var index = 0; index < lines.length; index++) ...[
                    _AuthoritativeDocumentLine(line: lines[index]),
                    if (index != lines.length - 1) const Divider(height: 16),
                  ],
                ],
              )
            : document.productName.isEmpty
            ? Text('暂无商品明细', style: AppTextStyles.bodySmall)
            : Row(
                children: [
                  Expanded(
                    child: Text(
                      document.productName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppTextStyles.bodyMedium,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Text(
                    'x${document.quantity}',
                    style: AppTextStyles.bodyMedium.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}

final class _AuthoritativeDocumentLine extends StatelessWidget {
  const _AuthoritativeDocumentLine({required this.line});

  final DocumentLine line;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(line.productName, style: AppTextStyles.bodyMedium),
              if (line.productCode.isNotEmpty)
                Text(line.productCode, style: AppTextStyles.bodySmall),
            ],
          ),
        ),
        Text(
          '${line.quantity} ${line.unit}',
          style: AppTextStyles.bodyMedium.copyWith(fontWeight: FontWeight.w700),
        ),
      ],
    );
  }
}

final class _DocumentDetailActions extends StatelessWidget {
  const _DocumentDetailActions({
    required this.document,
    required this.viewModel,
    this.eventBus,
  });

  final DocumentRecord document;
  final DocumentsViewModel viewModel;
  final AppEventBus? eventBus;

  @override
  Widget build(BuildContext context) {
    final actions = <Widget>[
      if (viewModel.canCompleteDocument(document))
        _DocumentDetailActionButton(
          label: '完成单据',
          icon: Icons.check_circle_outline,
          isBusy: viewModel.isCompletingDocument(document),
          onPressed: () => unawaited(
            _confirmAndRun(
              context: context,
              title: '完成单据',
              content: '确认完成 ${document.number}？完成后将执行库存变更。',
              confirmLabel: '确认完成',
              run: () => viewModel.completeDocument(document),
            ),
          ),
        ),
      if (viewModel.canConfirmStocktakeDocument(document))
        _DocumentDetailActionButton(
          label: '确认盘点差异',
          icon: Icons.fact_check_outlined,
          isBusy: viewModel.isCompletingDocument(document),
          onPressed: () => unawaited(
            _confirmAndRun(
              context: context,
              title: '确认盘点差异',
              content: '确认 ${document.number} 的盘点差异？',
              confirmLabel: '确认差异',
              run: () => viewModel.confirmStocktakeDocument(document),
            ),
          ),
        ),
      if (viewModel.canSettleStocktakeDocument(document))
        _DocumentDetailActionButton(
          label: '结转盘点差异',
          icon: Icons.done_all_outlined,
          isBusy: viewModel.isCompletingDocument(document),
          onPressed: () => unawaited(
            _confirmAndRun(
              context: context,
              title: '结转盘点差异',
              content: '确认结转 ${document.number}？结转后将应用库存差异。',
              confirmLabel: '确认结转',
              run: () => viewModel.settleStocktakeDocument(document),
            ),
          ),
        ),
    ];

    if (actions.isEmpty) {
      return Text('当前状态暂无可执行动作', style: AppTextStyles.bodySmall);
    }

    final actionError = viewModel.documentActionError;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (actionError != null) ...[
          DecoratedBox(
            key: const Key('document-detail-action-error'),
            decoration: BoxDecoration(
              color: AppColors.error.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: AppColors.error.withValues(alpha: 0.2)),
            ),
            child: Padding(
              padding: const EdgeInsets.all(10),
              child: Text(
                actionError,
                style: AppTextStyles.bodySmall.copyWith(
                  color: AppColors.error,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
        ],
        for (final action in actions) ...[
          action,
          if (action != actions.last) const SizedBox(height: 8),
        ],
      ],
    );
  }

  Future<void> _confirmAndRun({
    required BuildContext context,
    required String title,
    required String content,
    required String confirmLabel,
    required Future<bool> Function() run,
  }) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text(title),
          content: Text(content),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: Text(confirmLabel),
            ),
          ],
        );
      },
    );

    if (confirmed == true && context.mounted) {
      final succeeded = await run();
      if (succeeded) {
        eventBus?.publish(const GlobalRefreshRequestedEvent());
        if (context.mounted) {
          Navigator.of(context).maybePop();
        }
      }
    }
  }
}

final class _DocumentDetailActionButton extends StatelessWidget {
  const _DocumentDetailActionButton({
    required this.label,
    required this.icon,
    required this.isBusy,
    required this.onPressed,
  });

  final String label;
  final IconData icon;
  final bool isBusy;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return FilledButton.icon(
      onPressed: isBusy ? null : onPressed,
      icon: Icon(icon, size: 18),
      label: Text(isBusy ? '处理中...' : label),
      style: FilledButton.styleFrom(
        backgroundColor: AppColors.primary,
        foregroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
    );
  }
}

final class _DocumentFilters extends StatefulWidget {
  const _DocumentFilters({required this.viewModel});

  final DocumentsViewModel viewModel;

  @override
  State<_DocumentFilters> createState() => _DocumentFiltersState();
}

final class _DocumentFiltersState extends State<_DocumentFilters> {
  late final TextEditingController _startDateController;
  late final TextEditingController _endDateController;
  String? _dateInputError;

  @override
  void initState() {
    super.initState();
    _startDateController = TextEditingController(
      text: _formatDate(widget.viewModel.documentStartDate),
    );
    _endDateController = TextEditingController(
      text: _formatDate(widget.viewModel.documentEndDate),
    );
  }

  @override
  void dispose() {
    _startDateController.dispose();
    _endDateController.dispose();
    super.dispose();
  }

  void _applyDateRange() {
    final startDate = _parseDateInput(_startDateController.text);
    final endDate = _parseDateInput(_endDateController.text);
    if (startDate.hasInvalidInput || endDate.hasInvalidInput) {
      setState(() {
        _dateInputError = '日期格式应为 YYYY-MM-DD';
      });
      return;
    }

    if (_dateInputError != null) {
      setState(() {
        _dateInputError = null;
      });
    }

    widget.viewModel.selectDocumentDateRange(
      startDate: startDate.value,
      endDate: endDate.value,
    );
  }

  _ParsedFilterDate _parseDateInput(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) {
      return const _ParsedFilterDate(value: null, hasInvalidInput: false);
    }

    final match = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(trimmed);
    if (match == null) {
      return const _ParsedFilterDate(value: null, hasInvalidInput: true);
    }

    final year = int.parse(match.group(1)!);
    final month = int.parse(match.group(2)!);
    final day = int.parse(match.group(3)!);
    final parsed = DateTime(year, month, day);
    if (parsed.year != year || parsed.month != month || parsed.day != day) {
      return const _ParsedFilterDate(value: null, hasInvalidInput: true);
    }

    return _ParsedFilterDate(value: parsed, hasInvalidInput: false);
  }

  String _formatDate(DateTime? value) {
    if (value == null) {
      return '';
    }

    final month = value.month.toString().padLeft(2, '0');
    final day = value.day.toString().padLeft(2, '0');
    return '${value.year}-$month-$day';
  }

  @override
  Widget build(BuildContext context) {
    final viewModel = widget.viewModel;
    final statuses = viewModel.documentStatusFilters;

    return RimsCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            key: const Key('document-keyword-filter-field'),
            onChanged: viewModel.updateDocumentKeyword,
            decoration: const InputDecoration(
              labelText: '筛选单据',
              hintText: '输入单号、商品或状态',
              isDense: true,
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: TextField(
                  key: const Key('document-start-date-filter-field'),
                  controller: _startDateController,
                  keyboardType: TextInputType.datetime,
                  onChanged: (_) => _applyDateRange(),
                  decoration: const InputDecoration(
                    labelText: '开始日期',
                    hintText: 'YYYY-MM-DD',
                    isDense: true,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: TextField(
                  key: const Key('document-end-date-filter-field'),
                  controller: _endDateController,
                  keyboardType: TextInputType.datetime,
                  onChanged: (_) => _applyDateRange(),
                  decoration: const InputDecoration(
                    labelText: '结束日期',
                    hintText: 'YYYY-MM-DD',
                    isDense: true,
                  ),
                ),
              ),
            ],
          ),
          if (_dateInputError != null) ...[
            const SizedBox(height: 8),
            Text(
              _dateInputError!,
              style: AppTextStyles.bodySmall.copyWith(color: AppColors.error),
            ),
          ],
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              ChoiceChip(
                key: const Key('document-type-filter-all'),
                label: const Text('全部'),
                selected: viewModel.selectedDocumentTypeFilter == null,
                onSelected: (_) => viewModel.selectDocumentTypeFilter(null),
              ),
              for (final action in viewModel.actions)
                ChoiceChip(
                  key: Key('document-type-filter-${action.docType}'),
                  label: Text(action.label),
                  selected:
                      viewModel.selectedDocumentTypeFilter == action.docType,
                  onSelected: (_) =>
                      viewModel.selectDocumentTypeFilter(action.docType),
                ),
            ],
          ),
          if (statuses.isNotEmpty) ...[
            const SizedBox(height: 10),
            DropdownButtonFormField<String>(
              key: const Key('document-status-filter-field'),
              initialValue: viewModel.selectedDocumentStatusFilter,
              decoration: const InputDecoration(labelText: '状态', isDense: true),
              items: [
                const DropdownMenuItem<String>(
                  value: null,
                  child: Text('全部状态'),
                ),
                for (final status in statuses)
                  DropdownMenuItem<String>(value: status, child: Text(status)),
              ],
              onChanged: viewModel.selectDocumentStatusFilter,
            ),
          ],
        ],
      ),
    );
  }
}

final class _ParsedFilterDate {
  const _ParsedFilterDate({required this.value, required this.hasInvalidInput});

  final DateTime? value;
  final bool hasInvalidInput;
}

final class _DocumentForm extends StatefulWidget {
  const _DocumentForm({
    required this.viewModel,
    this.eventBus,
    this.onScanRequested,
    this.attachmentPicker,
    this.attachmentStagingStore,
    this.attachmentUserId,
  });

  final DocumentsViewModel viewModel;
  final AppEventBus? eventBus;
  final Future<void> Function()? onScanRequested;
  final AttachmentPicker? attachmentPicker;
  final AttachmentStagingStore? attachmentStagingStore;
  final String? attachmentUserId;

  @override
  State<_DocumentForm> createState() => _DocumentFormState();
}

final class _DocumentFormState extends State<_DocumentForm> {
  late final TextEditingController _productController;
  late final TextEditingController _quantityController;
  late final TextEditingController _remarkController;
  DraftAttachmentsViewModel? _draftAttachmentsViewModel;
  String _recoveredAttachmentSignature = '';

  @override
  void initState() {
    super.initState();
    _productController = TextEditingController(
      text: widget.viewModel.productQuery,
    );
    _quantityController = TextEditingController(
      text: widget.viewModel.quantityText,
    );
    _remarkController = TextEditingController(text: widget.viewModel.remark);
    _createDraftAttachmentsViewModel();
    _recoverDraftAttachments();
  }

  @override
  void didUpdateWidget(covariant _DocumentForm oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncController(_productController, widget.viewModel.productQuery);
    _syncController(_quantityController, widget.viewModel.quantityText);
    _syncController(_remarkController, widget.viewModel.remark);
    _recoverDraftAttachments();
  }

  @override
  void dispose() {
    _productController.dispose();
    _quantityController.dispose();
    _remarkController.dispose();
    _draftAttachmentsViewModel?.dispose();
    super.dispose();
  }

  void _createDraftAttachmentsViewModel() {
    final picker = widget.attachmentPicker;
    final stagingStore = widget.attachmentStagingStore;
    final userId = widget.attachmentUserId;
    if (picker == null || stagingStore == null || userId == null) return;
    _draftAttachmentsViewModel = DraftAttachmentsViewModel(
      picker: picker,
      stagingStore: stagingStore,
      userId: userId,
      draftIdProvider: widget.viewModel.ensureDraftId,
      onChanged: widget.viewModel.updateAttachmentStagingIds,
      canMutate: () => !widget.viewModel.isSubmitting,
      mutationEpochProvider: () => widget.viewModel.submissionEpoch,
    );
  }

  void _recoverDraftAttachments() {
    final attachments = _draftAttachmentsViewModel;
    if (attachments == null) return;
    final ids = widget.viewModel.attachmentStagingIds;
    final signature = '${widget.viewModel.activeDraftId}:${ids.join(',')}';
    if (signature == _recoveredAttachmentSignature) return;
    _recoveredAttachmentSignature = signature;
    unawaited(attachments.recover(ids));
  }

  Future<void> _createDocument() async {
    final created = await widget.viewModel.createDocument();
    if (created) {
      widget.eventBus?.publish(const GlobalRefreshRequestedEvent());
    }
  }

  void _syncController(TextEditingController controller, String text) {
    if (controller.text == text) {
      return;
    }
    controller.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
  }

  void _selectProduct(InventoryItem product) {
    widget.viewModel.selectProduct(product);
    _productController.value = TextEditingValue(
      text: product.productName,
      selection: TextSelection.collapsed(offset: product.productName.length),
    );
  }

  @override
  Widget build(BuildContext context) {
    final viewModel = widget.viewModel;

    return RimsCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '新建 ${viewModel.selectedAction.label}',
                  style: AppTextStyles.titleMedium,
                ),
              ),
              SizedBox.square(
                dimension: 24,
                child: IconButton(
                  key: const Key('document-save-draft-button'),
                  tooltip: '保存草稿',
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints.tightFor(
                    width: 24,
                    height: 24,
                  ),
                  iconSize: 20,
                  onPressed: viewModel.isSubmitting
                      ? null
                      : () => unawaited(viewModel.saveDraft()),
                  icon: const Icon(Icons.save_outlined),
                ),
              ),
            ],
          ),
          if (viewModel.draftSaveError case final error?) ...[
            const SizedBox(height: 6),
            Text(
              error,
              key: const Key('document-draft-save-error'),
              style: AppTextStyles.bodySmall.copyWith(color: AppColors.error),
            ),
          ],
          if (viewModel.requiresDraftReview) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                const Icon(Icons.fact_check_outlined, size: 18),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text('角色已变化，提交前需复核', style: AppTextStyles.bodySmall),
                ),
                TextButton(
                  key: const Key('document-confirm-draft-review'),
                  onPressed: viewModel.isSubmitting
                      ? null
                      : viewModel.confirmDraftReview,
                  child: const Text('确认复核'),
                ),
              ],
            ),
          ],
          const SizedBox(height: 12),
          if (viewModel.isConversionAction) ...[
            _NonStandardInventorySelector(viewModel: viewModel),
            const SizedBox(height: 10),
          ],
          Row(
            children: [
              Expanded(
                child: TextField(
                  key: const Key('document-product-field'),
                  controller: _productController,
                  enabled: !viewModel.isSubmitting,
                  onChanged: viewModel.isSubmitting
                      ? null
                      : (value) => unawaited(viewModel.searchProducts(value)),
                  decoration: const InputDecoration(
                    labelText: '商品',
                    hintText: '输入商品名称或 SKU',
                    isDense: true,
                  ),
                ),
              ),
              if (widget.onScanRequested != null) ...[
                const SizedBox(width: 6),
                IconButton(
                  key: const Key('document-scan-product-button'),
                  tooltip: '扫码添加商品',
                  onPressed: viewModel.isSubmitting
                      ? null
                      : () => unawaited(widget.onScanRequested!()),
                  icon: const Icon(Icons.qr_code_scanner),
                ),
              ],
            ],
          ),
          if (viewModel.isSearchingProducts ||
              viewModel.productSearchError != null ||
              viewModel.selectedProduct != null ||
              viewModel.productCandidates.isNotEmpty) ...[
            const SizedBox(height: 8),
            _ProductSearchState(
              viewModel: viewModel,
              onProductSelected: viewModel.isSubmitting ? null : _selectProduct,
            ),
          ],
          if (viewModel.isTransferAction) ...[
            const SizedBox(height: 10),
            _TargetWarehouseSelector(viewModel: viewModel),
          ],
          if (viewModel.isReturnAction) ...[
            const SizedBox(height: 10),
            _ReturnSourceSelector(viewModel: viewModel),
          ],
          const SizedBox(height: 10),
          TextField(
            key: const Key('document-quantity-field'),
            controller: _quantityController,
            enabled: !viewModel.isSubmitting,
            keyboardType: TextInputType.number,
            onChanged: viewModel.isSubmitting ? null : viewModel.updateQuantity,
            decoration: InputDecoration(
              labelText: viewModel.quantityInputLabel,
              hintText: viewModel.quantityInputHint,
              isDense: true,
            ),
          ),
          if (viewModel.selectedProduct != null) ...[
            const SizedBox(height: 8),
            OutlinedButton.icon(
              key: const Key('document-add-line-button'),
              onPressed: viewModel.isSubmitting
                  ? null
                  : () {
                      final quantity = int.tryParse(_quantityController.text);
                      final product = viewModel.selectedProduct;
                      if (quantity != null && product != null) {
                        viewModel.addProductToDraft(
                          product,
                          quantity: quantity,
                        );
                      }
                    },
              icon: const Icon(Icons.playlist_add),
              label: const Text('添加明细'),
            ),
          ],
          if (viewModel.draftLines.isNotEmpty) ...[
            const SizedBox(height: 10),
            for (final line in viewModel.draftLines)
              ListTile(
                key: Key('document-draft-line-${line.productId}'),
                contentPadding: EdgeInsets.zero,
                dense: true,
                title: Text(line.productName),
                subtitle: Text('数量 ${line.quantity}'),
                trailing: IconButton(
                  tooltip: '移除明细',
                  onPressed: viewModel.isSubmitting
                      ? null
                      : () => viewModel.removeDraftLine(line.productId),
                  icon: const Icon(Icons.remove_circle_outline),
                ),
              ),
          ],
          const SizedBox(height: 10),
          TextField(
            key: const Key('document-remark-field'),
            controller: _remarkController,
            enabled: !viewModel.isSubmitting,
            maxLength: 512,
            onChanged: viewModel.isSubmitting ? null : viewModel.updateRemark,
            decoration: const InputDecoration(
              labelText: '备注',
              counterText: '',
              isDense: true,
            ),
          ),
          if (_draftAttachmentsViewModel case final attachments?) ...[
            const SizedBox(height: 10),
            DraftAttachmentPanel(viewModel: attachments),
          ],
          if (viewModel.formError != null) ...[
            const SizedBox(height: 10),
            Text(
              viewModel.formError!,
              style: AppTextStyles.bodySmall.copyWith(
                color: AppColors.error,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
          const SizedBox(height: 14),
          FilledButton(
            key: const Key('document-create-button'),
            onPressed: viewModel.isSubmitting
                ? null
                : () => unawaited(_createDocument()),
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.primary,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
            ),
            child: Text(viewModel.isSubmitting ? '创建中...' : '创建单据'),
          ),
        ],
      ),
    );
  }
}

final class _ProductSearchState extends StatelessWidget {
  const _ProductSearchState({
    required this.viewModel,
    required this.onProductSelected,
  });

  final DocumentsViewModel viewModel;
  final ValueChanged<InventoryItem>? onProductSelected;

  @override
  Widget build(BuildContext context) {
    if (viewModel.isSearchingProducts) {
      return Text('正在搜索商品...', style: AppTextStyles.bodySmall);
    }

    final searchError = viewModel.productSearchError;
    if (searchError != null) {
      return Text(
        searchError,
        style: AppTextStyles.bodySmall.copyWith(color: AppColors.error),
      );
    }

    final selectedProduct = viewModel.selectedProduct;
    if (selectedProduct != null) {
      return _SelectedProductLine(product: selectedProduct);
    }

    return Column(
      children: [
        for (final product in viewModel.productCandidates)
          _ProductCandidateRow(product: product, onSelected: onProductSelected),
      ],
    );
  }
}

final class _NonStandardInventorySelector extends StatelessWidget {
  const _NonStandardInventorySelector({required this.viewModel});

  final DocumentsViewModel viewModel;

  @override
  Widget build(BuildContext context) {
    if (viewModel.isLoadingNonStandardInventory) {
      return Text('正在加载非标库存...', style: AppTextStyles.bodySmall);
    }

    final error = viewModel.nonStandardInventoryError;
    if (error != null) {
      return Text(
        error,
        style: AppTextStyles.bodySmall.copyWith(color: AppColors.error),
      );
    }

    final items = viewModel.nonStandardInventoryItems;
    if (items.isEmpty) {
      return Text(
        '暂无可转换非标库存',
        style: AppTextStyles.bodySmall.copyWith(color: AppColors.error),
      );
    }

    return DropdownButtonFormField<int>(
      key: const Key('document-non-standard-selector'),
      initialValue: viewModel.selectedNonStandardInventory?.id,
      decoration: const InputDecoration(labelText: '非标库存', isDense: true),
      items: [
        for (final item in items)
          DropdownMenuItem<int>(
            value: item.id,
            child: Text(
              '${item.displayName} · 剩余 ${item.remainingQuantity}${item.unit}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
      ],
      onChanged: viewModel.isSubmitting
          ? null
          : (itemId) {
              for (final item in items) {
                if (item.id == itemId) {
                  viewModel.selectNonStandardInventory(item);
                  return;
                }
              }
            },
    );
  }
}

final class _SelectedProductLine extends StatelessWidget {
  const _SelectedProductLine({required this.product});

  final InventoryItem product;

  @override
  Widget build(BuildContext context) {
    return Text(
      '已选择 ${product.productName} · ${product.sku}',
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: AppTextStyles.bodySmall.copyWith(color: AppColors.primary),
    );
  }
}

final class _ProductCandidateRow extends StatelessWidget {
  const _ProductCandidateRow({required this.product, required this.onSelected});

  final InventoryItem product;
  final ValueChanged<InventoryItem>? onSelected;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      key: Key('document-product-option-${product.productId}'),
      onTap: onSelected == null ? null : () => onSelected!(product),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 7),
        child: Row(
          children: [
            Expanded(
              child: Text(
                product.productName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppTextStyles.bodyMedium,
              ),
            ),
            const SizedBox(width: 10),
            Text(product.sku, style: AppTextStyles.bodySmall),
          ],
        ),
      ),
    );
  }
}

final class _TargetWarehouseSelector extends StatelessWidget {
  const _TargetWarehouseSelector({required this.viewModel});

  final DocumentsViewModel viewModel;

  @override
  Widget build(BuildContext context) {
    final targetWarehouses = viewModel.targetWarehouses;

    if (targetWarehouses.isEmpty) {
      return Text(
        '暂无可调拨目标仓库',
        style: AppTextStyles.bodySmall.copyWith(color: AppColors.error),
      );
    }

    return DropdownButtonFormField<int>(
      key: const Key('document-target-warehouse-selector'),
      initialValue: viewModel.selectedTargetWarehouse?.id,
      decoration: const InputDecoration(labelText: '目标仓库', isDense: true),
      items: [
        for (final warehouse in targetWarehouses)
          DropdownMenuItem<int>(
            value: warehouse.id,
            child: Text(
              warehouse.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
      ],
      onChanged: viewModel.isSubmitting
          ? null
          : (warehouseId) {
              for (final warehouse in targetWarehouses) {
                if (warehouse.id == warehouseId) {
                  viewModel.selectTargetWarehouse(warehouse);
                  return;
                }
              }
            },
    );
  }
}

final class _ReturnSourceSelector extends StatelessWidget {
  const _ReturnSourceSelector({required this.viewModel});

  final DocumentsViewModel viewModel;

  @override
  Widget build(BuildContext context) {
    if (viewModel.isLoadingReturnSources) {
      return Text('正在加载可退货销售单...', style: AppTextStyles.bodySmall);
    }

    final error = viewModel.returnSourceError;
    if (error != null) {
      return Text(
        error,
        style: AppTextStyles.bodySmall.copyWith(color: AppColors.error),
      );
    }

    final sourceDocuments = viewModel.returnSourceDocuments;

    if (sourceDocuments.isEmpty) {
      return Text(
        '暂无可退货销售单',
        style: AppTextStyles.bodySmall.copyWith(color: AppColors.error),
      );
    }

    return DropdownButtonFormField<int>(
      key: const Key('document-return-source-selector'),
      initialValue: viewModel.selectedReturnSourceDocument?.id,
      decoration: const InputDecoration(labelText: '原销售单', isDense: true),
      items: [
        for (final document in sourceDocuments)
          DropdownMenuItem<int>(
            value: document.id,
            child: Text(
              document.number,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
      ],
      onChanged: viewModel.isSubmitting
          ? null
          : (documentId) {
              for (final document in sourceDocuments) {
                if (document.id == documentId) {
                  viewModel.selectReturnSourceDocument(document);
                  return;
                }
              }
            },
    );
  }
}

Key? _documentActionKey(DocumentAction action) {
  return switch (action.docType) {
    1 => const Key('document-action-inbound'),
    2 => const Key('document-action-sales'),
    _ => null,
  };
}

final class _RecentDocumentCard extends StatelessWidget {
  const _RecentDocumentCard({
    required this.document,
    required this.viewModel,
    this.eventBus,
    this.onOpenDetail,
  });

  final DocumentRecord document;
  final DocumentsViewModel viewModel;
  final AppEventBus? eventBus;
  final VoidCallback? onOpenDetail;

  @override
  Widget build(BuildContext context) {
    final detailText = document.productName.isEmpty
        ? document.number
        : '${document.number} · ${document.productName} x${document.quantity}';

    return RimsCard(
      key: ValueKey('document-list-item-${document.id}'),
      child: Row(
        children: [
          DecoratedBox(
            decoration: BoxDecoration(
              color: AppColors.primaryLight,
              borderRadius: BorderRadius.circular(8),
            ),
            child: const SizedBox(
              width: 40,
              height: 40,
              child: Icon(Icons.article_outlined, color: AppColors.primary),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: InkWell(
              onTap: onOpenDetail,
              borderRadius: BorderRadius.circular(8),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      document.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppTextStyles.bodyMedium.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      detailText,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppTextStyles.bodySmall,
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(width: 10),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            mainAxisSize: MainAxisSize.min,
            children: [
              RimsStatusChip(
                label: document.status,
                kind: documentStatusKind(document.status),
              ),
              if (viewModel.canCompleteDocument(document)) ...[
                const SizedBox(height: 6),
                _LifecycleButton(
                  key: Key('document-complete-${document.id}'),
                  label: '完成',
                  busyLabel: '完成中',
                  isBusy: viewModel.isCompletingDocument(document),
                  onPressed: () => unawaited(
                    _confirmAndRun(
                      context: context,
                      title: '完成单据',
                      content: '确认完成 ${document.number}？完成后将执行库存变更。',
                      confirmLabel: '确认完成',
                      run: () => viewModel.completeDocument(document),
                    ),
                  ),
                ),
              ],
              if (viewModel.canConfirmStocktakeDocument(document)) ...[
                const SizedBox(height: 6),
                _LifecycleButton(
                  key: Key('document-confirm-${document.id}'),
                  label: '确认差异',
                  busyLabel: '确认中',
                  isBusy: viewModel.isCompletingDocument(document),
                  onPressed: () => unawaited(
                    _confirmAndRun(
                      context: context,
                      title: '确认盘点差异',
                      content: '确认 ${document.number} 的盘点差异？',
                      confirmLabel: '确认差异',
                      run: () => viewModel.confirmStocktakeDocument(document),
                    ),
                  ),
                ),
              ],
              if (viewModel.canSettleStocktakeDocument(document)) ...[
                const SizedBox(height: 6),
                _LifecycleButton(
                  key: Key('document-settle-${document.id}'),
                  label: '结转',
                  busyLabel: '结转中',
                  isBusy: viewModel.isCompletingDocument(document),
                  onPressed: () => unawaited(
                    _confirmAndRun(
                      context: context,
                      title: '结转盘点差异',
                      content: '确认结转 ${document.number}？结转后将应用库存差异。',
                      confirmLabel: '确认结转',
                      run: () => viewModel.settleStocktakeDocument(document),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _confirmAndRun({
    required BuildContext context,
    required String title,
    required String content,
    required String confirmLabel,
    required Future<bool> Function() run,
  }) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text(title),
          content: Text(content),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: Text(confirmLabel),
            ),
          ],
        );
      },
    );

    if (confirmed == true && context.mounted) {
      final succeeded = await run();
      if (succeeded) {
        eventBus?.publish(const GlobalRefreshRequestedEvent());
      }
    }
  }
}

final class _TransactionRecordCard extends StatelessWidget {
  const _TransactionRecordCard({required this.transaction});

  final TransactionRecord transaction;

  @override
  Widget build(BuildContext context) {
    final detailText =
        '商品ID ${transaction.productId} · ${transaction.beforeQty} -> '
        '${transaction.afterQty}';

    return RimsCard(
      child: Row(
        children: [
          DecoratedBox(
            decoration: BoxDecoration(
              color: _directionColor.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(8),
            ),
            child: SizedBox(
              width: 40,
              height: 40,
              child: Icon(_directionIcon, color: _directionColor),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${transaction.docTypeName} · ${transaction.docNo}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppTextStyles.bodyMedium.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  detailText,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppTextStyles.bodySmall,
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            mainAxisSize: MainAxisSize.min,
            children: [
              RimsStatusChip(
                label: transaction.directionLabel,
                kind: _statusKind,
              ),
              const SizedBox(height: 4),
              Text(
                'x${transaction.quantity}',
                style: AppTextStyles.bodySmall.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Color get _directionColor {
    return switch (transaction.direction) {
      1 => AppColors.success,
      -1 => AppColors.warning,
      _ => AppColors.primary,
    };
  }

  IconData get _directionIcon {
    return switch (transaction.direction) {
      1 => Icons.call_received,
      -1 => Icons.call_made,
      _ => Icons.swap_vert,
    };
  }

  RimsStatusKind get _statusKind {
    return switch (transaction.direction) {
      1 => RimsStatusKind.success,
      -1 => RimsStatusKind.warning,
      _ => RimsStatusKind.info,
    };
  }
}

final class _LifecycleButton extends StatelessWidget {
  const _LifecycleButton({
    required this.label,
    required this.busyLabel,
    required this.isBusy,
    required this.onPressed,
    super.key,
  });

  final String label;
  final String busyLabel;
  final bool isBusy;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 30,
      child: TextButton(
        onPressed: isBusy ? null : onPressed,
        style: TextButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
        child: Text(isBusy ? busyLabel : label),
      ),
    );
  }
}
