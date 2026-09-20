# Tuya Plug Enhanced

Enhanced SmartThings Edge Zigbee driver for Tuya plugs

[View the Korean document](README.md)

## Source and License

This driver is a fork and enhancement of `tuya-plug` from:

- Original repository: <https://github.com/iquix/ST-Edge-Driver/tree/master/tuya-plug>
- Original author: Jaewon Park (iquix)
- Original license: Apache-2.0

The original copyright and license notices are retained in `src/init.lua` and `LICENSE`.
The source and change summary are also recorded in `NOTICE.md`.

## Supported Devices

- Tuya `TS011F`
- Tuya `TS0121`

## Added Features

- Korean device settings
- Voltage measurement
- Uses the real current value when the device reports it
- Fixed-voltage fallback when no voltage sensor is available
- Current fallback: `power / voltage`
- Power fallback: `voltage * current`

Fallback values are calculated values, not direct sensor readings.

## Refresh Settings

Power polling can be configured as:

- Variable 5–15 seconds: default
- Variable 5–30 seconds
- Fixed 10 seconds
- Fixed 30 seconds
- Fixed 60 seconds
- Fixed 300 seconds
- Manual refresh only

Energy polling and the voltage/current/power reporting interval can also be configured.

## SmartThings Installation

Join the SmartThings Edge channel using this invitation link:

<https://bestow-regional.api.smartthings.com/invite/Y7236AZwknMr>

After joining the channel:

1. Install `Tuya Plug Enhanced by iquix` on the hub.
2. Open the Tuya plug in the SmartThings app.
3. Change its driver to `Tuya Plug Enhanced by iquix`.
4. Adjust the refresh mode and voltage fallback settings.
