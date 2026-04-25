#include <Adafruit_GFX.h>
#include <Adafruit_ST7789.h>
#include <SPI.h>
#include <math.h>
#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLEUtils.h>
#include <BLE2902.h>
#include <pgmspace.h>

// =========================================================
//  Buddy — Multi-mascot Bluetooth Pet
//  Receives agent status over BLE, displays matching mascot
//  Button: short=next mascot, long=toggle demo mode
// =========================================================

// --- LCD pins (board-fixed) ---
#define TFT_MOSI 6
#define TFT_SCLK 7
#define TFT_CS   14
#define TFT_DC   15
#define TFT_RST  21
#define TFT_BL   22

// --- Button ---
#define BTN_PIN  9

// --- Display ---
#define BACKLIGHT_ACTIVE_HIGH true
#define LCD_W    172
#define LCD_H    320
#define LCD_ROT  0
#define DEBOUNCE_MS 30
#define LONG_PRESS_MS 600

// --- Backlight PWM (reduce heat) ---
#define BL_PWM_CHANNEL  0
#define BL_PWM_FREQ     5000
#define BL_PWM_BITS     8
#define BL_BRIGHT_ACTIVE  180   // 0-255, lower = cooler (default was 255)
#define BL_BRIGHT_SLEEP    80   // dimmer in sleep scene
#define BL_BRIGHT_IDLE     40   // very dim after idle timeout
#define BL_IDLE_TIMEOUT_MS 30000UL

// --- Frame rate control ---
#define FPS_ACTIVE  25
#define FPS_SLEEP   10
#define FRAME_MS_ACTIVE (1000 / FPS_ACTIVE)
#define FRAME_MS_SLEEP  (1000 / FPS_SLEEP)

Adafruit_ST7789 tft(TFT_CS, TFT_DC, TFT_RST);
GFXcanvas16 canvas(LCD_W, LCD_H);
GFXcanvas16* gfx = &canvas;

// --- BLE UUIDs ---
// Device name is generated at runtime as "Buddy-XXXXXX" using the lower
// 24 bits of the eFuse MAC, so multiple Buddies can be distinguished.
#define BLE_DEVICE_NAME_PREFIX "Buddy-"
#define BLE_DEVICE_NAME_LEN  16   // "Buddy-" + 6 hex + NUL + headroom
static char bleDeviceName[BLE_DEVICE_NAME_LEN] = "Buddy";
#define SERVICE_UUID         "0000beef-0000-1000-8000-00805f9b34fb"
#define CHARACTERISTIC_UUID  "0000beef-0001-1000-8000-00805f9b34fb"
#define NOTIFY_CHAR_UUID     "0000beef-0002-1000-8000-00805f9b34fb"

// --- Buddy config frames ---
#define BUDDY_BRIGHTNESS_FRAME          0xFE
#define BUDDY_ORIENTATION_FRAME         0xFD
#define BUDDY_BRIGHTNESS_MIN_PERCENT    10
#define BUDDY_BRIGHTNESS_MAX_PERCENT    100
#define BUDDY_BRIGHTNESS_DEFAULT_PERCENT 70
#define BUDDY_SCREEN_UP                 0
#define BUDDY_SCREEN_DOWN               1

// QR code for https://github.com/wxtsky/CodeIsland (version 3, ECC M, border 2).
#define CODEISLAND_QR_SIZE 33
#define CODEISLAND_QR_SCALE 4
static const char CODEISLAND_QR[CODEISLAND_QR_SIZE][CODEISLAND_QR_SIZE + 1] PROGMEM = {
  "000000000000000000000000000000000",
  "000000000000000000000000000000000",
  "001111111011101101000110111111100",
  "001000001010010100000010100000100",
  "001011101001110000001110101110100",
  "001011101011100011010010101110100",
  "001011101001001011100100101110100",
  "001000001001110100110100100000100",
  "001111111010101010101010111111100",
  "000000000011111001111010000000000",
  "001011011101110101111010100101100",
  "000110100100110110110110111000100",
  "000100111011111100110001010011000",
  "001111000001000000101011101000100",
  "000001011111010011011010000110000",
  "001010110011111011100100100011100",
  "001000101010000100111110100011100",
  "000000010000001011100111111001000",
  "000011101101011011011110001101000",
  "000001000111010011000000010111000",
  "001010001110111111111010111010000",
  "000011000101110111011000111010000",
  "000111011001111110011011111110000",
  "000000000010001000111010001111100",
  "001111111011001010101110101101000",
  "001000001011011110101010001100100",
  "001011101001000000010011111010000",
  "001011101010001100110101011100100",
  "001011101011010100001010010010100",
  "001000001000010111101011010101000",
  "001111111010101100001111100001000",
  "000000000000000000000000000000000",
  "000000000000000000000000000000000",
};

