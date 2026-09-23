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
local st_device = require "st.device"
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
local STRIP_MANUFACTURER = "_TZ3000_bppxj3sf"
local STRIP_MODEL = "TS011F"
local STRIP_STATE_FIELD = "tuya_4socket_usb_endpoint_states"
local STRIP_ENDPOINTS = {1, 2, 3, 4, 5}
local STRIP_CHILD_ENDPOINTS = {2, 3, 4, 5}
local STRIP_ON_TIMER_FIELD = "tuya_4socket_usb_pending_on_timer"
local STRIP_ON_GENERATION_FIELD = "tuya_4socket_usb_on_generation"
local STRIP_ON_ACTIVE_FIELD = "tuya_4socket_usb_on_active"
local STRIP_ON_SKIP_ENDPOINTS_FIELD = "tuya_4socket_usb_on_skip_endpoints"
local STRIP_ON_INTERVAL_SECONDS = 0.5

local POWER_POLLING_TIMER = "tuya_plug_power_polling_timer"
local ENERGY_POLLING_TIMER = "tuya_plug_energy_polling_timer"
local AUTO_OFF_TIMER = "voltage_auto_off_timer"
local APPLICATION_VERSION = "application_version"
local REPORTING_DISABLED = 0xFFFF


---------------------------------------------------------------

local function is_child_device(device)
  return device.network_type == st_device.NETWORK_TYPE_CHILD
end

local function parent_device(device)
  if is_child_device(device) then
    return device:get_parent_device()
  end
  return device
end

local function is_four_socket_usb(device)
  local parent = parent_device(device)
  return parent ~= nil and parent:get_manufacturer() == STRIP_MANUFACTURER and parent:get_model() == STRIP_MODEL
end

local function master_controls_all(device)
  return is_four_socket_usb(device) and device.preferences.masterSwitchControlsAll == true
end

local function find_child(parent, endpoint)
  return parent:get_child_by_parent_assigned_key(string.format("%02X", endpoint))
end

local function endpoint_has_onoff(endpoint)
  for _, cluster_id in ipairs(endpoint.server_clusters or {}) do
    if type(cluster_id) == "table" then
      cluster_id = cluster_id.id or cluster_id.value
    end
    if tonumber(cluster_id) == OnOff.ID then
      return true
    end
  end
  return false
end

local function has_onoff_endpoint(device, endpoint_id)
  for _, endpoint in pairs(device.zigbee_endpoints or {}) do
    if tonumber(endpoint.id) == endpoint_id and endpoint_has_onoff(endpoint) then
      return true
    end
  end
  return false
end

local function create_strip_children(driver, device)
  if not is_four_socket_usb(device) or is_child_device(device) then return end
  for _, endpoint in ipairs(STRIP_CHILD_ENDPOINTS) do
    if has_onoff_endpoint(device, endpoint) and find_child(device, endpoint) == nil then
      local label = endpoint == 5 and "멀티탭 usb" or string.format("멀티탭 %d", endpoint)
      driver:try_create_device({
        type = "EDGE_CHILD",
        parent_assigned_child_key = string.format("%02X", endpoint),
        label = label,
        profile = "child-switch",
        parent_device_id = device.id,
        manufacturer = device:get_manufacturer(),
        model = device:get_model()
      })
    end
  end
end

local function emit_switch_state(device, endpoint, is_on)
  if endpoint == 1 or find_child(device, endpoint) ~= nil then
    device:emit_event_for_endpoint(endpoint, capabilities.switch.switch(is_on and "on" or "off"))
  end
end

local function update_master_switch_state(device)
  if not master_controls_all(device) then return end
  local states = device:get_field(STRIP_STATE_FIELD) or {}
  for _, endpoint in ipairs(STRIP_ENDPOINTS) do
    if states[endpoint] == true then
      device:emit_event(capabilities.switch.switch.on())
      return
    end
  end
  for _, endpoint in ipairs(STRIP_ENDPOINTS) do
    if states[endpoint] == nil then
      return
    end
  end
  device:emit_event(capabilities.switch.switch.off())
end

