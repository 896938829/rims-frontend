import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:rims_frontend/features/scanner/data/mobile_scanner_capability.dart';
import 'package:rims_frontend/features/scanner/data/system_scan_feedback.dart';
import 'package:rims_frontend/features/scanner/domain/entities/scan_data.dart';
import 'package:rims_frontend/features/scanner/domain/services/barcode_scanner_capability.dart';
import 'package:rims_frontend/features/scanner/domain/services/scan_feedback_capability.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late MobileScannerPlatform originalPlatform;
  late _FakeMobileScannerPlatform platform;

  setUp(() {
    originalPlatform = MobileScannerPlatform.instance;
    platform = _FakeMobileScannerPlatform();
    MobileScannerPlatform.instance = platform;
  });

  tearDown(() {
    MobileScannerPlatform.instance = originalPlatform;
  });

  MobileScannerCapability createCapability() {
    final capability = MobileScannerCapability(
      now: () => DateTime.utc(2026, 7, 13, 8),
    );
    // The plugin widget normally performs this attachment in initState.
    // ignore: invalid_use_of_internal_member
    capability.controller.attach();
    return capability;
  }

  test('uses the required controller configuration', () async {
    final capability = createCapability();

    expect(capability.controller.autoStart, isFalse);
    expect(capability.controller.detectionSpeed, DetectionSpeed.unrestricted);

    await capability.dispose();
  });

  test('maps every plugin capture barcode into domain scan data', () async {
    final capability = createCapability();
    final scans = <ScanData>[];
    final subscription = capability.scans.listen(scans.add);
    await capability.start();

    platform.emit(
      const BarcodeCapture(
        barcodes: <Barcode>[
          Barcode(rawValue: '128', format: BarcodeFormat.code128),
          Barcode(rawValue: '39', format: BarcodeFormat.code39),
          Barcode(rawValue: '13', format: BarcodeFormat.ean13),
          Barcode(rawValue: '8', format: BarcodeFormat.ean8),
          Barcode(rawValue: 'qr', format: BarcodeFormat.qrCode),
          Barcode(rawValue: 'other', format: BarcodeFormat.pdf417),
          Barcode(format: BarcodeFormat.code128),
        ],
      ),
    );
    await _flushEvents();

    expect(scans.map((scan) => scan.value), [
      '128',
      '39',
      '13',
      '8',
      'qr',
      'other',
    ]);
    expect(scans.map((scan) => scan.format), [
      ScanCodeFormat.code128,
      ScanCodeFormat.code39,
      ScanCodeFormat.ean13,
      ScanCodeFormat.ean8,
      ScanCodeFormat.qrCode,
      ScanCodeFormat.unknown,
    ]);
    expect(
      scans.map((scan) => scan.capturedAt),
      everyElement(DateTime.utc(2026, 7, 13, 8)),
    );

    await subscription.cancel();
    await capability.dispose();
  });

  test('publishes permission denied and recovers to ready on retry', () async {
    final capability = createCapability();
    final states = <ScannerAccessState>[];
    final scans = <ScanData>[];
    final subscription = capability.accessStates.listen(states.add);
    final scanSubscription = capability.scans.listen(scans.add);
    platform.startErrors.add(MobileScannerErrorCode.permissionDenied);

    await capability.start();
    expect(capability.accessState, ScannerAccessState.permissionDenied);

    await capability.start();
    expect(capability.accessState, ScannerAccessState.ready);
    await _flushEvents();
    expect(states, [
      ScannerAccessState.permissionDenied,
      ScannerAccessState.ready,
    ]);
    platform.emit(
      const BarcodeCapture(barcodes: [Barcode(rawValue: 'recovered')]),
    );
    await _flushEvents();
    expect(scans.map((scan) => scan.value), ['recovered']);

    await subscription.cancel();
    await scanSubscription.cancel();
    await capability.dispose();
  });

  test('maps an unsupported camera and generic failures', () async {
    final capability = createCapability();
    platform.startErrors.addAll([
      MobileScannerErrorCode.unsupported,
      MobileScannerErrorCode.genericError,
    ]);

    await capability.start();
    expect(capability.accessState, ScannerAccessState.unsupported);
    await capability.start();
    expect(capability.accessState, ScannerAccessState.unavailable);

    await capability.dispose();
  });

  test('serializes start and stop lifecycle calls', () async {
    final capability = createCapability();
    final startGate = Completer<MobileScannerViewAttributes>();
    platform.startGates.add(startGate);

    final starting = capability.start();
    final stopping = capability.stop();
    await _flushEvents();

    expect(platform.events, ['start']);
    startGate.complete(platform.defaultAttributes);
    await Future.wait([starting, stopping]);

    expect(platform.events, ['start', 'stop']);
    await capability.dispose();
  });

  test(
    'reflects permission revocation and restoration across restarts',
    () async {
      final capability = createCapability();

      await capability.start();
      expect(capability.accessState, ScannerAccessState.ready);
      await capability.stop();

      platform.startErrors.add(MobileScannerErrorCode.permissionDenied);
      await capability.start();
      expect(capability.accessState, ScannerAccessState.permissionDenied);

      await capability.start();
      expect(capability.accessState, ScannerAccessState.ready);

      await capability.dispose();
    },
  );

  test('calls after dispose are safe and do not touch the plugin', () async {
    final capability = createCapability();
    await capability.start();
    await capability.dispose();
    final eventsAfterDispose = List<String>.of(platform.events);

    await capability.start();
    await capability.stop();
    await capability.setTorch(true);
    await capability.setZoom(0.5);
    await capability.focus(0.5, 0.5);
    await capability.dispose();

    expect(platform.events, eventsAfterDispose);
  });

  test(
    'maps torch, clamped zoom, and normalized focus to the plugin',
    () async {
      final capability = createCapability();
      await capability.start();

      await capability.setTorch(true);
      await capability.setTorch(true);
      await capability.setTorch(false);
      await capability.setZoom(1.4);
      await capability.focus(-0.2, 1.4);

      expect(platform.torchToggleCount, 2);
      expect(platform.zoomValues, [1.0]);
      expect(platform.focusPoints, [const Offset(0, 1)]);

      await capability.dispose();
    },
  );

  test('dispose closes forwarded scan and access-state streams', () async {
    final capability = createCapability();
    final scansDone = expectLater(capability.scans, emitsDone);
    final statesDone = expectLater(capability.accessStates, emitsDone);

    await capability.dispose();

    await scansDone;
    await statesDone;
    expect(platform.barcodeController.hasListener, isFalse);
  });

  group('SystemScanFeedback', () {
    test('sound and vibration can be enabled independently', () async {
      final calls = <String>[];
      final feedback = SystemScanFeedback(
        playSound: (_) async => calls.add('sound'),
        vibrate: (_) async => calls.add('vibration'),
      );

      await feedback.play(
        ScanFeedbackKind.accepted,
        sound: true,
        vibration: false,
      );
      await feedback.play(
        ScanFeedbackKind.rejected,
        sound: false,
        vibration: true,
      );

      expect(calls, ['sound', 'vibration']);
    });

    test(
      'one feedback failure does not suppress the other or escape',
      () async {
        var vibrationCalls = 0;
        final feedback = SystemScanFeedback(
          playSound: (_) => Future<void>.error(StateError('sound unavailable')),
          vibrate: (_) async => vibrationCalls += 1,
        );

        await expectLater(
          feedback.play(
            ScanFeedbackKind.completed,
            sound: true,
            vibration: true,
          ),
          completes,
        );
        expect(vibrationCalls, 1);
      },
    );
  });
}

