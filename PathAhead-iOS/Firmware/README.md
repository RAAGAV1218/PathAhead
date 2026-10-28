# PathAhead ESP32 firmware

This sketch is adapted for the hardware already on your breadboard: ESP32, HC-SR04, MPU6050, and the existing LED. It does **not** use an OLED, vibration motor, pushbutton, or VL53L0X. Do not change the wiring to use this version.

## Existing pin assignments

| Part | ESP32 pin |
| --- | ---: |
| HC-SR04 TRIG | GPIO 27 |
| HC-SR04 ECHO, through your existing resistor divider | GPIO 13 |
| Existing LED | GPIO 26 |
| MPU6050 SDA | GPIO 32 |
| MPU6050 SCL | GPIO 14 |

Keep common ground and the current power wiring. **Never connect the HC-SR04 ECHO 5V output directly to an ESP32 GPIO; keep the existing divider.**

## Upload from your Mac

1. Keep a backup of your currently working sketch.
2. In Arduino IDE, use the Espressif ESP32 board package. The sketch uses its built-in `Wire`, `BLE`, and `Preferences` libraries; no extra library is required.
3. Open `PathAheadBLE/PathAheadBLE.ino`, select the same ESP32 board and USB port you used before, then click **Verify**.
4. Upload only if Verify succeeds. Open Serial Monitor at 115200 baud and check that JSON telemetry appears.
5. On your physical iPhone, open PathAhead, tap **Connect cane**, and select **PathAhead-Cane**. Do not pair it from iPhone Settings. Once connected, use **Start learning walk** and **End walk** in the app.

The MPU is sampled at 100 Hz independently from the ultrasound pings. HC-SR04 readings are collected asynchronously, so an ultrasound timeout should not stall gait sampling. This has not been physically validated on your particular ESP32 board; verify it on the bench before any demonstration involving a person.

## BLE message/control protocol

- Device: `PathAhead-Cane`
- Service: `6E400001-B5A3-F393-E0A9-E50E24DCCA9E`
- App-to-ESP32 write: `6E400002-B5A3-F393-E0A9-E50E24DCCA9E`
- ESP32-to-app notify: `6E400003-B5A3-F393-E0A9-E50E24DCCA9E`
- Commands are newline-terminated text: `START`, `END`, `RESET` (reset is ignored during an active walk).
- Notifications are chunks of up to 20 bytes. The app joins bytes until newline before decoding JSON. Telemetry is approximately every 200 ms; event objects are sent on the same stream.

Example telemetry:

```json
{"v":1,"seq":42,"cm":135.0,"closing":22.5,"eta":3.6,"warning":false,"mpu":true,"ax":80,"ay":-32,"az":4080,"walk":true}
```

Other line-delimited JSON objects include `walk_start`, `walk_end`, `baseline_ready`, `gait_drift`, `stumble_risk`, `route_hazard`, `route_changed`, and `route_confirmed`. The app translates these into interface updates and, when the user enables voice, pre-generated ElevenLabs phrases. No sensor readings are sent to ElevenLabs.

## Important ML limitations

The supplied ML is hand-coded statistical experimentation, not a trained production model. The gait detector assumes the cane has one detectable tap per step; its thresholds were not validated for this user's cane, walking style, or sensor mounting. If the taps are not detected cleanly at 100 Hz, gait and route learning will be unreliable. Route memory is adapted to use a first HC-SR04 sighting around 2.5 m, but sensor angle, beam width, moving objects, and room layout can create false matches. Learning only becomes useful after repeat supervised walks; starting a walk records data, it does not certify a route.

These features are exploratory informational cues only. They are **not** fall detection, medical monitoring, obstacle coverage guarantees, or directions. Keep using a mobility cane/guide dog and usual orientation-and-mobility practices. Do not use the prototype unsupervised or walk with eyes closed.

## Bench verification checklist

1. Verify/upload with the cane stationary, then confirm `mpu:true` and changing raw axis values in Serial Monitor.
2. Point the HC-SR04 at a large flat object. Confirm distance updates and becomes `null` when echoes stop; an unavailable reading means unknown, not clear.
3. Connect with the iPhone and confirm live readings arrive.
4. Send a short supervised walk command, confirm `walk_start`, then end it and check for `walk_end`.
5. Use the learning card and ElevenLabs only after the phone app says voice is prepared. Compare observed cues with reality; record false/missed detections.

This environment has no Arduino ESP32 toolchain or attached hardware. The firmware and iOS changes have **not** been compiled or tested on your Mac or board. Treat successful local Verify and cautious bench checks as required before the demo.