// --- Agent state from BLE ---
volatile uint8_t  bleSourceId = 0;    // 0=claude, 1=codex, ...
volatile uint8_t  bleStatusId = 0;    // 0=idle, 1=processing, 2=running, 3=waitApproval, 4=waitQuestion
volatile bool     bleConnected = false;
volatile unsigned long lastBleData = 0;
volatile uint8_t  buddyBrightnessPercent = BUDDY_BRIGHTNESS_DEFAULT_PERCENT;
volatile uint8_t  buddyScreenOrientation = BUDDY_SCREEN_UP;
volatile bool     buddyOrientationDirty = false;
char              bleToolName[18] = {0};
BLECharacteristic* pNotifyChar = nullptr;
portMUX_TYPE      bleMux = portMUX_INITIALIZER_UNLOCKED;

// --- Scenes ---
enum Scene { SCENE_SLEEP, SCENE_WORK, SCENE_ALERT, SCENE_COUNT };

// --- App mode ---
enum AppMode { MODE_ONBOARD, MODE_DEMO, MODE_AGENT };
volatile AppMode appMode = MODE_ONBOARD;
bool hasEverConnected = false;

// --- Include all mascot headers ---
#include "mascot_common.h"
#include "mascot_clawd.h"
#include "mascot_dex.h"
#include "mascot_gemini.h"
#include "mascot_cursor.h"
#include "mascot_copilot.h"
#include "mascot_trae.h"
#include "mascot_qoder.h"
#include "mascot_droid.h"
#include "mascot_buddy.h"
#include "mascot_stepfun.h"
#include "mascot_opencode.h"
#include "mascot_qwen.h"
#include "mascot_antigrav.h"
#include "mascot_workbuddy.h"
#include "mascot_hermes.h"
#include "mascot_kimi.h"

// --- Mascot function pointer table ---
typedef void (*DrawFunc)(float t);

struct Mascot {
  DrawFunc sleep;
  DrawFunc work;
  DrawFunc alert;
  const char* name;
};

#define NUM_MASCOTS 16

Mascot mascots[NUM_MASCOTS] = {
  { clawdSleep,     clawdWork,     clawdAlert,     "Claude"      },  // 0
  { dexSleep,       dexWork,       dexAlert,       "Codex"       },  // 1
  { geminiSleep,    geminiWork,    geminiAlert,    "Gemini"      },  // 2
  { cursorSleep,    cursorWork,    cursorAlert,    "Cursor"      },  // 3
  { copilotSleep,   copilotWork,   copilotAlert,   "Copilot"     },  // 4
  { traeSleep,      traeWork,      traeAlert,      "Trae"        },  // 5
  { qoderSleep,     qoderWork,     qoderAlert,     "Qoder"       },  // 6
  { droidSleep,     droidWork,     droidAlert,     "Factory"     },  // 7
  { buddySleep,     buddyWork,     buddyAlert,     "CodeBuddy"   },  // 8
  { stepfunSleep,   stepfunWork,   stepfunAlert,   "StepFun"     },  // 9
  { opencodeSleep,  opencodeWork,  opencodeAlert,  "OpenCode"    },  // 10
  { qwenSleep,      qwenWork,      qwenAlert,      "Qwen"        },  // 11
  { antigravSleep,  antigravWork,  antigravAlert,  "AntiGravity" },  // 12
  { workbuddySleep, workbuddyWork, workbuddyAlert, "WorkBuddy"  },  // 13
  { hermesSleep,    hermesWork,    hermesAlert,    "Hermes"      },  // 14
  { kimiSleep,      kimiWork,      kimiAlert,      "Kimi"        },  // 15
};

