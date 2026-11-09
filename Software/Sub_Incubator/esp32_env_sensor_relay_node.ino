#include <WiFi.h>
#include <HTTPClient.h>
#include <Wire.h>
#include <Adafruit_SHT31.h>
#include <math.h>

// ESP32 station that joins the ESP32-S3 camera AP and posts climate data.
// S3 AP firmware defaults from esp32_cam_no_ui.ino:
// SSID: AI_CANDLING, password: thesis123, IP: 192.168.4.1
const char* WIFI_SSID = "AI_CANDLING";
const char* WIFI_PASSWORD = "thesis123";
// Sub-incubator posts to its own S3 endpoint so it never collides with the
// P4 main-incubator climate that arrives on /sensordata.
const char* S3_SENSOR_URL = "http://192.168.4.1/subsensordata";

// Pin map for the DIYMORE ESP32-CAM (camera ribbon NOT plugged in).
// NOTE: GPIO16/17 are reserved for PSRAM on this board -- do NOT use for I2C.
// 21 and 13 are free, bidirectional pins that worked for the SHT3x.
#define I2C_SDA_PIN 21
#define I2C_SCL_PIN 13
#define BULB_RELAY_PIN 25
#define HUMIDIFIER_RELAY_PIN 32

// Water level sensor analog output. Monitoring only; no relay interlock.
#define WATER_LEVEL_ENABLED 1
#define WATER_LEVEL_PIN 37

// Most relay modules are active LOW. Set to 0 if your module turns ON with HIGH.
#define RELAY_ACTIVE_LOW 0

const uint8_t RELAY_ON_LEVEL = RELAY_ACTIVE_LOW ? LOW : HIGH;
const uint8_t RELAY_OFF_LEVEL = RELAY_ACTIVE_LOW ? HIGH : LOW;

// Lockdown sub-incubator targets: maintain 37.7-38.0 C, 65-75% RH.
const float BULB_ON_BELOW_C = 37.7f;
const float BULB_OFF_AT_OR_ABOVE_C = 38.0f;
// Humidity-only hysteresis; retain the relay state between these thresholds.
const float HUMIDIFIER_ON_BELOW_RH = 65.0f;
const float HUMIDIFIER_OFF_AT_OR_ABOVE_RH = 75.0f;

// Calibrate these with Serial Monitor dry/wet raw readings.
const int WATER_DRY_RAW = 0;      // measured dry (no water) -> 0%
const int WATER_WET_RAW = 2300;   // measured fully submerged -> 100%
const int WATER_LOW_PERCENT = 5;

const unsigned long READ_INTERVAL_MS = 2000UL;
const unsigned long POST_INTERVAL_MS = 5000UL;
const unsigned long WIFI_CONNECT_TIMEOUT_MS = 12000UL;
const unsigned long WIFI_DRIVER_SETTLE_MS = 350UL;
const unsigned long WIFI_RETRY_DELAY_MS = 2000UL;
const unsigned long WIFI_RADIO_OFF_MS = 750UL;
const uint8_t WIFI_FAILURES_BEFORE_RADIO_RESET = 3;
const uint8_t POST_FAILURES_BEFORE_WIFI_RECOVERY = 4;
const unsigned long SENSOR_STALE_SAFE_MS = 15000UL;

Adafruit_SHT31 sht31 = Adafruit_SHT31();

struct ClimateReading {
  float tempC = 0.0f;
  float humidityRh = 0.0f;
  bool tempValid = false;
  bool humidityValid = false;
  int waterRaw = 0;
  int waterLevel = 0;
  bool waterLow = true;
  bool waterValid = false;  // Diagnostic only; does not control the humidifier.
};

ClimateReading latest;
bool shtReady = false;
bool bulbOn = false;
bool humidifierOn = false;
unsigned long lastReadMs = 0;
unsigned long lastPostMs = 0;
unsigned long lastTempOkMs = 0;
unsigned long lastHumOkMs = 0;

enum WifiRecoveryPhase : uint8_t {
  WIFI_PHASE_CONNECTING,
  WIFI_PHASE_CONNECTED,
  WIFI_PHASE_DISCONNECTING,
  WIFI_PHASE_WAIT_RETRY,
  WIFI_PHASE_RADIO_OFF
};

