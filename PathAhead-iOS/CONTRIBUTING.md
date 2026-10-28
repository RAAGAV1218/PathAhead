# Contributing

Thanks for helping improve PathAhead. This is a safety-sensitive accessibility prototype, so prioritize honest status, accessible interaction, and safe failure behavior over feature count.

## Before opening a change

- Do not commit API keys, voice IDs that identify a private account, signing certificates, provisioning profiles, private user data, or generated audio.
- Preserve the documented sensor wiring unless a change is clearly marked as a new hardware configuration.
- Keep unsupported or missing sensor readings visibly **unknown**; never present them as a clear route.
- Label ML output as experimental. Do not claim fall detection, clinical validation, or guaranteed obstacle avoidance without appropriate evidence.
- Keep the existing interface style unless a redesign is specifically intended.

## Checks

- Build the iOS project in Xcode and test the preview separately from a physical-device Bluetooth test.
- Run Arduino IDE **Verify** for firmware changes before uploading.
- Bench-test sensors while stationary, then test BLE connection, notification framing, and app controls.
- Describe which checks were run and which physical tests remain unverified.

## License

No open-source license is currently provided. Please do not assume permission to reuse or redistribute the source. Confirm ownership and permissions before adding a license.
