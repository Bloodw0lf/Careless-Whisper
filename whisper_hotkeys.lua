-- Whisper speech-to-text hotkeys for Hammerspoon
-- Hotkeys are configured in whisper-stt.conf — reload Hammerspoon to apply changes.

local home = os.getenv("HOME")
-- Paths are set automatically by install.sh
local whisper_script = home .. "/Scripts/Whisper/whisper.sh"
local conf_file      = home .. "/Scripts/Whisper/whisper-stt.conf"

-- Read a value from whisper-stt.conf
local function read_conf(key, default)
    if not key:match("^%w+$") then return default end
    local handle = io.popen(
        "bash -c '. " .. conf_file .. " 2>/dev/null && printf \"%s\" \"${" .. key .. ":-}\"'"
    )
    if not handle then return default end
    local val = handle:read("*l")
    handle:close()
    return (val and val ~= "") and val or default
end

-- Parse "ctrl,cmd,w" → mods {"ctrl","cmd"}, key "w"
local function parse_hotkey(str)
    local parts = {}
    for p in str:gmatch("[^,]+") do
        parts[#parts + 1] = p:match("^%s*(.-)%s*$")
    end
    local key = table.remove(parts)
    return parts, key
end

local toggle_mods, toggle_key = parse_hotkey(read_conf("WHISPER_HOTKEY_TOGGLE", "ctrl,cmd,w"))
local stop_mods,   stop_key   = parse_hotkey(read_conf("WHISPER_HOTKEY_STOP",   "ctrl,cmd,q"))

local status_item = hs.menubar.new()

local script_dir  = whisper_script:match("(.+)/[^/]+$") or "."
local model_dir   = script_dir .. "/models"
local history_file = read_conf("WHISPER_HISTORY_FILE", script_dir .. "/history.txt")

local spinner_frames = {"⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"}
local spinner_index = 1
local spinner_timer = nil
local recording_start = nil

local function format_duration(seconds)
    local m = math.floor(seconds / 60)
    local s = seconds % 60
    return string.format("%d:%02d", m, s)
end

local function start_spinner()
    if spinner_timer then return end
    spinner_timer = hs.timer.doEvery(0.1, function()
        if status_item then
            status_item:setTitle(spinner_frames[spinner_index])
            status_item:setTooltip("Whisper: transcribing...")
        end
        spinner_index = (spinner_index % #spinner_frames) + 1
    end)
end

local function stop_spinner()
    if spinner_timer then
        spinner_timer:stop()
        spinner_timer = nil
    end
    spinner_index = 1
end

local function set_indicator(state)
    if not status_item then return end

    if state == "transcribing" then
        recording_start = nil
        start_spinner()
    else
        stop_spinner()
        if state == "recording" then
            if not recording_start then
                recording_start = os.time()
            end
            local elapsed = os.time() - recording_start
            status_item:setTitle("● " .. format_duration(elapsed))
            status_item:setTooltip("Whisper: recording")
        else
            recording_start = nil
            status_item:setTitle("○")
            status_item:setTooltip("Whisper: idle")
        end
    end
end

local function update_indicator()
    local task = hs.task.new(whisper_script, function(exit_code, std_out, _)
        if exit_code == 0 and std_out then
            if std_out:match("transcribing:%s+yes") then
                set_indicator("transcribing")
            elseif std_out:match("recording:%s+running") then
                set_indicator("recording")
            else
                set_indicator("idle")
            end
        else
            set_indicator("idle")
        end
        return false
    end, {"status"})

    if task then
        task:start()
    else
        set_indicator("idle")
    end
end

local whisper_busy = false
local whisper_busy_safety = nil

local function run_whisper(action)
    if action == "toggle" and whisper_busy then
        hs.alert.show("Whisper: transcription in progress…")
        return
    end

    whisper_busy = true
    -- Safety net: auto-reset after 10 min in case the callback never fires
    if whisper_busy_safety then whisper_busy_safety:stop() end
    whisper_busy_safety = hs.timer.doAfter(600, function()
        whisper_busy = false
        whisper_busy_safety = nil
    end)

    local task = hs.task.new(whisper_script, function()
        whisper_busy = false
        if whisper_busy_safety then whisper_busy_safety:stop(); whisper_busy_safety = nil end
        hs.timer.doAfter(0.4, update_indicator)
        return false
    end, {action})

    if task then
        task:start()
    else
        whisper_busy = false
        if whisper_busy_safety then whisper_busy_safety:stop(); whisper_busy_safety = nil end
        hs.notify.new({
            title = "Whisper",
            informativeText = "Failed to create task for " .. action
        }):send()
    end
end

local function read_history()
    local entries = {}
    local f = io.open(history_file, "r")
    if not f then return entries end
    for line in f:lines() do
        local ts, text = line:match("^%[(.-)%]%s+(.+)$")
        if ts and text then
            entries[#entries + 1] = { timestamp = ts, text = text }
        end
    end
    f:close()
    return entries
end

local function list_models()
    local models = {}
    local ok, result = pcall(function()
        for name in hs.fs.dir(model_dir) do
            if name:match("%.bin$") then
                models[#models + 1] = name
            end
        end
    end)
    if not ok then return {} end
    table.sort(models)
    return models
end

local function get_active_model()
    local path = read_conf("WHISPER_MODEL_PATH", "")
    if path == "" then return "" end
    return path:match("([^/]+)$") or path
end

local download_in_progress = {}

local function list_available_models()
    local installed = {}
    local available = {}
    local handle = io.popen(whisper_script .. " list-models 2>/dev/null")
    if not handle then return installed, available end
    for line in handle:lines() do
        local status, name = line:match("^(%w+):(.+)$")
        if status == "installed" then
            installed[#installed + 1] = name
        elseif status == "available" then
            available[#available + 1] = name
        end
    end
    handle:close()
    return installed, available
end

local function download_model(model_name)
    if download_in_progress[model_name] then
        hs.alert.show("Already downloading " .. model_name)
        return
    end

    download_in_progress[model_name] = true
    local display = model_name:gsub("^ggml%-", ""):gsub("%.bin$", "")
    hs.alert.show("Downloading " .. display .. "…")

    local task = hs.task.new(whisper_script, function(exit_code, std_out, _)
        download_in_progress[model_name] = nil
        if exit_code == 0 then
            if std_out and std_out:match("already_exists") then
                hs.alert.show(display .. " already installed")
            else
                hs.alert.show(display .. " ready")
            end
        else
            hs.alert.show("Download failed: " .. display)
        end
    end, {"download-model", model_name})

    if task then
        task:start()
    else
        download_in_progress[model_name] = nil
        hs.alert.show("Failed to start download")
    end
end

local function update_conf_value(key, value)
    local f = io.open(conf_file, "r")
    if not f then return false end
    local lines = {}
    local replaced = false
    local replacement = key .. '="' .. value .. '"'
    for line in f:lines() do
        if not replaced and line:match("^" .. key .. "=") then
            lines[#lines + 1] = replacement
            replaced = true
        else
            lines[#lines + 1] = line
        end
    end
    f:close()

    if not replaced then
        lines[#lines + 1] = replacement
    end

    local fw = io.open(conf_file, "w")
    if not fw then return false end
    fw:write(table.concat(lines, "\n") .. "\n")
    fw:close()
    return true
end

local function set_active_model(model_name)
    local new_path = model_dir .. "/" .. model_name
    if not update_conf_value("WHISPER_MODEL_PATH", new_path) then
        hs.alert.show("Cannot update config file")
        return
    end

    -- Pretty name without ggml- prefix and .bin suffix for display
    local display = model_name:gsub("^ggml%-", ""):gsub("%.bin$", "")
    hs.alert.show("Model → " .. display)
end

local function build_menu()
    local menu = {
        { title = "Toggle Recording", fn = function() run_whisper("toggle") end },
        { title = "Stop Recording",   fn = function() run_whisper("stop") end },
        { title = "Refresh Status",   fn = function() update_indicator() end },
        { title = "-" },
    }

    -- Notifications & Sounds toggles
    local notif_on = read_conf("WHISPER_NOTIFICATIONS", "1") == "1"
    local sound_on = read_conf("WHISPER_SOUNDS", "1") == "1"
    menu[#menu + 1] = {
        title = (notif_on and "✓ " or "   ") .. "Notifications",
        fn = function()
            local new_val = notif_on and "0" or "1"
            update_conf_value("WHISPER_NOTIFICATIONS", new_val)
            hs.alert.show("Notifications " .. (notif_on and "off" or "on"))
        end,
    }
    menu[#menu + 1] = {
        title = (sound_on and "✓ " or "   ") .. "Sounds",
        fn = function()
            local new_val = sound_on and "0" or "1"
            update_conf_value("WHISPER_SOUNDS", new_val)
            hs.alert.show("Sounds " .. (sound_on and "off" or "on"))
        end,
    }
    menu[#menu + 1] = { title = "-" }

    -- Model selector
    local installed, available = list_available_models()
    local active = get_active_model()
    if #installed > 0 or #available > 0 then
        menu[#menu + 1] = { title = "Model", disabled = true }
        for _, m in ipairs(installed) do
            local is_active = (m == active)
            local display = m:gsub("^ggml%-", ""):gsub("%.bin$", "")
            local captured_model = m
            menu[#menu + 1] = {
                title = (is_active and "✓ " or "   ") .. display,
                fn = function()
                    if not is_active then
                        set_active_model(captured_model)
                    end
                end,
                disabled = is_active,
                tooltip = m,
            }
        end
        if #available > 0 then
            menu[#menu + 1] = { title = "-" }
            menu[#menu + 1] = { title = "Download", disabled = true }
            for _, m in ipairs(available) do
                local display = m:gsub("^ggml%-", ""):gsub("%.bin$", "")
                local captured_model = m
                local is_downloading = download_in_progress[m] or false
                menu[#menu + 1] = {
                    title = (is_downloading and "⟳ " or "   ") .. display,
                    fn = function()
                        download_model(captured_model)
                    end,
                    disabled = is_downloading,
                    tooltip = "Download " .. m .. " from Hugging Face",
                }
            end
        end
        menu[#menu + 1] = { title = "-" }
    end

    -- History
    local history = read_history()
    if #history == 0 then
        menu[#menu + 1] = { title = "No history yet", disabled = true }
    else
        menu[#menu + 1] = { title = "Recent Transcriptions", disabled = true }
        for i = #history, 1, -1 do
            local entry = history[i]
            local preview = entry.text
            if #preview > 60 then
                preview = preview:sub(1, 60) .. "…"
            end
            local captured_text = entry.text
            menu[#menu + 1] = {
                title = preview,
                fn = function()
                    hs.pasteboard.setContents(captured_text)
                    hs.alert.show("Copied to clipboard")
                end,
                tooltip = entry.timestamp,
            }
        end
    end

    return menu
end

if status_item then
    status_item:setMenu(build_menu)
end

hs.hotkey.bind(toggle_mods, toggle_key, function() run_whisper("toggle") end)
hs.hotkey.bind(stop_mods,   stop_key,   function() run_whisper("stop")   end)

hs.timer.doEvery(3.0, update_indicator)
update_indicator()

hs.alert.show("Whisper: " .. table.concat(toggle_mods, "+") .. "+" .. toggle_key .. " start/stop")
