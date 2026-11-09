#include "esp_camera.h"
#include <WiFi.h>
#include <WebServer.h>
#include <HTTPClient.h>
#include <ArduinoJson.h>
#include <esp_heap_caps.h>
#include "esp_system.h"
#include "freertos/FreeRTOS.h"
#include "freertos/semphr.h"
#include "freertos/task.h"

const char* ssid = "AI_CANDLING";
const char* pass = "thesis123";
const uint8_t WIFI_AP_CHANNEL = 1;
const uint8_t WIFI_AP_MAX_CONNECTIONS = 8;
const unsigned long WIFI_AP_HEALTH_INTERVAL_MS = 5000UL;
const uint8_t WIFI_AP_HEALTH_FAILURE_LIMIT = 3;
const unsigned long RUNTIME_HEALTH_LOG_INTERVAL_MS = 30000UL;
// All peers live on this local AP. An absent P4/LED controller must fail fast
// instead of occupying the control server for the HTTPClient default 5 s
// connect timeout while the phone is starting or maintaining its stream.
const unsigned long P4_PROXY_CONNECT_TIMEOUT_MS = 500UL;
const unsigned long P4_PROXY_RESPONSE_TIMEOUT_MS = 2000UL;
const unsigned long P4_FOCUS_CONNECT_TIMEOUT_MS = 250UL;
const unsigned long P4_FOCUS_RESPONSE_TIMEOUT_MS = 750UL;
const unsigned long LED_CONTROLLER_CONNECT_TIMEOUT_MS = 500UL;
const unsigned long LED_CONTROLLER_PROXY_TIMEOUT_MS = 1500UL;
const int INTAKE_SLOT_LED_COUNT = 56;

const uint16_t CONTROL_HTTP_PORT = 80;
const uint16_t STREAM_HTTP_PORT = 81;
WebServer server(CONTROL_HTTP_PORT);
WebServer streamServer(STREAM_HTTP_PORT);
StaticSemaphore_t cameraMutexStorage;
SemaphoreHandle_t cameraMutex = nullptr;
TaskHandle_t streamServerTaskHandle = nullptr;

bool wifiApStarted = false;
unsigned long lastWifiApHealthMs = 0;
int lastWifiApStationCount = -1;
uint8_t wifiApHealthFailureCount = 0;
uint32_t wifiApRestartCount = 0;
unsigned long lastRuntimeHealthMs = 0;
esp_reset_reason_t bootResetReason = ESP_RST_UNKNOWN;

uint32_t p4HttpRequestCount = 0;
uint32_t p4HttpFailureCount = 0;
int lastP4HttpCode = 0;
unsigned long lastP4HttpDurationMs = 0;
char lastP4HttpPath[80] = "none";

uint32_t ledHttpRequestCount = 0;
uint32_t ledHttpFailureCount = 0;
int lastLedHttpCode = 0;
unsigned long lastLedHttpDurationMs = 0;
char lastLedHttpPath[80] = "none";

const char* P4_BASE_URL = "http://192.168.4.50";
const char* LED_CONTROLLER_BASE_URL = "http://192.168.4.60";

#define CAMERA_RELAY_GPIO     2

#define CAMERA_RELAY_ON       LOW
#define CAMERA_RELAY_OFF      HIGH

#define WATER_LOW_PERCENT     5
#define SENSOR_STALE_MS       30000UL
#define AI_POWER_SAVE_TIMEOUT_MS 120000UL
#define CAMERA_FOCUS_POWER_SETTLE_MS 500UL
#define CAMERA_FOCUS_RELEASE_DELAY_MS 3500UL
#define CAMERA_POWER_SETTLE_MS 1500
#define CAMERA_SENSOR_SETTLE_MS 2500
#define CAPTURE_TX_POWER_SETTLE_MS 500
#define CAMERA_XCLK_HZ 10000000
#define CAMERA_FRAME_ATTEMPTS  6
#define CAMERA_DISCARD_FRAMES  2
#define CAMERA_MUTEX_TIMEOUT_MS 10000UL
#define CANDLING_CAPTURE_FRAME_SIZE FRAMESIZE_5MP
#define CANDLING_CAPTURE_JPEG_QUALITY 5
#define CANDLING_CAPTURE_EXPOSURE 1600
#define CANDLING_CAPTURE_GAIN 2
#define CANDLING_CAPTURE_SHARPNESS 1
#define JPEG_TX_CHUNK_BYTES 2048
#define JPEG_TX_NO_PROGRESS_TIMEOUT_MS 10000UL
#define STREAM_TX_CHUNK_BYTES 2048
#define STREAM_TX_NO_PROGRESS_TIMEOUT_MS 2000UL

volatile bool cameraOn    = false;
volatile bool capturing   = false;
volatile bool streamAlive = false;

enum StreamBandwidthProfile {
  STREAM_PROFILE_FAR = 0,
  STREAM_PROFILE_MEDIUM = 1,
  STREAM_PROFILE_NEAR = 2
};

struct StreamProfileConfig {
  framesize_t frameSize;
  int jpegQuality;
  uint16_t frameIntervalMs;
  const char* name;
};

const StreamProfileConfig STREAM_PROFILES[] = {
  {FRAMESIZE_QVGA, 10, 200, "FAR 320x240 5FPS"},
  {FRAMESIZE_VGA, 18, 143, "MEDIUM 640x480 7FPS"},
  {FRAMESIZE_VGA, 12, 100, "NEAR 640x480 10FPS"},
};

// Keep streaming at the measured-stable profile. Higher profiles caused the
// phone link to saturate after the automatic 20/40-second upgrades.
const bool STREAM_ADAPTIVE_UPGRADE_ENABLED = false;
// Lower AP TX power only while sending a staged high-resolution JPEG. The
// camera relay is already OFF, so this further reduces capture-transfer peaks.
const wifi_power_t CAPTURE_TX_WIFI_POWER = WIFI_POWER_11dBm;

// Start with the lowest-load profile so the mobile app receives a stable first
// frame. The existing adaptive logic upgrades after sustained headroom.
StreamBandwidthProfile streamBandwidthProfile = STREAM_PROFILE_FAR;
unsigned long streamUpgradeBlockedUntilMs = 0;
volatile bool cameraFocusActive = false;
volatile unsigned long cameraFocusReleaseMs = 0;
bool cameraFocusP4Notified = false;
bool aiPowerSave = false;
unsigned long aiPowerSaveMs = 0;
// Kept as a protocol state for compatibility with the P4. The S3 has no
// climate-control hardware; camera power is owned by capture/stream only.
const bool AI_POWER_SAVE_CONTROLS_CAMERA = false;
bool doorStateReceived = false;
bool doorClosed = true;
unsigned long lastDoorMs = 0;
// MAIN incubator climate from P4 (SHT3X) via /sensordata.
float latestTemp  = 0.0;
float latestHum   = 0.0;
bool latestTempValid = false;
bool latestHumValid = false;
bool sensorDataReceived = false;
unsigned long lastSensorMs = 0;
// Read-only mirror reported by the P4. The physical main-bulb relay is on P4
// GPIO33; this S3 never drives that relay.
bool mainBulbOn = true;
bool mainBulbStateReceived = false;

// SUB incubator (lockdown relay node) climate via /subsensordata.
float subTemp = 0.0;
float subHum  = 0.0;
bool subTempValid = false;
bool subHumValid = false;
int subWaterRaw = 0;
int subWaterLevel = 0;
bool subWaterLow = true;
bool subBulbOn = false;
bool subHumidifierOn = false;
int subIncubatorUptimeMs = 0;
bool subDataReceived = false;
unsigned long lastSubMs = 0;

// The mobile app polls /sensor via POST; the P4 polls it via GET. So a recent
// POST means the app is actively connected. The P4 reads "appConnected" to slow
// its own polling (avoid contending on this single-request server).
unsigned long lastAppActivityMs = 0;
const unsigned long APP_ACTIVE_TIMEOUT_MS = 15000UL;

#define PWDN_GPIO_NUM   -1
#define RESET_GPIO_NUM  -1
#define XCLK_GPIO_NUM   15
#define SIOD_GPIO_NUM    4
#define SIOC_GPIO_NUM    5

#define Y2_GPIO_NUM     11
#define Y3_GPIO_NUM      9
#define Y4_GPIO_NUM      8
#define Y5_GPIO_NUM     10
#define Y6_GPIO_NUM     12
#define Y7_GPIO_NUM     18
#define Y8_GPIO_NUM     17
#define Y9_GPIO_NUM     16

#define VSYNC_GPIO_NUM   6
#define HREF_GPIO_NUM    7
#define PCLK_GPIO_NUM   13

const char* resetReasonName(esp_reset_reason_t reason) {
  switch (reason) {
    case ESP_RST_POWERON: return "POWERON";
    case ESP_RST_EXT: return "EXTERNAL";
    case ESP_RST_SW: return "SOFTWARE";
    case ESP_RST_PANIC: return "PANIC";
    case ESP_RST_INT_WDT: return "INT_WDT";
    case ESP_RST_TASK_WDT: return "TASK_WDT";
    case ESP_RST_WDT: return "WDT";
    case ESP_RST_DEEPSLEEP: return "DEEPSLEEP";
    case ESP_RST_BROWNOUT: return "BROWNOUT";
    case ESP_RST_SDIO: return "SDIO";
    default: return "UNKNOWN";
  }
}

void recordP4HttpResult(const String& path, int code, unsigned long durationMs) {
  p4HttpRequestCount++;
  if (code <= 0 || code >= 500) p4HttpFailureCount++;
  lastP4HttpCode = code;
  lastP4HttpDurationMs = durationMs;
  snprintf(lastP4HttpPath, sizeof(lastP4HttpPath), "%s", path.c_str());
}

void recordLedHttpResult(const String& path, int code, unsigned long durationMs) {
  ledHttpRequestCount++;
  if (code <= 0 || code >= 500) ledHttpFailureCount++;
  lastLedHttpCode = code;
  lastLedHttpDurationMs = durationMs;
  snprintf(lastLedHttpPath, sizeof(lastLedHttpPath), "%s", path.c_str());
}

