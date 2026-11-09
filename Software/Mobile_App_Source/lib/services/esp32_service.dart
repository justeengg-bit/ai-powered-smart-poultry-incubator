import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:flutter/foundation.dart';

// ─────────────────────────────────────────────────────────────────────────────
// ESP32 Service — Unified networking layer for both S3 and P4
// ─────────────────────────────────────────────────────────────────────────────

class ESP32Service {
  static final ESP32Service _instance = ESP32Service._internal();
  factory ESP32Service() => _instance;
  ESP32Service._internal();

  // Network configuration
  static const String _esp32S3Ip = '192.168.4.1';
  static const int _esp32S3StreamPort = 81;
  static const Duration _defaultTimeout = Duration(seconds: 10);

  // Private HTTP client
  final http.Client _client = http.Client();

  Uri _s3Uri(String path) => Uri.parse('http://$_esp32S3Ip$path');
  Uri _s3QueryUri(String path, Map<String, String> queryParameters) =>
      _s3Uri(path).replace(queryParameters: queryParameters);
  Uri _p4ProxyUri(String path) => _s3Uri('/p4$path');

  Future<http.Response> _postEmptyJson(Uri uri, {Duration? timeout}) {
    return _client
        .post(uri, headers: {'Content-Type': 'application/json'})
        .timeout(timeout ?? _defaultTimeout);
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // ESP32-S3 Endpoints (Camera Server)
  // ═══════════════════════════════════════════════════════════════════════════

  /// GET /capture — Download single JPEG for manual candling
  /// Returns: JPEG image bytes (UXGA 1600×1200, low contrast)
  Future<Uint8List> getCaptureImage() async {
    try {
      final response = await _client
          .get(Uri.parse('http://$_esp32S3Ip/capture'))
          .timeout(_defaultTimeout);

      if (response.statusCode == 200) {
        return Uint8List.fromList(response.bodyBytes);
      } else {
        throw HttpException(
          'Capture failed: ${response.statusCode}',
          uri: Uri.parse('http://$_esp32S3Ip/capture'),
        );
      }
    } catch (e) {
      debugPrint('getCaptureImage error: $e');
      rethrow;
    }
  }

  /// GET /capturep4 — Download JPEG for ESP32-P4 analysis
  /// Returns: JPEG image bytes (UXGA 1600×1200, standard settings)
  Future<Uint8List> getCaptureP4Image() async {
    try {
      final response = await _client
          .get(Uri.parse('http://$_esp32S3Ip/capturep4'))
          .timeout(_defaultTimeout);

      if (response.statusCode == 200) {
        return Uint8List.fromList(response.bodyBytes);
      } else {
        throw HttpException(
          'Capture P4 failed: ${response.statusCode}',
          uri: Uri.parse('http://$_esp32S3Ip/capturep4'),
        );
      }
    } catch (e) {
      debugPrint('getCaptureP4Image error: $e');
      rethrow;
    }
  }

  /// GET :81/stream - Get MJPEG stream URL from the dedicated stream server.
  /// Returns: Stream URL for use with MJPEG viewer
  String getStreamUrl() => 'http://$_esp32S3Ip:$_esp32S3StreamPort/stream';

  /// GET /sensor — Get latest temperature and humidity from P4
  /// Returns: SensorData object with temp, humidity, timestamp
  Future<SensorData> getSensorData() async {
    try {
      final response = await _postEmptyJson(
        Uri.parse('http://$_esp32S3Ip/sensor'),
      );

      if (response.statusCode == 200) {
        final json = jsonDecode(response.body) as Map<String, dynamic>;
        return SensorData.fromJson(json);
      } else {
        throw HttpException(
          'Sensor fetch failed: ${response.statusCode}',
          uri: Uri.parse('http://$_esp32S3Ip/sensor'),
        );
      }
    } catch (e) {
      debugPrint('getSensorData error: $e');
      rethrow;
    }
  }

  /// POST /sensordata — Send sensor data to S3 (for P4 relay)
  /// Sends temp and humidity to be stored on S3
  Future<void> postSensorData({
    required double temperature,
    required double humidity,
  }) async {
    try {
      final body = jsonEncode({'temp': temperature, 'hum': humidity});

      final response = await _client
          .post(
            Uri.parse('http://$_esp32S3Ip/sensordata'),
            headers: {'Content-Type': 'application/json'},
            body: body,
          )
          .timeout(_defaultTimeout);

      if (response.statusCode != 200) {
        throw HttpException(
          'Sensor post failed: ${response.statusCode}',
          uri: Uri.parse('http://$_esp32S3Ip/sensordata'),
        );
      }
    } catch (e) {
      debugPrint('postSensorData error: $e');
      rethrow;
    }
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // ESP32-P4 Endpoints (AI Controller) — Direct communication
  // ═══════════════════════════════════════════════════════════════════════════

  /// GET /get_slots — Get current egg grid state from P4
  /// Returns: EggGridData with array of 56 egg statuses
  Future<EggGridData> getEggGridData() async {
    final uri = _p4ProxyUri('/get_slots');
    try {
      final response = await _postEmptyJson(uri);

      if (response.statusCode == 200) {
        final json = jsonDecode(response.body) as Map<String, dynamic>;
        return EggGridData.fromJson(json);
      } else {
        throw HttpException(
          'Get slots failed: ${response.statusCode}',
          uri: uri,
        );
      }
    } catch (e) {
      debugPrint('getEggGridData error: $e');
      rethrow;
    }
  }

  /// GET /get_infertile — Get list of infertile egg slots from P4
  /// Returns: List of slot indices marked as infertile
  Future<List<int>> getInfertileSlots() async {
    final uri = _p4ProxyUri('/get_infertile');
    try {
      final response = await _postEmptyJson(uri);

      if (response.statusCode == 200) {
        final json = jsonDecode(response.body) as Map<String, dynamic>;
        final slots = (json['infertile'] as List?)?.cast<int>() ?? [];
        return slots;
      } else {
        throw HttpException(
          'Get infertile failed: ${response.statusCode}',
          uri: uri,
        );
      }
    } catch (e) {
      debugPrint('getInfertileSlots error: $e');
      rethrow;
    }
  }

  /// POST /set_infertile — Mark specific egg slots as infertile
  /// Sends: List of slot indices to mark as infertile
  Future<void> setInfertileSlots(List<int> slots) async {
    final uri = _p4ProxyUri('/set_infertile');
    try {
      final body = jsonEncode({'infertile': slots});

      final response = await _client
          .post(uri, headers: {'Content-Type': 'application/json'}, body: body)
          .timeout(_defaultTimeout);

      if (response.statusCode != 200) {
        throw HttpException(
          'Set infertile failed: ${response.statusCode}',
          uri: uri,
        );
      }
    } catch (e) {
      debugPrint('setInfertileSlots error: $e');
      rethrow;
    }
  }

  /// Publish final phone-model verdicts through the S3-to-P4 proxy.
  ///
  /// Cells are zero-based (0..55), matching the P4 `eggs` array. P4 does not
  /// infer fertility; it persists these accepted mobile results for its LCD,
  /// API mirror, and infertile-slot removal guidance.
  Future<Map<String, dynamic>> setAutomaticFertilityResults({
    required int day,
    required Iterable<int> fertileCells,
    required Iterable<int> infertileCells,
    String source = 'mobile_tflite',
  }) async {
    if (day < 7 || day > 14) {
      throw ArgumentError.value(day, 'day', 'Expected Day 7 through Day 14');
    }

    final fertile = fertileCells.toSet().toList()..sort();
    final infertile = infertileCells.toSet().toList()..sort();
    final allCells = <int>{...fertile, ...infertile};
    if (allCells.length != fertile.length + infertile.length) {
      throw ArgumentError('Fertile and infertile cell lists overlap.');
    }
    if (allCells.isEmpty || allCells.any((cell) => cell < 0 || cell >= 56)) {
      throw ArgumentError(
        'Fertility results require cells in the 0..55 range.',
      );
    }

    final uri = _p4ProxyUri('/set_fertility_results');
    final response = await _client
        .post(
          uri,
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'day': day,
            'fertile': fertile,
            'infertile': infertile,
            'source': source,
          }),
        )
        .timeout(_defaultTimeout);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw HttpException(
        'Set fertility results failed: ${response.statusCode} ${response.body}',
        uri: uri,
      );
    }
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  /// POST /clear_infertile — Clear all infertile marks on P4
  Future<void> clearInfertileSlots() async {
    final uri = _p4ProxyUri('/clear_infertile');
    try {
      final response = await _client
          .post(uri, headers: {'Content-Type': 'application/json'})
          .timeout(_defaultTimeout);

      if (response.statusCode != 200) {
        throw HttpException(
          'Clear infertile failed: ${response.statusCode}',
          uri: uri,
        );
      }
    } catch (e) {
      debugPrint('clearInfertileSlots error: $e');
      rethrow;
    }
  }