WifiRecoveryPhase wifiPhase = WIFI_PHASE_WAIT_RETRY;
unsigned long wifiPhaseStartedMs = 0;
uint8_t consecutiveWifiFailures = 0;
uint8_t consecutivePostTransportFailures = 0;
bool wifiRecoveryRequested = false;
bool postAfterReconnect = false;

void initRelayOutputOff(uint8_t pin) {
  digitalWrite(pin, RELAY_OFF_LEVEL);
  pinMode(pin, RELAY_OFF_LEVEL == HIGH ? INPUT_PULLUP : INPUT_PULLDOWN);
  delay(2);
  pinMode(pin, OUTPUT);
  digitalWrite(pin, RELAY_OFF_LEVEL);
}

void setRelay(uint8_t pin, bool on) {
  digitalWrite(pin, on ? RELAY_ON_LEVEL : RELAY_OFF_LEVEL);
}

void setBulb(bool on) {
  if (bulbOn == on) return;
  bulbOn = on;
  setRelay(BULB_RELAY_PIN, bulbOn);
  Serial.printf("[BULB] %s\n", bulbOn ? "ON" : "OFF");
}

void setHumidifier(bool on) {
  if (humidifierOn == on) return;
  humidifierOn = on;
  setRelay(HUMIDIFIER_RELAY_PIN, humidifierOn);
  Serial.printf("[HUMIDIFIER] %s\n", humidifierOn ? "ON" : "OFF");
}

bool beginShtSensor() {
  if (sht31.begin(0x44)) {
    Serial.println("[SHT] Found SHT3x at 0x44");
    sht31.heater(false);
    return true;
  }

  if (sht31.begin(0x45)) {
    Serial.println("[SHT] Found SHT3x at 0x45");
    sht31.heater(false);
    return true;
  }

  Serial.println("[SHT] Not found. Check SDA/SCL, VCC, GND, and sensor address.");
  return false;
}

int waterPercentFromRaw(int raw) {
  long percent;
  if (WATER_WET_RAW >= WATER_DRY_RAW) {
    percent = map(raw, WATER_DRY_RAW, WATER_WET_RAW, 0, 100);
  } else {
    percent = map(raw, WATER_WET_RAW, WATER_DRY_RAW, 100, 0);
  }
  return constrain((int)percent, 0, 100);
}

void readSensors() {
#if WATER_LEVEL_ENABLED
  latest.waterRaw = analogRead(WATER_LEVEL_PIN);
  latest.waterLevel = waterPercentFromRaw(latest.waterRaw);
  latest.waterLow = latest.waterLevel < WATER_LOW_PERCENT;
  // Near-zero readings are flagged for diagnostics, not used as an interlock.
  latest.waterValid = latest.waterRaw > 5;
#else
  // No water sensor compiled in; humidity control remains independent.
  latest.waterRaw = -1;
  latest.waterLevel = 0;
  latest.waterLow = true;
  latest.waterValid = false;
#endif

  latest.tempValid = false;
  latest.humidityValid = false;

  if (!shtReady) {
    shtReady = beginShtSensor();
  }

  if (shtReady) {
    const float temp = sht31.readTemperature();
    const float hum = sht31.readHumidity();

    if (!isnan(temp)) {
      latest.tempC = temp;
      latest.tempValid = true;
      lastTempOkMs = millis();
    }

    if (!isnan(hum)) {
      latest.humidityRh = hum;
      latest.humidityValid = true;
      lastHumOkMs = millis();
    }
  }

  // --- Water calibration helper: track lowest (dry) and highest (wet) raw ---
  static int waterRawMin = 4095;
  static int waterRawMax = 0;
  if (latest.waterRaw < waterRawMin) waterRawMin = latest.waterRaw;
  if (latest.waterRaw > waterRawMax) waterRawMax = latest.waterRaw;

  Serial.printf(
      "[READ] T=%s%.1fC H=%s%.1f%% waterRaw=%d water=%d%% low=%s valid=%s  | CAL min(dry)=%d max(wet)=%d\n",
      latest.tempValid ? "" : "?",
      latest.tempC,
      latest.humidityValid ? "" : "?",
      latest.humidityRh,
      latest.waterRaw,
      latest.waterLevel,
      latest.waterLow ? "true" : "false",
      latest.waterValid ? "true" : "false",
      waterRawMin,
      waterRawMax);
}

