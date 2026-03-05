#!/usr/bin/env bash
#
# System-wide speech-to-text using whisper.cpp
# Usage: whisper.sh start|stop|toggle|list-devices|status
#

set -uo pipefail

WHISPER_VERSION="1.0.0"

# Ensure UTF-8 text handling when launched from minimal environments (e.g. Hammerspoon).
export LANG="${LANG:-en_US.UTF-8}"
export LC_CTYPE="${LC_CTYPE:-en_US.UTF-8}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/whisper-stt.conf"

# shellcheck source=/dev/null
if [ -f "${CONFIG_FILE}" ]; then
    . "${CONFIG_FILE}"
fi

ACTION="${1:-}"

WHISPER_TMPDIR="${TMPDIR:-/tmp}"
AUDIO_FILE="${WHISPER_AUDIO_FILE:-${WHISPER_TMPDIR}/whisper_recording.wav}"
TEXT_FILE="${WHISPER_TEXT_FILE:-${WHISPER_TMPDIR}/whisper_output.txt}"
PID_FILE="${WHISPER_PID_FILE:-${WHISPER_TMPDIR}/whisper_recording.pid}"
LOG_FILE="${WHISPER_FFMPEG_LOG:-${WHISPER_TMPDIR}/ffmpeg.log}"
ERROR_LOG_FILE="${WHISPER_ERROR_LOG:-${WHISPER_TMPDIR}/whisper-error.log}"

MODEL="${WHISPER_MODEL_PATH:-${SCRIPT_DIR}/models/ggml-medium.bin}"
WHISPER_LANGUAGE="${WHISPER_LANGUAGE:-auto}"
WHISPER_TRANSLATE="${WHISPER_TRANSLATE:-0}"
WHISPER_AUTO_PASTE="${WHISPER_AUTO_PASTE:-1}"
MAX_SECONDS="${WHISPER_MAX_SECONDS:-7200}"
WHISPER_HISTORY_FILE="${WHISPER_HISTORY_FILE:-${SCRIPT_DIR}/history.txt}"
TRANSCRIBING_FILE="${WHISPER_TRANSCRIBING_FILE:-${WHISPER_TMPDIR}/whisper_transcribing}"
WHISPER_HISTORY_MAX="${WHISPER_HISTORY_MAX:-10}"

WHISPER_NOTIFICATIONS="${WHISPER_NOTIFICATIONS:-1}"
WHISPER_SOUNDS="${WHISPER_SOUNDS:-1}"
WHISPER_HOTKEY_TOGGLE="${WHISPER_HOTKEY_TOGGLE:-shift,cmd,r}"

# Audio input:
# - WHISPER_AUDIO_DEVICE=default follows macOS-selected input
# - WHISPER_AUDIO_DEVICE=<n> uses AVFoundation index
WHISPER_AUDIO_DEVICE="${WHISPER_AUDIO_DEVICE:-${WHISPER_AUDIO_DEVICE_INDEX:-default}}"

find_bin() {
    local name="$1"
    local brew_path="/opt/homebrew/bin/${name}"
    local usr_local_path="/usr/local/bin/${name}"

    if [ -x "${brew_path}" ]; then
        printf '%s\n' "${brew_path}"
    elif [ -x "${usr_local_path}" ]; then
        printf '%s\n' "${usr_local_path}"
    elif command -v "${name}" >/dev/null 2>&1; then
        command -v "${name}"
    else
        printf '%s\n' ""
    fi
}

FFMPEG_BIN="$(find_bin ffmpeg)"
WHISPER_BIN="$(find_bin whisper-cli)"

notify() {
    [ "${WHISPER_NOTIFICATIONS}" = "0" ] && return 0

    local title="$1"
    local message="$2"
    local sound="${3:-}"
    local escaped

    [ "${WHISPER_SOUNDS}" = "0" ] && sound=""

    escaped="$(printf '%s' "${message}" | sed 's/\\/\\\\/g; s/"/\\"/g')"

    if [ -n "${sound}" ]; then
        osascript -e "display notification \"${escaped}\" with title \"${title}\" sound name \"${sound}\"" >/dev/null 2>&1 || true
    else
        osascript -e "display notification \"${escaped}\" with title \"${title}\"" >/dev/null 2>&1 || true
    fi
}

