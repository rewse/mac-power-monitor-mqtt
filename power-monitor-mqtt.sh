#!/usr/bin/env bash
#
# Publishes the power draw reported by SAP Power Monitor to an MQTT broker.

set -euo pipefail

readonly DEFAULT_CONFIG_FILE="${HOME}/.config/power-monitor-mqtt/config"
readonly CONFIG_FILE="${POWER_MONITOR_MQTT_CONFIG:-${DEFAULT_CONFIG_FILE}}"
readonly MAX_PUBLISH_ATTEMPTS=3

if [[ -f "${CONFIG_FILE}" ]]; then
    # shellcheck source=config.example
    source "${CONFIG_FILE}"
fi

# Defaults match config.example so the script runs with a partial config.
: "${MQTT_HOST:=}"
: "${MQTT_PORT:=1883}"
: "${MQTT_USERNAME:=}"
: "${MQTT_PASSWORD:=}"
: "${TOPIC_PREFIX:=power-monitor}"
: "${DEVICE_NAME:=$(hostname -s)}"
: "${INTERVAL:=60}"
: "${POWER_MONITOR_PATH:=/Applications/Power Monitor.app/Contents/MacOS/Power Monitor}"
: "${LOG_FILE:=${HOME}/Library/Logs/power-monitor-mqtt/power-monitor-mqtt.log}"
: "${LOG_MAX_SIZE:=1000000}"
: "${LOG_MAX_FILES:=4}"
: "${DEBUG_MODE:=false}"

log() {
    local level="$1"
    local message="$2"

    if [[ "${level}" == "DEBUG" && "${DEBUG_MODE}" != "true" ]]; then
        return 0
    fi
    echo "$(date -Iseconds) [${level}] ${message}" | tee -a "${LOG_FILE}" >&2
}

die() {
    log "ERROR" "$1"
    exit 1
}

rotate_log() {
    local file_size i

    [[ -f "${LOG_FILE}" ]] || return 0
    file_size="$(stat -f%z "${LOG_FILE}" 2>/dev/null || echo 0)"
    (( file_size >= LOG_MAX_SIZE )) || return 0

    for (( i = LOG_MAX_FILES - 1; i >= 1; i-- )); do
        if [[ -f "${LOG_FILE}.${i}" ]]; then
            mv "${LOG_FILE}.${i}" "${LOG_FILE}.$(( i + 1 ))"
        fi
    done
    mv "${LOG_FILE}" "${LOG_FILE}.1"
}

