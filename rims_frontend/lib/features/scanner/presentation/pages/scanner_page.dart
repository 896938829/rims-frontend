import 'dart:async';

import 'package:flutter/material.dart';

import '../../../../core/result/failure.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../inventory/domain/entities/inventory_item.dart';
import '../../domain/entities/scan_data.dart';
import '../../domain/services/barcode_scanner_capability.dart';
import '../view_models/scan_session_view_model.dart';
import '../widgets/scanner_viewport.dart';

final class ScannerPage extends StatefulWidget {
  const ScannerPage({
    required this.viewModel,
    required this.scanner,
    required this.camera,
    this.onOpenSettings,
    this.returnSingleResult = false,
    super.key,
  });

  final ScanSessionViewModel viewModel;
  final BarcodeScannerCapability scanner;
  final Widget camera;
  final VoidCallback? onOpenSettings;
  final bool returnSingleResult;

  @override
  State<ScannerPage> createState() => _ScannerPageState();
}

final class _ScannerPageState extends State<ScannerPage>
    with WidgetsBindingObserver {
  final TextEditingController _manualController = TextEditingController();
  StreamSubscription<ScanData>? _scanSubscription;
  StreamSubscription<ScannerAccessState>? _accessSubscription;
  late ScannerAccessState _access;
  bool _torchEnabled = false;
  bool _isReturning = false;
  double _zoom = 0;

  @override
  void initState() {
    super.initState();
    _access = widget.scanner.accessState;
    WidgetsBinding.instance.addObserver(this);
    _scanSubscription = widget.scanner.scans.listen(
      (scan) => unawaited(widget.viewModel.accept(scan)),
    );
    _accessSubscription = widget.scanner.accessStates.listen((access) {
      if (mounted) setState(() => _access = access);
    });
    widget.viewModel.addListener(_returnSingleResult);
    unawaited(widget.viewModel.restore());
    unawaited(_start());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_start());
    } else if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached ||
        state == AppLifecycleState.hidden) {
      unawaited(widget.scanner.stop());
    }
  }

  Future<void> _start() async {
    try {
      await widget.scanner.start();
      if (mounted) setState(() => _access = widget.scanner.accessState);
    } on DevicePermissionFailure {
      if (mounted) {
        setState(() => _access = ScannerAccessState.permissionDenied);
      }
    } on UnsupportedError {
      if (mounted) setState(() => _access = ScannerAccessState.unsupported);
    } on Object {
      if (mounted) setState(() => _access = ScannerAccessState.unavailable);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.viewModel.removeListener(_returnSingleResult);
    _manualController.dispose();
    unawaited(_scanSubscription?.cancel());
    unawaited(_accessSubscription?.cancel());
    unawaited(widget.scanner.stop());
    unawaited(widget.scanner.dispose());
    super.dispose();
  }

  void _returnSingleResult() {
    if (_isReturning ||
        !widget.returnSingleResult ||
        !mounted ||
        widget.viewModel.mode != ScanMode.single ||
        !widget.viewModel.isComplete ||
        widget.viewModel.lines.isEmpty ||
        widget.viewModel.lines.single.isStale) {
      return;
    }
    _isReturning = true;
    final item = widget.viewModel.lines.single.item;
    unawaited(_clearAndReturn(item));
  }

  Future<void> _clearAndReturn(InventoryItem item) async {
    try {
      await widget.viewModel.clear();
    } on Object {
      // Returning a consumed result must not be blocked by local cleanup.
    }
    if (mounted) Navigator.of(context).pop(item);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('扫码作业')),
      body: SafeArea(
        child: AnimatedBuilder(
          animation: widget.viewModel,
          builder: (context, _) => ListView(
            key: const Key('scanner-page'),
            padding: const EdgeInsets.only(bottom: 24),
            children: [
              ScannerViewport(
                camera: widget.camera,
                overlayMessage: _overlayMessage,
                overlayKey: widget.viewModel.isLookingUp
                    ? const Key('scanner-lookup-progress')
                    : null,
                overlayAction: _access == ScannerAccessState.ready
                    ? null
                    : _AccessActions(
                        access: _access,
                        onRetry: _start,
                        onOpenSettings: widget.onOpenSettings,
                      ),
                onFocus: _access == ScannerAccessState.ready
                    ? (point) =>
                          unawaited(widget.scanner.focus(point.dx, point.dy))
                    : null,
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SegmentedButton<ScanMode>(
                      key: const Key('scanner-mode-control'),
                      showSelectedIcon: false,
                      segments: const [
                        ButtonSegment(
                          value: ScanMode.single,
                          label: Text('单次'),
                        ),
                        ButtonSegment(
                          value: ScanMode.continuous,
                          label: Text('连续'),
                        ),
                        ButtonSegment(value: ScanMode.batch, label: Text('批量')),
                        ButtonSegment(
                          value: ScanMode.quantity,
                          label: Text('计数'),
                        ),
                      ],
                      selected: {widget.viewModel.mode},
                      onSelectionChanged: (selection) =>
                          widget.viewModel.setMode(selection.single),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        IconButton.filledTonal(
                          key: const Key('scanner-torch-button'),
                          tooltip: '手电筒',
                          onPressed: _access == ScannerAccessState.ready
                              ? _toggleTorch
                              : null,
                          icon: Icon(
                            _torchEnabled
                                ? Icons.flashlight_on
                                : Icons.flashlight_off,
                          ),
                        ),
                        const SizedBox(width: 12),
                        const Icon(Icons.zoom_out, size: 20),
                        Expanded(
                          child: Slider(
                            key: const Key('scanner-zoom-slider'),
                            value: _zoom,
                            onChanged: _access == ScannerAccessState.ready
                                ? (value) {
                                    setState(() => _zoom = value);
                                    unawaited(widget.scanner.setZoom(value));
                                  }
                                : null,
                          ),
                        ),
                        const Icon(Icons.zoom_in, size: 20),
                      ],
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      key: const Key('scanner-manual-input'),
                      controller: _manualController,
                      textInputAction: TextInputAction.done,
                      decoration: InputDecoration(
                        labelText: '手动输入条码',
                        suffixIcon: IconButton(
                          key: const Key('scanner-manual-submit'),
                          tooltip: '查询',
                          icon: const Icon(Icons.search),
                          onPressed: _submitManual,
                        ),
                      ),
                      onSubmitted: (_) => _submitManual(),
                    ),
                    if (widget.viewModel.message case final message?) ...[
                      const SizedBox(height: 10),
                      Text(
                        message,
                        key: const Key('scanner-feedback-message'),
                        style: TextStyle(
                          color: widget.viewModel.issue == null
                              ? AppColors.textSecondary
                              : AppColors.error,
                        ),
                      ),
                    ],
                    if (widget.viewModel.lines.isNotEmpty) ...[
                      const SizedBox(height: 16),
                      ...widget.viewModel.lines.map(
                        (line) => ListTile(
                          key: ValueKey('scanner-line-${line.item.productId}'),
                          contentPadding: EdgeInsets.zero,
                          title: Text(line.item.productName),
                          subtitle: Text(
                            '${line.item.sku}${line.isStale ? ' · 离线身份' : ''}',
                          ),
                          trailing: Text('x${line.quantity}'),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String? get _overlayMessage {
    if (widget.viewModel.isLookingUp) return '正在查询条码...';
    return switch (_access) {
      ScannerAccessState.ready => null,
      ScannerAccessState.permissionDenied => '需要相机权限才能扫描条码',
      ScannerAccessState.unsupported => '此设备不支持相机扫码',
      ScannerAccessState.unavailable => '相机暂时不可用',
    };
  }

  Future<void> _toggleTorch() async {
    final next = !_torchEnabled;
    await widget.scanner.setTorch(next);
    if (mounted) setState(() => _torchEnabled = next);
  }

  void _submitManual() {
    unawaited(
      widget.viewModel.accept(
        ScanData(
          value: _manualController.text,
          format: ScanCodeFormat.code128,
          capturedAt: DateTime.now(),
        ),
      ),
    );
  }
}

final class _AccessActions extends StatelessWidget {
  const _AccessActions({
    required this.access,
    required this.onRetry,
    this.onOpenSettings,
  });

  final ScannerAccessState access;
  final Future<void> Function() onRetry;
  final VoidCallback? onOpenSettings;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Row(
        children: [
          FilledButton.icon(
            key: const Key('scanner-permission-retry'),
            onPressed: onRetry,
            icon: const Icon(Icons.refresh),
            label: const Text('重试'),
          ),
          if (access == ScannerAccessState.permissionDenied &&
              onOpenSettings != null) ...[
            const SizedBox(width: 10),
            OutlinedButton.icon(
              key: const Key('scanner-open-settings'),
              onPressed: onOpenSettings,
              icon: const Icon(Icons.settings),
              label: const Text('系统设置'),
            ),
          ],
        ],
      ),
    );
  }
}