void sendRuntimeHealth() {
  DynamicJsonDocument doc(1536);
  doc["status"] = "ok";
  doc["uptimeMs"] = millis();
  doc["resetReason"] = resetReasonName(bootResetReason);
  doc["resetReasonCode"] = static_cast<int>(bootResetReason);
  doc["freeHeap"] = ESP.getFreeHeap();
  doc["minFreeHeap"] = ESP.getMinFreeHeap();
  doc["psramSize"] = ESP.getPsramSize();
  doc["freePsram"] = ESP.getFreePsram();

  JsonObject ap = doc.createNestedObject("ap");
  ap["started"] = wifiApStarted;
  ap["mode"] = static_cast<int>(WiFi.getMode());
  ap["ip"] = WiFi.softAPIP().toString();
  ap["stations"] = WiFi.softAPgetStationNum();
  ap["healthMisses"] = wifiApHealthFailureCount;
  ap["restartCount"] = wifiApRestartCount;

  JsonObject camera = doc.createNestedObject("camera");
  camera["powered"] = cameraOn;
  camera["capturing"] = capturing;
  camera["streaming"] = streamAlive;
  camera["focusPowerMode"] = cameraFocusActive;
  camera["streamPort"] = STREAM_HTTP_PORT;
  camera["exclusiveCapture"] = true;

  JsonObject p4 = doc.createNestedObject("p4Http");
  p4["baseUrl"] = P4_BASE_URL;
  p4["requests"] = p4HttpRequestCount;
  p4["failures"] = p4HttpFailureCount;
  p4["lastPath"] = lastP4HttpPath;
  p4["lastCode"] = lastP4HttpCode;
  p4["lastDurationMs"] = lastP4HttpDurationMs;

  JsonObject led = doc.createNestedObject("ledHttp");
  led["baseUrl"] = LED_CONTROLLER_BASE_URL;
  led["requests"] = ledHttpRequestCount;
  led["failures"] = ledHttpFailureCount;
  led["lastPath"] = lastLedHttpPath;
  led["lastCode"] = lastLedHttpCode;
  led["lastDurationMs"] = lastLedHttpDurationMs;

  String response;
  serializeJson(doc, response);
  server.sendHeader("Access-Control-Allow-Origin", "*");
  server.send(200, "application/json", response);
}

void logRuntimeHealth() {
  const unsigned long now = millis();
  if ((now - lastRuntimeHealthMs) < RUNTIME_HEALTH_LOG_INTERVAL_MS) return;
  lastRuntimeHealthMs = now;

  Serial.printf(
      "[HEALTH] up=%lus reset=%s heap=%u min=%u psram=%u/%u "
      "ap=%s stations=%d misses=%u restarts=%lu camera=%s stream=%s "
      "p4=%d/%lums(%s) led=%d/%lums(%s)\n",
      now / 1000UL,
      resetReasonName(bootResetReason),
      ESP.getFreeHeap(),
      ESP.getMinFreeHeap(),
      ESP.getFreePsram(),
      ESP.getPsramSize(),
      WiFi.softAPIP().toString().c_str(),
      WiFi.softAPgetStationNum(),
      static_cast<unsigned int>(wifiApHealthFailureCount),
      static_cast<unsigned long>(wifiApRestartCount),
      cameraOn ? "ON" : "OFF",
      streamAlive ? "ON" : "OFF",
      lastP4HttpCode,
      lastP4HttpDurationMs,
      lastP4HttpPath,
      lastLedHttpCode,
      lastLedHttpDurationMs,
      lastLedHttpPath);
}

void initRelayOutputOff(uint8_t pin, uint8_t offLevel) {
  digitalWrite(pin, offLevel);
  pinMode(pin, offLevel == HIGH ? INPUT_PULLUP : INPUT_PULLDOWN);
  delay(2);
  pinMode(pin, OUTPUT);
  digitalWrite(pin, offLevel);
}

void setAiPowerSave(bool on) {
  if (on) {
    aiPowerSaveMs = millis();
  }
  if (aiPowerSave == on) {
    return;
  }

  aiPowerSave = on;
  aiPowerSaveMs = millis();
  Serial.printf("[AI_POWER] %s: compatibility state only; S3 camera unchanged\n",
                aiPowerSave ? "ON" : "OFF");
}

void sendActuatorStatus() {
  DynamicJsonDocument doc(1024);
  doc["hardwareProfile"] = "camera_only";
  doc["humidifier"] = false;
  doc["humidifierAuto"] = false;
  doc["humidifierAvailable"] = false;
  doc["environmentLed"] = mainBulbOn;
  doc["environmentLedAuto"] = true;
  doc["environmentLedManual"] = false;
  doc["environmentLedMode"] = "p4_gpio33";
  doc["environmentLedOwner"] = "p4";
  doc["environmentLedStateReceived"] = mainBulbStateReceived;
  doc["aiPowerSave"] = aiPowerSave;
  doc["aiPowerSaveScope"] = "compatibility_only";
  doc["aiPowerSaveControlsCamera"] = AI_POWER_SAVE_CONTROLS_CAMERA;
  doc["aiPowerSaveAgeMs"] = aiPowerSave ? (millis() - aiPowerSaveMs) : 0;
  doc["aiPowerSaveTimeoutMs"] = AI_POWER_SAVE_TIMEOUT_MS;
  doc["cameraFocus"] = cameraFocusActive;
  doc["waterSamplingAvailable"] = false;
  doc["waterSamplingPaused"] = false;
  doc["bulbCaptureMode"] = "p4_controlled";
  doc["doorClosed"] = doorClosed;
  doc["doorStateReceived"] = doorStateReceived;
  doc["doorAgeMs"] = doorStateReceived ? (millis() - lastDoorMs) : 0;
  doc["temp"] = latestTemp;
  doc["tempValid"] = latestTempValid;
  doc["hum"] = latestHum;
  doc["humValid"] = latestHumValid;
  doc["sensorReceived"] = sensorDataReceived;
  doc["sensorAgeMs"] = sensorDataReceived ? (millis() - lastSensorMs) : 0;
  doc["sensorFresh"] =
      sensorDataReceived &&
      latestTempValid &&
      latestHumValid &&
      ((millis() - lastSensorMs) <= SENSOR_STALE_MS);
  doc["subIncubatorConnected"] =
      subDataReceived && ((millis() - lastSubMs) <= SENSOR_STALE_MS);
  doc["subIncubatorAgeMs"] = subDataReceived ? (millis() - lastSubMs) : 0;
  doc["subIncubatorBulb"] = subBulbOn;
  doc["subIncubatorHumidifier"] = subHumidifierOn;
  doc["subIncubatorUptimeMs"] = subIncubatorUptimeMs;
  doc["waterRaw"] = 0;
  doc["waterLevel"] = 0;
  doc["waterLow"] = false;
  doc["waterReceived"] = false;
  doc["waterLowPercent"] = WATER_LOW_PERCENT;
  doc["waterSource"] = "none";
  doc["waterAgeMs"] = 0;
  JsonObject pins = doc.createNestedObject("pins");
  pins["cameraRelay"] = CAMERA_RELAY_GPIO;
  pins["humidifierRelay"] = nullptr;
  pins["p4BulbRelay"] = 33;
  pins["waterLevel"] = nullptr;

  String response;
  serializeJson(doc, response);
  server.sendHeader("Access-Control-Allow-Origin", "*");
  server.send(200, "application/json", response);
}

bool readStateArg(String& state) {
  if (!server.hasArg("state")) return false;
  state = server.arg("state");
  state.toLowerCase();
  return true;
}

void proxyP4Get(const char* path) {
  WiFiClient client;
  HTTPClient http;
  String url = String(P4_BASE_URL) + path;
  const unsigned long startedMs = millis();
  http.setConnectTimeout(P4_PROXY_CONNECT_TIMEOUT_MS);
  http.setTimeout(P4_PROXY_RESPONSE_TIMEOUT_MS);

  if (!http.begin(client, url)) {
    recordP4HttpResult(path, 0, millis() - startedMs);
    server.send(502, "text/plain", "P4 begin failed");
    return;
  }

  int code = http.GET();
  String payload = code > 0 ? http.getString() : "";
  http.end();
  const unsigned long durationMs = millis() - startedMs;
  recordP4HttpResult(path, code, durationMs);
  if (code <= 0 || durationMs >= 1000UL) {
    Serial.printf("[P4_HTTP] GET %s -> %d in %lu ms\n",
                  path, code, durationMs);
  }

  server.sendHeader("Access-Control-Allow-Origin", "*");
  server.send(code > 0 ? code : 502, "application/json", payload);
}

void proxyP4Post(const char* path) {
  WiFiClient client;
  HTTPClient http;
  String url = String(P4_BASE_URL) + path;
  String body = server.arg("plain");
  const unsigned long startedMs = millis();
  http.setConnectTimeout(P4_PROXY_CONNECT_TIMEOUT_MS);
  http.setTimeout(P4_PROXY_RESPONSE_TIMEOUT_MS);

  if (!http.begin(client, url)) {
    recordP4HttpResult(path, 0, millis() - startedMs);
    server.send(502, "text/plain", "P4 begin failed");
    return;
  }

  http.addHeader("Content-Type", "application/json");
  int code = http.POST(body);
  String payload = code > 0 ? http.getString() : "";
  http.end();
  const unsigned long durationMs = millis() - startedMs;
  recordP4HttpResult(path, code, durationMs);
  if (code <= 0 || durationMs >= 1000UL) {
    Serial.printf("[P4_HTTP] POST %s -> %d in %lu ms\n",
                  path, code, durationMs);
  }

  server.sendHeader("Access-Control-Allow-Origin", "*");
  server.send(code > 0 ? code : 502, "application/json", payload);
}

void proxyP4Data(const char* path) {
  if (server.method() == HTTP_POST) {
    proxyP4Post(path);
  } else {
    proxyP4Get(path);
  }
}

void notifyP4CameraFocus(bool active) {
  WiFiClient client;
  HTTPClient http;
  String path = active ? "/camera_focus?state=on" : "/camera_focus?state=off";
  String url = String(P4_BASE_URL) + path;
  const unsigned long startedMs = millis();
  http.setConnectTimeout(P4_FOCUS_CONNECT_TIMEOUT_MS);
  http.setTimeout(P4_FOCUS_RESPONSE_TIMEOUT_MS);

  if (!http.begin(client, url)) {
    recordP4HttpResult(path, 0, millis() - startedMs);
    Serial.println("[CAM_FOCUS] P4 notify begin failed");
    return;
  }

  int code = http.GET();
  http.end();
  recordP4HttpResult(path, code, millis() - startedMs);
  Serial.printf("[CAM_FOCUS] P4 background traffic %s -> HTTP %d\n",
                active ? "PAUSE" : "RESUME", code);
}

void beginCameraFocus(const char* source, bool notifyP4) {
  cameraFocusReleaseMs = 0;
  if (cameraFocusActive) {
    if (notifyP4 && !cameraFocusP4Notified) {
      notifyP4CameraFocus(true);
      cameraFocusP4Notified = true;
    }
    return;
  }

  cameraFocusActive = true;
  if (notifyP4) {
    notifyP4CameraFocus(true);
    cameraFocusP4Notified = true;
  }
  Serial.printf("[CAM_FOCUS] ON (%s): camera-only load window; settling %lu ms\n",
                source, CAMERA_FOCUS_POWER_SETTLE_MS);
  delay(CAMERA_FOCUS_POWER_SETTLE_MS);
}

