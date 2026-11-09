import 'package:image/image.dart' as img;
import 'package:tflite_flutter/tflite_flutter.dart';

class FertilityPrediction {
  const FertilityPrediction({
    required this.label,
    required this.confidence,
    required this.fertileConfidence,
    required this.infertileConfidence,
  });

  final String label;
  final double confidence;
  final double fertileConfidence;
  final double infertileConfidence;
}

class FertilityClassifier {
  static const String modelAsset =
      'assets/models/fertility_mobilenetv3small_float16.tflite';
  static const int inputSize = 224;

  Interpreter? _interpreter;

  Future<void> load() async {
    _interpreter ??= await Interpreter.fromAsset(modelAsset);
  }

  Future<FertilityPrediction> classify(img.Image crop) async {
    await load();
    final interpreter = _interpreter;
    if (interpreter == null) {
      throw StateError('Fertility model could not be loaded.');
    }

    final resized = img.copyResize(
      crop,
      width: inputSize,
      height: inputSize,
      interpolation: img.Interpolation.linear,
    );
    final input = List.generate(
      1,
      (_) => List.generate(
        inputSize,
        (y) => List.generate(inputSize, (x) {
          final pixel = resized.getPixel(x, y);
          return <double>[pixel.r / 255.0, pixel.g / 255.0, pixel.b / 255.0];
        }, growable: false),
        growable: false,
      ),
      growable: false,
    );
    final output = <List<double>>[
      <double>[0.0, 0.0],
    ];
    interpreter.run(input, output);

    final fertile = output[0][0];
    final infertile = output[0][1];
    final isFertile = fertile >= infertile;
    return FertilityPrediction(
      label: isFertile ? 'fertile' : 'infertile',
      confidence: isFertile ? fertile : infertile,
      fertileConfidence: fertile,
      infertileConfidence: infertile,
    );
  }

  void close() {
    _interpreter?.close();
    _interpreter = null;
  }
}
