-- Whisper speech-to-text hotkeys for Hammerspoon
-- Hotkeys are configured in whisper-stt.conf — reload Hammerspoon to apply changes.

local home = os.getenv("HOME")
-- Paths are set automatically by install.sh
local whisper_script = home .. "/Scripts/Whisper/whisper.sh"
local conf_file      = home .. "/Scripts/Whisper/whisper-stt.conf"

-- Read a value from whisper-stt.conf
local function read_conf(key, default)
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

local spinner_frames = {"⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"}
local spinner_index = 1
local spinner_timer = nil

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
        start_spinner()
    else
        stop_spinner()
        if state == "recording" then
            status_item:setTitle("●")
            status_item:setTooltip("Whisper: recording")
        else
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
        set_indicator(false)
    end
end

local function run_whisper(action)
    local task = hs.task.new(whisper_script, function()
        hs.timer.doAfter(0.4, update_indicator)
        return false
    end, {action})

    if task then
        task:start()
    else
        hs.notify.new({
            title = "Whisper",
            informativeText = "Failed to create task for " .. action
        }):send()
    end
end

if status_item then
    status_item:setMenu({
        { title = "Whisper Toggle", fn = function() run_whisper("toggle") end },
        { title = "Whisper Stop",   fn = function() run_whisper("stop") end },
        { title = "Refresh Status", fn = function() update_indicator() end }
    })
end

hs.hotkey.bind(toggle_mods, toggle_key, function() run_whisper("toggle") end)
hs.hotkey.bind(stop_mods,   stop_key,   function() run_whisper("stop")   end)

hs.timer.doEvery(1.0, update_indicator)
update_indicator()

hs.alert.show("Whisper: " .. table.concat(toggle_mods, "+") .. "+" .. toggle_key .. " start/stop")