// --- Mode ---
uint8_t currentMascotIdx = 0;
Scene currentScene = SCENE_SLEEP;
#define AUTO_CYCLE_MS 8000UL
#define BLE_TIMEOUT_MS 60000UL
unsigned long lastSceneChange = 0;
unsigned long lastInteraction = 0;
unsigned long lastFrameTime = 0;
uint8_t currentBrightness = BL_BRIGHT_ACTIVE;

// --- Logging ---
#define LOG_INTERVAL_MS 2000UL
unsigned long lastLogTime = 0;
unsigned long frameCount = 0;
unsigned long loopCount = 0;
unsigned long lastFpsCalcTime = 0;
float currentFps = 0;

static const char* sceneStr(Scene s) {
  switch (s) {
    case SCENE_SLEEP: return "SLEEP";
    case SCENE_WORK:  return "WORK";
    case SCENE_ALERT: return "ALERT";
    default:          return "?";
  }
}

static const char* appModeStr(AppMode m) {
  switch (m) {
    case MODE_ONBOARD: return "ONBOARD";
    case MODE_DEMO:    return "DEMO";
    case MODE_AGENT:   return "AGENT";
    default:           return "?";
  }
}

static const char* statusStr(uint8_t s) {
  switch (s) {
    case 0: return "idle";
    case 1: return "processing";
    case 2: return "running";
    case 3: return "waitApproval";
    case 4: return "waitQuestion";
    default: return "unknown";
  }
}

uint8_t clampBuddyBrightness(uint8_t percent) {
  if (percent < BUDDY_BRIGHTNESS_MIN_PERCENT) return BUDDY_BRIGHTNESS_MIN_PERCENT;
  if (percent > BUDDY_BRIGHTNESS_MAX_PERCENT) return BUDDY_BRIGHTNESS_MAX_PERCENT;
  return percent;
}

uint8_t clampBuddyOrientation(uint8_t orientation) {
  return orientation == BUDDY_SCREEN_DOWN ? BUDDY_SCREEN_DOWN : BUDDY_SCREEN_UP;
}

uint8_t tftRotationForBuddyOrientation(uint8_t orientation) {
  return orientation == BUDDY_SCREEN_DOWN ? (uint8_t)((LCD_ROT + 2) % 4) : LCD_ROT;
}

const char* buddyOrientationStr(uint8_t orientation) {
  return orientation == BUDDY_SCREEN_DOWN ? "down" : "up";
}

void applyBuddyScreenOrientation(uint8_t orientation) {
  uint8_t clamped = clampBuddyOrientation(orientation);
  tft.setRotation(tftRotationForBuddyOrientation(clamped));
  tft.fillScreen(0x0000);
}

uint8_t scaledBrightness(uint8_t base) {
  uint8_t percent = buddyBrightnessPercent;
  uint16_t scaled = (uint16_t)base * percent / BUDDY_BRIGHTNESS_DEFAULT_PERCENT;
  if (scaled > 255) return 255;
  if (scaled < 1) return 1;
  return (uint8_t)scaled;
}

uint8_t activeBrightness() {
  return scaledBrightness(BL_BRIGHT_ACTIVE);
}

uint8_t sleepBrightness() {
  return scaledBrightness(BL_BRIGHT_SLEEP);
}

uint8_t idleBrightness() {
  return scaledBrightness(BL_BRIGHT_IDLE);
}

void drawCenteredText(const char* text, int y, uint8_t textSize, uint16_t color) {
  gfx->setTextSize(textSize);
  gfx->setTextColor(color);
  int16_t tw = strlen(text) * 6 * textSize;
  gfx->setCursor((LCD_W - tw) / 2, y);
  gfx->print(text);
}

void drawCodeIslandQR(int x, int y, uint8_t scale) {
  int qrPixels = CODEISLAND_QR_SIZE * scale;
  gfx->fillRect(x - 4, y - 4, qrPixels + 8, qrPixels + 8, RGB565(245, 245, 245));
  for (int row = 0; row < CODEISLAND_QR_SIZE; row++) {
    for (int col = 0; col < CODEISLAND_QR_SIZE; col++) {
      char bit = (char)pgm_read_byte(&CODEISLAND_QR[row][col]);
      if (bit == '1') {
        gfx->fillRect(x + col * scale, y + row * scale, scale, scale, RGB565(10, 10, 14));
      }
    }
  }
}

// --- Button state ---
bool   btnStable   = HIGH;
bool   btnLastRead = HIGH;
unsigned long btnLastChange  = 0;
unsigned long btnPressStart  = 0;
bool   btnPressed  = false;
bool   btnLongFired = false;

