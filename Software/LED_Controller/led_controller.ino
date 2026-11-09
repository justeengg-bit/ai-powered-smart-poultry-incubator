#include <WiFi.h>
#include <WebServer.h>
#include <HTTPClient.h>
#include <esp_heap_caps.h>
#include <string.h>

const char* WIFI_SSID = "AI_CANDLING";
const char* WIFI_PASSWORD = "thesis123";
const char* P4_SLOTS_URL = "http://192.168.4.50/get_slots";

IPAddress localIp(192, 168, 4, 60);
IPAddress gateway(192, 168, 4, 1);
IPAddress subnet(255, 255, 255, 0);

WebServer server(80);

const int dataPin = 21;
const int latchPin = 19;
const int clockPin = 17;

const int NUM_REGISTERS = 7;
const int NUM_LEDS = 56;
const unsigned long CHASE_DELAY_MS = 250;
const unsigned long WIFI_RETRY_MS = 5000;
// Any steady LED command owns a finite lease. The command must be renewed or
// all outputs turn off locally even if the S3, P4, app, or WiFi disappears.
const unsigned long CANDLING_TIMEOUT_MS = 120000;
const unsigned long AUTO_SLOT_SYNC_MS = 30000;
const unsigned long P4_BODY_READ_TIMEOUT_MS = 2000;
const size_t SLOT_JSON_CAPACITY = 24576;

byte registerData[NUM_REGISTERS];
byte recentEggMaskFallback[NUM_REGISTERS];
byte previousEggMaskFallback[NUM_REGISTERS];
byte *recentEggMask = recentEggMaskFallback;
byte *previousEggMask = previousEggMaskFallback;
char slotJsonBufferStatic[SLOT_JSON_CAPACITY];
char *slotJsonBuffer = slotJsonBufferStatic;
bool candlingActive = false;
bool wifiWasConnected = false;
bool recentSlotCacheValid = false;
bool previousSlotCacheValid = false;
bool psramAvailable = false;
bool slotMasksInPsram = false;
bool slotJsonBufferInPsram = false;
int activeLedCount = 0;
int recentEggCount = 0;
int previousEggCount = 0;
size_t psramTotalBytes = 0;
size_t psramFreeBytesAtBoot = 0;
size_t lastSlotJsonBytes = 0;
unsigned long candlingStartedMs = 0;
unsigned long lastWifiAttemptMs = 0;
unsigned long lastSlotSyncMs = 0;
unsigned long lastAutoSlotSyncAttemptMs = 0;

// Removal-guidance blink: the P4 sends the infertile (7+ day) cells when the
// door opens so the farmer can see which eggs to pull, and an "off" when the
// door closes so the ICs/LEDs are not left driven. Blinking is done here on the
// controller (single command from the P4) instead of spamming on/off requests.
byte blinkMask[NUM_REGISTERS];
bool blinkActive = false;
bool blinkPhaseOn = false;
unsigned long blinkLastToggleMs = 0;
unsigned long blinkStartedMs = 0;
const unsigned long BLINK_INTERVAL_MS = 450;     // ~1.1 Hz on/off
const unsigned long BLINK_SAFETY_TIMEOUT_MS = 600000UL;  // 10 min fail-safe off

// Door-open guidance has two deliberately different patterns. Infertile or
// abnormal eggs to remove stay steadily lit; normal day-19+ eggs blink slowly
// for transfer. The P4 renews this finite lease while the door remains open.
byte removalGuidanceMask[NUM_REGISTERS];
byte transferGuidanceMask[NUM_REGISTERS];
bool guidanceActive = false;
int removalGuidanceCount = 0;
int transferGuidanceCount = 0;
unsigned long guidanceStartedMs = 0;
unsigned long guidanceLeaseMs = 90000UL;
int guidanceLastPhase = -1;
const unsigned long GUIDANCE_DEFAULT_LEASE_MS = 90000UL;
const unsigned long GUIDANCE_MIN_LEASE_MS = 10000UL;
const unsigned long GUIDANCE_MAX_LEASE_MS = 600000UL;
const unsigned long GUIDANCE_CYCLE_MS = 2400UL;

void clearMask(byte mask[NUM_REGISTERS]);

