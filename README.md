# Power Monitor MQTT Publisher for macOS

A Bash script that reads the power draw (W) of a Mac from the SAP Power Monitor app and publishes it to an MQTT broker, for example to track it in Home Assistant.

It can check the Power Monitor connection without publishing, publish once for use with a scheduler, or run continuously at a fixed interval.

## Requirements

- [SAP Power Monitor](https://github.com/SAP/power-monitoring-tool-for-macos): download the latest `.pkg` from the [releases page](https://github.com/SAP/power-monitoring-tool-for-macos/releases) and install it.
- [Homebrew](https://brew.sh/), used to install `mosquitto` and `jq`.

## Installation

Clone the repository:

```bash
git clone https://github.com/rewse/mac-power-monitor-mqtt.git
cd mac-power-monitor-mqtt
```

### With make (Recommended)

Install `mosquitto` and `jq`, then install the script to `~/.local/bin` and a configuration file to `~/.config/power-monitor-mqtt/config`. An existing configuration file is left untouched.

```bash
make deps
make install
```

Edit the configuration file before running the script:

```bash
vim ~/.config/power-monitor-mqtt/config
```

Other targets:

```bash
make help         # Show help message
make test         # Run the script in test mode
make uninstall    # Remove the installed script
make clean        # Remove ~/.config/power-monitor-mqtt, including the config file
```

### Manually

```bash
brew install mosquitto jq
mkdir -p ~/.local/bin ~/.config/power-monitor-mqtt
cp power-monitor-mqtt.sh ~/.local/bin/
cp config.example ~/.config/power-monitor-mqtt/config
vim ~/.config/power-monitor-mqtt/config
```

## Configuration

The script reads `~/.config/power-monitor-mqtt/config`. Set the `POWER_MONITOR_MQTT_CONFIG` environment variable to use a different file.

| Setting | Description | Default in `config.example` |
|---|---|---|
| `MQTT_HOST` | MQTT broker hostname | `mqtt.example.com` |
| `MQTT_PORT` | MQTT broker port | `1883` |
| `MQTT_USERNAME` | MQTT username | `pub_client` |
| `MQTT_PASSWORD` | MQTT password | |
| `TOPIC_PREFIX` | Topic prefix | `power-monitor` |
| `DEVICE_NAME` | Device name used in topics | The Mac's short hostname |
| `INTERVAL` | Seconds between publishes in continuous mode | `60` |
| `POWER_MONITOR_PATH` | Path to the Power Monitor executable | `/Applications/Power Monitor.app/Contents/MacOS/Power Monitor` |
| `LOG_FILE` | Log file path | `~/Library/Logs/power-monitor-mqtt/power-monitor-mqtt.log` |
| `LOG_MAX_SIZE` | Log size in bytes that triggers rotation | `1000000` |
| `LOG_MAX_FILES` | Number of rotated log files to keep | `4` |
| `DEBUG_MODE` | Write debug messages to the log | `false` |

## Usage

```bash
power-monitor-mqtt.sh --test    # Print Power Monitor data without publishing
power-monitor-mqtt.sh --once    # Publish once and exit
power-monitor-mqtt.sh           # Publish every INTERVAL seconds until stopped
power-monitor-mqtt.sh --config  # Show the effective configuration
```

If `~/.local/bin` is not on your `PATH`, run the script by its full path. Use `--once` with a scheduler such as Keyboard Maestro, a LaunchAgent, or cron.

Logs go to `LOG_FILE` and to stderr. The log file is rotated when it reaches `LOG_MAX_SIZE`.

## MQTT Topics

The script publishes retained messages to these topics:

- `{TOPIC_PREFIX}/{DEVICE_NAME}/power/current`: current power (W)
- `{TOPIC_PREFIX}/{DEVICE_NAME}/power/average`: average power (W)
- `{TOPIC_PREFIX}/{DEVICE_NAME}/status`: status information

The `power/current` and `power/average` payloads look like this:

```json
{
  "value": 45.2,
  "unit": "W",
  "timestamp": "2024-12-16T16:30:00+09:00"
}
```

The `status` payload looks like this:

```json
{
  "measurements": 150,
  "country_code": "unknown",
  "precise_location": false,
  "carbon_footprint": "-1",
  "timestamp": "2024-12-16T16:30:00+09:00"
}
```

SAP Power Monitor does not currently return correct values for `country_code`, `precise_location`, and `carbon_footprint`.

## Running Periodically with Keyboard Maestro

To use the bundled macro, download [Execute-power-monitor-mqtt.kmmacros](Execute-power-monitor-mqtt.kmmacros), import it in Keyboard Maestro with `File > Import > Import Macros Safely...`, and adjust the interval if needed.

To create the macro yourself:

1. Create a new macro, for example "Execute power-monitor-mqtt".
2. Add the trigger "Periodically while logged in" with the interval "Repeating every 1 Minutes", or whatever interval you prefer.
3. Add an "Execute a Shell Script" action with this script:
   ```bash
   PATH=/opt/homebrew/bin:$PATH ~/.local/bin/power-monitor-mqtt.sh --once
   ```
4. Save the macro.

![Keyboard Maestro configuration](docs/keyboard-maestro.png)

Keyboard Maestro does not load your shell's `PATH`, so the script adds `/opt/homebrew/bin` to find `mosquitto_pub` and `jq`. On an Intel Mac, use `/usr/local/bin` instead.

## Home Assistant Integration

### MQTT Sensors

```yaml
mqtt:
  sensor:
    - name: "My Mac Power Current"
      state_topic: "power-monitor/my-mac/power/current"
      value_template: "{{ value_json.value }}"
      unit_of_measurement: "W"
      device_class: power
      
    - name: "My Mac Power Average"
      state_topic: "power-monitor/my-mac/power/average"
      value_template: "{{ value_json.value }}"
      unit_of_measurement: "W"
      device_class: power
```

### Measurement Accuracy

The values from the Mac's internal sensors are typically 15-25% lower than the AC power measured by an external device such as a smart plug or power meter. The power adapter loses 10-20% in AC-DC conversion, and the motherboard and components lose more in their own power conversion. The internal sensors may also miss some components and connected devices, and their values are often estimates based on component usage.

If you need closer numbers, for example to estimate electricity cost, apply a correction factor. This template sensor adds 20%:

```yaml
template:
  - sensor:
      - name: "My Mac Power Current Corrected"
        unit_of_measurement: "W"
        device_class: power
        state: "{{ (states('sensor.my_mac_power_current') | float(0) * 1.2) }}"
        
      - name: "My Mac Power Average Corrected"
        unit_of_measurement: "W"
        device_class: power
        state: "{{ (states('sensor.my_mac_power_average') | float(0) * 1.2) }}"
```

### Energy (kWh)

Use the [Integral sensor](https://www.home-assistant.io/integrations/integration/) to turn power into energy:

```yaml
sensor:
  # Using raw internal sensor values
  - platform: integration
    source: sensor.my_mac_power_current
    name: My Mac Energy Total Internal
    unit_prefix: k
    round: 6
    method: trapezoidal
    max_sub_interval:
      minutes: 5
      
  # Using corrected values for more accurate consumption
  - platform: integration
    source: sensor.my_mac_power_current_corrected
    name: My Mac Energy Total Corrected
    unit_prefix: k
    round: 6
    method: trapezoidal
    max_sub_interval:
      minutes: 5
```
