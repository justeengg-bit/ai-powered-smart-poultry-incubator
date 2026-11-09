import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';

import '../services/fertility_classifier.dart';

class OfflineFertilityTestPage extends StatefulWidget {
  const OfflineFertilityTestPage({
    super.key,
    required this.cols,
    required this.rows,
    required this.trayWidthCm,
    required this.trayHeightCm,
    required this.colBoundariesCm,
    required this.rowBoundariesCm,
  });

  final int cols;
  final int rows;
  final double trayWidthCm;
  final double trayHeightCm;
  final List<double> colBoundariesCm;
  final List<double> rowBoundariesCm;

  @override
  State<OfflineFertilityTestPage> createState() =>
      _OfflineFertilityTestPageState();
}

class _OfflineFertilityTestPageState extends State<OfflineFertilityTestPage> {
  final _picker = ImagePicker();
  final _classifier = FertilityClassifier();
  final _selectedSlots = <int>{};
  final _previews = <int, Uint8List>{};
  final _predictions = <int, FertilityPrediction>{};

  Uint8List? _imageBytes;
  img.Image? _image;
  bool _busy = false;
  bool _running = false;
  String? _status;

  int get _slotCount => widget.cols * widget.rows;

  @override
  void dispose() {
    if (!_running) _classifier.close();
    super.dispose();
  }

  img.Image _cropSlot(int index) {
    final source = _image!;
    final row = index ~/ widget.cols;
    final col = index % widget.cols;
    int pixel(double cm, double trayCm, int size) =>
        ((cm / trayCm) * size).round().clamp(0, size).toInt();

    final left = pixel(
      widget.colBoundariesCm[col],
      widget.trayWidthCm,
      source.width,
    );
    final right = pixel(
      widget.colBoundariesCm[col + 1],
      widget.trayWidthCm,
      source.width,
    );
    final top = pixel(
      widget.rowBoundariesCm[row],
      widget.trayHeightCm,
      source.height,
    );
    final bottom = pixel(
      widget.rowBoundariesCm[row + 1],
      widget.trayHeightCm,
      source.height,
    );
    if (right <= left || bottom <= top) {
      throw StateError('Slot ${index + 1} has no pixels in this image.');
    }
    return img.copyCrop(
      source,
      x: left,
      y: top,
      width: right - left,
      height: bottom - top,
    );
  }

  Future<void> _chooseImage() async {
    if (_busy) return;
    try {
      final file = await _picker.pickImage(source: ImageSource.gallery);
      if (file == null || !mounted) return;
      final bytes = await file.readAsBytes();
      if (bytes.lengthInBytes > 15 * 1024 * 1024) {
        throw const FormatException('Choose a tray image smaller than 15 MB.');
      }
      final decoded = img.decodeImage(bytes);
      if (decoded == null) {
        throw const FormatException('Choose a JPEG or PNG tray image.');
      }
      if (!mounted) return;
      setState(() {
        _imageBytes = bytes;
        _image = decoded;
        _selectedSlots.clear();
        _previews.clear();
        _predictions.clear();
        _status = null;
      });
    } catch (error) {
      if (mounted) {
        setState(() => _status = 'Could not open image: $error');
      }
    }
  }

  void _selectSlot(int index) {
    if (_busy || _image == null || index < 0 || index >= _slotCount) return;
    try {
      setState(() {
        if (!_selectedSlots.add(index)) {
          _selectedSlots.remove(index);
          _previews.remove(index);
        } else {
          final crop = _cropSlot(index);
          final thumb = img.copyResize(crop, width: 96);
          _previews[index] = Uint8List.fromList(
            img.encodeJpg(thumb, quality: 85),
          );
        }
        _predictions.clear();
        _status = null;
      });
    } catch (error) {
      setState(() => _status = '$error');
    }
  }

