import 'dart:convert';
import 'dart:typed_data';

// ─────────────────────────────────────────────────────────────────────────────
// Data models
// ─────────────────────────────────────────────────────────────────────────────
enum EggStatus { unknown, fertile, infertile }

class EggData {
  EggStatus status = EggStatus.unknown;
  double confidence = 0.0;
  int? x1, y1, x2, y2;

  EggData();

  Map<String, dynamic> toJson() => {
        'status': status.index,
        'confidence': confidence,
        'x1': x1,
        'y1': y1,
        'x2': x2,
        'y2': y2,
      };

  factory EggData.fromJson(Map<String, dynamic> json) {
    return EggData()
      ..status = EggStatus.values[json['status'] as int]
      ..confidence = (json['confidence'] as num).toDouble()
      ..x1 = json['x1'] as int?
      ..y1 = json['y1'] as int?
      ..x2 = json['x2'] as int?
      ..y2 = json['y2'] as int?;
  }
}

class EggSession {
  final int id;
  final DateTime timestamp;
  final int fertileCount;
  final int infertileCount;
  final double? temperature;
  final double? humidity;
  final Uint8List? imageBytes;
  final int? imageWidth;
  final int? imageHeight;
  final List<EggData> eggData;
  final bool usedAi;
  final List<Map<String, dynamic>>? detections;

  static const int gridCols = 8;
  static const int gridRows = 7;

  EggSession({
    required this.id,
    required this.timestamp,
    required this.fertileCount,
    required this.infertileCount,
    required this.temperature,
    required this.humidity,
    this.imageBytes,
    this.imageWidth,
    this.imageHeight,
    required this.eggData,
    this.usedAi = false,
    this.detections,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'timestamp': timestamp.toIso8601String(),
        'fertileCount': fertileCount,
        'infertileCount': infertileCount,
        'temperature': temperature,
        'humidity': humidity,
        'imageBytes':
            imageBytes != null ? base64Encode(imageBytes!) : null,
        'imageWidth': imageWidth,
        'imageHeight': imageHeight,
        'eggData': eggData.map((e) => e.toJson()).toList(),
        'usedAi': usedAi,
        'detections': detections,
      };

  factory EggSession.fromJson(Map<String, dynamic> json) {
    return EggSession(
      id: json['id'] as int,
      timestamp: DateTime.parse(json['timestamp'] as String),
      fertileCount: json['fertileCount'] as int,
      infertileCount: json['infertileCount'] as int,
      temperature: json['temperature'] != null
          ? (json['temperature'] as num).toDouble()
          : null,
      humidity: json['humidity'] != null
          ? (json['humidity'] as num).toDouble()
          : null,
      imageBytes: json['imageBytes'] != null
          ? base64Decode(json['imageBytes'] as String)
          : null,
      imageWidth: json['imageWidth'] as int?,
      imageHeight: json['imageHeight'] as int?,
      eggData: (json['eggData'] as List)
          .map((e) => EggData.fromJson(e as Map<String, dynamic>))
          .toList(),
      usedAi: json['usedAi'] as bool? ?? false,
      detections: json['detections'] != null
          ? (json['detections'] as List)
                .map((d) => Map<String, dynamic>.from(d as Map))
                .toList()
          : null,
    );
  }
}
