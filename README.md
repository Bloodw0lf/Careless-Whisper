# Whisper Speech-to-Text – macOS Setup

System-wide local speech-to-text on macOS via whisper.cpp + Hammerspoon.
Press a hotkey anywhere (Terminal, Claude Code, browser, Outlook…) to record,
transcribe and auto-paste text.

---

## File Structure

**Repository (what you clone):**

```
Careless-Whisper/
├── whisper.sh           # Main script (record / transcribe / paste)
├── whisper_hotkeys.lua  # Hammerspoon hotkey bindings + menubar indicator
├── install.sh           # Installer (auto-installs dependencies via Homebrew)
├── uninstall.sh         # Clean uninstaller
├── README.md            # This file
└── index.html           # Human-readable docs (open in browser)
```

**Generated locally (gitignored):**

```
Careless-Whisper/
├── whisper-stt.conf     # User configuration — created by install.sh
├── history.txt          # Rolling transcription log (last N entries)
└── models/              # Downloaded by install.sh, selectable via menubar
    └── ggml-*.bin       # e.g. ggml-large-v3-turbo.bin (~800 MB)

~/.hammerspoon/init.lua  # Patched by install.sh to load whisper_hotkeys.lua
```

Available models (downloaded on first install or manually):

| Model                 | Size    | Speed | Quality | Languages           | Best for                              |
| --------------------- | ------- | ----- | ------- | ------------------- | ------------------------------------- |
| `ggml-large-v3-turbo` | ~800 MB | Fast  | High    | Multilingual + auto | Daily use, recommended default        |
| `ggml-large-v3`       | ~1.5 GB | Slow  | Highest | Multilingual + auto | Long recordings, noisy environments   |
| `ggml-medium`         | ~1.5 GB | Med   | Good    | Multilingual + auto | Balanced alternative                  |
| `ggml-medium.en`      | ~1.5 GB | Med   | Good    | English only        | English-only use (slightly better EN) |