int pollButton(unsigned long now) {
  bool raw = digitalRead(BTN_PIN);
  if (raw != btnLastRead) { btnLastRead = raw; btnLastChange = now; }
  if ((now - btnLastChange) < DEBOUNCE_MS) return 0;
  if (btnStable == btnLastRead) {
    if (btnPressed && !btnLongFired && (now - btnPressStart) >= LONG_PRESS_MS) {
      btnLongFired = true;
      return 2;
    }
    return 0;
  }
  btnStable = btnLastRead;
  if (btnStable == LOW) { btnPressed = true; btnLongFired = false; btnPressStart = now; return 0; }
  btnPressed = false;
  return btnLongFired ? 0 : 1;
}

// --- BLE Callbacks ---
class ServerCallbacks : public BLEServerCallbacks {
  void onConnect(BLEServer* pServer) override {
    bleConnected = true;
    hasEverConnected = true;
    Serial.println("[BLE] Connected");
  }
  void onDisconnect(BLEServer* pServer) override {
    bleConnected = false;
    Serial.println("[BLE] Disconnected, re-advertising...");
    BLEDevice::startAdvertising();
  }
};

class CharCallbacks : public BLECharacteristicCallbacks {
  void onWrite(BLECharacteristic* pChar) override {
    uint8_t* data = pChar->getData();
    size_t len = pChar->getLength();
    Serial.printf("[BLE] Write received, len=%d, raw hex:", len);
    for (size_t i = 0; i < len && i < 24; i++) Serial.printf(" %02X", data[i]);
    Serial.println();

    if (len == 2 && data[0] == BUDDY_BRIGHTNESS_FRAME) {
      uint8_t percent = clampBuddyBrightness(data[1]);
      portENTER_CRITICAL(&bleMux);
      buddyBrightnessPercent = percent;
      portEXIT_CRITICAL(&bleMux);
      lastInteraction = millis();
      Serial.printf("[BLE] Brightness config: %d%%\n", percent);
      return;
    }

    if (len == 2 && data[0] == BUDDY_ORIENTATION_FRAME) {
      uint8_t orientation = clampBuddyOrientation(data[1]);
      portENTER_CRITICAL(&bleMux);
      if (buddyScreenOrientation != orientation) {
        buddyScreenOrientation = orientation;
        buddyOrientationDirty = true;
      }
      portEXIT_CRITICAL(&bleMux);
      lastInteraction = millis();
      Serial.printf("[BLE] Screen orientation config: %s\n", buddyOrientationStr(orientation));
      return;
    }

    if (len < 3) {
      Serial.println("[BLE] WARN: payload too short (<3), ignored");
      return;
    }

    portENTER_CRITICAL(&bleMux);
    bleSourceId = data[0];
    bleStatusId = data[1];
    uint8_t toolLen = data[2];
    if (toolLen > 17) toolLen = 17;
    memset(bleToolName, 0, sizeof(bleToolName));
    if (toolLen > 0 && len >= 3u + toolLen) {
      memcpy(bleToolName, data + 3, toolLen);
    }
    bleToolName[toolLen] = '\0';
    lastBleData = millis();
    appMode = MODE_AGENT;
    portEXIT_CRITICAL(&bleMux);

    const char* srcName = (bleSourceId < NUM_MASCOTS) ? mascots[bleSourceId].name : "?";
    Serial.printf("[BLE] Parsed: source=%d(%s) status=%d(%s) tool=\"%s\"\n",
      bleSourceId, srcName, bleStatusId, statusStr(bleStatusId), bleToolName);
  }
};

// --- Map BLE status to scene ---
Scene statusToScene(uint8_t status) {
  switch (status) {
    case 0: return SCENE_SLEEP;       // idle
    case 1: return SCENE_WORK;        // processing
    case 2: return SCENE_WORK;        // running
    case 3: return SCENE_ALERT;       // waitingApproval
    case 4: return SCENE_ALERT;       // waitingQuestion
    default: return SCENE_SLEEP;
  }
}

