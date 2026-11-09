#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <stdint.h>
#include <stddef.h>
#include <math.h>
#include <float.h>

#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "freertos/event_groups.h"
#include "freertos/semphr.h"
#include "freertos/timers.h"

#include "esp_system.h"
#include "esp_wifi.h"
#include "esp_event.h"
#include "esp_log.h"
#include "nvs_flash.h"
#include "esp_netif.h"
#include "esp_heap_caps.h"
#include "esp_timer.h"
#include "esp_task_wdt.h"
#include "esp_rom_sys.h"
#include "esp_attr.h"

#include "esp_http_client.h"
#include "esp_http_server.h"
#include "driver/jpeg_decode.h"
#include "driver/i2c_master.h"
#include "cJSON.h"
#include "lwip/ip4_addr.h"

#include "esp_hosted.h"
#include "driver/gpio.h"

#include "tensorflow/lite/micro/micro_interpreter.h"
#include "tensorflow/lite/micro/micro_mutable_op_resolver.h"
#include "tensorflow/lite/schema/schema_generated.h"
#include <time.h>
#include <sys/time.h>

static const char *TAG = "egg_counter";

// WiFi / Camera
#define WIFI_SSID      "AI_CANDLING"
#define WIFI_PASSWORD  "thesis123"
#define S3_BASE_URL    "http://192.168.4.1"
#define CAPTURE_URL    S3_BASE_URL "/capturep4"
#define CANDLING_CAPTURE_URL S3_BASE_URL "/capture"
#define S3_HEALTH_URL  S3_BASE_URL "/sensor"
#define P4_STATIC_IP_OCTET_4 50
// Probe the S3 before changing any incubator output. If it is absent, climate
// control and sensor monitoring stay in normal operation while P4 waits.
#define S3_HEALTH_TIMEOUT_MS      3000
// A normal high-resolution S3 capture takes several seconds. Cap a dead
// request so a disconnected camera cannot hold scan mode for five minutes.
#define CAPTURE_HTTP_TIMEOUT_MS  30000
#define SCAN_RETRY_COOLDOWN_MS   30000
// The S3 finishes its camera shutdown after the final JPEG bytes are sent.
// Keep every P4 output unchanged until that cleanup and the HTTP connection
// have settled, then let relay transitions settle before CPU-heavy AI work.
#define POST_CAPTURE_DOWNLOAD_SETTLE_MS 2000
#define AI_FOCUS_POWER_SETTLE_MS         500
#define INTAKE_CANDLING_STABILIZE_MS    3000
#define NORMAL_CAPTURE_BULB_SETTLE_MS    500

// SHT3x temperature / humidity sensor on the shared I2C bus.
// Wire SDA to GPIO1 and SCL to GPIO2 with the LCD + DS3231.
#define SHT3X_I2C_ADDR_PRIMARY 0x44
#define SHT3X_I2C_ADDR_ALT     0x45
#define SHT3X_READ_INTERVAL_MS 2000
#define SHT3X_BAD_READ_LOG_INTERVAL 3
#define SHT3X_FAILSAFE_BAD_READS    3
#define SHT3X_RECOVERY_GOOD_READS   3

// RTC
#define MIN_TRUSTED_EPOCH 1700000000LL  // 2023-11-14; older means RTC is not usable.
#define MAX_TRUSTED_EPOCH 4102444800LL  // 2100-01-01
#define TIME_BACKWARD_TOLERANCE_SEC 300

// Model
#define MODEL_INPUT_W  224
#define MODEL_INPUT_H  224
#define MODEL_INPUT_C  3
#define CONF_THRESH    0.25f
#define IOU_THRESH     0.45f
// Release delimitation: newly placed eggs are tracked from their placement day;
// detecting a previously incubated/dead egg introduced on day one is future
// research. Keep the collector/endpoints available, but do not run an automatic
// second candling capture in production.
#define AUTOMATIC_INTAKE_SCREENING_ENABLED 0
// Set to 1 only together with the future, independently validated intake model.
#define INTAKE_MODEL_INSTALLED 0
#define ENABLE_DIAGNOSTIC_ALERT_API 1

// Binary slot classifier classes.
#define CLS_EGG_PRESENT_IDX    0
#define CLS_NOT_EGG_IDX        1
// Older 3-class models used class 2 for slot_reference.
#define CLS_SLOT_REFERENCE_IDX 2
#define CLS_EGG_CONF_THRESH    0.85f
#define CLS_EGG_MARGIN_THRESH  0.35f
// Build crop stats for every slot, then run the classifier across the full
// tray grid. The trained CNN owns the decision; crop stats are diagnostic.
#define CLASSIFIER_DEBUG_USE_PREFILTER 1
#define CLASSIFIER_SCAN_ALL_CELLS      1
#define CLASSIFIER_DEBUG_TOP_CELLS     12
#define CLASSIFIER_DEBUG_SAMPLE_STEP   4
#define CLASSIFIER_DEBUG_RUN_MODEL     1
#define HEURISTIC_GRID_NMS_RADIUS      1
#define HEURISTIC_CENTROID_SAMPLE_STEP 2
#define HEURISTIC_MIN_EGG_DISTANCE_FRAC 0.55f
#define HEURISTIC_EGG_DELTA_THRESH     20.0f
#define HEURISTIC_EGG_CENTER_MIN       140.0f
#define HEURISTIC_BLOB_MAX_SAMPLE_COLS 256
#define HEURISTIC_BLOB_MIN_RUN_FRAC    0.22f
#define HEURISTIC_BLOB_MIN_BRIGHT_FRAC 0.06f
#define HEURISTIC_BLOB_MAX_BRIGHT_FRAC 0.72f
#define HEURISTIC_BLOB_MIN_SCORE       27.0f
#define HEURISTIC_NEUTRAL_MIN_FRAC     0.16f
#define HEURISTIC_BLUE_RATIO_MIN       0.30f
#define HEURISTIC_VERIFY_DELTA_THRESH  35.0f
#define HEURISTIC_VERIFY_CENTER_MIN    155.0f
#define HEURISTIC_VERIFY_BLOB_SCORE    42.0f
#define HEURISTIC_VERIFY_RUN_FRAC      0.30f
#define HEURISTIC_VERIFY_NEUTRAL_FRAC  0.22f
#define HEURISTIC_VERIFY_BLUE_RATIO    0.36f
#define CLASSIFIER_DEBUG_LIMIT_CELLS 0
#define CLASSIFIER_DEBUG_FIRST_CELL  0
#define CLASSIFIER_DEBUG_LAST_CELL   7
// Match the app dataset crops exactly. Expanding a crop can pull in a neighbor
// egg and make an empty slot look positive to the binary classifier.
#define CELL_CROP_MARGIN       0.00f

// M4 camera quality gates. These are deliberately broad equipment checks,
// not egg verdict thresholds. Runtime logs from the real tray must be used to
// tighten them later without turning difficult eggs into camera failures.
#define QUALITY_SAMPLE_STEP                 8
#define QUALITY_MIN_IMAGE_W              1024
#define QUALITY_MIN_IMAGE_H               768
#define QUALITY_ASPECT_MIN               1.25f
#define QUALITY_ASPECT_MAX               1.40f
#define NORMAL_QUALITY_MIN_MEAN          10.0f
#define NORMAL_QUALITY_MAX_MEAN         245.0f
#define NORMAL_QUALITY_MIN_STDDEV         3.0f
#define NORMAL_QUALITY_MIN_P95_P05       10.0f
#define NORMAL_QUALITY_MAX_DARK_FRAC      0.97f
#define NORMAL_QUALITY_MAX_BRIGHT_FRAC    0.97f
#define CANDLING_QUALITY_MIN_STDDEV        2.0f
#define SLOT_LIGHT_MIN_BORDER_MEAN        12.0f
#define SLOT_LIGHT_MIN_BORDER_P90         36
#define SLOT_LIGHT_MIN_BRIGHT_FRAC         0.03f

// Egg tray grid (8 cols x 7 rows = 56 slots)
#define GRID_COLS   8
#define GRID_ROWS   7
#define NUM_CELLS   (GRID_COLS * GRID_ROWS)
#define MAX_GRID_COLS GRID_COLS
#define MAX_GRID_ROWS GRID_ROWS
#define EDGE_IGNORE 0.15f
#define GRID_DEFAULT_VERSION 2

// Tray physical dimensions (cm)
#define TRAY_W_CM  39.5f
#define TRAY_H_CM  39.0f

static int   s_grid_cols = GRID_COLS;
static int   s_grid_rows = GRID_ROWS;
static float s_tray_w_cm = TRAY_W_CM;
static float s_tray_h_cm = TRAY_H_CM;
static float s_col_bounds_cm[MAX_GRID_COLS + 1] = {};
static float s_row_bounds_cm[MAX_GRID_ROWS + 1] = {};
static bool  s_grid_config_ready = false;
static const float DEFAULT_COL_BOUNDS_CM[MAX_GRID_COLS + 1] = {
    8.0f, 12.0f, 15.0f, 17.9f, 20.8f, 23.6f, 26.6f, 29.6f, 33.2f
};
static const float DEFAULT_ROW_BOUNDS_CM[MAX_GRID_ROWS + 1] = {
    2.3f, 7.9f, 12.8f, 17.1f, 21.7f, 26.2f, 30.5f, 36.2f
};

// TFLite arena
#define MAX_DETS    200
static constexpr size_t ARENA_SIZE = 24 * 1024 * 1024;

static uint8_t              *s_arena  = NULL;
static tflite::MicroInterpreter *s_interp = NULL;
static bool                  s_tflite_ready = false;
static int                   s_model_input_w = MODEL_INPUT_W;
static int                   s_model_input_h = MODEL_INPUT_H;
static int                   s_model_input_c = MODEL_INPUT_C;

typedef enum {
    MODEL_OUTPUT_UNKNOWN = 0,
    MODEL_OUTPUT_DETECTOR,
    MODEL_OUTPUT_CLASSIFIER,
} ModelOutputKind;

static ModelOutputKind s_model_output_kind = MODEL_OUTPUT_UNKNOWN;

typedef enum {
    SCAN_FAIL_NONE = 0,
    SCAN_FAIL_WIFI,
    SCAN_FAIL_S3_OFFLINE,
    SCAN_FAIL_MEMORY,
    SCAN_FAIL_CAPTURE,
    SCAN_FAIL_NO_IMAGE,
    SCAN_FAIL_IMAGE_CORRUPT,
    SCAN_FAIL_AI,
    SCAN_FAIL_NO_GRID,
    SCAN_FAIL_BUSY,
    SCAN_FAIL_STATE,
    SCAN_FAIL_LED,
    SCAN_FAIL_IMAGE_QUALITY,
    SCAN_FAIL_TIMEOUT,
} ScanFailureReason;

static const char *scan_failure_key(ScanFailureReason reason)
{
    switch (reason) {
        case SCAN_FAIL_WIFI:          return "wifi_fail";
        case SCAN_FAIL_S3_OFFLINE:    return "s3_offline";
        case SCAN_FAIL_MEMORY:        return "no_memory";
        case SCAN_FAIL_CAPTURE:       return "capture_fail";
        case SCAN_FAIL_NO_IMAGE:      return "no_image";
        case SCAN_FAIL_IMAGE_CORRUPT: return "image_corrupt";
        case SCAN_FAIL_AI:            return "ai_fail";
        case SCAN_FAIL_NO_GRID:       return "no_grid";
        case SCAN_FAIL_BUSY:          return "hardware_busy";
        case SCAN_FAIL_STATE:         return "state_commit";
        case SCAN_FAIL_LED:           return "led_verify";
        case SCAN_FAIL_IMAGE_QUALITY: return "image_quality";
        case SCAN_FAIL_TIMEOUT:       return "timeout";
        case SCAN_FAIL_NONE:
        default:                      return "none";
    }
}

static const char *scan_failure_lcd_text(ScanFailureReason reason)
{
    switch (reason) {
        case SCAN_FAIL_WIFI:          return "WIFI FAIL";
        case SCAN_FAIL_S3_OFFLINE:    return "WAIT S3 CAM";
        case SCAN_FAIL_MEMORY:        return "NO MEMORY";
        case SCAN_FAIL_CAPTURE:       return "CAPTURE FAIL";
        case SCAN_FAIL_NO_IMAGE:      return "NO IMAGE";
        case SCAN_FAIL_IMAGE_CORRUPT: return "IMAGE CORRUPT";
        case SCAN_FAIL_AI:            return "AI FAIL";
        case SCAN_FAIL_NO_GRID:       return "NO GRID";
        case SCAN_FAIL_BUSY:          return "APP OP ACTIVE";
        case SCAN_FAIL_STATE:         return "STATE SAVE FAIL";
        case SCAN_FAIL_LED:           return "LED VERIFY FAIL";
        case SCAN_FAIL_IMAGE_QUALITY: return "CAMERA QUALITY";
        case SCAN_FAIL_TIMEOUT:       return "SCAN TIMEOUT";
        case SCAN_FAIL_NONE:
        default:                      return "SCAN ERROR";
    }
}

typedef enum {
    SCAN_PHASE_IDLE = 0,
    SCAN_PHASE_ACQUIRE,
    SCAN_PHASE_TRAY_SETTLE,
    SCAN_PHASE_NORMAL_CAPTURE,
    SCAN_PHASE_NORMAL_DOWNLOAD_SETTLE,
    SCAN_PHASE_NORMAL_INFERENCE,
    SCAN_PHASE_TARGET_SELECTION,
    SCAN_PHASE_CANDLING_LED_VERIFY,
    SCAN_PHASE_CANDLING_STABILIZE,
    SCAN_PHASE_CANDLING_CAPTURE,
    SCAN_PHASE_CANDLING_VALIDATE,
    SCAN_PHASE_COMMIT,
    SCAN_PHASE_RESTORE,
} ScanPhase;

static volatile ScanPhase s_scan_phase = SCAN_PHASE_IDLE;

static const char *scan_phase_name(ScanPhase phase)
{
    switch (phase) {
        case SCAN_PHASE_ACQUIRE:                 return "acquire";
        case SCAN_PHASE_TRAY_SETTLE:             return "tray_settle";
        case SCAN_PHASE_NORMAL_CAPTURE:          return "normal_capture";
        case SCAN_PHASE_NORMAL_DOWNLOAD_SETTLE:  return "normal_download_settle";
        case SCAN_PHASE_NORMAL_INFERENCE:        return "normal_inference";
        case SCAN_PHASE_TARGET_SELECTION:        return "target_selection";
        case SCAN_PHASE_CANDLING_LED_VERIFY:     return "candling_led_verify";
        case SCAN_PHASE_CANDLING_STABILIZE:      return "candling_stabilize";
        case SCAN_PHASE_CANDLING_CAPTURE:        return "candling_capture";
        case SCAN_PHASE_CANDLING_VALIDATE:       return "candling_validate";
        case SCAN_PHASE_COMMIT:                  return "commit";
        case SCAN_PHASE_RESTORE:                 return "restore";
        case SCAN_PHASE_IDLE:
        default:                                 return "idle";
    }
}

static void scan_phase_set(ScanPhase phase)
{
    ScanPhase previous = s_scan_phase;
    if (previous == phase) {
        return;
    }
    s_scan_phase = phase;
    ESP_LOGI(TAG, "Scan phase: %s -> %s",
             scan_phase_name(previous), scan_phase_name(phase));
}

static bool scan_failure_is_s3_recovery(ScanFailureReason reason)
{
    return reason == SCAN_FAIL_WIFI ||
           reason == SCAN_FAIL_S3_OFFLINE ||
           reason == SCAN_FAIL_CAPTURE ||
           reason == SCAN_FAIL_NO_IMAGE ||
           reason == SCAN_FAIL_IMAGE_CORRUPT;
}

#define P4_COUNTER_SCAN_ENABLED       1
#define AI_INFERENCE_ENABLED          P4_COUNTER_SCAN_ENABLED
#define AI_INFERENCE_GUARD_MAGIC      0xA17E0001u
#define AI_INFERENCE_DISABLED_MAGIC   0xA17E0002u
RTC_NOINIT_ATTR static uint32_t s_ai_inference_guard_magic;
RTC_NOINIT_ATTR static uint32_t s_ai_inference_guard_inverse;
RTC_NOINIT_ATTR static uint32_t s_ai_inference_disabled_magic;
RTC_NOINIT_ATTR static uint32_t s_ai_inference_disabled_inverse;
static bool s_ai_inference_runtime_enabled = (AI_INFERENCE_ENABLED != 0);

static bool p4_counter_scan_enabled(void)
{
    return (P4_COUNTER_SCAN_ENABLED != 0) && s_ai_inference_runtime_enabled;
}

// Persistent cell state
static bool s_cell_has_egg[NUM_CELLS]      = {};
static bool s_scan_valid                   = false;
static volatile bool s_ai_scan_active      = false;
#define S3_CAMERA_FOCUS_TIMEOUT_MS 600000
static volatile bool s_s3_camera_focus_active = false;
static volatile int64_t s_s3_camera_focus_deadline_us = 0;
static volatile ScanFailureReason s_last_scan_failure = SCAN_FAIL_NONE;
static volatile uint32_t s_scan_retry_count = 0;
static int  s_last_egg_count               = 0;
static bool s_sht3x_connected              = false;
static uint8_t s_sht3x_bad_reads           = 0;
static uint8_t s_sht3x_good_reads          = 0;
static volatile bool s_climate_sensor_fault = false;
static float s_main_temp = 0.0f;
static float s_main_hum = 0.0f;
static bool s_main_climate_valid = false;
static time_t s_cell_start_time[NUM_CELLS] = {};  // per-slot first-seen timestamps
static bool s_cell_alert[NUM_CELLS]        = {};  // true if incubation day >= 7
static bool s_infertile_slots[NUM_CELLS]   = {};  // app-provided day-7+ slots for LED feedback
// Consecutive candlings a cell has been reported infertile. A cell only earns a
// "remove this egg" blink once it reads infertile on 2+ candlings in a row, so a
// single false positive never makes the farmer discard a viable egg.
static uint8_t s_infertile_streak[NUM_CELLS] = {};
// These masks are populated by later intake/replacement milestones. They are
// durable now so a reset can never silently clear a farmer-facing warning.
static bool s_abnormal_slots[NUM_CELLS] = {};
static bool s_pending_verification_slots[NUM_CELLS] = {};
static bool s_persistent_state_fault = false;
static bool s_scan_recovery_incomplete = false;

static bool nvs_save_snapshots(void);
#if ENABLE_DIAGNOSTIC_ALERT_API
static bool diagnostic_backup_begin(void);
static bool diagnostic_backup_restore_and_clear(void);
static void diagnostic_backup_boot_check(void);
#endif
static bool nvs_scan_transaction_begin(void);
static void nvs_scan_transaction_abort(void);
static void nvs_scan_transaction_commit_complete(void);
static bool nvs_reset_state_journal(void);

static bool s3_camera_focus_active(void)
{
    if (!s_s3_camera_focus_active) {
        return false;
    }

    if (esp_timer_get_time() < s_s3_camera_focus_deadline_us) {
        return true;
    }

    s_s3_camera_focus_active = false;
    s_s3_camera_focus_deadline_us = 0;
    ESP_LOGW(TAG, "S3 camera-focus timeout; background S3 traffic restored");
    return false;
}

static void s3_camera_focus_set(bool active)
{
    s_s3_camera_focus_active = active;
    s_s3_camera_focus_deadline_us = active
        ? esp_timer_get_time() + (int64_t)S3_CAMERA_FOCUS_TIMEOUT_MS * 1000LL
        : 0;
    ESP_LOGI(TAG,
             "S3 camera focus %s: climate + sensor telemetry active, nonessential S3 HTTP %s",
             active ? "ON" : "OFF", active ? "paused" : "restored");
}

// Door-triggered scan + rolling NVS storage
#define TRUE_ID_DAY      7           // day threshold for mobile candling review
#define TRANSFER_READY_DAY 19         // normal eggs move to the hatch/sub incubator
#define INFERTILE_CONFIRM_CANDLINGS 2
#define MAX_SNAPSHOTS    1           // newest completed scan data only in NVS
                                     // (56-slot metadata; never a JPEG/RGB image)

typedef enum {
    CELL_STATUS_NO_EGG = 0,
    CELL_STATUS_UNKNOWN,
    CELL_STATUS_FERTILE,
    CELL_STATUS_INFERTILE,
} CellStatus;

typedef struct {
    time_t  scan_time;                     // Unix timestamp
    bool    cell_has_egg[NUM_CELLS];       // grid state
    time_t  cell_start_time[NUM_CELLS];    // per-slot timestamps
    int     cell_day[NUM_CELLS];           // incubation day per slot
    uint8_t cell_status[NUM_CELLS];        // CellStatus per slot
    int     egg_count;                     // total eggs
    bool    valid;                         // slot populated
    bool    cell_infertile[NUM_CELLS];     // app-provided LED feedback marks
} EggSnapshot;

typedef enum {
    INTAKE_VERDICT_NONE = 0,
    INTAKE_VERDICT_NORMAL,
    INTAKE_VERDICT_ABNORMAL,
    INTAKE_VERDICT_PENDING,
} IntakeVerdict;

// Compact normal-light visual signature used only to notice a likely egg
// replacement in an already occupied slot. It never decides NORMAL/ABNORMAL.
typedef struct {
    uint8_t mean;
    uint8_t stddev;
    int8_t center_delta;
    uint8_t blob_score;
    uint8_t neutral_frac;
    uint8_t blue_ratio;
    bool valid;
} SlotFingerprint;

static uint8_t s_intake_verdict[NUM_CELLS] = {};
static SlotFingerprint s_slot_fingerprint[NUM_CELLS] = {};
static SlotFingerprint s_candidate_fingerprint[NUM_CELLS] = {};

// Runtime state that a scan can roll back if capture, inference, or the final
// durable commit fails. It mirrors only farmer-relevant durable state.
typedef struct {
    bool     cell_has_egg[NUM_CELLS];
    time_t   cell_start_time[NUM_CELLS];
    int      cell_day[NUM_CELLS];
    uint8_t  cell_status[NUM_CELLS];
    bool     cell_alert[NUM_CELLS];
    bool     infertile_slots[NUM_CELLS];
    uint8_t  infertile_streak[NUM_CELLS];
    bool     abnormal_slots[NUM_CELLS];
    bool     pending_verification_slots[NUM_CELLS];
    uint8_t  intake_verdict[NUM_CELLS];
    SlotFingerprint slot_fingerprint[NUM_CELLS];
    EggSnapshot snapshots[MAX_SNAPSHOTS];
    int      snapshot_count;
    int      last_scan_mday;
    int      last_egg_count;
    bool     scan_valid;
    time_t   last_phone_sync_time;
    bool     time_synced_from_phone;
    bool     time_trusted;
    char     time_source[16];
} EggRuntimeState;

#if ENABLE_DIAGNOSTIC_ALERT_API
#define DIAGNOSTIC_BACKUP_MAGIC   0x44494147u
#define DIAGNOSTIC_BACKUP_VERSION 1u
typedef struct {
    uint32_t magic;
    uint32_t version;
    EggRuntimeState state;
    uint32_t checksum;
} DiagnosticStateBackup;
static bool s_diagnostic_session_active = false;
#endif

// Exact schema-v1 layout retained for one-way migration. Existing installations
// keep every egg/date/warning while new fields start conservatively as pending.
typedef struct {
    bool     cell_has_egg[NUM_CELLS];
    time_t   cell_start_time[NUM_CELLS];
    int      cell_day[NUM_CELLS];
    uint8_t  cell_status[NUM_CELLS];
    bool     cell_alert[NUM_CELLS];
    bool     infertile_slots[NUM_CELLS];
    uint8_t  infertile_streak[NUM_CELLS];
    bool     abnormal_slots[NUM_CELLS];
    bool     pending_verification_slots[NUM_CELLS];
    EggSnapshot snapshots[MAX_SNAPSHOTS];
    int      snapshot_count;
    int      last_scan_mday;
    int      last_egg_count;
    bool     scan_valid;
    time_t   last_phone_sync_time;
    bool     time_synced_from_phone;
    bool     time_trusted;
    char     time_source[16];
} EggRuntimeStateV1;

// Two alternating complete records make an interrupted NVS write recoverable:
// a checksum-valid older record always remains available until the newer one
// has committed. Do not change this layout without raising the schema version.
#define EGG_STATE_MAGIC            0x45474753u  // "EGGS"
#define EGG_STATE_SCHEMA_VERSION   2u
#define EGG_STATE_KEY_A            "state_v2_a"
#define EGG_STATE_KEY_B            "state_v2_b"
#define EGG_STATE_TXN_KEY          "state_v2_txn"
#define EGG_STATE_V1_KEY_A         "state_v1_a"
#define EGG_STATE_V1_KEY_B         "state_v1_b"
#define EGG_STATE_V1_TXN_KEY       "state_v1_txn"
#define EGG_STATE_TXN_MAGIC        0x4554584Eu  // "ETXN"

typedef struct {
    uint32_t magic;
    uint16_t schema_version;
    uint16_t record_size;
    uint32_t generation;
    uint32_t checksum;
    EggRuntimeState state;
} EggStateRecord;

typedef struct {
    uint32_t magic;
    uint16_t schema_version;
    uint16_t record_size;
    uint32_t generation;
    uint32_t checksum;
    EggRuntimeStateV1 state;
} EggStateRecordV1;

typedef struct {
    uint32_t magic;
    uint16_t schema_version;
    uint16_t record_size;
    uint32_t base_generation;
    uint32_t checksum;
} EggScanTransaction;

// NVS boot recovery needs to compare two current records and, when required,
// two schema-v1 records plus their migrated forms. Keeping all six objects as
// locals overflows ESP-IDF's small app_main stack before the first NVS read.
typedef struct {
    EggStateRecord state_a;
    EggStateRecord state_b;
    EggStateRecordV1 v1_a;
    EggStateRecordV1 v1_b;
    EggRuntimeState migrated_a;
    EggRuntimeState migrated_b;
} EggStateLoadScratch;

static uint32_t s_nvs_state_generation = 0;
static int      s_nvs_state_active_slot = -1;
static bool     s_nvs_scan_transaction_active = false;
static SemaphoreHandle_t s_state_mutex = NULL;

static EggSnapshot s_snapshots[MAX_SNAPSHOTS] = {};
static int         s_snapshot_count  = 0;   // 0..MAX_SNAPSHOTS
static int         s_last_scan_mday  = -1;  // legacy NVS field; no scan scheduling
static int         s_cell_day[NUM_CELLS] = {};
static uint8_t     s_cell_status[NUM_CELLS] = {};
static bool        s_time_trusted = false;
static bool        s_time_synced_from_phone = false;
static time_t      s_last_phone_sync_time = 0;
static char        s_time_source[16] = "unsynced";

static void runtime_state_capture(EggRuntimeState *state)
{
    if (state == NULL) {
        return;
    }
    memcpy(state->cell_has_egg, s_cell_has_egg, sizeof(s_cell_has_egg));
    memcpy(state->cell_start_time, s_cell_start_time, sizeof(s_cell_start_time));
    memcpy(state->cell_day, s_cell_day, sizeof(s_cell_day));
    memcpy(state->cell_status, s_cell_status, sizeof(s_cell_status));
    memcpy(state->cell_alert, s_cell_alert, sizeof(s_cell_alert));
    memcpy(state->infertile_slots, s_infertile_slots, sizeof(s_infertile_slots));
    memcpy(state->infertile_streak, s_infertile_streak, sizeof(s_infertile_streak));
    memcpy(state->abnormal_slots, s_abnormal_slots, sizeof(s_abnormal_slots));
    memcpy(state->pending_verification_slots, s_pending_verification_slots,
           sizeof(s_pending_verification_slots));
    memcpy(state->intake_verdict, s_intake_verdict, sizeof(s_intake_verdict));
    memcpy(state->slot_fingerprint, s_slot_fingerprint,
           sizeof(s_slot_fingerprint));
    memcpy(state->snapshots, s_snapshots, sizeof(s_snapshots));
    state->snapshot_count = s_snapshot_count;
    state->last_scan_mday = s_last_scan_mday;
    state->last_egg_count = s_last_egg_count;
    state->scan_valid = s_scan_valid;
    state->last_phone_sync_time = s_last_phone_sync_time;
    state->time_synced_from_phone = s_time_synced_from_phone;
    state->time_trusted = s_time_trusted;
    memcpy(state->time_source, s_time_source, sizeof(s_time_source));
}

static void runtime_state_restore(const EggRuntimeState *state)
{
    if (state == NULL) {
        return;
    }
    memcpy(s_cell_has_egg, state->cell_has_egg, sizeof(s_cell_has_egg));
    memcpy(s_cell_start_time, state->cell_start_time, sizeof(s_cell_start_time));
    memcpy(s_cell_day, state->cell_day, sizeof(s_cell_day));
    memcpy(s_cell_status, state->cell_status, sizeof(s_cell_status));
    memcpy(s_cell_alert, state->cell_alert, sizeof(s_cell_alert));
    memcpy(s_infertile_slots, state->infertile_slots, sizeof(s_infertile_slots));
    memcpy(s_infertile_streak, state->infertile_streak, sizeof(s_infertile_streak));
    memcpy(s_abnormal_slots, state->abnormal_slots, sizeof(s_abnormal_slots));
    memcpy(s_pending_verification_slots, state->pending_verification_slots,
           sizeof(s_pending_verification_slots));
    memcpy(s_intake_verdict, state->intake_verdict, sizeof(s_intake_verdict));
    memcpy(s_slot_fingerprint, state->slot_fingerprint,
           sizeof(s_slot_fingerprint));
    memcpy(s_snapshots, state->snapshots, sizeof(s_snapshots));
    s_snapshot_count = state->snapshot_count;
    s_last_scan_mday = state->last_scan_mday;
    s_last_egg_count = state->last_egg_count;
    s_scan_valid = state->scan_valid;
    s_last_phone_sync_time = state->last_phone_sync_time;
    s_time_synced_from_phone = state->time_synced_from_phone;
    s_time_trusted = state->time_trusted;
    memcpy(s_time_source, state->time_source, sizeof(s_time_source));
    s_time_source[sizeof(s_time_source) - 1] = '\0';
}

static bool epoch_is_valid(time_t t)
{
    return (long long)t >= MIN_TRUSTED_EPOCH && (long long)t < MAX_TRUSTED_EPOCH;
}

static bool current_time_is_trusted(time_t now)
{
    return s_time_trusted && epoch_is_valid(now);
}

static void set_time_trust(bool trusted, const char *source)
{
    s_time_trusted = trusted;
    snprintf(s_time_source, sizeof(s_time_source), "%s",
             (trusted && source != NULL) ? source : "unsynced");
}

static time_t latest_stored_time_marker(void)
{
    time_t latest = s_last_phone_sync_time;
    for (int i = 0; i < NUM_CELLS; i++) {
        if (s_cell_start_time[i] > latest) {
            latest = s_cell_start_time[i];
        }
    }
    for (int i = 0; i < s_snapshot_count && i < MAX_SNAPSHOTS; i++) {
        if (s_snapshots[i].valid && s_snapshots[i].scan_time > latest) {
            latest = s_snapshots[i].scan_time;
        }
    }
    return latest;
}

static void validate_time_against_stored_state(const char *source)
{
    time_t now = time(NULL);
    if (!epoch_is_valid(now)) {
        set_time_trust(false, NULL);
        ESP_LOGW(TAG, "Clock is not trusted: invalid epoch %lld; waiting for phone time sync",
                 (long long)now);
        return;
    }

    time_t latest = latest_stored_time_marker();
    if (latest > 0 && now + TIME_BACKWARD_TOLERANCE_SEC < latest) {
        set_time_trust(false, NULL);
        ESP_LOGW(TAG,
                 "Clock is not trusted: now=%lld is behind stored data=%lld; waiting for phone time sync",
                 (long long)now, (long long)latest);
        return;
    }

    set_time_trust(true, source);
}

static int cell_elapsed_days(time_t now, time_t start_time)
{
    if (start_time == 0 || now <= start_time) {
        return 0;
    }
    return (int)((now - start_time) / 86400);
}

static int max_egg_day(void)
{
    int max_day = 0;
    for (int i = 0; i < NUM_CELLS; i++) {
        if (s_cell_has_egg[i] && s_cell_day[i] > max_day) {
            max_day = s_cell_day[i];
        }
    }
    return max_day;
}

static const char *cell_status_name(uint8_t status)
{
    return (status == CELL_STATUS_NO_EGG) ? "NO_EGG" : "EGG";
}

static const char *fertility_verdict_name(uint8_t status)
{
    switch ((CellStatus)status) {
        case CELL_STATUS_FERTILE:   return "fertile";
        case CELL_STATUS_INFERTILE: return "infertile";
        case CELL_STATUS_NO_EGG:    return "none";
        case CELL_STATUS_UNKNOWN:
        default:                    return "pending";
    }
}

static bool cell_fertile_result(int cell)
{
    return cell >= 0 && cell < NUM_CELLS && s_cell_has_egg[cell] &&
           s_cell_status[cell] == CELL_STATUS_FERTILE;
}

static bool cell_infertile_result(int cell)
{
    return cell >= 0 && cell < NUM_CELLS && s_cell_has_egg[cell] &&
           s_cell_status[cell] == CELL_STATUS_INFERTILE;
}

static const char *intake_verdict_name(uint8_t verdict)
{
    switch ((IntakeVerdict)verdict) {
        case INTAKE_VERDICT_NORMAL:   return "normal";
        case INTAKE_VERDICT_ABNORMAL: return "abnormal";
        case INTAKE_VERDICT_PENDING:  return "pending";
        case INTAKE_VERDICT_NONE:
        default:                      return "none";
    }
}

static void set_intake_verdict(int cell, IntakeVerdict verdict)
{
    if (cell < 0 || cell >= NUM_CELLS) return;
    s_intake_verdict[cell] = (uint8_t)verdict;
    s_abnormal_slots[cell] = verdict == INTAKE_VERDICT_ABNORMAL;
    s_pending_verification_slots[cell] = verdict == INTAKE_VERDICT_PENDING;
}

static bool cell_confirmed_infertile(int cell)
{
    return cell >= 0 && cell < NUM_CELLS && s_cell_has_egg[cell] &&
           s_infertile_slots[cell] && s_cell_day[cell] >= TRUE_ID_DAY &&
           s_infertile_streak[cell] >= INFERTILE_CONFIRM_CANDLINGS;
}

static bool cell_remove_alert(int cell)
{
    return cell >= 0 && cell < NUM_CELLS && s_cell_has_egg[cell] &&
           (s_abnormal_slots[cell] || cell_confirmed_infertile(cell));
}

static bool cell_transfer_ready(int cell)
{
    return cell >= 0 && cell < NUM_CELLS && s_cell_has_egg[cell] &&
           !cell_remove_alert(cell) &&
           s_intake_verdict[cell] == INTAKE_VERDICT_NORMAL &&
           s_cell_day[cell] >= TRANSFER_READY_DAY;
}

static int count_cells_matching(bool (*predicate)(int))
{
    int count = 0;
    if (predicate == NULL) return count;
    for (int i = 0; i < NUM_CELLS; i++) {
        if (predicate(i)) count++;
    }
    return count;
}

static int pending_intake_count(void)
{
    int count = 0;
    for (int i = 0; i < NUM_CELLS; i++) {
        if (s_cell_has_egg[i] && s_pending_verification_slots[i]) count++;
    }
    return count;
}

static const char *equipment_fault_code(void)
{
    if (s_persistent_state_fault) return "state_recovery";
    if (s_climate_sensor_fault) return "temperature_sensor";
    if (s_scan_recovery_incomplete) return "scan_recovered";
    if (s_last_scan_failure != SCAN_FAIL_NONE) {
        return scan_failure_key((ScanFailureReason)s_last_scan_failure);
    }
    if (AUTOMATIC_INTAKE_SCREENING_ENABLED &&
        !INTAKE_MODEL_INSTALLED && pending_intake_count() > 0) {
        return "intake_model_missing";
    }
    return "none";
}

static const char *equipment_fault_message(const char *code)
{
    if (code == NULL || strcmp(code, "none") == 0) return "";
    if (strcmp(code, "state_recovery") == 0) return "Egg state needs recovery";
    if (strcmp(code, "temperature_sensor") == 0) return "Temperature sensor fault";
    if (strcmp(code, "scan_recovered") == 0) return "Interrupted scan recovered";
    if (strcmp(code, "intake_model_missing") == 0) return "Intake model not installed";
    return "Camera or scan needs attention";
}

static void apply_release_intake_delimitation(void)
{
    if (AUTOMATIC_INTAKE_SCREENING_ENABLED) return;

    bool changed = false;
    for (int cell = 0; cell < NUM_CELLS; cell++) {
        if (s_pending_verification_slots[cell]) {
            s_pending_verification_slots[cell] = false;
            changed = true;
        }
        if (s_intake_verdict[cell] == INTAKE_VERDICT_PENDING) {
            s_intake_verdict[cell] = INTAKE_VERDICT_NONE;
            changed = true;
        }
#if ENABLE_DIAGNOSTIC_ALERT_API
        if (!s_diagnostic_session_active &&
            (s_abnormal_slots[cell] ||
             s_intake_verdict[cell] == INTAKE_VERDICT_ABNORMAL)) {
            s_abnormal_slots[cell] = false;
            s_intake_verdict[cell] = INTAKE_VERDICT_NONE;
            changed = true;
        }
#else
        if (s_abnormal_slots[cell] ||
            s_intake_verdict[cell] == INTAKE_VERDICT_ABNORMAL) {
            s_abnormal_slots[cell] = false;
            s_intake_verdict[cell] = INTAKE_VERDICT_NONE;
            changed = true;
        }
#endif
    }
    if (changed) {
        ESP_LOGI(TAG,
                 "Cleared legacy automatic intake verdict state; screening is outside this release");
        if (!nvs_save_snapshots()) {
            ESP_LOGW(TAG, "Could not persist release intake delimitation cleanup");
        }
    }
}

static bool json_item_bool(cJSON *item, bool fallback)
{
    if (cJSON_IsBool(item)) {
        return cJSON_IsTrue(item);
    }
    if (cJSON_IsNumber(item)) {
        return item->valuedouble != 0.0;
    }
    if (cJSON_IsString(item) && item->valuestring != NULL) {
        return strcasecmp(item->valuestring, "true") == 0 ||
               strcmp(item->valuestring, "1") == 0 ||
               strcasecmp(item->valuestring, "yes") == 0;
    }
    return fallback;
}

static long long json_item_epoch_seconds(cJSON *item, long long fallback)
{
    if (cJSON_IsNumber(item)) {
        long long value = (long long)item->valuedouble;
        if (value > 1000000000000LL) {
            value /= 1000LL;
        }
        return value;
    }
    if (cJSON_IsString(item) && item->valuestring != NULL) {
        char *end = NULL;
        long long value = strtoll(item->valuestring, &end, 10);
        if (end != item->valuestring) {
            if (value > 1000000000000LL) {
                value /= 1000LL;
            }
            return value;
        }
    }
    return fallback;
}

static uint8_t resolve_cell_status(bool has_egg, int days,
                                   bool infertile_marked,
                                   uint8_t previous_status)
{
    (void)days;
    if (!has_egg) {
        return CELL_STATUS_NO_EGG;
    }
    if (infertile_marked) {
        return CELL_STATUS_INFERTILE;
    }
    if (previous_status == CELL_STATUS_FERTILE) {
        return CELL_STATUS_FERTILE;
    }
    return CELL_STATUS_UNKNOWN;
}

static void refresh_cell_day_status(time_t now)
{
    bool trusted = current_time_is_trusted(now);
    int total = 0;
    for (int i = 0; i < NUM_CELLS; i++) {
        if (s_cell_has_egg[i]) {
            total++;
            if (s_cell_start_time[i] == 0 && trusted) {
                s_cell_start_time[i] = now;
            }
            if (trusted && s_cell_start_time[i] > 0) {
                s_cell_day[i] = cell_elapsed_days(now, s_cell_start_time[i]);
            }
            s_cell_status[i] = resolve_cell_status(
                true, s_cell_day[i], s_infertile_slots[i], s_cell_status[i]);
            s_cell_alert[i] = (s_cell_day[i] >= TRUE_ID_DAY);
        } else {
            s_cell_day[i] = 0;
            s_cell_status[i] = CELL_STATUS_NO_EGG;
            s_cell_alert[i] = false;
            s_cell_start_time[i] = 0;
            s_infertile_slots[i] = false;
            s_infertile_streak[i] = 0;
            s_abnormal_slots[i] = false;
            s_pending_verification_slots[i] = false;
            s_intake_verdict[i] = INTAKE_VERDICT_NONE;
            memset(&s_slot_fingerprint[i], 0, sizeof(s_slot_fingerprint[i]));
        }
    }
    s_last_egg_count = total;
}

static void clear_egg_runtime_data(void)
{
    memset(s_cell_has_egg, 0, sizeof(s_cell_has_egg));
    memset(s_cell_start_time, 0, sizeof(s_cell_start_time));
    memset(s_cell_alert, 0, sizeof(s_cell_alert));
    memset(s_infertile_slots, 0, sizeof(s_infertile_slots));
    memset(s_infertile_streak, 0, sizeof(s_infertile_streak));
    memset(s_abnormal_slots, 0, sizeof(s_abnormal_slots));
    memset(s_pending_verification_slots, 0, sizeof(s_pending_verification_slots));
    memset(s_intake_verdict, 0, sizeof(s_intake_verdict));
    memset(s_slot_fingerprint, 0, sizeof(s_slot_fingerprint));
    memset(s_candidate_fingerprint, 0, sizeof(s_candidate_fingerprint));
    memset(s_snapshots, 0, sizeof(s_snapshots));
    memset(s_cell_day, 0, sizeof(s_cell_day));
    memset(s_cell_status, 0, sizeof(s_cell_status));
    s_snapshot_count = 0;
    s_last_scan_mday = -1;
    s_last_egg_count = 0;
    s_scan_valid = false;
    s_last_scan_failure = SCAN_FAIL_NONE;
    s_scan_retry_count = 0;
}

static void grid_apply_default_config(void)
{
    s_grid_cols = GRID_COLS;
    s_grid_rows = GRID_ROWS;
    s_tray_w_cm = TRAY_W_CM;
    s_tray_h_cm = TRAY_H_CM;
    memset(s_col_bounds_cm, 0, sizeof(s_col_bounds_cm));
    memset(s_row_bounds_cm, 0, sizeof(s_row_bounds_cm));
    memcpy(s_col_bounds_cm, DEFAULT_COL_BOUNDS_CM, sizeof(DEFAULT_COL_BOUNDS_CM));
    memcpy(s_row_bounds_cm, DEFAULT_ROW_BOUNDS_CM, sizeof(DEFAULT_ROW_BOUNDS_CM));
    s_grid_config_ready = true;
}

static bool grid_bounds_valid(const float *bounds, int count, float max_value)
{
    if (bounds == NULL || count < 1) {
        return false;
    }
    if (bounds[0] < -0.001f) {
        return false;
    }
    if (bounds[count] > max_value + 0.001f) {
        return false;
    }
    for (int i = 1; i <= count; i++) {
        if (!(bounds[i] > bounds[i - 1])) {
            return false;
        }
    }
    return true;
}

static bool grid_config_valid(int cols, int rows,
                              const float *col_bounds,
                              const float *row_bounds)
{
    if (cols < 1 || cols > MAX_GRID_COLS ||
        rows < 1 || rows > MAX_GRID_ROWS ||
        cols * rows > NUM_CELLS) {
        return false;
    }

    if (!grid_bounds_valid(col_bounds, cols, TRAY_W_CM) ||
        !grid_bounds_valid(row_bounds, rows, TRAY_H_CM)) {
        return false;
    }

    return true;
}

static void grid_save_config(void)
{
    if (!s_grid_config_ready) {
        ESP_LOGW(TAG, "Grid save skipped; no custom grid is active");
        return;
    }

    nvs_handle_t h;
    if (nvs_open("egg_data", NVS_READWRITE, &h) != ESP_OK) {
        ESP_LOGW(TAG, "NVS open failed (save grid)");
        return;
    }
    nvs_set_i32(h, "grid_cols", s_grid_cols);
    nvs_set_i32(h, "grid_rows", s_grid_rows);
    nvs_set_i32(h, "grid_def_ver", GRID_DEFAULT_VERSION);
    nvs_set_blob(h, "grid_col_cm", s_col_bounds_cm,
                 sizeof(float) * (s_grid_cols + 1));
    nvs_set_blob(h, "grid_row_cm", s_row_bounds_cm,
                 sizeof(float) * (s_grid_rows + 1));
    nvs_commit(h);
    nvs_close(h);
}

static void grid_erase_saved_config(void)
{
    nvs_handle_t h;
    if (nvs_open("egg_data", NVS_READWRITE, &h) != ESP_OK) {
        ESP_LOGW(TAG, "NVS open failed (erase grid)");
        return;
    }
    nvs_erase_key(h, "grid_cols");
    nvs_erase_key(h, "grid_rows");
    nvs_erase_key(h, "grid_col_cm");
    nvs_erase_key(h, "grid_row_cm");
    nvs_erase_key(h, "grid_rst_ver");
    nvs_erase_key(h, "grid_def_ver");
    nvs_commit(h);
    nvs_close(h);
}

static void grid_load_config(void)
{
    grid_apply_default_config();

    nvs_handle_t h;
    if (nvs_open("egg_data", NVS_READONLY, &h) != ESP_OK) {
        ESP_LOGI(TAG, "No saved custom grid config; using built-in default grid");
        return;
    }

    int32_t default_version = 0;
    if (nvs_get_i32(h, "grid_def_ver", &default_version) != ESP_OK ||
        default_version != GRID_DEFAULT_VERSION) {
        nvs_close(h);
        ESP_LOGI(TAG,
                 "Saved grid is from an older default version; using built-in default grid v%d",
                 GRID_DEFAULT_VERSION);
        grid_erase_saved_config();
        grid_apply_default_config();
        return;
    }

    int32_t cols = GRID_COLS;
    int32_t rows = GRID_ROWS;
    float col_bounds[MAX_GRID_COLS + 1] = {};
    float row_bounds[MAX_GRID_ROWS + 1] = {};
    size_t col_sz = sizeof(col_bounds);
    size_t row_sz = sizeof(row_bounds);

    bool ok = nvs_get_i32(h, "grid_cols", &cols) == ESP_OK &&
              nvs_get_i32(h, "grid_rows", &rows) == ESP_OK &&
              nvs_get_blob(h, "grid_col_cm", col_bounds, &col_sz) == ESP_OK &&
              nvs_get_blob(h, "grid_row_cm", row_bounds, &row_sz) == ESP_OK;
    nvs_close(h);

    if (!ok ||
        cols < 1 || cols > MAX_GRID_COLS ||
        rows < 1 || rows > MAX_GRID_ROWS ||
        col_sz < sizeof(float) * (cols + 1) ||
        row_sz < sizeof(float) * (rows + 1) ||
        !grid_config_valid((int)cols, (int)rows, col_bounds, row_bounds)) {
        ESP_LOGW(TAG, "Invalid/missing saved custom grid config; using built-in default grid");
        grid_apply_default_config();
        return;
    }

    s_grid_cols = (int)cols;
    s_grid_rows = (int)rows;
    s_tray_w_cm = TRAY_W_CM;
    s_tray_h_cm = TRAY_H_CM;
    memcpy(s_col_bounds_cm, col_bounds, sizeof(float) * (s_grid_cols + 1));
    memcpy(s_row_bounds_cm, row_bounds, sizeof(float) * (s_grid_rows + 1));
    s_grid_config_ready = true;
    ESP_LOGI(TAG, "Loaded grid config: %dx%d tray=%.1fx%.1fcm",
             s_grid_cols, s_grid_rows, s_tray_w_cm, s_tray_h_cm);
}

// WiFi
static EventGroupHandle_t s_wifi_eg;
#define WIFI_CONNECTED_BIT BIT0
#define WIFI_FAIL_BIT      BIT1

// RELAY GPIO PINS
// Fan1 + PTC share the 2-channel relay module. Fan2 uses the 1-channel module.
#define RELAY_FAN1_GPIO   GPIO_NUM_3    // 2-ch module CH1 -> Fan1
#define RELAY_PTC_GPIO    GPIO_NUM_4    // 2-ch module CH2 -> PTC heater
#define RELAY_FAN2_GPIO   GPIO_NUM_5    // 1-ch module -> Fan2 cooling
#define RELAY_TRAY_GPIO   GPIO_NUM_20   // 1-ch module -> egg tray motor
#define RELAY_BULB_GPIO   GPIO_NUM_33   // Main-incubator bulb relay

// Magnetic door sensor. Wire one sensor lead to GND and the other to GPIO46.
// With the internal pull-up enabled: closed = LOW, open = HIGH.
#define DOOR_SWITCH_ENABLED       1
#define DOOR_SWITCH_GPIO          GPIO_NUM_46
#define DOOR_CLOSED_LEVEL         0
#define DOOR_OPEN_DEBOUNCE_MS     150
// A noisy or disconnected input must never energize the tray. Opening remains
// fast/fail-safe, while closing must stay continuously LOW before it is trusted.
#define DOOR_CLOSE_DEBOUNCE_MS    3000
#define DOOR_TASK_TICK_MS         100
#define DOOR_CLOSE_SCAN_DELAY_MS  8000
#define DOOR_SCAN_LOCKOUT_MS      30000
#define PERIODIC_CAPTUREP4_ENABLED     0
#define PERIODIC_CAPTUREP4_INTERVAL_MS 120000

// No tray home switch is installed. Before scanning/candling, stop the tray
// wherever it is and let eggs/camera settle before capture.
#define TRAY_CAPTURE_SETTLE_MS  500
#define TRAY_RESUME_POWER_SAVE_MS 3000
#define CLIMATE_RESTORE_AFTER_TRAY_MS 15000
#define SCAN_OPERATION_DEADLINE_MS 180000
#define CAPTURE_HOLD_FAILSAFE_SEC  120

// Most opto-isolated relay modules are ACTIVE LOW (LOW = relay closes)
#define RELAY_ON    0
#define RELAY_OFF   1

// Candling slot LEDs through 7 chained 74HC595 shift registers.
// Same mapping as the Arduino test: LED index -> register=index/8, bit=index%8.
// Disabled: LED control handled by external microcontroller
#define ENABLE_SLOT_LED_OUTPUTS 0
#define SLOT_LED_DATA_GPIO   GPIO_NUM_32  // 74HC595 DS / pin 14
#define SLOT_LED_CLOCK_GPIO  GPIO_NUM_47  // 74HC595 SHCP / pin 11
// GPIO33 now belongs exclusively to the main-incubator bulb relay. If local
// slot LED outputs are re-enabled later, their latch pin must be remapped.
#define SLOT_LED_LATCH_GPIO  GPIO_NUM_NC
#define SLOT_LED_REGISTER_COUNT 7
#define SLOT_LED_COUNT NUM_CELLS
// Logical mask bit 1 means "LED ON". Arduino validation showed the 74HC595
// LED chain is active-high: shifting 0 turns a slot OFF, shifting 1 turns it ON.
#define SLOT_LED_ACTIVE_LOW 0
#define SLOT_LED_SHIFT_DELAY_US 20
// Keep normal candling focused on the slots marked by the app. Set this to 1
// only if you want every occupied egg slot to light solid during candling.
#define SLOT_LED_CANDLING_SHOW_OCCUPIED_SOLID 0

// Short timeout for manual LED tests and a longer fail-safe for app candling.
// The app permits a slow camera capture to run for up to five minutes and
// normally calls /candling_stop as soon as the image has downloaded.
#define CANDLE_LED_DURATION_SEC  15
#define CANDLING_CAPTURE_FAILSAFE_SEC 120
#define GET_SLOTS_RESP_BUF_SIZE 24576
#define SET_SLOTS_REQ_BUF_SIZE 8192

// Blink-state for P4 slot LED feedback.
static TimerHandle_t s_blink_timer  = NULL;
static TimerHandle_t s_candle_timer = NULL;
static TimerHandle_t s_capture_hold_timer = NULL;
static TimerHandle_t s_scan_deadline_timer = NULL;
static uint8_t      s_blink_mask[SLOT_LED_REGISTER_COUNT] = {};
static uint8_t      s_slot_led_mask[SLOT_LED_REGISTER_COUNT] = {};
static bool         s_blink_state  = false;
static bool         s_tray_paused_for_candling = false;
static bool         s_tray_paused_for_capture = false;
static bool         s_tray_motor_requested_on = false;
static bool         s_tray_motor_door_blocked = false;
static bool         s_tray_door_closed_confirmed = false;
static int64_t      s_tray_door_close_started_us = 0;
static bool         s_bulb_candling_hold = false;
static bool         s_bulb_ai_hold = false;
static bool         s_bulb_normal_capture_override = false;
static bool         s_bulb_temperature_demand = false;
static bool         s_bulb_door_open = false;
static bool         s_bulb_door_light_expired = false;
static int64_t      s_bulb_door_opened_us = 0;
static bool         s_bulb_relay_on = false;
static volatile bool s_scan_deadline_expired = false;

typedef enum {
    HARDWARE_OP_NONE = 0,
    HARDWARE_OP_SCAN,
    HARDWARE_OP_CANDLING,
    HARDWARE_OP_CAPTURE_HOLD,
    HARDWARE_OP_RESTORING,
} HardwareOperation;

static portMUX_TYPE s_hardware_operation_mux = portMUX_INITIALIZER_UNLOCKED;
static volatile HardwareOperation s_hardware_operation = HARDWARE_OP_NONE;

static bool hardware_operation_begin(HardwareOperation operation,
                                     bool allow_renew)
{
    bool acquired = false;
    portENTER_CRITICAL(&s_hardware_operation_mux);
    if (s_hardware_operation == HARDWARE_OP_NONE ||
        (allow_renew && s_hardware_operation == operation)) {
        s_hardware_operation = operation;
        acquired = true;
    }
    portEXIT_CRITICAL(&s_hardware_operation_mux);
    return acquired;
}

static bool hardware_operation_claim_restore(HardwareOperation operation)
{
    bool claimed = false;
    portENTER_CRITICAL(&s_hardware_operation_mux);
    if (s_hardware_operation == operation) {
        s_hardware_operation = HARDWARE_OP_RESTORING;
        claimed = true;
    }
    portEXIT_CRITICAL(&s_hardware_operation_mux);
    return claimed;
}

static void hardware_operation_finish_restore(void)
{
    portENTER_CRITICAL(&s_hardware_operation_mux);
    if (s_hardware_operation == HARDWARE_OP_RESTORING) {
        s_hardware_operation = HARDWARE_OP_NONE;
    }
    portEXIT_CRITICAL(&s_hardware_operation_mux);
}

// TEMPERATURE CONTROL
// Hysteresis avoids relay chatter while the incubator temperature settles.
// PTC + Fan1 heat ON below 37.4 C, OFF at/above 37.6 C.
// Fan2 cooling ON at/above 37.8 C, OFF at/below 37.6 C.
// The main bulb supplements heat only below the normal band. It is forced OFF
// once the heater's upper threshold is reached, while Fan2 handles overheating.
// Opening the door temporarily requests light for the farmer. A normal
// /capturep4 scan also requests consistent illumination until its JPEG is
// fully downloaded. Candling darkness and AI power-save always win.
// Normal range: 37.4 C to 37.8 C.
#define TEMP_HEAT_ON    37.4f   // Heater + Fan1 switch ON  below this
#define TEMP_HEAT_OFF   37.6f   // Heater + Fan1 switch OFF at/above this
#define TEMP_COOL_ON    37.8f   // Fan2 cooling switch ON   at/above this
#define TEMP_COOL_OFF   37.6f   // Fan2 cooling switch OFF  at/below this
#define TEMP_BULB_ON    37.4f   // Main bulb may switch ON below this
#define TEMP_BULB_OFF   37.6f   // Main bulb switches OFF at/above this
#define BULB_DOOR_LIGHT_MAX_MS 300000

// Relay state (file-scope, shared between sensor_task and LCD)
static bool s_heater_on = false;
static bool s_cooler_on = false;
static volatile int64_t s_climate_holdoff_until_us = 0;

static bool bulb_relay_door_light_active(void)
{
    return s_bulb_door_open && !s_bulb_door_light_expired;
}

static void bulb_relay_apply_state(void)
{
    bool door_light = bulb_relay_door_light_active();
    bool climate_safe = s_main_climate_valid &&
                        !s_climate_sensor_fault &&
                        !s_cooler_on;
    bool should_be_on = !s_bulb_candling_hold &&
                        !s_bulb_ai_hold &&
                        (s_bulb_normal_capture_override ||
                         (climate_safe &&
                          (door_light || s_bulb_temperature_demand)));
    if (s_bulb_relay_on == should_be_on) {
        return;
    }

    const char *reason = "temperature_ok";
    if (s_bulb_candling_hold) {
        reason = "candling_darkness";
    } else if (s_bulb_ai_hold) {
        reason = "ai_power_save";
    } else if (s_bulb_normal_capture_override) {
        reason = "normal_capture_light";
    } else if (!s_main_climate_valid || s_climate_sensor_fault) {
        reason = "temperature_sensor_unavailable";
    } else if (s_cooler_on) {
        reason = "cooling_active";
    } else if (door_light) {
        reason = "door_open_visibility";
    } else if (s_bulb_temperature_demand) {
        reason = "temperature_low";
    }

    s_bulb_relay_on = should_be_on;
    gpio_set_level(RELAY_BULB_GPIO, should_be_on ? RELAY_ON : RELAY_OFF);
    ESP_LOGI(TAG,
             "Main bulb %s (GPIO%d reason=%s temp=%.1fC door=%s capture_light=%s candling_hold=%s ai_hold=%s)",
             should_be_on ? "ON" : "OFF", (int)RELAY_BULB_GPIO,
             reason, s_main_temp,
             door_light ? "light" : "auto",
             s_bulb_normal_capture_override ? "yes" : "no",
             s_bulb_candling_hold ? "yes" : "no",
             s_bulb_ai_hold ? "yes" : "no");
}

static void bulb_relay_update_temperature(float temp)
{
    bool previous = s_bulb_temperature_demand;
    if (!isfinite(temp)) {
        s_bulb_temperature_demand = false;
    } else if (temp < TEMP_BULB_ON) {
        s_bulb_temperature_demand = true;
    } else if (temp >= TEMP_BULB_OFF) {
        s_bulb_temperature_demand = false;
    }

    if (previous != s_bulb_temperature_demand) {
        ESP_LOGI(TAG, "Main bulb temperature demand %s at %.1fC (ON<%.1f OFF>=%.1f)",
                 s_bulb_temperature_demand ? "ON" : "OFF", temp,
                 TEMP_BULB_ON, TEMP_BULB_OFF);
    }
    bulb_relay_apply_state();
}

static void bulb_relay_set_temperature_unavailable(void)
{
    s_bulb_temperature_demand = false;
    bulb_relay_apply_state();
}

static void bulb_relay_set_door_open(bool open)
{
    bool changed = s_bulb_door_open != open;
    s_bulb_door_open = open;
    if (open) {
        s_bulb_door_light_expired = false;
        s_bulb_door_opened_us = esp_timer_get_time();
    } else {
        s_bulb_door_light_expired = false;
        s_bulb_door_opened_us = 0;
    }

    if (changed) {
        ESP_LOGI(TAG, "Door bulb request %s%s",
                 open ? "ON" : "OFF",
                 open ? " (visibility, 5-minute fail-safe)" : "");
    }
    bulb_relay_apply_state();
}

static void bulb_relay_service(void)
{
    if (!s_bulb_door_open || s_bulb_door_light_expired ||
        s_bulb_door_opened_us == 0) {
        return;
    }

    int64_t elapsed_us = esp_timer_get_time() - s_bulb_door_opened_us;
    if (elapsed_us >= (int64_t)BULB_DOOR_LIGHT_MAX_MS * 1000LL) {
        s_bulb_door_light_expired = true;
        ESP_LOGW(TAG,
                 "Door remained open for 5 minutes; bulb visibility override expired");
        bulb_relay_apply_state();
    }
}

static void bulb_relay_set_candling_hold(bool active)
{
    s_bulb_candling_hold = active;
    bulb_relay_apply_state();
}

static void bulb_relay_set_ai_hold(bool active)
{
    s_bulb_ai_hold = active;
    bulb_relay_apply_state();
}

static void bulb_relay_set_normal_capture_override(bool active)
{
    if (s_bulb_normal_capture_override == active) {
        return;
    }
    s_bulb_normal_capture_override = active;
    ESP_LOGI(TAG, "Normal /capturep4 bulb override %s",
             active ? "ON" : "OFF");
    bulb_relay_apply_state();
}

struct NormalCaptureBulbGuard {
    bool active;

    NormalCaptureBulbGuard(void) : active(true)
    {
        bulb_relay_set_normal_capture_override(true);
    }

    ~NormalCaptureBulbGuard(void) { release(); }

    void release(void)
    {
        if (!active) {
            return;
        }
        active = false;
        bulb_relay_set_normal_capture_override(false);
    }
};

static bool rtc_marker_is_set(uint32_t value, uint32_t inverse, uint32_t magic)
{
    return value == magic && inverse == ~magic;
}

static void ai_inference_guard_set(bool active)
{
    if (active) {
        s_ai_inference_guard_magic = AI_INFERENCE_GUARD_MAGIC;
        s_ai_inference_guard_inverse = ~AI_INFERENCE_GUARD_MAGIC;
    } else {
        s_ai_inference_guard_magic = 0;
        s_ai_inference_guard_inverse = 0;
    }
}

static void ai_inference_disabled_latch_set(bool disabled)
{
    if (disabled) {
        s_ai_inference_disabled_magic = AI_INFERENCE_DISABLED_MAGIC;
        s_ai_inference_disabled_inverse = ~AI_INFERENCE_DISABLED_MAGIC;
    } else {
        s_ai_inference_disabled_magic = 0;
        s_ai_inference_disabled_inverse = 0;
    }
}

static void climate_relays_force_off_for_ai(void)
{
    gpio_set_level(RELAY_FAN1_GPIO, RELAY_OFF);
    gpio_set_level(RELAY_PTC_GPIO, RELAY_OFF);
    gpio_set_level(RELAY_FAN2_GPIO, RELAY_OFF);
}

static bool climate_holdoff_active(void);

static void climate_relays_apply_requested_state(void)
{
    // No fan has been physically verified as an independent non-heating
    // circulation output yet, so a temperature-sensor fault turns all three
    // climate outputs off.
    if (s_climate_sensor_fault || climate_holdoff_active()) {
        climate_relays_force_off_for_ai();
        return;
    }

    gpio_set_level(RELAY_FAN1_GPIO, s_heater_on ? RELAY_ON : RELAY_OFF);
    gpio_set_level(RELAY_PTC_GPIO, s_heater_on ? RELAY_ON : RELAY_OFF);
    gpio_set_level(RELAY_FAN2_GPIO, s_cooler_on ? RELAY_ON : RELAY_OFF);
}

static bool climate_holdoff_active(void)
{
    return esp_timer_get_time() < s_climate_holdoff_until_us;
}

static void climate_relays_holdoff_for_ms(uint32_t ms)
{
    s_climate_holdoff_until_us = esp_timer_get_time() + ((int64_t)ms * 1000LL);
    climate_relays_force_off_for_ai();
}

static void climate_relays_restore_after_ai(void)
{
    climate_relays_apply_requested_state();
}

static void s3_ai_power_save_set(bool active);
static void tray_motor_apply_requested_state(void);
static void tray_motor_request(bool run);
static void slot_leds_off(void);
static void slot_led_shift_write(const uint8_t data[SLOT_LED_REGISTER_COUNT]);
static void slot_led_mask_clear(uint8_t mask[SLOT_LED_REGISTER_COUNT]);
static void slot_led_mask_set_cell(uint8_t mask[SLOT_LED_REGISTER_COUNT], int cell);

static void scan_deadline_cb(TimerHandle_t x)
{
    (void)x;
    s_scan_deadline_expired = true;

    // This callback runs independently of JPEG decode and TFLM Invoke(). Even
    // if the scan task is delayed, local outputs return to their safe normal
    // ownership immediately; climate stays safely off until the scan task
    // unwinds and the guard can restore normal sensor ownership.
    bulb_relay_set_normal_capture_override(false);
    bulb_relay_set_ai_hold(false);
    slot_leds_off();
    tray_motor_request(true);
    climate_relays_force_off_for_ai();
    ESP_LOGE(TAG,
             "Scan hard deadline expired after %d ms in phase=%s; outputs restored",
             SCAN_OPERATION_DEADLINE_MS, scan_phase_name(s_scan_phase));
}

static void p4_outputs_force_off_for_ai(void)
{
    climate_relays_force_off_for_ai();
    gpio_set_level(RELAY_TRAY_GPIO, RELAY_OFF);
    bulb_relay_set_ai_hold(true);
#if ENABLE_SLOT_LED_OUTPUTS
    slot_leds_off();
    if (s_candle_timer != NULL) {
        xTimerStop(s_candle_timer, 0);
    }
#endif
}

static void p4_outputs_restore_after_ai(void)
{
    climate_relays_restore_after_ai();
    tray_motor_apply_requested_state();
    bulb_relay_set_ai_hold(false);
}

struct ScanActiveGuard {
    bool armed;
    bool state_lock_held;
    bool state_transaction_started;
    bool state_committed;
    bool state_storage_failed;
    EggRuntimeState baseline;

    ScanActiveGuard(void)
        : armed(false), state_lock_held(false), state_transaction_started(false),
          state_committed(false), state_storage_failed(false), baseline{}
    {
        s_scan_deadline_expired = false;
        if (!hardware_operation_begin(HARDWARE_OP_SCAN, false)) {
            ESP_LOGW(TAG, "Scan blocked: another hardware operation is active");
            return;
        }
        scan_phase_set(SCAN_PHASE_ACQUIRE);
        if (s_scan_deadline_timer == NULL) {
            s_scan_deadline_timer = xTimerCreate(
                "scanDeadline", pdMS_TO_TICKS(SCAN_OPERATION_DEADLINE_MS),
                pdFALSE, NULL, scan_deadline_cb);
        }
        if (s_scan_deadline_timer == NULL ||
            xTimerChangePeriod(s_scan_deadline_timer,
                               pdMS_TO_TICKS(SCAN_OPERATION_DEADLINE_MS),
                               pdMS_TO_TICKS(100)) != pdPASS) {
            ESP_LOGE(TAG, "Cannot arm scan hard deadline; scan blocked");
            s_scan_deadline_expired = true;
            if (hardware_operation_claim_restore(HARDWARE_OP_SCAN)) {
                hardware_operation_finish_restore();
            }
            return;
        }
        if (s_state_mutex == NULL ||
            xSemaphoreTake(s_state_mutex, pdMS_TO_TICKS(500)) != pdTRUE) {
            ESP_LOGW(TAG, "Scan blocked: durable state is busy");
            xTimerStop(s_scan_deadline_timer, pdMS_TO_TICKS(100));
            if (hardware_operation_claim_restore(HARDWARE_OP_SCAN)) {
                hardware_operation_finish_restore();
            }
            return;
        }
        state_lock_held = true;
        runtime_state_capture(&baseline);
        if (!nvs_scan_transaction_begin()) {
            ESP_LOGE(TAG, "Cannot start durable scan transaction; scan blocked");
            state_storage_failed = true;
            xTimerStop(s_scan_deadline_timer, pdMS_TO_TICKS(100));
            if (hardware_operation_claim_restore(HARDWARE_OP_SCAN)) {
                hardware_operation_finish_restore();
            }
            return;
        }
        state_transaction_started = true;
        s_ai_scan_active = true;
        armed = true;
    }

    ~ScanActiveGuard(void)
    {
        if (state_transaction_started && !state_committed) {
            runtime_state_restore(&baseline);
            nvs_scan_transaction_abort();
        }
        if (!armed) {
            if (state_lock_held) {
                xSemaphoreGive(s_state_mutex);
                state_lock_held = false;
            }
            scan_phase_set(SCAN_PHASE_IDLE);
            return;
        }
        scan_phase_set(SCAN_PHASE_RESTORE);
        if (s_scan_deadline_timer != NULL) {
            xTimerStop(s_scan_deadline_timer, pdMS_TO_TICKS(100));
        }
        if (hardware_operation_claim_restore(HARDWARE_OP_SCAN)) {
            s_ai_scan_active = false;
            bulb_relay_set_normal_capture_override(false);
            bulb_relay_set_ai_hold(false);
            slot_leds_off();
            tray_motor_request(true);
            climate_relays_restore_after_ai();
            hardware_operation_finish_restore();
        } else {
            s_ai_scan_active = false;
        }
        if (state_lock_held) {
            xSemaphoreGive(s_state_mutex);
            state_lock_held = false;
        }
        scan_phase_set(SCAN_PHASE_IDLE);
    }

    bool ready(void) const { return armed && !s_scan_deadline_expired; }
    bool timed_out(void) const { return s_scan_deadline_expired; }
    bool storage_failed(void) const { return state_storage_failed; }
    const EggRuntimeState *baseline_state(void) const { return &baseline; }
    void mark_state_committed(void)
    {
        state_committed = true;
        s_scan_recovery_incomplete = false;
        if (state_transaction_started) {
            nvs_scan_transaction_commit_complete();
            state_transaction_started = false;
        }
    }
};

struct InferenceResetGuard {
    InferenceResetGuard(void) { ai_inference_guard_set(true); }
    ~InferenceResetGuard(void) { ai_inference_guard_set(false); }
};

struct InferencePowerGuard {
    InferencePowerGuard(void)
    {
        p4_outputs_force_off_for_ai();
        s3_ai_power_save_set(true);
        ESP_LOGI(TAG, "AI power-save ON: P4 outputs + main bulb OFF, S3 humidifier OFF, camera unchanged");
    }
    ~InferencePowerGuard(void)
    {
        s3_ai_power_save_set(false);
        p4_outputs_restore_after_ai();
        ESP_LOGI(TAG, "AI power-save OFF: P4 outputs + main bulb restored, S3 humidifier auto restored, camera unchanged");
    }
};

// Detection struct
typedef struct { float x, y, w, h, conf; int cls; } Detection;

extern const uint8_t model_start[] asm("_binary_eggcounter_cls_int8_tflite_start");
extern const uint8_t model_end[]   asm("_binary_eggcounter_cls_int8_tflite_end");

// LCD 20x4 via PCF8574 I2C
#define LCD_I2C_ADDR     0x27
#define LCD_COLS         20
#define LCD_ROWS         4
#define LCD_I2C_MUTEX_TIMEOUT_MS 500

// RTC DS3231 on I2C bus
#define RTC_I2C_ADDR     0x68
static i2c_master_dev_handle_t s_rtc_dev = NULL;
static bool s_rtc_connected = false;
static i2c_master_dev_handle_t s_sht3x_dev = NULL;
static uint8_t s_sht3x_addr = SHT3X_I2C_ADDR_PRIMARY;

#define LCD_RS           0
#define LCD_RW           1
#define LCD_EN           2
#define LCD_BL           3
#define LCD_D4           4
#define LCD_D5           5
#define LCD_D6           6
#define LCD_D7           7

#define LCD_CMD_CLEAR    0x01
#define LCD_CMD_HOME     0x02
#define LCD_CMD_ENTRY    0x04
#define LCD_CMD_DISPLAY  0x08
#define LCD_CMD_CURSOR   0x10
#define LCD_CMD_FUNCTION 0x20
#define LCD_CMD_CGRAM    0x40
#define LCD_CMD_DDRAM    0x80

#define LCD_FLAG_DISPLAY_ON  0x04
#define LCD_FLAG_CURSOR_ON   0x02
#define LCD_FLAG_BLINK_ON    0x01
#define LCD_FLAG_8BIT_MODE   0x10
#define LCD_FLAG_2LINE       0x08
#define LCD_FLAG_5x8_DOTS    0x00

typedef struct {
    i2c_master_dev_handle_t dev;
    uint8_t backlight;
} lcd_t;

static i2c_master_bus_handle_t s_i2c_bus = NULL;
static lcd_t s_lcd;
static SemaphoreHandle_t s_i2c_mutex = NULL;
static char s_lcd_line_cache[LCD_ROWS][LCD_COLS + 1] = {};
static bool s_lcd_line_cache_valid[LCD_ROWS] = {};
static volatile bool s_lcd_alert_page_active = false;

// Forward declarations for functions used before their definitions.
static esp_err_t capture_jpeg(uint8_t *buf, size_t cap, size_t *out_len,
                               ScanFailureReason *failure_reason);
static esp_err_t capture_jpeg_from_url(
    const char *url, const char *label,
    uint8_t *buf, size_t cap, size_t *out_len,
    ScanFailureReason *failure_reason);
static bool nvs_save_snapshots(void);
static esp_err_t wifi_connect(void);

static esp_err_t lcd_init(lcd_t *lcd, i2c_master_bus_handle_t bus, uint8_t addr);
static esp_err_t lcd_clear(lcd_t *lcd);
static esp_err_t lcd_set_cursor(lcd_t *lcd, uint8_t col, uint8_t row);
static esp_err_t lcd_write_string(lcd_t *lcd, const char *str);
static void lcd_clear_line(lcd_t *lcd, uint8_t row);
static void lcd_write_line_if_changed(lcd_t *lcd, uint8_t row, const char *str);
static void lcd_show_scan_failure(ScanFailureReason reason);

static void i2c_init(void);
static void rtc_init(void);
static void sht3x_init(void);
static void relay_gpio_init(void);
static void sensor_task(void *arg);
static void set_slot_led_mask(const uint8_t mask[SLOT_LED_REGISTER_COUNT]);

static void log_psram(const char *stage)
{
    ESP_LOGI(TAG, "[PSRAM] %s free=%u largest=%u",
             stage,
             (unsigned)heap_caps_get_free_size(MALLOC_CAP_SPIRAM),
             (unsigned)heap_caps_get_largest_free_block(MALLOC_CAP_SPIRAM));
}

static uint8_t sht3x_crc8(const uint8_t *data, size_t len)
{
    uint8_t crc = 0xFF;
    for (size_t i = 0; i < len; i++) {
        crc ^= data[i];
        for (int bit = 0; bit < 8; bit++) {
            crc = (crc & 0x80) ? (uint8_t)((crc << 1) ^ 0x31) : (uint8_t)(crc << 1);
        }
    }
    return crc;
}

static esp_err_t sht3x_add_device(uint8_t addr, i2c_master_dev_handle_t *out_dev)
{
    if (s_i2c_bus == NULL || out_dev == NULL) {
        return ESP_ERR_INVALID_STATE;
    }

    i2c_device_config_t dev_cfg = {};
    dev_cfg.dev_addr_length = I2C_ADDR_BIT_LEN_7;
    dev_cfg.device_address = addr;
    dev_cfg.scl_speed_hz = 50000;
    return i2c_master_bus_add_device(s_i2c_bus, &dev_cfg, out_dev);
}

static bool read_sht3x(float *temp, float *hum)
{
    if (temp == NULL || hum == NULL || s_sht3x_dev == NULL) {
        return false;
    }

    const uint8_t measure_cmd[2] = {0x24, 0x00}; // high repeatability, no clock stretch
    if (s_i2c_mutex != NULL &&
        xSemaphoreTake(s_i2c_mutex, pdMS_TO_TICKS(LCD_I2C_MUTEX_TIMEOUT_MS)) != pdTRUE) {
        return false;
    }
    esp_err_t ret = i2c_master_transmit(s_sht3x_dev, measure_cmd, sizeof(measure_cmd),
                                        pdMS_TO_TICKS(100));
    if (s_i2c_mutex != NULL) {
        xSemaphoreGive(s_i2c_mutex);
    }
    if (ret != ESP_OK) {
        return false;
    }

    vTaskDelay(pdMS_TO_TICKS(15));

    uint8_t data[6] = {};
    if (s_i2c_mutex != NULL &&
        xSemaphoreTake(s_i2c_mutex, pdMS_TO_TICKS(LCD_I2C_MUTEX_TIMEOUT_MS)) != pdTRUE) {
        return false;
    }
    ret = i2c_master_receive(s_sht3x_dev, data, sizeof(data), pdMS_TO_TICKS(100));
    if (s_i2c_mutex != NULL) {
        xSemaphoreGive(s_i2c_mutex);
    }
    if (ret != ESP_OK) {
        return false;
    }

    if (sht3x_crc8(&data[0], 2) != data[2] ||
        sht3x_crc8(&data[3], 2) != data[5]) {
        ESP_LOGD(TAG, "SHT3x CRC mismatch");
        return false;
    }

    uint16_t raw_temp = ((uint16_t)data[0] << 8) | data[1];
    uint16_t raw_hum = ((uint16_t)data[3] << 8) | data[4];
    *temp = -45.0f + (175.0f * (float)raw_temp / 65535.0f);
    *hum = 100.0f * (float)raw_hum / 65535.0f;

    return *hum >= 0.0f && *hum <= 100.0f && *temp >= -40.0f && *temp <= 125.0f;
}

static bool sht3x_try_address(uint8_t addr)
{
    i2c_master_dev_handle_t dev = NULL;
    esp_err_t ret = sht3x_add_device(addr, &dev);
    if (ret != ESP_OK || dev == NULL) {
        ESP_LOGW(TAG, "SHT3x add device failed at 0x%02X: %s", addr, esp_err_to_name(ret));
        return false;
    }

    s_sht3x_dev = dev;
    s_sht3x_addr = addr;

    float temp = 0.0f;
    float hum = 0.0f;
    if (read_sht3x(&temp, &hum)) {
        s_sht3x_connected = true;
        ESP_LOGI(TAG, "SHT3x responds at 0x%02X: T=%.1fC H=%.1f%%",
                 addr, temp, hum);
        return true;
    }

    ESP_LOGW(TAG, "SHT3x not responding at 0x%02X", addr);
    i2c_master_bus_rm_device(dev);
    s_sht3x_dev = NULL;
    return false;
}

static void sht3x_init(void)
{
    s_sht3x_connected = false;
    s_sht3x_bad_reads = 0;
    if (sht3x_try_address(SHT3X_I2C_ADDR_PRIMARY)) {
        return;
    }
    if (sht3x_try_address(SHT3X_I2C_ADDR_ALT)) {
        return;
    }
    ESP_LOGW(TAG, "SHT3x not found on I2C SDA=GPIO1 SCL=GPIO2");
}

static void send_sensor_to_s3(float temp, float hum)
{
    if (wifi_connect() != ESP_OK) {
        ESP_LOGW(TAG, "WiFi not connected, skipping sensor data send");
        return;
    }

    esp_http_client_config_t config;
    memset(&config, 0, sizeof(config));
    config.url = "http://192.168.4.1/sensordata";
    config.method = HTTP_METHOD_POST;
    config.timeout_ms = 5000;

    esp_http_client_handle_t client = esp_http_client_init(&config);
    if (client == NULL) {
        ESP_LOGW(TAG, "HTTP client init failed");
        return;
    }

    bool hum_valid = hum == hum;
    char post_data[128];
    int len = snprintf(post_data, sizeof(post_data),
                       "{\"temp\":%.1f,\"hum\":%.1f,\"humValid\":%s,"
                       "\"mainBulb\":%s}",
                       temp, hum_valid ? hum : 0.0f,
                       hum_valid ? "true" : "false",
                       s_bulb_relay_on ? "true" : "false");
    esp_http_client_set_post_field(client, post_data, len);
    esp_http_client_set_header(client, "Content-Type", "application/json");

    esp_err_t err = esp_http_client_perform(client);
    if (err == ESP_OK) {
        int status = esp_http_client_get_status_code(client);
        ESP_LOGI(TAG, "Sensor data sent to S3: T=%.1fC H=%.1f%% bulb=%s HTTP=%d",
                 temp, hum_valid ? hum : 0.0f,
                 s_bulb_relay_on ? "ON" : "OFF", status);
    } else {
        ESP_LOGW(TAG, "Failed to send sensor data to S3: %s", esp_err_to_name(err));
    }
    esp_http_client_cleanup(client);
}

// ---- Sub-incubator climate, fetched from the S3 for the LCD (row 3). ----
// The sub relay node POSTs to the S3 (/subsensordata); we GET the S3 (/sensor)
// and read subTemp/subHum back so the P4 LCD can display it. This is a read-only
// poll and does not affect the mobile app's own /sensor reads.
static float   s_sub_temp = 0.0f;
static float   s_sub_hum = 0.0f;
static bool    s_sub_valid = false;
static int64_t s_sub_updated_us = 0;
static bool    s_app_connected = false;  // is the mobile app talking to the S3?
static char    s_sub_resp_buf[1536];

static void fetch_sub_sensor_from_s3(void)
{
    if (wifi_connect() != ESP_OK) {
        return;
    }

    esp_http_client_config_t config;
    memset(&config, 0, sizeof(config));
    config.url = "http://192.168.4.1/sensor";
    config.method = HTTP_METHOD_GET;
    config.timeout_ms = 4000;

    esp_http_client_handle_t client = esp_http_client_init(&config);
    if (client == NULL) {
        return;
    }

    int total = 0;
    if (esp_http_client_open(client, 0) == ESP_OK) {
        esp_http_client_fetch_headers(client);
        while (total < (int)sizeof(s_sub_resp_buf) - 1) {
            int r = esp_http_client_read(client, s_sub_resp_buf + total,
                                         sizeof(s_sub_resp_buf) - 1 - total);
            if (r <= 0) break;
            total += r;
        }
        s_sub_resp_buf[total] = '\0';
    }
    int status = esp_http_client_get_status_code(client);
    esp_http_client_close(client);
    esp_http_client_cleanup(client);

    if (status != 200 || total <= 0) {
        return;
    }

    cJSON *root = cJSON_Parse(s_sub_resp_buf);
    if (root == NULL) {
        return;
    }
    cJSON *t = cJSON_GetObjectItem(root, "subTemp");
    cJSON *h = cJSON_GetObjectItem(root, "subHum");
    cJSON *c = cJSON_GetObjectItem(root, "subConnected");
    cJSON *app = cJSON_GetObjectItem(root, "appConnected");
    if (cJSON_IsTrue(c) && cJSON_IsNumber(t) && cJSON_IsNumber(h)) {
        s_sub_temp = (float)t->valuedouble;
        s_sub_hum  = (float)h->valuedouble;
        s_sub_valid = true;
        s_sub_updated_us = esp_timer_get_time();
    } else {
        s_sub_valid = false;
    }
    s_app_connected = cJSON_IsTrue(app);
    cJSON_Delete(root);
}

static void sub_sensor_fetch_task(void *arg)
{
    (void)arg;
    while (true) {
        if (!s_ai_scan_active && !s3_camera_focus_active()) {
            fetch_sub_sensor_from_s3();
        }
        // Realtime LCD when the app is away (no contention on the S3's
        // single-request server); modest when the app is connected so both
        // the app and the P4 get data without queueing.
        vTaskDelay(pdMS_TO_TICKS(s_app_connected ? 6000 : 2000));
    }
}

// --- Door-open removal/transfer LED guidance ---------------------------------
// On door open, the P4 tells the dedicated LED controller (192.168.4.60) which
// infertile/abnormal eggs should stay steadily lit for removal and which
// day-19+ eggs should blink for transfer. Door close sends "off" so the 12V
// LEDs/ICs are never left driven.
#define LED_CONTROLLER_SET_BASE     "http://192.168.4.60/led_test"
#define LED_CONTROLLER_STOP_URL     "http://192.168.4.60/candling_stop"
#define LED_CONTROLLER_GUIDANCE_BASE "http://192.168.4.60/guidance"
#define LED_CONTROLLER_GUIDANCE_STOP "http://192.168.4.60/guidance_stop"
#define LED_GUIDANCE_LEASE_MS 90000
#define LED_GUIDANCE_RENEW_MS 30000
#define LED_CONTROLLER_HTTP_TIMEOUT_MS 2500

typedef struct {
    char data[1024];
    size_t len;
    bool overflow;
} LedControllerResponse;

static esp_err_t led_controller_response_event(esp_http_client_event_t *evt)
{
    LedControllerResponse *response =
        (LedControllerResponse *)evt->user_data;
    if (evt->event_id != HTTP_EVENT_ON_DATA || evt->data_len <= 0) {
        return ESP_OK;
    }
    if (response == NULL ||
        response->len + (size_t)evt->data_len >= sizeof(response->data)) {
        if (response != NULL) response->overflow = true;
        return ESP_FAIL;
    }
    memcpy(response->data + response->len, evt->data, evt->data_len);
    response->len += (size_t)evt->data_len;
    response->data[response->len] = '\0';
    return ESP_OK;
}

static bool led_controller_get(const char *url,
                               LedControllerResponse *response)
{
    if (url == NULL || response == NULL || wifi_connect() != ESP_OK) {
        return false;
    }
    memset(response, 0, sizeof(*response));

    esp_http_client_config_t config = {};
    config.url = url;
    config.method = HTTP_METHOD_GET;
    config.timeout_ms = LED_CONTROLLER_HTTP_TIMEOUT_MS;
    config.event_handler = led_controller_response_event;
    config.user_data = response;

    esp_http_client_handle_t client = esp_http_client_init(&config);
    if (client == NULL) {
        return false;
    }
    esp_err_t err = esp_http_client_perform(client);
    int status = esp_http_client_get_status_code(client);
    esp_http_client_cleanup(client);

    if (err != ESP_OK || status < 200 || status >= 300 ||
        response->overflow) {
        ESP_LOGW(TAG, "LED controller request failed: %s HTTP=%d overflow=%s",
                 esp_err_to_name(err), status,
                 response->overflow ? "yes" : "no");
        return false;
    }
    return true;
}

static bool led_controller_all_off(void)
{
    LedControllerResponse response = {};
    bool ok = led_controller_get(LED_CONTROLLER_STOP_URL, &response);
    if (!ok) {
        ESP_LOGW(TAG,
                 "LED controller OFF was not acknowledged; local 120 s LED lease remains active");
    }
    return ok;
}

static int format_slot_mask_1based(const bool mask[NUM_CELLS],
                                   char *out, size_t out_size)
{
    if (mask == NULL || out == NULL || out_size == 0) {
        return 0;
    }
    out[0] = '\0';
    size_t pos = 0;
    int count = 0;
    for (int cell = 0; cell < NUM_CELLS; cell++) {
        if (!mask[cell]) {
            continue;
        }
        int written = snprintf(out + pos, out_size - pos, "%s%d",
                               count == 0 ? "" : ",", cell + 1);
        if (written < 0 || (size_t)written >= out_size - pos) {
            out[0] = '\0';
            return 0;
        }
        pos += (size_t)written;
        count++;
    }
    return count;
}

static bool led_controller_activate_exact(const bool expected[NUM_CELLS],
                                          char *slot_list,
                                          size_t slot_list_size,
                                          int *active_count)
{
    int expected_count =
        format_slot_mask_1based(expected, slot_list, slot_list_size);
    if (active_count != NULL) *active_count = 0;
    if (expected_count <= 0) {
        ESP_LOGE(TAG, "Refusing empty intake LED request");
        led_controller_all_off();
        return false;
    }

    char url[320];
    int url_len = snprintf(url, sizeof(url), "%s?mode=set&led=%s",
                           LED_CONTROLLER_SET_BASE, slot_list);
    if (url_len < 0 || url_len >= (int)sizeof(url)) {
        ESP_LOGE(TAG, "Intake LED URL is too long");
        led_controller_all_off();
        return false;
    }

    LedControllerResponse response = {};
    if (!led_controller_get(url, &response)) {
        led_controller_all_off();
        return false;
    }

    cJSON *root = cJSON_Parse(response.data);
    cJSON *count_item = root == NULL ? NULL :
        cJSON_GetObjectItemCaseSensitive(root, "active_led_count");
    cJSON *leds = root == NULL ? NULL :
        cJSON_GetObjectItemCaseSensitive(root, "active_leds");
    bool actual[NUM_CELLS] = {};
    bool valid = cJSON_IsNumber(count_item) && cJSON_IsArray(leds) &&
                 count_item->valueint == expected_count &&
                 cJSON_GetArraySize(leds) == expected_count;

    if (valid) {
        cJSON *item = NULL;
        cJSON_ArrayForEach(item, leds) {
            int led = cJSON_IsNumber(item) ? item->valueint : -1;
            if (led < 1 || led > NUM_CELLS || actual[led - 1]) {
                valid = false;
                break;
            }
            actual[led - 1] = true;
        }
    }
    if (valid) {
        for (int cell = 0; cell < NUM_CELLS; cell++) {
            if (actual[cell] != expected[cell]) {
                valid = false;
                break;
            }
        }
    }
    cJSON_Delete(root);

    if (!valid) {
        ESP_LOGE(TAG,
                 "LED controller exact-mask verification failed for requested slots [%s]",
                 slot_list);
        led_controller_all_off();
        return false;
    }

    if (active_count != NULL) *active_count = expected_count;
    ESP_LOGI(TAG, "Verified %d intake LED(s): [%s]",
             expected_count, slot_list);
    return true;
}

struct ExternalCandlingLedGuard {
    bool active;
    bool cleanup_required;

    ExternalCandlingLedGuard(void)
        : active(false), cleanup_required(false) {}
    ~ExternalCandlingLedGuard(void) { off(); }

    bool activate(const bool mask[NUM_CELLS], char *slot_list,
                  size_t slot_list_size, int *active_count)
    {
        // The set request may reach the controller even if its HTTP response
        // is lost, so cleanup is required from the moment the request begins.
        cleanup_required = true;
        active = led_controller_activate_exact(
            mask, slot_list, slot_list_size, active_count);
        return active;
    }

    void off(void)
    {
        if (!cleanup_required) {
            return;
        }
        if (led_controller_all_off()) {
            cleanup_required = false;
        }
        active = false;
    }
};

static int build_guidance_lists(char *remove_list, size_t remove_size,
                                char *transfer_list, size_t transfer_size,
                                int *transfer_count)
{
    refresh_cell_day_status(time(NULL));
    bool remove_mask[NUM_CELLS] = {};
    bool transfer_mask[NUM_CELLS] = {};
    for (int cell = 0; cell < NUM_CELLS; cell++) {
        remove_mask[cell] = cell_remove_alert(cell);
        transfer_mask[cell] = !remove_mask[cell] && cell_transfer_ready(cell);
    }
    int remove_count = format_slot_mask_1based(
        remove_mask, remove_list, remove_size);
    int transfers = format_slot_mask_1based(
        transfer_mask, transfer_list, transfer_size);
    if (transfer_count != NULL) *transfer_count = transfers;
    return remove_count;
}

static bool led_controller_guidance_stop(void)
{
    LedControllerResponse response = {};
    bool ok = led_controller_get(LED_CONTROLLER_GUIDANCE_STOP, &response);
    if (!ok) {
        ESP_LOGW(TAG,
                 "LED guidance stop not acknowledged; controller lease will expire locally");
    }
    return ok;
}

static bool led_controller_send_guidance(void)
{
    char remove_list[192] = {};
    char transfer_list[192] = {};
    int transfer_count = 0;
    int remove_count = build_guidance_lists(
        remove_list, sizeof(remove_list), transfer_list,
        sizeof(transfer_list), &transfer_count);
    if (remove_count + transfer_count == 0) {
        return led_controller_guidance_stop();
    }

    char url[512];
    int url_len = snprintf(
        url, sizeof(url), "%s?remove=%s&transfer=%s&lease_ms=%d",
        LED_CONTROLLER_GUIDANCE_BASE, remove_list, transfer_list,
        LED_GUIDANCE_LEASE_MS);
    if (url_len < 0 || url_len >= (int)sizeof(url)) {
        ESP_LOGE(TAG, "LED guidance URL is too long");
        led_controller_guidance_stop();
        return false;
    }

    LedControllerResponse response = {};
    if (!led_controller_get(url, &response)) return false;
    cJSON *root = cJSON_Parse(response.data);
    cJSON *active = root == NULL ? NULL :
        cJSON_GetObjectItemCaseSensitive(root, "guidance_active");
    cJSON *actual_remove = root == NULL ? NULL :
        cJSON_GetObjectItemCaseSensitive(root, "removal_count");
    cJSON *actual_transfer = root == NULL ? NULL :
        cJSON_GetObjectItemCaseSensitive(root, "transfer_count");
    cJSON *removal_leds = root == NULL ? NULL :
        cJSON_GetObjectItemCaseSensitive(root, "removal_leds");
    cJSON *transfer_leds = root == NULL ? NULL :
        cJSON_GetObjectItemCaseSensitive(root, "transfer_leds");
    bool verified = cJSON_IsTrue(active) && cJSON_IsNumber(actual_remove) &&
                    cJSON_IsNumber(actual_transfer) &&
                    actual_remove->valueint == remove_count &&
                    actual_transfer->valueint == transfer_count &&
                    cJSON_IsArray(removal_leds) &&
                    cJSON_IsArray(transfer_leds) &&
                    cJSON_GetArraySize(removal_leds) == remove_count &&
                    cJSON_GetArraySize(transfer_leds) == transfer_count;
    bool actual_remove_mask[NUM_CELLS] = {};
    bool actual_transfer_mask[NUM_CELLS] = {};
    if (verified) {
        cJSON *item = NULL;
        cJSON_ArrayForEach(item, removal_leds) {
            int slot = cJSON_IsNumber(item) ? item->valueint : -1;
            if (slot < 1 || slot > NUM_CELLS ||
                actual_remove_mask[slot - 1]) {
                verified = false;
                break;
            }
            actual_remove_mask[slot - 1] = true;
        }
        cJSON_ArrayForEach(item, transfer_leds) {
            int slot = cJSON_IsNumber(item) ? item->valueint : -1;
            if (slot < 1 || slot > NUM_CELLS ||
                actual_transfer_mask[slot - 1]) {
                verified = false;
                break;
            }
            actual_transfer_mask[slot - 1] = true;
        }
    }
    if (verified) {
        for (int cell = 0; cell < NUM_CELLS; cell++) {
            bool expected_remove = cell_remove_alert(cell);
            bool expected_transfer = !expected_remove && cell_transfer_ready(cell);
            if (actual_remove_mask[cell] != expected_remove ||
                actual_transfer_mask[cell] != expected_transfer) {
                verified = false;
                break;
            }
        }
    }
    cJSON_Delete(root);
    if (!verified) {
        ESP_LOGE(TAG,
                 "LED guidance verification failed remove=%d transfer=%d",
                 remove_count, transfer_count);
        led_controller_guidance_stop();
        return false;
    }
    ESP_LOGI(TAG,
             "LED guidance lease renewed: remove=[%s] transfer=[%s]",
             remove_list, transfer_list);
    return true;
}

static void s3_control_get(const char *path, const char *label)
{
    if (path == NULL || label == NULL) {
        return;
    }

    if (wifi_connect() != ESP_OK) {
        ESP_LOGW(TAG, "WiFi not connected, cannot update S3 %s", label);
        return;
    }

    char url[128];
    snprintf(url, sizeof(url), "%s%s", S3_BASE_URL, path);

    esp_http_client_config_t config;
    memset(&config, 0, sizeof(config));
    config.url = url;
    config.method = HTTP_METHOD_GET;
    config.timeout_ms = 2500;

    esp_http_client_handle_t client = esp_http_client_init(&config);
    if (client == NULL) {
        ESP_LOGW(TAG, "HTTP client init failed for S3 %s", label);
        return;
    }

    esp_err_t err = esp_http_client_perform(client);
    if (err == ESP_OK) {
        int status = esp_http_client_get_status_code(client);
        if (status >= 200 && status < 300) {
            ESP_LOGI(TAG, "S3 %s updated, HTTP=%d", label, status);
        } else {
            ESP_LOGW(TAG, "S3 %s returned HTTP=%d", label, status);
        }
    } else {
        ESP_LOGW(TAG, "S3 %s update failed: %s", label, esp_err_to_name(err));
    }
    esp_http_client_cleanup(client);
}

static void s3_ai_power_save_set(bool active)
{
    s3_control_get(active ? "/ai_power?state=on" : "/ai_power?state=off",
                   active ? "AI power-save ON" : "AI power-save OFF");
}

static void s3_door_state_set(bool closed)
{
    s3_control_get(closed ? "/door?state=closed" : "/door?state=open",
                   closed ? "door CLOSED" : "door OPEN");
}

// Candling LED timer callback
static esp_err_t lcd_write_nibble(lcd_t *lcd, uint8_t nibble, uint8_t rs)
{
    if (lcd == NULL || lcd->dev == NULL || s_i2c_mutex == NULL) {
        return ESP_ERR_INVALID_STATE;
    }

    if (xSemaphoreTake(s_i2c_mutex, pdMS_TO_TICKS(LCD_I2C_MUTEX_TIMEOUT_MS)) != pdTRUE) {
        ESP_LOGW(TAG, "I2C mutex timeout (LCD write)");
        return ESP_ERR_TIMEOUT;
    }

    uint8_t data = (nibble & 0x0F) << 4;
    data |= (rs ? 1 : 0) << LCD_RS;
    data |= (lcd->backlight ? 1 : 0) << LCD_BL;

    data |= (1 << LCD_EN);
    esp_err_t ret = i2c_master_transmit(lcd->dev, &data, 1, pdMS_TO_TICKS(10));
    if (ret == ESP_OK) {
        esp_rom_delay_us(50);
        data &= ~(1 << LCD_EN);
        ret = i2c_master_transmit(lcd->dev, &data, 1, pdMS_TO_TICKS(10));
        esp_rom_delay_us(50);
    }

    xSemaphoreGive(s_i2c_mutex);
    return ret;
}

static esp_err_t lcd_write_byte(lcd_t *lcd, uint8_t byte, uint8_t rs)
{
    esp_err_t ret = lcd_write_nibble(lcd, byte >> 4, rs);
    if (ret != ESP_OK) return ret;
    return lcd_write_nibble(lcd, byte & 0x0F, rs);
}

static esp_err_t lcd_command(lcd_t *lcd, uint8_t cmd)
{
    return lcd_write_byte(lcd, cmd, 0);
}

static esp_err_t lcd_data(lcd_t *lcd, uint8_t data)
{
    return lcd_write_byte(lcd, data, 1);
}

static esp_err_t lcd_init(lcd_t *lcd, i2c_master_bus_handle_t bus, uint8_t addr)
{
    if (lcd == NULL || bus == NULL) return ESP_ERR_INVALID_ARG;

    i2c_device_config_t dev_cfg = {};
    dev_cfg.dev_addr_length = I2C_ADDR_BIT_LEN_7;
    dev_cfg.device_address = addr;
    dev_cfg.scl_speed_hz = 50000;

    esp_err_t ret = i2c_master_bus_add_device(bus, &dev_cfg, &lcd->dev);
    if (ret != ESP_OK) {
        ESP_LOGE(TAG, "LCD add device failed at 0x%02X: %s", addr, esp_err_to_name(ret));
        return ret;
    }

    uint8_t test_data = 0x00;
    ret = i2c_master_transmit(lcd->dev, &test_data, 1, pdMS_TO_TICKS(100));
    if (ret != ESP_OK) {
        ESP_LOGE(TAG, "LCD not responding at 0x%02X: %s", addr, esp_err_to_name(ret));
        return ret;
    }

    lcd->backlight = 1;
    vTaskDelay(pdMS_TO_TICKS(100));

    if (lcd_write_nibble(lcd, 0x03, 0) != ESP_OK) return ESP_FAIL;
    vTaskDelay(pdMS_TO_TICKS(5));
    if (lcd_write_nibble(lcd, 0x03, 0) != ESP_OK) return ESP_FAIL;
    vTaskDelay(pdMS_TO_TICKS(1));
    if (lcd_write_nibble(lcd, 0x03, 0) != ESP_OK) return ESP_FAIL;
    vTaskDelay(pdMS_TO_TICKS(1));
    if (lcd_write_nibble(lcd, 0x02, 0) != ESP_OK) return ESP_FAIL;

    if (lcd_command(lcd, LCD_CMD_FUNCTION | LCD_FLAG_2LINE | LCD_FLAG_5x8_DOTS) != ESP_OK) return ESP_FAIL;
    if (lcd_command(lcd, LCD_CMD_DISPLAY | LCD_FLAG_DISPLAY_ON) != ESP_OK) return ESP_FAIL;
    if (lcd_clear(lcd) != ESP_OK) return ESP_FAIL;
    if (lcd_command(lcd, LCD_CMD_ENTRY | 0x02) != ESP_OK) return ESP_FAIL;

    return ESP_OK;
}

static esp_err_t lcd_clear(lcd_t *lcd)
{
    esp_err_t ret = lcd_command(lcd, LCD_CMD_CLEAR);
    vTaskDelay(pdMS_TO_TICKS(2));
    memset(s_lcd_line_cache_valid, 0, sizeof(s_lcd_line_cache_valid));
    return ret;
}

static esp_err_t lcd_set_cursor(lcd_t *lcd, uint8_t col, uint8_t row)
{
    static const uint8_t row_offsets[] = {0x00, 0x40, 0x14, 0x54};
    if (row >= LCD_ROWS || col >= LCD_COLS) return ESP_ERR_INVALID_ARG;
    return lcd_command(lcd, LCD_CMD_DDRAM | (col + row_offsets[row]));
}

static esp_err_t lcd_write_string(lcd_t *lcd, const char *str)
{
    if (str == NULL) return ESP_ERR_INVALID_ARG;
    while (*str) {
        esp_err_t ret = lcd_data(lcd, (uint8_t)*str++);
        if (ret != ESP_OK) return ret;
    }
    return ESP_OK;
}

static void lcd_clear_line(lcd_t *lcd, uint8_t row)
{
    if (lcd == NULL || lcd->dev == NULL) return;
    if (row < LCD_ROWS) {
        s_lcd_line_cache_valid[row] = false;
    }
    lcd_set_cursor(lcd, 0, row);
    lcd_write_string(lcd, "                    ");
    lcd_set_cursor(lcd, 0, row);
}

static void lcd_write_line_if_changed(lcd_t *lcd, uint8_t row, const char *str)
{
    if (lcd == NULL || lcd->dev == NULL || row >= LCD_ROWS || str == NULL) return;

    char padded[LCD_COLS + 1];
    size_t len = strlen(str);
    if (len > LCD_COLS) len = LCD_COLS;
    memcpy(padded, str, len);
    memset(padded + len, ' ', LCD_COLS - len);
    padded[LCD_COLS] = '\0';

    if (s_lcd_line_cache_valid[row] &&
        memcmp(s_lcd_line_cache[row], padded, sizeof(padded)) == 0) {
        return;
    }

    lcd_set_cursor(lcd, 0, row);
    lcd_write_string(lcd, padded);
    memcpy(s_lcd_line_cache[row], padded, sizeof(padded));
    s_lcd_line_cache_valid[row] = true;
}

static void lcd_show_scan_failure(ScanFailureReason reason)
{
    if (s_lcd.dev == NULL) return;
    if (reason == SCAN_FAIL_S3_OFFLINE) {
        lcd_write_line_if_changed(&s_lcd, 3, "WAIT S3 CAM");
        return;
    }
    lcd_write_line_if_changed(&s_lcd, 3, "SCAN ERROR");
    vTaskDelay(pdMS_TO_TICKS(700));
    lcd_write_line_if_changed(&s_lcd, 3, scan_failure_lcd_text(reason));
}

static void i2c_init(void)
{
    i2c_master_bus_config_t bus_cfg = {};
    bus_cfg.i2c_port = I2C_NUM_0;
    bus_cfg.sda_io_num = GPIO_NUM_1;
    bus_cfg.scl_io_num = GPIO_NUM_2;
    bus_cfg.clk_source = I2C_CLK_SRC_DEFAULT;
    bus_cfg.glitch_ignore_cnt = 7;
    bus_cfg.flags.enable_internal_pullup = true;

    ESP_ERROR_CHECK(i2c_new_master_bus(&bus_cfg, &s_i2c_bus));
    ESP_LOGI(TAG, "I2C bus ready - SDA=GPIO1 SCL=GPIO2");

    s_i2c_mutex = xSemaphoreCreateMutex();
    if (s_i2c_mutex == NULL) {
        ESP_LOGE(TAG, "Failed to create I2C mutex");
        return;
    }

    i2c_device_config_t rtc_cfg = {};
    rtc_cfg.dev_addr_length = I2C_ADDR_BIT_LEN_7;
    rtc_cfg.device_address = RTC_I2C_ADDR;
    rtc_cfg.scl_speed_hz = 50000;
    ESP_ERROR_CHECK(i2c_master_bus_add_device(s_i2c_bus, &rtc_cfg, &s_rtc_dev));

    uint8_t rtc_reg = 0;
    esp_err_t rtc_test = i2c_master_transmit(s_rtc_dev, &rtc_reg, 1, pdMS_TO_TICKS(100));
    s_rtc_connected = (rtc_test == ESP_OK);
    if (s_rtc_connected) {
        ESP_LOGI(TAG, "RTC DS3231 responds at 0x%02X", RTC_I2C_ADDR);
    } else {
        ESP_LOGW(TAG, "RTC DS3231 not responding: %s", esp_err_to_name(rtc_test));
    }
}

static uint8_t bcd_to_bin(uint8_t bcd)
{
    return ((bcd >> 4) * 10) + (bcd & 0x0F);
}

static uint8_t bin_to_bcd(uint8_t value)
{
    return (uint8_t)(((value / 10) << 4) | (value % 10));
}

static bool rtc_read_time(struct tm *timeinfo)
{
    if (timeinfo == NULL || !s_rtc_connected || s_rtc_dev == NULL) return false;

    uint8_t reg = 0x00;
    esp_err_t ret = i2c_master_transmit(s_rtc_dev, &reg, 1, pdMS_TO_TICKS(100));
    if (ret != ESP_OK) return false;

    uint8_t data[7];
    ret = i2c_master_receive(s_rtc_dev, data, sizeof(data), pdMS_TO_TICKS(100));
    if (ret != ESP_OK) return false;

    memset(timeinfo, 0, sizeof(*timeinfo));
    timeinfo->tm_sec = bcd_to_bin(data[0] & 0x7F);
    timeinfo->tm_min = bcd_to_bin(data[1]);

    uint8_t hours = data[2];
    if (hours & 0x40) {
        timeinfo->tm_hour = bcd_to_bin(hours & 0x1F);
        if (hours & 0x20) timeinfo->tm_hour += 12;
    } else {
        timeinfo->tm_hour = bcd_to_bin(hours & 0x3F);
    }

    timeinfo->tm_mday = bcd_to_bin(data[4]);
    timeinfo->tm_mon = bcd_to_bin(data[5] & 0x1F) - 1;
    timeinfo->tm_year = 100 + bcd_to_bin(data[6]);
    timeinfo->tm_wday = data[3] - 1;
    timeinfo->tm_isdst = 0;
    return true;
}

static esp_err_t rtc_write_time(const struct tm *timeinfo)
{
    if (timeinfo == NULL || !s_rtc_connected || s_rtc_dev == NULL) {
        return ESP_ERR_INVALID_STATE;
    }

    uint8_t day_of_week = (timeinfo->tm_wday == 0) ? 1 : (uint8_t)(timeinfo->tm_wday + 1);
    uint8_t data[8] = {
        0x00,
        bin_to_bcd((uint8_t)timeinfo->tm_sec),
        bin_to_bcd((uint8_t)timeinfo->tm_min),
        bin_to_bcd((uint8_t)timeinfo->tm_hour),
        bin_to_bcd(day_of_week),
        bin_to_bcd((uint8_t)timeinfo->tm_mday),
        bin_to_bcd((uint8_t)(timeinfo->tm_mon + 1)),
        bin_to_bcd((uint8_t)((timeinfo->tm_year + 1900) % 100)),
    };

    if (s_i2c_mutex != NULL &&
        xSemaphoreTake(s_i2c_mutex, pdMS_TO_TICKS(LCD_I2C_MUTEX_TIMEOUT_MS)) != pdTRUE) {
        return ESP_ERR_TIMEOUT;
    }
    esp_err_t ret = i2c_master_transmit(s_rtc_dev, data, sizeof(data), pdMS_TO_TICKS(100));
    if (s_i2c_mutex != NULL) {
        xSemaphoreGive(s_i2c_mutex);
    }
    return ret;
}

static void rtc_init(void)
{
    if (!s_rtc_connected) {
        ESP_LOGW(TAG, "RTC not connected, using uptime clock until RTC is available");
        return;
    }

    struct tm timeinfo;
    if (!rtc_read_time(&timeinfo)) {
        ESP_LOGW(TAG, "Failed to read RTC time");
        return;
    }

    time_t t = mktime(&timeinfo);
    if (!epoch_is_valid(t)) {
        set_time_trust(false, NULL);
        ESP_LOGW(TAG,
                 "RTC time is not trusted: %04d-%02d-%02d %02d:%02d:%02d; waiting for phone sync",
                 timeinfo.tm_year + 1900, timeinfo.tm_mon + 1, timeinfo.tm_mday,
                 timeinfo.tm_hour, timeinfo.tm_min, timeinfo.tm_sec);
        return;
    }

    struct timeval tv = {
        .tv_sec = t,
        .tv_usec = 0,
    };
    settimeofday(&tv, NULL);
    set_time_trust(true, "rtc");
    ESP_LOGI(TAG, "RTC time set: %04d-%02d-%02d %02d:%02d:%02d",
             timeinfo.tm_year + 1900, timeinfo.tm_mon + 1, timeinfo.tm_mday,
             timeinfo.tm_hour, timeinfo.tm_min, timeinfo.tm_sec);
}

static void door_switch_init(void)
{
#if DOOR_SWITCH_ENABLED
    gpio_config_t door_cfg = {};
    door_cfg.mode = GPIO_MODE_INPUT;
    door_cfg.pin_bit_mask = (1ULL << DOOR_SWITCH_GPIO);
    door_cfg.pull_up_en = GPIO_PULLUP_ENABLE;
    door_cfg.pull_down_en = GPIO_PULLDOWN_DISABLE;
    door_cfg.intr_type = GPIO_INTR_DISABLE;
#if SOC_GPIO_SUPPORT_PIN_HYS_FILTER
    door_cfg.hys_ctrl_mode = GPIO_HYS_SOFT_ENABLE;
#endif
    ESP_ERROR_CHECK(gpio_config(&door_cfg));
    // Re-assert the pull mode after selecting the GPIO function. GPIO46 belongs
    // to the P4 SDIO IO domain, so do not rely on its reset/default pad state.
    ESP_ERROR_CHECK(gpio_set_pull_mode(DOOR_SWITCH_GPIO, GPIO_PULLUP_ONLY));
    ESP_LOGI(TAG,
             "Door magnetic switch ready on GPIO%d (closed=LOW, open=HIGH, initial=%s, close_confirm=%dms)",
             (int)DOOR_SWITCH_GPIO,
             gpio_get_level(DOOR_SWITCH_GPIO) == DOOR_CLOSED_LEVEL ? "LOW" : "HIGH",
             DOOR_CLOSE_DEBOUNCE_MS);
#else
    ESP_LOGW(TAG, "Door magnetic switch disabled for now; GPIO%d ignored",
             (int)DOOR_SWITCH_GPIO);
#endif
}

static bool door_switch_is_closed(void)
{
#if DOOR_SWITCH_ENABLED
    return gpio_get_level(DOOR_SWITCH_GPIO) == DOOR_CLOSED_LEVEL;
#else
    return true;
#endif
}

static bool door_switch_is_closed_for_tray(void)
{
#if DOOR_SWITCH_ENABLED
    bool raw_closed = door_switch_is_closed();
    int64_t now_us = esp_timer_get_time();

    // An OPEN sample always wins immediately. A CLOSED sample must remain
    // continuous long enough to reject a floating/disconnected GPIO46.
    if (!raw_closed) {
        s_tray_door_closed_confirmed = false;
        s_tray_door_close_started_us = 0;
        return false;
    }

    if (!s_tray_door_closed_confirmed) {
        if (s_tray_door_close_started_us == 0) {
            s_tray_door_close_started_us = now_us;
        }
        if ((now_us - s_tray_door_close_started_us) >=
            (int64_t)DOOR_CLOSE_DEBOUNCE_MS * 1000LL) {
            s_tray_door_closed_confirmed = true;
        }
    }
    return s_tray_door_closed_confirmed;
#else
    return true;
#endif
}

static void tray_motor_apply_requested_state(void)
{
    bool door_closed = door_switch_is_closed_for_tray();
    bool door_blocked = s_tray_motor_requested_on && !door_closed;

    gpio_set_level(RELAY_TRAY_GPIO,
                   (s_tray_motor_requested_on && door_closed) ? RELAY_ON : RELAY_OFF);

    if (door_blocked && !s_tray_motor_door_blocked) {
        ESP_LOGW(TAG, "Tray motor stopped: incubator door is open");
    } else if (!door_blocked && s_tray_motor_door_blocked && door_closed) {
        ESP_LOGI(TAG, "Door closed - tray motor safety block cleared");
    }
    s_tray_motor_door_blocked = door_blocked;
}

static void tray_motor_request(bool run)
{
    s_tray_motor_requested_on = run;
    tray_motor_apply_requested_state();
}

static bool tray_motor_stop_and_settle_for_capture(void)
{
    tray_motor_request(false);
    vTaskDelay(pdMS_TO_TICKS(TRAY_CAPTURE_SETTLE_MS));
    return door_switch_is_closed();
}

static void tray_motor_resume_with_power_stagger(const char *reason)
{
    const char *why = (reason != NULL) ? reason : "scan";
    climate_relays_force_off_for_ai();
    ESP_LOGI(TAG, "Tray resume power stagger: PTC/Fan OFF for %d ms (%s)",
             TRAY_RESUME_POWER_SAVE_MS, why);

    tray_motor_request(true);
    vTaskDelay(pdMS_TO_TICKS(TRAY_RESUME_POWER_SAVE_MS));

    climate_relays_holdoff_for_ms(CLIMATE_RESTORE_AFTER_TRAY_MS);
    ESP_LOGI(TAG, "Tray resumed after %s; PTC/Fan held OFF for another %d ms",
             why, CLIMATE_RESTORE_AFTER_TRAY_MS);
}

static void relay_gpio_init(void)
{
    // Preload the active-low bulb relay latch OFF before enabling the output.
    gpio_set_level(RELAY_BULB_GPIO, RELAY_OFF);

    gpio_config_t out_cfg = {};
    out_cfg.mode = GPIO_MODE_OUTPUT;
    out_cfg.pin_bit_mask =
        (1ULL << RELAY_FAN1_GPIO) |
        (1ULL << RELAY_PTC_GPIO) |
        (1ULL << RELAY_FAN2_GPIO) |
        (1ULL << RELAY_TRAY_GPIO) |
        (1ULL << RELAY_BULB_GPIO)
        ;
    ESP_ERROR_CHECK(gpio_config(&out_cfg));

    gpio_set_level(RELAY_FAN1_GPIO, RELAY_OFF);
    gpio_set_level(RELAY_PTC_GPIO, RELAY_OFF);
    gpio_set_level(RELAY_FAN2_GPIO, RELAY_OFF);
    gpio_set_level(RELAY_TRAY_GPIO, RELAY_OFF);
    gpio_set_level(RELAY_BULB_GPIO, RELAY_OFF);

    s_bulb_candling_hold = false;
    s_bulb_ai_hold = false;
    s_bulb_normal_capture_override = false;
    s_bulb_temperature_demand = false;
    s_bulb_door_open = false;
    s_bulb_door_light_expired = false;
    s_bulb_door_opened_us = 0;
    s_bulb_relay_on = false;
    bulb_relay_apply_state();
    tray_motor_request(true);

    slot_leds_off();
}

static void sensor_task(void *arg)
{
    (void)arg;

    while (true) {
        vTaskDelay(pdMS_TO_TICKS(SHT3X_READ_INTERVAL_MS));

        if (s_ai_scan_active) {
            continue;
        }

        float temp = 0.0f;
        float hum = 0.0f;
        bool sensor_ok = read_sht3x(&temp, &hum);
        if (!sensor_ok) {
            s_main_climate_valid = false;
            bulb_relay_set_temperature_unavailable();
            s_sht3x_good_reads = 0;
            if (s_sht3x_bad_reads < UINT8_MAX) {
                s_sht3x_bad_reads++;
            }
            if (s_sht3x_bad_reads == 1 ||
                (s_sht3x_bad_reads % SHT3X_BAD_READ_LOG_INTERVAL) == 0) {
                ESP_LOGW(TAG, "SHT3x bad read %u/%u",
                         (unsigned)s_sht3x_bad_reads,
                         (unsigned)SHT3X_FAILSAFE_BAD_READS);
            }

            if (s_sht3x_bad_reads >= SHT3X_FAILSAFE_BAD_READS) {
                bool entering_fault = !s_climate_sensor_fault;
                s_climate_sensor_fault = true;
                s_sht3x_connected = false;
                s_heater_on = false;
                s_cooler_on = false;
                climate_relays_force_off_for_ai();
                if (entering_fault) {
                    ESP_LOGE(TAG,
                             "SHT3x fail-safe ACTIVE after %u bad reads: PTC and all fans OFF",
                             (unsigned)s_sht3x_bad_reads);
                }
            }

            if (s_lcd.dev != NULL && !s_lcd_alert_page_active) {
                lcd_write_line_if_changed(
                    &s_lcd, 2,
                    s_climate_sensor_fault ? "TEMP SENSOR FAULT" : "MAIN: SENSOR RETRY");
            }
            continue;
        }

        s_sht3x_bad_reads = 0;
        if (s_climate_sensor_fault) {
            if (s_sht3x_good_reads < UINT8_MAX) {
                s_sht3x_good_reads++;
            }
            climate_relays_force_off_for_ai();

            if (s_lcd.dev != NULL && !s_lcd_alert_page_active) {
                char recovery[24];
                snprintf(recovery, sizeof(recovery), "SENSOR RECOVERY %u/%u",
                         (unsigned)s_sht3x_good_reads,
                         (unsigned)SHT3X_RECOVERY_GOOD_READS);
                lcd_write_line_if_changed(&s_lcd, 2, recovery);
            }

            ESP_LOGI(TAG, "SHT3x recovery read %u/%u: T=%.1fC H=%.1f%%",
                     (unsigned)s_sht3x_good_reads,
                     (unsigned)SHT3X_RECOVERY_GOOD_READS, temp, hum);
            if (s_sht3x_good_reads < SHT3X_RECOVERY_GOOD_READS) {
                send_sensor_to_s3(temp, hum);
                continue;
            }

            s_climate_sensor_fault = false;
            s_sht3x_good_reads = 0;
            ESP_LOGI(TAG,
                     "SHT3x fail-safe CLEARED after %u consecutive valid reads",
                     (unsigned)SHT3X_RECOVERY_GOOD_READS);
        } else {
            s_sht3x_good_reads = 0;
        }

        if (!s_sht3x_connected) {
            ESP_LOGI(TAG, "SHT3x connected at 0x%02X", s_sht3x_addr);
        }
        s_sht3x_connected = true;
        s_main_temp = temp;
        s_main_hum = hum;
        s_main_climate_valid = true;

        if (temp < TEMP_HEAT_ON) {
            s_heater_on = true;
        } else if (temp >= TEMP_HEAT_OFF) {
            s_heater_on = false;
        }

        if (temp >= TEMP_COOL_ON) {
            s_cooler_on = true;
        } else if (temp <= TEMP_COOL_OFF) {
            s_cooler_on = false;
        }

        bulb_relay_update_temperature(temp);
        climate_relays_apply_requested_state();

        if (s_lcd.dev != NULL && !s_lcd_alert_page_active) {
            char buf[32];
            snprintf(buf, sizeof(buf), "MAIN: T:%.1fC H:%.0f%%", temp, hum);
            lcd_write_line_if_changed(&s_lcd, 2, buf);
        }

        send_sensor_to_s3(temp, hum);
    }
}

static void candle_leds_off(TimerHandle_t x);
static void capture_hold_timeout_cb(TimerHandle_t x);
static void blink_timer_cb(TimerHandle_t x);
static bool schedule_candle_leds_off(uint32_t duration_sec);
static bool schedule_capture_hold_timeout(void);
static void slot_leds_off(void);

// HTTP server for P4 data/control endpoints.
static httpd_handle_t s_server = NULL;

// 56-slot LED helpers for the 74HC595 chain.
static void slot_led_mask_clear(uint8_t mask[SLOT_LED_REGISTER_COUNT])
{
    memset(mask, 0, SLOT_LED_REGISTER_COUNT);
}

static void slot_led_mask_set_cell(uint8_t mask[SLOT_LED_REGISTER_COUNT], int cell)
{
    if (cell < 0 || cell >= SLOT_LED_COUNT) {
        return;
    }
    mask[cell / 8] |= (uint8_t)(1u << (cell % 8));
}

static int slot_led_mask_count(const uint8_t mask[SLOT_LED_REGISTER_COUNT])
{
    int count = 0;
    for (int cell = 0; cell < SLOT_LED_COUNT; cell++) {
        if (mask[cell / 8] & (uint8_t)(1u << (cell % 8))) {
            count++;
        }
    }
    return count;
}

static void slot_led_mask_or(uint8_t out[SLOT_LED_REGISTER_COUNT],
                             const uint8_t a[SLOT_LED_REGISTER_COUNT],
                             const uint8_t b[SLOT_LED_REGISTER_COUNT])
{
    for (int i = 0; i < SLOT_LED_REGISTER_COUNT; i++) {
        out[i] = a[i] | b[i];
    }
}

static void slot_led_mask_without(uint8_t out[SLOT_LED_REGISTER_COUNT],
                                  const uint8_t a[SLOT_LED_REGISTER_COUNT],
                                  const uint8_t b[SLOT_LED_REGISTER_COUNT])
{
    for (int i = 0; i < SLOT_LED_REGISTER_COUNT; i++) {
        out[i] = a[i] & (uint8_t)~b[i];
    }
}

static void slot_led_format_cell_list(const uint8_t mask[SLOT_LED_REGISTER_COUNT],
                                      char *out, size_t out_sz)
{
    int pos = 0;
    bool first = true;
    if (out_sz == 0) return;
    out[0] = '\0';

    for (int cell = 0; cell < SLOT_LED_COUNT; cell++) {
        if ((mask[cell / 8] & (uint8_t)(1u << (cell % 8))) == 0) {
            continue;
        }
        pos += snprintf(out + pos, out_sz - pos,
                        "%s%d", first ? "" : ",", cell);
        first = false;
        if (pos >= (int)out_sz) {
            out[out_sz - 1] = '\0';
            return;
        }
    }
}

static void slot_led_shift_write(const uint8_t data[SLOT_LED_REGISTER_COUNT])
{
#if ENABLE_SLOT_LED_OUTPUTS
    const int inactive_data_level = SLOT_LED_ACTIVE_LOW ? 1 : 0;

    gpio_set_level(SLOT_LED_LATCH_GPIO, 0);
    for (int reg = SLOT_LED_REGISTER_COUNT - 1; reg >= 0; reg--) {
        uint8_t value = data[reg];
#if SLOT_LED_ACTIVE_LOW
        value = (uint8_t)~value;
#endif
        for (int bit = 7; bit >= 0; bit--) {
            gpio_set_level(SLOT_LED_CLOCK_GPIO, 0);
            gpio_set_level(SLOT_LED_DATA_GPIO, (value >> bit) & 0x01);
            esp_rom_delay_us(SLOT_LED_SHIFT_DELAY_US);
            gpio_set_level(SLOT_LED_CLOCK_GPIO, 1);
            esp_rom_delay_us(SLOT_LED_SHIFT_DELAY_US);
        }
    }
    gpio_set_level(SLOT_LED_CLOCK_GPIO, 0);
    gpio_set_level(SLOT_LED_LATCH_GPIO, 1);
    esp_rom_delay_us(SLOT_LED_SHIFT_DELAY_US);
    gpio_set_level(SLOT_LED_DATA_GPIO, inactive_data_level);
#else
    (void)data;
#endif
}

static void apply_slot_led_mask(const uint8_t mask[SLOT_LED_REGISTER_COUNT])
{
    slot_led_shift_write(mask);
}

static void set_slot_led_mask(const uint8_t mask[SLOT_LED_REGISTER_COUNT])
{
    if (mask == NULL) {
        slot_led_mask_clear(s_slot_led_mask);
    } else {
        memcpy(s_slot_led_mask, mask, SLOT_LED_REGISTER_COUNT);
    }
    apply_slot_led_mask(s_slot_led_mask);
}

static void pause_tray_for_candling(void)
{
    (void)tray_motor_stop_and_settle_for_capture();
    s_tray_paused_for_candling = true;
}

static void resume_tray_if_paused_for_candling(void)
{
    if (s_tray_paused_for_candling) {
        tray_motor_request(true);
        s_tray_paused_for_candling = false;
    }
}

static void pause_tray_for_app_capture(void)
{
    (void)tray_motor_stop_and_settle_for_capture();
    s_tray_paused_for_capture = true;
}

static void resume_tray_if_paused_for_app_capture(void)
{
    if (s_tray_paused_for_capture) {
        tray_motor_request(true);
        s_tray_paused_for_capture = false;
    }
}

static int start_candling_slot_leds(void)
{
#if !ENABLE_SLOT_LED_OUTPUTS
    refresh_cell_day_status(time(NULL));
    ESP_LOGI(TAG, "P4 slot LED output disabled; external LED controller owns candling LEDs");
    return 0;
#else
    slot_leds_off();
    refresh_cell_day_status(time(NULL));

    uint8_t solid_mask[SLOT_LED_REGISTER_COUNT] = {};
    uint8_t blink_mask[SLOT_LED_REGISTER_COUNT] = {};
    for (int cell = 0; cell < SLOT_LED_COUNT; cell++) {
        if (s_infertile_slots[cell]) {
            slot_led_mask_set_cell(blink_mask, cell);
        } else if (SLOT_LED_CANDLING_SHOW_OCCUPIED_SOLID && s_cell_has_egg[cell]) {
            slot_led_mask_set_cell(solid_mask, cell);
        }
    }

    set_slot_led_mask(solid_mask);

    int blink_count = slot_led_mask_count(blink_mask);
    if (blink_count > 0) {
        memcpy(s_blink_mask, blink_mask, SLOT_LED_REGISTER_COUNT);
        if (s_blink_timer == NULL) {
            s_blink_timer = xTimerCreate("candleBlink",
                                         pdMS_TO_TICKS(500),
                                         pdTRUE, NULL,
                                         blink_timer_cb);
        }
        if (s_blink_timer) {
            xTimerReset(s_blink_timer, 0);
            uint8_t on_mask[SLOT_LED_REGISTER_COUNT] = {};
            slot_led_mask_or(on_mask, solid_mask, blink_mask);
            apply_slot_led_mask(on_mask);
            s_blink_state = true;
        }
    }

    char solid_cells[192];
    char blink_cells[192];
    slot_led_format_cell_list(solid_mask, solid_cells, sizeof(solid_cells));
    slot_led_format_cell_list(blink_mask, blink_cells, sizeof(blink_cells));
    ESP_LOGI(TAG, "Candling slot LEDs: solid=[%s] blink=[%s]",
             solid_cells, blink_cells);

    return slot_led_mask_count(solid_mask) + blink_count;
#endif
}

static bool schedule_candle_leds_off(uint32_t duration_sec)
{
    if (duration_sec == 0) {
        duration_sec = 1;
    }
    if (s_candle_timer == NULL) {
        s_candle_timer = xTimerCreate("candleOff",
                                      pdMS_TO_TICKS(duration_sec * 1000),
                                      pdFALSE, NULL, candle_leds_off);
    }
    if (s_candle_timer == NULL) {
        return false;
    }
    return xTimerChangePeriod(s_candle_timer,
                              pdMS_TO_TICKS(duration_sec * 1000),
                              pdMS_TO_TICKS(100)) == pdPASS;
}

static bool schedule_capture_hold_timeout(void)
{
    if (s_capture_hold_timer == NULL) {
        s_capture_hold_timer = xTimerCreate(
            "captureHoldOff", pdMS_TO_TICKS(CAPTURE_HOLD_FAILSAFE_SEC * 1000),
            pdFALSE, NULL, capture_hold_timeout_cb);
    }
    if (s_capture_hold_timer == NULL) {
        return false;
    }
    return xTimerChangePeriod(
               s_capture_hold_timer,
               pdMS_TO_TICKS(CAPTURE_HOLD_FAILSAFE_SEC * 1000),
               pdMS_TO_TICKS(100)) == pdPASS;
}

static void slot_leds_off(void)
{
    if (s_blink_timer) {
        xTimerStop(s_blink_timer, 0);
    }
    slot_led_mask_clear(s_blink_mask);
    s_blink_state = false;
    slot_led_mask_clear(s_slot_led_mask);
    apply_slot_led_mask(s_slot_led_mask);
}

// One-shot candling shutdown. This also restores the P4-owned main bulb if the
// app never sends /candling_stop.
static void candle_leds_off(TimerHandle_t x)
{
    (void)x;
    slot_leds_off();
    if (hardware_operation_claim_restore(HARDWARE_OP_CANDLING)) {
        bulb_relay_set_candling_hold(false);
        resume_tray_if_paused_for_candling();
        hardware_operation_finish_restore();
        ESP_LOGW(TAG, "Candling fail-safe fired: bulb=%s, tray pause released",
                 s_bulb_relay_on ? "ON" : "OFF");
    } else {
        ESP_LOGW(TAG, "LED fail-safe fired: local slot outputs OFF");
    }
}

static void capture_hold_timeout_cb(TimerHandle_t x)
{
    (void)x;
    if (hardware_operation_claim_restore(HARDWARE_OP_CAPTURE_HOLD)) {
        bulb_relay_set_normal_capture_override(false);
        resume_tray_if_paused_for_app_capture();
        hardware_operation_finish_restore();
        ESP_LOGW(TAG,
                 "App capture-hold fail-safe fired after %d s; bulb override and tray pause released",
                 CAPTURE_HOLD_FAILSAFE_SEC);
    }
}

// GET /candling_start
static esp_err_t candling_start_handler(httpd_req_t *req)
{
    if (!hardware_operation_begin(HARDWARE_OP_CANDLING, true)) {
        httpd_resp_set_hdr(req, "Access-Control-Allow-Origin", "*");
        httpd_resp_set_type(req, "application/json");
        httpd_resp_set_status(req, "409 Conflict");
        httpd_resp_sendstr(req, "{\"status\":\"busy\",\"reason\":\"scan_or_capture_hold_active\"}");
        return ESP_FAIL;
    }

    ESP_LOGI(TAG, "Candling start: main bulb OFF, stopping tray, preparing slot LEDs");
    bulb_relay_set_candling_hold(true);
    pause_tray_for_candling();
    int active_leds = start_candling_slot_leds();
    if (!schedule_candle_leds_off(CANDLING_CAPTURE_FAILSAFE_SEC)) {
        if (hardware_operation_claim_restore(HARDWARE_OP_CANDLING)) {
            slot_leds_off();
            bulb_relay_set_candling_hold(false);
            resume_tray_if_paused_for_candling();
            hardware_operation_finish_restore();
        }
        httpd_resp_set_hdr(req, "Access-Control-Allow-Origin", "*");
        httpd_resp_send_err(req, HTTPD_500_INTERNAL_SERVER_ERROR,
                            "candling fail-safe timer unavailable");
        return ESP_FAIL;
    }

    char resp[224];
    snprintf(resp, sizeof(resp),
             "{\"status\":\"ready\",\"tray_paused\":true,"
             "\"slot_led_count\":%d,\"slot_led_zone_mask\":0,"
             "\"environment_led_owner\":\"p4\",\"bulb_gpio\":33,"
             "\"bulb_on\":false,\"failsafe_sec\":%d}",
             active_leds, CANDLING_CAPTURE_FAILSAFE_SEC);
    httpd_resp_set_hdr(req, "Access-Control-Allow-Origin", "*");
    httpd_resp_set_type(req, "application/json");
    httpd_resp_sendstr(req, resp);
    return ESP_OK;
}

// GET /candling_stop
static esp_err_t candling_stop_handler(httpd_req_t *req)
{
    ESP_LOGI(TAG, "Candling stop: slot LEDs off, main bulb restore, tray resume");
    if (s_candle_timer) {
        xTimerStop(s_candle_timer, 0);
    }
    slot_leds_off();
    bool restored = hardware_operation_claim_restore(HARDWARE_OP_CANDLING);
    if (restored) {
        bulb_relay_set_candling_hold(false);
        resume_tray_if_paused_for_candling();
        hardware_operation_finish_restore();
    }
    char resp[192];
    snprintf(resp, sizeof(resp),
             "{\"status\":\"%s\",\"tray_paused\":false,"
             "\"environment_led_owner\":\"p4\",\"bulb_gpio\":33,"
             "\"bulb_on\":%s}",
             restored ? "stopped" : "already_stopped",
             s_bulb_relay_on ? "true" : "false");
    httpd_resp_set_hdr(req, "Access-Control-Allow-Origin", "*");
    httpd_resp_set_type(req, "application/json");
    httpd_resp_sendstr(req, resp);
    return ESP_OK;
}

// GET/POST /capture_hold_start
static esp_err_t capture_hold_start_handler(httpd_req_t *req)
{
    if (!hardware_operation_begin(HARDWARE_OP_CAPTURE_HOLD, true)) {
        httpd_resp_set_hdr(req, "Access-Control-Allow-Origin", "*");
        httpd_resp_set_type(req, "application/json");
        httpd_resp_set_status(req, "409 Conflict");
        httpd_resp_sendstr(req, "{\"status\":\"busy\",\"reason\":\"scan_or_candling_active\"}");
        return ESP_FAIL;
    }

    ESP_LOGI(TAG,
             "App capture hold start: main bulb ON, stopping tray without slot LEDs");
    bulb_relay_set_normal_capture_override(true);
    pause_tray_for_app_capture();
    if (!schedule_capture_hold_timeout()) {
        if (hardware_operation_claim_restore(HARDWARE_OP_CAPTURE_HOLD)) {
            bulb_relay_set_normal_capture_override(false);
            resume_tray_if_paused_for_app_capture();
            hardware_operation_finish_restore();
        }
        httpd_resp_set_hdr(req, "Access-Control-Allow-Origin", "*");
        httpd_resp_send_err(req, HTTPD_500_INTERNAL_SERVER_ERROR,
                            "capture-hold fail-safe timer unavailable");
        return ESP_FAIL;
    }
    httpd_resp_set_hdr(req, "Access-Control-Allow-Origin", "*");
    httpd_resp_set_type(req, "application/json");
    char resp[192];
    snprintf(resp, sizeof(resp),
             "{\"status\":\"ready\",\"tray_paused\":true,"
             "\"slot_led_zone_mask\":0,\"bulb_gpio\":33,"
             "\"bulb_on\":%s,\"failsafe_sec\":%d}",
             s_bulb_relay_on ? "true" : "false",
             CAPTURE_HOLD_FAILSAFE_SEC);
    httpd_resp_sendstr(req, resp);
    return ESP_OK;
}

// GET/POST /capture_hold_stop
static esp_err_t capture_hold_stop_handler(httpd_req_t *req)
{
    ESP_LOGI(TAG, "App capture hold stop: bulb auto restore, tray resume");
    bool restored = hardware_operation_claim_restore(HARDWARE_OP_CAPTURE_HOLD);
    if (restored && s_capture_hold_timer) {
        xTimerStop(s_capture_hold_timer, pdMS_TO_TICKS(100));
    }
    if (restored) {
        bulb_relay_set_normal_capture_override(false);
        resume_tray_if_paused_for_app_capture();
        hardware_operation_finish_restore();
    }
    httpd_resp_set_hdr(req, "Access-Control-Allow-Origin", "*");
    httpd_resp_set_type(req, "application/json");
    httpd_resp_sendstr(
        req, restored
            ? "{\"status\":\"stopped\",\"tray_paused\":false,\"slot_led_zone_mask\":0}"
            : "{\"status\":\"already_stopped\",\"tray_paused\":false,\"slot_led_zone_mask\":0}");
    return ESP_OK;
}

// GET/POST /camera_focus?state=on|off
// The S3 uses this while streaming or capturing so the P4 does not compete
// for the S3's single HTTP server. Climate sensing and relay control continue.
static esp_err_t camera_focus_handler(httpd_req_t *req)
{
    char query[48] = {};
    char state[12] = {};
    if (httpd_req_get_url_query_str(req, query, sizeof(query)) != ESP_OK ||
        httpd_query_key_value(query, "state", state, sizeof(state)) != ESP_OK) {
        httpd_resp_set_hdr(req, "Access-Control-Allow-Origin", "*");
        httpd_resp_send_err(req, HTTPD_400_BAD_REQUEST, "use state=on or state=off");
        return ESP_FAIL;
    }

    bool active;
    if (strcasecmp(state, "on") == 0 || strcmp(state, "1") == 0) {
        active = true;
    } else if (strcasecmp(state, "off") == 0 || strcmp(state, "0") == 0) {
        active = false;
    } else {
        httpd_resp_set_hdr(req, "Access-Control-Allow-Origin", "*");
        httpd_resp_send_err(req, HTTPD_400_BAD_REQUEST, "use state=on or state=off");
        return ESP_FAIL;
    }

    s3_camera_focus_set(active);
    char resp[192];
    snprintf(resp, sizeof(resp),
             "{\"status\":\"ok\",\"camera_focus\":%s,"
             "\"climate_active\":true,\"s3_background_http_paused\":%s,"
             "\"timeout_ms\":%d}",
             active ? "true" : "false",
             active ? "true" : "false",
             S3_CAMERA_FOCUS_TIMEOUT_MS);
    httpd_resp_set_hdr(req, "Access-Control-Allow-Origin", "*");
    httpd_resp_set_type(req, "application/json");
    httpd_resp_sendstr(req, resp);
    return ESP_OK;
}

// GET /led_test?led=1..56, /led_test?cell=0..55, /led_test?slot=1..56,
// /led_test?chase=1, or /led_test?zone=0|1|2|all|off for quick checks.
static esp_err_t led_test_handler(httpd_req_t *req)
{
    char query[64] = {};
    char zone_arg[12] = {};
    char led_arg[12] = {};
    char cell_arg[12] = {};
    char slot_arg[12] = {};
    char chase_arg[12] = {};
    uint8_t mask[SLOT_LED_REGISTER_COUNT] = {};
    char label[24] = "off";

    if (httpd_req_get_url_query_str(req, query, sizeof(query)) == ESP_OK) {
        httpd_query_key_value(query, "zone", zone_arg, sizeof(zone_arg));
        httpd_query_key_value(query, "led", led_arg, sizeof(led_arg));
        httpd_query_key_value(query, "cell", cell_arg, sizeof(cell_arg));
        httpd_query_key_value(query, "slot", slot_arg, sizeof(slot_arg));
        httpd_query_key_value(query, "chase", chase_arg, sizeof(chase_arg));
    }

    if (chase_arg[0] != '\0') {
        if (s_candle_timer) {
            xTimerStop(s_candle_timer, 0);
        }
        slot_leds_off();
        for (int cell = 0; cell < SLOT_LED_COUNT; cell++) {
            slot_led_mask_clear(mask);
            slot_led_mask_set_cell(mask, cell);
            set_slot_led_mask(mask);
            vTaskDelay(pdMS_TO_TICKS(80));
        }
        slot_leds_off();
        httpd_resp_set_hdr(req, "Access-Control-Allow-Origin", "*");
        httpd_resp_set_type(req, "application/json");
        httpd_resp_sendstr(req, "{\"status\":\"ok\",\"target\":\"chase\",\"slot_led_count\":0,\"slot_led_zone_mask\":0}");
        return ESP_OK;
    } else if (strcmp(zone_arg, "all") == 0 || strcmp(led_arg, "all") == 0 ||
        strcmp(cell_arg, "all") == 0 || strcmp(slot_arg, "all") == 0) {
        for (int cell = 0; cell < SLOT_LED_COUNT; cell++) {
            slot_led_mask_set_cell(mask, cell);
        }
        snprintf(label, sizeof(label), "all");
    } else if (strcmp(zone_arg, "off") == 0 || strcmp(led_arg, "off") == 0 ||
               strcmp(cell_arg, "off") == 0 || strcmp(slot_arg, "off") == 0) {
        snprintf(label, sizeof(label), "off");
    } else if (led_arg[0] != '\0' || slot_arg[0] != '\0') {
        int led = atoi(led_arg[0] != '\0' ? led_arg : slot_arg);
        if (led < 1 || led > SLOT_LED_COUNT) {
            httpd_resp_set_hdr(req, "Access-Control-Allow-Origin", "*");
            httpd_resp_send_err(req, HTTPD_400_BAD_REQUEST,
                                "use led=1..56, slot=1..56, cell=0..55, all, or off");
            return ESP_FAIL;
        }
        slot_led_mask_set_cell(mask, led - 1);
        snprintf(label, sizeof(label), "led%d", led);
    } else if (cell_arg[0] != '\0') {
        int cell = atoi(cell_arg);
        if (cell < 0 || cell >= SLOT_LED_COUNT) {
            httpd_resp_set_hdr(req, "Access-Control-Allow-Origin", "*");
            httpd_resp_send_err(req, HTTPD_400_BAD_REQUEST,
                                "use cell=0..55, led=1..56, slot=1..56, all, or off");
            return ESP_FAIL;
        }
        slot_led_mask_set_cell(mask, cell);
        snprintf(label, sizeof(label), "cell%d", cell);
    } else if (zone_arg[0] != '\0') {
        int zone = atoi(zone_arg);
        if (zone < 0 || zone > 2) {
            httpd_resp_set_hdr(req, "Access-Control-Allow-Origin", "*");
            httpd_resp_send_err(req, HTTPD_400_BAD_REQUEST,
                                "use led=1..56, cell=0..55, zone=0..2, all, or off");
            return ESP_FAIL;
        }
        int start = (zone == 0) ? 0 : (zone == 1) ? 18 : 36;
        int end = (zone == 0) ? 17 : (zone == 1) ? 35 : 55;
        for (int cell = start; cell <= end; cell++) {
            slot_led_mask_set_cell(mask, cell);
        }
        snprintf(label, sizeof(label), "zone%d", zone);
    } else {
        snprintf(label, sizeof(label), "off");
    }

    if (s_candle_timer) {
        xTimerStop(s_candle_timer, 0);
    }
    slot_leds_off();
    set_slot_led_mask(mask);
    int active_count = slot_led_mask_count(mask);
    if (active_count != 0 &&
        !schedule_candle_leds_off(CANDLE_LED_DURATION_SEC)) {
        slot_leds_off();
        httpd_resp_set_hdr(req, "Access-Control-Allow-Origin", "*");
        httpd_resp_send_err(req, HTTPD_500_INTERNAL_SERVER_ERROR,
                            "LED fail-safe timer unavailable");
        return ESP_FAIL;
    }

    char cells[192];
    slot_led_format_cell_list(mask, cells, sizeof(cells));
    char resp[320];
    snprintf(resp, sizeof(resp),
             "{\"status\":\"ok\",\"target\":\"%s\",\"slot_led_count\":%d,"
             "\"cells\":[%s],\"slot_led_zone_mask\":0}",
             label, active_count, cells);
    httpd_resp_set_hdr(req, "Access-Control-Allow-Origin", "*");
    httpd_resp_set_type(req, "application/json");
    httpd_resp_sendstr(req, resp);
    return ESP_OK;
}

// Blink selected slot LEDs at 500 ms interval.
static void blink_timer_cb(TimerHandle_t x)
{
    (void)x;
    uint8_t next_mask[SLOT_LED_REGISTER_COUNT] = {};
    s_blink_state = !s_blink_state;
    if (s_blink_state) {
        slot_led_mask_or(next_mask, s_slot_led_mask, s_blink_mask);
    } else {
        slot_led_mask_without(next_mask, s_slot_led_mask, s_blink_mask);
    }
    apply_slot_led_mask(next_mask);
}

static void get_infertile_slot_mask(uint8_t mask[SLOT_LED_REGISTER_COUNT])
{
    slot_led_mask_clear(mask);
    for (int cell = 0; cell < SLOT_LED_COUNT; cell++) {
        if (s_infertile_slots[cell]) {
            slot_led_mask_set_cell(mask, cell);
        }
    }
}

static int start_infertile_slot_blink(void)
{
    refresh_cell_day_status(time(NULL));
    uint8_t blink_mask[SLOT_LED_REGISTER_COUNT] = {};
    get_infertile_slot_mask(blink_mask);
    int blink_count = slot_led_mask_count(blink_mask);
    if (blink_count == 0) {
        slot_leds_off();
        return 0;
    }

    set_slot_led_mask(blink_mask);

    memcpy(s_blink_mask, blink_mask, SLOT_LED_REGISTER_COUNT);
    if (s_blink_timer == NULL) {
        s_blink_timer = xTimerCreate("candleBlink",
                                     pdMS_TO_TICKS(500),
                                     pdTRUE, NULL,
                                     blink_timer_cb);
    }
    if (s_blink_timer) {
        s_blink_state = true;
        xTimerReset(s_blink_timer, 0);
    }
    if (!schedule_candle_leds_off(CANDLE_LED_DURATION_SEC)) {
        slot_leds_off();
        return 0;
    }
    return blink_count;
}

static int parse_json_int_field(const char *buf, const char *key, int fallback)
{
    char pattern[32];
    snprintf(pattern, sizeof(pattern), "\"%s\"", key);

    const char *p = strstr(buf, pattern);
    if (p == NULL) {
        return fallback;
    }
    p = strchr(p, ':');
    if (p == NULL) {
        return fallback;
    }
    p++;

    char *endp = NULL;
    long value = strtol(p, &endp, 10);
    return (endp != p) ? (int)value : fallback;
}

static bool mark_infertile_cell(int cell, int request_day, int *marked, int *ignored)
{
    if (cell < 0 || cell >= NUM_CELLS) {
        if (ignored) (*ignored)++;
        return false;
    }

    int effective_day = (request_day > 0) ? request_day : s_cell_day[cell];
    if (effective_day < TRUE_ID_DAY) {
        if (ignored) (*ignored)++;
        return false;
    }

    if (!s_infertile_slots[cell]) {
        s_infertile_slots[cell] = true;
        if (marked) (*marked)++;
    }
    return true;
}

static void parse_infertile_array_field(const char *buf, const char *key,
                                        int request_day, bool *seen,
                                        int *parsed, int *marked, int *ignored)
{
    char pattern[32];
    snprintf(pattern, sizeof(pattern), "\"%s\"", key);

    const char *field = strstr(buf, pattern);
    if (field == NULL) {
        return;
    }

    const char *p = strchr(field, '[');
    if (p == NULL) {
        return;
    }
    p++;

    while (*p && *p != ']') {
        while (*p && *p != ']' && (*p < '0' || *p > '9') && *p != '-') {
            p++;
        }
        if (*p == ']' || *p == '\0') {
            break;
        }

        char *endp = NULL;
        long idx = strtol(p, &endp, 10);
        if (endp == p) {
            break;
        }

        if (parsed) (*parsed)++;
        if (idx >= 0 && idx < NUM_CELLS && !seen[idx]) {
            seen[idx] = true;
            mark_infertile_cell((int)idx, request_day, marked, ignored);
        } else if (ignored) {
            (*ignored)++;
        }
        p = endp;
    }
}

// Infertile-marking endpoints (mobile app to P4)

struct StateMutationGuard {
    bool locked;

    explicit StateMutationGuard(httpd_req_t *req) : locked(false)
    {
        if (s_state_mutex != NULL &&
            xSemaphoreTake(s_state_mutex, pdMS_TO_TICKS(100)) == pdTRUE) {
            locked = true;
            return;
        }

        httpd_resp_set_hdr(req, "Access-Control-Allow-Origin", "*");
        httpd_resp_set_status(req, "409 Conflict");
        httpd_resp_set_type(req, "application/json");
        httpd_resp_sendstr(req,
            "{\"status\":\"busy\",\"error\":\"scan transaction active\"}");
    }

    ~StateMutationGuard(void)
    {
        if (locked) {
            xSemaphoreGive(s_state_mutex);
        }
    }

    bool ready(void) const { return locked; }
};

static bool persist_runtime_state_or_restore(httpd_req_t *req,
                                             const EggRuntimeState *previous)
{
    if (nvs_save_snapshots()) {
        return true;
    }

    runtime_state_restore(previous);
    httpd_resp_set_hdr(req, "Access-Control-Allow-Origin", "*");
    httpd_resp_send_err(req, HTTPD_500_INTERNAL_SERVER_ERROR,
                        "state persistence failed");
    return false;
}

static bool parse_fertility_result_cells(cJSON *root, const char *field_name,
                                         bool seen[NUM_CELLS],
                                         bool selected[NUM_CELLS],
                                         int *count, const char **error)
{
    cJSON *array = cJSON_GetObjectItemCaseSensitive(root, field_name);
    if (!cJSON_IsArray(array)) {
        if (error != NULL) *error = "fertile and infertile arrays are required";
        return false;
    }

    cJSON *item = NULL;
    cJSON_ArrayForEach(item, array) {
        if (!cJSON_IsNumber(item) || item->valuedouble != item->valueint) {
            if (error != NULL) *error = "fertility cells must be integer indexes";
            return false;
        }
        int cell = item->valueint;
        if (cell < 0 || cell >= NUM_CELLS) {
            if (error != NULL) *error = "fertility cells must be 0..55";
            return false;
        }
        if (seen[cell]) {
            if (error != NULL) *error = "fertility cells must be unique and non-overlapping";
            return false;
        }
        if (!s_cell_has_egg[cell]) {
            if (error != NULL) *error = "fertility result targets an empty P4 slot";
            return false;
        }
        seen[cell] = true;
        selected[cell] = true;
        if (count != NULL) (*count)++;
    }
    return true;
}

// The phone owns fertile/infertile inference. P4 never runs a fertility model;
// it only validates, persists, displays, and exposes the accepted phone result.
// Cell indexes are zero-based to match /set_slots and existing app payloads.
// POST /set_fertility_results
// {"day":7,"fertile":[0,1],"infertile":[5],"source":"mobile_tflite"}
static esp_err_t set_fertility_results_handler(httpd_req_t *req)
{
    StateMutationGuard mutation(req);
    if (!mutation.ready()) {
        return ESP_FAIL;
    }

    if (req->content_len == 0 || req->content_len >= 1024) {
        httpd_resp_set_hdr(req, "Access-Control-Allow-Origin", "*");
        httpd_resp_send_err(req, HTTPD_400_BAD_REQUEST, "invalid body size");
        return ESP_FAIL;
    }

    char buf[1024] = {};
    size_t got = 0;
    while (got < req->content_len) {
        int read_len = httpd_req_recv(req, buf + got, req->content_len - got);
        if (read_len <= 0) {
            httpd_resp_set_hdr(req, "Access-Control-Allow-Origin", "*");
            httpd_resp_send_err(req, HTTPD_500_INTERNAL_SERVER_ERROR,
                                "receive failed");
            return ESP_FAIL;
        }
        got += (size_t)read_len;
    }
    buf[got] = '\0';

    cJSON *root = cJSON_Parse(buf);
    if (root == NULL) {
        httpd_resp_set_hdr(req, "Access-Control-Allow-Origin", "*");
        httpd_resp_send_err(req, HTTPD_400_BAD_REQUEST, "invalid json");
        return ESP_FAIL;
    }

    cJSON *day_item = cJSON_GetObjectItemCaseSensitive(root, "day");
    int request_day = cJSON_IsNumber(day_item) ? day_item->valueint : -1;
    const char *error = NULL;
    bool seen[NUM_CELLS] = {};
    bool fertile[NUM_CELLS] = {};
    bool infertile[NUM_CELLS] = {};
    int fertile_count = 0;
    int infertile_count = 0;
    bool valid = request_day >= 7 && request_day <= 14;
    if (!valid) {
        error = "day must be 7..14";
    } else {
        valid = parse_fertility_result_cells(
                    root, "fertile", seen, fertile, &fertile_count, &error) &&
                parse_fertility_result_cells(
                    root, "infertile", seen, infertile, &infertile_count, &error);
    }
    if (valid && fertile_count + infertile_count == 0) {
        valid = false;
        error = "at least one fertility result is required";
    }
    if (!valid) {
        cJSON_Delete(root);
        httpd_resp_set_hdr(req, "Access-Control-Allow-Origin", "*");
        httpd_resp_send_err(req, HTTPD_400_BAD_REQUEST,
                            error != NULL ? error : "invalid fertility results");
        return ESP_FAIL;
    }

    cJSON *source_item = cJSON_GetObjectItemCaseSensitive(root, "source");
    const char *source = cJSON_IsString(source_item) && source_item->valuestring != NULL
                             ? source_item->valuestring
                             : "mobile_model";
    char source_copy[32];
    snprintf(source_copy, sizeof(source_copy), "%s", source);

    EggRuntimeState previous = {};
    runtime_state_capture(&previous);
    refresh_cell_day_status(time(NULL));
    for (int cell = 0; cell < NUM_CELLS; cell++) {
        if (fertile[cell]) {
            s_cell_status[cell] = CELL_STATUS_FERTILE;
            s_infertile_slots[cell] = false;
            s_infertile_streak[cell] = 0;
        } else if (infertile[cell]) {
            s_cell_status[cell] = CELL_STATUS_INFERTILE;
            s_infertile_slots[cell] = true;
            // A thresholded phone-model result is final for the automatic
            // workflow; no second farmer tap or manual confirmation is needed.
            s_infertile_streak[cell] = INFERTILE_CONFIRM_CANDLINGS;
        }
    }

    cJSON_Delete(root);
    if (!persist_runtime_state_or_restore(req, &previous)) {
        return ESP_FAIL;
    }

    ESP_LOGI(TAG,
             "Phone fertility results accepted: source=%s day=%d fertile=%d infertile=%d",
             source_copy, request_day, fertile_count, infertile_count);
    char response[256];
    snprintf(response, sizeof(response),
             "{\"status\":\"ok\",\"owner\":\"mobile_app\",\"day\":%d,"
             "\"fertile_count\":%d,\"infertile_count\":%d,"
             "\"manual_confirmation_required\":false}",
             request_day, fertile_count, infertile_count);
    httpd_resp_set_hdr(req, "Access-Control-Allow-Origin", "*");
    httpd_resp_set_type(req, "application/json");
    httpd_resp_sendstr(req, response);
    return ESP_OK;
}

// Mobile app owns fertility classification. P4 only stores the app-provided
// day-7+ slot list so it can drive physical LED feedback.
// POST /set_infertile  { "infertile": [0,5,12], "slots": [0,5,12], "day": 7 }
static esp_err_t set_infertile_handler(httpd_req_t *req)
{
    StateMutationGuard mutation(req);
    if (!mutation.ready()) {
        return ESP_FAIL;
    }

    char buf[256];
    size_t to_read = req->content_len;
    if (to_read >= sizeof(buf)) {
        httpd_resp_set_hdr(req, "Access-Control-Allow-Origin", "*");
        httpd_resp_send_err(req, HTTPD_400_BAD_REQUEST, "body too large");
        return ESP_FAIL;
    }

    size_t got = 0;
    while (got < to_read) {
        int r = httpd_req_recv(req, buf + got, to_read - got);
        if (r <= 0) {
            httpd_resp_set_hdr(req, "Access-Control-Allow-Origin", "*");
            httpd_resp_send_err(req, HTTPD_500_INTERNAL_SERVER_ERROR, "receive failed");
            return ESP_FAIL;
        }
        got += r;
    }
    buf[got] = '\0';

    EggRuntimeState previous = {};
    runtime_state_capture(&previous);
    refresh_cell_day_status(time(NULL));

    int request_day = parse_json_int_field(buf, "day", 0);
    int parsed = 0;
    int marked = 0;
    int ignored = 0;
    bool seen[NUM_CELLS] = {};

    memset(s_infertile_slots, 0, sizeof(s_infertile_slots));
    if (strstr(buf, "\"infertile\"") != NULL) {
        parse_infertile_array_field(buf, "infertile", request_day, seen,
                                    &parsed, &marked, &ignored);
    } else if (strstr(buf, "\"slots\"") != NULL) {
        parse_infertile_array_field(buf, "slots", request_day, seen,
                                    &parsed, &marked, &ignored);
    } else if (strstr(buf, "\"cells\"") != NULL) {
        parse_infertile_array_field(buf, "cells", request_day, seen,
                                    &parsed, &marked, &ignored);
    }

    int single_slot = (parsed == 0) ? parse_json_int_field(buf, "slot", -1) : -1;
    if (single_slot >= 0) {
        parsed++;
        if (single_slot < NUM_CELLS && !seen[single_slot]) {
            seen[single_slot] = true;
            mark_infertile_cell(single_slot, request_day, &marked, &ignored);
        } else {
            ignored++;
        }
    }

    int single_cell = (parsed == 0) ? parse_json_int_field(buf, "cell", -1) : -1;
    if (single_cell >= 0) {
        parsed++;
        if (single_cell < NUM_CELLS && !seen[single_cell]) {
            seen[single_cell] = true;
            mark_infertile_cell(single_cell, request_day, &marked, &ignored);
        } else {
            ignored++;
        }
    }

    if (parsed == 0) {
        runtime_state_restore(&previous);
        httpd_resp_set_hdr(req, "Access-Control-Allow-Origin", "*");
        httpd_resp_send_err(req, HTTPD_400_BAD_REQUEST, "expected cell or cells");
        return ESP_FAIL;
    }

    // One set_infertile call == one candling. Extend the streak for cells still
    // marked infertile; reset cells that are not. The door-open removal blink
    // only lights cells that reach INFERTILE_CONFIRM_CANDLINGS in a row.
    for (int c = 0; c < NUM_CELLS; c++) {
        if (s_infertile_slots[c]) {
            if (s_infertile_streak[c] < 255) s_infertile_streak[c]++;
        } else {
            s_infertile_streak[c] = 0;
        }
    }

    refresh_cell_day_status(time(NULL));
    if (!persist_runtime_state_or_restore(req, &previous)) {
        return ESP_FAIL;
    }
    int blink_count = start_infertile_slot_blink();

    uint8_t blink_mask[SLOT_LED_REGISTER_COUNT] = {};
    get_infertile_slot_mask(blink_mask);
    char blink_cells[192];
    slot_led_format_cell_list(blink_mask, blink_cells, sizeof(blink_cells));

    ESP_LOGI(TAG, "App infertile slots: day=%d parsed=%d marked=%d ignored=%d blink_leds=%d",
             request_day, parsed, marked, ignored, blink_count);

    char resp[384];
    snprintf(resp, sizeof(resp),
             "{\"status\":\"ok\",\"fertility_detection\":false,"
             "\"parsed\":%d,\"marked\":%d,\"ignored\":%d,"
             "\"day\":%d,\"true_id_day\":%d,"
             "\"blink_led_count\":%d,\"blink_cells\":[%s],"
             "\"blink_zone_mask\":0,\"blink_zones\":[]}",
             parsed, marked, ignored, request_day, TRUE_ID_DAY,
             blink_count, blink_cells);

    httpd_resp_set_hdr(req, "Access-Control-Allow-Origin", "*");
    httpd_resp_set_type(req, "application/json");
    httpd_resp_sendstr(req, resp);
    return ESP_OK;
}

// POST /clear_infertile  {}
static esp_err_t clear_infertile_handler(httpd_req_t *req)
{
    StateMutationGuard mutation(req);
    if (!mutation.ready()) {
        return ESP_FAIL;
    }
    EggRuntimeState previous = {};
    runtime_state_capture(&previous);
    memset(s_infertile_slots, 0, sizeof(s_infertile_slots));
    memset(s_infertile_streak, 0, sizeof(s_infertile_streak));
    refresh_cell_day_status(time(NULL));
    if (!persist_runtime_state_or_restore(req, &previous)) {
        return ESP_FAIL;
    }
    slot_leds_off();
    ESP_LOGI(TAG, "Legacy fertility marks cleared");
    httpd_resp_set_hdr(req, "Access-Control-Allow-Origin", "*");
    httpd_resp_set_type(req, "application/json");
    httpd_resp_sendstr(req, "{\"status\":\"cleared\",\"fertility_detection\":false}");
    return ESP_OK;
}

// GET /blink_infertile
static esp_err_t blink_infertile_handler(httpd_req_t *req)
{
    int blink_count = start_infertile_slot_blink();
    uint8_t blink_mask[SLOT_LED_REGISTER_COUNT] = {};
    get_infertile_slot_mask(blink_mask);
    char blink_cells[192];
    char resp[320];
    slot_led_format_cell_list(blink_mask, blink_cells, sizeof(blink_cells));

    snprintf(resp, sizeof(resp),
             "{\"status\":\"ok\",\"fertility_detection\":false,"
             "\"blink_led_count\":%d,\"blink_cells\":[%s],"
             "\"blink_zone_mask\":0,\"blink_zones\":[]}",
             blink_count, blink_cells);

    httpd_resp_set_hdr(req, "Access-Control-Allow-Origin", "*");
    httpd_resp_set_type(req, "application/json");
    httpd_resp_sendstr(req, resp);
    return ESP_OK;
}

// GET /get_infertile
static esp_err_t get_infertile_handler(httpd_req_t *req)
{
    refresh_cell_day_status(time(NULL));

    char cells[192];
    int cell_pos = 0;
    bool first = true;
    cells[0] = '\0';
    for (int i = 0; i < NUM_CELLS; i++) {
        if (!s_infertile_slots[i]) {
            continue;
        }
        cell_pos += snprintf(cells + cell_pos, sizeof(cells) - cell_pos,
                             "%s%d", first ? "" : ",", i);
        first = false;
        if (cell_pos >= (int)sizeof(cells)) {
            cells[sizeof(cells) - 1] = '\0';
            break;
        }
    }

    char resp[1024];
    int pos = 0;
    uint8_t blink_mask[SLOT_LED_REGISTER_COUNT] = {};
    get_infertile_slot_mask(blink_mask);
    int blink_count = slot_led_mask_count(blink_mask);

    pos += snprintf(resp + pos, sizeof(resp) - pos,
                    "{\"fertility_detection\":false,\"blink_led_count\":%d,"
                    "\"blink_cells\":[%s],\"blink_zone_mask\":0,"
                    "\"blink_zones\":[],\"infertile\":[%s],\"cells\":[%s]}",
                    blink_count, cells, cells, cells);
    httpd_resp_set_hdr(req, "Access-Control-Allow-Origin", "*");
    httpd_resp_set_type(req, "application/json");
    httpd_resp_sendstr(req, resp);
    return ESP_OK;
}

// GET /get_slots
static bool cell_abnormal_alert(int cell)
{
    return cell >= 0 && cell < NUM_CELLS && s_cell_has_egg[cell] &&
           s_abnormal_slots[cell];
}

static bool cell_pending_intake(int cell)
{
    return cell >= 0 && cell < NUM_CELLS && s_cell_has_egg[cell] &&
           s_pending_verification_slots[cell];
}

static void append_slot_number_array(char *buf, size_t buf_size, int *pos,
                                     bool (*predicate)(int))
{
    *pos += snprintf(buf + *pos, buf_size - *pos, "[");
    bool first = true;
    for (int cell = 0; cell < NUM_CELLS && *pos < (int)buf_size; cell++) {
        if (predicate == NULL || !predicate(cell)) continue;
        *pos += snprintf(buf + *pos, buf_size - *pos, "%s%d",
                         first ? "" : ",", cell + 1);
        first = false;
    }
    if (*pos < (int)buf_size) {
        *pos += snprintf(buf + *pos, buf_size - *pos, "]");
    }
}

static esp_err_t get_slots_handler(httpd_req_t *req)
{
    time_t now = time(NULL);
    refresh_cell_day_status(now);
    int day = max_egg_day();

    struct tm now_tm = {};
    char now_iso[80] = "";
    if (localtime_r(&now, &now_tm) != NULL) {
        snprintf(now_iso, sizeof(now_iso), "%04d-%02d-%02d %02d:%02d:%02d",
                 now_tm.tm_year + 1900, now_tm.tm_mon + 1, now_tm.tm_mday,
                 now_tm.tm_hour, now_tm.tm_min, now_tm.tm_sec);
    }
    time_t last_scan_time = 0;
    if (s_snapshot_count > 0 && s_snapshots[0].valid) {
        last_scan_time = s_snapshots[0].scan_time;
    }
    ScanFailureReason last_failure = s_last_scan_failure;
    const char *scan_status = s_ai_scan_active ? "active" :
                              (last_failure != SCAN_FAIL_NONE ? "error" :
                               (s_scan_valid ? "ok" : "idle"));
    const char *scan_error = scan_failure_key(last_failure);
    const char *equipment_code = equipment_fault_code();
    const char *equipment_message = equipment_fault_message(equipment_code);
    int abnormal_count = count_cells_matching(cell_abnormal_alert);
    int infertile_count = count_cells_matching(cell_confirmed_infertile);
    int fertile_result_count = count_cells_matching(cell_fertile_result);
    int infertile_result_count = count_cells_matching(cell_infertile_result);
    int removal_count = count_cells_matching(cell_remove_alert);
    int transfer_count = count_cells_matching(cell_transfer_ready);
    int pending_count = count_cells_matching(cell_pending_intake);
    int alert_count = removal_count + transfer_count;

    char *resp = (char *)heap_caps_malloc(GET_SLOTS_RESP_BUF_SIZE, MALLOC_CAP_8BIT);
    if (resp == NULL) {
        httpd_resp_set_hdr(req, "Access-Control-Allow-Origin", "*");
        httpd_resp_send_err(req, HTTPD_500_INTERNAL_SERVER_ERROR, "no response memory");
        return ESP_FAIL;
    }
    const size_t resp_sz = GET_SLOTS_RESP_BUF_SIZE;
    int pos = 0;
    pos += snprintf(resp + pos, resp_sz - pos,
                    "{\"eggs\":[");

    for (int i = 0; i < NUM_CELLS; i++) {
        if (i > 0) {
            pos += snprintf(resp + pos, resp_sz - pos, ",");
        }
        pos += snprintf(resp + pos, resp_sz - pos,
                        "%s", s_cell_has_egg[i] ? "true" : "false");
    }

    pos += snprintf(resp + pos, resp_sz - pos,
                    "],\"placed_at\":[");

    for (int i = 0; i < NUM_CELLS; i++) {
        if (i > 0) {
            pos += snprintf(resp + pos, resp_sz - pos, ",");
        }
        if (s_cell_has_egg[i] && s_cell_start_time[i] > 0) {
            pos += snprintf(resp + pos, resp_sz - pos,
                            "%lld", (long long)s_cell_start_time[i]);
        } else {
            pos += snprintf(resp + pos, resp_sz - pos, "null");
        }
    }

    pos += snprintf(resp + pos, resp_sz - pos,
                    "],\"days\":[");

    for (int i = 0; i < NUM_CELLS; i++) {
        if (i > 0) {
            pos += snprintf(resp + pos, resp_sz - pos, ",");
        }
        pos += snprintf(resp + pos, resp_sz - pos, "%d", s_cell_day[i]);
    }

    pos += snprintf(resp + pos, resp_sz - pos,
                    "],\"fertility_verdicts\":[");
    for (int i = 0; i < NUM_CELLS; i++) {
        pos += snprintf(resp + pos, resp_sz - pos, "%s\"%s\"",
                        i == 0 ? "" : ",",
                        fertility_verdict_name(s_cell_status[i]));
    }

    pos += snprintf(resp + pos, resp_sz - pos, "],\"abnormal_slots\":");
    append_slot_number_array(resp, resp_sz, &pos, cell_abnormal_alert);
    pos += snprintf(resp + pos, resp_sz - pos, ",\"fertile_slots\":");
    append_slot_number_array(resp, resp_sz, &pos, cell_fertile_result);
    pos += snprintf(resp + pos, resp_sz - pos,
                    ",\"infertile_result_slots\":");
    append_slot_number_array(resp, resp_sz, &pos, cell_infertile_result);
    pos += snprintf(resp + pos, resp_sz - pos,
                    ",\"confirmed_infertile_slots\":");
    append_slot_number_array(resp, resp_sz, &pos, cell_confirmed_infertile);
    pos += snprintf(resp + pos, resp_sz - pos,
                    ",\"remove_slots\":");
    append_slot_number_array(resp, resp_sz, &pos, cell_remove_alert);
    pos += snprintf(resp + pos, resp_sz - pos,
                    ",\"transfer_ready_slots\":");
    append_slot_number_array(resp, resp_sz, &pos, cell_transfer_ready);
    pos += snprintf(resp + pos, resp_sz - pos,
                    ",\"pending_intake_slots\":");
    append_slot_number_array(resp, resp_sz, &pos, cell_pending_intake);

    pos += snprintf(resp + pos, resp_sz - pos,
                    ",\"count\":%d,\"alert_count\":%d,"
                    "\"abnormal_count\":%d,\"confirmed_infertile_count\":%d,"
                    "\"fertile_result_count\":%d,\"infertile_result_count\":%d,"
                    "\"remove_count\":%d,\"transfer_ready_count\":%d,"
                    "\"pending_intake_count\":%d,\"intake_model_installed\":%s,"
                    "\"automatic_intake_screening_enabled\":%s,"
                    "\"equipment\":{\"active\":%s,\"code\":\"%s\",\"message\":\"%s\"},"
                    "\"metadata\":{\"day\":%d,\"now_epoch\":%lld,\"now\":\"%s\","
                    "\"last_scan_epoch\":%lld,\"scan_valid\":%s,\"snapshot_count\":%d,"
                    "\"scan_active\":%s,\"scan_status\":\"%s\",\"last_scan_error\":\"%s\",\"retry_count\":%lu,"
                    "\"time_trusted\":%s,\"time_sync_required\":%s,\"time_source\":\"%s\","
                    "\"time_synced_from_phone\":%s,\"last_phone_sync_epoch\":%lld},"
                    "\"now_epoch\":%lld,\"now\":\"%s\","
                    "\"last_scan_epoch\":%lld,\"scan_valid\":%s,"
                    "\"scan_active\":%s,\"scan_status\":\"%s\",\"last_scan_error\":\"%s\",\"retry_count\":%lu,"
                    "\"time_trusted\":%s,\"time_sync_required\":%s,\"time_source\":\"%s\","
                    "\"time_synced_from_phone\":%s,\"last_phone_sync_epoch\":%lld,"
                    "\"egg_count\":%d,\"eggDay\":%d,\"true_id_day\":%d,"
                    "\"fertility_detection\":false,"
                    "\"fertility_inference_owner\":\"mobile_app\","
                    "\"manual_fertility_confirmation_required\":false,"
                    "\"grid\":{\"cols\":%d,\"rows\":%d,\"ready\":%s},"
                    "\"slots\":[",
                    s_last_egg_count, alert_count, abnormal_count,
                    infertile_count, fertile_result_count,
                    infertile_result_count, removal_count, transfer_count,
                    pending_count, INTAKE_MODEL_INSTALLED ? "true" : "false",
                    AUTOMATIC_INTAKE_SCREENING_ENABLED ? "true" : "false",
                    strcmp(equipment_code, "none") != 0 ? "true" : "false",
                    equipment_code, equipment_message,
                    day, (long long)now, now_iso,
                    (long long)last_scan_time, s_scan_valid ? "true" : "false", s_snapshot_count,
                    s_ai_scan_active ? "true" : "false", scan_status, scan_error,
                    (unsigned long)s_scan_retry_count,
                    s_time_trusted ? "true" : "false", s_time_trusted ? "false" : "true",
                    s_time_source, s_time_synced_from_phone ? "true" : "false",
                    (long long)s_last_phone_sync_time,
                    (long long)now, now_iso,
                    (long long)last_scan_time, s_scan_valid ? "true" : "false",
                    s_ai_scan_active ? "true" : "false", scan_status, scan_error,
                    (unsigned long)s_scan_retry_count,
                    s_time_trusted ? "true" : "false", s_time_trusted ? "false" : "true",
                    s_time_source, s_time_synced_from_phone ? "true" : "false",
                    (long long)s_last_phone_sync_time,
                    s_last_egg_count, day, TRUE_ID_DAY,
                    s_grid_cols, s_grid_rows, s_grid_config_ready ? "true" : "false");

    for (int i = 0; i < NUM_CELLS; i++) {
        if (i > 0) {
            pos += snprintf(resp + pos, resp_sz - pos, ",");
        }
        pos += snprintf(resp + pos, resp_sz - pos,
                        "{\"cell\":%d,\"has_egg\":%s,\"placed_at\":",
                        i, s_cell_has_egg[i] ? "true" : "false");
        if (s_cell_has_egg[i] && s_cell_start_time[i] > 0) {
            pos += snprintf(resp + pos, resp_sz - pos,
                            "%lld", (long long)s_cell_start_time[i]);
        } else {
            pos += snprintf(resp + pos, resp_sz - pos, "null");
        }
        pos += snprintf(resp + pos, resp_sz - pos,
                        ",\"days\":%d,\"status\":\"%s\","
                        "\"fertility_verdict\":\"%s\","
                        "\"intake_verdict\":\"%s\",\"farmer_result\":%s,"
                        "\"abnormal\":%s,\"pending_verification\":%s,"
                        "\"confirmed_infertile\":%s,\"remove_alert\":%s,"
                        "\"transfer_ready\":%s,\"fingerprint_valid\":%s}",
                        s_cell_day[i], cell_status_name(s_cell_status[i]),
                        fertility_verdict_name(s_cell_status[i]),
                        intake_verdict_name(s_intake_verdict[i]),
                        s_intake_verdict[i] == INTAKE_VERDICT_NORMAL
                            ? "\"NORMAL\"" :
                        s_intake_verdict[i] == INTAKE_VERDICT_ABNORMAL
                            ? "\"ABNORMAL\"" : "null",
                        s_abnormal_slots[i] ? "true" : "false",
                        s_pending_verification_slots[i] ? "true" : "false",
                        cell_confirmed_infertile(i) ? "true" : "false",
                        cell_remove_alert(i) ? "true" : "false",
                        cell_transfer_ready(i) ? "true" : "false",
                        s_slot_fingerprint[i].valid ? "true" : "false");
        if (pos >= (int)resp_sz - 320) {
            ESP_LOGW(TAG, "/get_slots response truncated");
            break;
        }
    }

    pos += snprintf(resp + pos, resp_sz - pos, "]}");
    httpd_resp_set_hdr(req, "Access-Control-Allow-Origin", "*");
    httpd_resp_set_type(req, "application/json");
    esp_err_t send_ret = httpd_resp_sendstr(req, resp);
    free(resp);
    return send_ret;
}

#if ENABLE_DIAGNOSTIC_ALERT_API
typedef enum {
    DIAG_SET_NORMAL = 0,
    DIAG_SET_ABNORMAL,
    DIAG_SET_PENDING,
    DIAG_SET_INFERTILE,
    DIAG_SET_TRANSFER,
} DiagnosticAlertAction;

static bool apply_diagnostic_slot_array(cJSON *root, const char *name,
                                        DiagnosticAlertAction action,
                                        int *changed, const char **error)
{
    cJSON *array = cJSON_GetObjectItemCaseSensitive(root, name);
    if (array == NULL) return true;
    if (!cJSON_IsArray(array)) {
        if (error != NULL) *error = "diagnostic fields must be arrays";
        return false;
    }

    cJSON *item = NULL;
    cJSON_ArrayForEach(item, array) {
        int slot = cJSON_IsNumber(item) ? item->valueint : -1;
        if (slot < 1 || slot > NUM_CELLS) {
            if (error != NULL) *error = "diagnostic slots must be 1..56";
            return false;
        }
        int cell = slot - 1;
        if (!s_cell_has_egg[cell]) continue;

        switch (action) {
            case DIAG_SET_NORMAL:
                set_intake_verdict(cell, INTAKE_VERDICT_NORMAL);
                break;
            case DIAG_SET_ABNORMAL:
                set_intake_verdict(cell, INTAKE_VERDICT_ABNORMAL);
                break;
            case DIAG_SET_PENDING:
                set_intake_verdict(cell, INTAKE_VERDICT_PENDING);
                break;
            case DIAG_SET_INFERTILE:
                s_infertile_slots[cell] = true;
                s_infertile_streak[cell] = INFERTILE_CONFIRM_CANDLINGS;
                if (s_cell_day[cell] < TRUE_ID_DAY) {
                    s_cell_day[cell] = TRUE_ID_DAY;
                    time_t now = time(NULL);
                    if (current_time_is_trusted(now)) {
                        s_cell_start_time[cell] =
                            now - (time_t)TRUE_ID_DAY * 86400;
                    }
                }
                break;
            case DIAG_SET_TRANSFER:
                set_intake_verdict(cell, INTAKE_VERDICT_NORMAL);
                s_cell_day[cell] = TRANSFER_READY_DAY;
                if (current_time_is_trusted(time(NULL))) {
                    s_cell_start_time[cell] =
                        time(NULL) - (time_t)TRANSFER_READY_DAY * 86400;
                }
                break;
        }
        if (changed != NULL) (*changed)++;
    }
    return true;
}

// POST /diagnostic_alerts is a bench-test surface for M6-M9. It never creates
// occupancy; all slot numbers are farmer-facing 1..56. The first injection
// saves a checksum-protected baseline, and {"clear":true} restores it even
// after a reboot. Disable this endpoint for M10.
static esp_err_t diagnostic_alerts_handler(httpd_req_t *req)
{
    StateMutationGuard mutation(req);
    if (!mutation.ready()) return ESP_FAIL;
    if (req->content_len == 0 || req->content_len >= 1024) {
        httpd_resp_send_err(req, HTTPD_400_BAD_REQUEST, "invalid body size");
        return ESP_FAIL;
    }

    char body[1024];
    size_t got = 0;
    while (got < req->content_len) {
        int read = httpd_req_recv(req, body + got, req->content_len - got);
        if (read <= 0) {
            httpd_resp_send_err(req, HTTPD_500_INTERNAL_SERVER_ERROR,
                                "receive failed");
            return ESP_FAIL;
        }
        got += (size_t)read;
    }
    body[got] = '\0';
    cJSON *root = cJSON_Parse(body);
    if (root == NULL) {
        httpd_resp_send_err(req, HTTPD_400_BAD_REQUEST, "invalid json");
        return ESP_FAIL;
    }

    bool clear = cJSON_IsTrue(
        cJSON_GetObjectItemCaseSensitive(root, "clear"));
    bool has_actions =
        cJSON_GetObjectItemCaseSensitive(root, "normal") != NULL ||
        cJSON_GetObjectItemCaseSensitive(root, "pending") != NULL ||
        cJSON_GetObjectItemCaseSensitive(root, "abnormal") != NULL ||
        cJSON_GetObjectItemCaseSensitive(root, "confirmed_infertile") != NULL ||
        cJSON_GetObjectItemCaseSensitive(root, "transfer_ready") != NULL;

    if (clear) {
        if (!diagnostic_backup_restore_and_clear()) {
            cJSON_Delete(root);
            httpd_resp_send_err(req, HTTPD_500_INTERNAL_SERVER_ERROR,
                                "diagnostic baseline restore failed");
            return ESP_FAIL;
        }
        if (!has_actions) {
            cJSON_Delete(root);
            return get_slots_handler(req);
        }
    }

    if (!diagnostic_backup_begin()) {
        cJSON_Delete(root);
        httpd_resp_send_err(req, HTTPD_500_INTERNAL_SERVER_ERROR,
                            "diagnostic baseline save failed");
        return ESP_FAIL;
    }

    EggRuntimeState previous = {};
    runtime_state_capture(&previous);
    int changed = 0;
    const char *error = NULL;
    bool ok = apply_diagnostic_slot_array(
                  root, "normal", DIAG_SET_NORMAL, &changed, &error) &&
              apply_diagnostic_slot_array(
                  root, "pending", DIAG_SET_PENDING, &changed, &error) &&
              apply_diagnostic_slot_array(
                  root, "abnormal", DIAG_SET_ABNORMAL, &changed, &error) &&
              apply_diagnostic_slot_array(
                  root, "confirmed_infertile", DIAG_SET_INFERTILE,
                  &changed, &error) &&
              apply_diagnostic_slot_array(
                  root, "transfer_ready", DIAG_SET_TRANSFER,
                  &changed, &error);
    cJSON_Delete(root);
    if (!ok || (!clear && changed == 0)) {
        runtime_state_restore(&previous);
        httpd_resp_set_hdr(req, "Access-Control-Allow-Origin", "*");
        httpd_resp_send_err(req, HTTPD_400_BAD_REQUEST,
                            error != NULL ? error : "no occupied slots changed");
        return ESP_FAIL;
    }

    refresh_cell_day_status(time(NULL));
    if (!persist_runtime_state_or_restore(req, &previous)) return ESP_FAIL;
    ESP_LOGW(TAG,
             "Diagnostic alert state applied to %d occupied slot(s); disable API before M10",
             changed);
    return get_slots_handler(req);
}
#endif

// POST /set_slots
// {
//   "eggs": [true, false, ...],
//   "placed_at": [1760000000, null, ...],
//   "now_epoch": 1760001234
// }
static esp_err_t set_slots_handler(httpd_req_t *req)
{
    StateMutationGuard mutation(req);
    if (!mutation.ready()) {
        return ESP_FAIL;
    }

    size_t to_read = req->content_len;
    if (to_read >= SET_SLOTS_REQ_BUF_SIZE) {
        httpd_resp_set_hdr(req, "Access-Control-Allow-Origin", "*");
        httpd_resp_send_err(req, HTTPD_400_BAD_REQUEST, "body too large");
        return ESP_FAIL;
    }

    char *buf = (char *)heap_caps_malloc(SET_SLOTS_REQ_BUF_SIZE, MALLOC_CAP_8BIT);
    if (buf == NULL) {
        httpd_resp_set_hdr(req, "Access-Control-Allow-Origin", "*");
        httpd_resp_send_err(req, HTTPD_500_INTERNAL_SERVER_ERROR, "no request memory");
        return ESP_FAIL;
    }

    size_t got = 0;
    while (got < to_read) {
        int r = httpd_req_recv(req, buf + got, to_read - got);
        if (r <= 0) {
            free(buf);
            httpd_resp_set_hdr(req, "Access-Control-Allow-Origin", "*");
            httpd_resp_send_err(req, HTTPD_500_INTERNAL_SERVER_ERROR, "receive failed");
            return ESP_FAIL;
        }
        got += r;
    }
    buf[got] = '\0';

    cJSON *root = cJSON_Parse(buf);
    free(buf);
    if (root == NULL) {
        httpd_resp_set_hdr(req, "Access-Control-Allow-Origin", "*");
        httpd_resp_send_err(req, HTTPD_400_BAD_REQUEST, "invalid json");
        return ESP_FAIL;
    }

    cJSON *eggs = cJSON_GetObjectItemCaseSensitive(root, "eggs");
    if (!cJSON_IsArray(eggs)) {
        cJSON_Delete(root);
        httpd_resp_set_hdr(req, "Access-Control-Allow-Origin", "*");
        httpd_resp_send_err(req, HTTPD_400_BAD_REQUEST, "eggs array required");
        return ESP_FAIL;
    }

    EggRuntimeState previous = {};
    runtime_state_capture(&previous);

    cJSON *placed = cJSON_GetObjectItemCaseSensitive(root, "placed_at");
    if (!cJSON_IsArray(placed)) {
        placed = cJSON_GetObjectItemCaseSensitive(root, "placedAt");
    }
    if (!cJSON_IsArray(placed)) {
        placed = cJSON_GetObjectItemCaseSensitive(root, "start_times");
    }
    if (!cJSON_IsArray(placed)) {
        placed = cJSON_GetObjectItemCaseSensitive(root, "startTimes");
    }

    time_t now = time(NULL);
    long long now_from_app = json_item_epoch_seconds(
        cJSON_GetObjectItemCaseSensitive(root, "now_epoch"), 0);
    if (now_from_app <= 0) {
        now_from_app = json_item_epoch_seconds(
            cJSON_GetObjectItemCaseSensitive(root, "epoch"), 0);
    }
    bool sync_changed = false;
    if (now_from_app >= MIN_TRUSTED_EPOCH && now_from_app < MAX_TRUSTED_EPOCH) {
        sync_changed = previous.last_phone_sync_time != (time_t)now_from_app ||
                       !previous.time_synced_from_phone ||
                       !previous.time_trusted;
        if (!current_time_is_trusted(now) || llabs((long long)now - now_from_app) > 300) {
            struct timeval tv = {
                .tv_sec = (time_t)now_from_app,
                .tv_usec = 0,
            };
            settimeofday(&tv, NULL);
            now = (time_t)now_from_app;
        }
        s_last_phone_sync_time = (time_t)now_from_app;
        s_time_synced_from_phone = true;
        set_time_trust(true, "phone");
    }

    bool changed = false;
    int egg_count = 0;
    int app_claimed = 0;
    int egg_items = cJSON_GetArraySize(eggs);
    int limit = egg_items < NUM_CELLS ? egg_items : NUM_CELLS;

    // CAMERA-AUTHORITATIVE: the AI egg-counter scan is the only source of truth
    // for egg PRESENCE. set_slots carries app metadata (placed_at) only, and may
    // never add or resurrect an egg the camera did not see. Otherwise the app's
    // remembered (yesterday's) eggs merge with the fresh scan.
    for (int i = 0; i < NUM_CELLS; i++) {
        if (i < limit && json_item_bool(cJSON_GetArrayItem(eggs, i), false)) {
            app_claimed++;
        }

        long long placed_epoch = 0;
        if (cJSON_IsArray(placed) && i < cJSON_GetArraySize(placed)) {
            placed_epoch = json_item_epoch_seconds(cJSON_GetArrayItem(placed, i), 0);
        }
        bool placed_valid = placed_epoch > 1700000000LL && placed_epoch < 4102444800LL;

        if (s_cell_has_egg[i]) {
            egg_count++;
            time_t next_start = s_cell_start_time[i];
            if (placed_valid) {
                next_start = (time_t)placed_epoch;
            } else if (next_start == 0) {
                next_start = now;
            }
            if (s_cell_start_time[i] != next_start) {
                changed = true;
            }
            s_cell_start_time[i] = next_start;
        } else {
            if (s_cell_start_time[i] != 0 || s_infertile_slots[i] ||
                s_infertile_streak[i] != 0 || s_abnormal_slots[i] ||
                s_pending_verification_slots[i]) {
                changed = true;
            }
            s_cell_start_time[i] = 0;
            s_infertile_slots[i] = false;
            s_infertile_streak[i] = 0;
            s_abnormal_slots[i] = false;
            s_pending_verification_slots[i] = false;
            s_intake_verdict[i] = INTAKE_VERDICT_NONE;
            memset(&s_slot_fingerprint[i], 0, sizeof(s_slot_fingerprint[i]));
        }
    }

    if (app_claimed != egg_count) {
        ESP_LOGW(TAG,
                 "set_slots ignored app egg presence (app=%d camera=%d); camera scan is authoritative",
                 app_claimed, egg_count);
    }

    cJSON_Delete(root);

    refresh_cell_day_status(now);
    if ((changed || sync_changed) &&
        !persist_runtime_state_or_restore(req, &previous)) {
        return ESP_FAIL;
    }

    ESP_LOGI(TAG, "App slot metadata sync: eggs=%d slots_changed=%s time_changed=%s",
             egg_count, changed ? "yes" : "no", sync_changed ? "yes" : "no");
    return get_slots_handler(req);
}

static bool json_float_array(cJSON *root, const char *name,
                             float *out, int expected_count)
{
    cJSON *arr = cJSON_GetObjectItemCaseSensitive(root, name);
    if (!cJSON_IsArray(arr) || cJSON_GetArraySize(arr) != expected_count) {
        return false;
    }

    for (int i = 0; i < expected_count; i++) {
        cJSON *item = cJSON_GetArrayItem(arr, i);
        if (!cJSON_IsNumber(item)) {
            return false;
        }
        out[i] = (float)item->valuedouble;
    }
    return true;
}

static void append_float_array(char *buf, size_t buf_sz, int *pos,
                               const float *values, int count)
{
    *pos += snprintf(buf + *pos, buf_sz - *pos, "[");
    for (int i = 0; i < count; i++) {
        *pos += snprintf(buf + *pos, buf_sz - *pos,
                         "%s%.3f", (i == 0) ? "" : ",", values[i]);
        if (*pos >= (int)buf_sz) {
            buf[buf_sz - 1] = '\0';
            return;
        }
    }
    *pos += snprintf(buf + *pos, buf_sz - *pos, "]");
}

static esp_err_t send_grid_config_response(httpd_req_t *req, const char *status)
{
    char resp[1024];
    int pos = 0;
    pos += snprintf(resp + pos, sizeof(resp) - pos,
                    "{\"status\":\"%s\",\"ready\":%s,\"cols\":%d,\"rows\":%d,"
                    "\"num_cells\":%d,\"tray_w_cm\":%.3f,\"tray_h_cm\":%.3f,"
                    "\"col_bounds_cm\":",
                    status, s_grid_config_ready ? "true" : "false",
                    s_grid_cols, s_grid_rows,
                    s_grid_cols * s_grid_rows, s_tray_w_cm, s_tray_h_cm);
    append_float_array(resp, sizeof(resp), &pos, s_col_bounds_cm, s_grid_cols + 1);
    pos += snprintf(resp + pos, sizeof(resp) - pos, ",\"row_bounds_cm\":");
    append_float_array(resp, sizeof(resp), &pos, s_row_bounds_cm, s_grid_rows + 1);
    pos += snprintf(resp + pos, sizeof(resp) - pos, "}");

    httpd_resp_set_hdr(req, "Access-Control-Allow-Origin", "*");
    httpd_resp_set_type(req, "application/json");
    httpd_resp_sendstr(req, resp);
    return ESP_OK;
}

// GET /get_grid_config
static esp_err_t get_grid_config_handler(httpd_req_t *req)
{
    return send_grid_config_response(req, s_grid_config_ready ? "ok" : "missing");
}

// POST /grid_config
// {
//   "cols": 8,
//   "rows": 7,
//   "col_bounds_cm": [8.0, 12.0, ... 33.2],
//   "row_bounds_cm": [2.3, 7.9, ... 36.2]
// }
static esp_err_t grid_config_handler(httpd_req_t *req)
{
    StateMutationGuard mutation(req);
    if (!mutation.ready()) {
        return ESP_FAIL;
    }

    char buf[1024];
    size_t to_read = req->content_len;
    if (to_read >= sizeof(buf)) {
        httpd_resp_set_hdr(req, "Access-Control-Allow-Origin", "*");
        httpd_resp_send_err(req, HTTPD_400_BAD_REQUEST, "body too large");
        return ESP_FAIL;
    }

    size_t got = 0;
    while (got < to_read) {
        int r = httpd_req_recv(req, buf + got, to_read - got);
        if (r <= 0) {
            httpd_resp_set_hdr(req, "Access-Control-Allow-Origin", "*");
            httpd_resp_send_err(req, HTTPD_500_INTERNAL_SERVER_ERROR, "receive failed");
            return ESP_FAIL;
        }
        got += r;
    }
    buf[got] = '\0';

    cJSON *root = cJSON_Parse(buf);
    if (root == NULL) {
        httpd_resp_set_hdr(req, "Access-Control-Allow-Origin", "*");
        httpd_resp_send_err(req, HTTPD_400_BAD_REQUEST, "invalid json");
        return ESP_FAIL;
    }

    cJSON *cols_item = cJSON_GetObjectItemCaseSensitive(root, "cols");
    cJSON *rows_item = cJSON_GetObjectItemCaseSensitive(root, "rows");
    int cols = cJSON_IsNumber(cols_item) ? cols_item->valueint : -1;
    int rows = cJSON_IsNumber(rows_item) ? rows_item->valueint : -1;

    float col_bounds[MAX_GRID_COLS + 1] = {};
    float row_bounds[MAX_GRID_ROWS + 1] = {};
    bool ok = cols >= 1 && cols <= MAX_GRID_COLS &&
              rows >= 1 && rows <= MAX_GRID_ROWS &&
              json_float_array(root, "col_bounds_cm", col_bounds, cols + 1) &&
              json_float_array(root, "row_bounds_cm", row_bounds, rows + 1);

    ok = ok && grid_config_valid(cols, rows, col_bounds, row_bounds);
    cJSON_Delete(root);

    if (!ok) {
        httpd_resp_set_hdr(req, "Access-Control-Allow-Origin", "*");
        httpd_resp_send_err(req, HTTPD_400_BAD_REQUEST, "invalid grid config");
        return ESP_FAIL;
    }

    s_grid_cols = cols;
    s_grid_rows = rows;
    s_tray_w_cm = TRAY_W_CM;
    s_tray_h_cm = TRAY_H_CM;
    memset(s_col_bounds_cm, 0, sizeof(s_col_bounds_cm));
    memset(s_row_bounds_cm, 0, sizeof(s_row_bounds_cm));
    memcpy(s_col_bounds_cm, col_bounds, sizeof(float) * (cols + 1));
    memcpy(s_row_bounds_cm, row_bounds, sizeof(float) * (rows + 1));
    s_grid_config_ready = true;
    grid_save_config();

    clear_egg_runtime_data();
    if (!nvs_reset_state_journal() || !nvs_save_snapshots()) {
        s_persistent_state_fault = true;
        httpd_resp_set_hdr(req, "Access-Control-Allow-Origin", "*");
        httpd_resp_send_err(req, HTTPD_500_INTERNAL_SERVER_ERROR,
                            "grid saved but egg state reset failed");
        return ESP_FAIL;
    }

    ESP_LOGI(TAG, "Grid config updated: %dx%d tray=%.1fx%.1fcm",
             s_grid_cols, s_grid_rows, s_tray_w_cm, s_tray_h_cm);
    return send_grid_config_response(req, "saved");
}

// POST /time_sync
// Body from phone:
// {"epoch_ms":1779448200000,"year":2026,"month":5,"day":22,"hour":16,"minute":30,"second":0}
static esp_err_t time_sync_handler(httpd_req_t *req)
{
    StateMutationGuard mutation(req);
    if (!mutation.ready()) {
        return ESP_FAIL;
    }

    char buf[256];
    size_t to_read = req->content_len;
    if (to_read >= sizeof(buf)) {
        httpd_resp_set_hdr(req, "Access-Control-Allow-Origin", "*");
        httpd_resp_send_err(req, HTTPD_400_BAD_REQUEST, "body too large");
        return ESP_FAIL;
    }

    size_t got = 0;
    while (got < to_read) {
        int r = httpd_req_recv(req, buf + got, to_read - got);
        if (r <= 0) {
            httpd_resp_set_hdr(req, "Access-Control-Allow-Origin", "*");
            httpd_resp_send_err(req, HTTPD_500_INTERNAL_SERVER_ERROR, "receive failed");
            return ESP_FAIL;
        }
        got += r;
    }
    buf[got] = '\0';

    cJSON *root = cJSON_Parse(buf);
    if (root == NULL) {
        httpd_resp_set_hdr(req, "Access-Control-Allow-Origin", "*");
        httpd_resp_send_err(req, HTTPD_400_BAD_REQUEST, "invalid json");
        return ESP_FAIL;
    }

    int year = cJSON_IsNumber(cJSON_GetObjectItemCaseSensitive(root, "year")) ?
               cJSON_GetObjectItemCaseSensitive(root, "year")->valueint : -1;
    int month = cJSON_IsNumber(cJSON_GetObjectItemCaseSensitive(root, "month")) ?
                cJSON_GetObjectItemCaseSensitive(root, "month")->valueint : -1;
    int day = cJSON_IsNumber(cJSON_GetObjectItemCaseSensitive(root, "day")) ?
              cJSON_GetObjectItemCaseSensitive(root, "day")->valueint : -1;
    int hour = cJSON_IsNumber(cJSON_GetObjectItemCaseSensitive(root, "hour")) ?
               cJSON_GetObjectItemCaseSensitive(root, "hour")->valueint : -1;
    int minute = cJSON_IsNumber(cJSON_GetObjectItemCaseSensitive(root, "minute")) ?
                 cJSON_GetObjectItemCaseSensitive(root, "minute")->valueint : -1;
    int second = cJSON_IsNumber(cJSON_GetObjectItemCaseSensitive(root, "second")) ?
                 cJSON_GetObjectItemCaseSensitive(root, "second")->valueint : 0;
    long long phone_epoch = json_item_epoch_seconds(
        cJSON_GetObjectItemCaseSensitive(root, "epoch_ms"), 0);
    if (phone_epoch <= 0) {
        phone_epoch = json_item_epoch_seconds(
            cJSON_GetObjectItemCaseSensitive(root, "epoch"), 0);
    }
    if (phone_epoch <= 0) {
        phone_epoch = json_item_epoch_seconds(
            cJSON_GetObjectItemCaseSensitive(root, "now_epoch"), 0);
    }
    cJSON_Delete(root);

    bool epoch_ok = phone_epoch >= MIN_TRUSTED_EPOCH && phone_epoch < MAX_TRUSTED_EPOCH;
    bool fields_ok = year >= 2024 && year <= 2099 &&
                     month >= 1 && month <= 12 &&
                     day >= 1 && day <= 31 &&
                     hour >= 0 && hour <= 23 &&
                     minute >= 0 && minute <= 59 &&
                     second >= 0 && second <= 59;
    bool ok = epoch_ok || fields_ok;
    if (!ok) {
        httpd_resp_set_hdr(req, "Access-Control-Allow-Origin", "*");
        httpd_resp_send_err(req, HTTPD_400_BAD_REQUEST, "invalid time fields");
        return ESP_FAIL;
    }

    struct tm timeinfo = {};
    time_t t = 0;
    if (epoch_ok) {
        t = (time_t)phone_epoch;
        if (localtime_r(&t, &timeinfo) == NULL) {
            httpd_resp_set_hdr(req, "Access-Control-Allow-Origin", "*");
            httpd_resp_send_err(req, HTTPD_400_BAD_REQUEST, "epoch conversion failed");
            return ESP_FAIL;
        }
    } else {
        timeinfo.tm_year = year - 1900;
        timeinfo.tm_mon = month - 1;
        timeinfo.tm_mday = day;
        timeinfo.tm_hour = hour;
        timeinfo.tm_min = minute;
        timeinfo.tm_sec = second;
        timeinfo.tm_isdst = -1;

        t = mktime(&timeinfo);
        if (t == (time_t)-1 || !epoch_is_valid(t)) {
            httpd_resp_set_hdr(req, "Access-Control-Allow-Origin", "*");
            httpd_resp_send_err(req, HTTPD_400_BAD_REQUEST, "time conversion failed");
            return ESP_FAIL;
        }
    }

    EggRuntimeState previous = {};
    runtime_state_capture(&previous);
    struct timeval tv = {
        .tv_sec = t,
        .tv_usec = 0,
    };
    settimeofday(&tv, NULL);

    esp_err_t rtc_ret = rtc_write_time(&timeinfo);
    s_last_phone_sync_time = t;
    s_time_synced_from_phone = true;
    set_time_trust(true, "phone");
    refresh_cell_day_status(t);
    if (!persist_runtime_state_or_restore(req, &previous)) {
        return ESP_FAIL;
    }

    ESP_LOGI(TAG, "Phone time sync: %04d-%02d-%02d %02d:%02d:%02d RTC=%s",
             timeinfo.tm_year + 1900, timeinfo.tm_mon + 1, timeinfo.tm_mday,
             timeinfo.tm_hour, timeinfo.tm_min, timeinfo.tm_sec, esp_err_to_name(rtc_ret));

    char resp[256];
    snprintf(resp, sizeof(resp),
             "{\"status\":\"ok\",\"rtc_written\":%s,\"rtc_result\":\"%s\","
             "\"time_trusted\":true,\"time_source\":\"phone\","
             "\"epoch\":%lld,\"year\":%d,\"month\":%d,\"day\":%d,"
             "\"hour\":%d,\"minute\":%d,\"second\":%d}",
             rtc_ret == ESP_OK ? "true" : "false",
             esp_err_to_name(rtc_ret),
             (long long)t,
             timeinfo.tm_year + 1900, timeinfo.tm_mon + 1, timeinfo.tm_mday,
             timeinfo.tm_hour, timeinfo.tm_min, timeinfo.tm_sec);
    httpd_resp_set_hdr(req, "Access-Control-Allow-Origin", "*");
    httpd_resp_set_type(req, "application/json");
    httpd_resp_sendstr(req, resp);
    return ESP_OK;
}

// POST /reset_grid_config
static esp_err_t reset_grid_config_handler(httpd_req_t *req)
{
    StateMutationGuard mutation(req);
    if (!mutation.ready()) {
        return ESP_FAIL;
    }
    grid_apply_default_config();
    grid_erase_saved_config();
    clear_egg_runtime_data();
    if (!nvs_reset_state_journal() || !nvs_save_snapshots()) {
        s_persistent_state_fault = true;
        httpd_resp_set_hdr(req, "Access-Control-Allow-Origin", "*");
        httpd_resp_send_err(req, HTTPD_500_INTERNAL_SERVER_ERROR,
                            "grid reset state persistence failed");
        return ESP_FAIL;
    }
    ESP_LOGI(TAG, "Custom grid config cleared; restored built-in default grid");
    return send_grid_config_response(req, "default");
}

static const httpd_uri_t s_set_infertile_uri = {
    .uri      = "/set_infertile",
    .method   = HTTP_POST,
    .handler  = set_infertile_handler,
    .user_ctx = NULL
};

static const httpd_uri_t s_set_fertility_results_uri = {
    .uri      = "/set_fertility_results",
    .method   = HTTP_POST,
    .handler  = set_fertility_results_handler,
    .user_ctx = NULL
};

static const httpd_uri_t s_clear_infertile_uri = {
    .uri      = "/clear_infertile",
    .method   = HTTP_POST,
    .handler  = clear_infertile_handler,
    .user_ctx = NULL
};

static const httpd_uri_t s_candling_start_uri = {
    .uri      = "/candling_start",
    .method   = HTTP_GET,
    .handler  = candling_start_handler,
    .user_ctx = NULL
};

static const httpd_uri_t s_candling_start_post_uri = {
    .uri      = "/candling_start",
    .method   = HTTP_POST,
    .handler  = candling_start_handler,
    .user_ctx = NULL
};

static const httpd_uri_t s_candling_stop_uri = {
    .uri      = "/candling_stop",
    .method   = HTTP_GET,
    .handler  = candling_stop_handler,
    .user_ctx = NULL
};

static const httpd_uri_t s_candling_stop_post_uri = {
    .uri      = "/candling_stop",
    .method   = HTTP_POST,
    .handler  = candling_stop_handler,
    .user_ctx = NULL
};

static const httpd_uri_t s_capture_hold_start_uri = {
    .uri      = "/capture_hold_start",
    .method   = HTTP_GET,
    .handler  = capture_hold_start_handler,
    .user_ctx = NULL
};

static const httpd_uri_t s_capture_hold_start_post_uri = {
    .uri      = "/capture_hold_start",
    .method   = HTTP_POST,
    .handler  = capture_hold_start_handler,
    .user_ctx = NULL
};

static const httpd_uri_t s_capture_hold_stop_uri = {
    .uri      = "/capture_hold_stop",
    .method   = HTTP_GET,
    .handler  = capture_hold_stop_handler,
    .user_ctx = NULL
};

static const httpd_uri_t s_capture_hold_stop_post_uri = {
    .uri      = "/capture_hold_stop",
    .method   = HTTP_POST,
    .handler  = capture_hold_stop_handler,
    .user_ctx = NULL
};

static const httpd_uri_t s_camera_focus_uri = {
    .uri      = "/camera_focus",
    .method   = HTTP_GET,
    .handler  = camera_focus_handler,
    .user_ctx = NULL
};

static const httpd_uri_t s_camera_focus_post_uri = {
    .uri      = "/camera_focus",
    .method   = HTTP_POST,
    .handler  = camera_focus_handler,
    .user_ctx = NULL
};

static const httpd_uri_t s_led_test_uri = {
    .uri      = "/led_test",
    .method   = HTTP_GET,
    .handler  = led_test_handler,
    .user_ctx = NULL
};

static const httpd_uri_t s_led_test_post_uri = {
    .uri      = "/led_test",
    .method   = HTTP_POST,
    .handler  = led_test_handler,
    .user_ctx = NULL
};

static const httpd_uri_t s_blink_infertile_uri = {
    .uri      = "/blink_infertile",
    .method   = HTTP_GET,
    .handler  = blink_infertile_handler,
    .user_ctx = NULL
};

static const httpd_uri_t s_blink_infertile_post_uri = {
    .uri      = "/blink_infertile",
    .method   = HTTP_POST,
    .handler  = blink_infertile_handler,
    .user_ctx = NULL
};

static const httpd_uri_t s_get_infertile_uri = {
    .uri      = "/get_infertile",
    .method   = HTTP_GET,
    .handler  = get_infertile_handler,
    .user_ctx = NULL
};

static const httpd_uri_t s_get_infertile_post_uri = {
    .uri      = "/get_infertile",
    .method   = HTTP_POST,
    .handler  = get_infertile_handler,
    .user_ctx = NULL
};

static const httpd_uri_t s_get_slots_uri = {
    .uri      = "/get_slots",
    .method   = HTTP_GET,
    .handler  = get_slots_handler,
    .user_ctx = NULL
};

static const httpd_uri_t s_get_slots_post_uri = {
    .uri      = "/get_slots",
    .method   = HTTP_POST,
    .handler  = get_slots_handler,
    .user_ctx = NULL
};

static const httpd_uri_t s_set_slots_uri = {
    .uri      = "/set_slots",
    .method   = HTTP_POST,
    .handler  = set_slots_handler,
    .user_ctx = NULL
};

#if ENABLE_DIAGNOSTIC_ALERT_API
static const httpd_uri_t s_diagnostic_alerts_uri = {
    .uri      = "/diagnostic_alerts",
    .method   = HTTP_POST,
    .handler  = diagnostic_alerts_handler,
    .user_ctx = NULL
};
#endif

static const httpd_uri_t s_grid_config_uri = {
    .uri      = "/grid_config",
    .method   = HTTP_POST,
    .handler  = grid_config_handler,
    .user_ctx = NULL
};

static const httpd_uri_t s_time_sync_uri = {
    .uri      = "/time_sync",
    .method   = HTTP_POST,
    .handler  = time_sync_handler,
    .user_ctx = NULL
};

static const httpd_uri_t s_get_grid_config_uri = {
    .uri      = "/get_grid_config",
    .method   = HTTP_GET,
    .handler  = get_grid_config_handler,
    .user_ctx = NULL
};

static const httpd_uri_t s_get_grid_config_post_uri = {
    .uri      = "/get_grid_config",
    .method   = HTTP_POST,
    .handler  = get_grid_config_handler,
    .user_ctx = NULL
};

static const httpd_uri_t s_reset_grid_config_uri = {
    .uri      = "/reset_grid_config",
    .method   = HTTP_POST,
    .handler  = reset_grid_config_handler,
    .user_ctx = NULL
};

static void http_server_start(void)
{
    if (s_server) return;  // already running

    httpd_config_t cfg = HTTPD_DEFAULT_CONFIG();
    cfg.stack_size = 12000;
    cfg.max_uri_handlers = 29;

    esp_err_t err = httpd_start(&s_server, &cfg);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "HTTP server start failed: %s", esp_err_to_name(err));
        return;
    }

    httpd_register_uri_handler(s_server, &s_set_infertile_uri);
    httpd_register_uri_handler(s_server, &s_set_fertility_results_uri);
    httpd_register_uri_handler(s_server, &s_clear_infertile_uri);
    httpd_register_uri_handler(s_server, &s_candling_start_uri);
    httpd_register_uri_handler(s_server, &s_candling_start_post_uri);
    httpd_register_uri_handler(s_server, &s_candling_stop_uri);
    httpd_register_uri_handler(s_server, &s_candling_stop_post_uri);
    httpd_register_uri_handler(s_server, &s_capture_hold_start_uri);
    httpd_register_uri_handler(s_server, &s_capture_hold_start_post_uri);
    httpd_register_uri_handler(s_server, &s_capture_hold_stop_uri);
    httpd_register_uri_handler(s_server, &s_capture_hold_stop_post_uri);
    httpd_register_uri_handler(s_server, &s_camera_focus_uri);
    httpd_register_uri_handler(s_server, &s_camera_focus_post_uri);
    httpd_register_uri_handler(s_server, &s_led_test_uri);
    httpd_register_uri_handler(s_server, &s_led_test_post_uri);
    httpd_register_uri_handler(s_server, &s_blink_infertile_uri);
    httpd_register_uri_handler(s_server, &s_blink_infertile_post_uri);
    httpd_register_uri_handler(s_server, &s_get_infertile_uri);
    httpd_register_uri_handler(s_server, &s_get_infertile_post_uri);
    httpd_register_uri_handler(s_server, &s_get_slots_uri);
    httpd_register_uri_handler(s_server, &s_get_slots_post_uri);
    httpd_register_uri_handler(s_server, &s_set_slots_uri);
#if ENABLE_DIAGNOSTIC_ALERT_API
    httpd_register_uri_handler(s_server, &s_diagnostic_alerts_uri);
#endif
    httpd_register_uri_handler(s_server, &s_grid_config_uri);
    httpd_register_uri_handler(s_server, &s_time_sync_uri);
    httpd_register_uri_handler(s_server, &s_get_grid_config_uri);
    httpd_register_uri_handler(s_server, &s_get_grid_config_post_uri);
    httpd_register_uri_handler(s_server, &s_reset_grid_config_uri);
    ESP_LOGI(TAG, "HTTP server started - data/control endpoints accept POST; GET kept for manual tests");
}

// Legacy per-key storage is read once for migration into the versioned journal.
static void nvs_load_legacy_state(void)
{
    if (!s_grid_config_ready) {
        clear_egg_runtime_data();
        ESP_LOGW(TAG, "Snapshot load skipped; no custom grid config is active");
        return;
    }

    nvs_handle_t h;
    if (nvs_open("egg_data", NVS_READONLY, &h) != ESP_OK) {
        ESP_LOGI(TAG, "No existing NVS egg_data - starting fresh");
        return;
    }
    size_t sz;

    sz = sizeof(s_snapshots);
    nvs_get_blob(h, "snapshots", s_snapshots, &sz);

    int32_t v = 0;
    if (nvs_get_i32(h, "snap_count", &v) == ESP_OK) {
        s_snapshot_count = (int)v;
    }
    if (s_snapshot_count < 0 || s_snapshot_count > MAX_SNAPSHOTS) {
        ESP_LOGW(TAG, "Invalid NVS snapshot count %d; resetting", s_snapshot_count);
        s_snapshot_count = 0;
    }

    v = -1;
    if (nvs_get_i32(h, "last_mday", &v) == ESP_OK) {
        s_last_scan_mday = (int)v;
    }
    if (s_last_scan_mday < 1 || s_last_scan_mday > 31) {
        s_last_scan_mday = -1;
    }

    int64_t phone_sync = 0;
    if (nvs_get_i64(h, "phone_sync", &phone_sync) == ESP_OK && phone_sync > 0) {
        s_last_phone_sync_time = (time_t)phone_sync;
        s_time_synced_from_phone = true;
    }

    sz = sizeof(s_cell_has_egg);
    bool loaded_cell_eggs = nvs_get_blob(h, "cell_eggs", s_cell_has_egg, &sz) == ESP_OK;

    int latest_index = -1;
    time_t latest_time = 0;
    if (s_snapshot_count > 0 && s_snapshot_count <= MAX_SNAPSHOTS) {
        for (int i = 0; i < s_snapshot_count; i++) {
            if (!s_snapshots[i].valid) {
                continue;
            }
            if (latest_index < 0 || s_snapshots[i].scan_time >= latest_time) {
                latest_index = i;
                latest_time = s_snapshots[i].scan_time;
            }
        }
    }

    if (!loaded_cell_eggs && latest_index >= 0) {
        EggSnapshot *latest = &s_snapshots[latest_index];
        memcpy(s_cell_has_egg, latest->cell_has_egg, sizeof(s_cell_has_egg));
    }
    if (loaded_cell_eggs || latest_index >= 0) {
        int restored_count = 0;
        for (int i = 0; i < NUM_CELLS; i++) {
            if (s_cell_has_egg[i]) restored_count++;
        }
        s_last_egg_count = restored_count;
        // A valid snapshot proves that even an all-empty restored tray is a
        // completed scan rather than an uninitialized grid.
        s_scan_valid = latest_index >= 0;
    }

    sz = sizeof(s_cell_start_time);
    nvs_get_blob(h, "start_times", s_cell_start_time, &sz);

    sz = sizeof(s_cell_day);
    nvs_get_blob(h, "cell_days", s_cell_day, &sz);

    sz = sizeof(s_cell_status);
    nvs_get_blob(h, "cell_status", s_cell_status, &sz);

    sz = sizeof(s_infertile_slots);
    nvs_get_blob(h, "infertile", s_infertile_slots, &sz);

    nvs_close(h);
    validate_time_against_stored_state("rtc");
    refresh_cell_day_status(time(NULL));
    ESP_LOGI(TAG, "NVS loaded - snapshots:%d last_mday:%d time_trusted=%s source=%s",
             s_snapshot_count, s_last_scan_mday,
             s_time_trusted ? "true" : "false", s_time_source);
}

static uint32_t nvs_fnv1a_update(uint32_t hash, const uint8_t *data, size_t len)
{
    for (size_t i = 0; i < len; i++) {
        hash ^= data[i];
        hash *= 16777619u;
    }
    return hash;
}

static void *psram_buffer_calloc(size_t size, const char *purpose)
{
    void *buffer = heap_caps_calloc(
        1, size, MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
    if (buffer == NULL) {
        buffer = heap_caps_calloc(1, size, MALLOC_CAP_8BIT);
    }
    if (buffer == NULL) {
        ESP_LOGE(TAG, "Cannot allocate %zu-byte %s buffer",
                 size, purpose != NULL ? purpose : "work");
    }
    return buffer;
}

static uint32_t nvs_checksum_with_zero_field(const void *record, size_t record_size,
                                             size_t checksum_offset)
{
    const uint8_t *bytes = (const uint8_t *)record;
    const uint8_t zero[sizeof(uint32_t)] = {};
    uint32_t hash = 2166136261u;
    hash = nvs_fnv1a_update(hash, bytes, checksum_offset);
    hash = nvs_fnv1a_update(hash, zero, sizeof(zero));
    return nvs_fnv1a_update(hash,
                            bytes + checksum_offset + sizeof(uint32_t),
                            record_size - checksum_offset - sizeof(uint32_t));
}

static uint32_t egg_state_checksum(const EggStateRecord *record)
{
    return nvs_checksum_with_zero_field(record, sizeof(*record),
                                        offsetof(EggStateRecord, checksum));
}

static uint32_t egg_state_v1_checksum(const EggStateRecordV1 *record)
{
    return nvs_checksum_with_zero_field(record, sizeof(*record),
                                        offsetof(EggStateRecordV1, checksum));
}

static uint32_t egg_scan_transaction_checksum(const EggScanTransaction *transaction)
{
    return nvs_checksum_with_zero_field(transaction, sizeof(*transaction),
                                        offsetof(EggScanTransaction, checksum));
}

static bool egg_runtime_state_valid(const EggRuntimeState *state)
{
    if (state == NULL || state->snapshot_count < 0 ||
        state->snapshot_count > MAX_SNAPSHOTS || state->last_egg_count < 0 ||
        state->last_egg_count > NUM_CELLS || state->last_scan_mday < -1 ||
        state->last_scan_mday > 31) {
        return false;
    }

    int eggs = 0;
    for (int i = 0; i < NUM_CELLS; i++) {
        if (state->cell_day[i] < 0 || state->cell_day[i] > 10000 ||
            state->cell_status[i] > CELL_STATUS_INFERTILE ||
            state->intake_verdict[i] > INTAKE_VERDICT_PENDING ||
            state->cell_start_time[i] < 0 ||
            state->cell_start_time[i] >= MAX_TRUSTED_EPOCH) {
            return false;
        }
        if (state->cell_has_egg[i]) {
            eggs++;
        } else if (state->cell_start_time[i] != 0 || state->cell_day[i] != 0 ||
                   state->cell_status[i] != CELL_STATUS_NO_EGG ||
                   state->cell_alert[i] || state->infertile_slots[i] ||
                   state->infertile_streak[i] != 0 || state->abnormal_slots[i] ||
                   state->pending_verification_slots[i] ||
                   state->intake_verdict[i] != INTAKE_VERDICT_NONE ||
                   state->slot_fingerprint[i].valid) {
            return false;
        }
    }
    return eggs == state->last_egg_count;
}

#if ENABLE_DIAGNOSTIC_ALERT_API
static uint32_t diagnostic_backup_checksum(
    const DiagnosticStateBackup *backup)
{
    return nvs_checksum_with_zero_field(
        backup, sizeof(*backup),
        offsetof(DiagnosticStateBackup, checksum));
}

static bool diagnostic_backup_read(DiagnosticStateBackup *backup)
{
    if (backup == NULL) return false;
    nvs_handle_t h;
    if (nvs_open("egg_data", NVS_READONLY, &h) != ESP_OK) return false;
    size_t size = sizeof(*backup);
    esp_err_t ret = nvs_get_blob(h, "diag_backup", backup, &size);
    nvs_close(h);
    return ret == ESP_OK && size == sizeof(*backup) &&
           backup->magic == DIAGNOSTIC_BACKUP_MAGIC &&
           backup->version == DIAGNOSTIC_BACKUP_VERSION &&
           backup->checksum == diagnostic_backup_checksum(backup) &&
           egg_runtime_state_valid(&backup->state);
}

static bool diagnostic_backup_erase(void)
{
    nvs_handle_t h;
    if (nvs_open("egg_data", NVS_READWRITE, &h) != ESP_OK) return false;
    esp_err_t ret = nvs_erase_key(h, "diag_backup");
    if (ret == ESP_ERR_NVS_NOT_FOUND) ret = ESP_OK;
    if (ret == ESP_OK) ret = nvs_commit(h);
    nvs_close(h);
    if (ret == ESP_OK) s_diagnostic_session_active = false;
    return ret == ESP_OK;
}

static bool diagnostic_backup_begin(void)
{
    DiagnosticStateBackup existing = {};
    if (diagnostic_backup_read(&existing)) {
        s_diagnostic_session_active = true;
        return true;
    }

    DiagnosticStateBackup backup = {};
    backup.magic = DIAGNOSTIC_BACKUP_MAGIC;
    backup.version = DIAGNOSTIC_BACKUP_VERSION;
    runtime_state_capture(&backup.state);
    if (!egg_runtime_state_valid(&backup.state)) {
        ESP_LOGE(TAG, "Refusing diagnostic session: baseline state is invalid");
        return false;
    }
    backup.checksum = diagnostic_backup_checksum(&backup);

    nvs_handle_t h;
    if (nvs_open("egg_data", NVS_READWRITE, &h) != ESP_OK) return false;
    esp_err_t ret = nvs_set_blob(h, "diag_backup", &backup, sizeof(backup));
    if (ret == ESP_OK) ret = nvs_commit(h);
    nvs_close(h);
    if (ret != ESP_OK) {
        ESP_LOGE(TAG, "Diagnostic baseline save failed: %s",
                 esp_err_to_name(ret));
        return false;
    }
    s_diagnostic_session_active = true;
    ESP_LOGW(TAG, "Diagnostic baseline saved; clear restores real egg state");
    return true;
}

static bool diagnostic_backup_restore_and_clear(void)
{
    DiagnosticStateBackup backup = {};
    if (!diagnostic_backup_read(&backup)) {
        s_diagnostic_session_active = false;
        ESP_LOGI(TAG, "No diagnostic baseline is active");
        return true;
    }

    EggRuntimeState injected = {};
    runtime_state_capture(&injected);
    runtime_state_restore(&backup.state);
    refresh_cell_day_status(time(NULL));
    if (!nvs_save_snapshots()) {
        runtime_state_restore(&injected);
        ESP_LOGE(TAG, "Diagnostic baseline restore could not be committed");
        return false;
    }
    if (!diagnostic_backup_erase()) {
        ESP_LOGE(TAG, "Diagnostic state restored, but backup cleanup failed");
        return false;
    }
    ESP_LOGW(TAG, "Diagnostic alerts cleared; real egg state restored");
    return true;
}

static void diagnostic_backup_boot_check(void)
{
    DiagnosticStateBackup backup = {};
    s_diagnostic_session_active = diagnostic_backup_read(&backup);
    if (s_diagnostic_session_active) {
        ESP_LOGW(TAG,
                 "Diagnostic alert session is active; POST clear=true to restore the saved real egg state");
    }
}
#endif

static void runtime_state_migrate_v1(const EggRuntimeStateV1 *legacy,
                                     EggRuntimeState *state)
{
    memset(state, 0, sizeof(*state));
    memcpy(state->cell_has_egg, legacy->cell_has_egg,
           sizeof(state->cell_has_egg));
    memcpy(state->cell_start_time, legacy->cell_start_time,
           sizeof(state->cell_start_time));
    memcpy(state->cell_day, legacy->cell_day, sizeof(state->cell_day));
    memcpy(state->cell_status, legacy->cell_status,
           sizeof(state->cell_status));
    memcpy(state->cell_alert, legacy->cell_alert, sizeof(state->cell_alert));
    memcpy(state->infertile_slots, legacy->infertile_slots,
           sizeof(state->infertile_slots));
    memcpy(state->infertile_streak, legacy->infertile_streak,
           sizeof(state->infertile_streak));
    memcpy(state->abnormal_slots, legacy->abnormal_slots,
           sizeof(state->abnormal_slots));
    memcpy(state->pending_verification_slots,
           legacy->pending_verification_slots,
           sizeof(state->pending_verification_slots));
    memcpy(state->snapshots, legacy->snapshots, sizeof(state->snapshots));
    state->snapshot_count = legacy->snapshot_count;
    state->last_scan_mday = legacy->last_scan_mday;
    state->last_egg_count = legacy->last_egg_count;
    state->scan_valid = legacy->scan_valid;
    state->last_phone_sync_time = legacy->last_phone_sync_time;
    state->time_synced_from_phone = legacy->time_synced_from_phone;
    state->time_trusted = legacy->time_trusted;
    memcpy(state->time_source, legacy->time_source,
           sizeof(state->time_source));

    for (int i = 0; i < NUM_CELLS; i++) {
        if (!state->cell_has_egg[i]) {
            state->intake_verdict[i] = INTAKE_VERDICT_NONE;
        } else if (state->abnormal_slots[i]) {
            state->intake_verdict[i] = INTAKE_VERDICT_ABNORMAL;
        } else {
            // Schema v1 had no decisive NORMAL state or fingerprint. Recheck
            // occupied eggs on the next closed-door scan.
            state->intake_verdict[i] = INTAKE_VERDICT_PENDING;
            state->pending_verification_slots[i] = true;
        }
    }
}

static bool egg_state_v1_record_valid(const EggStateRecordV1 *record,
                                      EggRuntimeState *migrated)
{
    if (record == NULL || migrated == NULL ||
        record->magic != EGG_STATE_MAGIC || record->schema_version != 1u ||
        record->record_size != sizeof(EggStateRecordV1) ||
        record->checksum != egg_state_v1_checksum(record)) {
        return false;
    }
    runtime_state_migrate_v1(&record->state, migrated);
    return egg_runtime_state_valid(migrated);
}

static bool egg_state_record_valid(const EggStateRecord *record)
{
    return record != NULL && record->magic == EGG_STATE_MAGIC &&
           record->schema_version == EGG_STATE_SCHEMA_VERSION &&
           record->record_size == sizeof(EggStateRecord) &&
           record->checksum == egg_state_checksum(record) &&
           egg_runtime_state_valid(&record->state);
}

static bool egg_scan_transaction_valid(const EggScanTransaction *transaction)
{
    return transaction != NULL && transaction->magic == EGG_STATE_TXN_MAGIC &&
           transaction->schema_version == EGG_STATE_SCHEMA_VERSION &&
           transaction->record_size == sizeof(EggScanTransaction) &&
           transaction->checksum == egg_scan_transaction_checksum(transaction);
}

static void egg_state_record_build(EggStateRecord *record, uint32_t generation)
{
    memset(record, 0, sizeof(*record));
    record->magic = EGG_STATE_MAGIC;
    record->schema_version = EGG_STATE_SCHEMA_VERSION;
    record->record_size = sizeof(EggStateRecord);
    record->generation = generation;
    runtime_state_capture(&record->state);
    record->checksum = egg_state_checksum(record);
}

static bool nvs_state_slot_load(nvs_handle_t h, const char *key,
                                EggStateRecord *record, bool *present)
{
    size_t size = sizeof(*record);
    esp_err_t err = nvs_get_blob(h, key, record, &size);
    if (present != NULL) {
        *present = err != ESP_ERR_NVS_NOT_FOUND;
    }
    if (err != ESP_OK) {
        if (err != ESP_ERR_NVS_NOT_FOUND) {
            ESP_LOGW(TAG, "NVS %s read failed: %s", key, esp_err_to_name(err));
        }
        return false;
    }
    if (size != sizeof(*record) || !egg_state_record_valid(record)) {
        ESP_LOGE(TAG, "NVS %s is an invalid or incompatible state record", key);
        return false;
    }
    return true;
}

static bool nvs_state_v1_slot_load(nvs_handle_t h, const char *key,
                                   EggStateRecordV1 *record,
                                   EggRuntimeState *migrated,
                                   bool *present)
{
    size_t size = sizeof(*record);
    esp_err_t err = nvs_get_blob(h, key, record, &size);
    if (present != NULL) *present = err != ESP_ERR_NVS_NOT_FOUND;
    if (err != ESP_OK) return false;
    if (size != sizeof(*record) ||
        !egg_state_v1_record_valid(record, migrated)) {
        ESP_LOGE(TAG, "NVS %s is an invalid schema-v1 record", key);
        return false;
    }
    return true;
}

static bool nvs_transaction_load(nvs_handle_t h, EggScanTransaction *transaction,
                                 bool *present)
{
    size_t size = sizeof(*transaction);
    esp_err_t err = nvs_get_blob(h, EGG_STATE_TXN_KEY, transaction, &size);
    if (present != NULL) {
        *present = err != ESP_ERR_NVS_NOT_FOUND;
    }
    if (err != ESP_OK) {
        return false;
    }
    return size == sizeof(*transaction) && egg_scan_transaction_valid(transaction);
}

static bool nvs_transaction_erase(nvs_handle_t h)
{
    esp_err_t err = nvs_erase_key(h, EGG_STATE_TXN_KEY);
    if (err != ESP_OK && err != ESP_ERR_NVS_NOT_FOUND) {
        ESP_LOGW(TAG, "NVS transaction erase failed: %s", esp_err_to_name(err));
        return false;
    }
    err = nvs_commit(h);
    if (err != ESP_OK) {
        ESP_LOGW(TAG, "NVS transaction commit failed: %s", esp_err_to_name(err));
        return false;
    }
    return true;
}

static bool nvs_reset_state_journal(void)
{
    static const char *const state_keys[] = {
        EGG_STATE_KEY_A,
        EGG_STATE_KEY_B,
        EGG_STATE_TXN_KEY,
        EGG_STATE_V1_KEY_A,
        EGG_STATE_V1_KEY_B,
        EGG_STATE_V1_TXN_KEY,
        "snapshots",
        "snap_count",
        "last_mday",
        "cell_eggs",
        "start_times",
        "cell_days",
        "cell_status",
        "infertile",
    };

    nvs_handle_t h;
    esp_err_t err = nvs_open("egg_data", NVS_READWRITE, &h);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "Cannot open NVS for state reset: %s", esp_err_to_name(err));
        return false;
    }

    bool ok = true;
    for (size_t i = 0; i < sizeof(state_keys) / sizeof(state_keys[0]); i++) {
        err = nvs_erase_key(h, state_keys[i]);
        if (err != ESP_OK && err != ESP_ERR_NVS_NOT_FOUND) {
            ESP_LOGE(TAG, "Cannot erase NVS state key %s: %s",
                     state_keys[i], esp_err_to_name(err));
            ok = false;
        }
    }
    err = nvs_commit(h);
    nvs_close(h);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "NVS state reset commit failed: %s", esp_err_to_name(err));
        ok = false;
    }
    if (!ok) {
        return false;
    }

    s_nvs_state_generation = 0;
    s_nvs_state_active_slot = -1;
    s_nvs_scan_transaction_active = false;
    s_scan_recovery_incomplete = false;
    s_persistent_state_fault = false;
    ESP_LOGI(TAG, "NVS state journal reset; next commit starts generation 1");
    return true;
}

static bool nvs_save_snapshots(void)
{
    if (s_persistent_state_fault) {
        ESP_LOGE(TAG, "NVS state save blocked: recovery is required");
        return false;
    }

    uint32_t next_generation = s_nvs_state_generation + 1;
    if (next_generation == 0) next_generation = 1;
    EggStateRecord *record = (EggStateRecord *)psram_buffer_calloc(
        sizeof(EggStateRecord), "NVS save");
    if (record == NULL) {
        return false;
    }
    egg_state_record_build(record, next_generation);

    int target_slot = s_nvs_state_active_slot == 0 ? 1 : 0;
    const char *target_key = target_slot == 0 ? EGG_STATE_KEY_A : EGG_STATE_KEY_B;
    nvs_handle_t h;
    esp_err_t err = nvs_open("egg_data", NVS_READWRITE, &h);
    if (err != ESP_OK) {
        ESP_LOGW(TAG, "NVS open failed (save state): %s", esp_err_to_name(err));
        heap_caps_free(record);
        return false;
    }
    err = nvs_set_blob(h, target_key, record, sizeof(*record));
    if (err == ESP_OK) err = nvs_commit(h);
    nvs_close(h);
    heap_caps_free(record);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "NVS state save failed: %s", esp_err_to_name(err));
        return false;
    }

    s_nvs_state_generation = next_generation;
    s_nvs_state_active_slot = target_slot;
    ESP_LOGI(TAG, "NVS committed state gen=%lu slot=%c eggs=%d",
             (unsigned long)s_nvs_state_generation,
             target_slot == 0 ? 'A' : 'B', s_last_egg_count);
    return true;
}

static bool nvs_scan_transaction_begin(void)
{
    if (s_persistent_state_fault) {
        ESP_LOGE(TAG, "Scan transaction blocked: persistent state recovery required");
        return false;
    }
    if (s_nvs_scan_transaction_active) return true;

    EggScanTransaction transaction = {};
    transaction.magic = EGG_STATE_TXN_MAGIC;
    transaction.schema_version = EGG_STATE_SCHEMA_VERSION;
    transaction.record_size = sizeof(EggScanTransaction);
    transaction.base_generation = s_nvs_state_generation;
    transaction.checksum = egg_scan_transaction_checksum(&transaction);

    nvs_handle_t h;
    esp_err_t err = nvs_open("egg_data", NVS_READWRITE, &h);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "Cannot open NVS for scan transaction: %s", esp_err_to_name(err));
        return false;
    }
    err = nvs_set_blob(h, EGG_STATE_TXN_KEY, &transaction, sizeof(transaction));
    if (err == ESP_OK) err = nvs_commit(h);
    nvs_close(h);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "Cannot persist scan transaction marker: %s", esp_err_to_name(err));
        return false;
    }

    s_nvs_scan_transaction_active = true;
    ESP_LOGI(TAG, "Scan transaction started from generation %lu",
             (unsigned long)transaction.base_generation);
    return true;
}

static void nvs_scan_transaction_abort(void)
{
    if (!s_nvs_scan_transaction_active) return;
    nvs_handle_t h;
    if (nvs_open("egg_data", NVS_READWRITE, &h) == ESP_OK) {
        nvs_transaction_erase(h);
        nvs_close(h);
    }
    s_nvs_scan_transaction_active = false;
}

static void nvs_scan_transaction_commit_complete(void)
{
    nvs_scan_transaction_abort();
}

static bool nvs_blob_exists(nvs_handle_t h, const char *key)
{
    size_t size = 0;
    return nvs_get_blob(h, key, NULL, &size) == ESP_OK;
}

static void nvs_load_snapshots(void)
{
    clear_egg_runtime_data();
    s_persistent_state_fault = false;
    s_scan_recovery_incomplete = false;
    s_nvs_scan_transaction_active = false;
    s_nvs_state_generation = 0;
    s_nvs_state_active_slot = -1;

    if (!s_grid_config_ready) {
        ESP_LOGW(TAG, "Snapshot load skipped; no grid config is active");
        return;
    }

    EggStateLoadScratch *scratch =
        (EggStateLoadScratch *)psram_buffer_calloc(
            sizeof(EggStateLoadScratch), "NVS load");
    if (scratch == NULL) {
        s_persistent_state_fault = true;
        return;
    }

    nvs_handle_t h;
    esp_err_t err = nvs_open("egg_data", NVS_READWRITE, &h);
    if (err != ESP_OK) {
        s_persistent_state_fault = true;
        ESP_LOGE(TAG, "NVS unavailable; state recovery required: %s",
                 esp_err_to_name(err));
        heap_caps_free(scratch);
        return;
    }

    EggStateRecord &state_a = scratch->state_a;
    EggStateRecord &state_b = scratch->state_b;
    bool key_a_present = false;
    bool key_b_present = false;
    bool valid_a = nvs_state_slot_load(h, EGG_STATE_KEY_A, &state_a, &key_a_present);
    bool valid_b = nvs_state_slot_load(h, EGG_STATE_KEY_B, &state_b, &key_b_present);
    bool journal_loaded = valid_a || valid_b;
    bool state_loaded = journal_loaded;
    bool v1_migration_pending = false;
    if (journal_loaded) {
        const EggStateRecord *selected = &state_a;
        int selected_slot = 0;
        if (!valid_a || (valid_b && state_b.generation > state_a.generation)) {
            selected = &state_b;
            selected_slot = 1;
        }
        runtime_state_restore(&selected->state);
        s_nvs_state_generation = selected->generation;
        s_nvs_state_active_slot = selected_slot;
        ESP_LOGI(TAG, "Loaded committed NVS state gen=%lu slot=%c",
                 (unsigned long)s_nvs_state_generation,
                 selected_slot == 0 ? 'A' : 'B');
    } else if (key_a_present || key_b_present) {
        // Legacy keys may be stale after journal creation, so never resurrect
        // them when both current records are invalid.
        s_persistent_state_fault = true;
        ESP_LOGE(TAG, "No valid NVS journal record remains; recovery required");
    }

    if (!state_loaded && !key_a_present && !key_b_present) {
        EggStateRecordV1 &v1_a = scratch->v1_a;
        EggStateRecordV1 &v1_b = scratch->v1_b;
        EggRuntimeState &migrated_a = scratch->migrated_a;
        EggRuntimeState &migrated_b = scratch->migrated_b;
        bool v1_a_present = false;
        bool v1_b_present = false;
        bool v1_valid_a = nvs_state_v1_slot_load(
            h, EGG_STATE_V1_KEY_A, &v1_a, &migrated_a, &v1_a_present);
        bool v1_valid_b = nvs_state_v1_slot_load(
            h, EGG_STATE_V1_KEY_B, &v1_b, &migrated_b, &v1_b_present);
        if (v1_valid_a || v1_valid_b) {
            const EggRuntimeState *selected_state = &migrated_a;
            uint32_t selected_generation = v1_a.generation;
            if (!v1_valid_a ||
                (v1_valid_b && v1_b.generation > v1_a.generation)) {
                selected_state = &migrated_b;
                selected_generation = v1_b.generation;
            }
            runtime_state_restore(selected_state);
            s_nvs_state_generation = selected_generation;
            s_nvs_state_active_slot = -1;
            state_loaded = true;
            v1_migration_pending = true;
            ESP_LOGI(TAG,
                     "Loaded schema-v1 state gen=%lu; migration to v2 pending",
                     (unsigned long)selected_generation);
        } else if (v1_a_present || v1_b_present) {
            s_persistent_state_fault = true;
            ESP_LOGE(TAG,
                     "No valid schema-v1 record remains; recovery required");
        }

        if (nvs_blob_exists(h, EGG_STATE_V1_TXN_KEY)) {
            s_scan_recovery_incomplete = true;
            nvs_erase_key(h, EGG_STATE_V1_TXN_KEY);
            nvs_commit(h);
            ESP_LOGW(TAG,
                     "Recovered interrupted schema-v1 scan; last committed state retained");
        }
    }

    EggScanTransaction transaction = {};
    bool transaction_present = false;
    bool transaction_valid = nvs_transaction_load(h, &transaction, &transaction_present);
    if (transaction_present) {
        s_scan_recovery_incomplete = !transaction_valid || !state_loaded ||
                                     s_nvs_state_generation <= transaction.base_generation;
        ESP_LOGW(TAG, "%s scan transaction; committed generation %lu retained",
                 s_scan_recovery_incomplete ? "Recovered incomplete" : "Cleared completed",
                 (unsigned long)s_nvs_state_generation);
        nvs_transaction_erase(h);
    }

    bool legacy_present = !state_loaded && !key_a_present && !key_b_present &&
                          (nvs_blob_exists(h, "cell_eggs") ||
                           nvs_blob_exists(h, "snapshots"));
    nvs_close(h);
    heap_caps_free(scratch);

    if (v1_migration_pending && !s_persistent_state_fault) {
        refresh_cell_day_status(time(NULL));
        if (!nvs_save_snapshots()) {
            s_persistent_state_fault = true;
            ESP_LOGE(TAG, "Schema-v1 migration into schema v2 failed");
        } else {
            ESP_LOGI(TAG, "Migrated NVS schema v1 into schema v2");
        }
    } else if (legacy_present && !s_persistent_state_fault) {
        nvs_load_legacy_state();
        for (int i = 0; i < NUM_CELLS; i++) {
            if (s_cell_has_egg[i]) {
                set_intake_verdict(i, INTAKE_VERDICT_PENDING);
            }
        }
        refresh_cell_day_status(time(NULL));
        if (!nvs_save_snapshots()) {
            s_persistent_state_fault = true;
            ESP_LOGE(TAG, "Legacy state migration into schema v%d failed",
                     EGG_STATE_SCHEMA_VERSION);
        } else {
            ESP_LOGI(TAG, "Migrated legacy state into NVS schema v%d",
                     EGG_STATE_SCHEMA_VERSION);
        }
    } else if (!state_loaded && !legacy_present && !s_persistent_state_fault) {
        ESP_LOGI(TAG, "No existing egg state - starting fresh");
    }

    validate_time_against_stored_state("rtc");
    refresh_cell_day_status(time(NULL));
    ESP_LOGI(TAG, "NVS state gen=%lu eggs=%d scan_valid=%s recovery=%s fault=%s",
             (unsigned long)s_nvs_state_generation, s_last_egg_count,
             s_scan_valid ? "true" : "false",
             s_scan_recovery_incomplete ? "incomplete" : "none",
             s_persistent_state_fault ? "required" : "none");
}

// Rolling snapshot logic. Keep only the latest MAX_SNAPSHOTS records.
static bool add_egg_snapshot(void)
{
    EggSnapshot snap = {};
    snap.valid      = true;
    snap.scan_time  = time(NULL);
    snap.egg_count  = s_last_egg_count;
    memcpy(snap.cell_has_egg,    s_cell_has_egg,    sizeof(s_cell_has_egg));
    memcpy(snap.cell_start_time, s_cell_start_time, sizeof(s_cell_start_time));
    memcpy(snap.cell_day,        s_cell_day,        sizeof(s_cell_day));
    memcpy(snap.cell_status,     s_cell_status,     sizeof(s_cell_status));
    memcpy(snap.cell_infertile,  s_infertile_slots, sizeof(s_infertile_slots));

    bool evicted_oldest = false;
    if (s_snapshot_count < MAX_SNAPSHOTS) {
        s_snapshot_count++;
    } else {
        evicted_oldest = true;
    }

#if MAX_SNAPSHOTS > 1
    // Shift older records down so slot 0 always holds the newest.
    for (int i = s_snapshot_count - 1; i > 0; i--) {
        s_snapshots[i] = s_snapshots[i - 1];
    }
#endif
    s_snapshots[0] = snap;  // newest completed scan is always at index 0
    if (evicted_oldest) {
        ESP_LOGI(TAG, "[SNAP] Stored present scan; older record overwritten (kept %d)",
                 s_snapshot_count);
    } else {
        ESP_LOGI(TAG, "[SNAP] Stored present scan; records:%d", s_snapshot_count);
    }

    if (!nvs_save_snapshots()) {
        ESP_LOGE(TAG, "[SNAP] New scan was not committed to NVS");
        return false;
    }
    return true;
}

// WiFi event handler
static void wifi_event_handler(void *arg, esp_event_base_t base,
                                 int32_t id, void *data)
{
    if (base == WIFI_EVENT && id == WIFI_EVENT_STA_START) {
        esp_wifi_connect();
    } else if (base == WIFI_EVENT && id == WIFI_EVENT_STA_DISCONNECTED) {
        xEventGroupClearBits(s_wifi_eg, WIFI_CONNECTED_BIT);
        xEventGroupSetBits(s_wifi_eg, WIFI_FAIL_BIT);
    } else if (base == IP_EVENT && id == IP_EVENT_STA_GOT_IP) {
        ip_event_got_ip_t *e = (ip_event_got_ip_t *)data;
        ESP_LOGI(TAG, "Got IP: " IPSTR, IP2STR(&e->ip_info.ip));
        xEventGroupSetBits(s_wifi_eg, WIFI_CONNECTED_BIT);
    }
}

static void wifi_init(void)
{
    s_wifi_eg = xEventGroupCreate();
    ESP_ERROR_CHECK(esp_netif_init());
    ESP_ERROR_CHECK(esp_event_loop_create_default());
    esp_netif_t *sta_netif = esp_netif_create_default_wifi_sta();
    if (sta_netif == NULL) {
        ESP_LOGE(TAG, "Failed to create WiFi STA netif");
        return;
    }

    esp_err_t dhcp_ret = esp_netif_dhcpc_stop(sta_netif);
    if (dhcp_ret != ESP_OK) {
        ESP_LOGW(TAG, "DHCP client stop returned: %s", esp_err_to_name(dhcp_ret));
    }
    esp_netif_ip_info_t ip_info = {};
    IP4_ADDR(&ip_info.ip, 192, 168, 4, P4_STATIC_IP_OCTET_4);
    IP4_ADDR(&ip_info.gw, 192, 168, 4, 1);
    IP4_ADDR(&ip_info.netmask, 255, 255, 255, 0);
    ESP_ERROR_CHECK(esp_netif_set_ip_info(sta_netif, &ip_info));
    ESP_LOGI(TAG, "P4 static IP set to 192.168.4.%d", P4_STATIC_IP_OCTET_4);

    wifi_init_config_t cfg = WIFI_INIT_CONFIG_DEFAULT();
    ESP_ERROR_CHECK(esp_wifi_init(&cfg));
    ESP_ERROR_CHECK(esp_event_handler_instance_register(
        WIFI_EVENT, ESP_EVENT_ANY_ID, &wifi_event_handler, NULL, NULL));
    ESP_ERROR_CHECK(esp_event_handler_instance_register(
        IP_EVENT, IP_EVENT_STA_GOT_IP, &wifi_event_handler, NULL, NULL));

    wifi_config_t wc = {};
    strlcpy((char *)wc.sta.ssid,     WIFI_SSID,     sizeof(wc.sta.ssid));
    strlcpy((char *)wc.sta.password, WIFI_PASSWORD,  sizeof(wc.sta.password));
    wc.sta.threshold.authmode = WIFI_AUTH_WPA2_PSK;

    ESP_ERROR_CHECK(esp_wifi_set_mode(WIFI_MODE_STA));
    ESP_ERROR_CHECK(esp_wifi_set_config(WIFI_IF_STA, &wc));
    ESP_ERROR_CHECK(esp_wifi_start());
}

static esp_err_t wifi_connect(void)
{
    EventBits_t current = xEventGroupGetBits(s_wifi_eg);
    if (current & WIFI_CONNECTED_BIT) {
        return ESP_OK;
    }

    xEventGroupClearBits(s_wifi_eg, WIFI_FAIL_BIT);
    esp_err_t err = esp_wifi_connect();
    if (err != ESP_OK && err != ESP_ERR_WIFI_CONN) {
        ESP_LOGW(TAG, "esp_wifi_connect failed: %s", esp_err_to_name(err));
    }

    EventBits_t bits = xEventGroupWaitBits(
        s_wifi_eg, WIFI_CONNECTED_BIT | WIFI_FAIL_BIT,
        pdFALSE, pdFALSE, pdMS_TO_TICKS(10000));
    return (bits & WIFI_CONNECTED_BIT) ? ESP_OK : ESP_FAIL;
}

static bool s3_server_reachable(void)
{
    esp_http_client_config_t cfg = {};
    cfg.url = S3_HEALTH_URL;
    cfg.method = HTTP_METHOD_GET;
    cfg.timeout_ms = S3_HEALTH_TIMEOUT_MS;
    cfg.buffer_size = 512;

    esp_http_client_handle_t client = esp_http_client_init(&cfg);
    if (client == NULL) {
        ESP_LOGW(TAG, "S3 readiness probe could not create HTTP client");
        return false;
    }

    esp_err_t err = esp_http_client_perform(client);
    int status = esp_http_client_get_status_code(client);
    esp_http_client_cleanup(client);

    bool reachable = err == ESP_OK && status >= 200 && status < 300;
    if (reachable) {
        ESP_LOGI(TAG, "S3 camera host ready, HTTP=%d", status);
    } else {
        ESP_LOGW(TAG, "S3 camera host unavailable: %s HTTP=%d",
                 esp_err_to_name(err), status);
    }
    return reachable;
}

// HTTP capture
struct HttpBuf { uint8_t *data; size_t len; size_t cap; };

static esp_err_t http_evt(esp_http_client_event_t *evt)
{
    HttpBuf *b = (HttpBuf *)evt->user_data;
    if (evt->event_id == HTTP_EVENT_ON_DATA && evt->data_len > 0) {
        if (b->len + evt->data_len > b->cap) return ESP_FAIL;
        memcpy(b->data + b->len, evt->data, evt->data_len);
        b->len += evt->data_len;
        esp_task_wdt_reset();
    }
    return ESP_OK;
}

static bool jpeg_has_complete_markers(const uint8_t *buf, size_t len)
{
    if (buf == NULL || len < 4 || buf[0] != 0xFF || buf[1] != 0xD8) {
        return false;
    }
    for (size_t i = len - 1; i > 0; i--) {
        if (buf[i - 1] == 0xFF && buf[i] == 0xD9) {
            return true;
        }
    }
    return false;
}

static esp_err_t capture_jpeg_from_url(
    const char *url, const char *label,
    uint8_t *buf, size_t cap, size_t *out_len,
    ScanFailureReason *failure_reason)
{
    if (url == NULL || label == NULL ||
        buf == NULL || out_len == NULL || cap == 0) {
        return ESP_ERR_INVALID_ARG;
    }
    *out_len = 0;
    if (failure_reason != NULL) *failure_reason = SCAN_FAIL_CAPTURE;

    HttpBuf b = {buf, 0, cap};
    esp_http_client_config_t cfg = {};
    cfg.url            = url;
    cfg.timeout_ms     = CAPTURE_HTTP_TIMEOUT_MS;
    cfg.event_handler  = http_evt;
    cfg.user_data      = &b;
    cfg.buffer_size    = 4096;
    cfg.buffer_size_tx = 1024;

    esp_http_client_handle_t client = esp_http_client_init(&cfg);
    if (!client) {
        if (failure_reason != NULL) *failure_reason = SCAN_FAIL_MEMORY;
        return ESP_ERR_NO_MEM;
    }

    ESP_LOGI(TAG, "Requesting %s; waiting up to %d ms",
             label, CAPTURE_HTTP_TIMEOUT_MS);
    esp_err_t err = esp_http_client_perform(client);
    int status = esp_http_client_get_status_code(client);
    esp_http_client_cleanup(client);

    if (err == ESP_OK && status == 200 && b.len == 0) {
        ESP_LOGE(TAG, "%s returned no image bytes", label);
        if (failure_reason != NULL) *failure_reason = SCAN_FAIL_NO_IMAGE;
        return ESP_ERR_INVALID_SIZE;
    }

    if (err == ESP_OK && status == 200 && b.len > 0 &&
        !jpeg_has_complete_markers(buf, b.len)) {
        ESP_LOGE(TAG, "%s returned an incomplete/corrupt JPEG (%zu bytes)",
                 label, b.len);
        memset(buf, 0, b.len);
        if (failure_reason != NULL) *failure_reason = SCAN_FAIL_IMAGE_CORRUPT;
        return ESP_ERR_INVALID_CRC;
    }

    if (err == ESP_OK && status == 200 && b.len > 0) {
        *out_len = b.len;
        if (failure_reason != NULL) *failure_reason = SCAN_FAIL_NONE;
        ESP_LOGI(TAG, "%s downloaded and validated: %zu bytes", label, b.len);
        return ESP_OK;
    }

    ESP_LOGE(TAG, "%s failed: %s status=%d len=%zu",
             label, esp_err_to_name(err), status, b.len);
    if (b.len > 0) memset(buf, 0, b.len);
    if (failure_reason != NULL && err != ESP_OK && status <= 0) {
        *failure_reason = SCAN_FAIL_S3_OFFLINE;
    }
    return ESP_FAIL;
}

static esp_err_t capture_jpeg(uint8_t *buf, size_t cap, size_t *out_len,
                               ScanFailureReason *failure_reason)
{
    return capture_jpeg_from_url(
        CAPTURE_URL, "/capturep4",
        buf, cap, out_len, failure_reason);
}

// JPEG to RGB888
static esp_err_t jpeg_to_rgb888(const uint8_t *jpg, size_t jpg_len,
                                 uint8_t **rgb_out, uint32_t *w, uint32_t *h)
{
    if (jpg == NULL || jpg_len == 0 || rgb_out == NULL || w == NULL || h == NULL) {
        return ESP_ERR_INVALID_ARG;
    }
    *rgb_out = NULL;
    *w = 0;
    *h = 0;

    jpeg_decode_engine_cfg_t ecfg = {};
    ecfg.intr_priority = 0;
    ecfg.timeout_ms    = 30000;

    jpeg_decoder_handle_t dec = NULL;
    esp_err_t ret = jpeg_new_decoder_engine(&ecfg, &dec);
    if (ret != ESP_OK || dec == NULL) {
        ESP_LOGE(TAG, "JPEG decoder init failed: %s", esp_err_to_name(ret));
        return ret == ESP_OK ? ESP_FAIL : ret;
    }

    jpeg_decode_picture_info_t info = {};
    ret = jpeg_decoder_get_info(jpg, jpg_len, &info);
    if (ret != ESP_OK || info.width == 0 || info.height == 0 ||
        info.width > 8192 || info.height > 8192) {
        ESP_LOGE(TAG, "JPEG header invalid: %s %lux%lu",
                 esp_err_to_name(ret),
                 (unsigned long)info.width, (unsigned long)info.height);
        jpeg_del_decoder_engine(dec);
        return ret == ESP_OK ? ESP_ERR_INVALID_SIZE : ret;
    }
    *w = info.width;
    *h = info.height;

    jpeg_decode_memory_alloc_cfg_t mcfg = {};
    mcfg.buffer_direction = JPEG_DEC_ALLOC_OUTPUT_BUFFER;
    size_t alloc_sz = 0;
    *rgb_out = (uint8_t *)jpeg_alloc_decoder_mem(
        (size_t)(*w) * (*h) * 3, &mcfg, &alloc_sz);
    if (!*rgb_out) { jpeg_del_decoder_engine(dec); return ESP_ERR_NO_MEM; }

    jpeg_decode_cfg_t dcfg = {};
    dcfg.output_format = JPEG_DECODE_OUT_FORMAT_RGB888;
    dcfg.rgb_order     = JPEG_DEC_RGB_ELEMENT_ORDER_RGB;
    dcfg.conv_std      = JPEG_YUV_RGB_CONV_STD_BT601;

    uint32_t decoded_len = 0;
    ret = jpeg_decoder_process(
        dec, &dcfg, (uint8_t *)jpg, jpg_len, *rgb_out, alloc_sz, &decoded_len);
    jpeg_del_decoder_engine(dec);
    if (ret != ESP_OK) { heap_caps_free(*rgb_out); *rgb_out = NULL; }
    return ret;
}

// Letterbox (src to dw x dh with padding)
static uint8_t *letterbox(const uint8_t *src,
                           uint32_t sw, uint32_t sh,
                           uint32_t dw, uint32_t dh)
{
    uint8_t *dst = (uint8_t *)heap_caps_calloc(
        dw * dh * 3, 1, MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
    if (!dst) return NULL;

    float scale = fminf((float)dw / sw, (float)dh / sh);
    uint32_t nw = (uint32_t)(sw * scale);
    uint32_t nh = (uint32_t)(sh * scale);
    uint32_t ox = (dw - nw) / 2;
    uint32_t oy = (dh - nh) / 2;

    for (uint32_t dy = 0; dy < nh; dy++) {
        uint32_t sy = (uint32_t)(dy / scale);
        if (sy >= sh) sy = sh - 1;
        for (uint32_t dx = 0; dx < nw; dx++) {
            uint32_t sx = (uint32_t)(dx / scale);
            if (sx >= sw) sx = sw - 1;
            const uint8_t *sp = src + (sy * sw + sx) * 3;
            uint8_t *dp       = dst + ((oy + dy) * dw + (ox + dx)) * 3;
            dp[0] = sp[0]; dp[1] = sp[1]; dp[2] = sp[2];
        }
    }
    return dst;
}

// IoU calculation
static float det_iou(const Detection &a, const Detection &b)
{
    float ix1 = fmaxf(a.x, b.x), iy1 = fmaxf(a.y, b.y);
    float ix2 = fminf(a.x + a.w, b.x + b.w);
    float iy2 = fminf(a.y + a.h, b.y + b.h);
    float inter = fmaxf(0, ix2 - ix1) * fmaxf(0, iy2 - iy1);
    float ua    = a.w * a.h + b.w * b.h - inter;
    return ua > 0 ? inter / ua : 0;
}

static float tensor_value_at(const TfLiteTensor *out, int index)
{
    if (out->type == kTfLiteFloat32) {
        return out->data.f[index];
    }
    if (out->type == kTfLiteInt8) {
        return (out->data.int8[index] - out->params.zero_point) * out->params.scale;
    }
    if (out->type == kTfLiteUInt8) {
        return (out->data.uint8[index] - out->params.zero_point) * out->params.scale;
    }
    return 0.0f;
}

static float yolo_value_at(const TfLiteTensor *out, int index)
{
    return tensor_value_at(out, index);
}

// Parse YOLOv5 output and apply NMS
static int parse_and_nms(const TfLiteTensor *out, Detection *dets)
{
    static Detection *raw = NULL;
    static bool      *suppressed = NULL;
    if (raw == NULL) {
        raw = (Detection *)heap_caps_malloc(
            MAX_DETS * sizeof(Detection), MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
    }
    if (suppressed == NULL) {
        suppressed = (bool *)heap_caps_malloc(
            MAX_DETS * sizeof(bool), MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
    }
    if (raw == NULL || suppressed == NULL) {
        ESP_LOGE(TAG, "Detection work buffer alloc failed");
        return -1;
    }
    memset(suppressed, 0, MAX_DETS * sizeof(bool));
    int raw_count = 0;

    if (out->dims->size != 3) {
        ESP_LOGE(TAG, "Invalid output dims: %d", out->dims->size);
        return 0;
    }
    int num_dets = out->dims->data[1];
    int det_size = out->dims->data[2];
    if (det_size < 6) {
        ESP_LOGE(TAG, "Invalid detection size: %d", det_size);
        return 0;
    }
    int num_classes = det_size - 5;
    float best_seen_conf = 0.0f;
    float best_seen_obj = 0.0f;
    float best_seen_cls = 0.0f;
    int best_seen_class = -1;

    for (int i = 0; i < num_dets && raw_count < MAX_DETS; i++) {
        if (out->type != kTfLiteFloat32 &&
            out->type != kTfLiteInt8 &&
            out->type != kTfLiteUInt8) {
            ESP_LOGE(TAG, "Unsupported tensor type: %d", out->type);
            return 0;
        }

        int base = i * det_size;
        float obj_conf = yolo_value_at(out, base + 4);
        float cls_conf = 0.0f;
        int cls_id = 0;
        for (int c = 0; c < num_classes; c++) {
            float score = yolo_value_at(out, base + 5 + c);
            if (score > cls_conf) {
                cls_conf = score;
                cls_id = c;
            }
        }
        float conf = obj_conf * cls_conf;
        if (conf > best_seen_conf) {
            best_seen_conf = conf;
            best_seen_obj = obj_conf;
            best_seen_cls = cls_conf;
            best_seen_class = cls_id;
        }
        if (conf < CONF_THRESH) continue;

        Detection det;
        float cx = yolo_value_at(out, base + 0);
        float cy = yolo_value_at(out, base + 1);
        float w = yolo_value_at(out, base + 2);
        float h = yolo_value_at(out, base + 3);
        det.x = cx - w / 2.0f;
        det.y = cy - h / 2.0f;
        det.w = w;
        det.h = h;
        det.conf = conf;
        det.cls = cls_id;
        raw[raw_count++] = det;
    }

    ESP_LOGI(TAG, "YOLO raw above %.2f: %d, best seen conf=%.3f obj=%.3f cls=%.3f class=%d",
             CONF_THRESH, raw_count, best_seen_conf, best_seen_obj,
             best_seen_cls, best_seen_class);

    int kept_count = 0;
    for (int i = 0; i < raw_count; i++) {
        if (suppressed[i]) continue;
        dets[kept_count++] = raw[i];
        for (int j = i + 1; j < raw_count; j++) {
            if (!suppressed[j] && det_iou(raw[i], raw[j]) > IOU_THRESH)
                suppressed[j] = true;
        }
    }
    return kept_count;
}

static void complete_cell_scan(int total)
{
    s_last_egg_count = total;
    s_scan_valid     = true;

    // Update per-slot day counters and status.
    time_t now = time(NULL);
    bool trusted = current_time_is_trusted(now);
    for (int i = 0; i < NUM_CELLS; i++) {
        if (s_cell_has_egg[i]) {
            // ADDITIVE MERGE (last data vs new scan): if this slot was already
            // known to hold an egg in the previous (NVS-persisted) snapshot,
            // inherit its original placement time so a fresh scan after a reboot
            // never resets the date of an egg that is already there. This only
            // fills in a missing (0) date and never overwrites an existing one.
            if (s_cell_start_time[i] == 0 &&
                s_snapshot_count > 0 && s_snapshots[0].valid &&
                s_snapshots[0].cell_has_egg[i] &&
                s_snapshots[0].cell_start_time[i] > 0) {
                s_cell_start_time[i] = s_snapshots[0].cell_start_time[i];
            }
            if (s_cell_start_time[i] == 0 && trusted) {
                s_cell_start_time[i] = now;  // genuinely new egg
            }
            if (trusted && s_cell_start_time[i] > 0) {
                s_cell_day[i] = cell_elapsed_days(now, s_cell_start_time[i]);
            }
            s_cell_status[i] = resolve_cell_status(
                true, s_cell_day[i], s_infertile_slots[i], s_cell_status[i]);
            s_cell_alert[i] = (s_cell_day[i] >= TRUE_ID_DAY);
            // A committed count scan confirms occupancy, not fertility. Keep
            // existing farmer warnings until a committed scan confirms that
            // the egg was removed or a later verification clears them.
        } else {
            s_cell_start_time[i] = 0;
            s_cell_day[i] = 0;
            s_cell_status[i] = CELL_STATUS_NO_EGG;
            s_cell_alert[i] = false;
            s_infertile_slots[i] = false;
            s_infertile_streak[i] = 0;
            s_abnormal_slots[i] = false;
            s_pending_verification_slots[i] = false;
            s_intake_verdict[i] = INTAKE_VERDICT_NONE;
            memset(&s_slot_fingerprint[i], 0, sizeof(s_slot_fingerprint[i]));
        }
    }
    if (!trusted && total > 0) {
        ESP_LOGW(TAG, "Egg scan saved with untrusted clock; placed_at/day will recover after app time sync");
    }

    ESP_LOGI(TAG, "Egg grid (N=no egg E=egg):");
    for (int r = 0; r < s_grid_rows; r++) {
        char line[GRID_COLS * 2 + 2];
        int  pos = 0;
        for (int c = 0; c < s_grid_cols; c++) {
            uint8_t status = s_cell_status[r * s_grid_cols + c];
            char marker = 'N';
            if (status != CELL_STATUS_NO_EGG) marker = 'E';
            line[pos++] = marker;
            line[pos++] = ' ';
        }
        line[pos] = '\0';
        ESP_LOGI(TAG, "  Row %d: %s", r, line);
    }
    ESP_LOGI(TAG, "Total eggs: %d / %d", total, NUM_CELLS);
}

static const char *classifier_class_name(int cls)
{
    switch (cls) {
    case CLS_EGG_PRESENT_IDX:
        return "egg_present";
    case CLS_NOT_EGG_IDX:
        return "not_egg";
    case CLS_SLOT_REFERENCE_IDX:
        return "slot_reference";
    default:
        return "unknown";
    }
}

static int classifier_class_count(const TfLiteTensor *out)
{
    if (out == NULL || out->dims == NULL) {
        return 0;
    }
    if (out->dims->size == 2 && out->dims->data[0] == 1) {
        return out->dims->data[1];
    }
    if (out->dims->size == 1) {
        return out->dims->data[0];
    }
    return 0;
}

static esp_err_t fill_model_input_from_crop(const uint8_t *rgb,
                                            uint32_t img_w, uint32_t img_h,
                                            int crop_x0, int crop_y0,
                                            int crop_x1, int crop_y1)
{
    if (rgb == NULL || s_interp == NULL || img_w == 0 || img_h == 0) {
        return ESP_ERR_INVALID_ARG;
    }

    TfLiteTensor *in = s_interp->input(0);
    if (in == NULL || s_model_input_w <= 0 || s_model_input_h <= 0 ||
        s_model_input_c != MODEL_INPUT_C) {
        return ESP_ERR_INVALID_STATE;
    }

    if (crop_x0 < 0) crop_x0 = 0;
    if (crop_y0 < 0) crop_y0 = 0;
    if (crop_x1 > (int)img_w) crop_x1 = (int)img_w;
    if (crop_y1 > (int)img_h) crop_y1 = (int)img_h;
    if (crop_x1 <= crop_x0 || crop_y1 <= crop_y0) {
        return ESP_ERR_INVALID_ARG;
    }

    const int crop_w = crop_x1 - crop_x0;
    const int crop_h = crop_y1 - crop_y0;
    const size_t npix = (size_t)s_model_input_w * s_model_input_h * MODEL_INPUT_C;

    if (in->type == kTfLiteFloat32) {
        if (in->bytes < npix * sizeof(float)) {
            return ESP_ERR_INVALID_SIZE;
        }
        float *dst = in->data.f;
        for (int y = 0; y < s_model_input_h; y++) {
            int sy = crop_y0 + (int)(((float)y + 0.5f) * crop_h / s_model_input_h);
            if (sy >= crop_y1) sy = crop_y1 - 1;
            for (int x = 0; x < s_model_input_w; x++) {
                int sx = crop_x0 + (int)(((float)x + 0.5f) * crop_w / s_model_input_w);
                if (sx >= crop_x1) sx = crop_x1 - 1;
                const uint8_t *sp = rgb + ((uint32_t)sy * img_w + (uint32_t)sx) * MODEL_INPUT_C;
                size_t di = ((size_t)y * s_model_input_w + (size_t)x) * MODEL_INPUT_C;
                dst[di + 0] = sp[0] / 255.0f;
                dst[di + 1] = sp[1] / 255.0f;
                dst[di + 2] = sp[2] / 255.0f;
            }
        }
    } else if (in->type == kTfLiteInt8) {
        if (in->bytes < npix || in->params.scale <= 0.0f) {
            return ESP_ERR_INVALID_SIZE;
        }
        int8_t *dst = in->data.int8;
        float sc = in->params.scale;
        int zp = in->params.zero_point;
        for (int y = 0; y < s_model_input_h; y++) {
            int sy = crop_y0 + (int)(((float)y + 0.5f) * crop_h / s_model_input_h);
            if (sy >= crop_y1) sy = crop_y1 - 1;
            for (int x = 0; x < s_model_input_w; x++) {
                int sx = crop_x0 + (int)(((float)x + 0.5f) * crop_w / s_model_input_w);
                if (sx >= crop_x1) sx = crop_x1 - 1;
                const uint8_t *sp = rgb + ((uint32_t)sy * img_w + (uint32_t)sx) * MODEL_INPUT_C;
                size_t di = ((size_t)y * s_model_input_w + (size_t)x) * MODEL_INPUT_C;
                for (int ch = 0; ch < MODEL_INPUT_C; ch++) {
                    float real = sp[ch] / 255.0f;
                    int v = zp + (int)lroundf(real / sc);
                    dst[di + ch] = (int8_t)(v > 127 ? 127 : v < -128 ? -128 : v);
                }
            }
        }
    } else if (in->type == kTfLiteUInt8) {
        if (in->bytes < npix || in->params.scale <= 0.0f) {
            return ESP_ERR_INVALID_SIZE;
        }
        uint8_t *dst = in->data.uint8;
        float sc = in->params.scale;
        int zp = in->params.zero_point;
        for (int y = 0; y < s_model_input_h; y++) {
            int sy = crop_y0 + (int)(((float)y + 0.5f) * crop_h / s_model_input_h);
            if (sy >= crop_y1) sy = crop_y1 - 1;
            for (int x = 0; x < s_model_input_w; x++) {
                int sx = crop_x0 + (int)(((float)x + 0.5f) * crop_w / s_model_input_w);
                if (sx >= crop_x1) sx = crop_x1 - 1;
                const uint8_t *sp = rgb + ((uint32_t)sy * img_w + (uint32_t)sx) * MODEL_INPUT_C;
                size_t di = ((size_t)y * s_model_input_w + (size_t)x) * MODEL_INPUT_C;
                for (int ch = 0; ch < MODEL_INPUT_C; ch++) {
                    float real = sp[ch] / 255.0f;
                    int v = zp + (int)lroundf(real / sc);
                    dst[di + ch] = (uint8_t)(v > 255 ? 255 : v < 0 ? 0 : v);
                }
            }
        }
    } else {
        ESP_LOGE(TAG, "Unsupported input tensor type: %d", in->type);
        return ESP_ERR_NOT_SUPPORTED;
    }

    return ESP_OK;
}

static esp_err_t run_classifier_on_crop(const uint8_t *rgb,
                                        uint32_t img_w, uint32_t img_h,
                                        int crop_x0, int crop_y0,
                                        int crop_x1, int crop_y1,
                                        int cell_idx, int row, int col,
                                        bool *has_egg_out)
{
    if (has_egg_out == NULL) return ESP_ERR_INVALID_ARG;
    *has_egg_out = false;
    if (s_scan_deadline_expired) return ESP_ERR_TIMEOUT;
    esp_err_t prep = fill_model_input_from_crop(
        rgb, img_w, img_h, crop_x0, crop_y0, crop_x1, crop_y1);
    if (prep != ESP_OK) {
        ESP_LOGE(TAG, "Cell %d input prep failed: %s",
                 cell_idx, esp_err_to_name(prep));
        return prep;
    }

    int64_t t0 = esp_timer_get_time();
    if (s_interp->Invoke() != kTfLiteOk) {
        ESP_LOGE(TAG, "Cell %d Invoke() failed", cell_idx);
        return ESP_FAIL;
    }
    if (s_scan_deadline_expired) return ESP_ERR_TIMEOUT;

    TfLiteTensor *out = s_interp->output(0);
    int class_count = classifier_class_count(out);
    if (class_count <= CLS_NOT_EGG_IDX) {
        ESP_LOGE(TAG, "Classifier output class count invalid: %d", class_count);
        return ESP_ERR_INVALID_RESPONSE;
    }

    int top_class = -1;
    float top_score = -FLT_MAX;
    for (int cls = 0; cls < class_count; cls++) {
        float score = tensor_value_at(out, cls);
        if (score > top_score) {
            top_score = score;
            top_class = cls;
        }
    }

    float egg_score = tensor_value_at(out, CLS_EGG_PRESENT_IDX);
    float not_egg_score = tensor_value_at(out, CLS_NOT_EGG_IDX);
    float ref_score = (class_count > CLS_SLOT_REFERENCE_IDX) ?
                      tensor_value_at(out, CLS_SLOT_REFERENCE_IDX) : 0.0f;
    float nearest_negative = fmaxf(not_egg_score, ref_score);
    float egg_margin = egg_score - nearest_negative;
    bool has_egg = (top_class == CLS_EGG_PRESENT_IDX &&
                    egg_score >= CLS_EGG_CONF_THRESH &&
                    egg_margin >= CLS_EGG_MARGIN_THRESH);

    ESP_LOGI(TAG,
             "Cell %02d r%d c%d crop=(%d,%d)-(%d,%d) scores egg=%.3f not_egg=%.3f ref=%.3f margin=%.3f top=%s %.3f -> %s (%lld ms)",
             cell_idx, row, col, crop_x0, crop_y0, crop_x1, crop_y1,
             egg_score, not_egg_score, ref_score, egg_margin,
             classifier_class_name(top_class), top_score,
             has_egg ? "EGG" : "empty",
             (esp_timer_get_time() - t0) / 1000);

    *has_egg_out = has_egg;
    return ESP_OK;
}

typedef struct {
    int idx;
    int row;
    int col;
    int x0;
    int y0;
    int x1;
    int y1;
    float mean;
    float stddev;
    float center_mean;
    float border_mean;
    float center_delta;
    float bright_frac;
    float run_x_frac;
    float run_y_frac;
    float blob_score;
    float blob_threshold;
    float neutral_frac;
    float blue_ratio;
    float score;
} CropCandidate;

// The ranked/cell candidate tables consume about 9 KB. Keeping them in
// classify_grid_cells() left too little of egg_task's stack for TFLite and
// float-formatted diagnostics, so the whole scan workspace lives off-stack.
typedef struct {
    bool candidate_cells[NUM_CELLS];
#if CLASSIFIER_DEBUG_USE_PREFILTER
    bool classify_cell[NUM_CELLS];
    bool heuristic_egg[NUM_CELLS];
    CropCandidate cell_stats[NUM_CELLS];
    CropCandidate ranked[NUM_CELLS];
#if !CLASSIFIER_DEBUG_RUN_MODEL
    float heuristic_delta[NUM_CELLS];
    float heuristic_center[NUM_CELLS];
    bool suppressed[NUM_CELLS];
    float accepted_x[NUM_CELLS];
    float accepted_y[NUM_CELLS];
#endif
#endif
} GridClassifierScratch;

struct GridClassifierScratchGuard {
    GridClassifierScratch *scratch;

    explicit GridClassifierScratchGuard(GridClassifierScratch *value)
        : scratch(value) {}

    ~GridClassifierScratchGuard(void)
    {
        if (scratch != NULL) {
            heap_caps_free(scratch);
        }
    }

    GridClassifierScratchGuard(const GridClassifierScratchGuard &) = delete;
    GridClassifierScratchGuard &operator=(const GridClassifierScratchGuard &) = delete;
};

static uint8_t quantize_u8(float value)
{
    int rounded = (int)lroundf(value);
    return (uint8_t)(rounded < 0 ? 0 : rounded > 255 ? 255 : rounded);
}

static int8_t quantize_s8(float value)
{
    int rounded = (int)lroundf(value);
    return (int8_t)(rounded < -128 ? -128 : rounded > 127 ? 127 : rounded);
}

static SlotFingerprint fingerprint_from_candidate(const CropCandidate *cand)
{
    SlotFingerprint fingerprint = {};
    if (cand == NULL) return fingerprint;
    fingerprint.mean = quantize_u8(cand->mean);
    fingerprint.stddev = quantize_u8(cand->stddev);
    fingerprint.center_delta = quantize_s8(cand->center_delta);
    fingerprint.blob_score = quantize_u8(cand->blob_score);
    fingerprint.neutral_frac = quantize_u8(cand->neutral_frac * 255.0f);
    fingerprint.blue_ratio = quantize_u8(cand->blue_ratio * 255.0f);
    fingerprint.valid = true;
    return fingerprint;
}

static bool fingerprint_likely_replacement(const SlotFingerprint *previous,
                                           const SlotFingerprint *current)
{
    if (previous == NULL || current == NULL ||
        !previous->valid || !current->valid) {
        return false;
    }

    int differences[] = {
        abs((int)previous->mean - (int)current->mean),
        abs((int)previous->stddev - (int)current->stddev),
        abs((int)previous->center_delta - (int)current->center_delta),
        abs((int)previous->blob_score - (int)current->blob_score),
        abs((int)previous->neutral_frac - (int)current->neutral_frac),
        abs((int)previous->blue_ratio - (int)current->blue_ratio),
    };
    const int thresholds[] = {24, 18, 30, 30, 64, 51};
    int major_changes = 0;
    int normalized_total = 0;
    for (size_t i = 0; i < sizeof(differences) / sizeof(differences[0]); i++) {
        if (differences[i] >= thresholds[i]) major_changes++;
        normalized_total += differences[i] * 20 / thresholds[i];
    }
    // Require agreement from multiple features. Illumination drift in one
    // channel must not erase an existing farmer warning.
    return major_changes >= 2 && normalized_total >= 55;
}

static int clamp_int(int value, int min_value, int max_value)
{
    if (value < min_value) return min_value;
    if (value > max_value) return max_value;
    return value;
}

static float crop_luma_at(const uint8_t *rgb, uint32_t img_w, int x, int y)
{
    const uint8_t *p = rgb + ((uint32_t)y * img_w + (uint32_t)x) * MODEL_INPUT_C;
    return (77.0f * p[0] + 150.0f * p[1] + 29.0f * p[2]) / 256.0f;
}

static void crop_rgb_at(const uint8_t *rgb, uint32_t img_w, int x, int y,
                        float *r, float *g, float *b)
{
    const uint8_t *p = rgb + ((uint32_t)y * img_w + (uint32_t)x) * MODEL_INPUT_C;
    if (r) *r = (float)p[0];
    if (g) *g = (float)p[1];
    if (b) *b = (float)p[2];
}

static CropCandidate build_crop_candidate(const uint8_t *rgb,
                                          uint32_t img_w, uint32_t img_h,
                                          int idx, int row, int col,
                                          int x0, int y0, int x1, int y1)
{
    CropCandidate cand = {};
    cand.idx = idx;
    cand.row = row;
    cand.col = col;
    cand.x0 = clamp_int(x0, 0, (int)img_w - 1);
    cand.y0 = clamp_int(y0, 0, (int)img_h - 1);
    cand.x1 = clamp_int(x1, cand.x0 + 1, (int)img_w);
    cand.y1 = clamp_int(y1, cand.y0 + 1, (int)img_h);

    const int w = cand.x1 - cand.x0;
    const int h = cand.y1 - cand.y0;
    const int cx0 = cand.x0 + w / 4;
    const int cx1 = cand.x0 + (w * 3) / 4;
    const int cy0 = cand.y0 + h / 4;
    const int cy1 = cand.y0 + (h * 3) / 4;

    float sum = 0.0f;
    float sum_sq = 0.0f;
    float center_sum = 0.0f;
    float border_sum = 0.0f;
    int count = 0;
    int center_count = 0;
    int border_count = 0;

    for (int y = cand.y0; y < cand.y1; y += CLASSIFIER_DEBUG_SAMPLE_STEP) {
        for (int x = cand.x0; x < cand.x1; x += CLASSIFIER_DEBUG_SAMPLE_STEP) {
            float luma = crop_luma_at(rgb, img_w, x, y);
            sum += luma;
            sum_sq += luma * luma;
            count++;
            if (x >= cx0 && x < cx1 && y >= cy0 && y < cy1) {
                center_sum += luma;
                center_count++;
            } else {
                border_sum += luma;
                border_count++;
            }
        }
    }

    if (count > 0) {
        cand.mean = sum / count;
        float variance = (sum_sq / count) - cand.mean * cand.mean;
        cand.stddev = sqrtf(fmaxf(0.0f, variance));
    }
    if (center_count > 0 && border_count > 0) {
        cand.center_mean = center_sum / center_count;
        cand.border_mean = border_sum / border_count;
        cand.center_delta = cand.center_mean - cand.border_mean;
    }

    int blob_step = HEURISTIC_CENTROID_SAMPLE_STEP > 0 ? HEURISTIC_CENTROID_SAMPLE_STEP : 1;
    int sample_cols = (w + blob_step - 1) / blob_step;
    while (sample_cols > HEURISTIC_BLOB_MAX_SAMPLE_COLS) {
        blob_step++;
        sample_cols = (w + blob_step - 1) / blob_step;
    }

    int col_runs[HEURISTIC_BLOB_MAX_SAMPLE_COLS] = {};
    int max_run_x = 0;
    int max_run_y = 0;
    int bright_points = 0;
    int neutral_points = 0;
    int sample_points = 0;
    float blue_ratio_sum = 0.0f;
    cand.blob_threshold = fmaxf(HEURISTIC_EGG_CENTER_MIN,
                                cand.mean + (cand.stddev * 0.20f));

    for (int y = cand.y0; y < cand.y1; y += blob_step) {
        int run_x = 0;
        int sx = 0;
        for (int x = cand.x0; x < cand.x1 && sx < sample_cols; x += blob_step, sx++) {
            float luma = crop_luma_at(rgb, img_w, x, y);
            sample_points++;
            if (luma >= cand.blob_threshold) {
                float rr = 0.0f;
                float gg = 0.0f;
                float bb = 0.0f;
                crop_rgb_at(rgb, img_w, x, y, &rr, &gg, &bb);
                float warm_max = fmaxf(rr, gg);
                float blue_ratio = bb / fmaxf(1.0f, warm_max);
                bright_points++;
                blue_ratio_sum += blue_ratio;
                if (blue_ratio >= HEURISTIC_BLUE_RATIO_MIN) {
                    neutral_points++;
                }
                run_x++;
                col_runs[sx]++;
                if (run_x > max_run_x) max_run_x = run_x;
                if (col_runs[sx] > max_run_y) max_run_y = col_runs[sx];
            } else {
                run_x = 0;
                col_runs[sx] = 0;
            }
        }
    }

    int sample_rows = (h + blob_step - 1) / blob_step;
    if (sample_points > 0 && sample_cols > 0 && sample_rows > 0) {
        cand.bright_frac = (float)bright_points / (float)sample_points;
        cand.run_x_frac = (float)max_run_x / (float)sample_cols;
        cand.run_y_frac = (float)max_run_y / (float)sample_rows;
        if (bright_points > 0) {
            cand.neutral_frac = (float)neutral_points / (float)bright_points;
            cand.blue_ratio = blue_ratio_sum / (float)bright_points;
        }
        cand.blob_score = (fminf(cand.run_x_frac, cand.run_y_frac) * 100.0f) +
                          (cand.bright_frac * 20.0f) +
                          (cand.neutral_frac * 25.0f) +
                          (fmaxf(0.0f, cand.center_delta) * 0.15f);
    }

    cand.score = fmaxf(cand.center_delta + (0.15f * cand.stddev),
                       cand.blob_score);
    return cand;
}

typedef struct {
    float mean;
    float stddev;
    float dark_frac;
    float bright_frac;
    uint8_t p05;
    uint8_t p95;
    uint32_t samples;
} ImageQualityStats;

typedef struct {
    float border_mean;
    float bright_frac;
    uint8_t border_p90;
    uint32_t samples;
} SlotLightStats;

typedef struct {
    ImageQualityStats image;
    bool unreadable_slots[NUM_CELLS];
    int target_count;
    int light_ok_count;
    int unreadable_count;
    bool global_fault;
} CandlingQualityReport;

static uint8_t histogram_percentile(const uint32_t histogram[256],
                                    uint32_t samples, float fraction)
{
    if (histogram == NULL || samples == 0) {
        return 0;
    }
    uint32_t target = (uint32_t)ceilf(samples * fraction);
    if (target < 1) target = 1;
    uint32_t cumulative = 0;
    for (int value = 0; value < 256; value++) {
        cumulative += histogram[value];
        if (cumulative >= target) {
            return (uint8_t)value;
        }
    }
    return 255;
}

static ImageQualityStats measure_image_quality(const uint8_t *rgb,
                                                uint32_t img_w,
                                                uint32_t img_h)
{
    ImageQualityStats stats = {};
    if (rgb == NULL || img_w == 0 || img_h == 0) {
        return stats;
    }

    uint32_t histogram[256] = {};
    double sum = 0.0;
    double sum_sq = 0.0;
    uint32_t dark = 0;
    uint32_t bright = 0;
    const int step = QUALITY_SAMPLE_STEP > 0 ? QUALITY_SAMPLE_STEP : 1;

    for (uint32_t y = 0; y < img_h; y += (uint32_t)step) {
        for (uint32_t x = 0; x < img_w; x += (uint32_t)step) {
            int luma = (int)lroundf(crop_luma_at(rgb, img_w, (int)x, (int)y));
            luma = clamp_int(luma, 0, 255);
            histogram[luma]++;
            sum += luma;
            sum_sq += (double)luma * luma;
            if (luma <= 8) dark++;
            if (luma >= 247) bright++;
            stats.samples++;
        }
    }

    if (stats.samples > 0) {
        stats.mean = (float)(sum / stats.samples);
        double variance = (sum_sq / stats.samples) -
                          ((double)stats.mean * stats.mean);
        stats.stddev = (float)sqrt(fmax(0.0, variance));
        stats.dark_frac = (float)dark / stats.samples;
        stats.bright_frac = (float)bright / stats.samples;
        stats.p05 = histogram_percentile(histogram, stats.samples, 0.05f);
        stats.p95 = histogram_percentile(histogram, stats.samples, 0.95f);
    }
    return stats;
}

static bool image_dimensions_quality_valid(uint32_t img_w, uint32_t img_h)
{
    if (img_w < QUALITY_MIN_IMAGE_W || img_h < QUALITY_MIN_IMAGE_H) {
        ESP_LOGE(TAG, "Camera quality: frame too small (%lux%lu, need at least %dx%d)",
                 (unsigned long)img_w, (unsigned long)img_h,
                 QUALITY_MIN_IMAGE_W, QUALITY_MIN_IMAGE_H);
        return false;
    }
    float aspect = (float)img_w / (float)img_h;
    if (aspect < QUALITY_ASPECT_MIN || aspect > QUALITY_ASPECT_MAX) {
        ESP_LOGE(TAG, "Camera quality: unexpected aspect %.3f for %lux%lu",
                 aspect, (unsigned long)img_w, (unsigned long)img_h);
        return false;
    }
    return true;
}

static bool grid_geometry_quality_valid(uint32_t img_w, uint32_t img_h)
{
    if (!s_grid_config_ready ||
        !grid_config_valid(s_grid_cols, s_grid_rows,
                           s_col_bounds_cm, s_row_bounds_cm)) {
        ESP_LOGE(TAG, "Camera quality: grid configuration is invalid");
        return false;
    }

    float grid_width_frac =
        (s_col_bounds_cm[s_grid_cols] - s_col_bounds_cm[0]) / s_tray_w_cm;
    float grid_height_frac =
        (s_row_bounds_cm[s_grid_rows] - s_row_bounds_cm[0]) / s_tray_h_cm;
    if (grid_width_frac < 0.35f || grid_width_frac > 1.0f ||
        grid_height_frac < 0.50f || grid_height_frac > 1.0f) {
        ESP_LOGE(TAG,
                 "Camera quality: implausible grid coverage %.2fx%.2f of frame",
                 grid_width_frac, grid_height_frac);
        return false;
    }

    for (int col = 0; col < s_grid_cols; col++) {
        float width_px = (s_col_bounds_cm[col + 1] - s_col_bounds_cm[col]) /
                         s_tray_w_cm * img_w;
        if (width_px < 24.0f) {
            ESP_LOGE(TAG, "Camera quality: grid column %d is only %.1f px wide",
                     col, width_px);
            return false;
        }
    }
    for (int row = 0; row < s_grid_rows; row++) {
        float height_px = (s_row_bounds_cm[row + 1] - s_row_bounds_cm[row]) /
                          s_tray_h_cm * img_h;
        if (height_px < 24.0f) {
            ESP_LOGE(TAG, "Camera quality: grid row %d is only %.1f px high",
                     row, height_px);
            return false;
        }
    }
    return true;
}

static bool normal_image_quality_valid(const uint8_t *rgb,
                                       uint32_t img_w, uint32_t img_h)
{
    if (!image_dimensions_quality_valid(img_w, img_h) ||
        !grid_geometry_quality_valid(img_w, img_h)) {
        return false;
    }

    ImageQualityStats stats = measure_image_quality(rgb, img_w, img_h);
    float range = (float)stats.p95 - stats.p05;
    ESP_LOGI(TAG,
             "Normal image quality: mean=%.1f std=%.1f p05=%u p95=%u range=%.1f dark=%.3f bright=%.3f samples=%lu",
             stats.mean, stats.stddev, stats.p05, stats.p95, range,
             stats.dark_frac, stats.bright_frac,
             (unsigned long)stats.samples);

    bool valid = stats.samples > 0 &&
                 stats.mean >= NORMAL_QUALITY_MIN_MEAN &&
                 stats.mean <= NORMAL_QUALITY_MAX_MEAN &&
                 stats.stddev >= NORMAL_QUALITY_MIN_STDDEV &&
                 range >= NORMAL_QUALITY_MIN_P95_P05 &&
                 stats.dark_frac <= NORMAL_QUALITY_MAX_DARK_FRAC &&
                 stats.bright_frac <= NORMAL_QUALITY_MAX_BRIGHT_FRAC;
    if (!valid) {
        ESP_LOGE(TAG,
                 "Normal image rejected as global camera/lighting fault; committed egg state preserved");
    }
    return valid;
}

static SlotLightStats measure_slot_border_light(const uint8_t *rgb,
                                                uint32_t img_w,
                                                uint32_t img_h,
                                                int row, int col,
                                                float bright_threshold)
{
    SlotLightStats stats = {};
    if (rgb == NULL || row < 0 || row >= s_grid_rows ||
        col < 0 || col >= s_grid_cols) {
        return stats;
    }

    int x0 = (int)lroundf((s_col_bounds_cm[col] / s_tray_w_cm) * img_w);
    int x1 = (int)lroundf((s_col_bounds_cm[col + 1] / s_tray_w_cm) * img_w);
    int y0 = (int)lroundf((s_row_bounds_cm[row] / s_tray_h_cm) * img_h);
    int y1 = (int)lroundf((s_row_bounds_cm[row + 1] / s_tray_h_cm) * img_h);
    x0 = clamp_int(x0, 0, (int)img_w - 1);
    x1 = clamp_int(x1, x0 + 1, (int)img_w);
    y0 = clamp_int(y0, 0, (int)img_h - 1);
    y1 = clamp_int(y1, y0 + 1, (int)img_h);

    int width = x1 - x0;
    int height = y1 - y0;
    int center_x0 = x0 + width / 4;
    int center_x1 = x0 + (width * 3) / 4;
    int center_y0 = y0 + height / 4;
    int center_y1 = y0 + (height * 3) / 4;
    uint32_t histogram[256] = {};
    double sum = 0.0;
    uint32_t bright = 0;
    const int step = QUALITY_SAMPLE_STEP > 0 ? QUALITY_SAMPLE_STEP : 1;

    for (int y = y0; y < y1; y += step) {
        for (int x = x0; x < x1; x += step) {
            if (x >= center_x0 && x < center_x1 &&
                y >= center_y0 && y < center_y1) {
                continue;
            }
            int luma = clamp_int(
                (int)lroundf(crop_luma_at(rgb, img_w, x, y)), 0, 255);
            histogram[luma]++;
            sum += luma;
            if ((float)luma >= bright_threshold) bright++;
            stats.samples++;
        }
    }

    if (stats.samples > 0) {
        stats.border_mean = (float)(sum / stats.samples);
        stats.bright_frac = (float)bright / stats.samples;
        stats.border_p90 = histogram_percentile(
            histogram, stats.samples, 0.90f);
    }
    return stats;
}

static CandlingQualityReport evaluate_candling_quality(
    const uint8_t *rgb, uint32_t img_w, uint32_t img_h,
    const bool target_mask[NUM_CELLS])
{
    CandlingQualityReport report = {};
    if (rgb == NULL || target_mask == NULL ||
        !image_dimensions_quality_valid(img_w, img_h) ||
        !grid_geometry_quality_valid(img_w, img_h)) {
        report.global_fault = true;
        return report;
    }

    report.image = measure_image_quality(rgb, img_w, img_h);
    float bright_threshold = fmaxf(30.0f, report.image.mean + 10.0f);
    ESP_LOGI(TAG,
             "Candled image quality: mean=%.1f std=%.1f p05=%u p95=%u dark=%.3f bright=%.3f",
             report.image.mean, report.image.stddev,
             report.image.p05, report.image.p95,
             report.image.dark_frac, report.image.bright_frac);

    bool globally_unusable = report.image.samples == 0 ||
        report.image.stddev < CANDLING_QUALITY_MIN_STDDEV ||
        report.image.dark_frac > 0.995f ||
        report.image.bright_frac > 0.98f;

    for (int cell = 0; cell < NUM_CELLS; cell++) {
        if (!target_mask[cell]) {
            continue;
        }
        report.target_count++;
        int row = cell / s_grid_cols;
        int col = cell % s_grid_cols;
        SlotLightStats light = measure_slot_border_light(
            rgb, img_w, img_h, row, col, bright_threshold);
        bool light_ok = light.samples > 0 &&
            light.border_p90 >= SLOT_LIGHT_MIN_BORDER_P90 &&
            (light.border_mean >= SLOT_LIGHT_MIN_BORDER_MEAN ||
             light.bright_frac >= SLOT_LIGHT_MIN_BRIGHT_FRAC);
        if (light_ok) {
            report.light_ok_count++;
        } else {
            report.unreadable_slots[cell] = true;
            report.unreadable_count++;
        }
        ESP_LOGI(TAG,
                 "Candling light cell %02d slot %02d: border_mean=%.1f p90=%u bright=%.3f samples=%lu -> %s",
                 cell, cell + 1, light.border_mean, light.border_p90,
                 light.bright_frac, (unsigned long)light.samples,
                 light_ok ? "LIGHT_OK" : "UNREADABLE_LIGHT");
    }

    report.global_fault = globally_unusable || report.target_count == 0 ||
                          report.light_ok_count == 0;
    if (report.global_fault) {
        ESP_LOGE(TAG,
                 "Candled image rejected as global illumination/camera fault: targets=%d light_ok=%d unreadable=%d",
                 report.target_count, report.light_ok_count,
                 report.unreadable_count);
    } else if (report.unreadable_count > 0) {
        ESP_LOGW(TAG,
                 "Candled image has %d individually unreadable slot light(s); readable targets remain valid",
                 report.unreadable_count);
    }
    return report;
}

static void insert_crop_candidate(CropCandidate *top, int top_count,
                                  const CropCandidate *cand)
{
    for (int i = 0; i < top_count; i++) {
        if (cand->score > top[i].score) {
            for (int j = top_count - 1; j > i; j--) {
                top[j] = top[j - 1];
            }
            top[i] = *cand;
            return;
        }
    }
}

static bool crop_candidate_has_egg_evidence(const CropCandidate *cand)
{
    if (cand == NULL) {
        return false;
    }

    bool color_ok = cand->neutral_frac >= HEURISTIC_VERIFY_NEUTRAL_FRAC &&
                    cand->blue_ratio >= HEURISTIC_VERIFY_BLUE_RATIO;
    bool shape_ok = cand->run_x_frac >= HEURISTIC_VERIFY_RUN_FRAC &&
                    cand->run_y_frac >= HEURISTIC_VERIFY_RUN_FRAC;
    bool center_ok = cand->center_delta >= HEURISTIC_VERIFY_DELTA_THRESH &&
                     cand->center_mean >= HEURISTIC_VERIFY_CENTER_MIN &&
                     shape_ok;
    bool blob_ok = cand->blob_score >= HEURISTIC_VERIFY_BLOB_SCORE &&
                   cand->bright_frac >= HEURISTIC_BLOB_MIN_BRIGHT_FRAC &&
                   cand->bright_frac <= HEURISTIC_BLOB_MAX_BRIGHT_FRAC &&
                   shape_ok;

    return color_ok && (center_ok || blob_ok);
}

#if !CLASSIFIER_DEBUG_RUN_MODEL
static bool map_image_point_to_grid_cell(float px, float py,
                                         int work_l, int work_t,
                                         int work_w, int work_h,
                                         int *out_idx, int *out_row, int *out_col,
                                         float *out_cm_x, float *out_cm_y)
{
    if (work_w <= 0 || work_h <= 0 || s_tray_w_cm <= 0.0f || s_tray_h_cm <= 0.0f) {
        return false;
    }

    float rel_x = (px - (float)work_l) / (float)work_w;
    float rel_y = (py - (float)work_t) / (float)work_h;
    if (rel_x < 0.0f || rel_x > 1.0f || rel_y < 0.0f || rel_y > 1.0f) {
        return false;
    }

    float cm_x = rel_x * s_tray_w_cm;
    float cm_y = rel_y * s_tray_h_cm;
    int col = -1;
    int row = -1;

    for (int c = 0; c < s_grid_cols; c++) {
        bool in_col = (cm_x >= s_col_bounds_cm[c] && cm_x < s_col_bounds_cm[c + 1]);
        if (c == s_grid_cols - 1 && cm_x <= s_col_bounds_cm[c + 1]) {
            in_col = in_col || cm_x >= s_col_bounds_cm[c];
        }
        if (in_col) {
            col = c;
            break;
        }
    }

    for (int r = 0; r < s_grid_rows; r++) {
        bool in_row = (cm_y >= s_row_bounds_cm[r] && cm_y < s_row_bounds_cm[r + 1]);
        if (r == s_grid_rows - 1 && cm_y <= s_row_bounds_cm[r + 1]) {
            in_row = in_row || cm_y >= s_row_bounds_cm[r];
        }
        if (in_row) {
            row = r;
            break;
        }
    }

    if (row < 0 || col < 0) {
        return false;
    }

    if (out_idx) *out_idx = row * s_grid_cols + col;
    if (out_row) *out_row = row;
    if (out_col) *out_col = col;
    if (out_cm_x) *out_cm_x = cm_x;
    if (out_cm_y) *out_cm_y = cm_y;
    return true;
}

static bool estimate_candidate_centroid(const uint8_t *rgb, uint32_t img_w,
                                        const CropCandidate *cand,
                                        float *out_x, float *out_y,
                                        int *out_points, float *out_threshold)
{
    if (rgb == NULL || cand == NULL || cand->x1 <= cand->x0 || cand->y1 <= cand->y0) {
        return false;
    }

    float threshold = fmaxf(HEURISTIC_EGG_CENTER_MIN,
                            cand->border_mean + (cand->center_delta * 0.45f));
    threshold = fmaxf(threshold, cand->mean + (cand->stddev * 0.25f));

    float weighted_x = 0.0f;
    float weighted_y = 0.0f;
    float weight_sum = 0.0f;
    int points = 0;
    const int step = HEURISTIC_CENTROID_SAMPLE_STEP > 0 ? HEURISTIC_CENTROID_SAMPLE_STEP : 1;

    for (int y = cand->y0; y < cand->y1; y += step) {
        for (int x = cand->x0; x < cand->x1; x += step) {
            float luma = crop_luma_at(rgb, img_w, x, y);
            if (luma < threshold) {
                continue;
            }
            float weight = (luma - threshold) + 1.0f;
            weighted_x += ((float)x + 0.5f) * weight;
            weighted_y += ((float)y + 0.5f) * weight;
            weight_sum += weight;
            points++;
        }
    }

    if (points < 8 || weight_sum <= 0.0f) {
        return false;
    }

    if (out_x) *out_x = weighted_x / weight_sum;
    if (out_y) *out_y = weighted_y / weight_sum;
    if (out_points) *out_points = points;
    if (out_threshold) *out_threshold = threshold;
    return true;
}
#endif

static bool classify_grid_cells(const uint8_t *rgb, uint32_t img_w, uint32_t img_h)
{
    if (s_scan_deadline_expired) {
        ESP_LOGE(TAG, "Grid classification blocked: scan deadline expired");
        return false;
    }
    if (rgb == NULL || img_w == 0 || img_h == 0) {
        return false;
    }
    if (!s_grid_config_ready) {
        ESP_LOGW(TAG, "Grid classification skipped; no custom grid config is active");
        return false;
    }

    // The phone grid painter maps saved cm boundaries across the full camera
    // image. Use the same coordinate system here so saved app grid positions
    // line up with P4 slot indexes.
    int work_l = 0;
    int work_t = 0;
    int work_w = (int)img_w;
    int work_h = (int)img_h;

    if (work_w <= 0 || work_h <= 0 || s_tray_w_cm <= 0.0f || s_tray_h_cm <= 0.0f) {
        ESP_LOGE(TAG, "Invalid grid classification area");
        return false;
    }

    GridClassifierScratch *scratch =
        (GridClassifierScratch *)psram_buffer_calloc(
            sizeof(GridClassifierScratch), "grid classifier");
    if (scratch == NULL) {
        ESP_LOGE(TAG, "Grid classification aborted: no scratch memory");
        return false;
    }
    GridClassifierScratchGuard scratch_guard(scratch);
    ESP_LOGI(TAG, "Grid classifier scratch: %zu bytes off-stack",
             sizeof(GridClassifierScratch));

    // Build a candidate tray separately. /get_slots continues serving the last
    // verified tray until every cell has completed successfully.
    bool *candidate_cells = scratch->candidate_cells;
    memset(s_candidate_fingerprint, 0, sizeof(s_candidate_fingerprint));

    int64_t scan_t0 = esp_timer_get_time();
    int total = 0;

    ESP_LOGI(TAG, "Classifying %dx%d grid cells with %dx%d classifier",
             s_grid_cols, s_grid_rows, s_model_input_w, s_model_input_h);
    ESP_LOGI(TAG,
             "Grid mapping image=%lux%lu work=(%d,%d %dx%d) tray=%.1fx%.1fcm col0=%.1f colN=%.1f row0=%.1f rowN=%.1f",
             (unsigned long)img_w, (unsigned long)img_h,
             work_l, work_t, work_w, work_h,
             s_tray_w_cm, s_tray_h_cm,
             s_col_bounds_cm[0], s_col_bounds_cm[s_grid_cols],
             s_row_bounds_cm[0], s_row_bounds_cm[s_grid_rows]);
#if CLASSIFIER_DEBUG_USE_PREFILTER
    bool *classify_cell = scratch->classify_cell;
    bool *heuristic_egg = scratch->heuristic_egg;
#if !CLASSIFIER_DEBUG_RUN_MODEL
    float *heuristic_delta = scratch->heuristic_delta;
    float *heuristic_center = scratch->heuristic_center;
#endif
    CropCandidate *cell_stats = scratch->cell_stats;
    CropCandidate *ranked = scratch->ranked;
    for (int i = 0; i < NUM_CELLS; i++) {
        ranked[i].score = -1.0f;
    }

    for (int r = 0; r < s_grid_rows; r++) {
        float rel_y0 = s_row_bounds_cm[r] / s_tray_h_cm;
        float rel_y1 = s_row_bounds_cm[r + 1] / s_tray_h_cm;
        for (int c = 0; c < s_grid_cols; c++) {
            int idx = r * s_grid_cols + c;
            float rel_x0 = s_col_bounds_cm[c] / s_tray_w_cm;
            float rel_x1 = s_col_bounds_cm[c + 1] / s_tray_w_cm;

            int x0 = work_l + (int)lroundf(rel_x0 * work_w);
            int x1 = work_l + (int)lroundf(rel_x1 * work_w);
            int y0 = work_t + (int)lroundf(rel_y0 * work_h);
            int y1 = work_t + (int)lroundf(rel_y1 * work_h);

            int margin_x = (int)lroundf((x1 - x0) * CELL_CROP_MARGIN);
            int margin_y = (int)lroundf((y1 - y0) * CELL_CROP_MARGIN);
            CropCandidate cand = build_crop_candidate(
                rgb, img_w, img_h, idx, r, c,
                x0 - margin_x, y0 - margin_y, x1 + margin_x, y1 + margin_y);
            cell_stats[idx] = cand;
            s_candidate_fingerprint[idx] = fingerprint_from_candidate(&cand);
            classify_cell[idx] = true;
#if !CLASSIFIER_DEBUG_RUN_MODEL
            heuristic_delta[idx] = cand.center_delta;
            heuristic_center[idx] = cand.center_mean;
#endif
            if (crop_candidate_has_egg_evidence(&cand)) {
                heuristic_egg[idx] = true;
            }
            insert_crop_candidate(ranked, NUM_CELLS, &cand);
        }
    }

    ESP_LOGW(TAG,
             "Full 56-cell classifier scan active; CNN decides eggs, heuristic evidence is logged only, confidence >= %.2f",
             CLS_EGG_CONF_THRESH);
    for (int i = 0; i < CLASSIFIER_DEBUG_TOP_CELLS && i < NUM_CELLS; i++) {
        if (ranked[i].score < 0.0f) {
            continue;
        }
        classify_cell[ranked[i].idx] = true;
        ESP_LOGI(TAG,
                 "Candidate %02d: cell %02d r%d c%d score=%.1f mean=%.1f std=%.1f center=%.1f border=%.1f delta=%.1f blob=%.1f bright=%.2f run=%.2fx%.2f neutral=%.2f blue=%.2f heuristic=%s crop=(%d,%d)-(%d,%d)",
                 i + 1, ranked[i].idx, ranked[i].row, ranked[i].col, ranked[i].score,
                 ranked[i].mean, ranked[i].stddev, ranked[i].center_mean,
                 ranked[i].border_mean, ranked[i].center_delta,
                 ranked[i].blob_score, ranked[i].bright_frac,
                 ranked[i].run_x_frac, ranked[i].run_y_frac,
                 ranked[i].neutral_frac, ranked[i].blue_ratio,
                 heuristic_egg[ranked[i].idx] ? "EGG" : "empty",
                 ranked[i].x0, ranked[i].y0, ranked[i].x1, ranked[i].y1);
    }

#if !CLASSIFIER_DEBUG_RUN_MODEL
    bool *suppressed = scratch->suppressed;
    float *accepted_x = scratch->accepted_x;
    float *accepted_y = scratch->accepted_y;
    int accepted_count = 0;
    float grid_span_x = (s_col_bounds_cm[s_grid_cols] - s_col_bounds_cm[0]) / s_tray_w_cm;
    float grid_span_y = (s_row_bounds_cm[s_grid_rows] - s_row_bounds_cm[0]) / s_tray_h_cm;
    float avg_cell_px_w = (grid_span_x * work_w) / (float)s_grid_cols;
    float avg_cell_px_h = (grid_span_y * work_h) / (float)s_grid_rows;
    float min_egg_distance_px = fminf(avg_cell_px_w, avg_cell_px_h) * HEURISTIC_MIN_EGG_DISTANCE_FRAC;
    for (int rank = 0; rank < NUM_CELLS; rank++) {
        int idx = ranked[rank].idx;
        if (ranked[rank].score < 0.0f || idx < 0 || idx >= NUM_CELLS) {
            continue;
        }
        if (!heuristic_egg[idx]) {
            continue;
        }

        float centroid_x = (ranked[rank].x0 + ranked[rank].x1) * 0.5f;
        float centroid_y = (ranked[rank].y0 + ranked[rank].y1) * 0.5f;
        int centroid_points = 0;
        float centroid_threshold = 0.0f;
        bool centroid_ok = estimate_candidate_centroid(
            rgb, img_w, &ranked[rank],
            &centroid_x, &centroid_y,
            &centroid_points, &centroid_threshold);

        int mapped_idx = idx;
        int mapped_row = ranked[rank].row;
        int mapped_col = ranked[rank].col;
        float mapped_cm_x = 0.0f;
        float mapped_cm_y = 0.0f;
        bool mapped_ok = map_image_point_to_grid_cell(
            centroid_x, centroid_y,
            work_l, work_t, work_w, work_h,
            &mapped_idx, &mapped_row, &mapped_col,
            &mapped_cm_x, &mapped_cm_y);
        if (!mapped_ok) {
            mapped_idx = idx;
            mapped_row = ranked[rank].row;
            mapped_col = ranked[rank].col;
            mapped_cm_x = (s_col_bounds_cm[mapped_col] + s_col_bounds_cm[mapped_col + 1]) * 0.5f;
            mapped_cm_y = (s_row_bounds_cm[mapped_row] + s_row_bounds_cm[mapped_row + 1]) * 0.5f;
        }

        if (mapped_idx < 0 || mapped_idx >= NUM_CELLS || suppressed[mapped_idx]) {
            continue;
        }

        bool too_close = false;
        for (int i = 0; i < accepted_count; i++) {
            float dx = centroid_x - accepted_x[i];
            float dy = centroid_y - accepted_y[i];
            if ((dx * dx + dy * dy) < (min_egg_distance_px * min_egg_distance_px)) {
                too_close = true;
                break;
            }
        }
        if (too_close) {
            continue;
        }

        candidate_cells[mapped_idx] = true;
        suppressed[mapped_idx] = true;
        if (accepted_count < NUM_CELLS) {
            accepted_x[accepted_count] = centroid_x;
            accepted_y[accepted_count] = centroid_y;
            accepted_count++;
        }
        total++;
        ESP_LOGI(TAG,
                 "Heuristic peak source cell %02d r%d c%d -> %s centroid=(%.0f,%.0f) cm=(%.1f,%.1f) mapped cell %02d r%d c%d center=%.1f delta=%.1f blob=%.1f bright=%.2f run=%.2fx%.2f neutral=%.2f blue=%.2f score=%.1f points=%d threshold=%.1f min_dist=%.0f",
                 idx, ranked[rank].row, ranked[rank].col,
                 centroid_ok && mapped_ok ? "EGG" : "EGG fallback",
                 centroid_x, centroid_y, mapped_cm_x, mapped_cm_y,
                 mapped_idx, mapped_row, mapped_col,
                 heuristic_center[idx], heuristic_delta[idx],
                 ranked[rank].blob_score, ranked[rank].bright_frac,
                 ranked[rank].run_x_frac, ranked[rank].run_y_frac,
                 ranked[rank].neutral_frac, ranked[rank].blue_ratio,
                 ranked[rank].score,
                 centroid_points, centroid_threshold, min_egg_distance_px);
    }
    ESP_LOGI(TAG, "Grid heuristic scan finished in %lld ms",
             (esp_timer_get_time() - scan_t0) / 1000);
    memcpy(s_cell_has_egg, candidate_cells, sizeof(s_cell_has_egg));
    complete_cell_scan(total);
    return true;
#endif
#endif
#if CLASSIFIER_DEBUG_LIMIT_CELLS
    ESP_LOGW(TAG, "TEMP DEBUG: only cells %d..%d will be classified",
             CLASSIFIER_DEBUG_FIRST_CELL, CLASSIFIER_DEBUG_LAST_CELL);
#endif

    for (int r = 0; r < s_grid_rows; r++) {
        float rel_y0 = s_row_bounds_cm[r] / s_tray_h_cm;
        float rel_y1 = s_row_bounds_cm[r + 1] / s_tray_h_cm;
        for (int c = 0; c < s_grid_cols; c++) {
            int idx = r * s_grid_cols + c;
#if CLASSIFIER_DEBUG_LIMIT_CELLS
            if (idx < CLASSIFIER_DEBUG_FIRST_CELL ||
                idx > CLASSIFIER_DEBUG_LAST_CELL) {
                continue;
            }
#endif
#if CLASSIFIER_DEBUG_USE_PREFILTER
            if (!CLASSIFIER_SCAN_ALL_CELLS && !classify_cell[idx]) {
                continue;
            }
#endif

            float rel_x0 = s_col_bounds_cm[c] / s_tray_w_cm;
            float rel_x1 = s_col_bounds_cm[c + 1] / s_tray_w_cm;

            int x0 = work_l + (int)lroundf(rel_x0 * work_w);
            int x1 = work_l + (int)lroundf(rel_x1 * work_w);
            int y0 = work_t + (int)lroundf(rel_y0 * work_h);
            int y1 = work_t + (int)lroundf(rel_y1 * work_h);

            int margin_x = (int)lroundf((x1 - x0) * CELL_CROP_MARGIN);
            int margin_y = (int)lroundf((y1 - y0) * CELL_CROP_MARGIN);
            x0 -= margin_x;
            x1 += margin_x;
            y0 -= margin_y;
            y1 += margin_y;

            bool has_egg = false;
            esp_err_t classify_ret = run_classifier_on_crop(
                rgb, img_w, img_h, x0, y0, x1, y1, idx, r, c, &has_egg);
            if (classify_ret != ESP_OK) {
                ESP_LOGE(TAG, "Cell %02d classification failed; previous tray remains active: %s",
                         idx, esp_err_to_name(classify_ret));
                return false;
            }
            if (s_scan_deadline_expired) {
                ESP_LOGE(TAG, "Grid classification timed out at cell %02d", idx);
                return false;
            }
#if CLASSIFIER_DEBUG_USE_PREFILTER
            if (has_egg && !heuristic_egg[idx]) {
                CropCandidate *cand = &cell_stats[idx];
                ESP_LOGW(TAG,
                         "CNN accepted egg without heuristic evidence cell %02d: center=%.1f delta=%.1f blob=%.1f bright=%.2f run=%.2fx%.2f neutral=%.2f blue=%.2f",
                         idx, cand->center_mean, cand->center_delta,
                         cand->blob_score, cand->bright_frac,
                         cand->run_x_frac, cand->run_y_frac,
                         cand->neutral_frac, cand->blue_ratio);
            }
#endif
            if (has_egg) {
                candidate_cells[idx] = true;
                total++;
            }
        }
        vTaskDelay(1);
    }

    ESP_LOGI(TAG, "Grid classification finished in %lld ms",
             (esp_timer_get_time() - scan_t0) / 1000);
    if (s_scan_deadline_expired) {
        ESP_LOGE(TAG, "Grid candidate discarded: scan deadline expired");
        return false;
    }
    if (!door_switch_is_closed()) {
        ESP_LOGW(TAG,
                 "Door opened during AI; candidate tray discarded and verified tray preserved");
        return false;
    }
    memcpy(s_cell_has_egg, candidate_cells, sizeof(s_cell_has_egg));
    complete_cell_scan(total);
    return true;
}

// Map detections to grid cells
static void map_detections_to_cells(const Detection *dets, int det_count,
                                     uint32_t orig_w, uint32_t orig_h,
                                     float lb_scale, uint32_t lb_ox, uint32_t lb_oy)
{
    int edgeMargin = (int)(orig_w * EDGE_IGNORE);

    int workL = edgeMargin;
    int workT = edgeMargin;
    int workW = (int)orig_w - 2 * edgeMargin;
    int workH = (int)orig_h - 2 * edgeMargin;

    memset(s_cell_has_egg, 0, sizeof(s_cell_has_egg));
    int total = 0;

    for (int d = 0; d < det_count; d++) {
        float lb_cx = dets[d].x + dets[d].w / 2.0f;
        float lb_cy = dets[d].y + dets[d].h / 2.0f;

        float orig_cx = (lb_cx - lb_ox) / lb_scale;
        float orig_cy = (lb_cy - lb_oy) / lb_scale;

        float relX = (orig_cx - workL) / workW;
        float relY = (orig_cy - workT) / workH;

        if (relX < 0 || relX >= 1.0f || relY < 0 || relY >= 1.0f) {
            ESP_LOGW(TAG, "  Det[%d] outside working area (%.2f, %.2f) - skipped",
                     d, relX, relY);
            continue;
        }

        float cmX = relX * s_tray_w_cm;
        float cmY = relY * s_tray_h_cm;

        int col = -1;
        for (int c = 0; c < s_grid_cols; c++) {
            if (cmX >= s_col_bounds_cm[c] && cmX < s_col_bounds_cm[c + 1]) {
                col = c; break;
            }
        }
        int row = -1;
        for (int r = 0; r < s_grid_rows; r++) {
            if (cmY >= s_row_bounds_cm[r] && cmY < s_row_bounds_cm[r + 1]) {
                row = r; break;
            }
        }

        if (col >= 0 && row >= 0) {
            int idx = row * s_grid_cols + col;
            if (!s_cell_has_egg[idx]) {
                s_cell_has_egg[idx] = true;
                total++;
            }
            ESP_LOGI(TAG, "  Det[%d] conf=%.3f cls=%d cm=(%.1f,%.1f) -> cell[col%d,row%d] #%d",
                     d, dets[d].conf, dets[d].cls, cmX, cmY, col, row,
                     row * s_grid_cols + col);
        }
    }

    complete_cell_scan(total);
}

// TFLite init
static esp_err_t tflite_init(void)
{
    if (s_tflite_ready) {
        return ESP_OK;
    }
    if (s_arena != NULL) {
        ESP_LOGE(TAG, "TFLite init already failed once; reboot to retry cleanly");
        return ESP_FAIL;
    }

    size_t psram_free = heap_caps_get_free_size(MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
    size_t psram_largest = heap_caps_get_largest_free_block(MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
    ESP_LOGI(TAG, "PSRAM before arena: free=%zu bytes largest=%zu bytes",
             psram_free, psram_largest);

    s_arena = (uint8_t *)heap_caps_malloc(ARENA_SIZE, MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
    if (!s_arena) {
        ESP_LOGE(TAG, "Arena alloc failed (need %zu bytes PSRAM, free=%zu largest=%zu)",
                 ARENA_SIZE, psram_free, psram_largest);
        return ESP_ERR_NO_MEM;
    }
    ESP_LOGI(TAG, "Arena: %p (%zu MB, PSRAM)", s_arena, ARENA_SIZE >> 20);

    const tflite::Model *model = tflite::GetModel(model_start);
    if (model->version() != TFLITE_SCHEMA_VERSION) {
        ESP_LOGE(TAG, "TFLite schema mismatch");
        return ESP_FAIL;
    }

    static tflite::MicroMutableOpResolver<22> resolver;
    resolver.AddConv2D();
    resolver.AddDepthwiseConv2D();
    resolver.AddFullyConnected();
    resolver.AddReshape();
    resolver.AddSoftmax();
    resolver.AddMaxPool2D();
    resolver.AddPad();
    resolver.AddConcatenation();
    resolver.AddMul();
    resolver.AddAdd();
    resolver.AddLogistic();
    resolver.AddTranspose();
    resolver.AddLeakyRelu();
    resolver.AddResizeBilinear();
    resolver.AddStridedSlice();
    resolver.AddSplit();
    resolver.AddResizeNearestNeighbor();
    resolver.AddQuantize();
    resolver.AddDequantize();
    resolver.AddMean();
    resolver.AddShape();
    resolver.AddPack();

    static tflite::MicroInterpreter interp(model, resolver, s_arena, ARENA_SIZE);
    s_interp = &interp;

    if (s_interp->AllocateTensors() != kTfLiteOk) {
        ESP_LOGE(TAG, "AllocateTensors failed - try increasing ARENA_SIZE");
        return ESP_FAIL;
    }

    // Real arena footprint. If this is below the P4's internal SRAM budget we
    // can later move s_arena to MALLOC_CAP_INTERNAL for a large speedup.
    ESP_LOGI(TAG, "Arena used: %zu bytes (%.2f MB) of %zu MB reserved",
             s_interp->arena_used_bytes(),
             s_interp->arena_used_bytes() / (1024.0 * 1024.0),
             ARENA_SIZE >> 20);

    TfLiteTensor *in  = s_interp->input(0);
    TfLiteTensor *out = s_interp->output(0);
    if (in->dims->size != 4 || in->dims->data[0] != 1 ||
        in->dims->data[3] != MODEL_INPUT_C) {
        ESP_LOGE(TAG, "Unsupported model input layout; expected [1 H W 3]");
        return ESP_FAIL;
    }

    s_model_input_h = in->dims->data[1];
    s_model_input_w = in->dims->data[2];
    s_model_input_c = in->dims->data[3];

    ESP_LOGI(TAG, "Model input:  [%d %d %d %d]",
             in->dims->data[0], in->dims->data[1],
             in->dims->data[2], in->dims->data[3]);
    ESP_LOGI(TAG, "Model input tensor: type=%d scale=%.8f zero=%d bytes=%zu",
             in->type, in->params.scale, in->params.zero_point, in->bytes);
    if (out->dims->size == 2) {
        ESP_LOGI(TAG, "Model output: [%d %d]",
                 out->dims->data[0], out->dims->data[1]);
    } else if (out->dims->size == 3) {
        ESP_LOGI(TAG, "Model output: [%d %d %d]",
                 out->dims->data[0], out->dims->data[1], out->dims->data[2]);
    } else {
        ESP_LOGI(TAG, "Model output dims size: %d", out->dims->size);
    }
    ESP_LOGI(TAG, "Model output tensor: type=%d scale=%.8f zero=%d bytes=%zu",
             out->type, out->params.scale, out->params.zero_point, out->bytes);

    if (out->dims->size == 2 && out->dims->data[0] == 1 &&
        out->dims->data[1] >= 2) {
        s_model_output_kind = MODEL_OUTPUT_CLASSIFIER;
        ESP_LOGI(TAG, "Model output looks like a %d-class slot classifier",
                 out->dims->data[1]);
    } else if (out->dims->size == 3 && out->dims->data[2] >= 6) {
        s_model_output_kind = MODEL_OUTPUT_DETECTOR;
        if (out->dims->data[2] == 85) {
            ESP_LOGW(TAG, "Model output has 80 classes; this looks like generic YOLO, not the 1-class egg model");
            ESP_LOGW(TAG, "Egg-trained YOLO output should usually be 6 values per box: x,y,w,h,obj,egg");
        } else if (out->dims->data[2] == 6) {
            ESP_LOGI(TAG, "Model output looks like a 1-class egg detector");
        } else {
            ESP_LOGW(TAG, "Model output has %d classes; parser will use best class, but egg model should be 1 class",
                     out->dims->data[2] - 5);
        }
    } else {
        ESP_LOGE(TAG, "Unsupported model output layout");
        s_model_output_kind = MODEL_OUTPUT_UNKNOWN;
        return ESP_FAIL;
    }
    s_tflite_ready = true;
    return ESP_OK;
}

// Run inference
static int run_inference(const uint8_t *lb_rgb, Detection *dets)
{
    if (s_scan_deadline_expired) return -1;
    if (s_model_output_kind != MODEL_OUTPUT_DETECTOR) {
        ESP_LOGE(TAG, "Detection inference requested for non-detector model");
        return -1;
    }

    TfLiteTensor *in = s_interp->input(0);
    if (lb_rgb == NULL || dets == NULL || in == NULL ||
        s_model_input_w <= 0 || s_model_input_h <= 0 ||
        s_model_input_c != MODEL_INPUT_C) {
        ESP_LOGE(TAG, "Invalid inference input");
        return -1;
    }

    size_t npix = (size_t)s_model_input_w * s_model_input_h * s_model_input_c;
    ESP_LOGI(TAG, "Preparing model input: %dx%dx%d (%zu bytes)",
             s_model_input_w, s_model_input_h, s_model_input_c, npix);

    if (in->type == kTfLiteFloat32) {
        if (in->bytes < npix * sizeof(float)) {
            ESP_LOGE(TAG, "Input tensor too small: %zu < %zu",
                     in->bytes, npix * sizeof(float));
            return -1;
        }
        float *dst = in->data.f;
        for (size_t i = 0; i < npix; i++)
            dst[i] = lb_rgb[i] / 255.0f;
    } else if (in->type == kTfLiteInt8) {
        if (in->bytes < npix || in->params.scale <= 0.0f) {
            ESP_LOGE(TAG, "Invalid int8 input tensor: bytes=%zu scale=%.8f",
                     in->bytes, in->params.scale);
            return -1;
        }
        int8_t *dst = in->data.int8;
        float  sc   = in->params.scale;
        int    zp   = in->params.zero_point;
        for (size_t i = 0; i < npix; i++) {
            float real = lb_rgb[i] / 255.0f;
            int v = zp + (int)lroundf(real / sc);
            dst[i] = (int8_t)(v > 127 ? 127 : v < -128 ? -128 : v);
        }
    } else if (in->type == kTfLiteUInt8) {
        if (in->bytes < npix || in->params.scale <= 0.0f) {
            ESP_LOGE(TAG, "Invalid uint8 input tensor: bytes=%zu scale=%.8f",
                     in->bytes, in->params.scale);
            return -1;
        }
        uint8_t *dst = in->data.uint8;
        float    sc  = in->params.scale;
        int      zp  = in->params.zero_point;
        for (size_t i = 0; i < npix; i++) {
            float real = lb_rgb[i] / 255.0f;
            int v = zp + (int)lroundf(real / sc);
            dst[i] = (uint8_t)(v > 255 ? 255 : v < 0 ? 0 : v);
        }
    } else {
        ESP_LOGE(TAG, "Unsupported input tensor type: %d", in->type);
        return -1;
    }

    ESP_LOGI(TAG, "Input prepared; invoking model");
    int64_t t0 = esp_timer_get_time();
    if (s_interp->Invoke() != kTfLiteOk) {
        ESP_LOGE(TAG, "Invoke() failed");
        return -1;
    }
    if (s_scan_deadline_expired) return -1;
    ESP_LOGI(TAG, "Inference: %lld ms", (esp_timer_get_time() - t0) / 1000);

    return parse_and_nms(s_interp->output(0), dets);
}

// AI scan function. The caller owns the focus-power guard after the complete
// JPEG has been downloaded, validated, and allowed to settle.
static bool process_scan_jpeg(uint8_t *jpeg_buf, size_t jpeg_len,
                               ScanFailureReason *failure_reason)
{
    if (failure_reason != NULL) *failure_reason = SCAN_FAIL_AI;
    if (s_scan_deadline_expired) {
        if (jpeg_buf != NULL && jpeg_len > 0) memset(jpeg_buf, 0, jpeg_len);
        if (failure_reason != NULL) *failure_reason = SCAN_FAIL_TIMEOUT;
        return false;
    }
    if (jpeg_buf == NULL || jpeg_len == 0) {
        if (failure_reason != NULL) *failure_reason = SCAN_FAIL_NO_IMAGE;
        return false;
    }

    if (!s_ai_inference_runtime_enabled) {
        ESP_LOGW(TAG, "AI inference disabled; captured image discarded without processing");
        memset(jpeg_buf, 0, jpeg_len);
        return false;
    }

    if (!s_grid_config_ready) {
        ESP_LOGW(TAG, "AI scan skipped; no custom grid from app is saved on P4 yet");
        memset(jpeg_buf, 0, jpeg_len);
        if (failure_reason != NULL) *failure_reason = SCAN_FAIL_NO_GRID;
        return false;
    }

    if (tflite_init() != ESP_OK) {
        ESP_LOGE(TAG, "TFLite init failed");
        memset(jpeg_buf, 0, jpeg_len);
        return false;
    }

    if (s_lcd.dev != NULL) {
        lcd_clear_line(&s_lcd, 3);
        lcd_set_cursor(&s_lcd, 0, 3);
        lcd_write_string(&s_lcd, "AI PROCESSING");
    }

    log_psram("before jpeg decode");
    uint8_t *rgb = NULL;
    uint32_t img_w = 0, img_h = 0;
    esp_err_t decode_ret = jpeg_to_rgb888(jpeg_buf, jpeg_len, &rgb, &img_w, &img_h);
    if (decode_ret != ESP_OK) {
        ESP_LOGE(TAG, "JPEG decode failed: %s", esp_err_to_name(decode_ret));
        memset(jpeg_buf, 0, jpeg_len);
        if (failure_reason != NULL) {
            *failure_reason = decode_ret == ESP_ERR_NO_MEM ?
                              SCAN_FAIL_MEMORY : SCAN_FAIL_IMAGE_CORRUPT;
        }
        return false;
    }
    if (s_scan_deadline_expired) {
        heap_caps_free(rgb);
        memset(jpeg_buf, 0, jpeg_len);
        if (failure_reason != NULL) *failure_reason = SCAN_FAIL_TIMEOUT;
        return false;
    }
    memset(jpeg_buf, 0, jpeg_len); // Do not retain the captured JPEG after decoding.
    ESP_LOGI(TAG, "Decoded %dx%d", img_w, img_h);
    log_psram("after jpeg decode");

    // Reject equipment-level image failures before either model can modify the
    // candidate tray. The scan transaction guard will restore the last
    // committed state, so a covered lens can never become an empty tray.
    if (!normal_image_quality_valid(rgb, img_w, img_h)) {
        heap_caps_free(rgb);
        if (failure_reason != NULL) {
            *failure_reason = SCAN_FAIL_IMAGE_QUALITY;
        }
        return false;
    }

    if (s_model_output_kind == MODEL_OUTPUT_CLASSIFIER) {
        ESP_LOGI(TAG, "Running slot classifier over the tray grid");
        esp_task_wdt_delete(NULL);
        bool ok = classify_grid_cells(rgb, img_w, img_h);
        heap_caps_free(rgb);
        esp_task_wdt_add(NULL);
        esp_task_wdt_reset();
        if (ok && failure_reason != NULL) *failure_reason = SCAN_FAIL_NONE;
        return ok;
    }

    if (s_model_output_kind != MODEL_OUTPUT_DETECTOR) {
        ESP_LOGE(TAG, "Unsupported model output kind: %d", s_model_output_kind);
        heap_caps_free(rgb);
        return false;
    }

    const uint32_t input_w = (uint32_t)s_model_input_w;
    const uint32_t input_h = (uint32_t)s_model_input_h;
    float    lb_scale = fminf((float)input_w / img_w,
                               (float)input_h / img_h);
    uint32_t lb_nw    = (uint32_t)(img_w * lb_scale);
    uint32_t lb_nh    = (uint32_t)(img_h * lb_scale);
    uint32_t lb_ox    = (input_w - lb_nw) / 2;
    uint32_t lb_oy    = (input_h - lb_nh) / 2;

    ESP_LOGI(TAG, "Letterboxing to %lux%lu",
             (unsigned long)input_w, (unsigned long)input_h);
    uint8_t *lb = letterbox(rgb, img_w, img_h, input_w, input_h);
    heap_caps_free(rgb);

    if (!lb) {
        ESP_LOGE(TAG, "Letterbox alloc failed");
        if (failure_reason != NULL) *failure_reason = SCAN_FAIL_MEMORY;
        return false;
    }
    log_psram("after letterbox");

    esp_task_wdt_delete(NULL);

    Detection *dets = (Detection *)heap_caps_malloc(
        MAX_DETS * sizeof(Detection), MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
    if (dets == NULL) {
        ESP_LOGE(TAG, "Detection result buffer alloc failed");
        heap_caps_free(lb);
        esp_task_wdt_add(NULL);
        esp_task_wdt_reset();
        if (failure_reason != NULL) *failure_reason = SCAN_FAIL_MEMORY;
        return false;
    }
    ESP_LOGI(TAG, "Starting inference");
    int det_count = run_inference(lb, dets);
    heap_caps_free(lb);

    esp_task_wdt_add(NULL);
    esp_task_wdt_reset();

    if (det_count < 0) {
        ESP_LOGE(TAG, "Inference error");
        heap_caps_free(dets);
        return false;
    }

    ESP_LOGI(TAG, "Detections after NMS: %d", det_count);

    map_detections_to_cells(dets, det_count, img_w, img_h,
                            lb_scale, lb_ox, lb_oy);
    heap_caps_free(dets);
    if (failure_reason != NULL) *failure_reason = SCAN_FAIL_NONE;
    return true;
}

typedef struct {
    bool new_slots[NUM_CELLS];
    bool replacement_slots[NUM_CELLS];
    bool pending_slots[NUM_CELLS];
    bool combined[NUM_CELLS];
    int new_count;
    int replacement_count;
    int pending_count;
    int combined_count;
} IntakeTargetMask;

static IntakeTargetMask build_intake_target_mask(
    const EggRuntimeState *baseline)
{
    IntakeTargetMask targets = {};
    if (baseline == NULL) {
        return targets;
    }

    for (int cell = 0; cell < NUM_CELLS; cell++) {
        if (!s_cell_has_egg[cell]) {
            continue;
        }

        bool is_new = !baseline->cell_has_egg[cell];
        bool is_replacement =
            baseline->cell_has_egg[cell] &&
            fingerprint_likely_replacement(
                &baseline->slot_fingerprint[cell],
                &s_candidate_fingerprint[cell]);
        bool is_pending = baseline->pending_verification_slots[cell] ||
                          baseline->intake_verdict[cell] == INTAKE_VERDICT_NONE ||
                          baseline->intake_verdict[cell] == INTAKE_VERDICT_PENDING;

        targets.new_slots[cell] = is_new;
        targets.replacement_slots[cell] = is_replacement;
        targets.pending_slots[cell] = is_pending;
        targets.combined[cell] = is_new || is_replacement || is_pending;
        if (is_new) targets.new_count++;
        if (is_replacement) targets.replacement_count++;
        if (is_pending) targets.pending_count++;
        if (targets.combined[cell]) targets.combined_count++;
    }
    return targets;
}

static bool wait_for_intake_candling_stabilization(void)
{
    const TickType_t tick = pdMS_TO_TICKS(100);
    int waited_ms = 0;
    while (waited_ms < INTAKE_CANDLING_STABILIZE_MS) {
        if (s_scan_deadline_expired || !door_switch_is_closed()) {
            return false;
        }
        vTaskDelay(tick);
        waited_ms += 100;
        esp_task_wdt_reset();
    }
    return !s_scan_deadline_expired && door_switch_is_closed();
}

typedef enum {
    CANDLING_FRAME_ERROR = 0,
    CANDLING_FRAME_OK,
    CANDLING_FRAME_INDIVIDUAL_UNREADABLE,
    CANDLING_FRAME_GLOBAL_FAULT,
} CandlingFrameResult;

static CandlingFrameResult validate_candling_jpeg(
    uint8_t *jpeg_buf, size_t jpeg_len,
    const bool target_mask[NUM_CELLS],
    CandlingQualityReport *quality_report,
    ScanFailureReason *failure_reason)
{
    if (jpeg_buf == NULL || jpeg_len == 0 || target_mask == NULL ||
        quality_report == NULL) {
        if (failure_reason != NULL) *failure_reason = SCAN_FAIL_NO_IMAGE;
        return CANDLING_FRAME_ERROR;
    }
    memset(quality_report, 0, sizeof(*quality_report));

    uint8_t *rgb = NULL;
    uint32_t img_w = 0;
    uint32_t img_h = 0;
    esp_err_t ret =
        jpeg_to_rgb888(jpeg_buf, jpeg_len, &rgb, &img_w, &img_h);
    memset(jpeg_buf, 0, jpeg_len);

    if (ret != ESP_OK || rgb == NULL) {
        if (rgb != NULL) heap_caps_free(rgb);
        if (failure_reason != NULL) {
            *failure_reason = ret == ESP_ERR_NO_MEM
                ? SCAN_FAIL_MEMORY : SCAN_FAIL_IMAGE_CORRUPT;
        }
        ESP_LOGE(TAG, "Candled JPEG decode validation failed: %s",
                 esp_err_to_name(ret));
        return CANDLING_FRAME_ERROR;
    }

    *quality_report = evaluate_candling_quality(
        rgb, img_w, img_h, target_mask);
    heap_caps_free(rgb);
    if (s_scan_deadline_expired) {
        if (failure_reason != NULL) *failure_reason = SCAN_FAIL_TIMEOUT;
        return CANDLING_FRAME_ERROR;
    }

    ESP_LOGI(TAG,
             "Candled JPEG decoded and released: %lux%lu; no second RGB frame retained",
             (unsigned long)img_w, (unsigned long)img_h);
    if (quality_report->global_fault) {
        if (failure_reason != NULL) {
            *failure_reason = SCAN_FAIL_IMAGE_QUALITY;
        }
        return CANDLING_FRAME_GLOBAL_FAULT;
    }
    if (failure_reason != NULL) *failure_reason = SCAN_FAIL_NONE;
    return quality_report->unreadable_count > 0
        ? CANDLING_FRAME_INDIVIDUAL_UNREADABLE
        : CANDLING_FRAME_OK;
}

static CandlingFrameResult capture_candling_batch(
    const bool target_mask[NUM_CELLS], bool exposure_retry,
    uint8_t *jpeg_buf, size_t jpeg_capacity,
    CandlingQualityReport *quality_report,
    ScanFailureReason *failure_reason)
{
    if (target_mask == NULL || jpeg_buf == NULL || jpeg_capacity == 0 ||
        quality_report == NULL) {
        if (failure_reason != NULL) *failure_reason = SCAN_FAIL_CAPTURE;
        return CANDLING_FRAME_ERROR;
    }

    char slot_list[192] = {};
    int requested_count = format_slot_mask_1based(
        target_mask, slot_list, sizeof(slot_list));
    if (requested_count <= 0) {
        if (failure_reason != NULL) *failure_reason = SCAN_FAIL_CAPTURE;
        return CANDLING_FRAME_ERROR;
    }

    int verified_led_count = 0;
    ExternalCandlingLedGuard led_guard;

    scan_phase_set(SCAN_PHASE_CANDLING_LED_VERIFY);
    if (s_lcd.dev != NULL) {
        lcd_write_line_if_changed(&s_lcd, 3, "VERIFYING LEDS");
    }
    if (!led_guard.activate(target_mask, slot_list,
                            sizeof(slot_list), &verified_led_count) ||
        verified_led_count != requested_count) {
        if (failure_reason != NULL) *failure_reason = SCAN_FAIL_LED;
        return CANDLING_FRAME_ERROR;
    }

    scan_phase_set(SCAN_PHASE_CANDLING_STABILIZE);
    if (s_lcd.dev != NULL) {
        lcd_write_line_if_changed(&s_lcd, 3, "CANDLING SETTLE");
    }
    ESP_LOGI(TAG,
             "Candling targets stable for %d ms before %scapture: [%s]",
             INTAKE_CANDLING_STABILIZE_MS,
             exposure_retry ? "exposure-retry " : "", slot_list);
    if (!wait_for_intake_candling_stabilization()) {
        if (failure_reason != NULL) {
            *failure_reason = s_scan_deadline_expired
                ? SCAN_FAIL_TIMEOUT : SCAN_FAIL_CAPTURE;
        }
        return CANDLING_FRAME_ERROR;
    }

    char capture_url[320];
    int url_len = snprintf(capture_url, sizeof(capture_url),
                           "%s?led=%s%s", CANDLING_CAPTURE_URL, slot_list,
                           exposure_retry ? "&exposure=retry" : "");
    if (url_len < 0 || url_len >= (int)sizeof(capture_url)) {
        if (failure_reason != NULL) *failure_reason = SCAN_FAIL_CAPTURE;
        return CANDLING_FRAME_ERROR;
    }

    scan_phase_set(SCAN_PHASE_CANDLING_CAPTURE);
    if (s_lcd.dev != NULL) {
        lcd_write_line_if_changed(&s_lcd, 3, "CANDLING CAPTURE");
    }
    size_t candled_jpeg_len = 0;
    esp_err_t capture_ret = capture_jpeg_from_url(
        capture_url,
        exposure_retry ? "/capture selected LEDs exposure retry"
                       : "/capture selected LEDs",
        jpeg_buf, jpeg_capacity, &candled_jpeg_len, failure_reason);

    // S3 also turns the selected LEDs off after its staged JPEG transfer.
    // P4 repeats that command immediately so every normal return path is dark.
    led_guard.off();
    if (capture_ret != ESP_OK) {
        return CANDLING_FRAME_ERROR;
    }
    if (!door_switch_is_closed()) {
        memset(jpeg_buf, 0, candled_jpeg_len);
        if (failure_reason != NULL) *failure_reason = SCAN_FAIL_CAPTURE;
        return CANDLING_FRAME_ERROR;
    }

    scan_phase_set(SCAN_PHASE_CANDLING_VALIDATE);
    return validate_candling_jpeg(
        jpeg_buf, candled_jpeg_len, target_mask,
        quality_report, failure_reason);
}

static bool capture_intake_targets(
    const IntakeTargetMask *targets,
    uint8_t *jpeg_buf, size_t jpeg_capacity,
    ScanFailureReason *failure_reason)
{
    if (targets == NULL || targets->combined_count <= 0 ||
        jpeg_buf == NULL || jpeg_capacity == 0) {
        if (failure_reason != NULL) *failure_reason = SCAN_FAIL_CAPTURE;
        return false;
    }

    CandlingQualityReport primary = {};
    CandlingFrameResult first_result = capture_candling_batch(
        targets->combined, false, jpeg_buf, jpeg_capacity,
        &primary, failure_reason);
    if (first_result == CANDLING_FRAME_ERROR) {
        return false;
    }

    bool retry_mask[NUM_CELLS] = {};
    int retry_count = 0;
    if (first_result == CANDLING_FRAME_GLOBAL_FAULT) {
        memcpy(retry_mask, targets->combined, sizeof(retry_mask));
        retry_count = targets->combined_count;
    } else if (first_result == CANDLING_FRAME_INDIVIDUAL_UNREADABLE) {
        memcpy(retry_mask, primary.unreadable_slots, sizeof(retry_mask));
        retry_count = primary.unreadable_count;
    }

    CandlingQualityReport final_quality = primary;
    if (retry_count > 0) {
        ESP_LOGW(TAG,
                 "Candling quality requests one brighter exposure retry for %d slot(s)",
                 retry_count);
        CandlingQualityReport retry = {};
        ScanFailureReason retry_failure = SCAN_FAIL_IMAGE_QUALITY;
        CandlingFrameResult retry_result = capture_candling_batch(
            retry_mask, true, jpeg_buf, jpeg_capacity,
            &retry, &retry_failure);

        if (!door_switch_is_closed() || s_scan_deadline_expired) {
            if (failure_reason != NULL) {
                *failure_reason = s_scan_deadline_expired
                    ? SCAN_FAIL_TIMEOUT : SCAN_FAIL_CAPTURE;
            }
            return false;
        }

        if (first_result == CANDLING_FRAME_GLOBAL_FAULT) {
            if (retry_result == CANDLING_FRAME_ERROR ||
                retry_result == CANDLING_FRAME_GLOBAL_FAULT) {
                if (failure_reason != NULL) {
                    *failure_reason = retry_result == CANDLING_FRAME_ERROR
                        ? retry_failure : SCAN_FAIL_IMAGE_QUALITY;
                }
                ESP_LOGE(TAG,
                         "Candling global quality fault persisted after exposure retry");
                return false;
            }
            final_quality = retry;
        } else if (retry_result == CANDLING_FRAME_OK ||
                   retry_result == CANDLING_FRAME_INDIVIDUAL_UNREADABLE) {
            for (int cell = 0; cell < NUM_CELLS; cell++) {
                if (!retry_mask[cell]) continue;
                final_quality.unreadable_slots[cell] =
                    retry.unreadable_slots[cell];
            }
            final_quality.unreadable_count = 0;
            for (int cell = 0; cell < NUM_CELLS; cell++) {
                if (final_quality.unreadable_slots[cell]) {
                    final_quality.unreadable_count++;
                }
            }
        } else {
            if (failure_reason != NULL) {
                *failure_reason = retry_result == CANDLING_FRAME_GLOBAL_FAULT
                    ? SCAN_FAIL_IMAGE_QUALITY : retry_failure;
            }
            ESP_LOGE(TAG,
                     "Individual-slot exposure retry had an equipment/global failure; preserving all committed verdicts");
            return false;
        }
    }

    int newly_abnormal = 0;
    int awaiting_model = 0;
    for (int cell = 0; cell < NUM_CELLS; cell++) {
        if (!targets->combined[cell]) continue;

        if (s_candidate_fingerprint[cell].valid) {
            s_slot_fingerprint[cell] = s_candidate_fingerprint[cell];
        }
        if (final_quality.unreadable_slots[cell]) {
            set_intake_verdict(cell, INTAKE_VERDICT_ABNORMAL);
            newly_abnormal++;
            continue;
        }

        // M5's trained intake model is intentionally not substituted with a
        // brightness heuristic. Preserve an existing ABNORMAL warning during
        // likely-replacement verification; otherwise expose a pending result.
        if (targets->replacement_slots[cell] &&
            targets->combined[cell] && s_abnormal_slots[cell]) {
            s_intake_verdict[cell] = INTAKE_VERDICT_ABNORMAL;
            s_pending_verification_slots[cell] = true;
        } else {
            set_intake_verdict(cell, INTAKE_VERDICT_PENDING);
        }
        awaiting_model++;
    }
    ESP_LOGI(TAG,
             "Intake frame accepted: new=%d replacement=%d pending=%d total=%d unreadable->ABNORMAL=%d awaiting_model=%d",
             targets->new_count, targets->replacement_count,
             targets->pending_count, targets->combined_count,
             newly_abnormal, awaiting_model);
    if (failure_reason != NULL) *failure_reason = SCAN_FAIL_NONE;
    return true;
}

#if PERIODIC_CAPTUREP4_ENABLED
static int64_t next_periodic_scan_deadline_us(void)
{
    return esp_timer_get_time() +
           (int64_t)PERIODIC_CAPTUREP4_INTERVAL_MS * 1000LL;
}
#endif

static void format_countdown_mmss(char *buf, size_t buf_size,
                                  const char *prefix, int64_t remaining_us)
{
    if (remaining_us < 0) {
        remaining_us = 0;
    }
    long secs = (long)((remaining_us + 999999LL) / 1000000LL);
    long mins = secs / 60;
    long sec_rem = secs % 60;
    snprintf(buf, buf_size, "%s %02ld:%02ld", prefix, mins, sec_rem);
}

static void format_lcd_clock_line(time_t now, char *out, size_t out_size)
{
    struct tm ti = {};
    localtime_r(&now, &ti);
    if (ti.tm_year + 1900 >= 2024) {
        int hour12 = ti.tm_hour % 12;
        if (hour12 == 0) hour12 = 12;
        snprintf(out, out_size, "TD:%02d:%02d%s %02d/%02d/%02d",
                 hour12, ti.tm_min, ti.tm_hour < 12 ? "AM" : "PM",
                 ti.tm_mday, ti.tm_mon + 1,
                 (ti.tm_year + 1900) % 100);
    } else {
        uint32_t up = (uint32_t)(esp_timer_get_time() / 1000000LL);
        snprintf(out, out_size, "TD: UP %02lu:%02lu",
                 (unsigned long)(up / 3600),
                 (unsigned long)((up % 3600) / 60));
    }
}

static void format_lcd_slot_page(bool (*predicate)(int), int page,
                                 char *out, size_t out_size)
{
    int skip = page * 3;
    int seen = 0;
    int written_slots = 0;
    size_t pos = 0;
    pos += (size_t)snprintf(out + pos, out_size - pos, "SLOTS:");
    for (int cell = 0; cell < NUM_CELLS && pos < out_size; cell++) {
        if (predicate == NULL || !predicate(cell)) continue;
        if (seen++ < skip) continue;
        int n = snprintf(out + pos, out_size - pos, "%s%02d",
                         written_slots == 0 ? " " : ",", cell + 1);
        if (n < 0 || (size_t)n >= out_size - pos) break;
        pos += (size_t)n;
        if (++written_slots >= 3) break;
    }
}

static bool render_lcd_alert_cycle(time_t now, int64_t now_us,
                                   bool scan_pending)
{
    if (s_lcd.dev == NULL || s_ai_scan_active || scan_pending) {
        s_lcd_alert_page_active = false;
        return false;
    }

    refresh_cell_day_status(now);
    const char *fault_code = equipment_fault_code();
    bool equipment_active = strcmp(fault_code, "none") != 0;
    int abnormal_count = count_cells_matching(cell_abnormal_alert);
    int infertile_count = count_cells_matching(cell_confirmed_infertile);
    int fertile_result_count = count_cells_matching(cell_fertile_result);
    int infertile_result_count = count_cells_matching(cell_infertile_result);
    int removal_count = count_cells_matching(cell_remove_alert);
    int transfer_count = count_cells_matching(cell_transfer_ready);
    int abnormal_pages = (abnormal_count + 2) / 3;
    int infertile_pages = (infertile_count + 2) / 3;
    int transfer_pages = (transfer_count + 2) / 3;
    bool fertility_results_active =
        fertile_result_count + infertile_result_count > 0;
    int warning_pages = (equipment_active ? 1 : 0) +
                        (fertility_results_active ? 1 : 0) + abnormal_pages +
                        infertile_pages + transfer_pages;
    if (warning_pages == 0) {
        s_lcd_alert_page_active = false;
        return false;
    }

    s_lcd_alert_page_active = true;
    int page = (int)((now_us / 3000000LL) % (warning_pages + 1));
    char lines[LCD_ROWS][32] = {};
    if (page == 0) {
        format_lcd_clock_line(now, lines[0], sizeof(lines[0]));
        snprintf(lines[1], sizeof(lines[1]), "EGGS:%d ALERT:%02d",
                 s_last_egg_count, removal_count + transfer_count);
        if (s_main_climate_valid) {
            snprintf(lines[2], sizeof(lines[2]), "MAIN:T:%.1fC H:%.0f%%",
                     s_main_temp, s_main_hum);
        } else {
            snprintf(lines[2], sizeof(lines[2]), "MAIN: --");
        }
        if (s_sub_valid &&
            now_us - s_sub_updated_us < 20LL * 1000000LL) {
            snprintf(lines[3], sizeof(lines[3]), "SUB:T:%.1fC H:%.0f%%",
                     s_sub_temp, s_sub_hum);
        } else {
            snprintf(lines[3], sizeof(lines[3]), "SUB: --");
        }
    } else {
        page--;
        if (equipment_active && page-- == 0) {
            snprintf(lines[0], sizeof(lines[0]), "EQUIPMENT ALERT");
            snprintf(lines[1], sizeof(lines[1]), "%s",
                     equipment_fault_message(fault_code));
            snprintf(lines[2], sizeof(lines[2]), "CODE:%s", fault_code);
            snprintf(lines[3], sizeof(lines[3]), "EGGS STAY SAVED");
        } else if (fertility_results_active && page-- == 0) {
            snprintf(lines[0], sizeof(lines[0]), "CANDLING RESULT");
            snprintf(lines[1], sizeof(lines[1]), "FERTILE:%02d",
                     fertile_result_count);
            snprintf(lines[2], sizeof(lines[2]), "INFERTILE:%02d",
                     infertile_result_count);
            snprintf(lines[3], sizeof(lines[3]), "MOBILE AI RESULT");
        } else if (page < abnormal_pages) {
            snprintf(lines[0], sizeof(lines[0]), "ABNORMAL EGGS");
            format_lcd_slot_page(cell_abnormal_alert, page,
                                 lines[1], sizeof(lines[1]));
            snprintf(lines[2], sizeof(lines[2]), "OPEN DOOR REMOVE");
            snprintf(lines[3], sizeof(lines[3]), "LEDS WILL BLINK");
        } else {
            page -= abnormal_pages;
            if (page < infertile_pages) {
                snprintf(lines[0], sizeof(lines[0]), "INFERTILE EGGS");
                format_lcd_slot_page(cell_confirmed_infertile, page,
                                     lines[1], sizeof(lines[1]));
                snprintf(lines[2], sizeof(lines[2]), "OPEN DOOR REMOVE");
                snprintf(lines[3], sizeof(lines[3]), "LEDS WILL BLINK");
            } else {
                page -= infertile_pages;
                snprintf(lines[0], sizeof(lines[0]), "MOVE TO SUB");
                format_lcd_slot_page(cell_transfer_ready, page,
                                     lines[1], sizeof(lines[1]));
                snprintf(lines[2], sizeof(lines[2]), "DAY 19+ NORMAL");
                snprintf(lines[3], sizeof(lines[3]), "SLOW LED PULSE");
            }
        }
    }

    for (int row = 0; row < LCD_ROWS; row++) {
        lcd_write_line_if_changed(&s_lcd, row, lines[row]);
    }
    return true;
}

// Egg task: guards tray movement and runs egg scans.
// In final mode it scans after the door closes; in temporary mode it scans
// periodically until the magnetic reed switch is installed.
static void egg_task(void *unused)
{
    (void)unused;
    esp_task_wdt_add(NULL);

    static int s_last_minute_lcd = -1;
    static int s_last_day_lcd    = -1;

    constexpr size_t JPEG_BUF_SIZE = 800 * 1024;
    uint8_t *jpeg_buf = NULL;

    bool raw_door_closed = door_switch_is_closed();
    bulb_relay_set_door_open(!raw_door_closed);
    // Boot fail-safe: begin OPEN and qualify a real continuously closed switch.
    bool stable_door_closed = false;
    s3_door_state_set(stable_door_closed);
    int64_t door_changed_us = esp_timer_get_time();
    int64_t scan_due_us = 0;
    int64_t last_scan_attempt_us = 0;
    int64_t last_guidance_renew_us = 0;
#if PERIODIC_CAPTUREP4_ENABLED
    int64_t next_periodic_scan_us = next_periodic_scan_deadline_us();
#endif
    // A closed door at boot is qualified below before a scan is scheduled.
    bool scan_pending = false;
#if PERIODIC_CAPTUREP4_ENABLED
    bool scan_pending_from_periodic = false;
#endif
    bool scan_disabled_lcd_shown = false;
    bool lcd_alert_was_managed = false;

    if (!p4_counter_scan_enabled()) {
        ESP_LOGW(TAG, "P4 egg counter scan/timer disabled; RTC display remains active");
    } else {
#if PERIODIC_CAPTUREP4_ENABLED
        ESP_LOGI(TAG, "Temporary periodic /capturep4 scan mode active: every %d ms",
                 PERIODIC_CAPTUREP4_INTERVAL_MS);
#else
        ESP_LOGI(TAG, "Door-triggered scan mode active: open tray, place eggs, close tray");
#endif
        if (scan_pending) {
            ESP_LOGI(TAG, "Booted with door closed - scan scheduled in %d ms",
                     DOOR_CLOSE_SCAN_DELAY_MS);
        }
    }

    while (true) {
        vTaskDelay(pdMS_TO_TICKS(DOOR_TASK_TICK_MS));
        esp_task_wdt_reset();
        tray_motor_apply_requested_state();

        int64_t now_us = esp_timer_get_time();
        bulb_relay_service();
        time_t    now = time(NULL);
        struct tm ti;
        localtime_r(&now, &ti);

        // Door-light ownership is independent of the scanner. It therefore
        // remains available in AI safe mode or after a persistent-state fault.
        bool door_state_changed = false;
        bool current_raw_door_closed = door_switch_is_closed();
        if (current_raw_door_closed != raw_door_closed) {
            raw_door_closed = current_raw_door_closed;
            door_changed_us = now_us;
        }

        int door_debounce_ms = current_raw_door_closed
            ? DOOR_CLOSE_DEBOUNCE_MS
            : DOOR_OPEN_DEBOUNCE_MS;
        if (current_raw_door_closed != stable_door_closed &&
            (now_us - door_changed_us) >= (int64_t)door_debounce_ms * 1000LL) {
            stable_door_closed = current_raw_door_closed;
            bulb_relay_set_door_open(!stable_door_closed);
            door_state_changed = true;
        }

        // LCD line 0: clock.
        if (s_lcd.dev != NULL) {
            if (ti.tm_min != s_last_minute_lcd || ti.tm_mday != s_last_day_lcd) {
                char buf[32];
                lcd_clear_line(&s_lcd, 0);
                lcd_set_cursor(&s_lcd, 0, 0);
                if (ti.tm_year + 1900 >= 2024) {
                    int yr2 = (ti.tm_year + 1900) % 100;
                    int hour12 = ti.tm_hour % 12;
                    if (hour12 == 0) {
                        hour12 = 12;
                    }
                    const char *ampm = ti.tm_hour < 12 ? "AM" : "PM";
                    snprintf(buf, sizeof(buf), "TD:%02d:%02d%s %02d/%02d/%02d",
                             hour12, ti.tm_min, ampm,
                             ti.tm_mday, ti.tm_mon + 1, yr2);
                } else {
                    uint32_t up = (uint32_t)(esp_timer_get_time() / 1000000);
                    snprintf(buf, sizeof(buf), "TD: UP %02d:%02d",
                             (int)(up / 3600), (int)((up % 3600) / 60));
                }
                lcd_write_string(&s_lcd, buf);
                s_last_minute_lcd = ti.tm_min;
                s_last_day_lcd    = ti.tm_mday;
            }
        }

        if (!p4_counter_scan_enabled()) {
            if (s_lcd.dev != NULL && !scan_disabled_lcd_shown) {
                lcd_clear_line(&s_lcd, 3);
                lcd_set_cursor(&s_lcd, 0, 3);
                lcd_write_string(&s_lcd, "SCAN DISABLED");
                scan_disabled_lcd_shown = true;
            }
            continue;
        }
        if (s_persistent_state_fault) {
            render_lcd_alert_cycle(now, now_us, false);
            continue;
        }
        scan_disabled_lcd_shown = false;

        if (door_state_changed) {
            s3_door_state_set(stable_door_closed);
            if (stable_door_closed) {
                scan_pending = true;
                s_scan_retry_count = 0;
                s_last_scan_failure = SCAN_FAIL_NONE;
#if PERIODIC_CAPTUREP4_ENABLED
                scan_pending_from_periodic = false;
#endif
                scan_due_us = now_us + (int64_t)DOOR_CLOSE_SCAN_DELAY_MS * 1000LL;
                ESP_LOGI(TAG, "Door closed - scan scheduled in %d ms",
                         DOOR_CLOSE_SCAN_DELAY_MS);
                // Door shut: stop both physical guidance patterns immediately.
                led_controller_guidance_stop();
                last_guidance_renew_us = 0;
            } else {
                scan_pending = false;
                s_scan_retry_count = 0;
#if PERIODIC_CAPTUREP4_ENABLED
                scan_pending_from_periodic = false;
#endif
                ESP_LOGI(TAG, "Door opened - pending scan cancelled");
                // ABNORMAL/confirmed-infertile eggs double-flash; normal
                // day-19+ eggs slow-pulse. The controller enforces a lease.
                led_controller_send_guidance();
                last_guidance_renew_us = now_us;
            }
        }

        if (!stable_door_closed && !raw_door_closed &&
            now_us - door_changed_us >=
                (int64_t)DOOR_OPEN_DEBOUNCE_MS * 1000LL &&
            (last_guidance_renew_us == 0 ||
             now_us - last_guidance_renew_us >=
                 (int64_t)LED_GUIDANCE_RENEW_MS * 1000LL)) {
            led_controller_send_guidance();
            last_guidance_renew_us = now_us;
        }

#if PERIODIC_CAPTUREP4_ENABLED
        if (!scan_pending && stable_door_closed && now_us >= next_periodic_scan_us) {
            scan_pending = true;
            scan_pending_from_periodic = true;
            scan_due_us = now_us;
            ESP_LOGI(TAG, "Periodic /capturep4 scan scheduled");
        }
#endif

        bool lcd_alert_managed = render_lcd_alert_cycle(
            now, now_us, scan_pending);
        if (lcd_alert_was_managed && !lcd_alert_managed) {
            s_last_minute_lcd = -1;
            s_last_day_lcd = -1;
            memset(s_lcd_line_cache_valid, 0,
                   sizeof(s_lcd_line_cache_valid));
        }
        lcd_alert_was_managed = lcd_alert_managed;

        if (s_lcd.dev != NULL && !lcd_alert_managed) {
            char buf[32];
            if (s_climate_sensor_fault) {
                snprintf(buf, sizeof(buf), "HEATER/FANS SAFE OFF");
            } else if (!stable_door_closed) {
                snprintf(buf, sizeof(buf), "DOOR OPEN");
            } else if (scan_pending) {
                int64_t remaining_us = scan_due_us - now_us;
                const char *prefix = scan_failure_is_s3_recovery(
                    s_last_scan_failure) ? "S3 RETRY" :
                    (s_scan_retry_count > 0 ? "SCAN RETRY" : "SCAN IN");
                format_countdown_mmss(buf, sizeof(buf), prefix, remaining_us);
            } else if (s_sub_valid &&
                       (now_us - s_sub_updated_us) < 20LL * 1000000LL) {
                // Door closed & idle: show the sub-incubator T/H (from S3).
                snprintf(buf, sizeof(buf), "SUB: T:%.1fC H:%.0f%%",
                         s_sub_temp, s_sub_hum);
            } else {
                snprintf(buf, sizeof(buf), "SUB: --");
            }
            lcd_write_line_if_changed(&s_lcd, 3, buf);
        }

        if (!scan_pending || !stable_door_closed || now_us < scan_due_us) {
            continue;
        }

        if (last_scan_attempt_us != 0 &&
            (now_us - last_scan_attempt_us) < (int64_t)DOOR_SCAN_LOCKOUT_MS * 1000LL) {
            scan_due_us = last_scan_attempt_us +
                          (int64_t)DOOR_SCAN_LOCKOUT_MS * 1000LL;
            ESP_LOGW(TAG, "Scan lockout active; request retained for later retry");
            continue;
        }

#if PERIODIC_CAPTUREP4_ENABLED
        bool active_scan_from_periodic = scan_pending_from_periodic;
#endif
        auto finish_periodic_scan = [&]() {
#if PERIODIC_CAPTUREP4_ENABLED
            if (active_scan_from_periodic) {
                next_periodic_scan_us = next_periodic_scan_deadline_us();
            }
#endif
        };

        auto schedule_scan_retry = [&](ScanFailureReason reason,
                                       const char *context) {
            s_last_scan_failure = reason;
            uint32_t retry_count = s_scan_retry_count;
            if (retry_count < UINT32_MAX) retry_count++;
            s_scan_retry_count = retry_count;
            scan_pending = true;
            scan_due_us = esp_timer_get_time() +
                          (int64_t)SCAN_RETRY_COOLDOWN_MS * 1000LL;
#if PERIODIC_CAPTUREP4_ENABLED
            scan_pending_from_periodic = false;
#endif
            finish_periodic_scan();
            ESP_LOGW(TAG,
                     "%s; keeping verified tray and retrying /capturep4 in %d seconds (retry %lu)",
                     context, SCAN_RETRY_COOLDOWN_MS / 1000,
                     (unsigned long)s_scan_retry_count);
            lcd_show_scan_failure(reason);
            vTaskDelay(pdMS_TO_TICKS(1300));
        };

        scan_pending = false;
#if PERIODIC_CAPTUREP4_ENABLED
        scan_pending_from_periodic = false;
#endif

        if (!s_ai_inference_runtime_enabled) {
            ESP_LOGW(TAG, "AI inference safe mode active; scan skipped to prevent reboot loop");
            schedule_scan_retry(SCAN_FAIL_AI, "AI safe mode active");
            continue;
        }

        // SCAN SEQUENCE
        // 1. Check WiFi and the S3 HTTP server while normal incubation remains
        // active. A missing S3 must not stop the tray, pause SHT3x monitoring,
        // or cycle the climate relays every thirty seconds.
        if (s_lcd.dev) {
            lcd_clear_line(&s_lcd, 3);
            lcd_set_cursor(&s_lcd, 0, 3);
            lcd_write_string(&s_lcd, "CHECKING S3");
        }
        if (wifi_connect() != ESP_OK) {
            ESP_LOGE(TAG, "WiFi failed during door-triggered scan");
            schedule_scan_retry(SCAN_FAIL_WIFI, "WiFi connection failed");
            continue;
        }
        if (!door_switch_is_closed()) {
            ESP_LOGI(TAG, "Door opened before S3 readiness check - scan cancelled");
            finish_periodic_scan();
            continue;
        }
        if (!s3_server_reachable()) {
            schedule_scan_retry(SCAN_FAIL_S3_OFFLINE,
                                "S3 camera host is not reachable");
            continue;
        }

        // Allocate before entering scan mode so a memory failure also leaves
        // the incubator operating normally during the retry wait.
        if (jpeg_buf == NULL) {
            jpeg_buf = (uint8_t *)heap_caps_malloc(
                JPEG_BUF_SIZE, MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
            if (!jpeg_buf) {
                ESP_LOGE(TAG, "Cannot alloc JPEG buffer");
                schedule_scan_retry(SCAN_FAIL_MEMORY, "JPEG buffer allocation failed");
                continue;
            }
        }

        // The S3 is alive and memory is ready. Only now enter the short scan
        // phase where sensor sampling is paused and the tray is settled.
        ScanActiveGuard scan_guard;
        if (!scan_guard.ready()) {
            ScanFailureReason blocked_reason = scan_guard.storage_failed()
                ? SCAN_FAIL_STATE
                : (scan_guard.timed_out() ? SCAN_FAIL_TIMEOUT : SCAN_FAIL_BUSY);
            schedule_scan_retry(
                blocked_reason,
                blocked_reason == SCAN_FAIL_STATE
                    ? "Durable scan transaction could not be started"
                    : (blocked_reason == SCAN_FAIL_BUSY
                        ? "Scan deferred while an app hardware operation is active"
                        : "Scan hard deadline could not be armed"));
            continue;
        }

        // 2. Stop the tray wherever it is, then let the image settle.
        scan_phase_set(SCAN_PHASE_TRAY_SETTLE);
        if (s_lcd.dev) {
            lcd_clear_line(&s_lcd, 3);
            lcd_set_cursor(&s_lcd, 0, 3);
            lcd_write_string(&s_lcd, "TRAY STOPPED");
        }
        if (!tray_motor_stop_and_settle_for_capture()) {
            ESP_LOGW(TAG, "Door opened during tray settle - scan cancelled");
            if (s_lcd.dev) {
                lcd_clear_line(&s_lcd, 3);
                lcd_set_cursor(&s_lcd, 0, 3);
                lcd_write_string(&s_lcd, "DOOR OPEN");
            }
            tray_motor_request(true);
            finish_periodic_scan();
            continue;
        }
        last_scan_attempt_us = esp_timer_get_time();

        // 3. Capture a fresh normal-light image. Force the main bulb ON for
        // consistent /capturep4 illumination even when temperature control
        // does not currently request heat. The guard releases this override
        // on every failure/exit path.
        scan_phase_set(SCAN_PHASE_NORMAL_CAPTURE);
        if (s_lcd.dev) {
            lcd_clear_line(&s_lcd, 3);
            lcd_set_cursor(&s_lcd, 0, 3);
            lcd_write_string(&s_lcd, "CAPTURING...");
        }
        NormalCaptureBulbGuard normal_capture_bulb;
        ESP_LOGI(TAG,
                 "Normal capture light ready; settling bulb for %d ms before /capturep4",
                 NORMAL_CAPTURE_BULB_SETTLE_MS);
        vTaskDelay(pdMS_TO_TICKS(NORMAL_CAPTURE_BULB_SETTLE_MS));
        esp_task_wdt_reset();
        if (scan_guard.timed_out()) {
            schedule_scan_retry(SCAN_FAIL_TIMEOUT,
                                "Scan timed out while preparing normal capture light");
            continue;
        }
        if (!door_switch_is_closed()) {
            ESP_LOGI(TAG, "Door opened while normal capture light was settling - scan cancelled");
            tray_motor_request(true);
            finish_periodic_scan();
            continue;
        }
        size_t jpeg_len = 0;
        ScanFailureReason failure_reason = SCAN_FAIL_CAPTURE;
        bool capture_ok = capture_jpeg(
            jpeg_buf, JPEG_BUF_SIZE, &jpeg_len, &failure_reason) == ESP_OK;

        if (scan_guard.timed_out()) {
            if (jpeg_len > 0) memset(jpeg_buf, 0, jpeg_len);
            schedule_scan_retry(SCAN_FAIL_TIMEOUT,
                                "Scan timed out during capture/download");
            continue;
        }

        // 4. Validate capture result before AI processing.
        if (!capture_ok) {
            if (!door_switch_is_closed()) {
                ESP_LOGI(TAG, "Door opened during failed capture - retry cancelled");
                tray_motor_request(true);
                finish_periodic_scan();
                continue;
            }
            tray_motor_resume_with_power_stagger("capture failure");
            schedule_scan_retry(failure_reason, "Capture/download validation failed");
            continue;
        }
        if (!door_switch_is_closed()) {
            ESP_LOGI(TAG, "Door opened after capture - image discarded");
            memset(jpeg_buf, 0, jpeg_len);
            tray_motor_request(true);
            finish_periodic_scan();
            continue;
        }

        // The HTTP client has received and validated the full JPEG. Keep the
        // capture bulb ON and leave all other outputs untouched while the S3
        // finishes its capture-handler cleanup; only then enter AI mode.
        scan_phase_set(SCAN_PHASE_NORMAL_DOWNLOAD_SETTLE);
        if (s_lcd.dev) {
            lcd_clear_line(&s_lcd, 3);
            lcd_set_cursor(&s_lcd, 0, 3);
            lcd_write_string(&s_lcd, "IMAGE DOWNLOADED");
        }
        ESP_LOGI(TAG,
                 "JPEG download complete and validated (%zu bytes); settling %d ms before AI focus power",
                 jpeg_len, POST_CAPTURE_DOWNLOAD_SETTLE_MS);
        vTaskDelay(pdMS_TO_TICKS(POST_CAPTURE_DOWNLOAD_SETTLE_MS));
        esp_task_wdt_reset();

        if (scan_guard.timed_out()) {
            memset(jpeg_buf, 0, jpeg_len);
            schedule_scan_retry(SCAN_FAIL_TIMEOUT,
                                "Scan timed out while preparing AI");
            continue;
        }

        if (!door_switch_is_closed()) {
            ESP_LOGI(TAG, "Door opened while downloaded image was settling - image discarded");
            memset(jpeg_buf, 0, jpeg_len);
            tray_motor_request(true);
            finish_periodic_scan();
            continue;
        }

        // The normal image and its transfer are complete. Temperature control
        // owns the bulb again; the following AI guard then forces it OFF along
        // with the other high-current outputs for inference.
        normal_capture_bulb.release();

        if (s_lcd.dev) {
            lcd_clear_line(&s_lcd, 3);
            lcd_set_cursor(&s_lcd, 0, 3);
            lcd_write_string(&s_lcd, "PREPARING AI");
        }

        bool scan_ok = false;
        const char *scan_failure_context = "AI scan validation failed";
        IntakeTargetMask intake_targets = {};
        {
            InferencePowerGuard power_guard;
            ESP_LOGI(TAG,
                     "AI focus power active; waiting %d ms for relay/power settling",
                     AI_FOCUS_POWER_SETTLE_MS);
            vTaskDelay(pdMS_TO_TICKS(AI_FOCUS_POWER_SETTLE_MS));
            esp_task_wdt_reset();

            scan_phase_set(SCAN_PHASE_NORMAL_INFERENCE);
            {
                // A reset in the model invocation itself activates AI safe
                // mode. The following HTTP candling capture is outside this
                // marker so a camera/network reset is diagnosed separately.
                InferenceResetGuard reset_guard;
                scan_ok = process_scan_jpeg(
                    jpeg_buf, jpeg_len, &failure_reason);
            }

            if (scan_ok && !scan_guard.timed_out() &&
                door_switch_is_closed() &&
                AUTOMATIC_INTAKE_SCREENING_ENABLED) {
                scan_phase_set(SCAN_PHASE_TARGET_SELECTION);
                intake_targets = build_intake_target_mask(
                    scan_guard.baseline_state());
                if (intake_targets.combined_count == 0) {
                    ESP_LOGI(TAG,
                             "No new, replacement, or pending occupied slots; candled capture skipped");
                } else {
                    ESP_LOGI(TAG,
                             "Intake targets selected: new=%d replacement=%d pending=%d combined=%d",
                             intake_targets.new_count,
                             intake_targets.replacement_count,
                             intake_targets.pending_count,
                             intake_targets.combined_count);
                    scan_ok = capture_intake_targets(
                        &intake_targets, jpeg_buf, JPEG_BUF_SIZE,
                        &failure_reason);
                    if (!scan_ok) {
                        scan_failure_context =
                            "Intake candling capture/validation failed";
                    }
                }
            } else if (scan_ok && !AUTOMATIC_INTAKE_SCREENING_ENABLED) {
                for (int cell = 0; cell < NUM_CELLS; cell++) {
                    if (s_cell_has_egg[cell] &&
                        s_candidate_fingerprint[cell].valid) {
                        s_slot_fingerprint[cell] =
                            s_candidate_fingerprint[cell];
                    }
                    s_pending_verification_slots[cell] = false;
                    if (s_intake_verdict[cell] == INTAKE_VERDICT_PENDING) {
                        s_intake_verdict[cell] = INTAKE_VERDICT_NONE;
                    }
                }
                ESP_LOGI(TAG,
                         "Automatic intake screening skipped by release delimitation; egg-count scan complete");
            }
        }

        if (scan_guard.timed_out()) {
            failure_reason = SCAN_FAIL_TIMEOUT;
            scan_ok = false;
        }

        // 5. Validate AI scan result before saving.
        if (!scan_ok) {
            if (!door_switch_is_closed()) {
                ESP_LOGI(TAG, "Door opened during AI - retry cancelled");
                tray_motor_request(true);
                finish_periodic_scan();
                continue;
            }
            tray_motor_resume_with_power_stagger("scan failure");
            schedule_scan_retry(failure_reason, scan_failure_context);
            continue;
        }
        if (!door_switch_is_closed()) {
            ESP_LOGW(TAG, "Door opened before scan commit - snapshot not saved");
            tray_motor_request(true);
            finish_periodic_scan();
            continue;
        }
        if (scan_guard.timed_out()) {
            schedule_scan_retry(SCAN_FAIL_TIMEOUT,
                                "Scan timed out before result commit");
            continue;
        }

        scan_phase_set(SCAN_PHASE_COMMIT);
        s_last_scan_failure = SCAN_FAIL_NONE;
        s_scan_retry_count = 0;

        if (s_lcd.dev) {
            lcd_clear_line(&s_lcd, 3);
            lcd_set_cursor(&s_lcd, 0, 3);
            lcd_write_string(&s_lcd, "DONE SCANNING");
        }

        // 6. Store only the final egg-data snapshot in NVS. Images and AI
        // work buffers stay temporary in PSRAM/RAM and are not saved.
        s_last_scan_mday = ti.tm_mday; // legacy last-scan day field for NVS/logging
        if (!add_egg_snapshot()) {
            schedule_scan_retry(SCAN_FAIL_STATE,
                                "Completed scan could not be committed to NVS");
            continue;
        }
        scan_guard.mark_state_committed();
        tray_motor_resume_with_power_stagger("NVS save");

        // 7. Update egg-count line on LCD
        if (s_lcd.dev) {
            char buf[32];
            snprintf(buf, sizeof(buf), "EGGS:%d", s_last_egg_count);
            lcd_clear_line(&s_lcd, 1);
            lcd_set_cursor(&s_lcd, 0, 1);
            lcd_write_string(&s_lcd, buf);
        }

        finish_periodic_scan();
        vTaskDelay(pdMS_TO_TICKS(2000));
    }
}

static const char *reset_reason_name(esp_reset_reason_t reason)
{
    switch (reason) {
        case ESP_RST_POWERON: return "POWERON";
        case ESP_RST_EXT: return "EXT";
        case ESP_RST_SW: return "SW";
        case ESP_RST_PANIC: return "PANIC";
        case ESP_RST_INT_WDT: return "INT_WDT";
        case ESP_RST_TASK_WDT: return "TASK_WDT";
        case ESP_RST_WDT: return "WDT";
        case ESP_RST_DEEPSLEEP: return "DEEPSLEEP";
        case ESP_RST_BROWNOUT: return "BROWNOUT";
        case ESP_RST_SDIO: return "SDIO";
        case ESP_RST_USB: return "USB";
        case ESP_RST_JTAG: return "JTAG";
        case ESP_RST_EFUSE: return "EFUSE";
        case ESP_RST_PWR_GLITCH: return "PWR_GLITCH";
        case ESP_RST_CPU_LOCKUP: return "CPU_LOCKUP";
        default: return "UNKNOWN";
    }
}

static void ai_inference_boot_safety_check(esp_reset_reason_t reset_reason)
{
    bool guard_active = rtc_marker_is_set(s_ai_inference_guard_magic,
                                          s_ai_inference_guard_inverse,
                                          AI_INFERENCE_GUARD_MAGIC);
    bool disabled_latched = rtc_marker_is_set(s_ai_inference_disabled_magic,
                                              s_ai_inference_disabled_inverse,
                                              AI_INFERENCE_DISABLED_MAGIC);

    if (reset_reason == ESP_RST_POWERON) {
        ai_inference_guard_set(false);
        ai_inference_disabled_latch_set(false);
        s_ai_inference_runtime_enabled = (AI_INFERENCE_ENABLED != 0);
        return;
    }

    if (guard_active) {
        ESP_LOGE(TAG, "Previous reset happened during AI inference; AI scans disabled until power cycle");
        ai_inference_guard_set(false);
        ai_inference_disabled_latch_set(true);
        disabled_latched = true;
    }

    s_ai_inference_runtime_enabled =
        (AI_INFERENCE_ENABLED != 0) && !disabled_latched;

    if (!s_ai_inference_runtime_enabled) {
        ESP_LOGW(TAG, "AI inference safe mode active; periodic scans will be skipped");
    }
}

extern "C" void app_main(void)
{
    esp_reset_reason_t reset_reason = esp_reset_reason();
    ESP_LOGI(TAG, "Reset reason: %s (%d)",
             reset_reason_name(reset_reason), (int)reset_reason);
    ai_inference_boot_safety_check(reset_reason);

    esp_err_t ret = nvs_flash_init();
    if (ret == ESP_ERR_NVS_NO_FREE_PAGES || ret == ESP_ERR_NVS_NEW_VERSION_FOUND) {
        ESP_ERROR_CHECK(nvs_flash_erase());
        ESP_ERROR_CHECK(nvs_flash_init());
    }
    setenv("TZ", "PHT-8", 1);
    tzset();

    grid_load_config();
    door_switch_init();
    relay_gpio_init();
    i2c_init();
    rtc_init();
    sht3x_init();

    nvs_load_snapshots();   // restore snapshots + last_scan_mday from flash
    s_state_mutex = xSemaphoreCreateMutex();
    ESP_ERROR_CHECK(s_state_mutex != NULL ? ESP_OK : ESP_ERR_NO_MEM);
#if ENABLE_DIAGNOSTIC_ALERT_API
    diagnostic_backup_boot_check();
#endif
    apply_release_intake_delimitation();

    if (lcd_init(&s_lcd, s_i2c_bus, LCD_I2C_ADDR) == ESP_OK) {
        ESP_LOGI(TAG, "LCD initialized at 0x%02X", LCD_I2C_ADDR);
        lcd_clear(&s_lcd);

        if (reset_reason == ESP_RST_POWERON) {
            lcd_set_cursor(&s_lcd, 0, 0);
            lcd_write_string(&s_lcd, "WELCOME TO");
            lcd_set_cursor(&s_lcd, 0, 1);
            lcd_write_string(&s_lcd, "AI-POWERED");
            lcd_set_cursor(&s_lcd, 0, 2);
            lcd_write_string(&s_lcd, "SMART INCUBATOR");
            lcd_set_cursor(&s_lcd, 0, 3);
            lcd_write_string(&s_lcd, "PLEASE WAIT");
            vTaskDelay(pdMS_TO_TICKS(3000));
            lcd_clear(&s_lcd);
        }

        char egg_line[32];
        snprintf(egg_line, sizeof(egg_line), "EGGS:%d", s_last_egg_count);
        lcd_set_cursor(&s_lcd, 0, 1);
        lcd_write_string(&s_lcd, egg_line);
        lcd_set_cursor(&s_lcd, 0, 2);
        lcd_write_string(&s_lcd, "MAIN: --");
    } else {
        ESP_LOGW(TAG, "LCD not found at 0x%02X - check wiring", LCD_I2C_ADDR);
    }

    wifi_init();
    http_server_start();   // P4 data/control endpoints for the mobile app via S3

    esp_task_wdt_config_t wdt_cfg = {
        .timeout_ms    = 600000,
        .idle_core_mask = 0,
        .trigger_panic  = false,
    };
    esp_task_wdt_reconfigure(&wdt_cfg);

    xTaskCreate(egg_task,      "egg_task",    16384, NULL, 5, NULL);
    xTaskCreate(sensor_task,   "sensor_task",  8192, NULL, 5, NULL);
    xTaskCreate(sub_sensor_fetch_task, "sub_fetch", 6144, NULL, 4, NULL);
}