  /// GET /candling_start — Begin candling/scanning on P4
  /// Stops the egg tray and lights occupied egg-slot LED zones.
  Future<void> startCandling() async {
    final uri = _p4ProxyUri('/candling_start');
    try {
      final response = await _postEmptyJson(uri);

      if (response.statusCode != 200) {
        throw HttpException(
          'Candling start failed: ${response.statusCode}',
          uri: uri,
        );
      }
    } catch (e) {
      debugPrint('startCandling error: $e');
      rethrow;
    }
  }

  /// GET /candling_stop — Stop candling/scanning on P4
  /// Turns off slot LEDs and resumes the egg tray.
  Future<void> stopCandling() async {
    final uri = _p4ProxyUri('/candling_stop');
    try {
      final response = await _postEmptyJson(uri);

      if (response.statusCode != 200) {
        throw HttpException(
          'Candling stop failed: ${response.statusCode}',
          uri: uri,
        );
      }
    } catch (e) {
      debugPrint('stopCandling error: $e');
      rethrow;
    }
  }

  /// GET /blink_infertile — Trigger LED feedback for infertile eggs
  /// Makes infertile egg LEDs blink on the P4
  Future<void> blinkInfertileLeds() async {
    final uri = _p4ProxyUri('/blink_infertile');
    try {
      final response = await _postEmptyJson(uri);

      if (response.statusCode != 200) {
        throw HttpException(
          'Blink infertile failed: ${response.statusCode}',
          uri: uri,
        );
      }
    } catch (e) {
      debugPrint('blinkInfertileLeds error: $e');
      rethrow;
    }
  }