require_commands() {
    local cmd
    local missing=()

    for cmd in "$@"; do
        command -v "${cmd}" >/dev/null 2>&1 || missing+=("${cmd}")
    done
    if (( ${#missing[@]} > 0 )); then
        die "Missing required dependencies: ${missing[*]}. Install them with: brew install mosquitto jq"
    fi
}

require_power_monitor() {
    [[ -x "${POWER_MONITOR_PATH}" ]] \
        || die "Power Monitor app not found at ${POWER_MONITOR_PATH}"
}

require_mqtt_config() {
    [[ -n "${MQTT_HOST}" ]] || die "MQTT_HOST is not set in ${CONFIG_FILE}"
}

get_power_data() {
    local json

    if ! json="$("${POWER_MONITOR_PATH}" --noGUI --JSON 2>/dev/null)"; then
        log "ERROR" "Failed to get power data from Power Monitor"
        return 1
    fi
    log "DEBUG" "Power Monitor JSON output: ${json}"
    echo "${json}"
}

publish_mqtt() {
    local topic="$1"
    local payload="$2"
    local attempt output
    local args=(-r -t "${topic}")

    [[ -n "${MQTT_USERNAME}" ]] && args+=(-u "${MQTT_USERNAME}")
    [[ -n "${MQTT_PASSWORD}" ]] && args+=(-P "${MQTT_PASSWORD}")
    args+=(-h "${MQTT_HOST}" -p "${MQTT_PORT}" -m "${payload}")

    for (( attempt = 1; attempt <= MAX_PUBLISH_ATTEMPTS; attempt++ )); do
        log "DEBUG" "Publishing ${payload} to ${topic} (attempt ${attempt}/${MAX_PUBLISH_ATTEMPTS})"
        if output="$(mosquitto_pub "${args[@]}" 2>&1)"; then
            log "INFO" "Successfully published to ${topic}"
            return 0
        fi
        log "ERROR" "Attempt ${attempt} failed: ${output}"
        if (( attempt < MAX_PUBLISH_ATTEMPTS )); then
            local delay=$(( 2 ** (attempt - 1) ))
            log "INFO" "Retrying in ${delay} seconds..."
            sleep "${delay}"
        fi
    done

    log "ERROR" "Failed to publish to ${topic} after ${MAX_PUBLISH_ATTEMPTS} attempts"
    return 1
}

# Prints each message as a topic line followed by a single-line JSON payload.
# carbon_footprint and country_code stay strings because existing subscribers
# already parse them that way.
build_messages() {
    local json="$1"
    local timestamp
    timestamp="$(date -Iseconds)"

    jq -r \
        --arg base "${TOPIC_PREFIX}/${DEVICE_NAME}" \
        --arg ts "${timestamp}" '
        def power(v): {value: v, unit: "W", timestamp: $ts};
        $base + "/power/current", (power(.CurrentPower) | tojson),
        $base + "/power/average", (power(.AveragePower) | tojson),
        $base + "/status", ({
            measurements: .MeasurementsCount,
            country_code: (.CountryCode | tostring),
            precise_location: .PreciseLocation,
            carbon_footprint: (.CarbonFootprint | tostring),
            timestamp: $ts
        } | tojson)' <<< "${json}"
}

publish_power_data() {
    local json messages summary topic payload
    local failed=0

    rotate_log
    json="$(get_power_data)" || return 1
    if ! messages="$(build_messages "${json}")"; then
        log "ERROR" "Power Monitor returned invalid JSON"
        return 1
    fi

    while IFS= read -r topic && IFS= read -r payload; do
        publish_mqtt "${topic}" "${payload}" || failed=1
    done <<< "${messages}"

    summary="$(jq -r '"Current=\(.CurrentPower)W, Average=\(.AveragePower)W"' <<< "${json}")"
    log "INFO" "Power data processed: ${summary}"
    return "${failed}"
}

run_test() {
    local json

    rotate_log
    log "INFO" "Testing Power Monitor connection..."
    json="$(get_power_data)" || die "Power Monitor test failed"
    log "INFO" "Power Monitor test successful:"
    echo "${json}"
}

run_once() {
    log "INFO" "Running power monitor once..."
    publish_power_data || die "Failed to publish power data"
    log "INFO" "Power data published successfully"
}

run_continuous() {
    log "INFO" "Starting continuous power monitoring (interval: ${INTERVAL}s)"
    while true; do
        publish_power_data || log "ERROR" "Failed to publish power data, retrying in next interval"
        sleep "${INTERVAL}"
    done
}

show_config() {
    cat <<EOF
Current configuration:
  Config file: ${CONFIG_FILE}
  MQTT host: ${MQTT_HOST}
  MQTT port: ${MQTT_PORT}
  MQTT username: ${MQTT_USERNAME}
  Topic prefix: ${TOPIC_PREFIX}
  Device name: ${DEVICE_NAME}
  Interval: ${INTERVAL} seconds
  Power Monitor path: ${POWER_MONITOR_PATH}
  Log file: ${LOG_FILE}
  Log max size: ${LOG_MAX_SIZE} bytes
  Log max files: ${LOG_MAX_FILES}
  Debug mode: ${DEBUG_MODE}
EOF
}

show_help() {
    cat <<EOF
Usage: $0 [--test|--once|--config|--help]
  --test    Test power monitor connection and output
  --once    Run once and exit
  --config  Show current configuration
  --help    Show this help
  (no args) Run continuously

Configuration:
  Set POWER_MONITOR_MQTT_CONFIG environment variable to use custom config file
  Default config file: ${DEFAULT_CONFIG_FILE}
EOF
}

main() {
    local mode="${1:-}"

    case "${mode}" in
        --config) show_config; return ;;
        --help) show_help; return ;;
        --test | --once | "") ;;
        *)
            echo "Unknown option: ${mode}" >&2
            echo "Use --help for usage information" >&2
            exit 1
            ;;
    esac

    mkdir -p "$(dirname "${LOG_FILE}")"
    require_power_monitor
    if [[ "${mode}" == "--test" ]]; then
        run_test
        return
    fi

    require_commands mosquitto_pub jq
    require_mqtt_config
    if [[ "${mode}" == "--once" ]]; then
        run_once
    else
        run_continuous
    fi
}

main "$@"