  Future<void> _analyze() async {
    if (_busy || _image == null || _selectedSlots.isEmpty) return;
    final slots = _selectedSlots.toList()..sort();
    setState(() {
      _busy = true;
      _running = true;
      _predictions.clear();
      _status = 'Analyzing 0/${slots.length}';
    });
    try {
      await _classifier.load();
      for (var i = 0; i < slots.length; i++) {
        if (!mounted) return;
        final prediction = await _classifier.classify(_cropSlot(slots[i]));
        if (!mounted) return;
        setState(() {
          _predictions[slots[i]] = prediction;
          _status = 'Analyzing ${i + 1}/${slots.length}';
        });
        await Future<void>.delayed(Duration.zero);
      }
      if (mounted) {
        setState(() => _status = 'Done: ${slots.length} slots analyzed');
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _predictions.clear();
          _status = 'AI test failed: $error';
        });
      }
    } finally {
      _running = false;
      if (mounted) {
        setState(() => _busy = false);
      } else {
        _classifier.close();
      }
    }
  }

  void _selectFromImage(Offset position, Size size) {
    final x = position.dx / size.width * widget.trayWidthCm;
    final y = position.dy / size.height * widget.trayHeightCm;
    var col = -1;
    var row = -1;
    for (var i = 0; i < widget.cols; i++) {
      if (x >= widget.colBoundariesCm[i] && x < widget.colBoundariesCm[i + 1]) {
        col = i;
        break;
      }
    }
    for (var i = 0; i < widget.rows; i++) {
      if (y >= widget.rowBoundariesCm[i] && y < widget.rowBoundariesCm[i + 1]) {
        row = i;
        break;
      }
    }
    if (col >= 0 && row >= 0) _selectSlot(row * widget.cols + col);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final selected = _selectedSlots.toList()..sort();
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
      children: [
        Row(
          children: [
            Expanded(
              child: FilledButton.icon(
                onPressed: _busy ? null : _chooseImage,
                icon: const Icon(Icons.photo_library_outlined),
                label: const Text('Choose tray image'),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        if (_imageBytes == null)
          SizedBox(
            height: 190,
            child: Center(
              child: Icon(
                Icons.image_outlined,
                size: 52,
                color: theme.colorScheme.outline,
              ),
            ),
          )
        else ...[
          LayoutBuilder(
            builder: (context, constraints) {
              final size = Size(
                constraints.maxWidth,
                constraints.maxWidth * _image!.height / _image!.width,
              );
              return GestureDetector(
                onTapUp: (details) =>
                    _selectFromImage(details.localPosition, size),
                child: SizedBox.fromSize(
                  size: size,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      Image.memory(
                        _imageBytes!,
                        fit: BoxFit.fill,
                        gaplessPlayback: true,
                      ),
                      CustomPaint(
                        painter: _TraySelectionPainter(
                          cols: widget.cols,
                          rows: widget.rows,
                          trayWidthCm: widget.trayWidthCm,
                          trayHeightCm: widget.trayHeightCm,
                          colBounds: widget.colBoundariesCm,
                          rowBounds: widget.rowBoundariesCm,
                          selected: _selectedSlots,
                          predictions: _predictions,
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: Text(
                  'Occupied slots  ${selected.length}',
                  style: theme.textTheme.titleSmall,
                ),
              ),
              IconButton(
                onPressed: _busy || selected.isEmpty
                    ? null
                    : () => setState(() {
                        _selectedSlots.clear();
                        _previews.clear();
                        _predictions.clear();
                        _status = null;
                      }),
                icon: const Icon(Icons.clear_all_rounded),
                tooltip: 'Clear selection',
              ),
            ],
          ),
          GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: _slotCount,
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: widget.cols,
              mainAxisSpacing: 4,
              crossAxisSpacing: 4,
              childAspectRatio: 1,
            ),
            itemBuilder: (context, index) {
              final isSelected = _selectedSlots.contains(index);
              return Semantics(
                label: 'Slot ${index + 1}',
                button: true,
                selected: isSelected,
                child: InkWell(
                  onTap: _busy ? null : () => _selectSlot(index),
                  borderRadius: BorderRadius.circular(4),
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: isSelected
                          ? theme.colorScheme.primaryContainer
                          : theme.colorScheme.surfaceContainerHighest,
                      border: Border.all(
                        color: isSelected
                            ? theme.colorScheme.primary
                            : theme.colorScheme.outlineVariant,
                      ),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Center(
                      child: Text(
                        '${index + 1}',
                        style: theme.textTheme.labelMedium?.copyWith(
                          fontWeight: isSelected
                              ? FontWeight.bold
                              : FontWeight.normal,
                        ),
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
          const SizedBox(height: 14),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: _busy || selected.isEmpty ? null : _analyze,
              icon: const Icon(Icons.biotech_rounded),
              label: Text(
                'Analyze ${selected.length} slot${selected.length == 1 ? '' : 's'}',
              ),
            ),
          ),
          if (_status != null) ...[
            const SizedBox(height: 8),
            Text(_status!, style: theme.textTheme.bodySmall),
          ],
          if (selected.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text('Slot crops', style: theme.textTheme.titleSmall),
            const SizedBox(height: 6),
            for (final index in selected)
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: _previews[index] == null
                    ? const SizedBox(width: 52, height: 52)
                    : Image.memory(
                        _previews[index]!,
                        width: 52,
                        height: 52,
                        fit: BoxFit.cover,
                      ),
                title: Text('Slot ${(index + 1).toString().padLeft(2, '0')}'),
                subtitle: _predictions[index] == null
                    ? const Text('Selected')
                    : Text(
                        '${_predictions[index]!.label.toUpperCase()}  '
                        '${(_predictions[index]!.confidence * 100).toStringAsFixed(1)}%',
                      ),
                trailing: _predictions[index] == null
                    ? null
                    : Icon(
                        _predictions[index]!.label == 'fertile'
                            ? Icons.check_circle_rounded
                            : Icons.cancel_rounded,
                        color: _predictions[index]!.label == 'fertile'
                            ? Colors.green
                            : Colors.red,
                      ),
              ),
          ],
        ],
      ],
    );
  }
}

class _TraySelectionPainter extends CustomPainter {
  const _TraySelectionPainter({
    required this.cols,
    required this.rows,
    required this.trayWidthCm,
    required this.trayHeightCm,
    required this.colBounds,
    required this.rowBounds,
    required this.selected,
    required this.predictions,
  });

  final int cols;
  final int rows;
  final double trayWidthCm;
  final double trayHeightCm;
  final List<double> colBounds;
  final List<double> rowBounds;
  final Set<int> selected;
  final Map<int, FertilityPrediction> predictions;

  @override
  void paint(Canvas canvas, Size size) {
    for (var row = 0; row < rows; row++) {
      for (var col = 0; col < cols; col++) {
        final index = row * cols + col;
        final rect = Rect.fromLTRB(
          colBounds[col] / trayWidthCm * size.width,
          rowBounds[row] / trayHeightCm * size.height,
          colBounds[col + 1] / trayWidthCm * size.width,
          rowBounds[row + 1] / trayHeightCm * size.height,
        );
        final prediction = predictions[index];
        final color = prediction == null
            ? Colors.cyanAccent
            : prediction.label == 'fertile'
            ? Colors.greenAccent
            : Colors.redAccent;
        canvas.drawRect(
          rect,
          Paint()
            ..color = color.withValues(
              alpha: selected.contains(index) ? 0.15 : 0.04,
            ),
        );
        canvas.drawRect(
          rect,
          Paint()
            ..color = selected.contains(index) ? color : Colors.white54
            ..style = PaintingStyle.stroke
            ..strokeWidth = selected.contains(index) ? 2 : 0.8,
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant _TraySelectionPainter oldDelegate) => true;
}
