# AI-Powered Smart Poultry Incubator with Automated Fertility Detection for Enhanced Hatchability

Public source code, required models, retained executables, and historical snapshots for the smart incubator system.

## Browse The System

The five system projects are available as normal folders. No ZIP download is required to read their source code.

| Project | Source |
| --- | --- |
| Android mobile application | [Software/Mobile_App_Source](Software/Mobile_App_Source) |
| JC-ESP32P4-M3 main controller | [Software/P4_Firmware](Software/P4_Firmware) |
| ESP32-S3 camera and access point | [Software/S3_Camera](Software/S3_Camera) |
| Sub-incubator sensor and relay node | [Software/Sub_Incubator](Software/Sub_Incubator) |
| 56-slot LED controller | [Software/LED_Controller](Software/LED_Controller) |

Additional retained files:

- [Android release APK, version 1.0.0+1](Software/Android_APK/app-release.apk)
- [Existing P4 application, bootloader, partition table, and flash arguments](Software/P4_Prebuild)
- [Source-defined hardware pin map](Hardware/Pin_Map.md)
- [P4 egg-counter model](Software/P4_Firmware/main/model/eggcounter_cls_int8.tflite)
- [Android fertility model](Software/Mobile_App_Source/assets/models/fertility_mobilenetv3small_float16.tflite)

These folders match the corresponding entries in the reviewed November 10 archive and the current local projects. File bytes are preserved so the recorded source and model checksums remain valid. Both existing ZIP archives remain unchanged.

## Current Snapshot

[Download the November 10, 2026 system snapshot](Smart_Incubator_Submission_2026-11-10.zip)

The archive contains the current source for the Android app and all four controller projects, the existing release APK, the updated P4 egg-counter model, existing P4 flash binaries, build configuration, and a source-derived GPIO pin map.

**November 10 is the packaging date, not a new build date.** No firmware, APK, or AI model was rebuilt for this repository update.

| Component | Retained Version |
| --- | --- |
| Android APK | 1.0.0+1; October 9, 2026 release artifact |
| Android fertility model | MobileNetV3Small, float16 weights; October 9, 2026 |
| P4 egg-counter model | November 2, 2026 update; INT8 binary classifier |
| P4 application binary | Existing November 2, 2026 build |
| S3 camera source | September 6, 2026 source; unchanged from the historical snapshot |
| Sub-incubator source | September 5, 2026 source; unchanged from the historical snapshot |
| LED-controller source | August 30, 2026 source; unchanged from the historical snapshot |

[Version manifest and SHA-256 checksums](VERSION_MANIFEST.json)

The manifest inventory describes the archived snapshot. Its `Software/` and `Hardware/` paths also identify the matching browsable files. The inventory's `README.md` entry refers to the README inside the archive, not this updated repository homepage.

The main correction compared with the old archive is the November 2 P4 egg-counter model. Its SHA-256 is:

```text
33153FA977AB1452C05A2E8ED148B9145F962A8B9C6055A77EC58B8C77449890
```

The Android APK and bundled fertility model remain unchanged. P4 performs egg counting; fertility classification runs on the Android phone. Neither the latest local artifact nor a repository commit alone proves which build was used for every historical trial.

## Build Notes

- Android: from `Software/Mobile_App_Source`, use a compatible Flutter SDK and run `flutter pub get`, then `flutter build apk --release`. Private signing keys are not included; the existing project falls back to debug signing for a release-mode build without a configured release keystore.
- P4: from `Software/P4_Firmware`, use the compatible ESP-IDF 5.5.x toolchain and run `idf.py build`. Managed dependencies are declared in `main/idf_component.yml`. The separate hosted slave firmware is not included or changed.
- Arduino nodes: open the relevant `.ino` in Arduino IDE using the matching ESP32 board package and libraries.
- Retained P4 binaries: confirm the exact board, flash size, serial port, and installed configuration before using `Software/P4_Prebuild/flash_args`. Do not erase existing NVS as part of obtaining this source snapshot.

Publishing the folders did not rebuild, retrain, install, or flash anything.

## Historical Snapshot

[October 11, 2026 archive](Smart_Incubator_Submission_2026-10-11.zip), originally committed as `7367a9e7934f9a85417a4f7296b6c04f09017bd5`, is preserved unchanged. It contains the earlier August 31 P4 egg-counter model.

## Scope And Privacy

No screenshots, dataset/sample photos, raw training data, IDE caches, virtual environments, consent records, or signing keys were added. App icons and required runtime image assets are included. The separate ESP32-C6 slave firmware was not changed or included.

The project owner has authorized public sharing of the existing local device-network settings, including the incubator Wi-Fi configuration. Those settings are intentionally unchanged. Change the shared defaults before adapting this code to another network or deployment.

The ZIP archives retain their original packaging notes, including earlier instructions to keep the snapshots private. This repository was subsequently approved for public sharing on November 10, 2026. The archives, binaries, models, and their recorded checksums were not changed by the visibility update.

Refer to the README inside the current archive before building, installing, or using retained firmware binaries. Physical wiring and live system behavior require separate validation.
