-- whisper_webview.lua — Hammerspoon webview panel for Careless Whisper
-- Loaded by whisper_hotkeys.lua via dofile().
-- Provides: init(bridge), toggle(), pushState(), pushAll(), destroy()

local M = {}

local webview = nil
local controller = nil
local bridge = nil       -- callback table from whisper_hotkeys
local panel_ready = false
local custom_import_timer = nil

local PANEL_W = 380
local PANEL_H = 520

-- ── JSON via Hammerspoon ────────────────────────────────────────────────────

local json_encode = hs.json.encode

local function json_decode(str)
    if not str or str == "" then return nil end
    local ok, result = pcall(hs.json.decode, str)
    if ok then return result end
    return nil
end

-- ── Execute JS in webview ───────────────────────────────────────────────────

local function eval_js(js)
    if webview and panel_ready then
        webview:evaluateJavaScript(js)
    end
end

-- ── Push functions (Lua → JS) ───────────────────────────────────────────────

function M.pushState(state_info)
    if not bridge then return end
    local data = state_info or bridge.get_state()
    eval_js("updateState(" .. json_encode(data) .. ")")
end

function M.pushSettings()
    if not bridge then return end
    local settings = {
        WHISPER_NOTIFICATIONS      = bridge.read_conf("WHISPER_NOTIFICATIONS", "1"),
        WHISPER_SOUNDS             = bridge.read_conf("WHISPER_SOUNDS", "1"),
        WHISPER_AUTO_ENTER         = bridge.read_conf("WHISPER_AUTO_ENTER", "0"),
        WHISPER_RESTORE_CLIPBOARD  = bridge.read_conf("WHISPER_RESTORE_CLIPBOARD", "0"),
        WHISPER_POST_PROCESS       = bridge.read_conf("WHISPER_POST_PROCESS", "off"),
        WHISPER_PP_BACKEND         = bridge.read_conf("WHISPER_PP_BACKEND", "copilot"),
        WHISPER_CLAUDE_API_KEY     = bridge.read_conf("WHISPER_CLAUDE_API_KEY", ""),
        WHISPER_CUSTOM_VOCAB       = bridge.read_conf("WHISPER_CUSTOM_VOCAB", ""),
        WHISPER_HOTKEY_TOGGLE      = bridge.read_conf("WHISPER_HOTKEY_TOGGLE", "shift,cmd,r"),
        WHISPER_HOTKEY_STOP        = bridge.read_conf("WHISPER_HOTKEY_STOP", "shift,cmd,q"),
        WHISPER_HOTKEY_PANEL       = bridge.read_conf("WHISPER_HOTKEY_PANEL", "shift,cmd,w"),
    }
    eval_js("updateSettings(" .. json_encode(settings) .. ")")
end

function M.pushModels()
    if not bridge then return end
    local installed, available = bridge.list_available_models()
    local active = bridge.get_active_model()
    local downloading = bridge.get_download_progress()
    local data = {
        active = active,
        installed = installed,
        available = available,
        downloading = downloading,
    }
    eval_js("updateModels(" .. json_encode(data) .. ")")
end

