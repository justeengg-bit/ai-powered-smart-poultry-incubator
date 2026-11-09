/// Notes for the ESP32-S3 + ESP32-P4 integration.
///
/// The real implementation now lives inside `lib/main.dart` because the app is
/// still using a single large stateful widget. Keeping this file as valid Dart
/// prevents analyzer failures while preserving the endpoint map for reference.
///
/// Responsibility split:
/// - Mobile app live preview uses `GET /stream`.
/// - Mobile app candling/fertile-infertile classification uses `GET /capture`.
/// - Grid customization and P4 egg-count capture use `GET /capturep4`.
/// - P4 AI only detects egg presence/count and exposes slot/day data through
///   `POST /p4/get_slots`.
/// - P4 owns the main bulb relay on GPIO33 and reports its state to S3.
/// - S3 combines P4 temp/humidity/bulb with local water-level safety data
///   through `POST /sensor`.
/// - Mobile AI publishes final Day-7-to-Day-14 Fertile/Infertile results through
///   `POST /p4/set_fertility_results`; P4 only persists and displays them.
/// - A thresholded model result needs no second farmer tap or date confirmation.
///   Date/time editing remains available in the dataset collector as metadata.
/// - Stream/image endpoints stay GET; JSON data/control endpoints prefer POST.
class IntegrationMethodsNotes {
  const IntegrationMethodsNotes();

  static const s3BaseUrl = 'http://192.168.4.1';
  static const p4ProxyBaseUrl = 'http://192.168.4.1/p4';

  static const s3Endpoints = [
    '/stream',
    '/capture',
    '/capturep4',
    '/sensor',
    '/sensordata',
    '/actuators',
    '/humidifier?state=auto',
  ];

  static const p4ProxyEndpoints = [
    '/p4/get_slots',
    '/p4/get_infertile',
    '/p4/candling_start',
    '/p4/candling_stop',
    '/p4/set_infertile',
    '/p4/set_fertility_results',
    '/p4/clear_infertile',
    '/p4/blink_infertile',
    '/p4/grid_config',
    '/p4/get_grid_config',
    '/p4/reset_grid_config',
  ];
}
