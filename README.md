# Careless Whisper

Local speech-to-text for macOS. Press a hotkey anywhere, speak, get text pasted — no cloud, no subscription.

Uses [whisper.cpp](https://github.com/ggerganov/whisper.cpp) for transcription and [Hammerspoon](https://www.hammerspoon.org) for global hotkeys.

## Quick Start

```bash
git clone https://wwwin-github.cisco.com/bpleger/Careless-Whisper.git
cd Careless-Whisper
./install.sh
```

The installer handles everything automatically:

1. Installs `ffmpeg`, `whisper-cpp`, and `llama.cpp` via Homebrew (if missing)
2. Offers to install Hammerspoon via `brew install --cask`
3. Interactive arrow-key model selection (whisper + local LLM)
4. GitHub Copilot OAuth authentication (for AI post-processing)
5. Creates `whisper-stt.conf` with correct paths
6. Wires up `~/.hammerspoon/init.lua`
7. Launches Hammerspoon and reloads the config

After install: press **⇧⌘R** to start recording, press again to transcribe and paste.

## Hotkeys

| Shortcut | Action                                     |
| -------- | ------------------------------------------ |
| `⇧⌘R`    | Toggle recording (start / stop+transcribe) |
| `⇧⌘Q`    | Emergency stop                             |
| `⇧⌘W`    | Open/close settings panel                  |

All hotkeys are configurable in `whisper-stt.conf` and applied on Hammerspoon reload.

## Menubar

| Icon     | Meaning                       |
| -------- | ----------------------------- |
| `○`      | Idle                          |
| `● 0:12` | Recording (with elapsed time) |
| `⠋⠙⠹…`   | Transcribing                  |
| `◰◳◲◱`   | Post-processing (AI)          |

Click the menubar icon to open the **settings panel** — a floating window with:

- **Status** — live recording state with elapsed timer
- **Start / Stop** controls
- **Settings** — Notifications, Sounds, Auto-Enter toggles
- **Post-processing mode** — AI-powered text enhancement (see below)
- **Model selector** — switch models, download new ones with progress
- **Recent Transcriptions** — click to copy to clipboard

The panel can also be toggled via `⇧⌘W`. Closing the panel window does not stop Whisper.

## AI Post-Processing

Careless Whisper can enhance transcriptions using an AI model. Select a mode and backend from the settings panel.

### Modes

| Mode           | Description                                                      |
| -------------- | ---------------------------------------------------------------- |
| **Off**        | Raw transcript, no processing                                    |
| **Clean**      | Remove fillers, fix punctuation, strip Whisper hallucinations    |
| **Messenger**  | Concise message for WebEx/Teams — compact, no paragraph breaks   |
| **Email**      | Professional email body with greeting, no sign-off               |
| **Prompt**     | Light cleanup of a dictated AI prompt — preserves intent exactly |
| **Prompt Pro** | Full prompt engineering — adds role, constraints, structure      |

All modes handle spelling hints ("MAP, also M-A-B" → MAB) and keep the original language.

### Backends

Choose your AI backend in the settings panel under **AI Backend**:

| Backend               | Requirement          | Config                                 |
| --------------------- | -------------------- | -------------------------------------- |
| **None**              | —                    | `WHISPER_PP_BACKEND=none`              |
| **GitHub Copilot**    | Copilot subscription | `WHISPER_PP_BACKEND=copilot` (default) |
| **Claude API**        | Anthropic API key    | `WHISPER_PP_BACKEND=claude`            |
| **Local (llama.cpp)** | llama-server running | `WHISPER_PP_BACKEND=local`             |

#### None

Disables AI post-processing entirely. The Post Processing section is hidden when this backend is selected. Raw transcripts are pasted as-is.

#### GitHub Copilot

Uses the Copilot API (same as VS Code). Authentication via GitHub OAuth Device Flow.

- **Panel:** Select "GitHub Copilot" as backend — if no token is found, a "Sign in" button appears inline. Clicking it starts the device flow: a pairing code is copied to your clipboard, and GitHub opens in your browser. Just paste the code when prompted. On success, a green confirmation appears in the panel.
- **Installer:** Run `./install.sh` — prompts for authentication during setup
- **Manual:** Set `GITHUB_COPILOT_TOKEN` environment variable

Token stored in `~/.config/careless-whisper/auth.json` (permissions `600`).

#### Claude API

Direct access to Anthropic's Claude models. Enter your API key in the settings panel or set it in config:

```
WHISPER_PP_BACKEND=claude
WHISPER_CLAUDE_API_KEY=sk-ant-...
WHISPER_CLAUDE_MODEL=claude-sonnet-4-20250514
```

Get an API key at [console.anthropic.com](https://console.anthropic.com/).

#### Local (llama.cpp)

Fully offline processing via [llama.cpp](https://github.com/ggerganov/llama.cpp). Runs on-demand — the server starts automatically before post-processing and shuts down after, freeing GPU RAM. Native Metal acceleration on Apple Silicon. No auth, no cloud, no rate limits.

**Install:**

```bash
brew install llama.cpp
```

**Download a model:**

| Tier     | Model        | Size           | Use case                                       |
| -------- | ------------ | -------------- | ---------------------------------------------- |
| Tiny     | Bonsai-8B    | ~1.2 GB (Q1_0) | 1-bit 8B — all modes, auto-builds PrismML fork |
| Fast     | Llama-3.2-3B | ~1.9 GB (Q4)   | clean, message — filler removal                |
| Balanced | Qwen2.5-7B   | ~4.5 GB (Q4)   | All modes including email/prompt               |
| Quality  | Qwen2.5-14B  | ~9 GB (Q4)     | Longer transcripts, polished output            |

Models can be downloaded automatically via:

- **Install script**: `./install.sh` offers interactive local model selection (default: 7B)
- **Panel**: AI Backend → Local → Download section
- **CLI**: `./whisper.sh download-local-model Qwen2.5-7B`

Or download GGUFs manually from [bartowski](https://huggingface.co/bartowski) on Hugging Face (use Q4_K_M quantization).

> **Bonsai-8B** uses Q1_0 quantization which requires the [PrismML llama.cpp fork](https://github.com/PrismML-Eng/llama.cpp).
> The installer and panel download will build it automatically to `~/.local/share/careless-whisper/prismml-llama-server`.
> The standard Homebrew `llama-server` is used for all other models.

**Configure:**

```
WHISPER_PP_BACKEND=local
WHISPER_LOCAL_MODEL=/path/to/Qwen2.5-7B-Instruct-Q4_K_M.gguf
WHISPER_LOCAL_URL=http://127.0.0.1:8085
```

The server runs on-demand (starts/stops automatically with each transcription) on port 8085, with all layers offloaded to GPU (`-ngl 99`) and 8K context. Adjust via `WHISPER_LOCAL_GPU_LAYERS` and `WHISPER_LOCAL_CTX`.

## Models

The installer offers three models. You can download more later and switch via the menubar.

| Model                 | Size    | Speed | Quality | Best for                     |
| --------------------- | ------- | ----- | ------- | ---------------------------- |
| `ggml-large-v3-turbo` | ~800 MB | Fast  | High    | **Recommended** — daily use  |
| `ggml-large-v3`       | ~1.5 GB | Slow  | Highest | Long recordings, noisy audio |
| `ggml-medium`         | ~1.5 GB | Med   | Good    | Balanced alternative         |

All models are multilingual with automatic language detection.
English-only variants (`.en.bin`) are also available from [Hugging Face](https://huggingface.co/ggerganov/whisper.cpp).

### Performance by Size

| Size   | Relative Speed | Accuracy | Memory (VRAM) | Disk    |
| ------ | -------------- | -------- | ------------- | ------- |
| tiny   | 10×            | Lowest   | ~1 GB         | ~150 MB |
| base   | 7×             | Low      | ~1 GB         | ~300 MB |
| small  | 4×             | Medium   | ~2 GB         | ~1 GB   |
| medium | 2×             | High     | ~5 GB         | ~3 GB   |
| large  | 1×             | Highest  | ~10 GB        | ~6 GB   |

> On Apple Silicon, whisper.cpp uses Metal (GPU). Memory is shared with system RAM.
> 8 GB RAM handles `medium` comfortably; 16 GB+ recommended for `large`.

## Configuration

All settings live in `whisper-stt.conf` (created by the installer, gitignored):

| Variable                    | Default                                   | Description                                |
| --------------------------- | ----------------------------------------- | ------------------------------------------ |
| `WHISPER_MODEL_PATH`        | `models/ggml-large-v3-turbo.bin`          | Active model (or use menubar)              |
| `WHISPER_LANGUAGE`          | `auto`                                    | Language code or `auto`                    |
| `WHISPER_TRANSLATE`         | `0`                                       | `1` = translate everything to English      |
| `WHISPER_AUTO_PASTE`        | `1`                                       | Auto-paste after transcription             |
| `WHISPER_AUTO_ENTER`        | `0`                                       | Press Enter after paste (for LLM chats)    |
| `WHISPER_RESTORE_CLIPBOARD` | `0`                                       | Restore clipboard after auto-paste         |
| `WHISPER_AUDIO_DEVICE`      | `default`                                 | macOS input device (or AVFoundation index) |
| `WHISPER_MAX_SECONDS`       | `7200`                                    | Max recording length                       |
| `WHISPER_HISTORY_MAX`       | `10`                                      | Entries kept in history                    |
| `WHISPER_NOTIFICATIONS`     | `1`                                       | `0` = disable notifications                |
| `WHISPER_SOUNDS`            | `1`                                       | `0` = disable sounds                       |
| `WHISPER_TRIM_SILENCE`      | `1`                                       | Trim leading/trailing silence from audio   |
| `WHISPER_HOTKEY_TOGGLE`     | `shift,cmd,r`                             | Toggle hotkey                              |
| `WHISPER_HOTKEY_STOP`       | `shift,cmd,q`                             | Emergency stop hotkey                      |
| `WHISPER_HOTKEY_PANEL`      | `shift,cmd,w`                             | Panel hotkey                               |
| `WHISPER_POST_PROCESS`      | `off`                                     | Post-processing mode (or use panel)        |
| `WHISPER_PP_BACKEND`        | `copilot`                                 | AI backend: `none`, `copilot`, `claude`, `local`   |
| `WHISPER_COPILOT_MODEL`     | `claude-sonnet-4.6`                       | Copilot model for post-processing          |
| `WHISPER_CLAUDE_API_KEY`    | —                                         | Anthropic API key (for `claude` backend)   |
| `WHISPER_CLAUDE_MODEL`      | `claude-haiku-4-5-20251001`               | Claude model name                          |
| `WHISPER_LOCAL_MODEL`       | —                                         | Path to GGUF file (for `local` backend)    |
| `WHISPER_LOCAL_URL`         | `http://127.0.0.1:8085`                   | llama-server API URL                       |
| `WHISPER_LOCAL_GPU_LAYERS`  | `99`                                      | GPU layers to offload (Metal)              |
| `WHISPER_LOCAL_CTX`         | `8192`                                    | Context window size                        |
| `WHISPER_PRISMML_LLAMA_BIN` | `~/.local/share/.../prismml-llama-server` | PrismML fork binary for Bonsai Q1_0        |
| `WHISPER_CUSTOM_VOCAB`      | —                                         | Spelling hints for domain terms            |
| `WHISPER_HISTORY_FILE`      | `history.txt`                             | Path to transcription log                  |
| `WHISPER_DEV_TIMINGS`       | `0`                                       | `1` = append timing breakdown to output    |

## Uninstall

```bash
./uninstall.sh
```

Removes Hammerspoon integration, temp files, and optionally the PrismML llama-server (`~/.local/share/careless-whisper/`). Also offers to uninstall Homebrew packages (asks per package). The repo directory is kept.

## Updates

The settings panel checks for updates automatically. When a new version is available, an **"Update Available"** banner appears at the top of the panel. Click it to update in place — your settings, models, and history are preserved.

You can also update manually:

```bash
./update.sh
```

The update pulls the latest changes from git, re-patches paths, and reloads Hammerspoon. No re-configuration needed.

## Architecture

```
⇧⌘R  →  Hammerspoon (whisper_hotkeys.lua)
              │  hs.task.new()
              ▼
         whisper.sh toggle
              ├─ [start]  ffmpeg → segment recording (16kHz mono WAV)
              └─ [stop]   concat segments → whisper-cli transcribes
                               ├─ spinner in menubar (⠋⠙⠹…)
                               ├─ [if post-process] Copilot API → ◰◳◲◱
                               ├─ append to history.txt
                               ├─ copy to clipboard
                               └─ auto-paste via AppleScript
                    └─ [if auto-enter] simulate Return key
```

## Troubleshooting

| Problem                     | Solution                                                                     |
| --------------------------- | ---------------------------------------------------------------------------- |
| Hotkey does nothing         | Reload Hammerspoon config (menubar → Reload Config)                          |
| No audio captured           | Run `./whisper.sh list-devices`, set `WHISPER_AUDIO_DEVICE`                  |
| `whisper-cli not found`     | Re-run `./install.sh` or `brew install whisper-cpp`                          |
| Spinner stuck               | Auto-clears after 10 min; check `$TMPDIR/whisper-error.log`                  |
| Hotkey ignored while busy   | Expected — wait for transcription to finish                                  |
| Model rejected for language | `.en.bin` models are English-only; switch model or set `WHISPER_LANGUAGE=en` |

## File Structure

```

Careless-Whisper/ # Repository
├── whisper.sh # Core script (record/transcribe/paste)
├── whisper_hotkeys.lua # Hammerspoon integration + menubar
├── whisper_webview.lua # Settings panel (Hammerspoon webview)
├── whisper_panel.html # Panel UI (HTML/CSS/JS)
├── install.sh # Installer (auto-deps via Homebrew)
├── update.sh # Self-updater (preserves settings)
├── uninstall.sh # Clean removal
├── VERSION # Semantic version for update checks
├── README.md
└── index.html # Browser-friendly docs

Generated locally (gitignored):
├── whisper-stt.conf # User configuration
├── history.txt # Rolling transcription log
└── models/ # Downloaded model files
    ├── ggml-*.bin       # Whisper speech-to-text models
    └── *.gguf           # Local LLM models (GGUF format)

```

## Manual Testing

```bash
./whisper.sh status                        # current state + version
./whisper.sh toggle                        # start or stop+transcribe
./whisper.sh start                         # start recording
./whisper.sh stop                          # stop + transcribe
./whisper.sh list-devices                  # available audio inputs
./whisper.sh list-models                   # whisper models (installed/available)
./whisper.sh list-local-models             # local LLM models
./whisper.sh download-model <name.bin>     # download whisper model
./whisper.sh download-local-model <id>     # download local model (Bonsai-8B, Qwen2.5-7B, ...)
./whisper.sh local-server start|stop|status  # manage llama-server
./whisper.sh auth                          # GitHub Copilot OAuth sign-in
./whisper.sh check-update                  # check for available updates
./whisper.sh self-update                   # update in place
bash -n whisper.sh                         # syntax check
```