// --- Draw tool name label ---
void drawToolLabel() {
  char localTool[18];
  uint8_t localStatus;
  portENTER_CRITICAL(&bleMux);
  memcpy(localTool, bleToolName, sizeof(localTool));
  localStatus = bleStatusId;
  portEXIT_CRITICAL(&bleMux);
  if (localTool[0] == '\0') return;
  if (localStatus < 1 || localStatus > 2) return;
  gfx->setTextColor(RGB565(120, 120, 130));
  gfx->setTextSize(2);
  int16_t tw = strlen(localTool) * 12;
  gfx->setCursor((LCD_W - tw) / 2, sy(19.35f));
  gfx->print(localTool);
}

// --- Draw mascot name label (below mascot, larger font) ---
void drawMascotName(uint8_t idx) {
  if (idx >= NUM_MASCOTS) return;
  const char* name = mascots[idx].name;
  gfx->setTextSize(2);
  int16_t tw = strlen(name) * 12;
  gfx->setTextColor(RGB565(160, 160, 170));
  gfx->setCursor((LCD_W - tw) / 2, sy(17.45f));
  gfx->print(name);
}

// --- Draw connection status ---
void drawStatusBar() {
  uint16_t col = bleConnected ? RGB565(50, 230, 50) : RGB565(100, 100, 100);
  gfx->fillRect(LCD_W / 2 - 3, 4, 6, 3, col);
  if (appMode == MODE_DEMO) {
    gfx->setTextColor(RGB565(60, 60, 70));
    gfx->setTextSize(1);
    gfx->setCursor(LCD_W / 2 - 18, 10);
    gfx->print("DEMO");
  }
}

// --- Draw onboarding screen ---
void drawOnboardScreen(float t) {
  drawCenteredText("Buddy", 22, 3, RGB565(235, 235, 245));
  drawCenteredText(bleDeviceName, 50, 1, RGB565(120, 200, 255));
  drawCenteredText("Scan to get app", 64, 1, RGB565(130, 130, 150));

  int qrPixels = CODEISLAND_QR_SIZE * CODEISLAND_QR_SCALE;
  int qrX = (LCD_W - qrPixels) / 2;
  int qrY = 84;
  drawCodeIslandQR(qrX, qrY, CODEISLAND_QR_SCALE);

  int y = qrY + qrPixels + 16;
  drawCenteredText("Open CodeIsland", y, 1, RGB565(170, 170, 190));
  drawCenteredText("Settings > Buddy", y + 14, 1, RGB565(120, 200, 255));
  drawCenteredText("Connect by Bluetooth", y + 28, 1, RGB565(130, 130, 150));

  y += 50;
  if (bleConnected) {
    drawCenteredText("Bluetooth connected", y, 1, RGB565(50, 230, 50));
  } else {
    float pulse = (sinf(t * 3.0f) + 1.0f) * 0.5f;
    uint8_t g = 80 + (uint8_t)(pulse * 80);
    drawCenteredText("Waiting for Buddy...", y, 1, RGB565(g, g, (uint8_t)(g + 30)));
  }

  drawCenteredText("Long press: demo", LCD_H - 18, 1, RGB565(60, 60, 80));
}