paste_clipboard() {
    osascript -e 'tell application "System Events" to keystroke "v" using command down' >/dev/null 2>&1 || true
}

copy_to_clipboard() {
    local source_file="$1"

    # Primary path: force UTF-8 interpretation via AppleScript read.
    if osascript -e "set the clipboard to (read POSIX file \"${source_file}\" as «class utf8»)" >/dev/null 2>&1; then
        return 0
    fi

    # Fallback path in case AppleScript clipboard write fails.
    pbcopy < "${source_file}" 2>/dev/null
}

append_to_history() {
    local text="$1"
    local timestamp
    timestamp="$(date '+%Y-%m-%d %H:%M:%S')"

    mkdir -p "$(dirname "${WHISPER_HISTORY_FILE}")"
    printf '[%s] %s\n' "${timestamp}" "${text}" >> "${WHISPER_HISTORY_FILE}"

    # Rolling GC: keep only the last N entries
    local tmp
    tmp="$(tail -n "${WHISPER_HISTORY_MAX}" "${WHISPER_HISTORY_FILE}")"
    printf '%s\n' "${tmp}" > "${WHISPER_HISTORY_FILE}"
}

trim_text_file() {
    if [ -f "${TEXT_FILE}" ]; then
        sed -i '' 's/^[[:space:]]*//;s/[[:space:]]*$//' "${TEXT_FILE}" 2>/dev/null || true
    fi
}

cleanup_stale_pid_file() {
    [ ! -f "${PID_FILE}" ] && return 0

    local pid
    pid="$(cat "${PID_FILE}" 2>/dev/null || true)"
    if [ -z "${pid}" ] || ! kill -0 "${pid}" 2>/dev/null; then
        rm -f "${PID_FILE}"
    fi
}

cleanup_stale_transcribing_file() {
    [ ! -f "${TRANSCRIBING_FILE}" ] && return 0

    local file_mtime now file_age max_age=600
    file_mtime="$(stat -f '%m' "${TRANSCRIBING_FILE}" 2>/dev/null || echo 0)"
    now="$(date +%s)"
    file_age=$(( now - file_mtime ))

    if [ "${file_age}" -gt "${max_age}" ]; then
        rm -f "${TRANSCRIBING_FILE}"
    fi
}

recording_running() {
    cleanup_stale_pid_file
    if [ ! -f "${PID_FILE}" ]; then
        return 1
    fi

    local pid
    pid="$(cat "${PID_FILE}" 2>/dev/null || true)"
    [ -n "${pid}" ] && kill -0 "${pid}" 2>/dev/null
}

resolve_audio_input() {
    printf '%s\n' "${WHISPER_AUDIO_DEVICE}"
}

language_allowed_for_model() {
    local model_basename
    model_basename="$(basename "${MODEL}")"

    if [[ "${model_basename}" == *.en.bin ]]; then
        case "${WHISPER_LANGUAGE}" in
            en|english) return 0 ;;
            *)          return 1 ;;
        esac
    fi

    return 0
}

preflight_check() {
    if [ -z "${FFMPEG_BIN}" ]; then
        notify "Whisper" "ffmpeg not found (install with Homebrew)" "Basso"
        printf 'ffmpeg not found\n' >&2
        exit 1
    fi

    if [ -z "${WHISPER_BIN}" ]; then
        notify "Whisper" "whisper-cli not found (install with Homebrew)" "Basso"
        printf 'whisper-cli not found\n' >&2
        exit 1
    fi

    if [ ! -f "${MODEL}" ]; then
        notify "Whisper" "Model missing at ${MODEL}" "Basso"
        printf 'Model missing: %s\n' "${MODEL}" >&2
        exit 1
    fi

    if ! [[ "${MAX_SECONDS}" =~ ^[0-9]+$ ]]; then
        notify "Whisper" "WHISPER_MAX_SECONDS must be a number" "Basso"
        printf 'Invalid WHISPER_MAX_SECONDS: %s\n' "${MAX_SECONDS}" >&2
        exit 1
    fi

    if ! language_allowed_for_model; then
        notify "Whisper" "Model is English-only. Use ggml-medium.bin for auto/de" "Basso"
        printf 'Model %s is English-only, but language is %s\n' "${MODEL}" "${WHISPER_LANGUAGE}" >&2
        exit 1
    fi
}

