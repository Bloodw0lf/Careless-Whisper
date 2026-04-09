#!/usr/bin/env bash
#
# System-wide speech-to-text using whisper.cpp
# Usage: whisper.sh start|stop|toggle|restart-recording|list-devices|list-models|download-model|auth|status
#

set -uo pipefail

WHISPER_VERSION="$(cat "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/VERSION" 2>/dev/null || echo '0.0.0')"

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
WHISPER_AUTO_ENTER="${WHISPER_AUTO_ENTER:-0}"
WHISPER_RESTORE_CLIPBOARD="${WHISPER_RESTORE_CLIPBOARD:-0}"
WHISPER_TRIM_SILENCE="${WHISPER_TRIM_SILENCE:-1}"
MAX_SECONDS="${WHISPER_MAX_SECONDS:-7200}"
WHISPER_HISTORY_FILE="${WHISPER_HISTORY_FILE:-${SCRIPT_DIR}/history.txt}"
TRANSCRIBING_FILE="${WHISPER_TRANSCRIBING_FILE:-${WHISPER_TMPDIR}/whisper_transcribing}"
POSTPROCESSING_FILE="${WHISPER_TMPDIR}/whisper_postprocessing"
WHISPER_HISTORY_MAX="${WHISPER_HISTORY_MAX:-10}"

SEGMENTS_DIR="${WHISPER_TMPDIR}/whisper_segments"
SEGMENT_INDEX_FILE="${WHISPER_TMPDIR}/whisper_segment_index"

WHISPER_NOTIFICATIONS="${WHISPER_NOTIFICATIONS:-1}"
WHISPER_SOUNDS="${WHISPER_SOUNDS:-1}"
WHISPER_HOTKEY_TOGGLE="${WHISPER_HOTKEY_TOGGLE:-shift,cmd,r}"

# Audio input:
# - WHISPER_AUDIO_DEVICE=default follows macOS-selected input
# - WHISPER_AUDIO_DEVICE=<n> uses AVFoundation index
WHISPER_AUDIO_DEVICE="${WHISPER_AUDIO_DEVICE:-${WHISPER_AUDIO_DEVICE_INDEX:-default}}"

# Developer option: append timing breakdown to pasted text
WHISPER_DEV_TIMINGS="${WHISPER_DEV_TIMINGS:-0}"

# Post-processing mode: off | clean | message | email | prompt | prompt-pro
WHISPER_POST_PROCESS="${WHISPER_POST_PROCESS:-off}"
# Post-processing backend: copilot | claude | local
WHISPER_PP_BACKEND="${WHISPER_PP_BACKEND:-copilot}"
# Copilot model for post-processing (via /chat/completions).
# Verified working: claude-opus-4.5, claude-opus-4.6, claude-sonnet-4.6,
#   claude-sonnet-4.5, claude-sonnet-4, claude-haiku-4.5, gpt-5.2,
#   gpt-5-mini, gpt-4.1, gpt-4o, gpt-4o-mini, gemini-3-pro-preview,
#   gemini-3-flash-preview
WHISPER_COPILOT_MODEL="${WHISPER_COPILOT_MODEL:-claude-sonnet-4.6}"
# Claude API (direct via api.anthropic.com)
WHISPER_CLAUDE_API_KEY="${WHISPER_CLAUDE_API_KEY:-}"
WHISPER_CLAUDE_MODEL="${WHISPER_CLAUDE_MODEL:-claude-haiku-4-5-20251001}"
# Local model via llama-server (llama.cpp)
WHISPER_LOCAL_MODEL="${WHISPER_LOCAL_MODEL:-}"
WHISPER_LOCAL_URL="${WHISPER_LOCAL_URL:-http://127.0.0.1:8085}"
WHISPER_LOCAL_GPU_LAYERS="${WHISPER_LOCAL_GPU_LAYERS:-99}"
WHISPER_LOCAL_CTX="${WHISPER_LOCAL_CTX:-8192}"
# PrismML llama.cpp fork for Q1_0 models (Bonsai)
WHISPER_PRISMML_LLAMA_BIN="${WHISPER_PRISMML_LLAMA_BIN:-${HOME}/.local/share/careless-whisper/prismml-llama-server}"
WHISPER_CUSTOM_VOCAB="${WHISPER_CUSTOM_VOCAB:-}"

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
WHISPER_SERVER_BIN="$(find_bin whisper-server)"

# ── Copilot API for post-processing ──────────────────────────────────────────

COPILOT_API_URL="https://api.githubcopilot.com/chat/completions"
COPILOT_CLIENT_ID="Iv1.b507a08c87ecfe98"
WHISPER_AUTH_DIR="${HOME}/.config/careless-whisper"
WHISPER_AUTH_FILE="${WHISPER_AUTH_DIR}/auth.json"
COPILOT_API_HEADERS=(
    -H "Content-Type: application/json"
    -H "Editor-Version: vscode/1.120.0"
    -H "Editor-Plugin-Version: copilot-chat/0.35.0"
    -H "Copilot-Integration-Id: vscode-chat"
)

copilot_device_flow() {
    local device_response
    device_response="$(curl -s -X POST "https://github.com/login/device/code" \
        -H "Accept: application/json" \
        -d "client_id=${COPILOT_CLIENT_ID}&scope=copilot" 2>/dev/null)"

    if [ -z "${device_response}" ]; then
        printf 'ERROR: Could not reach github.com\n' >&2
        return 1
    fi

    local device_code user_code verification_uri interval
    device_code="$(python3 -c "import json,sys; print(json.load(sys.stdin)['device_code'])" <<< "${device_response}" 2>/dev/null)"
    user_code="$(python3 -c "import json,sys; print(json.load(sys.stdin)['user_code'])" <<< "${device_response}" 2>/dev/null)"
    verification_uri="$(python3 -c "import json,sys; print(json.load(sys.stdin)['verification_uri'])" <<< "${device_response}" 2>/dev/null)"
    interval="$(python3 -c "import json,sys; print(json.load(sys.stdin).get('interval', 5))" <<< "${device_response}" 2>/dev/null)"

    if [ -z "${device_code}" ] || [ -z "${user_code}" ]; then
        printf 'ERROR: Unexpected response from GitHub\n' >&2
        return 1
    fi

    # Output code for the caller (Lua reads this)
    printf 'USER_CODE=%s\n' "${user_code}"
    printf 'VERIFICATION_URI=%s\n' "${verification_uri}"

    # Copy to clipboard
    printf '%s' "${user_code}" | pbcopy 2>/dev/null

    # Poll for token
    local max_attempts=60
    local attempt=0
    while [ "${attempt}" -lt "${max_attempts}" ]; do
        sleep "${interval}"
        attempt=$((attempt + 1))

        local token_response
        token_response="$(curl -s -X POST "https://github.com/login/oauth/access_token" \
            -H "Accept: application/json" \
            -d "client_id=${COPILOT_CLIENT_ID}&device_code=${device_code}&grant_type=urn:ietf:params:oauth:grant-type:device_code" 2>/dev/null)"

        local error access_token
        error="$(python3 -c "import json,sys; print(json.load(sys.stdin).get('error', ''))" <<< "${token_response}" 2>/dev/null)"

        if [ "${error}" = "authorization_pending" ]; then
            continue
        elif [ "${error}" = "slow_down" ]; then
            interval=$((interval + 5))
            continue
        elif [ -z "${error}" ]; then
            access_token="$(python3 -c "import json,sys; print(json.load(sys.stdin).get('access_token', ''))" <<< "${token_response}" 2>/dev/null)"
            if [ -n "${access_token}" ] && [ "${#access_token}" -gt 10 ]; then
                mkdir -p "${WHISPER_AUTH_DIR}"
                python3 -c "
