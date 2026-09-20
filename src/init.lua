-- tuya Plug ver 0.1.2
-- Copyright 2022-2024 Jaewon Park (iquix)
--
-- Licensed under the Apache License, Version 2.0 (the "License");
-- you may not use this file except in compliance with the License.
-- You may obtain a copy of the License at
--
--     http://www.apache.org/licenses/LICENSE-2.0
--
-- Unless required by applicable law or agreed to in writing, software
-- distributed under the License is distributed on an "AS IS" BASIS,
-- WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
-- See the License for the specific language governing permissions and
-- limitations under the License.

local capabilities = require "st.capabilities"
local zcl_clusters = require "st.zigbee.zcl.clusters"
local zcl_types = require "st.zigbee.zcl.types"
local ZigbeeDriver = require "st.zigbee"
local constants = require "st.zigbee.constants"
local defaults = require "st.zigbee.defaults"
local switch_defaults = require "st.zigbee.defaults.switch_defaults"
local device_management = require "st.zigbee.device_management"
local log = require "log"

local Basic = zcl_clusters.Basic
local OnOff = zcl_clusters.OnOff
local SimpleMetering = zcl_clusters.SimpleMetering
local ElectricalMeasurement = zcl_clusters.ElectricalMeasurement

local POWER_POLLING_TIMER = "tuya_plug_power_polling_timer"
local ENERGY_POLLING_TIMER = "tuya_plug_energy_polling_timer"
local APPLICATION_VERSION = "application_version"
local REPORTING_DISABLED = 0xFFFF


---------------------------------------------------------------


local function power_refresh(device)
  log.debug("** power_refresh()")
  if (device:get_latest_state("main", capabilities.switch.ID, capabilities.switch.switch.NAME) ~= "off") then
    device:send(SimpleMetering.attributes.InstantaneousDemand:read(device))
    device:send(ElectricalMeasurement.attributes.ActivePower:read(device))
    device:send(ElectricalMeasurement.attributes.RMSVoltage:read(device))
    device:send(ElectricalMeasurement.attributes.RMSCurrent:read(device))
  end
end

local function configured_voltage(device)
  local preset = device.preferences.voltagePreset or "auto"
  if preset == "100" then return 100 end
  if preset == "110" then return 110 end
  if preset == "220" then return 220 end
  if preset == "230" then return 230 end
  return 220
end

local function effective_voltage(device)
  if device.preferences.voltageMode == "fixed" then
    return configured_voltage(device)
  end
  local voltage = device:get_field("last_voltage")
  if voltage == nil or voltage < 100 then return configured_voltage(device) end
  return voltage
end

local function emit_fallbacks(device)
  local voltage = effective_voltage(device)
  if device.preferences.voltageMode == "fixed" or not device:get_field("voltage_seen") or (device:get_field("last_voltage") or 0) < 100 then
    device:emit_event(capabilities.voltageMeasurement.voltage({value = voltage, unit = "V"}))
  end
  local power = device:get_field("last_power")
  local current = device:get_field("last_current")
  if power == nil and current ~= nil then
    device:emit_event(capabilities.powerMeter.power({value = current * voltage, unit = "W"}))
  elseif current == nil and power ~= nil and voltage > 0 then
    device:emit_event(capabilities.currentMeasurement.current({value = power / voltage, unit = "A"}))
  end
end

local function scale_electrical(device, value, multiplier_key, divisor_key, default_divisor)
  local multiplier = device:get_field(multiplier_key) or 1
  local divisor = device:get_field(divisor_key) or default_divisor
  if divisor == 0 then divisor = default_divisor end
  return value.value * multiplier / divisor
end

local function voltage_handler(driver, device, value)
  local voltage = scale_electrical(device, value, "voltage_multiplier", "voltage_divisor", 10)
  if device.preferences.voltageMode ~= "fixed" and value.value >= 100 and voltage < 100 then
    voltage = value.value * (device:get_field("voltage_multiplier") or 1)
  end
  device:set_field("voltage_seen", true)
  device:set_field("last_voltage", voltage)
  device:emit_event(capabilities.voltageMeasurement.voltage({value = voltage, unit = "V"}))
  emit_fallbacks(device)