Future<void> _flushEvents() => Future<void>.delayed(Duration.zero);

final class _FakeMobileScannerPlatform extends MobileScannerPlatform {
  final barcodeController = StreamController<BarcodeCapture?>.broadcast();
  final torchController = StreamController<TorchState>.broadcast();
  final zoomController = StreamController<double>.broadcast();
  final List<MobileScannerErrorCode> startErrors = [];
  final List<Completer<MobileScannerViewAttributes>> startGates = [];
  final List<String> events = [];
  final List<double> zoomValues = [];
  final List<Offset> focusPoints = [];
  int torchToggleCount = 0;
  TorchState torchState = TorchState.off;

  MobileScannerViewAttributes get defaultAttributes =>
      MobileScannerViewAttributes(
        cameraDirection: CameraFacing.back,
        currentTorchMode: torchState,
        size: const Size(640, 480),
        numberOfCameras: 1,
      );

  @override
  Stream<BarcodeCapture?> get barcodesStream => barcodeController.stream;

  @override
  Stream<TorchState> get torchStateStream => torchController.stream;

  @override
  Stream<double> get zoomScaleStateStream => zoomController.stream;

  @override
  Future<MobileScannerViewAttributes> start(StartOptions startOptions) async {
    events.add('start');
    if (startErrors.isNotEmpty) {
      final code = startErrors.removeAt(0);
      throw MobileScannerException(errorCode: code);
    }
    if (startGates.isNotEmpty) return startGates.removeAt(0).future;
    return defaultAttributes;
  }

  @override
  Future<void> stop() async {
    events.add('stop');
  }

  @override
  Future<void> toggleTorch() async {
    events.add('torch');
    torchToggleCount += 1;
    torchState = torchState == TorchState.on ? TorchState.off : TorchState.on;
    torchController.add(torchState);
    await _flushEvents();
  }

  @override
  Future<void> setZoomScale(double zoomScale) async {
    events.add('zoom');
    zoomValues.add(zoomScale);
  }

  @override
  Future<void> setFocusPoint(Offset position) async {
    events.add('focus');
    focusPoints.add(position);
  }

  void emit(BarcodeCapture capture) => barcodeController.add(capture);

  @override
  Future<void> dispose() async {
    events.add('dispose');
    await Future.wait([
      barcodeController.close(),
      torchController.close(),
      zoomController.close(),
    ]);
  }
}