function M.pushHistory()
    if not bridge then return end
    local entries = bridge.read_history()
    local data = {}
    for _, e in ipairs(entries) do
        data[#data + 1] = { ts = e.timestamp, text = e.text }
    end
    eval_js("updateHistory(" .. json_encode(data) .. ")")
end

function M.pushAuth()
    if not bridge then return end
    local has_token = bridge.has_copilot_token()
    eval_js("updateAuth(" .. json_encode({ authenticated = has_token }) .. ")")
end

function M.pushUpdateStatus()
    if not bridge then return end
    bridge.check_update(function(data)
        eval_js("updateUpdateStatus(" .. json_encode(data) .. ")")
    end)
end

function M.pushLocalServer()
    if not bridge then return end
    bridge.local_server_status(function(data)
        eval_js("updateLocalServer(" .. json_encode(data) .. ")")
    end)
end

function M.pushLocalModels()
    if not bridge then return end
    local installed, available = bridge.list_local_models()
    local downloading = bridge.get_local_download_progress()
    local data = {
        installed = installed,
        available = available,
        downloading = downloading,
    }
    eval_js("updateLocalModels(" .. json_encode(data) .. ")")
end

-- Lightweight: push only download progress without re-listing models from shell
function M.pushDownloadProgress()
    if not bridge then return end
    local downloading = bridge.get_download_progress()
    eval_js("updateDownloadProgress(" .. json_encode(downloading) .. ")")
end

function M.pushLocalDownloadProgress()
    if not bridge then return end
    local downloading = bridge.get_local_download_progress()
    eval_js("updateLocalDownloadProgress(" .. json_encode(downloading) .. ")")
end

function M.pushAll()
    M.pushState()
    M.pushSettings()
    M.pushModels()
    M.pushHistory()
    M.pushAuth()
    M.pushUpdateStatus()
    M.pushLocalServer()
    M.pushLocalModels()
end

-- ── Handle messages from JS ─────────────────────────────────────────────────

local function handle_message(msg)
    if not bridge then return end
    local body = msg.body
    if type(body) == "string" then
        body = json_decode(body)
    end
    if not body or not body.action then return end

    local action = body.action
    local data = body.data or {}

    if action == "init" then
        -- JS page loaded and requests initial data
        panel_ready = true
        M.pushAll()
        return

    elseif action == "poll" then
        -- JS periodic poll for live state updates
        M.pushState()
        return

    elseif action == "action" then
        local cmd = data.command
        if cmd == "toggle" or cmd == "stop" then
            bridge.run_whisper(cmd)
        elseif cmd == "reloadHammerspoon" then
            hs.alert.show("Reloading…")
            hs.timer.doAfter(0.5, function() hs.reload() end)
        elseif cmd == "hotkeyCapture" then
            if data.active then
                bridge.disable_hotkeys()
            else
                bridge.enable_hotkeys()
            end
        elseif cmd == "auth" then
            -- Start device flow
            hs.alert.show("Authenticating with GitHub…")
            local authUserCode = nil
            local authOk = false
            local task = hs.task.new(bridge.whisper_script, function(exitCode, stdout, stderr)
                if authOk then
                    hs.alert.show("✓ Copilot authenticated!")
                    bridge.update_conf_value("WHISPER_POST_PROCESS", "clean")
                    eval_js("showAuthSuccess()")
                    hs.timer.doAfter(3, function()
                        M.pushAuth()
                        M.pushSettings()
                    end)
                else
                    local err = (stderr or ""):match("ERROR: (.+)")
                    hs.alert.show(err or "Authentication failed")
                end
            end, function(task, stdoutChunk, stderrChunk)
                -- Streaming callback: capture output as it arrives
                if stdoutChunk then
                    if not authUserCode then
                        local code = stdoutChunk:match("USER_CODE=(%S+)")
                        if code then
                            authUserCode = code
                            hs.alert.show("Code " .. code .. " copied to clipboard — paste it on GitHub", 8)
                            eval_js("updateAuth(" .. json_encode({ authenticated = false, userCode = code }) .. ")")
                        end
                    end
                    if stdoutChunk:match("AUTH_OK") then
                        authOk = true
                    end
                end
                return true
            end, { "auth" })
            if task then
                task:start()
                hs.timer.doAfter(2, function()
                    hs.urlevent.openURL("https://github.com/login/device")
                end)
            end
        elseif cmd == "localServer" then
            local sub = data.subcommand
            if sub == "start" then
                bridge.local_server_start(function(ok, msg)
                    if not ok then
                        hs.alert.show("Failed: " .. (msg or "unknown error"))
                    end
                    M.pushLocalServer()
                end)
            elseif sub == "stop" then
                bridge.local_server_stop(function()
                    M.pushLocalServer()
                end)
            end
        elseif cmd == "selfUpdate" then
            bridge.self_update(function(success, output)
                if success then
                    hs.alert.show("✓ Update complete — reloading")
                    hs.timer.doAfter(1, function() hs.reload() end)
                else
                    hs.alert.show("Update failed")
                    eval_js('updateUpdateStatus({available:false})')
                end
            end)
        end

    elseif action == "setSetting" then
        local key = data.key
        local value = data.value
        -- Only allow known config keys
        local allowed = {
            WHISPER_NOTIFICATIONS = true,
            WHISPER_SOUNDS = true,
            WHISPER_AUTO_ENTER = true,
            WHISPER_RESTORE_CLIPBOARD = true,
            WHISPER_POST_PROCESS = true,
            WHISPER_PP_BACKEND = true,
            WHISPER_CLAUDE_API_KEY = true,
            WHISPER_CUSTOM_VOCAB = true,
            WHISPER_HOTKEY_TOGGLE = true,
            WHISPER_HOTKEY_STOP = true,
            WHISPER_HOTKEY_PANEL = true,
        }
        if key and value and allowed[key] then
            bridge.update_conf_value(key, value)
            M.pushSettings()
            if key == "WHISPER_PP_BACKEND" then
                M.pushAuth()
            end
        end

    elseif action == "setModel" then
        if data.model then
            bridge.set_active_model(data.model)
            -- Refresh model list in panel after switch
            hs.timer.doAfter(0.3, function() M.pushModels() end)
        end

    elseif action == "downloadModel" then
        if data.model then
            bridge.download_model(data.model)
        end

    elseif action == "downloadLocalModel" then
        if data.model then
            bridge.download_local_model(data.model)
        end

    elseif action == "selectLocalModel" then
        if data.filename then
            bridge.select_local_model(data.filename)
            hs.timer.doAfter(0.3, function()
                M.pushLocalServer()
                M.pushLocalModels()
            end)
        end

    elseif action == "copyHistory" then
        if data.text then
            hs.pasteboard.setContents(data.text)
            hs.alert.show("Copied to clipboard")
        end

    elseif action == "clearCopilotToken" then
        local task = hs.task.new(bridge.whisper_script, function(exitCode, stdout, _)
            if exitCode == 0 then
                hs.alert.show("Copilot token cleared")
                M.pushAuth()
                eval_js("updateSystemSettings(" .. json_encode({ copilotCleared = true }) .. ")")
            end
        end, { "clear-copilot-token" })
        if task then task:start() end

    elseif action == "clearClaudeKey" then
        local task = hs.task.new(bridge.whisper_script, function(exitCode, stdout, _)
            if exitCode == 0 then
                hs.alert.show("Claude API key cleared")
                M.pushSettings()
                eval_js("updateSystemSettings(" .. json_encode({ claudeCleared = true }) .. ")")
            end
        end, { "clear-claude-key" })
        if task then task:start() end

    elseif action == "importCustomModel" then
        if data.url then
            local args = { "import-custom-model", data.url }
            if data.name and data.name ~= "" then
                args[#args + 1] = data.name
            end
            hs.alert.show("Importing model…")
            local importWarnings = {}
            local importDone = false
            local importExists = false
            local task = hs.task.new(bridge.whisper_script, function(exitCode, stdout, stderr)
                -- Stop progress timer
                if custom_import_timer then
                    custom_import_timer:stop()
                    custom_import_timer = nil
                end
                if exitCode == 0 and (importDone or (stdout or ""):match("done:")) then
                    local msg = "✓ Model imported"
                    if #importWarnings > 0 then
                        msg = msg .. " (with warnings)"
                    end
                    hs.alert.show(msg)
                    eval_js("updateSystemSettings(" .. json_encode({ importDone = true, importWarnings = importWarnings }) .. ")")
                elseif importExists or (stdout or ""):match("already_exists:") then
                    hs.alert.show("Model already exists")
                    eval_js("updateSystemSettings(" .. json_encode({ importDone = true }) .. ")")
                else
                    local err = (stderr or ""):match("error:(.+)")
                    hs.alert.show(err or "Import failed")
                    eval_js("updateSystemSettings(" .. json_encode({ importError = err or "Import failed", importWarnings = importWarnings }) .. ")")
                end
                M.pushLocalModels()
            end, function(task, stdoutChunk, stderrChunk)
                -- Streaming: capture status flags, warnings, and start download progress
                if stdoutChunk then
                    if stdoutChunk:match("done:") then importDone = true end
                    if stdoutChunk:match("already_exists:") then importExists = true end
                    for w in stdoutChunk:gmatch("warn:([^\n]+)") do
                        importWarnings[#importWarnings + 1] = w
                        hs.alert.show("⚠ " .. w, 4)
                    end
                    -- Capture downloading line and start progress timer
                    local dl_name, dl_file, dl_label, dl_total = stdoutChunk:match("downloading:([^|]+)|([^|]+)|([^|]+)|([^\n]+)")
                    if dl_file then
                        local part_path = bridge.script_dir .. "/models/" .. dl_file .. ".part"
                        local total_bytes = tonumber(dl_total) or 0
                        if custom_import_timer then custom_import_timer:stop() end
                        custom_import_timer = hs.timer.doEvery(1.5, function()
                            local f = io.open(part_path, "r")
                            if f then
                                local size = f:seek("end")
                                f:close()
                                if size then
                                    local mb = size / (1024 * 1024)
                                    local progress_text
                                    if mb >= 1024 then
                                        progress_text = string.format("%.1f GB", mb / 1024)
                                    else
                                        progress_text = string.format("%.0f MB", mb)
                                    end
                                    local pct = 0
                                    if total_bytes > 0 then
                                        pct = math.min(100, math.floor(size / total_bytes * 100))
                                    end
                                    eval_js("updateSystemSettings(" .. json_encode({
                                        importProgress = progress_text,
                                        importTotal = dl_label,
                                        importPct = pct,
                                    }) .. ")")
                                end
                            end
                        end)
                    end
                end
                return true
            end, args)
            if task then task:start() end
        end
    end
end

-- ── Panel position: bottom-right of main screen ─────────────────────────────

local function panel_frame()
    local screen = hs.screen.mainScreen():frame()
    return hs.geometry.rect(
        screen.x + screen.w - PANEL_W - 16,
        screen.y + screen.h - PANEL_H - 16,
        PANEL_W,
        PANEL_H
    )
end

-- ── Create / Toggle ─────────────────────────────────────────────────────────

local function create_webview()
    if webview then return end

    controller = hs.webview.usercontent.new("whisper")
    controller:setCallback(function(msg)
        handle_message(msg)
    end)

    webview = hs.webview.new(panel_frame(), { developerExtrasEnabled = true }, controller)
    webview:windowTitle("Careless Whisper")
    webview:windowStyle({"titled", "closable", "resizable", "utility"})
    webview:level(hs.drawing.windowLevels.floating)
    webview:allowTextEntry(true)
    webview:allowNewWindows(false)
    webview:closeOnEscape(true)
    webview:deleteOnClose(false)
    webview:bringToFront(true)

    -- Navigation callback to detect when HTML is loaded
    webview:navigationCallback(function(navAction, wv, navID, navError)
        if navAction == "didFinishNavigation" then
            panel_ready = true
            M.pushAll()
        end
    end)

    -- Load HTML content directly (avoids file:// restrictions)
    local html_path = bridge.script_dir .. "/whisper_panel.html"
    local f = io.open(html_path, "r")
    if f then
        local html = f:read("*a")
        f:close()
        webview:html(html)
    end

    -- Fallback: if neither nav callback nor JS init fires, push after delay
    hs.timer.doAfter(1.5, function()
        if webview and not panel_ready then
            panel_ready = true
            M.pushAll()
        end
    end)
end

function M.toggle()
    if not bridge then return end

    if webview then
        if webview:isVisible() then
            webview:hide()
            -- Safety: re-enable hotkeys in case capture was active
            bridge.enable_hotkeys()
        else
            webview:frame(panel_frame())
            webview:show()
            webview:bringToFront(true)
            -- Always refresh data when showing
            hs.timer.doAfter(0.2, function()
                if panel_ready then M.pushAll() end
            end)
        end
    else
        create_webview()
        webview:show()
        webview:bringToFront(true)
    end
end

function M.isVisible()
    return webview and webview:isVisible() or false
end

function M.destroy()
    panel_ready = false
    if custom_import_timer then
        custom_import_timer:stop()
        custom_import_timer = nil
    end
    if webview then
        webview:delete()
        webview = nil
    end
    controller = nil
end

-- ── Init ────────────────────────────────────────────────────────────────────

function M.init(b)
    bridge = b
end

return M