void initStorage() {
  clearMask(recentEggMaskFallback);
  clearMask(previousEggMaskFallback);

  psramTotalBytes = heap_caps_get_total_size(MALLOC_CAP_SPIRAM);
  psramFreeBytesAtBoot = heap_caps_get_free_size(MALLOC_CAP_SPIRAM);
  psramAvailable = psramTotalBytes > 0;
  psramAvailable = false;  // PSRAM disabled - use internal RAM only

  if (psramAvailable) {
    byte *recent = (byte *)heap_caps_malloc(NUM_REGISTERS, MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
    byte *previous = (byte *)heap_caps_malloc(NUM_REGISTERS, MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
    if (recent != NULL && previous != NULL) {
      recentEggMask = recent;
      previousEggMask = previous;
      clearMask(recentEggMask);
      clearMask(previousEggMask);
      slotMasksInPsram = true;
    } else {
      if (recent != NULL) heap_caps_free(recent);
      if (previous != NULL) heap_caps_free(previous);
      recentEggMask = recentEggMaskFallback;
      previousEggMask = previousEggMaskFallback;
    }
  } else {
    psramAvailable = false;
  }

  // Slot JSON buffer is now static, always available
  slotJsonBuffer = slotJsonBufferStatic;
  slotJsonBuffer[0] = '\0';
  slotJsonBufferInPsram = false;

  Serial.print("PSRAM: ");
  Serial.print(psramAvailable ? "available" : "not available");
  Serial.print(" total=");
  Serial.print(psramTotalBytes);
  Serial.print(" free_at_boot=");
  Serial.println(psramFreeBytesAtBoot);
  Serial.print("Slot masks storage: ");
  Serial.println(slotMasksInPsram ? "PSRAM" : "fallback RAM");
  Serial.print("Slot JSON buffer: static (");
  Serial.print(SLOT_JSON_CAPACITY);
  Serial.print(" bytes)");
  Serial.println();
}

void clearMask(byte mask[NUM_REGISTERS]) {
  for (int i = 0; i < NUM_REGISTERS; i++) {
    mask[i] = 0;
  }
}

void copyMask(byte dst[NUM_REGISTERS], const byte src[NUM_REGISTERS]) {
  for (int i = 0; i < NUM_REGISTERS; i++) {
    dst[i] = src[i];
  }
}

int countMask(const byte mask[NUM_REGISTERS]) {
  int count = 0;
  for (int reg = 0; reg < NUM_REGISTERS; reg++) {
    byte value = mask[reg];
    for (int bit = 0; bit < 8; bit++) {
      if (value & (1 << bit)) {
        count++;
      }
    }
  }
  return count;
}

void clearAllRegisters() {
  clearMask(registerData);
}

void updateShiftRegisters() {
  digitalWrite(latchPin, LOW);

  // Send last chip first, then chip 1 last.
  for (int i = NUM_REGISTERS - 1; i >= 0; i--) {
    shiftOut(dataPin, clockPin, MSBFIRST, registerData[i]);
  }

  digitalWrite(latchPin, HIGH);
}

bool isValidLedIndex(int ledIndex) {
  return ledIndex >= 0 && ledIndex < NUM_LEDS;
}

void setLEDInMask(byte mask[NUM_REGISTERS], int ledIndex, bool state) {
  if (!isValidLedIndex(ledIndex)) return;

  int registerIndex = ledIndex / 8;
  int bitIndex = ledIndex % 8;

  if (state) {
    mask[registerIndex] |= (1 << bitIndex);
  } else {
    mask[registerIndex] &= ~(1 << bitIndex);
  }
}

void setLED(int ledIndex, bool state) {
  setLEDInMask(registerData, ledIndex, state);
}

void cancelGuidanceState() {
  guidanceActive = false;
  clearMask(removalGuidanceMask);
  clearMask(transferGuidanceMask);
  removalGuidanceCount = 0;
  transferGuidanceCount = 0;
  guidanceLastPhase = -1;
}

void applyMask(const byte mask[NUM_REGISTERS]) {
  copyMask(registerData, mask);
  activeLedCount = countMask(registerData);
  updateShiftRegisters();
}

void updateSlotCache(const byte mask[NUM_REGISTERS], int eggCount) {
  copyMask(recentEggMask, mask);
  recentEggCount = eggCount;
  recentSlotCacheValid = true;
  previousSlotCacheValid = false;  // Discard previous data on new sync
  lastSlotSyncMs = millis();
}

bool applyRecentEggMask() {
  if (!recentSlotCacheValid) {
    return false;
  }

  cancelGuidanceState();
  blinkActive = false;
  applyMask(recentEggMask);
  candlingActive = true;
  candlingStartedMs = millis();
  Serial.print("Candling LEDs lit from recent cache; eggs=");
  Serial.println(recentEggCount);
  return true;
}

void onlyLed(int ledNumber) {
  cancelGuidanceState();
  blinkActive = false;
  clearAllRegisters();
  setLED(ledNumber - 1, true);
  activeLedCount = 1;
  updateShiftRegisters();
  candlingActive = true;
  candlingStartedMs = millis();

  Serial.print("ONLY LED ");
  Serial.print(ledNumber);
  Serial.println(" ENABLED");
}

void addLed(int ledNumber) {
  cancelGuidanceState();
  blinkActive = false;
  setLED(ledNumber - 1, true);
  activeLedCount = countMask(registerData);
  updateShiftRegisters();
  candlingActive = activeLedCount > 0;
  if (candlingActive) candlingStartedMs = millis();

  Serial.print("LED ");
  Serial.print(ledNumber);
  Serial.println(" ADDED");
}

void removeLed(int ledNumber) {
  cancelGuidanceState();
  blinkActive = false;
  setLED(ledNumber - 1, false);
  activeLedCount = countMask(registerData);
  updateShiftRegisters();
  candlingActive = activeLedCount > 0;
  if (candlingActive) candlingStartedMs = millis();

  Serial.print("LED ");
  Serial.print(ledNumber);
  Serial.println(" REMOVED");
}

void allOff() {
  clearAllRegisters();
  updateShiftRegisters();
  candlingActive = false;
  blinkActive = false;
  guidanceActive = false;
  clearMask(blinkMask);
  clearMask(removalGuidanceMask);
  clearMask(transferGuidanceMask);
  removalGuidanceCount = 0;
  transferGuidanceCount = 0;
  guidanceLastPhase = -1;
  activeLedCount = 0;
  Serial.println("ALL LEDs: OFF");
}

void allOn() {
  cancelGuidanceState();
  blinkActive = false;
  for (int i = 0; i < NUM_REGISTERS; i++) {
    registerData[i] = 0xFF;
  }
  activeLedCount = NUM_LEDS;
  updateShiftRegisters();
  candlingActive = true;
  candlingStartedMs = millis();
  Serial.println("ALL LEDs: ON");
}

void chaseTest() {
  Serial.println("CHASE TEST: LED 1 to 56");
  cancelGuidanceState();
  blinkActive = false;
  candlingActive = false;

  for (int led = 0; led < NUM_LEDS; led++) {
    clearAllRegisters();
    setLED(led, true);
    activeLedCount = 1;
    updateShiftRegisters();

    Serial.print("ACTIVE LED ");
    Serial.println(led + 1);
    delay(CHASE_DELAY_MS);
    server.handleClient();
  }

  allOff();
}

void registerTest() {
  Serial.println("REGISTER TEST: chip 1 to chip 7");
  cancelGuidanceState();
  blinkActive = false;
  candlingActive = false;

  for (int reg = 0; reg < NUM_REGISTERS; reg++) {
    clearAllRegisters();
    registerData[reg] = 0xFF;
    activeLedCount = 8;
    updateShiftRegisters();

    Serial.print("ACTIVE CHIP ");
    Serial.print(reg + 1);
    Serial.print(" LEDs ");
    Serial.print((reg * 8) + 1);
    Serial.print("-");
    Serial.println((reg * 8) + 8);
    delay(1200);
    server.handleClient();
  }

  allOff();
}

bool parseLedNumber(const String &text, int *ledNumber) {
  if (ledNumber == NULL) return false;

  int value = text.toInt();
  if (value < 1 || value > NUM_LEDS) {
    return false;
  }

  *ledNumber = value;
  return true;
}

bool parseEggMaskFromP4Json(const char *payload, byte mask[NUM_REGISTERS], int *eggCount) {
  for (int i = 0; i < NUM_REGISTERS; i++) {
    mask[i] = 0;
  }
  if (eggCount != NULL) {
    *eggCount = 0;
  }
  if (payload == NULL) {
    return false;
  }

  const char *eggsStart = strstr(payload, "\"eggs\"");
  if (eggsStart == NULL) {
    return false;
  }

  const char *pos = strchr(eggsStart, '[');
  if (pos == NULL) {
    return false;
  }
  pos++;

  const char *eggsEnd = strchr(pos, ']');
  if (eggsEnd == NULL) {
    return false;
  }

  int cell = 0;
  int count = 0;
  while (pos < eggsEnd && cell < NUM_LEDS) {
    char c = *pos;
    if (c == ' ' || c == '\n' || c == '\r' || c == '\t' || c == ',') {
      pos++;
      continue;
    }

    if (strncmp(pos, "true", 4) == 0) {
      setLEDInMask(mask, cell, true);
      count++;
      cell++;
      pos += 4;
      continue;
    }

    if (strncmp(pos, "false", 5) == 0) {
      cell++;
      pos += 5;
      continue;
    }

    return false;
  }

  if (eggCount != NULL) {
    *eggCount = count;
  }
  return cell > 0;
}

bool readHttpBodyToSlotBuffer(HTTPClient &http, size_t *outLen, String *errorText) {
  if (outLen != NULL) {
    *outLen = 0;
  }

  if (slotJsonBuffer == NULL) {
    if (errorText != NULL) *errorText = "slot JSON buffer not allocated";
    return false;
  }

  int contentLength = http.getSize();
  if (contentLength >= (int)SLOT_JSON_CAPACITY) {
    if (errorText != NULL) {
      *errorText = "P4 get_slots payload too large: " + String(contentLength);
    }
    slotJsonBuffer[0] = '\0';
    lastSlotJsonBytes = 0;
    return false;
  }

  WiFiClient *stream = http.getStreamPtr();
  if (stream == NULL) {
    if (errorText != NULL) *errorText = "HTTP stream unavailable";
    slotJsonBuffer[0] = '\0';
    lastSlotJsonBytes = 0;
    return false;
  }

  size_t total = 0;
  unsigned long lastDataMs = millis();

  while (true) {
    if (contentLength >= 0 && total >= (size_t)contentLength) {
      break;
    }

    int available = stream->available();
    if (available > 0) {
      size_t room = SLOT_JSON_CAPACITY - 1 - total;
      if (room == 0) {
        if (errorText != NULL) *errorText = "P4 get_slots payload exceeded buffer";
        slotJsonBuffer[0] = '\0';
        lastSlotJsonBytes = 0;
        return false;
      }

      size_t toRead = (size_t)available;
      if (toRead > room) {
        toRead = room;
      }

      size_t readNow = stream->readBytes(slotJsonBuffer + total, toRead);
      if (readNow > 0) {
        total += readNow;
        lastDataMs = millis();
      }
      continue;
    }

    if (!http.connected()) {
      break;
    }

    if (millis() - lastDataMs > P4_BODY_READ_TIMEOUT_MS) {
      if (total > 0) {
        break;
      }
      if (errorText != NULL) *errorText = "P4 get_slots body read timeout";
      slotJsonBuffer[0] = '\0';
      lastSlotJsonBytes = 0;
      return false;
    }

    delay(5);
  }

  slotJsonBuffer[total] = '\0';
  lastSlotJsonBytes = total;
  if (outLen != NULL) {
    *outLen = total;
  }

  if (total == 0) {
    if (errorText != NULL) *errorText = "P4 get_slots empty body";
    return false;
  }

  return true;
}

bool syncEggSlotsFromP4(bool lightNow, String *errorText) {
  if (WiFi.status() != WL_CONNECTED) {
    if (errorText != NULL) *errorText = "wifi not connected";
    return false;
  }

  WiFiClient client;
  HTTPClient http;
  http.setTimeout(1500);

  if (!http.begin(client, P4_SLOTS_URL)) {
    if (errorText != NULL) *errorText = "http begin failed";
    return false;
  }

  int code = http.GET();

  if (code != 200) {
    http.end();
    if (errorText != NULL) {
      *errorText = "P4 get_slots HTTP " + String(code);
    }
    return false;
  }

  size_t payloadLen = 0;
  if (!readHttpBodyToSlotBuffer(http, &payloadLen, errorText)) {
    http.end();
    return false;
  }
  http.end();

  byte eggMask[NUM_REGISTERS];
  int eggCount = 0;
  if (!parseEggMaskFromP4Json(slotJsonBuffer, eggMask, &eggCount)) {
    if (errorText != NULL) *errorText = "failed to parse eggs array";
    return false;
  }

  updateSlotCache(eggMask, eggCount);
  if (lightNow) {
    applyRecentEggMask();
  }

  Serial.print("P4 slots synced; eggs=");
  Serial.print(eggCount);
  Serial.print(" bytes=");
  Serial.println(payloadLen);
  return true;
}

String ipToString(IPAddress ip) {
  return String(ip[0]) + "." + String(ip[1]) + "." + String(ip[2]) + "." + String(ip[3]);
}

String statusJson(const char *status) {
  String body = "{";
  body += "\"status\":\"";
  body += status;
  body += "\",\"wifi_connected\":";
  body += WiFi.status() == WL_CONNECTED ? "true" : "false";
  body += ",\"ip\":\"";
  body += WiFi.status() == WL_CONNECTED ? ipToString(WiFi.localIP()) : "";
  body += "\",\"candling_active\":";
  body += candlingActive ? "true" : "false";
  body += ",\"active_led_count\":";
  body += String(activeLedCount);
  body += ",\"recent_cache_valid\":";
  body += recentSlotCacheValid ? "true" : "false";
  body += ",\"recent_egg_count\":";
  body += String(recentEggCount);
  body += ",\"previous_cache_valid\":";
  body += previousSlotCacheValid ? "true" : "false";
  body += ",\"previous_egg_count\":";
  body += String(previousEggCount);
  body += ",\"last_slot_sync_ms\":";
  body += String(lastSlotSyncMs);
  body += ",\"registers\":";
  body += String(NUM_REGISTERS);
  body += ",\"max_leds\":";
  body += String(NUM_LEDS);
  body += ",\"active_leds\":[";
  bool firstLed = true;
  for (int led = 0; led < NUM_LEDS; led++) {
    int registerIndex = led / 8;
    int bitIndex = led % 8;
    if (registerData[registerIndex] & (1 << bitIndex)) {
      if (!firstLed) body += ",";
      firstLed = false;
      body += String(led + 1);
    }
  }
  body += "]";
  body += ",\"guidance_active\":";
  body += guidanceActive ? "true" : "false";
  body += ",\"guidance_lease_ms\":";
  body += String(guidanceLeaseMs);
  unsigned long guidanceElapsed = guidanceActive
      ? millis() - guidanceStartedMs : guidanceLeaseMs;
  unsigned long guidanceRemaining = guidanceActive && guidanceElapsed < guidanceLeaseMs
      ? guidanceLeaseMs - guidanceElapsed : 0;
  body += ",\"guidance_remaining_ms\":";
  body += String(guidanceRemaining);
  body += ",\"removal_count\":";
  body += String(removalGuidanceCount);
  body += ",\"removal_pattern\":\"steady\"";
  body += ",\"removal_leds\":[";
  bool firstRemoval = true;
  for (int led = 0; led < NUM_LEDS; led++) {
    if (removalGuidanceMask[led / 8] & (1 << (led % 8))) {
      if (!firstRemoval) body += ",";
      firstRemoval = false;
      body += String(led + 1);
    }
  }
  body += "]";
  body += ",\"transfer_count\":";
  body += String(transferGuidanceCount);
  body += ",\"transfer_pattern\":\"slow_blink\"";
  body += ",\"transfer_leds\":[";
  bool firstTransfer = true;
  for (int led = 0; led < NUM_LEDS; led++) {
    if (transferGuidanceMask[led / 8] & (1 << (led % 8))) {
      if (!firstTransfer) body += ",";
      firstTransfer = false;
      body += String(led + 1);
    }
  }
  body += "]";
  body += ",\"p4_slots_url\":\"";
  body += P4_SLOTS_URL;
  body += "\"}";
  return body;
}

void sendJson(int code, const String &body) {
  server.sendHeader("Access-Control-Allow-Origin", "*");
  server.send(code, "application/json", body);
}

void handleRoot() {
  sendJson(200, statusJson("ready"));
}

void handleStatus() {
  sendJson(200, statusJson("ready"));
}

void handleCandlingStart() {
  blinkActive = false;  // candling takes over from any door-open blink
  bool litFromCache = applyRecentEggMask();

  String error;
  if (!syncEggSlotsFromP4(true, &error)) {
    if (litFromCache) {
      String body = statusJson("candling_started_from_cache");
      sendJson(200, body);
      return;
    }

    allOff();
    String body = "{\"status\":\"error\",\"message\":\"";
    body += error;
    body += "\"}";
    sendJson(502, body);
    return;
  }

  String body = statusJson("candling_started");
  sendJson(200, body);
}

void handleCandlingStop() {
  allOff();
  sendJson(200, statusJson("candling_stopped"));
}

void handleSlotsSync() {
  String error;
  if (!syncEggSlotsFromP4(false, &error)) {
    String body = "{\"status\":\"error\",\"message\":\"";
    body += error;
    body += "\"}";
    sendJson(502, body);
    return;
  }

  sendJson(200, statusJson("slots_synced"));
}

bool isLedListSeparator(char c) {
  return c == ',' || c == ' ' || c == '\t' || c == '\n' || c == '\r';
}

bool applyLedList(const String &text, const String &mode, String *errorText) {
  cancelGuidanceState();
  const bool addMode = mode == "add";
  const bool removeMode = mode == "remove" || mode == "del";
  const bool toggleMode = mode == "toggle";
  const bool setMode = !addMode && !removeMode && !toggleMode;

  if (setMode) {
    clearAllRegisters();
  }

  int requestedCount = 0;
  int start = 0;
  while (start < text.length()) {
    while (start < text.length() && isLedListSeparator(text.charAt(start))) {
      start++;
    }
    if (start >= text.length()) break;

    int end = start;
    while (end < text.length() && !isLedListSeparator(text.charAt(end))) {
      end++;
    }

    String token = text.substring(start, end);
    token.trim();

    int ledNumber = 0;
    if (!parseLedNumber(token, &ledNumber)) {
      if (errorText != NULL) {
        *errorText = "invalid LED number: " + token;
      }
      return false;
    }

    const int ledIndex = ledNumber - 1;
    if (removeMode) {
      setLED(ledIndex, false);
    } else if (toggleMode) {
      const int registerIndex = ledIndex / 8;
      const int bitIndex = ledIndex % 8;
      const bool currentlyOn = registerData[registerIndex] & (1 << bitIndex);
      setLED(ledIndex, !currentlyOn);
    } else {
      setLED(ledIndex, true);
    }

    requestedCount++;
    start = end;
  }

  if (requestedCount == 0) {
    if (errorText != NULL) *errorText = "no LED numbers provided";
    return false;
  }

  activeLedCount = countMask(registerData);
  updateShiftRegisters();
  candlingActive = activeLedCount > 0;
  if (candlingActive) candlingStartedMs = millis();

  Serial.print("LED list ");
  if (mode.length() == 0) {
    Serial.print("set");
  } else {
    Serial.print(mode);
  }
  Serial.print(": requested=");
  Serial.print(requestedCount);
  Serial.print(" active=");
  Serial.println(activeLedCount);
  blinkActive = false;
  return true;
}

bool parseLedListToMask(const String &text, byte mask[NUM_REGISTERS],
                        int *count, String *errorText) {
  clearMask(mask);
  int parsed = 0;
  int start = 0;
  while (start < text.length()) {
    while (start < text.length() && isLedListSeparator(text.charAt(start))) {
      start++;
    }
    if (start >= text.length()) break;

    int end = start;
    while (end < text.length() && !isLedListSeparator(text.charAt(end))) {
      end++;
    }

    String token = text.substring(start, end);
    token.trim();

    int ledNumber = 0;
    if (!parseLedNumber(token, &ledNumber)) {
      if (errorText != NULL) *errorText = "invalid LED number: " + token;
      return false;
    }
    setLEDInMask(mask, ledNumber - 1, true);
    parsed++;
    start = end;
  }
  if (count != NULL) *count = parsed;
  return true;
}

void serviceGuidance() {
  if (!guidanceActive) return;

  unsigned long now = millis();
  if (now - guidanceStartedMs >= guidanceLeaseMs) {
    Serial.println("GUIDANCE: lease expired; LEDs off");
    allOff();
    return;
  }

  unsigned long cycle = (now - guidanceStartedMs) % GUIDANCE_CYCLE_MS;
  bool removalOn = removalGuidanceCount > 0;
  bool transferOn = cycle < 1200UL;
  int phase = (removalOn ? 1 : 0) | (transferOn ? 2 : 0);
  if (phase == guidanceLastPhase) return;
  guidanceLastPhase = phase;

  byte output[NUM_REGISTERS];
  clearMask(output);
  for (int reg = 0; reg < NUM_REGISTERS; reg++) {
    if (removalOn) output[reg] |= removalGuidanceMask[reg];
    if (transferOn) output[reg] |= transferGuidanceMask[reg];
  }
  applyMask(output);
}

void startGuidance(const byte removal[NUM_REGISTERS],
                   const byte transfer[NUM_REGISTERS],
                   unsigned long leaseMs) {
  blinkActive = false;
  candlingActive = false;
  copyMask(removalGuidanceMask, removal);
  copyMask(transferGuidanceMask, transfer);
  removalGuidanceCount = countMask(removalGuidanceMask);
  transferGuidanceCount = countMask(transferGuidanceMask);
  guidanceLeaseMs = leaseMs;
  guidanceStartedMs = millis();
  guidanceLastPhase = -1;
  guidanceActive = removalGuidanceCount + transferGuidanceCount > 0;
  serviceGuidance();
  Serial.print("GUIDANCE: removal=");
  Serial.print(removalGuidanceCount);
  Serial.print(" transfer=");
  Serial.print(transferGuidanceCount);
  Serial.print(" lease_ms=");
  Serial.println(guidanceLeaseMs);
}

void handleGuidanceStop() {
  allOff();
  sendJson(200, statusJson("guidance_stopped"));
}

void handleGuidance() {
  String removalArg = server.arg("remove");
  String transferArg = server.arg("transfer");
  removalArg.trim();
  transferArg.trim();

  String stopArg = server.arg("state");
  stopArg.toLowerCase();
  stopArg.trim();
  if (stopArg == "off" || removalArg == "off" || transferArg == "off") {
    handleGuidanceStop();
    return;
  }

  byte removal[NUM_REGISTERS];
  byte transfer[NUM_REGISTERS];
  int ignoredParsedCount = 0;
  String error;
  if (!parseLedListToMask(removalArg, removal, &ignoredParsedCount, &error) ||
      !parseLedListToMask(transferArg, transfer, &ignoredParsedCount, &error)) {
    String body = "{\"status\":\"error\",\"message\":\"";
    body += error;
    body += "; use remove=1,2 and transfer=3,4\"}";
    sendJson(400, body);
    return;
  }

  // Removal always wins if a slot appears in both lists.
  for (int reg = 0; reg < NUM_REGISTERS; reg++) {
    transfer[reg] &= (byte)~removal[reg];
  }
  if (countMask(removal) + countMask(transfer) == 0) {
    sendJson(400, "{\"status\":\"error\",\"message\":\"at least one removal or transfer slot is required\"}");
    return;
  }

  unsigned long leaseMs = GUIDANCE_DEFAULT_LEASE_MS;
  if (server.hasArg("lease_ms")) {
    long requested = server.arg("lease_ms").toInt();
    if (requested < (long)GUIDANCE_MIN_LEASE_MS ||
        requested > (long)GUIDANCE_MAX_LEASE_MS) {
      sendJson(400, "{\"status\":\"error\",\"message\":\"lease_ms must be 10000..600000\"}");
      return;
    }
    leaseMs = (unsigned long)requested;
  }

  startGuidance(removal, transfer, leaseMs);
  sendJson(200, statusJson("guidance_active"));
}

void stopBlink() {
  cancelGuidanceState();
  blinkActive = false;
  clearMask(blinkMask);
  clearAllRegisters();
  updateShiftRegisters();
  activeLedCount = 0;
  Serial.println("BLINK: stopped, LEDs off");
}

void startBlink(const byte mask[NUM_REGISTERS], int count) {
  cancelGuidanceState();
  copyMask(blinkMask, mask);
  blinkActive = true;
  candlingActive = false;
  blinkPhaseOn = true;
  blinkLastToggleMs = millis();
  blinkStartedMs = millis();
  applyMask(blinkMask);  // start lit immediately
  Serial.print("BLINK: start; cells=");
  Serial.println(count);
}

// Toggle the blink mask on/off at BLINK_INTERVAL_MS. A fail-safe timeout turns
// everything off if the P4 never sends the door-close "off" (protects the ICs).
void serviceBlink() {
  if (!blinkActive) return;

  unsigned long now = millis();
  if (now - blinkStartedMs > BLINK_SAFETY_TIMEOUT_MS) {
    Serial.println("BLINK: safety timeout; LEDs off");
    allOff();
    return;
  }

  if (now - blinkLastToggleMs < BLINK_INTERVAL_MS) return;
  blinkLastToggleMs = now;
  blinkPhaseOn = !blinkPhaseOn;
  if (blinkPhaseOn) {
    applyMask(blinkMask);
  } else {
    clearAllRegisters();
    updateShiftRegisters();
    activeLedCount = 0;
  }
}

void handleBlink() {
  String ledArg = server.arg("led");
  ledArg.toLowerCase();
  ledArg.trim();

  if (ledArg.length() == 0 || ledArg == "off" || ledArg == "0" ||
      ledArg == "stop") {
    stopBlink();
    sendJson(200, statusJson("blink_off"));
    return;
  }

  byte mask[NUM_REGISTERS];
  int count = 0;
  String error;
  if (!parseLedListToMask(ledArg, mask, &count, &error)) {
    String body = "{\"status\":\"error\",\"message\":\"";
    body += error;
    body += "; use /blink?led=1,2,3 or /blink?led=off\"}";
    sendJson(400, body);
    return;
  }
  if (count == 0) {
    stopBlink();
    sendJson(200, statusJson("blink_off"));
    return;
  }

  startBlink(mask, count);
  sendJson(200, statusJson("blink_on"));
}

void handleLedTest() {
  String ledArg = server.arg("led");
  ledArg.toLowerCase();
  ledArg.trim();
  String modeArg = server.arg("mode");
  modeArg.toLowerCase();
  modeArg.trim();

  if (ledArg == "off" || ledArg == "0") {
    allOff();
    sendJson(200, statusJson("off"));
    return;
  }

  if (ledArg == "all" || ledArg == "on") {
    allOn();
    sendJson(200, statusJson("all_on"));
    return;
  }

  if (ledArg == "chase" || ledArg == "test") {
    chaseTest();
    sendJson(200, statusJson("chase_done"));
    return;
  }

  if (modeArg.length() > 0 &&
      modeArg != "set" &&
      modeArg != "add" &&
      modeArg != "remove" &&
      modeArg != "del" &&
      modeArg != "toggle") {
    sendJson(400, "{\"status\":\"error\",\"message\":\"mode must be set, add, remove, or toggle\"}");
    return;
  }

  String error;
  if (applyLedList(ledArg, modeArg, &error)) {
    sendJson(200, statusJson(modeArg == "add"
                                 ? "leds_added"
                                 : modeArg == "remove" || modeArg == "del"
                                     ? "leds_removed"
                                     : modeArg == "toggle"
                                         ? "leds_toggled"
                                         : "leds_set"));
    return;
  }

  String body = "{\"status\":\"error\",\"message\":\"";
  body += error;
  body += "; use /led_test?led=1..56|1,2,3|all|off|chase&mode=set|add|remove|toggle\"}";
  sendJson(400, body);
}

void setupServer() {
  server.on("/", HTTP_GET, handleRoot);
  server.on("/status", HTTP_GET, handleStatus);
  server.on("/candling_start", HTTP_GET, handleCandlingStart);
  server.on("/candling_start", HTTP_POST, handleCandlingStart);
  server.on("/candling_stop", HTTP_GET, handleCandlingStop);
  server.on("/candling_stop", HTTP_POST, handleCandlingStop);
  server.on("/slots_sync", HTTP_GET, handleSlotsSync);
  server.on("/led_test", HTTP_GET, handleLedTest);
  server.on("/blink", HTTP_GET, handleBlink);
  server.on("/blink", HTTP_POST, handleBlink);
  server.on("/guidance", HTTP_GET, handleGuidance);
  server.on("/guidance", HTTP_POST, handleGuidance);
  server.on("/guidance_stop", HTTP_GET, handleGuidanceStop);
  server.on("/guidance_stop", HTTP_POST, handleGuidanceStop);
  server.begin();
  Serial.println("HTTP server ready");
}

void startWiFi() {
  Serial.print("Connecting to ");
  Serial.println(WIFI_SSID);

  WiFi.mode(WIFI_STA);
  WiFi.config(localIp, gateway, subnet);
  WiFi.begin(WIFI_SSID, WIFI_PASSWORD);
  lastWifiAttemptMs = millis();
}

void maintainWiFi() {
  if (WiFi.status() == WL_CONNECTED) {
    if (!wifiWasConnected) {
      wifiWasConnected = true;
      Serial.print("WiFi connected. IP: ");
      Serial.println(WiFi.localIP());
    }
    return;
  }

  if (wifiWasConnected) {
    wifiWasConnected = false;
    Serial.println("WiFi disconnected");
  }

  unsigned long now = millis();
  if (now - lastWifiAttemptMs < WIFI_RETRY_MS) {
    return;
  }

  Serial.println("WiFi reconnect...");
  WiFi.disconnect();
  WiFi.config(localIp, gateway, subnet);
  WiFi.begin(WIFI_SSID, WIFI_PASSWORD);
  lastWifiAttemptMs = now;
}

void autoSyncSlotsFromP4() {
  if (WiFi.status() != WL_CONNECTED || candlingActive || blinkActive ||
      guidanceActive) {
    return;
  }

  unsigned long now = millis();
  if (now - lastAutoSlotSyncAttemptMs < AUTO_SLOT_SYNC_MS) {
    return;
  }
  lastAutoSlotSyncAttemptMs = now;

  String error;
  if (!syncEggSlotsFromP4(false, &error)) {
    Serial.print("AUTO SLOT SYNC ERROR: ");
    Serial.println(error);
  }
}

void printHelp() {
  Serial.println();
  Serial.println("--- 56 LED Controller Started ---");
  Serial.println("Hardware: 7x chained SN74HC595N outputs");
  Serial.println("GPIO 21: DATA  -> first SN74HC595N pin 14 DS");
  Serial.println("GPIO 19: LATCH -> all SN74HC595N pin 12 STCP");
  Serial.println("GPIO 17: CLOCK -> all SN74HC595N pin 11 SHCP");
  Serial.println("Static IP: 192.168.4.60");
  Serial.println("WARNING: 12V 5W LEDs need MOSFET/driver channels.");
  Serial.println("Do not power LEDs directly from SN74HC595N outputs.");
  Serial.println();
  Serial.println("HTTP endpoints:");
  Serial.println("  /status");
  Serial.println("  /candling_start  -> light recent cache immediately, then refresh P4 slots");
  Serial.println("  /candling_stop   -> all LEDs off");
  Serial.println("  /slots_sync      -> fetch P4 slots into previous/recent cache");
  Serial.println("  /led_test?led=1..56|1,2,3|all|off|chase&mode=set|add|remove|toggle");
  Serial.println("  /blink?led=1,2,3 -> blink those cells (door-open removal guide)");
  Serial.println("  /blink?led=off   -> stop blinking, all LEDs off (door close)");
  Serial.println("  /guidance?remove=1,2&transfer=3,4&lease_ms=90000");
  Serial.println("  /guidance_stop   -> stop all door-open guidance");
  Serial.println();
  Serial.println("Serial commands:");
  Serial.println("  1-56        : turn on only that LED");
  Serial.println("  add 1-56    : turn that LED on, keeping others unchanged");
  Serial.println("  del 1-56    : turn that LED off, keeping others unchanged");
  Serial.println("  0 / off     : all LEDs off");
  Serial.println("  all / on    : all LEDs on");
  Serial.println("  test/chase  : chase LED 1 to 56");
  Serial.println("  regs        : turn on one 8-output chip at a time");
  Serial.println("  sync        : fetch P4 slots and light egg slots");
  Serial.println("  help        : show this help");
  Serial.println();
}

void handleSerialCommand() {
  if (Serial.available() <= 0) {
    return;
  }

  String input = Serial.readStringUntil('\n');
  input.trim();
  input.toLowerCase();

  if (input.length() == 0) {
    return;
  }

  if (input == "help" || input == "?") {
    printHelp();
    return;
  }

  if (input == "0" || input == "off" || input == "clear") {
    allOff();
    return;
  }

  if (input == "all" || input == "on") {
    allOn();
    return;
  }

  if (input == "test" || input == "chase") {
    chaseTest();
    return;
  }

  if (input == "regs" || input == "registers") {
    registerTest();
    return;
  }

  if (input == "sync" || input == "candling") {
    String error;
    if (!syncEggSlotsFromP4(true, &error)) {
      Serial.print("SYNC ERROR: ");
      Serial.println(error);
    }
    return;
  }

  if (input.startsWith("add ")) {
    int ledNumber = 0;
    String arg = input.substring(4);
    arg.trim();
    if (parseLedNumber(arg, &ledNumber)) {
      addLed(ledNumber);
    } else {
      Serial.println("ERROR: use add 1-56");
    }
    return;
  }

  if (input.startsWith("del ") || input.startsWith("remove ")) {
    int splitAt = input.indexOf(' ');
    int ledNumber = 0;
    String arg = input.substring(splitAt + 1);
    arg.trim();
    if (parseLedNumber(arg, &ledNumber)) {
      removeLed(ledNumber);
    } else {
      Serial.println("ERROR: use del 1-56");
    }
    return;
  }

  int ledNumber = 0;
  if (parseLedNumber(input, &ledNumber)) {
    onlyLed(ledNumber);
  } else {
    Serial.print("ERROR: enter 1-56, add 1-56, del 1-56, 0, all, test, regs, sync, or help. You entered: ");
    Serial.println(input);
  }
}

void setup() {
  pinMode(dataPin, OUTPUT);
  pinMode(latchPin, OUTPUT);
  pinMode(clockPin, OUTPUT);

  digitalWrite(dataPin, LOW);
  digitalWrite(clockPin, LOW);
  digitalWrite(latchPin, LOW);

  clearAllRegisters();
  updateShiftRegisters();

  Serial.begin(115200);
  delay(1000);
  printHelp();

  startWiFi();
  setupServer();
}

void loop() {
  maintainWiFi();
  autoSyncSlotsFromP4();
  server.handleClient();
  handleSerialCommand();
  serviceBlink();
  serviceGuidance();

  if (candlingActive && millis() - candlingStartedMs > CANDLING_TIMEOUT_MS) {
    Serial.println("Candling timeout; LEDs off");
    allOff();
  }

  delay(10);
}