local function request_strip_switch_states(device)
  if not master_controls_all(device) then return end
  device:set_field(STRIP_STATE_FIELD, {})
  for _, endpoint in ipairs(STRIP_ENDPOINTS) do
    device:send(OnOff.attributes.OnOff:read(device):to_endpoint(endpoint))
  end
end

local function cancel_pending_strip_on(device)
  local timer = device:get_field(STRIP_ON_TIMER_FIELD)
  if timer then
    device.thread:cancel_timer(timer)
    device:set_field(STRIP_ON_TIMER_FIELD, nil)
  end
  local generation = (device:get_field(STRIP_ON_GENERATION_FIELD) or 0) + 1
  device:set_field(STRIP_ON_GENERATION_FIELD, generation)
  device:set_field(STRIP_ON_ACTIVE_FIELD, false)
  device:set_field(STRIP_ON_SKIP_ENDPOINTS_FIELD, nil)
  return generation
end

local function child_endpoint_id(device)
  local child_key = device.parent_assigned_child_key
  local endpoint = type(child_key) == "string" and tonumber(child_key, 16) or tonumber(child_key)
  return endpoint or tonumber(device:get_endpoint())
end

local function skip_pending_child_on(parent, endpoint)
  if endpoint == nil or not parent:get_field(STRIP_ON_ACTIVE_FIELD) then return end
  local skipped = parent:get_field(STRIP_ON_SKIP_ENDPOINTS_FIELD) or {}
  skipped[endpoint] = true
  parent:set_field(STRIP_ON_SKIP_ENDPOINTS_FIELD, skipped)
end

local function schedule_strip_on_endpoint(device, index, generation)
  local endpoint = STRIP_CHILD_ENDPOINTS[index]
  if endpoint == nil then
    if device:get_field(STRIP_ON_GENERATION_FIELD) == generation then
      device:set_field(STRIP_ON_ACTIVE_FIELD, false)
      device:set_field(STRIP_ON_SKIP_ENDPOINTS_FIELD, nil)
      device:set_field(STRIP_ON_TIMER_FIELD, nil)
    end
    return
  end
  local timer = device.thread:call_with_delay(STRIP_ON_INTERVAL_SECONDS, function()
    if device:get_field(STRIP_ON_GENERATION_FIELD) ~= generation then return end
    device:set_field(STRIP_ON_TIMER_FIELD, nil)
    local skipped = device:get_field(STRIP_ON_SKIP_ENDPOINTS_FIELD) or {}
    if not skipped[endpoint] then
      device:send(OnOff.server.commands.On(device):to_endpoint(endpoint))
    end
    schedule_strip_on_endpoint(device, index + 1, generation)
  end)
  device:set_field(STRIP_ON_TIMER_FIELD, timer)
end

local function send_strip_off_to_all(device)
  local parent = parent_device(device)
  if parent == nil then return end
  cancel_pending_strip_on(parent)
  for _, endpoint in ipairs(STRIP_ENDPOINTS) do
    parent:send(OnOff.server.commands.Off(parent):to_endpoint(endpoint))
  end
end

local function configure_strip_child_endpoints(device)
  if not is_four_socket_usb(device) then return end
  local onoff_config = device_management.attr_config(device, switch_defaults.default_on_off_configuration)
  for _, endpoint in ipairs(STRIP_CHILD_ENDPOINTS) do
    if has_onoff_endpoint(device, endpoint) then
      local bind = device_management.build_bind_request(device, OnOff.ID, device.driver.environment_info.hub_zigbee_eui, endpoint)
      device:send(bind:to_endpoint(endpoint))
      device:send(onoff_config:to_endpoint(endpoint))
      device:send(OnOff.attributes.OnOff:read(device):to_endpoint(endpoint))
    end
  end
end


local function power_refresh(device)
  log.debug("** power_refresh()")
  if is_child_device(device) then return end
  if is_four_socket_usb(device) or (device:get_latest_state("main", capabilities.switch.ID, capabilities.switch.switch.NAME) ~= "off") then
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

local function cancel_auto_off(device)
  local timer = device:get_field(AUTO_OFF_TIMER)
  if timer then
    device.thread:cancel_timer(timer)
    device:set_field(AUTO_OFF_TIMER, nil)
  end
end

