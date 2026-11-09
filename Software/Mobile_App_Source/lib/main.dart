import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:intl/intl.dart';
import 'package:http/http.dart' as http;
import 'package:network_info_plus/network_info_plus.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:archive/archive.dart';
import 'package:image/image.dart' as img;
import 'package:permission_handler/permission_handler.dart';
import 'services/esp32_service.dart';
import 'services/fertility_classifier.dart';
import 'pages/offline_fertility_test_page.dart';
import 'services/notification_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  runApp(const EggCandlingApp());
}

bool _isDarkTheme(BuildContext context) =>
    Theme.of(context).brightness == Brightness.dark;

Color _appCardColor(BuildContext context) =>
    _isDarkTheme(context) ? const Color(0xFF161B2E) : Colors.white;

Color _appPanelColor(BuildContext context) =>
    _isDarkTheme(context) ? const Color(0xFF1F243A) : const Color(0xFFEFF3FA);

Color _appDeepPanelColor(BuildContext context) =>
    _isDarkTheme(context) ? const Color(0xFF0F111A) : const Color(0xFFE7ECF5);

Color _appTextColor(BuildContext context) =>
    _isDarkTheme(context) ? Colors.white : const Color(0xFF171B24);

Color _appMutedTextColor(BuildContext context) =>
    _isDarkTheme(context) ? Colors.white70 : const Color(0xFF3F4A5C);

Color _appSubtleTextColor(BuildContext context) =>
    _isDarkTheme(context) ? Colors.white54 : const Color(0xFF667085);

Color _appFaintTextColor(BuildContext context) =>
    _isDarkTheme(context) ? Colors.white38 : const Color(0xFF8A94A6);

Color _appDividerColor(BuildContext context) =>
    _isDarkTheme(context) ? Colors.white24 : const Color(0xFFD7DEEA);

Color _appOutlineColor(BuildContext context) =>
    _isDarkTheme(context) ? Colors.white12 : const Color(0xFFE0E6F0);

Color _appDisabledColor(BuildContext context) =>
    _isDarkTheme(context) ? const Color(0xFF37474F) : const Color(0xFFD6DEE9);

class _DatasetCropQuality {
  const _DatasetCropQuality({
    required this.status,
    required this.brightness,
    required this.edgeScore,
  });

  final String status;
  final double brightness;
  final double edgeScore;

  bool get isOk => status == 'ok';
}

class _FertilityClassificationResult {
  const _FertilityClassificationResult({
    required this.analyzedSlots,
    required this.elapsedMs,
  });

  const _FertilityClassificationResult.empty()
    : analyzedSlots = const [],
      elapsedMs = 0;

  final List<int> analyzedSlots;
  final int elapsedMs;
}

class _DatasetCropRecord {
  const _DatasetCropRecord({
    required this.batchId,
    required this.timestamp,
    required this.label,
    required this.row,
    required this.col,
    required this.slotNumber,
    required this.filePath,
    required this.sourcePath,
    required this.width,
    required this.height,
    required this.qualityStatus,
    required this.brightness,
    required this.edgeScore,
  });

  final String batchId;
  final DateTime timestamp;
  final String label;
  final int row;
  final int col;
  final int slotNumber;
  final String filePath;
  final String sourcePath;
  final int width;
  final int height;
  final String qualityStatus;
  final double brightness;
  final double edgeScore;

  static const csvHeader =
      'batch_id,timestamp,label,row,col,slot_number,file_path,'
      'source_path,'
      'width,height,quality_status,brightness,edge_score';

  Map<String, dynamic> toJson() => {
    'batch_id': batchId,
    'timestamp': timestamp.toIso8601String(),
    'label': label,
    'row': row,
    'col': col,
    'slot_number': slotNumber,
    'file_path': filePath,
    'source_path': sourcePath,
    'width': width,
    'height': height,
    'quality_status': qualityStatus,
    'brightness': double.parse(brightness.toStringAsFixed(2)),
    'edge_score': double.parse(edgeScore.toStringAsFixed(2)),
  };

  String toCsvRow() => [
    batchId,
    timestamp.toIso8601String(),
    label,
    row,
    col,
    slotNumber,
    filePath,
    sourcePath,
    width,
    height,
    qualityStatus,
    brightness.toStringAsFixed(2),
    edgeScore.toStringAsFixed(2),
  ].map(_csvCell).join(',');
}

class _DatasetBatchResult {
  const _DatasetBatchResult({
    required this.records,
    required this.previewBytes,
    required this.previewStatuses,
    required this.previewLabels,
    required this.previewSlotNumbers,
    required this.files,
    required this.manifestPath,
    required this.batchCsvPath,
    required this.warningCount,
  });

  final List<_DatasetCropRecord> records;
  final List<Uint8List> previewBytes;
  final List<String> previewStatuses;
  final List<String> previewLabels;
  final List<int> previewSlotNumbers;
  final List<String> files;
  final String manifestPath;
  final String batchCsvPath;
  final int warningCount;

  int get savedCount => records.length;
}

class _IntakeDatasetCropRecord {
  const _IntakeDatasetCropRecord({
    required this.batchId,
    required this.collectionRunId,
    required this.eggKey,
    required this.timestamp,
    required this.captureTrigger,
    required this.label,
    required this.classIndex,
    required this.row,
    required this.col,
    required this.slotNumber,
    required this.p4Occupied,
    required this.placedAt,
    required this.incubationDay,
    required this.filePath,
    required this.sourcePath,
    required this.cropLeft,
    required this.cropTop,
    required this.cropRight,
    required this.cropBottom,
    required this.width,
    required this.height,
    required this.qualityStatus,
    required this.brightness,
    required this.edgeScore,
    required this.selectedLeds,
    required this.ledsVerified,
  });

  final String batchId;
  final String collectionRunId;
  final String eggKey;
  final DateTime timestamp;
  final String captureTrigger;
  final String label;
  final int classIndex;
  final int row;
  final int col;
  final int slotNumber;
  final bool p4Occupied;
  final DateTime? placedAt;
  final int? incubationDay;
  final String filePath;
  final String sourcePath;
  final int cropLeft;
  final int cropTop;
  final int cropRight;
  final int cropBottom;
  final int width;
  final int height;
  final String qualityStatus;
  final double brightness;
  final double edgeScore;
  final List<int> selectedLeds;
  final bool ledsVerified;

  static const csvHeader =
      'batch_id,collection_run_id,egg_key,timestamp,capture_trigger,'
      'label,class_index,row,col,slot_number,p4_occupied,placed_at,'
      'incubation_day,file_path,source_path,crop_left,crop_top,'
      'crop_right,crop_bottom,width,height,quality_status,brightness,'
      'edge_score,selected_leds,leds_verified';

  Map<String, dynamic> toJson() => {
    'batch_id': batchId,
    'collection_run_id': collectionRunId,
    'egg_key': eggKey,
    'timestamp': timestamp.toIso8601String(),
    'capture_trigger': captureTrigger,
    'label': label,
    'class_index': classIndex,
    'row': row,
    'col': col,
    'slot_number': slotNumber,
    'p4_occupied': p4Occupied,
    'placed_at': placedAt?.toIso8601String(),
    'incubation_day': incubationDay,
    'file_path': filePath,
    'source_path': sourcePath,
    'crop': {
      'left': cropLeft,
      'top': cropTop,
      'right': cropRight,
      'bottom': cropBottom,
      'width': width,
      'height': height,
    },
    'quality_status': qualityStatus,
    'brightness': double.parse(brightness.toStringAsFixed(2)),
    'edge_score': double.parse(edgeScore.toStringAsFixed(2)),
    'selected_leds': selectedLeds,
    'leds_verified': ledsVerified,
  };

  String toCsvRow() => [
    batchId,
    collectionRunId,
    eggKey,
    timestamp.toIso8601String(),
    captureTrigger,
    label,
    classIndex,
    row,
    col,
    slotNumber,
    p4Occupied,
    placedAt?.toIso8601String() ?? '',
    incubationDay ?? '',
    filePath,
    sourcePath,
    cropLeft,
    cropTop,
    cropRight,
    cropBottom,
    width,
    height,
    qualityStatus,
    brightness.toStringAsFixed(2),
    edgeScore.toStringAsFixed(2),
    selectedLeds.join('|'),
    ledsVerified,
  ].map(_csvCell).join(',');
}

class _IntakeDatasetBatchResult {
  const _IntakeDatasetBatchResult({
    required this.records,
    required this.previewBytes,
    required this.previewStatuses,
    required this.previewLabels,
    required this.previewSlotNumbers,
    required this.files,
    required this.manifestPath,
    required this.batchCsvPath,
    required this.warningCount,
  });

  final List<_IntakeDatasetCropRecord> records;
  final List<Uint8List> previewBytes;
  final List<String> previewStatuses;
  final List<String> previewLabels;
  final List<int> previewSlotNumbers;
  final List<String> files;
  final String manifestPath;
  final String batchCsvPath;
  final int warningCount;

  int get savedCount => records.length;
}

class _FertilityDatasetCropRecord {
  const _FertilityDatasetCropRecord({
    required this.batchId,
    required this.collectionRunId,
    required this.captureTrigger,
    required this.viewIndex,
    required this.timestamp,
    required this.label,
    required this.trainingEligible,
    required this.verification,
    required this.reviewerId,
    required this.verifiedAt,
    required this.eggId,
    required this.row,
    required this.col,
    required this.slotNumber,
    required this.p4HasEgg,
    required this.incubationDay,
    required this.incubationAgeHours,
    required this.placedAt,
    required this.placedAtConfirmed,
    required this.p4Connected,
    required this.detectionReady,
    required this.filePath,
    required this.sourcePath,
    required this.cropLeft,
    required this.cropTop,
    required this.cropRight,
    required this.cropBottom,
    required this.width,
    required this.height,
    required this.qualityStatus,
    required this.brightness,
    required this.edgeScore,
  });

  final String batchId;
  final String collectionRunId;
  final String captureTrigger;
  final int viewIndex;
  final DateTime timestamp;
  final String label;
  final bool trainingEligible;
  final String verification;
  final String reviewerId;
  final DateTime verifiedAt;
  final String eggId;
  final int row;
  final int col;
  final int slotNumber;
  final bool p4HasEgg;
  final int? incubationDay;
  final int? incubationAgeHours;
  final DateTime? placedAt;
  final bool placedAtConfirmed;
  final bool p4Connected;
  final bool detectionReady;
  final String filePath;
  final String sourcePath;
  final int cropLeft;
  final int cropTop;
  final int cropRight;
  final int cropBottom;
  final int width;
  final int height;
  final String qualityStatus;
  final double brightness;
  final double edgeScore;

  static const csvHeader =
      'schema_version,protocol_version,batch_id,collection_run_id,'
      'capture_trigger,view_index,timestamp,label,'
      'training_eligible,verification,verification_state,'
      'verification_method,verified_at_utc,verdict_scope,reviewer_id,'
      'workflow_status,exclusion_reason,egg_id,'
      'row,col,slot_number,p4_has_egg,incubation_day,incubation_age_hours,'
      'placed_at,placed_at_confirmed,incubation_age_source,p4_connected,'
      'detection_ready,file_path,source_path,'
      'crop_left,crop_top,crop_right,crop_bottom,width,height,quality_status,'
      'brightness,edge_score,capture_endpoint';

  Map<String, dynamic> toJson() => {
    'schema_version': 7,
    'protocol_version': 'fertility_p4_multiview_v7',
    'batch_id': batchId,
    'collection_run_id': collectionRunId,
    'capture_trigger': captureTrigger,
    'view_index': viewIndex,
    'timestamp': timestamp.toIso8601String(),
    'label': label,
    'training_eligible': trainingEligible,
    'verification': verification,
    'verification_state': 'confirmed',
    'verification_method': 'operator_candling_review',
    'verified_at_utc': verifiedAt.toUtc().toIso8601String(),
    'verdict_scope': 'per_slot',
    'reviewer_id': reviewerId,
    'workflow_status': trainingEligible
        ? 'saved_for_training'
        : 'saved_for_quality_review',
    'exclusion_reason': exclusionReason,
    'egg_id': eggId,
    'row': row,
    'col': col,
    'slot_number': slotNumber,
    'p4_has_egg': p4HasEgg,
    'incubation_day': incubationDay,
    'incubation_age_hours': incubationAgeHours,
    'placed_at': placedAt?.toUtc().toIso8601String(),
    'placed_at_confirmed': placedAtConfirmed,
    'incubation_age_source': 'placed_at_to_capture_timestamp',
    'p4_connected': p4Connected,
    'detection_ready': detectionReady,
    'file_path': filePath,
    'source_path': sourcePath,
    'crop_left': cropLeft,
    'crop_top': cropTop,
    'crop_right': cropRight,
    'crop_bottom': cropBottom,
    'width': width,
    'height': height,
    'quality_status': qualityStatus,
    'brightness': double.parse(brightness.toStringAsFixed(2)),
    'edge_score': double.parse(edgeScore.toStringAsFixed(2)),
    'capture_endpoint': '/capture',
  };

  String toCsvRow() => [
    7,
    'fertility_p4_multiview_v7',
    batchId,
    collectionRunId,
    captureTrigger,
    viewIndex,
    timestamp.toIso8601String(),
    label,
    trainingEligible,
    verification,
    'confirmed',
    'operator_candling_review',
    verifiedAt.toUtc().toIso8601String(),
    'per_slot',
    reviewerId,
    trainingEligible ? 'saved_for_training' : 'saved_for_quality_review',
    exclusionReason,
    eggId,
    row,
    col,
    slotNumber,
    p4HasEgg,
    incubationDay,
    incubationAgeHours,
    placedAt?.toUtc().toIso8601String(),
    placedAtConfirmed,
    'placed_at_to_capture_timestamp',
    p4Connected,
    detectionReady,
    filePath,
    sourcePath,
    cropLeft,
    cropTop,
    cropRight,
    cropBottom,
    width,
    height,
    qualityStatus,
    brightness.toStringAsFixed(2),
    edgeScore.toStringAsFixed(2),
    '/capture',
  ].map(_csvCell).join(',');

  String? get exclusionReason {
    if (trainingEligible) return null;
    if (!p4HasEgg) return 'no_egg';
    if (!detectionReady) return 'unsupported_incubation_age';
    if (label != 'fertile' && label != 'infertile') return 'label_pending';
    if (verification != 'operator_candling_review') return 'unverified_label';
    if (qualityStatus != 'ok') return 'bad_capture';
    return 'excluded_by_protocol';
  }
}

class _FertilityDatasetBatchResult {
  const _FertilityDatasetBatchResult({
    required this.records,
    required this.previewBytes,
    required this.previewStatuses,
    required this.previewLabels,
    required this.previewSlotNumbers,
    required this.files,
    required this.manifestPath,
    required this.batchCsvPath,
    required this.warningCount,
  });

  final List<_FertilityDatasetCropRecord> records;
  final List<Uint8List> previewBytes;
  final List<String> previewStatuses;
  final List<String> previewLabels;
  final List<int> previewSlotNumbers;
  final List<String> files;
  final String manifestPath;
  final String batchCsvPath;
  final int warningCount;

  int get savedCount => records.length;
}

class _PendingFertilityDatasetBatch {
  const _PendingFertilityDatasetBatch({
    required this.sourceBytes,
    required this.batchStamp,
    required this.collectionRunId,
    required this.captureTrigger,
    required this.viewIndex,
    required this.capturedAt,
    required this.selectedSlots,
    required this.occupiedSlots,
    required this.slotDays,
    required this.slotPlacedAt,
    required this.slotPlacedAtConfirmed,
    required this.p4EggDay,
    required this.colBounds,
    required this.rowBounds,
    required this.p4Connected,
    required this.ledVerification,
    required this.temperature,
    required this.humidity,
    required this.previewBytes,
    required this.previewStatuses,
    required this.previewSlotNumbers,
  });

  final Uint8List sourceBytes;
  final String batchStamp;
  final String collectionRunId;
  final String captureTrigger;
  final int viewIndex;
  final DateTime capturedAt;
  final List<int> selectedSlots;
  final List<bool> occupiedSlots;
  final List<int?> slotDays;
  final List<DateTime?> slotPlacedAt;
  final List<bool> slotPlacedAtConfirmed;
  final int? p4EggDay;
  final List<double> colBounds;
  final List<double> rowBounds;
  final bool p4Connected;
  final Map<String, dynamic> ledVerification;
  final double? temperature;
  final double? humidity;
  final List<Uint8List> previewBytes;
  final List<String> previewStatuses;
  final List<int> previewSlotNumbers;
}

String _csvCell(Object? value) {
  final text = value?.toString() ?? '';
  final escaped = text.replaceAll('"', '""');
  if (escaped.contains(',') ||
      escaped.contains('"') ||
      escaped.contains('\n') ||
      escaped.contains('\r')) {
    return '"$escaped"';
  }
  return escaped;
}

// App root
class EggCandlingApp extends StatelessWidget {
  const EggCandlingApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Candling',
      debugShowCheckedModeBanner: false,
      theme: _buildLightTheme(),
      darkTheme: _buildDarkTheme(),
      themeMode: ThemeMode.system, // Auto-switch based on system settings
      home: const HomePage(),
    );
  }

  ThemeData _buildLightTheme() {
    return ThemeData.light().copyWith(
      scaffoldBackgroundColor: const Color(0xFFF5F5F5),
      primaryColor: const Color(0xFF2979FF),
      visualDensity: VisualDensity.adaptivePlatformDensity,
      colorScheme: const ColorScheme.light(
        primary: Color(0xFF2979FF),
        secondary: Color(0xFF00E676),
        surface: Colors.white,
      ),
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: {
          TargetPlatform.android: ZoomPageTransitionsBuilder(),
          TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
          TargetPlatform.macOS: CupertinoPageTransitionsBuilder(),
          TargetPlatform.windows: FadeUpwardsPageTransitionsBuilder(),
          TargetPlatform.linux: FadeUpwardsPageTransitionsBuilder(),
        },
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: Color(0xFF2979FF),
        foregroundColor: Colors.white,
        elevation: 0,
      ),
      bottomNavigationBarTheme: const BottomNavigationBarThemeData(
        backgroundColor: Color(0xFFE0E0E0),
        selectedItemColor: Color(0xFF2979FF),
        unselectedItemColor: Colors.black54,
      ),
      cardTheme: CardThemeData(
        color: Colors.white,
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          elevation: 0,
          minimumSize: const Size(48, 48),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: const Color(0xFFEFF3FA),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    );
  }

  ThemeData _buildDarkTheme() {
    return ThemeData.dark().copyWith(
      scaffoldBackgroundColor: const Color(0xFF0F111A),
      primaryColor: const Color(0xFF2979FF),
      visualDensity: VisualDensity.adaptivePlatformDensity,
      colorScheme: const ColorScheme.dark(
        primary: Color(0xFF2979FF),
        secondary: Color(0xFF00E676),
        surface: Color(0xFF161B2E),
      ),
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: {
          TargetPlatform.android: ZoomPageTransitionsBuilder(),
          TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
          TargetPlatform.macOS: CupertinoPageTransitionsBuilder(),
          TargetPlatform.windows: FadeUpwardsPageTransitionsBuilder(),
          TargetPlatform.linux: FadeUpwardsPageTransitionsBuilder(),
        },
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: Color(0xFF0F111A),
        foregroundColor: Colors.white,
        elevation: 0,
      ),
      bottomNavigationBarTheme: const BottomNavigationBarThemeData(
        backgroundColor: Color(0xFF161B2E),
        selectedItemColor: Color(0xFF2979FF),
        unselectedItemColor: Colors.white54,
      ),
      cardTheme: CardThemeData(
        color: const Color(0xFF161B2E),
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          elevation: 0,
          minimumSize: const Size(48, 48),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: const Color(0xFF1F243A),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: const Color(0xFF1F243A),
        contentTextStyle: const TextStyle(color: Colors.white),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    );
  }
}

// HomePage
class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _P4GridDecision {
  const _P4GridDecision({
    required this.eggs,
    required this.sourceFresh,
    required this.protectedSnapshot,
    required this.status,
  });

  final List<bool> eggs;
  final bool sourceFresh;
  final bool protectedSnapshot;
  final String status;
}

enum _CandlingEggScope { allOccupied, day7Plus }

class _HomePageState extends State<HomePage> with WidgetsBindingObserver {
  // Network and WiFi
  final NetworkInfo _networkInfo = NetworkInfo();
  final ESP32Service _esp32 = ESP32Service();
  final FertilityClassifier _fertilityClassifier = FertilityClassifier();
  final NotificationService _notifications = NotificationService();
  bool _isCandling = false;
  bool _isWifiCorrect = false;
  bool _hasCheckedWifi = false;
  String _currentSsid = '';
  String _status = 'Checking WiFi...';
  bool _isBooting = true;
  bool _showModeSelect = true;
  bool _demoMode = false;
  double _startupProgress = 0.05;
  String _startupMessage = 'Starting scanner...';
  String _startupDetail = 'Preparing local setup';
  List<EggData> _eggData = List.generate(gridRows * gridCols, (_) => EggData());

  int _fertileCount = 0;
  int _infertileCount = 0;
  bool _fertilityPending = false;
  bool _fertilityModelReady = false;
  double? _temperature;
  double? _humidity;
  bool? _waterLow;
  int? _waterLevel;
  List<SensorSnapshot> _sensorHistory = [];
  DateTime? _lastSensorHistoryAt;

  List<EggSession> _sessions = [];
  List<EggCounterRecord> _eggCounterHistory = [];
  Uint8List? _capturedImage;
  DateTime? _captureTimestamp;
  int _countdown = 0;
  int _countdownTotal = 30;
  Timer? _countdownTimer;

  bool _isSelectionMode = false;
  final Set<int> _selectedSessions = {};
  bool _isCounterSelectionMode = false;
  final Set<int> _selectedCounterRecords = {};
  bool _isResetting = false;
  String _languageCode = 'en';

  bool _isStreaming = true;
  // True when the user manually turned the stream off via the banner toggle.
  // The stream then stays off when returning to the dashboard from other tabs
  // (the auto-off in other tabs for camera-overheat protection is untouched).
  bool _streamManuallyOff = false;
  bool _streamFrameReceived = false;
  bool _isDownloading = false;
  int _streamKey = 0;
  _CandlingEggScope _candlingEggScope = _CandlingEggScope.allOccupied;
  Timer? _sensorTimer;
  bool _sensorFetchInProgress = false;

  static const int _esp32S3StreamPort = 81;
  final String _esp32S3Ip = '192.168.4.1';
  bool _isConnectedToCorrectSSID = false;
  bool _incubatorWifiRequestInProgress = false;
  bool _incubatorNetworkHeld = false;
  bool _incubatorConcurrentInternetSupported = false;
  String _incubatorNetworkStatus = 'Local incubator link not requested';
  Timer? _incubatorNetworkReleaseTimer;
  bool _p4Connected = false;
  bool _s3Connected = false;
  bool _ledsConnected = false;
  // MAIN incubator actuators (P4 SHT3X temp/hum feed _temperature/_humidity;
  // water/bulb/humidifier are owned by the S3).
  bool _mainConnected = false;
  int? _mainAgeMs;
  bool? _mainBulbOn;
  bool? _mainHumidifierOn;
  // SUB incubator (lockdown relay node) climate.
  bool _subIncubatorConnected = false;
  int? _subIncubatorAgeMs;
  String? _subIncubatorWaterSource;
  bool? _subIncubatorBulbOn;
  bool? _subIncubatorHumidifierOn;
  double? _subTemperature;
  double? _subHumidity;
  int? _subWaterLevel;
  bool? _subWaterLow;
  int? _ledActiveCount;
  int? _ledRecentEggCount;
  bool _ledRecentCacheValid = false;
  String _ledTestStatus = 'Not tested yet';
  bool _ledTestBusy = false;
  final Set<int> _selectedLedNumbers = <int>{};
  int? _p4EggCount;
  int? _p4EggDay;
  List<bool> _p4SlotHasEgg = List<bool>.filled(gridRows * gridCols, false);
  List<int?> _p4SlotDays = List<int?>.filled(gridRows * gridCols, null);
  List<DateTime?> _p4SlotPlacedAt = List<DateTime?>.filled(
    gridRows * gridCols,
    null,
  );
  List<bool> _p4SlotPlacedAtConfirmed = List<bool>.filled(
    gridRows * gridCols,
    false,
  );
  List<String> _p4SlotIntakeVerdict = List<String>.filled(
    gridRows * gridCols,
    'none',
  );
  List<String> _p4SlotFertilityVerdict = List<String>.filled(
    gridRows * gridCols,
    'none',
  );
  List<bool> _p4SlotAbnormal = List<bool>.filled(gridRows * gridCols, false);
  List<bool> _p4SlotConfirmedInfertile = List<bool>.filled(
    gridRows * gridCols,
    false,
  );
  List<bool> _p4SlotTransferReady = List<bool>.filled(
    gridRows * gridCols,
    false,
  );
  int _p4PhysicalAlertCount = 0;
  bool _p4AutomaticIntakeScreeningEnabled = false;
  bool _p4EquipmentFaultActive = false;
  String _p4EquipmentFaultCode = 'none';
  String _p4EquipmentFaultMessage = '';
  bool _hasStableP4Grid = false;
  int? _lastAcceptedP4ScanEpoch;
  List<bool>? _pendingP4RemovalGrid;
  int? _pendingP4RemovalScanEpoch;
  bool _p4GridUsingPreservedSnapshot = false;
  String _p4GridDataStatus = 'Waiting for a completed P4 scan';
  DateTime? _lastSyncTime;
  DateTime? _lastP4RtcSyncAt;
  DateTime? _p4LastPhoneSyncAt;
  bool _p4RtcSyncInProgress = false;
  bool _p4TimeTrusted = false;
  bool _p4TimeSyncRequired = true;
  bool _slotMetadataDirty = false;
  Timer? _p4PollTimer;
  String _lastGridSyncStatus = 'Not synced yet';
  DateTime? _lastGridSyncTime;
  int? _lastGridSyncMs;
  int? _lastCaptureMs;
  int? _lastTotalScanMs;
  bool? _lastCandlingLightsVerified;
  bool? _lastCandlingLedCacheValid;
  List<int> _lastActiveCandlingLeds = const [];
  List<int> _lastMissingCandlingLeds = const [];
  bool _notificationsReady = false;

  static const int gridCols = 8;
  static const int gridRows = 7;
  static const int _morningCheckInNotificationId = 7001;
  static const int _eveningCheckInNotificationId = 7002;
  static const int _maxSensorHistorySamples = 5000;
  static const int _maxEggCounterHistoryRecords = 500;
  static const Duration _sensorHistoryInterval = Duration(minutes: 5);
  static const String _actualOnboardingCompleteKey =
      'actual_onboarding_complete';
  static const String _demoOnboardingCompleteKey = 'demo_onboarding_complete';
  static const String _notificationPermissionPromptedKey =
      'notification_permission_prompted';
  static const Duration _datasetCaptureInterval = Duration(minutes: 2);
  static const Duration _fertilityDatasetCaptureInterval = Duration(
    seconds: 15,
  );
  static const int _fertilityDatasetMinDay = 5;
  static const int _fertilityDatasetMaxDay = 10;
  static const int _fertilityDatasetTargetViews = 8;
  static const Duration _cameraCaptureRequestTimeout = Duration(seconds: 90);
  static const Duration _captureHoldSettleDelay = Duration(milliseconds: 1200);
  static const Duration _intakeCandlingSettleDelay = Duration(seconds: 3);
  static const Duration _ledTestCaptureWaitTimeout = Duration(seconds: 22);
  static const Duration _p4RtcSyncInterval = Duration(minutes: 10);
  static const String _datasetCaptureEndpoint = '/capturep4';
  static const String _intakeDatasetCaptureEndpoint = '/capture';
  static const String _fertilityDatasetCaptureEndpoint = '/capture';
  static const String _fertilityDatasetVerification =
      'operator_candling_review';
  static const String _fertilityDatasetReviewerId = 'operator_01';
  static const String _stableP4GridSnapshotKey = 'stable_p4_grid_snapshot_v1';
  static const String _slotPlacedAtConfirmedKey = 'slot_placed_at_confirmed_v1';
  static const String _gridCalibrationCaptureEndpoint = '/capturep4';

  int _currentIndex = 0;
  bool _showGridOverlay = false;

  static const int _maxDailyPdfExports = 5;

  static const _channel = MethodChannel(
    'com.eggcandling.egg_candling_app/platform_bridge',
  );

  int get _activeGridCols => gridCols;
  int get _activeGridRows => gridRows;
  int get _activeGridCellCount => _activeGridCols * _activeGridRows;

  List<double> get _scanColBoundaries => _scanBoundariesForAxis(
    _customColBoundaries,
    cellCount: gridCols,
    maxValue: _trayWidthCm,
    fallback: _defaultColBoundaries,
  );

  List<double> get _scanRowBoundaries => _scanBoundariesForAxis(
    _customRowBoundaries,
    cellCount: gridRows,
    maxValue: _trayHeightCm,
    fallback: _defaultRowBoundaries,
  );

  List<double> _scanBoundariesForAxis(
    List<double> boundaries, {
    required int cellCount,
    required double maxValue,
    required List<double> fallback,
  }) {
    final boundaryCount = boundaries.length - 1;
    if (!_isValidBoundarySet(
      boundaries,
      cellCount: boundaryCount,
      maxValue: maxValue,
    )) {
      return List<double>.from(fallback);
    }
    if (boundaryCount == cellCount) {
      return List<double>.from(boundaries);
    }

    final first = boundaries.first;
    final last = boundaries.last;
    final step = (last - first) / cellCount;
    return List<double>.generate(
      cellCount + 1,
      (index) => first + index * step,
    );
  }

  String _t(String key) {
    const translations = {
      'en': {
        'dashboard': 'Dashboard',
        'history': 'History',
        'gridCustom': 'Grid Custom',
        'settings': 'Settings',
        'faq': 'FAQ',
        'aboutUs': 'About Us',
        'mainMenu': 'Main Menu',
        'tools': 'Tools',
        'today': 'Today',
        'threeDays': '3 Days',
        'fertility': 'Fertility',
        'latest': 'Latest',
        'readyFarm': 'Live controls and local records',
        'connectedHub': 'Connected to AI_CANDLING',
        'openWifi': 'Open WiFi Settings',
        'connectHub': 'Connect to AI_CANDLING',
        'refreshApp': 'Refresh App',
        'refreshSubtitle': 'Reload WiFi, stream, sensors, grid, and history',
        'backupData': 'Backup Data',
        'backupSubtitle': 'Share a backup copy of saved candling records',
        'language': 'Language',
        'languageSubtitle': 'English, Tagalog, or Bisaya',
        'appVersion': 'App Version',
        'farmerGuide': 'Farmer quick guide',
        'farmerGuideText':
            'Connect to AI_CANDLING, check the live stream, press AI CANDLING, review slot readiness, then export from History if needed.',
        'wifiQuestion': 'Why connect to WiFi first?',
        'wifiAnswer':
            'Candling reads the ESP32 camera and incubator data through AI_CANDLING.',
        'day7Question': 'When is infertile detection valid?',
        'day7Answer':
            'Fertile / Infertile classification runs for occupied eggs from Day 5 through Day 10.',
        'gridQuestion': 'What does Grid Custom do?',
        'gridAnswer':
            'It aligns the saved capture grid to the real egg tray so research records match the correct slots.',
        'reportQuestion': 'Where are reports?',
        'reportAnswer':
            'Open History, tap the export button, then choose Today, Last 7 Days, Last 30 Days, or Custom.',
        'connecting': 'Connecting...',
        'currentWifi': 'Current WiFi',
        'none': 'None',
        'howToConnect': 'How to Connect:',
        'connectSteps':
            '1. Go to WiFi Settings\n2. Connect to "AI_CANDLING" network\n3. Password: thesis123\n4. Return to this app',
        'connectNow': 'CONNECT NOW',
      },
      'tl': {
        'dashboard': 'Dashboard',
        'history': 'Kasaysayan',
        'gridCustom': 'Ayos ng Grid',
        'settings': 'Settings',
        'faq': 'Mga Tanong',
        'aboutUs': 'Tungkol sa Amin',
        'mainMenu': 'Main Menu',
        'tools': 'Tools',
        'today': 'Ngayon',
        'threeDays': '3 Araw',
        'fertility': 'Fertility',
        'latest': 'Huli',
        'readyFarm': 'Mga kontrol at lokal na tala',
        'connectedHub': 'Nakakonekta sa AI_CANDLING',
        'openWifi': 'Buksan ang WiFi Settings',
        'connectHub': 'Kumonekta sa AI_CANDLING',
        'refreshApp': 'I-refresh ang App',
        'refreshSubtitle':
            'I-reload ang WiFi, stream, sensors, grid, at history',
        'backupData': 'Backup ng Data',
        'backupSubtitle': 'I-share ang backup copy ng candling records',
        'language': 'Wika',
        'languageSubtitle': 'English, Tagalog, o Bisaya',
        'appVersion': 'Bersyon ng App',
        'farmerGuide': 'Mabilis na gabay para sa farmer',
        'farmerGuideText':
            'Kumonekta sa AI_CANDLING, tingnan ang live stream, pindutin ang AI CANDLING, suriin ang readiness ng slots, tapos mag-export sa History kung kailangan.',
        'wifiQuestion': 'Bakit kailangan muna kumonekta sa WiFi?',
        'wifiAnswer':
            'Binabasa ng Candling ang ESP32 camera at incubator data gamit ang AI_CANDLING.',
        'day7Question': 'Kailan valid ang infertile detection?',
        'day7Answer':
            'Ang Fertile / Infertile classification ay para sa occupied eggs mula Day 5 hanggang Day 10.',
        'gridQuestion': 'Para saan ang Grid Custom?',
        'gridAnswer':
            'Ina-align nito ang saved capture grid sa totoong egg tray para tumama ang research record sa tamang slot.',
        'reportQuestion': 'Nasaan ang reports?',
        'reportAnswer':
            'Buksan ang History, pindutin ang export button, tapos pumili ng Today, Last 7 Days, Last 30 Days, o Custom.',
        'connecting': 'Kumokonekta...',
        'currentWifi': 'Kasalukuyang WiFi',
        'none': 'Wala',
        'howToConnect': 'Paano Kumonekta:',
        'connectSteps':
            '1. Pumunta sa WiFi Settings\n2. Kumonekta sa "AI_CANDLING"\n3. Password: thesis123\n4. Bumalik sa app',
        'connectNow': 'KONEKTA NGAYON',
      },
      'ceb': {
        'dashboard': 'Dashboard',
        'history': 'Kasaysayan',
        'gridCustom': 'Ayos sa Grid',
        'settings': 'Settings',
        'faq': 'Mga Pangutana',
        'aboutUs': 'Mahitungod Kanamo',
        'mainMenu': 'Main Menu',
        'tools': 'Tools',
        'today': 'Karong Adlawa',
        'threeDays': '3 Ka Adlaw',
        'fertility': 'Fertility',
        'latest': 'Pinakabag-o',
        'readyFarm': 'Mga kontrol ug lokal nga rekord',
        'connectedHub': 'Nakakonekta sa AI_CANDLING',
        'openWifi': 'Ablihi ang WiFi Settings',
        'connectHub': 'Konekta sa AI_CANDLING',
        'refreshApp': 'I-refresh ang App',
        'refreshSubtitle':
            'I-reload ang WiFi, stream, sensors, grid, ug history',
        'backupData': 'Backup sa Data',
        'backupSubtitle': 'I-share ang backup copy sa candling records',
        'language': 'Pinulongan',
        'languageSubtitle': 'English, Tagalog, o Bisaya',
        'appVersion': 'Bersyon sa App',
        'farmerGuide': 'Dali nga giya para sa farmer',
        'farmerGuideText':
            'Konekta sa AI_CANDLING, tan-awa ang live stream, pindota ang AI CANDLING, susiha ang readiness sa slots, dayon export sa History kung kinahanglan.',
        'wifiQuestion': 'Ngano kailangan una mokonekta sa WiFi?',
        'wifiAnswer':
            'Basahon sa Candling ang ESP32 camera ug incubator data gamit ang AI_CANDLING.',
        'day7Question': 'Kanus-a valid ang infertile detection?',
        'day7Answer':
            'Ang Fertile / Infertile classification para sa occupied eggs gikan Day 5 hangtod Day 10.',
        'gridQuestion': 'Para asa ang Grid Custom?',
        'gridAnswer':
            'I-align niini ang saved capture grid sa tinuod nga egg tray para ang research record motugma sa sakto nga slot.',
        'reportQuestion': 'Asa makita ang reports?',
        'reportAnswer':
            'Ablihi ang History, pindota ang export button, dayon pili og Today, Last 7 Days, Last 30 Days, o Custom.',
        'connecting': 'Nagkonekta...',
        'currentWifi': 'Karon nga WiFi',
        'none': 'Wala',
        'howToConnect': 'Unsaon Pagkonekta:',
        'connectSteps':
            '1. Adto sa WiFi Settings\n2. Konekta sa "AI_CANDLING"\n3. Password: thesis123\n4. Balik sa app',
        'connectNow': 'KONEKTA KARON',
      },
    };

    return translations[_languageCode]?[key] ?? translations['en']![key] ?? key;
  }

  String get _languageName {
    switch (_languageCode) {
      case 'tl':
        return 'Tagalog';
      case 'ceb':
        return 'Bisaya';
      default:
        return 'English';
    }
  }

  Duration get _candlingCameraSettleDelay => const Duration(milliseconds: 800);

  Duration get _candlingCaptureTimeout {
    // No practical limit on the capture: the ESP32 camera usually takes a few
    // seconds but can take longer, and the analysis happens on the phone (not
    // the prototype). This large value only recovers from a fully hung camera;
    // normal slow captures are never cut off.
    return const Duration(minutes: 5);
  }

  Duration get _candlingP4Timeout => const Duration(seconds: 10);

  int get _candlingCooldownSeconds => 30;

  int get _currentReadyEggCount {
    var count = 0;
    for (var index = 0; index < _activeGridCellCount; index++) {
      if (_slotIsFertilityDatasetAgeReady(index)) count++;
    }
    return count;
  }

  int get _currentInReviewCount {
    var count = 0;
    for (var index = 0; index < _activeGridCellCount; index++) {
      if (_slotHasEgg(index) &&
          (index >= _eggData.length ||
              _eggData[index].status == EggStatus.unknown)) {
        count++;
      }
    }
    return count;
  }

  String get _currentDayRangeLabel {
    final days = <int>[];
    for (var index = 0; index < _activeGridCellCount; index++) {
      if (!_slotHasEgg(index)) continue;
      final day = _slotDay(index);
      if (day != null) days.add(day);
    }
    if (days.isEmpty) return 'Day --';
    days.sort();
    return days.first == days.last
        ? 'Day ${days.first}'
        : 'Days ${days.first}-${days.last}';
  }

  // Grid customization
  static const double _trayWidthCm = 39.5;
  static const double _trayHeightCm = 39.0;
  static const int _gridDefaultVersion = 2;
  static const List<double> _defaultColBoundaries = [
    8.0,
    12.0,
    15.0,
    17.9,
    20.8,
    23.6,
    26.6,
    29.6,
    33.2,
  ];
  static const List<double> _defaultRowBoundaries = [
    2.3,
    7.9,
    12.8,
    17.1,
    21.7,
    26.2,
    30.5,
    36.2,
  ];

  List<double> _customColBoundaries = List<double>.from([
    8.0,
    12.0,
    15.0,
    17.9,
    20.8,
    23.6,
    26.6,
    29.6,
    33.2,
  ]);
  List<double> _customRowBoundaries = List<double>.from([
    2.3,
    7.9,
    12.8,
    17.1,
    21.7,
    26.2,
    30.5,
    36.2,
  ]);

  // Global line length factor (applies uniformly to all grid lines)
  double _globalLineLengthScale = 1.0;
  double _lineLengthStep = 0.1;

  int? _selectedBoundaryIndex;
  bool _selectedBoundaryIsCol = true;
  bool _selectedCountIsCol = false;
  double _adjustStep = 0.5;
  bool _gridSaved = false;
  Uint8List? _gridCalibrationImage;
  bool _isCapturingCalibration = false;
  bool _referenceTrashDimmed = false;
  Timer? _referenceTrashOpacityTimer;
  bool _isDatasetCapturing = false;
  bool _isDatasetAutoCapturing = false;
  Timer? _datasetAutoCaptureTimer;
  Timer? _datasetCountdownTimer;
  DateTime? _datasetNextCaptureAt;
  int _datasetNextCaptureSeconds = 0;
  String _datasetCaptureLabel = 'egg_present';
  final Set<int> _datasetSelectedEggSlots = <int>{};
  int _datasetCaptureCount = 0;
  int _datasetLastBatchCount = 0;
  int _datasetLastQualityWarningCount = 0;
  Uint8List? _datasetLastImage;
  List<Uint8List> _datasetLastCropPreviews = const [];
  List<String> _datasetLastCropStatuses = const [];
  List<String> _datasetLastCropLabels = const [];
  List<int> _datasetLastCropSlotNumbers = const [];
  String? _datasetLastManifestPath;
  String? _datasetLastCsvPath;
  String? _datasetRootPath;
  List<String> _datasetLastBatchFiles = const [];
  String _datasetCaptureTool = 'egg_counter';
  final Map<int, String> _intakeDatasetLabels = <int, String>{};
  Map<int, String>? _intakeDatasetLockedLabels;
  bool _isIntakeDatasetCapturing = false;
  bool _isIntakeDatasetAutoCapturing = false;
  Timer? _intakeDatasetAutoCaptureTimer;
  Timer? _intakeDatasetCountdownTimer;
  DateTime? _intakeDatasetNextCaptureAt;
  int _intakeDatasetNextCaptureSeconds = 0;
  String? _intakeDatasetCollectionRunId;
  int _intakeDatasetCaptureCount = 0;
  int _intakeDatasetLastBatchCount = 0;
  int _intakeDatasetLastQualityWarningCount = 0;
  Uint8List? _intakeDatasetLastImage;
  List<Uint8List> _intakeDatasetLastCropPreviews = const [];
  List<String> _intakeDatasetLastCropStatuses = const [];
  List<String> _intakeDatasetLastCropLabels = const [];
  List<int> _intakeDatasetLastCropSlotNumbers = const [];
  String? _intakeDatasetLastManifestPath;
  String? _intakeDatasetLastCsvPath;
  String? _intakeDatasetRootPath;
  List<String> _intakeDatasetLastBatchFiles = const [];
  bool _isFertilityDatasetCapturing = false;
  bool _isFertilityDatasetSaving = false;
  bool _isFertilityDatasetAutoCapturing = false;
  Timer? _fertilityDatasetAutoCaptureTimer;
  Timer? _fertilityDatasetCountdownTimer;
  DateTime? _fertilityDatasetNextCaptureAt;
  int _fertilityDatasetNextCaptureSeconds = 0;
  String? _fertilityDatasetCollectionRunId;
  Map<int, String>? _fertilityDatasetLockedLabels;
  Map<int, int>? _fertilityDatasetLockedPlacedAtEpochMs;
  int _fertilityDatasetCompletedViewCount = 0;
  int _fertilityDatasetCaptureCount = 0;
  int _fertilityDatasetLastBatchCount = 0;
  int _fertilityDatasetLastQualityWarningCount = 0;
  Uint8List? _fertilityDatasetLastImage;
  List<Uint8List> _fertilityDatasetLastCropPreviews = const [];
  List<String> _fertilityDatasetLastCropStatuses = const [];
  List<String> _fertilityDatasetLastCropLabels = const [];
  List<int> _fertilityDatasetLastCropSlotNumbers = const [];
  int _selectedFertilityDatasetCropIndex = 0;
  _PendingFertilityDatasetBatch? _pendingFertilityDatasetBatch;
  String? _fertilityDatasetLastManifestPath;
  String? _fertilityDatasetLastCsvPath;
  String? _fertilityDatasetRootPath;
  List<String> _fertilityDatasetLastBatchFiles = const [];
  List<String> _fertilityDatasetRunFiles = const [];
  // Uniform scaling toggles
  bool _uniformRows = false;
  bool _uniformCols = false;

  // History search
  final TextEditingController _searchController = TextEditingController();
  final TextEditingController _lineLengthStepController =
      TextEditingController();
  final TextEditingController _adjustStepController = TextEditingController();
  String _historySearch = '';

  Uri _s3Uri(String path) => Uri.parse('http://$_esp32S3Ip$path');
  Uri _s3StreamUri() =>
      Uri.parse('http://$_esp32S3Ip:$_esp32S3StreamPort/stream');

  Future<http.Response> _getP4(
    String path, {
    Duration timeout = const Duration(seconds: 10),
  }) async {
    return http
        .post(_s3Uri('/p4$path'), headers: {'Content-Type': 'application/json'})
        .timeout(timeout);
  }

  Future<http.Response> _postP4(
    String path,
    Map<String, dynamic> body, {
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final encoded = jsonEncode(body);
    final headers = {'Content-Type': 'application/json'};
    return http
        .post(_s3Uri('/p4$path'), headers: headers, body: encoded)
        .timeout(timeout);
  }

  Future<void> _syncPhoneTimeToP4({bool force = false}) async {
    if (_p4RtcSyncInProgress) return;

    final previousSync = _lastP4RtcSyncAt;
    if (!force &&
        previousSync != null &&
        DateTime.now().difference(previousSync) < _p4RtcSyncInterval) {
      return;
    }

    _p4RtcSyncInProgress = true;
    try {
      final now = DateTime.now();
      final response = await _postP4('/time_sync', {
        'year': now.year,
        'month': now.month,
        'day': now.day,
        'hour': now.hour,
        'minute': now.minute,
        'second': now.second,
        'millisecond': now.millisecond,
        'epoch_ms': now.millisecondsSinceEpoch,
        'timezone_offset_minutes': now.timeZoneOffset.inMinutes,
        'timezone_name': now.timeZoneName,
      }, timeout: const Duration(seconds: 5));

      if (response.statusCode >= 200 && response.statusCode < 300) {
        DateTime? p4Epoch;
        try {
          final data = jsonDecode(response.body) as Map<String, dynamic>;
          p4Epoch = _dateTimeFromEpochValue(data['epoch']);
        } catch (_) {
          p4Epoch = now;
        }
        if (mounted) {
          setState(() {
            _lastP4RtcSyncAt = DateTime.now();
            _p4LastPhoneSyncAt = p4Epoch ?? now;
            _p4TimeTrusted = true;
            _p4TimeSyncRequired = false;
          });
        } else {
          _lastP4RtcSyncAt = DateTime.now();
          _p4LastPhoneSyncAt = p4Epoch ?? now;
          _p4TimeTrusted = true;
          _p4TimeSyncRequired = false;
        }
        debugPrint('P4 RTC synced from phone: ${response.body}');
      } else {
        debugPrint('P4 RTC sync failed: HTTP ${response.statusCode}');
      }
    } catch (e) {
      debugPrint('P4 RTC sync error: $e');
    } finally {
      _p4RtcSyncInProgress = false;
    }
  }

  bool _slotHasEgg(int index) =>
      index >= 0 && index < _p4SlotHasEgg.length && _p4SlotHasEgg[index];

  String _slotIntakeVerdict(int index) =>
      index >= 0 && index < _p4SlotIntakeVerdict.length
      ? _p4SlotIntakeVerdict[index]
      : 'none';

  bool _slotFlag(List<bool> flags, int index) =>
      index >= 0 && index < flags.length && flags[index];

  DateTime? _slotPlacedAt(int index) {
    if (index >= 0 && index < _p4SlotPlacedAt.length) {
      return _p4SlotPlacedAt[index];
    }
    return null;
  }

  int? _daysSincePlaced(DateTime? placedAt, {DateTime? now}) {
    if (placedAt == null) return null;
    final current = now ?? DateTime.now();
    if (current.isBefore(placedAt)) return 0;
    return current.difference(placedAt).inDays;
  }

  int? _slotDay(int index) {
    final fromPlacedAt = _daysSincePlaced(_slotPlacedAt(index));
    if (fromPlacedAt != null) return fromPlacedAt;
    if (index >= 0 && index < _p4SlotDays.length) {
      return _p4SlotDays[index] ?? _p4EggDay;
    }
    return _p4EggDay;
  }

  bool _slotIsDetectionReady(int index) {
    final day = _slotDay(index);
    return day != null &&
        day >= _fertilityDatasetMinDay &&
        day <= _fertilityDatasetMaxDay;
  }

  bool _slotMatchesCandlingScope(int index) {
    if (!_slotHasEgg(index)) return false;
    if (_candlingEggScope == _CandlingEggScope.allOccupied) return true;
    final day = _slotDay(index);
    return day != null && day >= 7;
  }

  String get _candlingEggScopeLabel =>
      _candlingEggScope == _CandlingEggScope.allOccupied
      ? 'All eggs'
      : '7+ days';

  bool _slotIsFertilityDatasetAgeReady(int slotIndex, {DateTime? now}) {
    if (!_slotHasEgg(slotIndex)) return false;
    final placedAt = _slotPlacedAt(slotIndex);
    if (placedAt != null) {
      final capturedAt = now ?? DateTime.now();
      if (capturedAt.isBefore(placedAt)) return false;
      final day = capturedAt.difference(placedAt).inDays;
      return day >= _fertilityDatasetMinDay && day <= _fertilityDatasetMaxDay;
    }
    final day = _slotDay(slotIndex);
    return day != null &&
        day >= _fertilityDatasetMinDay &&
        day <= _fertilityDatasetMaxDay;
  }

  int? _fertilityDatasetTimestampDay(int slotIndex, {DateTime? now}) {
    if (!_slotHasEgg(slotIndex)) return null;
    final placedAt = _slotPlacedAt(slotIndex);
    if (placedAt == null) return null;
    final capturedAt = now ?? DateTime.now();
    if (capturedAt.isBefore(placedAt)) return null;
    return capturedAt.difference(placedAt).inDays;
  }

  bool _slotIsFertilityDatasetTimestampReady(int slotIndex, {DateTime? now}) {
    final day = _fertilityDatasetTimestampDay(slotIndex, now: now);
    return day != null &&
        day >= _fertilityDatasetMinDay &&
        day <= _fertilityDatasetMaxDay;
  }

  String _formatSlotDateTime(DateTime? value) {
    if (value == null) return '--';
    return DateFormat('MMM dd, yyyy h:mm a').format(value);
  }

  String _formatSlotAge(DateTime? placedAt) {
    if (placedAt == null) return '--';
    final duration = DateTime.now().difference(placedAt);
    if (duration.isNegative) return '0 days';
    final days = duration.inDays;
    final hours = duration.inHours.remainder(24);
    return '$days day${days == 1 ? '' : 's'}, $hours hour${hours == 1 ? '' : 's'}';
  }

  Future<int> _androidSdkVersion() async {
    if (!Platform.isAndroid) return 0;
    try {
      final status = await _channel.invokeMethod<Map<dynamic, dynamic>>(
        'getIncubatorHubStatus',
      );
      return (status?['sdk'] as num?)?.toInt() ?? 0;
    } catch (_) {
      return 0;
    }
  }

  Future<bool> _ensureIncubatorWifiPermission({int? sdk}) async {
    if (!Platform.isAndroid) return true;
    final androidSdk = sdk ?? await _androidSdkVersion();
    final permission = androidSdk >= 33
        ? Permission.nearbyWifiDevices
        : Permission.locationWhenInUse;
    var status = await permission.status;
    if (!status.isGranted) status = await permission.request();
    return status.isGranted;
  }

  Future<void> _releaseIncubatorNetwork({bool updateUi = true}) async {
    _incubatorNetworkReleaseTimer?.cancel();
    _incubatorNetworkReleaseTimer = null;
    try {
      await _channel.invokeMethod('releaseIncubatorHub');
    } catch (e) {
      debugPrint('Release incubator WiFi error: $e');
    }
    if (!updateUi || !mounted) return;
    setState(() {
      _incubatorNetworkHeld = false;
      _incubatorConcurrentInternetSupported = false;
      _incubatorNetworkStatus = 'Incubator link released while app is away';
    });
  }

  Future<void> _openWifiSettings() async {
    if (_incubatorWifiRequestInProgress) return;
    if (mounted) {
      setState(() {
        _incubatorWifiRequestInProgress = true;
        _status = 'Requesting local AI_CANDLING connection...';
        _incubatorNetworkStatus = 'Waiting for Android WiFi approval';
        _isStreaming = false;
        _streamKey++;
      });
    }

    try {
      if (!Platform.isAndroid) {
        await _channel.invokeMethod('openWifiSettings');
        return;
      }

      final nativeStatus = await _channel.invokeMethod<Map<dynamic, dynamic>>(
        'getIncubatorHubStatus',
      );
      final sdk = (nativeStatus?['sdk'] as num?)?.toInt() ?? 0;
      if (!await _ensureIncubatorWifiPermission(sdk: sdk)) {
        throw PlatformException(
          code: 'WIFI_PERMISSION_REQUIRED',
          message: 'WiFi permission is needed to hold AI_CANDLING.',
        );
      }

      final raw = await _channel.invokeMethod<Map<dynamic, dynamic>>(
        'connectIncubatorHub',
      );
      final response = raw == null
          ? const <String, dynamic>{}
          : Map<String, dynamic>.from(raw);
      final networkStatus = response['status']?.toString() ?? 'unavailable';
      final connected =
          networkStatus == 'connected' && response['bound'] == true;
      final concurrent = response['concurrentInternetSupported'] == true;
      final message = response['message']?.toString();

      if (!mounted) return;
      setState(() {
        _incubatorNetworkHeld = connected;
        _incubatorConcurrentInternetSupported = concurrent;
        _incubatorNetworkStatus = connected
            ? concurrent
                  ? 'AI_CANDLING held | phone internet remains available'
                  : 'AI_CANDLING held | other apps may use mobile data'
            : message ?? 'AI_CANDLING connection was not completed';
        _status = connected
            ? 'AI_CANDLING local link ready'
            : _incubatorNetworkStatus;
      });

      if (connected) {
        await Future.delayed(const Duration(milliseconds: 500));
        if (mounted) await _loadStream(waitForConnectivity: true);
      } else if (networkStatus == 'settings_required') {
        // Android 8/9 fallback already opened WiFi settings natively.
      } else if (networkStatus == 'unavailable' && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              message ?? 'AI_CANDLING was not found. Move closer and retry.',
            ),
            duration: const Duration(seconds: 4),
          ),
        );
      }
    } on PlatformException catch (e) {
      debugPrint('Incubator WiFi request error: ${e.message}');
      if (!mounted) return;
      setState(() {
        _incubatorNetworkHeld = false;
        _incubatorNetworkStatus = e.message ?? 'Could not request AI_CANDLING';
        _status = _incubatorNetworkStatus;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(_incubatorNetworkStatus),
          action: SnackBarAction(
            label: 'Settings',
            onPressed: () => unawaited(openAppSettings()),
          ),
        ),
      );
    } finally {
      if (mounted) {
        setState(() => _incubatorWifiRequestInProgress = false);
      }
    }
  }

  Future<void> _selectRunMode({required bool demo}) async {
    if (demo) {
      if (_incubatorNetworkHeld) await _releaseIncubatorNetwork();
      await _prepareDemoMode();
    } else {
      if (!mounted) return;
      setState(() {
        _demoMode = false;
        _showModeSelect = false;
        _status = 'Actual mode ready';
      });
    }
    if (!mounted) return;
    final shouldShowOnboarding = await _shouldShowOnboarding(demoMode: demo);
    if (!mounted) return;
    if (!shouldShowOnboarding) {
      if (!demo) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) unawaited(_showNotificationPermissionDialog());
        });
      }
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_showOnboardingDialog(demoMode: demo));
    });
  }

  Future<bool> _shouldShowOnboarding({required bool demoMode}) async {
    final prefs = await SharedPreferences.getInstance();
    final key = demoMode
        ? _demoOnboardingCompleteKey
        : _actualOnboardingCompleteKey;
    return !(prefs.getBool(key) ?? false);
  }

  Future<void> _markOnboardingComplete({required bool demoMode}) async {
    final prefs = await SharedPreferences.getInstance();
    final key = demoMode
        ? _demoOnboardingCompleteKey
        : _actualOnboardingCompleteKey;
    await prefs.setBool(key, true);
  }

  Future<void> _prepareDemoMode() async {
    final now = DateTime.now();
    final demoEggs = List<EggData>.generate(
      _activeGridCellCount,
      (_) => EggData(),
    );
    _eggData = demoEggs.map((egg) => egg.copy()).toList();
    _recalculateCurrentCounts();

    final sampleSessions = List<EggSession>.generate(3, (i) {
      return EggSession(
        id: now.millisecondsSinceEpoch + i,
        timestamp: now.subtract(Duration(days: i, hours: i * 2)),
        fertileCount: 0,
        infertileCount: 0,
        temperature: 37.5 + (i * 0.1),
        humidity: 58 + i.toDouble(),
        waterLevel: 72 - i,
        waterLow: false,
        eggDay: 7 + i,
        p4EggCount: _activeGridCellCount,
        occupiedSlots: List<bool>.filled(_activeGridCellCount, true),
        slotDays: List<int?>.filled(_activeGridCellCount, 7 + i),
        eggData: demoEggs.map((egg) => egg.copy()).toList(),
        analyzedSlots: const [],
        usedAi: false,
        columnCount: _activeGridCols,
        rowCount: _activeGridRows,
        captureMs: 850,
        totalScanMs: 1400 + (i * 120),
      );
    });

    if (!mounted) return;
    setState(() {
      _demoMode = true;
      _showModeSelect = false;
      _isConnectedToCorrectSSID = true;
      _isWifiCorrect = true;
      _hasCheckedWifi = true;
      _s3Connected = true;
      _p4Connected = true;
      _ledsConnected = true;
      _mainConnected = true;
      _mainAgeMs = 1200;
      _mainBulbOn = true;
      _mainHumidifierOn = false;
      _subIncubatorConnected = true;
      _subIncubatorAgeMs = 1200;
      _subIncubatorWaterSource = 'remote';
      _subIncubatorBulbOn = true;
      _subIncubatorHumidifierOn = true;
      _subTemperature = 37.8;
      _subHumidity = 68;
      _subWaterLevel = 80;
      _subWaterLow = false;
      _ledActiveCount = 0;
      _ledRecentEggCount = _activeGridCellCount;
      _ledRecentCacheValid = true;
      _ledTestStatus = 'Demo LED controller ready';
      _selectedLedNumbers.clear();
      _isStreaming = false;
      _currentSsid = 'DEMO_MODE';
      _temperature = 37.6;
      _humidity = 59;
      _waterLow = false;
      _waterLevel = 72;
      _p4EggCount = _activeGridCellCount;
      _p4EggDay = 7;
      _p4SlotHasEgg = List<bool>.filled(_activeGridCellCount, true);
      _p4SlotDays = List<int?>.filled(_activeGridCellCount, 7);
      _p4SlotPlacedAt = List<DateTime?>.filled(
        _activeGridCellCount,
        now.subtract(const Duration(days: 7)),
      );
      _p4SlotPlacedAtConfirmed = List<bool>.filled(_activeGridCellCount, true);
      _lastSyncTime = now;
      _lastGridSyncStatus = 'Demo grid ready';
      _lastGridSyncTime = now;
      _lastGridSyncMs = 0;
      _lastCaptureMs = 850;
      _lastTotalScanMs = 1400;
      _sessions = [...sampleSessions, ..._sessions].take(50).toList();
      _status = 'Demo mode ready';
    });
  }

  // Lifecycle
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _channel.setMethodCallHandler(_handlePlatformChannelCall);
    _lineLengthStepController.text = '0.1';
    _adjustStepController.text = _adjustStep.toStringAsFixed(1);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _bootstrapApp();
    });
  }

  Future<void> _bootstrapApp() async {
    final startedAt = DateTime.now();

    await _loadLanguage();
    await _runStartupStep('Restoring saved sessions...', 0.28, _loadSessions);
    await _runStartupStep(
      'Applying grid calibration...',
      0.50,
      _loadCustomGrid,
    );
    await _runStartupStep('Checking WiFi permission...', 0.70, _checkWifiSsid);
    await _runStartupStep(
      'Preparing camera stream...',
      0.86,
      () => _loadStream(waitForConnectivity: false),
    );
    await _runStartupStep(
      'Checking reminder status...',
      0.96,
      _restoreNotificationReminders,
    );

    final elapsed = DateTime.now().difference(startedAt);
    const minimumSplashDuration = Duration(seconds: 5);
    if (elapsed < minimumSplashDuration) {
      await _animateStartupProgress(
        from: _startupProgress,
        to: 0.98,
        duration: minimumSplashDuration - elapsed,
        message: 'Finishing setup...',
      );
    }

    if (!mounted) return;
    setState(() {
      _startupProgress = 1.0;
      _startupMessage = 'Ready';
      _startupDetail = 'Candling capture and research history ready';
    });
    await Future.delayed(const Duration(milliseconds: 250));
    if (!mounted) return;
    setState(() {
      _isBooting = false;
    });
  }

  Future<void> _runStartupStep(
    String message,
    double progress,
    Future<void> Function() action,
  ) async {
    if (!mounted) return;
    setState(() {
      _startupMessage = message;
      _startupProgress = progress.clamp(0.0, 1.0);
      _startupDetail = _startupDetailFor(message);
    });

    try {
      await action();
    } catch (e) {
      debugPrint('Startup step "$message" failed: $e');
    }
  }

  Future<void> _restoreNotificationReminders() async {
    try {
      await _notifications.initialize();
      _notificationsReady = await _notificationsAllowed();
      if (_notificationsReady) {
        await _scheduleDailyCheckInNotifications();
      }
    } catch (e) {
      _notificationsReady = false;
      debugPrint('Notification restore error: $e');
    }
  }

  Future<void> _prepareNotifications() async {
    try {
      await _notifications.initialize();
      await _notifications.requestPermissions();
      await Future.delayed(const Duration(milliseconds: 300));
      final granted = await _notificationsAllowed();
      _notificationsReady = granted;
      if (granted) {
        await _scheduleDailyCheckInNotifications();
      }
    } catch (e) {
      _notificationsReady = false;
      debugPrint('Notification setup error: $e');
    }
  }

  void _showNotificationsEnabledMessage() {
    if (!mounted) return;
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Notifications are enabled.'),
        duration: Duration(seconds: 3),
      ),
    );
  }

  Future<bool> _notificationsAllowed() async {
    final pluginEnabled = await _notifications.areNotificationsEnabled();
    if (pluginEnabled) return true;

    final permission = await Permission.notification.status;
    return permission.isGranted;
  }

  Future<void> _showNotificationPermissionDialog() async {
    await _restoreNotificationReminders();
    if (_notificationsReady) {
      _showNotificationsEnabledMessage();
      return;
    }

    final prefs = await SharedPreferences.getInstance();
    final alreadyPrompted =
        prefs.getBool(_notificationPermissionPromptedKey) ?? false;
    if (alreadyPrompted) return;

    if (!mounted) return;
    Timer? autoCloseTimer;
    final shouldAsk = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        autoCloseTimer ??= Timer(const Duration(seconds: 10), () {
          final navigator = Navigator.of(dialogContext);
          if (navigator.canPop()) navigator.pop(false);
        });

        return AlertDialog(
          backgroundColor: _appCardColor(dialogContext),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(18),
          ),
          title: const Text('Allow egg-check reminders?'),
          content: Text(
            'The app can remind you twice a day to check the eggs inside the incubator.',
            style: TextStyle(
              color: _appMutedTextColor(dialogContext),
              height: 1.4,
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Not now'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('Allow'),
            ),
          ],
        );
      },
    ).whenComplete(() => autoCloseTimer?.cancel());

    await prefs.setBool(_notificationPermissionPromptedKey, true);
    if (shouldAsk != true) return;
    await _prepareNotifications();
    if (!mounted) return;
    if (_notificationsReady) {
      _showNotificationsEnabledMessage();
      return;
    }
    final allowedAfterRequest = await _notificationsAllowed();
    if (!mounted) return;
    if (allowedAfterRequest) {
      _notificationsReady = true;
      await _scheduleDailyCheckInNotifications();
      _showNotificationsEnabledMessage();
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: const Text(
          'Notifications are still off. Enable them in app settings.',
        ),
        duration: const Duration(seconds: 10),
        action: SnackBarAction(label: 'Settings', onPressed: openAppSettings),
      ),
    );
  }

  Future<void> _scheduleDailyCheckInNotifications() async {
    if (!_notificationsReady) return;
    try {
      await _notifications.scheduleDailyCheckInReminder(
        id: _morningCheckInNotificationId,
        hour: 7,
        minute: 0,
        title: 'Morning egg check',
        body:
            'Want to check the eggs inside the incubator today? Open the app when you are near it.',
      );
      await _notifications.scheduleDailyCheckInReminder(
        id: _eveningCheckInNotificationId,
        hour: 18,
        minute: 0,
        title: 'Evening incubator check',
        body:
            'Quick egg check before the day ends? Connect to AI_CANDLING for today\'s status.',
      );
    } catch (e) {
      debugPrint('Daily notification schedule error: $e');
    }
  }

  Future<void> _animateStartupProgress({
    required double from,
    required double to,
    required Duration duration,
    required String message,
  }) async {
    const frame = Duration(milliseconds: 80);
    final steps = (duration.inMilliseconds / frame.inMilliseconds).ceil();
    if (steps <= 0) return;

    for (int i = 1; i <= steps; i++) {
      if (!mounted) return;
      final t = i / steps;
      final eased = Curves.easeOutCubic.transform(t);
      setState(() {
        _startupMessage = message;
        _startupDetail = _startupDetailFor(message);
        _startupProgress = from + (to - from) * eased;
      });
      await Future.delayed(frame);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _incubatorNetworkReleaseTimer?.cancel();
    if (_incubatorNetworkHeld) {
      unawaited(_channel.invokeMethod('releaseIncubatorHub'));
    }
    _channel.setMethodCallHandler(null);
    _sensorTimer?.cancel();
    _countdownTimer?.cancel();
    _p4PollTimer?.cancel();
    _referenceTrashOpacityTimer?.cancel();
    _datasetAutoCaptureTimer?.cancel();
    _datasetCountdownTimer?.cancel();
    _intakeDatasetAutoCaptureTimer?.cancel();
    _intakeDatasetCountdownTimer?.cancel();
    _fertilityDatasetAutoCaptureTimer?.cancel();
    _fertilityDatasetCountdownTimer?.cancel();
    _fertilityClassifier.close();
    _capturedImage = null;
    _gridCalibrationImage = null;
    _searchController.dispose();
    _lineLengthStepController.dispose();
    _adjustStepController.dispose();
    super.dispose();
  }

  Future<dynamic> _handlePlatformChannelCall(MethodCall call) async {
    if (call.method != 'incubatorNetworkState') return null;
    final raw = call.arguments;
    if (raw is! Map) return null;
    final state = Map<String, dynamic>.from(raw);
    final networkStatus = state['status']?.toString() ?? 'disconnected';
    final connected = networkStatus == 'connected' && state['bound'] == true;
    final concurrent = state['concurrentInternetSupported'] == true;
    if (!mounted) return null;

    setState(() {
      _incubatorNetworkHeld = connected;
      _incubatorConcurrentInternetSupported = concurrent;
      _incubatorNetworkStatus = connected
          ? concurrent
                ? 'AI_CANDLING held | phone internet remains available'
                : 'AI_CANDLING held | other apps may use mobile data'
          : networkStatus == 'unavailable'
          ? 'AI_CANDLING not found'
          : 'AI_CANDLING local link disconnected';
      if (!connected) {
        _s3Connected = false;
        _status = _incubatorNetworkStatus;
      }
    });

    if (connected && !_isBooting) {
      unawaited(_loadStream(waitForConnectivity: true));
    }
    return null;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _incubatorNetworkReleaseTimer?.cancel();
      _incubatorNetworkReleaseTimer = null;
      if (!_isBooting) unawaited(_refreshApp(silent: true));
      return;
    }

    if ((state == AppLifecycleState.paused ||
            state == AppLifecycleState.hidden) &&
        _incubatorNetworkHeld) {
      _incubatorNetworkReleaseTimer?.cancel();
      _incubatorNetworkReleaseTimer = Timer(const Duration(seconds: 10), () {
        unawaited(_releaseIncubatorNetwork());
      });
    } else if (state == AppLifecycleState.detached && _incubatorNetworkHeld) {
      unawaited(_releaseIncubatorNetwork(updateUi: false));
    }
  }

  void _syncEggDataToGrid() {
    final targetCount = _activeGridCellCount;
    if (targetCount < 1 || _eggData.length == targetCount) {
      _syncSlotMetadataLength(targetCount);
      _recalculateCurrentCounts();
      return;
    }

    if (_eggData.length > targetCount) {
      _eggData = _eggData.take(targetCount).toList();
    } else {
      _eggData = [
        ..._eggData,
        ...List.generate(targetCount - _eggData.length, (_) => EggData()),
      ];
    }
    _syncSlotMetadataLength(targetCount);
    _recalculateCurrentCounts();
  }

  void _syncSlotMetadataLength(int targetCount) {
    if (_p4SlotHasEgg.length != targetCount) {
      _p4SlotHasEgg = List<bool>.generate(
        targetCount,
        (index) => index < _p4SlotHasEgg.length && _p4SlotHasEgg[index],
      );
    }
    if (_p4SlotDays.length != targetCount) {
      _p4SlotDays = List<int?>.generate(
        targetCount,
        (index) => index < _p4SlotDays.length ? _p4SlotDays[index] : null,
      );
    }
    if (_p4SlotPlacedAt.length != targetCount) {
      _p4SlotPlacedAt = List<DateTime?>.generate(
        targetCount,
        (index) =>
            index < _p4SlotPlacedAt.length ? _p4SlotPlacedAt[index] : null,
      );
    }
    if (_p4SlotPlacedAtConfirmed.length != targetCount) {
      _p4SlotPlacedAtConfirmed = List<bool>.generate(
        targetCount,
        (index) =>
            index < _p4SlotPlacedAtConfirmed.length &&
            _p4SlotPlacedAtConfirmed[index],
      );
    }
    if (_p4SlotFertilityVerdict.length != targetCount) {
      _p4SlotFertilityVerdict = List<String>.generate(
        targetCount,
        (index) => index < _p4SlotFertilityVerdict.length
            ? _p4SlotFertilityVerdict[index]
            : 'none',
      );
    }
  }

  void _recalculateCurrentCounts() {
    _fertileCount = _eggData
        .where((egg) => egg.status == EggStatus.fertile)
        .length;
    _infertileCount = _eggData
        .where((egg) => egg.status == EggStatus.infertile)
        .length;
  }

  Future<void> _placeEggInSlot(int index, {DateTime? placedAt}) async {
    if (index < 0 || index >= _activeGridCellCount) return;
    final placed = placedAt ?? DateTime.now();
    setState(() {
      _syncSlotMetadataLength(_activeGridCellCount);
      _p4SlotHasEgg[index] = true;
      _p4SlotPlacedAt[index] = placed;
      _p4SlotPlacedAtConfirmed[index] = true;
      _p4SlotDays[index] = _daysSincePlaced(placed);
      _p4SlotFertilityVerdict[index] = 'none';
      _p4EggCount = _p4SlotHasEgg.where((hasEgg) => hasEgg).length;
      _p4EggDay = _p4SlotDays.whereType<int>().fold<int>(
        0,
        (maxDay, day) => day > maxDay ? day : maxDay,
      );
      _slotMetadataDirty = true;
      if (index < _eggData.length) {
        _eggData[index].status = EggStatus.unknown;
        _eggData[index].confidence = 0.0;
      }
      _recalculateCurrentCounts();
    });
    _hasStableP4Grid = true;
    _pendingP4RemovalGrid = null;
    _pendingP4RemovalScanEpoch = null;
    _p4GridUsingPreservedSnapshot = false;
    _p4GridDataStatus = 'Tray updated manually';
    unawaited(_saveStableP4GridSnapshot());
    unawaited(_saveSlotPlacedAt());
    await _syncSlotMetadataToP4(showSnack: true);
  }

  Future<void> _clearEggSlot(int index) async {
    if (index < 0 || index >= _activeGridCellCount) return;
    setState(() {
      _syncSlotMetadataLength(_activeGridCellCount);
      _p4SlotHasEgg[index] = false;
      _p4SlotPlacedAt[index] = null;
      _p4SlotPlacedAtConfirmed[index] = false;
      _p4SlotDays[index] = null;
      _p4SlotFertilityVerdict[index] = 'none';
      if (index < _eggData.length) {
        _eggData[index] = EggData();
      }
      _p4EggCount = _p4SlotHasEgg.where((hasEgg) => hasEgg).length;
      _p4EggDay = _p4SlotDays.whereType<int>().fold<int>(
        0,
        (maxDay, day) => day > maxDay ? day : maxDay,
      );
      _slotMetadataDirty = true;
      _recalculateCurrentCounts();
    });
    _hasStableP4Grid = true;
    _pendingP4RemovalGrid = null;
    _pendingP4RemovalScanEpoch = null;
    _p4GridUsingPreservedSnapshot = false;
    _p4GridDataStatus = 'Tray updated manually';
    unawaited(_saveStableP4GridSnapshot());
    unawaited(_saveSlotPlacedAt());
    await _syncSlotMetadataToP4(showSnack: true);
  }

  Future<void> _pickSlotPlacedAt(int index) async {
    final current = _slotPlacedAt(index) ?? DateTime.now();
    final date = await showDatePicker(
      context: context,
      initialDate: current,
      firstDate: DateTime(2020),
      lastDate: DateTime.now().add(const Duration(days: 1)),
    );
    if (date == null || !mounted) return;

    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(current),
    );
    if (time == null || !mounted) return;

    await _placeEggInSlot(
      index,
      placedAt: DateTime(
        date.year,
        date.month,
        date.day,
        time.hour,
        time.minute,
      ),
    );
  }

  // WiFi / Stream
  Future<void> _loadStream({bool waitForConnectivity = true}) async {
    setState(() {
      _status = 'Checking WiFi...';
    });

    await _checkWifiSsid();
    if (!_isConnectedToCorrectSSID) {
      final cameraReachable = await _canReachCameraStream();
      if (cameraReachable && mounted) {
        setState(() {
          _currentSsid = _currentSsid.isEmpty ? 'AI_CANDLING' : _currentSsid;
          _isConnectedToCorrectSSID = true;
          _isWifiCorrect = true;
          _hasCheckedWifi = true;
          _s3Connected = true;
        });
      }
    }

    if (!_isConnectedToCorrectSSID) {
      if (!mounted) return;
      setState(() {
        _isStreaming = false;
        _s3Connected = false;
        _p4Connected = false;
        _ledsConnected = false;
        _mainConnected = false;
        _mainAgeMs = null;
        _mainBulbOn = null;
        _mainHumidifierOn = null;
        _subIncubatorConnected = false;
        _subIncubatorAgeMs = null;
        _subIncubatorWaterSource = null;
        _subIncubatorBulbOn = null;
        _subIncubatorHumidifierOn = null;
        _subTemperature = null;
        _subHumidity = null;
        _subWaterLevel = null;
        _subWaterLow = null;
        _ledActiveCount = null;
        _ledRecentEggCount = null;
        _ledRecentCacheValid = false;
        _temperature = null;
        _humidity = null;
        _waterLow = null;
        _waterLevel = null;
        _status = 'Connect to AI_CANDLING';
      });
      return;
    }

    final connectivityCheck = _checkESP32Connectivity();
    if (waitForConnectivity) {
      await connectivityCheck;
      await _fetchSensorData();
    } else {
      unawaited(connectivityCheck);
    }

    if (!mounted) return;
    _sensorTimer?.cancel();
    _p4PollTimer?.cancel();
    setState(() {
      _isStreaming = true;
      _streamFrameReceived = false;
      _streamKey++;
      _status = 'Starting S3 stream...';
    });
    _startSensorPolling();
    _startPeriodicP4Sync();
  }

  String _startupDetailFor(String message) {
    if (message.contains('sessions')) {
      return 'Loading saved candling records from this phone';
    }
    if (message.contains('grid')) {
      return 'Applying tray calibration for accurate slot mapping';
    }
    if (message.contains('WiFi')) {
      return 'Checking access to AI_CANDLING';
    }
    if (message.contains('camera')) {
      return 'Preparing ESP32 camera stream';
    }
    if (message.contains('reminder')) {
      return 'Keeping daily egg-check reminders in sync';
    }
    if (message.contains('Finishing')) {
      return 'Finalizing camera capture and research logging';
    }
    return 'Preparing local setup';
  }

  Future<bool> _canReachCameraStream() async {
    final client = http.Client();
    try {
      final response = await client
          .post(
            _s3Uri('/sensor'),
            headers: {'Content-Type': 'application/json'},
          )
          .timeout(const Duration(seconds: 3));
      return response.statusCode >= 200 && response.statusCode < 400;
    } catch (e) {
      debugPrint('Camera bridge reachability check failed: $e');
      return false;
    } finally {
      client.close();
    }
  }

  Future<void> _checkWifiSsid() async {
    try {
      if (Platform.isAndroid) {
        final held = await _channel.invokeMethod<Map<dynamic, dynamic>>(
          'getIncubatorHubStatus',
        );
        if (held?['status'] == 'connected' && held?['bound'] == true) {
          setState(() {
            _currentSsid = 'AI_CANDLING';
            _isConnectedToCorrectSSID = true;
            _isWifiCorrect = true;
            _hasCheckedWifi = true;
            _incubatorNetworkHeld = true;
            _incubatorConcurrentInternetSupported =
                held?['concurrentInternetSupported'] == true;
          });
          return;
        }
      }

      if (!await _ensureIncubatorWifiPermission()) {
        setState(() {
          _isWifiCorrect = false;
          _hasCheckedWifi = true;
        });
        return;
      }

      final ssid = await _networkInfo.getWifiName();
      setState(() {
        _currentSsid = ssid?.replaceAll('"', '').trim() ?? '';
        _isConnectedToCorrectSSID = _currentSsid == 'AI_CANDLING';
        _isWifiCorrect = _isConnectedToCorrectSSID;
        _hasCheckedWifi = true;
      });
    } catch (e) {
      debugPrint('WiFi SSID check error: $e');
      setState(() {
        _isWifiCorrect = false;
        _hasCheckedWifi = true;
      });
    }
  }

  String _deviceConnectivityStatus({
    required bool s3Ok,
    required bool p4Ok,
    required bool ledsOk,
    required bool subOk,
  }) {
    if (s3Ok && p4Ok && ledsOk && subOk) {
      return 'Connected to S3, P4, LEDs & Sub-Incubator';
    }
    if (!s3Ok) return 'S3 camera bridge offline';

    final offline = <String>[
      if (!p4Ok) 'P4',
      if (!ledsOk) 'LEDs',
      if (!subOk) 'Sub-Incubator',
    ];
    if (offline.isEmpty) return 'S3 connected';
    return 'S3 connected, ${offline.join(', ')} offline';
  }

  void _applyLedControllerStatus(LedControllerStatus status) {
    _ledsConnected = true;
    _ledActiveCount = status.activeLedCount;
    _ledRecentEggCount = status.recentEggCount;
    _ledRecentCacheValid = status.recentCacheValid;
    _ledTestStatus = status.status.replaceAll('_', ' ');

    final activeLeds = status.activeLeds
        .where((led) => led >= 1 && led <= 56)
        .toSet();
    if (activeLeds.isNotEmpty || status.activeLedCount == 0) {
      _selectedLedNumbers
        ..clear()
        ..addAll(activeLeds);
    }
  }

  // ESP32 Connectivity & Sensor polling
  Future<void> _checkESP32Connectivity() async {
    bool s3Ok = false;
    bool p4Ok = false;
    bool ledsOk = false;
    bool subOk = false;
    int? subAgeMs;
    String? waterSource;
    bool? subBulbOn;
    bool? subHumidifierOn;
    LedControllerStatus? ledStatus;

    try {
      final s3Test = await http
          .post(
            _s3Uri('/sensor'),
            headers: {'Content-Type': 'application/json'},
          )
          .timeout(const Duration(seconds: 3));
      s3Ok = s3Test.statusCode == 200;
      if (s3Ok) {
        final data = jsonDecode(s3Test.body) as Map<String, dynamic>;
        subOk =
            data['subConnected'] as bool? ??
            data['subIncubatorConnected'] as bool? ??
            false;
        subAgeMs =
            (data['subAgeMs'] as num?)?.toInt() ??
            (data['subIncubatorAgeMs'] as num?)?.toInt();
        waterSource = data['waterSource']?.toString();
        subBulbOn =
            data['subBulb'] as bool? ?? data['subIncubatorBulb'] as bool?;
        subHumidifierOn =
            data['subHumidifier'] as bool? ??
            data['subIncubatorHumidifier'] as bool?;
      }
    } catch (e) {
      debugPrint('S3 connectivity check error: $e');
    }

    try {
      final p4Test = await _getP4(
        '/get_slots',
        timeout: const Duration(seconds: 3),
      );
      p4Ok = p4Test.statusCode == 200;
    } catch (e) {
      debugPrint('P4 connectivity check error: $e');
    }

    try {
      ledStatus = await _esp32.getLedControllerStatus(
        timeout: const Duration(seconds: 3),
      );
      ledsOk = true;
    } catch (e) {
      debugPrint('LED controller connectivity check error: $e');
    }

    if (mounted) {
      setState(() {
        _s3Connected = s3Ok;
        _p4Connected = p4Ok;
        _ledsConnected = ledsOk;
        _subIncubatorConnected = subOk;
        _subIncubatorAgeMs = subAgeMs;
        _subIncubatorWaterSource = waterSource;
        _subIncubatorBulbOn = subBulbOn;
        _subIncubatorHumidifierOn = subHumidifierOn;
        if (ledStatus != null) {
          _applyLedControllerStatus(ledStatus);
        } else {
          _ledActiveCount = null;
          _ledRecentEggCount = null;
          _ledRecentCacheValid = false;
          _ledTestStatus = 'LED controller offline';
        }
        _status = _deviceConnectivityStatus(
          s3Ok: s3Ok,
          p4Ok: p4Ok,
          ledsOk: ledsOk,
          subOk: subOk,
        );
      });
    }

    if (p4Ok) {
      await _syncPhoneTimeToP4(force: true);
      await _syncCustomGridFromP4();
      await _syncEggGridFromP4();
    }
  }

  Future<GridConfigData> _callP4GridConfig(
    Future<GridConfigData> Function({bool viaS3}) action,
  ) async {
    return action(viaS3: true);
  }

  bool _isValidGridConfig(GridConfigData config) {
    return _isValidBoundarySet(
          config.colBoundsCm,
          cellCount: config.cols,
          maxValue: _trayWidthCm,
        ) &&
        _isValidBoundarySet(
          config.rowBoundsCm,
          cellCount: config.rows,
          maxValue: _trayHeightCm,
        );
  }

  bool _isValidBoundarySet(
    List<double> boundaries, {
    required int cellCount,
    required double maxValue,
  }) {
    if (cellCount < 2 || cellCount > 50) return false;
    if (boundaries.length != cellCount + 1) return false;
    if (boundaries.any((value) => !value.isFinite)) return false;
    if (boundaries.first < 0 || boundaries.last > maxValue + 0.001) {
      return false;
    }

    for (var i = 1; i < boundaries.length; i++) {
      if (boundaries[i] <= boundaries[i - 1]) return false;
    }
    return true;
  }

  Future<void> _syncCustomGridFromP4() async {
    if (_currentIndex == 2) return;
    final watch = Stopwatch()..start();
    try {
      final config = await _callP4GridConfig(_esp32.getGridConfig);
      if (!_isValidGridConfig(config) || !mounted) return;
      watch.stop();

      setState(() {
        _customColBoundaries = List<double>.from(config.colBoundsCm);
        _customRowBoundaries = List<double>.from(config.rowBoundsCm);
        _gridSaved = true;
        _lastGridSyncStatus = 'Read from P4';
        _lastGridSyncTime = DateTime.now();
        _lastGridSyncMs = watch.elapsedMilliseconds;
        _syncEggDataToGrid();
      });
      await _saveCustomGridPrefs();
    } catch (e) {
      debugPrint('Sync grid config from P4 skipped: $e');
    }
  }

  Future<bool> _sendCustomGridToP4() async {
    final watch = Stopwatch()..start();
    try {
      final config = await _callP4GridConfig(
        ({bool viaS3 = true}) => _esp32.setGridConfig(
          cols: _activeGridCols,
          rows: _activeGridRows,
          colBoundsCm: _scanColBoundaries,
          rowBoundsCm: _scanRowBoundaries,
          viaS3: viaS3,
        ),
      );
      watch.stop();
      final ok = _isValidGridConfig(config);
      if (mounted) {
        setState(() {
          _lastGridSyncStatus = ok ? 'Saved to P4' : 'P4 returned invalid grid';
          _lastGridSyncTime = DateTime.now();
          _lastGridSyncMs = watch.elapsedMilliseconds;
        });
      }
      return ok;
    } catch (e) {
      debugPrint('Send custom grid to P4 failed: $e');
      if (mounted) {
        setState(() {
          _lastGridSyncStatus = 'Saved locally only';
          _lastGridSyncTime = DateTime.now();
          _lastGridSyncMs = null;
        });
      }
      return false;
    }
  }

  Future<bool> _resetP4GridConfig() async {
    final watch = Stopwatch()..start();
    try {
      await _callP4GridConfig(_esp32.resetGridConfig);
      watch.stop();
      if (mounted) {
        setState(() {
          _lastGridSyncStatus = 'Reset on P4';
          _lastGridSyncTime = DateTime.now();
          _lastGridSyncMs = watch.elapsedMilliseconds;
        });
      }
      return true;
    } catch (e) {
      debugPrint('Reset P4 grid config failed: $e');
      if (mounted) {
        setState(() {
          _lastGridSyncStatus = 'Reset locally only';
          _lastGridSyncTime = DateTime.now();
          _lastGridSyncMs = null;
        });
      }
      return false;
    }
  }

  Future<void> _fetchSensorData() async {
    if (!_isConnectedToCorrectSSID ||
        !_hasCheckedWifi ||
        !_s3Connected ||
        _sensorFetchInProgress) {
      return;
    }

    _sensorFetchInProgress = true;
    final client = http.Client();
    try {
      final response = await client
          .post(
            _s3Uri('/sensor'),
            headers: {'Content-Type': 'application/json'},
          )
          .timeout(const Duration(seconds: 10));
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;

        // --- MAIN incubator (P4 temp/hum/bulb + S3 water/humidifier) ---
        final received = data['received'] as bool? ?? false;
        final humValid = data['humValid'] as bool?;
        final waterLow = data['waterLow'] as bool?;
        final waterLevel = (data['waterLevel'] as num?)?.toInt();
        final mainConnected =
            data['mainConnected'] as bool? ??
            data['sensorFresh'] as bool? ??
            received;
        final mainAgeMs =
            (data['mainAgeMs'] as num?)?.toInt() ??
            (data['sensorAgeMs'] as num?)?.toInt();
        final mainBulbOn = data['mainBulb'] as bool?;
        final mainHumidifierOn = data['mainHumidifier'] as bool?;
        final waterSource = data['waterSource']?.toString();
        final temperature = received
            ? (data['temp'] as num?)?.toDouble()
            : null;
        final humidity = received && humValid != false
            ? (data['hum'] as num?)?.toDouble()
            : null;

        // --- SUB incubator (lockdown relay node via /subsensordata) ---
        final subConnected =
            data['subConnected'] as bool? ??
            data['subIncubatorConnected'] as bool? ??
            false;
        final subAgeMs =
            (data['subAgeMs'] as num?)?.toInt() ??
            (data['subIncubatorAgeMs'] as num?)?.toInt();
        final subBulbOn =
            data['subBulb'] as bool? ?? data['subIncubatorBulb'] as bool?;
        final subHumidifierOn =
            data['subHumidifier'] as bool? ??
            data['subIncubatorHumidifier'] as bool?;
        final subTempValid = data['subTempValid'] as bool?;
        final subHumValid = data['subHumValid'] as bool?;
        final subTemperature = subConnected && subTempValid != false
            ? (data['subTemp'] as num?)?.toDouble()
            : null;
        final subHumidity = subConnected && subHumValid != false
            ? (data['subHum'] as num?)?.toDouble()
            : null;
        final subWaterLevel = (data['subWaterLevel'] as num?)?.toInt();
        final subWaterLow = data['subWaterLow'] as bool?;

        if (!mounted) return;
        setState(() {
          _waterLow = waterLow;
          _waterLevel = waterLevel;
          _mainConnected = mainConnected;
          _mainAgeMs = mainAgeMs;
          _mainBulbOn = mainBulbOn;
          _mainHumidifierOn = mainHumidifierOn;
          _subIncubatorWaterSource = waterSource;
          if (received) {
            _temperature = temperature;
            _humidity = humidity;
          } else {
            _temperature = null;
            _humidity = null;
          }
          _subIncubatorConnected = subConnected;
          _subIncubatorAgeMs = subAgeMs;
          _subIncubatorBulbOn = subBulbOn;
          _subIncubatorHumidifierOn = subHumidifierOn;
          _subTemperature = subTemperature;
          _subHumidity = subHumidity;
          _subWaterLevel = subWaterLevel;
          _subWaterLow = subWaterLow;
        });
        unawaited(
          _recordSensorSnapshot(
            temperature: temperature,
            humidity: humidity,
            waterLevel: waterLevel,
            waterLow: waterLow,
            subTemperature: subTemperature,
            subHumidity: subHumidity,
          ),
        );
      }
    } catch (e) {
      debugPrint('Sensor fetch error: $e');
      if (mounted) {
        setState(() => _subIncubatorConnected = false);
      }
    } finally {
      client.close();
      _sensorFetchInProgress = false;
    }
  }

  bool _shouldRecordSensorSnapshot(SensorSnapshot next) {
    if (_sensorHistory.isEmpty || _lastSensorHistoryAt == null) return true;
    final previous = _sensorHistory.last;
    if (next.timestamp.difference(_lastSensorHistoryAt!) >=
        _sensorHistoryInterval) {
      return true;
    }
    if (previous.waterLow != next.waterLow) return true;
    if (previous.waterLevel != null &&
        next.waterLevel != null &&
        (previous.waterLevel! - next.waterLevel!).abs() >= 10) {
      return true;
    }
    if (previous.temperature != null &&
        next.temperature != null &&
        (previous.temperature! - next.temperature!).abs() >= 0.3) {
      return true;
    }
    if (previous.humidity != null &&
        next.humidity != null &&
        (previous.humidity! - next.humidity!).abs() >= 3.0) {
      return true;
    }
    if (previous.subTemperature != null &&
        next.subTemperature != null &&
        (previous.subTemperature! - next.subTemperature!).abs() >= 0.3) {
      return true;
    }
    if (previous.subHumidity != null &&
        next.subHumidity != null &&
        (previous.subHumidity! - next.subHumidity!).abs() >= 3.0) {
      return true;
    }
    // First time we start seeing sub data, capture it.
    if (previous.subTemperature == null && next.subTemperature != null) {
      return true;
    }
    if (previous.subHumidity == null && next.subHumidity != null) {
      return true;
    }
    return false;
  }

  Future<void> _recordSensorSnapshot({
    required double? temperature,
    required double? humidity,
    required int? waterLevel,
    required bool? waterLow,
    double? subTemperature,
    double? subHumidity,
  }) async {
    if (temperature == null &&
        humidity == null &&
        waterLevel == null &&
        subTemperature == null &&
        subHumidity == null) {
      return;
    }

    final snapshot = SensorSnapshot(
      timestamp: DateTime.now(),
      temperature: temperature,
      humidity: humidity,
      waterLevel: waterLevel,
      waterLow: waterLow,
      subTemperature: subTemperature,
      subHumidity: subHumidity,
    );
    if (!_shouldRecordSensorSnapshot(snapshot)) return;

    _sensorHistory.add(snapshot);
    _lastSensorHistoryAt = snapshot.timestamp;
    _trimSensorHistory();
    await _saveSensorHistory();
  }

  void _trimSensorHistory() {
    final cutoff = DateTime.now().subtract(const Duration(days: 30));
    _sensorHistory = _sensorHistory
        .where((sample) => !sample.timestamp.isBefore(cutoff))
        .toList();
    if (_sensorHistory.length > _maxSensorHistorySamples) {
      _sensorHistory = _sensorHistory.sublist(
        _sensorHistory.length - _maxSensorHistorySamples,
      );
    }
  }

  Future<void> _saveSensorHistory() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      'sensor_history',
      jsonEncode(_sensorHistory.map((sample) => sample.toJson()).toList()),
    );
  }

  List<SensorSnapshot> _sensorHistoryInRange(DateTime start, DateTime end) {
    return _sensorHistory
        .where(
          (sample) =>
              !sample.timestamp.isBefore(start) &&
              sample.timestamp.isBefore(end),
        )
        .toList()
      ..sort((a, b) => a.timestamp.compareTo(b.timestamp));
  }

  void _startSensorPolling() {
    _sensorTimer?.cancel();
    _fetchSensorData();
    _sensorTimer = Timer.periodic(
      const Duration(seconds: 2),
      (_) => _fetchSensorData(),
    );
  }

  void _startPeriodicP4Sync() {
    _p4PollTimer?.cancel();
    _p4PollTimer = Timer.periodic(const Duration(seconds: 10), (_) async {
      final cameraBusy =
          _isStreaming ||
          _isCandling ||
          _isCapturingCalibration ||
          _isDatasetCapturing ||
          _isDatasetAutoCapturing ||
          _isIntakeDatasetCapturing ||
          _isFertilityDatasetCapturing ||
          _isFertilityDatasetAutoCapturing;
      if (_p4Connected && mounted && !cameraBusy) {
        await _syncPhoneTimeToP4(force: _p4TimeSyncRequired);
        if (_slotMetadataDirty) {
          await _syncSlotMetadataToP4();
        } else {
          await _syncEggGridFromP4();
          await _syncSlotMetadataToP4();
        }
      }
    });
  }

  Future<void> _syncSlotMetadataToP4({bool showSnack = false}) async {
    if (!_p4Connected) return;
    _syncSlotMetadataLength(_activeGridCellCount);

    final now = DateTime.now();
    for (var i = 0; i < _activeGridCellCount; i++) {
      if (_p4SlotHasEgg[i] && _p4SlotPlacedAt[i] == null) {
        _p4SlotPlacedAt[i] = now;
      }
    }

    final eggs = List<bool>.generate(
      _activeGridCellCount,
      (index) => index < _p4SlotHasEgg.length && _p4SlotHasEgg[index],
    );
    final placedAt = List<dynamic>.generate(_activeGridCellCount, (index) {
      if (!eggs[index]) return null;
      final placed = index < _p4SlotPlacedAt.length
          ? _p4SlotPlacedAt[index]
          : null;
      return placed == null ? null : placed.millisecondsSinceEpoch ~/ 1000;
    });
    final days = List<int>.generate(
      _activeGridCellCount,
      (index) => eggs[index] ? (_slotDay(index) ?? 0) : 0,
    );

    try {
      final response = await _postP4('/set_slots', {
        'eggs': eggs,
        'placed_at': placedAt,
        'days': days,
        'now_epoch': now.millisecondsSinceEpoch ~/ 1000,
        'now_iso': now.toIso8601String(),
      }, timeout: const Duration(seconds: 6));
      if (response.statusCode != 200) {
        debugPrint('P4 set_slots returned ${response.statusCode}');
        return;
      }

      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final metadata = data['metadata'] is Map
          ? Map<String, dynamic>.from(data['metadata'] as Map)
          : const <String, dynamic>{};
      final syncedEggs = _extractBoolList(data['eggs'], _activeGridCellCount);
      final syncedCount = syncedEggs.where((hasEgg) => hasEgg).length;
      final reportedCount = (data['count'] as num?)?.toInt();
      if (reportedCount != null && reportedCount != syncedCount) {
        throw FormatException(
          'P4 count $reportedCount does not match $syncedCount occupied slots.',
        );
      }
      final syncedDay = _extractP4EggDay(data, metadata);
      final syncedDays = _extractSlotDays(
        data,
        metadata,
        _activeGridCellCount,
        syncedDay,
      );
      final syncedPlaced = _extractSlotPlacedAt(
        data,
        metadata,
        _activeGridCellCount,
      );
      final timeTrusted =
          _extractP4Bool(data, metadata, const ['time_trusted']) ?? true;
      final timeSyncRequired =
          _extractP4Bool(data, metadata, const ['time_sync_required']) ??
          !timeTrusted;
      final lastPhoneSync = _extractP4EpochDateTime(data, metadata, const [
        'last_phone_sync_epoch',
        'lastPhoneSyncEpoch',
      ]);

      // /set_slots acknowledges metadata; it is not a new camera scan. Never
      // let that response replace the last completed P4 tray snapshot.
      final effectiveEggs = List<bool>.from(_p4SlotHasEgg);
      final mergedPlaced = _mergeAuthoritativePlacedAt(
        effectiveEggs,
        syncedPlaced,
      );
      final mergedPlacedConfirmed = _mergeAuthoritativePlacedAtConfirmation(
        effectiveEggs,
        mergedPlaced,
      );
      final mergedDays = _daysFromPlacedAt(mergedPlaced, syncedDays);
      if (mounted) {
        setState(() {
          _applyAutomaticFertilityVerdicts(
            effectiveEggs,
            _p4SlotFertilityVerdict,
          );
          _p4SlotHasEgg = effectiveEggs;
          _p4EggCount = effectiveEggs.where((hasEgg) => hasEgg).length;
          _p4EggDay = syncedDay;
          _p4SlotDays = mergedDays;
          _p4SlotPlacedAt = mergedPlaced;
          _p4SlotPlacedAtConfirmed = mergedPlacedConfirmed;
          _p4TimeTrusted = timeTrusted;
          _p4TimeSyncRequired = timeSyncRequired;
          _p4LastPhoneSyncAt = lastPhoneSync ?? _p4LastPhoneSyncAt;
          _slotMetadataDirty = false;
          _lastSyncTime = DateTime.now();
        });
        unawaited(_saveSlotPlacedAt());
        if (showSnack) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Slot metadata synced to P4.'),
              duration: Duration(seconds: 2),
            ),
          );
        }
      }
    } catch (e) {
      debugPrint('P4 set_slots sync error: $e');
    }
  }

  Future<bool> _refreshEggGridFromP4() async {
    if (!_p4Connected) return false;
    try {
      final response = await _getP4('/get_slots');

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        final eggs = _extractBoolList(data['eggs'], _activeGridCellCount);
        final occupiedCount = eggs.where((hasEgg) => hasEgg).length;
        final reportedCount = (data['count'] as num?)?.toInt();
        if (reportedCount != null && reportedCount != occupiedCount) {
          throw FormatException(
            'P4 count $reportedCount does not match $occupiedCount occupied slots.',
          );
        }
        final metadata = data['metadata'] is Map
            ? Map<String, dynamic>.from(data['metadata'] as Map)
            : const <String, dynamic>{};
        final day = _extractP4EggDay(data, metadata);
        final slotDays = _extractSlotDays(data, metadata, eggs.length, day);
        final placedAt = _extractSlotPlacedAt(data, metadata, eggs.length);
        Set<int> oneBasedSlotSet(dynamic raw) {
          final values = raw is List ? raw : const [];
          return values
              .whereType<num>()
              .map((value) => value.toInt() - 1)
              .where((index) => index >= 0 && index < eggs.length)
              .toSet();
        }

        final rootAbnormal = oneBasedSlotSet(data['abnormal_slots']);
        final rootInfertile = oneBasedSlotSet(
          data['confirmed_infertile_slots'],
        );
        final rootTransfer = oneBasedSlotSet(data['transfer_ready_slots']);
        final intakeVerdicts = List<String>.filled(eggs.length, 'none');
        final fertilityVerdicts = List<String>.filled(eggs.length, 'none');
        final rootFertilityPayload = data['fertility_verdicts'] is List
            ? data['fertility_verdicts'] as List
            : const [];
        final abnormalSlots = List<bool>.filled(eggs.length, false);
        final confirmedInfertileSlots = List<bool>.filled(eggs.length, false);
        final transferReadySlots = List<bool>.filled(eggs.length, false);
        final slotPayload = data['slots'] is List
            ? data['slots'] as List
            : const [];
        for (var index = 0; index < eggs.length; index++) {
          final slot = index < slotPayload.length && slotPayload[index] is Map
              ? Map<String, dynamic>.from(slotPayload[index] as Map)
              : const <String, dynamic>{};
          final verdict = slot['intake_verdict']?.toString().toLowerCase();
          if (const {
            'normal',
            'abnormal',
            'pending',
            'none',
          }.contains(verdict)) {
            intakeVerdicts[index] = verdict!;
          }
          final fertilityVerdict =
              (slot['fertility_verdict'] ??
                      (index < rootFertilityPayload.length
                          ? rootFertilityPayload[index]
                          : null))
                  ?.toString()
                  .toLowerCase();
          if (const {
            'fertile',
            'infertile',
            'pending',
            'none',
          }.contains(fertilityVerdict)) {
            fertilityVerdicts[index] = fertilityVerdict!;
          }
          abnormalSlots[index] =
              slot['abnormal'] == true || rootAbnormal.contains(index);
          confirmedInfertileSlots[index] =
              slot['confirmed_infertile'] == true ||
              rootInfertile.contains(index);
          if (fertilityVerdicts[index] == 'none' &&
              confirmedInfertileSlots[index]) {
            fertilityVerdicts[index] = 'infertile';
          }
          transferReadySlots[index] =
              slot['transfer_ready'] == true || rootTransfer.contains(index);
        }
        final equipment = data['equipment'] is Map
            ? Map<String, dynamic>.from(data['equipment'] as Map)
            : const <String, dynamic>{};
        final equipmentActive = equipment['active'] == true;
        final equipmentCode = equipment['code']?.toString() ?? 'none';
        final equipmentMessage = equipment['message']?.toString() ?? '';
        final automaticIntakeScreeningEnabled =
            data['automatic_intake_screening_enabled'] == true;
        final physicalAlertCount =
            (data['alert_count'] as num?)?.toInt() ??
            List<bool>.generate(
              eggs.length,
              (index) =>
                  abnormalSlots[index] ||
                  confirmedInfertileSlots[index] ||
                  transferReadySlots[index],
            ).where((value) => value).length;
        final p4ScanEpoch = _extractP4LastScanEpoch(data, metadata);
        final scanActive =
            _extractP4Bool(data, metadata, const [
              'scan_active',
              'scanActive',
            ]) ??
            false;
        final scanStatus = _extractP4String(data, metadata, const [
          'scan_status',
          'scanStatus',
        ]);
        final scanError = _extractP4String(data, metadata, const [
          'last_scan_error',
          'lastScanError',
          'scan_error',
        ]);
        final gridDecision = _reconcileP4GridCandidate(
          eggs,
          scanEpoch: p4ScanEpoch,
          scanActive: scanActive,
          scanStatus: scanStatus,
          scanError: scanError,
        );
        final effectiveEggs = gridDecision.eggs;
        final effectiveCount = effectiveEggs.where((hasEgg) => hasEgg).length;
        final timeTrusted =
            _extractP4Bool(data, metadata, const ['time_trusted']) ?? true;
        final timeSyncRequired =
            _extractP4Bool(data, metadata, const ['time_sync_required']) ??
            !timeTrusted;
        final lastPhoneSync = _extractP4EpochDateTime(data, metadata, const [
          'last_phone_sync_epoch',
          'lastPhoneSyncEpoch',
        ]);

        // Phone is authoritative for date-placed: never let a P4 power-cycle
        // reset a slot's age. Keep our existing dates for slots that still hold
        // an egg; only new eggs get a fresh date.
        final mergedPlaced = _mergeAuthoritativePlacedAt(
          effectiveEggs,
          placedAt,
        );
        final mergedPlacedConfirmed = _mergeAuthoritativePlacedAtConfirmation(
          effectiveEggs,
          mergedPlaced,
        );
        final mergedDays = _daysFromPlacedAt(mergedPlaced, slotDays);
        final effectiveDay = mergedDays.whereType<int>().fold<int?>(
          null,
          (maxDay, slotDay) =>
              maxDay == null || slotDay > maxDay ? slotDay : maxDay,
        );
        if (!mounted) return false;
        setState(() {
          _applyAutomaticFertilityVerdicts(
            effectiveEggs,
            gridDecision.sourceFresh
                ? fertilityVerdicts
                : _p4SlotFertilityVerdict,
          );
          _p4EggCount = effectiveCount;
          _p4EggDay = effectiveDay;
          _p4SlotHasEgg = effectiveEggs;
          _p4SlotDays = mergedDays;
          _p4SlotPlacedAt = mergedPlaced;
          _p4SlotPlacedAtConfirmed = mergedPlacedConfirmed;
          if (gridDecision.sourceFresh) {
            _p4SlotIntakeVerdict = intakeVerdicts;
            _p4SlotFertilityVerdict = fertilityVerdicts;
            _p4SlotAbnormal = abnormalSlots;
            _p4SlotConfirmedInfertile = confirmedInfertileSlots;
            _p4SlotTransferReady = transferReadySlots;
            _p4PhysicalAlertCount = physicalAlertCount;
          }
          _p4EquipmentFaultActive = equipmentActive;
          _p4EquipmentFaultCode = equipmentCode;
          _p4EquipmentFaultMessage = equipmentMessage;
          _p4AutomaticIntakeScreeningEnabled = automaticIntakeScreeningEnabled;
          _p4TimeTrusted = timeTrusted;
          _p4TimeSyncRequired = timeSyncRequired;
          _p4LastPhoneSyncAt = lastPhoneSync ?? _p4LastPhoneSyncAt;
          _lastSyncTime = DateTime.now();
          _p4GridUsingPreservedSnapshot = gridDecision.protectedSnapshot;
          _p4GridDataStatus = gridDecision.status;
          _status = gridDecision.protectedSnapshot
              ? 'P4 scan protected | showing $effectiveCount verified eggs'
              : day == null
              ? 'P4 count: $effectiveCount eggs'
              : 'P4 count: $effectiveCount eggs | Day $day';
        });
        unawaited(_saveStableP4GridSnapshot());
        unawaited(_saveSlotPlacedAt());
        if (gridDecision.sourceFresh) {
          try {
            await _recordEggCounterSnapshot(
              count: effectiveCount,
              eggDay: effectiveDay,
              occupiedSlots: effectiveEggs,
              slotDays: mergedDays,
              placedAt: mergedPlaced,
              p4ScanEpoch: p4ScanEpoch,
            );
          } catch (e) {
            debugPrint('P4 counter-history save error: $e');
          }
        }
        return gridDecision.sourceFresh;
      }
    } catch (e) {
      debugPrint('P4 sync error: $e');
    }
    return false;
  }

  Future<void> _syncEggGridFromP4() async {
    await _refreshEggGridFromP4();
  }

  Future<void> _recordEggCounterSnapshot({
    required int count,
    required int? eggDay,
    required List<bool> occupiedSlots,
    required List<int?> slotDays,
    required List<DateTime?> placedAt,
    required int? p4ScanEpoch,
  }) async {
    if (p4ScanEpoch == null && count == 0 && _eggCounterHistory.isEmpty) {
      return;
    }
    if (_eggCounterHistory.isNotEmpty) {
      final latest = _eggCounterHistory.first;
      if (p4ScanEpoch != null && latest.p4ScanEpoch == p4ScanEpoch) {
        return;
      }
      if (p4ScanEpoch == null &&
          latest.count == count &&
          _sameBoolList(latest.occupiedSlots, occupiedSlots)) {
        return;
      }
    }

    final record = EggCounterRecord(
      id: DateTime.now().millisecondsSinceEpoch,
      timestamp: DateTime.now(),
      p4ScanEpoch: p4ScanEpoch,
      count: count,
      eggDay: eggDay,
      occupiedSlots: List<bool>.from(occupiedSlots),
      slotDays: List<int?>.from(slotDays),
      placedAt: List<DateTime?>.from(placedAt),
    );

    if (mounted) {
      setState(() => _eggCounterHistory.insert(0, record));
    } else {
      _eggCounterHistory.insert(0, record);
    }
    await _saveEggCounterHistory();
  }

  bool _sameBoolList(List<bool> a, List<bool> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  bool? _extractP4Bool(
    Map<String, dynamic> data,
    Map<String, dynamic> metadata,
    List<String> keys,
  ) {
    for (final source in [metadata, data]) {
      for (final key in keys) {
        final value = source[key];
        if (value is bool) return value;
        if (value is num) return value != 0;
        if (value is String) {
          final normalized = value.toLowerCase().trim();
          if (normalized == 'true' ||
              normalized == '1' ||
              normalized == 'yes') {
            return true;
          }
          if (normalized == 'false' ||
              normalized == '0' ||
              normalized == 'no') {
            return false;
          }
        }
      }
    }
    return null;
  }

  DateTime? _extractP4EpochDateTime(
    Map<String, dynamic> data,
    Map<String, dynamic> metadata,
    List<String> keys,
  ) {
    for (final source in [metadata, data]) {
      for (final key in keys) {
        final parsed = _dateTimeFromEpochValue(source[key]);
        if (parsed != null) return parsed;
      }
    }
    return null;
  }

  List<bool> _extractBoolList(dynamic raw, int targetLength) {
    if (raw is! List || raw.length != targetLength) {
      throw FormatException(
        'P4 eggs must contain exactly $targetLength slot values.',
      );
    }
    final result = raw.map((value) {
      if (value is bool) return value;
      if (value is num && (value == 0 || value == 1)) return value == 1;
      if (value is String) {
        final normalized = value.toLowerCase().trim();
        if (normalized == 'true' || normalized == '1' || normalized == 'yes') {
          return true;
        }
        if (normalized == 'false' || normalized == '0' || normalized == 'no') {
          return false;
        }
      }
      throw FormatException('P4 eggs contains an invalid slot value: $value');
    }).toList();
    return result;
  }

  List<int?> _extractSlotDays(
    Map<String, dynamic> data,
    Map<String, dynamic> metadata,
    int targetLength,
    int? fallbackDay,
  ) {
    dynamic raw;
    for (final source in [data, metadata]) {
      raw ??= source['days'];
      raw ??= source['slotDays'];
      raw ??= source['slot_days'];
      raw ??= source['eggDays'];
      raw ??= source['egg_days'];
    }

    final values = raw is List ? raw : const [];
    final result = List<int?>.generate(targetLength, (index) {
      if (index >= values.length) return fallbackDay;
      final value = values[index];
      if (value is num) return value.toInt();
      if (value is String) return int.tryParse(value);
      return fallbackDay;
    });
    return result;
  }

  List<DateTime?> _extractSlotPlacedAt(
    Map<String, dynamic> data,
    Map<String, dynamic> metadata,
    int targetLength,
  ) {
    dynamic raw;
    for (final source in [data, metadata]) {
      raw ??= source['placed_at'];
      raw ??= source['placedAt'];
      raw ??= source['start_times'];
      raw ??= source['startTimes'];
      raw ??= source['datePlaced'];
    }

    final values = raw is List ? raw : const [];
    final result = List<DateTime?>.generate(targetLength, (index) {
      if (index >= values.length) return null;
      return _dateTimeFromEpochValue(values[index]);
    });

    final slots = data['slots'];
    if (slots is List) {
      for (final slot in slots) {
        if (slot is! Map) continue;
        final cell = (slot['cell'] as num?)?.toInt();
        if (cell == null || cell < 0 || cell >= targetLength) continue;
        result[cell] =
            _dateTimeFromEpochValue(
              slot['placed_at'] ??
                  slot['placedAt'] ??
                  slot['start_time'] ??
                  slot['startTime'],
            ) ??
            result[cell];
      }
    }
    return result;
  }

  /// The phone is the source of truth for each slot's "date placed".
  ///
  /// The P4 has no battery-backed clock, so after the incubator loses power it
  /// can boot with a blank/fresh placed_at and, on the next scan, report the
  /// same eggs as if they were just placed. If we trusted that, every slot's age
  /// (and the 7-day candling window) would silently reset.
  ///
  /// Rule: while a slot keeps holding an egg, its existing date is kept and is
  /// never overwritten by the P4. We only assign a date when a slot newly gains
  /// an egg (empty -> egg) and we clear it when the egg is removed (egg ->
  /// empty). So a genuinely new egg gets a fresh date; a power cycle does not.
  /// (If an egg is swapped in the same slot without the app ever observing it
  /// empty, the old date is kept by design — clear that slot manually to reset.)
  List<DateTime?> _mergeAuthoritativePlacedAt(
    List<bool> newEggs,
    List<DateTime?> incoming,
  ) {
    final now = DateTime.now();
    return List<DateTime?>.generate(newEggs.length, (index) {
      if (!newEggs[index]) return null; // egg removed -> forget its date
      final existing = index < _p4SlotPlacedAt.length
          ? _p4SlotPlacedAt[index]
          : null;
      if (existing != null) return existing; // keep the date we already have
      final fromP4 = index < incoming.length ? incoming[index] : null;
      return fromP4 ?? now; // brand-new egg: first time we've seen it
    });
  }

  List<bool> _mergeAuthoritativePlacedAtConfirmation(
    List<bool> newEggs,
    List<DateTime?> merged,
  ) {
    return List<bool>.generate(newEggs.length, (index) {
      final mergedDate = index < merged.length ? merged[index] : null;
      // A recorded or edited date is immediately usable metadata. There is no
      // second farmer confirmation step in the automatic workflow.
      return newEggs[index] && mergedDate != null;
    });
  }

  /// Derive each slot's age from the authoritative placed-at, falling back to
  /// the P4-reported day only where we have no date.
  List<int?> _daysFromPlacedAt(List<DateTime?> placedAt, List<int?> fallback) {
    return List<int?>.generate(placedAt.length, (index) {
      final fromPlaced = _daysSincePlaced(placedAt[index]);
      if (fromPlaced != null) return fromPlaced;
      return index < fallback.length ? fallback[index] : null;
    });
  }

  Future<void> _saveSlotPlacedAt() async {
    final prefs = await SharedPreferences.getInstance();
    final encoded = _p4SlotPlacedAt
        .map((d) => d == null ? null : d.millisecondsSinceEpoch ~/ 1000)
        .toList();
    await prefs.setString('slot_placed_at', jsonEncode(encoded));
    await prefs.setString(
      _slotPlacedAtConfirmedKey,
      jsonEncode(_p4SlotPlacedAtConfirmed),
    );
  }

  void _applyAutomaticFertilityVerdicts(
    List<bool> occupiedSlots,
    List<String> fertilityVerdicts,
  ) {
    for (var index = 0; index < _activeGridCellCount; index++) {
      if (index >= _eggData.length) break;
      final occupied = index < occupiedSlots.length && occupiedSlots[index];
      final verdict = index < fertilityVerdicts.length
          ? fertilityVerdicts[index]
          : 'none';
      final nextStatus = !occupied
          ? EggStatus.unknown
          : verdict == 'fertile'
          ? EggStatus.fertile
          : verdict == 'infertile'
          ? EggStatus.infertile
          : EggStatus.unknown;
      final egg = _eggData[index];
      if (egg.status != nextStatus ||
          egg.confidence != (nextStatus == EggStatus.unknown ? 0.0 : 1.0)) {
        egg.status = nextStatus;
        egg.confidence = nextStatus == EggStatus.unknown ? 0.0 : 1.0;
      }
    }
    _recalculateCurrentCounts();
  }

  DateTime? _dateTimeFromEpochValue(dynamic value) {
    if (value == null) return null;
    if (value is num) {
      var epoch = value.toInt();
      if (epoch <= 0) return null;
      if (epoch > 1000000000000) epoch ~/= 1000;
      return DateTime.fromMillisecondsSinceEpoch(epoch * 1000);
    }
    if (value is String) {
      final numeric = int.tryParse(value);
      if (numeric != null) return _dateTimeFromEpochValue(numeric);
      return DateTime.tryParse(value);
    }
    return null;
  }

  int? _extractP4LastScanEpoch(
    Map<String, dynamic> data,
    Map<String, dynamic> metadata,
  ) {
    for (final source in [data, metadata]) {
      for (final key in [
        'last_scan_epoch',
        'lastScanEpoch',
        'scan_time',
        'scanTime',
      ]) {
        final parsed = _epochSecondsFromValue(source[key]);
        if (parsed != null && parsed > 0) return parsed;
      }
    }
    return null;
  }

  String? _extractP4String(
    Map<String, dynamic> data,
    Map<String, dynamic> metadata,
    List<String> keys,
  ) {
    for (final source in [data, metadata]) {
      for (final key in keys) {
        final value = source[key];
        if (value is String && value.trim().isNotEmpty) {
          return value.trim();
        }
      }
    }
    return null;
  }

  bool _sameP4Grid(List<bool> a, List<bool> b) {
    if (a.length != b.length) return false;
    for (var index = 0; index < a.length; index++) {
      if (a[index] != b[index]) return false;
    }
    return true;
  }

  _P4GridDecision _reconcileP4GridCandidate(
    List<bool> incoming, {
    required int? scanEpoch,
    required bool scanActive,
    required String? scanStatus,
    required String? scanError,
  }) {
    final current = List<bool>.from(_p4SlotHasEgg);
    final normalizedStatus = scanStatus?.trim().toLowerCase();
    final normalizedError = scanError?.trim().toLowerCase();
    final hasReportedError =
        normalizedStatus == 'error' ||
        (normalizedError != null &&
            normalizedError.isNotEmpty &&
            normalizedError != 'none' &&
            normalizedError != 'ok');

    if (scanActive || normalizedStatus == 'active') {
      return _P4GridDecision(
        eggs: current,
        sourceFresh: false,
        protectedSnapshot: true,
        status: _hasStableP4Grid
            ? 'P4 scanning - last verified tray preserved'
            : 'P4 scanning - waiting for its first complete tray',
      );
    }

    if (hasReportedError) {
      final reason = (scanError ?? 'scan error').replaceAll('_', ' ');
      return _P4GridDecision(
        eggs: current,
        sourceFresh: false,
        protectedSnapshot: true,
        status: _hasStableP4Grid
            ? 'P4 $reason - last verified tray preserved'
            : 'P4 $reason - waiting for a successful scan',
      );
    }

    if (!_hasStableP4Grid) {
      _hasStableP4Grid = true;
      _lastAcceptedP4ScanEpoch = scanEpoch;
      _pendingP4RemovalGrid = null;
      _pendingP4RemovalScanEpoch = null;
      return _P4GridDecision(
        eggs: List<bool>.from(incoming),
        sourceFresh: true,
        protectedSnapshot: false,
        status: 'P4 tray verified',
      );
    }

    if (scanEpoch != null &&
        _lastAcceptedP4ScanEpoch != null &&
        scanEpoch < _lastAcceptedP4ScanEpoch!) {
      return _P4GridDecision(
        eggs: current,
        sourceFresh: false,
        protectedSnapshot: true,
        status: 'Older P4 result ignored - verified tray preserved',
      );
    }

    if (scanEpoch != null &&
        _lastAcceptedP4ScanEpoch == scanEpoch &&
        !_sameP4Grid(current, incoming)) {
      return _P4GridDecision(
        eggs: current,
        sourceFresh: false,
        protectedSnapshot: true,
        status: 'Incomplete P4 result ignored - verified tray preserved',
      );
    }

    if (_sameP4Grid(current, incoming)) {
      if (scanEpoch != null) _lastAcceptedP4ScanEpoch = scanEpoch;
      _pendingP4RemovalGrid = null;
      _pendingP4RemovalScanEpoch = null;
      return _P4GridDecision(
        eggs: current,
        sourceFresh: true,
        protectedSnapshot: false,
        status: 'P4 tray verified - no slot changes',
      );
    }

    var hasRemoval = false;
    for (var index = 0; index < incoming.length; index++) {
      if (current[index] && !incoming[index]) {
        hasRemoval = true;
        break;
      }
    }

    if (!hasRemoval) {
      _lastAcceptedP4ScanEpoch = scanEpoch ?? _lastAcceptedP4ScanEpoch;
      _pendingP4RemovalGrid = null;
      _pendingP4RemovalScanEpoch = null;
      return _P4GridDecision(
        eggs: List<bool>.from(incoming),
        sourceFresh: true,
        protectedSnapshot: false,
        status: 'P4 tray verified - new occupied slots added',
      );
    }

    // New P4 firmware publishes "ok" only after the JPEG is complete and all
    // 56 classifier calls succeed transactionally. That completed result can
    // safely apply real removals immediately. Older firmware has no such
    // guarantee, so it keeps the two-distinct-scan fallback below.
    if (normalizedStatus == 'ok' && scanEpoch != null) {
      _lastAcceptedP4ScanEpoch = scanEpoch;
      _pendingP4RemovalGrid = null;
      _pendingP4RemovalScanEpoch = null;
      return _P4GridDecision(
        eggs: List<bool>.from(incoming),
        sourceFresh: true,
        protectedSnapshot: false,
        status: 'P4 tray verified - completed slot changes applied',
      );
    }

    final pendingMatches =
        _pendingP4RemovalGrid != null &&
        _sameP4Grid(_pendingP4RemovalGrid!, incoming);
    final isNewerConfirmation =
        scanEpoch != null &&
        _pendingP4RemovalScanEpoch != null &&
        scanEpoch > _pendingP4RemovalScanEpoch!;
    if (pendingMatches && isNewerConfirmation) {
      _lastAcceptedP4ScanEpoch = scanEpoch;
      _pendingP4RemovalGrid = null;
      _pendingP4RemovalScanEpoch = null;
      return _P4GridDecision(
        eggs: List<bool>.from(incoming),
        sourceFresh: true,
        protectedSnapshot: false,
        status: 'P4 tray verified - removals confirmed twice',
      );
    }

    final protectedGrid = List<bool>.generate(
      incoming.length,
      (index) => current[index] || incoming[index],
      growable: false,
    );
    _pendingP4RemovalGrid = List<bool>.from(incoming);
    _pendingP4RemovalScanEpoch = scanEpoch;
    if (scanEpoch != null) _lastAcceptedP4ScanEpoch = scanEpoch;
    return _P4GridDecision(
      eggs: protectedGrid,
      sourceFresh: false,
      protectedSnapshot: true,
      status: scanEpoch == null
          ? 'Possible removals protected - waiting for a completed scan'
          : 'Possible removals protected - one more scan will confirm',
    );
  }

  Future<void> _saveStableP4GridSnapshot() async {
    if (!_hasStableP4Grid) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _stableP4GridSnapshotKey,
      jsonEncode({
        'eggs': _p4SlotHasEgg,
        'last_scan_epoch': _lastAcceptedP4ScanEpoch,
        'pending_removal_eggs': _pendingP4RemovalGrid,
        'pending_removal_scan_epoch': _pendingP4RemovalScanEpoch,
      }),
    );
  }

  int? _epochSecondsFromValue(dynamic value) {
    if (value == null) return null;
    if (value is num) {
      var epoch = value.toInt();
      if (epoch <= 0) return null;
      if (epoch > 1000000000000) epoch ~/= 1000;
      return epoch;
    }
    if (value is String) {
      final numeric = int.tryParse(value);
      if (numeric != null) return _epochSecondsFromValue(numeric);
      final parsed = DateTime.tryParse(value);
      if (parsed != null) return parsed.millisecondsSinceEpoch ~/ 1000;
    }
    return null;
  }

  int? _extractP4EggDay(
    Map<String, dynamic> data,
    Map<String, dynamic> metadata,
  ) {
    for (final source in [data, metadata]) {
      for (final key in [
        'day',
        'eggDay',
        'egg_day',
        'eggDayCounter',
        'dayCounter',
        'incubationDay',
      ]) {
        final value = source[key];
        if (value is num) return value.toInt();
        if (value is String) {
          final parsed = int.tryParse(value);
          if (parsed != null) return parsed;
        }
      }
    }
    return null;
  }

  Future<void> _startP4IntakeCandlingHardware(List<int> ledNumbers) async {
    // Candling owns the tray pause and bulb darkness. Do not start the
    // mutually exclusive normal-photo capture hold before this request.
    final selected = ledNumbers.where((led) => led >= 1 && led <= 56).toSet();
    final sorted = selected.toList()..sort();
    if (sorted.isEmpty) {
      throw StateError('Select at least one occupied slot before capture.');
    }
    final ledQuery = Uri.encodeQueryComponent(sorted.join(','));
    final response = await _getP4(
      '/candling_start?led=$ledQuery',
      timeout: _candlingP4Timeout,
    );
    if (response.statusCode != 200) {
      throw HttpException(
        'P4 candling start failed: ${response.statusCode} ${response.body}',
        uri: _s3Uri('/p4/candling_start?led=$ledQuery'),
      );
    }
  }

  Future<Map<String, dynamic>> _verifyIntakeSelectedLeds(
    List<int> selectedLeds,
  ) async {
    final expected = selectedLeds.toSet();
    final ledStatus = await _esp32.getLedControllerStatus(
      timeout: const Duration(seconds: 5),
    );
    final active = ledStatus.activeLeds.toSet();
    final missing = expected.difference(active).toList()..sort();
    final unexpected = active.difference(expected).toList()..sort();
    final verified = missing.isEmpty && unexpected.isEmpty;
    final result = <String, dynamic>{
      'verified': verified,
      'controller_status': ledStatus.status,
      'candling_active': ledStatus.candlingActive,
      'active_led_count': ledStatus.activeLedCount,
      'active_leds': active.toList()..sort(),
      'expected_leds': expected.toList()..sort(),
      'missing_leds': missing,
      'unexpected_leds': unexpected,
    };
    if (!verified) {
      throw StateError(
        'Exact LED activation failed. Missing: '
        '${missing.isEmpty ? 'none' : missing.join(', ')}; unexpected: '
        '${unexpected.isEmpty ? 'none' : unexpected.join(', ')}.',
      );
    }
    return result;
  }

  Future<void> _stopP4CandlingHardware() async {
    try {
      final response = await _getP4(
        '/candling_stop',
        timeout: _candlingP4Timeout,
      );
      if (response.statusCode != 200) {
        debugPrint('P4 candling_stop returned ${response.statusCode}');
      }
    } catch (e) {
      debugPrint('P4 candling stop error: $e');
    }
  }

  Future<void> _startP4CaptureHold() async {
    final response = await _getP4(
      '/capture_hold_start',
      timeout: _candlingP4Timeout,
    );
    if (response.statusCode != 200) {
      final body = response.body.trim();
      throw HttpException(
        'P4 capture hold start failed: ${response.statusCode}'
        '${body.isEmpty ? '' : ' $body'}',
        uri: _s3Uri('/p4/capture_hold_start'),
      );
    }
  }

  Future<void> _finishLedTestBeforeCandlingCapture() async {
    if (!_ledTestBusy) return;

    if (mounted) {
      setState(() => _status = 'Waiting for one-by-one LED test to finish...');
    }
    final deadline = DateTime.now().add(_ledTestCaptureWaitTimeout);
    while (_ledTestBusy && DateTime.now().isBefore(deadline)) {
      await Future.delayed(const Duration(milliseconds: 100));
    }
    if (_ledTestBusy) {
      throw TimeoutException('One-by-one LED test did not finish in time');
    }

    if (mounted) {
      setState(() => _status = 'LED test complete; clearing test lights...');
    }
    final status = await _esp32.stopLedCandling(
      timeout: const Duration(seconds: 6),
    );
    if (mounted) {
      setState(() {
        _applyLedControllerStatus(status);
        _selectedLedNumbers.clear();
        _ledActiveCount = 0;
      });
    }
    await Future.delayed(const Duration(milliseconds: 500));
  }

  Future<void> _stopP4CaptureHold() async {
    try {
      final response = await _getP4(
        '/capture_hold_stop',
        timeout: _candlingP4Timeout,
      );
      if (response.statusCode != 200) {
        debugPrint('P4 capture_hold_stop returned ${response.statusCode}');
      }
    } catch (e) {
      debugPrint('P4 capture hold stop error: $e');
    }
  }

  Future<void> _restoreCandlingHardware() async {
    // P4 turns slot LEDs off, restores its GPIO33 bulb, and releases the tray.
    await _stopP4CandlingHardware();
  }

  Future<void> _verifyCandlingLightsForHistory(
    Iterable<int> expectedLeds,
  ) async {
    final expected = expectedLeds.toSet();
    try {
      final ledStatus = await _esp32.getLedControllerStatus(
        timeout: const Duration(seconds: 5),
      );
      final active = ledStatus.activeLeds.toSet();
      final missing = expected.difference(active).toList()..sort();
      _lastActiveCandlingLeds = active.toList()..sort();
      _lastMissingCandlingLeds = missing;
      _lastCandlingLedCacheValid = ledStatus.recentCacheValid;
      _lastCandlingLightsVerified =
          ledStatus.candlingActive &&
          ledStatus.recentCacheValid &&
          missing.isEmpty;
    } catch (error) {
      debugPrint('Candling LED history verification unavailable: $error');
      _lastCandlingLightsVerified = null;
      _lastCandlingLedCacheValid = null;
      _lastActiveCandlingLeds = const [];
      _lastMissingCandlingLeds = expected.toList()..sort();
    }
  }

  Future<void> _runLedControllerCommand({
    required Future<LedControllerStatus> Function() command,
    required String pendingStatus,
    Set<int>? optimisticSelection,
    bool clearSelectionAfter = false,
  }) async {
    if (_ledTestBusy) return;

    if (_demoMode) {
      setState(() {
        _ledsConnected = true;
        _ledTestStatus = pendingStatus;
        if (optimisticSelection != null) {
          _selectedLedNumbers
            ..clear()
            ..addAll(optimisticSelection);
          _ledActiveCount = optimisticSelection.length;
        }
        if (clearSelectionAfter) {
          _selectedLedNumbers.clear();
          _ledActiveCount = 0;
        }
      });
      return;
    }

    if (!_isConnectedToCorrectSSID || !_s3Connected) {
      setState(() {
        _ledsConnected = false;
        _ledTestStatus = 'Connect to AI_CANDLING first';
      });
      return;
    }

    setState(() {
      _ledTestBusy = true;
      _ledTestStatus = pendingStatus;
      if (optimisticSelection != null) {
        _selectedLedNumbers
          ..clear()
          ..addAll(optimisticSelection);
        _ledActiveCount = optimisticSelection.length;
      }
    });

    try {
      final status = await command();
      if (!mounted) return;
      setState(() {
        _applyLedControllerStatus(status);
        if (clearSelectionAfter) {
          _selectedLedNumbers.clear();
          _ledActiveCount = 0;
        }
      });
    } catch (e) {
      debugPrint('LED controller command failed: $e');
      if (!mounted) return;
      setState(() {
        _ledsConnected = false;
        _ledTestStatus = 'LED controller command failed';
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('LED controller command failed: $e')),
      );
    } finally {
      if (mounted) {
        setState(() => _ledTestBusy = false);
      }
    }
  }

  Future<void> _refreshLedControllerStatus() async {
    await _runLedControllerCommand(
      pendingStatus: 'Refreshing LED controller...',
      command: () =>
          _esp32.getLedControllerStatus(timeout: const Duration(seconds: 5)),
    );
  }

  Future<void> _sendLedSelection(Set<int> ledNumbers) async {
    final sorted = ledNumbers.where((led) => led >= 1 && led <= 56).toList()
      ..sort();
    await _runLedControllerCommand(
      pendingStatus: sorted.isEmpty
          ? 'Turning all LEDs off...'
          : 'Updating ${sorted.length} LEDs...',
      optimisticSelection: sorted.toSet(),
      command: () => _esp32.setLedTest(
        led: sorted.isEmpty ? 'off' : sorted.join(','),
        timeout: const Duration(seconds: 6),
      ),
    );
  }

  void _toggleLedNumber(int ledNumber) {
    if (_ledTestBusy) return;
    final next = Set<int>.from(_selectedLedNumbers);
    if (!next.add(ledNumber)) {
      next.remove(ledNumber);
    }
    unawaited(_sendLedSelection(next));
  }

  Future<void> _turnAllLedsOff() async {
    await _runLedControllerCommand(
      pendingStatus: 'Turning all LEDs off...',
      optimisticSelection: const <int>{},
      command: () => _esp32.stopLedCandling(),
    );
  }

  Future<void> _turnAllLedsOn() async {
    final allLeds = {for (var led = 1; led <= 56; led++) led};
    await _runLedControllerCommand(
      pendingStatus: 'Turning all LEDs on...',
      optimisticSelection: allLeds,
      command: () =>
          _esp32.setLedTest(led: 'all', timeout: const Duration(seconds: 6)),
    );
  }

  Future<void> _runLedChaseTest() async {
    await _runLedControllerCommand(
      pendingStatus: 'Running one-by-one LED test...',
      optimisticSelection: const <int>{},
      clearSelectionAfter: true,
      command: () =>
          _esp32.setLedTest(led: 'chase', timeout: const Duration(seconds: 20)),
    );
  }

  Future<void> _syncLedSlotsFromP4() async {
    await _runLedControllerCommand(
      pendingStatus: 'Syncing LED slots from P4...',
      command: () => _esp32.syncLedSlots(timeout: const Duration(seconds: 8)),
    );
  }

  Future<void> _lightOccupiedEggLeds() async {
    await _runLedControllerCommand(
      pendingStatus: 'Lighting occupied egg LEDs...',
      command: () =>
          _esp32.startLedCandling(timeout: const Duration(seconds: 8)),
    );
  }

  void _resumeStreamAndSensor() {
    _sensorTimer?.cancel();
    setState(() {
      _isStreaming = true;
      _streamManuallyOff = false;
      _streamFrameReceived = false;
      _streamKey++;
    });
    _startSensorPolling();
    _startPeriodicP4Sync();
  }

  // Manual stream on/off from the banner toggle. Disabled unless connected to
  // the incubator AP. The stream also auto-stops during candling / P4 capture
  // (those paths set _isStreaming = false), so the toggle reflects that too.
  void _toggleStream() {
    if (!_isConnectedToCorrectSSID) return;
    if (_isStreaming) {
      setState(() {
        _isStreaming = false;
        _streamFrameReceived = false;
        _streamManuallyOff = true;
      });
    } else {
      _streamManuallyOff = false;
      _resumeStreamAndSensor();
    }
  }

  void _handleS3StreamFirstFrame() {
    if (!mounted || !_isStreaming || _streamFrameReceived) return;
    setState(() {
      _streamFrameReceived = true;
      _s3Connected = true;
      _status = 'S3 stream live';
    });
  }

  void _handleS3StreamError(Object error, StackTrace stackTrace) {
    debugPrint('MJPEG stream error: $error');
    if (!mounted || !_isStreaming) return;
    setState(() {
      _streamFrameReceived = false;
      _s3Connected = false;
      _status = 'S3 stream reconnecting...';
    });
  }

  Future<void> _refreshApp({bool silent = false}) async {
    if (_isResetting || !mounted) return;
    if (_demoMode) {
      setState(() {
        _status = 'Demo mode refreshed';
        _lastSyncTime = DateTime.now();
      });
      return;
    }
    setState(() {
      _isResetting = true;
      if (!silent) _status = 'Refreshing app...';
    });

    _sensorTimer?.cancel();
    _p4PollTimer?.cancel();
    setState(() {
      _isStreaming = false;
      _streamKey++;
    });

    await _loadSessions();
    await _loadCustomGrid();
    await _loadStream(waitForConnectivity: true);

    if (!mounted) return;
    setState(() => _isResetting = false);
  }

  // Grid calibration capture
  Future<void> _captureForGridCalibration() async {
    if (_isCandling ||
        _isDatasetCapturing ||
        _isDatasetAutoCapturing ||
        _isFertilityDatasetCapturing ||
        _isFertilityDatasetAutoCapturing ||
        !_isWifiCorrect ||
        _isCapturingCalibration) {
      return;
    }

    // Stop streaming and sensor polling to free camera for capture
    _sensorTimer?.cancel();
    setState(() {
      _isStreaming = false;
      _streamKey++; // Forces the MJPEG viewer to disconnect
      _isCapturingCalibration = true;
      _status = 'Capturing reference image...';
    });

    // Brief delay to ensure stream fully stops
    await Future.delayed(const Duration(milliseconds: 500));

    try {
      bool captureHoldStarted = false;
      Object? captureHoldError;
      final client = http.Client();
      try {
        try {
          await _startP4CaptureHold();
          captureHoldStarted = true;
        } catch (e) {
          captureHoldError = e;
          debugPrint(
            'P4 tray hold unavailable during grid capture; '
            'continuing with the S3 camera: $e',
          );
        }
        if (!mounted) return;
        setState(() {
          _status = captureHoldStarted
              ? 'Waiting for camera to settle...'
              : 'P4 unavailable - capturing camera directly...';
        });
        await Future.delayed(_captureHoldSettleDelay);
        if (!mounted) return;

        final request = http.Request(
          'GET',
          _s3Uri(_gridCalibrationCaptureEndpoint),
        );

        final response = await client
            .send(request)
            .timeout(
              _cameraCaptureRequestTimeout,
              onTimeout: () => throw TimeoutException('Capture timed out'),
            );

        if (response.statusCode != 200) {
          throw HttpException(
            'Grid camera capture failed: ${response.statusCode}',
            uri: _s3Uri(_gridCalibrationCaptureEndpoint),
          );
        }
        final bytes = await response.stream.toBytes();
        final isJpeg =
            bytes.length >= 4 &&
            bytes[0] == 0xFF &&
            bytes[1] == 0xD8 &&
            bytes[bytes.length - 2] == 0xFF &&
            bytes[bytes.length - 1] == 0xD9;
        if (!isJpeg) {
          throw const FormatException('Camera returned an invalid JPEG');
        }

        setState(() {
          _gridCalibrationImage = Uint8List.fromList(bytes);
          _gridSaved = false;
          _isCapturingCalibration = false;
          _referenceTrashDimmed = false;
          _status = captureHoldError == null
              ? 'Reference image captured - adjust grid'
              : 'Reference captured - P4 tray hold was unavailable';
        });
        _startReferenceTrashOpacityTimer();
      } finally {
        client.close();
        if (captureHoldStarted) {
          await _stopP4CaptureHold();
        }
      }
    } catch (e) {
      setState(() {
        _isCapturingCalibration = false;
        _status = 'Calibration capture failed: $e';
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Capture failed: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
      // Restart stream on failure
      _resumeStreamAndSensor();
    }
  }

  void _startReferenceTrashOpacityTimer() {
    _referenceTrashOpacityTimer?.cancel();
    _referenceTrashOpacityTimer = Timer(const Duration(seconds: 5), () {
      if (!mounted || _gridCalibrationImage == null) return;
      setState(() => _referenceTrashDimmed = true);
    });
  }

  void _clearGridCalibrationImage() {
    _referenceTrashOpacityTimer?.cancel();
    if (!mounted) return;
    setState(() {
      _gridCalibrationImage = null;
      _referenceTrashDimmed = false;
      _status = 'Reference image removed';
    });
  }

  String _datasetLabelName(String label) {
    return switch (label) {
      'custom_slots' => 'Custom slots',
      'custom_empty_slots' => 'Hard empty',
      'empty_slot' => 'Empty slot',
      'slot_reference' => 'Slot reference',
      _ => 'Egg present',
    };
  }

  String _datasetLabelFolderName(String label) {
    return switch (label) {
      'empty_slot' => 'empty_slot',
      'slot_reference' => 'slot_reference',
      _ => 'egg_present',
    };
  }

  String get _datasetCaptureLabelName =>
      _datasetLabelName(_datasetCaptureLabel);

  bool get _datasetUsesCustomSlots => _datasetCaptureLabel == 'custom_slots';

  bool get _datasetUsesSelectedSlotMode =>
      _datasetCaptureLabel == 'custom_slots' ||
      _datasetCaptureLabel == 'custom_empty_slots';

  bool get _datasetUsesCustomEmptySlots =>
      _datasetCaptureLabel == 'custom_empty_slots';

  String get _datasetSelectedSlotLabel =>
      _datasetUsesCustomEmptySlots ? 'empty_slot' : 'egg_present';

  String get _datasetSelectSlotSnackText => _datasetUsesCustomEmptySlots
      ? 'Select at least one hard empty slot first.'
      : 'Select at least one custom egg slot first.';

  String _datasetActualLabelForSlot(int slotIndex) {
    if (_datasetUsesSelectedSlotMode &&
        _datasetSelectedEggSlots.contains(slotIndex)) {
      return _datasetSelectedSlotLabel;
    }
    return _datasetCaptureLabel;
  }

  String get _datasetCountdownText {
    final seconds = math.max(0, _datasetNextCaptureSeconds);
    final minutes = seconds ~/ 60;
    final remainingSeconds = seconds % 60;
    return '$minutes:${remainingSeconds.toString().padLeft(2, '0')}';
  }

  String get _datasetAutoStatusText {
    if (!_isDatasetAutoCapturing) return 'Stopped';
    if (_isDatasetCapturing) return 'Capturing now';
    if (_datasetNextCaptureAt == null) return 'Preparing next capture';
    return 'Next in $_datasetCountdownText';
  }

  String get _datasetGridScopeText {
    final colBounds = _scanColBoundaries;
    final rowBounds = _scanRowBoundaries;
    final mode = _gridSaved ? 'Custom saved' : 'Current custom';
    final width = colBounds.last - colBounds.first;
    final height = rowBounds.last - rowBounds.first;
    return '$mode | ${width.toStringAsFixed(1)} x ${height.toStringAsFixed(1)} cm';
  }

  String get _datasetLabelScopeText {
    if (_datasetUsesSelectedSlotMode) {
      final selectedCount = _datasetSelectedEggSlots.length;
      final label = _datasetUsesCustomEmptySlots ? 'Empty' : 'Egg';
      return '$selectedCount selected $label crop${selectedCount == 1 ? '' : 's'} only';
    }
    return '$_datasetCaptureLabelName applied to all 56 crops';
  }

  bool get _canStartDatasetCapture =>
      !_isDatasetAutoCapturing &&
      !_isDatasetCapturing &&
      !_isIntakeDatasetCapturing &&
      !_isIntakeDatasetAutoCapturing &&
      !_isFertilityDatasetCapturing &&
      !_isFertilityDatasetAutoCapturing &&
      !_demoMode &&
      _isWifiCorrect &&
      (!_datasetUsesSelectedSlotMode || _datasetSelectedEggSlots.isNotEmpty);

  String _datasetMimeTypeForPath(String path) {
    final lower = path.toLowerCase();
    if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) {
      return 'image/jpeg';
    }
    if (lower.endsWith('.json')) return 'application/json';
    if (lower.endsWith('.csv')) return 'text/csv';
    if (lower.endsWith('.zip')) return 'application/zip';
    return 'application/octet-stream';
  }

  Future<Directory> _datasetRootDirectory() async {
    const folderName = 'datasets_AI_eggCounter';

    if (Platform.isAndroid) {
      final downloadsDir = Directory(
        '/storage/emulated/0/Download/$folderName',
      );
      try {
        await downloadsDir.create(recursive: true);
        return downloadsDir;
      } catch (e) {
        debugPrint('Public dataset folder unavailable: $e');
      }
    }

    final docsDir = await getApplicationDocumentsDirectory();
    final fallbackDir = Directory(
      '${docsDir.path}${Platform.pathSeparator}$folderName',
    );
    await fallbackDir.create(recursive: true);
    return fallbackDir;
  }

  int _boundaryToPixel(
    double boundaryCm, {
    required double trayCm,
    required int imagePixels,
  }) {
    return ((boundaryCm / trayCm) * imagePixels)
        .round()
        .clamp(0, imagePixels)
        .toInt();
  }

  _DatasetCropQuality _measureDatasetCropQuality(img.Image crop) {
    const sampleTarget = 28;
    final stepX = math.max(1, (crop.width / sampleTarget).floor());
    final stepY = math.max(1, (crop.height / sampleTarget).floor());
    var totalBrightness = 0.0;
    var brightnessCount = 0;
    var edgeTotal = 0.0;
    var edgeCount = 0;

    for (var y = 0; y < crop.height; y += stepY) {
      double? previousGray;
      for (var x = 0; x < crop.width; x += stepX) {
        final pixel = crop.getPixel(x, y);
        final gray = (0.299 * pixel.r) + (0.587 * pixel.g) + (0.114 * pixel.b);
        totalBrightness += gray;
        brightnessCount++;

        if (previousGray != null) {
          edgeTotal += (gray - previousGray).abs();
          edgeCount++;
        }
        if (y >= stepY) {
          final verticalPixel = crop.getPixel(x, y - stepY);
          final verticalGray =
              (0.299 * verticalPixel.r) +
              (0.587 * verticalPixel.g) +
              (0.114 * verticalPixel.b);
          edgeTotal += (gray - verticalGray).abs();
          edgeCount++;
        }
        previousGray = gray;
      }
    }

    final brightness = brightnessCount == 0
        ? 0.0
        : totalBrightness / brightnessCount;
    final edgeScore = edgeCount == 0 ? 0.0 : edgeTotal / edgeCount;
    final flags = <String>[];
    if (brightness < 28) flags.add('dark');
    if (brightness > 246) flags.add('washed');
    if (edgeScore < 3.8) flags.add('soft');

    return _DatasetCropQuality(
      status: flags.isEmpty ? 'ok' : flags.join('_'),
      brightness: brightness,
      edgeScore: edgeScore,
    );
  }

  _DatasetCropQuality _measureFertilityDatasetCropQuality(img.Image crop) {
    final metrics = _measureDatasetCropQuality(crop);
    // Dark or low-detail interiors are valid candling evidence. The operator
    // reviews every crop before Save All, so do not reject those class traits.
    return _DatasetCropQuality(
      status: 'ok',
      brightness: metrics.brightness,
      edgeScore: metrics.edgeScore,
    );
  }

  Future<void> _writeDatasetCsv(
    File file,
    List<_DatasetCropRecord> records, {
    required bool append,
  }) async {
    final exists = await file.exists();
    final needsHeader =
        !append || !exists || (exists && await file.length() == 0);
    final buffer = StringBuffer();
    if (needsHeader) buffer.writeln(_DatasetCropRecord.csvHeader);
    for (final record in records) {
      buffer.writeln(record.toCsvRow());
    }
    await file.writeAsString(
      buffer.toString(),
      mode: append ? FileMode.append : FileMode.write,
      flush: true,
    );
  }

  Map<String, int> _countDatasetValues(
    List<_DatasetCropRecord> records,
    String Function(_DatasetCropRecord record) selector,
  ) {
    final counts = <String, int>{};
    for (final record in records) {
      final key = selector(record);
      counts[key] = (counts[key] ?? 0) + 1;
    }
    return counts;
  }

  Future<_DatasetBatchResult> _saveDatasetCellCrops({
    required Uint8List sourceBytes,
    required String batchStamp,
    required Directory rootDir,
    required DateTime capturedAt,
  }) async {
    final image = img.decodeImage(sourceBytes);
    if (image == null) throw Exception('Could not decode captured image');

    final colBounds = _scanColBoundaries;
    final rowBounds = _scanRowBoundaries;
    final records = <_DatasetCropRecord>[];
    final previewBytes = <Uint8List>[];
    final previewStatuses = <String>[];
    final previewLabels = <String>[];
    final previewSlotNumbers = <int>[];
    final files = <String>[];
    final labelDirs = <String, Directory>{};
    final sourceDir = Directory(
      '${rootDir.path}${Platform.pathSeparator}_source',
    );
    await sourceDir.create(recursive: true);
    final sourceFile = File(
      '${sourceDir.path}${Platform.pathSeparator}source_$batchStamp.jpg',
    );
    await sourceFile.writeAsBytes(sourceBytes, flush: true);
    files.add(sourceFile.path);

    Future<Directory> labelDirectory(String label) async {
      final folder = _datasetLabelFolderName(label);
      final cached = labelDirs[folder];
      if (cached != null) return cached;
      final dir = Directory('${rootDir.path}${Platform.pathSeparator}$folder');
      await dir.create(recursive: true);
      labelDirs[folder] = dir;
      return dir;
    }

    for (var row = 0; row < gridRows; row++) {
      for (var col = 0; col < gridCols; col++) {
        final slotIndex = (row * gridCols) + col;
        final slotNumber = slotIndex + 1;
        if (_datasetUsesSelectedSlotMode &&
            !_datasetSelectedEggSlots.contains(slotIndex)) {
          continue;
        }
        final label = _datasetActualLabelForSlot(slotIndex);
        final labelFolder = _datasetLabelFolderName(label);
        final labelDir = await labelDirectory(label);
        final left = _boundaryToPixel(
          colBounds[col],
          trayCm: _trayWidthCm,
          imagePixels: image.width,
        );
        final right = _boundaryToPixel(
          colBounds[col + 1],
          trayCm: _trayWidthCm,
          imagePixels: image.width,
        );
        final top = _boundaryToPixel(
          rowBounds[row],
          trayCm: _trayHeightCm,
          imagePixels: image.height,
        );
        final bottom = _boundaryToPixel(
          rowBounds[row + 1],
          trayCm: _trayHeightCm,
          imagePixels: image.height,
        );

        final cropWidth = (right - left).clamp(1, image.width - left).toInt();
        final cropHeight = (bottom - top).clamp(1, image.height - top).toInt();
        final crop = img.copyCrop(
          image,
          x: left,
          y: top,
          width: cropWidth,
          height: cropHeight,
        );
        final quality = _measureDatasetCropQuality(crop);
        final cropBytes = Uint8List.fromList(img.encodeJpg(crop, quality: 95));
        final qualitySuffix = quality.isOk ? '' : '_${quality.status}';
        final fileName =
            '${labelFolder}_${batchStamp}_r${row + 1}_c${col + 1}_s${slotNumber.toString().padLeft(2, '0')}$qualitySuffix.jpg';
        final file = File('${labelDir.path}${Platform.pathSeparator}$fileName');
        await file.writeAsBytes(cropBytes, flush: true);

        final thumb = crop.width >= crop.height
            ? img.copyResize(crop, width: 72)
            : img.copyResize(crop, height: 72);
        previewBytes.add(Uint8List.fromList(img.encodeJpg(thumb, quality: 72)));
        previewStatuses.add(quality.status);
        previewLabels.add(label);
        previewSlotNumbers.add(slotNumber);
        files.add(file.path);

        records.add(
          _DatasetCropRecord(
            batchId: batchStamp,
            timestamp: capturedAt,
            label: label,
            row: row + 1,
            col: col + 1,
            slotNumber: slotNumber,
            filePath: file.path,
            sourcePath: sourceFile.path,
            width: cropWidth,
            height: cropHeight,
            qualityStatus: quality.status,
            brightness: quality.brightness,
            edgeScore: quality.edgeScore,
          ),
        );
      }
    }

    final metadataDir = Directory(
      '${rootDir.path}${Platform.pathSeparator}_metadata',
    );
    await metadataDir.create(recursive: true);
    final batchCsvFile = File(
      '${metadataDir.path}${Platform.pathSeparator}metadata_$batchStamp.csv',
    );
    final globalCsvFile = File(
      '${metadataDir.path}${Platform.pathSeparator}metadata.csv',
    );
    await _writeDatasetCsv(batchCsvFile, records, append: false);
    await _writeDatasetCsv(globalCsvFile, records, append: true);

    final manifestFile = File(
      '${metadataDir.path}${Platform.pathSeparator}manifest_$batchStamp.json',
    );
    final manifest = {
      'batch_id': batchStamp,
      'captured_at': capturedAt.toIso8601String(),
      'capture_mode': _datasetCaptureLabel,
      'capture_mode_name': _datasetCaptureLabelName,
      'labeling': _datasetUsesSelectedSlotMode
          ? _datasetUsesCustomEmptySlots
                ? 'custom_slots_selected_empty_only'
                : 'custom_slots_selected_egg_only'
          : 'manual_single_label',
      'selected_egg_slots': _datasetUsesCustomSlots
          ? (_datasetSelectedEggSlots.toList()..sort())
                .map(
                  (slotIndex) => {
                    'slot_number': slotIndex + 1,
                    'row': (slotIndex ~/ gridCols) + 1,
                    'col': (slotIndex % gridCols) + 1,
                  },
                )
                .toList()
          : const [],
      'selected_empty_slots': _datasetUsesCustomEmptySlots
          ? (_datasetSelectedEggSlots.toList()..sort())
                .map(
                  (slotIndex) => {
                    'slot_number': slotIndex + 1,
                    'row': (slotIndex ~/ gridCols) + 1,
                    'col': (slotIndex % gridCols) + 1,
                  },
                )
                .toList()
          : const [],
      'source_saved': true,
      'source_path': sourceFile.path,
      'root_path': rootDir.path,
      'camera': {
        'device': 'ESP32-S3 camera',
        'endpoint': _datasetCaptureEndpoint,
      },
      'grid': {
        'rows': gridRows,
        'cols': gridCols,
        'cells': gridRows * gridCols,
        'saved_cells': records.length,
        'unselected_cells_saved': !_datasetUsesSelectedSlotMode,
        'col_boundaries_cm': colBounds,
        'row_boundaries_cm': rowBounds,
        'tray_width_cm': _trayWidthCm,
        'tray_height_cm': _trayHeightCm,
        'crop_window_cm': {
          'left': colBounds.first,
          'right': colBounds.last,
          'top': rowBounds.first,
          'bottom': rowBounds.last,
          'width': colBounds.last - colBounds.first,
          'height': rowBounds.last - rowBounds.first,
        },
        'outside_crop_window_saved': false,
      },
      'counts': {
        'total': records.length,
        'by_label': _countDatasetValues(records, (record) => record.label),
        'by_quality': _countDatasetValues(
          records,
          (record) => record.qualityStatus,
        ),
      },
      'records': records.map((record) => record.toJson()).toList(),
    };
    await manifestFile.writeAsString(
      const JsonEncoder.withIndent('  ').convert(manifest),
      flush: true,
    );
    files
      ..add(batchCsvFile.path)
      ..add(manifestFile.path);

    return _DatasetBatchResult(
      records: records,
      previewBytes: previewBytes,
      previewStatuses: previewStatuses,
      previewLabels: previewLabels,
      previewSlotNumbers: previewSlotNumbers,
      files: files,
      manifestPath: manifestFile.path,
      batchCsvPath: batchCsvFile.path,
      warningCount: records
          .where((record) => record.qualityStatus != 'ok')
          .length,
    );
  }

  void _startDatasetAutoCapture() {
    if (_isDatasetAutoCapturing ||
        _isFertilityDatasetCapturing ||
        _isFertilityDatasetAutoCapturing) {
      return;
    }
    if (_demoMode || !_isWifiCorrect) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Connect to the incubator camera before capturing.'),
          duration: Duration(seconds: 3),
        ),
      );
      return;
    }
    if (_datasetUsesSelectedSlotMode && _datasetSelectedEggSlots.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(_datasetSelectSlotSnackText),
          duration: const Duration(seconds: 3),
        ),
      );
      return;
    }

    setState(() {
      _isDatasetAutoCapturing = true;
      _datasetNextCaptureAt = null;
      _datasetNextCaptureSeconds = 0;
      _status = 'Dataset auto capture started';
    });
    _datasetAutoCaptureTimer?.cancel();
    _datasetCountdownTimer?.cancel();
    unawaited(
      _captureDatasetImage().whenComplete(() {
        if (!mounted || !_isDatasetAutoCapturing) return;
        _scheduleNextDatasetAutoCapture();
      }),
    );

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Auto capture started. Capturing every 2 minutes.'),
        duration: Duration(seconds: 3),
      ),
    );
  }

  void _scheduleNextDatasetAutoCapture() {
    if (!_isDatasetAutoCapturing) return;
    final nextCaptureAt = DateTime.now().add(_datasetCaptureInterval);
    _datasetAutoCaptureTimer?.cancel();
    if (mounted) {
      setState(() {
        _datasetNextCaptureAt = nextCaptureAt;
        _datasetNextCaptureSeconds = _datasetCaptureInterval.inSeconds;
      });
    }
    _startDatasetCountdownTimer();
    _datasetAutoCaptureTimer = Timer(_datasetCaptureInterval, () async {
      if (!mounted || !_isDatasetAutoCapturing) return;
      await _captureDatasetImage(showSnack: false);
      if (!mounted || !_isDatasetAutoCapturing) return;
      _scheduleNextDatasetAutoCapture();
    });
  }

  void _startDatasetCountdownTimer() {
    _datasetCountdownTimer?.cancel();
    _updateDatasetCountdown();
    _datasetCountdownTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      _updateDatasetCountdown();
    });
  }

  void _updateDatasetCountdown() {
    if (!mounted || !_isDatasetAutoCapturing || _datasetNextCaptureAt == null) {
      return;
    }
    final seconds = math.max(
      0,
      _datasetNextCaptureAt!.difference(DateTime.now()).inSeconds,
    );
    if (seconds == _datasetNextCaptureSeconds) return;
    setState(() => _datasetNextCaptureSeconds = seconds);
  }

  void _stopDatasetAutoCapture({bool showSnack = true}) {
    _datasetAutoCaptureTimer?.cancel();
    _datasetAutoCaptureTimer = null;
    _datasetCountdownTimer?.cancel();
    _datasetCountdownTimer = null;
    if (!mounted) return;
    if (!_isDatasetAutoCapturing) return;
    setState(() {
      _isDatasetAutoCapturing = false;
      _datasetNextCaptureAt = null;
      _datasetNextCaptureSeconds = 0;
      _status = 'Dataset auto capture stopped';
    });
    if (showSnack) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Auto dataset capture stopped.'),
          duration: Duration(seconds: 3),
        ),
      );
    }
  }

  Future<void> _captureDatasetImage({bool showSnack = true}) async {
    if (_isDatasetCapturing ||
        _isFertilityDatasetCapturing ||
        _isFertilityDatasetAutoCapturing ||
        _isCandling ||
        _isCapturingCalibration) {
      return;
    }
    if (_demoMode || !_isWifiCorrect) {
      if (showSnack) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Connect to the incubator camera before capturing.'),
            duration: Duration(seconds: 3),
          ),
        );
      }
      return;
    }
    if (_datasetUsesSelectedSlotMode && _datasetSelectedEggSlots.isEmpty) {
      if (showSnack) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(_datasetSelectSlotSnackText),
            duration: const Duration(seconds: 3),
          ),
        );
      }
      return;
    }

    _sensorTimer?.cancel();
    setState(() {
      _isStreaming = false;
      _streamKey++;
      _isDatasetCapturing = true;
      _status = 'Capturing dataset image...';
    });

    await Future.delayed(const Duration(milliseconds: 400));
    if (!mounted) return;

    try {
      setState(() => _status = 'Stopping tray for dataset capture...');
      bool captureHoldStarted = false;
      final client = http.Client();
      try {
        await _startP4CaptureHold();
        captureHoldStarted = true;
        if (!mounted) return;
        setState(() => _status = 'Waiting for camera to settle...');
        await Future.delayed(_captureHoldSettleDelay);
        if (!mounted) return;
        setState(() => _status = 'Capturing dataset image...');

        final request = http.Request('GET', _s3Uri(_datasetCaptureEndpoint));
        final response = await client
            .send(request)
            .timeout(
              _cameraCaptureRequestTimeout,
              onTimeout: () => throw TimeoutException('Capture timed out'),
            );
        if (response.statusCode != 200) {
          throw HttpException(
            'Dataset camera capture failed: ${response.statusCode}',
            uri: _s3Uri(_datasetCaptureEndpoint),
          );
        }
        final bytes = await response.stream.toBytes();
        if (bytes.isEmpty) throw Exception('Empty response from camera');

        final capturedAt = DateTime.now();
        final batchStamp = DateFormat('yyyyMMdd_HHmmss_SSS').format(capturedAt);
        final rootDir = await _datasetRootDirectory();
        final batchResult = await _saveDatasetCellCrops(
          sourceBytes: Uint8List.fromList(bytes),
          batchStamp: batchStamp,
          rootDir: rootDir,
          capturedAt: capturedAt,
        );

        if (!mounted) return;
        setState(() {
          _datasetLastImage = Uint8List.fromList(bytes);
          _datasetLastCropPreviews = batchResult.previewBytes;
          _datasetLastCropStatuses = batchResult.previewStatuses;
          _datasetLastCropLabels = batchResult.previewLabels;
          _datasetLastCropSlotNumbers = batchResult.previewSlotNumbers;
          _datasetLastManifestPath = batchResult.manifestPath;
          _datasetLastCsvPath = batchResult.batchCsvPath;
          _datasetRootPath = rootDir.path;
          _datasetLastBatchFiles = batchResult.files;
          _datasetLastBatchCount = batchResult.savedCount;
          _datasetLastQualityWarningCount = batchResult.warningCount;
          _datasetCaptureCount += batchResult.savedCount;
          _isDatasetCapturing = false;
          _status = 'Dataset cell crops saved';
        });
        if (showSnack) {
          final warningText = batchResult.warningCount == 0
              ? ''
              : ' (${batchResult.warningCount} flagged)';
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                'Saved ${batchResult.savedCount} dataset crops$warningText.',
              ),
              duration: const Duration(seconds: 3),
            ),
          );
        }
      } finally {
        client.close();
        if (captureHoldStarted) {
          await _stopP4CaptureHold();
        }
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isDatasetCapturing = false;
        _status = 'Dataset capture failed: $e';
      });
      if (showSnack) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Dataset capture failed: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Future<void> _shareDatasetLastBatch() async {
    final paths = _datasetLastBatchFiles
        .where((path) => File(path).existsSync())
        .toList(growable: false);
    if (paths.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('No dataset batch is ready to share yet.'),
          duration: Duration(seconds: 3),
        ),
      );
      return;
    }

    try {
      await Share.shareXFiles(
        paths
            .map((path) => XFile(path, mimeType: _datasetMimeTypeForPath(path)))
            .toList(growable: false),
        subject: 'Egg dataset batch',
        text: 'Egg-counter dataset batch from $_datasetCaptureLabelName.',
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Dataset share failed: $e'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  String _intakeDatasetLabelName(String label) => switch (label) {
    'normal' => 'NORMAL',
    'abnormal' => 'ABNORMAL',
    _ => 'SKIPPED',
  };

  int _intakeDatasetClassIndex(String label) => switch (label) {
    'normal' => 0,
    'abnormal' => 1,
    _ => throw ArgumentError.value(label, 'label', 'Unknown intake label'),
  };

  String get _intakeDatasetCountdownText {
    final seconds = math.max(0, _intakeDatasetNextCaptureSeconds);
    final minutes = seconds ~/ 60;
    final remainingSeconds = seconds % 60;
    return '$minutes:${remainingSeconds.toString().padLeft(2, '0')}';
  }

  String get _intakeDatasetAutoStatusText {
    if (!_isIntakeDatasetAutoCapturing) return 'Stopped';
    if (_isIntakeDatasetCapturing) return 'Capturing now';
    if (_intakeDatasetNextCaptureAt == null) return 'Preparing next capture';
    return 'Next in $_intakeDatasetCountdownText';
  }

  bool get _canStartIntakeDatasetCapture =>
      !_isIntakeDatasetCapturing &&
      !_isIntakeDatasetAutoCapturing &&
      !_isDatasetCapturing &&
      !_isDatasetAutoCapturing &&
      !_isFertilityDatasetCapturing &&
      !_isFertilityDatasetAutoCapturing &&
      !_isCandling &&
      !_isCapturingCalibration &&
      !_demoMode &&
      _isWifiCorrect &&
      _p4Connected &&
      _intakeDatasetLabels.isNotEmpty;

  String _newIntakeDatasetRunId() {
    final now = DateTime.now();
    return 'run_${DateFormat('yyyyMMdd_HHmmss_SSS').format(now)}';
  }

  String _intakeDatasetEggKey({
    required int slotNumber,
    required DateTime? placedAt,
    required String collectionRunId,
  }) {
    final slot = slotNumber.toString().padLeft(2, '0');
    if (placedAt != null) {
      final placedKey = DateFormat('yyyyMMdd_HHmmss').format(placedAt.toUtc());
      return 'slot_${slot}_$placedKey';
    }
    return '${collectionRunId}_slot_$slot';
  }

  Uri _intakeDatasetCaptureUri(List<int> selectedLeds) => Uri.http(
    _esp32S3Ip,
    _intakeDatasetCaptureEndpoint,
    <String, String>{'led': selectedLeds.join(',')},
  );

  Future<Directory> _intakeDatasetRootDirectory() async {
    const folderName = 'datasets_AI_p4_intake';
    if (Platform.isAndroid) {
      final downloadsDir = Directory(
        '/storage/emulated/0/Download/$folderName',
      );
      try {
        await downloadsDir.create(recursive: true);
        return downloadsDir;
      } catch (e) {
        debugPrint('Public P4 intake dataset folder unavailable: $e');
      }
    }

    final docsDir = await getApplicationDocumentsDirectory();
    final fallbackDir = Directory(
      '${docsDir.path}${Platform.pathSeparator}$folderName',
    );
    await fallbackDir.create(recursive: true);
    return fallbackDir;
  }

  Future<void> _writeIntakeDatasetCsv(
    File file,
    List<_IntakeDatasetCropRecord> records, {
    required bool append,
  }) async {
    final exists = await file.exists();
    final needsHeader =
        !append || !exists || (exists && await file.length() == 0);
    final buffer = StringBuffer();
    if (needsHeader) buffer.writeln(_IntakeDatasetCropRecord.csvHeader);
    for (final record in records) {
      buffer.writeln(record.toCsvRow());
    }
    await file.writeAsString(
      buffer.toString(),
      mode: append ? FileMode.append : FileMode.write,
      flush: true,
    );
  }

  Map<String, int> _countIntakeDatasetValues(
    List<_IntakeDatasetCropRecord> records,
    String Function(_IntakeDatasetCropRecord record) selector,
  ) {
    final counts = <String, int>{};
    for (final record in records) {
      final key = selector(record);
      counts[key] = (counts[key] ?? 0) + 1;
    }
    return counts;
  }

  Future<_IntakeDatasetBatchResult> _saveIntakeDatasetCellCrops({
    required Uint8List sourceBytes,
    required String batchStamp,
    required String collectionRunId,
    required String captureTrigger,
    required Directory rootDir,
    required DateTime capturedAt,
    required Map<int, String> labelsBySlot,
    required List<bool> occupiedSlots,
    required List<DateTime?> slotPlacedAt,
    required List<int?> slotDays,
    required List<double> colBounds,
    required List<double> rowBounds,
    required List<int> selectedLeds,
    required Map<String, dynamic> ledVerification,
    required double? temperature,
    required double? humidity,
  }) async {
    final entries = labelsBySlot.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    if (entries.isEmpty) {
      throw StateError('No labeled intake slots were selected.');
    }
    for (final entry in entries) {
      final slotIndex = entry.key;
      if (slotIndex < 0 ||
          slotIndex >= occupiedSlots.length ||
          !occupiedSlots[slotIndex]) {
        throw StateError(
          'Slot ${slotIndex + 1} is no longer occupied; batch not saved.',
        );
      }
      _intakeDatasetClassIndex(entry.value);
    }

    final image = img.decodeImage(sourceBytes);
    if (image == null) throw Exception('Could not decode intake capture');

    final records = <_IntakeDatasetCropRecord>[];
    final previewBytes = <Uint8List>[];
    final previewStatuses = <String>[];
    final previewLabels = <String>[];
    final previewSlotNumbers = <int>[];
    final files = <String>[];
    final sourceDir = Directory(
      '${rootDir.path}${Platform.pathSeparator}_source',
    );
    final metadataDir = Directory(
      '${rootDir.path}${Platform.pathSeparator}_metadata',
    );
    final normalDir = Directory(
      '${rootDir.path}${Platform.pathSeparator}normal',
    );
    final abnormalDir = Directory(
      '${rootDir.path}${Platform.pathSeparator}abnormal',
    );
    await Future.wait([
      sourceDir.create(recursive: true),
      metadataDir.create(recursive: true),
      normalDir.create(recursive: true),
      abnormalDir.create(recursive: true),
    ]);

    final sourceFile = File(
      '${sourceDir.path}${Platform.pathSeparator}source_$batchStamp.jpg',
    );
    await sourceFile.writeAsBytes(sourceBytes, flush: true);
    files.add(sourceFile.path);

    for (final entry in entries) {
      final slotIndex = entry.key;
      final label = entry.value;
      final classIndex = _intakeDatasetClassIndex(label);
      final row = slotIndex ~/ gridCols;
      final col = slotIndex % gridCols;
      final slotNumber = slotIndex + 1;
      final left = _boundaryToPixel(
        colBounds[col],
        trayCm: _trayWidthCm,
        imagePixels: image.width,
      ).clamp(0, image.width - 1).toInt();
      final right = _boundaryToPixel(
        colBounds[col + 1],
        trayCm: _trayWidthCm,
        imagePixels: image.width,
      ).clamp(left + 1, image.width).toInt();
      final top = _boundaryToPixel(
        rowBounds[row],
        trayCm: _trayHeightCm,
        imagePixels: image.height,
      ).clamp(0, image.height - 1).toInt();
      final bottom = _boundaryToPixel(
        rowBounds[row + 1],
        trayCm: _trayHeightCm,
        imagePixels: image.height,
      ).clamp(top + 1, image.height).toInt();
      final cropWidth = right - left;
      final cropHeight = bottom - top;
      final crop = img.copyCrop(
        image,
        x: left,
        y: top,
        width: cropWidth,
        height: cropHeight,
      );
      final quality = _measureDatasetCropQuality(crop);
      final cropBytes = Uint8List.fromList(img.encodeJpg(crop, quality: 95));
      final qualitySuffix = quality.isOk ? '' : '_${quality.status}';
      final slotText = slotNumber.toString().padLeft(2, '0');
      final fileName =
          '${label}_${batchStamp}_r${row + 1}_c${col + 1}_s$slotText$qualitySuffix.jpg';
      final labelDir = label == 'normal' ? normalDir : abnormalDir;
      final cropFile = File(
        '${labelDir.path}${Platform.pathSeparator}$fileName',
      );
      await cropFile.writeAsBytes(cropBytes, flush: true);

      final placedAt = slotIndex < slotPlacedAt.length
          ? slotPlacedAt[slotIndex]
          : null;
      final incubationDay = slotIndex < slotDays.length
          ? slotDays[slotIndex]
          : null;
      final eggKey = _intakeDatasetEggKey(
        slotNumber: slotNumber,
        placedAt: placedAt,
        collectionRunId: collectionRunId,
      );
      final thumb = crop.width >= crop.height
          ? img.copyResize(crop, width: 72)
          : img.copyResize(crop, height: 72);
      previewBytes.add(Uint8List.fromList(img.encodeJpg(thumb, quality: 72)));
      previewStatuses.add(quality.status);
      previewLabels.add(label);
      previewSlotNumbers.add(slotNumber);
      files.add(cropFile.path);

      records.add(
        _IntakeDatasetCropRecord(
          batchId: batchStamp,
          collectionRunId: collectionRunId,
          eggKey: eggKey,
          timestamp: capturedAt,
          captureTrigger: captureTrigger,
          label: label,
          classIndex: classIndex,
          row: row + 1,
          col: col + 1,
          slotNumber: slotNumber,
          p4Occupied: true,
          placedAt: placedAt,
          incubationDay: incubationDay,
          filePath: cropFile.path,
          sourcePath: sourceFile.path,
          cropLeft: left,
          cropTop: top,
          cropRight: right,
          cropBottom: bottom,
          width: cropWidth,
          height: cropHeight,
          qualityStatus: quality.status,
          brightness: quality.brightness,
          edgeScore: quality.edgeScore,
          selectedLeds: selectedLeds,
          ledsVerified: ledVerification['verified'] == true,
        ),
      );
    }

    final batchCsvFile = File(
      '${metadataDir.path}${Platform.pathSeparator}metadata_$batchStamp.csv',
    );
    final globalCsvFile = File(
      '${metadataDir.path}${Platform.pathSeparator}metadata.csv',
    );
    await _writeIntakeDatasetCsv(batchCsvFile, records, append: false);
    await _writeIntakeDatasetCsv(globalCsvFile, records, append: true);

    final manifestFile = File(
      '${metadataDir.path}${Platform.pathSeparator}manifest_$batchStamp.json',
    );
    final manifest = <String, dynamic>{
      'schema': 'p4_intake_dataset_v1',
      'batch_id': batchStamp,
      'collection_run_id': collectionRunId,
      'captured_at': capturedAt.toIso8601String(),
      'capture_trigger': captureTrigger,
      'root_path': rootDir.path,
      'source_path': sourceFile.path,
      'source_saved': true,
      'label_contract': {
        'normal': 0,
        'abnormal': 1,
        'farmer_facing': ['NORMAL', 'ABNORMAL'],
      },
      'identity': {
        'egg_key': 'slot plus P4 placed_at; run plus slot fallback',
        'collection_run_stable_across_timer_captures': true,
      },
      'camera': {
        'device': 'ESP32-S3 camera',
        'endpoint': _intakeDatasetCaptureEndpoint,
        'selected_led_query': selectedLeds.join(','),
        'settle_ms': _intakeCandlingSettleDelay.inMilliseconds,
      },
      'led_verification': ledVerification,
      'p4': {
        'connected': _p4Connected,
        'time_trusted': _p4TimeTrusted,
        'last_scan_epoch': _lastAcceptedP4ScanEpoch,
        'occupied_slots': [
          for (var index = 0; index < occupiedSlots.length; index++)
            if (occupiedSlots[index]) index + 1,
        ],
      },
      'environment': {
        'temperature_c': temperature,
        'humidity_percent': humidity,
      },
      'grid': {
        'rows': gridRows,
        'cols': gridCols,
        'col_boundaries_cm': colBounds,
        'row_boundaries_cm': rowBounds,
        'tray_width_cm': _trayWidthCm,
        'tray_height_cm': _trayHeightCm,
      },
      'training': {
        'stored_crop': 'raw_grid_crop',
        'target_model_input': '160x160 INT8',
        'resize_deferred_to_training': true,
        'quality_flags_are_diagnostic_only': true,
      },
      'counts': {
        'total': records.length,
        'by_label': _countIntakeDatasetValues(
          records,
          (record) => record.label,
        ),
        'by_quality': _countIntakeDatasetValues(
          records,
          (record) => record.qualityStatus,
        ),
      },
      'records': records.map((record) => record.toJson()).toList(),
    };
    await manifestFile.writeAsString(
      const JsonEncoder.withIndent('  ').convert(manifest),
      flush: true,
    );
    files
      ..add(batchCsvFile.path)
      ..add(manifestFile.path);

    return _IntakeDatasetBatchResult(
      records: records,
      previewBytes: previewBytes,
      previewStatuses: previewStatuses,
      previewLabels: previewLabels,
      previewSlotNumbers: previewSlotNumbers,
      files: files,
      manifestPath: manifestFile.path,
      batchCsvPath: batchCsvFile.path,
      warningCount: records
          .where((record) => record.qualityStatus != 'ok')
          .length,
    );
  }

  void _toggleIntakeDatasetLabel(int slotIndex) {
    if (_isIntakeDatasetCapturing || _isIntakeDatasetAutoCapturing) return;
    final occupied =
        slotIndex >= 0 &&
        slotIndex < _p4SlotHasEgg.length &&
        _p4SlotHasEgg[slotIndex];
    final current = _intakeDatasetLabels[slotIndex];
    if (!occupied) {
      if (current != null) {
        setState(() => _intakeDatasetLabels.remove(slotIndex));
      }
      return;
    }
    setState(() {
      switch (current) {
        case null:
          _intakeDatasetLabels[slotIndex] = 'normal';
        case 'normal':
          _intakeDatasetLabels[slotIndex] = 'abnormal';
        default:
          _intakeDatasetLabels.remove(slotIndex);
      }
    });
  }

  void _setAllOccupiedIntakeSlotsNormal() {
    if (_isIntakeDatasetCapturing || _isIntakeDatasetAutoCapturing) return;
    setState(() {
      _intakeDatasetLabels
        ..clear()
        ..addEntries(<MapEntry<int, String>>[
          for (var index = 0; index < _p4SlotHasEgg.length; index++)
            if (_p4SlotHasEgg[index]) MapEntry(index, 'normal'),
        ]);
    });
  }

  void _clearIntakeDatasetLabels() {
    if (_isIntakeDatasetCapturing || _isIntakeDatasetAutoCapturing) return;
    setState(_intakeDatasetLabels.clear);
  }

  Future<void> _refreshIntakeDatasetOccupancy() async {
    if (_isIntakeDatasetCapturing || _isIntakeDatasetAutoCapturing) return;
    if (mounted) {
      setState(() => _status = 'Refreshing P4 occupied slots...');
    }
    final refreshed = await _refreshEggGridFromP4();
    if (!mounted) return;
    if (!refreshed) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('P4 occupancy refresh failed or is not verified.'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  void _restoreIntakeDatasetServices({
    required bool wasStreaming,
    required bool wasStreamManuallyOff,
  }) {
    if (!mounted) return;
    setState(() {
      _isStreaming = wasStreaming;
      _streamManuallyOff = wasStreamManuallyOff;
      _streamFrameReceived = false;
      if (wasStreaming) _streamKey++;
    });
    _startSensorPolling();
    _startPeriodicP4Sync();
  }

  Future<bool> _captureIntakeDatasetImage({
    required String captureTrigger,
    bool showSnack = true,
  }) async {
    final autoCapture = captureTrigger == 'auto_2_minute';

    void stopAutoBeforeCapture(String message) {
      if (!autoCapture || !_isIntakeDatasetAutoCapturing) return;
      _stopIntakeDatasetAutoCapture(showSnack: false);
      if (mounted) setState(() => _status = message);
    }

    if (_isIntakeDatasetCapturing ||
        _isDatasetCapturing ||
        _isDatasetAutoCapturing ||
        _isFertilityDatasetCapturing ||
        _isFertilityDatasetAutoCapturing ||
        _isCandling ||
        _isCapturingCalibration) {
      stopAutoBeforeCapture('P4 intake auto capture stopped: hardware busy');
      return false;
    }
    if (_demoMode || !_isWifiCorrect || !_p4Connected) {
      stopAutoBeforeCapture(
        'P4 intake auto capture stopped: S3 or P4 disconnected',
      );
      if (showSnack && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Connect the S3 camera and P4 before capturing.'),
            duration: Duration(seconds: 3),
          ),
        );
      }
      return false;
    }

    final labelsSnapshot = Map<int, String>.from(
      _intakeDatasetLockedLabels ?? _intakeDatasetLabels,
    );
    if (labelsSnapshot.isEmpty) {
      stopAutoBeforeCapture('P4 intake auto capture stopped: no labeled slots');
      if (showSnack && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Label at least one occupied P4 slot first.'),
            duration: Duration(seconds: 3),
          ),
        );
      }
      return false;
    }
    for (final label in labelsSnapshot.values) {
      _intakeDatasetClassIndex(label);
    }

    final collectionRunId = autoCapture
        ? (_intakeDatasetCollectionRunId ?? _newIntakeDatasetRunId())
        : _newIntakeDatasetRunId();
    final wasStreaming = _isStreaming;
    final wasStreamManuallyOff = _streamManuallyOff;
    _sensorTimer?.cancel();
    _p4PollTimer?.cancel();
    if (mounted) {
      setState(() {
        _intakeDatasetCollectionRunId = collectionRunId;
        _isStreaming = false;
        _streamFrameReceived = false;
        _streamKey++;
        _isIntakeDatasetCapturing = true;
        _status = 'Refreshing P4 occupancy for intake capture...';
      });
    }

    await Future.delayed(const Duration(milliseconds: 400));
    try {
      final p4SyncSucceeded = await _refreshEggGridFromP4();
      if (!p4SyncSucceeded) {
        throw StateError('Could not verify current occupied slots from P4.');
      }

      final invalidSlots =
          labelsSnapshot.keys
              .where(
                (slotIndex) =>
                    slotIndex < 0 ||
                    slotIndex >= _p4SlotHasEgg.length ||
                    !_p4SlotHasEgg[slotIndex],
              )
              .map((slotIndex) => slotIndex + 1)
              .toList()
            ..sort();
      if (invalidSlots.isNotEmpty) {
        throw StateError(
          'Labeled slot occupancy changed: ${invalidSlots.join(', ')}. '
          'Auto capture stopped without saving a partial batch.',
        );
      }

      final occupiedSnapshot = List<bool>.from(_p4SlotHasEgg);
      final placedAtSnapshot = List<DateTime?>.from(_p4SlotPlacedAt);
      final daySnapshot = List<int?>.generate(
        _activeGridCellCount,
        _slotDay,
        growable: false,
      );
      final colBoundsSnapshot = List<double>.from(_scanColBoundaries);
      final rowBoundsSnapshot = List<double>.from(_scanRowBoundaries);
      final temperatureSnapshot = _temperature;
      final humiditySnapshot = _humidity;
      final selectedLeds =
          labelsSnapshot.keys.map((index) => index + 1).toList()..sort();

      if (mounted) {
        setState(
          () => _status =
              'Tray stopped, bulb off, activating ${selectedLeds.length} LEDs...',
        );
      }

      late Uint8List sourceBytes;
      late DateTime capturedAt;
      late Map<String, dynamic> ledVerification;
      var hardwareTouched = false;
      try {
        hardwareTouched = true;
        await _startP4IntakeCandlingHardware(selectedLeds);
        ledVerification = await _verifyIntakeSelectedLeds(selectedLeds);
        if (mounted) {
          setState(() => _status = 'Candling LEDs verified; stabilizing...');
        }
        await Future.delayed(_intakeCandlingSettleDelay);

        final captureUri = _intakeDatasetCaptureUri(selectedLeds);
        if (mounted) {
          setState(() => _status = 'Downloading P4 intake capture...');
        }
        capturedAt = DateTime.now();
        final client = http.Client();
        try {
          final request = http.Request('GET', captureUri);
          final response = await client
              .send(request)
              .timeout(
                _cameraCaptureRequestTimeout,
                onTimeout: () => throw TimeoutException('Capture timed out'),
              );
          if (response.statusCode != 200) {
            throw HttpException(
              'Intake camera capture failed: ${response.statusCode}',
              uri: captureUri,
            );
          }
          final bytes = await response.stream.toBytes().timeout(
            _cameraCaptureRequestTimeout,
          );
          if (bytes.isEmpty) throw Exception('Empty response from camera');
          sourceBytes = Uint8List.fromList(bytes);
        } finally {
          client.close();
        }
      } finally {
        if (hardwareTouched) {
          await _restoreCandlingHardware();
        }
      }

      if (mounted) {
        setState(() => _status = 'Saving P4 intake dataset batch...');
      }
      final batchStamp = DateFormat('yyyyMMdd_HHmmss_SSS').format(capturedAt);
      final rootDir = await _intakeDatasetRootDirectory();
      final batchResult = await _saveIntakeDatasetCellCrops(
        sourceBytes: sourceBytes,
        batchStamp: batchStamp,
        collectionRunId: collectionRunId,
        captureTrigger: captureTrigger,
        rootDir: rootDir,
        capturedAt: capturedAt,
        labelsBySlot: labelsSnapshot,
        occupiedSlots: occupiedSnapshot,
        slotPlacedAt: placedAtSnapshot,
        slotDays: daySnapshot,
        colBounds: colBoundsSnapshot,
        rowBounds: rowBoundsSnapshot,
        selectedLeds: selectedLeds,
        ledVerification: ledVerification,
        temperature: temperatureSnapshot,
        humidity: humiditySnapshot,
      );

      if (mounted) {
        setState(() {
          _intakeDatasetLastImage = sourceBytes;
          _intakeDatasetLastCropPreviews = batchResult.previewBytes;
          _intakeDatasetLastCropStatuses = batchResult.previewStatuses;
          _intakeDatasetLastCropLabels = batchResult.previewLabels;
          _intakeDatasetLastCropSlotNumbers = batchResult.previewSlotNumbers;
          _intakeDatasetLastManifestPath = batchResult.manifestPath;
          _intakeDatasetLastCsvPath = batchResult.batchCsvPath;
          _intakeDatasetRootPath = rootDir.path;
          _intakeDatasetLastBatchFiles = batchResult.files;
          _intakeDatasetLastBatchCount = batchResult.savedCount;
          _intakeDatasetLastQualityWarningCount = batchResult.warningCount;
          _intakeDatasetCaptureCount += batchResult.savedCount;
          _status = 'P4 intake crops saved';
        });
        if (showSnack) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                'Saved ${batchResult.savedCount} P4 intake crops in run $collectionRunId.',
              ),
              duration: const Duration(seconds: 4),
            ),
          );
        }
      }
      return true;
    } catch (e) {
      final stopAuto = _isIntakeDatasetAutoCapturing;
      if (stopAuto) {
        _stopIntakeDatasetAutoCapture(showSnack: false);
      }
      if (mounted) {
        setState(() {
          _status = stopAuto
              ? 'P4 intake auto capture stopped: $e'
              : 'P4 intake capture failed: $e';
        });
        if (showSnack || stopAuto) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                stopAuto
                    ? 'Auto capture stopped after an error: $e'
                    : 'P4 intake capture failed: $e',
              ),
              backgroundColor: Colors.red,
              duration: const Duration(seconds: 5),
            ),
          );
        }
      }
      return false;
    } finally {
      if (mounted) {
        setState(() => _isIntakeDatasetCapturing = false);
      }
      _restoreIntakeDatasetServices(
        wasStreaming: wasStreaming,
        wasStreamManuallyOff: wasStreamManuallyOff,
      );
    }
  }

  void _startIntakeDatasetAutoCapture() {
    if (_isIntakeDatasetAutoCapturing || !_canStartIntakeDatasetCapture) {
      return;
    }
    final lockedLabels = Map<int, String>.from(_intakeDatasetLabels);
    final runId = _newIntakeDatasetRunId();
    setState(() {
      _isIntakeDatasetAutoCapturing = true;
      _intakeDatasetLockedLabels = Map<int, String>.unmodifiable(lockedLabels);
      _intakeDatasetCollectionRunId = runId;
      _intakeDatasetNextCaptureAt = null;
      _intakeDatasetNextCaptureSeconds = 0;
      _status = 'P4 intake auto capture started';
    });
    _intakeDatasetAutoCaptureTimer?.cancel();
    _intakeDatasetCountdownTimer?.cancel();
    unawaited(() async {
      final saved = await _captureIntakeDatasetImage(
        captureTrigger: 'auto_2_minute',
        showSnack: false,
      );
      if (!mounted || !_isIntakeDatasetAutoCapturing || !saved) return;
      _scheduleNextIntakeDatasetAutoCapture();
    }());
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('P4 intake auto capture started. First capture is now.'),
        duration: Duration(seconds: 3),
      ),
    );
  }

  void _scheduleNextIntakeDatasetAutoCapture() {
    if (!_isIntakeDatasetAutoCapturing) return;
    final nextCaptureAt = DateTime.now().add(_datasetCaptureInterval);
    _intakeDatasetAutoCaptureTimer?.cancel();
    if (mounted) {
      setState(() {
        _intakeDatasetNextCaptureAt = nextCaptureAt;
        _intakeDatasetNextCaptureSeconds = _datasetCaptureInterval.inSeconds;
      });
    }
    _startIntakeDatasetCountdownTimer();
    _intakeDatasetAutoCaptureTimer = Timer(_datasetCaptureInterval, () async {
      if (!mounted || !_isIntakeDatasetAutoCapturing) return;
      _intakeDatasetCountdownTimer?.cancel();
      _intakeDatasetCountdownTimer = null;
      final saved = await _captureIntakeDatasetImage(
        captureTrigger: 'auto_2_minute',
        showSnack: false,
      );
      if (!mounted || !_isIntakeDatasetAutoCapturing || !saved) return;
      _scheduleNextIntakeDatasetAutoCapture();
    });
  }

  void _startIntakeDatasetCountdownTimer() {
    _intakeDatasetCountdownTimer?.cancel();
    _updateIntakeDatasetCountdown();
    _intakeDatasetCountdownTimer = Timer.periodic(
      const Duration(seconds: 1),
      (_) => _updateIntakeDatasetCountdown(),
    );
  }

  void _updateIntakeDatasetCountdown() {
    if (!mounted ||
        !_isIntakeDatasetAutoCapturing ||
        _intakeDatasetNextCaptureAt == null) {
      return;
    }
    final seconds = math.max(
      0,
      _intakeDatasetNextCaptureAt!.difference(DateTime.now()).inSeconds,
    );
    if (seconds == _intakeDatasetNextCaptureSeconds) return;
    setState(() => _intakeDatasetNextCaptureSeconds = seconds);
  }

  void _stopIntakeDatasetAutoCapture({bool showSnack = true}) {
    _intakeDatasetAutoCaptureTimer?.cancel();
    _intakeDatasetAutoCaptureTimer = null;
    _intakeDatasetCountdownTimer?.cancel();
    _intakeDatasetCountdownTimer = null;
    final wasActive = _isIntakeDatasetAutoCapturing;
    if (mounted) {
      setState(() {
        _isIntakeDatasetAutoCapturing = false;
        _intakeDatasetLockedLabels = null;
        _intakeDatasetNextCaptureAt = null;
        _intakeDatasetNextCaptureSeconds = 0;
        if (wasActive) _status = 'P4 intake auto capture stopped';
      });
      if (showSnack && wasActive) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('P4 intake auto capture stopped.'),
            duration: Duration(seconds: 3),
          ),
        );
      }
    }
  }

  Future<void> _shareIntakeDatasetLastBatch() async {
    final paths = _intakeDatasetLastBatchFiles
        .where((path) => File(path).existsSync())
        .toList(growable: false);
    if (paths.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('No P4 intake dataset batch is ready to share yet.'),
          duration: Duration(seconds: 3),
        ),
      );
      return;
    }
    try {
      await Share.shareXFiles(
        paths
            .map((path) => XFile(path, mimeType: _datasetMimeTypeForPath(path)))
            .toList(growable: false),
        subject: 'P4 intake dataset batch',
        text: 'NORMAL/ABNORMAL P4 intake dataset batch.',
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('P4 intake dataset share failed: $e'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  String _fertilityDatasetLabelName(String label) {
    return switch (label) {
      'fertile' => 'Fertile',
      'infertile' => 'Infertile',
      'pending' => 'Pending label',
      'pending_outcome' => 'Pending validated outcome',
      _ => throw ArgumentError.value(label, 'label', 'Unknown fertility label'),
    };
  }

  String _fertilityDatasetLabelFolderName(String label) {
    return switch (label) {
      'fertile' => 'fertile',
      'infertile' => 'infertile',
      'pending_outcome' => '_pending_outcome',
      _ => throw ArgumentError.value(label, 'label', 'Unknown fertility label'),
    };
  }

  String _fertilityDatasetVerificationName(String verification) {
    return switch (verification) {
      'operator_candling_review' => 'Operator labeled per crop',
      'post_hatch_outcome_pending' => 'Pending validated outcome',
      _ => 'Pending outcome',
    };
  }

  Color _fertilityDatasetLabelColor(String label) {
    return switch (label) {
      'fertile' => const Color(0xFF00A86B),
      'infertile' => const Color(0xFFFF5252),
      'pending' => const Color(0xFFFF9800),
      'pending_outcome' => const Color(0xFFFF9800),
      _ => _appOutlineColor(context),
    };
  }

  bool get _canStartFertilityDatasetCapture =>
      !_isFertilityDatasetCapturing &&
      !_isDatasetCapturing &&
      !_isDatasetAutoCapturing &&
      !_isIntakeDatasetCapturing &&
      !_isIntakeDatasetAutoCapturing &&
      !_isFertilityDatasetAutoCapturing &&
      !_isCandling &&
      !_isCapturingCalibration &&
      !_isFertilityDatasetSaving &&
      _pendingFertilityDatasetBatch == null &&
      !_demoMode &&
      _isWifiCorrect &&
      _p4Connected;

  String _newFertilityDatasetRunId() {
    final now = DateTime.now();
    return 'fertility_run_${DateFormat('yyyyMMdd_HHmmss_SSS').format(now)}';
  }

  String get _fertilityDatasetCountdownText {
    final seconds = math.max(0, _fertilityDatasetNextCaptureSeconds);
    final minutes = seconds ~/ 60;
    final remainingSeconds = seconds % 60;
    return '${minutes.toString().padLeft(2, '0')}:'
        '${remainingSeconds.toString().padLeft(2, '0')}';
  }

  bool get _canStartFertilityDatasetAutoCapture =>
      !_isFertilityDatasetAutoCapturing &&
      !_isFertilityDatasetCapturing &&
      !_isFertilityDatasetSaving &&
      _pendingFertilityDatasetBatch == null &&
      _fertilityDatasetLockedLabels?.isNotEmpty == true &&
      _fertilityDatasetLockedPlacedAtEpochMs?.isNotEmpty == true &&
      _fertilityDatasetCollectionRunId != null &&
      _fertilityDatasetCompletedViewCount > 0 &&
      _fertilityDatasetCompletedViewCount < _fertilityDatasetTargetViews &&
      !_demoMode &&
      _isWifiCorrect &&
      _p4Connected;

  Future<Directory> _fertilityDatasetRootDirectory() async {
    const folderName = 'datasets_AI_fertility';

    if (Platform.isAndroid) {
      final downloadsDir = Directory(
        '/storage/emulated/0/Download/$folderName',
      );
      try {
        await downloadsDir.create(recursive: true);
        return downloadsDir;
      } catch (e) {
        debugPrint('Public fertility dataset folder unavailable: $e');
      }
    }

    final docsDir = await getApplicationDocumentsDirectory();
    final fallbackDir = Directory(
      '${docsDir.path}${Platform.pathSeparator}$folderName',
    );
    await fallbackDir.create(recursive: true);
    return fallbackDir;
  }

  Future<String> _writeFertilityDatasetRunArchive({
    required Directory rootDir,
    required String collectionRunId,
    required List<String> files,
  }) async {
    final uniquePaths = files.toSet().toList(growable: false);
    if (uniquePaths.isEmpty) {
      throw const FileSystemException(
        'Cannot create an empty fertility collection ZIP.',
      );
    }

    final archive = Archive();
    final rootPrefix = '${rootDir.path}${Platform.pathSeparator}';
    for (final path in uniquePaths) {
      final file = File(path);
      if (!await file.exists()) {
        throw FileSystemException('Collection export file is missing.', path);
      }
      final bytes = await file.readAsBytes();
      if (bytes.isEmpty) {
        throw FileSystemException('Collection export file is empty.', path);
      }
      final relativePath = path.startsWith(rootPrefix)
          ? path.substring(rootPrefix.length)
          : file.uri.pathSegments.last;
      archive.addFile(
        ArchiveFile(
          relativePath.replaceAll(Platform.pathSeparator, '/'),
          bytes.length,
          bytes,
        ),
      );
    }

    final exportDir = Directory(
      '${rootDir.path}${Platform.pathSeparator}_exports',
    );
    await exportDir.create(recursive: true);
    final archiveFile = File(
      '${exportDir.path}${Platform.pathSeparator}$collectionRunId.zip',
    );
    await archiveFile.writeAsBytes(
      ZipEncoder().encodeBytes(archive),
      flush: true,
    );
    if (!await archiveFile.exists() || await archiveFile.length() == 0) {
      throw FileSystemException(
        'Fertility collection ZIP verification failed.',
        archiveFile.path,
      );
    }
    return archiveFile.path;
  }

  Future<void> _writeFertilityDatasetCsv(
    File file,
    List<_FertilityDatasetCropRecord> records, {
    required bool append,
  }) async {
    final exists = await file.exists();
    final needsHeader =
        !append || !exists || (exists && await file.length() == 0);
    final buffer = StringBuffer();
    if (needsHeader) {
      buffer.writeln(_FertilityDatasetCropRecord.csvHeader);
    }
    for (final record in records) {
      buffer.writeln(record.toCsvRow());
    }
    await file.writeAsString(
      buffer.toString(),
      mode: append ? FileMode.append : FileMode.write,
      flush: true,
    );
  }

  Map<String, int> _countFertilityDatasetValues(
    List<_FertilityDatasetCropRecord> records,
    String Function(_FertilityDatasetCropRecord record) selector,
  ) {
    final counts = <String, int>{};
    for (final record in records) {
      final key = selector(record);
      counts[key] = (counts[key] ?? 0) + 1;
    }
    return counts;
  }

  String _fertilityDatasetEggId({
    required int slotNumber,
    required DateTime? placedAt,
    required String batchStamp,
  }) {
    final slot = slotNumber.toString().padLeft(2, '0');
    if (placedAt == null) return 'slot_${slot}_unknown_$batchStamp';
    return 'slot_${slot}_${placedAt.toUtc().millisecondsSinceEpoch}';
  }

  _PendingFertilityDatasetBatch _prepareFertilityDatasetBatch({
    required Uint8List sourceBytes,
    required String batchStamp,
    required String collectionRunId,
    required String captureTrigger,
    required int viewIndex,
    required DateTime capturedAt,
    required List<int> selectedSlots,
    required List<bool> occupiedSlots,
    required List<int?> slotDays,
    required List<DateTime?> slotPlacedAt,
    required List<bool> slotPlacedAtConfirmed,
    required int? p4EggDay,
    required List<double> colBounds,
    required List<double> rowBounds,
    required bool p4Connected,
    required Map<String, dynamic> ledVerification,
    required double? temperature,
    required double? humidity,
  }) {
    final image = img.decodeImage(sourceBytes);
    if (image == null) throw Exception('Could not decode captured image');

    final sortedSlots = selectedSlots.toSet().toList()..sort();
    if (sortedSlots.isEmpty) {
      throw StateError('No occupied P4 slots were selected for labeling.');
    }

    final previewBytes = <Uint8List>[];
    final previewStatuses = <String>[];
    final previewSlotNumbers = <int>[];
    for (final slotIndex in sortedSlots) {
      if (slotIndex < 0 || slotIndex >= gridRows * gridCols) {
        throw StateError('Invalid fertility dataset slot ${slotIndex + 1}.');
      }
      if (slotIndex >= occupiedSlots.length || !occupiedSlots[slotIndex]) {
        throw StateError(
          'Slot ${slotIndex + 1} changed after occupancy was checked. '
          'Refresh P4 and capture again.',
        );
      }

      final placedAt = slotIndex < slotPlacedAt.length
          ? slotPlacedAt[slotIndex]
          : null;
      if (placedAt == null || capturedAt.isBefore(placedAt)) {
        throw StateError(
          'Slot ${slotIndex + 1} has no usable Date Placed timestamp.',
        );
      }
      final incubationDay = capturedAt.difference(placedAt).inHours ~/ 24;
      if (incubationDay < _fertilityDatasetMinDay ||
          incubationDay > _fertilityDatasetMaxDay) {
        throw StateError(
          'Slot ${slotIndex + 1} changed outside the Day '
          '$_fertilityDatasetMinDay-$_fertilityDatasetMaxDay collection window.',
        );
      }

      final row = slotIndex ~/ gridCols;
      final col = slotIndex % gridCols;
      final left = _boundaryToPixel(
        colBounds[col],
        trayCm: _trayWidthCm,
        imagePixels: image.width,
      );
      final right = _boundaryToPixel(
        colBounds[col + 1],
        trayCm: _trayWidthCm,
        imagePixels: image.width,
      );
      final top = _boundaryToPixel(
        rowBounds[row],
        trayCm: _trayHeightCm,
        imagePixels: image.height,
      );
      final bottom = _boundaryToPixel(
        rowBounds[row + 1],
        trayCm: _trayHeightCm,
        imagePixels: image.height,
      );
      final crop = img.copyCrop(
        image,
        x: left,
        y: top,
        width: (right - left).clamp(1, image.width - left).toInt(),
        height: (bottom - top).clamp(1, image.height - top).toInt(),
      );
      final quality = _measureFertilityDatasetCropQuality(crop);
      final thumb = crop.width >= crop.height
          ? img.copyResize(crop, width: 96)
          : img.copyResize(crop, height: 96);
      previewBytes.add(Uint8List.fromList(img.encodeJpg(thumb, quality: 78)));
      previewStatuses.add(quality.status);
      previewSlotNumbers.add(slotIndex + 1);
    }

    return _PendingFertilityDatasetBatch(
      sourceBytes: sourceBytes,
      batchStamp: batchStamp,
      collectionRunId: collectionRunId,
      captureTrigger: captureTrigger,
      viewIndex: viewIndex,
      capturedAt: capturedAt,
      selectedSlots: List<int>.unmodifiable(sortedSlots),
      occupiedSlots: List<bool>.unmodifiable(occupiedSlots),
      slotDays: List<int?>.unmodifiable(slotDays),
      slotPlacedAt: List<DateTime?>.unmodifiable(slotPlacedAt),
      slotPlacedAtConfirmed: List<bool>.unmodifiable(slotPlacedAtConfirmed),
      p4EggDay: p4EggDay,
      colBounds: List<double>.unmodifiable(colBounds),
      rowBounds: List<double>.unmodifiable(rowBounds),
      p4Connected: p4Connected,
      ledVerification: Map<String, dynamic>.unmodifiable(ledVerification),
      temperature: temperature,
      humidity: humidity,
      previewBytes: List<Uint8List>.unmodifiable(previewBytes),
      previewStatuses: List<String>.unmodifiable(previewStatuses),
      previewSlotNumbers: List<int>.unmodifiable(previewSlotNumbers),
    );
  }

  Future<_FertilityDatasetBatchResult> _saveFertilityDatasetCellCrops({
    required _PendingFertilityDatasetBatch batch,
    required Directory rootDir,
    required Map<int, String> labelsBySlot,
  }) async {
    final sourceBytes = batch.sourceBytes;
    final batchStamp = batch.batchStamp;
    final collectionRunId = batch.collectionRunId;
    final captureTrigger = batch.captureTrigger;
    final viewIndex = batch.viewIndex;
    final viewToken = 'view_${viewIndex.toString().padLeft(2, '0')}';
    final capturedAt = batch.capturedAt;
    final selectedSlots = batch.selectedSlots;
    final verification = _fertilityDatasetVerification;
    final occupiedSlots = batch.occupiedSlots;
    final slotDays = batch.slotDays;
    final slotPlacedAt = batch.slotPlacedAt;
    final slotPlacedAtConfirmed = batch.slotPlacedAtConfirmed;
    final p4EggDay = batch.p4EggDay;
    final colBounds = batch.colBounds;
    final rowBounds = batch.rowBounds;
    final p4Connected = batch.p4Connected;
    final ledVerification = batch.ledVerification;
    final temperature = batch.temperature;
    final humidity = batch.humidity;
    final image = img.decodeImage(sourceBytes);
    if (image == null) throw Exception('Could not decode captured image');

    final sortedSlots = selectedSlots.toSet().toList()..sort();
    if (sortedSlots.isEmpty) {
      throw StateError('No occupied P4 slots were selected for saving.');
    }
    for (final slotIndex in sortedSlots) {
      if (slotIndex < 0 || slotIndex >= gridRows * gridCols) {
        throw StateError('Invalid fertility dataset slot ${slotIndex + 1}.');
      }
      final occupied =
          slotIndex < occupiedSlots.length && occupiedSlots[slotIndex];
      if (!occupied) {
        throw StateError(
          'Slot ${slotIndex + 1} changed after occupancy was checked. '
          'Refresh P4 and capture again.',
        );
      }
      final label = labelsBySlot[slotIndex];
      if (label != 'fertile' && label != 'infertile') {
        throw StateError(
          'Slot ${slotIndex + 1} must be labeled Fertile or Infertile.',
        );
      }
    }

    final records = <_FertilityDatasetCropRecord>[];
    final previewBytes = <Uint8List>[];
    final previewStatuses = <String>[];
    final previewLabels = <String>[];
    final previewSlotNumbers = <int>[];
    final files = <String>[];
    final labelDirs = <String, Directory>{};
    final sourceDir = Directory(
      '${rootDir.path}${Platform.pathSeparator}_source'
      '${Platform.pathSeparator}$collectionRunId'
      '${Platform.pathSeparator}$viewToken',
    );
    await sourceDir.create(recursive: true);
    final sourceFile = File(
      '${sourceDir.path}${Platform.pathSeparator}source_$batchStamp.jpg',
    );
    await sourceFile.writeAsBytes(sourceBytes, flush: true);
    files.add(sourceFile.path);

    Future<Directory> cropDirectory(
      String label, {
      required bool trainingEligible,
      required int incubationDay,
      required String eggId,
    }) async {
      final classFolder = _fertilityDatasetLabelFolderName(label);
      final dayFolder = 'day_${incubationDay.toString().padLeft(2, '0')}';
      final folder = trainingEligible
          ? '$classFolder${Platform.pathSeparator}$dayFolder'
                '${Platform.pathSeparator}$eggId${Platform.pathSeparator}$viewToken'
          : '_quality_review${Platform.pathSeparator}$classFolder'
                '${Platform.pathSeparator}$dayFolder${Platform.pathSeparator}$eggId'
                '${Platform.pathSeparator}$viewToken';
      final cached = labelDirs[folder];
      if (cached != null) return cached;
      final dir = Directory('${rootDir.path}${Platform.pathSeparator}$folder');
      await dir.create(recursive: true);
      labelDirs[folder] = dir;
      return dir;
    }

    for (final slotIndex in sortedSlots) {
      final label = labelsBySlot[slotIndex]!;
      final row = slotIndex ~/ gridCols;
      final col = slotIndex % gridCols;
      final slotNumber = slotIndex + 1;
      final p4HasEgg = slotIndex < occupiedSlots.length
          ? occupiedSlots[slotIndex]
          : false;
      final placedAt = slotIndex < slotPlacedAt.length
          ? slotPlacedAt[slotIndex]
          : null;
      final placedAtConfirmed =
          slotIndex < slotPlacedAtConfirmed.length &&
          slotPlacedAtConfirmed[slotIndex];
      if (placedAt == null || capturedAt.isBefore(placedAt)) {
        throw StateError(
          'Slot $slotNumber has no usable Date Placed timestamp.',
        );
      }
      final incubationAgeHours = capturedAt.difference(placedAt).inHours;
      final incubationDay = incubationAgeHours ~/ 24;
      if (incubationDay < _fertilityDatasetMinDay ||
          incubationDay > _fertilityDatasetMaxDay) {
        throw StateError(
          'Slot $slotNumber changed outside the Day '
          '$_fertilityDatasetMinDay-$_fertilityDatasetMaxDay collection window.',
        );
      }
      const detectionReady = true;
      final eggId = _fertilityDatasetEggId(
        slotNumber: slotNumber,
        placedAt: placedAt,
        batchStamp: batchStamp,
      );

      final left = _boundaryToPixel(
        colBounds[col],
        trayCm: _trayWidthCm,
        imagePixels: image.width,
      );
      final right = _boundaryToPixel(
        colBounds[col + 1],
        trayCm: _trayWidthCm,
        imagePixels: image.width,
      );
      final top = _boundaryToPixel(
        rowBounds[row],
        trayCm: _trayHeightCm,
        imagePixels: image.height,
      );
      final bottom = _boundaryToPixel(
        rowBounds[row + 1],
        trayCm: _trayHeightCm,
        imagePixels: image.height,
      );
      final cropWidth = (right - left).clamp(1, image.width - left).toInt();
      final cropHeight = (bottom - top).clamp(1, image.height - top).toInt();
      final crop = img.copyCrop(
        image,
        x: left,
        y: top,
        width: cropWidth,
        height: cropHeight,
      );
      final quality = _measureFertilityDatasetCropQuality(crop);
      final cropBytes = Uint8List.fromList(img.encodeJpg(crop, quality: 95));
      final trainingEligible = quality.isOk;
      final qualitySuffix = quality.isOk ? '' : '_${quality.status}';
      final dayToken = 'd${incubationDay.toString().padLeft(2, '0')}';
      final fileName =
          '${label}_${dayToken}_${viewToken}_${batchStamp}_r${row + 1}_c${col + 1}_s${slotNumber.toString().padLeft(2, '0')}$qualitySuffix.jpg';
      final labelDir = await cropDirectory(
        label,
        trainingEligible: trainingEligible,
        incubationDay: incubationDay,
        eggId: eggId,
      );
      final file = File('${labelDir.path}${Platform.pathSeparator}$fileName');
      await file.writeAsBytes(cropBytes, flush: true);

      final thumb = crop.width >= crop.height
          ? img.copyResize(crop, width: 72)
          : img.copyResize(crop, height: 72);
      previewBytes.add(Uint8List.fromList(img.encodeJpg(thumb, quality: 72)));
      previewStatuses.add(quality.status);
      previewLabels.add(label);
      previewSlotNumbers.add(slotNumber);
      files.add(file.path);

      records.add(
        _FertilityDatasetCropRecord(
          batchId: batchStamp,
          collectionRunId: collectionRunId,
          captureTrigger: captureTrigger,
          viewIndex: viewIndex,
          timestamp: capturedAt,
          label: label,
          trainingEligible: trainingEligible,
          verification: verification,
          reviewerId: _fertilityDatasetReviewerId,
          verifiedAt: DateTime.now(),
          eggId: eggId,
          row: row + 1,
          col: col + 1,
          slotNumber: slotNumber,
          p4HasEgg: p4HasEgg,
          incubationDay: incubationDay,
          incubationAgeHours: incubationAgeHours,
          placedAt: placedAt,
          placedAtConfirmed: placedAtConfirmed,
          p4Connected: p4Connected,
          detectionReady: detectionReady,
          filePath: file.path,
          sourcePath: sourceFile.path,
          cropLeft: left,
          cropTop: top,
          cropRight: right,
          cropBottom: bottom,
          width: cropWidth,
          height: cropHeight,
          qualityStatus: quality.status,
          brightness: quality.brightness,
          edgeScore: quality.edgeScore,
        ),
      );
    }

    final metadataDir = Directory(
      '${rootDir.path}${Platform.pathSeparator}_metadata',
    );
    await metadataDir.create(recursive: true);
    final batchCsvFile = File(
      '${metadataDir.path}${Platform.pathSeparator}metadata_$batchStamp.csv',
    );
    final globalCsvFile = File(
      '${metadataDir.path}${Platform.pathSeparator}metadata_multiview_v7.csv',
    );
    await _writeFertilityDatasetCsv(batchCsvFile, records, append: false);

    final trainingEligibleCount = records
        .where((record) => record.trainingEligible)
        .length;
    final capturedSlotNumbers = sortedSlots
        .map((slotIndex) => slotIndex + 1)
        .toList(growable: false);
    final manifestFile = File(
      '${metadataDir.path}${Platform.pathSeparator}manifest_$batchStamp.json',
    );
    final manifest = <String, dynamic>{
      'schema_version': 7,
      'protocol_version': 'fertility_p4_multiview_v7',
      'collection_batch_id': batchStamp,
      'collection_run_id': collectionRunId,
      'capture_trigger': captureTrigger,
      'view_index': viewIndex,
      'target_views': _fertilityDatasetTargetViews,
      'captured_at': capturedAt.toIso8601String(),
      'capture_mode': 'candling',
      'capture_endpoint': _fertilityDatasetCaptureEndpoint,
      'verification': verification,
      'verification_name': _fertilityDatasetVerificationName(verification),
      'verification_state': 'confirmed',
      'verification_method': 'operator_candling_review',
      'verdicts_confirmed_after_capture': true,
      'verdict_scope': 'per_slot',
      'reviewer_id': _fertilityDatasetReviewerId,
      'age_selection': 'placed_at_to_capture_timestamp',
      'day_selection_range': {
        'min': _fertilityDatasetMinDay,
        'max': _fertilityDatasetMaxDay,
        'automatic': true,
      },
      'captured_incubation_days':
          records
              .map((record) => record.incubationDay)
              .whereType<int>()
              .toSet()
              .toList()
            ..sort(),
      'labeling_note': captureTrigger == 'manual_label_seed'
          ? 'Each crop was labeled Fertile or Infertile by the operator after reviewing this captured candling image.'
          : 'Labels were locked from the operator-reviewed seed view and reused only after slot occupancy and Date Placed identity were revalidated.',
      'source_saved': true,
      'source_path': sourceFile.path,
      'source_width': image.width,
      'source_height': image.height,
      'root_path': rootDir.path,
      'batch_csv_path': batchCsvFile.path,
      'global_csv_path': globalCsvFile.path,
      'camera': {
        'device': 'ESP32-S3 camera',
        'endpoint': _fertilityDatasetCaptureEndpoint,
        'distribution': 'production_candling',
        'environment_bulb': 'force_off_by_capture_endpoint',
        'slot_underlights': 'timestamp_age_ready_occupied_slots',
      },
      'hardware_verification': ledVerification,
      'environment': {
        'temperature_c': temperature,
        'humidity_percent': humidity,
      },
      'target_model': {
        'deployment_status': 'future_candidate_not_installed',
        'backbone': 'EfficientNet-Lite0',
        'task': 'per_slot_binary_classification',
        'input': {
          'shape': [1, 224, 224, 3],
          'dtype': 'float32',
          'color_order': 'RGB',
          'normalization': 'pixel_div_255',
        },
        'output': {
          'shape': [1, 2],
          'dtype': 'float32',
          'activation': 'softmax',
          'labels': ['fertile', 'infertile'],
        },
        'class_count': 2,
      },
      'grid': {
        'rows': gridRows,
        'cols': gridCols,
        'cells': gridRows * gridCols,
        'saved_cells': records.length,
        'unlabeled_cells_saved': false,
        'col_boundaries_cm': colBounds,
        'row_boundaries_cm': rowBounds,
        'tray_width_cm': _trayWidthCm,
        'tray_height_cm': _trayHeightCm,
      },
      'p4_snapshot': {
        'connected': p4Connected,
        'egg_day': p4EggDay,
        'occupied_slots': occupiedSlots,
        'slot_days': slotDays,
        'captured_slot_numbers': capturedSlotNumbers,
        'age_selection': 'placed_at_to_capture_timestamp',
        'date_confirmation_required': false,
        'review_workflow_status': 'Operator labels complete',
        'slot_placed_at': slotPlacedAt
            .map((value) => value?.toUtc().toIso8601String())
            .toList(),
        'slot_placed_at_confirmed': slotPlacedAtConfirmed,
      },
      'operator_verdicts': {
        for (final record in records)
          record.slotNumber.toString(): record.label,
      },
      'multiview_identity': {
        'egg_id': 'slot number plus Date Placed timestamp',
        'all_views_share_collection_run_id': true,
        'exact_angle_known': false,
        'tray_position': 'natural_swing_position_after_settle',
      },
      'counts': {
        'total': records.length,
        'training_eligible': trainingEligibleCount,
        'excluded': records.length - trainingEligibleCount,
        'by_label': _countFertilityDatasetValues(
          records,
          (record) => record.label,
        ),
        'by_quality': _countFertilityDatasetValues(
          records,
          (record) => record.qualityStatus,
        ),
      },
      'records': records.map((record) => record.toJson()).toList(),
    };
    await manifestFile.writeAsString(
      const JsonEncoder.withIndent('  ').convert(manifest),
      flush: true,
    );
    await _writeFertilityDatasetCsv(globalCsvFile, records, append: true);
    files
      ..add(batchCsvFile.path)
      ..add(manifestFile.path);

    final savedCropFiles = records
        .map((record) => File(record.filePath))
        .toList();
    final missingOrEmptySlots = <int>[];
    for (var index = 0; index < records.length; index++) {
      final file = savedCropFiles[index];
      if (!await file.exists() || await file.length() == 0) {
        missingOrEmptySlots.add(records[index].slotNumber);
      }
    }
    if (records.length != sortedSlots.length ||
        missingOrEmptySlots.isNotEmpty) {
      throw FileSystemException(
        'Fertility batch verification failed. Expected ${sortedSlots.length} '
        'crops, saved ${records.length}; missing/empty slots: '
        '${missingOrEmptySlots.isEmpty ? 'none' : missingOrEmptySlots.join(', ')}.',
      );
    }

    return _FertilityDatasetBatchResult(
      records: records,
      previewBytes: previewBytes,
      previewStatuses: previewStatuses,
      previewLabels: previewLabels,
      previewSlotNumbers: previewSlotNumbers,
      files: files,
      manifestPath: manifestFile.path,
      batchCsvPath: batchCsvFile.path,
      warningCount: records
          .where((record) => record.qualityStatus != 'ok')
          .length,
    );
  }

  Future<void> _captureFertilityDatasetImage() async {
    if (!_canStartFertilityDatasetCapture) {
      final message = !_p4Connected
          ? 'Connect the P4 tray controller before fertility capture.'
          : !_isWifiCorrect
          ? 'Connect to AI_CANDLING before fertility capture.'
          : 'The camera or candling hardware is busy.';
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(message),
            duration: const Duration(seconds: 3),
          ),
        );
      }
      return;
    }

    final collectionRunId = _newFertilityDatasetRunId();

    _sensorTimer?.cancel();
    _p4PollTimer?.cancel();
    setState(() {
      _isStreaming = false;
      _streamKey++;
      _isFertilityDatasetCapturing = true;
      _status = 'Syncing occupied slots before fertility capture...';
    });

    try {
      final p4SyncSucceeded = await _refreshEggGridFromP4();
      if (!p4SyncSucceeded) {
        throw StateError(
          'Could not refresh occupied slots and dates from P4. Try again.',
        );
      }

      final occupiedSnapshot = List<bool>.from(_p4SlotHasEgg);
      final selectionAt = DateTime.now();
      final placedAtSnapshot = List<DateTime?>.from(_p4SlotPlacedAt);
      final selectedSlots = <int>[
        for (var index = 0; index < occupiedSnapshot.length; index++)
          if (occupiedSnapshot[index] &&
              _slotIsFertilityDatasetTimestampReady(index, now: selectionAt))
            index,
      ];
      if (selectedSlots.isEmpty) {
        throw StateError(
          'No occupied eggs have a Date Placed timestamp within Day '
          '$_fertilityDatasetMinDay-$_fertilityDatasetMaxDay.',
        );
      }
      final selectedLedNumbers = selectedSlots
          .map((slotIndex) => slotIndex + 1)
          .toList(growable: false);
      final selectedLedQuery = Uri.encodeQueryComponent(
        selectedLedNumbers.join(','),
      );
      final daySnapshot = List<int?>.generate(
        _activeGridCellCount,
        (index) => _daysSincePlaced(
          index < placedAtSnapshot.length ? placedAtSnapshot[index] : null,
          now: selectionAt,
        ),
        growable: false,
      );
      final placedAtConfirmedSnapshot = List<bool>.from(
        _p4SlotPlacedAtConfirmed,
      );
      final colBoundsSnapshot = List<double>.from(_scanColBoundaries);
      final rowBoundsSnapshot = List<double>.from(_scanRowBoundaries);
      final p4EggDaySnapshot = _p4EggDay;
      final p4ConnectedSnapshot = _p4Connected;
      final temperatureSnapshot = _temperature;
      final humiditySnapshot = _humidity;

      if (!mounted) return;
      setState(
        () => _status =
            'Bulb off, tray stopped, Day '
            '$_fertilityDatasetMinDay-$_fertilityDatasetMaxDay underlights on...',
      );

      Uint8List sourceBytes;
      late DateTime capturedAt;
      late Map<String, dynamic> ledVerification;
      var hardwareTouched = false;
      try {
        hardwareTouched = true;
        await _startP4IntakeCandlingHardware(selectedLedNumbers);
        await Future.delayed(_candlingCameraSettleDelay);
        if (!mounted) return;
        setState(() => _status = 'Verifying candling underlights...');
        ledVerification = await _verifyIntakeSelectedLeds(selectedLedNumbers);

        if (!mounted) return;
        setState(
          () => _status =
              'Capturing candling image from $_fertilityDatasetCaptureEndpoint...',
        );
        capturedAt = DateTime.now();
        final client = http.Client();
        try {
          final request = http.Request(
            'GET',
            _s3Uri('$_fertilityDatasetCaptureEndpoint?led=$selectedLedQuery'),
          );
          final response = await client
              .send(request)
              .timeout(
                _cameraCaptureRequestTimeout,
                onTimeout: () => throw TimeoutException('Capture timed out'),
              );
          if (response.statusCode != 200) {
            throw HttpException(
              'Fertility camera capture failed: ${response.statusCode}',
              uri: _s3Uri(_fertilityDatasetCaptureEndpoint),
            );
          }
          final bytes = await response.stream.toBytes().timeout(
            _cameraCaptureRequestTimeout,
          );
          if (bytes.isEmpty) throw Exception('Empty response from camera');
          sourceBytes = Uint8List.fromList(bytes);
        } finally {
          client.close();
        }
      } finally {
        if (hardwareTouched) {
          await _restoreCandlingHardware();
        }
      }

      if (!mounted) return;
      setState(
        () => _status = 'Preparing timestamp-aged crops for labeling...',
      );
      final batchStamp = DateFormat('yyyyMMdd_HHmmss_SSS').format(capturedAt);
      final pendingBatch = _prepareFertilityDatasetBatch(
        sourceBytes: sourceBytes,
        batchStamp: batchStamp,
        collectionRunId: collectionRunId,
        captureTrigger: 'manual_label_seed',
        viewIndex: 1,
        capturedAt: capturedAt,
        selectedSlots: selectedSlots,
        occupiedSlots: occupiedSnapshot,
        slotDays: daySnapshot,
        slotPlacedAt: placedAtSnapshot,
        slotPlacedAtConfirmed: placedAtConfirmedSnapshot,
        p4EggDay: p4EggDaySnapshot,
        colBounds: colBoundsSnapshot,
        rowBounds: rowBoundsSnapshot,
        p4Connected: p4ConnectedSnapshot,
        ledVerification: ledVerification,
        temperature: temperatureSnapshot,
        humidity: humiditySnapshot,
      );

      if (!mounted) return;
      setState(() {
        _fertilityDatasetLastImage = sourceBytes;
        _fertilityDatasetLastCropPreviews = pendingBatch.previewBytes;
        _fertilityDatasetLastCropStatuses = pendingBatch.previewStatuses;
        _fertilityDatasetLastCropLabels = List<String>.filled(
          pendingBatch.previewBytes.length,
          'pending',
        );
        _fertilityDatasetLastCropSlotNumbers = pendingBatch.previewSlotNumbers;
        _selectedFertilityDatasetCropIndex = 0;
        _pendingFertilityDatasetBatch = pendingBatch;
        _isFertilityDatasetCapturing = false;
        _status = 'Label every crop Fertile or Infertile';
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Captured ${pendingBatch.previewBytes.length} crops. '
            'Label every crop, then tap Save All.',
          ),
          duration: const Duration(seconds: 4),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isFertilityDatasetCapturing = false;
        _status = 'Fertility dataset capture failed: $e';
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Fertility capture failed: $e'),
          backgroundColor: Colors.red,
          duration: const Duration(seconds: 5),
        ),
      );
    } finally {
      if (mounted && _currentIndex == 5) {
        _startSensorPolling();
        _startPeriodicP4Sync();
      }
    }
  }

  int get _fertilityDatasetLabeledCropCount => _fertilityDatasetLastCropLabels
      .where((label) => label == 'fertile' || label == 'infertile')
      .length;

  bool get _canSaveAllFertilityDatasetCrops {
    final batch = _pendingFertilityDatasetBatch;
    return batch != null &&
        !_isFertilityDatasetSaving &&
        _fertilityDatasetLastCropLabels.length == batch.selectedSlots.length &&
        _fertilityDatasetLastCropLabels.every(
          (label) => label == 'fertile' || label == 'infertile',
        );
  }

  void _labelSelectedFertilityDatasetCrop(String label) {
    if (label != 'fertile' && label != 'infertile') return;
    if (_pendingFertilityDatasetBatch == null ||
        _fertilityDatasetLastCropLabels.isEmpty) {
      return;
    }
    final index = _selectedFertilityDatasetCropIndex.clamp(
      0,
      _fertilityDatasetLastCropLabels.length - 1,
    );
    final labels = List<String>.from(_fertilityDatasetLastCropLabels);
    labels[index] = label;
    final labeledCount = labels
        .where((value) => value == 'fertile' || value == 'infertile')
        .length;
    setState(() {
      _fertilityDatasetLastCropLabels = labels;
      _status = 'Labeled $labeledCount of ${labels.length} crops';
    });
  }

  Future<void> _discardPendingFertilityDatasetCapture() async {
    final batch = _pendingFertilityDatasetBatch;
    if (batch == null || _isFertilityDatasetSaving) return;

    final discard = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Discard capture?'),
        content: Text(
          'Discard this unsaved capture and its ${batch.selectedSlots.length} '
          'crop labels? Previously saved dataset files will remain untouched.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('KEEP'),
          ),
          FilledButton.icon(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            icon: const Icon(Icons.delete_outline_rounded, size: 18),
            label: const Text('DISCARD'),
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFFFF5252),
              foregroundColor: Colors.white,
            ),
          ),
        ],
      ),
    );
    if (discard != true || !mounted) return;

    setState(() {
      _pendingFertilityDatasetBatch = null;
      _fertilityDatasetLastImage = null;
      _fertilityDatasetLastCropPreviews = const [];
      _fertilityDatasetLastCropStatuses = const [];
      _fertilityDatasetLastCropLabels = const [];
      _fertilityDatasetLastCropSlotNumbers = const [];
      _selectedFertilityDatasetCropIndex = 0;
      _status = 'Unsaved fertility capture discarded; ready to capture again';
    });
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Unsaved capture discarded. You can capture again.'),
        duration: Duration(seconds: 3),
      ),
    );
  }

  Future<void> _saveAllFertilityDatasetCrops() async {
    final batch = _pendingFertilityDatasetBatch;
    if (batch == null || !_canSaveAllFertilityDatasetCrops) return;

    final labels = List<String>.from(_fertilityDatasetLastCropLabels);
    final labelsBySlot = <int, String>{
      for (var index = 0; index < batch.selectedSlots.length; index++)
        batch.selectedSlots[index]: labels[index],
    };
    setState(() {
      _isFertilityDatasetSaving = true;
      _status = 'Saving labeled fertility training batch...';
    });

    try {
      final rootDir = await _fertilityDatasetRootDirectory();
      final batchResult = await _saveFertilityDatasetCellCrops(
        batch: batch,
        rootDir: rootDir,
        labelsBySlot: labelsBySlot,
      );
      final runFiles = batchResult.files.toSet().toList(growable: false);
      final runArchivePath = await _writeFertilityDatasetRunArchive(
        rootDir: rootDir,
        collectionRunId: batch.collectionRunId,
        files: runFiles,
      );
      if (!mounted) return;

      final lockedPlacedAt = <int, int>{
        for (final slotIndex in batch.selectedSlots)
          if (slotIndex < batch.slotPlacedAt.length &&
              batch.slotPlacedAt[slotIndex] != null)
            slotIndex: batch.slotPlacedAt[slotIndex]!
                .toUtc()
                .millisecondsSinceEpoch,
      };

      setState(() {
        _fertilityDatasetLastCropPreviews = batchResult.previewBytes;
        _fertilityDatasetLastCropStatuses = batchResult.previewStatuses;
        _fertilityDatasetLastCropLabels = batchResult.previewLabels;
        _fertilityDatasetLastCropSlotNumbers = batchResult.previewSlotNumbers;
        _fertilityDatasetLastManifestPath = batchResult.manifestPath;
        _fertilityDatasetLastCsvPath = batchResult.batchCsvPath;
        _fertilityDatasetRootPath = rootDir.path;
        _fertilityDatasetLastBatchFiles = [runArchivePath];
        _fertilityDatasetRunFiles = runFiles;
        _fertilityDatasetLastBatchCount = batchResult.savedCount;
        _fertilityDatasetLastQualityWarningCount = batchResult.warningCount;
        _fertilityDatasetCaptureCount += batchResult.savedCount;
        _pendingFertilityDatasetBatch = null;
        _isFertilityDatasetSaving = false;
        _fertilityDatasetCollectionRunId = batch.collectionRunId;
        _fertilityDatasetLockedLabels = Map<int, String>.unmodifiable(
          labelsBySlot,
        );
        _fertilityDatasetLockedPlacedAtEpochMs = Map<int, int>.unmodifiable(
          lockedPlacedAt,
        );
        _fertilityDatasetCompletedViewCount = batch.viewIndex;
        _fertilityDatasetNextCaptureAt = null;
        _fertilityDatasetNextCaptureSeconds = 0;
        _status = 'Seed view saved; automatic angle views are ready';
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Saved ${batchResult.savedCount} labeled fertility crops. '
            '${batchResult.warningCount == 0 ? 'All are ready for training.' : '${batchResult.warningCount} moved to quality review.'} '
            'Start Auto Views to collect the remaining angles.',
          ),
          duration: const Duration(seconds: 4),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isFertilityDatasetSaving = false;
        _status = 'Fertility dataset save failed: $e';
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Save All failed: $e'),
          backgroundColor: Colors.red,
          duration: const Duration(seconds: 5),
        ),
      );
    }
  }

  void _startFertilityDatasetAutoCapture() {
    if (!_canStartFertilityDatasetAutoCapture) return;
    setState(() {
      _isFertilityDatasetAutoCapturing = true;
      _status =
          'Automatic angle collection started at view '
          '$_fertilityDatasetCompletedViewCount/$_fertilityDatasetTargetViews';
    });
    _scheduleNextFertilityDatasetAutoCapture();
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          'Auto Views started. The next settled tray view is captured in 15 seconds.',
        ),
        duration: Duration(seconds: 4),
      ),
    );
  }

  void _scheduleNextFertilityDatasetAutoCapture() {
    if (!_isFertilityDatasetAutoCapturing) return;
    if (_fertilityDatasetCompletedViewCount >= _fertilityDatasetTargetViews) {
      _stopFertilityDatasetAutoCapture(showSnack: true, completed: true);
      return;
    }

    final nextCaptureAt = DateTime.now().add(_fertilityDatasetCaptureInterval);
    _fertilityDatasetAutoCaptureTimer?.cancel();
    if (mounted) {
      setState(() {
        _fertilityDatasetNextCaptureAt = nextCaptureAt;
        _fertilityDatasetNextCaptureSeconds =
            _fertilityDatasetCaptureInterval.inSeconds;
      });
    }
    _startFertilityDatasetCountdownTimer();
    _fertilityDatasetAutoCaptureTimer = Timer(
      _fertilityDatasetCaptureInterval,
      () async {
        if (!mounted || !_isFertilityDatasetAutoCapturing) return;
        _fertilityDatasetCountdownTimer?.cancel();
        _fertilityDatasetCountdownTimer = null;
        final saved = await _captureFertilityDatasetAutoView();
        if (!mounted || !_isFertilityDatasetAutoCapturing || !saved) return;
        _scheduleNextFertilityDatasetAutoCapture();
      },
    );
  }

  void _startFertilityDatasetCountdownTimer() {
    _fertilityDatasetCountdownTimer?.cancel();
    _updateFertilityDatasetCountdown();
    _fertilityDatasetCountdownTimer = Timer.periodic(
      const Duration(seconds: 1),
      (_) => _updateFertilityDatasetCountdown(),
    );
  }

  void _updateFertilityDatasetCountdown() {
    if (!mounted ||
        !_isFertilityDatasetAutoCapturing ||
        _fertilityDatasetNextCaptureAt == null) {
      return;
    }
    final seconds = math.max(
      0,
      _fertilityDatasetNextCaptureAt!.difference(DateTime.now()).inSeconds,
    );
    if (seconds == _fertilityDatasetNextCaptureSeconds) return;
    setState(() => _fertilityDatasetNextCaptureSeconds = seconds);
  }

  void _stopFertilityDatasetAutoCapture({
    bool showSnack = true,
    bool completed = false,
  }) {
    _fertilityDatasetAutoCaptureTimer?.cancel();
    _fertilityDatasetAutoCaptureTimer = null;
    _fertilityDatasetCountdownTimer?.cancel();
    _fertilityDatasetCountdownTimer = null;
    final wasActive = _isFertilityDatasetAutoCapturing;
    if (!mounted) return;
    setState(() {
      _isFertilityDatasetAutoCapturing = false;
      _fertilityDatasetNextCaptureAt = null;
      _fertilityDatasetNextCaptureSeconds = 0;
      if (wasActive) {
        _status = completed
            ? 'Automatic angle collection complete'
            : 'Automatic angle collection stopped';
      }
    });
    if (showSnack && wasActive) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            completed
                ? 'All $_fertilityDatasetTargetViews settled views are saved.'
                : 'Auto Views stopped.',
          ),
          duration: const Duration(seconds: 3),
        ),
      );
    }
  }

  Future<bool> _captureFertilityDatasetAutoView() async {
    if (!_isFertilityDatasetAutoCapturing ||
        _isFertilityDatasetCapturing ||
        _isFertilityDatasetSaving) {
      return false;
    }

    final labelsBySlot = Map<int, String>.from(
      _fertilityDatasetLockedLabels ?? const <int, String>{},
    );
    final expectedPlacedAt = Map<int, int>.from(
      _fertilityDatasetLockedPlacedAtEpochMs ?? const <int, int>{},
    );
    final collectionRunId = _fertilityDatasetCollectionRunId;
    final viewIndex = _fertilityDatasetCompletedViewCount + 1;
    if (labelsBySlot.isEmpty ||
        expectedPlacedAt.length != labelsBySlot.length ||
        collectionRunId == null ||
        viewIndex > _fertilityDatasetTargetViews) {
      _stopFertilityDatasetAutoCapture(showSnack: false);
      return false;
    }

    _sensorTimer?.cancel();
    _p4PollTimer?.cancel();
    if (mounted) {
      setState(() {
        _isFertilityDatasetCapturing = true;
        _fertilityDatasetNextCaptureAt = null;
        _fertilityDatasetNextCaptureSeconds = 0;
        _status =
            'Verifying egg identities for view '
            '$viewIndex/$_fertilityDatasetTargetViews...';
      });
    }

    try {
      final p4SyncSucceeded = await _refreshEggGridFromP4();
      if (!p4SyncSucceeded) {
        throw StateError('Could not refresh occupied slots and dates from P4.');
      }

      final occupiedSnapshot = List<bool>.from(_p4SlotHasEgg);
      final placedAtSnapshot = List<DateTime?>.from(_p4SlotPlacedAt);
      final selectionAt = DateTime.now();
      final selectedSlots = labelsBySlot.keys.toList()..sort();
      for (final slotIndex in selectedSlots) {
        if (slotIndex < 0 ||
            slotIndex >= occupiedSnapshot.length ||
            !occupiedSnapshot[slotIndex]) {
          throw StateError(
            'Slot ${slotIndex + 1} is no longer occupied. Auto Views stopped.',
          );
        }
        final placedAt = slotIndex < placedAtSnapshot.length
            ? placedAtSnapshot[slotIndex]
            : null;
        final expectedEpoch = expectedPlacedAt[slotIndex];
        if (placedAt == null ||
            expectedEpoch == null ||
            placedAt.toUtc().millisecondsSinceEpoch != expectedEpoch) {
          throw StateError(
            'Slot ${slotIndex + 1} has a different Date Placed identity. '
            'Auto Views stopped before saving.',
          );
        }
        if (!_slotIsFertilityDatasetTimestampReady(
          slotIndex,
          now: selectionAt,
        )) {
          throw StateError(
            'Slot ${slotIndex + 1} is outside Day '
            '$_fertilityDatasetMinDay-$_fertilityDatasetMaxDay. '
            'Auto Views stopped.',
          );
        }
        final label = labelsBySlot[slotIndex];
        if (label != 'fertile' && label != 'infertile') {
          throw StateError('Slot ${slotIndex + 1} has no locked label.');
        }
      }

      final selectedLedNumbers = selectedSlots
          .map((slotIndex) => slotIndex + 1)
          .toList(growable: false);
      final daySnapshot = List<int?>.generate(
        _activeGridCellCount,
        (index) => _daysSincePlaced(
          index < placedAtSnapshot.length ? placedAtSnapshot[index] : null,
          now: selectionAt,
        ),
        growable: false,
      );
      final placedAtConfirmedSnapshot = List<bool>.from(
        _p4SlotPlacedAtConfirmed,
      );
      final colBoundsSnapshot = List<double>.from(_scanColBoundaries);
      final rowBoundsSnapshot = List<double>.from(_scanRowBoundaries);
      final p4EggDaySnapshot = _p4EggDay;
      final p4ConnectedSnapshot = _p4Connected;
      final temperatureSnapshot = _temperature;
      final humiditySnapshot = _humidity;

      if (mounted) {
        setState(
          () => _status =
              'Tray stopped; settling automatic view '
              '$viewIndex/$_fertilityDatasetTargetViews...',
        );
      }

      late Uint8List sourceBytes;
      late DateTime capturedAt;
      late Map<String, dynamic> ledVerification;
      var hardwareTouched = false;
      try {
        hardwareTouched = true;
        await _startP4IntakeCandlingHardware(selectedLedNumbers);
        await Future.delayed(_intakeCandlingSettleDelay);
        ledVerification = await _verifyIntakeSelectedLeds(selectedLedNumbers);
        capturedAt = DateTime.now();
        final client = http.Client();
        try {
          final request = http.Request(
            'GET',
            Uri.http(
              _esp32S3Ip,
              _fertilityDatasetCaptureEndpoint,
              <String, String>{'led': selectedLedNumbers.join(',')},
            ),
          );
          final response = await client
              .send(request)
              .timeout(
                _cameraCaptureRequestTimeout,
                onTimeout: () => throw TimeoutException('Capture timed out'),
              );
          if (response.statusCode != 200) {
            throw HttpException(
              'Fertility camera capture failed: ${response.statusCode}',
              uri: request.url,
            );
          }
          final bytes = await response.stream.toBytes().timeout(
            _cameraCaptureRequestTimeout,
          );
          if (bytes.isEmpty) throw Exception('Empty response from camera');
          sourceBytes = Uint8List.fromList(bytes);
        } finally {
          client.close();
        }
      } finally {
        if (hardwareTouched) await _restoreCandlingHardware();
      }

      final batchStamp = DateFormat('yyyyMMdd_HHmmss_SSS').format(capturedAt);
      final batch = _prepareFertilityDatasetBatch(
        sourceBytes: sourceBytes,
        batchStamp: batchStamp,
        collectionRunId: collectionRunId,
        captureTrigger: 'auto_angle_view',
        viewIndex: viewIndex,
        capturedAt: capturedAt,
        selectedSlots: selectedSlots,
        occupiedSlots: occupiedSnapshot,
        slotDays: daySnapshot,
        slotPlacedAt: placedAtSnapshot,
        slotPlacedAtConfirmed: placedAtConfirmedSnapshot,
        p4EggDay: p4EggDaySnapshot,
        colBounds: colBoundsSnapshot,
        rowBounds: rowBoundsSnapshot,
        p4Connected: p4ConnectedSnapshot,
        ledVerification: ledVerification,
        temperature: temperatureSnapshot,
        humidity: humiditySnapshot,
      );
      final rootDir = await _fertilityDatasetRootDirectory();
      final batchResult = await _saveFertilityDatasetCellCrops(
        batch: batch,
        rootDir: rootDir,
        labelsBySlot: labelsBySlot,
      );
      final runFiles = <String>{
        ..._fertilityDatasetRunFiles,
        ...batchResult.files,
      }.toList(growable: false);
      final runArchivePath = await _writeFertilityDatasetRunArchive(
        rootDir: rootDir,
        collectionRunId: collectionRunId,
        files: runFiles,
      );
      if (!mounted) return false;

      setState(() {
        _fertilityDatasetLastImage = sourceBytes;
        _fertilityDatasetLastCropPreviews = batchResult.previewBytes;
        _fertilityDatasetLastCropStatuses = batchResult.previewStatuses;
        _fertilityDatasetLastCropLabels = batchResult.previewLabels;
        _fertilityDatasetLastCropSlotNumbers = batchResult.previewSlotNumbers;
        _fertilityDatasetLastManifestPath = batchResult.manifestPath;
        _fertilityDatasetLastCsvPath = batchResult.batchCsvPath;
        _fertilityDatasetRootPath = rootDir.path;
        _fertilityDatasetLastBatchFiles = [runArchivePath];
        _fertilityDatasetRunFiles = runFiles;
        _fertilityDatasetLastBatchCount = batchResult.savedCount;
        _fertilityDatasetLastQualityWarningCount = batchResult.warningCount;
        _fertilityDatasetCaptureCount += batchResult.savedCount;
        _fertilityDatasetCompletedViewCount = viewIndex;
        _status = 'Saved settled view $viewIndex/$_fertilityDatasetTargetViews';
      });
      return true;
    } catch (e) {
      _stopFertilityDatasetAutoCapture(showSnack: false);
      if (mounted) {
        setState(() => _status = 'Auto Views stopped: $e');
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Auto Views stopped safely: $e'),
            backgroundColor: Colors.red,
            duration: const Duration(seconds: 5),
          ),
        );
      }
      return false;
    } finally {
      if (mounted) {
        setState(() => _isFertilityDatasetCapturing = false);
        if (_currentIndex == 5) {
          _startSensorPolling();
          _startPeriodicP4Sync();
        }
      }
    }
  }

  Future<void> _shareFertilityDatasetLastBatch() async {
    final paths = _fertilityDatasetLastBatchFiles
        .where(
          (path) =>
              path.toLowerCase().endsWith('.zip') && File(path).existsSync(),
        )
        .toList(growable: false);
    if (paths.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'No complete fertility collection ZIP is ready. Save All again first.',
          ),
          duration: Duration(seconds: 3),
        ),
      );
      return;
    }

    try {
      await Share.shareXFiles(
        [XFile(paths.last, mimeType: 'application/zip')],
        subject: 'Fertility dataset collection',
        text:
            'Complete candling collection: every captured view, labeled crop, CSV, and JSON.',
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Fertility dataset share failed: $e'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  Future<void> _triggerCaptureFlow() async {
    if (_demoMode) {
      await _runDemoScan();
      return;
    }
    if (_isCandling ||
        _isDatasetCapturing ||
        _isDatasetAutoCapturing ||
        _isIntakeDatasetCapturing ||
        _isIntakeDatasetAutoCapturing ||
        _isFertilityDatasetCapturing ||
        _isFertilityDatasetAutoCapturing ||
        _isCapturingCalibration ||
        !_isWifiCorrect) {
      return;
    }
    if (!_p4Connected) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'P4 slot and incubation-day data is required to light every occupied slot and save exact research ages.',
            ),
            backgroundColor: Color(0xFFFF9800),
            duration: Duration(seconds: 5),
          ),
        );
      }
      return;
    }
    final scanWatch = Stopwatch()..start();
    _lastCandlingLightsVerified = null;
    _lastCandlingLedCacheValid = null;
    _lastActiveCandlingLeds = const [];
    _lastMissingCandlingLeds = const [];

    _sensorTimer?.cancel();
    setState(() {
      _isCandling = true;
      _isStreaming = false;
      _isDownloading = true;
      _status = 'Step 1/5: Preparing candling capture...';
    });

    try {
      await _finishLedTestBeforeCandlingCapture();
      if (_p4Connected) {
        setState(() => _status = 'Step 1/5: Syncing P4 egg slots...');
        await _syncEggGridFromP4();
      }

      final selectedLedNumbers = <int>[
        for (var index = 0; index < _p4SlotHasEgg.length; index++)
          if (_slotMatchesCandlingScope(index)) index + 1,
      ];
      if (selectedLedNumbers.isEmpty) {
        throw StateError(
          _candlingEggScope == _CandlingEggScope.day7Plus
              ? 'No occupied eggs are 7 or more days old.'
              : 'No occupied P4 egg slots are available for candling.',
        );
      }
      final selectedLedQuery = Uri.encodeQueryComponent(
        selectedLedNumbers.join(','),
      );

      setState(
        () => _status = 'Step 2/6: Bulb off, tray off, egg slots lit...',
      );
      Uint8List imageBytes;
      try {
        // /candling_start owns the complete candling operation on P4: it turns
        // the bulb off and stops the tray. A capture hold is a separate,
        // mutually exclusive operation and must not be active at the same time.
        await _startP4IntakeCandlingHardware(selectedLedNumbers);
        await Future.delayed(_candlingCameraSettleDelay);
        if (!mounted) return;
        setState(
          () => _status =
              'Step 3/6: Verifying $_candlingEggScopeLabel underlights...',
        );
        await _verifyCandlingLightsForHistory(selectedLedNumbers);
        if (!mounted) return;
        setState(() => _status = 'Step 3/6: Camera capturing...');

        final client = http.Client();
        try {
          final request = http.Request(
            'GET',
            _s3Uri('/capture?led=$selectedLedQuery'),
          );
          setState(() => _status = 'Step 4/6: Downloading image...');

          final captureWatch = Stopwatch()..start();
          final response = await client
              .send(request)
              .timeout(
                _candlingCaptureTimeout,
                onTimeout: () => throw TimeoutException('Capture timed out'),
              );

          final bytes = await response.stream.toBytes();
          captureWatch.stop();
          _lastCaptureMs = captureWatch.elapsedMilliseconds;
          if (response.statusCode != 200) {
            final errorBody = utf8.decode(bytes, allowMalformed: true).trim();
            throw HttpException(
              'Candling camera capture failed: ${response.statusCode}'
              '${errorBody.isEmpty ? '' : ' $errorBody'}',
              uri: _s3Uri('/capture'),
            );
          }
          if (bytes.isEmpty) throw Exception('Empty response from camera');

          final isJpeg =
              bytes.length >= 4 &&
              bytes[0] == 0xFF &&
              bytes[1] == 0xD8 &&
              bytes[bytes.length - 2] == 0xFF &&
              bytes[bytes.length - 1] == 0xD9;
          if (!isJpeg) {
            throw const FormatException('Camera returned an invalid JPEG');
          }

          imageBytes = Uint8List.fromList(bytes);
          _capturedImage = imageBytes;
          final kb = (bytes.length / 1024).toStringAsFixed(1);
          debugPrint('Captured ${bytes.length} bytes ($kb KB)');

          setState(() {
            _isDownloading = false;
            _status = 'Step 5/6: Restoring bulb, tray & slot LEDs... ($kb KB)';
          });
        } finally {
          client.close();
        }
      } catch (captureError) {
        // Capture failed: restore hardware now, then surface the error.
        await _stopP4CandlingHardware();
        rethrow;
      }

      // Capture succeeded: restore the bulb, tray, and slot LEDs while the
      // phone records the research session.
      final restoreFuture = _stopP4CandlingHardware();

      if (!mounted) {
        await restoreFuture;
        return;
      }
      setState(() => _status = 'Step 6/6: Saving research capture...');
      await _recordCapturedCandlingImage(imageBytes, scanWatch: scanWatch);
      await restoreFuture;
    } catch (e) {
      debugPrint('Capture error: $e');
      setState(() {
        _isCandling = false;
        _isDownloading = false;
        _status = _friendlyError(e);
      });
      _resumeStreamAndSensor();
    }
  }

  Future<void> _recordCapturedCandlingImage(
    Uint8List imageBytes, {
    Stopwatch? scanWatch,
  }) async {
    final decodedImage = img.decodeImage(imageBytes);
    final imageWidth = decodedImage?.width ?? 640;
    final imageHeight = decodedImage?.height ?? 480;
    scanWatch?.stop();
    _lastTotalScanMs = scanWatch?.elapsedMilliseconds;
    setState(() {
      _fertilityPending = true;
      _isCandling = false;
      _captureTimestamp = DateTime.now();
      _status = 'Classifying occupied Day 5-10 egg slots...';
    });

    final classification = await _classifyCapturedFertilityImage(imageBytes);

    await _saveCurrentSession(
      usedAi: classification.analyzedSlots.isNotEmpty,
      imageWidth: imageWidth,
      imageHeight: imageHeight,
      detections: const [],
      captureMs: _lastCaptureMs,
      totalScanMs: _lastTotalScanMs,
      aiMs: classification.elapsedMs,
      analyzedSlots: classification.analyzedSlots,
    );

    final savedSession = _sessions.first;
    _playCompletionSound();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _showCandlingResultSheet(savedSession);
    });
  }

  Future<_FertilityClassificationResult> _classifyCapturedFertilityImage(
    Uint8List imageBytes,
  ) async {
    final source = img.decodeImage(imageBytes);
    if (source == null) {
      throw const FormatException(
        'Candling image could not be decoded for AI.',
      );
    }

    final eligibleSlots = <int>[
      for (var index = 0; index < _activeGridCellCount; index++)
        if (_slotHasEgg(index) && _slotIsDetectionReady(index)) index,
    ];
    if (eligibleSlots.isEmpty) {
      if (mounted) {
        setState(() {
          _fertilityPending = false;
          _status =
              'Captured - no occupied eggs are within the Day 5-10 AI window.';
        });
      }
      return const _FertilityClassificationResult.empty();
    }

    final watch = Stopwatch()..start();
    final predictions = <int, FertilityPrediction>{};
    try {
      await _fertilityClassifier.load();
      final colBounds = _scanColBoundaries;
      final rowBounds = _scanRowBoundaries;
      for (final slotIndex in eligibleSlots) {
        final row = slotIndex ~/ _activeGridCols;
        final col = slotIndex % _activeGridCols;
        final left = _boundaryToPixel(
          colBounds[col],
          trayCm: _trayWidthCm,
          imagePixels: source.width,
        );
        final right = _boundaryToPixel(
          colBounds[col + 1],
          trayCm: _trayWidthCm,
          imagePixels: source.width,
        );
        final top = _boundaryToPixel(
          rowBounds[row],
          trayCm: _trayHeightCm,
          imagePixels: source.height,
        );
        final bottom = _boundaryToPixel(
          rowBounds[row + 1],
          trayCm: _trayHeightCm,
          imagePixels: source.height,
        );
        final width = (right - left).clamp(1, source.width - left).toInt();
        final height = (bottom - top).clamp(1, source.height - top).toInt();
        final crop = img.copyCrop(
          source,
          x: left,
          y: top,
          width: width,
          height: height,
        );
        predictions[slotIndex] = await _fertilityClassifier.classify(crop);
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _fertilityPending = true;
          _status = 'Captured, but mobile fertility AI could not finish.';
        });
      }
      rethrow;
    } finally {
      watch.stop();
    }

    final verdicts = List<String>.generate(
      _activeGridCellCount,
      (index) => index < _p4SlotFertilityVerdict.length
          ? _p4SlotFertilityVerdict[index]
          : 'none',
    );
    final publishableFertile = <int>[];
    final publishableInfertile = <int>[];
    for (final entry in predictions.entries) {
      verdicts[entry.key] = entry.value.label;
      final day = _slotDay(entry.key);
      if (day != null && day >= 7 && day <= _fertilityDatasetMaxDay) {
        if (entry.value.label == 'fertile') {
          publishableFertile.add(entry.key);
        } else {
          publishableInfertile.add(entry.key);
        }
      }
    }

    if (mounted) {
      setState(() {
        _syncSlotMetadataLength(_activeGridCellCount);
        _p4SlotFertilityVerdict = verdicts;
        _applyAutomaticFertilityVerdicts(_p4SlotHasEgg, verdicts);
        for (final entry in predictions.entries) {
          if (entry.key < _eggData.length) {
            _eggData[entry.key].confidence = entry.value.confidence;
          }
        }
        _fertilityPending = false;
        _fertilityModelReady = true;
        _status =
            'Mobile AI classified ${predictions.length} Day 5-10 egg slot(s).';
      });
    }

    // The installed P4 endpoint is intentionally unchanged and accepts only
    // Day 7+. Day 5-6 predictions remain visible in the phone app.
    if (_p4Connected &&
        (publishableFertile.isNotEmpty || publishableInfertile.isNotEmpty)) {
      try {
        await _esp32.setAutomaticFertilityResults(
          day: 7,
          fertileCells: publishableFertile,
          infertileCells: publishableInfertile,
          source: 'mobile_tflite_mobilenetv3small',
        );
      } catch (error) {
        debugPrint('P4 fertility result publication failed: $error');
        if (mounted) {
          setState(
            () => _status =
                'Mobile AI classified ${predictions.length} slot(s); P4 result sync will retry later.',
          );
        }
      }
    }

    return _FertilityClassificationResult(
      analyzedSlots: eligibleSlots,
      elapsedMs: watch.elapsedMilliseconds,
    );
  }

  // Sessions
  Future<void> _loadSessions() async {
    final prefs = await SharedPreferences.getInstance();
    final sessionsJson = prefs.getString('egg_sessions');
    if (sessionsJson != null) {
      try {
        final List<dynamic> decoded = jsonDecode(sessionsJson);
        setState(() {
          _sessions = decoded.map((s) => EggSession.fromJson(s)).toList();
        });
      } catch (e) {
        debugPrint('Failed to load sessions: $e — starting with empty list');
        // Corrupted data; optionally clear it
        await prefs.remove('egg_sessions');
      }
    }

    final sensorJson = prefs.getString('sensor_history');
    if (sensorJson != null) {
      try {
        final List<dynamic> decoded = jsonDecode(sensorJson);
        _sensorHistory =
            decoded
                .map(
                  (sample) =>
                      SensorSnapshot.fromJson(sample as Map<String, dynamic>),
                )
                .toList()
              ..sort((a, b) => a.timestamp.compareTo(b.timestamp));
        _trimSensorHistory();
        _lastSensorHistoryAt = _sensorHistory.isEmpty
            ? null
            : _sensorHistory.last.timestamp;
        await _saveSensorHistory();
      } catch (e) {
        debugPrint('Failed to load sensor history: $e');
        await prefs.remove('sensor_history');
        _sensorHistory = [];
        _lastSensorHistoryAt = null;
      }
    }

    final counterJson = prefs.getString('egg_counter_history');
    if (counterJson != null) {
      try {
        final List<dynamic> decoded = jsonDecode(counterJson);
        setState(() {
          _eggCounterHistory =
              decoded
                  .map(
                    (record) => EggCounterRecord.fromJson(
                      record as Map<String, dynamic>,
                    ),
                  )
                  .toList()
                ..sort((a, b) => b.timestamp.compareTo(a.timestamp));
        });
        await _saveEggCounterHistory();
      } catch (e) {
        debugPrint('Failed to load egg counter history: $e');
        await prefs.remove('egg_counter_history');
        _eggCounterHistory = [];
      }
    }

    final stableGridJson = prefs.getString(_stableP4GridSnapshotKey);
    if (stableGridJson != null) {
      try {
        final decoded = jsonDecode(stableGridJson);
        if (decoded is! Map) {
          throw const FormatException('Stable P4 grid is not an object.');
        }
        final payload = Map<String, dynamic>.from(decoded);
        final restoredEggs = _extractBoolList(
          payload['eggs'],
          _activeGridCellCount,
        );
        final pendingRaw = payload['pending_removal_eggs'];
        final restoredPending = pendingRaw == null
            ? null
            : _extractBoolList(pendingRaw, _activeGridCellCount);
        setState(() {
          _p4SlotHasEgg = restoredEggs;
          _p4EggCount = restoredEggs.where((hasEgg) => hasEgg).length;
          _hasStableP4Grid = true;
          _lastAcceptedP4ScanEpoch = _epochSecondsFromValue(
            payload['last_scan_epoch'],
          );
          _pendingP4RemovalGrid = restoredPending;
          _pendingP4RemovalScanEpoch = _epochSecondsFromValue(
            payload['pending_removal_scan_epoch'],
          );
          _p4GridUsingPreservedSnapshot = true;
          _p4GridDataStatus = 'Restored last verified P4 tray from this phone';
        });
      } catch (e) {
        debugPrint('Failed to load stable P4 tray: $e');
        await prefs.remove(_stableP4GridSnapshotKey);
      }
    }

    // Restore the phone-authoritative per-slot "date placed" so egg ages survive
    // an app restart (the P4 cannot be trusted to remember them across power
    // loss). The next P4 sync merges these and keeps them.
    final placedAtJson = prefs.getString('slot_placed_at');
    if (placedAtJson != null) {
      try {
        final List<dynamic> decoded = jsonDecode(placedAtJson);
        final restored = decoded
            .map((v) => v == null ? null : _dateTimeFromEpochValue(v))
            .toList();
        setState(() {
          _p4SlotPlacedAt = List<DateTime?>.generate(
            _activeGridCellCount,
            (index) => index < restored.length ? restored[index] : null,
          );
        });
      } catch (e) {
        debugPrint('Failed to load slot placed-at: $e');
        await prefs.remove('slot_placed_at');
      }
    }

    final placedAtConfirmedJson = prefs.getString(_slotPlacedAtConfirmedKey);
    if (placedAtConfirmedJson != null) {
      try {
        final decoded = jsonDecode(placedAtConfirmedJson);
        if (decoded is List) {
          _p4SlotPlacedAtConfirmed = List<bool>.generate(
            _activeGridCellCount,
            (index) => _slotPlacedAt(index) != null,
          );
        }
      } catch (e) {
        debugPrint('Failed to load Date Placed confirmations: $e');
        await prefs.remove(_slotPlacedAtConfirmedKey);
      }
    }

    _p4SlotDays = _daysFromPlacedAt(_p4SlotPlacedAt, _p4SlotDays);
    _p4EggDay = _p4SlotDays.whereType<int>().fold<int>(
      0,
      (maxDay, day) => day > maxDay ? day : maxDay,
    );
  }

  Future<void> _loadLanguage() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString('language_code') ?? 'en';
    if (!mounted) return;
    setState(() => _languageCode = saved);
  }

  Future<void> _setLanguage(String code) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('language_code', code);
    if (!mounted) return;
    setState(() => _languageCode = code);
  }

  String _friendlyError(Object error) {
    final text = error.toString().toLowerCase();
    if (text.contains('timed out') || text.contains('timeout')) {
      return 'Camera took too long. Check incubator WiFi and tap Refresh.';
    }
    if (text.contains('socket') ||
        text.contains('connection') ||
        text.contains('host')) {
      return 'Camera not reachable. Connect to AI_CANDLING and try again.';
    }
    if (text.contains('empty response')) {
      return 'Camera returned no image. Restart camera module if this repeats.';
    }
    return 'Scan failed. Check WiFi, camera power, then tap Refresh.';
  }

  Future<void> _runDemoScan() async {
    if (_isCandling || _countdown > 0) return;
    setState(() {
      _isCandling = true;
      _status = 'Demo scan running...';
    });
    await Future.delayed(const Duration(milliseconds: 900));

    final data = List<EggData>.generate(_activeGridCellCount, (_) => EggData());

    setState(() {
      _eggData = data;
      _fertileCount = 0;
      _infertileCount = 0;
      _lastCaptureMs = 820;
      _lastTotalScanMs = 1100;
      _isCandling = false;
      _fertilityPending = true;
      _status = 'Demo candling capture recorded - classification not run';
    });
    await _saveCurrentSession(
      usedAi: false,
      captureMs: _lastCaptureMs,
      totalScanMs: _lastTotalScanMs,
      analyzedSlots: const [],
    );
    _startCountdown();
  }

  Future<void> _saveSessions() async {
    if (_sessions.length > 50) _sessions = _sessions.sublist(0, 50);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      'egg_sessions',
      jsonEncode(_sessions.map((s) => s.toJson()).toList()),
    );
  }

  Future<void> _saveEggCounterHistory() async {
    if (_eggCounterHistory.length > _maxEggCounterHistoryRecords) {
      _eggCounterHistory = _eggCounterHistory.sublist(
        0,
        _maxEggCounterHistoryRecords,
      );
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      'egg_counter_history',
      jsonEncode(_eggCounterHistory.map((r) => r.toJson()).toList()),
    );
  }

  Future<void> _saveCurrentSession({
    bool usedAi = false,
    int? imageWidth,
    int? imageHeight,
    List<Map<String, dynamic>>? detections,
    int? captureMs,
    int? aiMs,
    int? totalScanMs,
    List<int>? analyzedSlots,
  }) async {
    // Compress image to keep SharedPreferences size small
    Uint8List? imageToStore = _capturedImage;
    if (_capturedImage != null) {
      imageToStore = await _compressImage(_capturedImage!);
    }

    final session = EggSession(
      id: DateTime.now().millisecondsSinceEpoch,
      timestamp: DateTime.now(),
      fertileCount: _fertileCount,
      infertileCount: _infertileCount,
      temperature: _temperature,
      humidity: _humidity,
      waterLevel: _waterLevel,
      waterLow: _waterLow,
      eggDay: _p4EggDay,
      p4EggCount: _p4EggCount,
      occupiedSlots: List<bool>.from(_p4SlotHasEgg),
      slotDays: List<int?>.generate(
        _activeGridCellCount,
        _slotDay,
        growable: false,
      ),
      slotPlacedAt: List<DateTime?>.from(_p4SlotPlacedAt),
      analyzedSlots: List<int>.from(analyzedSlots ?? const <int>[]),
      imageBytes: imageToStore,
      imageWidth: imageWidth,
      imageHeight: imageHeight,
      eggData: _eggData.map((egg) => egg.copy()).toList(),
      usedAi: usedAi,
      detections: detections,
      columnCount: _activeGridCols,
      rowCount: _activeGridRows,
      colBoundaries: List<double>.from(_scanColBoundaries),
      rowBoundaries: List<double>.from(_scanRowBoundaries),
      aiModel: usedAi ? 'MobileNetV3Small on-device' : null,
      captureMs: captureMs ?? _lastCaptureMs,
      aiMs: usedAi ? aiMs : null,
      totalScanMs: totalScanMs ?? _lastTotalScanMs,
      captureEndpoint: '/capture',
      p4TimeTrusted: _p4TimeTrusted,
      expectedCandlingLedCount: _p4SlotHasEgg.where((hasEgg) => hasEgg).length,
      candlingLightsVerified: _lastCandlingLightsVerified,
      candlingLedCacheValid: _lastCandlingLedCacheValid,
      activeCandlingLeds: List<int>.from(_lastActiveCandlingLeds),
      missingCandlingLeds: List<int>.from(_lastMissingCandlingLeds),
    );
    setState(() => _sessions.insert(0, session));
    await _saveSessions();
  }

  // Grid customization
  Future<void> _loadCustomGrid() async {
    final prefs = await SharedPreferences.getInstance();
    final colJson = prefs.getString('custom_col_boundaries');
    final rowJson = prefs.getString('custom_row_boundaries');
    final saved = prefs.getBool('grid_saved') ?? false;
    final defaultVersion = prefs.getInt('grid_default_version') ?? 0;
    final uniformRows = prefs.getBool('uniform_rows') ?? false;
    final uniformCols = prefs.getBool('uniform_cols') ?? false;
    final globalLineScale = prefs.getDouble('global_line_length_scale') ?? 1.0;
    final lineStep = prefs.getDouble('line_length_step') ?? 0.1;

    if (defaultVersion != _gridDefaultVersion) {
      if (mounted) {
        setState(() {
          _customColBoundaries = List<double>.from(_defaultColBoundaries);
          _customRowBoundaries = List<double>.from(_defaultRowBoundaries);
          _gridSaved = false;
          _uniformRows = false;
          _uniformCols = false;
          _globalLineLengthScale = 1.0;
          _lineLengthStep = 0.1;
          _lineLengthStepController.text = '0.1';
          _syncEggDataToGrid();
        });
      }
      await prefs.remove('custom_col_boundaries');
      await prefs.remove('custom_row_boundaries');
      await _saveCustomGridPrefs();
      return;
    }

    if (colJson != null && rowJson != null) {
      try {
        final List<double> colList = (jsonDecode(colJson) as List)
            .map((e) => (e as num).toDouble())
            .toList();
        final List<double> rowList = (jsonDecode(rowJson) as List)
            .map((e) => (e as num).toDouble())
            .toList();

        if (!_isValidBoundarySet(
              colList,
              cellCount: colList.length - 1,
              maxValue: _trayWidthCm,
            ) ||
            !_isValidBoundarySet(
              rowList,
              cellCount: rowList.length - 1,
              maxValue: _trayHeightCm,
            )) {
          throw const FormatException('Invalid saved grid boundaries');
        }

        if (mounted) {
          setState(() {
            _customColBoundaries = colList;
            _customRowBoundaries = rowList;
            _gridSaved = saved;
            _uniformRows = uniformRows;
            _uniformCols = uniformCols;
            _globalLineLengthScale = globalLineScale;
            _lineLengthStep = lineStep;
            _syncEggDataToGrid();
          });
          _lineLengthStepController.text = lineStep.toStringAsFixed(1);
        }
      } catch (e) {
        debugPrint('Failed to load grid prefs: $e — using defaults');
        // Keep defaults; optionally clear corrupted prefs
        await prefs.remove('custom_col_boundaries');
        await prefs.remove('custom_row_boundaries');
      }
    }
  }

  Future<void> _saveCustomGridPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      'custom_col_boundaries',
      jsonEncode(_customColBoundaries),
    );
    await prefs.setString(
      'custom_row_boundaries',
      jsonEncode(_customRowBoundaries),
    );
    await prefs.setBool('grid_saved', _gridSaved);
    await prefs.setBool('uniform_rows', _uniformRows);
    await prefs.setBool('uniform_cols', _uniformCols);
    await prefs.setDouble('global_line_length_scale', _globalLineLengthScale);
    await prefs.setDouble('line_length_step', _lineLengthStep);
    await prefs.setInt('grid_default_version', _gridDefaultVersion);
  }

  void _adjustBoundary(double delta) {
    if (_selectedBoundaryIndex == null) return;
    final idx = _selectedBoundaryIndex!;
    setState(() {
      if (_selectedBoundaryIsCol) {
        if (_uniformCols) {
          // Uniform scaling for columns: adjust spacing, keep first boundary fixed
          final n = _customColBoundaries.length;
          final start = _customColBoundaries.first;
          final currentSpacing = (_customColBoundaries.last - start) / (n - 1);
          final maxSpacing = (_trayWidthCm - start) / (n - 1);
          final newSpacing = (currentSpacing + delta).clamp(0.2, maxSpacing);
          _customColBoundaries = List<double>.generate(
            n,
            (i) => start + i * newSpacing,
          );
        } else {
          final minVal = idx > 0 ? _customColBoundaries[idx - 1] + 0.2 : 0.0;
          final maxVal = idx < _customColBoundaries.length - 1
              ? _customColBoundaries[idx + 1] - 0.2
              : _trayWidthCm;
          final updated = List<double>.from(_customColBoundaries);
          updated[idx] = (_customColBoundaries[idx] + delta).clamp(
            minVal,
            maxVal,
          );
          _customColBoundaries = updated;
        }
      } else {
        if (_uniformRows) {
          // Uniform scaling for rows: adjust spacing, keep first boundary fixed
          final n = _customRowBoundaries.length;
          final start = _customRowBoundaries.first;
          final currentSpacing = (_customRowBoundaries.last - start) / (n - 1);
          final maxSpacing = (_trayHeightCm - start) / (n - 1);
          final newSpacing = (currentSpacing + delta).clamp(0.2, maxSpacing);
          _customRowBoundaries = List<double>.generate(
            n,
            (i) => start + i * newSpacing,
          );
        } else {
          final minVal = idx > 0 ? _customRowBoundaries[idx - 1] + 0.2 : 0.0;
          final maxVal = idx < _customRowBoundaries.length - 1
              ? _customRowBoundaries[idx + 1] - 0.2
              : _trayHeightCm;
          final updated = List<double>.from(_customRowBoundaries);
          updated[idx] = (_customRowBoundaries[idx] + delta).clamp(
            minVal,
            maxVal,
          );
          _customRowBoundaries = updated;
        }
      }
      _gridSaved = false;
    });
    _saveCustomGridPrefs();
  }

  void _adjustLineLength(double delta) {
    setState(() {
      _globalLineLengthScale = (_globalLineLengthScale + delta).clamp(
        0.1,
        1.0,
      ); // min 10%, max 100%
    });
    _saveCustomGridPrefs();
  }

  void _toggleUniformAxis({required bool columns}) {
    setState(() {
      if (columns) {
        _uniformCols = !_uniformCols;
        if (_uniformCols) {
          _customColBoundaries = _uniformBoundaries(_customColBoundaries);
        }
      } else {
        _uniformRows = !_uniformRows;
        if (_uniformRows) {
          _customRowBoundaries = _uniformBoundaries(_customRowBoundaries);
        }
      }
      _gridSaved = false;
      _syncEggDataToGrid();
    });
    _saveCustomGridPrefs();
  }

  List<double> _uniformBoundaries(List<double> boundaries) {
    final first = boundaries.first;
    final last = boundaries.last;
    final spacing = (last - first) / (boundaries.length - 1);
    return List<double>.generate(boundaries.length, (i) => first + i * spacing);
  }

  // Compress JPEG image to reduce size before storing in SharedPreferences
  Future<Uint8List> _compressImage(Uint8List bytes) async {
    try {
      var image = img.decodeImage(bytes);
      if (image == null) return bytes;

      // Limit max dimension to 640px (maintains aspect)
      const maxDim = 640;
      if (image.width > maxDim || image.height > maxDim) {
        image = image.width >= image.height
            ? img.copyResize(image, width: maxDim)
            : img.copyResize(image, height: maxDim);
      }

      // Encode with 70% quality
      final compressed = Uint8List.fromList(img.encodeJpg(image, quality: 70));
      debugPrint(
        'Image compressed: ${bytes.length} -> ${compressed.length} bytes',
      );
      return compressed;
    } catch (e) {
      debugPrint('Compression error: $e');
      return bytes; // fallback to original
    }
  }

  Future<void> _saveAndApplyGrid() async {
    setState(() => _gridSaved = true);
    await _saveCustomGridPrefs();
    final p4Synced = await _sendCustomGridToP4();

    final colRange =
        '${_customColBoundaries.first.toStringAsFixed(1)}-${_customColBoundaries.last.toStringAsFixed(1)} cm';
    final rowRange =
        '${_customRowBoundaries.first.toStringAsFixed(1)}-${_customRowBoundaries.last.toStringAsFixed(1)} cm';

    if (!mounted) return;
    unawaited(
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) => AlertDialog(
          backgroundColor: _appCardColor(dialogContext),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(22),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 64,
                height: 64,
                decoration: BoxDecoration(
                  color: const Color(0xFF00C853).withValues(alpha: 0.14),
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.check_circle_rounded,
                  color: Color(0xFF00C853),
                  size: 42,
                ),
              ),
              const SizedBox(height: 16),
              Text(
                'Grid Saved',
                style: TextStyle(
                  color: _appTextColor(dialogContext),
                  fontSize: 20,
                  fontWeight: FontWeight.w900,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                p4Synced
                    ? 'Saved to phone and P4\nX $colRange | Y $rowRange'
                    : 'Saved to phone only\nP4 sync skipped or offline\nX $colRange | Y $rowRange',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: _appMutedTextColor(dialogContext),
                  height: 1.35,
                ),
              ),
            ],
          ),
        ),
      ),
    );

    await Future.delayed(const Duration(milliseconds: 1300));
    if (!mounted) return;
    final navigator = Navigator.of(context, rootNavigator: true);
    if (navigator.canPop()) navigator.pop();
    _openMainSection(0);
  }

  Future<void> _confirmResetGridToDefault() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          backgroundColor: _appCardColor(dialogContext),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
          ),
          title: Row(
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: const Color(0xFFFF5252).withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(13),
                ),
                child: const Icon(
                  Icons.warning_amber_rounded,
                  color: Color(0xFFFF5252),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Reset custom grid?',
                  style: TextStyle(
                    color: _appTextColor(dialogContext),
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
            ],
          ),
          content: Text(
            'This will replace your custom columns, rows, line length, and grid settings with the default layout.',
            style: TextStyle(
              color: _appMutedTextColor(dialogContext),
              height: 1.35,
            ),
          ),
          actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Cancel'),
            ),
            FilledButton.icon(
              onPressed: () => Navigator.pop(dialogContext, true),
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFFFF5252),
                foregroundColor: Colors.white,
              ),
              icon: const Icon(Icons.refresh_rounded, size: 18),
              label: const Text('Reset'),
            ),
          ],
        );
      },
    );

    if (confirmed == true && mounted) {
      await _resetGridToDefault();
    }
  }

  Future<void> _resetGridToDefault() async {
    setState(() {
      _customColBoundaries = List<double>.from(_defaultColBoundaries);
      _customRowBoundaries = List<double>.from(_defaultRowBoundaries);
      _selectedBoundaryIndex = null;
      _gridSaved = false;
      _uniformRows = false;
      _uniformCols = false;
      _globalLineLengthScale = 1.0;
      _lineLengthStep = 0.1;
      _lineLengthStepController.text = '0.1';
      _adjustStep = 0.5;
      _adjustStepController.text = '0.5';
      _syncEggDataToGrid();
    });
    await _saveCustomGridPrefs();
    final p4Synced = await _resetP4GridConfig();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          p4Synced
              ? 'Grid reset on phone and P4'
              : 'Grid reset on phone only. P4 offline or not flashed.',
        ),
        backgroundColor: Colors.orange,
      ),
    );
  }

  // Dynamic grid count configuration
  void _setGridAxisCount(int count) {
    if (count < 2 || count > 50) return; // reasonable limits
    final traySize = _selectedCountIsCol ? _trayWidthCm : _trayHeightCm;
    final step = traySize / count;
    setState(() {
      final boundaries = List<double>.generate(count + 1, (i) => i * step);
      if (_selectedCountIsCol) {
        _customColBoundaries = boundaries;
        _uniformCols = false;
      } else {
        _customRowBoundaries = boundaries;
        _uniformRows = false;
      }
      _selectedBoundaryIndex = null;
      _gridSaved = false;
      _syncEggDataToGrid();
    });
    _saveCustomGridPrefs();
  }

  void _adjustGridAxisCount(int delta) {
    final currentCount = _selectedCountIsCol
        ? _customColBoundaries.length - 1
        : _customRowBoundaries.length - 1;
    _setGridAxisCount((currentCount + delta).clamp(2, 50).toInt());
  }

  Widget _buildRowCountStepper() {
    final count = _selectedCountIsCol
        ? _customColBoundaries.length - 1
        : _customRowBoundaries.length - 1;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: _appCardColor(context),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: _appOutlineColor(context)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'GRID COUNT',
            style: TextStyle(
              color: _appMutedTextColor(context),
              fontSize: 11,
              fontWeight: FontWeight.w900,
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              _buildCountAxisButton('X', _selectedCountIsCol, () {
                setState(() => _selectedCountIsCol = true);
              }),
              const SizedBox(width: 6),
              _buildCountAxisButton('Y', !_selectedCountIsCol, () {
                setState(() => _selectedCountIsCol = false);
              }),
              const Spacer(),
              _buildRowCountButton(
                icon: Icons.remove_rounded,
                delta: -1,
                enabled: count > 2,
              ),
              const SizedBox(width: 8),
              Container(
                width: 58,
                height: 34,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: _appPanelColor(context),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: _appDividerColor(context)),
                ),
                child: Text(
                  '$count',
                  style: TextStyle(
                    color: _appTextColor(context),
                    fontSize: 13,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              _buildRowCountButton(
                icon: Icons.add_rounded,
                delta: 1,
                enabled: count < 50,
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildCountAxisButton(
    String label,
    bool selected,
    VoidCallback onTap,
  ) {
    return SizedBox(
      width: 34,
      height: 34,
      child: FilledButton(
        onPressed: onTap,
        style: FilledButton.styleFrom(
          backgroundColor: selected
              ? const Color(0xFF2979FF)
              : _appPanelColor(context),
          foregroundColor: selected
              ? Colors.white
              : _appMutedTextColor(context),
          padding: EdgeInsets.zero,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(9),
            side: BorderSide(
              color: selected
                  ? const Color(0xFF2979FF)
                  : _appOutlineColor(context),
            ),
          ),
        ),
        child: Text(
          label,
          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w900),
        ),
      ),
    );
  }

  Widget _buildRowCountButton({
    required IconData icon,
    required int delta,
    required bool enabled,
  }) {
    return SizedBox(
      width: 34,
      height: 34,
      child: IconButton(
        padding: EdgeInsets.zero,
        icon: Icon(icon, size: 18),
        color: _appMutedTextColor(context),
        disabledColor: _appFaintTextColor(context),
        onPressed: enabled ? () => _adjustGridAxisCount(delta) : null,
        tooltip: delta > 0 ? 'Add count' : 'Remove count',
      ),
    );
  }

  // Grid customization
  // Onboarding
  Future<void> _showOnboardingDialog({required bool demoMode}) async {
    final completed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => _OnboardingDialog(demoMode: demoMode),
    );
    if (completed == true) {
      await _markOnboardingComplete(demoMode: demoMode);
    }
    if (!mounted || demoMode) return;
    if (completed != true) return;
    await Future.delayed(const Duration(milliseconds: 350));
    if (!mounted) return;
    await _showNotificationPermissionDialog();
  }

  // Backup / Export
  Future<void> _exportBackup() async {
    try {
      final data = {
        'version': 1,
        'exportDate': DateTime.now().toIso8601String(),
        'sessions': _sessions.map((s) => s.toJson()).toList(),
        'eggCounterHistory': _eggCounterHistory
            .map((record) => record.toJson())
            .toList(),
      };
      final jsonBytes = utf8.encode(jsonEncode(data));
      final dir = await getTemporaryDirectory();
      final file = File(
        '${dir.path}/egg_backup_${DateTime.now().millisecondsSinceEpoch}.json',
      );
      await file.writeAsBytes(jsonBytes);

      await Share.shareXFiles([
        XFile(file.path, mimeType: 'application/json'),
      ], subject: 'Egg Incubator Session Backup');
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Backup failed: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  // Delete helpers
  void _showDeleteOptions() {
    showModalBottomSheet(
      context: context,
      backgroundColor: _appCardColor(context),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) => Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Delete Options',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 16),
            ListTile(
              leading: const Icon(Icons.delete_forever, color: Colors.red),
              title: const Text('Delete All'),
              onTap: () {
                Navigator.pop(context);
                _confirmDeleteAll();
              },
            ),
            ListTile(
              leading: const Icon(Icons.calendar_month, color: Colors.orange),
              title: const Text('Delete This Month'),
              onTap: () {
                Navigator.pop(context);
                _deleteThisMonth();
              },
            ),
            ListTile(
              leading: const Icon(Icons.view_week, color: Colors.yellow),
              title: const Text('Delete This Week'),
              onTap: () {
                Navigator.pop(context);
                _deleteThisWeek();
              },
            ),
            ListTile(
              leading: const Icon(Icons.today, color: Colors.green),
              title: const Text('Delete Today'),
              onTap: () {
                Navigator.pop(context);
                _deleteToday();
              },
            ),
            ListTile(
              leading: const Icon(Icons.check_box, color: Colors.blue),
              title: const Text('Select to Delete'),
              onTap: () {
                Navigator.pop(context);
                setState(() => _isSelectionMode = true);
              },
            ),
            ListTile(
              leading: const Icon(Icons.date_range, color: Colors.purple),
              title: const Text('Custom Date Range'),
              onTap: () {
                Navigator.pop(context);
                _showCustomDateDelete();
              },
            ),
          ],
        ),
      ),
    );
  }

  void _confirmDeleteAll() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: _appCardColor(context),
        title: const Text('Delete All?'),
        content: const Text('This will permanently delete all sessions.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              setState(() {
                _sessions.clear();
                _isSelectionMode = false;
                _selectedSessions.clear();
              });
              _saveSessions();
              Navigator.pop(context);
            },
            child: const Text('Delete', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
  }

  void _deleteThisMonth() {
    final now = DateTime.now();
    setState(() {
      _sessions.removeWhere(
        (s) => s.timestamp.month == now.month && s.timestamp.year == now.year,
      );
    });
    _saveSessions();
  }

  void _deleteThisWeek() {
    final weekStart = DateTime.now().subtract(const Duration(days: 7));
    setState(
      () => _sessions.removeWhere((s) => s.timestamp.isAfter(weekStart)),
    );
    _saveSessions();
  }

  void _deleteToday() {
    final now = DateTime.now();
    final todayStart = DateTime(now.year, now.month, now.day);
    setState(
      () => _sessions.removeWhere((s) => s.timestamp.isAfter(todayStart)),
    );
    _saveSessions();
  }

  void _showCustomDateDelete() async {
    final now = DateTime.now();
    final DateTimeRange? picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2020),
      lastDate: now,
      initialDateRange: DateTimeRange(
        start: now.subtract(const Duration(days: 7)),
        end: now,
      ),
      builder: (context, child) {
        final scheme = Theme.of(context).colorScheme;
        return Theme(
          data: Theme.of(context).copyWith(
            colorScheme: scheme.copyWith(
              primary: const Color(0xFF2979FF),
              onPrimary: Colors.white,
              surface: _appCardColor(context),
              onSurface: _appTextColor(context),
            ),
          ),
          child: child!,
        );
      },
    );
    if (picked != null && mounted) {
      setState(() {
        _sessions.removeWhere(
          (s) =>
              s.timestamp.isAfter(picked.start) &&
              s.timestamp.isBefore(picked.end.add(const Duration(days: 1))),
        );
      });
      _saveSessions();
    }
  }

  void _deleteSelected() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: _appCardColor(context),
        title: const Text('Delete Selected?'),
        content: Text('Delete ${_selectedSessions.length} session(s)?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              setState(() {
                _sessions.removeWhere((s) => _selectedSessions.contains(s.id));
                _isSelectionMode = false;
                _selectedSessions.clear();
              });
              _saveSessions();
              Navigator.pop(context);
            },
            child: const Text('Delete', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
  }

  void _viewSession(EggSession session) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) =>
            SessionDetailPage(session: session, allSessions: _sessions),
      ),
    );
  }

  // Sound / countdown
  Future<void> _playCompletionSound() async {
    try {
      await HapticFeedback.heavyImpact();
      await Future.delayed(const Duration(milliseconds: 100));
      await HapticFeedback.heavyImpact();
      await Future.delayed(const Duration(milliseconds: 100));
      await HapticFeedback.heavyImpact();
    } catch (e) {
      debugPrint('Haptic error: $e');
    }
  }

  void _startCountdown() {
    _countdownTimer?.cancel();
    _countdownTotal = _candlingCooldownSeconds;
    _countdown = _countdownTotal;
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (mounted) {
        setState(() => _countdown--);
        if (_countdown <= 0) {
          timer.cancel();
          _countdownTimer = null;
        }
      } else {
        timer.cancel();
        _countdownTimer = null;
      }
    });
  }

  // Stat helpers
  String _getOverallFertilityRate() {
    int totalFertile = 0, totalInfertile = 0;
    for (var s in _sessions) {
      totalFertile += s.fertileCount;
      totalInfertile += s.infertileCount;
    }
    final total = totalFertile + totalInfertile;
    if (total == 0) return '0%';
    return '${(totalFertile * 100 / total).toStringAsFixed(1)}%';
  }

  int _getThisWeekCount() {
    final weekStart = DateTime.now().subtract(const Duration(days: 7));
    return _sessions.where((s) => s.timestamp.isAfter(weekStart)).length;
  }

  int _getMaxBarValue(
    List<String> last7Days,
    Map<String, List<EggSession>> sessionsByDay,
  ) {
    int maxVal = 0;
    for (var day in last7Days) {
      int total = (sessionsByDay[day] ?? []).fold(
        0,
        (s, e) => s + e.fertileCount + e.infertileCount,
      );
      if (total > maxVal) maxVal = total;
    }
    return maxVal > 0 ? maxVal : 10;
  }

  String get _pageTitle {
    switch (_currentIndex) {
      case 1:
        return _t('history').toUpperCase();
      case 2:
        return _t('gridCustom').toUpperCase();
      case 3:
        return 'DS-CAPTURING';
      case 4:
        return 'LED TEST';
      case 5:
        return 'FERTILITY DS';
      case 6:
        return 'IMAGE AI TEST';
      default:
        return 'Candling';
    }
  }

  void _openMainSection(int index) {
    if (_currentIndex == index) return;
    if (_currentIndex == 5 && _isFertilityDatasetCapturing) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please wait for fertility capture to finish.'),
        ),
      );
      return;
    }
    if (_currentIndex == 5 && index != 5) {
      _stopFertilityDatasetAutoCapture(showSnack: false);
    }

    if (_currentIndex == 0 && index != 0) {
      _sensorTimer?.cancel();
      setState(() {
        _isStreaming = false;
        _streamKey++;
      });
    }

    if (_currentIndex == 2 && index != 2) {
      _referenceTrashOpacityTimer?.cancel();
      setState(() {
        _gridCalibrationImage = null;
        _referenceTrashDimmed = false;
      });
    }

    if (_currentIndex == 3 && index != 3) {
      _stopDatasetAutoCapture(showSnack: false);
    }

    if (index == 4 && _currentIndex != 4) {
      _sensorTimer?.cancel();
      setState(() {
        _isStreaming = false;
        _streamKey++;
      });
      unawaited(_refreshLedControllerStatus());
    }

    if (index == 0 && _currentIndex != 0) {
      setState(() {
        if (!_streamManuallyOff) {
          _isStreaming = true;
          _streamFrameReceived = false;
          _streamKey++;
        }
      });
      _startSensorPolling();
      _startPeriodicP4Sync();
    }

    if (index == 2 && _currentIndex != 2) {
      _sensorTimer?.cancel();
      setState(() {
        _isStreaming = false;
        _streamKey++;
        _selectedBoundaryIsCol = true;
        if (_selectedBoundaryIndex != null &&
            _selectedBoundaryIndex! >= _customColBoundaries.length) {
          _selectedBoundaryIndex = null;
        }
      });
    }

    if (index == 3 && _currentIndex != 3) {
      _sensorTimer?.cancel();
      setState(() {
        _isStreaming = false;
        _streamKey++;
      });
    }

    if (index == 5 && _currentIndex != 5) {
      _sensorTimer?.cancel();
      _p4PollTimer?.cancel();
      setState(() {
        _isStreaming = false;
        _streamKey++;
      });
      unawaited(_syncEggGridFromP4());
    }

    if (index == 6 && _currentIndex != 6) {
      _sensorTimer?.cancel();
      _p4PollTimer?.cancel();
      setState(() {
        _isStreaming = false;
        _streamKey++;
      });
    }

    setState(() => _currentIndex = index);
  }

  Widget _buildMenuItem({
    required IconData icon,
    required String label,
    required bool selected,
    required VoidCallback onTap,
  }) {
    final iconColor = selected
        ? const Color(0xFF2979FF)
        : _appMutedTextColor(context);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Material(
        color: selected
            ? const Color(0xFF2979FF).withValues(alpha: 0.12)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(14),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            child: Row(
              children: [
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: selected
                        ? const Color(0xFF2979FF).withValues(alpha: 0.14)
                        : _appPanelColor(context),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(icon, color: iconColor, size: 20),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Text(
                    label,
                    style: TextStyle(
                      color: selected
                          ? const Color(0xFF2979FF)
                          : _appTextColor(context),
                      fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
                    ),
                  ),
                ),
                if (selected)
                  const Icon(
                    Icons.radio_button_checked,
                    size: 16,
                    color: Color(0xFF2979FF),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildDrawerSectionLabel(String label, IconData icon) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 14, 24, 6),
      child: Row(
        children: [
          Icon(icon, size: 15, color: _appFaintTextColor(context)),
          const SizedBox(width: 8),
          Text(
            label.toUpperCase(),
            style: TextStyle(
              color: _appFaintTextColor(context),
              fontSize: 11,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.8,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDrawerMetric({
    required IconData icon,
    required String label,
    required String value,
  }) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 7),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: Colors.white.withValues(alpha: 0.10)),
        ),
        child: Row(
          children: [
            Icon(icon, color: Colors.white, size: 16),
            const SizedBox(width: 6),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    value,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 12,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white70, fontSize: 9),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAppDrawer() {
    final now = DateTime.now();
    final todayStart = DateTime(now.year, now.month, now.day);
    final last3Start = todayStart.subtract(const Duration(days: 2));
    final todaySessions = _sessions
        .where((s) => !s.timestamp.isBefore(todayStart))
        .length;
    final last3Sessions = _sessions
        .where((s) => !s.timestamp.isBefore(last3Start))
        .toList();
    final last3Fertile = last3Sessions.fold<int>(
      0,
      (sum, s) => sum + s.fertileCount,
    );
    final last3Infertile = last3Sessions.fold<int>(
      0,
      (sum, s) => sum + s.infertileCount,
    );
    final last3Analyzed = last3Fertile + last3Infertile;
    final last3Rate = last3Analyzed == 0
        ? '--'
        : '${(last3Fertile * 100 / last3Analyzed).round()}%';
    final lastScan = _sessions.isEmpty
        ? null
        : _sessions.reduce(
            (latest, session) =>
                session.timestamp.isAfter(latest.timestamp) ? session : latest,
          );

    return Drawer(
      width: 310,
      backgroundColor: _appCardColor(context),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.horizontal(right: Radius.circular(26)),
      ),
      child: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 16, 18, 12),
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: const Color(0xFF2979FF),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        ClipRRect(
                          borderRadius: BorderRadius.circular(16),
                          child: Image.asset(
                            'assets/egg_ai_icon.png',
                            width: 54,
                            height: 54,
                            fit: BoxFit.cover,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                'Candling',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 22,
                                  fontWeight: FontWeight.w900,
                                ),
                              ),
                              const SizedBox(height: 5),
                              Row(
                                children: [
                                  Icon(
                                    _isConnectedToCorrectSSID
                                        ? Icons.check_circle_rounded
                                        : Icons.info_rounded,
                                    color: Colors.white70,
                                    size: 15,
                                  ),
                                  const SizedBox(width: 5),
                                  Expanded(
                                    child: Text(
                                      _isConnectedToCorrectSSID
                                          ? _t('connectedHub')
                                          : _t('readyFarm'),
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        color: Colors.white70,
                                        fontSize: 12,
                                        height: 1.2,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Container(
                      height: 1,
                      color: Colors.white.withValues(alpha: 0.16),
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        _buildDrawerMetric(
                          icon: Icons.today_rounded,
                          label: _t('today'),
                          value: '$todaySessions scans',
                        ),
                        const SizedBox(width: 8),
                        _buildDrawerMetric(
                          icon: Icons.calendar_view_week_rounded,
                          label: _t('threeDays'),
                          value: '${last3Sessions.length} scans',
                        ),
                      ],
                    ),
                    const SizedBox(height: 7),
                    Row(
                      children: [
                        _buildDrawerMetric(
                          icon: Icons.trending_up_rounded,
                          label: _t('fertility'),
                          value: last3Rate,
                        ),
                        const SizedBox(width: 8),
                        _buildDrawerMetric(
                          icon: Icons.schedule_rounded,
                          label: _t('latest'),
                          value: lastScan == null
                              ? '--'
                              : DateFormat('h:mm a').format(lastScan.timestamp),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            Expanded(
              child: ListView(
                padding: EdgeInsets.zero,
                children: [
                  _buildDrawerSectionLabel(_t('mainMenu'), Icons.apps_rounded),
                  _buildMenuItem(
                    icon: Icons.dashboard_rounded,
                    label: _t('dashboard'),
                    selected: _currentIndex == 0,
                    onTap: () {
                      Navigator.pop(context);
                      _openMainSection(0);
                    },
                  ),
                  _buildMenuItem(
                    icon: Icons.history_rounded,
                    label: _t('history'),
                    selected: _currentIndex == 1,
                    onTap: () {
                      Navigator.pop(context);
                      _openMainSection(1);
                    },
                  ),
                  _buildMenuItem(
                    icon: Icons.grid_view_rounded,
                    label: _t('gridCustom'),
                    selected: _currentIndex == 2,
                    onTap: () {
                      Navigator.pop(context);
                      _openMainSection(2);
                    },
                  ),
                  _buildMenuItem(
                    icon: Icons.dataset_rounded,
                    label: 'DS-Capturing',
                    selected: _currentIndex == 3,
                    onTap: () {
                      Navigator.pop(context);
                      _openMainSection(3);
                    },
                  ),
                  _buildMenuItem(
                    icon: Icons.biotech_rounded,
                    label: 'Fertility DS',
                    selected: _currentIndex == 5,
                    onTap: () {
                      Navigator.pop(context);
                      _openMainSection(5);
                    },
                  ),
                  _buildMenuItem(
                    icon: Icons.image_search_rounded,
                    label: 'Image AI Test',
                    selected: _currentIndex == 6,
                    onTap: () {
                      Navigator.pop(context);
                      _openMainSection(6);
                    },
                  ),
                  _buildMenuItem(
                    icon: Icons.lightbulb_rounded,
                    label: 'LED Test',
                    selected: _currentIndex == 4,
                    onTap: () {
                      Navigator.pop(context);
                      _openMainSection(4);
                    },
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 18,
                      vertical: 6,
                    ),
                    child: Divider(color: _appOutlineColor(context)),
                  ),
                  _buildDrawerSectionLabel(
                    _t('tools'),
                    Icons.construction_rounded,
                  ),
                  _buildMenuItem(
                    icon: Icons.settings_rounded,
                    label: _t('settings'),
                    selected: false,
                    onTap: () {
                      Navigator.pop(context);
                      _showSettingsSheet();
                    },
                  ),
                  _buildMenuItem(
                    icon: Icons.help_rounded,
                    label: _t('faq'),
                    selected: false,
                    onTap: () {
                      Navigator.pop(context);
                      _showFaqSheet();
                    },
                  ),
                  _buildMenuItem(
                    icon: Icons.groups_rounded,
                    label: _t('aboutUs'),
                    selected: false,
                    onTap: () {
                      Navigator.pop(context);
                      _showAboutUsSheet();
                    },
                  ),
                  const SizedBox(height: 22),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showSettingsSheet() {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      backgroundColor: _appCardColor(context),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (sheetContext) {
        Widget settingTile({
          required IconData icon,
          required Color color,
          required String title,
          required String subtitle,
          VoidCallback? onTap,
        }) {
          return Container(
            margin: const EdgeInsets.only(bottom: 10),
            decoration: BoxDecoration(
              color: _appPanelColor(sheetContext),
              borderRadius: BorderRadius.circular(16),
            ),
            child: ListTile(
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 14,
                vertical: 6,
              ),
              leading: Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Icon(icon, color: color, size: 21),
              ),
              title: Text(
                title,
                style: TextStyle(
                  color: _appTextColor(sheetContext),
                  fontWeight: FontWeight.w800,
                ),
              ),
              subtitle: Text(
                subtitle,
                style: TextStyle(color: _appMutedTextColor(sheetContext)),
              ),
              trailing: onTap == null
                  ? null
                  : Icon(
                      Icons.chevron_right_rounded,
                      color: _appFaintTextColor(sheetContext),
                    ),
              onTap: onTap,
            ),
          );
        }

        return SafeArea(
          child: DraggableScrollableSheet(
            expand: false,
            initialChildSize: 0.74,
            minChildSize: 0.42,
            maxChildSize: 0.9,
            builder: (context, scrollController) {
              return ListView(
                controller: scrollController,
                padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
                children: [
                  Row(
                    children: [
                      Container(
                        width: 42,
                        height: 42,
                        decoration: BoxDecoration(
                          color: const Color(
                            0xFF2979FF,
                          ).withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: const Icon(
                          Icons.settings_rounded,
                          color: Color(0xFF2979FF),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Text(
                        _t('settings'),
                        style: TextStyle(
                          color: _appTextColor(sheetContext),
                          fontSize: 20,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  settingTile(
                    icon: _isConnectedToCorrectSSID
                        ? Icons.wifi_rounded
                        : Icons.wifi_off_rounded,
                    color: const Color(0xFF2979FF),
                    title: _t('openWifi'),
                    subtitle: _incubatorNetworkHeld
                        ? _incubatorNetworkStatus
                        : _isConnectedToCorrectSSID
                        ? '${_t('connectedHub')}: $_currentSsid'
                        : _t('connectHub'),
                    onTap: () {
                      Navigator.pop(sheetContext);
                      _openWifiSettings();
                    },
                  ),
                  settingTile(
                    icon: Icons.refresh_rounded,
                    color: const Color(0xFF00A86B),
                    title: _t('refreshApp'),
                    subtitle: _t('refreshSubtitle'),
                    onTap: () {
                      Navigator.pop(sheetContext);
                      _refreshApp();
                    },
                  ),
                  settingTile(
                    icon: Icons.troubleshoot_rounded,
                    color: const Color(0xFF7C4DFF),
                    title: 'Diagnostics',
                    subtitle:
                        'WiFi, stream, P4, LEDs, Sub-Incubator, grid, and timing',
                    onTap: () {
                      Navigator.pop(sheetContext);
                      _showDiagnosticsSheet();
                    },
                  ),
                  settingTile(
                    icon: Icons.backup_rounded,
                    color: const Color(0xFFFFA000),
                    title: _t('backupData'),
                    subtitle: _t('backupSubtitle'),
                    onTap: () {
                      Navigator.pop(sheetContext);
                      _exportBackup();
                    },
                  ),
                  settingTile(
                    icon: Icons.translate_rounded,
                    color: const Color(0xFF2979FF),
                    title: _t('language'),
                    subtitle: '${_t('languageSubtitle')} ($_languageName)',
                    onTap: () {
                      Navigator.pop(sheetContext);
                      _showLanguageSheet();
                    },
                  ),
                  settingTile(
                    icon: Icons.verified_rounded,
                    color: const Color(0xFF7C4DFF),
                    title: _t('appVersion'),
                    subtitle: 'Candling thesis build 1.0.0',
                  ),
                ],
              );
            },
          ),
        );
      },
    );
  }

  void _showLanguageSheet() {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      backgroundColor: _appCardColor(context),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (sheetContext) {
        Widget languageTile(String code, String title, String subtitle) {
          final selected = _languageCode == code;
          return Container(
            margin: const EdgeInsets.fromLTRB(20, 0, 20, 10),
            decoration: BoxDecoration(
              color: selected
                  ? const Color(0xFF2979FF).withValues(alpha: 0.12)
                  : _appPanelColor(sheetContext),
              borderRadius: BorderRadius.circular(16),
            ),
            child: ListTile(
              leading: Icon(
                selected
                    ? Icons.radio_button_checked_rounded
                    : Icons.radio_button_off_rounded,
                color: selected
                    ? const Color(0xFF2979FF)
                    : _appMutedTextColor(sheetContext),
              ),
              title: Text(
                title,
                style: TextStyle(
                  color: _appTextColor(sheetContext),
                  fontWeight: FontWeight.w800,
                ),
              ),
              subtitle: Text(
                subtitle,
                style: TextStyle(color: _appMutedTextColor(sheetContext)),
              ),
              onTap: () {
                Navigator.pop(sheetContext);
                unawaited(_setLanguage(code));
              },
            ),
          );
        }

        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.only(bottom: 14),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 4, 20, 14),
                  child: Row(
                    children: [
                      Container(
                        width: 42,
                        height: 42,
                        decoration: BoxDecoration(
                          color: const Color(
                            0xFF2979FF,
                          ).withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: const Icon(
                          Icons.translate_rounded,
                          color: Color(0xFF2979FF),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Text(
                        _t('language'),
                        style: TextStyle(
                          color: _appTextColor(sheetContext),
                          fontSize: 20,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                    ],
                  ),
                ),
                languageTile('en', 'English', 'Default language'),
                languageTile('tl', 'Tagalog', 'Para sa mas madaling paggamit'),
                languageTile('ceb', 'Bisaya', 'Para sa lokal nga paggamit'),
              ],
            ),
          ),
        );
      },
    );
  }

  void _showDiagnosticsSheet() {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      backgroundColor: _appCardColor(context),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (sheetContext) {
        Widget row(IconData icon, String label, String value, Color color) {
          return Container(
            margin: const EdgeInsets.only(bottom: 10),
            padding: const EdgeInsets.all(13),
            decoration: BoxDecoration(
              color: _appPanelColor(sheetContext),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Row(
              children: [
                Icon(icon, color: color, size: 22),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        label,
                        style: TextStyle(
                          color: _appMutedTextColor(sheetContext),
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        value,
                        style: TextStyle(
                          color: _appTextColor(sheetContext),
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          );
        }

        final gridTime = _lastGridSyncTime == null
            ? ''
            : ' at ${DateFormat('h:mm:ss a').format(_lastGridSyncTime!)}';
        final gridMs = _lastGridSyncMs == null ? '' : ' (${_lastGridSyncMs}ms)';

        return SafeArea(
          child: DraggableScrollableSheet(
            expand: false,
            initialChildSize: 0.78,
            minChildSize: 0.45,
            maxChildSize: 0.92,
            builder: (context, controller) => ListView(
              controller: controller,
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
              children: [
                Text(
                  'Diagnostics',
                  style: TextStyle(
                    color: _appTextColor(sheetContext),
                    fontSize: 22,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 14),
                row(
                  Icons.play_circle_rounded,
                  'Mode',
                  _demoMode ? 'Demo mode' : 'Actual mode',
                  const Color(0xFF2979FF),
                ),
                row(
                  Icons.wifi_rounded,
                  'WiFi',
                  _currentSsid.isEmpty ? 'Not detected' : _currentSsid,
                  _isConnectedToCorrectSSID
                      ? const Color(0xFF00A86B)
                      : Colors.orange,
                ),
                row(
                  Icons.camera_alt_rounded,
                  'S3 / Stream',
                  _s3Connected ? 'Reachable' : 'Not reachable',
                  _s3Connected ? const Color(0xFF00A86B) : Colors.red,
                ),
                row(
                  Icons.memory_rounded,
                  'P4',
                  _p4Connected ? 'Reachable' : 'Not reachable',
                  _p4Connected ? const Color(0xFF00A86B) : Colors.red,
                ),
                row(
                  Icons.lightbulb_rounded,
                  'LEDs',
                  _ledsConnected
                      ? 'Reachable | ${_ledActiveCount ?? 0} active'
                      : 'Not reachable',
                  _ledsConnected ? const Color(0xFF00A86B) : Colors.red,
                ),
                row(
                  Icons.thermostat_rounded,
                  'Sub-Incubator',
                  _subIncubatorConnected
                      ? 'Fresh ${_subIncubatorAgeMs == null ? '' : '(${(_subIncubatorAgeMs! / 1000).round()}s)'}'
                      : 'Not fresh',
                  _subIncubatorConnected ? const Color(0xFF00A86B) : Colors.red,
                ),
                row(
                  Icons.grid_view_rounded,
                  'Grid Sync',
                  '$_lastGridSyncStatus$gridMs$gridTime',
                  const Color(0xFFFFA000),
                ),
                row(
                  Icons.science_outlined,
                  'Classification',
                  'On-device Fertile / Infertile model',
                  const Color(0xFF00A86B),
                ),
                row(
                  Icons.timer_rounded,
                  'Last Scan Timing',
                  _lastTotalScanMs == null
                      ? 'No scan yet'
                      : 'Capture ${_lastCaptureMs ?? '--'}ms | Total ${_lastTotalScanMs}ms',
                  const Color(0xFF00A86B),
                ),
                row(
                  Icons.photo_camera_back_rounded,
                  'Last Capture',
                  _lastTotalScanMs == null
                      ? 'No capture yet'
                      : _sessions.isNotEmpty && _sessions.first.usedAi
                      ? '${_sessions.first.analyzedSlotCount} slots analyzed; saved to History'
                      : 'Saved to History; AI not run',
                  const Color(0xFF2979FF),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  void _showFaqSheet() {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      backgroundColor: _appCardColor(context),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (sheetContext) {
        Widget faq(IconData icon, String question, String answer) {
          return Container(
            width: double.infinity,
            margin: const EdgeInsets.only(bottom: 10),
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: _appPanelColor(sheetContext),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      width: 36,
                      height: 36,
                      decoration: BoxDecoration(
                        color: const Color(0xFF2979FF).withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Icon(
                        icon,
                        color: const Color(0xFF2979FF),
                        size: 20,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        question,
                        style: TextStyle(
                          color: _appTextColor(sheetContext),
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Padding(
                  padding: const EdgeInsets.only(left: 46),
                  child: Text(
                    answer,
                    style: TextStyle(
                      color: _appMutedTextColor(sheetContext),
                      height: 1.35,
                    ),
                  ),
                ),
              ],
            ),
          );
        }

        return SafeArea(
          child: DraggableScrollableSheet(
            expand: false,
            initialChildSize: 0.72,
            minChildSize: 0.45,
            maxChildSize: 0.92,
            builder: (context, controller) => ListView(
              controller: controller,
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
              children: [
                Row(
                  children: [
                    Container(
                      width: 42,
                      height: 42,
                      decoration: BoxDecoration(
                        color: const Color(0xFF2979FF).withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: const Icon(
                        Icons.help_rounded,
                        color: Color(0xFF2979FF),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Text(
                      _t('faq'),
                      style: TextStyle(
                        color: _appTextColor(sheetContext),
                        fontSize: 20,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                faq(
                  Icons.route_rounded,
                  _t('farmerGuide'),
                  _t('farmerGuideText'),
                ),
                faq(Icons.wifi_rounded, _t('wifiQuestion'), _t('wifiAnswer')),
                faq(
                  Icons.event_available_rounded,
                  _t('day7Question'),
                  _t('day7Answer'),
                ),
                faq(
                  Icons.grid_view_rounded,
                  _t('gridQuestion'),
                  _t('gridAnswer'),
                ),
                faq(
                  Icons.picture_as_pdf_rounded,
                  _t('reportQuestion'),
                  _t('reportAnswer'),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  void _showAboutUsSheet() {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      backgroundColor: _appCardColor(context),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (sheetContext) {
        Widget detail(IconData icon, String label, String value) {
          return Container(
            width: double.infinity,
            margin: const EdgeInsets.only(bottom: 10),
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: _appPanelColor(sheetContext),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 38,
                  height: 38,
                  decoration: BoxDecoration(
                    color: const Color(0xFF2979FF).withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(icon, color: const Color(0xFF2979FF), size: 20),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        label,
                        style: TextStyle(
                          color: _appMutedTextColor(sheetContext),
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        value,
                        style: TextStyle(
                          color: _appTextColor(sheetContext),
                          fontWeight: FontWeight.w800,
                          height: 1.28,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          );
        }

        return SafeArea(
          child: DraggableScrollableSheet(
            expand: false,
            initialChildSize: 0.78,
            minChildSize: 0.45,
            maxChildSize: 0.94,
            builder: (context, controller) => ListView(
              controller: controller,
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
              children: [
                Row(
                  children: [
                    Container(
                      width: 46,
                      height: 46,
                      decoration: BoxDecoration(
                        color: const Color(0xFF2979FF).withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(15),
                      ),
                      child: const Icon(
                        Icons.groups_rounded,
                        color: Color(0xFF2979FF),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Text(
                      _t('aboutUs'),
                      style: TextStyle(
                        color: _appTextColor(sheetContext),
                        fontSize: 20,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: const Color(0xFF2979FF),
                    borderRadius: BorderRadius.circular(18),
                  ),
                  child: const Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'AI-Powered Smart Poultry Incubator with Automated Fertility Detection for Enhanced Hatchability',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                          fontWeight: FontWeight.w900,
                          height: 1.25,
                        ),
                      ),
                      SizedBox(height: 8),
                      Text(
                        'Research project title - replacement classifier planned',
                        style: TextStyle(color: Colors.white70),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 14),
                detail(
                  Icons.school_rounded,
                  'School',
                  'PHINMA COC - Carmen Campus',
                ),
                detail(
                  Icons.engineering_rounded,
                  'Department',
                  'BS in Computer Engineering',
                ),
                detail(
                  Icons.person_rounded,
                  'Researchers',
                  'Justeen Gayle E. Bondoc\nIan Jay D. Mayake',
                ),
                detail(
                  Icons.supervisor_account_rounded,
                  'Thesis Adviser',
                  'Engr. Amir Hasan Bunza',
                ),
                detail(
                  Icons.agriculture_rounded,
                  'Beneficiary',
                  'Batinga Mini Farm',
                ),
                detail(
                  Icons.info_rounded,
                  'Project Purpose',
                  'This mobile build focuses on camera-assisted candling capture, incubation-day tracking, and research-grade reports with less egg handling. Fertile / Infertile classification will be added later using the replacement model; no classifier is currently installed on the phone.',
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  // BUILD
  @override
  Widget build(BuildContext context) {
    if (_isBooting) {
      return _buildStartupScreen();
    }
    if (_showModeSelect) {
      return _buildModeSelectScreen();
    }

    return PopScope(
      // Allow pop only when already on Camera tab and not in selection mode
      canPop:
          _currentIndex == 0 && !_isSelectionMode && !_isCounterSelectionMode,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return; // already handled by the system

        // Priority 1: exit selection mode before anything else
        if (_isSelectionMode) {
          setState(() {
            _isSelectionMode = false;
            _selectedSessions.clear();
          });
          return;
        }
        if (_isCounterSelectionMode) {
          setState(() {
            _isCounterSelectionMode = false;
            _selectedCounterRecords.clear();
          });
          return;
        }

        // Grid custom
        if (_currentIndex == 2) {
          _referenceTrashOpacityTimer?.cancel();
          setState(() {
            _gridCalibrationImage = null;
            _referenceTrashDimmed = false;
            _currentIndex = 0;
          });
          if (!_isStreaming && !_streamManuallyOff) {
            setState(() {
              _isStreaming = true;
              _streamFrameReceived = false;
              _streamKey++;
            });
          }
          _startSensorPolling();
          _startPeriodicP4Sync();
          return;
        }

        // Camera tab
        if (_currentIndex == 1) {
          setState(() {
            if (!_streamManuallyOff) {
              _isStreaming = true;
              _streamFrameReceived = false;
              _streamKey++;
            }
            _currentIndex = 0;
          });
          _startSensorPolling();
          _startPeriodicP4Sync();
          return;
        }

        // Dataset capturing
        if (_currentIndex == 3) {
          _stopDatasetAutoCapture(showSnack: false);
          setState(() {
            _isStreaming = true;
            _streamFrameReceived = false;
            _streamKey++;
            _currentIndex = 0;
          });
          _startSensorPolling();
          _startPeriodicP4Sync();
          return;
        }

        if (_currentIndex == 5) {
          if (_isFertilityDatasetCapturing) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('Please wait for fertility capture to finish.'),
              ),
            );
            return;
          }
          _stopFertilityDatasetAutoCapture(showSnack: false);
          setState(() {
            if (!_streamManuallyOff) {
              _isStreaming = true;
              _streamFrameReceived = false;
              _streamKey++;
            }
            _currentIndex = 0;
          });
          _startSensorPolling();
          _startPeriodicP4Sync();
          return;
        }

        if (_currentIndex == 4) {
          setState(() {
            _isStreaming = true;
            _streamFrameReceived = false;
            _streamKey++;
            _currentIndex = 0;
          });
          _startSensorPolling();
          _startPeriodicP4Sync();
          return;
        }

        if (_currentIndex == 6) {
          _openMainSection(0);
          return;
        }

        // Camera tab
        SystemNavigator.pop();
      },
      child: Scaffold(
        drawer: _buildAppDrawer(),
        appBar: AppBar(
          title: Text(
            _pageTitle,
            style: const TextStyle(fontWeight: FontWeight.bold),
          ),
          centerTitle: true,
          leading: Builder(
            builder: (context) => IconButton(
              icon: const Icon(Icons.menu_rounded),
              onPressed: () => Scaffold.of(context).openDrawer(),
              tooltip: 'Open Menu',
            ),
          ),
          actions: [
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 220),
              transitionBuilder: _premiumSwitchTransition,
              child: _currentIndex == 2
                  ? IconButton(
                      key: const ValueKey('grid-save-action'),
                      icon: const Icon(Icons.save_rounded),
                      onPressed: _saveAndApplyGrid,
                      tooltip: 'Save grid',
                    )
                  : _currentIndex == 4
                  ? IconButton(
                      key: const ValueKey('led-refresh-action'),
                      icon: const Icon(Icons.refresh_rounded),
                      onPressed: _ledTestBusy
                          ? null
                          : () => unawaited(_refreshLedControllerStatus()),
                      tooltip: 'Refresh LEDs',
                    )
                  : const SizedBox(key: ValueKey('grid-save-empty'), width: 48),
            ),
          ],
        ),
        body: AnimatedSwitcher(
          duration: const Duration(milliseconds: 360),
          reverseDuration: const Duration(milliseconds: 240),
          switchInCurve: Curves.easeOutCubic,
          switchOutCurve: Curves.easeInCubic,
          transitionBuilder: _premiumSwitchTransition,
          layoutBuilder: (currentChild, previousChildren) {
            return Stack(
              fit: StackFit.expand,
              children: [...previousChildren, ?currentChild],
            );
          },
          child: KeyedSubtree(
            key: ValueKey<int>(_currentIndex),
            child: _buildCurrentTab(),
          ),
        ),
      ),
    );
  }

  Widget _buildCurrentTab() {
    return switch (_currentIndex) {
      1 => _buildHistoryTab(),
      2 => _buildGridCustomizationTab(),
      3 => _buildDatasetCapturingTab(),
      4 => _buildLedTestTab(),
      5 => _buildFertilityDatasetCapturingTab(),
      6 => OfflineFertilityTestPage(
        cols: _activeGridCols,
        rows: _activeGridRows,
        trayWidthCm: _trayWidthCm,
        trayHeightCm: _trayHeightCm,
        colBoundariesCm: _scanColBoundaries,
        rowBoundariesCm: _scanRowBoundaries,
      ),
      _ => _buildCameraTab(),
    };
  }

  Widget _premiumSwitchTransition(Widget child, Animation<double> animation) {
    final curved = CurvedAnimation(
      parent: animation,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );
    return FadeTransition(
      opacity: curved,
      child: SlideTransition(
        position: Tween<Offset>(
          begin: const Offset(0.025, 0.012),
          end: Offset.zero,
        ).animate(curved),
        child: ScaleTransition(
          scale: Tween<double>(begin: 0.985, end: 1).animate(curved),
          child: child,
        ),
      ),
    );
  }

  Widget _premiumEntry(int order, Widget child) {
    return TweenAnimationBuilder<double>(
      key: ValueKey<String>('premium-entry-$_currentIndex-$order'),
      tween: Tween<double>(begin: 0, end: 1),
      duration: Duration(
        milliseconds: 280 + (order * 35).clamp(0, 180).toInt(),
      ),
      curve: Curves.easeOutCubic,
      builder: (context, value, child) {
        return Opacity(
          opacity: value,
          child: Transform.translate(
            offset: Offset(0, (1 - value) * 14),
            child: Transform.scale(
              scale: 0.985 + (value * 0.015),
              alignment: Alignment.topCenter,
              child: child,
            ),
          ),
        );
      },
      child: child,
    );
  }

  // Camera Tab
  Widget _buildStartupScreen() {
    final progressPercent = (_startupProgress * 100).round().clamp(0, 100);

    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFF2979FF), Color(0xFF00E676)],
          ),
        ),
        child: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 360),
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Center(
                      child: Container(
                        width: 118,
                        height: 118,
                        margin: const EdgeInsets.only(bottom: 24),
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.16),
                          borderRadius: BorderRadius.circular(28),
                          border: Border.all(
                            color: Colors.white.withValues(alpha: 0.28),
                          ),
                        ),
                        clipBehavior: Clip.antiAlias,
                        child: Padding(
                          padding: const EdgeInsets.all(8),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(20),
                            child: Image.asset(
                              'assets/egg_ai_icon.png',
                              fit: BoxFit.cover,
                              width: double.infinity,
                              height: double.infinity,
                            ),
                          ),
                        ),
                      ),
                    ),
                    const Text(
                      'Candling',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 32,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 1.2,
                      ),
                    ),
                    const SizedBox(height: 36),
                    TweenAnimationBuilder<double>(
                      tween: Tween<double>(end: _startupProgress),
                      duration: const Duration(milliseconds: 420),
                      curve: Curves.easeOutCubic,
                      builder: (context, value, _) {
                        return ClipRRect(
                          borderRadius: BorderRadius.circular(99),
                          child: LinearProgressIndicator(
                            value: value,
                            minHeight: 12,
                            backgroundColor: Colors.white.withValues(
                              alpha: 0.24,
                            ),
                            valueColor: const AlwaysStoppedAnimation(
                              Colors.white,
                            ),
                          ),
                        );
                      },
                    ),
                    const SizedBox(height: 12),
                    SizedBox(
                      height: 18,
                      child: Stack(
                        alignment: Alignment.center,
                        children: [
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 48),
                            child: AnimatedSwitcher(
                              duration: const Duration(milliseconds: 200),
                              child: Text(
                                _startupMessage,
                                key: ValueKey(_startupMessage),
                                textAlign: TextAlign.center,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: Colors.white.withValues(alpha: 0.88),
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ),
                          Align(
                            alignment: Alignment.centerRight,
                            child: Text(
                              '$progressPercent%',
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 13,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 18),
                    Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.14),
                        borderRadius: BorderRadius.circular(18),
                        border: Border.all(
                          color: Colors.white.withValues(alpha: 0.22),
                        ),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _buildStartupInfoRow(
                            Icons.camera_alt_rounded,
                            'Capture mode',
                            '/capture candling with occupied-slot lighting',
                          ),
                          const SizedBox(height: 10),
                          _buildStartupInfoRow(
                            Icons.science_outlined,
                            'Classification',
                            'On-device Fertile / Infertile model',
                          ),
                          const SizedBox(height: 10),
                          _buildStartupInfoRow(
                            Icons.history_rounded,
                            'Research records',
                            'Full session and per-slot data saved locally',
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),
                    AnimatedSwitcher(
                      duration: const Duration(milliseconds: 200),
                      child: Text(
                        _startupDetail,
                        key: ValueKey(_startupDetail),
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.76),
                          fontSize: 12,
                          height: 1.25,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildStartupInfoRow(IconData icon, String label, String value) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, color: Colors.white, size: 18),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.72),
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                value,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 12,
                  height: 1.2,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildModeSelectScreen() {
    final isDark = _isDarkTheme(context);
    final backgroundColors = isDark
        ? const [Color(0xFF0F111A), Color(0xFF151B2D), Color(0xFF1D2740)]
        : const [Color(0xFFF7FAFC), Color(0xFFEFF4FB), Color(0xFFE8F0FC)];
    final titleColor = isDark ? Colors.white : const Color(0xFF171B24);
    final mutedColor = isDark ? Colors.white70 : const Color(0xFF506070);
    final glassColor = isDark
        ? Colors.white.withValues(alpha: 0.08)
        : Colors.white.withValues(alpha: 0.70);
    final glassBorder = isDark
        ? Colors.white.withValues(alpha: 0.14)
        : const Color(0xFFDCE6F2);

    return Scaffold(
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: backgroundColors,
          ),
        ),
        child: SafeArea(
          child: LayoutBuilder(
            builder: (context, constraints) {
              return SingleChildScrollView(
                physics: const ClampingScrollPhysics(),
                child: ConstrainedBox(
                  constraints: BoxConstraints(minHeight: constraints.maxHeight),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(22, 24, 22, 22),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const SizedBox(height: 18),
                        TweenAnimationBuilder<double>(
                          tween: Tween<double>(begin: 0.94, end: 1),
                          duration: const Duration(milliseconds: 560),
                          curve: Curves.easeOutCubic,
                          builder: (context, scale, child) {
                            return Transform.scale(scale: scale, child: child);
                          },
                          child: Column(
                            children: [
                              ClipRRect(
                                borderRadius: BorderRadius.circular(28),
                                child: BackdropFilter(
                                  filter: ui.ImageFilter.blur(
                                    sigmaX: 18,
                                    sigmaY: 18,
                                  ),
                                  child: Container(
                                    width: 106,
                                    height: 106,
                                    padding: const EdgeInsets.all(8),
                                    decoration: BoxDecoration(
                                      color: glassColor,
                                      borderRadius: BorderRadius.circular(28),
                                      border: Border.all(color: glassBorder),
                                    ),
                                    child: ClipRRect(
                                      borderRadius: BorderRadius.circular(22),
                                      child: Image.asset(
                                        'assets/egg_ai_icon.png',
                                        fit: BoxFit.cover,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                              const SizedBox(height: 18),
                              Text(
                                'Candling',
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  color: titleColor,
                                  fontSize: 36,
                                  fontWeight: FontWeight.w900,
                                  letterSpacing: 0,
                                ),
                              ),
                              const SizedBox(height: 6),
                              Text(
                                'Choose your workspace',
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  color: mutedColor,
                                  fontSize: 15,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 32),
                        _buildModeCard(
                          icon: Icons.sensors_rounded,
                          title: 'Actual Mode',
                          subtitle:
                              'Live camera, sensors, P4 sync, and records',
                          color: const Color(0xFF2979FF),
                          onTap: () => _selectRunMode(demo: false),
                        ),
                        const SizedBox(height: 14),
                        _buildModeCard(
                          icon: Icons.slideshow_rounded,
                          title: 'Demo Mode',
                          subtitle: 'Sample scans for presentation and backup',
                          color: const Color(0xFF2979FF),
                          onTap: () => _selectRunMode(demo: true),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _buildModeCard({
    required IconData icon,
    required String title,
    required String subtitle,
    required Color color,
    required VoidCallback onTap,
  }) {
    final isDark = _isDarkTheme(context);
    final titleColor = isDark ? Colors.white : const Color(0xFF171B24);
    final mutedColor = isDark ? Colors.white70 : const Color(0xFF506070);
    final cardStart = isDark
        ? Colors.white.withValues(alpha: 0.12)
        : Colors.white.withValues(alpha: 0.82);
    final cardEnd = isDark
        ? Colors.white.withValues(alpha: 0.06)
        : Colors.white.withValues(alpha: 0.58);
    final borderColor = isDark
        ? Colors.white.withValues(alpha: 0.14)
        : const Color(0xFFDCE6F2);

    return ClipRRect(
      borderRadius: BorderRadius.circular(24),
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: 18, sigmaY: 18),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: onTap,
            splashColor: color.withValues(alpha: 0.08),
            highlightColor: color.withValues(alpha: 0.05),
            child: Container(
              constraints: const BoxConstraints(minHeight: 122),
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(24),
                border: Border.all(color: borderColor),
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [cardStart, cardEnd],
                ),
              ),
              child: Row(
                children: [
                  Container(
                    width: 58,
                    height: 58,
                    decoration: BoxDecoration(
                      color: color.withValues(alpha: 0.18),
                      borderRadius: BorderRadius.circular(18),
                      border: Border.all(color: color.withValues(alpha: 0.38)),
                    ),
                    child: Icon(icon, color: color, size: 28),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: titleColor,
                            fontSize: 19,
                            fontWeight: FontWeight.w900,
                            letterSpacing: 0,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          subtitle,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: mutedColor,
                            height: 1.25,
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  Container(
                    width: 38,
                    height: 38,
                    decoration: BoxDecoration(
                      color: color.withValues(alpha: 0.12),
                      shape: BoxShape.circle,
                      border: Border.all(color: color.withValues(alpha: 0.20)),
                    ),
                    child: Icon(
                      Icons.arrow_forward_rounded,
                      color: color,
                      size: 20,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  // Camera tab
  Widget _buildCameraTab() {
    return RefreshIndicator(
      onRefresh: () => _refreshApp(),
      child: SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(20),
        child: Column(
          children: [
            _premiumEntry(0, _buildConnectionStatusBanner()),
            const SizedBox(height: 10),
            _premiumEntry(1, _buildCameraPreview()),
            const SizedBox(height: 16),
            _premiumEntry(2, _buildCaptureButton()),
            const SizedBox(height: 20),
            _premiumEntry(3, _buildTempHumidityCard()),
            const SizedBox(height: 16),
            _premiumEntry(4, _buildStatusBar()),
            const SizedBox(height: 16),
            _premiumEntry(5, _buildCountsCard()),
            const SizedBox(height: 24),
            _premiumEntry(6, _buildEggGrid()),
          ],
        ),
      ),
    );
  }

  Widget _buildConnectionStatusBanner() {
    Widget chip({
      required IconData icon,
      required String label,
      required bool active,
    }) {
      final color = active ? const Color(0xFF00A86B) : const Color(0xFFFF5252);
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 6),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: color.withValues(alpha: 0.20)),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, color: color, size: 13),
            const SizedBox(width: 4),
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: color,
                  fontSize: 10,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          ],
        ),
      );
    }

    // 6th chip: interactive STREAM toggle. Reflects _isStreaming (which also
    // auto-goes-off during candling / P4 capture). Disabled off-network.
    Widget streamToggleChip() {
      final enabled = _isConnectedToCorrectSSID;
      final on = _isStreaming;
      final color = !enabled
          ? _appSubtleTextColor(context)
          : (on ? const Color(0xFF00A86B) : const Color(0xFFFF9800));
      return GestureDetector(
        onTap: enabled ? _toggleStream : null,
        child: Opacity(
          opacity: enabled ? 1.0 : 0.45,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 6),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(999),
              border: Border.all(color: color.withValues(alpha: 0.20)),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  on ? Icons.videocam_rounded : Icons.videocam_off_rounded,
                  color: color,
                  size: 13,
                ),
                const SizedBox(width: 4),
                Flexible(
                  child: Text(
                    on ? 'Live' : 'Stream',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: color,
                      fontSize: 10,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
      decoration: BoxDecoration(
        color: _appCardColor(context),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: _appOutlineColor(context)),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final itemWidth = (constraints.maxWidth - 12) / 3;
          return Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              SizedBox(
                width: itemWidth,
                child: chip(
                  icon: _isConnectedToCorrectSSID
                      ? Icons.wifi_rounded
                      : Icons.wifi_off_rounded,
                  label: 'WiFi',
                  active: _isConnectedToCorrectSSID,
                ),
              ),
              SizedBox(
                width: itemWidth,
                child: chip(
                  icon: Icons.camera_alt_rounded,
                  label: 'S3',
                  active: _s3Connected,
                ),
              ),
              SizedBox(
                width: itemWidth,
                child: chip(
                  icon: Icons.memory_rounded,
                  label: 'P4',
                  active: _p4Connected,
                ),
              ),
              SizedBox(
                width: itemWidth,
                child: chip(
                  icon: Icons.lightbulb_rounded,
                  label: 'LEDs',
                  active: _ledsConnected,
                ),
              ),
              SizedBox(
                width: itemWidth,
                child: chip(
                  icon: Icons.thermostat_rounded,
                  label: 'Sub',
                  active: _subIncubatorConnected,
                ),
              ),
              SizedBox(width: itemWidth, child: streamToggleChip()),
            ],
          );
        },
      ),
    );
  }

  Widget _buildCameraPreview() {
    if (_demoMode) {
      return Container(
        width: double.infinity,
        height: 240,
        decoration: BoxDecoration(
          color: _appCardColor(context),
          borderRadius: BorderRadius.circular(24),
        ),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.slideshow_rounded,
                size: 48,
                color: Color(0xFF2979FF),
              ),
              const SizedBox(height: 10),
              Text(
                'Demo Mode',
                style: TextStyle(
                  color: _appTextColor(context),
                  fontSize: 18,
                  fontWeight: FontWeight.w900,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                'No camera connection required',
                style: TextStyle(color: _appMutedTextColor(context)),
              ),
            ],
          ),
        ),
      );
    }

    if (!_isConnectedToCorrectSSID && _hasCheckedWifi) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          color: _appCardColor(context),
          borderRadius: BorderRadius.circular(24),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.wifi_off, size: 48, color: _appSubtleTextColor(context)),
            const SizedBox(height: 12),
            Text(
              _t('connecting'),
              style: TextStyle(
                color: _appSubtleTextColor(context),
                fontSize: 16,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '${_t('currentWifi')}: ${_currentSsid.isEmpty ? _t('none') : _currentSsid}',
              style: TextStyle(
                color: _appSubtleTextColor(context),
                fontSize: 12,
              ),
            ),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xFF2979FF).withAlpha(26),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: const Color(0xFF2979FF)),
              ),
              child: Column(
                children: [
                  Text(
                    _t('howToConnect'),
                    style: TextStyle(
                      color: Color(0xFF2979FF),
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  SizedBox(height: 8),
                  Text(
                    _t('connectSteps'),
                    style: TextStyle(
                      color: _appMutedTextColor(context),
                      fontSize: 12,
                    ),
                  ),
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      onPressed: _incubatorWifiRequestInProgress
                          ? null
                          : _openWifiSettings,
                      icon: _incubatorWifiRequestInProgress
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.wifi, size: 18),
                      label: Text(
                        _incubatorWifiRequestInProgress
                            ? 'CONNECTING...'
                            : _t('connectNow'),
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 0.4,
                        ),
                      ),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF2979FF),
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
          ],
        ),
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final containerWidth = constraints.maxWidth;
        final containerHeight = containerWidth * 3 / 4; // 4:3 VGA

        return Container(
          width: containerWidth,
          height: containerHeight,
          decoration: BoxDecoration(color: _appCardColor(context)),
          clipBehavior: Clip.antiAlias,
          child: Stack(
            children: [
              // Pinch-to-zoom the live stream (the grid overlay zooms with it
              // so they stay aligned). Overlays/buttons below stay fixed.
              Positioned.fill(
                child: InteractiveViewer(
                  panEnabled: true,
                  scaleEnabled: true,
                  minScale: 1.0,
                  maxScale: 5.0,
                  clipBehavior: Clip.hardEdge,
                  child: SizedBox(
                    width: containerWidth,
                    height: containerHeight,
                    child: Stack(
                      children: [
                        if (_isStreaming)
                          Esp32MjpegView(
                            key: ValueKey(_streamKey),
                            uri: _s3StreamUri().toString(),
                            width: containerWidth,
                            height: containerHeight,
                            fit: BoxFit.contain,
                            fps: 5,
                            onFirstFrame: _handleS3StreamFirstFrame,
                            onError: (error, stackTrace) {
                              _handleS3StreamError(error, stackTrace);
                            },
                          )
                        else if (_isDownloading)
                          Container(
                            color: Colors.black,
                            child: Center(
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const CircularProgressIndicator(
                                    color: Color(0xFF00E676),
                                  ),
                                  const SizedBox(height: 12),
                                  Text(
                                    _status,
                                    style: TextStyle(
                                      color: _appMutedTextColor(context),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          )
                        else
                          Container(
                            color: Colors.black,
                            child: Center(
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    Icons.videocam_off_rounded,
                                    color: _appSubtleTextColor(context),
                                    size: 40,
                                  ),
                                  const SizedBox(height: 12),
                                  Text(
                                    _isConnectedToCorrectSSID
                                        ? 'Stream off'
                                        : 'Camera preparing...',
                                    style: TextStyle(
                                      color: _appMutedTextColor(context),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        // Grid overlay (zooms with the video)
                        if (_showGridOverlay)
                          CustomPaint(
                            size: Size(containerWidth, containerHeight),
                            painter: GridPainter(
                              colBoundaries: _customColBoundaries,
                              rowBoundaries: _customRowBoundaries,
                              showIsolationBox: _gridSaved,
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
              // ---- Fixed overlays (do not zoom) ----
              // Pinch-to-zoom hint
              Positioned(
                top: 8,
                left: 8,
                child: IgnorePointer(
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.black45,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.pinch_rounded,
                          color: Colors.white70,
                          size: 13,
                        ),
                        SizedBox(width: 4),
                        Text(
                          'Pinch to zoom',
                          style: TextStyle(
                            color: Colors.white70,
                            fontSize: 9,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              // Toggle grid overlay button (bottom-right of preview)
              Positioned(
                bottom: 8,
                right: 8,
                child: GestureDetector(
                  onTap: () =>
                      setState(() => _showGridOverlay = !_showGridOverlay),
                  child: Container(
                    padding: const EdgeInsets.all(6),
                    decoration: BoxDecoration(
                      color: _isDarkTheme(context)
                          ? Colors.black54
                          : Colors.white.withAlpha(210),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Icon(
                      _showGridOverlay ? Icons.grid_on : Icons.grid_off,
                      color: _showGridOverlay
                          ? const Color(0xFF00E676)
                          : _appSubtleTextColor(context),
                      size: 18,
                    ),
                  ),
                ),
              ),
              Positioned(
                bottom: 8,
                right: 46,
                child: PopupMenuButton<_CandlingEggScope>(
                  initialValue: _candlingEggScope,
                  tooltip: 'Candling scope: $_candlingEggScopeLabel',
                  padding: EdgeInsets.zero,
                  onSelected: (scope) =>
                      setState(() => _candlingEggScope = scope),
                  itemBuilder: (context) => const [
                    PopupMenuItem(
                      value: _CandlingEggScope.allOccupied,
                      child: Row(
                        children: [
                          Icon(Icons.egg_alt_rounded, size: 18),
                          SizedBox(width: 10),
                          Text('All eggs'),
                        ],
                      ),
                    ),
                    PopupMenuItem(
                      value: _CandlingEggScope.day7Plus,
                      child: Row(
                        children: [
                          Icon(Icons.event_available_rounded, size: 18),
                          SizedBox(width: 10),
                          Text('7+ days'),
                        ],
                      ),
                    ),
                  ],
                  child: Container(
                    width: 30,
                    height: 30,
                    decoration: BoxDecoration(
                      color: _isDarkTheme(context)
                          ? Colors.black54
                          : Colors.white.withAlpha(210),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Icon(
                      _candlingEggScope == _CandlingEggScope.allOccupied
                          ? Icons.egg_alt_rounded
                          : Icons.event_available_rounded,
                      color: const Color(0xFF00E676),
                      size: 18,
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  // Result sheet shown after candling capture: photo + readiness research data,
  // dismissed by the Done button (which resumes the stream).
  void _showCandlingResultSheet(EggSession session) {
    final bytes = _capturedImage;
    if (bytes == null) {
      _resumeStreamAndSensor();
      return;
    }
    final timestamp = _captureTimestamp ?? DateTime.now();

    final eggsInTray = session.occupiedCount ?? 0;
    final readyCount = session.readyEggCount;
    final inReviewCount = session.inReviewCount;

    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useRootNavigator: true,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) {
        return DraggableScrollableSheet(
          initialChildSize: 0.85,
          minChildSize: 0.5,
          maxChildSize: 0.95,
          expand: false,
          builder: (context, scrollController) {
            return Container(
              decoration: BoxDecoration(
                color: _appCardColor(context),
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(24),
                ),
              ),
              child: Column(
                children: [
                  const SizedBox(height: 10),
                  Container(
                    width: 42,
                    height: 4,
                    decoration: BoxDecoration(
                      color: _appSubtleTextColor(context),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(18, 12, 18, 4),
                    child: Row(
                      children: [
                        const Icon(
                          Icons.biotech_rounded,
                          color: Color(0xFF00A86B),
                          size: 22,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            'Candling Capture',
                            style: TextStyle(
                              color: _appTextColor(context),
                              fontSize: 18,
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: ListView(
                      controller: scrollController,
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                      children: [
                        ClipRRect(
                          borderRadius: BorderRadius.circular(16),
                          child: AspectRatio(
                            aspectRatio: 4 / 3,
                            child: Container(
                              color: Colors.black,
                              child: InteractiveViewer(
                                panEnabled: true,
                                minScale: 1.0,
                                maxScale: 5.0,
                                child: Image.memory(
                                  bytes,
                                  fit: BoxFit.contain,
                                  gaplessPlayback: true,
                                  errorBuilder: (context, error, stack) =>
                                      const Center(
                                        child: Icon(
                                          Icons.broken_image_rounded,
                                          color: Colors.white38,
                                          size: 48,
                                        ),
                                      ),
                                ),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 6),
                        Center(
                          child: Text(
                            'Pinch to zoom the photo',
                            style: TextStyle(
                              color: _appSubtleTextColor(context),
                              fontSize: 11,
                            ),
                          ),
                        ),
                        const SizedBox(height: 14),
                        if (session.analyzedSlots.isNotEmpty) ...[
                          _buildFertilitySlotVerdicts(context, session),
                          const SizedBox(height: 16),
                        ],
                        if (_fertilityPending) ...[
                          Row(
                            children: [
                              _resultStat(
                                'EGGS',
                                '$eggsInTray',
                                const Color(0xFF2979FF),
                              ),
                              const SizedBox(width: 10),
                              _resultStat(
                                'READY (5-10d)',
                                '$readyCount',
                                const Color(0xFF00A86B),
                              ),
                              const SizedBox(width: 10),
                              _resultStat(
                                'IN REVIEW',
                                '$inReviewCount',
                                const Color(0xFFFF9800),
                              ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          Container(
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: const Color(
                                0xFFFF9800,
                              ).withValues(alpha: 0.10),
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(
                                color: const Color(
                                  0xFFFF9800,
                                ).withValues(alpha: 0.30),
                              ),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    const Icon(
                                      Icons.hourglass_top_rounded,
                                      color: Color(0xFFFF9800),
                                      size: 18,
                                    ),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: Text(
                                        'The mobile Fertile / Infertile model could not complete this capture. Try AI CANDLING again.',
                                        style: TextStyle(
                                          color: _appTextColor(context),
                                          fontSize: 12,
                                          height: 1.3,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                                if (inReviewCount > 0) ...[
                                  const SizedBox(height: 8),
                                  Text(
                                    '$inReviewCount egg(s) have no saved fertility verdict.',
                                    style: TextStyle(
                                      color: _appMutedTextColor(context),
                                      fontSize: 11.5,
                                      height: 1.3,
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                        ] else ...[
                          Row(
                            children: [
                              _resultStat(
                                'FERTILE',
                                '$_fertileCount',
                                const Color(0xFF00A86B),
                              ),
                              const SizedBox(width: 10),
                              _resultStat(
                                'INFERTILE',
                                '$_infertileCount',
                                const Color(0xFFFF5252),
                              ),
                              const SizedBox(width: 10),
                              _resultStat(
                                'IN REVIEW',
                                '$inReviewCount',
                                const Color(0xFFFF9800),
                              ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          if (inReviewCount > 0)
                            _resultInfoRow(
                              'Without a verdict',
                              '$inReviewCount',
                            ),
                        ],
                        const SizedBox(height: 12),
                        _resultInfoRow(
                          'Occupied eggs (P4 grid)',
                          '$eggsInTray',
                        ),
                        _resultInfoRow(
                          'Mobile classification',
                          _fertilityModelReady
                              ? 'MobileNetV3Small on device'
                              : 'Not completed',
                        ),
                        _resultInfoRow(
                          'Occupied underlights',
                          _lastCandlingLightsVerified == null
                              ? 'Verification unavailable'
                              : _lastCandlingLightsVerified!
                              ? 'Verified (${_lastActiveCandlingLeds.length} active)'
                              : 'Warning (${_lastMissingCandlingLeds.length} missing)',
                        ),
                        _resultInfoRow('Incubation age', _currentDayRangeLabel),
                        _resultInfoRow(
                          'Captured',
                          DateFormat('yyyy-MM-dd h:mm:ss a').format(timestamp),
                        ),
                      ],
                    ),
                  ),
                  SafeArea(
                    top: false,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 4, 16, 14),
                      child: SizedBox(
                        width: double.infinity,
                        child: ElevatedButton.icon(
                          onPressed: () => Navigator.of(sheetContext).pop(),
                          icon: const Icon(Icons.check_circle_rounded),
                          label: const Text(
                            'Done',
                            style: TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF00A86B),
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(vertical: 14),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    ).whenComplete(() {
      if (mounted) {
        setState(() {
          _status = 'Stream Ready';
        });
        _resumeStreamAndSensor();
      }
    });
  }

  Widget _resultStat(String label, String value, Color color) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: color.withValues(alpha: 0.25)),
        ),
        child: Column(
          children: [
            Text(
              value,
              style: TextStyle(
                color: color,
                fontSize: 22,
                fontWeight: FontWeight.w900,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              label,
              style: TextStyle(
                color: color,
                fontSize: 10,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.5,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _resultInfoRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                color: _appMutedTextColor(context),
                fontSize: 13,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              value,
              textAlign: TextAlign.right,
              style: TextStyle(
                color: _appTextColor(context),
                fontSize: 13,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTempHumidityCard() {
    return Column(
      children: [
        // MAIN incubator: P4 SHT3X temp/hum + S3 water/bulb/humidifier.
        _buildIncubatorCard(
          title: 'Main Incubator',
          connected: _mainConnected,
          ageMs: _mainAgeMs,
          waterSource: _subIncubatorWaterSource,
          temperature: _temperature,
          humidity: _humidity,
          waterLevel: _waterLevel,
          waterLow: _waterLow,
          bulbOn: _mainBulbOn,
          humidifierOn: _mainHumidifierOn,
          showWater: false,
        ),
        const SizedBox(height: 12),
        // SUB incubator (lockdown relay node).
        _buildIncubatorCard(
          title: 'Sub-Incubator (Lockdown)',
          connected: _subIncubatorConnected,
          ageMs: _subIncubatorAgeMs,
          waterSource: null,
          temperature: _subTemperature,
          humidity: _subHumidity,
          waterLevel: _subWaterLevel,
          waterLow: _subWaterLow,
          bulbOn: _subIncubatorBulbOn,
          humidifierOn: _subIncubatorHumidifierOn,
        ),
      ],
    );
  }

  Widget _buildIncubatorCard({
    required String title,
    required bool connected,
    required int? ageMs,
    required String? waterSource,
    required double? temperature,
    required double? humidity,
    required int? waterLevel,
    required bool? waterLow,
    required bool? bulbOn,
    required bool? humidifierOn,
    bool showWater = true,
  }) {
    final waterText = waterLevel == null
        ? '--'
        : '${waterLow == true ? 'LOW' : 'OK'} $waterLevel%';
    final sourceText = !showWater || waterSource == null
        ? ''
        : ' | $waterSource water';
    final ageText = ageMs == null ? '' : ' | ${(ageMs / 1000).round()}s';
    final statusColor = connected
        ? const Color(0xFF00A86B)
        : const Color(0xFFFF5252);

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: _appCardColor(context),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        children: [
          Row(
            children: [
              Icon(Icons.thermostat_rounded, color: statusColor, size: 18),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  title,
                  style: TextStyle(
                    color: _appTextColor(context),
                    fontSize: 13,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
                decoration: BoxDecoration(
                  color: statusColor.withValues(alpha: 0.10),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  connected ? 'LIVE$ageText$sourceText' : 'OFFLINE',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: statusColor,
                    fontSize: 10,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              Expanded(
                child: _buildSensorItem(
                  'TEMP',
                  temperature != null
                      ? '${temperature.toStringAsFixed(1)} C'
                      : '--',
                ),
              ),
              Container(width: 1, height: 40, color: _appDividerColor(context)),
              Expanded(
                child: _buildSensorItem(
                  'HUMIDITY',
                  humidity != null ? '${humidity.toStringAsFixed(0)}%' : '--',
                ),
              ),
              if (showWater) ...[
                Container(
                  width: 1,
                  height: 40,
                  color: _appDividerColor(context),
                ),
                Expanded(child: _buildSensorItem('WATER', waterText)),
              ],
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: _buildSubActuatorPill(
                  Icons.lightbulb_rounded,
                  'Bulb',
                  bulbOn ?? false,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _buildSubActuatorPill(
                  Icons.water_drop_rounded,
                  'Humidifier',
                  humidifierOn ?? false,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildSensorItem(String label, String value) {
    return Column(
      children: [
        Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            fontSize: 10,
            color: Color(0xFF2979FF),
            letterSpacing: 1,
          ),
        ),
        const SizedBox(height: 4),
        FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(
            value,
            maxLines: 1,
            style: TextStyle(
              color: _appTextColor(context),
              fontSize: 23,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildSubActuatorPill(IconData icon, String label, bool active) {
    final color = active
        ? const Color(0xFF00A86B)
        : _appFaintTextColor(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: color.withValues(alpha: active ? 0.10 : 0.08),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.18)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, color: color, size: 14),
          const SizedBox(width: 5),
          Flexible(
            child: Text(
              '$label ${active ? 'ON' : 'OFF'}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: color,
                fontSize: 10,
                fontWeight: FontWeight.w900,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLedTestTab() {
    return RefreshIndicator(
      onRefresh: _refreshLedControllerStatus,
      child: SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(20),
        child: Column(
          children: [
            _premiumEntry(0, _buildLedStatusPanel()),
            const SizedBox(height: 14),
            _premiumEntry(1, _buildLedActionPanel()),
            const SizedBox(height: 14),
            _premiumEntry(2, _buildLedGridPanel()),
          ],
        ),
      ),
    );
  }

  Widget _buildLedStatusPanel() {
    final color = _ledsConnected
        ? const Color(0xFF00A86B)
        : const Color(0xFFFF5252);
    final activeCount = _ledActiveCount ?? _selectedLedNumbers.length;
    final recentEggs = _ledRecentEggCount?.toString() ?? '--';

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: _appCardColor(context),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: _appOutlineColor(context)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(Icons.lightbulb_rounded, color: color),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '56 LED Controller',
                      style: TextStyle(
                        color: _appTextColor(context),
                        fontSize: 17,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      _ledTestStatus,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: _appMutedTextColor(context),
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.10),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  _ledsConnected ? 'ONLINE' : 'OFFLINE',
                  style: TextStyle(
                    color: color,
                    fontSize: 11,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
            ],
          ),
          if (_ledTestBusy) ...[
            const SizedBox(height: 12),
            const LinearProgressIndicator(
              color: Color(0xFF2979FF),
              minHeight: 3,
            ),
          ],
          const SizedBox(height: 14),
          Row(
            children: [
              _buildLedMetric(
                Icons.bolt_rounded,
                'Active',
                activeCount.toString(),
              ),
              const SizedBox(width: 8),
              _buildLedMetric(
                Icons.checklist_rounded,
                'Selected',
                _selectedLedNumbers.length.toString(),
              ),
              const SizedBox(width: 8),
              _buildLedMetric(
                Icons.egg_alt_rounded,
                _ledRecentCacheValid ? 'Egg Cache' : 'Cache',
                recentEggs,
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildLedMetric(IconData icon, String label, String value) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
        decoration: BoxDecoration(
          color: _appPanelColor(context),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            Icon(icon, color: const Color(0xFF2979FF), size: 18),
            const SizedBox(width: 7),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerLeft,
                    child: Text(
                      value,
                      style: TextStyle(
                        color: _appTextColor(context),
                        fontSize: 18,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ),
                  Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: _appFaintTextColor(context),
                      fontSize: 10,
                      fontWeight: FontWeight.w800,
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

  Widget _buildLedActionPanel() {
    Widget actionButton({
      required IconData icon,
      required String label,
      required Color color,
      required VoidCallback? onPressed,
    }) {
      return SizedBox(
        height: 48,
        child: FilledButton.icon(
          onPressed: _ledTestBusy ? null : onPressed,
          icon: Icon(icon, size: 18),
          label: FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              label,
              maxLines: 1,
              style: const TextStyle(fontWeight: FontWeight.w900),
            ),
          ),
          style: FilledButton.styleFrom(
            backgroundColor: color,
            foregroundColor: Colors.white,
            disabledBackgroundColor: _appDisabledColor(context),
            disabledForegroundColor: _appSubtleTextColor(context),
            padding: const EdgeInsets.symmetric(horizontal: 10),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
        ),
      );
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: _appCardColor(context),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: _appOutlineColor(context)),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final itemWidth = (constraints.maxWidth - 10) / 2;
          return Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              SizedBox(
                width: itemWidth,
                child: actionButton(
                  icon: Icons.refresh_rounded,
                  label: 'Refresh',
                  color: const Color(0xFF2979FF),
                  onPressed: () => unawaited(_refreshLedControllerStatus()),
                ),
              ),
              SizedBox(
                width: itemWidth,
                child: actionButton(
                  icon: Icons.sync_rounded,
                  label: 'Sync Slots',
                  color: const Color(0xFF00A86B),
                  onPressed: () => unawaited(_syncLedSlotsFromP4()),
                ),
              ),
              SizedBox(
                width: itemWidth,
                child: actionButton(
                  icon: Icons.egg_alt_rounded,
                  label: 'Light Eggs',
                  color: const Color(0xFF7C4DFF),
                  onPressed: () => unawaited(_lightOccupiedEggLeds()),
                ),
              ),
              SizedBox(
                width: itemWidth,
                child: actionButton(
                  icon: Icons.power_settings_new_rounded,
                  label: 'All Off',
                  color: const Color(0xFFFF5252),
                  onPressed: () => unawaited(_turnAllLedsOff()),
                ),
              ),
              SizedBox(
                width: itemWidth,
                child: actionButton(
                  icon: Icons.highlight_rounded,
                  label: 'All On',
                  color: const Color(0xFFFFA000),
                  onPressed: () => unawaited(_turnAllLedsOn()),
                ),
              ),
              SizedBox(
                width: itemWidth,
                child: actionButton(
                  icon: Icons.motion_photos_on_rounded,
                  label: 'One By One',
                  color: const Color(0xFF00ACC1),
                  onPressed: () => unawaited(_runLedChaseTest()),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildLedGridPanel() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: _appCardColor(context),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: _appOutlineColor(context)),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final columns = constraints.maxWidth >= 420 ? 8 : 7;
          return GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: 56,
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: columns,
              crossAxisSpacing: 7,
              mainAxisSpacing: 7,
              childAspectRatio: 1,
            ),
            itemBuilder: (context, index) {
              final ledNumber = index + 1;
              final selected = _selectedLedNumbers.contains(ledNumber);
              final color = selected
                  ? const Color(0xFF2979FF)
                  : _appPanelColor(context);
              final textColor = selected
                  ? Colors.white
                  : _appTextColor(context);
              return Tooltip(
                message: 'LED $ledNumber',
                child: Material(
                  color: color,
                  borderRadius: BorderRadius.circular(10),
                  child: InkWell(
                    onTap: _ledTestBusy
                        ? null
                        : () => _toggleLedNumber(ledNumber),
                    borderRadius: BorderRadius.circular(10),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 160),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(
                          color: selected
                              ? const Color(0xFF00E676)
                              : _appOutlineColor(context),
                          width: selected ? 2 : 1,
                        ),
                      ),
                      child: Center(
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Text(
                            ledNumber.toString(),
                            style: TextStyle(
                              color: textColor,
                              fontSize: 15,
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }

  Widget _buildCaptureButton() {
    final bool canCapture =
        (_demoMode || (_isConnectedToCorrectSSID && _hasCheckedWifi)) &&
        !_isCandling &&
        _countdown == 0 &&
        (_demoMode || _isStreaming);

    return SizedBox(
      width: double.infinity,
      height: 56,
      child: ElevatedButton.icon(
        onPressed: canCapture ? _triggerCaptureFlow : null,
        icon: const Icon(Icons.camera_alt),
        label: !_isStreaming && _hasCheckedWifi
            ? const Text(
                'CONNECT CAMERA FIRST',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1,
                ),
              )
            : _countdown > 0
            ? Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  SizedBox(
                    width: 24,
                    height: 24,
                    child: CircularProgressIndicator(
                      value: _countdownTotal == 0
                          ? 0
                          : _countdown / _countdownTotal,
                      color: Colors.black,
                      strokeWidth: 3,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    'WAIT $_countdown S',
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 1,
                    ),
                  ),
                ],
              )
            : Text(
                _isCandling
                    ? 'CAPTURING...'
                    : _demoMode
                    ? 'RUN DEMO CAPTURE'
                    : 'AI CANDLING',
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1,
                ),
              ),
        style: ElevatedButton.styleFrom(
          backgroundColor: const Color(0xFF00E676),
          foregroundColor: Colors.black,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          disabledBackgroundColor: _appDisabledColor(context),
          disabledForegroundColor: _appSubtleTextColor(context),
        ),
      ),
    );
  }

  Widget _buildStatusBar() {
    return Column(
      children: [
        LinearProgressIndicator(
          value: _isCandling ? null : 0,
          backgroundColor: _appPanelColor(context),
          valueColor: const AlwaysStoppedAnimation(Color(0xFF00E676)),
        ),
        const SizedBox(height: 8),
        Text(
          _status,
          style: TextStyle(color: _appMutedTextColor(context), fontSize: 14),
        ),
        if (_p4EquipmentFaultActive) ...[
          const SizedBox(height: 6),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(
                Icons.warning_amber_rounded,
                size: 16,
                color: Color(0xFFD32F2F),
              ),
              const SizedBox(width: 5),
              Flexible(
                child: Text(
                  _p4EquipmentFaultMessage.isNotEmpty
                      ? _p4EquipmentFaultMessage
                      : _p4EquipmentFaultCode.replaceAll('_', ' '),
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Color(0xFFD32F2F),
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ],
          ),
        ],
        if (_p4PhysicalAlertCount > 0) ...[
          const SizedBox(height: 4),
          Text(
            '$_p4PhysicalAlertCount physical alert${_p4PhysicalAlertCount == 1 ? '' : 's'} | open the door for LED guidance',
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: Color(0xFFD32F2F),
              fontSize: 11,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
        if (_lastSyncTime != null) ...[
          const SizedBox(height: 4),
          Text(
            [
              if (_p4EggCount != null) 'P4 eggs: $_p4EggCount',
              if (_p4EggDay != null) 'Day $_p4EggDay',
              'sync ${DateFormat('h:mm:ss a').format(_lastSyncTime!)}',
            ].join(' | '),
            style: TextStyle(color: _appFaintTextColor(context), fontSize: 11),
          ),
        ],
        if (Platform.isAndroid &&
            (_incubatorNetworkHeld || _incubatorWifiRequestInProgress)) ...[
          const SizedBox(height: 4),
          Text(
            _incubatorWifiRequestInProgress
                ? 'Android is requesting AI_CANDLING...'
                : _incubatorConcurrentInternetSupported
                ? 'AI_CANDLING held locally | internet can remain active'
                : 'AI_CANDLING held locally | other apps can use mobile data',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: _incubatorNetworkHeld
                  ? const Color(0xFF00C853)
                  : const Color(0xFFFFA000),
              fontSize: 11,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
        if (_p4Connected) ...[
          const SizedBox(height: 4),
          Text(
            _p4GridDataStatus,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: _p4GridUsingPreservedSnapshot
                  ? const Color(0xFFFFA000)
                  : const Color(0xFF00C853),
              fontSize: 11,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            _p4TimeTrusted
                ? 'P4 time recovered${_p4LastPhoneSyncAt == null ? '' : ' | phone ${DateFormat('h:mm:ss a').format(_p4LastPhoneSyncAt!)}'}'
                : 'P4 time needs phone sync',
            style: TextStyle(
              color: _p4TimeTrusted
                  ? _appFaintTextColor(context)
                  : const Color(0xFFFFA000),
              fontSize: 11,
              fontWeight: _p4TimeTrusted ? FontWeight.w500 : FontWeight.w800,
            ),
          ),
        ],
        if (_lastGridSyncTime != null) ...[
          const SizedBox(height: 4),
          Text(
            'Grid: $_lastGridSyncStatus${_lastGridSyncMs == null ? '' : ' (${_lastGridSyncMs}ms)'}',
            style: TextStyle(color: _appFaintTextColor(context), fontSize: 11),
          ),
        ],
        if (_lastTotalScanMs != null) ...[
          const SizedBox(height: 4),
          Text(
            'Last capture: ${_lastTotalScanMs}ms total | ${_sessions.isNotEmpty && _sessions.first.usedAi ? '${_sessions.first.analyzedSlotCount} slots analyzed' : 'AI not run'}',
            style: TextStyle(color: _appFaintTextColor(context), fontSize: 11),
          ),
        ],
      ],
    );
  }

  Widget _buildCountsCard() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: _appPanelColor(context),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          _buildCountItem(
            const Color(0xFF2979FF),
            'Occupied',
            _p4SlotHasEgg.where((hasEgg) => hasEgg).length,
          ),
          _buildCountItem(
            const Color(0xFF00A86B),
            'Ready (5-10)',
            _currentReadyEggCount,
          ),
          _buildCountItem(
            const Color(0xFFFF9800),
            'In review',
            _currentInReviewCount,
          ),
        ],
      ),
    );
  }

  Widget _buildCountItem(Color color, String label, int count) {
    return Column(
      children: [
        Container(
          width: 16,
          height: 16,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(4),
          ),
        ),
        const SizedBox(height: 4),
        Text(
          '$label: $count',
          style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold),
        ),
      ],
    );
  }

  Widget _buildEggGrid() {
    final abnormalCount = _p4SlotAbnormal.where((value) => value).length;
    final transferCount = _p4SlotTransferReady.where((value) => value).length;
    final showAbnormal =
        _p4AutomaticIntakeScreeningEnabled || abnormalCount > 0;
    final readinessText = showAbnormal
        ? 'ABNORMAL $abnormalCount | Transfer $transferCount'
        : 'Transfer ready: $transferCount';

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: _appCardColor(context),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'Incubation Slots',
                  style: TextStyle(
                    color: _appTextColor(context),
                    fontSize: 14,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              Text(
                _currentDayRangeLabel,
                style: TextStyle(
                  color: _appMutedTextColor(context),
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            readinessText,
            style: TextStyle(
              color: _appSubtleTextColor(context),
              fontSize: 11,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 10,
            runSpacing: 8,
            children: [
              if (showAbnormal)
                _buildSlotLegend(const Color(0xFFD50000), 'Abnormal'),
              _buildSlotLegend(const Color(0xFF00838F), 'Transfer'),
              _buildSlotLegend(const Color(0xFF00A86B), 'Normal'),
              _buildSlotLegend(const Color(0xFFFF9800), 'In review'),
              _buildSlotLegend(const Color(0xFFAD1457), 'Infertile'),
              _buildSlotLegend(const Color(0xFF2979FF), 'Fertile'),
              _buildSlotLegend(const Color(0xFF37474F), 'No slot'),
            ],
          ),
          const SizedBox(height: 14),
          GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: _activeGridCols,
              crossAxisSpacing: 8,
              mainAxisSpacing: 8,
            ),
            itemCount: _activeGridCellCount,
            itemBuilder: (context, index) {
              final egg = index < _eggData.length ? _eggData[index] : EggData();
              return GestureDetector(
                onTap: () => _showEggDetail(index, egg),
                onLongPress: () => _showSlotHelp(index, egg),
                child: _buildEggCell(index, egg),
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _buildSlotLegend(Color color, String label) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(3),
          ),
        ),
        const SizedBox(width: 5),
        Text(
          label,
          style: TextStyle(
            color: _appSubtleTextColor(context),
            fontSize: 10,
            fontWeight: FontWeight.w700,
          ),
        ),
      ],
    );
  }

  void _showEggDetail(int index, EggData egg) {
    final hasEgg = _slotHasEgg(index);
    final placedAt = _slotPlacedAt(index);
    final day = _slotDay(index);
    final ready = hasEgg && _slotIsFertilityDatasetAgeReady(index);
    final intakeVerdict = _slotIntakeVerdict(index);
    final abnormal = _slotFlag(_p4SlotAbnormal, index);
    final confirmedInfertile = _slotFlag(_p4SlotConfirmedInfertile, index);
    final transferReady = _slotFlag(_p4SlotTransferReady, index);
    final intakeText = abnormal
        ? 'ABNORMAL'
        : _p4AutomaticIntakeScreeningEnabled && intakeVerdict == 'normal'
        ? 'NORMAL'
        : '--';
    final statusText = !hasEgg
        ? 'EMPTY'
        : !ready
        ? 'IN REVIEW - OUTSIDE DAY 5-10'
        : egg.status == EggStatus.unknown
        ? 'READY - NO CONCLUSIVE RESULT'
        : egg.status.name.toUpperCase();
    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: _appCardColor(dialogContext),
        title: Text('Slot ${index + 1}'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            StreamBuilder<int>(
              stream: Stream.periodic(
                const Duration(seconds: 1),
                (tick) => tick,
              ),
              builder: (context, snapshot) => _buildSlotDetailRow(
                'Current',
                _formatSlotDateTime(DateTime.now()),
              ),
            ),
            _buildSlotDetailRow(
              'Slot',
              hasEgg ? 'Occupied' : 'No egg detected',
            ),
            _buildSlotDetailRow(
              'Date Placed',
              hasEgg ? _formatSlotDateTime(placedAt) : '--',
            ),
            _buildSlotDetailRow(
              'Date Status',
              !hasEgg
                  ? '--'
                  : placedAt == null
                  ? 'Optional metadata not set'
                  : 'Editable metadata recorded',
            ),
            _buildSlotDetailRow(
              'Running Time',
              hasEgg ? _formatSlotAge(placedAt) : '--',
            ),
            _buildSlotDetailRow('Days in Slot', day?.toString() ?? '--'),
            _buildSlotDetailRow(
              'Detection',
              ready
                  ? 'Ready for the Day 5-10 mobile classifier'
                  : 'Outside the Day 5-10 model window',
            ),
            if (_p4AutomaticIntakeScreeningEnabled || abnormal)
              _buildSlotDetailRow('Intake Result', intakeText),
            _buildSlotDetailRow(
              'Door Guidance',
              abnormal || confirmedInfertile
                  ? 'Remove - double flash'
                  : transferReady
                  ? 'Transfer - slow pulse'
                  : 'None',
            ),
            if (_p4EquipmentFaultActive)
              _buildSlotDetailRow(
                'Equipment',
                _p4EquipmentFaultMessage.isNotEmpty
                    ? _p4EquipmentFaultMessage
                    : _p4EquipmentFaultCode.replaceAll('_', ' '),
              ),
            _buildSlotDetailRow('Status', statusText),
          ],
        ),
        actions: [
          if (!hasEgg)
            TextButton(
              onPressed: () {
                Navigator.pop(dialogContext);
                unawaited(_placeEggInSlot(index));
              },
              child: const Text('Place Now'),
            ),
          TextButton(
            onPressed: () {
              Navigator.pop(dialogContext);
              unawaited(_pickSlotPlacedAt(index));
            },
            child: Text(hasEgg ? 'Edit Placed' : 'Set Date'),
          ),
          if (hasEgg)
            TextButton(
              onPressed: () {
                Navigator.pop(dialogContext);
                unawaited(_clearEggSlot(index));
              },
              child: const Text('Remove Egg'),
            ),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  void _showSlotHelp(int index, EggData egg) {
    final hasEgg = _slotHasEgg(index);
    final placedAt = _slotPlacedAt(index);
    final day = _slotDay(index);
    final ready = hasEgg && _slotIsFertilityDatasetAgeReady(index);
    final intakeVerdict = _slotIntakeVerdict(index);
    final removeAlert =
        _slotFlag(_p4SlotAbnormal, index) ||
        _slotFlag(_p4SlotConfirmedInfertile, index);
    final transferReady = _slotFlag(_p4SlotTransferReady, index);
    final statusText = !hasEgg
        ? 'Empty'
        : !ready
        ? 'Outside the Day 5-10 model window'
        : switch (egg.status) {
            EggStatus.fertile => 'Fertile',
            EggStatus.infertile => 'Infertile',
            EggStatus.unknown => 'Ready - no conclusive result',
          };

    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      backgroundColor: _appCardColor(context),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (sheetContext) {
        Widget info(IconData icon, String label, String value, Color color) {
          return Container(
            margin: const EdgeInsets.only(bottom: 10),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: _appPanelColor(sheetContext),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Row(
              children: [
                Container(
                  width: 38,
                  height: 38,
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(icon, color: color, size: 20),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        label,
                        style: TextStyle(
                          color: _appMutedTextColor(sheetContext),
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      Text(
                        value,
                        style: TextStyle(
                          color: _appTextColor(sheetContext),
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          );
        }

        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Slot ${index + 1} Guide',
                  style: TextStyle(
                    color: _appTextColor(sheetContext),
                    fontSize: 20,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 14),
                info(
                  hasEgg ? Icons.egg_alt_rounded : Icons.block_rounded,
                  'Slot',
                  hasEgg ? 'Occupied' : 'No egg detected',
                  hasEgg ? const Color(0xFF2979FF) : const Color(0xFF667085),
                ),
                info(
                  Icons.event_available_rounded,
                  'Date Placed',
                  hasEgg ? _formatSlotDateTime(placedAt) : '--',
                  const Color(0xFF2979FF),
                ),
                info(
                  placedAt != null
                      ? Icons.verified_rounded
                      : Icons.event_busy_rounded,
                  'Date Status',
                  !hasEgg
                      ? '--'
                      : placedAt == null
                      ? 'Optional metadata not set'
                      : 'Editable metadata recorded',
                  placedAt == null
                      ? const Color(0xFFFF9800)
                      : const Color(0xFF00A86B),
                ),
                info(
                  Icons.schedule_rounded,
                  'Running Time',
                  hasEgg ? _formatSlotAge(placedAt) : '--',
                  const Color(0xFF7C4DFF),
                ),
                info(
                  Icons.event_available_rounded,
                  'Incubation Day',
                  day == null ? 'Unknown day' : 'Day $day',
                  ready ? const Color(0xFF00A86B) : const Color(0xFFFF5252),
                ),
                info(
                  ready ? Icons.verified_rounded : Icons.hourglass_top_rounded,
                  'Detection Rule',
                  ready
                      ? 'Fertile / Infertile classification is allowed'
                      : 'Outside the Day 5-10 model window',
                  ready ? const Color(0xFF00A86B) : const Color(0xFFFFA000),
                ),
                info(
                  Icons.analytics_rounded,
                  'Current Status',
                  statusText,
                  _colorForEggStatus(egg.status),
                ),
                if (_p4AutomaticIntakeScreeningEnabled ||
                    _slotFlag(_p4SlotAbnormal, index))
                  info(
                    Icons.fact_check_rounded,
                    'Intake Result',
                    _slotFlag(_p4SlotAbnormal, index)
                        ? 'ABNORMAL'
                        : intakeVerdict == 'normal'
                        ? 'NORMAL'
                        : '--',
                    _slotFlag(_p4SlotAbnormal, index)
                        ? const Color(0xFFD50000)
                        : intakeVerdict == 'normal'
                        ? const Color(0xFF00A86B)
                        : const Color(0xFF667085),
                  ),
                info(
                  Icons.lightbulb_outline_rounded,
                  'Door Guidance',
                  removeAlert
                      ? 'Remove - double flash'
                      : transferReady
                      ? 'Transfer - slow pulse'
                      : 'None',
                  removeAlert
                      ? const Color(0xFFD50000)
                      : const Color(0xFF00838F),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildSlotDetailRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 86,
            child: Text(
              label,
              style: TextStyle(
                color: _appSubtleTextColor(context),
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          Flexible(
            child: Text(
              value,
              style: TextStyle(
                color: _appTextColor(context),
                fontSize: 12,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEggCell(int index, EggData egg) {
    final hasEgg = _slotHasEgg(index);
    final day = _slotDay(index);
    final isReady = hasEgg && _slotIsFertilityDatasetAgeReady(index);
    final isInReview = hasEgg && !isReady;
    final abnormal = _slotFlag(_p4SlotAbnormal, index);
    final confirmedInfertile = _slotFlag(_p4SlotConfirmedInfertile, index);
    final transferReady = _slotFlag(_p4SlotTransferReady, index);
    final intakeNormal =
        _p4AutomaticIntakeScreeningEnabled &&
        _slotIntakeVerdict(index) == 'normal';
    final slotNumber = index + 1;

    Color bgColor = const Color(0xFF37474F);
    Color borderColor = const Color(0xFF546E7A);
    String statusText = hasEgg ? 'EGG' : '--';
    String dayText = hasEgg && day != null ? 'DAY $day' : 'NO SLOT';

    if (abnormal) {
      bgColor = const Color(0xFFD50000);
      borderColor = const Color(0xFFFF8A80);
      statusText = 'ABN';
    } else if (confirmedInfertile) {
      bgColor = const Color(0xFFAD1457);
      borderColor = const Color(0xFFF48FB1);
      statusText = 'INF';
    } else if (transferReady) {
      bgColor = const Color(0xFF00838F);
      borderColor = const Color(0xFF80DEEA);
      statusText = 'MOVE';
    } else if (intakeNormal) {
      bgColor = const Color(0xFF00A86B);
      borderColor = const Color(0xFFA5D6A7);
      statusText = 'NORM';
    } else if (isInReview) {
      bgColor = const Color(0xFFFF9800);
      borderColor = const Color(0xFFFFE0B2);
      statusText = 'REVIEW';
    } else {
      switch (egg.status) {
        case EggStatus.fertile:
          bgColor = const Color(0xFF2979FF);
          borderColor = const Color(0xFF82B1FF);
          statusText = 'FERT';
          break;
        case EggStatus.infertile:
          bgColor = const Color(0xFF00E676);
          borderColor = const Color(0xFFA5D6A7);
          statusText = 'INF';
          break;
        case EggStatus.unknown:
          if (hasEgg && isReady) {
            bgColor = const Color(0xFFFFB300);
            borderColor = const Color(0xFFFFECB3);
            statusText = 'READY';
          }
      }
    }

    return Container(
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: borderColor),
      ),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '$slotNumber',
              style: const TextStyle(
                fontSize: 9,
                color: Colors.white,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 1),
            Text(
              dayText,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 7,
                color: Colors.white,
                fontWeight: FontWeight.w800,
              ),
            ),
            Text(
              statusText,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 6,
                color: Colors.white,
                fontWeight: FontWeight.bold,
              ),
            ),
            if (egg.confidence > 0)
              Text(
                '${(egg.confidence * 100).toInt()}%',
                style: const TextStyle(fontSize: 6, color: Colors.white70),
              ),
          ],
        ),
      ),
    );
  }

  DateTime _startOfDay(DateTime date) =>
      DateTime(date.year, date.month, date.day);

  List<EggSession> _historySessionsInRange(DateTime start, DateTime end) {
    final sessions = _sessions
        .where((s) => !s.timestamp.isBefore(start) && s.timestamp.isBefore(end))
        .toList();
    sessions.sort((a, b) => b.timestamp.compareTo(a.timestamp));
    return sessions;
  }

  List<EggCounterRecord> _eggCounterRecordsInRange(
    DateTime start,
    DateTime end,
  ) {
    final records = _eggCounterHistory.where((record) {
      final time = record.p4ScanTime ?? record.timestamp;
      return !time.isBefore(start) && time.isBefore(end);
    }).toList();
    records.sort((a, b) {
      final aTime = a.p4ScanTime ?? a.timestamp;
      final bTime = b.p4ScanTime ?? b.timestamp;
      return bTime.compareTo(aTime);
    });
    return records;
  }

  Future<void> _showHistoryExportSheet() async {
    final now = DateTime.now();
    final today = _startOfDay(now);

    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      backgroundColor: _appCardColor(context),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (sheetContext) {
        Widget option({
          required IconData icon,
          required String title,
          required String subtitle,
          required VoidCallback onTap,
        }) {
          return ListTile(
            contentPadding: const EdgeInsets.symmetric(horizontal: 20),
            leading: Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: const Color(0xFF2979FF).withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Icon(icon, color: const Color(0xFF2979FF)),
            ),
            title: Text(
              title,
              style: TextStyle(
                color: _appTextColor(sheetContext),
                fontWeight: FontWeight.w700,
              ),
            ),
            subtitle: Text(
              subtitle,
              style: TextStyle(color: _appMutedTextColor(sheetContext)),
            ),
            trailing: Icon(
              Icons.chevron_right,
              color: _appFaintTextColor(sheetContext),
            ),
            onTap: onTap,
          );
        }

        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
                  child: Text(
                    'Export History Report',
                    style: TextStyle(
                      color: _appTextColor(sheetContext),
                      fontSize: 18,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                option(
                  icon: Icons.today_rounded,
                  title: 'Today',
                  subtitle: 'All candling sessions from today',
                  onTap: () {
                    Navigator.pop(sheetContext);
                    _showPdfExportActionSheet(
                      label: 'Today',
                      start: today,
                      end: today.add(const Duration(days: 1)),
                    );
                  },
                ),
                option(
                  icon: Icons.calendar_view_week_rounded,
                  title: 'Last 7 Days',
                  subtitle: 'A weekly report with totals and session data',
                  onTap: () {
                    Navigator.pop(sheetContext);
                    _showPdfExportActionSheet(
                      label: 'Last 7 Days',
                      start: today.subtract(const Duration(days: 6)),
                      end: today.add(const Duration(days: 1)),
                    );
                  },
                ),
                option(
                  icon: Icons.calendar_month_rounded,
                  title: 'Last 30 Days',
                  subtitle: 'A monthly report for recent candling sessions',
                  onTap: () {
                    Navigator.pop(sheetContext);
                    _showPdfExportActionSheet(
                      label: 'Last 30 Days',
                      start: today.subtract(const Duration(days: 29)),
                      end: today.add(const Duration(days: 1)),
                    );
                  },
                ),
                option(
                  icon: Icons.tune_rounded,
                  title: 'Custom Range',
                  subtitle: 'Choose your own start and end dates',
                  onTap: () {
                    Navigator.pop(sheetContext);
                    _pickCustomHistoryRange();
                  },
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _pickCustomHistoryRange() async {
    final now = DateTime.now();
    final today = _startOfDay(now);
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(now.year - 5),
      lastDate: now,
      initialDateRange: DateTimeRange(
        start: today.subtract(const Duration(days: 6)),
        end: today,
      ),
      builder: (context, child) {
        return Theme(
          data: Theme.of(context).copyWith(
            colorScheme: Theme.of(
              context,
            ).colorScheme.copyWith(primary: const Color(0xFF2979FF)),
          ),
          child: child!,
        );
      },
    );

    if (picked == null) return;
    final start = _startOfDay(picked.start);
    final end = _startOfDay(picked.end).add(const Duration(days: 1));
    await _showPdfExportActionSheet(
      label:
          '${DateFormat('MMM dd, yyyy').format(picked.start)} - ${DateFormat('MMM dd, yyyy').format(picked.end)}',
      start: start,
      end: end,
    );
  }

  Future<void> _showEggCounterExportSheet() async {
    final now = DateTime.now();
    final today = _startOfDay(now);

    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      backgroundColor: _appCardColor(context),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (sheetContext) {
        Widget option({
          required IconData icon,
          required String title,
          required String subtitle,
          required VoidCallback onTap,
        }) {
          return ListTile(
            contentPadding: const EdgeInsets.symmetric(horizontal: 20),
            leading: Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: const Color(0xFF2979FF).withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Icon(icon, color: const Color(0xFF2979FF)),
            ),
            title: Text(
              title,
              style: TextStyle(
                color: _appTextColor(sheetContext),
                fontWeight: FontWeight.w700,
              ),
            ),
            subtitle: Text(
              subtitle,
              style: TextStyle(color: _appMutedTextColor(sheetContext)),
            ),
            trailing: Icon(
              Icons.chevron_right,
              color: _appFaintTextColor(sheetContext),
            ),
            onTap: onTap,
          );
        }

        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
                  child: Text(
                    'Export Egg Counter Report',
                    style: TextStyle(
                      color: _appTextColor(sheetContext),
                      fontSize: 18,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                option(
                  icon: Icons.today_rounded,
                  title: 'Today',
                  subtitle: 'P4 egg counter records from today',
                  onTap: () {
                    Navigator.pop(sheetContext);
                    _showEggCounterPdfActionSheet(
                      label: 'Today',
                      start: today,
                      end: today.add(const Duration(days: 1)),
                    );
                  },
                ),
                option(
                  icon: Icons.calendar_view_week_rounded,
                  title: 'Last 7 Days',
                  subtitle: 'A weekly counter report with graph and records',
                  onTap: () {
                    Navigator.pop(sheetContext);
                    _showEggCounterPdfActionSheet(
                      label: 'Last 7 Days',
                      start: today.subtract(const Duration(days: 6)),
                      end: today.add(const Duration(days: 1)),
                    );
                  },
                ),
                option(
                  icon: Icons.calendar_month_rounded,
                  title: 'Last 30 Days',
                  subtitle: 'A monthly egg count trend report',
                  onTap: () {
                    Navigator.pop(sheetContext);
                    _showEggCounterPdfActionSheet(
                      label: 'Last 30 Days',
                      start: today.subtract(const Duration(days: 29)),
                      end: today.add(const Duration(days: 1)),
                    );
                  },
                ),
                option(
                  icon: Icons.tune_rounded,
                  title: 'Custom Range',
                  subtitle: 'Choose your own start and end dates',
                  onTap: () {
                    Navigator.pop(sheetContext);
                    _pickCustomEggCounterHistoryRange();
                  },
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _pickCustomEggCounterHistoryRange() async {
    final now = DateTime.now();
    final today = _startOfDay(now);
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(now.year - 5),
      lastDate: now,
      initialDateRange: DateTimeRange(
        start: today.subtract(const Duration(days: 6)),
        end: today,
      ),
      builder: (context, child) {
        return Theme(
          data: Theme.of(context).copyWith(
            colorScheme: Theme.of(
              context,
            ).colorScheme.copyWith(primary: const Color(0xFF2979FF)),
          ),
          child: child!,
        );
      },
    );

    if (picked == null) return;
    final start = _startOfDay(picked.start);
    final end = _startOfDay(picked.end).add(const Duration(days: 1));
    await _showEggCounterPdfActionSheet(
      label:
          '${DateFormat('MMM dd, yyyy').format(picked.start)} - ${DateFormat('MMM dd, yyyy').format(picked.end)}',
      start: start,
      end: end,
    );
  }

  Future<void> _showPdfExportActionSheet({
    required String label,
    required DateTime start,
    required DateTime end,
  }) async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      backgroundColor: _appCardColor(context),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (sheetContext) {
        Widget action({
          required IconData icon,
          required Color color,
          required String title,
          required String subtitle,
          required VoidCallback onTap,
        }) {
          return Container(
            margin: const EdgeInsets.fromLTRB(20, 0, 20, 10),
            decoration: BoxDecoration(
              color: _appPanelColor(sheetContext),
              borderRadius: BorderRadius.circular(16),
            ),
            child: ListTile(
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 14,
                vertical: 7,
              ),
              leading: Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Icon(icon, color: color),
              ),
              title: Text(
                title,
                style: TextStyle(
                  color: _appTextColor(sheetContext),
                  fontWeight: FontWeight.w800,
                ),
              ),
              subtitle: Text(
                subtitle,
                style: TextStyle(color: _appMutedTextColor(sheetContext)),
              ),
              trailing: Icon(
                Icons.chevron_right_rounded,
                color: _appFaintTextColor(sheetContext),
              ),
              onTap: onTap,
            ),
          );
        }

        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 4, 20, 14),
                  child: Row(
                    children: [
                      Container(
                        width: 42,
                        height: 42,
                        decoration: BoxDecoration(
                          color: const Color(
                            0xFF2979FF,
                          ).withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: const Icon(
                          Icons.file_upload_rounded,
                          color: Color(0xFF2979FF),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          label,
                          style: TextStyle(
                            color: _appTextColor(sheetContext),
                            fontSize: 18,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                action(
                  icon: Icons.folder_rounded,
                  color: const Color(0xFF00A86B),
                  title: 'Save to Documents',
                  subtitle: 'Automatically saves inside Documents/Candling',
                  onTap: () {
                    Navigator.pop(sheetContext);
                    _saveHistoryReportToDocuments(
                      label: label,
                      start: start,
                      end: end,
                    );
                  },
                ),
                action(
                  icon: Icons.ios_share_rounded,
                  color: const Color(0xFF2979FF),
                  title: 'Share PDF',
                  subtitle:
                      'Send through Gmail, Messenger, Bluetooth, and more',
                  onTap: () {
                    Navigator.pop(sheetContext);
                    _shareHistoryReport(label: label, start: start, end: end);
                  },
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _showEggCounterPdfActionSheet({
    required String label,
    required DateTime start,
    required DateTime end,
  }) async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      backgroundColor: _appCardColor(context),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (sheetContext) {
        Widget action({
          required IconData icon,
          required Color color,
          required String title,
          required String subtitle,
          required VoidCallback onTap,
        }) {
          return Container(
            margin: const EdgeInsets.fromLTRB(20, 0, 20, 10),
            decoration: BoxDecoration(
              color: _appPanelColor(sheetContext),
              borderRadius: BorderRadius.circular(16),
            ),
            child: ListTile(
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 14,
                vertical: 7,
              ),
              leading: Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Icon(icon, color: color),
              ),
              title: Text(
                title,
                style: TextStyle(
                  color: _appTextColor(sheetContext),
                  fontWeight: FontWeight.w800,
                ),
              ),
              subtitle: Text(
                subtitle,
                style: TextStyle(color: _appMutedTextColor(sheetContext)),
              ),
              trailing: Icon(
                Icons.chevron_right_rounded,
                color: _appFaintTextColor(sheetContext),
              ),
              onTap: onTap,
            ),
          );
        }

        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 4, 20, 14),
                  child: Row(
                    children: [
                      Container(
                        width: 42,
                        height: 42,
                        decoration: BoxDecoration(
                          color: const Color(
                            0xFF2979FF,
                          ).withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: const Icon(
                          Icons.egg_alt_rounded,
                          color: Color(0xFF2979FF),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          label,
                          style: TextStyle(
                            color: _appTextColor(sheetContext),
                            fontSize: 18,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                action(
                  icon: Icons.folder_rounded,
                  color: const Color(0xFF00A86B),
                  title: 'Save to Documents',
                  subtitle: 'Save an egg counter PDF for thesis records',
                  onTap: () {
                    Navigator.pop(sheetContext);
                    _saveEggCounterReportToDocuments(
                      label: label,
                      start: start,
                      end: end,
                    );
                  },
                ),
                action(
                  icon: Icons.ios_share_rounded,
                  color: const Color(0xFF2979FF),
                  title: 'Share PDF',
                  subtitle: 'Send the egg counter report to another app',
                  onTap: () {
                    Navigator.pop(sheetContext);
                    _shareEggCounterReport(
                      label: label,
                      start: start,
                      end: end,
                    );
                  },
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<({String fileName, Uint8List bytes})> _buildHistoryReportBytes({
    required String label,
    required DateTime start,
    required DateTime end,
  }) async {
    final sessions = _historySessionsInRange(start, end);
    final pdf = _buildHistoryPdf(
      label: label,
      start: start,
      end: end,
      sessions: sessions,
      sensorSamples: _sensorHistoryInRange(start, end),
    );
    final today = DateFormat('yyyy-MM-dd').format(DateTime.now());
    final slug = label
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
        .replaceAll(RegExp(r'^-|-$'), '');
    return (
      fileName: 'Candling_history_${slug}_$today.pdf',
      bytes: await pdf.save(),
    );
  }

  Future<({String fileName, Uint8List bytes})> _buildEggCounterReportBytes({
    required String label,
    required DateTime start,
    required DateTime end,
  }) async {
    final records = _eggCounterRecordsInRange(start, end);
    final pdf = _buildEggCounterPdf(
      label: label,
      start: start,
      end: end,
      records: records,
      sensorSamples: _sensorHistoryInRange(start, end),
    );
    final today = DateFormat('yyyy-MM-dd').format(DateTime.now());
    final slug = label
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
        .replaceAll(RegExp(r'^-|-$'), '');
    return (
      fileName: 'Egg_counter_history_${slug}_$today.pdf',
      bytes: await pdf.save(),
    );
  }

  Future<bool> _canUsePdfExportSlot() async {
    final prefs = await SharedPreferences.getInstance();
    final today = DateFormat('yyyy-MM-dd').format(DateTime.now());
    final savedDate = prefs.getString('pdf_export_date');
    final usedCount = savedDate == today
        ? prefs.getInt('pdf_export_count') ?? 0
        : 0;

    if (usedCount >= _maxDailyPdfExports) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'PDF export limit reached ($_maxDailyPdfExports per day).',
            ),
            backgroundColor: Colors.orange,
          ),
        );
      }
      return false;
    }
    return true;
  }

  Future<void> _recordPdfExportSlot() async {
    final prefs = await SharedPreferences.getInstance();
    final today = DateFormat('yyyy-MM-dd').format(DateTime.now());
    final savedDate = prefs.getString('pdf_export_date');
    final usedCount = savedDate == today
        ? prefs.getInt('pdf_export_count') ?? 0
        : 0;
    await prefs.setString('pdf_export_date', today);
    await prefs.setInt('pdf_export_count', usedCount + 1);
  }

  Future<void> _shareReportBytes({
    required String fileName,
    required Uint8List bytes,
    required String subject,
  }) async {
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/$fileName');
    await file.writeAsBytes(bytes);
    await Share.shareXFiles([
      XFile(file.path, mimeType: 'application/pdf'),
    ], subject: subject);
  }

  Future<void> _saveHistoryReportToDocuments({
    required String label,
    required DateTime start,
    required DateTime end,
  }) async {
    try {
      if (!await _canUsePdfExportSlot()) return;
      final report = await _buildHistoryReportBytes(
        label: label,
        start: start,
        end: end,
      );
      final savedPath = await _channel.invokeMethod<String>(
        'savePdfToDocuments',
        {'fileName': report.fileName, 'bytes': report.bytes},
      );
      await _recordPdfExportSlot();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(savedPath ?? 'Saved to Documents/Candling'),
          backgroundColor: const Color(0xFF00A86B),
          action: SnackBarAction(
            label: 'SHARE',
            textColor: Colors.white,
            onPressed: () {
              unawaited(
                _shareReportBytes(
                  fileName: report.fileName,
                  bytes: report.bytes,
                  subject: 'Candling History Report - $label',
                ),
              );
            },
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Save error: $e'), backgroundColor: Colors.red),
      );
    }
  }

  Future<void> _saveEggCounterReportToDocuments({
    required String label,
    required DateTime start,
    required DateTime end,
  }) async {
    try {
      if (!await _canUsePdfExportSlot()) return;
      final report = await _buildEggCounterReportBytes(
        label: label,
        start: start,
        end: end,
      );
      final savedPath = await _channel.invokeMethod<String>(
        'savePdfToDocuments',
        {'fileName': report.fileName, 'bytes': report.bytes},
      );
      await _recordPdfExportSlot();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(savedPath ?? 'Saved to Documents/Candling'),
          backgroundColor: const Color(0xFF00A86B),
          action: SnackBarAction(
            label: 'SHARE',
            textColor: Colors.white,
            onPressed: () {
              unawaited(
                _shareReportBytes(
                  fileName: report.fileName,
                  bytes: report.bytes,
                  subject: 'Egg Counter History Report - $label',
                ),
              );
            },
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Save error: $e'), backgroundColor: Colors.red),
      );
    }
  }

  Future<void> _shareHistoryReport({
    required String label,
    required DateTime start,
    required DateTime end,
  }) async {
    try {
      if (!await _canUsePdfExportSlot()) return;
      final report = await _buildHistoryReportBytes(
        label: label,
        start: start,
        end: end,
      );
      await _shareReportBytes(
        fileName: report.fileName,
        bytes: report.bytes,
        subject: 'Candling History Report - $label',
      );
      await _recordPdfExportSlot();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Share error: $e'), backgroundColor: Colors.red),
      );
    }
  }

  Future<void> _shareEggCounterReport({
    required String label,
    required DateTime start,
    required DateTime end,
  }) async {
    try {
      if (!await _canUsePdfExportSlot()) return;
      final report = await _buildEggCounterReportBytes(
        label: label,
        start: start,
        end: end,
      );
      await _shareReportBytes(
        fileName: report.fileName,
        bytes: report.bytes,
        subject: 'Egg Counter History Report - $label',
      );
      await _recordPdfExportSlot();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Share error: $e'), backgroundColor: Colors.red),
      );
    }
  }

  pw.Document _buildEggCounterPdf({
    required String label,
    required DateTime start,
    required DateTime end,
    required List<EggCounterRecord> records,
    required List<SensorSnapshot> sensorSamples,
  }) {
    final pdf = pw.Document();
    final latest = records.isNotEmpty ? records.first : null;
    final counts = records.map((record) => record.count).toList();
    final highest = counts.isEmpty ? 0 : counts.reduce(math.max);
    final lowest = counts.isEmpty ? 0 : counts.reduce(math.min);
    final average = counts.isEmpty
        ? 0.0
        : counts.reduce((a, b) => a + b) / counts.length;
    final previous = records.length > 1 ? records[1] : null;
    final latestChange = latest == null || previous == null
        ? '--'
        : _formatEggCountDelta(latest.count - previous.count);

    final rangeDays = <DateTime>[];
    for (
      var day = DateTime(start.year, start.month, start.day);
      day.isBefore(end);
      day = day.add(const Duration(days: 1))
    ) {
      rangeDays.add(day);
    }

    final recordsByDay = <String, List<EggCounterRecord>>{};
    for (final record in records) {
      final time = record.p4ScanTime ?? record.timestamp;
      final key = DateFormat('yyyy-MM-dd').format(time);
      (recordsByDay[key] ??= []).add(record);
    }

    String fmtDate(DateTime? value) => value == null
        ? 'Not recorded'
        : DateFormat('MMM dd, yyyy - h:mm a').format(value);

    String slotList(List<int> slots, {int maxItems = 36}) {
      if (slots.isEmpty) return 'None';
      if (slots.length <= maxItems) return slots.join(', ');
      final hidden = slots.length - maxItems;
      return '${slots.take(maxItems).join(', ')} ... (+$hidden more)';
    }

    String dayText(EggCounterRecord record) =>
        record.eggDay == null ? '--' : 'Day ${record.eggDay}';

    pw.Widget stat(String title, String value, PdfColor color) {
      return pw.Expanded(
        child: pw.Container(
          padding: const pw.EdgeInsets.all(10),
          decoration: pw.BoxDecoration(
            border: pw.Border.all(color: PdfColors.grey300),
            borderRadius: const pw.BorderRadius.all(pw.Radius.circular(8)),
          ),
          child: pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              pw.Text(
                title,
                style: pw.TextStyle(fontSize: 9, color: PdfColors.grey600),
              ),
              pw.SizedBox(height: 4),
              pw.Text(
                value,
                style: pw.TextStyle(
                  fontSize: 16,
                  color: color,
                  fontWeight: pw.FontWeight.bold,
                ),
              ),
            ],
          ),
        ),
      );
    }

    pw.TableRow tableRow(List<String> cells, {bool header = false}) {
      return pw.TableRow(
        decoration: header
            ? const pw.BoxDecoration(color: PdfColors.grey200)
            : null,
        children: cells
            .map(
              (cell) => pw.Padding(
                padding: const pw.EdgeInsets.all(5),
                child: pw.Text(
                  cell,
                  style: pw.TextStyle(
                    fontSize: header ? 8 : 7,
                    fontWeight: header ? pw.FontWeight.bold : null,
                  ),
                ),
              ),
            )
            .toList(),
      );
    }

    pw.Widget countTrendGraph() {
      final chartPoints = <Map<String, dynamic>>[];

      if (rangeDays.length <= 1) {
        final todayRecords = List<EggCounterRecord>.from(records)
          ..sort((a, b) {
            final aTime = a.p4ScanTime ?? a.timestamp;
            final bTime = b.p4ScanTime ?? b.timestamp;
            return aTime.compareTo(bTime);
          });
        for (var i = 0; i < todayRecords.length; i++) {
          chartPoints.add({
            'label': '${i + 1}',
            'count': todayRecords[i].count,
          });
        }
        if (chartPoints.isEmpty) {
          chartPoints.add({'label': 'Today', 'count': 0});
        }
      } else {
        final step = (rangeDays.length / 14).ceil().clamp(1, 9999);
        for (var i = 0; i < rangeDays.length; i += step) {
          final day = rangeDays[i];
          final key = DateFormat('yyyy-MM-dd').format(day);
          final dayRecords = recordsByDay[key] ?? const <EggCounterRecord>[];
          final count = dayRecords.isEmpty ? 0 : dayRecords.first.count;
          chartPoints.add({
            'label': rangeDays.length <= 7
                ? DateFormat('EEE').format(day)
                : DateFormat('MM/dd').format(day),
            'count': count,
          });
        }
      }

      var maxCount = 1;
      for (final point in chartPoints) {
        final count = point['count'] as int;
        if (count > maxCount) maxCount = count;
      }

      const graphWidth = 360.0;
      return pw.Container(
        padding: const pw.EdgeInsets.all(10),
        decoration: pw.BoxDecoration(
          border: pw.Border.all(color: PdfColors.grey300),
          borderRadius: const pw.BorderRadius.all(pw.Radius.circular(8)),
        ),
        child: pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.Text(
              '$label Egg Count Graph',
              style: pw.TextStyle(fontSize: 12, fontWeight: pw.FontWeight.bold),
            ),
            pw.SizedBox(height: 3),
            pw.Text(
              'Bars show the latest P4 egg count recorded for each plotted point.',
              style: pw.TextStyle(fontSize: 8, color: PdfColors.grey600),
            ),
            pw.SizedBox(height: 8),
            ...chartPoints.map((point) {
              final count = point['count'] as int;
              final width = count == 0 ? 0.0 : graphWidth * count / maxCount;
              return pw.Padding(
                padding: const pw.EdgeInsets.only(bottom: 6),
                child: pw.Row(
                  children: [
                    pw.SizedBox(
                      width: 42,
                      child: pw.Text(
                        point['label'] as String,
                        style: const pw.TextStyle(fontSize: 7),
                      ),
                    ),
                    pw.SizedBox(
                      width: graphWidth,
                      child: pw.Stack(
                        children: [
                          pw.Container(
                            width: graphWidth,
                            height: 10,
                            color: PdfColors.grey100,
                          ),
                          pw.Container(
                            width: width,
                            height: 10,
                            color: PdfColors.blue700,
                          ),
                        ],
                      ),
                    ),
                    pw.SizedBox(width: 6),
                    pw.SizedBox(
                      width: 24,
                      child: pw.Text(
                        '$count',
                        style: const pw.TextStyle(fontSize: 7),
                        textAlign: pw.TextAlign.right,
                      ),
                    ),
                  ],
                ),
              );
            }),
          ],
        ),
      );
    }

    pw.Widget recordSummary(EggCounterRecord record) {
      final slots = record.occupiedSlotNumbers;
      // Per-slot detail: slot number, incubation day, and the exact date the
      // egg was placed (phone-authoritative). Useful for thesis traceability of
      // each egg's age and set date.
      final slotDetailRows = <pw.TableRow>[
        tableRow(['Slot', 'Day', 'Date Placed'], header: true),
      ];
      for (var i = 0; i < record.occupiedSlots.length; i++) {
        if (!record.occupiedSlots[i]) continue;
        final day = i < record.slotDays.length ? record.slotDays[i] : null;
        final placed = i < record.placedAt.length ? record.placedAt[i] : null;
        slotDetailRows.add(
          tableRow([
            '${i + 1}',
            day == null ? '--' : 'Day $day',
            placed == null ? 'Not recorded' : fmtDate(placed),
          ]),
        );
      }
      return pw.Container(
        margin: const pw.EdgeInsets.only(bottom: 8),
        padding: const pw.EdgeInsets.all(8),
        decoration: pw.BoxDecoration(
          border: pw.Border.all(color: PdfColors.grey300, width: 0.5),
          borderRadius: const pw.BorderRadius.all(pw.Radius.circular(8)),
        ),
        child: pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.Text(
              '${record.count} eggs | ${dayText(record)}',
              style: pw.TextStyle(fontSize: 10, fontWeight: pw.FontWeight.bold),
            ),
            pw.SizedBox(height: 3),
            pw.Text(
              'P4 scan: ${fmtDate(record.p4ScanTime)} | App sync: ${fmtDate(record.timestamp)}',
              style: pw.TextStyle(fontSize: 7, color: PdfColors.grey700),
            ),
            pw.SizedBox(height: 4),
            pw.Text(
              'Occupied slots: ${slotList(slots)}',
              style: const pw.TextStyle(fontSize: 7),
            ),
            if (slots.isNotEmpty) ...[
              pw.SizedBox(height: 6),
              pw.Text(
                'Per-slot detail',
                style: pw.TextStyle(
                  fontSize: 8,
                  fontWeight: pw.FontWeight.bold,
                ),
              ),
              pw.SizedBox(height: 3),
              pw.Table(
                border: pw.TableBorder.all(
                  color: PdfColors.grey300,
                  width: 0.4,
                ),
                columnWidths: {
                  0: const pw.FixedColumnWidth(40),
                  1: const pw.FixedColumnWidth(60),
                  2: const pw.FlexColumnWidth(),
                },
                children: slotDetailRows,
              ),
            ],
          ],
        ),
      );
    }

    final dailyRows = rangeDays.reversed.take(60).map((day) {
      final key = DateFormat('yyyy-MM-dd').format(day);
      final dayRecords = recordsByDay[key] ?? const <EggCounterRecord>[];
      final dayCounts = dayRecords.map((record) => record.count).toList();
      final dayLatest = dayCounts.isEmpty ? 0 : dayRecords.first.count;
      final dayMin = dayCounts.isEmpty ? 0 : dayCounts.reduce(math.min);
      final dayMax = dayCounts.isEmpty ? 0 : dayCounts.reduce(math.max);
      final dayAvg = dayCounts.isEmpty
          ? 0.0
          : dayCounts.reduce((a, b) => a + b) / dayCounts.length;
      return tableRow([
        DateFormat('MMM dd').format(day),
        '${dayRecords.length}',
        '$dayLatest',
        '$dayMin',
        '$dayMax',
        dayAvg.toStringAsFixed(1),
      ]);
    }).toList();

    final shownRecords = records.take(120).toList();

    pdf.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.all(34),
        header: (ctx) => pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.Row(
              mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
              children: [
                pw.Text(
                  'Egg Counter History Report',
                  style: pw.TextStyle(
                    fontSize: 18,
                    fontWeight: pw.FontWeight.bold,
                  ),
                ),
                pw.Text(
                  label,
                  style: pw.TextStyle(fontSize: 10, color: PdfColors.grey600),
                ),
              ],
            ),
            pw.SizedBox(height: 4),
            pw.Text(
              'Generated ${DateFormat('MMM dd, yyyy - h:mm a').format(DateTime.now())}',
              style: pw.TextStyle(fontSize: 9, color: PdfColors.grey600),
            ),
            pw.Divider(color: PdfColors.grey300),
          ],
        ),
        footer: (ctx) => pw.Row(
          mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
          children: [
            pw.Text(
              'Egg Counter',
              style: pw.TextStyle(fontSize: 8, color: PdfColors.grey500),
            ),
            pw.Text(
              'Page ${ctx.pageNumber} of ${ctx.pagesCount}',
              style: pw.TextStyle(fontSize: 8, color: PdfColors.grey500),
            ),
          ],
        ),
        build: (ctx) => [
          pw.Row(
            children: [
              stat('Records', '${records.length}', PdfColors.blue700),
              pw.SizedBox(width: 8),
              stat('Latest Count', '${latest?.count ?? 0}', PdfColors.blue700),
              pw.SizedBox(width: 8),
              stat('Average', average.toStringAsFixed(1), PdfColors.green700),
              pw.SizedBox(width: 8),
              stat('Highest', '$highest', PdfColors.orange700),
            ],
          ),
          pw.SizedBox(height: 8),
          pw.Text(
            'Lowest count: $lowest | Latest count change: $latestChange | Latest P4 scan: ${fmtDate(latest?.p4ScanTime)}',
            style: pw.TextStyle(fontSize: 9, color: PdfColors.grey600),
          ),
          pw.SizedBox(height: 8),
          pw.Container(
            padding: const pw.EdgeInsets.all(8),
            decoration: pw.BoxDecoration(
              color: PdfColors.grey100,
              border: pw.Border.all(color: PdfColors.grey300, width: 0.5),
              borderRadius: const pw.BorderRadius.all(pw.Radius.circular(8)),
            ),
            child: pw.Text(
              'Data note: P4 egg counter scans are treated as the authoritative occupancy record. '
              'When P4 reports an empty slot, that slot is cleared in the app and in this counter history.',
              style: pw.TextStyle(fontSize: 8, color: PdfColors.grey700),
            ),
          ),
          pw.SizedBox(height: 16),
          countTrendGraph(),
          pw.SizedBox(height: 16),
          pw.Text(
            'Daily Summary',
            style: pw.TextStyle(fontSize: 12, fontWeight: pw.FontWeight.bold),
          ),
          pw.SizedBox(height: 6),
          pw.Table(
            border: pw.TableBorder.all(color: PdfColors.grey300, width: 0.5),
            children: [
              tableRow([
                'Date',
                'Records',
                'Latest',
                'Min',
                'Max',
                'Avg',
              ], header: true),
              ...dailyRows,
            ],
          ),
          if (rangeDays.length > 60)
            pw.Padding(
              padding: const pw.EdgeInsets.only(top: 4),
              child: pw.Text(
                'Daily table limited to the latest 60 days in the selected range.',
                style: pw.TextStyle(fontSize: 7, color: PdfColors.grey600),
              ),
            ),
          pw.SizedBox(height: 16),
          ..._environmentGraphWidgets(sensorSamples),
          pw.SizedBox(height: 16),
          pw.Text(
            'Counter Records',
            style: pw.TextStyle(fontSize: 12, fontWeight: pw.FontWeight.bold),
          ),
          pw.SizedBox(height: 6),
          if (shownRecords.isEmpty)
            pw.Text(
              'No egg counter records were found in this report range.',
              style: pw.TextStyle(fontSize: 9, color: PdfColors.grey600),
            )
          else
            ...shownRecords.map(recordSummary),
          if (records.length > shownRecords.length)
            pw.Text(
              'Record list limited to the latest ${shownRecords.length} records in the selected range.',
              style: pw.TextStyle(fontSize: 7, color: PdfColors.grey600),
            ),
        ],
      ),
    );

    return pdf;
  }

  pw.Widget _pdfLegendDot(PdfColor c, String text) {
    return pw.Row(
      mainAxisSize: pw.MainAxisSize.min,
      children: [
        pw.Container(
          width: 8,
          height: 8,
          decoration: pw.BoxDecoration(color: c, shape: pw.BoxShape.circle),
        ),
        pw.SizedBox(width: 4),
        pw.Text(text, style: const pw.TextStyle(fontSize: 7)),
      ],
    );
  }

  // Time-series line chart of one environment metric for both incubators
  // (Main = P4 SHT3X, Sub = relay node). Shows the environment was held within
  // target ranges over time — the kind of evidence a thesis panel asks for.
  pw.Widget _pdfEnvironmentChart({
    required List<SensorSnapshot> sensorSamples,
    required String title,
    required String unit,
    required double? Function(SensorSnapshot) mainSel,
    required double? Function(SensorSnapshot) subSel,
    required PdfColor mainColor,
    required PdfColor subColor,
  }) {
    final ordered = List<SensorSnapshot>.from(sensorSamples)
      ..sort((a, b) => a.timestamp.compareTo(b.timestamp));
    final mainData = <pw.PointChartValue>[];
    final subData = <pw.PointChartValue>[];
    for (var i = 0; i < ordered.length; i++) {
      final mv = mainSel(ordered[i]);
      final sv = subSel(ordered[i]);
      if (mv != null) mainData.add(pw.PointChartValue(i.toDouble(), mv));
      if (sv != null) subData.add(pw.PointChartValue(i.toDouble(), sv));
    }

    final allVals = <double>[
      ...mainData.map((e) => e.y),
      ...subData.map((e) => e.y),
    ];

    if (allVals.isEmpty) {
      return pw.Container(
        padding: const pw.EdgeInsets.all(10),
        decoration: pw.BoxDecoration(
          border: pw.Border.all(color: PdfColors.grey300),
          borderRadius: const pw.BorderRadius.all(pw.Radius.circular(8)),
        ),
        child: pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.Text(
              title,
              style: pw.TextStyle(fontSize: 11, fontWeight: pw.FontWeight.bold),
            ),
            pw.SizedBox(height: 4),
            pw.Text(
              'No environment samples were recorded in this range yet.',
              style: pw.TextStyle(fontSize: 8, color: PdfColors.grey600),
            ),
          ],
        ),
      );
    }

    var minY = allVals.reduce(math.min);
    var maxY = allVals.reduce(math.max);
    minY = (minY - 1).floorToDouble();
    maxY = (maxY + 1).ceilToDouble();
    if (maxY <= minY) maxY = minY + 1;

    final n = ordered.length;
    final maxX = (n - 1) <= 0 ? 1.0 : (n - 1).toDouble();

    final yTicks = <double>[];
    const yCount = 5;
    for (var t = 0; t <= yCount; t++) {
      yTicks.add(minY + (maxY - minY) * t / yCount);
    }

    final xTicks = <double>[];
    const xCount = 4;
    for (var t = 0; t <= xCount; t++) {
      xTicks.add(maxX * t / xCount);
    }

    String xLabel(num v) {
      final idx = v.round().clamp(0, n - 1);
      return DateFormat('MM/dd\nh:mm a').format(ordered[idx].timestamp);
    }

    return pw.Container(
      height: 190,
      padding: const pw.EdgeInsets.fromLTRB(10, 10, 12, 8),
      decoration: pw.BoxDecoration(
        border: pw.Border.all(color: PdfColors.grey300),
        borderRadius: const pw.BorderRadius.all(pw.Radius.circular(8)),
      ),
      child: pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.Row(
            mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
            children: [
              pw.Text(
                title,
                style: pw.TextStyle(
                  fontSize: 11,
                  fontWeight: pw.FontWeight.bold,
                ),
              ),
              pw.Row(
                children: [
                  _pdfLegendDot(mainColor, 'Main'),
                  pw.SizedBox(width: 12),
                  _pdfLegendDot(subColor, 'Sub'),
                ],
              ),
            ],
          ),
          pw.SizedBox(height: 8),
          pw.Expanded(
            child: pw.Chart(
              grid: pw.CartesianGrid(
                xAxis: pw.FixedAxis(
                  xTicks,
                  format: (v) => xLabel(v),
                  textStyle: const pw.TextStyle(fontSize: 5),
                ),
                yAxis: pw.FixedAxis(
                  yTicks,
                  format: (v) => '${v.toStringAsFixed(0)}$unit',
                  divisions: true,
                  textStyle: const pw.TextStyle(fontSize: 6),
                ),
              ),
              datasets: [
                if (mainData.isNotEmpty)
                  pw.LineDataSet(
                    legend: 'Main',
                    data: mainData,
                    color: mainColor,
                    isCurved: false,
                    drawPoints: false,
                    lineWidth: 1.5,
                  ),
                if (subData.isNotEmpty)
                  pw.LineDataSet(
                    legend: 'Sub',
                    data: subData,
                    color: subColor,
                    isCurved: false,
                    drawPoints: false,
                    lineWidth: 1.5,
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // Heading + temperature graph + humidity graph (Main vs Sub) for PDF reports.
  List<pw.Widget> _environmentGraphWidgets(List<SensorSnapshot> sensorSamples) {
    return [
      pw.Text(
        'Environment Graphs (Main vs Sub)',
        style: pw.TextStyle(fontSize: 12, fontWeight: pw.FontWeight.bold),
      ),
      pw.SizedBox(height: 4),
      pw.Text(
        'Time-series of each incubator\'s temperature and humidity, showing the '
        'environment was maintained within target ranges over time.',
        style: pw.TextStyle(fontSize: 8, color: PdfColors.grey600),
      ),
      pw.SizedBox(height: 8),
      _pdfEnvironmentChart(
        sensorSamples: sensorSamples,
        title: 'Temperature over time (C)',
        unit: '',
        mainSel: (s) => s.temperature,
        subSel: (s) => s.subTemperature,
        mainColor: PdfColors.red700,
        subColor: PdfColors.orange400,
      ),
      pw.SizedBox(height: 10),
      _pdfEnvironmentChart(
        sensorSamples: sensorSamples,
        title: 'Humidity over time (%)',
        unit: '',
        mainSel: (s) => s.humidity,
        subSel: (s) => s.subHumidity,
        mainColor: PdfColors.blue700,
        subColor: PdfColors.teal400,
      ),
    ];
  }

  pw.Document _buildHistoryPdf({
    required String label,
    required DateTime start,
    required DateTime end,
    required List<EggSession> sessions,
    required List<SensorSnapshot> sensorSamples,
  }) {
    final pdf = pw.Document();
    final fertile = sessions.fold<int>(0, (sum, s) => sum + s.fertileCount);
    final infertile = sessions.fold<int>(0, (sum, s) => sum + s.infertileCount);
    final review = sessions.fold<int>(0, (sum, s) => sum + s.inReviewCount);
    final readyUnresolved = sessions.fold<int>(
      0,
      (sum, s) => sum + s.readyUnclassifiedCount,
    );
    final classified = fertile + infertile;
    final rate = classified == 0 ? 0 : (fertile / classified * 100).round();
    final days = <String, List<EggSession>>{};
    final scanTemps = sessions
        .where((session) => session.temperature != null)
        .map((session) => session.temperature!)
        .toList();
    final scanHums = sessions
        .where((session) => session.humidity != null)
        .map((session) => session.humidity!)
        .toList();
    final sampledTemps = sensorSamples
        .where((sample) => sample.temperature != null)
        .map((sample) => sample.temperature!)
        .toList();
    final sampledHums = sensorSamples
        .where((sample) => sample.humidity != null)
        .map((sample) => sample.humidity!)
        .toList();
    final sampledWater = sensorSamples
        .where((sample) => sample.waterLevel != null)
        .map((sample) => sample.waterLevel!)
        .toList();
    final lowWaterSamples = sensorSamples
        .where((sample) => sample.waterLow == true)
        .length;
    final sampledSubTemps = sensorSamples
        .where((sample) => sample.subTemperature != null)
        .map((sample) => sample.subTemperature!)
        .toList();
    final sampledSubHums = sensorSamples
        .where((sample) => sample.subHumidity != null)
        .map((sample) => sample.subHumidity!)
        .toList();

    for (final session in sessions) {
      final day = DateFormat('yyyy-MM-dd').format(session.timestamp);
      (days[day] ??= []).add(session);
    }

    final rangeDays = <DateTime>[];
    for (
      var day = DateTime(start.year, start.month, start.day);
      day.isBefore(end);
      day = day.add(const Duration(days: 1))
    ) {
      rangeDays.add(day);
    }

    final dayRows = rangeDays.reversed.toList();

    String fmtTemp(double? value) =>
        value == null ? 'Not recorded' : '${value.toStringAsFixed(1)} C';
    String fmtHum(double? value) =>
        value == null ? 'Not recorded' : '${value.toStringAsFixed(1)}%';
    String fmtWater(EggSession session) {
      if (session.waterLevel == null) return 'Not recorded';
      return '${session.waterLow == true ? 'LOW ' : ''}${session.waterLevel}%';
    }

    String fmtMs(int? value) => value == null ? '--' : '${value}ms';

    String summarizeDouble(
      List<double> values,
      String unit, {
      int decimals = 1,
    }) {
      if (values.isEmpty) return 'No samples';
      final min = values.reduce(math.min);
      final max = values.reduce(math.max);
      final avg = values.reduce((a, b) => a + b) / values.length;
      return 'avg ${avg.toStringAsFixed(decimals)}$unit, '
          'min ${min.toStringAsFixed(decimals)}$unit, '
          'max ${max.toStringAsFixed(decimals)}$unit '
          '(${values.length} samples)';
    }

    String summarizeInt(List<int> values, String unit) {
      if (values.isEmpty) return 'No samples';
      final min = values.reduce(math.min);
      final max = values.reduce(math.max);
      final avg = values.reduce((a, b) => a + b) / values.length;
      return 'avg ${avg.round()}$unit, min $min$unit, max $max$unit '
          '(${values.length} samples)';
    }

    String slotList(List<int>? slots) {
      if (slots == null) return 'Not recorded';
      if (slots.isEmpty) return 'None';
      return slots.join(', ');
    }

    List<int>? occupiedSlots(EggSession session) {
      if (!session.hasOccupancyData) return null;
      return [
        for (var i = 0; i < session.totalCells; i++)
          if (i < session.occupiedSlots.length && session.occupiedSlots[i])
            i + 1,
      ];
    }

    List<int> statusSlots(EggSession session, EggStatus status) {
      return [
        for (var i = 0; i < session.eggData.length; i++)
          if (session.eggData[i].status == status) i + 1,
      ];
    }

    String slotCode(EggSession session, int index) {
      final hasOccupancy = session.hasOccupancyData;
      if (hasOccupancy &&
          index < session.occupiedSlots.length &&
          !session.occupiedSlots[index]) {
        return 'E';
      }
      final status = index < session.eggData.length
          ? session.eggData[index].status
          : EggStatus.unknown;
      switch (status) {
        case EggStatus.fertile:
          return 'F';
        case EggStatus.infertile:
          return 'I';
        case EggStatus.unknown:
          return session.isSlotReady(index)
              ? 'U'
              : hasOccupancy
              ? 'R'
              : '?';
      }
    }

    List<pw.TableRow> slotMapRows(EggSession session) {
      return [
        for (var row = 0; row < session.rowCount; row++)
          pw.TableRow(
            children: [
              for (var col = 0; col < session.columnCount; col++)
                pw.Padding(
                  padding: const pw.EdgeInsets.all(3),
                  child: pw.Text(
                    '${row * session.columnCount + col + 1}:${slotCode(session, row * session.columnCount + col)}',
                    style: const pw.TextStyle(fontSize: 6),
                    textAlign: pw.TextAlign.center,
                  ),
                ),
            ],
          ),
      ];
    }

    pw.Widget stat(String title, String value, PdfColor color) {
      return pw.Expanded(
        child: pw.Container(
          padding: const pw.EdgeInsets.all(10),
          decoration: pw.BoxDecoration(
            border: pw.Border.all(color: PdfColors.grey300),
            borderRadius: const pw.BorderRadius.all(pw.Radius.circular(8)),
          ),
          child: pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              pw.Text(
                title,
                style: pw.TextStyle(fontSize: 9, color: PdfColors.grey600),
              ),
              pw.SizedBox(height: 4),
              pw.Text(
                value,
                style: pw.TextStyle(
                  fontSize: 16,
                  color: color,
                  fontWeight: pw.FontWeight.bold,
                ),
              ),
            ],
          ),
        ),
      );
    }

    pw.Widget historyGraph() {
      final rangeLength = rangeDays.length;
      final chartPoints = <Map<String, dynamic>>[];

      if (rangeLength <= 1) {
        final todaySessions = List<EggSession>.from(sessions)
          ..sort((a, b) => a.timestamp.compareTo(b.timestamp));
        for (var i = 0; i < todaySessions.length; i++) {
          final session = todaySessions[i];
          chartPoints.add({
            'label': i == 0 ? '1st' : '2nd',
            'fertile': session.fertileCount,
            'infertile': session.infertileCount,
            'review': session.inReviewCount,
            'unresolved': session.readyUnclassifiedCount,
          });
        }
        if (chartPoints.isEmpty) {
          chartPoints.add({
            'label': 'Today',
            'fertile': 0,
            'infertile': 0,
            'review': 0,
            'unresolved': 0,
          });
        }
      } else {
        for (final day in rangeDays) {
          final key = DateFormat('yyyy-MM-dd').format(day);
          final daySessions = days[key] ?? const <EggSession>[];
          chartPoints.add({
            'label': rangeLength <= 7
                ? DateFormat('EEE').format(day)
                : DateFormat('MM/dd').format(day),
            'fertile': daySessions.fold<int>(
              0,
              (sum, s) => sum + s.fertileCount,
            ),
            'infertile': daySessions.fold<int>(
              0,
              (sum, s) => sum + s.infertileCount,
            ),
            'review': daySessions.fold<int>(
              0,
              (sum, s) => sum + s.inReviewCount,
            ),
            'unresolved': daySessions.fold<int>(
              0,
              (sum, s) => sum + s.readyUnclassifiedCount,
            ),
          });
        }
      }

      var maxTotal = 1;
      for (final point in chartPoints) {
        final total =
            (point['fertile'] as int) +
            (point['infertile'] as int) +
            (point['review'] as int) +
            (point['unresolved'] as int);
        if (total > maxTotal) maxTotal = total;
      }

      pw.Widget segment(int value, PdfColor color) {
        if (value <= 0) return pw.SizedBox();
        return pw.Expanded(
          flex: value,
          child: pw.Container(height: 10, color: color),
        );
      }

      return pw.Container(
        padding: const pw.EdgeInsets.all(10),
        decoration: pw.BoxDecoration(
          border: pw.Border.all(color: PdfColors.grey300),
          borderRadius: const pw.BorderRadius.all(pw.Radius.circular(8)),
        ),
        child: pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.Text(
              rangeLength <= 1 ? 'Today Graph' : '$label Graph',
              style: pw.TextStyle(fontSize: 12, fontWeight: pw.FontWeight.bold),
            ),
            pw.SizedBox(height: 3),
            pw.Text(
              'Blue = fertile, red = infertile, amber = in review, gray = Day 5-10 ready/unclassified',
              style: pw.TextStyle(fontSize: 8, color: PdfColors.grey600),
            ),
            pw.SizedBox(height: 8),
            ...chartPoints.map((point) {
              final fertileValue = point['fertile'] as int;
              final infertileValue = point['infertile'] as int;
              final reviewValue = point['review'] as int;
              final unresolvedValue = point['unresolved'] as int;
              final total =
                  fertileValue + infertileValue + reviewValue + unresolvedValue;
              return pw.Padding(
                padding: const pw.EdgeInsets.only(bottom: 6),
                child: pw.Row(
                  children: [
                    pw.SizedBox(
                      width: 42,
                      child: pw.Text(
                        point['label'] as String,
                        style: const pw.TextStyle(fontSize: 7),
                      ),
                    ),
                    pw.SizedBox(
                      width: 360,
                      child: pw.Stack(
                        children: [
                          pw.Container(
                            width: 360,
                            height: 10,
                            color: PdfColors.grey100,
                          ),
                          pw.Container(
                            width: total == 0 ? 0 : 360 * total / maxTotal,
                            height: 10,
                            child: pw.Row(
                              children: [
                                segment(fertileValue, PdfColors.blue700),
                                segment(infertileValue, PdfColors.red700),
                                segment(reviewValue, PdfColors.orange700),
                                segment(unresolvedValue, PdfColors.grey500),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                    pw.SizedBox(width: 6),
                    pw.SizedBox(
                      width: 24,
                      child: pw.Text(
                        '$total',
                        style: const pw.TextStyle(fontSize: 7),
                        textAlign: pw.TextAlign.right,
                      ),
                    ),
                  ],
                ),
              );
            }),
          ],
        ),
      );
    }

    pw.TableRow tableRow(List<String> cells, {bool header = false}) {
      return pw.TableRow(
        decoration: header
            ? const pw.BoxDecoration(color: PdfColors.grey200)
            : null,
        children: cells
            .map(
              (cell) => pw.Padding(
                padding: const pw.EdgeInsets.all(5),
                child: pw.Text(
                  cell,
                  style: pw.TextStyle(
                    fontSize: header ? 8 : 7,
                    fontWeight: header ? pw.FontWeight.bold : null,
                  ),
                ),
              ),
            )
            .toList(),
      );
    }

    pw.Widget sessionSlotReport(EggSession session) {
      final occupied = occupiedSlots(session);
      final fertileSlotList = statusSlots(session, EggStatus.fertile);
      final infertileSlotList = statusSlots(session, EggStatus.infertile);
      final image = session.imageBytes == null
          ? null
          : pw.MemoryImage(session.imageBytes!);

      final map = pw.Table(
        border: pw.TableBorder.all(color: PdfColors.grey300, width: 0.4),
        children: slotMapRows(session),
      );

      return pw.Container(
        margin: const pw.EdgeInsets.only(bottom: 12),
        padding: const pw.EdgeInsets.all(10),
        decoration: pw.BoxDecoration(
          border: pw.Border.all(color: PdfColors.grey300, width: 0.6),
          borderRadius: const pw.BorderRadius.all(pw.Radius.circular(8)),
        ),
        child: pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.Text(
              DateFormat('MMM dd, yyyy - h:mm a').format(session.timestamp),
              style: pw.TextStyle(fontSize: 10, fontWeight: pw.FontWeight.bold),
            ),
            pw.SizedBox(height: 4),
            pw.Text(
              '${session.dayRangeLabel} | Occupied: ${session.occupiedCount?.toString() ?? 'Not recorded'} | Empty: ${session.emptyCount?.toString() ?? 'Not recorded'} | '
              'Temp: ${fmtTemp(session.temperature)} | Humidity: ${fmtHum(session.humidity)} | '
              'Water: ${fmtWater(session)} | Endpoint: ${session.captureEndpoint}',
              style: pw.TextStyle(fontSize: 7, color: PdfColors.grey700),
            ),
            pw.SizedBox(height: 2),
            pw.Text(
              'Capture: ${fmtMs(session.captureMs)} | Total: ${fmtMs(session.totalScanMs)} | '
              'Classification: ${session.usedAi ? (session.aiModel ?? 'Legacy model') : 'Not run'} | '
              'Image: ${session.imageWidth != null && session.imageHeight != null ? '${session.imageWidth}x${session.imageHeight}px' : 'Not recorded'} | '
              'Grid: ${session.columnCount}x${session.rowCount}',
              style: pw.TextStyle(fontSize: 7, color: PdfColors.grey700),
            ),
            pw.SizedBox(height: 2),
            pw.Text(
              'Ready: ${session.readyEggCount} | Analyzed: ${session.analyzedSlotCount} | Classified: ${session.classifiedCount} | '
              'In review: ${session.inReviewCount} | Ready without result: ${session.readyUnclassifiedCount} | '
              'P4 time trusted: ${session.p4TimeTrusted?.toString() ?? 'Not recorded'} | Expected LEDs: ${session.expectedCandlingLedCount?.toString() ?? 'Not recorded'}',
              style: pw.TextStyle(fontSize: 7, color: PdfColors.grey700),
            ),
            pw.SizedBox(height: 2),
            pw.Text(
              'Candling LEDs verified: ${session.candlingLightsVerified?.toString() ?? 'Not recorded'} | '
              'Cache valid: ${session.candlingLedCacheValid?.toString() ?? 'Not recorded'} | '
              'Active: ${slotList(session.activeCandlingLeds)} | Missing: ${slotList(session.missingCandlingLeds)}',
              style: pw.TextStyle(fontSize: 7, color: PdfColors.grey700),
            ),
            pw.SizedBox(height: 8),
            if (image != null)
              pw.Row(
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                children: [
                  pw.Container(
                    width: 150,
                    height: 105,
                    decoration: pw.BoxDecoration(
                      border: pw.Border.all(
                        color: PdfColors.grey300,
                        width: 0.5,
                      ),
                    ),
                    child: pw.Image(image, fit: pw.BoxFit.contain),
                  ),
                  pw.SizedBox(width: 10),
                  pw.Expanded(child: map),
                ],
              )
            else
              map,
            pw.SizedBox(height: 8),
            pw.Text(
              'Occupied slots: ${slotList(occupied)}',
              style: const pw.TextStyle(fontSize: 7),
            ),
            pw.Text(
              'Fertile slots: ${slotList(fertileSlotList)}',
              style: const pw.TextStyle(fontSize: 7),
            ),
            pw.Text(
              'Infertile slots: ${slotList(infertileSlotList)}',
              style: const pw.TextStyle(fontSize: 7),
            ),
            pw.Text(
              'Ready Day 5-10 slots: ${slotList(session.readySlotNumbers)}',
              style: const pw.TextStyle(fontSize: 7),
            ),
            pw.Text(
              'Analyzed slots: ${slotList(session.analyzedSlotNumbers)}',
              style: const pw.TextStyle(fontSize: 7),
            ),
            pw.Text(
              'In review - waiting Day 5: ${slotList(session.waitingForDay5SlotNumbers)}',
              style: const pw.TextStyle(fontSize: 7),
            ),
            pw.Text(
              'In review - unknown age: ${slotList(session.unknownAgeReviewSlotNumbers)}',
              style: const pw.TextStyle(fontSize: 7),
            ),
            pw.Text(
              'Ready without conclusive result: ${slotList(session.readyUnclassifiedSlotNumbers)}',
              style: const pw.TextStyle(fontSize: 7),
            ),
          ],
        ),
      );
    }

    pw.Widget sessionSlotEvidenceTable(EggSession session) {
      String occupancyFor(int index) {
        if (!session.hasOccupancyData) return '--';
        return session.isOccupiedSlot(index) ? 'Yes' : 'No';
      }

      String confidenceFor(int index) {
        final status = session.statusForSlot(index);
        if (status == EggStatus.unknown) return '--';
        return '${(session.confidenceForSlot(index) * 100).toStringAsFixed(2)}%';
      }

      String boundsFor(int index) {
        if (index < 0 || index >= session.eggData.length) return '--';
        final egg = session.eggData[index];
        if (egg.x1 == null ||
            egg.y1 == null ||
            egg.x2 == null ||
            egg.y2 == null) {
          return '--';
        }
        return '${egg.x1},${egg.y1}-${egg.x2},${egg.y2}';
      }

      return pw.Table(
        border: pw.TableBorder.all(color: PdfColors.grey300, width: 0.4),
        columnWidths: {
          0: const pw.FixedColumnWidth(24),
          1: const pw.FixedColumnWidth(30),
          2: const pw.FixedColumnWidth(32),
          3: const pw.FixedColumnWidth(24),
          4: const pw.FixedColumnWidth(66),
          5: const pw.FlexColumnWidth(),
          6: const pw.FixedColumnWidth(38),
          7: const pw.FixedColumnWidth(38),
          8: const pw.FixedColumnWidth(60),
        },
        children: [
          tableRow([
            'Slot',
            'R/C',
            'Occ',
            'Day',
            'Placed',
            'Research status',
            'Analyzed',
            'Conf.',
            'Bounds px',
          ], header: true),
          for (var index = 0; index < session.totalCells; index++)
            tableRow([
              '${index + 1}',
              '${index ~/ session.columnCount + 1}/${index % session.columnCount + 1}',
              occupancyFor(index),
              session.dayForSlot(index)?.toString() ?? '--',
              session.placedAtForSlot(index) == null
                  ? '--'
                  : DateFormat(
                      'yyyy-MM-dd HH:mm',
                    ).format(session.placedAtForSlot(index)!),
              session.researchStatusForSlot(index),
              session.wasSlotAnalyzed(index) ? 'Yes' : 'No',
              confidenceFor(index),
              boundsFor(index),
            ]),
        ],
      );
    }

    pdf.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.all(34),
        header: (ctx) => pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.Row(
              mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
              children: [
                pw.Text(
                  'Candling History Report',
                  style: pw.TextStyle(
                    fontSize: 18,
                    fontWeight: pw.FontWeight.bold,
                  ),
                ),
                pw.Text(
                  label,
                  style: pw.TextStyle(fontSize: 10, color: PdfColors.grey600),
                ),
              ],
            ),
            pw.SizedBox(height: 4),
            pw.Text(
              'Generated ${DateFormat('MMM dd, yyyy - h:mm a').format(DateTime.now())}',
              style: pw.TextStyle(fontSize: 9, color: PdfColors.grey600),
            ),
            pw.Divider(color: PdfColors.grey300),
          ],
        ),
        footer: (ctx) => pw.Row(
          mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
          children: [
            pw.Text(
              'Candling',
              style: pw.TextStyle(fontSize: 8, color: PdfColors.grey500),
            ),
            pw.Text(
              'Page ${ctx.pageNumber} of ${ctx.pagesCount}',
              style: pw.TextStyle(fontSize: 8, color: PdfColors.grey500),
            ),
          ],
        ),
        build: (ctx) => [
          pw.Row(
            children: [
              stat('Sessions', '${sessions.length}', PdfColors.blue700),
              pw.SizedBox(width: 8),
              stat('Fertile', '$fertile', PdfColors.green700),
              pw.SizedBox(width: 8),
              stat('Infertile', '$infertile', PdfColors.red700),
              pw.SizedBox(width: 8),
              stat('In Review', '$review', PdfColors.orange700),
            ],
          ),
          pw.SizedBox(height: 10),
          pw.Text(
            'Classified: $classified | Fertility rate among classified records: $rate% | '
            'Day 5-10 ready without a result: $readyUnresolved',
            style: pw.TextStyle(fontSize: 9, color: PdfColors.grey600),
          ),
          pw.SizedBox(height: 8),
          pw.Container(
            padding: const pw.EdgeInsets.all(8),
            decoration: pw.BoxDecoration(
              color: PdfColors.grey100,
              border: pw.Border.all(color: PdfColors.grey300, width: 0.5),
              borderRadius: const pw.BorderRadius.all(pw.Radius.circular(8)),
            ),
            child: pw.Text(
              'Data note: This report only includes values recorded by the app. '
              'Fields marked "Not recorded" were not stored for that session or '
              'were unavailable while the phone was disconnected from the S3/P4 hub. '
              'Counts are session observations, not necessarily unique eggs. The temporary '
              'app-generated fertility verdicts require field validation.',
              style: pw.TextStyle(fontSize: 8, color: PdfColors.grey700),
            ),
          ),
          pw.SizedBox(height: 16),
          historyGraph(),
          pw.SizedBox(height: 16),
          pw.Text(
            'Environment Summary',
            style: pw.TextStyle(fontSize: 12, fontWeight: pw.FontWeight.bold),
          ),
          pw.SizedBox(height: 6),
          pw.Table(
            border: pw.TableBorder.all(color: PdfColors.grey300, width: 0.5),
            columnWidths: {
              0: const pw.FixedColumnWidth(120),
              1: const pw.FlexColumnWidth(),
            },
            children: [
              tableRow(['Metric', 'Recorded Value'], header: true),
              tableRow([
                'Sensor samples',
                '${sensorSamples.length} samples in selected range',
              ]),
              tableRow([
                'Main temperature',
                summarizeDouble(sampledTemps, ' C'),
              ]),
              tableRow(['Main humidity', summarizeDouble(sampledHums, '%')]),
              tableRow([
                'Sub temperature',
                summarizeDouble(sampledSubTemps, ' C'),
              ]),
              tableRow(['Sub humidity', summarizeDouble(sampledSubHums, '%')]),
              tableRow(['Water history', summarizeInt(sampledWater, '%')]),
              tableRow([
                'Low-water samples',
                sensorSamples.isEmpty
                    ? 'No samples'
                    : '$lowWaterSamples of ${sensorSamples.length}',
              ]),
              tableRow([
                'Scan-time temperature',
                summarizeDouble(scanTemps, ' C'),
              ]),
              tableRow(['Scan-time humidity', summarizeDouble(scanHums, '%')]),
            ],
          ),
          pw.SizedBox(height: 16),
          ..._environmentGraphWidgets(sensorSamples),
          pw.SizedBox(height: 16),
          pw.Text(
            'Daily Summary',
            style: pw.TextStyle(fontSize: 12, fontWeight: pw.FontWeight.bold),
          ),
          pw.SizedBox(height: 6),
          pw.Table(
            border: pw.TableBorder.all(color: PdfColors.grey300, width: 0.5),
            children: [
              tableRow([
                'Date',
                'Sessions',
                'Fertile',
                'Infertile',
                'In Review',
                'Ready/No Result',
              ], header: true),
              ...dayRows.map((day) {
                final key = DateFormat('yyyy-MM-dd').format(day);
                final daySessions = days[key] ?? const <EggSession>[];
                final dayFertile = daySessions.fold<int>(
                  0,
                  (sum, s) => sum + s.fertileCount,
                );
                final dayInfertile = daySessions.fold<int>(
                  0,
                  (sum, s) => sum + s.infertileCount,
                );
                final dayReview = daySessions.fold<int>(
                  0,
                  (sum, s) => sum + s.inReviewCount,
                );
                final dayUnresolved = daySessions.fold<int>(
                  0,
                  (sum, s) => sum + s.readyUnclassifiedCount,
                );
                return tableRow([
                  DateFormat('MMM dd, yyyy').format(day),
                  '${daySessions.length}',
                  '$dayFertile',
                  '$dayInfertile',
                  '$dayReview',
                  '$dayUnresolved',
                ]);
              }),
            ],
          ),
          pw.SizedBox(height: 16),
          pw.Text(
            'Session Records',
            style: pw.TextStyle(fontSize: 12, fontWeight: pw.FontWeight.bold),
          ),
          pw.SizedBox(height: 6),
          pw.Table(
            border: pw.TableBorder.all(color: PdfColors.grey300, width: 0.5),
            columnWidths: {
              0: const pw.FixedColumnWidth(66),
              1: const pw.FixedColumnWidth(45),
              2: const pw.FixedColumnWidth(30),
              3: const pw.FixedColumnWidth(34),
              4: const pw.FixedColumnWidth(34),
              5: const pw.FixedColumnWidth(38),
              6: const pw.FixedColumnWidth(38),
              7: const pw.FixedColumnWidth(48),
              8: const pw.FlexColumnWidth(),
            },
            children: [
              tableRow([
                'Date / Time',
                'Age',
                'Occ',
                'Ready',
                'Review',
                'F/I',
                'Analyzed',
                'Timing',
                'Classification',
              ], header: true),
              ...sessions.map(
                (s) => tableRow([
                  DateFormat('MMM dd, h:mm a').format(s.timestamp),
                  s.dayRangeLabel,
                  s.occupiedCount?.toString() ?? '--',
                  '${s.readyEggCount}',
                  '${s.inReviewCount}',
                  '${s.fertileCount}/${s.infertileCount}',
                  '${s.analyzedSlotCount}',
                  fmtMs(s.totalScanMs),
                  s.usedAi ? (s.aiModel ?? 'Legacy') : 'Not run',
                ]),
              ),
            ],
          ),
          pw.SizedBox(height: 16),
          pw.Text(
            'Per-Session Slot Reports',
            style: pw.TextStyle(fontSize: 12, fontWeight: pw.FontWeight.bold),
          ),
          pw.SizedBox(height: 4),
          pw.Text(
            'Slot map codes: F=fertile, I=infertile, R=in review, U=Day 5-10 ready without a result, E=empty, ?=occupancy not recorded.',
            style: pw.TextStyle(fontSize: 8, color: PdfColors.grey600),
          ),
          pw.SizedBox(height: 8),
          if (sessions.isEmpty)
            pw.Text(
              'No candling sessions were recorded in this report range.',
              style: pw.TextStyle(fontSize: 9, color: PdfColors.grey600),
            )
          else
            ...sessions.expand(
              (session) => [
                sessionSlotReport(session),
                sessionSlotEvidenceTable(session),
                pw.SizedBox(height: 16),
              ],
            ),
        ],
      ),
    );

    return pdf;
  }

  // History Tab
  Widget _buildHistoryTab() {
    return DefaultTabController(
      length: 2,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: TabBar(
              labelColor: const Color(0xFF2979FF),
              unselectedLabelColor: _appMutedTextColor(context),
              indicatorColor: const Color(0xFF2979FF),
              dividerColor: Colors.transparent,
              tabs: const [
                Tab(icon: Icon(Icons.camera_alt_rounded), text: 'Candling'),
                Tab(icon: Icon(Icons.egg_alt_rounded), text: 'Egg Counter'),
              ],
            ),
          ),
          Expanded(
            child: TabBarView(
              children: [
                _buildCandlingHistoryView(),
                _buildEggCounterHistoryView(),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCandlingHistoryView() {
    final filteredSessions = _historySearch.isEmpty
        ? _sessions
        : _sessions.where((s) {
            final searchable = <String>[
              DateFormat('MMM dd, yyyy - h:mm a').format(s.timestamp),
              s.id.toString(),
              s.aiModel ?? '',
              s.captureEndpoint,
              s.dayRangeLabel,
              'fertile ${s.fertileCount}',
              'infertile ${s.infertileCount}',
              'review ${s.inReviewCount}',
              'occupied ${s.occupiedCount ?? '--'}',
              'ready ${s.readyEggCount}',
              'analyzed ${s.analyzedSlotCount}',
              'waiting ${s.waitingForDay5SlotNumbers.join(' ')}',
              'slots ${s.analyzedSlotNumbers.join(' ')}',
            ].join(' ').toLowerCase();
            return searchable.contains(_historySearch);
          }).toList();

    return RefreshIndicator(
      onRefresh: () => _refreshApp(),
      child: CustomScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          SliverToBoxAdapter(
            child: _premiumEntry(
              0,
              Column(
                children: [
                  _buildHistoryOverview(),
                  ExpansionTile(
                    tilePadding: const EdgeInsets.symmetric(horizontal: 16),
                    title: const Text('Statistics and research log'),
                    children: [_buildStatsHeader()],
                  ),
                ],
              ),
            ),
          ),
          // Search bar
          SliverToBoxAdapter(
            child: _premiumEntry(
              1,
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                child: Row(
                  children: [
                    Tooltip(
                      message: 'Export history',
                      child: SizedBox(
                        height: 54,
                        width: 54,
                        child: FilledButton(
                          onPressed: _showHistoryExportSheet,
                          style: FilledButton.styleFrom(
                            backgroundColor: const Color(0xFF2979FF),
                            foregroundColor: Colors.white,
                            padding: EdgeInsets.zero,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(8),
                            ),
                          ),
                          child: const Icon(Icons.file_upload_rounded),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: TextField(
                        controller: _searchController,
                        onChanged: (v) =>
                            setState(() => _historySearch = v.toLowerCase()),
                        style: TextStyle(color: _appTextColor(context)),
                        decoration: InputDecoration(
                          hintText: 'Search history...',
                          hintStyle: TextStyle(
                            color: _appFaintTextColor(context),
                          ),
                          suffixIcon: Padding(
                            padding: const EdgeInsets.only(right: 6),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                if (_historySearch.isNotEmpty)
                                  IconButton(
                                    icon: Icon(
                                      Icons.clear,
                                      color: _appFaintTextColor(context),
                                    ),
                                    onPressed: () {
                                      _searchController.clear();
                                      setState(() => _historySearch = '');
                                    },
                                  ),
                              ],
                            ),
                          ),
                          filled: true,
                          fillColor: _appCardColor(context),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(14),
                            borderSide: BorderSide.none,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          // Delete row
          if (!_isSelectionMode && filteredSessions.isNotEmpty)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton.icon(
                      icon: const Icon(Icons.delete_outline, size: 18),
                      label: const Text('Delete'),
                      onPressed: _showDeleteOptions,
                      style: TextButton.styleFrom(foregroundColor: Colors.red),
                    ),
                  ],
                ),
              ),
            ),
          if (_isSelectionMode)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      '${_selectedSessions.length} selected',
                      style: const TextStyle(fontSize: 16),
                    ),
                    Row(
                      children: [
                        TextButton(
                          onPressed: () => setState(() {
                            _isSelectionMode = false;
                            _selectedSessions.clear();
                          }),
                          child: const Text('Cancel'),
                        ),
                        const SizedBox(width: 8),
                        ElevatedButton(
                          onPressed: _selectedSessions.isEmpty
                              ? null
                              : _deleteSelected,
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.red,
                          ),
                          child: const Text('Delete'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          filteredSessions.isEmpty
              ? SliverFillRemaining(
                  child: Center(
                    child: Text(
                      _historySearch.isNotEmpty
                          ? 'No sessions match "$_historySearch"'
                          : 'No candling sessions yet',
                      style: TextStyle(color: _appSubtleTextColor(context)),
                    ),
                  ),
                )
              : SliverList(
                  delegate: SliverChildBuilderDelegate(
                    (context, index) =>
                        _buildSessionCard(filteredSessions[index], index),
                    childCount: filteredSessions.length,
                  ),
                ),
        ],
      ),
    );
  }

  Widget _buildEggCounterHistoryView() {
    return RefreshIndicator(
      onRefresh: () async {
        await _refreshApp();
        await _syncEggGridFromP4();
      },
      child: CustomScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          SliverToBoxAdapter(
            child: _premiumEntry(0, _buildEggCounterStatsHeader()),
          ),
          if (!_isCounterSelectionMode && _eggCounterHistory.isNotEmpty)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton.icon(
                      icon: const Icon(Icons.delete_outline, size: 18),
                      label: const Text('Select to delete'),
                      onPressed: () =>
                          setState(() => _isCounterSelectionMode = true),
                      style: TextButton.styleFrom(foregroundColor: Colors.red),
                    ),
                  ],
                ),
              ),
            ),
          if (_isCounterSelectionMode)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      '${_selectedCounterRecords.length} selected',
                      style: const TextStyle(fontSize: 16),
                    ),
                    Row(
                      children: [
                        TextButton(
                          onPressed: () => setState(() {
                            _isCounterSelectionMode = false;
                            _selectedCounterRecords.clear();
                          }),
                          child: const Text('Cancel'),
                        ),
                        const SizedBox(width: 8),
                        ElevatedButton(
                          onPressed: _selectedCounterRecords.isEmpty
                              ? null
                              : _deleteSelectedCounterRecords,
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.red,
                          ),
                          child: const Text('Delete'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          _eggCounterHistory.isEmpty
              ? SliverFillRemaining(
                  child: Center(
                    child: Text(
                      'No egg counter records yet',
                      style: TextStyle(color: _appSubtleTextColor(context)),
                    ),
                  ),
                )
              : SliverList(
                  delegate: SliverChildBuilderDelegate(
                    (context, index) =>
                        _buildEggCounterRecordCard(_eggCounterHistory[index]),
                    childCount: _eggCounterHistory.length,
                  ),
                ),
        ],
      ),
    );
  }

  Widget _buildEggCounterStatsHeader() {
    final latest = _eggCounterHistory.isNotEmpty
        ? _eggCounterHistory.first
        : null;
    final now = DateTime.now();
    final todayStart = DateTime(now.year, now.month, now.day);
    final weekStart = todayStart.subtract(const Duration(days: 6));
    final todayRecords = _eggCounterHistory
        .where((record) => record.timestamp.isAfter(todayStart))
        .length;
    final weekRecords = _eggCounterHistory.where((record) {
      final time = record.p4ScanTime ?? record.timestamp;
      return !time.isBefore(weekStart);
    }).length;
    final last7Days = List.generate(7, (index) {
      final day = now.subtract(Duration(days: 6 - index));
      return DateFormat('yyyy-MM-dd').format(day);
    });
    final latestCountByDay = <String, int>{};
    for (final record in _eggCounterHistory) {
      final key = DateFormat(
        'yyyy-MM-dd',
      ).format(record.p4ScanTime ?? record.timestamp);
      latestCountByDay.putIfAbsent(key, () => record.count);
    }

    var highestCount = 0;
    var lowestCount = latest?.count ?? 0;
    var totalCount = 0;
    for (final record in _eggCounterHistory) {
      if (record.count > highestCount) highestCount = record.count;
      if (record.count < lowestCount) lowestCount = record.count;
      totalCount += record.count;
    }
    final averageCount = _eggCounterHistory.isEmpty
        ? 0.0
        : totalCount / _eggCounterHistory.length;
    final previous = _eggCounterHistory.length > 1
        ? _eggCounterHistory[1]
        : null;
    final latestChange = latest == null || previous == null
        ? '--'
        : _formatEggCountDelta(latest.count - previous.count);

    return Container(
      margin: const EdgeInsets.all(16),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: _appCardColor(context),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'EGG COUNTER HISTORY',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: _appMutedTextColor(context),
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              SizedBox(
                width: 42,
                height: 42,
                child: Tooltip(
                  message: 'Export egg counter PDF',
                  child: FilledButton(
                    onPressed: _showEggCounterExportSheet,
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFF2979FF),
                      foregroundColor: Colors.white,
                      padding: EdgeInsets.zero,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    child: const Icon(Icons.picture_as_pdf_rounded, size: 20),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              _buildStatItem(
                'Latest',
                '${latest?.count ?? _p4EggCount ?? 0}',
                const Color(0xFF2979FF),
              ),
              _buildStatItem(
                'Records',
                _eggCounterHistory.length.toString(),
                _appTextColor(context),
              ),
              _buildStatItem(
                'Today',
                todayRecords.toString(),
                const Color(0xFF00E676),
              ),
            ],
          ),
          const SizedBox(height: 16),
          _buildDataRow(
            'Latest P4 scan:',
            latest?.p4ScanTime == null
                ? 'Not recorded'
                : _formatSlotDateTime(latest!.p4ScanTime),
          ),
          _buildDataRow(
            'Latest app sync:',
            latest == null
                ? 'Not recorded'
                : _formatSlotDateTime(latest.timestamp),
          ),
          _buildDataRow(
            'Occupied slots:',
            latest == null
                ? 'None'
                : '${latest.occupiedSlotNumbers.length} slots',
          ),
          const SizedBox(height: 24),
          Text(
            'LAST 7 DAYS - P4 EGG COUNT',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: _appMutedTextColor(context),
              fontSize: 12,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 12),
          SizedBox(
            height: 150,
            child: BarChart(
              BarChartData(
                alignment: BarChartAlignment.spaceAround,
                maxY: _eggCounterGraphMaxY(last7Days, latestCountByDay),
                minY: 0,
                barTouchData: BarTouchData(enabled: false),
                titlesData: FlTitlesData(
                  show: true,
                  bottomTitles: AxisTitles(
                    sideTitles: SideTitles(
                      showTitles: true,
                      getTitlesWidget: (value, meta) {
                        final index = value.toInt();
                        if (index < 0 || index >= last7Days.length) {
                          return const Text('');
                        }
                        final date = DateTime.parse(last7Days[index]);
                        return Text(
                          '${date.day}',
                          style: TextStyle(
                            color: _appSubtleTextColor(context),
                            fontSize: 10,
                          ),
                        );
                      },
                      reservedSize: 20,
                    ),
                  ),
                  leftTitles: AxisTitles(
                    sideTitles: SideTitles(
                      showTitles: true,
                      reservedSize: 28,
                      interval: 10,
                      getTitlesWidget: (value, meta) => Text(
                        value.toInt().toString(),
                        style: TextStyle(
                          color: _appFaintTextColor(context),
                          fontSize: 9,
                        ),
                      ),
                    ),
                  ),
                  rightTitles: AxisTitles(
                    sideTitles: SideTitles(showTitles: false),
                  ),
                  topTitles: AxisTitles(
                    sideTitles: SideTitles(showTitles: false),
                  ),
                ),
                borderData: FlBorderData(show: false),
                gridData: FlGridData(
                  show: true,
                  drawVerticalLine: false,
                  getDrawingHorizontalLine: (_) =>
                      FlLine(color: _appPanelColor(context), strokeWidth: 1),
                ),
                barGroups: last7Days.asMap().entries.map((entry) {
                  final count = latestCountByDay[entry.value] ?? 0;
                  return BarChartGroupData(
                    x: entry.key,
                    barRods: [
                      BarChartRodData(
                        toY: count.toDouble(),
                        color: count > 0
                            ? const Color(0xFF2979FF)
                            : _appDisabledColor(context),
                        width: 14,
                        borderRadius: const BorderRadius.vertical(
                          top: Radius.circular(4),
                        ),
                      ),
                    ],
                  );
                }).toList(),
              ),
            ),
          ),
          const SizedBox(height: 24),
          Text(
            'THESIS EGG COUNTER DATA LOG',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: _appMutedTextColor(context),
              fontSize: 12,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: _appPanelColor(context),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Column(
              children: [
                _buildDataRow(
                  'Total counter records:',
                  _eggCounterHistory.length.toString(),
                ),
                _buildDataRow('Records this week:', weekRecords.toString()),
                _buildDataRow('Records today:', todayRecords.toString()),
                _buildDataRow(
                  'Average egg count:',
                  averageCount.toStringAsFixed(1),
                ),
                _buildDataRow('Highest egg count:', highestCount.toString()),
                _buildDataRow('Lowest egg count:', lowestCount.toString()),
                _buildDataRow('Latest count change:', latestChange),
              ],
            ),
          ),
        ],
      ),
    );
  }

  double _eggCounterGraphMaxY(
    List<String> last7Days,
    Map<String, int> latestCountByDay,
  ) {
    var maxCount = 0;
    for (final day in last7Days) {
      final count = latestCountByDay[day] ?? 0;
      if (count > maxCount) maxCount = count;
    }
    return (maxCount <= 0 ? 10 : maxCount + 5).toDouble();
  }

  String _formatEggCountDelta(int delta) {
    if (delta == 0) return 'No change';
    final prefix = delta > 0 ? '+' : '';
    final suffix = delta.abs() == 1 ? 'egg' : 'eggs';
    return '$prefix$delta $suffix';
  }

  Widget _buildEggCounterRecordCard(EggCounterRecord record) {
    final slotNumbers = record.occupiedSlotNumbers;
    final slotText = slotNumbers.isEmpty ? 'None' : slotNumbers.join(', ');
    final dayText = record.eggDay == null ? 'Day --' : 'Day ${record.eggDay}';
    final isSelected = _selectedCounterRecords.contains(record.id);

    return GestureDetector(
      onTap: () {
        if (_isCounterSelectionMode) {
          setState(() {
            if (isSelected) {
              _selectedCounterRecords.remove(record.id);
            } else {
              _selectedCounterRecords.add(record.id);
            }
          });
        } else {
          _showEggCounterRecordDetail(record);
        }
      },
      onLongPress: () {
        if (!_isCounterSelectionMode) {
          setState(() {
            _isCounterSelectionMode = true;
            _selectedCounterRecords.add(record.id);
          });
        }
      },
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 5),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: _appCardColor(context),
          borderRadius: BorderRadius.circular(8),
          border: isSelected
              ? Border.all(color: const Color(0xFF2979FF), width: 2)
              : null,
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (_isCounterSelectionMode)
              Checkbox(
                value: isSelected,
                onChanged: (value) {
                  setState(() {
                    if (value == true) {
                      _selectedCounterRecords.add(record.id);
                    } else {
                      _selectedCounterRecords.remove(record.id);
                    }
                  });
                },
                activeColor: const Color(0xFF2979FF),
              ),
            Container(
              width: 46,
              height: 46,
              decoration: BoxDecoration(
                color: const Color(0xFF2979FF).withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(14),
              ),
              child: const Icon(
                Icons.egg_alt_rounded,
                color: Color(0xFF2979FF),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          '${record.count} eggs',
                          style: TextStyle(
                            color: _appTextColor(context),
                            fontSize: 16,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                      ),
                      Text(
                        dayText,
                        style: TextStyle(
                          color: _appMutedTextColor(context),
                          fontSize: 12,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'App sync: ${_formatSlotDateTime(record.timestamp)}',
                    style: TextStyle(
                      color: _appSubtleTextColor(context),
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  if (record.p4ScanTime != null)
                    Text(
                      'P4 scan: ${_formatSlotDateTime(record.p4ScanTime)}',
                      style: TextStyle(
                        color: _appFaintTextColor(context),
                        fontSize: 11,
                      ),
                    ),
                  const SizedBox(height: 8),
                  Text(
                    'Slots: $slotText',
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: _appTextColor(context),
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
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

  Widget _counterDetailRow(String label, String value, {Color? valueColor}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 120,
            child: Text(
              label,
              style: TextStyle(
                color: _appMutedTextColor(context),
                fontSize: 13,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: TextStyle(
                color: valueColor ?? _appTextColor(context),
                fontSize: 13,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _showEggCounterRecordDetail(EggCounterRecord record) {
    final slotNumbers = record.occupiedSlotNumbers;
    showModalBottomSheet(
      context: context,
      backgroundColor: _appCardColor(context),
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetContext) {
        return DraggableScrollableSheet(
          initialChildSize: 0.72,
          minChildSize: 0.4,
          maxChildSize: 0.95,
          expand: false,
          builder: (context, scrollController) {
            return Column(
              children: [
                const SizedBox(height: 10),
                Container(
                  width: 44,
                  height: 5,
                  decoration: BoxDecoration(
                    color: _appDividerColor(context),
                    borderRadius: BorderRadius.circular(3),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 14, 20, 6),
                  child: Row(
                    children: [
                      Container(
                        width: 46,
                        height: 46,
                        decoration: BoxDecoration(
                          color: const Color(
                            0xFF2979FF,
                          ).withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: const Icon(
                          Icons.egg_alt_rounded,
                          color: Color(0xFF2979FF),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '${record.count} eggs',
                              style: TextStyle(
                                color: _appTextColor(context),
                                fontSize: 20,
                                fontWeight: FontWeight.w900,
                              ),
                            ),
                            Text(
                              record.eggDay == null
                                  ? 'Day --'
                                  : 'Day ${record.eggDay}',
                              style: TextStyle(
                                color: _appMutedTextColor(context),
                                fontSize: 13,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: ListView(
                    controller: scrollController,
                    padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
                    children: [
                      _counterDetailRow('Total eggs', '${record.count}'),
                      _counterDetailRow(
                        'Incubation day',
                        record.eggDay == null ? '--' : 'Day ${record.eggDay}',
                      ),
                      _counterDetailRow(
                        'App sync',
                        _formatSlotDateTime(record.timestamp),
                      ),
                      _counterDetailRow(
                        'P4 scan',
                        record.p4ScanTime == null
                            ? '--'
                            : _formatSlotDateTime(record.p4ScanTime),
                      ),
                      _counterDetailRow(
                        'Occupied slots',
                        slotNumbers.isEmpty ? 'None' : slotNumbers.join(', '),
                      ),
                      const SizedBox(height: 14),
                      Text(
                        'PER-SLOT DETAIL',
                        style: TextStyle(
                          color: _appMutedTextColor(context),
                          fontSize: 12,
                          fontWeight: FontWeight.w900,
                          letterSpacing: 0.5,
                        ),
                      ),
                      const SizedBox(height: 8),
                      if (slotNumbers.isEmpty)
                        Text(
                          'No eggs were detected in this scan.',
                          style: TextStyle(
                            color: _appSubtleTextColor(context),
                            fontSize: 13,
                          ),
                        )
                      else
                        ...List.generate(record.occupiedSlots.length, (i) {
                          if (!record.occupiedSlots[i]) {
                            return const SizedBox.shrink();
                          }
                          final placed = i < record.placedAt.length
                              ? record.placedAt[i]
                              : null;
                          final day = i < record.slotDays.length
                              ? record.slotDays[i]
                              : null;
                          return Container(
                            margin: const EdgeInsets.only(bottom: 8),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 14,
                              vertical: 10,
                            ),
                            decoration: BoxDecoration(
                              color: _appPanelColor(context),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Row(
                              children: [
                                Container(
                                  width: 34,
                                  height: 34,
                                  alignment: Alignment.center,
                                  decoration: BoxDecoration(
                                    color: const Color(
                                      0xFF2979FF,
                                    ).withValues(alpha: 0.14),
                                    borderRadius: BorderRadius.circular(10),
                                  ),
                                  child: Text(
                                    '${i + 1}',
                                    style: const TextStyle(
                                      color: Color(0xFF2979FF),
                                      fontWeight: FontWeight.w900,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        'Slot ${i + 1}  ·  ${day == null ? 'Day --' : 'Day $day'}',
                                        style: TextStyle(
                                          color: _appTextColor(context),
                                          fontSize: 13,
                                          fontWeight: FontWeight.w800,
                                        ),
                                      ),
                                      const SizedBox(height: 2),
                                      Text(
                                        'Placed: ${_formatSlotDateTime(placed)}',
                                        style: TextStyle(
                                          color: _appSubtleTextColor(context),
                                          fontSize: 11,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          );
                        }),
                    ],
                  ),
                ),
                SafeArea(
                  top: false,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(20, 0, 20, 14),
                    child: SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        icon: const Icon(Icons.delete_outline, size: 18),
                        label: const Text('Delete this record'),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.red,
                          side: const BorderSide(color: Colors.red),
                          padding: const EdgeInsets.symmetric(vertical: 14),
                        ),
                        onPressed: () {
                          Navigator.pop(sheetContext);
                          _deleteSingleCounterRecord(record);
                        },
                      ),
                    ),
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }

  void _deleteSingleCounterRecord(EggCounterRecord record) {
    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: _appCardColor(context),
        title: const Text('Delete Record?'),
        content: Text(
          'Delete this egg counter record (${record.count} eggs, '
          '${_formatSlotDateTime(record.timestamp)})?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              setState(() {
                _eggCounterHistory.removeWhere((r) => r.id == record.id);
                _selectedCounterRecords.remove(record.id);
              });
              _saveEggCounterHistory();
              Navigator.pop(dialogContext);
            },
            child: const Text('Delete', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
  }

  void _deleteSelectedCounterRecords() {
    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: _appCardColor(context),
        title: const Text('Delete Selected?'),
        content: Text('Delete ${_selectedCounterRecords.length} record(s)?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              setState(() {
                _eggCounterHistory.removeWhere(
                  (r) => _selectedCounterRecords.contains(r.id),
                );
                _isCounterSelectionMode = false;
                _selectedCounterRecords.clear();
              });
              _saveEggCounterHistory();
              Navigator.pop(dialogContext);
            },
            child: const Text('Delete', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
  }

  Widget _buildHistoryOverview() {
    final latest = _sessions.isNotEmpty ? _sessions.first : null;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 18, 16, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            latest == null
                ? 'No candling history yet'
                : 'Latest scan  ${DateFormat('MMM d, h:mm a').format(latest.timestamp)}',
            style: TextStyle(
              color: _appMutedTextColor(context),
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              _buildStatItem(
                'Fertile',
                '${latest?.fertileCount ?? 0}',
                const Color(0xFF00A86B),
              ),
              _buildStatItem(
                'Infertile',
                '${latest?.infertileCount ?? 0}',
                const Color(0xFFFF5252),
              ),
              _buildStatItem(
                'In review',
                '${latest?.inReviewCount ?? 0}',
                const Color(0xFFFF9800),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildStatsHeader() {
    final lastScan = _sessions.isNotEmpty ? _sessions.first : null;
    final now = DateTime.now();
    final todayStart = DateTime(now.year, now.month, now.day);
    final todaySessions = _sessions
        .where((s) => s.timestamp.isAfter(todayStart))
        .toList();

    final Map<String, List<EggSession>> sessionsByDay = {};
    for (var s in _sessions) {
      final dayKey = DateFormat('yyyy-MM-dd').format(s.timestamp);
      (sessionsByDay[dayKey] ??= []).add(s);
    }

    final last7Days = List.generate(7, (i) {
      final d = now.subtract(Duration(days: 6 - i));
      return DateFormat('yyyy-MM-dd').format(d);
    });

    return Container(
      margin: const EdgeInsets.all(16),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: _appCardColor(context),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        children: [
          Text(
            'STATISTICS - LAST SCAN',
            style: TextStyle(
              color: _appMutedTextColor(context),
              fontSize: 14,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 10),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              _buildStatItem(
                'Fertile',
                lastScan?.fertileCount.toString() ?? '0',
                const Color(0xFF00E676),
              ),
              _buildStatItem(
                'Infertile',
                lastScan?.infertileCount.toString() ?? '0',
                const Color(0xFFFF5252),
              ),
              _buildStatItem(
                'In review',
                lastScan?.inReviewCount.toString() ?? '0',
                const Color(0xFFFF9800),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            lastScan == null
                ? 'No candling capture recorded yet'
                : 'Occupied ${lastScan.occupiedCount ?? '--'} | Ready ${lastScan.readyEggCount} | Analyzed ${lastScan.analyzedSlotCount} | ${lastScan.usedAi ? 'AI classification complete' : 'Classification not run'}',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: _appSubtleTextColor(context),
              fontSize: 10,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 24),

          Text(
            'LAST 7 DAYS — EGG COUNT',
            style: TextStyle(
              color: _appMutedTextColor(context),
              fontSize: 12,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 12),
          SizedBox(
            height: 150,
            child: BarChart(
              BarChartData(
                alignment: BarChartAlignment.spaceAround,
                maxY: _getMaxBarValue(last7Days, sessionsByDay).toDouble() + 5,
                minY: 0,
                barTouchData: BarTouchData(enabled: false),
                titlesData: FlTitlesData(
                  show: true,
                  bottomTitles: AxisTitles(
                    sideTitles: SideTitles(
                      showTitles: true,
                      getTitlesWidget: (value, meta) {
                        final idx = value.toInt();
                        if (idx >= 0 && idx < last7Days.length) {
                          final date = DateTime.parse(last7Days[idx]);
                          return Text(
                            '${date.day}',
                            style: TextStyle(
                              color: _appSubtleTextColor(context),
                              fontSize: 10,
                            ),
                          );
                        }
                        return const Text('');
                      },
                      reservedSize: 20,
                    ),
                  ),
                  leftTitles: AxisTitles(
                    sideTitles: SideTitles(showTitles: false),
                  ),
                  rightTitles: AxisTitles(
                    sideTitles: SideTitles(showTitles: false),
                  ),
                  topTitles: AxisTitles(
                    sideTitles: SideTitles(showTitles: false),
                  ),
                ),
                borderData: FlBorderData(show: false),
                gridData: const FlGridData(show: false),
                barGroups: last7Days.asMap().entries.map((e) {
                  final day = e.value;
                  final sessions = sessionsByDay[day] ?? [];
                  int fertile = 0, infertile = 0;
                  for (var s in sessions) {
                    fertile += s.fertileCount;
                    infertile += s.infertileCount;
                  }
                  return BarChartGroupData(
                    x: e.key,
                    barRods: [
                      BarChartRodData(
                        toY: fertile.toDouble(),
                        color: const Color(0xFF00E676),
                        width: 12,
                        borderRadius: const BorderRadius.vertical(
                          top: Radius.circular(4),
                        ),
                      ),
                      BarChartRodData(
                        toY: infertile.toDouble(),
                        color: const Color(0xFFFF5252),
                        width: 12,
                        borderRadius: const BorderRadius.vertical(
                          top: Radius.circular(4),
                        ),
                      ),
                    ],
                  );
                }).toList(),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(width: 10, height: 10, color: const Color(0xFF00E676)),
              const SizedBox(width: 4),
              Text(
                'Fertile',
                style: TextStyle(
                  color: _appSubtleTextColor(context),
                  fontSize: 10,
                ),
              ),
              const SizedBox(width: 16),
              Container(width: 10, height: 10, color: const Color(0xFFFF5252)),
              const SizedBox(width: 4),
              Text(
                'Infertile',
                style: TextStyle(
                  color: _appSubtleTextColor(context),
                  fontSize: 10,
                ),
              ),
            ],
          ),

          const SizedBox(height: 24),
          Text(
            '7-DAY FERTILITY RATE TREND',
            style: TextStyle(
              color: _appMutedTextColor(context),
              fontSize: 12,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 12),
          SizedBox(
            height: 120,
            child: LineChart(
              LineChartData(
                minY: 0,
                maxY: 100,
                lineTouchData: const LineTouchData(enabled: false),
                gridData: FlGridData(
                  show: true,
                  drawVerticalLine: false,
                  getDrawingHorizontalLine: (_) =>
                      FlLine(color: _appPanelColor(context), strokeWidth: 1),
                ),
                borderData: FlBorderData(show: false),
                titlesData: FlTitlesData(
                  leftTitles: AxisTitles(
                    sideTitles: SideTitles(
                      showTitles: true,
                      reservedSize: 30,
                      getTitlesWidget: (v, _) => Text(
                        '${v.toInt()}%',
                        style: TextStyle(
                          color: _appFaintTextColor(context),
                          fontSize: 9,
                        ),
                      ),
                      interval: 50,
                    ),
                  ),
                  bottomTitles: AxisTitles(
                    sideTitles: SideTitles(
                      showTitles: true,
                      reservedSize: 20,
                      getTitlesWidget: (value, _) {
                        final idx = value.toInt();
                        if (idx >= 0 && idx < last7Days.length) {
                          final date = DateTime.parse(last7Days[idx]);
                          return Text(
                            '${date.day}',
                            style: TextStyle(
                              color: _appSubtleTextColor(context),
                              fontSize: 10,
                            ),
                          );
                        }
                        return const Text('');
                      },
                    ),
                  ),
                  rightTitles: AxisTitles(
                    sideTitles: SideTitles(showTitles: false),
                  ),
                  topTitles: AxisTitles(
                    sideTitles: SideTitles(showTitles: false),
                  ),
                ),
                lineBarsData: [
                  LineChartBarData(
                    spots: last7Days.asMap().entries.map((e) {
                      final sessions = sessionsByDay[e.value] ?? [];
                      int f = 0, inf = 0;
                      for (var s in sessions) {
                        f += s.fertileCount;
                        inf += s.infertileCount;
                      }
                      final total = f + inf;
                      final rate = total > 0 ? f / total * 100.0 : 0.0;
                      return FlSpot(e.key.toDouble(), rate);
                    }).toList(),
                    isCurved: true,
                    color: const Color(0xFF2979FF),
                    barWidth: 2,
                    dotData: FlDotData(
                      show: true,
                      getDotPainter: (spot, _, _, _) => FlDotCirclePainter(
                        radius: 3,
                        color: const Color(0xFF2979FF),
                        strokeWidth: 0,
                      ),
                    ),
                    belowBarData: BarAreaData(
                      show: true,
                      color: const Color(0xFF2979FF).withAlpha(30),
                    ),
                  ),
                ],
              ),
            ),
          ),

          const SizedBox(height: 24),
          Text(
            'THESIS DATA LOG',
            style: TextStyle(
              color: _appMutedTextColor(context),
              fontSize: 12,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: _appPanelColor(context),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Column(
              children: [
                _buildDataRow('Total Scans Done:', _sessions.length.toString()),
                _buildDataRow(
                  'Analyzed Slot Observations:',
                  _sessions
                      .fold(0, (sum, s) => sum + s.analyzedSlotCount)
                      .toString(),
                ),
                _buildDataRow(
                  'Classified Observations:',
                  _sessions
                      .fold(
                        0,
                        (sum, s) => sum + s.fertileCount + s.infertileCount,
                      )
                      .toString(),
                ),
                _buildDataRow(
                  'In-Review Observations:',
                  _sessions
                      .fold(0, (sum, s) => sum + s.inReviewCount)
                      .toString(),
                ),
                _buildDataRow(
                  'Total Fertile Eggs:',
                  _sessions
                      .fold(0, (sum, s) => sum + s.fertileCount)
                      .toString(),
                ),
                _buildDataRow(
                  'Total Infertile Eggs:',
                  _sessions
                      .fold(0, (sum, s) => sum + s.infertileCount)
                      .toString(),
                ),
                _buildDataRow(
                  'Overall Fertility Rate:',
                  _getOverallFertilityRate(),
                ),
                _buildDataRow(
                  'Scans This Week:',
                  _getThisWeekCount().toString(),
                ),
                _buildDataRow('Scans Today:', todaySessions.length.toString()),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDataRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: TextStyle(color: _appSubtleTextColor(context), fontSize: 11),
          ),
          Text(
            value,
            style: TextStyle(
              color: _appTextColor(context),
              fontSize: 11,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStatItem(String label, String value, Color color) {
    return Column(
      children: [
        Text(
          label,
          style: TextStyle(fontSize: 10, color: _appSubtleTextColor(context)),
        ),
        const SizedBox(height: 4),
        Text(
          value,
          style: TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.bold,
            color: color,
          ),
        ),
      ],
    );
  }

  Widget _buildSessionCard(EggSession session, int index) {
    final isSelected = _selectedSessions.contains(session.id);
    return GestureDetector(
      onTap: () {
        if (_isSelectionMode) {
          setState(() {
            if (isSelected) {
              _selectedSessions.remove(session.id);
            } else {
              _selectedSessions.add(session.id);
            }
          });
        } else {
          _viewSession(session);
        }
      },
      onLongPress: () {
        if (!_isSelectionMode) {
          setState(() {
            _isSelectionMode = true;
            _selectedSessions.add(session.id);
          });
        }
      },
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: _appCardColor(context),
          borderRadius: BorderRadius.circular(16),
          border: isSelected
              ? Border.all(color: const Color(0xFF2979FF), width: 2)
              : null,
        ),
        child: Row(
          children: [
            if (_isSelectionMode)
              Checkbox(
                value: isSelected,
                onChanged: (value) {
                  setState(() {
                    if (value == true) {
                      _selectedSessions.add(session.id);
                    } else {
                      _selectedSessions.remove(session.id);
                    }
                  });
                },
                activeColor: const Color(0xFF2979FF),
              ),
            Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                color: _appPanelColor(context),
                borderRadius: BorderRadius.circular(8),
              ),
              child: session.imageBytes != null
                  ? Image.memory(session.imageBytes!, fit: BoxFit.contain)
                  : Icon(Icons.image, color: _appDividerColor(context)),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    DateFormat(
                      'MMM dd, yyyy - h:mm a',
                    ).format(session.timestamp),
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 4),
                  Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    children: [
                      _buildMiniStat(
                        const Color(0xFF00E676),
                        'F ${session.fertileCount}',
                      ),
                      _buildMiniStat(
                        const Color(0xFFFF5252),
                        'I ${session.infertileCount}',
                      ),
                      if (session.inReviewCount > 0)
                        _buildMiniStat(
                          const Color(0xFFFF9800),
                          'Review ${session.inReviewCount}',
                        ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '${session.occupiedCount ?? '--'} eggs | ${session.analyzedSlotCount} analyzed',
                    style: TextStyle(
                      fontSize: 10,
                      color: _appMutedTextColor(context),
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
            Icon(Icons.chevron_right, color: _appFaintTextColor(context)),
          ],
        ),
      ),
    );
  }

  Widget _buildMiniStat(Color color, String text) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withAlpha(51),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 10,
          color: color,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }

  Widget _buildDatasetCapturingTab() {
    final modeLocked =
        _isDatasetCapturing ||
        _isDatasetAutoCapturing ||
        _isIntakeDatasetCapturing ||
        _isIntakeDatasetAutoCapturing ||
        _isFertilityDatasetCapturing;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
          child: SizedBox(
            width: double.infinity,
            child: SegmentedButton<String>(
              segments: const [
                ButtonSegment<String>(
                  value: 'egg_counter',
                  icon: Icon(Icons.grid_view_rounded, size: 18),
                  label: Text('Egg Counter'),
                ),
                ButtonSegment<String>(
                  value: 'p4_intake',
                  icon: Icon(Icons.flare_rounded, size: 18),
                  label: Text('P4 Intake'),
                ),
              ],
              selected: <String>{_datasetCaptureTool},
              onSelectionChanged: modeLocked
                  ? null
                  : (selection) {
                      setState(() => _datasetCaptureTool = selection.first);
                    },
              showSelectedIcon: false,
              style: ButtonStyle(
                visualDensity: VisualDensity.compact,
                textStyle: WidgetStateProperty.all(
                  const TextStyle(fontSize: 12, fontWeight: FontWeight.w900),
                ),
              ),
            ),
          ),
        ),
        Expanded(
          child: _datasetCaptureTool == 'p4_intake'
              ? _buildIntakeDatasetCapturingTab()
              : _buildEggCounterDatasetCapturingTab(),
        ),
      ],
    );
  }

  Widget _buildEggCounterDatasetCapturingTab() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _premiumEntry(
            0,
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: _appCardColor(context),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: _appOutlineColor(context)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        width: 44,
                        height: 44,
                        decoration: BoxDecoration(
                          color: const Color(
                            0xFF2979FF,
                          ).withValues(alpha: 0.14),
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: const Icon(
                          Icons.dataset_rounded,
                          color: Color(0xFF2979FF),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Dataset Capturing',
                              style: TextStyle(
                                color: _appTextColor(context),
                                fontSize: 18,
                                fontWeight: FontWeight.w900,
                              ),
                            ),
                            const SizedBox(height: 3),
                            Text(
                              'Auto-crops 56 egg-counter cells',
                              style: TextStyle(
                                color: _appSubtleTextColor(context),
                                fontSize: 12,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  Text(
                    'The ESP32-S3 camera capture is sliced into 8 x 7 cell images for egg/no-slot identification. Fertile and infertile labels stay out of this dataset.',
                    style: TextStyle(
                      color: _appMutedTextColor(context),
                      fontSize: 12,
                      height: 1.35,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          _premiumEntry(
            1,
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: _appCardColor(context),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: _appOutlineColor(context)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'LABEL',
                    style: TextStyle(
                      color: _appMutedTextColor(context),
                      fontSize: 11,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  const SizedBox(height: 10),
                  LayoutBuilder(
                    builder: (context, constraints) {
                      final halfWidth = (constraints.maxWidth - 8) / 2;
                      return Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          SizedBox(
                            width: halfWidth,
                            child: _buildDatasetLabelButton(
                              id: 'egg_present',
                              label: 'Egg',
                              icon: Icons.radio_button_checked_rounded,
                            ),
                          ),
                          SizedBox(
                            width: halfWidth,
                            child: _buildDatasetLabelButton(
                              id: 'empty_slot',
                              label: 'Empty',
                              icon: Icons.crop_square_rounded,
                            ),
                          ),
                          SizedBox(
                            width: halfWidth,
                            child: _buildDatasetLabelButton(
                              id: 'slot_reference',
                              label: 'Slot',
                              icon: Icons.grid_on_rounded,
                            ),
                          ),
                          SizedBox(
                            width: halfWidth,
                            child: _buildDatasetLabelButton(
                              id: 'custom_slots',
                              label: 'Custom',
                              icon: Icons.touch_app_rounded,
                            ),
                          ),
                          SizedBox(
                            width: halfWidth,
                            child: _buildDatasetLabelButton(
                              id: 'custom_empty_slots',
                              label: 'Hard Empty',
                              icon: Icons.report_problem_rounded,
                            ),
                          ),
                        ],
                      );
                    },
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          if (_datasetUsesSelectedSlotMode) ...[
            _premiumEntry(2, _buildDatasetCustomSlotSelector()),
            const SizedBox(height: 16),
          ],
          _premiumEntry(
            _datasetUsesSelectedSlotMode ? 3 : 2,
            Container(
              decoration: BoxDecoration(
                color: _appDeepPanelColor(context),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: _appOutlineColor(context)),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: AspectRatio(
                  aspectRatio: 4 / 3,
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 260),
                    transitionBuilder: _premiumSwitchTransition,
                    child: _datasetLastImage == null
                        ? Center(
                            key: const ValueKey('dataset-empty-preview'),
                            child: Text(
                              'No dataset image yet',
                              style: TextStyle(
                                color: _appFaintTextColor(context),
                                fontSize: 12,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          )
                        : Image.memory(
                            _datasetLastImage!,
                            key: ValueKey<int>(_datasetCaptureCount),
                            fit: BoxFit.contain,
                          ),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 16),
          _premiumEntry(
            _datasetUsesSelectedSlotMode ? 4 : 3,
            _buildDatasetCropPreviewGrid(),
          ),
          const SizedBox(height: 16),
          _premiumEntry(
            _datasetUsesSelectedSlotMode ? 5 : 4,
            Row(
              children: [
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: _canStartDatasetCapture
                        ? _startDatasetAutoCapture
                        : null,
                    icon: _isDatasetCapturing
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              valueColor: AlwaysStoppedAnimation<Color>(
                                Colors.white,
                              ),
                            ),
                          )
                        : const Icon(Icons.play_arrow_rounded),
                    label: Text(
                      _isDatasetCapturing
                          ? 'CAPTURING...'
                          : _isDatasetAutoCapturing
                          ? 'AUTO ON'
                          : 'START 2-MIN CAPTURE',
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF2979FF),
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 15),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                SizedBox(
                  width: 98,
                  child: OutlinedButton.icon(
                    onPressed: _isDatasetAutoCapturing
                        ? _stopDatasetAutoCapture
                        : null,
                    icon: const Icon(Icons.stop_rounded, size: 18),
                    label: const Text('STOP'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: const Color(0xFFFF5252),
                      side: BorderSide(
                        color: _isDatasetAutoCapturing
                            ? const Color(0xFFFF5252)
                            : _appOutlineColor(context),
                      ),
                      padding: const EdgeInsets.symmetric(vertical: 15),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          _premiumEntry(
            _datasetUsesSelectedSlotMode ? 6 : 5,
            OutlinedButton.icon(
              onPressed: _datasetLastBatchFiles.isEmpty
                  ? null
                  : _shareDatasetLastBatch,
              icon: const Icon(Icons.ios_share_rounded, size: 18),
              label: const Text('SHARE LAST BATCH'),
              style: OutlinedButton.styleFrom(
                foregroundColor: const Color(0xFF2979FF),
                side: BorderSide(
                  color: _datasetLastBatchFiles.isEmpty
                      ? _appOutlineColor(context)
                      : const Color(0xFF2979FF),
                ),
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
            ),
          ),
          const SizedBox(height: 16),
          _premiumEntry(
            _datasetUsesSelectedSlotMode ? 7 : 6,
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: _appCardColor(context),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: _appOutlineColor(context)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildDatasetInfoRow(
                    'Saved',
                    '$_datasetCaptureCount crop${_datasetCaptureCount == 1 ? '' : 's'}',
                  ),
                  const SizedBox(height: 8),
                  _buildDatasetInfoRow('Auto', _datasetAutoStatusText),
                  const SizedBox(height: 8),
                  _buildDatasetInfoRow(
                    'Camera',
                    'ESP32-S3 $_datasetCaptureEndpoint',
                  ),
                  const SizedBox(height: 8),
                  _buildDatasetInfoRow(
                    'Last batch',
                    _datasetLastBatchCount == 0
                        ? '--'
                        : '$_datasetLastBatchCount cell crops',
                  ),
                  const SizedBox(height: 8),
                  _buildDatasetInfoRow(
                    'Quality',
                    _datasetLastBatchCount == 0
                        ? '--'
                        : _datasetLastQualityWarningCount == 0
                        ? 'All clear'
                        : '$_datasetLastQualityWarningCount flagged',
                  ),
                  const SizedBox(height: 8),
                  _buildDatasetInfoRow('Class', _datasetCaptureLabelName),
                  const SizedBox(height: 8),
                  _buildDatasetInfoRow('Labeling', _datasetLabelScopeText),
                  const SizedBox(height: 8),
                  _buildDatasetInfoRow('Grid', _datasetGridScopeText),
                  if (_datasetRootPath != null) ...[
                    const SizedBox(height: 8),
                    _buildDatasetInfoRow('Folder', _datasetRootPath!),
                  ],
                  if (_datasetLastCsvPath != null) ...[
                    const SizedBox(height: 8),
                    _buildDatasetInfoRow('CSV', _datasetLastCsvPath!),
                  ],
                  if (_datasetLastManifestPath != null) ...[
                    const SizedBox(height: 8),
                    _buildDatasetInfoRow('Manifest', _datasetLastManifestPath!),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildIntakeDatasetCapturingTab() {
    final labels = _intakeDatasetLockedLabels ?? _intakeDatasetLabels;
    final occupiedCount = _p4SlotHasEgg.where((occupied) => occupied).length;
    final normalCount = labels.values
        .where((label) => label == 'normal')
        .length;
    final abnormalCount = labels.values
        .where((label) => label == 'abnormal')
        .length;
    final missingCount = labels.keys
        .where(
          (index) =>
              index < 0 ||
              index >= _p4SlotHasEgg.length ||
              !_p4SlotHasEgg[index],
        )
        .length;
    final skippedCount = math.max(
      0,
      occupiedCount - labels.length + missingCount,
    );
    final labelsLocked =
        _isIntakeDatasetCapturing || _isIntakeDatasetAutoCapturing;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: _appCardColor(context),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: _appOutlineColor(context)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.flare_rounded, color: Color(0xFFFF9100)),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'P4 Intake Dataset',
                        style: TextStyle(
                          color: _appTextColor(context),
                          fontSize: 17,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                    ),
                    IconButton(
                      onPressed: labelsLocked
                          ? null
                          : _refreshIntakeDatasetOccupancy,
                      tooltip: 'Refresh P4 occupancy',
                      icon: const Icon(Icons.refresh_rounded),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 7,
                  runSpacing: 7,
                  children: [
                    _buildIntakeDatasetCountBadge(
                      'OCC',
                      occupiedCount,
                      const Color(0xFF2979FF),
                    ),
                    _buildIntakeDatasetCountBadge(
                      'NORMAL',
                      normalCount,
                      const Color(0xFF00A86B),
                    ),
                    _buildIntakeDatasetCountBadge(
                      'ABNORMAL',
                      abnormalCount,
                      const Color(0xFFFF5252),
                    ),
                    _buildIntakeDatasetCountBadge(
                      'SKIP',
                      skippedCount,
                      _appSubtleTextColor(context),
                    ),
                  ],
                ),
                if (missingCount > 0) ...[
                  const SizedBox(height: 10),
                  Text(
                    '$missingCount labeled slot${missingCount == 1 ? '' : 's'} no longer occupied',
                    style: const TextStyle(
                      color: Color(0xFFFF5252),
                      fontSize: 11,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: _appCardColor(context),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: _appOutlineColor(context)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'OCCUPIED SLOT LABELS',
                  style: TextStyle(
                    color: _appMutedTextColor(context),
                    fontSize: 11,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: labelsLocked || occupiedCount == 0
                            ? null
                            : _setAllOccupiedIntakeSlotsNormal,
                        icon: const Icon(Icons.done_all_rounded, size: 17),
                        label: const Text('ALL NORMAL'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: labelsLocked || labels.isEmpty
                            ? null
                            : _clearIntakeDatasetLabels,
                        icon: const Icon(Icons.clear_all_rounded, size: 17),
                        label: const Text('CLEAR'),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                _buildIntakeDatasetSlotGrid(labels, labelsLocked: labelsLocked),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Container(
            decoration: BoxDecoration(
              color: _appDeepPanelColor(context),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: _appOutlineColor(context)),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: AspectRatio(
                aspectRatio: 4 / 3,
                child: _intakeDatasetLastImage == null
                    ? Center(
                        child: Text(
                          'No P4 intake image yet',
                          style: TextStyle(
                            color: _appFaintTextColor(context),
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      )
                    : Image.memory(
                        _intakeDatasetLastImage!,
                        fit: BoxFit.contain,
                        gaplessPlayback: true,
                      ),
              ),
            ),
          ),
          const SizedBox(height: 12),
          _buildIntakeDatasetCropPreviewGrid(),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: _canStartIntakeDatasetCapture
                      ? () => unawaited(
                          _captureIntakeDatasetImage(captureTrigger: 'manual'),
                        )
                      : null,
                  icon: _isIntakeDatasetCapturing
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : const Icon(Icons.camera_alt_rounded),
                  label: Text(
                    _isIntakeDatasetCapturing ? 'CAPTURING...' : 'CAPTURE NOW',
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFFFF9100),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: _canStartIntakeDatasetCapture
                      ? _startIntakeDatasetAutoCapture
                      : null,
                  icon: const Icon(Icons.schedule_rounded),
                  label: Text(
                    _isIntakeDatasetAutoCapturing ? 'AUTO ON' : 'START 2-MIN',
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF2979FF),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              IconButton.outlined(
                onPressed: _isIntakeDatasetAutoCapturing
                    ? _stopIntakeDatasetAutoCapture
                    : null,
                tooltip: 'Stop automatic capture',
                color: const Color(0xFFFF5252),
                icon: const Icon(Icons.stop_rounded),
              ),
            ],
          ),
          const SizedBox(height: 10),
          OutlinedButton.icon(
            onPressed: _intakeDatasetLastBatchFiles.isEmpty
                ? null
                : _shareIntakeDatasetLastBatch,
            icon: const Icon(Icons.ios_share_rounded, size: 18),
            label: const Text('SHARE LAST BATCH'),
          ),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: _appCardColor(context),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: _appOutlineColor(context)),
            ),
            child: Column(
              children: [
                _buildDatasetInfoRow(
                  'Saved',
                  '$_intakeDatasetCaptureCount crop${_intakeDatasetCaptureCount == 1 ? '' : 's'}',
                ),
                const SizedBox(height: 8),
                _buildDatasetInfoRow('Auto', _intakeDatasetAutoStatusText),
                const SizedBox(height: 8),
                _buildDatasetInfoRow(
                  'Run',
                  _intakeDatasetCollectionRunId ?? '--',
                ),
                const SizedBox(height: 8),
                _buildDatasetInfoRow(
                  'Last batch',
                  _intakeDatasetLastBatchCount == 0
                      ? '--'
                      : '$_intakeDatasetLastBatchCount raw crops',
                ),
                const SizedBox(height: 8),
                _buildDatasetInfoRow(
                  'Quality',
                  _intakeDatasetLastBatchCount == 0
                      ? '--'
                      : _intakeDatasetLastQualityWarningCount == 0
                      ? 'All clear'
                      : '$_intakeDatasetLastQualityWarningCount diagnostic flags',
                ),
                if (_intakeDatasetRootPath != null) ...[
                  const SizedBox(height: 8),
                  _buildDatasetInfoRow('Folder', _intakeDatasetRootPath!),
                ],
                if (_intakeDatasetLastCsvPath != null) ...[
                  const SizedBox(height: 8),
                  _buildDatasetInfoRow('CSV', _intakeDatasetLastCsvPath!),
                ],
                if (_intakeDatasetLastManifestPath != null) ...[
                  const SizedBox(height: 8),
                  _buildDatasetInfoRow(
                    'Manifest',
                    _intakeDatasetLastManifestPath!,
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildIntakeDatasetCountBadge(String label, int count, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Text(
        '$label $count',
        style: TextStyle(
          color: color,
          fontSize: 10,
          fontWeight: FontWeight.w900,
        ),
      ),
    );
  }

  Widget _buildIntakeDatasetSlotGrid(
    Map<int, String> labels, {
    required bool labelsLocked,
  }) {
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: _activeGridCellCount,
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: gridCols,
        crossAxisSpacing: 4,
        mainAxisSpacing: 4,
        childAspectRatio: 0.86,
      ),
      itemBuilder: (context, index) {
        final occupied = index < _p4SlotHasEgg.length && _p4SlotHasEgg[index];
        final label = labels[index];
        final missing = label != null && !occupied;
        final color = missing
            ? const Color(0xFFFF9100)
            : label == 'normal'
            ? const Color(0xFF00A86B)
            : label == 'abnormal'
            ? const Color(0xFFFF5252)
            : occupied
            ? _appPanelColor(context)
            : _appDeepPanelColor(context);
        final foreground = label != null || missing
            ? Colors.white
            : occupied
            ? _appMutedTextColor(context)
            : _appFaintTextColor(context);
        final stateText = missing
            ? 'MISSING'
            : label != null
            ? _intakeDatasetLabelName(label)
            : occupied
            ? 'SKIP'
            : 'EMPTY';
        return Tooltip(
          message: 'Slot ${index + 1}: $stateText',
          child: InkWell(
            borderRadius: BorderRadius.circular(5),
            onTap: labelsLocked || (!occupied && label == null)
                ? null
                : () => _toggleIntakeDatasetLabel(index),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 160),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: color,
                borderRadius: BorderRadius.circular(5),
                border: Border.all(
                  color: label != null || missing
                      ? color
                      : _appOutlineColor(context),
                ),
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    '${index + 1}',
                    style: TextStyle(
                      color: foreground,
                      fontSize: 10,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  const SizedBox(height: 2),
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      stateText,
                      style: TextStyle(
                        color: foreground,
                        fontSize: 7,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildIntakeDatasetCropPreviewGrid() {
    if (_intakeDatasetLastCropPreviews.isEmpty) {
      return Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: _appCardColor(context),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: _appOutlineColor(context)),
        ),
        child: Text(
          'No labeled crop previews yet',
          textAlign: TextAlign.center,
          style: TextStyle(
            color: _appFaintTextColor(context),
            fontSize: 12,
            fontWeight: FontWeight.w700,
          ),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: _appCardColor(context),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: _appOutlineColor(context)),
      ),
      child: GridView.builder(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        itemCount: _intakeDatasetLastCropPreviews.length,
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: gridCols,
          crossAxisSpacing: 4,
          mainAxisSpacing: 4,
          childAspectRatio: 1,
        ),
        itemBuilder: (context, index) {
          final label = index < _intakeDatasetLastCropLabels.length
              ? _intakeDatasetLastCropLabels[index]
              : 'normal';
          final status = index < _intakeDatasetLastCropStatuses.length
              ? _intakeDatasetLastCropStatuses[index]
              : 'ok';
          final slot = index < _intakeDatasetLastCropSlotNumbers.length
              ? _intakeDatasetLastCropSlotNumbers[index]
              : index + 1;
          final labelColor = label == 'abnormal'
              ? const Color(0xFFFF5252)
              : const Color(0xFF00A86B);
          return Tooltip(
            message: 'Slot $slot | ${_intakeDatasetLabelName(label)} | $status',
            child: Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(5),
                border: Border.all(color: labelColor, width: 1.5),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    Image.memory(
                      _intakeDatasetLastCropPreviews[index],
                      fit: BoxFit.cover,
                      gaplessPlayback: true,
                    ),
                    Positioned(
                      top: 2,
                      left: 2,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 4,
                          vertical: 1,
                        ),
                        color: Colors.black.withValues(alpha: 0.65),
                        child: Text(
                          '$slot',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 9,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                      ),
                    ),
                    if (status != 'ok')
                      const Positioned(
                        right: 2,
                        bottom: 2,
                        child: Icon(
                          Icons.warning_amber_rounded,
                          color: Color(0xFFFFD740),
                          size: 13,
                        ),
                      ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildDatasetCropPreviewGrid() {
    if (_datasetLastCropPreviews.isEmpty) {
      return Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: _appCardColor(context),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: _appOutlineColor(context)),
        ),
        child: Text(
          'Cell previews will appear here after the first capture.',
          style: TextStyle(
            color: _appFaintTextColor(context),
            fontSize: 12,
            fontWeight: FontWeight.w700,
          ),
          textAlign: TextAlign.center,
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: _appCardColor(context),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: _appOutlineColor(context)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                'CELL PREVIEW',
                style: TextStyle(
                  color: _appMutedTextColor(context),
                  fontSize: 11,
                  fontWeight: FontWeight.w900,
                ),
              ),
              const Spacer(),
              Text(
                '${_datasetLastCropPreviews.length} crop${_datasetLastCropPreviews.length == 1 ? '' : 's'}',
                style: TextStyle(
                  color: _appFaintTextColor(context),
                  fontSize: 11,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: _datasetLastCropPreviews.length,
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: gridCols,
              crossAxisSpacing: 4,
              mainAxisSpacing: 4,
              childAspectRatio: 1,
            ),
            itemBuilder: (context, index) {
              final status = index < _datasetLastCropStatuses.length
                  ? _datasetLastCropStatuses[index]
                  : 'ok';
              final label = index < _datasetLastCropLabels.length
                  ? _datasetLastCropLabels[index]
                  : _datasetCaptureLabel;
              final slotNumber = index < _datasetLastCropSlotNumbers.length
                  ? _datasetLastCropSlotNumbers[index]
                  : index + 1;
              return Tooltip(
                message:
                    'Slot $slotNumber | ${_datasetLabelName(label)} | $status',
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 220),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(5),
                    border: Border.all(
                      color: _datasetCropPreviewColor(label, status),
                      width: status == 'ok' ? 1.2 : 2,
                    ),
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        Image.memory(
                          _datasetLastCropPreviews[index],
                          fit: BoxFit.cover,
                          gaplessPlayback: true,
                        ),
                        Positioned(
                          top: 2,
                          left: 2,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 4,
                              vertical: 1,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.black.withValues(alpha: 0.62),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(
                              '$slotNumber',
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 9,
                                fontWeight: FontWeight.w900,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _buildDatasetCustomSlotSelector() {
    final selectedCount = _datasetSelectedEggSlots.length;
    final emptyMode = _datasetUsesCustomEmptySlots;
    final accent = emptyMode
        ? const Color(0xFF2979FF)
        : const Color(0xFF00C853);
    final accentText = emptyMode
        ? const Color(0xFF1565C0)
        : const Color(0xFF00A86B);
    final noun = emptyMode ? 'empty' : 'egg';
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: _appCardColor(context),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: _appOutlineColor(context)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                emptyMode ? 'HARD EMPTY SLOTS' : 'CUSTOM EGG SLOTS',
                style: TextStyle(
                  color: _appMutedTextColor(context),
                  fontSize: 11,
                  fontWeight: FontWeight.w900,
                ),
              ),
              const Spacer(),
              AnimatedContainer(
                duration: const Duration(milliseconds: 220),
                padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
                decoration: BoxDecoration(
                  color: accent.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  '$selectedCount $noun${selectedCount == 1 ? '' : 's'}',
                  style: TextStyle(
                    color: accentText,
                    fontSize: 11,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                height: 32,
                child: OutlinedButton(
                  onPressed: _datasetSelectedEggSlots.isEmpty
                      ? null
                      : () => setState(_datasetSelectedEggSlots.clear),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: _appMutedTextColor(context),
                    side: BorderSide(color: _appOutlineColor(context)),
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(9),
                    ),
                  ),
                  child: const Text(
                    'CLEAR',
                    style: TextStyle(fontSize: 10, fontWeight: FontWeight.w900),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            emptyMode
                ? 'Only selected cells are saved as Empty hard negatives. Unselected cells are skipped.'
                : 'Only selected cells are saved as Egg. Unselected cells are skipped.',
            style: TextStyle(
              color: _appFaintTextColor(context),
              fontSize: 11,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 12),
          GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: _activeGridCellCount,
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: gridCols,
              crossAxisSpacing: 5,
              mainAxisSpacing: 5,
              childAspectRatio: 1,
            ),
            itemBuilder: (context, index) {
              final selected = _datasetSelectedEggSlots.contains(index);
              return InkWell(
                borderRadius: BorderRadius.circular(7),
                onTap: () {
                  setState(() {
                    if (selected) {
                      _datasetSelectedEggSlots.remove(index);
                    } else {
                      _datasetSelectedEggSlots.add(index);
                    }
                  });
                },
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 180),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: selected ? accent : _appPanelColor(context),
                    borderRadius: BorderRadius.circular(7),
                    border: Border.all(
                      color: selected ? accent : _appOutlineColor(context),
                    ),
                  ),
                  child: Text(
                    '${index + 1}',
                    style: TextStyle(
                      color: selected
                          ? Colors.white
                          : _appMutedTextColor(context),
                      fontSize: 10,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ),
              );
            },
          ),
        ],
      ),
    );
  }

  Color _datasetCropPreviewColor(String label, String status) {
    if (status != 'ok') return const Color(0xFFFF5252);
    return switch (label) {
      'egg_present' => const Color(0xFF00C853),
      'empty_slot' => const Color(0xFF2979FF),
      'slot_reference' => const Color(0xFF7C4DFF),
      _ => _appOutlineColor(context),
    };
  }

  Widget _buildDatasetLabelButton({
    required String id,
    required String label,
    required IconData icon,
  }) {
    final selected = _datasetCaptureLabel == id;
    return SizedBox(
      height: 42,
      child: FilledButton.icon(
        onPressed: () => setState(() => _datasetCaptureLabel = id),
        icon: Icon(icon, size: 17),
        label: FittedBox(fit: BoxFit.scaleDown, child: Text(label)),
        style: FilledButton.styleFrom(
          backgroundColor: selected
              ? const Color(0xFF2979FF)
              : _appPanelColor(context),
          foregroundColor: selected
              ? Colors.white
              : _appMutedTextColor(context),
          padding: const EdgeInsets.symmetric(horizontal: 9),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(11),
            side: BorderSide(
              color: selected
                  ? const Color(0xFF2979FF)
                  : _appOutlineColor(context),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildDatasetInfoRow(String label, String value) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 72,
          child: Text(
            label,
            style: TextStyle(
              color: _appFaintTextColor(context),
              fontSize: 11,
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
        Expanded(
          child: Text(
            value,
            style: TextStyle(
              color: _appMutedTextColor(context),
              fontSize: 11,
              fontWeight: FontWeight.w700,
              height: 1.25,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildFertilityDatasetCapturingTab() {
    final now = DateTime.now();
    final occupiedSlots = [
      for (var index = 0; index < _activeGridCellCount; index++)
        if (_slotHasEgg(index)) index,
    ];
    final readySlotCount = occupiedSlots
        .where(
          (index) => _slotIsFertilityDatasetTimestampReady(index, now: now),
        )
        .length;
    final waitingSlotCount = occupiedSlots.length - readySlotCount;
    final canCaptureAgeReady =
        _canStartFertilityDatasetCapture && readySlotCount > 0;
    final autoViewStatus = _isFertilityDatasetAutoCapturing
        ? _isFertilityDatasetCapturing
              ? 'Capturing view ${_fertilityDatasetCompletedViewCount + 1}'
              : 'Next view in $_fertilityDatasetCountdownText'
        : _fertilityDatasetCompletedViewCount >= _fertilityDatasetTargetViews
        ? 'Collection complete'
        : _fertilityDatasetCompletedViewCount > 0
        ? 'Ready to continue'
        : 'Label and save one seed view first';

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _premiumEntry(
            0,
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: _appCardColor(context),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: _appOutlineColor(context)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        width: 44,
                        height: 44,
                        decoration: BoxDecoration(
                          color: const Color(
                            0xFF00A86B,
                          ).withValues(alpha: 0.14),
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: const Icon(
                          Icons.biotech_rounded,
                          color: Color(0xFF00A86B),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Fertility Dataset',
                              style: TextStyle(
                                color: _appTextColor(context),
                                fontSize: 18,
                                fontWeight: FontWeight.w900,
                              ),
                            ),
                            const SizedBox(height: 3),
                            Text(
                              'Fertile / infertile candling crops',
                              style: TextStyle(
                                color: _appSubtleTextColor(context),
                                fontSize: 12,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  Text(
                    'P4 supplies occupied slots and Date Placed timestamps. The dataset collector automatically selects only Day 5-10 eggs and preserves every settled tray view under the same egg identity.',
                    style: TextStyle(
                      color: _appMutedTextColor(context),
                      fontSize: 12,
                      height: 1.4,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          _premiumEntry(
            1,
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: const Color(0xFF00A86B).withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: const Color(0xFF00A86B).withValues(alpha: 0.45),
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Row(
                    children: [
                      Icon(
                        Icons.memory_rounded,
                        color: Color(0xFF00A86B),
                        size: 20,
                      ),
                      SizedBox(width: 8),
                      Text(
                        'FUTURE MODEL CANDIDATE',
                        style: TextStyle(
                          color: Color(0xFF00A86B),
                          fontSize: 11,
                          fontWeight: FontWeight.w900,
                          letterSpacing: 0.5,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 9),
                  Text(
                    'EfficientNet-Lite0 per-slot classifier',
                    style: TextStyle(
                      color: _appTextColor(context),
                      fontSize: 15,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  const SizedBox(height: 5),
                  Text(
                    'RGB float32 [1, 224, 224, 3] / 255  ->  softmax [1, 2]\n0 = Fertile  |  1 = Infertile  |  INT8 internals, float I/O',
                    style: TextStyle(
                      color: _appMutedTextColor(context),
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      height: 1.45,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'This candidate is not installed yet. After capture, review each crop and assign Fertile or Infertile. Save All writes only the completed labels into the training dataset folders.',
                    style: TextStyle(
                      color: _appSubtleTextColor(context),
                      fontSize: 11,
                      height: 1.35,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          _premiumEntry(2, _buildFertilityDatasetAutoFilterCard()),
          const SizedBox(height: 16),
          _premiumEntry(
            4,
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: _appCardColor(context),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: _appOutlineColor(context)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      _buildFertilityDatasetCountBadge(
                        'OCC',
                        occupiedSlots.length,
                        const Color(0xFF2979FF),
                      ),
                      const SizedBox(width: 7),
                      _buildFertilityDatasetCountBadge(
                        'READY',
                        readySlotCount,
                        const Color(0xFF00A86B),
                      ),
                      const SizedBox(width: 7),
                      _buildFertilityDatasetCountBadge(
                        'WAIT',
                        waitingSlotCount,
                        const Color(0xFFFF9800),
                      ),
                      const Spacer(),
                      Flexible(
                        child: Text(
                          _pendingFertilityDatasetBatch == null
                              ? '$readySlotCount ready'
                              : '${_fertilityDatasetLastCropLabels.length - _fertilityDatasetLabeledCropCount} labels left',
                          textAlign: TextAlign.end,
                          style: TextStyle(
                            color: _appMutedTextColor(context),
                            fontSize: 11,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  FilledButton.icon(
                    onPressed: canCaptureAgeReady
                        ? () => unawaited(_captureFertilityDatasetImage())
                        : null,
                    icon: _isFertilityDatasetCapturing
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : const Icon(Icons.camera_alt_rounded, size: 19),
                    label: Text(
                      _isFertilityDatasetCapturing
                          ? 'CANDLING CAPTURE IN PROGRESS...'
                          : _pendingFertilityDatasetBatch != null
                          ? 'FINISH LABELING CURRENT BATCH'
                          : 'CAPTURE AGE-READY EGGS',
                      style: const TextStyle(fontWeight: FontWeight.w900),
                    ),
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFF00A86B),
                      padding: const EdgeInsets.symmetric(vertical: 15),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  Container(
                    padding: const EdgeInsets.all(11),
                    decoration: BoxDecoration(
                      color: const Color(0xFF2979FF).withValues(alpha: 0.06),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color: const Color(0xFF2979FF).withValues(alpha: 0.24),
                      ),
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'AUTO ANGLE VIEWS  '
                                '$_fertilityDatasetCompletedViewCount/'
                                '$_fertilityDatasetTargetViews',
                                style: TextStyle(
                                  color: _appTextColor(context),
                                  fontSize: 11,
                                  fontWeight: FontWeight.w900,
                                ),
                              ),
                              const SizedBox(height: 3),
                              Text(
                                autoViewStatus,
                                style: TextStyle(
                                  color: _appSubtleTextColor(context),
                                  fontSize: 10,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 8),
                        OutlinedButton.icon(
                          onPressed: _isFertilityDatasetAutoCapturing
                              ? _stopFertilityDatasetAutoCapture
                              : _canStartFertilityDatasetAutoCapture
                              ? _startFertilityDatasetAutoCapture
                              : null,
                          icon: Icon(
                            _isFertilityDatasetAutoCapturing
                                ? Icons.stop_rounded
                                : Icons.play_arrow_rounded,
                            size: 17,
                          ),
                          label: Text(
                            _isFertilityDatasetAutoCapturing ? 'STOP' : 'START',
                            style: const TextStyle(fontWeight: FontWeight.w900),
                          ),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: _isFertilityDatasetAutoCapturing
                                ? const Color(0xFFFF5252)
                                : const Color(0xFF2979FF),
                            visualDensity: VisualDensity.compact,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (!canCaptureAgeReady && !_isFertilityDatasetCapturing) ...[
                    const SizedBox(height: 9),
                    Text(
                      _pendingFertilityDatasetBatch != null
                          ? 'Label every crop below, then tap Save All.'
                          : _isFertilityDatasetAutoCapturing
                          ? 'Automatic views are using the locked egg labels.'
                          : !_isWifiCorrect
                          ? 'Connect to AI_CANDLING first.'
                          : !_p4Connected
                          ? 'P4 tray controller must be connected.'
                          : readySlotCount == 0
                          ? 'No timestamp-derived Day 5-10 eggs are ready.'
                          : 'Camera or candling hardware is busy.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: _appSubtleTextColor(context),
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          _premiumEntry(
            5,
            _fertilityDatasetLastImage == null
                ? Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: _appCardColor(context),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: _appOutlineColor(context)),
                    ),
                    child: Text(
                      'The last /capture candling image will appear here.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: _appFaintTextColor(context),
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  )
                : Container(
                    decoration: BoxDecoration(
                      color: Colors.black,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: _appOutlineColor(context)),
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: AspectRatio(
                      aspectRatio: 4 / 3,
                      child: Image.memory(
                        _fertilityDatasetLastImage!,
                        fit: BoxFit.contain,
                        gaplessPlayback: true,
                      ),
                    ),
                  ),
          ),
          const SizedBox(height: 16),
          _premiumEntry(6, _buildFertilityDatasetCropPreviewGrid()),
          const SizedBox(height: 16),
          _premiumEntry(
            7,
            OutlinedButton.icon(
              onPressed: _fertilityDatasetLastBatchFiles.isEmpty
                  ? null
                  : _shareFertilityDatasetLastBatch,
              icon: const Icon(Icons.ios_share_rounded, size: 18),
              label: const Text('SHARE COLLECTION ZIP'),
              style: OutlinedButton.styleFrom(
                foregroundColor: const Color(0xFF00A86B),
                side: BorderSide(
                  color: _fertilityDatasetLastBatchFiles.isEmpty
                      ? _appOutlineColor(context)
                      : const Color(0xFF00A86B),
                ),
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
            ),
          ),
          const SizedBox(height: 16),
          _premiumEntry(
            8,
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: _appCardColor(context),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: _appOutlineColor(context)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildDatasetInfoRow(
                    'Saved',
                    '$_fertilityDatasetCaptureCount crop${_fertilityDatasetCaptureCount == 1 ? '' : 's'}',
                  ),
                  const SizedBox(height: 8),
                  _buildDatasetInfoRow(
                    'Camera',
                    'ESP32-S3 $_fertilityDatasetCaptureEndpoint candling',
                  ),
                  const SizedBox(height: 8),
                  _buildDatasetInfoRow(
                    'Last batch',
                    _fertilityDatasetLastBatchCount == 0
                        ? '--'
                        : '$_fertilityDatasetLastBatchCount labeled crops',
                  ),
                  const SizedBox(height: 8),
                  _buildDatasetInfoRow(
                    'Training',
                    _fertilityDatasetLastBatchCount == 0
                        ? '--'
                        : '${_fertilityDatasetLastBatchCount - _fertilityDatasetLastQualityWarningCount} ready',
                  ),
                  const SizedBox(height: 8),
                  _buildDatasetInfoRow(
                    'Quality',
                    _fertilityDatasetLastBatchCount == 0
                        ? '--'
                        : _fertilityDatasetLastQualityWarningCount == 0
                        ? 'No automatic warnings'
                        : '$_fertilityDatasetLastQualityWarningCount flagged for review',
                  ),
                  const SizedBox(height: 8),
                  _buildDatasetInfoRow(
                    'Label state',
                    _fertilityDatasetVerificationName(
                      _fertilityDatasetVerification,
                    ),
                  ),
                  const SizedBox(height: 8),
                  _buildDatasetInfoRow(
                    'Grid',
                    '8 x 7 | automatic timestamp-derived Day 5-10',
                  ),
                  const SizedBox(height: 8),
                  _buildDatasetInfoRow(
                    'Views',
                    '$_fertilityDatasetCompletedViewCount / '
                        '$_fertilityDatasetTargetViews settled positions',
                  ),
                  if (_fertilityDatasetRootPath != null) ...[
                    const SizedBox(height: 8),
                    _buildDatasetInfoRow('Folder', _fertilityDatasetRootPath!),
                  ],
                  if (_fertilityDatasetLastCsvPath != null) ...[
                    const SizedBox(height: 8),
                    _buildDatasetInfoRow('CSV', _fertilityDatasetLastCsvPath!),
                  ],
                  if (_fertilityDatasetLastManifestPath != null) ...[
                    const SizedBox(height: 8),
                    _buildDatasetInfoRow(
                      'Manifest',
                      _fertilityDatasetLastManifestPath!,
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFertilityDatasetAutoFilterCard() {
    final now = DateTime.now();
    final occupiedSlots = <int>[
      for (var index = 0; index < _activeGridCellCount; index++)
        if (_slotHasEgg(index)) index,
    ];
    final readySlots = <int>[
      for (final index in occupiedSlots)
        if (_slotIsFertilityDatasetTimestampReady(index, now: now)) index,
    ];
    final missingDateCount = occupiedSlots
        .where((index) => _slotPlacedAt(index) == null)
        .length;
    final waitingCount = occupiedSlots.length - readySlots.length;

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: _appCardColor(context),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: _appOutlineColor(context)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'AUTOMATIC TIMESTAMP SELECTION',
                  style: TextStyle(
                    color: _appMutedTextColor(context),
                    fontSize: 11,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
              IconButton(
                onPressed:
                    _isFertilityDatasetCapturing ||
                        _isFertilityDatasetAutoCapturing ||
                        !_p4Connected
                    ? null
                    : () => unawaited(_syncEggGridFromP4()),
                icon: const Icon(Icons.sync_rounded, size: 19),
                tooltip: 'Refresh slots and dates from P4',
                visualDensity: VisualDensity.compact,
              ),
            ],
          ),
          Text(
            'Date Placed and the current capture timestamp determine each occupied egg\'s incubation day. Only Day 5-10 eggs are captured and saved.',
            style: TextStyle(
              color: _appSubtleTextColor(context),
              fontSize: 11,
              height: 1.4,
            ),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 7,
            runSpacing: 7,
            children: [
              _buildFertilityDatasetCountBadge(
                'OCC',
                occupiedSlots.length,
                const Color(0xFF2979FF),
              ),
              _buildFertilityDatasetCountBadge(
                'READY',
                readySlots.length,
                const Color(0xFF00A86B),
              ),
              _buildFertilityDatasetCountBadge(
                'WAIT',
                waitingCount,
                const Color(0xFFFF9800),
              ),
            ],
          ),
          if (missingDateCount > 0) ...[
            const SizedBox(height: 10),
            _buildFertilityDatasetAutoFilterNotice(
              icon: Icons.event_busy_rounded,
              color: const Color(0xFFFF9800),
              title: 'Date Placed required',
              message:
                  '$missingDateCount occupied egg${missingDateCount == 1 ? '' : 's'} will wait until Date Placed is available from the tray record.',
            ),
          ],
          if (occupiedSlots.isNotEmpty && readySlots.isEmpty) ...[
            const SizedBox(height: 10),
            _buildFertilityDatasetAutoFilterNotice(
              icon: Icons.hourglass_top_rounded,
              color: const Color(0xFF2979FF),
              title: 'No age-ready eggs yet',
              message:
                  'Capture becomes available automatically when an occupied egg reaches Day 5 and remains available through Day 10.',
            ),
          ],
          const SizedBox(height: 8),
          Text(
            'Each crop stores its capture timestamp, Date Placed, calculated age in hours, and incubation day. Fertile or Infertile is assigned after capture before any files are saved.',
            style: TextStyle(
              color: _appFaintTextColor(context),
              fontSize: 10,
              height: 1.35,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFertilityDatasetAutoFilterNotice({
    required IconData icon,
    required Color color,
    required String title,
    required String message,
  }) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.28)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: color, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Text.rich(
              TextSpan(
                children: [
                  TextSpan(
                    text: '$title\n',
                    style: TextStyle(color: color, fontWeight: FontWeight.w900),
                  ),
                  TextSpan(text: message),
                ],
              ),
              style: TextStyle(
                color: _appMutedTextColor(context),
                fontSize: 10,
                height: 1.35,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFertilityDatasetCountBadge(
    String label,
    int count,
    Color color,
  ) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        '$label $count',
        style: TextStyle(
          color: color,
          fontSize: 11,
          fontWeight: FontWeight.w900,
        ),
      ),
    );
  }

  Widget _buildFertilityDatasetCropPreviewGrid() {
    if (_fertilityDatasetLastCropPreviews.isEmpty) {
      return Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: _appCardColor(context),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: _appOutlineColor(context)),
        ),
        child: Text(
          'Captured fertility crop previews will appear here for labeling.',
          textAlign: TextAlign.center,
          style: TextStyle(
            color: _appFaintTextColor(context),
            fontSize: 12,
            fontWeight: FontWeight.w700,
          ),
        ),
      );
    }

    final cropCount = _fertilityDatasetLastCropPreviews.length;
    final selectedIndex = _selectedFertilityDatasetCropIndex.clamp(
      0,
      cropCount - 1,
    );
    final canEdit =
        _pendingFertilityDatasetBatch != null && !_isFertilityDatasetSaving;

    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: _appCardColor(context),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: _appOutlineColor(context)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                'FERTILITY CROP LABELS',
                style: TextStyle(
                  color: _appMutedTextColor(context),
                  fontSize: 11,
                  fontWeight: FontWeight.w900,
                ),
              ),
              const Spacer(),
              Text(
                '$_fertilityDatasetLabeledCropCount / $cropCount labeled',
                style: TextStyle(
                  color: _appFaintTextColor(context),
                  fontSize: 11,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          SizedBox(
            height: 116,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: cropCount,
              separatorBuilder: (_, _) => const SizedBox(width: 8),
              itemBuilder: (context, index) {
                final status = index < _fertilityDatasetLastCropStatuses.length
                    ? _fertilityDatasetLastCropStatuses[index]
                    : 'ok';
                final label = index < _fertilityDatasetLastCropLabels.length
                    ? _fertilityDatasetLastCropLabels[index]
                    : 'pending';
                final slotNumber =
                    index < _fertilityDatasetLastCropSlotNumbers.length
                    ? _fertilityDatasetLastCropSlotNumbers[index]
                    : index + 1;
                final color = _fertilityDatasetLabelColor(label);
                final isSelected = index == selectedIndex;
                return Tooltip(
                  message:
                      'Slot $slotNumber | ${_fertilityDatasetLabelName(label)} | $status',
                  child: InkWell(
                    onTap: () => setState(
                      () => _selectedFertilityDatasetCropIndex = index,
                    ),
                    borderRadius: BorderRadius.circular(8),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 160),
                      width: 92,
                      padding: const EdgeInsets.all(3),
                      decoration: BoxDecoration(
                        color: color.withValues(
                          alpha: isSelected ? 0.14 : 0.06,
                        ),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: color,
                          width: isSelected ? 3 : 2,
                        ),
                      ),
                      child: Column(
                        children: [
                          Expanded(
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(4),
                              child: Stack(
                                fit: StackFit.expand,
                                children: [
                                  Image.memory(
                                    _fertilityDatasetLastCropPreviews[index],
                                    fit: BoxFit.cover,
                                    gaplessPlayback: true,
                                  ),
                                  Positioned(
                                    top: 3,
                                    left: 3,
                                    child: Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 5,
                                        vertical: 2,
                                      ),
                                      decoration: BoxDecoration(
                                        color: Colors.black.withValues(
                                          alpha: 0.68,
                                        ),
                                        borderRadius: BorderRadius.circular(4),
                                      ),
                                      child: Text(
                                        'S${slotNumber.toString().padLeft(2, '0')}',
                                        style: const TextStyle(
                                          color: Colors.white,
                                          fontSize: 9,
                                          fontWeight: FontWeight.w900,
                                        ),
                                      ),
                                    ),
                                  ),
                                  if (status != 'ok')
                                    const Positioned(
                                      top: 3,
                                      right: 3,
                                      child: Icon(
                                        Icons.warning_amber_rounded,
                                        color: Color(0xFFFFB300),
                                        size: 16,
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            label == 'fertile'
                                ? 'FERTILE'
                                : label == 'infertile'
                                ? 'INFERTILE'
                                : 'PENDING',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: color,
                              fontSize: 9,
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
          if (_pendingFertilityDatasetBatch != null ||
              _isFertilityDatasetSaving) ...[
            const SizedBox(height: 12),
            Text(
              'SELECTED SLOT ${_fertilityDatasetLastCropSlotNumbers[selectedIndex].toString().padLeft(2, '0')}',
              style: TextStyle(
                color: _appSubtleTextColor(context),
                fontSize: 10,
                fontWeight: FontWeight.w900,
              ),
            ),
            const SizedBox(height: 7),
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: canEdit
                        ? () => _labelSelectedFertilityDatasetCrop('fertile')
                        : null,
                    icon: const Icon(Icons.check_circle_rounded, size: 18),
                    label: const Text('FERTILE'),
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFF00A86B),
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: FilledButton.icon(
                    onPressed: canEdit
                        ? () => _labelSelectedFertilityDatasetCrop('infertile')
                        : null,
                    icon: const Icon(Icons.cancel_rounded, size: 18),
                    label: const Text('INFERTILE'),
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFFFF5252),
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 9),
            FilledButton.icon(
              onPressed: _canSaveAllFertilityDatasetCrops
                  ? () => unawaited(_saveAllFertilityDatasetCrops())
                  : null,
              icon: _isFertilityDatasetSaving
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Icon(Icons.save_rounded, size: 19),
              label: Text(
                _isFertilityDatasetSaving
                    ? 'SAVING TRAINING BATCH...'
                    : 'SAVE ALL ($_fertilityDatasetLabeledCropCount/$cropCount)',
                style: const TextStyle(fontWeight: FontWeight.w900),
              ),
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFF2979FF),
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 13),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: canEdit
                    ? () => unawaited(_discardPendingFertilityDatasetCapture())
                    : null,
                icon: const Icon(Icons.delete_outline_rounded, size: 19),
                label: const Text(
                  'DISCARD CAPTURE',
                  style: TextStyle(fontWeight: FontWeight.w900),
                ),
                style: OutlinedButton.styleFrom(
                  foregroundColor: const Color(0xFFFF5252),
                  side: const BorderSide(color: Color(0xFFFF5252)),
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  // Grid customization
  Widget _buildGridCustomizationTab() {
    final selIdx = _selectedBoundaryIndex;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Grid preview canvas (with optional background image)
          _premiumEntry(
            0,
            Container(
              width: double.infinity,
              decoration: BoxDecoration(
                color: _appDeepPanelColor(context),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: _appOutlineColor(context)),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: AspectRatio(
                  aspectRatio: 4 / 3,
                  child: _gridCalibrationImage != null
                      ? Stack(
                          fit: StackFit.expand,
                          children: [
                            Image.memory(
                              _gridCalibrationImage!,
                              fit: BoxFit.contain,
                            ),
                            CustomPaint(
                              painter: GridPainter(
                                colBoundaries: _customColBoundaries,
                                rowBoundaries: _customRowBoundaries,
                                selectedBoundaryIndex: _selectedBoundaryIndex,
                                selectedBoundaryIsCol: _selectedBoundaryIsCol,
                                showIsolationBox: _gridSaved,
                                lineLengthScale: _globalLineLengthScale,
                              ),
                            ),
                            Positioned(
                              top: 8,
                              right: 8,
                              child: _buildReferenceImageDeleteButton(),
                            ),
                          ],
                        )
                      : Center(
                          child: Padding(
                            padding: const EdgeInsets.all(18),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  'No reference image\nTap below to capture one',
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                    color: _appFaintTextColor(context),
                                    fontSize: 12,
                                  ),
                                ),
                                const SizedBox(height: 14),
                                _buildReferenceCaptureButton(),
                              ],
                            ),
                          ),
                        ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 16),
          _premiumEntry(1, _buildBoundaryAdjustmentPanel(selIdx)),
          const SizedBox(height: 16),

          _premiumEntry(2, _buildGridFineTuneControls()),
          const SizedBox(height: 16),

          _premiumEntry(3, _buildRowCountStepper()),
          const SizedBox(height: 16),

          // Isolation box info (shown when saved)
          if (_gridSaved) ...[
            _premiumEntry(4, _buildIsolationBoxInfo()),
            const SizedBox(height: 16),
          ],
          _premiumEntry(5, _buildGridResetButton()),
        ],
      ),
    );
  }

  Widget _buildReferenceCaptureButton() {
    return ElevatedButton.icon(
      onPressed: _isCapturingCalibration ? null : _captureForGridCalibration,
      icon: _isCapturingCalibration
          ? const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
              ),
            )
          : const Icon(Icons.camera_alt_rounded, size: 18),
      label: Text(
        _isCapturingCalibration ? 'CAPTURING...' : 'CAPTURE REFERENCE IMAGE',
      ),
      style: ElevatedButton.styleFrom(
        backgroundColor: const Color(0xFF2979FF),
        foregroundColor: Colors.white,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    );
  }

  Widget _buildReferenceImageDeleteButton() {
    return AnimatedOpacity(
      opacity: _referenceTrashDimmed ? 0.5 : 1.0,
      duration: const Duration(milliseconds: 250),
      child: Material(
        color: Colors.red.withAlpha(230),
        borderRadius: BorderRadius.circular(12),
        child: IconButton(
          icon: const Icon(Icons.delete_rounded, color: Colors.white),
          onPressed: _clearGridCalibrationImage,
          tooltip: 'Remove reference image',
        ),
      ),
    );
  }

  void _setAdjustStep(double step) {
    if (step <= 0) return;
    setState(() {
      _adjustStep = step;
      _adjustStepController.text = step.toStringAsFixed(step < 1 ? 1 : 0);
    });
  }

  Widget _buildGridFineTuneControls() {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(child: _buildLineLengthPanel()),
        const SizedBox(width: 12),
        Expanded(child: _buildStepSizePanel()),
      ],
    );
  }

  Widget _buildLineLengthPanel() {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: _appCardColor(context),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: _appOutlineColor(context)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'LINE LENGTH',
            style: TextStyle(
              color: _appMutedTextColor(context),
              fontSize: 11,
              fontWeight: FontWeight.w900,
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _lineLengthStepController,
                  keyboardType: TextInputType.number,
                  style: TextStyle(fontSize: 12, color: _appTextColor(context)),
                  textAlign: TextAlign.center,
                  decoration: _compactInputDecoration('Step'),
                ),
              ),
              const SizedBox(width: 6),
              _buildLineLengthButton(Icons.remove_rounded, -1),
              const SizedBox(width: 4),
              _buildLineLengthButton(Icons.add_rounded, 1),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: Text(
                  '${(_globalLineLengthScale * 100).toInt()}%',
                  style: const TextStyle(
                    color: Color(0xFF2979FF),
                    fontSize: 14,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
              _buildUniformAxisButton('X', _uniformCols, () {
                _toggleUniformAxis(columns: true);
              }),
              const SizedBox(width: 6),
              _buildUniformAxisButton('Y', _uniformRows, () {
                _toggleUniformAxis(columns: false);
              }),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildLineLengthButton(IconData icon, int direction) {
    return SizedBox(
      width: 34,
      height: 34,
      child: IconButton(
        padding: EdgeInsets.zero,
        icon: Icon(icon, size: 18),
        color: _appMutedTextColor(context),
        onPressed: () {
          final step = double.tryParse(_lineLengthStepController.text) ?? 0.1;
          _adjustLineLength(step * direction);
        },
        tooltip: direction > 0 ? 'Increase length' : 'Decrease length',
      ),
    );
  }

  Widget _buildUniformAxisButton(
    String label,
    bool selected,
    VoidCallback onTap,
  ) {
    return SizedBox(
      width: 34,
      height: 34,
      child: FilledButton(
        onPressed: onTap,
        style: FilledButton.styleFrom(
          backgroundColor: selected
              ? const Color(0xFF2979FF)
              : _appPanelColor(context),
          foregroundColor: selected
              ? Colors.white
              : _appMutedTextColor(context),
          padding: EdgeInsets.zero,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(9),
            side: BorderSide(
              color: selected
                  ? const Color(0xFF2979FF)
                  : _appOutlineColor(context),
            ),
          ),
        ),
        child: Text(
          label,
          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w900),
        ),
      ),
    );
  }

  Widget _buildStepSizePanel() {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: _appCardColor(context),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: _appOutlineColor(context)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'STEP SIZE',
            style: TextStyle(
              color: _appMutedTextColor(context),
              fontSize: 11,
              fontWeight: FontWeight.w900,
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _adjustStepController,
                  keyboardType: TextInputType.number,
                  style: TextStyle(fontSize: 12, color: _appTextColor(context)),
                  textAlign: TextAlign.center,
                  decoration: _compactInputDecoration('Custom'),
                  onSubmitted: (value) {
                    final step = double.tryParse(value);
                    if (step != null && step > 0) {
                      _setAdjustStep(step);
                    }
                  },
                ),
              ),
              const SizedBox(width: 6),
              _buildStepSizeButton(0.1),
              const SizedBox(width: 4),
              _buildStepSizeButton(0.5),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildStepSizeButton(double step) {
    final selected = (_adjustStep - step).abs() < 0.001;
    return SizedBox(
      width: 34,
      height: 34,
      child: FilledButton(
        onPressed: () => _setAdjustStep(step),
        style: FilledButton.styleFrom(
          backgroundColor: selected
              ? const Color(0xFF2979FF)
              : _appPanelColor(context),
          foregroundColor: selected
              ? Colors.white
              : _appMutedTextColor(context),
          padding: EdgeInsets.zero,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(9),
            side: BorderSide(
              color: selected
                  ? const Color(0xFF2979FF)
                  : _appOutlineColor(context),
            ),
          ),
        ),
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(
            '${step.toStringAsFixed(1)}cm',
            style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w900),
          ),
        ),
      ),
    );
  }

  InputDecoration _compactInputDecoration(String hint) {
    return InputDecoration(
      hintText: hint,
      hintStyle: TextStyle(color: _appFaintTextColor(context), fontSize: 10),
      isDense: true,
      contentPadding: const EdgeInsets.symmetric(vertical: 9, horizontal: 8),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(9),
        borderSide: BorderSide(color: _appDividerColor(context)),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(9),
        borderSide: BorderSide(color: _appDividerColor(context)),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(9),
        borderSide: const BorderSide(color: Color(0xFF2979FF)),
      ),
    );
  }

  Widget _buildGridAxisSwitch() {
    Widget axisButton({required bool isColumn, required IconData icon}) {
      final selected = _selectedBoundaryIsCol == isColumn;
      return Expanded(
        child: Tooltip(
          message: isColumn ? 'Column' : 'Row',
          child: InkWell(
            onTap: () => _selectBoundaryAxis(isColumn),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 140),
              alignment: Alignment.center,
              height: 42,
              color: selected ? const Color(0xFF2979FF) : Colors.transparent,
              child: Icon(
                icon,
                size: 20,
                color: selected ? Colors.white : _appMutedTextColor(context),
              ),
            ),
          ),
        ),
      );
    }

    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: Container(
        height: 42,
        decoration: BoxDecoration(
          color: _appPanelColor(context),
          border: Border.all(color: _appOutlineColor(context)),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          children: [
            axisButton(isColumn: true, icon: Icons.view_column_rounded),
            Container(width: 1, color: _appOutlineColor(context)),
            axisButton(isColumn: false, icon: Icons.table_rows_rounded),
          ],
        ),
      ),
    );
  }

  void _selectBoundaryAxis(bool isColumn) {
    if (_selectedBoundaryIsCol == isColumn) return;
    setState(() {
      _selectedBoundaryIsCol = isColumn;
      final length = isColumn
          ? _customColBoundaries.length
          : _customRowBoundaries.length;
      if (_selectedBoundaryIndex != null && _selectedBoundaryIndex! >= length) {
        _selectedBoundaryIndex = null;
      }
    });
  }

  Widget _buildBoundaryAdjustmentPanel(int? selIdx) {
    final panelHeight = _activeBoundarySelectorHeight();

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: SizedBox(
            height: panelHeight,
            child: _buildActiveBoundarySelector(),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: SizedBox(
            height: panelHeight,
            child: _buildDirectionalControls(selIdx),
          ),
        ),
      ],
    );
  }

  double _activeBoundarySelectorHeight() {
    final boundaryCount = _selectedBoundaryIsCol
        ? _customColBoundaries.length
        : _customRowBoundaries.length;
    final gridRows = (boundaryCount + 2) ~/ 3;
    final safeGridRows = gridRows < 1 ? 1 : gridRows;

    const verticalPadding = 20.0;
    const axisSwitchHeight = 42.0;
    const switchGridGap = 10.0;
    const gridItemHeight = 40.0;
    const gridMainSpacing = 6.0;

    return verticalPadding +
        axisSwitchHeight +
        switchGridGap +
        (safeGridRows * gridItemHeight) +
        ((safeGridRows - 1) * gridMainSpacing);
  }

  Widget _buildActiveBoundarySelector() {
    final isCol = _selectedBoundaryIsCol;
    final boundaries = isCol ? _customColBoundaries : _customRowBoundaries;
    final prefix = isCol ? 'C' : 'R';

    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: _appCardColor(context),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: _appOutlineColor(context)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildGridAxisSwitch(),
          const SizedBox(height: 10),
          GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: boundaries.length,
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 3,
              crossAxisSpacing: 6,
              mainAxisSpacing: 6,
              mainAxisExtent: 40,
            ),
            itemBuilder: (context, i) {
              final isSelected =
                  _selectedBoundaryIndex == i &&
                  _selectedBoundaryIsCol == isCol;
              final isOuter = i == 0 || i == boundaries.length - 1;
              return InkWell(
                onTap: () => setState(() {
                  _selectedBoundaryIndex = i;
                  _selectedBoundaryIsCol = isCol;
                }),
                borderRadius: BorderRadius.circular(8),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 140),
                  alignment: Alignment.center,
                  padding: const EdgeInsets.symmetric(vertical: 5),
                  decoration: BoxDecoration(
                    color: isSelected
                        ? const Color(0xFF2979FF)
                        : isOuter
                        ? _appPanelColor(context)
                        : _appDeepPanelColor(context),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: isSelected
                          ? const Color(0xFF2979FF)
                          : isOuter
                          ? _appFaintTextColor(context)
                          : _appOutlineColor(context),
                    ),
                  ),
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          '$prefix$i',
                          style: TextStyle(
                            fontSize: 8,
                            color: isSelected
                                ? Colors.white70
                                : _appFaintTextColor(context),
                          ),
                        ),
                        Text(
                          boundaries[i].toStringAsFixed(1),
                          style: TextStyle(
                            color: isSelected
                                ? Colors.white
                                : _appMutedTextColor(context),
                            fontSize: 10,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _buildGridResetButton() {
    return SizedBox(
      width: double.infinity,
      child: OutlinedButton.icon(
        icon: const Icon(Icons.refresh_rounded, size: 18),
        label: const Text('Reset'),
        onPressed: _confirmResetGridToDefault,
        style: OutlinedButton.styleFrom(
          foregroundColor: _appSubtleTextColor(context),
          side: BorderSide(color: _appDividerColor(context)),
          padding: const EdgeInsets.symmetric(vertical: 14),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      ),
    );
  }

  Widget _buildDirectionalControls(int? selIdx) {
    final hasSelected = selIdx != null;

    final double? upDelta = hasSelected && !_selectedBoundaryIsCol
        ? -_adjustStep
        : null;
    final double? downDelta = hasSelected && !_selectedBoundaryIsCol
        ? _adjustStep
        : null;
    final double? leftDelta = hasSelected && _selectedBoundaryIsCol
        ? -_adjustStep
        : null;
    final double? rightDelta = hasSelected && _selectedBoundaryIsCol
        ? _adjustStep
        : null;

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: _appCardColor(context),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: hasSelected
              ? const Color(0xFF2979FF).withAlpha(80)
              : _appOutlineColor(context),
        ),
      ),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [_buildDPadBtn(Icons.arrow_upward, upDelta)],
            ),
            const SizedBox(height: 4),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _buildDPadBtn(Icons.arrow_back, leftDelta),
                const SizedBox(width: 16),
                _buildDPadBtn(Icons.arrow_forward, rightDelta),
              ],
            ),
            const SizedBox(height: 4),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [_buildDPadBtn(Icons.arrow_downward, downDelta)],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDPadBtn(IconData icon, double? delta) {
    final active = delta != null;
    return GestureDetector(
      onTap: active ? () => _adjustBoundary(delta) : null,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 100),
        width: 42,
        height: 42,
        decoration: BoxDecoration(
          color: active ? _appPanelColor(context) : _appDeepPanelColor(context),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: active ? const Color(0xFF2979FF) : _appOutlineColor(context),
            width: active ? 1.5 : 1,
          ),
        ),
        child: Icon(
          icon,
          color: active ? const Color(0xFF2979FF) : _appOutlineColor(context),
          size: 20,
        ),
      ),
    );
  }

  Widget _buildIsolationBoxInfo() {
    final left = _customColBoundaries.first;
    final right = _customColBoundaries.last;
    final top = _customRowBoundaries.first;
    final bottom = _customRowBoundaries.last;

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF00E676).withAlpha(20),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFF00E676).withAlpha(100)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.crop_free, color: Color(0xFF00E676), size: 16),
              SizedBox(width: 6),
              Text(
                'ISOLATION BOX (Capture Crop Area)',
                style: TextStyle(
                  color: Color(0xFF00E676),
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 0.5,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          _buildIsoRow(
            'X-axis',
            '${left.toStringAsFixed(1)} -> ${right.toStringAsFixed(1)} cm  '
                '(${(right - left).toStringAsFixed(1)} cm wide)',
          ),
          _buildIsoRow(
            'Y-axis',
            '${top.toStringAsFixed(1)} -> ${bottom.toStringAsFixed(1)} cm  '
                '(${(bottom - top).toStringAsFixed(1)} cm tall)',
          ),
          _buildIsoRow(
            'Grid size',
            '${_customColBoundaries.length - 1} cols × '
                '${_customRowBoundaries.length - 1} rows = '
                '${(_customColBoundaries.length - 1) * (_customRowBoundaries.length - 1)} cells',
          ),
          _buildIsoRow(
            'Capture status',
            _gridSaved ? '✓ Active on next capture' : '—',
          ),
        ],
      ),
    );
  }

  Widget _buildIsoRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          SizedBox(
            width: 72,
            child: Text(
              label,
              style: TextStyle(
                color: _appFaintTextColor(context),
                fontSize: 11,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: TextStyle(
                color: _appMutedTextColor(context),
                fontSize: 11,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// Onboarding Dialog
class _OnboardingDialog extends StatefulWidget {
  const _OnboardingDialog({required this.demoMode});

  final bool demoMode;

  @override
  State<_OnboardingDialog> createState() => _OnboardingDialogState();
}

class _OnboardingDialogState extends State<_OnboardingDialog> {
  int _page = 0;

  static const _actualSteps = [
    _OnboardStep(
      icon: Icons.wifi,
      color: Color(0xFF2979FF),
      title: 'Connect to Incubator WiFi',
      body:
          'Go to your phone\'s WiFi settings and connect to '
          '"AI_CANDLING" (password: thesis123). The camera stream '
          'will start automatically once connected.',
    ),
    _OnboardStep(
      icon: Icons.tune,
      color: Color(0xFF00E676),
      title: 'Calibrate the Grid',
      body:
          'Tap the Grid tab (bottom nav) or the tune icon in the '
          'toolbar. Select individual boundary lines and use the D-pad '
          'to align the grid with your physical egg tray. Tap '
          '"Save & Apply" when done.',
    ),
    _OnboardStep(
      icon: Icons.camera_alt,
      color: Color(0xFFFFD54F),
      title: 'AI Candling',
      body:
          'Press "AI CANDLING". The app records the candling image, '
          'slot ages, environment, and readiness without classifying eggs.',
    ),
    _OnboardStep(
      icon: Icons.history,
      color: Color(0xFFFF5252),
      title: 'Review & Export',
      body:
          'All scans are saved in the History tab with charts, trend '
          'lines, and your thesis data log. Open any session and tap '
          'the print icon to generate a PDF report you can share or '
          'print.',
    ),
  ];

  static const _demoSteps = [
    _OnboardStep(
      icon: Icons.slideshow_rounded,
      color: Color(0xFF2979FF),
      title: 'Explore Demo Mode',
      body:
          'Demo mode loads sample scans, sensor values, egg counts, and history '
          'records so you can present the workflow without connecting to the incubator.',
    ),
    _OnboardStep(
      icon: Icons.dashboard_customize_rounded,
      color: Color(0xFF00E676),
      title: 'Read the Dashboard',
      body:
          'Use the camera page to review the sample grid. Day 7-14 slots are '
          'eligible for the mobile classifier; other days remain outside its scope.',
    ),
    _OnboardStep(
      icon: Icons.camera_alt,
      color: Color(0xFFFFD54F),
      title: 'Run a Demo Capture',
      body:
          'Press "RUN DEMO CAPTURE" to simulate a candling capture. The app '
          'records sample tray and research-history data without classification.',
    ),
    _OnboardStep(
      icon: Icons.history,
      color: Color(0xFFFF5252),
      title: 'Review & Export',
      body:
          'Open History to inspect sample sessions, charts, and PDF reports. '
          'Use Actual Mode when you are ready to work with the S3 camera and P4 board.',
    ),
  ];

  @override
  Widget build(BuildContext context) {
    final steps = widget.demoMode ? _demoSteps : _actualSteps;
    final step = steps[_page];
    final isLast = _page == steps.length - 1;

    return AlertDialog(
      backgroundColor: _appCardColor(context),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      contentPadding: const EdgeInsets.all(24),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Progress dots
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: List.generate(
              steps.length,
              (i) => Container(
                width: i == _page ? 20 : 8,
                height: 8,
                margin: const EdgeInsets.symmetric(horizontal: 3),
                decoration: BoxDecoration(
                  color: i == _page ? step.color : _appDividerColor(context),
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
            ),
          ),
          const SizedBox(height: 24),
          Container(
            width: 72,
            height: 72,
            decoration: BoxDecoration(
              color: step.color.withAlpha(30),
              shape: BoxShape.circle,
              border: Border.all(color: step.color, width: 2),
            ),
            child: Icon(step.icon, color: step.color, size: 36),
          ),
          const SizedBox(height: 16),
          Text(
            step.title,
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 12),
          Text(
            step.body,
            style: TextStyle(
              color: _appMutedTextColor(context),
              fontSize: 13,
              height: 1.5,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 24),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              if (_page > 0)
                TextButton(
                  onPressed: () => setState(() => _page--),
                  child: const Text('Back'),
                )
              else
                const SizedBox(width: 60),
              ElevatedButton(
                onPressed: isLast
                    ? () => Navigator.pop(context, true)
                    : () => setState(() => _page++),
                style: ElevatedButton.styleFrom(
                  backgroundColor: step.color,
                  foregroundColor: Colors.black,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                child: Text(isLast ? 'Get Started' : 'Next'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _OnboardStep {
  final IconData icon;
  final Color color;
  final String title;
  final String body;
  const _OnboardStep({
    required this.icon,
    required this.color,
    required this.title,
    required this.body,
  });
}

Widget _buildFertilitySlotVerdicts(BuildContext context, EggSession session) {
  final slots = session.analyzedSlots.isNotEmpty
      ? (session.analyzedSlots.toSet().toList()..sort())
      : [
          for (var index = 0; index < session.totalCells; index++)
            if (session.statusForSlot(index) != EggStatus.unknown &&
                (!session.hasOccupancyData || session.isOccupiedSlot(index)))
              index,
        ];
  if (slots.isEmpty) return const SizedBox.shrink();

  return Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        'Slot verdicts',
        style: TextStyle(
          color: _appTextColor(context),
          fontSize: 14,
          fontWeight: FontWeight.w700,
        ),
      ),
      const SizedBox(height: 8),
      LayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.maxWidth >= 310
              ? (constraints.maxWidth - 8) / 2
              : constraints.maxWidth;
          return Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final index in slots)
                SizedBox(
                  width: width,
                  child: Builder(
                    builder: (context) {
                      final status = session.statusForSlot(index);
                      final color = status == EggStatus.fertile
                          ? const Color(0xFF00A86B)
                          : status == EggStatus.infertile
                          ? const Color(0xFFFF5252)
                          : const Color(0xFFFF9800);
                      final label = status == EggStatus.fertile
                          ? 'Fertile'
                          : status == EggStatus.infertile
                          ? 'Infertile'
                          : 'In review';
                      return Row(
                        children: [
                          Icon(Icons.circle, size: 9, color: color),
                          const SizedBox(width: 7),
                          Text(
                            'Slot ${(index + 1).toString().padLeft(2, '0')}',
                            style: TextStyle(
                              color: _appTextColor(context),
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(width: 7),
                          Flexible(
                            child: Text(
                              label,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(color: color, fontSize: 12),
                            ),
                          ),
                        ],
                      );
                    },
                  ),
                ),
            ],
          );
        },
      ),
    ],
  );
}

// Session persistence
class SessionDetailPage extends StatefulWidget {
  final EggSession session;
  final List<EggSession> allSessions;

  const SessionDetailPage({
    super.key,
    required this.session,
    this.allSessions = const [],
  });

  @override
  State<SessionDetailPage> createState() => _SessionDetailPageState();
}

class _SessionDetailPageState extends State<SessionDetailPage> {
  bool _showGridOverlay = false;

  @override
  Widget build(BuildContext context) {
    final session = widget.session;
    return Scaffold(
      appBar: AppBar(
        title: Text(
          DateFormat('MMM dd, yyyy - h:mm a').format(session.timestamp),
        ),
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
                  color: _appCardColor(context),
                  borderRadius: BorderRadius.circular(16),
                ),
                clipBehavior: Clip.antiAlias,
                child: _buildImageWithDetections(
                  session.imageBytes!,
                  session.detections,
                  imageWidth: session.imageWidth,
                  imageHeight: session.imageHeight,
                  colBoundaries: session.colBoundaries,
                  rowBoundaries: session.rowBoundaries,
                ),
              ),
            const SizedBox(height: 20),
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: _appCardColor(context),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  _buildDetailStat(
                    context,
                    'Fertile',
                    session.fertileCount.toString(),
                    const Color(0xFF00E676),
                  ),
                  Container(
                    width: 1,
                    height: 40,
                    color: _appDividerColor(context),
                  ),
                  _buildDetailStat(
                    context,
                    'Infertile',
                    session.infertileCount.toString(),
                    const Color(0xFFFF5252),
                  ),
                  Container(
                    width: 1,
                    height: 40,
                    color: _appDividerColor(context),
                  ),
                  _buildDetailStat(
                    context,
                    'In review',
                    session.inReviewCount.toString(),
                    const Color(0xFFFF9800),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            _buildFertilitySlotVerdicts(context, session),
            const SizedBox(height: 16),
            _buildResearchSummary(context, session),
            const SizedBox(height: 16),
            _buildPerSlotRecords(context, session),
          ],
        ),
      ),
    );
  }

  Widget _buildDetailStat(
    BuildContext context,
    String label,
    String value,
    Color color,
  ) {
    return Column(
      children: [
        Text(
          label,
          style: TextStyle(fontSize: 10, color: _appSubtleTextColor(context)),
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

  Widget _buildResearchSummary(BuildContext context, EggSession session) {
    String numberList(List<int> values) =>
        values.isEmpty ? '--' : values.join(', ');
    String duration(int? milliseconds) =>
        milliseconds == null ? '--' : '$milliseconds ms';
    String decimal(double? value, String suffix) =>
        value == null ? '--' : '${value.toStringAsFixed(1)}$suffix';
    String yesNo(bool? value) => value == null
        ? 'Not recorded'
        : value
        ? 'Yes'
        : 'No';

    return ExpansionTile(
      tilePadding: EdgeInsets.zero,
      title: const Text('Technical details', style: TextStyle(fontSize: 13)),
      children: [
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _researchInfoRow(context, 'Session ID', session.id.toString()),
            _researchInfoRow(
              context,
              'Timestamp',
              DateFormat('yyyy-MM-dd HH:mm:ss').format(session.timestamp),
            ),
            _researchInfoRow(
              context,
              'Capture endpoint',
              session.captureEndpoint,
            ),
            _researchInfoRow(
              context,
              'Classification model',
              session.usedAi ? (session.aiModel ?? 'Legacy model') : 'Not run',
            ),
            _researchInfoRow(
              context,
              'Classification run',
              session.usedAi ? 'Completed' : 'Not run',
            ),
            _researchInfoRow(context, 'Incubation ages', session.dayRangeLabel),
            _researchInfoRow(
              context,
              'Occupied / empty',
              '${session.occupiedCount ?? '--'} / ${session.emptyCount ?? '--'}',
            ),
            _researchInfoRow(
              context,
              'Ready / analyzed / classified',
              '${session.readyEggCount} / ${session.analyzedSlotCount} / ${session.classifiedCount}',
            ),
            _researchInfoRow(
              context,
              'In review',
              session.inReviewCount.toString(),
            ),
            _researchInfoRow(
              context,
              'Ready without result',
              session.readyUnclassifiedCount.toString(),
            ),
            _researchInfoRow(
              context,
              'Ready slot numbers',
              numberList(session.readySlotNumbers),
            ),
            _researchInfoRow(
              context,
              'Analyzed slot numbers',
              numberList(session.analyzedSlotNumbers),
            ),
            _researchInfoRow(
              context,
              'Waiting slot numbers',
              numberList(session.waitingForDay5SlotNumbers),
            ),
            _researchInfoRow(
              context,
              'Unknown-age review slots',
              numberList(session.unknownAgeReviewSlotNumbers),
            ),
            _researchInfoRow(
              context,
              'Ready unresolved slots',
              numberList(session.readyUnclassifiedSlotNumbers),
            ),
            _researchInfoRow(
              context,
              'Temperature / humidity',
              '${decimal(session.temperature, ' C')} / ${decimal(session.humidity, '%')}',
            ),
            _researchInfoRow(
              context,
              'Water',
              session.waterLevel == null
                  ? '--'
                  : '${session.waterLevel}% (${session.waterLow == true ? 'LOW' : 'OK'})',
            ),
            _researchInfoRow(
              context,
              'Image / grid',
              '${session.imageWidth ?? '--'} x ${session.imageHeight ?? '--'} px | ${session.columnCount} x ${session.rowCount}',
            ),
            _researchInfoRow(
              context,
              'Column boundaries (cm)',
              session.colBoundaries.isEmpty
                  ? '--'
                  : session.colBoundaries
                        .map((value) => value.toStringAsFixed(2))
                        .join(', '),
            ),
            _researchInfoRow(
              context,
              'Row boundaries (cm)',
              session.rowBoundaries.isEmpty
                  ? '--'
                  : session.rowBoundaries
                        .map((value) => value.toStringAsFixed(2))
                        .join(', '),
            ),
            _researchInfoRow(
              context,
              'Capture / classification / total',
              '${duration(session.captureMs)} / ${duration(session.aiMs)} / ${duration(session.totalScanMs)}',
            ),
            _researchInfoRow(
              context,
              'P4 time trusted',
              yesNo(session.p4TimeTrusted),
            ),
            _researchInfoRow(
              context,
              'Expected occupied LEDs',
              session.expectedCandlingLedCount?.toString() ?? '--',
            ),
            _researchInfoRow(
              context,
              'Candling lights verified',
              yesNo(session.candlingLightsVerified),
            ),
            _researchInfoRow(
              context,
              'LED slot cache valid',
              yesNo(session.candlingLedCacheValid),
            ),
            _researchInfoRow(
              context,
              'Active candling LEDs',
              numberList(session.activeCandlingLeds),
            ),
            _researchInfoRow(
              context,
              'Missing candling LEDs',
              numberList(session.missingCandlingLeds),
            ),
            _researchInfoRow(
              context,
              'Saved detections',
              (session.detections?.length ?? 0).toString(),
            ),
          ],
        ),
      ],
    );
  }

  Widget _researchInfoRow(BuildContext context, String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 132,
            child: Text(
              label,
              style: TextStyle(
                color: _appSubtleTextColor(context),
                fontSize: 11,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          Expanded(
            child: SelectableText(
              value,
              style: TextStyle(
                color: _appTextColor(context),
                fontSize: 11,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPerSlotRecords(BuildContext context, EggSession session) {
    return Container(
      decoration: BoxDecoration(
        color: _appCardColor(context),
        borderRadius: BorderRadius.circular(16),
      ),
      clipBehavior: Clip.antiAlias,
      child: ExpansionTile(
        title: const Text(
          'All tray slots',
          style: TextStyle(fontSize: 12, fontWeight: FontWeight.w900),
        ),
        subtitle: Text(
          '${session.totalCells} tray slots | tap to inspect occupancy, age, classification and confidence',
          style: TextStyle(color: _appSubtleTextColor(context), fontSize: 10),
        ),
        children: List.generate(session.totalCells, (index) {
          final occupied = session.hasOccupancyData
              ? session.isOccupiedSlot(index)
              : null;
          final status = session.researchStatusForSlot(index);
          final day = session.dayForSlot(index);
          final placedAt = session.placedAtForSlot(index);
          final analyzed = session.wasSlotAnalyzed(index);
          final egg = index < session.eggData.length
              ? session.eggData[index]
              : EggData();
          final classified = egg.status != EggStatus.unknown;
          final color =
              session.isSlotWaitingForDay5(index) ||
                  session.isSlotReviewUnknownAge(index)
              ? const Color(0xFFFF9800)
              : _colorForEggStatus(egg.status);
          final bounds =
              egg.x1 == null ||
                  egg.y1 == null ||
                  egg.x2 == null ||
                  egg.y2 == null
              ? '--'
              : '${egg.x1},${egg.y1}-${egg.x2},${egg.y2} px';
          return Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
            decoration: BoxDecoration(
              border: Border(top: BorderSide(color: _appDividerColor(context))),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Slot ${index + 1} | Row ${index ~/ session.columnCount + 1}, Column ${index % session.columnCount + 1}',
                  style: TextStyle(
                    color: color,
                    fontSize: 12,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  '$status | Occupied ${occupied == null
                      ? 'not recorded'
                      : occupied
                      ? 'yes'
                      : 'no'} | Day ${day ?? '--'}',
                  style: TextStyle(
                    color: _appTextColor(context),
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  'Placed ${placedAt == null ? '--' : DateFormat('yyyy-MM-dd HH:mm:ss').format(placedAt)} | Classifier analyzed ${analyzed ? 'yes' : 'no'} | Confidence ${classified ? '${(egg.confidence * 100).toStringAsFixed(2)}%' : '--'} | Bounds $bounds',
                  style: TextStyle(
                    color: _appSubtleTextColor(context),
                    fontSize: 10,
                    height: 1.35,
                  ),
                ),
              ],
            ),
          );
        }),
      ),
    );
  }

  Widget _buildImageWithDetections(
    Uint8List imageBytes,
    List<Map<String, dynamic>>? detections, {
    int? imageWidth,
    int? imageHeight,
    List<double> colBoundaries = const [],
    List<double> rowBoundaries = const [],
  }) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final imgWidth = (imageWidth ?? 640).toDouble();
        final imgHeight = (imageHeight ?? 480).toDouble();

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
        final offsetX = (constraints.maxWidth - displayWidth) / 2;
        final offsetY = (constraints.maxHeight - displayHeight) / 2;
        final gridColBoundaries = colBoundaries.length >= 2
            ? colBoundaries
            : NumberedSlotGridPainter.defaultColBoundaries;
        final gridRowBoundaries = rowBoundaries.length >= 2
            ? rowBoundaries
            : NumberedSlotGridPainter.defaultRowBoundaries;

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
                if (_showGridOverlay)
                  Positioned(
                    left: offsetX,
                    top: offsetY,
                    width: displayWidth,
                    height: displayHeight,
                    child: IgnorePointer(
                      child: CustomPaint(
                        painter: NumberedSlotGridPainter(
                          colBoundaries: gridColBoundaries,
                          rowBoundaries: gridRowBoundaries,
                        ),
                      ),
                    ),
                  ),
                Positioned(
                  top: 8,
                  right: 8,
                  child: GestureDetector(
                    onTap: () =>
                        setState(() => _showGridOverlay = !_showGridOverlay),
                    child: Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: Colors.black.withAlpha(165),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(
                          color: _showGridOverlay
                              ? const Color(0xFF00E676)
                              : Colors.white24,
                        ),
                      ),
                      child: Icon(
                        _showGridOverlay
                            ? Icons.grid_on_rounded
                            : Icons.grid_off_rounded,
                        color: _showGridOverlay
                            ? const Color(0xFF00E676)
                            : Colors.white70,
                        size: 20,
                      ),
                    ),
                  ),
                ),
                if (detections != null && detections.isNotEmpty)
                  ...detections.map((det) {
                    final x1 = (det['x1'] as num).toDouble() * scaleX;
                    final y1 = (det['y1'] as num).toDouble() * scaleY;
                    final x2 = (det['x2'] as num).toDouble() * scaleX;
                    final y2 = (det['y2'] as num).toDouble() * scaleY;

                    final status = _eggStatusFromDetectionLabel(
                      det['label']?.toString() ?? '',
                    );
                    final color = _colorForEggStatus(status);

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

class NumberedSlotGridPainter extends CustomPainter {
  final List<double> colBoundaries;
  final List<double> rowBoundaries;
  final Color lineColor;
  final Color textColor;
  final Color labelColor;

  static const double trayWidthCm = 39.5;
  static const double trayHeightCm = 39.0;
  static const List<double> defaultColBoundaries = [
    8.0,
    12.0,
    15.0,
    17.9,
    20.8,
    23.6,
    26.6,
    29.6,
    33.2,
  ];
  static const List<double> defaultRowBoundaries = [
    2.3,
    7.9,
    12.8,
    17.1,
    21.7,
    26.2,
    30.5,
    36.2,
  ];

  const NumberedSlotGridPainter({
    required this.colBoundaries,
    required this.rowBoundaries,
    this.lineColor = const Color(0xFF00E676),
    this.textColor = Colors.white,
    this.labelColor = const Color(0xA6000000),
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (colBoundaries.length < 2 || rowBoundaries.length < 2) return;

    final linePaint = Paint()
      ..color = lineColor.withAlpha(170)
      ..strokeWidth = 1.2;
    final borderPaint = Paint()
      ..color = lineColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    final labelPaint = Paint()..color = labelColor;

    final workLeft = (colBoundaries.first / trayWidthCm) * size.width;
    final workRight = (colBoundaries.last / trayWidthCm) * size.width;
    final workTop = (rowBoundaries.first / trayHeightCm) * size.height;
    final workBottom = (rowBoundaries.last / trayHeightCm) * size.height;

    canvas.drawRect(
      Rect.fromLTRB(workLeft, workTop, workRight, workBottom),
      borderPaint,
    );

    for (var i = 1; i < colBoundaries.length - 1; i++) {
      final x = (colBoundaries[i] / trayWidthCm) * size.width;
      canvas.drawLine(Offset(x, workTop), Offset(x, workBottom), linePaint);
    }
    for (var i = 1; i < rowBoundaries.length - 1; i++) {
      final y = (rowBoundaries[i] / trayHeightCm) * size.height;
      canvas.drawLine(Offset(workLeft, y), Offset(workRight, y), linePaint);
    }

    final cols = colBoundaries.length - 1;
    final rows = rowBoundaries.length - 1;
    for (var row = 0; row < rows; row++) {
      for (var col = 0; col < cols; col++) {
        final slotNumber = row * cols + col + 1;
        final left = (colBoundaries[col] / trayWidthCm) * size.width;
        final right = (colBoundaries[col + 1] / trayWidthCm) * size.width;
        final top = (rowBoundaries[row] / trayHeightCm) * size.height;
        final bottom = (rowBoundaries[row + 1] / trayHeightCm) * size.height;
        final rect = Rect.fromLTRB(left, top, right, bottom);
        final fontSize = (math.min(rect.width, rect.height) * 0.24)
            .clamp(7.0, 14.0)
            .toDouble();
        final textPainter = TextPainter(
          text: TextSpan(
            text: '$slotNumber',
            style: TextStyle(
              color: textColor,
              fontSize: fontSize,
              fontWeight: FontWeight.w900,
            ),
          ),
          textDirection: ui.TextDirection.ltr,
        )..layout();

        final labelWidth = textPainter.width + 8;
        final labelHeight = textPainter.height + 4;
        final labelRect = RRect.fromRectAndRadius(
          Rect.fromCenter(
            center: rect.center,
            width: labelWidth,
            height: labelHeight,
          ),
          const Radius.circular(5),
        );
        canvas.drawRRect(labelRect, labelPaint);
        textPainter.paint(
          canvas,
          Offset(
            rect.center.dx - textPainter.width / 2,
            rect.center.dy - textPainter.height / 2,
          ),
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant NumberedSlotGridPainter oldDelegate) {
    return colBoundaries != oldDelegate.colBoundaries ||
        rowBoundaries != oldDelegate.rowBoundaries ||
        lineColor != oldDelegate.lineColor ||
        textColor != oldDelegate.textColor ||
        labelColor != oldDelegate.labelColor;
  }
}

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
      final isSelected = selectedBoundaryIndex == i && selectedBoundaryIsCol;
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
      final isSelected = selectedBoundaryIndex == i && !selectedBoundaryIsCol;
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

    if (selectedBoundaryIndex == 0 && selectedBoundaryIsCol) {
      canvas.drawLine(
        Offset(lineLeft, lineTop),
        Offset(lineLeft, lineBottom),
        Paint()
          ..color = const Color(0xFFFFD54F)
          ..strokeWidth = 2.5,
      );
    }
    if (selectedBoundaryIndex == colBoundaries.length - 1 &&
        selectedBoundaryIsCol) {
      canvas.drawLine(
        Offset(lineRight, lineTop),
        Offset(lineRight, lineBottom),
        Paint()
          ..color = const Color(0xFFFFD54F)
          ..strokeWidth = 2.5,
      );
    }
    if (selectedBoundaryIndex == 0 && !selectedBoundaryIsCol) {
      canvas.drawLine(
        Offset(lineLeft, lineTop),
        Offset(lineRight, lineTop),
        Paint()
          ..color = const Color(0xFFFFD54F)
          ..strokeWidth = 2.5,
      );
    }
    if (selectedBoundaryIndex == rowBoundaries.length - 1 &&
        !selectedBoundaryIsCol) {
      canvas.drawLine(
        Offset(lineLeft, lineBottom),
        Offset(lineRight, lineBottom),
        Paint()
          ..color = const Color(0xFFFFD54F)
          ..strokeWidth = 2.5,
      );
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
      canvas.drawLine(
        Offset(workLeft - 4, workTop + cornerLen),
        Offset(workLeft - 4, workTop - 4),
        cornerPaint,
      );
      canvas.drawLine(
        Offset(workLeft - 4, workTop - 4),
        Offset(workLeft + cornerLen, workTop - 4),
        cornerPaint,
      );
      // TR
      canvas.drawLine(
        Offset(workRight + 4, workTop + cornerLen),
        Offset(workRight + 4, workTop - 4),
        cornerPaint,
      );
      canvas.drawLine(
        Offset(workRight + 4, workTop - 4),
        Offset(workRight - cornerLen, workTop - 4),
        cornerPaint,
      );
      // BL
      canvas.drawLine(
        Offset(workLeft - 4, workBottom - cornerLen),
        Offset(workLeft - 4, workBottom + 4),
        cornerPaint,
      );
      canvas.drawLine(
        Offset(workLeft - 4, workBottom + 4),
        Offset(workLeft + cornerLen, workBottom + 4),
        cornerPaint,
      );
      // BR
      canvas.drawLine(
        Offset(workRight + 4, workBottom - cornerLen),
        Offset(workRight + 4, workBottom + 4),
        cornerPaint,
      );
      canvas.drawLine(
        Offset(workRight + 4, workBottom + 4),
        Offset(workRight - cornerLen, workBottom + 4),
        cornerPaint,
      );
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

class Esp32MjpegView extends StatefulWidget {
  final String uri;
  final double width;
  final double height;
  final BoxFit fit;
  final double fps;
  final VoidCallback? onFirstFrame;
  final void Function(Object error, StackTrace stackTrace)? onError;

  const Esp32MjpegView({
    required this.uri,
    required this.width,
    required this.height,
    this.fit = BoxFit.contain,
    this.fps = 12,
    this.onFirstFrame,
    this.onError,
    super.key,
  });

  @override
  State<Esp32MjpegView> createState() => _Esp32MjpegViewState();
}

class _Esp32MjpegViewState extends State<Esp32MjpegView> {
  static const List<int> _soi = [0xFF, 0xD8];
  static const List<int> _eoi = [0xFF, 0xD9];
  static const int _maxBufferBytes = 2 * 1024 * 1024;
  static const int _coldStartTimeoutMs = 30000;
  static const int _steadyFrameTimeoutMs = 3500;

  final List<int> _buffer = [];
  Socket? _socket;
  StreamSubscription<List<int>>? _subscription;
  Timer? _retryTimer;
  Timer? _stallTimer;
  Uint8List? _frame;
  Object? _error;
  bool _active = false;
  bool _connectionHasFrame = false;
  bool _reconnecting = false;
  int _retryAttempt = 0;
  int _connectionGeneration = 0;
  DateTime _lastFrameAt = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _lastCompleteFrameAt = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void didUpdateWidget(covariant Esp32MjpegView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.uri != widget.uri || oldWidget.fps != widget.fps) {
      _restart();
    }
  }

  @override
  void dispose() {
    _stop();
    super.dispose();
  }

  Future<void> _restart({bool keepLastFrame = false}) async {
    _retryTimer?.cancel();
    _retryTimer = null;
    _disconnect();
    if (!mounted) return;
    setState(() {
      if (!keepLastFrame) {
        _frame = null;
        _reconnecting = false;
        _error = null;
      } else {
        _reconnecting = true;
      }
    });
    _start();
  }

  void _stop() {
    _active = false;
    _retryTimer?.cancel();
    _retryTimer = null;
    _disconnect();
  }

  void _disconnect() {
    _connectionGeneration++;
    _stallTimer?.cancel();
    _stallTimer = null;
    _subscription?.cancel();
    _subscription = null;
    _socket?.destroy();
    _socket = null;
    _buffer.clear();
  }

  Future<void> _start() async {
    _active = true;
    final generation = ++_connectionGeneration;
    _connectionHasFrame = false;
    try {
      final uri = Uri.parse(widget.uri);
      final socket = await Socket.connect(
        uri.host,
        uri.hasPort ? uri.port : 80,
        timeout: const Duration(seconds: 15),
      );

      if (!_isCurrentConnection(generation)) {
        socket.destroy();
        return;
      }
      _socket = socket;
      socket.setOption(SocketOption.tcpNoDelay, true);
      _lastCompleteFrameAt = DateTime.now();
      _startStallWatchdog(generation);
      _subscription = socket.listen(
        (chunk) => _handleChunk(chunk, generation),
        onError: (Object error, StackTrace stackTrace) {
          _handleError(error, stackTrace, generation: generation);
        },
        onDone: () {
          _handleError(
            const HttpException('Stream connection ended'),
            StackTrace.current,
            generation: generation,
          );
        },
        cancelOnError: true,
      );

      final path = uri.path.isEmpty ? '/' : uri.path;
      final target = uri.hasQuery ? '$path?${uri.query}' : path;
      socket.write(
        'GET $target HTTP/1.1\r\n'
        'Host: ${uri.host}:${uri.port}\r\n'
        'Accept: multipart/x-mixed-replace\r\n'
        'Cache-Control: no-cache\r\n'
        'Connection: close\r\n\r\n',
      );
      await socket.flush();
    } catch (e, stackTrace) {
      _handleError(e, stackTrace, generation: generation);
    }
  }

  bool _isCurrentConnection(int generation) {
    return mounted && _active && generation == _connectionGeneration;
  }

  void _startStallWatchdog(int generation) {
    _stallTimer?.cancel();
    _stallTimer = Timer.periodic(const Duration(milliseconds: 500), (timer) {
      if (!_isCurrentConnection(generation)) {
        timer.cancel();
        return;
      }

      final stalledFor = DateTime.now().difference(_lastCompleteFrameAt);
      // A relay-powered OV5640 cold start includes power, sensor, and profile
      // settling before the S3 can write the first HTTP/JPEG bytes. Once a
      // complete frame arrives, retain the short watchdog for real stalls.
      final stallLimitMs = _connectionHasFrame
          ? _steadyFrameTimeoutMs
          : _coldStartTimeoutMs;
      if (stalledFor.inMilliseconds < stallLimitMs) return;
      _handleError(
        const HttpException('Stream stalled without a complete frame'),
        StackTrace.current,
        generation: generation,
      );
    });
  }

  void _handleError(Object error, StackTrace stackTrace, {int? generation}) {
    if (!_active ||
        (generation != null && generation != _connectionGeneration)) {
      return;
    }
    _disconnect();
    widget.onError?.call(error, stackTrace);
    if (!mounted) return;
    setState(() {
      _error = error;
      _reconnecting = true;
    });
    _scheduleRetry();
  }

  void _scheduleRetry() {
    if (!_active || !mounted || _retryTimer != null) return;
    final seconds = _retryAttempt == 0 ? 1 : (_retryAttempt == 1 ? 2 : 4);
    _retryAttempt++;
    _retryTimer = Timer(Duration(seconds: seconds), () {
      _retryTimer = null;
      if (!mounted || !_active) return;
      _restart(keepLastFrame: _frame != null);
    });
  }

  void _handleChunk(List<int> chunk, int generation) {
    if (!_isCurrentConnection(generation)) return;
    _buffer.addAll(chunk);

    if (_buffer.length > _maxBufferBytes) {
      _buffer.removeRange(0, _buffer.length - _maxBufferBytes);
    }

    Uint8List? newestFrame;
    while (true) {
      final soiIndex = _findSequence(_buffer, _soi, 0);
      if (soiIndex < 0) {
        if (_buffer.length > 1) {
          _buffer.removeRange(0, _buffer.length - 1);
        }
        break;
      }

      if (soiIndex > 0) {
        _buffer.removeRange(0, soiIndex);
      }

      final eoiIndex = _findSequence(_buffer, _eoi, 2);
      if (eoiIndex < 0) {
        break;
      }

      newestFrame = Uint8List.fromList(_buffer.sublist(0, eoiIndex + 2));
      _buffer.removeRange(0, eoiIndex + 2);
    }

    if (newestFrame == null || !_isCurrentConnection(generation)) return;

    final now = DateTime.now();
    _lastCompleteFrameAt = now;
    final isFirstFrameForConnection = !_connectionHasFrame;
    if (isFirstFrameForConnection) {
      _connectionHasFrame = true;
      widget.onFirstFrame?.call();
    }
    _retryAttempt = 0;

    final intervalMs = widget.fps <= 0 ? 0 : (1000 / widget.fps).round();
    if (isFirstFrameForConnection ||
        intervalMs == 0 ||
        now.difference(_lastFrameAt).inMilliseconds >= intervalMs) {
      _lastFrameAt = now;
      setState(() {
        _frame = newestFrame;
        _error = null;
        _reconnecting = false;
      });
    }
  }

  int _findSequence(List<int> bytes, List<int> sequence, int startIndex) {
    if (sequence.isEmpty || bytes.length < sequence.length) return -1;
    for (int i = startIndex; i <= bytes.length - sequence.length; i++) {
      var matched = true;
      for (int j = 0; j < sequence.length; j++) {
        if (bytes[i + j] != sequence[j]) {
          matched = false;
          break;
        }
      }
      if (matched) return i;
    }
    return -1;
  }

  @override
  Widget build(BuildContext context) {
    if (_frame != null) {
      return SizedBox(
        width: widget.width,
        height: widget.height,
        child: Stack(
          fit: StackFit.expand,
          children: [
            Image.memory(
              _frame!,
              width: widget.width,
              height: widget.height,
              fit: widget.fit,
              gaplessPlayback: true,
            ),
            if (_reconnecting)
              Positioned(
                top: 10,
                right: 10,
                child: IgnorePointer(
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.72),
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(color: Colors.orangeAccent),
                    ),
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        SizedBox(
                          width: 12,
                          height: 12,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.orangeAccent,
                          ),
                        ),
                        SizedBox(width: 7),
                        Text(
                          'Reconnecting',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        ),
      );
    }

    return Container(
      width: widget.width,
      height: widget.height,
      color: Colors.black,
      child: Center(
        child: _error == null
            ? const CircularProgressIndicator(color: Color(0xFF00E676))
            : Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(
                    Icons.videocam_off_rounded,
                    color: Colors.redAccent,
                    size: 34,
                  ),
                  const SizedBox(height: 10),
                  Text(
                    _reconnecting
                        ? 'Reconnecting stream...'
                        : 'Stream unavailable',
                    style: TextStyle(
                      color: Colors.white70,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 10),
                  TextButton.icon(
                    onPressed: () => _restart(),
                    icon: const Icon(Icons.refresh_rounded),
                    label: const Text('Retry'),
                  ),
                ],
              ),
      ),
    );
  }
}

// Data models
enum EggStatus { unknown, fertile, infertile }

EggStatus _eggStatusFromDetectionLabel(String label) {
  final normalized = label.toLowerCase().trim();
  if (normalized.contains('infertile') ||
      normalized.contains('nonfertile') ||
      normalized.contains('non-fertile') ||
      normalized.contains('non_fertile') ||
      normalized.contains('not_fertile') ||
      normalized.contains('not fertile')) {
    return EggStatus.infertile;
  }
  if (normalized.contains('fertile')) return EggStatus.fertile;
  return EggStatus.unknown;
}

Color _colorForEggStatus(EggStatus status) {
  switch (status) {
    case EggStatus.fertile:
      return const Color(0xFF00E676);
    case EggStatus.infertile:
      return Colors.red;
    case EggStatus.unknown:
      return Colors.amber;
  }
}

class EggData {
  EggStatus status = EggStatus.unknown;
  double confidence = 0.0;
  int? x1, y1, x2, y2;

  EggData();

  EggData copy() {
    return EggData()
      ..status = status
      ..confidence = confidence
      ..x1 = x1
      ..y1 = y1
      ..x2 = x2
      ..y2 = y2;
  }

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

class SensorSnapshot {
  final DateTime timestamp;
  final double? temperature; // main incubator (P4 SHT3X)
  final double? humidity; // main incubator
  final int? waterLevel;
  final bool? waterLow;
  final double? subTemperature; // sub incubator (relay node)
  final double? subHumidity; // sub incubator

  const SensorSnapshot({
    required this.timestamp,
    this.temperature,
    this.humidity,
    this.waterLevel,
    this.waterLow,
    this.subTemperature,
    this.subHumidity,
  });

  Map<String, dynamic> toJson() => {
    'timestamp': timestamp.toIso8601String(),
    'temperature': temperature,
    'humidity': humidity,
    'waterLevel': waterLevel,
    'waterLow': waterLow,
    'subTemperature': subTemperature,
    'subHumidity': subHumidity,
  };

  factory SensorSnapshot.fromJson(Map<String, dynamic> json) {
    return SensorSnapshot(
      timestamp: DateTime.parse(json['timestamp'] as String),
      temperature: json['temperature'] != null
          ? (json['temperature'] as num).toDouble()
          : null,
      humidity: json['humidity'] != null
          ? (json['humidity'] as num).toDouble()
          : null,
      waterLevel: (json['waterLevel'] as num?)?.toInt(),
      waterLow: json['waterLow'] as bool?,
      subTemperature: json['subTemperature'] != null
          ? (json['subTemperature'] as num).toDouble()
          : null,
      subHumidity: json['subHumidity'] != null
          ? (json['subHumidity'] as num).toDouble()
          : null,
    );
  }
}

class EggCounterRecord {
  final int id;
  final DateTime timestamp;
  final int? p4ScanEpoch;
  final int count;
  final int? eggDay;
  final List<bool> occupiedSlots;
  final List<int?> slotDays;
  final List<DateTime?> placedAt;

  EggCounterRecord({
    required this.id,
    required this.timestamp,
    required this.p4ScanEpoch,
    required this.count,
    required this.eggDay,
    required this.occupiedSlots,
    required this.slotDays,
    required this.placedAt,
  });

  DateTime? get p4ScanTime => p4ScanEpoch == null
      ? null
      : DateTime.fromMillisecondsSinceEpoch(p4ScanEpoch! * 1000);

  List<int> get occupiedSlotNumbers {
    final slots = <int>[];
    for (var i = 0; i < occupiedSlots.length; i++) {
      if (occupiedSlots[i]) slots.add(i + 1);
    }
    return slots;
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'timestamp': timestamp.toIso8601String(),
    'p4ScanEpoch': p4ScanEpoch,
    'count': count,
    'eggDay': eggDay,
    'occupiedSlots': occupiedSlots,
    'slotDays': slotDays,
    'placedAt': placedAt.map((value) => value?.toIso8601String()).toList(),
  };

  factory EggCounterRecord.fromJson(Map<String, dynamic> json) {
    return EggCounterRecord(
      id:
          (json['id'] as num?)?.toInt() ??
          DateTime.now().millisecondsSinceEpoch,
      timestamp: _dateFromJson(json['timestamp']) ?? DateTime.now(),
      p4ScanEpoch: (json['p4ScanEpoch'] as num?)?.toInt(),
      count: (json['count'] as num?)?.toInt() ?? 0,
      eggDay: (json['eggDay'] as num?)?.toInt(),
      occupiedSlots: _boolListFromJson(json['occupiedSlots']),
      slotDays: _nullableIntListFromJson(json['slotDays']),
      placedAt: _nullableDateListFromJson(json['placedAt']),
    );
  }

  static List<bool> _boolListFromJson(dynamic raw) {
    if (raw is! List) return const [];
    return raw.map((value) => value == true).toList();
  }

  static List<int?> _nullableIntListFromJson(dynamic raw) {
    if (raw is! List) return const [];
    return raw.map((value) => (value as num?)?.toInt()).toList();
  }

  static List<DateTime?> _nullableDateListFromJson(dynamic raw) {
    if (raw is! List) return const [];
    return raw.map(_dateFromJson).toList();
  }

  static DateTime? _dateFromJson(dynamic value) {
    if (value == null) return null;
    if (value is String) return DateTime.tryParse(value);
    if (value is num) {
      var epoch = value.toInt();
      if (epoch <= 0) return null;
      if (epoch > 1000000000000) epoch ~/= 1000;
      return DateTime.fromMillisecondsSinceEpoch(epoch * 1000);
    }
    return null;
  }
}

class EggSession {
  final int id;
  final DateTime timestamp;
  final int fertileCount;
  final int infertileCount;
  final double? temperature;
  final double? humidity;
  final int? waterLevel;
  final bool? waterLow;
  final int? eggDay;
  final int? p4EggCount;
  final List<bool> occupiedSlots;
  final List<int?> slotDays;
  final List<DateTime?> slotPlacedAt;
  final List<int> analyzedSlots;
  final Uint8List? imageBytes;
  final int? imageWidth;
  final int? imageHeight;
  final List<EggData> eggData;
  final bool usedAi;
  final List<Map<String, dynamic>>? detections;
  final int columnCount;
  final int rowCount;
  final List<double> colBoundaries;
  final List<double> rowBoundaries;
  final String? aiModel;
  final int? captureMs;
  final int? aiMs;
  final int? totalScanMs;
  final String captureEndpoint;
  final bool? p4TimeTrusted;
  final int? expectedCandlingLedCount;
  final bool? candlingLightsVerified;
  final bool? candlingLedCacheValid;
  final List<int> activeCandlingLeds;
  final List<int> missingCandlingLeds;

  static const int gridCols = 8;
  static const int gridRows = 7;

  EggSession({
    required this.id,
    required this.timestamp,
    required this.fertileCount,
    required this.infertileCount,
    required this.temperature,
    required this.humidity,
    this.waterLevel,
    this.waterLow,
    this.eggDay,
    this.p4EggCount,
    this.occupiedSlots = const [],
    this.slotDays = const [],
    this.slotPlacedAt = const [],
    this.analyzedSlots = const [],
    this.imageBytes,
    this.imageWidth,
    this.imageHeight,
    required this.eggData,
    this.usedAi = false,
    this.detections,
    this.columnCount = gridCols,
    this.rowCount = gridRows,
    this.colBoundaries = const [],
    this.rowBoundaries = const [],
    this.aiModel,
    this.captureMs,
    this.aiMs,
    this.totalScanMs,
    this.captureEndpoint = '/capture',
    this.p4TimeTrusted,
    this.expectedCandlingLedCount,
    this.candlingLightsVerified,
    this.candlingLedCacheValid,
    this.activeCandlingLeds = const [],
    this.missingCandlingLeds = const [],
  });

  int get totalCells => columnCount * rowCount;

  bool get hasOccupancyData => occupiedSlots.length >= totalCells;

  int? get occupiedCount {
    if (!hasOccupancyData) return p4EggCount;
    return occupiedSlots.take(totalCells).where((hasEgg) => hasEgg).length;
  }

  bool isOccupiedSlot(int index) =>
      index >= 0 && index < occupiedSlots.length && occupiedSlots[index];

  int? dayForSlot(int index) {
    if (index >= 0 && index < slotDays.length) return slotDays[index];
    if (slotDays.isEmpty) return eggDay;
    return null;
  }

  String get dayRangeLabel {
    if (!hasOccupancyData) {
      return eggDay == null ? 'Day not recorded' : 'Day $eggDay';
    }
    final days = <int>[
      for (var index = 0; index < totalCells; index++)
        if (isOccupiedSlot(index) && dayForSlot(index) != null)
          dayForSlot(index)!,
    ];
    if (days.isEmpty) return 'Day not recorded';
    days.sort();
    return days.first == days.last
        ? 'Day ${days.first}'
        : 'Days ${days.first}-${days.last}';
  }

  DateTime? placedAtForSlot(int index) =>
      index >= 0 && index < slotPlacedAt.length ? slotPlacedAt[index] : null;

  bool isSlotReady(int index) {
    if (!isOccupiedSlot(index)) return false;
    final day = dayForSlot(index);
    return day != null && day >= 5 && day <= 10;
  }

  bool isSlotWaitingForDay5(int index) {
    if (!isOccupiedSlot(index) || statusForSlot(index) != EggStatus.unknown) {
      return false;
    }
    final day = dayForSlot(index);
    return day != null && day < 5;
  }

  bool isSlotReviewUnknownAge(int index) =>
      isOccupiedSlot(index) &&
      statusForSlot(index) == EggStatus.unknown &&
      dayForSlot(index) == null;

  bool wasSlotAnalyzed(int index) => analyzedSlots.contains(index);

  EggStatus statusForSlot(int index) => index >= 0 && index < eggData.length
      ? eggData[index].status
      : EggStatus.unknown;

  double confidenceForSlot(int index) =>
      index >= 0 && index < eggData.length ? eggData[index].confidence : 0.0;

  String researchStatusForSlot(int index) {
    if (hasOccupancyData && !isOccupiedSlot(index)) return 'Empty';
    if (statusForSlot(index) == EggStatus.fertile) return 'Fertile';
    if (statusForSlot(index) == EggStatus.infertile) return 'Infertile';
    if (!hasOccupancyData) return 'Occupancy not recorded';
    if (isSlotWaitingForDay5(index)) return 'In review - waiting for Day 5';
    if (isSlotReviewUnknownAge(index)) {
      return 'In review - incubation age unavailable';
    }
    if (isSlotReady(index)) return 'Ready (5-10) - classification not run';
    return 'In review - outside Day 5-10 model window';
  }

  List<int> get readySlotNumbers => [
    for (var i = 0; i < totalCells; i++)
      if (isSlotReady(i)) i + 1,
  ];

  List<int> get analyzedSlotNumbers => [
    for (final index in analyzedSlots)
      if (index >= 0 && index < totalCells) index + 1,
  ];

  List<int> get waitingForDay5SlotNumbers => [
    for (var i = 0; i < totalCells; i++)
      if (isSlotWaitingForDay5(i)) i + 1,
  ];

  List<int> get unknownAgeReviewSlotNumbers => [
    for (var i = 0; i < totalCells; i++)
      if (isSlotReviewUnknownAge(i)) i + 1,
  ];

  List<int> get readyUnclassifiedSlotNumbers => [
    for (var i = 0; i < totalCells; i++)
      if (isSlotReady(i) && statusForSlot(i) == EggStatus.unknown) i + 1,
  ];

  int get readyEggCount => readySlotNumbers.length;

  int get waitingForDay5Count => waitingForDay5SlotNumbers.length;

  int get unknownAgeReviewCount => unknownAgeReviewSlotNumbers.length;

  int get inReviewCount => [
    for (var i = 0; i < totalCells; i++)
      if (isOccupiedSlot(i) && statusForSlot(i) == EggStatus.unknown) i,
  ].length;

  int get analyzedSlotCount => analyzedSlotNumbers.length;

  int get classifiedCount => fertileCount + infertileCount;

  int get readyUnclassifiedCount => readyUnclassifiedSlotNumbers.length;

  int? get emptyCount =>
      hasOccupancyData ? totalCells - (occupiedCount ?? 0) : null;

  Map<String, dynamic> toJson() => {
    'id': id,
    'timestamp': timestamp.toIso8601String(),
    'fertileCount': fertileCount,
    'infertileCount': infertileCount,
    'temperature': temperature,
    'humidity': humidity,
    'waterLevel': waterLevel,
    'waterLow': waterLow,
    'eggDay': eggDay,
    'p4EggCount': p4EggCount,
    'occupiedSlots': occupiedSlots,
    'slotDays': slotDays,
    'slotPlacedAt': slotPlacedAt
        .map((value) => value?.toIso8601String())
        .toList(),
    'analyzedSlots': analyzedSlots,
    'imageBytes': imageBytes != null ? base64Encode(imageBytes!) : null,
    'imageWidth': imageWidth,
    'imageHeight': imageHeight,
    'eggData': eggData.map((e) => e.toJson()).toList(),
    'usedAi': usedAi,
    'detections': detections,
    'columnCount': columnCount,
    'rowCount': rowCount,
    'colBoundaries': colBoundaries,
    'rowBoundaries': rowBoundaries,
    'aiModel': aiModel,
    'captureMs': captureMs,
    'aiMs': aiMs,
    'totalScanMs': totalScanMs,
    'captureEndpoint': captureEndpoint,
    'p4TimeTrusted': p4TimeTrusted,
    'expectedCandlingLedCount': expectedCandlingLedCount,
    'candlingLightsVerified': candlingLightsVerified,
    'candlingLedCacheValid': candlingLedCacheValid,
    'activeCandlingLeds': activeCandlingLeds,
    'missingCandlingLeds': missingCandlingLeds,
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
      waterLevel: (json['waterLevel'] as num?)?.toInt(),
      waterLow: json['waterLow'] as bool?,
      eggDay: (json['eggDay'] as num?)?.toInt(),
      p4EggCount: (json['p4EggCount'] as num?)?.toInt(),
      occupiedSlots:
          (json['occupiedSlots'] as List?)
              ?.map((value) => value == true)
              .toList() ??
          const [],
      slotDays:
          (json['slotDays'] as List?)
              ?.map((value) => (value as num?)?.toInt())
              .toList() ??
          const [],
      slotPlacedAt: _nullableDateListFromJson(json['slotPlacedAt']),
      analyzedSlots: _intListFromJson(json['analyzedSlots']),
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
      columnCount: (json['columnCount'] as num?)?.toInt() ?? gridCols,
      rowCount: (json['rowCount'] as num?)?.toInt() ?? gridRows,
      colBoundaries: _doubleListFromJson(json['colBoundaries']),
      rowBoundaries: _doubleListFromJson(json['rowBoundaries']),
      aiModel: json['aiModel'] as String?,
      captureMs: (json['captureMs'] as num?)?.toInt(),
      aiMs: (json['aiMs'] as num?)?.toInt(),
      totalScanMs: (json['totalScanMs'] as num?)?.toInt(),
      captureEndpoint: json['captureEndpoint']?.toString() ?? '/capture',
      p4TimeTrusted: json['p4TimeTrusted'] as bool?,
      expectedCandlingLedCount: (json['expectedCandlingLedCount'] as num?)
          ?.toInt(),
      candlingLightsVerified: json['candlingLightsVerified'] as bool?,
      candlingLedCacheValid: json['candlingLedCacheValid'] as bool?,
      activeCandlingLeds: _intListFromJson(json['activeCandlingLeds']),
      missingCandlingLeds: _intListFromJson(json['missingCandlingLeds']),
    );
  }

  static List<int> _intListFromJson(dynamic raw) {
    if (raw is! List) return const [];
    return raw
        .map((value) => (value as num?)?.toInt())
        .whereType<int>()
        .toList();
  }

  static List<DateTime?> _nullableDateListFromJson(dynamic raw) {
    if (raw is! List) return const [];
    return raw.map((value) {
      if (value == null) return null;
      if (value is String) return DateTime.tryParse(value);
      if (value is num) {
        var epoch = value.toInt();
        if (epoch <= 0) return null;
        if (epoch > 1000000000000) epoch ~/= 1000;
        return DateTime.fromMillisecondsSinceEpoch(epoch * 1000);
      }
      return null;
    }).toList();
  }

  static List<double> _doubleListFromJson(dynamic raw) {
    if (raw is! List) return const [];
    return raw
        .map((value) => value is num ? value.toDouble() : null)
        .whereType<double>()
        .toList();
  }
}
