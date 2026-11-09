import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:share_plus/share_plus.dart';
import '../models/egg_models.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Session Detail Page  – now with Print / Share report
// ─────────────────────────────────────────────────────────────────────────────
class SessionDetailPage extends StatelessWidget {
  final EggSession session;
  final List<EggSession> allSessions;

  const SessionDetailPage({
    super.key,
    required this.session,
    this.allSessions = const [],
  });

  int get _candlingNumber {
    final start = DateTime(
      session.timestamp.year,
      session.timestamp.month,
      session.timestamp.day,
    );
    final end = start.add(const Duration(days: 1));
    final source = allSessions.isEmpty ? [session] : allSessions;
    final sameDay =
        source
            .where(
              (s) => !s.timestamp.isBefore(start) && s.timestamp.isBefore(end),
            )
            .toList()
          ..sort((a, b) => a.timestamp.compareTo(b.timestamp));
    final index = sameDay.indexWhere((s) => s.id == session.id);
    return index < 0 ? 1 : (index + 1).clamp(1, 2);
  }

  String get _candlingLabel =>
      _candlingNumber == 1 ? '1st Candling' : '2nd Candling';

  String get _reportFileName {
    final date = DateFormat('yyyy-MM-dd').format(session.timestamp);
    final time = DateFormat('hhmma').format(session.timestamp).toLowerCase();
    final order = _candlingNumber == 1 ? '1st-candling' : '2nd-candling';
    return 'Candling_${date}_${time}_$order.pdf';
  }

  // ── PDF report generation ─────────────────────────────────────────────────
  static pw.Widget _pdfStat(String label, String value, PdfColor color) {
    return pw.Column(
      mainAxisSize: pw.MainAxisSize.min,
      children: [
        pw.Text(
          label,
          style: pw.TextStyle(fontSize: 9, color: PdfColors.grey600),
        ),
        pw.SizedBox(height: 4),
        pw.Text(
          value,
          style: pw.TextStyle(
            fontSize: 22,
            fontWeight: pw.FontWeight.bold,
            color: color,
          ),
        ),
      ],
    );
  }