Models are downloaded from [Hugging Face](https://huggingface.co/ggerganov/whisper.cpp) and stored in `models/`.
Switch between installed models at any time via the menubar dropdown — no restart needed.

### Performance Benchmarks

General comparison across all whisper.cpp model sizes (GGML quantised):

| Model  | Relative Speed | Accuracy | Memory (VRAM) | Disk Space |
| ------ | -------------- | -------- | ------------- | ---------- |
| tiny   | 10×            | Lowest   | ~1 GB         | ~150 MB    |
| base   | 7×             | Low      | ~1 GB         | ~300 MB    |
| small  | 4×             | Medium   | ~2 GB         | ~1 GB      |
| medium | 2×             | High     | ~5 GB         | ~3 GB      |
| large  | 1×             | Highest  | ~10 GB        | ~6 GB      |

> **Note:** On Apple Silicon Macs, whisper.cpp uses the GPU via Metal. The memory
> values above are approximate and shared with system RAM (unified memory).
> A MacBook with 8 GB RAM can comfortably run `medium`; 16 GB+ is recommended for `large`.

---

## Architecture

```
Hotkey (Ctrl+Cmd+W)
      │
      ▼
Hammerspoon (whisper_hotkeys.lua)
      │  hs.task.new()
      ▼
whisper.sh toggle
      ├─ [start]  ffmpeg records → /tmp/whisper_recording.wav
      └─ [stop]   whisper-cli transcribes
                       │
                       ├─ touch /tmp/whisper_transcribing   (spinner in menubar)
                       ├─ whisper-cli runs
                       ├─ rm /tmp/whisper_transcribing
                       ├─ append to history.txt (rolling 10)
                       ├─ copy to clipboard
                       └─ auto-paste via AppleScript keystroke
```

---

## Hotkeys

| Shortcut     | Action                                     |
| ------------ | ------------------------------------------ |
| `Ctrl+Cmd+W` | Toggle recording (start / stop+transcribe) |
| `Ctrl+Cmd+Q` | Stop recording immediately (emergency)     |

---

## Menubar Indicator

| Symbol        | State                              |
| ------------- | ---------------------------------- |
| `○`           | Idle                               |
| `● 0:12`      | Recording (with elapsed time)      |
| `⠋⠙⠹…` (spin) | Transcribing (whisper-cli running) |

Clicking the menubar icon opens a dropdown with:

- **Toggle / Stop** controls
- **Notifications / Sounds** toggles (on/off per setting)
- **Model selector** — switch between all `.bin` models in `models/`
- **Recent Transcriptions** — click any entry to copy it to the clipboard

---

## Installation

```bash
git clone https://github.com/Bloodw0lf/Careless-Whisper.git
cd Careless-Whisper
./install.sh
```

`install.sh` will:

1. Install `ffmpeg` and `whisper-cpp` via Homebrew if missing
2. Optionally install Hammerspoon via `brew install --cask`
3. Download a whisper model (~800 MB+) if `models/` is empty
4. Let you choose between available models if multiple exist
5. Create `whisper-stt.conf` with correct paths for the clone location
6. Wire up `~/.hammerspoon/init.lua` to load the hotkeys

Then reload Hammerspoon config (menubar → Reload Config) and press `Ctrl+Cmd+W`.

---

## Uninstall

```bash
./uninstall.sh
```

Removes the Hammerspoon integration and temp files. Optionally uninstalls
`whisper-cpp`, `ffmpeg` and Hammerspoon via Homebrew (asks before each).
The repo directory is kept — delete manually if desired.

---

## Dependencies

- `ffmpeg` — `brew install ffmpeg`
- `whisper-cli` — `brew install whisper-cpp`
- Hammerspoon — <https://www.hammerspoon.org>

---

## Configuration (`whisper-stt.conf`)

| Variable                | Default                          | Description                                   |
| ----------------------- | -------------------------------- | --------------------------------------------- |
| `WHISPER_MODEL_PATH`    | `models/ggml-large-v3-turbo.bin` | Path to active model (switchable via menubar) |
| `WHISPER_LANGUAGE`      | `auto`                           | Language or `auto` for detection              |
| `WHISPER_TRANSLATE`     | `0`                              | Set `1` to translate to English               |
| `WHISPER_AUTO_PASTE`    | `1`                              | Auto-paste after transcription                |
| `WHISPER_AUDIO_DEVICE`  | `default`                        | Follows macOS input selection                 |
| `WHISPER_MAX_SECONDS`   | `7200`                           | Max recording length in seconds               |
| `WHISPER_HISTORY_MAX`   | `10`                             | Max entries kept in history                   |
| `WHISPER_NOTIFICATIONS` | `1`                              | Set `0` to disable notifications              |
| `WHISPER_SOUNDS`        | `1`                              | Set `0` to disable sounds                     |

---

## Manual Testing

```bash
bash -n whisper.sh          # syntax check
./whisper.sh status         # current state
./whisper.sh list-devices   # audio inputs
./whisper.sh start          # start recording
./whisper.sh stop           # stop + transcribe
```

---

## Runtime Files (not in repo)

| Path                         | Purpose                             |
| ---------------------------- | ----------------------------------- |
| `/tmp/whisper_recording.wav` | Audio captured by ffmpeg            |
| `/tmp/whisper_output.txt`    | Raw whisper-cli output              |
| `/tmp/whisper_transcribing`  | Marker while whisper-cli is running |
| `/tmp/ffmpeg.log`            | ffmpeg stderr                       |
| `/tmp/whisper-error.log`     | whisper-cli stderr                  |

---

## Pitfalls

| Problem                             | Root Cause                              | Fix                                                               |
| ----------------------------------- | --------------------------------------- | ----------------------------------------------------------------- |
| Hotkey does nothing                 | Hammerspoon config not reloaded         | Menubar → Reload Config                                           |
| No audio output                     | Wrong device index                      | `whisper.sh list-devices` → adjust conf                           |
| `whisper-cli not found`             | PATH missing in Hammerspoon             | `find_bin()` checks Homebrew paths first                          |
| Spinner stays on                    | `/tmp/whisper_transcribing` not removed | Auto-cleaned after 10 min; check error path in `stop_recording()` |
| Hotkey ignored during transcription | Guard active while transcribing         | Expected — wait for transcription to finish                       |
| Model rejected for language         | `.en.bin` + non-English lang            | Switch model or set `WHISPER_LANGUAGE=en`                         |