void scheduleCameraFocusRelease() {
  if (!cameraFocusActive) return;
  cameraFocusReleaseMs = millis() + CAMERA_FOCUS_RELEASE_DELAY_MS;
  Serial.printf("[CAM_FOCUS] Camera complete; release scheduled in %lu ms\n",
                CAMERA_FOCUS_RELEASE_DELAY_MS);
}

void serviceCameraFocusRelease() {
  if (!cameraFocusActive || cameraFocusReleaseMs == 0 ||
      cameraOn || streamAlive || capturing ||
      static_cast<int32_t>(millis() - cameraFocusReleaseMs) < 0) {
    return;
  }

  cameraFocusActive = false;
  cameraFocusReleaseMs = 0;
  if (cameraFocusP4Notified) {
    notifyP4CameraFocus(false);
    cameraFocusP4Notified = false;
  }
  Serial.println("[CAM_FOCUS] OFF: camera-only load window released");
}

int requestLedController(const String& path, String* responsePayload = nullptr) {
  WiFiClient client;
  HTTPClient http;
  String url = String(LED_CONTROLLER_BASE_URL) + path;
  const unsigned long startedMs = millis();
  http.setConnectTimeout(LED_CONTROLLER_CONNECT_TIMEOUT_MS);
  http.setTimeout(LED_CONTROLLER_PROXY_TIMEOUT_MS);

  if (!http.begin(client, url)) {
    recordLedHttpResult(path, 0, millis() - startedMs);
    if (responsePayload != nullptr) responsePayload->remove(0);
    Serial.printf("[LEDCTRL] begin failed: %s\n", path.c_str());
    return 0;
  }

  int code = http.GET();
  String payload = code > 0 ? http.getString() : "";
  http.end();
  const unsigned long durationMs = millis() - startedMs;
  recordLedHttpResult(path, code, durationMs);

  Serial.printf("[LEDCTRL] %s -> HTTP %d in %lu ms\n",
                path.c_str(), code, durationMs);
  if (code > 0 && payload.length() > 0) {
    Serial.println(payload);
  }
  if (responsePayload != nullptr) *responsePayload = payload;
  return code;
}

void notifyLedController(const char* path) {
  requestLedController(String(path));
}

const int SELECTED_LED_QUERY_OMITTED = 0;
const int SELECTED_LED_QUERY_VALID = 1;
const int SELECTED_LED_QUERY_INVALID = 2;

int parseSelectedLedQuery(
    String& normalized, bool selected[INTAKE_SLOT_LED_COUNT],
    int& selectedCount, String& errorText) {
  normalized = "";
  selectedCount = 0;
  errorText = "";
  memset(selected, 0, sizeof(bool) * INTAKE_SLOT_LED_COUNT);

  if (!server.hasArg("led")) {
    return SELECTED_LED_QUERY_OMITTED;
  }

  String raw = server.arg("led");
  raw.trim();
  if (raw.length() == 0) {
    errorText = "led must contain one or more slots from 1 to 56";
    return SELECTED_LED_QUERY_INVALID;
  }

  int start = 0;
  while (start < raw.length()) {
    int comma = raw.indexOf(',', start);
    int end = comma >= 0 ? comma : raw.length();
    String token = raw.substring(start, end);
    token.trim();
    if (token.length() == 0) {
      errorText = "led contains an empty slot";
      return SELECTED_LED_QUERY_INVALID;
    }

    for (int i = 0; i < token.length(); i++) {
      char ch = token.charAt(i);
      if (ch < '0' || ch > '9') {
        errorText = "led must be a comma-separated list of slots 1 to 56";
        return SELECTED_LED_QUERY_INVALID;
      }
    }

    int led = token.toInt();
    if (led < 1 || led > INTAKE_SLOT_LED_COUNT) {
      errorText = "led slot out of range; use 1 to 56";
      return SELECTED_LED_QUERY_INVALID;
    }

    if (!selected[led - 1]) {
      selected[led - 1] = true;
      if (normalized.length() > 0) normalized += ',';
      normalized += String(led);
      selectedCount++;
    }

    if (comma < 0) break;
    start = comma + 1;
    if (start >= raw.length()) {
      errorText = "led contains an empty slot";
      return SELECTED_LED_QUERY_INVALID;
    }
  }

  return selectedCount > 0 ? SELECTED_LED_QUERY_VALID
                           : SELECTED_LED_QUERY_INVALID;
}

bool verifySelectedLedResponse(
    const String& payload, const bool selected[INTAKE_SLOT_LED_COUNT],
    int selectedCount, String& errorText) {
  DynamicJsonDocument doc(1536);
  DeserializationError jsonError = deserializeJson(doc, payload);
  if (jsonError) {
    errorText = "LED controller returned invalid JSON";
    return false;
  }

  JsonArray active = doc["active_leds"].as<JsonArray>();
  if (active.isNull()) {
    errorText = "LED controller response has no active_leds";
    return false;
  }

  bool actual[INTAKE_SLOT_LED_COUNT] = {};
  int actualCount = 0;
  for (JsonVariant item : active) {
    if (!item.is<int>()) {
      errorText = "LED controller returned an invalid active slot";
      return false;
    }
    int led = item.as<int>();
    if (led < 1 || led > INTAKE_SLOT_LED_COUNT || actual[led - 1]) {
      errorText = "LED controller returned an invalid active slot";
      return false;
    }
    actual[led - 1] = true;
    actualCount++;
  }

  if (actualCount != selectedCount) {
    errorText = "LED controller active count does not match requested slots";
    return false;
  }
  for (int i = 0; i < INTAKE_SLOT_LED_COUNT; i++) {
    if (actual[i] != selected[i]) {
      errorText = "LED controller active slots do not match requested slots";
      return false;
    }
  }
  return true;
}

bool activateSelectedLeds(
    const String& normalized, const bool selected[INTAKE_SLOT_LED_COUNT],
    int selectedCount, String& errorText) {
  String path = "/led_test?mode=set&led=" + normalized;
  String payload;
  int code = requestLedController(path, &payload);
  if (code < 200 || code >= 300) {
    errorText = "LED controller rejected selected slots";
    notifyLedController("/candling_stop");
    return false;
  }
  if (!verifySelectedLedResponse(payload, selected, selectedCount, errorText)) {
    notifyLedController("/candling_stop");
    return false;
  }
  return true;
}

void proxyLedControllerGet(const String& path) {
  WiFiClient client;
  HTTPClient http;
  String url = String(LED_CONTROLLER_BASE_URL) + path;
  const unsigned long startedMs = millis();
  http.setConnectTimeout(LED_CONTROLLER_CONNECT_TIMEOUT_MS);
  http.setTimeout(LED_CONTROLLER_PROXY_TIMEOUT_MS);

  if (!http.begin(client, url)) {
    recordLedHttpResult(path, 0, millis() - startedMs);
    server.send(502, "text/plain", "LED controller begin failed");
    return;
  }

  int code = http.GET();
  String payload = code > 0 ? http.getString() : "";
  http.end();
  const unsigned long durationMs = millis() - startedMs;
  recordLedHttpResult(path, code, durationMs);
  if (code <= 0 || durationMs >= 1000UL) {
    Serial.printf("[LEDCTRL] proxy %s -> %d in %lu ms\n",
                  path.c_str(), code, durationMs);
  }

  server.sendHeader("Access-Control-Allow-Origin", "*");
  server.send(code > 0 ? code : 502, "application/json", payload);
}

void appendLedQueryArg(String& path, const char* name, bool& hasQuery) {
  if (!server.hasArg(name)) return;
  path += hasQuery ? "&" : "?";
  hasQuery = true;
  path += name;
  path += "=";
  path += server.arg(name);
}

void handleLedControllerStatus() { proxyLedControllerGet("/status"); }
void handleLedControllerCandlingStart() { proxyLedControllerGet("/candling_start"); }
void handleLedControllerCandlingStop() { proxyLedControllerGet("/candling_stop"); }
void handleLedControllerSlotsSync() { proxyLedControllerGet("/slots_sync"); }
void handleLedControllerTest() {
  String path = "/led_test";
  bool hasQuery = false;
  appendLedQueryArg(path, "led", hasQuery);
  appendLedQueryArg(path, "mode", hasQuery);
  proxyLedControllerGet(path);
}

void handleP4CandlingStart() {
  String normalized;
  String errorText;
  bool selected[INTAKE_SLOT_LED_COUNT] = {};
  int selectedCount = 0;
  int queryResult = parseSelectedLedQuery(
      normalized, selected, selectedCount, errorText);
  if (queryResult == SELECTED_LED_QUERY_INVALID) {
    server.send(400, "text/plain", errorText);
    return;
  }
  if (queryResult == SELECTED_LED_QUERY_VALID) {
    if (!activateSelectedLeds(
            normalized, selected, selectedCount, errorText)) {
      server.send(502, "text/plain", errorText);
      return;
    }
  } else {
    notifyLedController("/candling_start");
  }
  proxyP4Data("/candling_start");
}

void handleP4CandlingStop() {
  notifyLedController("/candling_stop");
  proxyP4Data("/candling_stop");
}

void handleP4CaptureHoldStart() { proxyP4Data("/capture_hold_start"); }
void handleP4CaptureHoldStop()  { proxyP4Data("/capture_hold_stop"); }
void handleP4BlinkInfertile(){ proxyP4Data("/blink_infertile"); }
void handleP4LedTest() {
  String path = "/led_test";
  if (server.hasArg("zone")) {
    path += "?zone=" + server.arg("zone");
  }
  proxyP4Data(path.c_str());
}
void handleP4GetSlots() {
  proxyP4Data("/get_slots");
}
void handleP4SetSlots()      { proxyP4Post("/set_slots"); }
void handleP4SetFertilityResults() {
  proxyP4Post("/set_fertility_results");
}
void handleP4DiagnosticAlerts(){ proxyP4Post("/diagnostic_alerts"); }
void handleP4GetInfertile()  { proxyP4Data("/get_infertile"); }
void handleP4ClearInfertile(){ proxyP4Post("/clear_infertile"); }
void handleP4GetGridConfig() { proxyP4Data("/get_grid_config"); }
void handleP4ResetGridConfig(){ proxyP4Post("/reset_grid_config"); }
void handleP4TimeSync()      { proxyP4Post("/time_sync"); }