import json, sys
with open(sys.argv[1], 'w') as f:
    json.dump({'access_token': sys.argv[2]}, f)
" "${WHISPER_AUTH_FILE}" "${access_token}"
                chmod 600 "${WHISPER_AUTH_FILE}"
                printf 'AUTH_OK\n'
                return 0
            fi
        else
            printf 'ERROR: %s\n' "${error}" >&2
            return 1
        fi
    done

    printf 'ERROR: Timed out\n' >&2
    return 1
}

resolve_copilot_token() {
    if [ -n "${GITHUB_COPILOT_TOKEN:-}" ]; then
        printf '%s' "${GITHUB_COPILOT_TOKEN}"
        return 0
    fi

    # Check careless-whisper auth file (from install.sh device flow)
    local auth_file="${HOME}/.config/careless-whisper/auth.json"
    if [ -f "${auth_file}" ]; then
        local token
        token="$(python3 -c "
import json, sys
data = json.load(open(sys.argv[1]))
print(data.get('access_token', ''))
" "${auth_file}" 2>/dev/null || true)"
        if [ -n "${token}" ] && [ "${#token}" -gt 10 ]; then
            printf '%s' "${token}"
            return 0
        fi
    fi

    return 1
}

# ── Post-processing prompt helpers ─────────────────────────────────────────

pp_spelling_hints() {
    cat <<'BLOCK'
Spelling hints in speech:
- The speaker sometimes spells out letters to clarify a technical term (e.g. "ISE I-S-E", "MAP, also M-A-B")
- The spelled letters ALWAYS override the preceding word. Combine the letters into the correct term: M-A-B → MAB, I-S-E → ISE
- The spoken word before the spelling may be WRONG (speech-to-text error). Always trust the spelled version.
- REMOVE the spelled-out letters and any bridging words ("also", "ist", "meaning") from the output
BLOCK
    if [ "${1:-}" = "email" ]; then
        printf '%s\n' "- The relevant word is typically within 5-10 words before the spelling"
    fi
}

pp_no_ai_punctuation() {
    cat <<'BLOCK'
- NEVER use AI-typical punctuation or phrasing: no semicolons (;), no em dashes (—), no en dashes (–), no colons for emphasis. Use commas, periods. Use normal dashes (-) only when it's connecting two words together. Write like a normal person typing, not like a language model.
BLOCK
}

pp_custom_vocab() {
    if [ -n "${WHISPER_CUSTOM_VOCAB}" ]; then
        printf '\nCustom vocabulary — use these exact spellings when these terms appear:\n%s\n' "${WHISPER_CUSTOM_VOCAB}"
    fi
}

post_process_prompt() {
    local mode="$1"
    case "${mode}" in
        clean)
            cat <<'PROMPT'
You are a transcript cleaner. Your job is to take raw speech-to-text output and clean it up.

Rules:
- Remove filler words (um, uh, äh, also, halt, quasi, sozusagen, basically, like, you know, irgendwie, eigentlich, eben, ja, naja, ne)
- Remove conversation markers that carry no content (e.g. "Okay", "Alles klar", "Genau", "So", "Ja", "Right", "Sure") — especially at sentence beginnings and endings
- Remove stutters and word-level repetitions ("ich habe ich habe" → "ich habe")
- Fix broken sentence structure from natural speech jumps
- Fix punctuation where whisper got it wrong (missing periods, misplaced commas)
- Remove incomplete sentence fragments at the very beginning or end of the transcript (caused by recording start/stop cutting mid-sentence)
- Keep the original meaning, tone, and style — do NOT rewrite or formalize
- Keep the original language (German stays German, English stays English)

Whisper hallucinations:
- whisper.cpp sometimes hallucinates phantom text from silence or noise. Remove obvious hallucinations like "Vielen Dank für's Zuschauen", "Untertitel von...", "Thank you for watching", "Bis zum nächsten Mal", or any text that clearly does not match spoken content
- Also remove repetitive looping phrases that whisper generates when audio is unclear

PROMPT
            pp_spelling_hints
            pp_custom_vocab
            cat <<'PROMPT'

- Preserve technical terms, names, and numbers using corrected spellings
- Output ONLY the cleaned text, nothing else — no explanations, no quotes
PROMPT
            ;;
        message)
            cat <<'PROMPT'
You are a business message optimizer. Take raw speech-to-text output and turn it into a clean, concise message suitable for Slack, Teams, or WebEx chat.

Rules:
- Make it clear, concise, and well-structured
- Use short paragraphs or bullet points where appropriate
- Do NOT insert empty lines (paragraph breaks) between sections. On messaging platforms, people write in compact blocks. Use a single line break at most to separate a closing question or call-to-action, but never double newlines.
- Keep the original language (German stays German, English stays English)
- Keep a professional but approachable tone
PROMPT
            pp_no_ai_punctuation
            printf '\n'
            pp_spelling_hints
            pp_custom_vocab
            cat <<'PROMPT'

- Preserve technical terms, names, and numbers using corrected spellings
- Output ONLY the message text, nothing else — no explanations, no quotes
PROMPT
            ;;
        email)
            cat <<'PROMPT'
You are a professional email writer. Take raw speech-to-text output and rewrite it as a polished professional email body.

Rules:
- Extract the INTENT and KEY INFORMATION from the rambling speech — do not just clean up the wording
- Rewrite into clear, professional prose — this should read like a well-written email, not like someone talking
- Write like a real person: warm, direct, and natural. Avoid stiff or formulaic phrasing that sounds AI-generated. Vary sentence length. Use the kind of language a competent professional would actually write.
- Add an appropriate greeting (e.g. "Hallo Frank,") based on names mentioned
- Do NOT add a sign-off, closing, or signature (no "Viele Grüße", "Best regards", etc.) — the user's email client appends a signature automatically
- Structure with short, clear paragraphs
- Keep the original language (German stays German, English stays English)
- Use a professional, polite, but not overly formal tone
PROMPT
            pp_no_ai_punctuation
            printf '\n'
            pp_spelling_hints "email"
            pp_custom_vocab
            cat <<'PROMPT'

- Preserve technical terms, product names, and numbers using the corrected spellings
- Do NOT invent a subject line — only the email body
- Output ONLY the email text, nothing else — no explanations, no quotes
PROMPT
            ;;
        prompt)
            cat <<'PROMPT'
