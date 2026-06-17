-- Copyright 2026 SmartThings, Inc.
-- Licensed under the Apache License, Version 2.0

--
-- Driver for Tuya EF00 temperature & humidity LCD sensor "ZTH08"
-- (manufacturer _TZE284_d7lpruvi, model TS0601).
--
-- The sensor reports temperature/humidity/battery over the Tuya EF00 cluster
-- datapoints, and drives its on-device CLOCK by periodically sending a Tuya
-- "MCU sync time" request (cluster 0xEF00, command 0x24). The hub must answer
-- with the current UTC + local epoch, otherwise the clock is never set. There
-- is no datapoint for the clock -- it is set exclusively via this command.
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
local TUYA_CMD_DATA_RESPONSE = 0x01
local TUYA_CMD_DATA_REPORT = 0x02
local TUYA_CMD_MCU_SYNC_TIME = 0x24
local TUYA_CMD_GW_STATUS = 0x25

local DP_TEMPERATURE = 1
local DP_HUMIDITY = 2
local DP_BATTERY = 4
local DP_TEMPERATURE_UNIT = 9

local TIME_SYNC_INTERVAL = 3600 -- seconds
local TIME_SYNC_TIMER = "_timeSyncTimer"

------------------------- low-level send helpers -------------------------

-- Send a cluster-specific command on the Tuya EF00 cluster with a raw body.
local function send_tuya_raw(device, cmd, body)
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
  local MsgBody = ZigbeeZcl.ZclMessageBody({
    zcl_header = zclh,
    zcl_body = generic_body.GenericBody(body)
  })
  device:send(Messages.ZigbeeMessageTx({address_header = addrh, body = MsgBody}))
end

local function uint32_be(v)
  v = math.floor(v)
  return string.char(
    (v >> 24) & 0xFF,
    (v >> 16) & 0xFF,
    (v >> 8) & 0xFF,
    v & 0xFF
  )
end

local function get_utc_and_local_time(device)
  local utc_time = os.time() -- SmartThings hubs run on UTC
  local tz_offset_hours = tonumber(device.preferences and device.preferences.utcOffset) or 0
  local local_time = utc_time + (tz_offset_hours * 3600)
  return utc_time, local_time
end

local function send_time_sync(device)
  local utc_time, local_time = get_utc_and_local_time(device)
  -- body: [payloadSize = 8, UINT16 little-endian][UTC epoch, 4B big-endian][local epoch, 4B big-endian]
  local body = string.char(0x08, 0x00) .. uint32_be(utc_time) .. uint32_be(local_time)
  send_tuya_raw(device, TUYA_CMD_MCU_SYNC_TIME, body)
  log.info(string.format("ZTH08 time sync sent: utc=%d local=%d (offset=%+dh)",
    utc_time, local_time, (local_time - utc_time) // 3600))
end

local function send_gateway_status(device)
  -- payloadSize = 1 (LE), payload = 1 (connected to internet)
  send_tuya_raw(device, TUYA_CMD_GW_STATUS, string.char(0x01, 0x00, 0x01))
end

------------------------- datapoint parsing -------------------------

local function tuya_dp_handler(driver, device, zb_rx)
  local body = zb_rx.body.zcl_body.body_bytes
  local dp = string.byte(body, 3)
  local len = string.unpack(">I2", body:sub(5, 6))
  local raw = string.unpack(">I" .. len, body:sub(7))
  log.debug(string.format("ZTH08 dp=%d len=%d value=%d", dp, len, raw))

  if dp == DP_TEMPERATURE then
    -- Signed value, tenths of a degree Celsius.
    local signed = raw
    if len == 4 and signed >= 0x80000000 then
      signed = signed - 0x100000000
    end
    device:emit_event(capabilities.temperatureMeasurement.temperature({
      value = signed / 10.0,
      unit = "C"
    }))
  elseif dp == DP_HUMIDITY then
    device:emit_event(capabilities.relativeHumidityMeasurement.humidity(raw))
  elseif dp == DP_BATTERY then
    device:emit_event(capabilities.battery.battery(raw))
  elseif dp == DP_TEMPERATURE_UNIT then
    log.info("ZTH08 display unit: " .. (raw == 0 and "Celsius" or "Fahrenheit"))
  end
end

------------------------- time-sync handlers -------------------------

local function time_sync_handler(driver, device, zb_rx)
  log.debug("ZTH08 received MCU time-sync request")
  send_time_sync(device)
end

local function gateway_status_handler(driver, device, zb_rx)
  log.debug("ZTH08 received gateway-status request")
  send_gateway_status(device)
end

------------------------- periodic + lifecycle -------------------------

local function schedule_time_sync(driver, device)
  local existing = device:get_field(TIME_SYNC_TIMER)
  if existing then
    device.thread:cancel_timer(existing)
  end
  local timer = device.thread:call_on_schedule(TIME_SYNC_INTERVAL, function()
    send_time_sync(device)
  end)
  device:set_field(TIME_SYNC_TIMER, timer)
end

local function device_init(driver, device)
  schedule_time_sync(driver, device)
end

local function device_added(driver, device)
  -- Push the time shortly after join; many units don't request it immediately.
  device.thread:call_with_delay(2, function()
    send_time_sync(device)
  end)
end

local function do_refresh(driver, device)
  send_time_sync(device)
end

local function device_info_changed(driver, device, event, args)
  if args.old_st_store.preferences.utcOffset ~= device.preferences.utcOffset then
    send_time_sync(device)
  end
end

------------------------- driver template -------------------------

local zth08_driver_template = {
  supported_capabilities = {
    capabilities.temperatureMeasurement,
    capabilities.relativeHumidityMeasurement,
    capabilities.battery,
    capabilities.refresh
  },
  capability_handlers = {
    [capabilities.refresh.ID] = {
      [capabilities.refresh.commands.refresh.NAME] = do_refresh
    }
  },
  zigbee_handlers = {
    cluster = {
      [TUYA_CLUSTER] = {
        [TUYA_CMD_DATA_RESPONSE] = tuya_dp_handler,
        [TUYA_CMD_DATA_REPORT] = tuya_dp_handler,
        [TUYA_CMD_MCU_SYNC_TIME] = time_sync_handler,
        [TUYA_CMD_GW_STATUS] = gateway_status_handler
      }
    }
  },
  lifecycle_handlers = {
    init = device_init,
    added = device_added,
    infoChanged = device_info_changed
  },
  health_check = false,
}

local zth08_driver = ZigbeeDriver("zigbee-tuya-th-sensor-zth08", zth08_driver_template)
zth08_driver:run()