void handleHumidifier() {
  String state;
  if (!readStateArg(state)) {
    sendActuatorStatus();
    return;
  }

  if (state != "auto" && state != "on" && state != "off") {
    server.send(400, "text/plain", "Use state=auto, state=on, or state=off");
    return;
  }

  Serial.printf("[HUMIDIFIER] Ignored state=%s; hardware removed from S3\n",
                state.c_str());
  sendActuatorStatus();
}

void handleDoorState() {
  String state;
  if (!readStateArg(state)) {
    sendActuatorStatus();
    return;
  }

  if (state == "closed" || state == "close" || state == "1") {
    doorClosed = true;
  } else if (state == "open" || state == "0") {
    doorClosed = false;
  } else {
    server.send(400, "text/plain", "Use state=open or state=closed");
    return;
  }

  doorStateReceived = true;
  lastDoorMs = millis();
  Serial.printf("[DOOR] %s\n", doorClosed ? "CLOSED" : "OPEN");
  sendActuatorStatus();
}

void handleAiPower() {
  String state;
  if (!readStateArg(state)) {
    sendActuatorStatus();
    return;
  }

  if (state == "on") {
    setAiPowerSave(true);
  } else if (state == "off" || state == "auto") {
    setAiPowerSave(false);
  } else {
    server.send(400, "text/plain", "Use state=on or state=off");
    return;
  }

  sendActuatorStatus();
}

void handleP4SetInfertile() {
  if (server.method() != HTTP_POST) {
    server.send(405, "text/plain", "Method Not Allowed");
    return;
  }

  String body = server.arg("plain");
  if (body.length() == 0) {
    server.send(400, "text/plain", "No body");
    return;
  }

  DynamicJsonDocument doc(768);
  DeserializationError error = deserializeJson(doc, body);
  if (error) {
    server.send(400, "text/plain", "Invalid JSON");
    return;
  }

  int day = -1;
  if (doc["day"].is<int>()) {
    day = doc["day"];
  } else if (doc["eggDay"].is<int>()) {
    day = doc["eggDay"];
  } else if (doc["egg_day"].is<int>()) {
    day = doc["egg_day"];
  } else if (doc["eggDayCounter"].is<int>()) {
    day = doc["eggDayCounter"];
  } else if (doc["dayCounter"].is<int>()) {
    day = doc["dayCounter"];
  } else if (doc["incubationDay"].is<int>()) {
    day = doc["incubationDay"];
  }

  const bool hasSlotList =
      doc["infertile"].is<JsonArray>() || doc["slots"].is<JsonArray>();
  const bool hasSingleSlot = doc["slot"].is<int>();
  if (!hasSlotList && !hasSingleSlot) {
    server.send(400, "text/plain", "Missing infertile slot data");
    return;
  }

  if (day < 7) {
    server.send(409, "text/plain", "Infertile slots accepted only on day 7+");
    return;
  }

  proxyP4Post("/set_infertile");
}

void handleP4GridConfig() {
  if (server.method() != HTTP_POST) {
    server.send(405, "text/plain", "Method Not Allowed");
    return;
  }
  proxyP4Post("/grid_config");
}
bool initCamera(framesize_t size, int quality, int fbCount) {
  if (cameraOn) {
    esp_camera_deinit();
    cameraOn = false;
    delay(300);
  }

  camera_config_t cfg = {};
  cfg.ledc_channel = LEDC_CHANNEL_0;
  cfg.ledc_timer   = LEDC_TIMER_0;

  cfg.pin_d0    = Y2_GPIO_NUM;
  cfg.pin_d1    = Y3_GPIO_NUM;
  cfg.pin_d2    = Y4_GPIO_NUM;
  cfg.pin_d3    = Y5_GPIO_NUM;
  cfg.pin_d4    = Y6_GPIO_NUM;
  cfg.pin_d5    = Y7_GPIO_NUM;
  cfg.pin_d6    = Y8_GPIO_NUM;
  cfg.pin_d7    = Y9_GPIO_NUM;

  cfg.pin_xclk      = XCLK_GPIO_NUM;
  cfg.pin_pclk      = PCLK_GPIO_NUM;
  cfg.pin_vsync     = VSYNC_GPIO_NUM;
  cfg.pin_href      = HREF_GPIO_NUM;
  cfg.pin_sccb_sda  = SIOD_GPIO_NUM;
  cfg.pin_sccb_scl  = SIOC_GPIO_NUM;
  cfg.pin_pwdn      = PWDN_GPIO_NUM;
  cfg.pin_reset     = RESET_GPIO_NUM;

  // The DCX-OV5640-E is manual focus; XCLK only drives the image sensor and
  // does not control focus. Keep it within the OV5640's supported clock range.
  cfg.xclk_freq_hz = CAMERA_XCLK_HZ;
  cfg.pixel_format = PIXFORMAT_JPEG;
  cfg.frame_size   = size;
  cfg.jpeg_quality = quality;
  cfg.fb_count     = fbCount;
  cfg.fb_location  = CAMERA_FB_IN_PSRAM;
  cfg.grab_mode    = fbCount > 1 ? CAMERA_GRAB_LATEST : CAMERA_GRAB_WHEN_EMPTY;

  digitalWrite(CAMERA_RELAY_GPIO, CAMERA_RELAY_ON);
  delay(CAMERA_POWER_SETTLE_MS);

  esp_err_t err = esp_camera_init(&cfg);
  if (err != ESP_OK) {
    Serial.printf("[CAM] Init fail: 0x%x\n", err);
    digitalWrite(CAMERA_RELAY_GPIO, CAMERA_RELAY_OFF);
    return false;
  }

  cameraOn = true;
  sensor_t* sensor = esp_camera_sensor_get();
  if (sensor == nullptr) {
    Serial.println("[CAM] Init returned OK but sensor handle is missing");
    shutdownCamera();
    return false;
  }
  Serial.printf(
    "[CAM] Ready sensor=%s PID=0x%04X VER=0x%02X MID=0x%02X%02X XCLK=%luHz frame=%d quality=%d fb=%d grab=%s\n",
    sensor->id.PID == OV5640_PID ? "OV5640" : "other",
    static_cast<unsigned int>(sensor->id.PID),
    static_cast<unsigned int>(sensor->id.VER),
    static_cast<unsigned int>(sensor->id.MIDH),
    static_cast<unsigned int>(sensor->id.MIDL),
    static_cast<unsigned long>(CAMERA_XCLK_HZ),
    static_cast<int>(size),
    quality,
    fbCount,
    fbCount > 1 ? "latest" : "when_empty"
  );
  return true;
}

bool applyCandlingCaptureProfile() {
  if (!cameraOn) return false;
  sensor_t* sensor = esp_camera_sensor_get();
  if (!sensor) return false;

  // The selected underlights occupy only a small part of an otherwise dark
  // frame. Unrestricted auto exposure therefore washes out the active slots,
  // while the former 250/0 manual profile made many eggs unreadably dark.
  // Keep exposure deterministic for dataset consistency. The moderate
  // Favor a longer exposure over sensor gain while the tray is stopped. This
  // brightens egg interiors with less amplified noise and leaves the fixed
  // sharpness/denoise profile unchanged.
  int result = 0;
  result |= sensor->set_brightness(sensor, 0);
  result |= sensor->set_contrast(sensor, -1);
  result |= sensor->set_saturation(sensor, -1);
  result |= sensor->set_gain_ctrl(sensor, 0);
  result |= sensor->set_agc_gain(sensor, CANDLING_CAPTURE_GAIN);
  result |= sensor->set_exposure_ctrl(sensor, 0);
  result |= sensor->set_aec_value(sensor, CANDLING_CAPTURE_EXPOSURE);
  result |= sensor->set_sharpness(sensor, CANDLING_CAPTURE_SHARPNESS);
  result |= sensor->set_denoise(sensor, 3);
  result |= sensor->set_whitebal(sensor, 1);
  result |= sensor->set_wb_mode(sensor, 0);

  Serial.printf(
    "[CAPTURE] Fixed candling profile requested exp=%d gain=%d sharpness=%d; applied exp=%u gain=%u sharpness=%d result=%d\n",
    CANDLING_CAPTURE_EXPOSURE,
    CANDLING_CAPTURE_GAIN,
    CANDLING_CAPTURE_SHARPNESS,
    static_cast<unsigned int>(sensor->status.aec_value),
    static_cast<unsigned int>(sensor->status.agc_gain),
    static_cast<int>(sensor->status.sharpness),
    result
  );
  return result == 0;
}

bool applyStreamBandwidthProfile(StreamBandwidthProfile profile) {
  if (!cameraOn) return false;
  sensor_t* sensor = esp_camera_sensor_get();
  if (!sensor) return false;

  const StreamProfileConfig& config = STREAM_PROFILES[(int)profile];
  const int frameResult = sensor->set_framesize(sensor, config.frameSize);
  const int qualityResult = sensor->set_quality(sensor, config.jpegQuality);
  if (frameResult != 0 || qualityResult != 0) {
    Serial.printf(
      "[STREAM] Profile apply failed frame=%d quality=%d\n",
      frameResult,
      qualityResult
    );
    return false;
  }

  streamBandwidthProfile = profile;
  Serial.printf("[STREAM] Auto profile -> %s\n", config.name);
  // Do not synchronously flush/fetch frames here. The stream loop owns every
  // frame and discards stale queued frames itself.
  delay(80);
  return true;
}

camera_fb_t* acquireCameraFrame(const char* tag) {
  int discarded = 0;
  for (int attempt = 1; attempt <= CAMERA_FRAME_ATTEMPTS; attempt++) {
    camera_fb_t* fb = esp_camera_fb_get();
    if (!fb) {
      Serial.printf("[%s] Frame not ready (%d/%d)\n",
                    tag, attempt, CAMERA_FRAME_ATTEMPTS);
      delay(250);
      yield();
      continue;
    }

    if (fb->len == 0) {
      Serial.printf("[%s] Empty frame (%d/%d)\n",
                    tag, attempt, CAMERA_FRAME_ATTEMPTS);
      esp_camera_fb_return(fb);
      delay(250);
      yield();
      continue;
    }

    if (discarded < CAMERA_DISCARD_FRAMES) {
      discarded++;
      esp_camera_fb_return(fb);
      delay(120);
      yield();
      continue;
    }

    Serial.printf("[%s] Frame: %ux%u, %u bytes\n",
                  tag, fb->width, fb->height, fb->len);
    return fb;
  }

  return nullptr;
}

