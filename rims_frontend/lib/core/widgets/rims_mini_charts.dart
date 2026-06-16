import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import '../theme/app_text_styles.dart';

final class RimsLineChart extends StatelessWidget {
  const RimsLineChart({
    required this.values,
    this.color = const Color(0xFF0F6BFF),
    super.key,
  });

  final List<double> values;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: const Size(double.infinity, 120),
      painter: _RimsLineChartPainter(values: values, color: color),
    );
  }
}

final class RimsRingChart extends StatelessWidget {
  const RimsRingChart({
    required this.segments,
    required this.centerLabel,
    super.key,
  });

  final List<RimsRingSegment> segments;
  final String centerLabel;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 132,
      height: 132,
      child: Stack(
        alignment: Alignment.center,
        children: [
          CustomPaint(
            size: const Size.square(132),
            painter: _RimsRingChartPainter(segments: segments),
          ),
          Text(
            centerLabel,
            textAlign: TextAlign.center,
            style: AppTextStyles.titleMedium,
          ),
        ],
      ),
    );
  }
}

final class RimsRingSegment {
  const RimsRingSegment({
    required this.label,
    required this.value,
    required this.color,
  });

  final String label;
  final double value;
  final Color color;
}

final class _RimsLineChartPainter extends CustomPainter {
  const _RimsLineChartPainter({required this.values, required this.color});

  final List<double> values;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final chartWidth = size.width.isFinite ? size.width : 0.0;
    final chartHeight = size.height.isFinite ? size.height : 0.0;
    if (chartWidth <= 0 || chartHeight <= 0) {
      return;
    }

    final gridPaint = Paint()
      ..color = AppColors.border
      ..strokeWidth = 1;
    final baselineY = chartHeight - 14;
    canvas.drawLine(
      Offset(0, baselineY),
      Offset(chartWidth, baselineY),
      gridPaint,
    );

    final points = values.where((value) => value.isFinite).toList();
    if (points.isEmpty) {
      return;
    }

    final minValue = points.reduce(math.min);
    final maxValue = points.reduce(math.max);
    final span = maxValue - minValue;
    final usableHeight = math.max(1.0, chartHeight - 28);
    final stepX = points.length == 1 ? 0.0 : chartWidth / (points.length - 1);

    Offset pointFor(int index, double value) {
      final normalized = span == 0 ? 0.5 : (value - minValue) / span;
      return Offset(index * stepX, 14 + (1 - normalized) * usableHeight);
    }

    final path = Path()
      ..moveTo(pointFor(0, points.first).dx, pointFor(0, points.first).dy);
    for (var index = 1; index < points.length; index += 1) {
      final point = pointFor(index, points[index]);
      path.lineTo(point.dx, point.dy);
    }

    final fillPath = Path.from(path)
      ..lineTo(chartWidth, baselineY)
      ..lineTo(0, baselineY)
      ..close();
    canvas.drawPath(fillPath, Paint()..color = color.withValues(alpha: 0.10));

    final linePaint = Paint()
      ..color = color
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3;
    canvas.drawPath(path, linePaint);

    final dotPaint = Paint()..color = color;
    for (var index = 0; index < points.length; index += 1) {
      canvas.drawCircle(pointFor(index, points[index]), 3.5, dotPaint);
    }
  }

  @override
  bool shouldRepaint(covariant _RimsLineChartPainter oldDelegate) {
    return oldDelegate.values != values || oldDelegate.color != color;
  }
}

final class _RimsRingChartPainter extends CustomPainter {
  const _RimsRingChartPainter({required this.segments});

  final List<RimsRingSegment> segments;

  @override
  void paint(Canvas canvas, Size size) {
    final diameter = math.min(size.width, size.height);
    if (!diameter.isFinite || diameter <= 0) {
      return;
    }

    final rect =
        Offset((size.width - diameter) / 2, (size.height - diameter) / 2) &
        Size.square(diameter);
    final strokeWidth = math.max(8.0, diameter * 0.12);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = strokeWidth;

    canvas.drawArc(
      rect.deflate(strokeWidth / 2),
      -math.pi / 2,
      math.pi * 2,
      false,
      paint..color = AppColors.border,
    );

    final validSegments = segments
        .where((segment) => segment.value.isFinite && segment.value > 0)
        .toList();
    final total = validSegments.fold<double>(
      0,
      (sum, segment) => sum + segment.value,
    );
    if (total <= 0) {
      return;
    }

    var startAngle = -math.pi / 2;
    for (final segment in validSegments) {
      final sweepAngle = math.pi * 2 * (segment.value / total);
      canvas.drawArc(
        rect.deflate(strokeWidth / 2),
        startAngle,
        math.max(0, sweepAngle - 0.05),
        false,
        paint..color = segment.color,
      );
      startAngle += sweepAngle;
    }
  }

  @override
  bool shouldRepaint(covariant _RimsRingChartPainter oldDelegate) {
    return oldDelegate.segments != segments;
  }
}
