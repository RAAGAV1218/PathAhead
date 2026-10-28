/*
 * PathAhead cane firmware — ESP32 + HC-SR04 + MPU6050 + existing LED.
 * Retains the user's working wiring. No OLED, motor, pushbutton, or ToF sensor.
 * Sends line-delimited JSON over the Nordic-UART BLE service used by the iOS app.
 * ML cues are experimental; this is not a validated mobility or fall-detection device.
 */
#include <Arduino.h>
#include <Wire.h>
#include <Preferences.h>
#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLEUtils.h>
#include <BLE2902.h>
#include <atomic>
#include <math.h>
#include "pa_core.h"

// Existing connected hardware. Do not change the breadboard wiring.
constexpr int PIN_TRIG = 27, PIN_ECHO = 13, PIN_LED = 26;
constexpr int PIN_SDA = 32, PIN_SCL = 14;
constexpr uint8_t MPU_ADDRESS = 0x68;
constexpr char DEVICE_NAME[] = "PathAhead-Cane";
constexpr char SERVICE_UUID[] = "6E400001-B5A3-F393-E0A9-E50E24DCCA9E";
constexpr char WRITE_UUID[] = "6E400002-B5A3-F393-E0A9-E50E24DCCA9E";
constexpr char NOTIFY_UUID[] = "6E400003-B5A3-F393-E0A9-E50E24DCCA9E";

// Keep tap sampling independent of ultrasound. The tap detector expects 100 Hz.
constexpr uint32_t SAMPLE_PERIOD_US = 1000000UL / pa::TAP_FS;
constexpr uint32_t TELEMETRY_MS = 200;
constexpr uint32_t PING_PERIOD_MS = 75;
constexpr uint32_t RANGE_STALE_MS = 250;          // > three 75 ms pings
constexpr uint32_t BLE_CHUNK_GAP_MS = 15;
constexpr size_t BLE_CHUNK_BYTES = 20;
constexpr uint16_t ROUTE_SIGHT_MM = 2500;        // HC-SR04 adapted, experimental
constexpr uint16_t ROUTE_RELEASE_MM = 2750;
constexpr float STRIDE_MIN_S = 0.5f, STRIDE_MAX_S = 3.0f;
constexpr float ETA_MIN_SPEED_CM_S = 15.0f, ETA_WARN_S = 2.0f;
constexpr uint8_t QUEUE_SIZE = 8;
constexpr size_t FRAME_SIZE = 240;

BLEServer *bleServer = nullptr;
BLECharacteristic *tx = nullptr;
std::atomic<bool> bleConnected{false};
std::atomic<bool> clearBleQueue{false};
std::atomic<uint8_t> pendingCommand{0};
bool advertiseAfterDisconnect = false;
uint32_t disconnectedAt = 0;

char frames[QUEUE_SIZE][FRAME_SIZE];
uint16_t frameLengths[QUEUE_SIZE] = {};
uint8_t frameHead = 0, frameCount = 0;
uint16_t frameOffset = 0;
uint32_t lastChunkAt = 0;

// The interrupt does only timestamp capture; all math and route logic run in loop().
portMUX_TYPE echoMux = portMUX_INITIALIZER_UNLOCKED;
volatile uint32_t echoRiseUs = 0, echoWidthUs = 0;
volatile bool echoReady = false;
uint32_t lastPingMs = 0, lastValidEchoMs = 0;
float distances[3] = {-1, -1, -1};
uint8_t distanceCount = 0, distanceIndex = 0;
float currentCm = NAN, previousCm = NAN, closingCmS = NAN, etaS = NAN;
bool warning = false, inRouteSight = false;

bool mpuOk = false;
int16_t rawAx = 0, rawAy = 0, rawAz = 0;
uint32_t nextSampleUs = 0, lastTelemetryMs = 0, sequence = 0;
uint32_t sampleCount = 0, lastTapMs = 0, lastEtaMs = 0;
uint32_t lastMpuRetryMs = 0;
bool walking = false, baselineAnnounced = false, driftActive = false;
pa::TapDetector tapDetector;
pa::GaitDrift gait;
pa::RouteMemory route(true);
Preferences preferences;