void shutdownCamera() {
  if (!cameraOn) return;
  const esp_err_t deinitResult = esp_camera_deinit();
  digitalWrite(CAMERA_RELAY_GPIO, CAMERA_RELAY_OFF);
  cameraOn = false;
  Serial.printf("[CAM] Relay OFF after deinit=0x%x; settling 200 ms\n",
                static_cast<unsigned int>(deinitResult));
  delay(200);
}

bool stageCapturedJpegForLowPowerTransfer(camera_fb_t* fb,
                                          const char* tag,
                                          uint8_t** jpegData,
                                          size_t* jpegLength) {
  if (!fb || !jpegData || !jpegLength || fb->len == 0) {
    if (fb) esp_camera_fb_return(fb);
    shutdownCamera();
    return false;
  }

  const size_t length = fb->len;
  uint8_t* staged = static_cast<uint8_t*>(heap_caps_malloc(
      length, MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT));
  if (!staged) {
    Serial.printf("[%s] Cannot stage %u-byte JPEG in PSRAM\n",
                  tag, static_cast<unsigned int>(length));
    esp_camera_fb_return(fb);
    shutdownCamera();
    return false;
  }

  memcpy(staged, fb->buf, length);
  esp_camera_fb_return(fb);
  Serial.printf("[%s] JPEG staged; switching camera relay OFF before WiFi transfer\n",
                tag);
  shutdownCamera();
  delay(CAPTURE_TX_POWER_SETTLE_MS);

  *jpegData = staged;
  *jpegLength = length;
  Serial.printf("[%s] Camera relay is OFF; starting %u-byte HTTP transfer\n",
                tag, static_cast<unsigned int>(length));
  return true;
}

bool acquireCameraForStream() {
  if (capturing || cameraMutex == nullptr) {
    return false;
  }
  if (xSemaphoreTake(cameraMutex, 0) != pdTRUE) {
    return false;
  }
  if (capturing) {
    xSemaphoreGive(cameraMutex);
    return false;
  }

  streamAlive = true;
  return true;
}

void releaseCameraFromStream() {
  shutdownCamera();
  streamAlive = false;
  scheduleCameraFocusRelease();
  if (cameraMutex != nullptr) {
    xSemaphoreGive(cameraMutex);
  }
}

bool acquireCameraForCapture(const char* tag) {
  capturing = true;
  if (cameraMutex == nullptr) {
    Serial.printf("[%s] Camera mutex unavailable\n", tag);
    capturing = false;
    return false;
  }

  if (streamAlive) {
    Serial.printf("[%s] Capture requested; stopping stream first\n", tag);
    // A congested NetworkClient::write can otherwise retry for several
    // seconds. Closing this shared socket makes the stream task release the
    // camera mutex promptly before high-resolution capture begins.
    streamServer.client().stop();
  }
  if (xSemaphoreTake(
        cameraMutex,
        pdMS_TO_TICKS(CAMERA_MUTEX_TIMEOUT_MS)
      ) != pdTRUE) {
    Serial.printf("[%s] Timed out waiting for exclusive camera ownership\n", tag);
    capturing = false;
    return false;
  }

  Serial.printf("[%s] Exclusive camera ownership acquired\n", tag);
  return true;
}

void releaseCameraFromCapture() {
  capturing = false;
  if (cameraMutex != nullptr) {
    xSemaphoreGive(cameraMutex);
  }
}

bool sendStagedJpeg(WebServer& httpServer,
                    const char* tag,
                    const char* filename,
                    const uint8_t* jpegData,
                    size_t jpegLength) {
  if (jpegData == nullptr || jpegLength == 0) {
    return false;
  }

  const wifi_power_t previousTxPower = WiFi.getTxPower();
  const bool txPowerLowered =
      previousTxPower > CAPTURE_TX_WIFI_POWER &&
      WiFi.setTxPower(CAPTURE_TX_WIFI_POWER);
  if (txPowerLowered) {
    Serial.printf("[%s] WiFi TX power reduced %d -> %d for JPEG transfer\n",
                  tag,
                  static_cast<int>(previousTxPower),
                  static_cast<int>(CAPTURE_TX_WIFI_POWER));
  }

  char disposition[80];
  snprintf(disposition, sizeof(disposition),
           "inline; filename=%s", filename);
  httpServer.sendHeader("Access-Control-Allow-Origin", "*");
  httpServer.sendHeader("Cache-Control", "no-cache");
  httpServer.sendHeader("Content-Disposition", disposition);
  httpServer.setContentLength(jpegLength);
  httpServer.send(200, "image/jpeg", "");

  WiFiClient client = httpServer.client();
  size_t sent = 0;
  unsigned long lastProgressMs = millis();
  while (sent < jpegLength && client.connected()) {
    const size_t remaining = jpegLength - sent;
    const size_t chunkLength =
        remaining < JPEG_TX_CHUNK_BYTES ? remaining : JPEG_TX_CHUNK_BYTES;
    const size_t written = client.write(jpegData + sent, chunkLength);
    if (written > 0) {
      sent += written;
      lastProgressMs = millis();
    } else {
      if ((millis() - lastProgressMs) >= JPEG_TX_NO_PROGRESS_TIMEOUT_MS) {
        Serial.printf("[%s] JPEG transfer stalled at %u/%u bytes\n",
                      tag,
                      static_cast<unsigned int>(sent),
                      static_cast<unsigned int>(jpegLength));
        break;
      }
      delay(2);
    }
    delay(1);
  }

  if (txPowerLowered) {
    WiFi.setTxPower(previousTxPower);
  }

  const bool complete = sent == jpegLength;
  Serial.printf("[%s] HTTP transfer %s: %u/%u bytes\n",
                tag,
                complete ? "complete" : "failed",
                static_cast<unsigned int>(sent),
                static_cast<unsigned int>(jpegLength));
  return complete;
}

static bool writeStreamBytes(WiFiClient& client, const uint8_t* data,
                             size_t length, size_t* writtenOut) {
  size_t total = 0;
  unsigned long lastProgressMs = millis();
  while (total < length && client.connected()) {
    const size_t remaining = length - total;
    const size_t chunkLength = remaining < STREAM_TX_CHUNK_BYTES
      ? remaining
      : STREAM_TX_CHUNK_BYTES;
    const size_t written = client.write(data + total, chunkLength);
    if (written > 0) {
      total += written;
      lastProgressMs = millis();
      continue;
    }
    if ((millis() - lastProgressMs) >= STREAM_TX_NO_PROGRESS_TIMEOUT_MS) {
      break;
    }
    delay(1);
  }
  if (writtenOut != nullptr) *writtenOut = total;
  return total == length;
}