start_recording() {
    preflight_check

    if recording_running; then
        notify "Whisper" "Recording already in progress" "Basso"
        return 1
    fi

    rm -f "${AUDIO_FILE}" "${TEXT_FILE}" "${PID_FILE}"

    local audio_input
    audio_input="$(resolve_audio_input)"

    local hotkey_display
    hotkey_display="$(printf '%s' "${WHISPER_HOTKEY_TOGGLE}" | sed 's/,/+/g' | tr '[:lower:]' '[:upper:]')"

    notify "Whisper" "Recording... press ${hotkey_display} again to stop" "Blow"

    nohup "${FFMPEG_BIN}" \
        -f avfoundation \
        -i ":${audio_input}" \
        -t "${MAX_SECONDS}" \
        -ar 16000 \
        -ac 1 \
        -y "${AUDIO_FILE}" >"${LOG_FILE}" 2>&1 &

    printf '%s\n' "$!" > "${PID_FILE}"
    sleep 0.6

    if ! recording_running; then
        local reason
        reason="$(tail -n 1 "${LOG_FILE}" 2>/dev/null || true)"
        notify "Whisper" "Start failed. Check ${LOG_FILE}" "Basso"
        [ -n "${reason}" ] && printf 'ffmpeg start error: %s\n' "${reason}" >&2
        return 1
    fi
}

stop_recording() {
    preflight_check

    if ! recording_running; then
        notify "Whisper" "No recording in progress" "Basso"
        return 1
    fi

    local pid
    pid="$(cat "${PID_FILE}" 2>/dev/null || true)"

    if [ -n "${pid}" ] && kill -0 "${pid}" 2>/dev/null; then
        kill -INT "${pid}" 2>/dev/null || true
        for _ in $(seq 1 30); do
            if ! kill -0 "${pid}" 2>/dev/null; then
                break
            fi
            sleep 0.1
        done
        # Force-kill if still running to prevent orphan ffmpeg processes
        kill -0 "${pid}" 2>/dev/null && kill -9 "${pid}" 2>/dev/null || true
    fi

    rm -f "${PID_FILE}"
    touch "${TRANSCRIBING_FILE}"

    for _ in $(seq 1 15); do
        if [ -f "${AUDIO_FILE}" ] && [ -s "${AUDIO_FILE}" ]; then
            break
        fi
        sleep 0.1
    done

    if [ ! -f "${AUDIO_FILE}" ] || [ ! -s "${AUDIO_FILE}" ]; then
        rm -f "${TRANSCRIBING_FILE}"
        notify "Whisper" "No audio recorded. Check microphone settings." "Basso"
        return 1
    fi

    notify "Whisper" "Transcribing..." ""

    local -a cmd
    cmd=("${WHISPER_BIN}" -m "${MODEL}" --no-prints -l "${WHISPER_LANGUAGE}")
    if [ "${WHISPER_TRANSLATE}" = "1" ]; then
        cmd+=(-tr)
    fi
    cmd+=("${AUDIO_FILE}")
    if ! "${cmd[@]}" 2>"${ERROR_LOG_FILE}" | sed 's/^\[.*\] //' | tr '\n' ' ' | sed 's/  */ /g' > "${TEXT_FILE}"; then
        rm -f "${TRANSCRIBING_FILE}"
        local err
        err="$(tail -n 1 "${ERROR_LOG_FILE}" 2>/dev/null || true)"
        notify "Whisper" "Transcription failed. Check ${ERROR_LOG_FILE}" "Basso"
        [ -n "${err}" ] && printf 'whisper error: %s\n' "${err}" >&2
        return 1
    fi
    rm -f "${TRANSCRIBING_FILE}"

    trim_text_file

    local result preview
    result="$(cat "${TEXT_FILE}" 2>/dev/null || true)"

    if [ -n "${result}" ]; then
        append_to_history "${result}"

        if ! copy_to_clipboard "${TEXT_FILE}"; then
            notify "Whisper" "Clipboard copy failed" "Basso"
            return 1
        fi

        if [ "${WHISPER_AUTO_PASTE}" = "1" ]; then
            paste_clipboard
        fi

        if [ "${#result}" -gt 80 ]; then
            preview="${result:0:80}..."
        else
            preview="${result}"
        fi

        notify "Whisper copied" "${preview}" "Glass"
    else
        notify "Whisper" "No speech detected" "Basso"
    fi

    rm -f "${AUDIO_FILE}"
}

