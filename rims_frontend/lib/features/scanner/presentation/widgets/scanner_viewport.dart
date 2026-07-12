import 'package:flutter/material.dart';

import '../../../../core/theme/app_colors.dart';

final class ScannerViewport extends StatelessWidget {
  const ScannerViewport({
    required this.camera,
    this.overlayMessage,
    this.overlayKey,
    this.overlayAction,
    this.onFocus,
    super.key,
  });

  final Widget camera;
  final String? overlayMessage;
  final Key? overlayKey;
  final Widget? overlayAction;
  final ValueChanged<Offset>? onFocus;

  @override
  Widget build(BuildContext context) {
    return AspectRatio(
      aspectRatio: 4 / 3,
      child: LayoutBuilder(
        builder: (context, constraints) {
          return GestureDetector(
            key: const Key('scanner-viewport'),
            behavior: HitTestBehavior.opaque,
            onTapUp: onFocus == null
                ? null
                : (details) => onFocus!(
                    Offset(
                      (details.localPosition.dx / constraints.maxWidth).clamp(
                        0,
                        1,
                      ),
                      (details.localPosition.dy / constraints.maxHeight).clamp(
                        0,
                        1,
                      ),
                    ),
                  ),
            child: Stack(
              fit: StackFit.expand,
              children: [
                ColoredBox(color: Colors.black, child: camera),
                IgnorePointer(
                  child: CustomPaint(painter: const _ScanFramePainter()),
                ),
                if (overlayMessage case final message?)
                  ColoredBox(
                    color: Colors.black.withValues(alpha: 0.72),
                    child: Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              message,
                              key: overlayKey,
                              textAlign: TextAlign.center,
                              style: Theme.of(context).textTheme.titleMedium
                                  ?.copyWith(color: Colors.white),
                            ),
                            if (overlayAction case final action?) ...[
                              const SizedBox(height: 16),
                              action,
                            ],
                          ],
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }
}

final class _ScanFramePainter extends CustomPainter {
  const _ScanFramePainter();

  @override
  void paint(Canvas canvas, Size size) {
    final frame = Rect.fromCenter(
      center: size.center(Offset.zero),
      width: size.width * 0.7,
      height: size.height * 0.42,
    );
    final paint = Paint()
      ..color = AppColors.primary
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3;
    canvas.drawRRect(
      RRect.fromRectAndRadius(frame, const Radius.circular(8)),
      paint,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