void handleStream() {
  if (!acquireCameraForStream()) {
    streamServer.sendHeader("Access-Control-Allow-Origin", "*");
    streamServer.send(503, "text/plain", "CAMERA BUSY");
    return;
  }

  Serial.println("[STREAM] Start");
  // Streaming must remain available when the P4 is booting or disconnected.
  // Capture paths still notify the P4, but a live preview never waits on a
  // callback before returning the MJPEG response to the phone.
  beginCameraFocus("stream", false);
  if (capturing) {
    streamServer.send(503, "text/plain", "CAPTURE PENDING");
    releaseCameraFromStream();
    return;
  }

  if (!STREAM_ADAPTIVE_UPGRADE_ENABLED) {
    streamBandwidthProfile = STREAM_PROFILE_FAR;
    Serial.println("[STREAM] Stable mode: FAR 320x240 5FPS; local telemetry active");
  }

  // Use the Freenove reference mode directly: QVGA JPEG, one framebuffer and
  // CAMERA_GRAB_WHEN_EMPTY. This avoids reconfiguring the OV5640 and avoids
  // continuous two-buffer DMA before the first frame is proven healthy.
  const StreamProfileConfig& initialProfile =
    STREAM_PROFILES[(int)streamBandwidthProfile];
  if (!initCamera(initialProfile.frameSize,
                  initialProfile.jpegQuality,
                  1)) {
    streamServer.send(503, "text/plain", "CAM FAIL");
    releaseCameraFromStream();
    return;
  }
  Serial.printf("[STREAM] Active profile -> %s\n", initialProfile.name);
  if (capturing) {
    streamServer.send(503, "text/plain", "CAPTURE PENDING");
    releaseCameraFromStream();
    return;
  }

  WiFiClient client = streamServer.client();
  client.setNoDelay(true);
  const char* responseHeaders =
    "HTTP/1.1 200 OK\r\n"
    "Content-Type: multipart/x-mixed-replace; boundary=fb\r\n"
    "Cache-Control: no-cache\r\n"
    "Pragma: no-cache\r\n"
    "Access-Control-Allow-Origin: *\r\n"
    "X-Stream-Mode: stable-far\r\n"
    // A close-delimited HTTP body is understood consistently by Android's
    // Dart socket/HTTP stacks. The connection still remains open until either
    // side intentionally ends this one long MJPEG response.
    "Connection: close\r\n\r\n"
  ;
  const size_t responseHeaderLength = strlen(responseHeaders);
  size_t responseHeaderWritten = 0;
  if (!writeStreamBytes(
        client,
        reinterpret_cast<const uint8_t*>(responseHeaders),
        responseHeaderLength,
        &responseHeaderWritten
      )) {
    Serial.printf(
      "[STREAM] Response header write failed: %u/%u bytes connected=%s\n",
      static_cast<unsigned int>(responseHeaderWritten),
      static_cast<unsigned int>(responseHeaderLength),
      client.connected() ? "yes" : "no"
    );
    releaseCameraFromStream();
    return;
  }

  float sendLoadEwma = 0.0f;
  int slowFrameCount = 0;
  unsigned long lowLoadSinceMs = 0;
  unsigned long profileChangedAtMs = millis();
  unsigned long lastTxLogMs = millis();
  uint32_t framesSent = 0;
  uint32_t frameTimeouts = 0;
  uint64_t bytesSent = 0;

  while (client.connected() && !capturing) {
    const unsigned long frameStartedAtMs = millis();
    camera_fb_t* fb = esp_camera_fb_get();
    if (!fb) {
      frameTimeouts++;
      if (frameTimeouts == 1 || (frameTimeouts % 3) == 0) {
        Serial.printf("[STREAM] Camera frame timeout #%lu; no JPEG received\n",
                      static_cast<unsigned long>(frameTimeouts));
      }
      delay(10);
      continue;
    }

    // A slow network can leave an older frame queued. Drop queued frames and
    // always send the newest complete image instead of growing visual latency.
    while (esp_camera_available_frames()) {
      camera_fb_t* newer = esp_camera_fb_get();
      if (!newer) break;
      esp_camera_fb_return(fb);
      fb = newer;
    }

    const size_t frameLength = fb->len;
    char partHeader[96];
    const int partHeaderLength = snprintf(
      partHeader,
      sizeof(partHeader),
      "--fb\r\nContent-Type: image/jpeg\r\nContent-Length: %u\r\n\r\n",
      static_cast<unsigned int>(frameLength)
    );

    const unsigned long sendStartedAtMs = millis();
    size_t headerWritten = 0;
    size_t imageWritten = 0;
    size_t trailerWritten = 0;
    if (partHeaderLength > 0 &&
        partHeaderLength < static_cast<int>(sizeof(partHeader))) {
      writeStreamBytes(
        client,
        reinterpret_cast<const uint8_t*>(partHeader),
        static_cast<size_t>(partHeaderLength),
        &headerWritten
      );
      if (headerWritten == static_cast<size_t>(partHeaderLength)) {
        writeStreamBytes(client, fb->buf, frameLength, &imageWritten);
      }
      if (imageWritten == frameLength) {
        static const uint8_t trailer[] = {'\r', '\n'};
        writeStreamBytes(client, trailer, sizeof(trailer), &trailerWritten);
      }
    }
    const unsigned long sendDurationMs = millis() - sendStartedAtMs;
    esp_camera_fb_return(fb);

    const bool partialWrite =
      partHeaderLength <= 0 ||
      partHeaderLength >= static_cast<int>(sizeof(partHeader)) ||
      headerWritten != static_cast<size_t>(partHeaderLength) ||
      imageWritten != frameLength ||
      trailerWritten != 2;
    if (partialWrite) {
      Serial.printf(
        "[STREAM] Partial write header=%u/%d image=%u/%u trailer=%u/2\n",
        static_cast<unsigned int>(headerWritten),
        partHeaderLength,
        static_cast<unsigned int>(imageWritten),
        static_cast<unsigned int>(frameLength),
        static_cast<unsigned int>(trailerWritten)
      );
      if (streamBandwidthProfile > STREAM_PROFILE_FAR) {
        streamBandwidthProfile = static_cast<StreamBandwidthProfile>(
          static_cast<int>(streamBandwidthProfile) - 1
        );
        Serial.printf(
          "[STREAM] Next connection will use %s\n",
          STREAM_PROFILES[(int)streamBandwidthProfile].name
        );
      }
      streamUpgradeBlockedUntilMs = millis() + 60000UL;
      break;
    }

    framesSent++;
    bytesSent += frameLength;
    if (framesSent == 1) {
      Serial.printf("[STREAM] First JPEG sent: %u bytes in %lu ms\n",
                    static_cast<unsigned int>(frameLength), sendDurationMs);
    }
    if ((millis() - lastTxLogMs) >= 10000UL) {
      Serial.printf("[STREAM] TX alive: frames=%lu bytes=%llu last=%uB/%lums\n",
                    static_cast<unsigned long>(framesSent),
                    static_cast<unsigned long long>(bytesSent),
                    static_cast<unsigned int>(frameLength), sendDurationMs);
      lastTxLogMs = millis();
    }

    if (streamBandwidthProfile == STREAM_PROFILE_FAR &&
        sendDurationMs > 1000UL) {
      Serial.printf(
        "[STREAM] Far profile too slow (%lu ms); reconnecting later\n",
        sendDurationMs
      );
      streamUpgradeBlockedUntilMs = millis() + 60000UL;
      break;
    }

    const unsigned long nowMs = millis();
    const StreamProfileConfig& activeConfig =
      STREAM_PROFILES[(int)streamBandwidthProfile];
    const float sendLoad =
      static_cast<float>(sendDurationMs) / activeConfig.frameIntervalMs;
    sendLoadEwma = sendLoadEwma == 0.0f
      ? sendLoad
      : (sendLoadEwma * 0.80f) + (sendLoad * 0.20f);

    const bool severelySlow =
      sendDurationMs > (static_cast<unsigned long>(activeConfig.frameIntervalMs) * 2UL);
    if (sendLoadEwma > 0.70f) {
      slowFrameCount++;
    } else {
      slowFrameCount = 0;
    }

    if (streamBandwidthProfile > STREAM_PROFILE_FAR &&
        (severelySlow || slowFrameCount >= 3)) {
      const StreamBandwidthProfile lowerProfile =
        static_cast<StreamBandwidthProfile>(
          static_cast<int>(streamBandwidthProfile) - 1
        );
      Serial.printf(
        "[STREAM] Congested send=%lu ms load=%.2f; stepping down\n",
        sendDurationMs,
        sendLoadEwma
      );
      if (applyStreamBandwidthProfile(lowerProfile)) {
        streamUpgradeBlockedUntilMs = millis() + 60000UL;
        profileChangedAtMs = millis();
        sendLoadEwma = 0.0f;
        slowFrameCount = 0;
        lowLoadSinceMs = 0;
      } else {
        break;
      }
    } else {
      const bool upgradeBlocked =
        streamUpgradeBlockedUntilMs != 0 &&
        static_cast<int32_t>(streamUpgradeBlockedUntilMs - nowMs) > 0;
      if (STREAM_ADAPTIVE_UPGRADE_ENABLED &&
          streamBandwidthProfile < STREAM_PROFILE_NEAR &&
          !upgradeBlocked && sendLoadEwma < 0.30f) {
        if (lowLoadSinceMs == 0) lowLoadSinceMs = nowMs;

        const bool sustainedHeadroom = nowMs - lowLoadSinceMs >= 18000UL;
        const bool profileSettled = nowMs - profileChangedAtMs >= 20000UL;
        if (sustainedHeadroom && profileSettled) {
          const StreamBandwidthProfile higherProfile =
            static_cast<StreamBandwidthProfile>(
              static_cast<int>(streamBandwidthProfile) + 1
            );
          Serial.printf(
            "[STREAM] Stable load=%.2f; trying higher bandwidth\n",
            sendLoadEwma
          );
          if (applyStreamBandwidthProfile(higherProfile)) {
            profileChangedAtMs = millis();
            sendLoadEwma = 0.0f;
            slowFrameCount = 0;
            lowLoadSinceMs = 0;
          } else {
            streamUpgradeBlockedUntilMs = millis() + 60000UL;
            lowLoadSinceMs = 0;
          }
        }
      } else {
        lowLoadSinceMs = 0;
      }
    }

    const unsigned long frameElapsedMs = millis() - frameStartedAtMs;
    const uint16_t frameIntervalMs =
      STREAM_PROFILES[(int)streamBandwidthProfile].frameIntervalMs;
    if (frameElapsedMs < frameIntervalMs) {
      delay(frameIntervalMs - frameElapsedMs);
    } else {
      yield();
    }
  }

  // Drop any queued TCP data immediately after a failed/overloaded stream.
  client.stop();
  Serial.printf("[STREAM] Stopped: frames=%lu bytes=%llu capture=%s\n",
                static_cast<unsigned long>(framesSent),
                static_cast<unsigned long long>(bytesSent),
                capturing ? "yes" : "no");
  releaseCameraFromStream();
}

void handleCapture() {
  Serial.println("[CAPTURE] Request");
  String normalized;
  String ledError;
  bool selected[INTAKE_SLOT_LED_COUNT] = {};
  int selectedCount = 0;
  int queryResult = parseSelectedLedQuery(
      normalized, selected, selectedCount, ledError);
  if (queryResult == SELECTED_LED_QUERY_INVALID) {
    server.send(400, "text/plain", ledError);
    return;
  }

  if (!acquireCameraForCapture("CAPTURE")) {
    server.send(503, "text/plain", "CAMERA BUSY");
    return;
  }

  beginCameraFocus("mobile capture", true);
  if (queryResult == SELECTED_LED_QUERY_VALID) {
    if (!activateSelectedLeds(
            normalized, selected, selectedCount, ledError)) {
      server.send(502, "text/plain", ledError);
      scheduleCameraFocusRelease();
      releaseCameraFromCapture();
      return;
    }
  } else {
    notifyLedController("/candling_start");
  }
  shutdownCamera();
  delay(500);

  Serial.println("[CAPTURE] Init maximum 5MP mode");
  if (!initCamera(CANDLING_CAPTURE_FRAME_SIZE,
                  CANDLING_CAPTURE_JPEG_QUALITY, 1)) {
    server.send(503, "text/plain", "CAM FAIL");
    notifyLedController("/candling_stop");
    scheduleCameraFocusRelease();
    releaseCameraFromCapture();
    return;
  }

  if (!applyCandlingCaptureProfile()) {
    Serial.println("[CAPTURE] Fixed candling profile failed; capture aborted");
    server.send(503, "text/plain", "CANDLING PROFILE FAIL");
    shutdownCamera();
    notifyLedController("/candling_stop");
    scheduleCameraFocusRelease();
    releaseCameraFromCapture();
    return;
  }

  // Let the manual profile settle under the selected underlights.
  // acquireCameraFrame() then discards stale frames.
  delay(CAMERA_SENSOR_SETTLE_MS);

  camera_fb_t* fb = acquireCameraFrame("CAPTURE");
  if (!fb) {
    server.send(503, "text/plain", "FRAME FAIL");
    shutdownCamera();
    notifyLedController("/candling_stop");
    scheduleCameraFocusRelease();
    releaseCameraFromCapture();
    return;
  }

  uint8_t* jpegData = nullptr;
  size_t jpegLength = 0;
  if (!stageCapturedJpegForLowPowerTransfer(
          fb, "CAPTURE", &jpegData, &jpegLength)) {
    server.send(503, "text/plain", "JPEG STAGE OOM");
    notifyLedController("/candling_stop");
    scheduleCameraFocusRelease();
    releaseCameraFromCapture();
    return;
  }

  const bool transferComplete = sendStagedJpeg(
      server, "CAPTURE", "capture.jpg", jpegData, jpegLength);
  heap_caps_free(jpegData);
  delay(800);

  notifyLedController("/candling_stop");
  scheduleCameraFocusRelease();
  releaseCameraFromCapture();
  Serial.printf("[CAPTURE] Done transfer=%s\n",
                transferComplete ? "complete" : "failed");
}