You are a prompt reformulator. The user dictated a prompt for an AI assistant using speech-to-text. Your job is to clean up and restructure the spoken input so it works well as a prompt, while keeping the original intent fully intact.

Rules:
- Keep the user's intent, meaning, and level of detail exactly as spoken
- Restructure rambling speech into clear, direct instructions
- Fix grammar, remove filler words, and clean up speech artifacts
- Use clear, natural language — do NOT add prompt engineering patterns (no "You are a...", no "Act as...", no role definitions, no constraints the user didn't mention)
- If the user mentioned specific requirements, keep them all — do not drop or summarize away details
- Keep the original language (German stays German, English stays English)
- Do NOT add anything the user didn't say — no extra context, no assumptions, no embellishments
- You MAY use any formatting that helps AI models parse the prompt effectively (markdown headers, em dashes, bullet points, etc.) — the output is for AI consumption, not human reading

PROMPT
            pp_spelling_hints
            pp_custom_vocab
            cat <<'PROMPT'

- Output ONLY the cleaned prompt, nothing else — no explanations, no quotes, no meta-commentary
PROMPT
            ;;
        prompt-pro)
            cat <<'PROMPT'
You are an expert prompt engineer. The user dictated a rough idea or request using speech-to-text. Your job is to transform it into a well-structured, effective prompt following prompt engineering best practices.

Rules:
- Extract the core INTENT and REQUIREMENTS from the spoken input
- Rewrite into a professional, well-structured prompt that will get the best results from an LLM
- Apply prompt engineering best practices:
  - Add an appropriate role/persona ("You are a senior [relevant role] with deep expertise in [domain]...")
  - Define clear objectives and expected output format
  - Add relevant constraints (conciseness, tone, scope) that fit the request
  - Structure with clear sections if the task is complex
- Do NOT invent requirements the user didn't mention — enhance the structure and framing, not the scope
- Keep the original language (German stays German, English stays English)
- Use any formatting that helps AI models parse the prompt effectively (markdown headers, em dashes, bullet points, etc.) — the output is for AI consumption
- Match the complexity of the enhanced prompt to the complexity of the request — a simple question gets a concise enhanced prompt, not a 500-word framework

PROMPT
            pp_spelling_hints
            pp_custom_vocab
            cat <<'PROMPT'

- Output ONLY the enhanced prompt, nothing else — no explanations, no quotes, no meta-commentary
PROMPT
            ;;
        *)
            printf 'Unknown post-processing mode: %s\n' "${mode}" >&2
            return 1
            ;;
    esac
}

post_process_text() {
    local mode="${WHISPER_POST_PROCESS}"

    if [ "${mode}" = "off" ] || [ -z "${mode}" ]; then
        return 0
    fi

    local raw_text
    raw_text="$(cat "${TEXT_FILE}" 2>/dev/null || true)"
    if [ -z "${raw_text}" ]; then
        return 0
    fi

    local system_prompt
    system_prompt="$(post_process_prompt "${mode}")"

    local backend="${WHISPER_PP_BACKEND:-copilot}"
    case "${backend}" in
        copilot) pp_via_copilot  "${raw_text}" "${system_prompt}" ;;
        claude)  pp_via_claude   "${raw_text}" "${system_prompt}" ;;
        local)   pp_via_local    "${raw_text}" "${system_prompt}" ;;
        *)
            notify "Whisper" "Unknown backend: ${backend}" "Basso"
            return 1
            ;;
    esac
}

# ── Backend: GitHub Copilot API ──────────────────────────────────────────────

pp_via_copilot() {
    local raw_text="$1" system_prompt="$2"

    local token
    if ! token="$(resolve_copilot_token)"; then
        notify "Whisper" "Post-processing skipped — no Copilot token" ""
        return 0
    fi

    local payload
    payload="$(python3 -c "
import json, sys
print(json.dumps({
    'model': sys.argv[3],
    'messages': [
        {'role': 'system', 'content': sys.argv[1]},
        {'role': 'user', 'content': sys.argv[2]}
    ],
    'max_tokens': 4096,
    'temperature': 0.2
}))
" "${system_prompt}" "${raw_text}" "${WHISPER_COPILOT_MODEL}" 2>/dev/null)"

    if [ -z "${payload}" ]; then
        notify "Whisper" "Post-processing failed — payload error" "Basso"
        return 1
    fi

    local response http_code
    local max_retries=3
    local attempt=0

    while [ "${attempt}" -lt "${max_retries}" ]; do
        attempt=$((attempt + 1))

        response="$(curl -s --max-time 120 -w '\n%{http_code}' \
            -H "Authorization: Bearer ${token}" \
            "${COPILOT_API_HEADERS[@]}" \
            -d "${payload}" \
            "${COPILOT_API_URL}" 2>/dev/null)"

        http_code="$(tail -n1 <<< "${response}")"
        response="$(sed '$ d' <<< "${response}")"

        if [ "${http_code}" = "200" ] && [ -n "${response}" ]; then
            break
        fi

        if [ "${http_code}" = "401" ] || [ "${http_code}" = "403" ]; then
            rm -f "${WHISPER_AUTH_FILE}"
            notify "Whisper" "Copilot token expired (${http_code}) — sign in again via menubar" "Basso"
            return 1
        fi

        if [ "${attempt}" -lt "${max_retries}" ]; then
            sleep $((3 * attempt))
        fi
    done

    if [ -z "${response}" ]; then
        notify "Whisper" "Post-processing failed — no API response after ${max_retries} attempts" "Basso"
        return 1
    fi

    local processed
    processed="$(python3 -c "
import json, sys
data = json.loads(sys.stdin.read())
choices = data.get('choices', [])
if choices:
    print(choices[0].get('message', {}).get('content', ''))
" <<< "${response}" 2>/dev/null)"

    if [ -n "${processed}" ]; then
        printf '%s' "${processed}" > "${TEXT_FILE}"
    else
        notify "Whisper" "Post-processing failed — using raw transcript" "Basso"
    fi
}

# ── Backend: Claude API (api.anthropic.com) ──────────────────────────────────