local function emit_voltage_alarm(device)
  local mode = device.preferences.voltageAlarmMode or "strobe"
  if mode == "off" then
    device:emit_event(capabilities.alarm.alarm.off())
  elseif mode == "siren" then
    device:emit_event(capabilities.alarm.alarm.siren())
  elseif mode == "both" then
    device:emit_event(capabilities.alarm.alarm.both())
  else
    device:emit_event(capabilities.alarm.alarm.strobe())
  end
end

local function switch_off_for_voltage(device)
  cancel_auto_off(device)
  -- 차단 직전에 경보 상태를 다시 전환해 자동화 알림을 확실히 발생시킵니다.
  device:emit_event(capabilities.alarm.alarm.off())
  device:emit_event(capabilities.alarm.alarm.siren())
  if is_four_socket_usb(device) then
    send_strip_off_to_all(device)
  else
    device:send(OnOff.server.commands.Off(device))
  end
end

local function evaluate_voltage_auto_off(device, voltage, average)
  if device.preferences.voltageAutoOffEnabled == false or average == nil or average <= 0 then
    cancel_auto_off(device)
    return
  end
  local deviation = math.abs(voltage - average) / average
  if deviation >= 0.20 then
    switch_off_for_voltage(device)
  elseif deviation >= 0.15 then
    if device:get_field(AUTO_OFF_TIMER) == nil then
      local timer = device.thread:call_with_delay(15, function()
        local latest = device:get_field("last_voltage")
        local current_average = device:get_field("voltage_average")
        if device.preferences.voltageAutoOffEnabled ~= false and latest and current_average and current_average > 0 and math.abs(latest - current_average) / current_average >= 0.15 then
          switch_off_for_voltage(device)
        else
          cancel_auto_off(device)
        end
      end)
      device:set_field(AUTO_OFF_TIMER, timer)
    end
  else
    cancel_auto_off(device)
  end
end

local function evaluate_voltage_alarm(device, voltage)
  local alarm_enabled = device.preferences.voltageAlarmEnabled ~= false
  local auto_off_enabled = device.preferences.voltageAutoOffEnabled ~= false
  if not alarm_enabled and device:get_field("voltage_alarm_active") then
    device:emit_event(capabilities.alarm.alarm.off())
    device:set_field("voltage_alarm_active", false)
  end
  if not alarm_enabled and not auto_off_enabled then
    device:set_field("voltage_average", nil)
    cancel_auto_off(device)
    return
  end
  local average = device:get_field("voltage_average")
  if average == nil or average <= 0 then
    device:set_field("voltage_average", voltage, {persist = true})
    evaluate_voltage_auto_off(device, voltage, voltage)
    return
  end
  local tolerance = tonumber(device.preferences.voltageAlarmTolerance) or 5
  local out_of_range = voltage < average * (1 - tolerance / 100) or voltage > average * (1 + tolerance / 100)
  local active = device:get_field("voltage_alarm_active") == true
  if alarm_enabled then
    if out_of_range and not active then
      emit_voltage_alarm(device)
      device:set_field("voltage_alarm_active", true, {persist = true})
    elseif not out_of_range and active then
      device:emit_event(capabilities.alarm.alarm.off())
      device:set_field("voltage_alarm_active", false, {persist = true})
    end
  end
  if not out_of_range then
    device:set_field("voltage_average", average * 0.9 + voltage * 0.1, {persist = true})
  end
  evaluate_voltage_auto_off(device, voltage, average)
end

local function emit_fallbacks(device, skip_voltage_event)
  local voltage = effective_voltage(device)
  local low_voltage_fallback = not is_four_socket_usb(device) and (device:get_field("last_voltage") or 0) < 100
  if not skip_voltage_event and (device.preferences.voltageMode == "fixed" or not device:get_field("voltage_seen") or low_voltage_fallback) then
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
  if is_child_device(device) then return end
  local voltage = scale_electrical(device, value, "voltage_multiplier", "voltage_divisor", 10)
  if device.preferences.voltageMode ~= "fixed" and value.value >= 100 and voltage < 100 then
    voltage = value.value * (device:get_field("voltage_multiplier") or 1)
  end
  if is_four_socket_usb(device) and voltage <= 0 then
    cancel_auto_off(device)
    device:emit_event(capabilities.voltageMeasurement.voltage({value = effective_voltage(device), unit = "V"}))
    emit_fallbacks(device, true)
    return
  end
  device:set_field("voltage_seen", true)
  device:set_field("last_voltage", voltage)
  if device.preferences.voltageMode ~= "fixed" then
    device:emit_event(capabilities.voltageMeasurement.voltage({value = voltage, unit = "V"}))
  end
  evaluate_voltage_alarm(device, voltage)
  emit_fallbacks(device)