end

local function current_handler(driver, device, value)
  local current = scale_electrical(device, value, "current_multiplier", "current_divisor", 1000)
  if current == 0 and (device:get_field("last_power") or 0) > 0 then
    device:set_field("current_seen", nil)
    emit_fallbacks(device)
    return
  end
  device:set_field("current_seen", true)
  device:set_field("last_current", current)
  device:emit_event(capabilities.currentMeasurement.current({value = current, unit = "A"}))
  emit_fallbacks(device)
end

local function active_power_handler(driver, device, value)
  local power = scale_electrical(device, value, "power_multiplier", "power_divisor", 1)
  if power == 0 and (device:get_field("last_power") or 0) > 0 then
    return
  end
  device:set_field("last_power", power)
  device:emit_event(capabilities.powerMeter.power({value = power, unit = "W"}))
  emit_fallbacks(device)
end

local function instantaneous_power_handler(driver, device, value)
  local divisor = device:get_field("meter_divisor") or 100
  if device:get_manufacturer() == "DAWON_DNS" and device:get_model() == "PM-B540-ZB" then
    -- This model reports InstantaneousDemand directly in watts.
    divisor = 1
  end
  local power = value.value * (device:get_field("meter_multiplier") or 1) / divisor
  if power == 0 and (device:get_field("last_power") or 0) > 0 then
    return
  end
  device:set_field("last_power", power)
  device:emit_event(capabilities.powerMeter.power({value = power, unit = "W"}))
  emit_fallbacks(device)
end

local function save_electrical_scale(field, default)
  return function(driver, device, value)
    local number = value.value
    if number == 0 then number = default end
    device:set_field(field, number, {persist = true})
  end
end

local function energy_refresh(device)
  log.debug("** energy_refresh()")
  if (device:get_latest_state("main", capabilities.switch.ID, capabilities.switch.switch.NAME) ~= "off") then
    device:send(SimpleMetering.attributes.CurrentSummationDelivered:read(device))
  end
end

local function is_polling(device) 
  local manufacturer = device:get_manufacturer()
  local model = device:get_model()
  local app_ver = device:get_field(APPLICATION_VERSION)
  local power_polling = device.preferences.powerPolling
  local polling_mode = device.preferences.powerPollingMode or "variable_5_15"
  local polling_TS011F_app_vers = {[69]=true, [68]=true, [65]=true, [64]=true}
  local push_TS0121_devices = {_TZ3000_8nkb7mof=true}
  return (power_polling ~= "p2") and (polling_mode ~= "manual") and ((model == "TS0121" and (push_TS0121_devices[manufacturer] == nil) ) or (model == "TS011F" and polling_TS011F_app_vers[app_ver] == true) or power_polling == "p1")
end

local function power_poll_bounds(device)
  local mode = device.preferences.powerPollingMode or "variable_5_15"
  if mode == "variable_5_30" then return 5, 30 end
  if mode == "fixed_10" then return 10, 10 end
  if mode == "fixed_30" then return 30, 30 end
  if mode == "fixed_60" then return 60, 60 end
  if mode == "fixed_300" then return 300, 300 end
  if mode == "manual" then return nil, nil end
  return 5, 15
end

local function schedule_power_polling(device)
  local min_seconds, max_seconds = power_poll_bounds(device)
  if min_seconds == nil then return end
  local delay = math.random(min_seconds, max_seconds)
  local timer = device.thread:call_with_delay(delay, function()
    power_refresh(device)
    schedule_power_polling(device)
  end)
  device:set_field(POWER_POLLING_TIMER, timer)
end

local function setup_power_polling(device)
  log.debug("** setup_power_polling()")
  local power_polling_timer = device:get_field(POWER_POLLING_TIMER)
  if power_polling_timer then
    log.debug("** unschedule power polling...")
    device.thread:cancel_timer(power_polling_timer)
    power_polling_timer = nil
  end
  if is_polling(device) then
    log.debug("** set variable power polling...")
    schedule_power_polling(device)
    power_polling_timer = device:get_field(POWER_POLLING_TIMER)
  end
  device:set_field(POWER_POLLING_TIMER, power_polling_timer)