  /// POST /led/status - Read external 56 LED controller state via S3.
  Future<LedControllerStatus> getLedControllerStatus({
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final uri = _s3Uri('/led/status');
    try {
      final response = await _postEmptyJson(uri, timeout: timeout);

      if (response.statusCode == 200) {
        final json = jsonDecode(response.body) as Map<String, dynamic>;
        return LedControllerStatus.fromJson(json);
      } else {
        throw HttpException(
          'LED status failed: ${response.statusCode}',
          uri: uri,
        );
      }
    } catch (e) {
      debugPrint('getLedControllerStatus error: $e');
      rethrow;
    }
  }

  /// POST /led/led_test - Drive one LED, a comma-separated LED list, all/off,
  /// or chase through the S3 bridge.
  Future<LedControllerStatus> setLedTest({
    required String led,
    String? mode,
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final query = <String, String>{'led': led};
    if (mode != null && mode.trim().isNotEmpty) {
      query['mode'] = mode.trim();
    }
    final uri = _s3QueryUri('/led/led_test', query);

    try {
      final response = await _postEmptyJson(uri, timeout: timeout);

      if (response.statusCode == 200) {
        final json = jsonDecode(response.body) as Map<String, dynamic>;
        return LedControllerStatus.fromJson(json);
      } else {
        throw HttpException(
          'LED test failed: ${response.statusCode}',
          uri: uri,
        );
      }
    } catch (e) {
      debugPrint('setLedTest error: $e');
      rethrow;
    }
  }

  /// POST /led/slots_sync - Refresh LED controller cache from P4.
  Future<LedControllerStatus> syncLedSlots({
    Duration timeout = const Duration(seconds: 8),
  }) async {
    final uri = _s3Uri('/led/slots_sync');
    try {
      final response = await _postEmptyJson(uri, timeout: timeout);

      if (response.statusCode == 200) {
        final json = jsonDecode(response.body) as Map<String, dynamic>;
        return LedControllerStatus.fromJson(json);
      } else {
        throw HttpException(
          'LED slots sync failed: ${response.statusCode}',
          uri: uri,
        );
      }
    } catch (e) {
      debugPrint('syncLedSlots error: $e');
      rethrow;
    }
  }

  /// POST /led/candling_start - Light occupied egg slots on the LED controller.
  Future<LedControllerStatus> startLedCandling({
    Duration timeout = const Duration(seconds: 8),
  }) async {
    final uri = _s3Uri('/led/candling_start');
    try {
      final response = await _postEmptyJson(uri, timeout: timeout);

      if (response.statusCode == 200) {
        final json = jsonDecode(response.body) as Map<String, dynamic>;
        return LedControllerStatus.fromJson(json);
      } else {
        throw HttpException(
          'LED candling start failed: ${response.statusCode}',
          uri: uri,
        );
      }
    } catch (e) {
      debugPrint('startLedCandling error: $e');
      rethrow;
    }
  }

  /// POST /led/candling_stop - Turn all LED controller outputs off.
  Future<LedControllerStatus> stopLedCandling({
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final uri = _s3Uri('/led/candling_stop');
    try {
      final response = await _postEmptyJson(uri, timeout: timeout);

      if (response.statusCode == 200) {
        final json = jsonDecode(response.body) as Map<String, dynamic>;
        return LedControllerStatus.fromJson(json);
      } else {
        throw HttpException(
          'LED candling stop failed: ${response.statusCode}',
          uri: uri,
        );
      }
    } catch (e) {
      debugPrint('stopLedCandling error: $e');
      rethrow;
    }
  }

  /// Test connectivity to the external 56 LED controller through S3.
  Future<bool> testLedControllerConnection() async {
    try {
      await getLedControllerStatus(timeout: const Duration(seconds: 3));
      return true;
    } catch (e) {
      debugPrint('LED controller connection test failed: $e');
      return false;
    }
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Proxy Endpoints via S3 (alternative routing)
  // ═══════════════════════════════════════════════════════════════════════════

  /// GET /p4/get_slots — Get egg grid via S3 proxy
  /// Alternative to direct P4 call if P4 unreachable
  /// GET grid layout from P4.
  /// Uses the S3 proxy by default because the phone is normally on the S3 AP.
  /// GET /get_grid_config — Read the active custom grid from P4
  Future<GridConfigData> getGridConfig({bool viaS3 = true}) async {
    final uri = _p4ProxyUri('/get_grid_config');

    try {
      final response = await _postEmptyJson(uri);

      if (response.statusCode >= 200 && response.statusCode < 300) {
        final json = jsonDecode(response.body) as Map<String, dynamic>;
        return GridConfigData.fromJson(json);
      } else {
        throw HttpException(
          'Get grid config failed: ${response.statusCode}',
          uri: uri,
        );
      }
    } catch (e) {
      debugPrint('getGridConfig error: $e');
      rethrow;
    }
  }

  /// POST /grid_config — Save a custom grid on P4
  Future<GridConfigData> setGridConfig({
    required int cols,
    required int rows,
    required List<double> colBoundsCm,
    required List<double> rowBoundsCm,
    bool viaS3 = true,
  }) async {
    final uri = _p4ProxyUri('/grid_config');

    try {
      final body = jsonEncode({
        'cols': cols,
        'rows': rows,
        'col_bounds_cm': colBoundsCm,
        'row_bounds_cm': rowBoundsCm,
      });

      final response = await _client
          .post(uri, headers: {'Content-Type': 'application/json'}, body: body)
          .timeout(_defaultTimeout);

      if (response.statusCode >= 200 && response.statusCode < 300) {
        return _gridConfigFromResponse(
          response,
          cols: cols,
          rows: rows,
          colBoundsCm: colBoundsCm,
          rowBoundsCm: rowBoundsCm,
        );
      } else {
        throw HttpException(
          'Set grid config failed: ${response.statusCode}',
          uri: uri,
        );
      }
    } catch (e) {
      debugPrint('setGridConfig error: $e');
      rethrow;
    }
  }

  /// POST /reset_grid_config — Restore the default P4 grid
  Future<GridConfigData> resetGridConfig({bool viaS3 = true}) async {
    final uri = _p4ProxyUri('/reset_grid_config');

    try {
      final response = await _client
          .post(uri, headers: {'Content-Type': 'application/json'})
          .timeout(_defaultTimeout);

      if (response.statusCode >= 200 && response.statusCode < 300) {
        return _gridConfigFromResponse(
          response,
          cols: 8,
          rows: 7,
          colBoundsCm: const [
            0.0,
            5.5,
            10.3,
            15.0,
            19.8,
            24.5,
            29.3,
            34.0,
            39.5,
          ],
          rowBoundsCm: const [0.0, 5.5, 11.0, 16.6, 22.3, 28.0, 33.5, 39.0],
        );
      } else {
        throw HttpException(
          'Reset grid config failed: ${response.statusCode}',
          uri: uri,
        );
      }
    } catch (e) {
      debugPrint('resetGridConfig error: $e');
      rethrow;
    }
  }

  GridConfigData _gridConfigFromResponse(
    http.Response response, {
    required int cols,
    required int rows,
    required List<double> colBoundsCm,
    required List<double> rowBoundsCm,
  }) {
    try {
      final decoded = jsonDecode(response.body);
      if (decoded is Map<String, dynamic>) {
        return GridConfigData.fromJson(decoded);
      }
    } catch (_) {
      // Some firmware builds reply with plain "OK"; treat 2xx as success.
    }

    final status = response.body.trim().isEmpty ? 'ok' : response.body.trim();
    return GridConfigData(
      cols: cols,
      rows: rows,
      numCells: cols * rows,
      trayWidthCm: 39.5,
      trayHeightCm: 39.0,
      colBoundsCm: colBoundsCm,
      rowBoundsCm: rowBoundsCm,
      status: status,
    );
  }

  Future<EggGridData> getEggGridDataViaProxy() async {
    try {
      final response = await _postEmptyJson(
        Uri.parse('http://$_esp32S3Ip/p4/get_slots'),
      );

      if (response.statusCode == 200) {
        final json = jsonDecode(response.body) as Map<String, dynamic>;
        return EggGridData.fromJson(json);
      } else {
        throw HttpException(
          'Proxy get slots failed: ${response.statusCode}',
          uri: Uri.parse('http://$_esp32S3Ip/p4/get_slots'),
        );
      }
    } catch (e) {
      debugPrint('getEggGridDataViaProxy error: $e');
      rethrow;
    }
  }

  /// GET /p4/get_infertile — Get infertile list via S3 proxy
  Future<List<int>> getInfertileSlotsViaProxy() async {
    try {
      final response = await _postEmptyJson(
        Uri.parse('http://$_esp32S3Ip/p4/get_infertile'),
      );

      if (response.statusCode == 200) {
        final json = jsonDecode(response.body) as Map<String, dynamic>;
        final slots = (json['infertile'] as List?)?.cast<int>() ?? [];
        return slots;
      } else {
        throw HttpException(
          'Proxy get infertile failed: ${response.statusCode}',
          uri: Uri.parse('http://$_esp32S3Ip/p4/get_infertile'),
        );
      }
    } catch (e) {
      debugPrint('getInfertileSlotsViaProxy error: $e');
      rethrow;
    }
  }

  /// POST /p4/set_infertile — Set infertile via S3 proxy
  Future<void> setInfertileSlotsViaProxy(List<int> slots) async {
    try {
      final body = jsonEncode({'infertile': slots});

      final response = await _client
          .post(
            Uri.parse('http://$_esp32S3Ip/p4/set_infertile'),
            headers: {'Content-Type': 'application/json'},
            body: body,
          )
          .timeout(_defaultTimeout);

      if (response.statusCode != 200) {
        throw HttpException(
          'Proxy set infertile failed: ${response.statusCode}',
          uri: Uri.parse('http://$_esp32S3Ip/p4/set_infertile'),
        );
      }
    } catch (e) {
      debugPrint('setInfertileSlotsViaProxy error: $e');
      rethrow;
    }
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Connection Testing & Health Checks
  // ═══════════════════════════════════════════════════════════════════════════

  /// POST /p4/clear_infertile — Clear infertile marks via S3 proxy
  Future<void> clearInfertileSlotsViaProxy() async {
    try {
      final response = await _client
          .post(
            Uri.parse('http://$_esp32S3Ip/p4/clear_infertile'),
            headers: {'Content-Type': 'application/json'},
          )
          .timeout(_defaultTimeout);

      if (response.statusCode != 200) {
        throw HttpException(
          'Proxy clear infertile failed: ${response.statusCode}',
          uri: Uri.parse('http://$_esp32S3Ip/p4/clear_infertile'),
        );
      }
    } catch (e) {
      debugPrint('clearInfertileSlotsViaProxy error: $e');
      rethrow;
    }
  }

  /// Test connectivity to ESP32-S3
  Future<bool> testS3Connection() async {
    try {
      final response = await _postEmptyJson(
        Uri.parse('http://$_esp32S3Ip/sensor'),
        timeout: const Duration(seconds: 3),
      );
      return response.statusCode == 200;
    } catch (e) {
      debugPrint('S3 connection test failed: $e');
      return false;
    }
  }

  /// Test connectivity to ESP32-P4
  Future<bool> testP4Connection() async {
    try {
      final response = await _postEmptyJson(
        _p4ProxyUri('/get_slots'),
        timeout: const Duration(seconds: 3),
      );
      return response.statusCode == 200;
    } catch (e) {
      debugPrint('P4 connection test failed: $e');
      return false;
    }
  }

  /// Test both boards
  Future<ConnectivityStatus> testFullConnectivity() async {
    final s3 = await testS3Connection();
    final p4 = await testP4Connection();
    final leds = await testLedControllerConnection();
    bool subIncubator = false;
    try {
      final sensor = await getSensorData();
      subIncubator = sensor.subIncubatorConnected ?? sensor.received;
    } catch (e) {
      debugPrint('Sub-Incubator connection test failed: $e');
    }
    return ConnectivityStatus(
      s3Connected: s3,
      p4Connected: p4,
      ledsConnected: leds,
      subIncubatorConnected: subIncubator,
    );
  }

  /// Dispose resources
  void dispose() {
    _client.close();
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Data Models for ESP32 Responses
// ─────────────────────────────────────────────────────────────────────────────

/// Sensor data from ESP32-S3 or P4
class SensorData {
  final double? temperature;
  final double? humidity;
  final int? waterLevel;
  final bool? waterLow;
  final int? sensorAgeMs;
  final bool? sensorFresh;
  final bool? subIncubatorConnected;
  final int? subIncubatorAgeMs;
  final String? waterSource;
  final bool? subIncubatorBulb;
  final bool? subIncubatorHumidifier;
  final DateTime? timestamp;
  final bool received;

  SensorData({
    this.temperature,
    this.humidity,
    this.waterLevel,
    this.waterLow,
    this.sensorAgeMs,
    this.sensorFresh,
    this.subIncubatorConnected,
    this.subIncubatorAgeMs,
    this.waterSource,
    this.subIncubatorBulb,
    this.subIncubatorHumidifier,
    this.timestamp,
    required this.received,
  });

  factory SensorData.fromJson(Map<String, dynamic> json) {
    final humValid = json['humValid'] as bool?;
    return SensorData(
      temperature: (json['temp'] as num?)?.toDouble(),
      humidity: humValid == false ? null : (json['hum'] as num?)?.toDouble(),
      waterLevel: (json['waterLevel'] as num?)?.toInt(),
      waterLow: json['waterLow'] as bool?,
      sensorAgeMs: (json['sensorAgeMs'] as num?)?.toInt(),
      sensorFresh: json['sensorFresh'] as bool?,
      subIncubatorConnected: json['subIncubatorConnected'] as bool?,
      subIncubatorAgeMs: (json['subIncubatorAgeMs'] as num?)?.toInt(),
      waterSource: json['waterSource'] as String?,
      subIncubatorBulb: json['subIncubatorBulb'] as bool?,
      subIncubatorHumidifier: json['subIncubatorHumidifier'] as bool?,
      timestamp: json['ts'] != null
          ? DateTime.fromMillisecondsSinceEpoch(
              (json['ts'] as num).toInt() * 1000,
            )
          : null,
      received: json['received'] as bool? ?? false,
    );
  }

  Map<String, dynamic> toJson() => {
    'temp': temperature,
    'hum': humidity,
    'waterLevel': waterLevel,
    'waterLow': waterLow,
    'sensorAgeMs': sensorAgeMs,
    'sensorFresh': sensorFresh,
    'subIncubatorConnected': subIncubatorConnected,
    'subIncubatorAgeMs': subIncubatorAgeMs,
    'waterSource': waterSource,
    'subIncubatorBulb': subIncubatorBulb,
    'subIncubatorHumidifier': subIncubatorHumidifier,
    'ts': timestamp?.millisecondsSinceEpoch,
    'received': received,
  };
}

/// Status from the external 56 LED controller.
class LedControllerStatus {
  final String status;
  final bool wifiConnected;
  final String ip;
  final bool candlingActive;
  final int activeLedCount;
  final bool recentCacheValid;
  final int recentEggCount;
  final int maxLeds;
  final List<int> activeLeds;

  LedControllerStatus({
    required this.status,
    required this.wifiConnected,
    required this.ip,
    required this.candlingActive,
    required this.activeLedCount,
    required this.recentCacheValid,
    required this.recentEggCount,
    required this.maxLeds,
    required this.activeLeds,
  });

  factory LedControllerStatus.fromJson(Map<String, dynamic> json) {
    List<int> parseIntList(dynamic value) {
      final list = value as List? ?? const [];
      return list
          .whereType<num>()
          .map((item) => item.toInt())
          .where((item) => item > 0)
          .toList();
    }

    return LedControllerStatus(
      status: json['status']?.toString() ?? 'unknown',
      wifiConnected: json['wifi_connected'] as bool? ?? false,
      ip: json['ip']?.toString() ?? '',
      candlingActive: json['candling_active'] as bool? ?? false,
      activeLedCount: (json['active_led_count'] as num?)?.toInt() ?? 0,
      recentCacheValid: json['recent_cache_valid'] as bool? ?? false,
      recentEggCount: (json['recent_egg_count'] as num?)?.toInt() ?? 0,
      maxLeds: (json['max_leds'] as num?)?.toInt() ?? 56,
      activeLeds: parseIntList(json['active_leds']),
    );
  }
}

/// Egg grid data from ESP32-P4
class EggGridData {
  final List<bool> eggs; // 56 elements: true = egg present, false = empty
  final int count; // Total eggs detected
  final DateTime? timestamp;
  final Map<String, dynamic>? metadata;
  final List<int> abnormalSlots;
  final List<int> confirmedInfertileSlots;
  final List<int> transferReadySlots;
  final List<int> pendingIntakeSlots;
  final int alertCount;
  final bool intakeModelInstalled;
  final Map<String, dynamic> equipment;

  EggGridData({
    required this.eggs,
    required this.count,
    this.timestamp,
    this.metadata,
    this.abnormalSlots = const [],
    this.confirmedInfertileSlots = const [],
    this.transferReadySlots = const [],
    this.pendingIntakeSlots = const [],
    this.alertCount = 0,
    this.intakeModelInstalled = false,
    this.equipment = const {},
  });

  factory EggGridData.fromJson(Map<String, dynamic> json) {
    List<int> parseSlots(dynamic raw) => raw is List
        ? raw.whereType<num>().map((value) => value.toInt()).toList()
        : const <int>[];

    final eggsList =
        (json['eggs'] as List?)?.map((e) => e as bool).toList() ?? [];

    // Ensure we have exactly 56 eggs
    while (eggsList.length < 56) {
      eggsList.add(false);
    }
    if (eggsList.length > 56) {
      eggsList.removeRange(56, eggsList.length);
    }

    return EggGridData(
      eggs: eggsList,
      count:
          (json['count'] as num?)?.toInt() ?? eggsList.where((e) => e).length,
      timestamp: json['timestamp'] != null
          ? DateTime.fromMillisecondsSinceEpoch(
              (json['timestamp'] as num).toInt() * 1000,
            )
          : null,
      metadata: json['metadata'] as Map<String, dynamic>?,
      abnormalSlots: parseSlots(json['abnormal_slots']),
      confirmedInfertileSlots: parseSlots(json['confirmed_infertile_slots']),
      transferReadySlots: parseSlots(json['transfer_ready_slots']),
      pendingIntakeSlots: parseSlots(json['pending_intake_slots']),
      alertCount: (json['alert_count'] as num?)?.toInt() ?? 0,
      intakeModelInstalled: json['intake_model_installed'] == true,
      equipment: json['equipment'] is Map
          ? Map<String, dynamic>.from(json['equipment'] as Map)
          : const <String, dynamic>{},
    );
  }

  Map<String, dynamic> toJson() => {
    'eggs': eggs,
    'count': count,
    'timestamp': timestamp?.millisecondsSinceEpoch,
    'metadata': metadata,
    'abnormal_slots': abnormalSlots,
    'confirmed_infertile_slots': confirmedInfertileSlots,
    'transfer_ready_slots': transferReadySlots,
    'pending_intake_slots': pendingIntakeSlots,
    'alert_count': alertCount,
    'intake_model_installed': intakeModelInstalled,
    'equipment': equipment,
  };
}

/// Grid configuration saved on ESP32-P4.
class GridConfigData {
  final int cols;
  final int rows;
  final int numCells;
  final double trayWidthCm;
  final double trayHeightCm;
  final List<double> colBoundsCm;
  final List<double> rowBoundsCm;
  final String? status;

  GridConfigData({
    required this.cols,
    required this.rows,
    required this.numCells,
    required this.trayWidthCm,
    required this.trayHeightCm,
    required this.colBoundsCm,
    required this.rowBoundsCm,
    this.status,
  });

  factory GridConfigData.fromJson(Map<String, dynamic> json) {
    List<double> parseBounds(dynamic value) {
      final list = value as List? ?? const [];
      return list.map((item) => (item as num).toDouble()).toList();
    }

    final cols = (json['cols'] as num?)?.toInt() ?? 8;
    final rows = (json['rows'] as num?)?.toInt() ?? 7;

    return GridConfigData(
      cols: cols,
      rows: rows,
      numCells: (json['num_cells'] as num?)?.toInt() ?? cols * rows,
      trayWidthCm: (json['tray_w_cm'] as num?)?.toDouble() ?? 39.5,
      trayHeightCm: (json['tray_h_cm'] as num?)?.toDouble() ?? 39.0,
      colBoundsCm: parseBounds(json['col_bounds_cm']),
      rowBoundsCm: parseBounds(json['row_bounds_cm']),
      status: json['status'] as String?,
    );
  }

  Map<String, dynamic> toJson() => {
    'cols': cols,
    'rows': rows,
    'num_cells': numCells,
    'tray_w_cm': trayWidthCm,
    'tray_h_cm': trayHeightCm,
    'col_bounds_cm': colBoundsCm,
    'row_bounds_cm': rowBoundsCm,
    'status': status,
  };
}

/// Connectivity status for both boards
class ConnectivityStatus {
  final bool s3Connected;
  final bool p4Connected;
  final bool ledsConnected;
  final bool subIncubatorConnected;

  ConnectivityStatus({
    required this.s3Connected,
    required this.p4Connected,
    this.ledsConnected = false,
    this.subIncubatorConnected = false,
  });

  bool get bothConnected =>
      s3Connected && p4Connected && ledsConnected && subIncubatorConnected;
  bool get anyConnected =>
      s3Connected || p4Connected || ledsConnected || subIncubatorConnected;

  @override
  String toString() =>
      'S3: $s3Connected, P4: $p4Connected, LEDs: $ledsConnected, Sub: $subIncubatorConnected';
}
