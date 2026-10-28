// Backup of the working serial sketch supplied in the conversation.
#include <Wire.h>

const int PIN_TRIG = 27, PIN_ECHO = 13, PIN_LED = 26;
const int MPU = 0x68;

bool mpuOk = false;
float r[3] = {-1, -1, -1};
int ri = 0;
float prevCm = -1;
unsigned long prevMs = 0;
bool warning = false;

float readCm() {
  digitalWrite(PIN_TRIG, LOW);  delayMicroseconds(2);
  digitalWrite(PIN_TRIG, HIGH); delayMicroseconds(10);
  digitalWrite(PIN_TRIG, LOW);
  unsigned long t0 = micros();
  long us = 0;
  while (true) {
    long left = 30000L - (long)(micros() - t0);
    if (left <= 0) { us = 0; break; }
    us = pulseIn(PIN_ECHO, HIGH, left);
    if (us == 0 || us >= 120) break;
  }
  return us == 0 ? -1 : us * 0.0343f / 2;
}

float med3(float a, float b, float c) {
  return max(min(a, b), min(max(a, b), c));
}

bool readMpu(int16_t &ax, int16_t &ay, int16_t &az) {
  Wire.beginTransmission(MPU);
  Wire.write(0x3B);
  if (Wire.endTransmission(false) != 0) return false;
  if (Wire.requestFrom(MPU, 6, true) != 6) return false;
  ax = (Wire.read() << 8) | Wire.read();
  ay = (Wire.read() << 8) | Wire.read();
  az = (Wire.read() << 8) | Wire.read();
  return true;
}

void setup() {
  Serial.begin(115200);
  pinMode(PIN_TRIG, OUTPUT);
  pinMode(PIN_ECHO, INPUT);
  pinMode(PIN_LED, OUTPUT);

  Wire.begin(32, 14);  // SDA = 32, SCL = 14
  Wire.beginTransmission(MPU);
  Wire.write(0x6B);
  Wire.write(0);       // Wake the MPU6050
  mpuOk = (Wire.endTransmission() == 0);
  Serial.println(mpuOk ? "MPU6050 found" :
                 "MPU6050 NOT found (distance still works)");
}

void loop() {
  float d = readCm();
  if (d > 0) { r[ri] = d; ri = (ri + 1) % 3; }

  if (r[0] > 0 && r[1] > 0 && r[2] > 0) {
    float cm = med3(r[0], r[1], r[2]);
    unsigned long now = millis();
    if (prevCm < 0) { prevCm = cm; prevMs = now; }
    else if (now - prevMs >= 150) {
      float v = (prevCm - cm) / ((now - prevMs) / 1000.0f);
      float eta = (v > 15) ? (cm - 55) / v : 99;
      bool danger = (eta < 2.0f && cm < 250) || cm < 40;

      int16_t ax = 0, ay = 0, az = 0;
      if (mpuOk && readMpu(ax, ay, az))
        Serial.printf("dist=%.0f cm  closing=%.0f cm/s  eta=%.1f s  |  ax=%d ay=%d az=%d\n",
                      cm, v, eta, ax, ay, az);
      else
        Serial.printf("dist=%.0f cm  closing=%.0f cm/s  eta=%.1f s\n",
                      cm, v, eta);

      if (danger && !warning)
        Serial.println("SAY: Obstacle ahead, slow down");
      warning = danger;
      prevCm = cm;
      prevMs = now;
    }
  }
  digitalWrite(PIN_LED, warning);
  delay(60);
}
