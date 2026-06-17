-- Luacheck configuration for SmartThings Edge drivers.
-- The SmartThings hub Lua runtime is 5.3.
std = "lua53"

-- Driver source is intentionally readable; don't fail on long lines.
max_line_length = false

-- Capability/zigbee handlers receive a fixed signature (driver, device, command,
-- event, args, zb_rx) and frequently don't use every argument.
ignore = {
  "212", -- unused argument
  "213", -- unused loop variable
}

include_files = {
  "drivers/**/src/**/*.lua",
}