void handleCaptureP4() {
  Serial.println("[CAPTURE_P4] Request");
  if (!acquireCameraForCapture("CAPTURE_P4")) {
    server.send(503, "text/plain", "CAMERA BUSY");
    return;
  }

  beginCameraFocus("P4 capture", true);
  shutdownCamera();
  delay(500);

  if (!initCamera(FRAMESIZE_UXGA, 5, 1)) {
    server.send(503, "text/plain", "CAM FAIL");
    scheduleCameraFocusRelease();
    releaseCameraFromCapture();
    return;
  }

  delay(CAMERA_SENSOR_SETTLE_MS);

  camera_fb_t* fb = acquireCameraFrame("CAPTURE_P4");
  if (!fb) {
    server.send(503, "text/plain", "FRAME FAIL");
    shutdownCamera();
    scheduleCameraFocusRelease();
    releaseCameraFromCapture();
    return;
  }

  uint8_t* jpegData = nullptr;
  size_t jpegLength = 0;
  if (!stageCapturedJpegForLowPowerTransfer(
          fb, "CAPTURE_P4", &jpegData, &jpegLength)) {
    server.send(503, "text/plain", "JPEG STAGE OOM");
    scheduleCameraFocusRelease();
    releaseCameraFromCapture();
    return;
  }

  const bool transferComplete = sendStagedJpeg(
      server, "CAPTURE_P4", "capturep4.jpg", jpegData, jpegLength);
  heap_caps_free(jpegData);
  delay(800);

  scheduleCameraFocusRelease();
  releaseCameraFromCapture();
  Serial.printf("[CAPTURE_P4] Done transfer=%s\n",
                transferComplete ? "complete" : "failed");
}

void handleSensorData() {
  if (server.method() != HTTP_POST) {
    server.send(405, "text/plain", "Method Not Allowed");
    return;
  }
  String body = server.arg("plain");
  if (body.length() == 0) {
    server.send(400, "text/plain", "No body");
    return;
  }
  DynamicJsonDocument doc(512);
  DeserializationError error = deserializeJson(doc, body);
  if (error) {
    server.send(400, "text/plain", "Invalid JSON");
    return;
  }
  // /sensordata carries the MAIN incubator climate from the P4 (SHT3X).
  if (doc.containsKey("temp")) {
    latestTemp = doc["temp"];
    latestTempValid = true;
  } else {
    latestTempValid = false;
  }
  bool hasHum = doc.containsKey("hum");
  if (hasHum) latestHum = doc["hum"];
  if (doc.containsKey("humValid")) {
    latestHumValid = hasHum && doc["humValid"];
  } else {
    latestHumValid = hasHum;
  }
  if (doc.containsKey("mainBulb")) {
    mainBulbOn = doc["mainBulb"].as<bool>();
    mainBulbStateReceived = true;
  }
  lastSensorMs = millis();
  sensorDataReceived = true;
  Serial.printf("[SENSOR] T=%.1fC tempValid=%s H=%.1f%% humValid=%s mainBulb=%s owner=P4_GPIO33\n",
                latestTemp,
                latestTempValid ? "true" : "false",
                latestHum,
                latestHumValid ? "true" : "false",
                mainBulbOn ? "ON" : "OFF");
  server.sendHeader("Access-Control-Allow-Origin", "*");
  server.send(200, "text/plain", "OK");
}

// SUB incubator (lockdown relay node) climate. Kept separate from the main
// /sensordata so the two incubators never overwrite each other.
void handleSubSensorData() {
  if (server.method() != HTTP_POST) {
    server.send(405, "text/plain", "Method Not Allowed");
    return;
  }
  String body = server.arg("plain");
  if (body.length() == 0) {
    server.send(400, "text/plain", "No body");
    return;
  }
  DynamicJsonDocument doc(512);
  DeserializationError error = deserializeJson(doc, body);
  if (error) {
    server.send(400, "text/plain", "Invalid JSON");
    return;
  }
  if (doc.containsKey("temp")) {
    subTemp = doc["temp"];
    subTempValid = true;
  } else {
    subTempValid = false;
  }
  bool hasHum = doc.containsKey("hum");
  if (hasHum) subHum = doc["hum"];
  if (doc.containsKey("humValid")) {
    subHumValid = hasHum && doc["humValid"];
  } else {
    subHumValid = hasHum;
  }
  if (doc.containsKey("waterLevel")) {
    subWaterLevel = constrain(doc["waterLevel"].as<int>(), 0, 100);
    subWaterLow = doc.containsKey("waterLow") ? doc["waterLow"].as<bool>()
                                              : subWaterLevel < WATER_LOW_PERCENT;
    subWaterRaw = doc.containsKey("waterRaw") ? doc["waterRaw"].as<int>()
                                              : subWaterLevel;
  }
  if (doc.containsKey("bulb")) {
    subBulbOn = doc["bulb"];
  }
  if (doc.containsKey("humidifier")) {
    subHumidifierOn = doc["humidifier"];
  }
  if (doc.containsKey("uptimeMs")) {
    subIncubatorUptimeMs = doc["uptimeMs"];
  }
  lastSubMs = millis();
  subDataReceived = true;
  Serial.printf("[SUB] T=%.1fC H=%.1f%% water=%d%% low=%s bulb=%s hum=%s\n",
                subTemp, subHum, subWaterLevel,
                subWaterLow ? "true" : "false",
                subBulbOn ? "ON" : "OFF",
                subHumidifierOn ? "ON" : "OFF");
  server.sendHeader("Access-Control-Allow-Origin", "*");
  server.send(200, "text/plain", "OK");
}

void handleGetSensor() {
  // App reads /sensor via POST; the P4 LCD poller uses GET. A POST = the app is
  // active, so the P4 can back off its own polling.
  if (server.method() == HTTP_POST) {
    lastAppActivityMs = millis();
  }
  DynamicJsonDocument doc(1024);

  // --- MAIN incubator: telemetry mirrored from the P4. ---
  doc["temp"] = latestTemp;
  doc["tempValid"] = latestTempValid;
  doc["hum"] = latestHum;
  doc["humValid"] = latestHumValid;
  doc["waterRaw"] = 0;
  doc["waterLevel"] = 0;
  doc["waterLow"] = false;
  doc["waterReceived"] = false;
  doc["waterTs"] = 0;
  doc["waterLowPercent"] = WATER_LOW_PERCENT;
  doc["waterSource"] = "none";
  doc["waterAgeMs"] = 0;
  doc["ts"] = lastSensorMs;
  doc["received"] = sensorDataReceived;
  doc["sensorAgeMs"] = sensorDataReceived ? (millis() - lastSensorMs) : 0;
  bool mainFresh =
      sensorDataReceived &&
      latestTempValid &&
      latestHumValid &&
      ((millis() - lastSensorMs) <= SENSOR_STALE_MS);
  doc["sensorFresh"] = mainFresh;
  doc["mainConnected"] =
      sensorDataReceived && ((millis() - lastSensorMs) <= SENSOR_STALE_MS);
  doc["mainAgeMs"] = sensorDataReceived ? (millis() - lastSensorMs) : 0;
  doc["mainBulb"] = mainBulbOn;
  doc["mainBulbStateReceived"] = mainBulbStateReceived;
  doc["mainBulbOwner"] = "p4_gpio33";
  doc["mainHumidifier"] = false;
  doc["mainHumidifierAvailable"] = false;
  doc["appConnected"] =
      lastAppActivityMs > 0 &&
      ((millis() - lastAppActivityMs) <= APP_ACTIVE_TIMEOUT_MS);

  // --- SUB incubator (lockdown relay node) via /subsensordata ---
  bool subFresh = subDataReceived && ((millis() - lastSubMs) <= SENSOR_STALE_MS);
  doc["subConnected"] = subFresh;
  doc["subAgeMs"] = subDataReceived ? (millis() - lastSubMs) : 0;
  doc["subTemp"] = subTemp;
  doc["subTempValid"] = subTempValid;
  doc["subHum"] = subHum;
  doc["subHumValid"] = subHumValid;
  doc["subWaterRaw"] = subWaterRaw;
  doc["subWaterLevel"] = subWaterLevel;
  doc["subWaterLow"] = subWaterLow;
  doc["subBulb"] = subBulbOn;
  doc["subHumidifier"] = subHumidifierOn;
  doc["subUptimeMs"] = subIncubatorUptimeMs;
  // Backward-compatible aliases (now point at the real sub-incubator data).
  doc["subIncubatorConnected"] = subFresh;
  doc["subIncubatorAgeMs"] = subDataReceived ? (millis() - lastSubMs) : 0;
  doc["subIncubatorBulb"] = subBulbOn;
  doc["subIncubatorHumidifier"] = subHumidifierOn;
  doc["subIncubatorUptimeMs"] = subIncubatorUptimeMs;
  String response;
  serializeJson(doc, response);
  server.sendHeader("Access-Control-Allow-Origin", "*");
  server.send(200, "application/json", response);
}

bool startCandlingAccessPoint() {
  WiFi.mode(WIFI_AP);
  const bool started = WiFi.softAP(
      ssid,
      pass,
      WIFI_AP_CHANNEL,
      0,
      WIFI_AP_MAX_CONNECTIONS);
  wifiApStarted = started;
  if (started) {
    Serial.printf(
        "[AP] Started %s on channel %u with capacity %u. IP=%s\n",
        ssid,
        (unsigned int)WIFI_AP_CHANNEL,
        (unsigned int)WIFI_AP_MAX_CONNECTIONS,
        WiFi.softAPIP().toString().c_str());
  } else {
    Serial.println("[AP] Start failed; the loop will keep retrying.");
  }
  return started;
}

void maintainCandlingAccessPoint() {
  const unsigned long now = millis();
  if ((now - lastWifiApHealthMs) < WIFI_AP_HEALTH_INTERVAL_MS) return;
  lastWifiApHealthMs = now;

  const wifi_mode_t mode = WiFi.getMode();
  const IPAddress apIp = WiFi.softAPIP();
  const bool apModeActive = mode == WIFI_AP || mode == WIFI_AP_STA;
  const bool healthy = wifiApStarted && apModeActive && apIp[0] != 0;
  if (!healthy) {
    if (wifiApHealthFailureCount < UINT8_MAX) wifiApHealthFailureCount++;
    Serial.printf(
        "[AP] Health miss %u/%u: started=%s mode=%d ip=%s\n",
        static_cast<unsigned int>(wifiApHealthFailureCount),
        static_cast<unsigned int>(WIFI_AP_HEALTH_FAILURE_LIMIT),
        wifiApStarted ? "true" : "false",
        static_cast<int>(mode),
        apIp.toString().c_str());
    if (wifiApHealthFailureCount < WIFI_AP_HEALTH_FAILURE_LIMIT) return;

    wifiApRestartCount++;
    wifiApHealthFailureCount = 0;
    Serial.printf("[AP] Restarting access point after repeated failures (restart %lu).\n",
                  static_cast<unsigned long>(wifiApRestartCount));
    WiFi.softAPdisconnect(true);
    wifiApStarted = false;
    lastWifiApStationCount = -1;
    startCandlingAccessPoint();
    return;
  }

  if (wifiApHealthFailureCount != 0) {
    Serial.printf("[AP] Health recovered after %u miss(es).\n",
                  static_cast<unsigned int>(wifiApHealthFailureCount));
    wifiApHealthFailureCount = 0;
  }

  const int stationCount = WiFi.softAPgetStationNum();
  if (stationCount != lastWifiApStationCount) {
    lastWifiApStationCount = stationCount;
    Serial.printf(
        "[AP] Connected stations: %d/%u\n",
        stationCount,
        (unsigned int)WIFI_AP_MAX_CONNECTIONS);
  }
}