pp_via_claude() {
    local raw_text="$1" system_prompt="$2"

    if [ -z "${WHISPER_CLAUDE_API_KEY}" ]; then
        notify "Whisper" "Post-processing skipped — no Claude API key" ""
        return 0
    fi

    local payload
    payload="$(python3 -c "
import json, sys
print(json.dumps({
    'model': sys.argv[3],
    'max_tokens': 4096,
    'system': sys.argv[1],
    'messages': [
        {'role': 'user', 'content': sys.argv[2]}
    ]
}))
" "${system_prompt}" "${raw_text}" "${WHISPER_CLAUDE_MODEL}" 2>/dev/null)"

    if [ -z "${payload}" ]; then
        notify "Whisper" "Post-processing failed — payload error" "Basso"
        return 1
    fi

    local response http_code
    local max_retries=3
    local attempt=0

    while [ "${attempt}" -lt "${max_retries}" ]; do
        attempt=$((attempt + 1))

        response="$(curl -s --max-time 120 -w '\n%{http_code}' \
            -H "x-api-key: ${WHISPER_CLAUDE_API_KEY}" \
            -H "anthropic-version: 2023-06-01" \
            -H "content-type: application/json" \
            -d "${payload}" \
            "https://api.anthropic.com/v1/messages" 2>/dev/null)"

        http_code="$(tail -n1 <<< "${response}")"
        response="$(sed '$ d' <<< "${response}")"

        if [ "${http_code}" = "200" ] && [ -n "${response}" ]; then
            break
        fi

        if [ "${http_code}" = "401" ]; then
            notify "Whisper" "Claude API key invalid" "Basso"
            return 1
        fi

        if [ "${http_code}" = "400" ]; then
            local err_msg
            err_msg="$(python3 -c "import json,sys; print(json.loads(sys.stdin.read()).get('error',{}).get('message',''))" <<< "${response}" 2>/dev/null)"
            if echo "${err_msg}" | grep -qi "credit balance"; then
                osascript -e 'display dialog "Claude API: no credits left.\nTop up at console.anthropic.com/settings/billing" with title "Whisper – Claude Error" buttons {"OK"} default button "OK" with icon caution' >/dev/null 2>&1 || true
            else
                notify "Whisper" "Claude error: ${err_msg:-bad request}" "Basso"
            fi
            return 1
        fi

        if [ "${attempt}" -lt "${max_retries}" ]; then
            sleep $((3 * attempt))
        fi
    done

    if [ -z "${response}" ]; then
        notify "Whisper" "Post-processing failed — no Claude response after ${max_retries} attempts" "Basso"
        return 1
    fi

    local processed
    processed="$(python3 -c "
import json, sys
data = json.loads(sys.stdin.read())
content = data.get('content', [])
if content:
    print(content[0].get('text', ''))
" <<< "${response}" 2>/dev/null)"

    if [ -n "${processed}" ]; then
        printf '%s' "${processed}" > "${TEXT_FILE}"
    else
        notify "Whisper" "Post-processing failed — using raw transcript" "Basso"
    fi
}

# ── Backend: Local model via llama-server (llama.cpp) ────────────────────────

LLAMA_SERVER_PID_FILE="${WHISPER_TMPDIR}/llama-server.pid"

local_server_running() {
    if [ -f "${LLAMA_SERVER_PID_FILE}" ]; then
        local pid
        pid="$(cat "${LLAMA_SERVER_PID_FILE}" 2>/dev/null)"
        if [ -n "${pid}" ] && kill -0 "${pid}" 2>/dev/null; then
            return 0
        fi
        rm -f "${LLAMA_SERVER_PID_FILE}"
    fi
    return 1
}

local_server_start() {
    if local_server_running; then
        printf 'already_running\n'
        return 0
    fi

    local model_path="${WHISPER_LOCAL_MODEL}"
    if [ -z "${model_path}" ] || [ ! -f "${model_path}" ]; then
        printf 'error: no local model configured or file not found: %s\n' "${model_path}" >&2
        return 1
    fi

    # Pick the right llama-server: PrismML fork for Q1_0 models (Bonsai), Homebrew for the rest
    local llama_bin
    local model_basename
    model_basename="$(basename "${model_path}")"
    if [[ "${model_basename}" == Bonsai-* ]]; then
        llama_bin="${WHISPER_PRISMML_LLAMA_BIN}"
        if [ ! -x "${llama_bin}" ]; then
            printf 'error: PrismML llama-server not found at %s\n' "${llama_bin}" >&2
            printf 'Bonsai Q1_0 models require the PrismML fork. Run: ./install.sh\n' >&2
            return 1
        fi
    else
        llama_bin="$(find_bin llama-server)"
        if [ -z "${llama_bin}" ]; then
            printf 'error: llama-server not found (brew install llama.cpp)\n' >&2
            return 1
        fi
    fi

    local port
    port="$(printf '%s' "${WHISPER_LOCAL_URL}" | sed -E 's|.*:([0-9]+)$|\1|')"
    port="${port:-8085}"

    # Ensure a valid working directory (llama-server calls getcwd on init)
    cd "${SCRIPT_DIR}" 2>/dev/null || cd /tmp

    "${llama_bin}" \
        -m "${model_path}" \
        -ngl "${WHISPER_LOCAL_GPU_LAYERS}" \
        -c "${WHISPER_LOCAL_CTX}" \
        -np 1 \
        --port "${port}" \
        --host 127.0.0.1 \
        > "${WHISPER_TMPDIR}/llama-server.log" 2>&1 &

    local pid=$!
    printf '%s' "${pid}" > "${LLAMA_SERVER_PID_FILE}"

    # Wait for server to become ready (up to 30s)
    local attempts=0
    while [ "${attempts}" -lt 60 ]; do
        if curl -s --max-time 1 "${WHISPER_LOCAL_URL}/health" 2>/dev/null | grep -q 'ok'; then
            printf 'started:%s\n' "${pid}"
            return 0
        fi
        sleep 0.5
        attempts=$((attempts + 1))
        # Check if process died
        if ! kill -0 "${pid}" 2>/dev/null; then
            rm -f "${LLAMA_SERVER_PID_FILE}"
            printf 'error: llama-server exited unexpectedly\n' >&2
            return 1
        fi
    done

    # Timeout but process still alive — keep it
    printf 'started:%s\n' "${pid}"
}

local_server_stop() {
    if [ -f "${LLAMA_SERVER_PID_FILE}" ]; then
        local pid
        pid="$(cat "${LLAMA_SERVER_PID_FILE}" 2>/dev/null)"
        if [ -n "${pid}" ] && kill -0 "${pid}" 2>/dev/null; then
            kill "${pid}" 2>/dev/null
            wait "${pid}" 2>/dev/null || true
        fi
        rm -f "${LLAMA_SERVER_PID_FILE}"
    fi
    printf 'stopped\n'
}

local_server_status() {
    if local_server_running; then
        local pid
        pid="$(cat "${LLAMA_SERVER_PID_FILE}" 2>/dev/null)"
        printf 'running:%s\n' "${pid}"

        # Check health endpoint for loaded model info
        local health
        health="$(curl -s --max-time 2 "${WHISPER_LOCAL_URL}/health" 2>/dev/null || true)"
        if printf '%s' "${health}" | grep -q 'ok'; then
            printf 'healthy:yes\n'
        else
            printf 'healthy:no\n'
        fi
    else
        printf 'stopped\n'
    fi
    printf 'model:%s\n' "${WHISPER_LOCAL_MODEL:-none}"
    printf 'url:%s\n' "${WHISPER_LOCAL_URL}"
}

# ── Whisper server for pre-warmed transcription ──────────────────────────────

WHISPER_SERVER_PID_FILE="${WHISPER_TMPDIR}/whisper-server.pid"
WHISPER_SERVER_PORT="8083"
WHISPER_SERVER_URL="http://127.0.0.1:${WHISPER_SERVER_PORT}"

