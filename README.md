# Tuya Plug Enhanced

SmartThings Edge Zigbee driver fork based on [`iquix/ST-Edge-Driver/tuya-plug`](https://github.com/iquix/ST-Edge-Driver/tree/master/tuya-plug).

## Added changes

- Korean device settings
- Voltage measurement support
- Current measurement support when the device reports it
- Fixed-voltage fallback when voltage is not reported
- Current fallback calculated as `power / voltage`
- Power fallback calculated as `voltage * current` when power is not reported
- Configurable power refresh modes:
  - Variable 5–15 seconds (default)
  - Variable 5–30 seconds
  - Fixed 10, 30, 60, or 300 seconds
  - Manual refresh only
- Configurable energy polling and electrical reporting intervals

## Supported devices

- Tuya `TS011F`
- Tuya `TS0121`

## License and attribution

The original driver is copyright 2022–2024 Jaewon Park (iquix) and is licensed under Apache-2.0.
The original license notice is retained in `src/init.lua` and in this repository's `LICENSE` file.
This repository contains modifications made for enhanced measurement and Korean settings support.