end

local function current_handler(driver, device, value)
  if is_child_device(device) then return end
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
  if is_child_device(device) then return end
  local power = scale_electrical(device, value, "power_multiplier", "power_divisor", 1)
  if power == 0 and (device:get_field("last_power") or 0) > 0 then
    return
  end
  device:set_field("last_power", power)
  device:emit_event(capabilities.powerMeter.power({value = power, unit = "W"}))
  emit_fallbacks(device)
end

local function instantaneous_power_handler(driver, device, value)
  if is_child_device(device) then return end
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
    if is_child_device(device) then return end
    local number = value.value
    if number == 0 then number = default end
    device:set_field(field, number, {persist = true})
  end
end

local function energy_refresh(device)
  log.debug("** energy_refresh()")
  if is_child_device(device) then return end
  if is_four_socket_usb(device) or (device:get_latest_state("main", capabilities.switch.ID, capabilities.switch.switch.NAME) ~= "off") then
    device:send(SimpleMetering.attributes.CurrentSummationDelivered:read(device))
  end
end

local function is_polling(device) 
  if is_child_device(device) then return false end
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
  if is_child_device(device) then return end
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
  if is_child_device(device) then return end
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
  if is_child_device(device) then return end
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
  if is_child_device(device) then return end
  local version = tonumber(value.value)
  device:set_field(APPLICATION_VERSION, version, {persist = true})
  setup_power_polling(device)
end

local function on_off_attr_handler(driver, device, value, zb_rx)
  if is_child_device(device) then return end
  if is_four_socket_usb(device) then
    local endpoint = zb_rx.address_header.src_endpoint.value
    if endpoint >= 1 and endpoint <= 5 then
      local is_on = value.value == true or value.value == 1
      local states = device:get_field(STRIP_STATE_FIELD) or {}
      if states[endpoint] == true and not is_on and device:get_field(STRIP_ON_ACTIVE_FIELD) then
        if endpoint == 1 then
          cancel_pending_strip_on(device)
        else
          skip_pending_child_on(device, endpoint)
        end
      end
      states[endpoint] = is_on
      device:set_field(STRIP_STATE_FIELD, states)
      if endpoint ~= 1 or not master_controls_all(device) then
        emit_switch_state(device, endpoint, is_on)
      end
      update_master_switch_state(device)
    end
    if is_polling(device) then
      device.thread:call_with_delay(5, function(d)
        power_refresh(device)
      end)
    end
    return
  end
  if is_polling(device) then
    power_polling_timer = device.thread:call_with_delay(5, function(d)
      power_refresh(device)
    end)
  end
  switch_defaults.on_off_attr_handler(driver, device, value, zb_rx)
end

local function switch_on(driver, device, command)
  if is_four_socket_usb(device) then
    local parent = parent_device(device)
    if parent == nil then return end
    if is_child_device(device) then
      skip_pending_child_on(parent, child_endpoint_id(device))
      switch_defaults.on(driver, device, command)
    elseif master_controls_all(device) then
      if parent:get_field(STRIP_ON_ACTIVE_FIELD) then return end
      local generation = cancel_pending_strip_on(parent)
      parent:set_field(STRIP_ON_ACTIVE_FIELD, true)
      parent:set_field(STRIP_ON_SKIP_ENDPOINTS_FIELD, {})
      switch_defaults.on(driver, device, command)
      schedule_strip_on_endpoint(parent, 1, generation)
    else
      cancel_pending_strip_on(parent)
      switch_defaults.on(driver, device, command)
    end
    return
  end
  switch_defaults.on(driver, device, command)
end