toggle_recording() {
    cleanup_stale_transcribing_file

    if [ -f "${TRANSCRIBING_FILE}" ]; then
        notify "Whisper" "Transcription in progress — please wait" "Basso"
        return 0
    fi

    if recording_running; then
        stop_recording
    else
        start_recording
    fi
}

status() {
    if [ -f "${TRANSCRIBING_FILE}" ]; then
        printf 'transcribing: yes\n'
    elif recording_running; then
        printf 'recording: running\n'
    else
        printf 'recording: stopped\n'
    fi

    printf 'model: %s\n' "${MODEL}"
    printf 'language: %s\n' "${WHISPER_LANGUAGE}"
    printf 'version: %s\n' "${WHISPER_VERSION}"
}

list_devices() {
    if [ -z "${FFMPEG_BIN}" ]; then
        printf 'ffmpeg not found\n' >&2
        exit 1
    fi

    "${FFMPEG_BIN}" -f avfoundation -list_devices true -i "" 2>&1 | sed -n '/AVFoundation audio devices/,+24p'
}

list_available_models() {
    local installed_models
    installed_models="$(ls "${SCRIPT_DIR}/models/"*.bin 2>/dev/null | xargs -I{} basename {} || true)"

    local all_models="ggml-large-v3-turbo.bin
ggml-large-v3.bin
ggml-medium.bin
ggml-small.bin
ggml-base.bin
ggml-tiny.bin"

    while IFS= read -r model; do
        if printf '%s\n' "${installed_models}" | grep -qx "${model}"; then
            printf 'installed:%s\n' "${model}"
        else
            printf 'available:%s\n' "${model}"
        fi
    done <<< "${all_models}"
}

download_model() {
    local model_name="${2:-}"
    if [ -z "${model_name}" ]; then
        printf 'Usage: %s download-model <model-name.bin>\n' "$0" >&2
        exit 1
    fi

    # Validate model name
    if ! printf '%s' "${model_name}" | grep -qE '^ggml-[a-z0-9.-]+\.bin$'; then
        printf 'Invalid model name: %s\n' "${model_name}" >&2
        exit 1
    fi

    local model_path="${SCRIPT_DIR}/models/${model_name}"
    if [ -f "${model_path}" ]; then
        printf 'already_exists\n'
        exit 0
    fi

    mkdir -p "${SCRIPT_DIR}/models"
    local url="https://huggingface.co/ggerganov/whisper.cpp/resolve/main/${model_name}"

    notify "Whisper" "Downloading ${model_name}..." ""
    printf 'downloading:%s\n' "${model_name}"

    if curl -L --fail --silent --show-error --output "${model_path}.part" "${url}" 2>&1; then
        mv "${model_path}.part" "${model_path}"
        printf 'done:%s\n' "${model_name}"
        notify "Whisper" "Model ${model_name} downloaded" "Glass"
    else
        rm -f "${model_path}.part"
        printf 'failed:%s\n' "${model_name}" >&2
        notify "Whisper" "Download failed for ${model_name}" "Basso"
        exit 1
    fi
}

case "${ACTION}" in
    start)
        start_recording
        ;;
    stop)
        stop_recording
        ;;
    toggle)
        toggle_recording
        ;;
    list-devices)
        list_devices
        ;;
    list-models)
        list_available_models
        ;;
    download-model)
        download_model "$@"
        ;;
    status)
        status
        ;;
    *)
        printf 'Usage: %s start|stop|toggle|list-devices|list-models|download-model|status\n' "$0" >&2
        exit 1
        ;;
esac
