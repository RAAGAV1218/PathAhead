# PathAhead

An iPhone companion and ESP32 prototype exploring additional walking awareness for people with visual impairment. The app receives distance and motion readings over Bluetooth LE, presents them in a calm dashboard, and can play prepared ElevenLabs voice cues through the phone. The ESP32 experiments with cane-tap rhythm and repeated route-obstacle cues.

> **Safety:** PathAhead is an early, unvalidated prototype. It is not a mobility aid, fall detector, medical device, or guarantee that a path is clear. Continue using your usual cane or guide dog and orientation-and-mobility techniques. Test only with supervision; never walk with your eyes closed.

## What’s in this repository

- **iOS app:** SwiftUI dashboard, Bluetooth LE connection, session controls, and ElevenLabs voice setup.
- **ESP32 firmware:** HC-SR04 distance sensing, MPU6050 sampling, BLE telemetry and app commands, plus experimental learning routines.
- **No added hardware:** This version uses the existing HC-SR04, MPU6050, LED, resistor divider, and ESP32. It does not use an OLED, motor, physical button, or ToF sensor.

## Hardware pinout

| Component | ESP32 pin |
| --- | ---: |
| HC-SR04 TRIG | GPIO 27 |
| HC-SR04 ECHO, through the existing resistor divider | GPIO 13 |
| Existing LED | GPIO 26 |
| MPU6050 SDA | GPIO 32 |
| MPU6050 SCL | GPIO 14 |

Keep the existing common ground and power arrangement. **Never connect the HC-SR04 ECHO output directly to an ESP32 GPIO; retain the resistor divider.**

## Get started

### iPhone app

1. Open `PathAhead.xcodeproj` in Xcode on a Mac.
2. Select the **PathAhead** app target. In **Signing & Capabilities**, enable **Automatically manage signing** and select your Apple development team.
3. If Xcode rejects `com.example.pathahead`, set **Product Bundle Identifier** to a unique value for your team.
4. Run on an iPhone Simulator to preview the UI, or select a physical iPhone to use Bluetooth. The Simulator preview is simulated and does not connect to the ESP32.

### ESP32 firmware

1. Keep a backup of the sketch currently on your ESP32.
2. Install Arduino IDE and Espressif’s `esp32` board package if needed.
3. Open `Firmware/PathAheadBLE/PathAheadBLE.ino`, select the correct ESP32 board and port, then use **Verify** before **Upload**.
4. Upload with the existing wiring unchanged. Disconnect the Mac before returning to the powerbank.
5. On a physical iPhone, open PathAhead, tap **Connect cane**, and select **PathAhead-Cane**. Do not pair from iOS Bluetooth Settings.
6. Once connected, use **Start learning walk** and **End walk** in the app. These controls require the matching firmware in this repository.

See [Firmware/README.md](Firmware/README.md) for upload, BLE protocol, and bench-check details.

## ElevenLabs and privacy

The owner enters their own ElevenLabs API key and voice ID in the iPhone app. The key is stored in the phone’s Keychain and is not included in this repository or the ESP32 firmware. The app requests a small set of fixed phrases and caches the resulting audio on the phone; it does not send sensor readings, location, or microphone audio to ElevenLabs. Preparing voice requires internet access and may use the account’s text-to-speech allowance.

This direct-from-phone key arrangement is only suitable for a personal prototype. A public production app should use an authenticated backend rather than distribute a shared API credential. BLE is not designed here as a secure production protocol.

## Experimental learning: read before use

The included core is hand-coded statistical experimentation, not a validated or generally trained model. Gait analysis assumes one detectable cane tap per stride and needs a personal baseline. Route learning uses first obstacle sightings from the HC-SR04 and can be affected by sensor direction, beam width, moving objects, and changes in the environment. It needs repeat supervised walks and can produce missed or false cues. It must not be described as fall detection or reliable route guidance.

The ML code was adapted from the project archive supplied for this prototype. That archive contained no license file, so **this repository currently has no open-source license**. Public visibility alone does not grant permission to reuse or redistribute the code. Confirm the rights and add an appropriate license before inviting reuse.

## Repository map

```text
.
├── PathAhead/                 SwiftUI app, BLE manager, models, ElevenLabs client
├── PathAhead.xcodeproj/        Xcode project
└── Firmware/
    ├── PathAheadBLE/           Current ESP32 sketch and learning core
    ├── OriginalWorkingSketch.ino
    └── README.md
```

## Verification status

The source has not been compiled with Xcode or the Arduino ESP32 toolchain in this environment, and has not been tested on the physical iPhone/ESP32 setup. Run an Xcode build and Arduino **Verify**, then conduct the documented stationary bench checks before presenting it. See [CONTRIBUTING.md](CONTRIBUTING.md) for safe change practices and [SECURITY.md](SECURITY.md) for security reporting guidance.