local function switch_off(driver, device, command)
  if is_four_socket_usb(device) then
    local parent = parent_device(device)
    if parent == nil then return end
    if is_child_device(device) then
      skip_pending_child_on(parent, child_endpoint_id(device))
      switch_defaults.off(driver, device, command)
    elseif master_controls_all(device) then
      send_strip_off_to_all(parent)
    else
      cancel_pending_strip_on(parent)
      switch_defaults.off(driver, device, command)
    end
    return
  end
  switch_defaults.off(driver, device, command)
end

---------------------------------------------------------------------


local function device_added(self, device)
  log.debug("** device_added()")
  if is_child_device(device) then return end
  device:set_field(constants.SIMPLE_METERING_DIVISOR_KEY, 100, {persist = true})
  if is_four_socket_usb(device) then
    create_strip_children(self, device)
    if not master_controls_all(device) and device:get_latest_state("main", capabilities.switch.ID, capabilities.switch.switch.NAME) ~= "on" then
      device:emit_event(capabilities.switch.switch.off())
    end
    return
  end
end

local function device_init(self, device)
  log.debug("** device_init()")
  if is_child_device(device) then return end
  math.randomseed(os.time())
  if is_four_socket_usb(device) then
    device:set_find_child(find_child)
    create_strip_children(self, device)
  end
  
  local ver = device:get_field(APPLICATION_VERSION)
  if ver==nil or c==0 then
    device:set_field(APPLICATION_VERSION, 0)
    device:send(Basic.attributes.ApplicationVersion:read(device))
  else
    setup_power_polling(device)
  end
  setup_energy_polling(device)
  if master_controls_all(device) then
    request_strip_switch_states(device)
  end

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
  if is_child_device(device) then return end
  device:configure()
  device:refresh()
  configure_strip_child_endpoints(device)
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
  if is_child_device(device) then return end
  if is_four_socket_usb(device) then
    cancel_pending_strip_on(device)
  end
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
  if args.old_st_store.preferences.voltageAlarmEnabled ~= device.preferences.voltageAlarmEnabled or
    args.old_st_store.preferences.voltageAlarmTolerance ~= device.preferences.voltageAlarmTolerance or
    args.old_st_store.preferences.voltageAlarmMode ~= device.preferences.voltageAlarmMode then
    if device:get_field("voltage_alarm_active") then
      device:emit_event(capabilities.alarm.alarm.off())
    end
    device:set_field("voltage_alarm_active", false)
    if device.preferences.voltageAlarmEnabled == false and device.preferences.voltageAutoOffEnabled == false then
      device:set_field("voltage_average", nil)
    end
    emit_fallbacks(device)
  end
  if args.old_st_store.preferences.voltageAutoOffEnabled ~= device.preferences.voltageAutoOffEnabled then
    cancel_auto_off(device)
    if device.preferences.voltageAlarmEnabled == false and device.preferences.voltageAutoOffEnabled == false then
      device:set_field("voltage_average", nil)
    end
  end
  if args.old_st_store.preferences.masterSwitchControlsAll ~= device.preferences.masterSwitchControlsAll then
    device:set_field(STRIP_STATE_FIELD, {})
    if master_controls_all(device) then
      request_strip_switch_states(device)
    else
      device:send(OnOff.attributes.OnOff:read(device):to_endpoint(1))
    end
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
    capabilities.alarm,
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
  health_check = false,
  capability_handlers = {
    [capabilities.switch.ID] = {
      [capabilities.switch.commands.on.NAME] = switch_on,
      [capabilities.switch.commands.off.NAME] = switch_off,
    },
    [capabilities.alarm.ID] = {
      [capabilities.alarm.commands.off.NAME] = function(driver, device)
        device:emit_event(capabilities.alarm.alarm.off())
        device:set_field("voltage_alarm_active", false, {persist = true})
      end,
      [capabilities.alarm.commands.siren.NAME] = function(driver, device)
        device:emit_event(capabilities.alarm.alarm.siren())
        device:set_field("voltage_alarm_active", true, {persist = true})
      end,
    },
  }
}

defaults.register_for_default_handlers(tuya_plug, tuya_plug.supported_capabilities, {native_capability_cmds_enabled = true})
local zigbee_driver = ZigbeeDriver("tuya-plug", tuya_plug)
zigbee_driver:run()