end

local function setup_energy_polling(device)
  log.debug("** setup_energy_polling()")
  local energy_polling_timer = device:get_field(ENERGY_POLLING_TIMER)
  if energy_polling_timer then
    log.debug("** unschedule energy polling...")
    device.thread:cancel_timer(energy_polling_timer)
    energy_polling_timer = nil
  end
  if device.preferences.energyPolling then
    local interval = tonumber(device.preferences.energyPollingInterval) or 60
    log.debug(string.format("** set energy polling every %d seconds...", interval))
    energy_polling_timer = device.thread:call_on_schedule(interval, function(d)
      energy_refresh(device)
    end)
  end
  device:set_field(ENERGY_POLLING_TIMER, energy_polling_timer)
end


---------------------------------------------------------------


local function energy_meter_handler(driver, device, value, zb_rx)
  local raw_value = value.value
  local multiplier = device:get_field(constants.SIMPLE_METERING_MULTIPLIER_KEY) or 1
  local divisor = device:get_field(constants.SIMPLE_METERING_DIVISOR_KEY) or 100
  local converted_value = raw_value * multiplier/divisor

  local delta_energy = 0.0
  local current_power_consumption = device:get_latest_state("main", capabilities.powerConsumptionReport.ID, capabilities.powerConsumptionReport.powerConsumption.NAME)
  if current_power_consumption ~= nil then
    delta_energy = math.max(raw_value - current_power_consumption.energy, 0.0)
  end
  device:emit_event(capabilities.powerConsumptionReport.powerConsumption({energy = raw_value, deltaEnergy = delta_energy })) -- the unit of these values should be 'Wh'
  device:emit_event(capabilities.energyMeter.energy({value = converted_value, unit = "kWh"}))
end

local function application_version_attr_handler(driver, device, value, zb_rx)
  local version = tonumber(value.value)
  device:set_field(APPLICATION_VERSION, version, {persist = true})
  setup_power_polling(device)
end

local function on_off_attr_handler(driver, device, value, zb_rx)
  if is_polling(device) then
    power_polling_timer = device.thread:call_with_delay(5, function(d)
      power_refresh(device)
    end)
  end
  switch_defaults.on_off_attr_handler(driver, device, value, zb_rx)
end

---------------------------------------------------------------------


local function device_added(self, device)
  log.debug("** device_added()")
  device:set_field(constants.SIMPLE_METERING_DIVISOR_KEY, 100, {persist = true})
end

local function device_init(self, device)
  log.debug("** device_init()")
  math.randomseed(os.time())
  
  local ver = device:get_field(APPLICATION_VERSION)
  if ver==nil or c==0 then
    device:set_field(APPLICATION_VERSION, 0)
    device:send(Basic.attributes.ApplicationVersion:read(device))
  else
    setup_power_polling(device)
  end
  setup_energy_polling(device)

  -- Read Divisor and multipler for PowerMeter
  device:send(SimpleMetering.attributes.Divisor:read(device))
  device:send(SimpleMetering.attributes.Multiplier:read(device))
  -- Read Divisor and multipler for EnergyMeter
  device:send(ElectricalMeasurement.attributes.ACPowerDivisor:read(device))
  device:send(ElectricalMeasurement.attributes.ACPowerMultiplier:read(device))
  device:send(ElectricalMeasurement.attributes.ACVoltageDivisor:read(device))
  device:send(ElectricalMeasurement.attributes.ACVoltageMultiplier:read(device))
  device:send(ElectricalMeasurement.attributes.ACCurrentDivisor:read(device))
  device:send(ElectricalMeasurement.attributes.ACCurrentMultiplier:read(device))
end

