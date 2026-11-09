# AI-Powered Smart Poultry Incubator with Automated Fertility Detection for Enhanced Hatchability

Public source-code and executable snapshots for the smart incubator system.

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

The main correction compared with the old archive is the November 2 P4 egg-counter model. Its SHA-256 is:

```text
33153FA977AB1452C05A2E8ED148B9145F962A8B9C6055A77EC58B8C77449890
```

The Android APK and bundled fertility model remain unchanged. P4 performs egg counting; fertility classification runs on the Android phone. Neither the latest local artifact nor a repository commit alone proves which build was used for every historical trial.

## Historical Snapshot

[October 11, 2026 archive](Smart_Incubator_Submission_2026-10-11.zip), originally committed as `7367a9e7934f9a85417a4f7296b6c04f09017bd5`, is preserved unchanged. It contains the earlier August 31 P4 egg-counter model.

## Scope And Privacy

No screenshots, dataset/sample photos, raw training data, IDE caches, virtual environments, consent records, or signing keys were added. App icons and required runtime image assets are included. The separate ESP32-C6 slave firmware was not changed or included.

The project owner has authorized public sharing of the existing local device-network settings, including the incubator Wi-Fi configuration. Those settings are intentionally unchanged. Change the shared defaults before adapting this code to another network or deployment.

The ZIP archives retain their original packaging notes, including earlier instructions to keep the snapshots private. This repository was subsequently approved for public sharing on November 10, 2026. The archives, binaries, models, and their recorded checksums were not changed by the visibility update.

Refer to the README inside the current archive before building, installing, or using retained firmware binaries. Physical wiring and live system behavior require separate validation.