whisper_server_running() {
    if [ -f "${WHISPER_SERVER_PID_FILE}" ]; then
        local pid
        pid="$(cat "${WHISPER_SERVER_PID_FILE}" 2>/dev/null)"
        if [ -n "${pid}" ] && kill -0 "${pid}" 2>/dev/null; then
            return 0
        fi
        rm -f "${WHISPER_SERVER_PID_FILE}"
    fi
    return 1
}

whisper_server_start() {
    if whisper_server_running; then
        return 0
    fi

    if [ -z "${WHISPER_SERVER_BIN}" ]; then
        return 1
    fi

    if [ ! -f "${MODEL}" ]; then
        return 1
    fi

    local -a server_args=(
        --host 127.0.0.1
        --port "${WHISPER_SERVER_PORT}"
        -m "${MODEL}"
        -l "${WHISPER_LANGUAGE}"
        --flash-attn
    )
    if [ "${WHISPER_TRANSLATE}" = "1" ]; then
        server_args+=(--translate)
    fi

    cd "${SCRIPT_DIR}" 2>/dev/null || cd /tmp

    "${WHISPER_SERVER_BIN}" "${server_args[@]}" \
        > "${WHISPER_TMPDIR}/whisper-server.log" 2>&1 &

    local pid=$!
    printf '%s' "${pid}" > "${WHISPER_SERVER_PID_FILE}"

    # Wait for server to become ready (up to 30s)
    local attempts=0
    while [ "${attempts}" -lt 60 ]; do
        if curl -s --max-time 1 "${WHISPER_SERVER_URL}/health" 2>/dev/null | grep -q '"ok"'; then
            return 0
        fi
        sleep 0.5
        attempts=$((attempts + 1))
        if ! kill -0 "${pid}" 2>/dev/null; then
            rm -f "${WHISPER_SERVER_PID_FILE}"
            return 1
        fi
    done

    # Timeout but process still alive — usable
    return 0
}

whisper_server_stop() {
    if [ -f "${WHISPER_SERVER_PID_FILE}" ]; then
        local pid
        pid="$(cat "${WHISPER_SERVER_PID_FILE}" 2>/dev/null)"
        if [ -n "${pid}" ] && kill -0 "${pid}" 2>/dev/null; then
            kill "${pid}" 2>/dev/null
            wait "${pid}" 2>/dev/null || true
        fi
        rm -f "${WHISPER_SERVER_PID_FILE}"
    fi
}

# Transcribe audio via whisper-server HTTP API.
# Returns 0 on success (result written to TEXT_FILE), 1 on failure.
whisper_server_transcribe() {
    # Wait for server to be healthy (may still be loading after short recording)
    local attempts=0
    while [ "${attempts}" -lt 60 ]; do
        if curl -s --max-time 1 "${WHISPER_SERVER_URL}/health" 2>/dev/null | grep -q '"ok"'; then
            break
        fi
        sleep 0.5
        attempts=$((attempts + 1))
    done

    if [ "${attempts}" -ge 60 ]; then
        return 1
    fi

    local -a curl_args=(
        -s --max-time 300
        -F "file=@${AUDIO_FILE}"
        -F "response_format=text"
        -F "language=${WHISPER_LANGUAGE}"
    )
    if [ "${WHISPER_TRANSLATE}" = "1" ]; then
        curl_args+=(-F "translate=true")
    fi
    if [ -n "${WHISPER_CUSTOM_VOCAB}" ]; then
        curl_args+=(-F "prompt=${WHISPER_CUSTOM_VOCAB}")
    fi

    local response http_code
    response="$(curl -w '\n%{http_code}' "${curl_args[@]}" \
        "${WHISPER_SERVER_URL}/inference" 2>/dev/null)"

    http_code="$(tail -n1 <<< "${response}")"
    response="$(sed '$ d' <<< "${response}")"

    if [ "${http_code}" = "200" ] && [ -n "${response}" ]; then
        # Collapse newlines and multiple spaces into continuous text (same as whisper-cli path)
        printf '%s' "${response}" | tr '\n' ' ' | sed 's/  */ /g' > "${TEXT_FILE}"
        return 0
    fi

    return 1
}

# ── Local LLM model management (GGUFs from Hugging Face) ────────────────────

LOCAL_MODELS_DIR="${SCRIPT_DIR}/models"

# Catalog: id|filename|size_label|huggingface_url
LOCAL_MODEL_CATALOG="Bonsai-8B|Bonsai-8B.gguf|~1.2 GB · 1-bit experimental|https://huggingface.co/prism-ml/Bonsai-8B-gguf/resolve/main/Bonsai-8B.gguf
Llama-3.2-3B|Llama-3.2-3B-Instruct-Q4_K_M.gguf|~1.9 GB|https://huggingface.co/bartowski/Llama-3.2-3B-Instruct-GGUF/resolve/main/Llama-3.2-3B-Instruct-Q4_K_M.gguf
Qwen2.5-7B|Qwen2.5-7B-Instruct-Q4_K_M.gguf|~4.5 GB|https://huggingface.co/bartowski/Qwen2.5-7B-Instruct-GGUF/resolve/main/Qwen2.5-7B-Instruct-Q4_K_M.gguf
Qwen2.5-14B|Qwen2.5-14B-Instruct-Q4_K_M.gguf|~9 GB|https://huggingface.co/bartowski/Qwen2.5-14B-Instruct-GGUF/resolve/main/Qwen2.5-14B-Instruct-Q4_K_M.gguf"

list_local_models() {
    while IFS='|' read -r id filename size_label _url; do
        local model_path="${LOCAL_MODELS_DIR}/${filename}"
        if [ -f "${model_path}" ]; then
            printf 'installed:%s|%s|%s\n' "${id}" "${filename}" "${size_label}"
        else
            printf 'available:%s|%s|%s\n' "${id}" "${filename}" "${size_label}"
        fi
    done <<< "${LOCAL_MODEL_CATALOG}"
}

