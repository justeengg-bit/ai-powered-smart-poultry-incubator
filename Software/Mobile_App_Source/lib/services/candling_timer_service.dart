import 'package:shared_preferences/shared_preferences.dart';

class CandlingTimerService {
  static const String _keyInterval = 'candling_interval_days';
  static const String _keyLastSessionDate = 'last_candling_date';
  static const String _keyEnabled = 'candling_timer_enabled';
  static const String _keyTempMin = 'temp_min_threshold';
  static const String _keyTempMax = 'temp_max_threshold';
  static const String _keyHumMin = 'hum_min_threshold';
  static const String _keyHumMax = 'hum_max_threshold';
  static const String _keyAlertsEnabled = 'alerts_enabled';

  // Default values
  static const int defaultInterval = 3; // days
  static const double defaultTempMin = 37.0;
  static const double defaultTempMax = 38.0;
  static const double defaultHumMin = 50.0;
  static const double defaultHumMax = 60.0;

  Future<void> setIntervalDays(int days) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_keyInterval, days);
  }

  Future<int> getIntervalDays() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(_keyInterval) ?? defaultInterval;
  }

  Future<void> setLastSessionDate(DateTime date) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyLastSessionDate, date.toIso8601String());
  }

  Future<DateTime?> getLastSessionDate() async {
    final prefs = await SharedPreferences.getInstance();
    final str = prefs.getString(_keyLastSessionDate);
    if (str == null) return null;
    try {
      return DateTime.parse(str);
    } catch (_) {
      return null;
    }
  }

  Future<DateTime?> calculateNextDueDate() async {
    final last = await getLastSessionDate();
    final interval = await getIntervalDays();
    if (last == null) return null;
    return last.add(Duration(days: interval));
  }

  Future<void> setTimerEnabled(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyEnabled, enabled);
  }

  Future<bool> isTimerEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_keyEnabled) ?? false;
  }

  // Temperature/Humidity thresholds
  Future<void> setTempMin(double min) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_keyTempMin, min);
  }

  Future<double> getTempMin() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getDouble(_keyTempMin) ?? defaultTempMin;
  }

  Future<void> setTempMax(double max) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_keyTempMax, max);
  }

  Future<double> getTempMax() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getDouble(_keyTempMax) ?? defaultTempMax;
  }

  Future<void> setHumMin(double min) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_keyHumMin, min);
  }

  Future<double> getHumMin() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getDouble(_keyHumMin) ?? defaultHumMin;
  }

  Future<void> setHumMax(double max) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_keyHumMax, max);
  }

  Future<double> getHumMax() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getDouble(_keyHumMax) ?? defaultHumMax;
  }

  Future<void> setAlertsEnabled(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyAlertsEnabled, enabled);
  }

  Future<bool> areAlertsEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_keyAlertsEnabled) ?? true;
  }

  bool isOutsideThreshold({
    required double? temp,
    required double? hum,
    required double tempMin,
    required double tempMax,
    required double humMin,
    required double humMax,
  }) {
    if (temp == null || hum == null) return false;
    return temp < tempMin || temp > tempMax || hum < humMin || hum > humMax;
  }
}
