# Whisper Speech-to-Text – macOS Setup

System-wide local speech-to-text on macOS via whisper.cpp + Hammerspoon.
Press a hotkey anywhere (Terminal, Claude Code, browser, Outlook…) to record,
transcribe and auto-paste text.

---

## File Structure

```
~/Scripts/Whisper/
├── whisper.sh           # Main script (record / transcribe / paste)
├── whisper_hotkeys.lua  # Hammerspoon hotkey bindings + menubar indicator
├── whisper-stt.conf     # User configuration (model path, language, …)
├── install.sh           # One-shot installer
├── history.txt          # Last 10 transcriptions (rolling)
├── models/
│   └── ggml-large-v3-turbo.bin   ← active model (downloaded by install.sh)
├── README.md            # This file (AI-readable project reference)
└── index.html           # Human-readable docs (open in browser)

~/.hammerspoon/init.lua  # Loads whisper_hotkeys.lua from clone directory
```

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

| Shortcut        | Action                                      |
|-----------------|---------------------------------------------|
| `Ctrl+Cmd+W`    | Toggle recording (start / stop+transcribe)  |
| `Ctrl+Cmd+Q`    | Stop recording immediately (emergency)      |

---

## Menubar Indicator

| Symbol          | State                                      |
|-----------------|--------------------------------------------|
| `○`             | Idle                                       |
| `●`             | Recording                                  |
| `⠋⠙⠹…` (spin) | Transcribing (whisper-cli running)         |

---

## Installation

```bash
git clone https://github.com/bpleger_cisco/Careless_Whisper.git
cd Careless_Whisper
./install.sh
```

`install.sh` will:
1. Check for `ffmpeg` and `whisper-cli`
2. Download `ggml-large-v3-turbo.bin` (~800MB) if no model is present
3. Create `whisper-stt.conf` with correct paths for the clone location
4. Wire up `~/.hammerspoon/init.lua` to load the hotkeys

Then reload Hammerspoon config (menubar → Reload Config) and press `Ctrl+Cmd+W`.

---

## Dependencies

- `ffmpeg` — `brew install ffmpeg`
- `whisper-cli` — `brew install whisper-cpp`
- Hammerspoon — <https://www.hammerspoon.org>

---

## Configuration (`whisper-stt.conf`)

| Variable               | Default                          | Description                        |
|------------------------|----------------------------------|------------------------------------|
| `WHISPER_MODEL_PATH`   | `models/ggml-large-v3-turbo.bin` | Path to model file                 |
| `WHISPER_LANGUAGE`     | `auto`                           | Language or `auto` for detection   |
| `WHISPER_TRANSLATE`    | `0`                              | Set `1` to translate to English    |
| `WHISPER_AUTO_PASTE`   | `1`                              | Auto-paste after transcription     |
| `WHISPER_AUDIO_DEVICE` | `default`                        | Follows macOS input selection      |
| `WHISPER_MAX_SECONDS`  | `7200`                           | Max recording length in seconds    |
| `WHISPER_HISTORY_MAX`  | `10`                             | Max entries kept in history        |

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

| Path                        | Purpose                              |
|-----------------------------|--------------------------------------|
| `/tmp/whisper_recording.wav`| Audio captured by ffmpeg             |
| `/tmp/whisper_output.txt`   | Raw whisper-cli output               |
| `/tmp/whisper_transcribing` | Marker while whisper-cli is running  |
| `/tmp/ffmpeg.log`           | ffmpeg stderr                        |
| `/tmp/whisper-error.log`    | whisper-cli stderr                   |

---

## AI Guidelines

1. After editing `whisper_hotkeys.lua`: user must reload Hammerspoon (menubar → Reload Config).
2. Always use full binary paths — PATH is unavailable in Hammerspoon context.
3. Use `hs.task.new()` not `hs.execute` for scripts with arguments.
4. `nohup` is required for ffmpeg to persist after the parent script exits.
5. `.en.bin` models reject non-English language settings — `language_allowed_for_model()` guards this.
6. `Ctrl+Cmd` combos are reliably free. Avoid `Cmd+numbers`, `F5` (macOS Dictation).
7. `spinner_timer` must be stopped explicitly on every non-transcribing state.

---

## Pitfalls

| Problem                              | Root Cause                          | Fix                                       |
|--------------------------------------|-------------------------------------|-------------------------------------------|
| Hotkey does nothing                  | Hammerspoon config not reloaded     | Menubar → Reload Config                   |
| No audio output                      | Wrong device index                  | `whisper.sh list-devices` → adjust conf   |
| `whisper-cli not found`              | PATH missing in Hammerspoon         | `find_bin()` checks Homebrew paths first  |
| Spinner stays on                     | `/tmp/whisper_transcribing` not removed | Check error path in `stop_recording()` |
| Model rejected for language          | `.en.bin` + non-English lang        | Switch model or set `WHISPER_LANGUAGE=en` |