download_local_model() {
    local model_id="${2:-}"
    if [ -z "${model_id}" ]; then
        printf 'Usage: %s download-local-model <model-id>\n' "$0" >&2
        printf 'Available: Bonsai-8B, Llama-3.2-3B, Qwen2.5-7B, Qwen2.5-14B\n' >&2
        exit 1
    fi

    # Look up model in catalog
    local filename="" url=""
    while IFS='|' read -r id fname _size hf_url; do
        if [ "${id}" = "${model_id}" ]; then
            filename="${fname}"
            url="${hf_url}"
            break
        fi
    done <<< "${LOCAL_MODEL_CATALOG}"

    if [ -z "${filename}" ]; then
        printf 'error:unknown model %s\n' "${model_id}" >&2
        exit 1
    fi

    local model_path="${LOCAL_MODELS_DIR}/${filename}"
    if [ -f "${model_path}" ]; then
        printf 'already_exists\n'
    else
        mkdir -p "${LOCAL_MODELS_DIR}"
        notify "Whisper" "Downloading ${model_id}..." ""
        printf 'downloading:%s\n' "${filename}"

        if curl -L --fail --silent --show-error --output "${model_path}.part" "${url}" 2>&1; then
            mv "${model_path}.part" "${model_path}"
            printf 'done:%s\n' "${filename}"
            notify "Whisper" "Model ${model_id} downloaded" "Glass"
        else
            rm -f "${model_path}.part"
            printf 'failed:%s\n' "${filename}" >&2
            notify "Whisper" "Download failed for ${model_id}" "Basso"
            exit 1
        fi
    fi

    # Build PrismML llama.cpp fork for Q1_0 models if needed
    if [ "${model_id}" = "Bonsai-8B" ] && [ ! -x "${WHISPER_PRISMML_LLAMA_BIN}" ]; then
        # cmake is required to build the PrismML fork
        if ! command -v cmake >/dev/null 2>&1; then
            notify "Whisper" "Installing cmake via Homebrew..." ""
            printf 'installing_cmake\n'
            brew install cmake >/dev/null 2>&1
        fi
        notify "Whisper" "Building PrismML llama-server for Bonsai Q1_0..." ""
        printf 'building_prismml\n'
        local build_dir
        build_dir="$(mktemp -d)"
        if (
            set -e
            cd "${build_dir}"
            git clone --depth 1 https://github.com/PrismML-Eng/llama.cpp prismml-llama
            cd prismml-llama
            cmake -B build && cmake --build build -j
            local dest_dir
            dest_dir="$(dirname "${WHISPER_PRISMML_LLAMA_BIN}")"
            mkdir -p "${dest_dir}"
            cp build/bin/llama-server "${WHISPER_PRISMML_LLAMA_BIN}"
            # Copy shared libraries that the binary needs at runtime
            find build/bin build/src build/ggml/src -name '*.dylib' -exec cp {} "${dest_dir}/" \; 2>/dev/null || true
            # Fix rpath so the binary finds libs next to itself
            install_name_tool -add_rpath @executable_path "${WHISPER_PRISMML_LLAMA_BIN}" 2>/dev/null || true
        ) >/dev/null 2>&1; then
            notify "Whisper" "PrismML llama-server built" "Glass"
            printf 'prismml_done\n'
        else
            notify "Whisper" "PrismML build failed — Bonsai won't work" "Basso"
            printf 'prismml_failed\n'
        fi
        rm -rf "${build_dir}"
    fi
}

pp_via_local() {
    local raw_text="$1" system_prompt="$2"

    # Auto-start llama-server if not running
    if ! curl -s --max-time 2 "${WHISPER_LOCAL_URL}/health" 2>/dev/null | grep -q 'ok'; then
        local_server_start >/dev/null 2>&1
        if ! curl -s --max-time 2 "${WHISPER_LOCAL_URL}/health" 2>/dev/null | grep -q 'ok'; then
            notify "Whisper" "Post-processing skipped — llama-server failed to start" "Basso"
            return 0
        fi
    fi

    local user_content="${raw_text}"

    local payload
    payload="$(python3 -c "
import json, sys
print(json.dumps({
    'messages': [
        {'role': 'system', 'content': sys.argv[1]},
        {'role': 'user', 'content': sys.argv[2]}
    ],
    'max_tokens': 4096,
    'temperature': 0.2
}))
" "${system_prompt}" "${user_content}" 2>/dev/null)"

    if [ -z "${payload}" ]; then
        notify "Whisper" "Post-processing failed — payload error" "Basso"
        return 1
    fi

    local response http_code
    response="$(curl -s --max-time 120 -w '\n%{http_code}' \
        -H "Content-Type: application/json" \
        -d "${payload}" \
        "${WHISPER_LOCAL_URL}/v1/chat/completions" 2>/dev/null)"

    http_code="$(tail -n1 <<< "${response}")"
    response="$(sed '$ d' <<< "${response}")"

    if [ "${http_code}" != "200" ] || [ -z "${response}" ]; then
        notify "Whisper" "Local model failed (HTTP ${http_code})" "Basso"
        return 1
    fi

    # OpenAI-compatible response: choices[0].message.content
    local processed
    processed="$(python3 -c "
import json, sys
data = json.loads(sys.stdin.read())
choices = data.get('choices', [])
if choices:
    text = choices[0].get('message', {}).get('content', '')
    # Strip any thinking tags that might slip through
    import re
    text = re.sub(r'<think>.*?</think>', '', text, flags=re.DOTALL).strip()
    print(text)
" <<< "${response}" 2>/dev/null)"

    if [ -n "${processed}" ]; then
        printf '%s' "${processed}" > "${TEXT_FILE}"
    else
        notify "Whisper" "Post-processing failed — using raw transcript" "Basso"
    fi

    # Shutdown server after use to free GPU RAM
    local_server_stop >/dev/null 2>&1
}

# ── DEV: Benchmark all installed local models ────────────────────────────────

benchmark_local_models() {
    local raw_text="$1" system_prompt="$2"

    # Collect installed model paths
    local -a model_ids=() model_files=()
    while IFS='|' read -r id filename _size _url; do
        local model_path="${LOCAL_MODELS_DIR}/${filename}"
        if [ -f "${model_path}" ]; then
            model_ids+=("${id}")
            model_files+=("${model_path}")
        fi
    done <<< "${LOCAL_MODEL_CATALOG}"

    if [ "${#model_ids[@]}" -eq 0 ]; then
        notify "Whisper" "Benchmark: no local models installed" "Basso"
        return 1
    fi

    # Build JSON payload once (same input for all models)
    local payload
    payload="$(python3 -c "
import json, sys
print(json.dumps({
    'messages': [
        {'role': 'system', 'content': sys.argv[1]},
        {'role': 'user', 'content': sys.argv[2]}
    ],
    'max_tokens': 4096,
    'temperature': 0.2
}))
" "${system_prompt}" "${raw_text}" 2>/dev/null)"

    if [ -z "${payload}" ]; then
        notify "Whisper" "Benchmark: payload error" "Basso"
        return 1
    fi

    local saved_model="${WHISPER_LOCAL_MODEL}"
    local output=""

    for i in "${!model_ids[@]}"; do
        local mid="${model_ids[$i]}"
        local mfile="${model_files[$i]}"

        notify "Whisper" "Benchmark: ${mid} ($(( i + 1 ))/${#model_ids[@]})..." ""

        # Stop any running server
        local_server_stop >/dev/null 2>&1
        sleep 0.5

        # Start server with this model
        WHISPER_LOCAL_MODEL="${mfile}"
        local ts_start ts_end

        local_server_start >/dev/null 2>&1
        if ! curl -s --max-time 2 "${WHISPER_LOCAL_URL}/health" 2>/dev/null | grep -q 'ok'; then
            output="${output}\n\n── ${mid} (FAILED: server start) ──\n[Server konnte nicht gestartet werden]"
            continue
        fi

        # Timer starts AFTER server is healthy — measures inference only
        ts_start="$(python3 -c 'import time; print(time.time())' 2>/dev/null)"

        # Send request
        local response http_code
        response="$(curl -s --max-time 120 -w '\n%{http_code}' \
            -H "Content-Type: application/json" \
            -d "${payload}" \
            "${WHISPER_LOCAL_URL}/v1/chat/completions" 2>/dev/null)"

        ts_end="$(python3 -c 'import time; print(time.time())' 2>/dev/null)"

        http_code="$(tail -n1 <<< "${response}")"
        response="$(sed '$ d' <<< "${response}")"

        # Stop server immediately
        local_server_stop >/dev/null 2>&1

        if [ "${http_code}" != "200" ] || [ -z "${response}" ]; then
            output="${output}\n\n── ${mid} (FAILED: HTTP ${http_code}) ──\n[Keine Antwort]"
            continue
        fi

        local processed
        processed="$(python3 -c "
import json, sys, re
data = json.loads(sys.stdin.read())
choices = data.get('choices', [])
if choices:
    msg = choices[0].get('message', {})
    text = msg.get('content', '') or ''
    # Strip thinking tags
    cleaned = re.sub(r'<think>.*?</think>', '', text, flags=re.DOTALL).strip()
    if cleaned:
        print(cleaned)
    elif text.strip():
        print(text.strip())
    else:
        # Reasoning models: content in reasoning_content field
        rc = msg.get('reasoning_content', '') or ''
        # Extract actual answer after reasoning (last paragraph)
        parts = rc.strip().split('\n\n')
        # Try to find a clean result line
        for p in reversed(parts):
            p = p.strip()
            if p and not p.startswith('*') and not p.startswith('#') and len(p) > 10:
                print('[reasoning] ' + p)
                break
        else:
            print('[reasoning model - no usable output]')
" <<< "${response}" 2>/dev/null)"

        local duration
        duration="$(python3 -c "print(f'{${ts_end}-${ts_start}:.1f}')" 2>/dev/null)"

        output="${output}\n\n── ${mid} (${duration}s) ──\n${processed}"
    done

    # Restore original model
    WHISPER_LOCAL_MODEL="${saved_model}"

    # Write all results to text file
    printf '%b' "${output}" > "${TEXT_FILE}"
}

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