void handleStreamRedirect() {
  const String location =
      String("http://") + WiFi.softAPIP().toString() + ":" +
      String(STREAM_HTTP_PORT) + "/stream";
  server.sendHeader("Access-Control-Allow-Origin", "*");
  server.sendHeader("Location", location, true);
  server.send(307, "text/plain", "Stream moved to port 81");
}

void handleStreamNotFound() {
  streamServer.sendHeader("Access-Control-Allow-Origin", "*");
  streamServer.send(
      404,
      "application/json",
      "{\"error\":\"not_found\",\"hint\":\"MJPEG is available at /stream on port 81\"}");
}

void streamServerTask(void* parameter) {
  (void)parameter;
  Serial.printf("[STREAM] HTTP task ready on port %u\n",
                static_cast<unsigned int>(STREAM_HTTP_PORT));
  while (true) {
    streamServer.handleClient();
    vTaskDelay(pdMS_TO_TICKS(2));
  }
}

void handleNotFound() {
  const String remoteIp = server.client().remoteIP().toString();
  Serial.printf("[HTTP] 404 method=%d uri=%s remote=%s\n",
                static_cast<int>(server.method()),
                server.uri().c_str(),
                remoteIp.c_str());
  server.sendHeader("Access-Control-Allow-Origin", "*");
  server.send(404, "application/json",
              "{\"error\":\"not_found\",\"hint\":\"S3 listens on 192.168.4.1 port 80; P4 is 192.168.4.50\"}");
}

void setup() {
  Serial.begin(115200);
  Serial.setDebugOutput(true);
  cameraMutex = xSemaphoreCreateMutexStatic(&cameraMutexStorage);

  bootResetReason = esp_reset_reason();

  initRelayOutputOff(CAMERA_RELAY_GPIO, CAMERA_RELAY_OFF);
  mainBulbOn = true;
  mainBulbStateReceived = false;
  sensorDataReceived = false;
  latestTempValid = false;
  latestHumValid = false;
  Serial.printf("[BOOT] Reset reason: %s (%d)\n",
                resetReasonName(bootResetReason),
                static_cast<int>(bootResetReason));
  Serial.println("[BOOT] S3 hardware profile: camera relay only; climate hardware removed");

  startCandlingAccessPoint();

  Serial.println("\n=== AP MODE ACTIVE ===");
  Serial.print("SSID: "); Serial.println(ssid);
  Serial.print("IP:   "); Serial.println(WiFi.softAPIP());

  // Mobile app endpoints:
  // - :81/stream: live preview on its own task and socket
  // - /capture: mobile-app candling capture for fertile/infertile AI
  // - /sensor: read-only temp/humidity display for the app
  // - /actuators: camera-only hardware status plus P4-reported bulb state
  // - /humidifier: compatibility no-op; S3 humidifier hardware was removed
  // - /door?state=open|closed: door state from P4 reed switch
  // - /ai_power?state=on|off: compatibility state for the P4 protocol.
  //   Camera relay remains owned only by capture/stream.
  server.on("/health", HTTP_GET, sendRuntimeHealth);
  server.on("/health", HTTP_POST, sendRuntimeHealth);
  server.on("/stream", HTTP_GET, handleStreamRedirect);
  server.on("/capture", HTTP_GET, handleCapture);
  server.on("/sensor", HTTP_GET, handleGetSensor);
  server.on("/sensor", HTTP_POST, handleGetSensor);
  server.on("/actuators", HTTP_GET, sendActuatorStatus);
  server.on("/actuators", HTTP_POST, sendActuatorStatus);
  server.on("/humidifier", HTTP_GET, handleHumidifier);
  server.on("/humidifier", HTTP_POST, handleHumidifier);
  server.on("/door", HTTP_GET, handleDoorState);
  server.on("/door", HTTP_POST, handleDoorState);
  server.on("/ai_power", HTTP_GET, handleAiPower);
  server.on("/ai_power", HTTP_POST, handleAiPower);

  // External 56 LED controller endpoints used by the mobile app:
  // - /led/status: read current LED controller state
  // - /led/led_test?led=1..56|1,2,3|all|off|chase&mode=set|add|remove|toggle
  // - /led/slots_sync: pull P4 slot cache into the LED controller
  // - /led/candling_start: light occupied egg slots
  // - /led/candling_stop: all LEDs off
  server.on("/led/status", HTTP_GET, handleLedControllerStatus);
  server.on("/led/status", HTTP_POST, handleLedControllerStatus);
  server.on("/led/led_test", HTTP_GET, handleLedControllerTest);
  server.on("/led/led_test", HTTP_POST, handleLedControllerTest);
  server.on("/led/slots_sync", HTTP_GET, handleLedControllerSlotsSync);
  server.on("/led/slots_sync", HTTP_POST, handleLedControllerSlotsSync);
  server.on("/led/candling_start", HTTP_GET, handleLedControllerCandlingStart);
  server.on("/led/candling_start", HTTP_POST, handleLedControllerCandlingStart);
  server.on("/led/candling_stop", HTTP_GET, handleLedControllerCandlingStop);
  server.on("/led/candling_stop", HTTP_POST, handleLedControllerCandlingStop);

  // Grid/dataset sensor-source endpoints:
  // - /capturep4: high-resolution lit capture for one-time grid setup and dataset gathering
  // - /sensordata: sensor source updates values read by /sensor
  server.on("/capturep4", HTTP_GET, handleCaptureP4);
  server.on("/sensordata", HTTP_POST, handleSensorData);
  server.on("/subsensordata", HTTP_POST, handleSubSensorData);

  // P4 proxy endpoints used by the mobile app:
  // - /p4/get_slots: read egg count and day metadata
  // - /p4/set_slots: app dashboard slot/date metadata -> P4
  // - /p4/set_fertility_results: phone AI verdicts -> P4 persistence/LCD
  // - /p4/candling_start: external LEDs on, P4 bulb off, then stop the tray
  // - /p4/candling_stop: external LEDs off, P4 bulb restored, tray resumed
  // - /p4/capture_hold_start: stop tray for /capturep4 without slot LEDs
  // - /p4/capture_hold_stop: resume tray after app-side /capturep4
  // - /p4/led_test?zone=0|1|2|all|off: identify temporary slot LED zones
  // - /p4/set_infertile: day-7+ infertile slot list only
  // - /p4/get_infertile: read the last infertile slot list
  // - /p4/clear_infertile: clear app-provided infertile slots
  // - /p4/blink_infertile: blink LEDs for the last infertile list
  // - /p4/grid_config: send custom grid bounds to P4
  // - /p4/get_grid_config: read active P4 grid bounds
  // - /p4/reset_grid_config: restore default P4 grid bounds
  // - /p4/time_sync: phone clock -> P4 system clock + DS3231 RTC
  // - /p4/diagnostic_alerts: M6-M9 occupied-slot alert bench testing
  server.on("/p4/candling_start", HTTP_GET, handleP4CandlingStart);
  server.on("/p4/candling_start", HTTP_POST, handleP4CandlingStart);
  server.on("/p4/candling_stop", HTTP_GET, handleP4CandlingStop);
  server.on("/p4/candling_stop", HTTP_POST, handleP4CandlingStop);
  server.on("/p4/capture_hold_start", HTTP_GET, handleP4CaptureHoldStart);
  server.on("/p4/capture_hold_start", HTTP_POST, handleP4CaptureHoldStart);
  server.on("/p4/capture_hold_stop", HTTP_GET, handleP4CaptureHoldStop);
  server.on("/p4/capture_hold_stop", HTTP_POST, handleP4CaptureHoldStop);
  server.on("/p4/led_test", HTTP_GET, handleP4LedTest);
  server.on("/p4/led_test", HTTP_POST, handleP4LedTest);
  server.on("/p4/blink_infertile", HTTP_GET, handleP4BlinkInfertile);
  server.on("/p4/blink_infertile", HTTP_POST, handleP4BlinkInfertile);
  server.on("/p4/get_slots", HTTP_GET, handleP4GetSlots);
  server.on("/p4/get_slots", HTTP_POST, handleP4GetSlots);
  server.on("/p4/set_slots", HTTP_POST, handleP4SetSlots);
  server.on("/p4/set_fertility_results", HTTP_POST,
            handleP4SetFertilityResults);
  server.on("/p4/diagnostic_alerts", HTTP_POST, handleP4DiagnosticAlerts);
  server.on("/p4/get_infertile", HTTP_GET, handleP4GetInfertile);
  server.on("/p4/get_infertile", HTTP_POST, handleP4GetInfertile);
  server.on("/p4/set_infertile", HTTP_POST, handleP4SetInfertile);
  server.on("/p4/clear_infertile", HTTP_POST, handleP4ClearInfertile);
  server.on("/p4/grid_config", HTTP_POST, handleP4GridConfig);
  server.on("/p4/time_sync", HTTP_POST, handleP4TimeSync);
  server.on("/p4/get_grid_config", HTTP_GET, handleP4GetGridConfig);
  server.on("/p4/get_grid_config", HTTP_POST, handleP4GetGridConfig);
  server.on("/p4/reset_grid_config", HTTP_POST, handleP4ResetGridConfig);
  server.onNotFound(handleNotFound);
  server.begin();

  streamServer.on("/stream", HTTP_GET, handleStream);
  streamServer.onNotFound(handleStreamNotFound);
  streamServer.begin();
  const BaseType_t streamTaskResult = xTaskCreate(
      streamServerTask,
      "stream_http",
      12288,
      nullptr,
      2,
      &streamServerTaskHandle);

  Serial.printf("CONTROL SERVER READY :%u\n",
                static_cast<unsigned int>(CONTROL_HTTP_PORT));
  Serial.printf("STREAM SERVER %s :%u\n",
                streamTaskResult == pdPASS ? "READY" : "FAILED",
                static_cast<unsigned int>(STREAM_HTTP_PORT));
}

void loop() {
  server.handleClient();

  const unsigned long now = millis();
  maintainCandlingAccessPoint();
  logRuntimeHealth();
  serviceCameraFocusRelease();
  if (aiPowerSave && (now - aiPowerSaveMs) >= AI_POWER_SAVE_TIMEOUT_MS) {
    Serial.println("[AI_POWER] Timeout release");
    setAiPowerSave(false);
  }

}
