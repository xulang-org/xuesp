# XuESP

Standalone ESP32 BLE HID cluster controller, MQTT command arbiter, BLE Wi-Fi/MQTT provisioning tool, HTTP transfer hub, and MCP server written in [Xu](https://xulang.org) and Swift.

XuESP owns all ESP32 hardware control and automation, separated cleanly from [XuPlay](https://github.com/xulang-org/xuplay) (which is purely responsible for AirPlay screen mirroring display).

## Build and run

```sh
make build
./xuesp -headless
```

For the macOS console with CoreBluetooth BLE provisioning (`XuPlay-Setup-*`):

```sh
make app
open xuesp.app
```

| Flag | Default | Meaning |
|---|---|---|
| `-state` | `~/.xuesp` | Directory for `devices.toml`, `macros.json`, `flows/`, `inbox/` |
| `-ctl-port` | `8765` | Loopback WebSocket control port (`0` disables) |
| `-http-port` | `-1` | HTTP transfer & `/mcp` port (`-1` uses `devices.toml`, `0` disables) |
| `-mqtt-host` | `` | Override MQTT broker host from `devices.toml` |
| `-mqtt-port` | `0` | Override MQTT broker port from `devices.toml` |
| `-headless` | off | Run without opening the macOS console window |
| `-h` | off | Show usage |

## Configuration (`~/.xuesp/devices.toml`)

```toml
[mqtt]
host = "127.0.0.1"
port = 1883
default_topic = "xu/esp32/cyd"

[esp]
http_port = 8766
auto_link = true

[[device]]
id = "office-iphone"
phone_name = "Mr.Router"
mqtt_topic = "xu/esp32/cyd"
ble_slot = 0
```

## CLI & MCP

```sh
./xuesp status
./xuesp ctl '{"op":"cluster_state"}'
./xuesp ctl '{"op":"exec","device":"office-iphone","text":"tap 16384 16384"}'
./xuesp ctl '{"op":"provision_scan"}'
./xuesp mcp
```

HTTP endpoints on `http://127.0.0.1:8766`:
- `GET /transfer`, `POST /upload` — LAN clipboard & file staging
- `POST /mcp`, `GET /mcp` — MCP JSON-RPC 2.0 endpoint (`xuesp_list_cluster`, `xuesp_bind_device`, `xuesp_exec_command`, `xuesp_list_macros`, `xuesp_run_macro`, `xuesp_save_macro`, `xuesp_provision_esp32`)