void queueJson(const char *json) {
  if (!json || !*json || frameCount >= QUEUE_SIZE) return;
  const uint8_t index = (frameHead + frameCount) % QUEUE_SIZE;
  const size_t length = strnlen(json, FRAME_SIZE - 2);
  memcpy(frames[index], json, length);
  frames[index][length] = '\n';
  frameLengths[index] = length + 1;
  frameCount++;
  Serial.println(json);
}

void emitEvent(const char *name) {
  char b[80]; snprintf(b, sizeof(b), "{\"event\":\"%s\"}", name); queueJson(b);
}

void IRAM_ATTR echoChanged() {
  const uint32_t now = micros();
  if (digitalRead(PIN_ECHO)) {
    echoRiseUs = now;
  } else if (echoRiseUs != 0) {
    portENTER_CRITICAL_ISR(&echoMux);
    echoWidthUs = now - echoRiseUs;
    echoReady = true;
    echoRiseUs = 0;
    portEXIT_CRITICAL_ISR(&echoMux);
  }
}

class ServerCallbacks : public BLEServerCallbacks {
  void onConnect(BLEServer *) override {
    bleConnected.store(true);
    clearBleQueue.store(true);
  }
  void onDisconnect(BLEServer *) override {
    bleConnected.store(false);
    clearBleQueue.store(true);
    advertiseAfterDisconnect = true;
    disconnectedAt = millis();
  }
};

class CommandCallbacks : public BLECharacteristicCallbacks {
  void onWrite(BLECharacteristic *characteristic) override {
    const auto rawValue = characteristic->getValue();
    const String value(rawValue.c_str());
    if (value.startsWith("START")) pendingCommand.store(1);
    else if (value.startsWith("END")) pendingCommand.store(2);
    else if (value.startsWith("RESET")) pendingCommand.store(3);
  }
};

float median3(float a, float b, float c) {
  return max(min(a, b), min(max(a, b), c));
}

bool writeMpu(uint8_t reg, uint8_t value) {
  Wire.beginTransmission(MPU_ADDRESS); Wire.write(reg); Wire.write(value);
  return Wire.endTransmission() == 0;
}

bool wakeMpu() {
  // DLPF ~44 Hz, +/-8g accelerometer, 100 Hz output data rate.
  if (!writeMpu(0x6B, 0x00)) return false;
  if (!writeMpu(0x1A, 0x03)) return false;
  if (!writeMpu(0x1C, 0x10)) return false;
  if (!writeMpu(0x19, 0x09)) return false;
  delay(10);
  Wire.beginTransmission(MPU_ADDRESS); Wire.write(0x75);
  if (Wire.endTransmission(false) != 0 || Wire.requestFrom(MPU_ADDRESS, (uint8_t)1) != 1) return false;
  const uint8_t id = Wire.read();
  return id == 0x68 || id == 0x70 || id == 0x71 || id == 0x72 || id == 0x73;
}

bool readMpuRaw() {
  Wire.beginTransmission(MPU_ADDRESS); Wire.write(0x3B);
  if (Wire.endTransmission(false) != 0 || Wire.requestFrom(MPU_ADDRESS, (uint8_t)6) != 6) return false;
  uint8_t b[6]; for (uint8_t i = 0; i < 6; ++i) b[i] = Wire.read();
  rawAx = (int16_t)((b[0] << 8) | b[1]);
  rawAy = (int16_t)((b[2] << 8) | b[3]);
  rawAz = (int16_t)((b[4] << 8) | b[5]);
  return true;
}

void startPing(uint32_t now) {
  if (now - lastPingMs < PING_PERIOD_MS) return;
  lastPingMs = now;
  digitalWrite(PIN_TRIG, LOW); delayMicroseconds(2);
  digitalWrite(PIN_TRIG, HIGH); delayMicroseconds(10); digitalWrite(PIN_TRIG, LOW);
}