current_segment_file() {
    local idx
    idx="$(cat "${SEGMENT_INDEX_FILE}" 2>/dev/null || echo 1)"
    printf '%s/segment_%03d.wav\n' "${SEGMENTS_DIR}" "${idx}"
}

next_segment_index() {
    local idx
    idx="$(cat "${SEGMENT_INDEX_FILE}" 2>/dev/null || echo 1)"
    printf '%s\n' "$(( idx + 1 ))" > "${SEGMENT_INDEX_FILE}"
}

# ── Trim leading/trailing silence to reduce Whisper hallucinations ─────────

trim_silence() {
    if [ "${WHISPER_TRIM_SILENCE}" != "1" ]; then
        return 0
    fi
    local input="${AUDIO_FILE}"
    local trimmed="${WHISPER_TMPDIR}/whisper_trimmed.wav"
    if "${FFMPEG_BIN}" -y -i "${input}" -af \
        "silenceremove=start_periods=1:start_silence=0.5:start_threshold=-40dB,areverse,silenceremove=start_periods=1:start_silence=0.5:start_threshold=-40dB,areverse" \
        "${trimmed}" >/dev/null 2>&1 && [ -s "${trimmed}" ]; then
        mv "${trimmed}" "${input}"
    else
        rm -f "${trimmed}"
    fi
}

