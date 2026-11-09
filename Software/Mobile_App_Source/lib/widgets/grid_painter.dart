import 'package:flutter/material.dart';

// ─────────────────────────────────────────────────────────────────────────────
// GridPainter  – updated to accept custom boundaries + selected highlight
// ─────────────────────────────────────────────────────────────────────────────
 class GridPainter extends CustomPainter {
   final List<double> colBoundaries;
   final List<double> rowBoundaries;
   final int? selectedBoundaryIndex;
   final bool selectedBoundaryIsCol;
   final bool showIsolationBox;
   final double lineLengthScale;

   static const double _trayWidthCm = 39.5;
   static const double _trayHeightCm = 39.0;

   GridPainter({
     required this.colBoundaries,
     required this.rowBoundaries,
     this.selectedBoundaryIndex,
     this.selectedBoundaryIsCol = true,
     this.showIsolationBox = false,
     this.lineLengthScale = 1.0,
   });

  @override
  void paint(Canvas canvas, Size size) {
    final gridPaint = Paint()
      ..color = const Color(0xFF00E676).withAlpha(128)
      ..strokeWidth = 1;

    // Working area derived from outer boundaries
    final workLeft = (colBoundaries.first / _trayWidthCm) * size.width;
    final workRight = (colBoundaries.last / _trayWidthCm) * size.width;
    final workTop = (rowBoundaries.first / _trayHeightCm) * size.height;
    final workBottom = (rowBoundaries.last / _trayHeightCm) * size.height;

    // Compute scaled line endpoints (centered)
    final vSpan = workBottom - workTop;
    final hSpan = workRight - workLeft;
    final vOffset = vSpan * (1 - lineLengthScale) / 2;
    final hOffset = hSpan * (1 - lineLengthScale) / 2;
    final lineTop = workTop + vOffset;
    final lineBottom = workBottom - vOffset;
    final lineLeft = workLeft + hOffset;
    final lineRight = workRight - hOffset;

    // Draw interior column lines (vertical)
    for (int i = 1; i < colBoundaries.length - 1; i++) {
      final x = (colBoundaries[i] / _trayWidthCm) * size.width;
      final isSelected =
          selectedBoundaryIndex == i && selectedBoundaryIsCol;
      canvas.drawLine(
        Offset(x, lineTop),
        Offset(x, lineBottom),
        isSelected
            ? (Paint()
              ..color = const Color(0xFFFFD54F)
              ..strokeWidth = 2.5)
            : gridPaint,
      );
    }

    // Draw interior row lines (horizontal)
    for (int i = 1; i < rowBoundaries.length - 1; i++) {
      final y = (rowBoundaries[i] / _trayHeightCm) * size.height;
      final isSelected =
          selectedBoundaryIndex == i && !selectedBoundaryIsCol;
      canvas.drawLine(
        Offset(lineLeft, y),
        Offset(lineRight, y),
        isSelected
            ? (Paint()
              ..color = const Color(0xFFFFD54F)
              ..strokeWidth = 2.5)
            : gridPaint,
      );
    }

    // Outer boundary selection highlights (first / last) — also scaled
    if (selectedBoundaryIndex == 0 && selectedBoundaryIsCol) {
      canvas.drawLine(Offset(lineLeft, lineTop), Offset(lineLeft, lineBottom),
          Paint()..color = const Color(0xFFFFD54F)..strokeWidth = 2.5);
    }
    if (selectedBoundaryIndex == colBoundaries.length - 1 &&
        selectedBoundaryIsCol) {
      canvas.drawLine(Offset(lineRight, lineTop), Offset(lineRight, lineBottom),
          Paint()..color = const Color(0xFFFFD54F)..strokeWidth = 2.5);
    }
    if (selectedBoundaryIndex == 0 && !selectedBoundaryIsCol) {
      canvas.drawLine(Offset(lineLeft, lineTop), Offset(lineRight, lineTop),
          Paint()..color = const Color(0xFFFFD54F)..strokeWidth = 2.5);
    }
    if (selectedBoundaryIndex == rowBoundaries.length - 1 &&
        !selectedBoundaryIsCol) {
      canvas.drawLine(
          Offset(lineLeft, lineBottom), Offset(lineRight, lineBottom),
          Paint()..color = const Color(0xFFFFD54F)..strokeWidth = 2.5);
    }

    // Grid border (full work area)
    final borderPaint = Paint()
      ..color = const Color(0xFF00E676)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    canvas.drawRect(
      Rect.fromLTRB(workLeft, workTop, workRight, workBottom),
      borderPaint,
    );

    // Isolation box highlight (shown after Save)
    if (showIsolationBox) {
      final isoPaint = Paint()
        ..color = const Color(0xFF2979FF)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3;
      // Draw with corner markers
      canvas.drawRect(
        Rect.fromLTRB(workLeft - 4, workTop - 4, workRight + 4, workBottom + 4),
        isoPaint,
      );
      // Corner accents
      const cornerLen = 14.0;
      final cornerPaint = Paint()
        ..color = const Color(0xFF2979FF)
        ..strokeWidth = 3
        ..strokeCap = StrokeCap.round;
      // TL
      canvas.drawLine(Offset(workLeft - 4, workTop + cornerLen),
          Offset(workLeft - 4, workTop - 4), cornerPaint);
      canvas.drawLine(Offset(workLeft - 4, workTop - 4),
          Offset(workLeft + cornerLen, workTop - 4), cornerPaint);
      // TR
      canvas.drawLine(Offset(workRight + 4, workTop + cornerLen),
          Offset(workRight + 4, workTop - 4), cornerPaint);
      canvas.drawLine(Offset(workRight + 4, workTop - 4),
          Offset(workRight - cornerLen, workTop - 4), cornerPaint);
      // BL
      canvas.drawLine(Offset(workLeft - 4, workBottom - cornerLen),
          Offset(workLeft - 4, workBottom + 4), cornerPaint);
      canvas.drawLine(Offset(workLeft - 4, workBottom + 4),
          Offset(workLeft + cornerLen, workBottom + 4), cornerPaint);
      // BR
      canvas.drawLine(Offset(workRight + 4, workBottom - cornerLen),
          Offset(workRight + 4, workBottom + 4), cornerPaint);
      canvas.drawLine(Offset(workRight + 4, workBottom + 4),
          Offset(workRight - cornerLen, workBottom + 4), cornerPaint);
    }
  }

  @override
  bool shouldRepaint(covariant GridPainter oldDelegate) {
    return colBoundaries != oldDelegate.colBoundaries ||
        rowBoundaries != oldDelegate.rowBoundaries ||
        selectedBoundaryIndex != oldDelegate.selectedBoundaryIndex ||
        selectedBoundaryIsCol != oldDelegate.selectedBoundaryIsCol ||
        showIsolationBox != oldDelegate.showIsolationBox ||
        lineLengthScale != oldDelegate.lineLengthScale;
  }
}