// ============================================================
//  Setup
// ============================================================
void setup() {
  Serial.begin(115200);
  delay(100);
  Serial.println();
  Serial.println("========================================");
  Serial.println("  Buddy — Multi-mascot Bluetooth Pet");
  Serial.println("========================================");
  Serial.printf("[BOOT] Chip: %s  Rev: %d  Cores: %d\n",
    ESP.getChipModel(), ESP.getChipRevision(), ESP.getChipCores());
  Serial.printf("[BOOT] CPU freq: %d MHz\n", ESP.getCpuFreqMHz());
  Serial.printf("[BOOT] Free heap: %d bytes\n", ESP.getFreeHeap());
  Serial.printf("[BOOT] Flash: %d KB  Speed: %d MHz\n",
    ESP.getFlashChipSize() / 1024, ESP.getFlashChipSpeed() / 1000000);

  // LCD — PWM backlight for heat reduction
  Serial.println("[LCD]  Initializing...");
  Serial.printf("[LCD]  Pins: MOSI=%d SCLK=%d CS=%d DC=%d RST=%d BL=%d\n",
    TFT_MOSI, TFT_SCLK, TFT_CS, TFT_DC, TFT_RST, TFT_BL);
  Serial.printf("[LCD]  Size: %dx%d  Rotation: %d (%s)\n",
    LCD_W, LCD_H, tftRotationForBuddyOrientation(buddyScreenOrientation),
    buddyOrientationStr(buddyScreenOrientation));
  ledcAttach(TFT_BL, BL_PWM_FREQ, BL_PWM_BITS);
  currentBrightness = activeBrightness();
  ledcWrite(TFT_BL, currentBrightness);
  Serial.printf("[LCD]  Backlight PWM: freq=%dHz bits=%d brightness=%d/255 (%d%%)\n",
    BL_PWM_FREQ, BL_PWM_BITS, currentBrightness, buddyBrightnessPercent);
  pinMode(BTN_PIN, INPUT_PULLUP);
  Serial.printf("[BTN]  Pin=%d (INPUT_PULLUP)\n", BTN_PIN);
  SPI.begin(TFT_SCLK, -1, TFT_MOSI, TFT_CS);
  tft.init(LCD_W, LCD_H);
  applyBuddyScreenOrientation(buddyScreenOrientation);
  Serial.printf("[LCD]  Canvas buffer: %d bytes\n", LCD_W * LCD_H * 2);
  Serial.println("[LCD]  OK");

  // BLE — derive a unique name from the eFuse MAC so multiple Buddies
  // can co-exist and be distinguished from the macOS app.
  uint64_t mac = ESP.getEfuseMac();
  uint32_t suffix = (uint32_t)(mac & 0xFFFFFFULL);
  snprintf(bleDeviceName, BLE_DEVICE_NAME_LEN,
           BLE_DEVICE_NAME_PREFIX "%06X", (unsigned int)suffix);
  Serial.printf("[BLE]  Device name: %s\n", bleDeviceName);
  Serial.println("[BLE]  Initializing...");
  BLEDevice::init(bleDeviceName);
  BLEServer* pServer = BLEDevice::createServer();
  pServer->setCallbacks(new ServerCallbacks());

  BLEService* pService = pServer->createService(SERVICE_UUID);
  BLECharacteristic* pChar = pService->createCharacteristic(
    CHARACTERISTIC_UUID,
    BLECharacteristic::PROPERTY_WRITE | BLECharacteristic::PROPERTY_WRITE_NR
  );
  pChar->setCallbacks(new CharCallbacks());

  pNotifyChar = pService->createCharacteristic(
    NOTIFY_CHAR_UUID,
    BLECharacteristic::PROPERTY_READ | BLECharacteristic::PROPERTY_NOTIFY
  );
  pNotifyChar->addDescriptor(new BLE2902());

  pService->start();

  BLEAdvertising* pAdv = BLEDevice::getAdvertising();
  pAdv->addServiceUUID(SERVICE_UUID);
  pAdv->setScanResponse(true);
  pAdv->setMinPreferred(0x06);
  BLEDevice::startAdvertising();
  Serial.printf("[BLE]  Service UUID: %s\n", SERVICE_UUID);
  Serial.printf("[BLE]  Write UUID:   %s\n", CHARACTERISTIC_UUID);
  Serial.printf("[BLE]  Notify UUID:  %s\n", NOTIFY_CHAR_UUID);
  Serial.printf("[BLE]  Advertising as: %s\n", bleDeviceName);

  Serial.printf("[MASCOT] Loaded %d mascots:", NUM_MASCOTS);
  for (int i = 0; i < NUM_MASCOTS; i++) Serial.printf(" %s", mascots[i].name);
  Serial.println();

  Serial.printf("[CFG]  FPS active=%d sleep=%d\n", FPS_ACTIVE, FPS_SLEEP);
  Serial.printf("[CFG]  Backlight active=%d sleep=%d idle=%d brightness=%d%%  idle_timeout=%lums\n",
    activeBrightness(), sleepBrightness(), idleBrightness(), buddyBrightnessPercent, BL_IDLE_TIMEOUT_MS);
  Serial.printf("[CFG]  Auto-cycle=%lums  BLE timeout=%lums\n", AUTO_CYCLE_MS, BLE_TIMEOUT_MS);

  lastSceneChange = millis();
  lastInteraction = millis();
  lastFrameTime = millis();
  lastFpsCalcTime = millis();

  Serial.printf("[BOOT] Setup complete, free heap: %d bytes\n", ESP.getFreeHeap());
  Serial.println("========================================");
  Serial.println("[LOOP] Starting main loop...");
}