concat_segments() {
    local -a valid_segments=()
    for seg in "${SEGMENTS_DIR}"/segment_*.wav; do
        [ -f "${seg}" ] && [ -s "${seg}" ] && valid_segments+=("${seg}")
    done

    if [ "${#valid_segments[@]}" -eq 0 ]; then
        return 1
    elif [ "${#valid_segments[@]}" -eq 1 ]; then
        mv "${valid_segments[0]}" "${AUDIO_FILE}"
    else
        local concat_list="${WHISPER_TMPDIR}/whisper_concat.txt"
        rm -f "${concat_list}"
        for seg in "${valid_segments[@]}"; do
            printf "file '%s'\n" "${seg}" >> "${concat_list}"
        done
        if ! "${FFMPEG_BIN}" -f concat -safe 0 -i "${concat_list}" -c copy -y "${AUDIO_FILE}" >/dev/null 2>&1; then
            rm -f "${concat_list}"
            return 1
        fi
        rm -f "${concat_list}"
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
    rm -rf "${SEGMENTS_DIR}" "${SEGMENT_INDEX_FILE}"
    mkdir -p "${SEGMENTS_DIR}"
    printf '1\n' > "${SEGMENT_INDEX_FILE}"

    local segment_file
    segment_file="$(current_segment_file)"
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
        -y "${segment_file}" >"${LOG_FILE}" 2>&1 &

    printf '%s\n' "$!" > "${PID_FILE}"
    sleep 0.6

    if ! recording_running; then
        local reason
        reason="$(tail -n 1 "${LOG_FILE}" 2>/dev/null || true)"
        notify "Whisper" "Start failed. Check ${LOG_FILE}" "Basso"
        [ -n "${reason}" ] && printf 'ffmpeg start error: %s\n' "${reason}" >&2
        return 1
    fi

    # Pre-warm whisper model: start the server in the background so the model
    # is loaded by the time the user stops recording.
    whisper_server_start >/dev/null 2>&1 &
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

    sleep 0.3

    if ! concat_segments; then
        rm -f "${TRANSCRIBING_FILE}"
        rm -rf "${SEGMENTS_DIR}" "${SEGMENT_INDEX_FILE}"
        whisper_server_stop >/dev/null 2>&1
        notify "Whisper" "No audio recorded. Check microphone settings." "Basso"
        return 1
    fi

    if [ ! -f "${AUDIO_FILE}" ] || [ ! -s "${AUDIO_FILE}" ]; then
        rm -f "${TRANSCRIBING_FILE}"
        rm -rf "${SEGMENTS_DIR}" "${SEGMENT_INDEX_FILE}"
        whisper_server_stop >/dev/null 2>&1
        notify "Whisper" "No audio recorded. Check microphone settings." "Basso"
        return 1
    fi

    trim_silence

    notify "Whisper" "Transcribing..." ""

    local _ts_transcribe_start
    _ts_transcribe_start="$(python3 -c 'import time; print(time.time())' 2>/dev/null)"

    # Try pre-warmed whisper-server first, fall back to whisper-cli
    if whisper_server_running && whisper_server_transcribe; then
        whisper_server_stop >/dev/null 2>&1
    else
        whisper_server_stop >/dev/null 2>&1
        local -a cmd
        cmd=("${WHISPER_BIN}" -m "${MODEL}" --no-prints -l "${WHISPER_LANGUAGE}")
        if [ "${WHISPER_TRANSLATE}" = "1" ]; then
            cmd+=(-tr)
        fi
        if [ -n "${WHISPER_CUSTOM_VOCAB}" ]; then
            cmd+=(--prompt "${WHISPER_CUSTOM_VOCAB}")
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
    fi
    rm -f "${TRANSCRIBING_FILE}"

    local _ts_transcribe_end
    _ts_transcribe_end="$(python3 -c 'import time; print(time.time())' 2>/dev/null)"

    trim_text_file

    local _ts_pp_start="" _ts_pp_end=""
    local _did_benchmark=0
    # Post-process via Copilot API if enabled
    if [ "${WHISPER_POST_PROCESS}" != "off" ] && [ -n "${WHISPER_POST_PROCESS}" ]; then
        touch "${POSTPROCESSING_FILE}"

        # DEV benchmark mode: run through all installed local models
        if [ "${WHISPER_DEV_TIMINGS}" = "1" ] && [ "${WHISPER_PP_BACKEND}" = "local" ]; then
            local raw_text system_prompt
            raw_text="$(cat "${TEXT_FILE}" 2>/dev/null || true)"
            system_prompt="$(post_process_prompt "${WHISPER_POST_PROCESS}")"
            notify "Whisper" "Benchmark: running all local models..." ""
            _ts_pp_start="$(python3 -c 'import time; print(time.time())' 2>/dev/null)"
            benchmark_local_models "${raw_text}" "${system_prompt}"
            _ts_pp_end="$(python3 -c 'import time; print(time.time())' 2>/dev/null)"
            _did_benchmark=1
        else
            notify "Whisper" "Post-processing (${WHISPER_POST_PROCESS})..." ""
            _ts_pp_start="$(python3 -c 'import time; print(time.time())' 2>/dev/null)"
            post_process_text
            _ts_pp_end="$(python3 -c 'import time; print(time.time())' 2>/dev/null)"
        fi

        rm -f "${POSTPROCESSING_FILE}"
    fi

    # Append timing breakdown if dev mode enabled
    if [ "${WHISPER_DEV_TIMINGS}" = "1" ]; then
        local _t_transcribe _t_pp _timing_line
        _t_transcribe="$(python3 -c "print(f'{${_ts_transcribe_end}-${_ts_transcribe_start}:.1f}')" 2>/dev/null)"
        if [ "${_did_benchmark}" = "1" ]; then
            # Benchmark already appended its own results; just prepend STT time
            _timing_line="\n[DEV] Transcription: ${_t_transcribe}s"
        else
            _timing_line="\n\n[DEV] Transcription: ${_t_transcribe}s"
            if [ -n "${_ts_pp_start}" ] && [ -n "${_ts_pp_end}" ]; then
                _t_pp="$(python3 -c "print(f'{${_ts_pp_end}-${_ts_pp_start}:.1f}')" 2>/dev/null)"
                _timing_line="${_timing_line} | Post-processing: ${_t_pp}s"
            fi
        fi
        printf '%s' "${_timing_line}" >> "${TEXT_FILE}"
    fi

    local result preview
    result="$(cat "${TEXT_FILE}" 2>/dev/null || true)"

    if [ -n "${result}" ]; then
        append_to_history "${result}"

        # Save current clipboard so we can restore it after pasting
        local saved_clipboard=""
        if [ "${WHISPER_RESTORE_CLIPBOARD}" = "1" ]; then
            saved_clipboard="$(pbpaste 2>/dev/null || true)"
        fi

        if ! copy_to_clipboard "${TEXT_FILE}"; then
            notify "Whisper" "Clipboard copy failed" "Basso"
            return 1
        fi

        if [ "${WHISPER_AUTO_PASTE}" = "1" ]; then
            paste_clipboard
            if [ "${WHISPER_AUTO_ENTER}" = "1" ]; then
                osascript -e 'tell application "System Events" to key code 36' >/dev/null 2>&1 || true
            fi
        fi

        # Restore previous clipboard content
        if [ "${WHISPER_RESTORE_CLIPBOARD}" = "1" ] && [ -n "${saved_clipboard}" ]; then
            printf '%s' "${saved_clipboard}" | pbcopy 2>/dev/null
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
    rm -rf "${SEGMENTS_DIR}" "${SEGMENT_INDEX_FILE}"
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

restart_recording() {
    if ! recording_running; then
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
        kill -0 "${pid}" 2>/dev/null && kill -9 "${pid}" 2>/dev/null || true
    fi
    rm -f "${PID_FILE}"

    sleep 0.3

    next_segment_index
    local segment_file
    segment_file="$(current_segment_file)"
    local audio_input
    audio_input="$(resolve_audio_input)"

    nohup "${FFMPEG_BIN}" \
        -f avfoundation \
        -i ":${audio_input}" \
        -t "${MAX_SECONDS}" \
        -ar 16000 \
        -ac 1 \
        -y "${segment_file}" >"${LOG_FILE}" 2>&1 &

    printf '%s\n' "$!" > "${PID_FILE}"
    sleep 0.6

    if ! recording_running; then
        notify "Whisper" "Device changed but new input failed" "Basso"
        return 1
    fi

    notify "Whisper" "Audio input changed — recording continues" ""
}

status() {
    if [ -f "${POSTPROCESSING_FILE}" ]; then
        printf 'postprocessing: yes\n'
    elif [ -f "${TRANSCRIBING_FILE}" ]; then
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

check_update() {
    local version_file="${SCRIPT_DIR}/VERSION"
    local local_version
    local_version="$(cat "${version_file}" 2>/dev/null | tr -d '[:space:]')"
    if [ -z "${local_version}" ]; then
        printf 'error: no local version\n' >&2
        exit 1
    fi

    # Fetch latest refs from origin (quiet, no merge)
    if ! git -C "${SCRIPT_DIR}" fetch origin --quiet 2>/dev/null; then
        printf 'error: git fetch failed\n' >&2
        exit 1
    fi

    local default_branch
    default_branch="$(git -C "${SCRIPT_DIR}" symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|refs/remotes/origin/||' || echo 'main')"

    local remote_version
    remote_version="$(git -C "${SCRIPT_DIR}" show "origin/${default_branch}:VERSION" 2>/dev/null | tr -d '[:space:]')"
    if [ -z "${remote_version}" ]; then
        printf 'error: could not read remote VERSION\n' >&2
        exit 1
    fi

    printf 'local_version: %s\n' "${local_version}"
    printf 'remote_version: %s\n' "${remote_version}"
    if [ "${local_version}" = "${remote_version}" ]; then
        printf 'update_available: no\n'
    else
        printf 'update_available: yes\n'
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
    restart-recording)
        restart_recording
        ;;
    status)
        status
        ;;
    auth)
        copilot_device_flow
        ;;
    check-update)
        check_update
        ;;
    self-update)
        # Run update.sh from same directory
        exec "${SCRIPT_DIR}/update.sh"
        ;;
    local-server)
        case "${2:-}" in
            start)  local_server_start  ;;
            stop)   local_server_stop   ;;
            status) local_server_status ;;
            *)      printf 'Usage: %s local-server start|stop|status\n' "$0" >&2; exit 1 ;;
        esac
        ;;
    list-local-models)
        list_local_models
        ;;
    download-local-model)
        download_local_model "$@"
        ;;
    *)
        printf 'Usage: %s start|stop|toggle|restart-recording|list-devices|list-models|download-model|list-local-models|download-local-model|auth|status|check-update|self-update|local-server\n' "$0" >&2
        exit 1
        ;;
esac
