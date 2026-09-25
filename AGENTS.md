# Repository Rules

## Project

`power-monitor-mqtt.sh` is a Bash script for macOS that reads power draw (W) from [SAP Power Monitor](https://github.com/SAP/power-monitoring-tool-for-macos) and publishes it to an MQTT broker, mainly for Home Assistant users. It depends on `mosquitto_pub` and `jq` from Homebrew, and ships through this GitHub repository with a Makefile installer. The license is MIT.

The script runs in one of four modes: `--test` reads Power Monitor without publishing, `--once` publishes once for an external scheduler such as Keyboard Maestro, LaunchAgent, or cron, no argument loops every `INTERVAL` seconds, and `--config` prints the effective settings.

## External Contracts

The script reads `CurrentPower`, `AveragePower`, `MeasurementsCount`, `CountryCode`, `PreciseLocation`, and `CarbonFootprint` from `Power Monitor --noGUI --JSON`. SAP Power Monitor does not yet return correct values for the last three.

Home Assistant configurations subscribe to these retained topics, so changing a topic or payload field breaks existing users:

```
{TOPIC_PREFIX}/{DEVICE_NAME}/power/current  # {"value", "unit": "W", "timestamp"}
{TOPIC_PREFIX}/{DEVICE_NAME}/power/average  # {"value", "unit": "W", "timestamp"}
{TOPIC_PREFIX}/{DEVICE_NAME}/status         # {"measurements", "country_code", "precise_location", "carbon_footprint", "timestamp"}
```

## Configuration and Secrets

The script sources `~/.config/power-monitor-mqtt/config`, or the path in `POWER_MONITOR_MQTT_CONFIG`. `config.example` is the template that `make setup-config` copies there. The real config holds the MQTT password, so never commit a file named `config` and keep `config.example` limited to placeholder values. When adding a setting, update `config.example`, the defaults block and `show_config` in the script, and the Configuration section of `README.md` together.

## Logging

Logs are written to `LOG_FILE` (default `~/Library/Logs/power-monitor-mqtt/power-monitor-mqtt.log`) and echoed to stderr, with levels INFO, ERROR, and DEBUG (DEBUG only when `DEBUG_MODE=true`). `rotate_log` rotates the file by `LOG_MAX_SIZE` and `LOG_MAX_FILES`. Read logs from that file; the script does not use the macOS unified log.

## Verification

There is no automated test suite. `make test` runs `--test`, which needs SAP Power Monitor installed; `--once` additionally needs a reachable broker. Run `shellcheck power-monitor-mqtt.sh` after every change. Without Power Monitor or a broker, exercise the script with stub `Power Monitor` and `mosquitto_pub` executables on `PATH` and a config that points `POWER_MONITOR_PATH` at the stub.
