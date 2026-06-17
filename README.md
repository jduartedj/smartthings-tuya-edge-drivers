# SmartThings Tuya Edge Drivers

Custom [SmartThings Edge](https://developer.smartthings.com/docs/devices/hub-connected/get-started) drivers that make a couple of **Tuya Zigbee** devices *fully* work — features the generic, off‑the‑shelf community drivers don't deliver.

Most budget Tuya devices identify themselves with generic, ever‑changing manufacturer codes (`_TZE200_`, `_TZE204_`, `_TZE284_`, …). New "versions" of the exact same physical product appear almost weekly, and the generic drivers only half‑support them — your blind connects but never shows its position, the "set to 50 %" button does nothing, and your sensor's clock never sets.

These drivers were built by reverse‑engineering the **live Zigbee traffic** of the actual devices, decoding their real Tuya **EF00 (`0xEF00`)** datapoints, and implementing the correct behaviour in Lua.

## Drivers

| Driver | Device | Zigbee fingerprint | What it fixes |
|---|---|---|---|
| [`zigbee-window-treatment-mb60l`](drivers/zigbee-window-treatment-mb60l) | Manhot **MB60L‑ZG‑ZT‑TY** roller‑blind motor | `_TZE284_2gi1hy8s` / `TS0601` | Live position %, slider + presets (go‑to‑position), battery, reverse |
| [`zigbee-tuya-th-sensor-zth08`](drivers/zigbee-tuya-th-sensor-zth08) | **ZTH08** temperature/humidity LCD sensor | `_TZE284_d7lpruvi` / `TS0601` | Temperature, humidity, battery **+ on‑device clock time‑sync** |

## Install (no building required)

These are published to a SmartThings driver channel — just enroll your hub and install:

1. Open the enrollment link and accept it for your hub:
   **https://bestow-regional.api.smartthings.com/invite/OzMgV48kRj9G**
2. Install the driver(s) you want onto your hub.
3. Pair (or re‑pair) the device — the hub matches it to the right driver automatically by fingerprint.
   - Already paired on another driver? Open the device → **⋮ → Driver → Change driver** and pick the matching one.

## How they work (the interesting bit)

### MB60L blind — non‑standard, inverted datapoints
Unlike classic Tuya covers (which use DP2 = set, DP3 = report), this motor uses:

| DP | Meaning | Notes |
|----|---------|-------|
| 1 | control | `0` = open, `1` = stop, `2` = close |
| 8 | target position | echo of the commanded position |
| 9 | current position | **the datapoint that actually accepts the "go‑to" write** |
| 11 | motor direction | `0` = normal, `1` = reversed |
| 13 | battery | 0–100 % |

Positions are **inverted** vs. SmartThings (device `0` = fully open, `100` = fully closed), so the driver converts with `100 - value` in both directions. Trailing DP1 work‑state reports after a move are ignored so the tile doesn't flicker back to "opening/closing".

### ZTH08 sensor — Tuya time‑sync
Temperature is DP1 (÷10 °C, signed), humidity DP2, battery DP4. The on‑device **clock has no datapoint** — it is set by answering the device's Tuya time‑sync request (cluster `0xEF00`, command `0x24`) with:

```
[0x08, 0x00]  payloadSize = 8 (uint16 little‑endian)
[UTC epoch]   4 bytes, big‑endian (seconds since 1970)
[local epoch] 4 bytes, big‑endian (UTC + timezone offset)
```

The driver answers this on join, hourly, and on demand, and also replies to the `0x25` gateway‑status request. The clock offset is set with the **`utcOffset`** device preference (default `+1`).

## Build & deploy from source

Requires the [SmartThings CLI](https://github.com/SmartThingsCommunity/smartthings-cli).

```bash
# package a driver
smartthings edge:drivers:package drivers/zigbee-tuya-th-sensor-zth08

# publish to your channel and install on your hub
smartthings edge:channels:assign  <driverId> --channel <channelId>
smartthings edge:drivers:install  <driverId> --channel <channelId> --hub <hubId>
```

> Note: the `zigbee-window-treatment-mb60l` driver here is a clean, **standalone** implementation of the MB60L logic. The build published to the channel above is functionally equivalent and is integrated into a fork of the official SmartThings `zigbee-window-treatment` driver (so the same MB60L handler can coexist with other window‑treatment devices).

## Contributing

Got the same hardware under a different `_TZE2xx_` manufacturer code? Open an issue or PR adding your fingerprint — the datapoint maps above are usually shared across variants of the same physical product.

## License

[Apache License 2.0](LICENSE). The MB60L driver derives in part from the official
[SmartThingsCommunity/SmartThingsEdgeDrivers](https://github.com/SmartThingsCommunity/SmartThingsEdgeDrivers)
`zigbee-window-treatment` driver, also Apache‑2.0 licensed.