// ============================================================
//  Loop
// ============================================================
void loop() {
  unsigned long now = millis();
  loopCount++;

  bool shouldApplyOrientation = false;
  uint8_t localOrientation = BUDDY_SCREEN_UP;
  portENTER_CRITICAL(&bleMux);
  if (buddyOrientationDirty) {
    buddyOrientationDirty = false;
    localOrientation = buddyScreenOrientation;
    shouldApplyOrientation = true;
  }
  portEXIT_CRITICAL(&bleMux);
  if (shouldApplyOrientation) {
    applyBuddyScreenOrientation(localOrientation);
    Serial.printf("[LCD]  Screen orientation applied: %s (rotation=%d)\n",
      buddyOrientationStr(localOrientation),
      tftRotationForBuddyOrientation(localOrientation));
  }

  // Frame rate limiter
  bool isSleepy = (appMode == MODE_DEMO && currentScene == SCENE_SLEEP)
               || (appMode == MODE_AGENT && statusToScene(bleStatusId) == SCENE_SLEEP)
               || (appMode == MODE_ONBOARD);
  unsigned long frameInterval = isSleepy ? FRAME_MS_SLEEP : FRAME_MS_ACTIVE;
  if ((now - lastFrameTime) < frameInterval) {
    delay(1);
    return;
  }
  lastFrameTime = now;
  frameCount++;

  // FPS calculation
  if ((now - lastFpsCalcTime) >= 1000) {
    currentFps = frameCount * 1000.0f / (now - lastFpsCalcTime);
    frameCount = 0;
    lastFpsCalcTime = now;
  }

  float t = now / 1000.0f;

  // Button handling
  int btn = pollButton(now);
  if (appMode == MODE_AGENT) {
    if (btn == 1 && bleConnected && pNotifyChar) {
      uint8_t focusPayload = bleSourceId;
      pNotifyChar->setValue(&focusPayload, 1);
      pNotifyChar->notify();
      const char* srcName = (bleSourceId < NUM_MASCOTS) ? mascots[bleSourceId].name : "?";
      Serial.printf("[BTN]  Focus request sent: sourceId=%d(%s)\n", bleSourceId, srcName);
    } else if (btn == 1) {
      Serial.println("[BTN]  Short press (AGENT mode, BLE not ready)");
    } else if (btn == 2) {
      Serial.println("[BTN]  Long press ignored (in AGENT mode)");
    }
  } else {
    // ONBOARD or DEMO mode
    if (btn == 1) {
      lastInteraction = now;
      if (appMode == MODE_DEMO) {
        currentMascotIdx = (currentMascotIdx + 1) % NUM_MASCOTS;
        lastSceneChange = now;
        Serial.printf("[BTN]  Short press -> next mascot: %s (#%d)\n",
          mascots[currentMascotIdx].name, currentMascotIdx);
      } else {
        Serial.println("[BTN]  Short press (onboard mode, no action)");
      }
    } else if (btn == 2) {
      lastInteraction = now;
      AppMode prevMode = appMode;
      if (appMode == MODE_ONBOARD) {
        appMode = MODE_DEMO;
        lastSceneChange = now;
      } else {
        appMode = MODE_ONBOARD;
      }
      Serial.printf("[BTN]  Long press -> %s -> %s\n", appModeStr(prevMode), appModeStr(appMode));
    }
  }

  // BLE timeout: agent mode -> back to previous mode
  if (appMode == MODE_AGENT && (now - lastBleData) > BLE_TIMEOUT_MS) {
    appMode = hasEverConnected ? MODE_ONBOARD : MODE_ONBOARD;
    Serial.printf("[BLE]  Timeout (%lus no data), -> %s\n", BLE_TIMEOUT_MS / 1000, appModeStr(appMode));
  }

  // Dynamic backlight brightness
  uint8_t targetBright;
  if (appMode == MODE_AGENT && bleConnected) {
    lastInteraction = now;
    Scene agentScene = statusToScene(bleStatusId);
    targetBright = (agentScene == SCENE_SLEEP) ? sleepBrightness() : activeBrightness();
  } else if ((now - lastInteraction) > BL_IDLE_TIMEOUT_MS) {
    targetBright = idleBrightness();
  } else if (appMode == MODE_ONBOARD) {
    targetBright = sleepBrightness();
  } else {
    targetBright = (currentScene == SCENE_SLEEP) ? sleepBrightness() : activeBrightness();
  }
  if (currentBrightness != targetBright) {
    uint8_t prevBright = currentBrightness;
    if (currentBrightness < targetBright) currentBrightness += min((uint8_t)3, (uint8_t)(targetBright - currentBrightness));
    else currentBrightness -= min((uint8_t)3, (uint8_t)(currentBrightness - targetBright));
    ledcWrite(TFT_BL, currentBrightness);
    if (currentBrightness == targetBright) {
      Serial.printf("[LCD]  Backlight %d -> %d (target reached)\n", prevBright, currentBrightness);
    }
  }

  // ---- Render ----
  canvas.fillScreen(0x0000);

  if (appMode == MODE_ONBOARD) {
    drawOnboardScreen(t);
  } else {
    uint8_t drawIdx;
    Scene drawScene;

    if (appMode == MODE_DEMO) {
      drawIdx = currentMascotIdx;
      if ((now - lastSceneChange) >= AUTO_CYCLE_MS) {
        Scene prevScene = currentScene;
        currentScene = (Scene)((currentScene + 1) % SCENE_COUNT);
        if (currentScene == SCENE_SLEEP) {
          uint8_t prevIdx = currentMascotIdx;
          currentMascotIdx = (currentMascotIdx + 1) % NUM_MASCOTS;
          Serial.printf("[DEMO] Cycle mascot: %s(#%d) -> %s(#%d)\n",
            mascots[prevIdx].name, prevIdx, mascots[currentMascotIdx].name, currentMascotIdx);
        }
        Serial.printf("[DEMO] Cycle scene: %s -> %s\n", sceneStr(prevScene), sceneStr(currentScene));
        lastSceneChange = now;
        drawIdx = currentMascotIdx;
      }
      drawScene = currentScene;
    } else {
      drawIdx = bleSourceId < NUM_MASCOTS ? bleSourceId : 0;
      drawScene = statusToScene(bleStatusId);
    }

    drawStatusBar();

    Mascot& m = mascots[drawIdx];
    switch (drawScene) {
      case SCENE_SLEEP: m.sleep(t); break;
      case SCENE_WORK:  m.work(t);  break;
      case SCENE_ALERT: m.alert(t); break;
      default: break;
    }

    drawMascotName(drawIdx);

    if (appMode == MODE_AGENT) drawToolLabel();
  }

  tft.drawRGBBitmap(0, 0, canvas.getBuffer(), LCD_W, LCD_H);

  // Periodic status log
  if ((now - lastLogTime) >= LOG_INTERVAL_MS) {
    lastLogTime = now;
    unsigned long upSec = now / 1000;
    unsigned long idleSec = (now - lastInteraction) / 1000;

    Serial.printf("[STAT] up=%lus | fps=%.1f | heap=%d | bright=%d/255 (%d%%)\n",
      upSec, currentFps, ESP.getFreeHeap(), currentBrightness, buddyBrightnessPercent);
    Serial.printf("[STAT] mode=%s | ble=%s | ever_connected=%s\n",
      appModeStr(appMode),
      bleConnected ? "CONNECTED" : "disconnected",
      hasEverConnected ? "yes" : "no");

    if (appMode == MODE_AGENT) {
      char toolBuf[18];
      portENTER_CRITICAL(&bleMux);
      memcpy(toolBuf, bleToolName, sizeof(toolBuf));
      uint8_t localSrc = bleSourceId;
      uint8_t localSts = bleStatusId;
      portEXIT_CRITICAL(&bleMux);
      Serial.printf("[STAT] agent=%s(#%d) status=%s tool=\"%s\"\n",
        (localSrc < NUM_MASCOTS) ? mascots[localSrc].name : "?",
        localSrc, statusStr(localSts), toolBuf);
    } else if (appMode == MODE_DEMO) {
      Serial.printf("[STAT] mascot=%s(#%d) scene=%s idle=%lus next_cycle=%lus\n",
        mascots[currentMascotIdx].name, currentMascotIdx,
        sceneStr(currentScene), idleSec,
        (AUTO_CYCLE_MS - min(AUTO_CYCLE_MS, now - lastSceneChange)) / 1000);
    } else {
      Serial.printf("[STAT] onboard idle=%lus\n", idleSec);
    }
  }
}
