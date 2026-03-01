#!/usr/bin/env bash
#
# Install whisper speech-to-text for the current macOS user.
# Run once from ~/Scripts/Whisper/ to wire up Hammerspoon and download a model.
#
# Usage: ./install.sh
#

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RELATIVE_PATH="${ROOT_DIR#${HOME}/}"

HAMMERSPOON_DIR="${HOME}/.hammerspoon"
HAMMERSPOON_INIT="${HAMMERSPOON_DIR}/init.lua"
MODEL_DIR="${ROOT_DIR}/models"
CONFIG_FILE="${ROOT_DIR}/whisper-stt.conf"
WHISPER_SCRIPT="${ROOT_DIR}/whisper.sh"
HOTKEYS_SCRIPT="${ROOT_DIR}/whisper_hotkeys.lua"

# Default model to download if models/ is empty
DEFAULT_MODEL_FILE="${MODEL_DIR}/ggml-large-v3-turbo.bin"
DEFAULT_MODEL_URL="https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin"

echo "==> Whisper STT install"
echo "    Root: ${ROOT_DIR}"
echo

# ── Dependency checks ────────────────────────────────────────────────────────

if ! command -v ffmpeg >/dev/null 2>&1; then
    echo "ERROR: ffmpeg not found. Install with: brew install ffmpeg"
    exit 1
fi

if ! command -v whisper-cli >/dev/null 2>&1; then
    echo "ERROR: whisper-cli not found. Install with: brew install whisper-cpp"
    exit 1
fi

if [ ! -d "/Applications/Hammerspoon.app" ]; then
    echo "WARN:  Hammerspoon not found at /Applications/Hammerspoon.app"
    echo "       Download from https://www.hammerspoon.org"
fi

echo "    ffmpeg:      $(command -v ffmpeg)"
echo "    whisper-cli: $(command -v whisper-cli)"
echo

# ── Permissions ──────────────────────────────────────────────────────────────

chmod +x "${WHISPER_SCRIPT}"

# ── Patch whisper_hotkeys.lua with actual whisper.sh path ────────────────────

sed -i '' "s|local whisper_script = .*|local whisper_script = home .. \"/${RELATIVE_PATH}/whisper.sh\"|" "${ROOT_DIR}/whisper_hotkeys.lua"
echo "==> Patched whisper_hotkeys.lua → ${ROOT_DIR}/whisper.sh"

# ── Models directory ─────────────────────────────────────────────────────────

mkdir -p "${MODEL_DIR}"

if [ -z "$(ls "${MODEL_DIR}"/*.bin 2>/dev/null)" ]; then
    echo "==> No models found. Downloading ggml-large-v3-turbo.bin (~800MB)..."
    curl -L --fail --output "${DEFAULT_MODEL_FILE}.part" "${DEFAULT_MODEL_URL}"
    mv "${DEFAULT_MODEL_FILE}.part" "${DEFAULT_MODEL_FILE}"
    echo "    Downloaded: ${DEFAULT_MODEL_FILE}"
else
    echo "==> Models found:"
    ls "${MODEL_DIR}"/*.bin | while read -r f; do echo "    $(basename "${f}")"; done
fi
echo

# ── Config file ──────────────────────────────────────────────────────────────

if [ ! -f "${CONFIG_FILE}" ]; then
    cat > "${CONFIG_FILE}" <<EOFCONF
# Whisper speech-to-text configuration
#
# Ctrl+Cmd+W toggles recording (start / stop + transcribe).
# Ctrl+Cmd+Q emergency stop.
#
WHISPER_AUDIO_DEVICE=default
WHISPER_LANGUAGE=auto
WHISPER_MODEL_PATH="${MODEL_DIR}/ggml-large-v3-turbo.bin"
WHISPER_AUTO_PASTE=1
WHISPER_MAX_SECONDS=7200
# Optional fixed device index: WHISPER_AUDIO_DEVICE_INDEX=1
# Optional translate to English: WHISPER_TRANSLATE=1
# Optional history size: WHISPER_HISTORY_MAX=10
EOFCONF
    echo "==> Created config: ${CONFIG_FILE}"
else
    echo "==> Config exists, skipping: ${CONFIG_FILE}"
fi
echo

# ── Hammerspoon init.lua ──────────────────────────────────────────────────────

mkdir -p "${HAMMERSPOON_DIR}"

DOFILE_LINE="dofile(os.getenv(\"HOME\") .. \"/${RELATIVE_PATH}/whisper_hotkeys.lua\")"

if [ ! -f "${HAMMERSPOON_INIT}" ]; then
    cat > "${HAMMERSPOON_INIT}" <<LUAEOF
-- Hammerspoon configuration
pcall(function()
    ${DOFILE_LINE}
end)
LUAEOF
    echo "==> Created ${HAMMERSPOON_INIT}"
else
    if grep -q "Scripts/Whisper/whisper_hotkeys.lua" "${HAMMERSPOON_INIT}"; then
        echo "==> init.lua already loads whisper_hotkeys.lua, skipping"
    else
        cat >> "${HAMMERSPOON_INIT}" <<LUAEOF

-- Whisper speech-to-text
pcall(function()
    ${DOFILE_LINE}
end)
LUAEOF
        echo "==> Updated ${HAMMERSPOON_INIT}"
    fi
fi
echo

# ── Summary ───────────────────────────────────────────────────────────────────

echo "==> Install complete."
echo
echo "Next steps:"
echo "  1) Open Hammerspoon and grant Accessibility permission."
echo "  2) Reload Hammerspoon config (menubar icon → Reload Config)."
echo "  3) Press Ctrl+Cmd+W to start recording."
echo "  4) Press Ctrl+Cmd+W again to stop + transcribe + paste."
echo "  5) Emergency stop: Ctrl+Cmd+Q."
echo
echo "Files:"
echo "  Script:  ${WHISPER_SCRIPT}"
echo "  Config:  ${CONFIG_FILE}"
echo "  Models:  ${MODEL_DIR}/"
echo "  History: ${ROOT_DIR}/history.txt"
