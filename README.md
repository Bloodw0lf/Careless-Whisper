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

1. Installs `ffmpeg` and `whisper-cpp` via Homebrew (if missing)
2. Offers to install Hammerspoon via `brew install --cask`
3. Downloads a whisper model (~800 MB) if none exist yet
4. Creates `whisper-stt.conf` with correct paths
5. Wires up `~/.hammerspoon/init.lua`
6. Launches Hammerspoon and reloads the config

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
| **GitHub Copilot**    | Copilot subscription | `WHISPER_PP_BACKEND=copilot` (default) |
| **Claude API**        | Anthropic API key    | `WHISPER_PP_BACKEND=claude`            |
| **Local (llama.cpp)** | llama-server running | `WHISPER_PP_BACKEND=local`             |

#### GitHub Copilot

Uses the Copilot API (same as VS Code). Authentication via GitHub OAuth Device Flow.

- **Panel:** Click "Sign in to GitHub Copilot" when Copilot backend is selected
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

Fully offline processing via [llama.cpp](https://github.com/ggerganov/llama.cpp). Runs a GGUF model as a persistent local server with native Metal acceleration on Apple Silicon. No auth, no cloud, no rate limits.

**Install:**

```bash
brew install llama.cpp
```

**Download a model** (Qwen3.5 recommended — Apache 2.0, 201 languages, native DE/EN):

| Tier     | Model       | Size (Q4_K_M) | Use case                            |
| -------- | ----------- | ------------- | ----------------------------------- |
| Fast     | Qwen3.5-4B  | ~3.4 GB       | clean, message — filler removal     |
| Balanced | Qwen3.5-9B  | ~6.6 GB       | All modes including email/prompt    |
| Quality  | Qwen3.5-27B | ~17 GB        | Longer transcripts, polished output |

Models can be downloaded automatically via:

- **Install script**: `./install.sh` offers interactive local model selection
- **Panel**: AI Backend → Local → Download section
- **CLI**: `./whisper.sh download-local-model Qwen3.5-9B`

Or download GGUFs manually from [unsloth/Qwen3.5-\*-GGUF](https://huggingface.co/unsloth) on Hugging Face (use Q4_K_M quantization).

**Configure:**

```
WHISPER_PP_BACKEND=local
WHISPER_LOCAL_MODEL=/path/to/Qwen3.5-9B-Q4_K_M.gguf
WHISPER_LOCAL_URL=http://127.0.0.1:8085
```

**Start/stop** the server from the settings panel (AI Backend → Local → Start/Stop) or manually:

```bash
./whisper.sh local-server start
./whisper.sh local-server stop
./whisper.sh local-server status
```

The server runs on port 8085 with all layers offloaded to GPU (`-ngl 99`) and 8K context. Adjust via `WHISPER_LOCAL_GPU_LAYERS` and `WHISPER_LOCAL_CTX`.

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

| Variable                   | Default                          | Description                                |
| -------------------------- | -------------------------------- | ------------------------------------------ |
| `WHISPER_MODEL_PATH`       | `models/ggml-large-v3-turbo.bin` | Active model (or use menubar)              |
| `WHISPER_LANGUAGE`         | `auto`                           | Language code or `auto`                    |
| `WHISPER_TRANSLATE`        | `0`                              | `1` = translate everything to English      |
| `WHISPER_AUTO_PASTE`       | `1`                              | Auto-paste after transcription             |
| `WHISPER_AUTO_ENTER`       | `0`                              | Press Enter after paste (for LLM chats)    |
| `WHISPER_AUDIO_DEVICE`     | `default`                        | macOS input device (or AVFoundation index) |
| `WHISPER_MAX_SECONDS`      | `7200`                           | Max recording length                       |
| `WHISPER_HISTORY_MAX`      | `10`                             | Entries kept in history                    |
| `WHISPER_NOTIFICATIONS`    | `1`                              | `0` = disable notifications                |
| `WHISPER_SOUNDS`           | `1`                              | `0` = disable sounds                       |
| `WHISPER_HOTKEY_TOGGLE`    | `shift,cmd,r`                    | Toggle hotkey                              |
| `WHISPER_HOTKEY_STOP`      | `shift,cmd,q`                    | Emergency stop hotkey                      |
| `WHISPER_HOTKEY_PANEL`     | `shift,cmd,w`                    | Panel hotkey                               |
| `WHISPER_POST_PROCESS`     | `off`                            | Post-processing mode (or use panel)        |
| `WHISPER_PP_BACKEND`       | `copilot`                        | AI backend: `copilot`, `claude`, `local`   |
| `WHISPER_CLAUDE_API_KEY`   | —                                | Anthropic API key (for `claude` backend)   |
| `WHISPER_CLAUDE_MODEL`     | `claude-sonnet-4-20250514`       | Claude model name                          |
| `WHISPER_LOCAL_MODEL`      | —                                | Path to GGUF file (for `local` backend)    |
| `WHISPER_LOCAL_URL`        | `http://127.0.0.1:8085`          | llama-server API URL                       |
| `WHISPER_LOCAL_GPU_LAYERS` | `99`                             | GPU layers to offload (Metal)              |
| `WHISPER_LOCAL_CTX`        | `8192`                           | Context window size                        |

## Uninstall

```bash
./uninstall.sh
```

Removes Hammerspoon integration and temp files. Optionally uninstalls Homebrew packages (asks per package). The repo directory is kept.

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
└── models/ # Downloaded GGML model files
└── ggml-\*.bin

````

## Manual Testing

```bash
./whisper.sh status         # current state + version
./whisper.sh check-update   # check for available updates
./whisper.sh list-devices   # available audio inputs
./whisper.sh start          # start recording
./whisper.sh stop           # stop + transcribe
bash -n whisper.sh          # syntax check
````
