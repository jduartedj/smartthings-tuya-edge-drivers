-- Copyright 2026 Duarte Sotto-Mayor Ribeirinho
-- Licensed under the Apache License, Version 2.0

--
-- Standalone SmartThings Edge driver for the Manhot MB60L-ZG-ZT-TY roller-blind
-- motor (Zigbee manufacturer _TZE284_2gi1hy8s, model TS0601).
--
-- This motor talks over the Tuya manufacturer cluster 0xEF00 using a remapped
-- datapoint set instead of the classic Tuya cover map (DP2 = set, DP3 = report):
--
--   DP1  (enum)  control          0 = open, 1 = stop, 2 = close
--   DP8  (value) percent_control  target position (write)
--   DP9  (value) percent_state    actual current position (report; also accepts the set)
--   DP11 (enum)  motor_direction  0 = normal, 1 = reversed
--   DP13 (value) battery          0-100 %
--
-- Position datapoints are INVERTED versus SmartThings: the device uses
-- 0 = fully open / 100 = fully closed, while windowShadeLevel uses
-- 0 = closed / 100 = open, so we convert with `100 - value` both directions.
--
-- Notes from live reverse-engineering:
--  * Writing the target to DP9 (not DP8) is what actually moves the motor, so we
--    write both to be safe.
--  * DP9 is the authoritative position; the device also emits trailing DP1
--    work-state reports after a move that must be ignored to avoid the tile
--    flicking back to opening/closing.
--

local capabilities = require "st.capabilities"
local ZigbeeDriver = require "st.zigbee"
local ZigbeeZcl = require "st.zigbee.zcl"
local Messages = require "st.zigbee.messages"
local data_types = require "st.zigbee.data_types"
local ZigbeeConstants = require "st.zigbee.constants"
local generic_body = require "st.zigbee.generic_body"
local log = require "log"

local TUYA_CLUSTER = 0xEF00
local TUYA_CMD_REQUEST = 0x00
local TUYA_CMD_QUERY = 0x03

local DP_TYPE_VALUE = "\x02"
local DP_TYPE_ENUM = "\x04"

local DP_ID_CONTROL = "\x01"
local DP_ID_SET_POSITION = "\x08"
local DP_ID_SET_POSITION_ALT = "\x09"
local DP_ID_MOTOR_DIRECTION = "\x0B"

local DP_RX_CONTROL = 1
local DP_RX_SET_POSITION = 8
local DP_RX_POSITION = 9
local DP_RX_MOTOR_DIRECTION = 11
local DP_RX_BATTERY = 13

local DP_VAL_OPEN = "\x00"
local DP_VAL_PAUSE = "\x01"
local DP_VAL_CLOSE = "\x02"
local DP_VAL_DIRECT = "\x00"
local DP_VAL_REVERSE = "\x01"

local PRESET_LEVEL_KEY = "_presetLevel"
local DEFAULT_PRESET = 50

local SeqNum = 0

------------------------- low-level send helpers -------------------------

local function send_tuya(device, cmd, DpId, Type, Value)
  local addrh = Messages.AddressHeader(
    ZigbeeConstants.HUB.ADDR,
    ZigbeeConstants.HUB.ENDPOINT,
    device:get_short_address(),
    device:get_endpoint(TUYA_CLUSTER),
    ZigbeeConstants.HA_PROFILE_ID,
    TUYA_CLUSTER
  )
  local zclh = ZigbeeZcl.ZclHeader({cmd = data_types.ZCLCommandId(cmd)})
  zclh.frame_ctrl:set_cluster_specific()
  SeqNum = (SeqNum + 1) % 65536
  local body
  if DpId ~= nil then
    body = string.pack(">I2", SeqNum) .. DpId .. Type .. string.pack(">I2", string.len(Value)) .. Value
  else
    body = string.pack(">I2", SeqNum)
  end
  local MsgBody = ZigbeeZcl.ZclMessageBody({zcl_header = zclh, zcl_body = generic_body.GenericBody(body)})
  device:send(Messages.ZigbeeMessageTx({address_header = addrh, body = MsgBody}))
end

local function set_dp(device, DpId, Type, Value)
  send_tuya(device, TUYA_CMD_REQUEST, DpId, Type, Value)
end

------------------------- capability event helpers -------------------------

local function get_latest_level(device)
  return device:get_latest_state("main", capabilities.windowShadeLevel.ID,
    capabilities.windowShadeLevel.shadeLevel.NAME) or 0
end

local function to_st_level(device_value)
  return 100 - device_value
end

local function to_device_value(st_level)
  return 100 - st_level
end

local function emit_movement(device, target_level)
  local current = get_latest_level(device)
  if current ~= target_level then
    if current > target_level then
      device:emit_event(capabilities.windowShade.windowShade.closing())
    else
      device:emit_event(capabilities.windowShade.windowShade.opening())
    end
  end
end

local function emit_final_position(device, level)
  local state
  if type(level) ~= "number" or level < 0 or level > 100 then
    state = "unknown"
    level = 50
  elseif level == 0 then
    state = "closed"
  elseif level == 100 then
    state = "open"
  else
    state = "partially open"
  end
  device:emit_event(capabilities.windowShadeLevel.shadeLevel(level))
  device:emit_event(capabilities.windowShade.windowShade(state))
end