void updateActuators() {
  const unsigned long now = millis();
  const bool tempFresh = lastTempOkMs > 0 && (now - lastTempOkMs) <= SENSOR_STALE_SAFE_MS;
  const bool humFresh = lastHumOkMs > 0 && (now - lastHumOkMs) <= SENSOR_STALE_SAFE_MS;

  if (!tempFresh) {
    setBulb(false);
  } else if (!bulbOn && latest.tempC < BULB_ON_BELOW_C) {
    setBulb(true);
  } else if (bulbOn && latest.tempC >= BULB_OFF_AT_OR_ABOVE_C) {
    setBulb(false);
  }

  if (!humFresh) {
    setHumidifier(false);
  } else if (!humidifierOn && latest.humidityRh < HUMIDIFIER_ON_BELOW_RH) {
    setHumidifier(true);
  } else if (humidifierOn && latest.humidityRh >= HUMIDIFIER_OFF_AT_OR_ABOVE_RH) {
    setHumidifier(false);
  }
}

void appendCommaIfNeeded(String& body, bool& hasField) {
  if (hasField) body += ',';
  hasField = true;
}

void appendJsonFloat(String& body, bool& hasField, const char* key, float value, int decimals) {
  appendCommaIfNeeded(body, hasField);
  body += '"';
  body += key;
  body += "\":";
  body += String(value, decimals);
}

void appendJsonInt(String& body, bool& hasField, const char* key, int value) {
  appendCommaIfNeeded(body, hasField);
  body += '"';
  body += key;
  body += "\":";
  body += String(value);
}

void appendJsonBool(String& body, bool& hasField, const char* key, bool value) {
  appendCommaIfNeeded(body, hasField);
  body += '"';
  body += key;
  body += "\":";
  body += (value ? "true" : "false");
}

String buildSensorJson() {
  String body;
  body.reserve(192);
  body = "{";
  bool hasField = false;

  if (latest.tempValid) {
    appendJsonFloat(body, hasField, "temp", latest.tempC, 2);
  }
  if (latest.humidityValid) {
    appendJsonFloat(body, hasField, "hum", latest.humidityRh, 2);
  }
  appendJsonBool(body, hasField, "humValid", latest.humidityValid);
#if WATER_LEVEL_ENABLED
  appendJsonInt(body, hasField, "waterRaw", latest.waterRaw);
  appendJsonInt(body, hasField, "waterLevel", latest.waterLevel);
  appendJsonBool(body, hasField, "waterLow", latest.waterLow);
#endif
  appendJsonBool(body, hasField, "bulb", bulbOn);
  appendJsonBool(body, hasField, "humidifier", humidifierOn);
  appendJsonInt(body, hasField, "uptimeMs", (int)millis());

  body += "}";
  return body;
}

const char* wifiStatusName(wl_status_t status) {
  switch (status) {
    case WL_IDLE_STATUS: return "IDLE";
    case WL_NO_SSID_AVAIL: return "NO_SSID";
    case WL_SCAN_COMPLETED: return "SCAN_COMPLETE";
    case WL_CONNECTED: return "CONNECTED";
    case WL_CONNECT_FAILED: return "CONNECT_FAILED";
    case WL_CONNECTION_LOST: return "CONNECTION_LOST";
    case WL_DISCONNECTED: return "DISCONNECTED";
    default: return "UNKNOWN";
  }
}

void configureWifiStation() {
  WiFi.persistent(false);
  WiFi.mode(WIFI_STA);
  WiFi.setSleep(false);
  // This sketch owns all retries. Disabling the driver's independent retry
  // prevents it from racing our disconnect/settle/begin state machine.
  WiFi.setAutoReconnect(false);
}

void beginWifiAttempt(const char* reason) {
  configureWifiStation();
  const wl_status_t beginStatus = WiFi.begin(WIFI_SSID, WIFI_PASSWORD);
  wifiPhase = WIFI_PHASE_CONNECTING;
  wifiPhaseStartedMs = millis();
  Serial.printf(
      "[WIFI] Attempt %u: %s; WiFi.begin=%s. Local control continues.\n",
      (unsigned int)consecutiveWifiFailures + 1,
      reason,
      wifiStatusName(beginStatus));
}

