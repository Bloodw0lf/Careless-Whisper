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

Both are configurable in `whisper-stt.conf` and applied on Hammerspoon reload.

## Menubar

| Icon     | Meaning                       |
| -------- | ----------------------------- |
| `○`      | Idle                          |
| `● 0:12` | Recording (with elapsed time) |
| `⠋⠙⠹…`   | Transcribing                  |

Click the icon for a dropdown with:

- **Toggle / Stop** controls
- **Notifications / Sounds** on/off toggles
- **Model selector** — switch models without editing config
- **Recent Transcriptions** — click to copy to clipboard

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

| Variable                | Default                          | Description                                |
| ----------------------- | -------------------------------- | ------------------------------------------ |
| `WHISPER_MODEL_PATH`    | `models/ggml-large-v3-turbo.bin` | Active model (or use menubar)              |
| `WHISPER_LANGUAGE`      | `auto`                           | Language code or `auto`                    |
| `WHISPER_TRANSLATE`     | `0`                              | `1` = translate everything to English      |
| `WHISPER_AUTO_PASTE`    | `1`                              | Auto-paste after transcription             |
| `WHISPER_AUDIO_DEVICE`  | `default`                        | macOS input device (or AVFoundation index) |
| `WHISPER_MAX_SECONDS`   | `7200`                           | Max recording length                       |
| `WHISPER_HISTORY_MAX`   | `10`                             | Entries kept in history                    |
| `WHISPER_NOTIFICATIONS` | `1`                              | `0` = disable notifications                |
| `WHISPER_SOUNDS`        | `1`                              | `0` = disable sounds                       |
| `WHISPER_HOTKEY_TOGGLE` | `shift,cmd,r`                    | Toggle hotkey                              |
| `WHISPER_HOTKEY_STOP`   | `shift,cmd,q`                    | Emergency stop hotkey                      |

## Uninstall

```bash
./uninstall.sh
```

Removes Hammerspoon integration and temp files. Optionally uninstalls Homebrew packages (asks per package). The repo directory is kept.

## Architecture

```
Ctrl+Cmd+W  →  Hammerspoon (whisper_hotkeys.lua)
                    │  hs.task.new()
                    ▼
               whisper.sh toggle
                    ├─ [start]  ffmpeg → $TMPDIR/whisper_recording.wav
                    └─ [stop]   whisper-cli transcribes
                                    ├─ spinner in menubar
                                    ├─ append to history.txt
                                    ├─ copy to clipboard
                                    └─ auto-paste via AppleScript
```

## Troubleshooting

| Problem                     | Fix                                                                          |
| --------------------------- | ---------------------------------------------------------------------------- |
| Hotkey does nothing         | Reload Hammerspoon config (menubar → Reload Config)                          |
| No audio captured           | Run `./whisper.sh list-devices`, set `WHISPER_AUDIO_DEVICE`                  |
| `whisper-cli not found`     | Re-run `./install.sh` or `brew install whisper-cpp`                          |
| Spinner stuck               | Auto-clears after 10 min; check `$TMPDIR/whisper-error.log`                  |
| Hotkey ignored while busy   | Expected — wait for transcription to finish                                  |
| Model rejected for language | `.en.bin` models are English-only; switch model or set `WHISPER_LANGUAGE=en` |

## File Structure

```
Careless-Whisper/              # Repository
├── whisper.sh                 # Core script (record/transcribe/paste)
├── whisper_hotkeys.lua        # Hammerspoon integration + menubar
├── install.sh                 # Installer (auto-deps via Homebrew)
├── uninstall.sh               # Clean removal
├── README.md
└── index.html                 # Browser-friendly docs

Generated locally (gitignored):
├── whisper-stt.conf           # User configuration
├── history.txt                # Rolling transcription log
└── models/                    # Downloaded GGML model files
    └── ggml-*.bin
```

## Manual Testing

```bash
./whisper.sh status         # current state + version
./whisper.sh list-devices   # available audio inputs
./whisper.sh start          # start recording
./whisper.sh stop           # stop + transcribe
bash -n whisper.sh          # syntax check
```