local function do_configure(self, device)
  log.debug("** do_configure()")
  device:configure()
  device:refresh()
  local _, report_interval = power_poll_bounds(device)
  report_interval = report_interval or REPORTING_DISABLED
  local energy_interval = tonumber(device.preferences.energyPollingInterval) or 60
  device:send(SimpleMetering.attributes.CurrentSummationDelivered:configure_reporting(device, 1, energy_interval, 1))
  device:send(ElectricalMeasurement.attributes.RMSVoltage:configure_reporting(device, 1, report_interval, 1))
  device:send(ElectricalMeasurement.attributes.RMSCurrent:configure_reporting(device, 1, report_interval, 1))
  device:send(ElectricalMeasurement.attributes.ActivePower:configure_reporting(device, 1, report_interval, 1))
end

local function device_info_changed(driver, device, event, args)
  log.debug("** device_info_changed()")
  if args.old_st_store.preferences.powerPolling ~= device.preferences.powerPolling then
    setup_power_polling(device)
  end
  if args.old_st_store.preferences.energyPolling ~= device.preferences.energyPolling then
    setup_energy_polling(device)
  end
  if args.old_st_store.preferences.powerPollingMode ~= device.preferences.powerPollingMode then
    setup_power_polling(device)
  end
  if args.old_st_store.preferences.energyPollingInterval ~= device.preferences.energyPollingInterval then
    setup_energy_polling(device)
    do_configure(driver, device)
  end
  if args.old_st_store.preferences.electricalReportInterval ~= device.preferences.electricalReportInterval then
    do_configure(driver, device)
  end
  if args.old_st_store.preferences.voltageMode ~= device.preferences.voltageMode or
    args.old_st_store.preferences.voltagePreset ~= device.preferences.voltagePreset then
    emit_fallbacks(device)
  end
end


---------------------------------------------------------------------


local tuya_plug = {
  supported_capabilities = {
    capabilities.switch,
    capabilities.powerMeter,
    capabilities.voltageMeasurement,
    capabilities.currentMeasurement,
    capabilities.energyMeter,
    capabilities.powerConsumptionReport,
    capabilities.refresh,
  },
  zigbee_handlers = {
    attr = {
      [Basic.ID] = {
        [Basic.attributes.ApplicationVersion.ID] = application_version_attr_handler
      },
      [SimpleMetering.ID] = {
        [SimpleMetering.attributes.CurrentSummationDelivered.ID] = energy_meter_handler,
        [SimpleMetering.attributes.InstantaneousDemand.ID] = instantaneous_power_handler,
      },
      [ElectricalMeasurement.ID] = {
        [ElectricalMeasurement.attributes.RMSVoltage.ID] = voltage_handler,
        [ElectricalMeasurement.attributes.RMSCurrent.ID] = current_handler,
        [ElectricalMeasurement.attributes.ActivePower.ID] = active_power_handler,
        [ElectricalMeasurement.attributes.ACVoltageDivisor.ID] = save_electrical_scale("voltage_divisor", 10),
        [ElectricalMeasurement.attributes.ACVoltageMultiplier.ID] = save_electrical_scale("voltage_multiplier", 1),
        [ElectricalMeasurement.attributes.ACCurrentDivisor.ID] = save_electrical_scale("current_divisor", 1000),
        [ElectricalMeasurement.attributes.ACCurrentMultiplier.ID] = save_electrical_scale("current_multiplier", 1),
        [ElectricalMeasurement.attributes.ACPowerDivisor.ID] = save_electrical_scale("power_divisor", 1),
        [ElectricalMeasurement.attributes.ACPowerMultiplier.ID] = save_electrical_scale("power_multiplier", 1),
      },
      [OnOff.ID] = {
        [OnOff.attributes.OnOff.ID] = on_off_attr_handler,
      },
    }
  },
  lifecycle_handlers = {
    added = device_added,
    init = device_init,
    doConfigure = do_configure,
    infoChanged = device_info_changed,
  },
  health_check = false
}

defaults.register_for_default_handlers(tuya_plug, tuya_plug.supported_capabilities, {native_capability_cmds_enabled = true})
local zigbee_driver = ZigbeeDriver("tuya-plug", tuya_plug)
zigbee_driver:run()