void startWifi() {
  consecutiveWifiFailures = 0;
  consecutivePostTransportFailures = 0;
  wifiRecoveryRequested = false;
  beginWifiAttempt("startup");
}

void scheduleWifiRecovery(const char* reason) {
  if (wifiPhase == WIFI_PHASE_DISCONNECTING ||
      wifiPhase == WIFI_PHASE_WAIT_RETRY ||
      wifiPhase == WIFI_PHASE_RADIO_OFF) {
    return;
  }

  if (consecutiveWifiFailures < 255) {
    consecutiveWifiFailures++;
  }
  Serial.printf(
      "[WIFI] Recovery scheduled (%s), failure %u.\n",
      reason,
      (unsigned int)consecutiveWifiFailures);

  // disconnect() is asynchronous. Wait in WIFI_PHASE_DISCONNECTING before
  // the next begin() instead of issuing both calls back-to-back.
  WiFi.setAutoReconnect(false);
  WiFi.disconnect(false, false);
  wifiPhase = WIFI_PHASE_DISCONNECTING;
  wifiPhaseStartedMs = millis();
}

void startWifiRadioReset() {
  Serial.println("[WIFI] Repeated failures: cycling the station radio.");
  WiFi.setAutoReconnect(false);
  WiFi.disconnect(true, false);  // radio off, keep credentials in RAM
  WiFi.mode(WIFI_OFF);
  wifiPhase = WIFI_PHASE_RADIO_OFF;
  wifiPhaseStartedMs = millis();
}

void maintainWifi() {
  const unsigned long now = millis();
  const wl_status_t status = WiFi.status();

  // Repeated negative HTTP results mean the association may be stale even if
  // the driver still reports WL_CONNECTED. Recover through the same serialized
  // state machine instead of letting failed POSTs continue forever.
  if (wifiRecoveryRequested) {
    wifiRecoveryRequested = false;
    scheduleWifiRecovery("S3 transport unreachable");
    return;
  }

  if (status == WL_CONNECTED) {
    if (wifiPhase != WIFI_PHASE_CONNECTED) {
      Serial.printf(
          "[WIFI] Connected. IP=%s RSSI=%d dBm; reporting resumes now.\n",
          WiFi.localIP().toString().c_str(),
          WiFi.RSSI());
      postAfterReconnect = true;
      consecutivePostTransportFailures = 0;
    }
    wifiPhase = WIFI_PHASE_CONNECTED;
    wifiPhaseStartedMs = now;
    consecutiveWifiFailures = 0;
    return;
  }

  if (wifiPhase == WIFI_PHASE_CONNECTED) {
    Serial.printf(
        "[WIFI] Link lost (%s). Retrying until the S3 returns.\n",
        wifiStatusName(status));
    scheduleWifiRecovery("link lost");
    return;
  }

  switch (wifiPhase) {
    case WIFI_PHASE_CONNECTING: {
      const bool terminalFailure =
          status == WL_NO_SSID_AVAIL ||
          status == WL_CONNECT_FAILED ||
          status == WL_CONNECTION_LOST;
      if ((terminalFailure && (now - wifiPhaseStartedMs) >= 2000UL) ||
          (now - wifiPhaseStartedMs) >= WIFI_CONNECT_TIMEOUT_MS) {
        Serial.printf("[WIFI] Attempt ended with %s.\n", wifiStatusName(status));
        scheduleWifiRecovery(
            terminalFailure ? "association failed" : "connect timeout");
      }
      break;
    }

    case WIFI_PHASE_DISCONNECTING:
      if ((now - wifiPhaseStartedMs) >= WIFI_DRIVER_SETTLE_MS) {
        wifiPhase = WIFI_PHASE_WAIT_RETRY;
        wifiPhaseStartedMs = now;
      }
      break;

    case WIFI_PHASE_WAIT_RETRY:
      if ((now - wifiPhaseStartedMs) >= WIFI_RETRY_DELAY_MS) {
        if (consecutiveWifiFailures >= WIFI_FAILURES_BEFORE_RADIO_RESET) {
          startWifiRadioReset();
        } else {
          beginWifiAttempt("scheduled retry");
        }
      }
      break;

    case WIFI_PHASE_RADIO_OFF:
      if ((now - wifiPhaseStartedMs) >= WIFI_RADIO_OFF_MS) {
        consecutiveWifiFailures = 0;
        beginWifiAttempt("radio reset complete");
      }
      break;

    case WIFI_PHASE_CONNECTED:
      // Handled above. Kept for exhaustive enum coverage.
      break;
  }
}