bool pollDistance(float &cm) {
  bool ready; uint32_t width;
  portENTER_CRITICAL(&echoMux);
  ready = echoReady; width = echoWidthUs; echoReady = false;
  portEXIT_CRITICAL(&echoMux);
  if (!ready) return false;
  const float measured = width * 0.0343f / 2.0f;
  if (width < 120 || measured < 2.0f || measured > 400.0f) return true; // invalid pulse
  cm = measured; lastValidEchoMs = millis();
  distances[distanceIndex] = measured; distanceIndex = (distanceIndex + 1) % 3;
  if (distanceCount < 3) distanceCount++;
  if (distanceCount == 3) currentCm = median3(distances[0], distances[1], distances[2]);
  return true;
}

void updateDistanceModel(uint32_t now) {
  if (lastValidEchoMs == 0 || now - lastValidEchoMs > RANGE_STALE_MS) {
    currentCm = NAN; previousCm = NAN; closingCmS = NAN; etaS = NAN;
    warning = false; distanceCount = 0;
    for (float &d : distances) d = -1;
    digitalWrite(PIN_LED, LOW); inRouteSight = false;
    return;
  }
  static uint32_t lastModelMs = 0;
  if (now - lastModelMs < 180 || !isfinite(currentCm)) return;
  const float old = previousCm;
  const uint32_t dt = now - lastModelMs;
  lastModelMs = now;
  closingCmS = (isfinite(old) && dt > 0) ? (old - currentCm) / (dt / 1000.0f) : NAN;
  etaS = (isfinite(closingCmS) && closingCmS > ETA_MIN_SPEED_CM_S)
      ? max(0.0f, (currentCm - 55.0f) / closingCmS) : NAN;
  warning = (isfinite(etaS) && etaS < 2.0f && currentCm < 250.0f) || currentCm < 40.0f;
  previousCm = currentCm;
  digitalWrite(PIN_LED, warning ? HIGH : LOW);
}

void persistRoute() {
  pa::Landmark table[pa::ROUTE_MAXL];
  const int n = route.exportTable(table);
  preferences.putInt("n", n);
  if (n > 0) preferences.putBytes("tbl", table, n * sizeof(pa::Landmark));
  else preferences.remove("tbl");
}

void restoreRoute() {
  const int n = preferences.getInt("n", 0);
  if (n <= 0 || n > pa::ROUTE_MAXL) return;
  pa::Landmark table[pa::ROUTE_MAXL];
  const size_t bytes = n * sizeof(pa::Landmark);
  if (preferences.getBytes("tbl", table, bytes) == bytes) route.importTable(table, n);
}

void emitRouteEvent(const pa::Event &e) {
  char b[FRAME_SIZE];
  switch (e.type) {
    case pa::EV_HAZARD:
      snprintf(b, sizeof(b), "{\"event\":\"route_hazard\",\"steps_ahead\":%d,\"confidence\":%.2f,\"expected_mm\":%d}", e.n, e.confidence, e.expectedMm); break;
    case pa::EV_CONFIRMED:
      snprintf(b, sizeof(b), "{\"event\":\"route_confirmed\",\"predicted\":%s,\"confidence\":%.2f}", e.predicted ? "true" : "false", e.confidence); break;
    case pa::EV_CHANGED:
      if (e.reason == pa::R_NOT_FOUND) snprintf(b, sizeof(b), "{\"event\":\"route_changed\",\"reason\":\"not_found\",\"was_steps\":%d}", e.n);
      else if (e.reason == pa::R_MOVED) snprintf(b, sizeof(b), "{\"event\":\"route_changed\",\"reason\":\"moved\",\"shift_steps\":%d}", e.n);
      else snprintf(b, sizeof(b), "{\"event\":\"route_changed\",\"reason\":\"different_obstacle\",\"z\":%.1f}", e.z);
      break;
    case pa::EV_NEW: snprintf(b, sizeof(b), "{\"event\":\"new_obstacle\"}"); break;
    default: return;
  }
  queueJson(b);
}

