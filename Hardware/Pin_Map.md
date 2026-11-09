# Hardware Pin Map

These are **source-defined GPIO assignments**, not proof that the physical wiring matches. The older diagram images were excluded because their LED assignments conflict with the current firmware.

## Main Controller: JC-ESP32P4-M3

| Function | GPIO |
| --- | ---: |
| I2C SDA (LCD, DS3231, SHT3x) | 1 |
| I2C SCL | 2 |
| Fan 1 relay | 3 |
| PTC heater relay | 4 |
| Fan 2 relay | 5 |
| Tray motor relay | 20 |
| Main-incubator bulb relay | 33 |
| Door magnetic switch | 46 |

The door input is configured closed=LOW and open=HIGH. P4 local slot-LED output is disabled; the separate LED controller owns the 56 underlights. GPIO32/47 are retained as disabled shift-register data/clock definitions, and the local latch is unassigned.

## ESP32-S3 Camera With OV5640

| Function | GPIO |
| --- | ---: |
| Camera power relay | 2 |
| XCLK | 15 |
| Camera SDA / SIOC data | 4 |
| Camera SCL / SIOC clock | 5 |
| D0-D7 (Y2-Y9) | 11, 9, 8, 10, 12, 18, 17, 16 |
| VSYNC / HREF / PCLK | 6 / 7 / 13 |

PWDN and RESET are configured as `-1` (not driven by a GPIO).

## Sub-Incubator Sensor And Relay Node

| Function | GPIO |
| --- | ---: |
| SHT3x I2C SDA / SCL | 21 / 13 |
| Bulb relay | 25 |
| Humidifier relay | 32 |
| Water-level analog input | 37 |

The water-level reading is for monitoring only; the humidifier control uses humidity hysteresis.

## Separate 56-Slot LED Controller

| 74HC595 signal | GPIO |
| --- | ---: |
| Data | 21 |
| Latch | 19 |
| Clock | 17 |

Seven chained 74HC595 registers drive the 56 slot outputs. Confirm the actual controller board, supply voltage, common ground, and LED driver hardware before connecting or powering the circuit.