void recordS3TransportFailure(const char* detail) {
  if (consecutivePostTransportFailures < 255) {
    consecutivePostTransportFailures++;
  }
  Serial.printf(
      "[POST] Transport failure %u/%u: %s\n",
      (unsigned int)consecutivePostTransportFailures,
      (unsigned int)POST_FAILURES_BEFORE_WIFI_RECOVERY,
      detail);
  if (consecutivePostTransportFailures >= POST_FAILURES_BEFORE_WIFI_RECOVERY) {
    wifiRecoveryRequested = true;
  }
}

void postSensorData() {
  if (WiFi.status() != WL_CONNECTED) {
    Serial.println("[POST] Skipped: WiFi not connected");
    return;
  }

  const String body = buildSensorJson();
  WiFiClient client;
  HTTPClient http;
  client.setTimeout(2000);
  http.setTimeout(2000);

  if (!http.begin(client, S3_SENSOR_URL)) {
    recordS3TransportFailure("http.begin failed");
    return;
  }

  http.addHeader("Content-Type", "application/json");
  const int code = http.POST(body);
  const String response = code > 0 ? http.getString() : String();
  http.end();

  if (code > 0) {
    // Any HTTP response proves that the S3 transport is reachable. Only a 2xx
    // response confirms that this reading was accepted.
    consecutivePostTransportFailures = 0;
    Serial.printf("[POST] %s -> HTTP %d %s\n", body.c_str(), code, response.c_str());
  } else {
    const String error = HTTPClient::errorToString(code);
    recordS3TransportFailure(error.c_str());
  }
}

void setup() {
  Serial.begin(115200);
  delay(300);

  initRelayOutputOff(BULB_RELAY_PIN);
  initRelayOutputOff(HUMIDIFIER_RELAY_PIN);
  Serial.printf(
      "[HUMIDIFIER] Humidity-only control: ON below %.1f%% RH, OFF at %.1f%% RH; "
      "water monitoring only, humidity stale cutoff=%lu ms\n",
      HUMIDIFIER_ON_BELOW_RH, HUMIDIFIER_OFF_AT_OR_ABOVE_RH,
      SENSOR_STALE_SAFE_MS);

#if WATER_LEVEL_ENABLED
  pinMode(WATER_LEVEL_PIN, INPUT);
  analogReadResolution(12);
  analogSetPinAttenuation(WATER_LEVEL_PIN, ADC_11db);
#endif

  // Internal pull-ups + slower I2C clock improve reliability on long/jumper
  // wiring. Real 4.7k pull-ups on the breakout are still recommended.
  pinMode(I2C_SDA_PIN, INPUT_PULLUP);
  pinMode(I2C_SCL_PIN, INPUT_PULLUP);
  Wire.begin(I2C_SDA_PIN, I2C_SCL_PIN);
  Wire.setClock(50000);

  shtReady = beginShtSensor();

  // Read + regulate FIRST so the incubator is controlled even if WiFi never
  // connects. WiFi is started non-blocking and is only used to POST data.
  readSensors();
  updateActuators();

  startWifi();
}

void loop() {
  // Incubator control always runs before network maintenance or HTTP work.
  unsigned long now = millis();
  if (now - lastReadMs >= READ_INTERVAL_MS) {
    lastReadMs = now;
    readSensors();
    updateActuators();
  }

  maintainWifi();

  now = millis();
  if (postAfterReconnect || now - lastPostMs >= POST_INTERVAL_MS) {
    lastPostMs = now;
    postAfterReconnect = false;
    postSensorData();
  }
}