local function get_preset_level(device)
  return device:get_latest_state("main", capabilities.windowShadePreset.ID, "position")
    or device:get_field(PRESET_LEVEL_KEY)
    or (device.preferences ~= nil and device.preferences.presetPosition)
    or DEFAULT_PRESET
end

------------------------- capability handlers -------------------------

local function open_handler(driver, device, command)
  device:emit_event(capabilities.windowShade.windowShade.opening())
  set_dp(device, DP_ID_CONTROL, DP_TYPE_ENUM, DP_VAL_OPEN)
end

local function close_handler(driver, device, command)
  device:emit_event(capabilities.windowShade.windowShade.closing())
  set_dp(device, DP_ID_CONTROL, DP_TYPE_ENUM, DP_VAL_CLOSE)
end

local function pause_handler(driver, device, command)
  set_dp(device, DP_ID_CONTROL, DP_TYPE_ENUM, DP_VAL_PAUSE)
end

local function set_shade_level_handler(driver, device, command)
  local level = command.args.shadeLevel
  local device_value = string.pack(">I4", to_device_value(level))
  -- The motor accepts the "go to position" write on DP9; DP8 is the target echo
  -- on some firmware. Writing both is safe (the unused one is ignored).
  set_dp(device, DP_ID_SET_POSITION, DP_TYPE_VALUE, device_value)
  set_dp(device, DP_ID_SET_POSITION_ALT, DP_TYPE_VALUE, device_value)
end

local function preset_position_handler(driver, device, command)
  set_shade_level_handler(driver, device, {args = {shadeLevel = get_preset_level(device)}})
end

local function set_preset_position_handler(driver, device, command)
  device:emit_event(capabilities.windowShadePreset.position(command.args.position))
  device:set_field(PRESET_LEVEL_KEY, command.args.position, {persist = true})
end

local function refresh_handler(driver, device, command)
  send_tuya(device, TUYA_CMD_QUERY, nil, nil, nil)
end

------------------------- Tuya cluster receive handler -------------------------

local function tuya_cluster_rx(driver, device, zb_rx)
  local body = zb_rx.body.zcl_body.body_bytes
  local dp = string.byte(body, 3)
  local len = string.unpack(">I2", body:sub(5, 6))
  local value = string.unpack(">I" .. len, body:sub(7))
  log.debug(string.format("MB60L Tuya rx: dp=%d value=%d", dp, value))

  if dp == DP_RX_CONTROL then
    -- Trailing work-state reports would flip the tile back to opening/closing,
    -- so movement is driven by handlers + DP8, and the resting state by DP9.
    log.debug("MB60L control/work-state report: " .. value)
  elseif dp == DP_RX_SET_POSITION then
    emit_movement(device, to_st_level(value))
  elseif dp == DP_RX_POSITION then
    emit_final_position(device, to_st_level(value))
  elseif dp == DP_RX_BATTERY then
    device:emit_event(capabilities.battery.battery(value))
  elseif dp == DP_RX_MOTOR_DIRECTION then
    log.info("MB60L motor_direction: " .. (value == 0 and "normal" or "reversed"))
  end
end

------------------------- lifecycle handlers -------------------------

local function device_added(driver, device)
  device:emit_event(capabilities.windowShade.supportedWindowShadeCommands(
    {"open", "close", "pause"}, {visibility = {displayed = false}}))
  device:emit_event(capabilities.windowShadePreset.position(
    device:get_field(PRESET_LEVEL_KEY) or DEFAULT_PRESET, {visibility = {displayed = false}}))
  device.thread:call_with_delay(2, function() refresh_handler(driver, device) end)
end

local function device_info_changed(driver, device, event, args)
  if args.old_st_store.preferences.reverse ~= device.preferences.reverse then
    set_dp(device, DP_ID_MOTOR_DIRECTION, DP_TYPE_ENUM,
      device.preferences.reverse and DP_VAL_REVERSE or DP_VAL_DIRECT)
  end
end

------------------------- driver template -------------------------

local mb60l_driver_template = {
  supported_capabilities = {
    capabilities.windowShade,
    capabilities.windowShadePreset,
    capabilities.windowShadeLevel,
    capabilities.battery,
    capabilities.refresh
  },
  capability_handlers = {
    [capabilities.windowShade.ID] = {
      [capabilities.windowShade.commands.open.NAME] = open_handler,
      [capabilities.windowShade.commands.close.NAME] = close_handler,
      [capabilities.windowShade.commands.pause.NAME] = pause_handler
    },
    [capabilities.windowShadeLevel.ID] = {
      [capabilities.windowShadeLevel.commands.setShadeLevel.NAME] = set_shade_level_handler
    },
    [capabilities.windowShadePreset.ID] = {
      [capabilities.windowShadePreset.commands.presetPosition.NAME] = preset_position_handler,
      [capabilities.windowShadePreset.commands.setPresetPosition.NAME] = set_preset_position_handler
    },
    [capabilities.refresh.ID] = {
      [capabilities.refresh.commands.refresh.NAME] = refresh_handler
    }
  },
  zigbee_handlers = {
    cluster = {
      [TUYA_CLUSTER] = {
        [0x01] = tuya_cluster_rx,
        [0x02] = tuya_cluster_rx
      }
    }
  },
  lifecycle_handlers = {
    added = device_added,
    infoChanged = device_info_changed
  },
  health_check = false,
}

local mb60l_driver = ZigbeeDriver("zigbee-window-treatment-mb60l", mb60l_driver_template)
mb60l_driver:run()