void onTap(uint32_t tapMs) {
  if (!walking) return;
  if (lastTapMs != 0) {
    const float interval = (tapMs - lastTapMs) / 1000.0f;
    if (interval >= STRIDE_MIN_S && interval <= STRIDE_MAX_S) {
      pa::GaitResult result = gait.update(interval);
      char b[128];
      if (result.calibrated && !baselineAnnounced) {
        baselineAnnounced = true;
        snprintf(b, sizeof(b), "{\"event\":\"baseline_ready\",\"stride_s\":%.2f,\"cv_pct\":%.1f}", gait.mean(), 100.0f * gait.cv()); queueJson(b);
      }
      if (result.alarmsValid && result.stumble) {
        snprintf(b, sizeof(b), "{\"event\":\"stumble_risk\",\"z\":%.1f}", result.zInst); queueJson(b);
      }
      if (result.alarmsValid && result.drift && !driftActive) {
        driftActive = true; snprintf(b, sizeof(b), "{\"event\":\"gait_drift\",\"z\":%.1f}", result.zDrift); queueJson(b);
      }
      if (!result.drift) driftActive = false;
    }
  }
  lastTapMs = tapMs;
  pa::Event events[pa::ROUTE_MAXL * 2];
  const int count = route.onStep(events, pa::ROUTE_MAXL * 2);
  for (int i = 0; i < count; ++i) emitRouteEvent(events[i]);
}

void processRouteDistance(uint32_t now) {
  if (!walking || !isfinite(currentCm)) return;
  const uint16_t mm = (uint16_t)(currentCm * 10.0f);
  if (mm < ROUTE_SIGHT_MM && !inRouteSight) {
    inRouteSight = true;
    pa::Event events[pa::ROUTE_MAXL * 2];
    const int count = route.onSighting((float)mm, events, pa::ROUTE_MAXL * 2);
    for (int i = 0; i < count; ++i) emitRouteEvent(events[i]);
  }
  if (mm > ROUTE_RELEASE_MM) inRouteSight = false;
  static uint32_t etaNoticeAt = 0;
  if (isfinite(etaS) && etaS < ETA_WARN_S && now - etaNoticeAt > 1500) {
    etaNoticeAt = now; char b[100];
    snprintf(b, sizeof(b), "{\"event\":\"obstacle_eta\",\"eta_s\":%.1f,\"distance_mm\":%u}", etaS, mm); queueJson(b);
  }
}

void beginWalk() {
  if (walking) return;
  walking = true; route.beginWalk(); lastTapMs = 0; inRouteSight = false; driftActive = false;
  queueJson("{\"event\":\"walk_start\"}");
}

void finishWalk() {
  if (!walking) return;
  walking = false; route.endWalk(); persistRoute();
  char b[80]; snprintf(b, sizeof(b), "{\"event\":\"walk_end\",\"landmarks\":%d}", route.count()); queueJson(b);
}

void processCommand() {
  const uint8_t command = pendingCommand.exchange(0);
  if (command == 1) beginWalk();
  else if (command == 2) finishWalk();
  else if (command == 3 && !walking) {
    gait.reset(); tapDetector.reset(); baselineAnnounced = false; driftActive = false;
    emitEvent("baseline_reset");
  }
}

void publishTelemetry(uint32_t now) {
  updateDistanceModel(now);
  processRouteDistance(now);
  char cm[20], closing[20], eta[20];
  if (isfinite(currentCm)) snprintf(cm, sizeof(cm), "%.1f", currentCm); else strcpy(cm, "null");
  if (isfinite(closingCmS)) snprintf(closing, sizeof(closing), "%.1f", closingCmS); else strcpy(closing, "null");
  if (isfinite(etaS)) snprintf(eta, sizeof(eta), "%.1f", etaS); else strcpy(eta, "null");
  char b[FRAME_SIZE];
  snprintf(b, sizeof(b), "{\"v\":1,\"seq\":%lu,\"cm\":%s,\"closing\":%s,\"eta\":%s,\"warning\":%s,\"mpu\":%s,\"ax\":%d,\"ay\":%d,\"az\":%d,\"walk\":%s}",
    (unsigned long)sequence++, cm, closing, eta, warning ? "true" : "false",
    mpuOk ? "true" : "false", rawAx, rawAy, rawAz, walking ? "true" : "false");
  queueJson(b);
}

