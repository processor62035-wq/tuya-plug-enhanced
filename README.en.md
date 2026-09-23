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
- Tuya `_TZ3000_bppxj3sf` `TS011F` four-socket plus USB strip
- Tuya `TS0121`
- DAWON DNS `PM-B540-ZB`

## Added Features

- Korean device settings
- Voltage measurement
- Uses the real current value when the device reports it
- Fixed-voltage fallback when no voltage sensor is available
- Current fallback: `power / voltage`
- Power fallback: `voltage * current`
- Immediate voltage alarm based on the normal-voltage average (±5% or ±10%, default ±10%)
- Automatic switch-off at ±15% for 15 seconds, or immediately at ±20%
- Selectable alarm mode: off, strobe, siren and strobe+siren
- Individual child switches for outlets 2–4 and the USB group on the identified `_TZ3000_bppxj3sf` strip
- The strip-only `masterSwitchControlsAll` setting makes the parent switch control outlets 1–4 and the USB group. It defaults to off, preserving outlet 1-only parent control.

With whole-strip control enabled, the parent switch state is aggregated from endpoint reports 1–5. Any reported on endpoint makes it on; it becomes off only after all five endpoints report off. An endpoint with no report is not treated as off. Available device information and hub records establish the individual-endpoint structure, but whole-strip control has not been tested on the hardware.

For this strip, voltage auto-off turns off endpoints 1–5 regardless of the parent-switch setting. Power and energy polling also continues when endpoint 1 is off, because another outlet or the USB group may still be on.

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

## Immediate Voltage Alarm

Enable `전압 이상 즉시 경보` in the device settings and choose `±5%` or `±10%`
of the normal-voltage average; the default is ±10%. The first normal reading establishes the baseline,
and only normal readings update the average. When a reading leaves the selected
range, the driver emits the standard SmartThings `alarm` state immediately; it
does not wait for one minute. The alarm clears automatically when voltage returns
to the normal range, and the `alarm` capability can be used in SmartThings
automation conditions for notifications.

When `전압 이상 자동 차단` is enabled, the switch turns off after ±15% deviation
continues for 15 seconds, or immediately at ±20%. The driver emits the alarm state
once more immediately before either shutoff.

The alarm mode for a voltage deviation is configurable. Immediately before automatic
shutoff, the driver uses the siren regardless of the selected deviation mode.

## SmartThings Installation

Join the SmartThings Edge channel using this invitation link:

<https://bestow-regional.api.smartthings.com/invite/Boj0wXyx8qlA>

After joining the channel:

1. Install `Tuya Plug Enhanced by iquix` on the hub.
2. Open the Tuya plug in the SmartThings app.
3. Change its driver to `Tuya Plug Enhanced by iquix`.
4. Adjust the refresh mode and voltage fallback settings.