  Future<void> _printReport(BuildContext context) async {
    try {
      final pdf = pw.Document();

      // Build egg grid rows
      final List<pw.TableRow> gridRows = [];
      // Column header row
      gridRows.add(
        pw.TableRow(
          decoration: const pw.BoxDecoration(color: PdfColors.grey200),
          children: [
            pw.Padding(
              padding: const pw.EdgeInsets.all(3),
              child: pw.Text('', style: pw.TextStyle(fontSize: 7)),
            ),
            ...List.generate(
              8,
              (c) => pw.Padding(
                padding: const pw.EdgeInsets.all(3),
                child: pw.Center(
                  child: pw.Text(
                    'C${c + 1}',
                    style: pw.TextStyle(
                      fontSize: 7,
                      fontWeight: pw.FontWeight.bold,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      );

      for (int row = 0; row < 7; row++) {
        gridRows.add(
          pw.TableRow(
            children: [
              // Row header
              pw.Padding(
                padding: const pw.EdgeInsets.all(3),
                child: pw.Center(
                  child: pw.Text(
                    'R${row + 1}',
                    style: pw.TextStyle(
                      fontSize: 7,
                      fontWeight: pw.FontWeight.bold,
                    ),
                  ),
                ),
              ),
              ...List.generate(8, (col) {
                final idx = row * 8 + col;
                final egg = session.eggData[idx];
                PdfColor bg;
                String label;
                switch (egg.status) {
                  case EggStatus.fertile:
                    bg = const PdfColor(0.8, 1.0, 0.86);
                    label = 'F';
                    break;
                  case EggStatus.infertile:
                    bg = const PdfColor(1.0, 0.8, 0.8);
                    label = 'I';
                    break;
                  default:
                    bg = const PdfColor(0.9, 0.9, 0.9);
                    label = '?';
                }
                return pw.Container(
                  color: bg,
                  height: 28,
                  child: pw.Center(
                    child: pw.Column(
                      mainAxisSize: pw.MainAxisSize.min,
                      children: [
                        pw.Text(
                          label,
                          style: pw.TextStyle(
                            fontSize: 8,
                            fontWeight: pw.FontWeight.bold,
                          ),
                        ),
                        if (egg.confidence > 0)
                          pw.Text(
                            '${(egg.confidence * 100).toInt()}%',
                            style: pw.TextStyle(fontSize: 6),
                          ),
                      ],
                    ),
                  ),
                );
              }),
            ],
          ),
        );
      }

      pdf.addPage(
        pw.MultiPage(
          pageFormat: PdfPageFormat.a4,
          margin: const pw.EdgeInsets.all(36),
          header: (pw.Context ctx) => pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              pw.Row(
                mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                children: [
                  pw.Column(
                    crossAxisAlignment: pw.CrossAxisAlignment.start,
                    children: [
                      pw.Text(
                        'Candling Scan Report',
                        style: pw.TextStyle(
                          fontSize: 18,
                          fontWeight: pw.FontWeight.bold,
                        ),
                      ),
                      pw.SizedBox(height: 2),
                      pw.Text(
                        DateFormat(
                          'MMMM dd, yyyy  h:mm:ss a',
                        ).format(session.timestamp),
                        style: pw.TextStyle(
                          fontSize: 10,
                          color: PdfColors.grey600,
                        ),
                      ),
                    ],
                  ),
                  pw.Text(
                    'Session #${session.id}',
                    style: pw.TextStyle(fontSize: 9, color: PdfColors.grey400),
                  ),
                ],
              ),
              pw.SizedBox(height: 8),
              pw.Divider(color: PdfColors.grey300),
            ],
          ),
          build: (pw.Context ctx) => [
            // Summary stats row
            pw.Container(
              padding: const pw.EdgeInsets.symmetric(
                vertical: 12,
                horizontal: 16,
              ),
              decoration: pw.BoxDecoration(
                border: pw.Border.all(color: PdfColors.grey300),
                borderRadius: const pw.BorderRadius.all(pw.Radius.circular(8)),
              ),
              child: pw.Row(
                mainAxisAlignment: pw.MainAxisAlignment.spaceEvenly,
                children: [
                  _pdfStat(
                    'FERTILE',
                    '${session.fertileCount}',
                    PdfColors.green700,
                  ),
                  pw.Container(width: 1, height: 40, color: PdfColors.grey200),
                  _pdfStat(
                    'INFERTILE',
                    '${session.infertileCount}',
                    PdfColors.red700,
                  ),
                  pw.Container(width: 1, height: 40, color: PdfColors.grey200),
                  _pdfStat(
                    'UNKNOWN',
                    '${56 - session.fertileCount - session.infertileCount}',
                    PdfColors.grey600,
                  ),
                  pw.Container(width: 1, height: 40, color: PdfColors.grey200),
                  _pdfStat(
                    'FERTILITY RATE',
                    session.fertileCount + session.infertileCount > 0
                        ? '${(session.fertileCount * 100 / (session.fertileCount + session.infertileCount)).toStringAsFixed(1)}%'
                        : '—',
                    PdfColors.blue700,
                  ),
                ],
              ),
            ),
            pw.SizedBox(height: 12),

            // Environment row
            if (session.temperature != null || session.humidity != null)
              pw.Container(
                padding: const pw.EdgeInsets.symmetric(
                  vertical: 8,
                  horizontal: 16,
                ),
                decoration: pw.BoxDecoration(
                  color: PdfColors.grey50,
                  borderRadius: const pw.BorderRadius.all(
                    pw.Radius.circular(6),
                  ),
                ),
                child: pw.Row(
                  children: [
                    pw.Text(
                      'Temperature: ',
                      style: pw.TextStyle(
                        color: PdfColors.grey600,
                        fontSize: 10,
                      ),
                    ),
                    pw.Text(
                      session.temperature != null
                          ? '${session.temperature!.toStringAsFixed(1)}°C'
                          : '—',
                      style: pw.TextStyle(
                        fontWeight: pw.FontWeight.bold,
                        fontSize: 10,
                      ),
                    ),
                    pw.SizedBox(width: 24),
                    pw.Text(
                      'Humidity: ',
                      style: pw.TextStyle(
                        color: PdfColors.grey600,
                        fontSize: 10,
                      ),
                    ),
                    pw.Text(
                      session.humidity != null
                          ? '${session.humidity!.toStringAsFixed(0)}%'
                          : '—',
                      style: pw.TextStyle(
                        fontWeight: pw.FontWeight.bold,
                        fontSize: 10,
                      ),
                    ),
                    pw.SizedBox(width: 24),
                    pw.Text(
                      'AI Analysis: ',
                      style: pw.TextStyle(
                        color: PdfColors.grey600,
                        fontSize: 10,
                      ),
                    ),
                    pw.Text(
                      session.usedAi ? 'Yes' : 'No',
                      style: pw.TextStyle(
                        fontWeight: pw.FontWeight.bold,
                        fontSize: 10,
                      ),
                    ),
                  ],
                ),
              ),
            pw.SizedBox(height: 16),

            // Egg grid heading
            pw.Text(
              'EGG GRID  (8 columns × 7 rows = 56 cells)',
              style: pw.TextStyle(fontSize: 12, fontWeight: pw.FontWeight.bold),
            ),
            pw.SizedBox(height: 4),
            // Legend
            pw.Row(
              children: [
                pw.Container(
                  width: 12,
                  height: 12,
                  color: const PdfColor(0.8, 1.0, 0.86),
                ),
                pw.SizedBox(width: 4),
                pw.Text('Fertile (F)', style: pw.TextStyle(fontSize: 9)),
                pw.SizedBox(width: 16),
                pw.Container(
                  width: 12,
                  height: 12,
                  color: const PdfColor(1.0, 0.8, 0.8),
                ),
                pw.SizedBox(width: 4),
                pw.Text('Infertile (I)', style: pw.TextStyle(fontSize: 9)),
                pw.SizedBox(width: 16),
                pw.Container(
                  width: 12,
                  height: 12,
                  color: const PdfColor(0.9, 0.9, 0.9),
                ),
                pw.SizedBox(width: 4),
                pw.Text('Unknown (?)', style: pw.TextStyle(fontSize: 9)),
              ],
            ),
            pw.SizedBox(height: 8),
            pw.Table(
              columnWidths: {
                0: const pw.FixedColumnWidth(18),
                for (int i = 1; i <= 8; i++) i: const pw.FlexColumnWidth(1),
              },
              border: pw.TableBorder.all(color: PdfColors.grey300, width: 0.5),
              children: gridRows,
            ),
          ],
          footer: (pw.Context ctx) => pw.Row(
            mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
            children: [
              pw.Text(
                'Candling - Confidential Research Data',
                style: pw.TextStyle(fontSize: 8, color: PdfColors.grey400),
              ),
              pw.Text(
                'Page ${ctx.pageNumber} / ${ctx.pagesCount}',
                style: pw.TextStyle(fontSize: 8, color: PdfColors.grey400),
              ),
            ],
          ),
        ),
      );

      await Printing.layoutPdf(
        onLayout: (PdfPageFormat format) async => pdf.save(),
        name: _reportFileName,
      );
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Report error: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Future<void> _shareReport(BuildContext context) async {
    try {
      final pdf = pw.Document();
      // Minimal one-page summary for quick sharing
      pdf.addPage(
        pw.Page(
          pageFormat: PdfPageFormat.a4,
          build: (pw.Context ctx) => pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              pw.Text(
                'Candling Scan Report',
                style: pw.TextStyle(
                  fontSize: 18,
                  fontWeight: pw.FontWeight.bold,
                ),
              ),
              pw.Text(
                DateFormat('MMMM dd, yyyy  h:mm a').format(session.timestamp),
                style: pw.TextStyle(color: PdfColors.grey600, fontSize: 11),
              ),
              pw.Divider(),
              pw.SizedBox(height: 8),
              pw.Row(
                mainAxisAlignment: pw.MainAxisAlignment.spaceEvenly,
                children: [
                  _pdfStat(
                    'FERTILE',
                    '${session.fertileCount}',
                    PdfColors.green700,
                  ),
                  _pdfStat(
                    'INFERTILE',
                    '${session.infertileCount}',
                    PdfColors.red700,
                  ),
                  _pdfStat(
                    'RATE',
                    session.fertileCount + session.infertileCount > 0
                        ? '${(session.fertileCount * 100 / (session.fertileCount + session.infertileCount)).toStringAsFixed(1)}%'
                        : '—',
                    PdfColors.blue700,
                  ),
                ],
              ),
            ],
          ),
        ),
      );

      final pdfBytes = await pdf.save();
      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}/$_reportFileName');
      await file.writeAsBytes(pdfBytes);

      await Share.shareXFiles(
        [XFile(file.path, mimeType: 'application/pdf')],
        subject:
            'Candling $_candlingLabel - ${DateFormat('MMM dd, yyyy').format(session.timestamp)}',
      );
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Share error: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          DateFormat('MMM dd, yyyy - h:mm a').format(session.timestamp),
        ),
        actions: [
          // Share (quick PDF share)
          IconButton(
            icon: const Icon(Icons.share),
            onPressed: () => _shareReport(context),
            tooltip: 'Share Report',
          ),
          // Print (full PDF with grid)
          IconButton(
            icon: const Icon(Icons.print),
            onPressed: () => _printReport(context),
            tooltip: 'Print / Save PDF',
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          children: [
            if (session.imageBytes != null)
              Container(
                height: 300,
                width: double.infinity,
                decoration: BoxDecoration(
                  color: const Color(0xFF161B2E),
                  borderRadius: BorderRadius.circular(16),
                ),
                clipBehavior: Clip.antiAlias,
                child: _buildImageWithDetections(
                  session.imageBytes!,
                  session.detections,
                ),
              ),
            const SizedBox(height: 20),
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: const Color(0xFF161B2E),
                borderRadius: BorderRadius.circular(16),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  _buildDetailStat(
                    'Fertile',
                    session.fertileCount.toString(),
                    const Color(0xFF00E676),
                  ),
                  Container(width: 1, height: 40, color: Colors.white24),
                  _buildDetailStat(
                    'Infertile',
                    session.infertileCount.toString(),
                    const Color(0xFFFF5252),
                  ),
                  Container(width: 1, height: 40, color: Colors.white24),
                  _buildDetailStat(
                    'Unknown',
                    (56 - session.fertileCount - session.infertileCount)
                        .toString(),
                    const Color(0xFF37474F),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),

            // Print / Share call-to-action
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: const Color(0xFF161B2E),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.white12),
              ),
              child: Row(
                children: [
                  const Icon(Icons.picture_as_pdf, color: Color(0xFF2979FF)),
                  const SizedBox(width: 12),
                  const Expanded(
                    child: Text(
                      'Generate a full PDF report with egg grid, stats, '
                      'and environment data.',
                      style: TextStyle(color: Colors.white70, fontSize: 12),
                    ),
                  ),
                  const SizedBox(width: 12),
                  ElevatedButton.icon(
                    icon: const Icon(Icons.print, size: 16),
                    label: const Text('Print'),
                    onPressed: () => _printReport(context),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF2979FF),
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 8,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDetailStat(String label, String value, Color color) {
    return Column(
      children: [
        Text(
          label,
          style: const TextStyle(fontSize: 10, color: Colors.white54),
        ),
        const SizedBox(height: 4),
        Text(
          value,
          style: TextStyle(
            fontSize: 24,
            fontWeight: FontWeight.bold,
            color: color,
          ),
        ),
      ],
    );
  }

  Widget _buildImageWithDetections(
    Uint8List imageBytes,
    List<Map<String, dynamic>>? detections,
  ) {
    return LayoutBuilder(
      builder: (context, constraints) {
        const imgWidth = 1600.0;
        const imgHeight = 1200.0;

        final displayAspectRatio = constraints.maxWidth / constraints.maxHeight;
        final imageAspectRatio = imgWidth / imgHeight;

        double displayWidth, displayHeight;
        if (displayAspectRatio > imageAspectRatio) {
          displayHeight = constraints.maxHeight;
          displayWidth = displayHeight * imageAspectRatio;
        } else {
          displayWidth = constraints.maxWidth;
          displayHeight = displayWidth / imageAspectRatio;
        }

        final scaleX = displayWidth / imgWidth;
        final scaleY = displayHeight / imgHeight;

        return InteractiveViewer(
          panEnabled: true,
          minScale: 1.0,
          maxScale: 5.0,
          clipBehavior: Clip.hardEdge,
          child: SizedBox(
            width: constraints.maxWidth,
            height: constraints.maxHeight,
            child: Stack(
          fit: StackFit.expand,
          children: [
            Center(child: Image.memory(imageBytes, fit: BoxFit.contain)),
            if (detections != null && detections.isNotEmpty)
              ...detections.map((det) {
                final x1 = (det['x1'] as int).toDouble() * scaleX;
                final y1 = (det['y1'] as int).toDouble() * scaleY;
                final x2 = (det['x2'] as int).toDouble() * scaleX;
                final y2 = (det['y2'] as int).toDouble() * scaleY;

                final isFertile = (det['label'] as String)
                    .toLowerCase()
                    .contains('fertile');
                final color = isFertile ? const Color(0xFF00E676) : Colors.red;

                final offsetX = (constraints.maxWidth - displayWidth) / 2;
                final offsetY = (constraints.maxHeight - displayHeight) / 2;

                return Positioned(
                  left: offsetX + x1,
                  top: offsetY + y1,
                  width: x2 - x1,
                  height: y2 - y1,
                  child: Container(
                    decoration: BoxDecoration(
                      border: Border.all(color: color, width: 3),
                      borderRadius: BorderRadius.circular(4),
                    ),
                  ),
                );
              }),
          ],
            ),
          ),
        );
      },
    );
  }
}