void serviceBLE(uint32_t now) {
  if (clearBleQueue.exchange(false)) { frameHead = frameCount = 0; frameOffset = 0; }
  if (advertiseAfterDisconnect && !bleConnected.load() && now - disconnectedAt > 500) {
    advertiseAfterDisconnect = false; bleServer->startAdvertising();
  }
  if (!bleConnected.load() || frameCount == 0 || now - lastChunkAt < BLE_CHUNK_GAP_MS) return;
  const uint8_t index = frameHead;
  const size_t left = frameLengths[index] - frameOffset;
  const size_t count = min(left, BLE_CHUNK_BYTES);
  tx->setValue((uint8_t *)frames[index] + frameOffset, count);
  tx->notify();
  frameOffset += count; lastChunkAt = now;
  if (frameOffset >= frameLengths[index]) {
    frameHead = (frameHead + 1) % QUEUE_SIZE; frameCount--; frameOffset = 0;
  }
}

void setup() {
  Serial.begin(115200);
  pinMode(PIN_TRIG, OUTPUT); pinMode(PIN_ECHO, INPUT); pinMode(PIN_LED, OUTPUT);
  digitalWrite(PIN_TRIG, LOW); digitalWrite(PIN_LED, LOW);
  attachInterrupt(digitalPinToInterrupt(PIN_ECHO), echoChanged, CHANGE);

  Wire.begin(PIN_SDA, PIN_SCL, 400000);
  Wire.setTimeOut(10);
  mpuOk = wakeMpu();

  preferences.begin("pathahead", false); restoreRoute();
  BLEDevice::init(DEVICE_NAME);
  bleServer = BLEDevice::createServer(); bleServer->setCallbacks(new ServerCallbacks());
  BLEService *service = bleServer->createService(SERVICE_UUID);
  tx = service->createCharacteristic(NOTIFY_UUID, BLECharacteristic::PROPERTY_READ | BLECharacteristic::PROPERTY_NOTIFY);
  tx->addDescriptor(new BLE2902());
  BLECharacteristic *rx = service->createCharacteristic(WRITE_UUID, BLECharacteristic::PROPERTY_WRITE | BLECharacteristic::PROPERTY_WRITE_NR);
  rx->setCallbacks(new CommandCallbacks());
  service->start();
  BLEAdvertising *advertising = BLEDevice::getAdvertising();
  advertising->addServiceUUID(SERVICE_UUID); advertising->setScanResponse(true);
  BLEDevice::startAdvertising();
  emitEvent(mpuOk ? "ready" : "mpu_unavailable");
  nextSampleUs = micros() + SAMPLE_PERIOD_US;
}

void loop() {
  uint32_t now = millis();
  serviceBLE(now);
  processCommand();
  startPing(now);
  float newCm = NAN;
  if (pollDistance(newCm)) processRouteDistance(millis());

  const uint32_t us = micros();
  if ((int32_t)(us - nextSampleUs) >= 0) {
    nextSampleUs += SAMPLE_PERIOD_US;
    if ((int32_t)(us - nextSampleUs) >= 0) nextSampleUs = us + SAMPLE_PERIOD_US;
    if (mpuOk && readMpuRaw()) {
      const float scale = 9.80665f / 4096.0f;
      const long peakIndex = tapDetector.update(rawAx * scale, rawAy * scale, rawAz * scale);
      sampleCount++;
      if (peakIndex >= 0) {
        const uint32_t tapMs = millis() - (uint32_t)((sampleCount - (uint32_t)peakIndex) * 10UL);
        onTap(tapMs);
      }
    } else {
      mpuOk = false;
      if (millis() - lastMpuRetryMs >= 2000) {
        lastMpuRetryMs = millis();
        mpuOk = wakeMpu();
      }
    }
  }
  now = millis();
  if (now - lastTelemetryMs >= TELEMETRY_MS) {
    lastTelemetryMs = now; publishTelemetry(now);
  }
  serviceBLE(millis());
  delay(1);
}
