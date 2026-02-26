-- @description ReaPyTapeSim3 UI
-- @author ZS
-- @version 1.4
-- @provides
--   presets/Default.ini
--   tape_sim3.py
--   requirements.txt
--   README.md
-- @about
--   # Analog Tape Simulator
--   A highly realistic, procedural analog tape degradation simulator bridging Python DSP with ReaImGui.

if not reaper.ImGui_CreateContext then
    reaper.ShowMessageBox("ReaImGui is required for this script.\nPlease install it via ReaPack.", "Missing Dependency", 0)
    return
end

local ctx = reaper.ImGui_CreateContext('ReaPyTapeSim3')

-- Formats
local tape_type_idx = 1 -- 1 = A, 2 = B
local format_list = {"WAV", "MP3"}
local format_idx = 1
local sr_list = {"44100", "48000", "88200", "96000"}
local sr_idx = 2
local bd_list = {"16", "24", "32"}
local bd_idx = 2
local br_list = {"128k", "192k", "256k", "320k"}
local br_idx = 4

-- DSP Parameters
local sat_amt = 25.0
local wow_rate = 1.0
local wow_depth = 20.0
local wow_var = 10.0
local flutter_rate = 15.0
local flutter_depth = 20.0
local flutter_var = 10.0

local noise_types = {"Brown", "Pink", "White"}
local noise_type_idx = 2 -- defaults to Pink
local noise_vol = 10.0

local dropouts_en = true
local drop_filter_vol = 50.0
local drop_doubling = 30.0
local drop_delay_drift = 30.0
local drop_prob = 20.0

-- Utility variables
local input_file = ""
local target_item = nil
local processing = false
local process_triggered = false
local processing_frames = 0
local generated_files = {}
local last_cleanup_time = 0

-- Locate script and preset paths securely
local _, script_file = reaper.get_action_context()
local script_path = script_file:match("^(.*[/\\])")
if not script_path then script_path = "" end
local py_script = script_path .. "tape_sim3.py"

local sep = (reaper.GetOS():match("Win")) and "\\" or "/"
local preset_dir = script_path .. "presets" .. sep
reaper.RecursiveCreateDirectory(preset_dir, 0) -- Auto-create presets folder if it doesn't exist

-- Preset System Variables
local presets_list = {}
local selected_preset_idx = 0
local selected_preset_name = "Select a Preset..."
local save_preset_name = ""


-- ==========================================
-- PRESET SYSTEM
-- ==========================================

function ScanPresets()
    presets_list = {}
    local i = 0
    while true do
        local file = reaper.EnumerateFiles(preset_dir, i)
        if not file then break end
        if file:match("%.ini$") then
            local name = file:gsub("%.ini$", "")
            table.insert(presets_list, {name = name, filename = file})
        end
        i = i + 1
    end
end

function LoadPreset(filename, display_name)
    local path = preset_dir .. filename
    local f = io.open(path, "r")
    if not f then return end
    for line in f:lines() do
        local k, v = line:match("^([%w_]+)%s*=%s*(.*)$")
        if k and v then
            if k == "tape_type_idx" then tape_type_idx = tonumber(v) or 1
            elseif k == "sat_amt" then sat_amt = tonumber(v) or 25.0
            elseif k == "wow_rate" then wow_rate = tonumber(v) or 1.0
            elseif k == "wow_depth" then wow_depth = tonumber(v) or 20.0
            elseif k == "wow_var" then wow_var = tonumber(v) or 10.0
            elseif k == "flutter_rate" then flutter_rate = tonumber(v) or 15.0
            elseif k == "flutter_depth" then flutter_depth = tonumber(v) or 20.0
            elseif k == "flutter_var" then flutter_var = tonumber(v) or 10.0
            elseif k == "noise_type_idx" then noise_type_idx = tonumber(v) or 2
            elseif k == "noise_vol" then noise_vol = tonumber(v) or 10.0
            elseif k == "dropouts_en" then dropouts_en = (v == "true")
            elseif k == "drop_filter_vol" then drop_filter_vol = tonumber(v) or 50.0
            elseif k == "drop_doubling" then drop_doubling = tonumber(v) or 30.0
            elseif k == "drop_delay_drift" then drop_delay_drift = tonumber(v) or 30.0
            elseif k == "drop_prob" then drop_prob = tonumber(v) or 20.0
            end
        end
    end
    f:close()
    selected_preset_name = display_name
end

function SavePreset(name)
    local path = preset_dir .. name .. ".ini"
    local f = io.open(path, "w")
    if not f then 
        reaper.ShowMessageBox("Failed to save preset to:\n" .. path, "Write Error", 0)
        return 
    end
    
    f:write("tape_type_idx=" .. tostring(tape_type_idx) .. "\n")
    f:write("sat_amt=" .. tostring(sat_amt) .. "\n")
    f:write("wow_rate=" .. tostring(wow_rate) .. "\n")
    f:write("wow_depth=" .. tostring(wow_depth) .. "\n")
    f:write("wow_var=" .. tostring(wow_var) .. "\n")
    f:write("flutter_rate=" .. tostring(flutter_rate) .. "\n")
    f:write("flutter_depth=" .. tostring(flutter_depth) .. "\n")
    f:write("flutter_var=" .. tostring(flutter_var) .. "\n")
    f:write("noise_type_idx=" .. tostring(noise_type_idx) .. "\n")
    f:write("noise_vol=" .. tostring(noise_vol) .. "\n")
    f:write("dropouts_en=" .. tostring(dropouts_en) .. "\n")
    f:write("drop_filter_vol=" .. tostring(drop_filter_vol) .. "\n")
    f:write("drop_doubling=" .. tostring(drop_doubling) .. "\n")
    f:write("drop_delay_drift=" .. tostring(drop_delay_drift) .. "\n")
    f:write("drop_prob=" .. tostring(drop_prob) .. "\n")
    
    f:close()
    ScanPresets()
    
    selected_preset_name = name
    for i, p in ipairs(presets_list) do
        if p.name == name then
            selected_preset_idx = i
            break
        end
    end
end

ScanPresets()

-- ==========================================
-- FILE PATH & CLEANUP UTILS
-- ==========================================

function EnsureTrailingSlash(path)
    if not path or path == "" then return "" end
    if not path:match("[\\/]$") then return path .. sep end
    return path
end

function NormalizePath(p)
    if not p then return "" end
    return p:gsub("\\", "/"):lower()
end

function GetReaperMediaDir()
    local path = reaper.GetProjectPath("")
    if path and path ~= "" then return EnsureTrailingSlash(path) end
    
    local ini_path = reaper.get_ini_file()
    local f = io.open(ini_path, "r")
    if f then
        for line in f:lines() do
            local match = line:match("^defrecpath=(.*)")
            if match and match ~= "" then
                f:close()
                return EnsureTrailingSlash(match:gsub("[\r\n]", ""))
            end
        end
        f:close()
    end
    
    local os_name = reaper.GetOS()
    if os_name:match("Win") then
        local userprofile = os.getenv("USERPROFILE")
        if userprofile then return EnsureTrailingSlash(userprofile .. "\\Documents\\REAPER Media") end
    else
        local home = os.getenv("HOME")
        if home then return EnsureTrailingSlash(home .. "/Documents/REAPER Media") end
    end
    return EnsureTrailingSlash(reaper.GetResourcePath() .. "/Media")
end

function GetActiveProjectFiles()
    local active_files = {}
    local num_items = reaper.CountMediaItems(0)
    for i = 0, num_items - 1 do
        local item = reaper.GetMediaItem(0, i)
        local num_takes = reaper.CountTakes(item)
        for j = 0, num_takes - 1 do
            local take = reaper.GetTake(item, j)
            if reaper.ValidatePtr(take, "MediaItem_Take*") then
                local src = reaper.GetMediaItemTake_Source(take)
                if src then
                    local src_path = reaper.GetMediaSourceFileName(src, "")
                    if src_path and src_path ~= "" then
                        active_files[NormalizePath(src_path)] = true
                    end
                end
            end
        end
    end
    return active_files
end

function PerformJunkCleaning()
    local now = reaper.time_precise()
    if now - last_cleanup_time < 3.0 then return end
    last_cleanup_time = now

    if #generated_files == 0 then return end

    local _, proj_path = reaper.EnumProjects(-1, "")
    if proj_path == "" then
        local active_files = GetActiveProjectFiles()
        for i = #generated_files, 1, -1 do
            local file = generated_files[i]
            if reaper.file_exists(file) then
                if not active_files[NormalizePath(file)] then
                    os.remove(file)
                    table.remove(generated_files, i)
                end
            else
                table.remove(generated_files, i)
            end
        end
    end
end


-- ==========================================
-- MAIN PROCESSING
-- ==========================================

function ExecuteProcessing()
    local ext = format_idx == 1 and "wav" or "mp3"
    
    local out_dir = GetReaperMediaDir()
    local base_name = input_file:match("([^\\/]+)%.%w+$") or "Audio"
    local timestamp = os.time()
    local rand = math.random(1000, 9999)
    local out_file = out_dir .. base_name .. "_TapeSim_" .. timestamp .. "_" .. rand .. "." .. ext
    
    local drop_val = dropouts_en and 1 or 0
    local noise_str = string.lower(noise_types[noise_type_idx])

    local cmd = string.format('python "%s" -i "%s" -o "%s" -t %s --out-format %s --samplerate %s',
        py_script, input_file, out_file, tape_type_idx == 1 and "A" or "B", ext, sr_list[sr_idx])
        
    cmd = cmd .. string.format(' --sat-amt %.1f --wow-rate %.2f --wow-depth %.1f --wow-var %.1f', sat_amt, wow_rate, wow_depth, wow_var)
    cmd = cmd .. string.format(' --flutter-rate %.1f --flutter-depth %.1f --flutter-var %.1f', flutter_rate, flutter_depth, flutter_var)
    cmd = cmd .. string.format(' --noise-type %s --noise-vol %.1f', noise_str, noise_vol)
    cmd = cmd .. string.format(' --dropouts %d --drop-filter-vol %.1f --drop-doubling %.1f --drop-delay-drift %.1f --drop-prob %.1f',
                               drop_val, drop_filter_vol, drop_doubling, drop_delay_drift, drop_prob)

    if format_idx == 1 then
        cmd = cmd .. string.format(' --bitdepth %s', bd_list[bd_idx])
    else
        cmd = cmd .. string.format(' --bitrate %s', br_list[br_idx])
    end

    local handle = io.popen(cmd .. ' 2>&1')
    local result = ""
    if handle then
        result = handle:read("*a")
        handle:close()
    end

    if not reaper.file_exists(out_file) then
        reaper.ShowConsoleMsg("--- TAPE SIMULATOR PYTHON ERROR ---\n\n")
        reaper.ShowConsoleMsg("Command run:\n" .. cmd .. "\n\n")
        reaper.ShowConsoleMsg("Output/Error Log:\n" .. (result or "None") .. "\n")
        reaper.ShowMessageBox("Processing failed!\n\nThe audio file was not created. Check the REAPER Console for the crash log.", "Processing Error", 0)
        processing = false
        return
    end

    table.insert(generated_files, out_file)

    if target_item and reaper.ValidatePtr(target_item, "MediaItem*") then
        local take = reaper.AddTakeToMediaItem(target_item)
        local src = reaper.PCM_Source_CreateFromFile(out_file)
        reaper.SetMediaItemTake_Source(take, src)
        reaper.SetActiveTake(take)
        reaper.UpdateItemInProject(target_item)
    else
        reaper.InsertTrackAtIndex(0, true)
        local track = reaper.GetTrack(0, 0)
        reaper.GetSetMediaTrackInfo_String(track, "P_NAME", "Tape Sim Output", true)
        local item = reaper.AddMediaItemToTrack(track)
        reaper.SetMediaItemInfo_Value(item, "D_POSITION", 0)
        
        local take = reaper.AddTakeToMediaItem(item)
        local src = reaper.PCM_Source_CreateFromFile(out_file)
        reaper.SetMediaItemTake_Source(take, src)
        
        local length = reaper.GetMediaSourceLength(src)
        reaper.SetMediaItemInfo_Value(item, "D_LENGTH", length)
        reaper.UpdateItemInProject(item)
    end
    
    reaper.Main_OnCommand(40047, 0)
    reaper.UpdateArrange()
    
    input_file = ""
    target_item = nil
end


-- ==========================================
-- UI & LOOPS
-- ==========================================

function DrawUI()
    local visible, open = reaper.ImGui_Begin(ctx, 'ReaPyTapeSim3', true, reaper.ImGui_WindowFlags_AlwaysAutoResize())
    if not visible then return open end

    -- Layout Dimensions
    local col1_w = 340
    local slider_w = 200
    local rv

    -- ================= LEFT COLUMN (System) =================
    reaper.ImGui_BeginGroup(ctx)
    
    reaper.ImGui_Text(ctx, "INPUT AUDIO")
    reaper.ImGui_Separator(ctx)
    
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(), 0x333333FF)
    local btn_text = input_file == "" and "Click to Browse File\n\n(or Drag & Drop File Here)" or "File Loaded:\n" .. input_file:match("([^\\/]+)$")
    if reaper.ImGui_Button(ctx, btn_text, col1_w, 70) then
        local retval, filename = reaper.GetUserFileNameForRead("", "Select Audio File", "")
        if retval then
            input_file = filename
            target_item = nil 
        end
    end
    reaper.ImGui_PopStyleColor(ctx)

    if reaper.ImGui_BeginDragDropTarget(ctx) then
        local rv_d, count = reaper.ImGui_AcceptDragDropPayloadFiles(ctx)
        if rv_d and count > 0 then
            local ok, filename = reaper.ImGui_GetDragDropPayloadFile(ctx, 0)
            if ok and filename ~= "" then
                input_file = filename
                target_item = nil
            end
        end
        reaper.ImGui_EndDragDropTarget(ctx)
    end
    
    if reaper.ImGui_Button(ctx, "Grab Selected Item from REAPER Timeline", col1_w, 25) then
        local item = reaper.GetSelectedMediaItem(0, 0)
        if item then
            local take = reaper.GetActiveTake(item)
            if take then
                local src = reaper.GetMediaItemTake_Source(take)
                local path = reaper.GetMediaSourceFileName(src, "")
                if path ~= "" then
                    input_file = path
                    target_item = item
                end
            end
        end
    end
    
    reaper.ImGui_Dummy(ctx, 0, 10)
    
    reaper.ImGui_Text(ctx, "PRESETS")
    reaper.ImGui_Separator(ctx)
    
    reaper.ImGui_PushItemWidth(ctx, 205)
    if reaper.ImGui_BeginCombo(ctx, "##presets", selected_preset_name) then
        for i, p in ipairs(presets_list) do
            if reaper.ImGui_Selectable(ctx, p.name, selected_preset_idx == i) then
                selected_preset_idx = i
                LoadPreset(p.filename, p.name)
            end
        end
        reaper.ImGui_EndCombo(ctx)
    end
    reaper.ImGui_PopItemWidth(ctx)
    
    reaper.ImGui_SameLine(ctx)
    if reaper.ImGui_Button(ctx, "Save") then
        reaper.ImGui_OpenPopup(ctx, "Save Preset Popup")
    end
    reaper.ImGui_SameLine(ctx)
    if reaper.ImGui_Button(ctx, "Rescan") then
        ScanPresets()
    end

    reaper.ImGui_Dummy(ctx, 0, 10)
    
    reaper.ImGui_Text(ctx, "OUTPUT FORMAT")
    reaper.ImGui_Separator(ctx)

    reaper.ImGui_PushItemWidth(ctx, col1_w - 90) -- Leaves space so Labels fit naturally
    if reaper.ImGui_BeginCombo(ctx, "File Format", format_list[format_idx]) then
        for i, v in ipairs(format_list) do
            if reaper.ImGui_Selectable(ctx, v, format_idx == i) then format_idx = i end
        end
        reaper.ImGui_EndCombo(ctx)
    end

    if reaper.ImGui_BeginCombo(ctx, "Sample Rate", sr_list[sr_idx]) then
        for i, v in ipairs(sr_list) do
            if reaper.ImGui_Selectable(ctx, v, sr_idx == i) then sr_idx = i end
        end
        reaper.ImGui_EndCombo(ctx)
    end
    
    if format_idx == 1 then
        local current_label = bd_list[bd_idx] == "32" and "32-bit float" or (bd_list[bd_idx] .. "-bit")
        if reaper.ImGui_BeginCombo(ctx, "Bit Depth", current_label) then
            for i, v in ipairs(bd_list) do
                local label = v == "32" and "32-bit float" or (v .. "-bit")
                if reaper.ImGui_Selectable(ctx, label, bd_idx == i) then bd_idx = i end
            end
            reaper.ImGui_EndCombo(ctx)
        end
    else
        if reaper.ImGui_BeginCombo(ctx, "Bitrate", br_list[br_idx]) then
            for i, v in ipairs(br_list) do
                if reaper.ImGui_Selectable(ctx, v, br_idx == i) then br_idx = i end
            end
            reaper.ImGui_EndCombo(ctx)
        end
    end
    reaper.ImGui_PopItemWidth(ctx)

    reaper.ImGui_Dummy(ctx, 0, 15)
    
    -- Processing Buttons dynamically adjust their look to fit column cleanly
    if processing then
        reaper.ImGui_BeginDisabled(ctx)
        reaper.ImGui_Button(ctx, "Processing... REAPER may freeze briefly.", col1_w, 45)
        reaper.ImGui_EndDisabled(ctx)
        
        processing_frames = processing_frames + 1
        if processing_frames > 2 then
            ExecuteProcessing()
            processing = false
            process_triggered = false
        end
    else
        if input_file ~= "" then
            reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(), 0x228B22FF)
            if reaper.ImGui_Button(ctx, "PROCESS OFFLINE", col1_w, 45) then
                process_triggered = true
                processing_frames = 0
            end
            reaper.ImGui_PopStyleColor(ctx)
        else
            reaper.ImGui_BeginDisabled(ctx)
            reaper.ImGui_Button(ctx, "Awaiting file input...", col1_w, 45)
            reaper.ImGui_EndDisabled(ctx)
        end
    end
    
    if process_triggered and not processing then processing = true end

    reaper.ImGui_EndGroup(ctx)
    -- ================= END LEFT COLUMN =================

    reaper.ImGui_SameLine(ctx, 0, 30) -- Empty horizontal margin between the two columns

    -- ================= RIGHT COLUMN (DSP Parameters) =================
    reaper.ImGui_BeginGroup(ctx)
    reaper.ImGui_PushItemWidth(ctx, slider_w)
    
    reaper.ImGui_Text(ctx, "TAPE PROPERTIES")
    reaper.ImGui_Separator(ctx)
    
    reaper.ImGui_Text(ctx, "Tape Type:")
    reaper.ImGui_SameLine(ctx)
    if reaper.ImGui_RadioButton(ctx, "Cassette", tape_type_idx == 1) then tape_type_idx = 1 end
    reaper.ImGui_SameLine(ctx)
    if reaper.ImGui_RadioButton(ctx, "VHS", tape_type_idx == 2) then tape_type_idx = 2 end
    
    reaper.ImGui_Dummy(ctx, 0, 2)
    rv, sat_amt = reaper.ImGui_SliderDouble(ctx, "Saturation Amount (%)", sat_amt, 0.0, 100.0, "%.1f")
    
    reaper.ImGui_Dummy(ctx, 0, 10)
    
    reaper.ImGui_Text(ctx, "TIME-WARP (WOW & FLUTTER)")
    reaper.ImGui_Separator(ctx)
    
    rv, wow_rate = reaper.ImGui_SliderDouble(ctx, "Wow Rate (Hz)", wow_rate, 0.1, 5.0, "%.2f")
    rv, wow_depth = reaper.ImGui_SliderDouble(ctx, "Wow Depth (%)", wow_depth, 0.0, 100.0, "%.1f")
    rv, wow_var = reaper.ImGui_SliderDouble(ctx, "Wow Randomness (%)", wow_var, 0.0, 100.0, "%.1f")
    
    reaper.ImGui_Dummy(ctx, 0, 5)
    
    rv, flutter_rate = reaper.ImGui_SliderDouble(ctx, "Flutter Rate (Hz)", flutter_rate, 5.0, 30.0, "%.1f")
    rv, flutter_depth = reaper.ImGui_SliderDouble(ctx, "Flutter Depth (%)", flutter_depth, 0.0, 100.0, "%.1f")
    rv, flutter_var = reaper.ImGui_SliderDouble(ctx, "Flutter Randomness (%)", flutter_var, 0.0, 100.0, "%.1f")

    reaper.ImGui_Dummy(ctx, 0, 10)
    
    reaper.ImGui_Text(ctx, "NOISE & DROPOUTS")
    reaper.ImGui_Separator(ctx)
    
    if reaper.ImGui_BeginCombo(ctx, "Noise Type", noise_types[noise_type_idx]) then
        for i, v in ipairs(noise_types) do
            if reaper.ImGui_Selectable(ctx, v, noise_type_idx == i) then noise_type_idx = i end
        end
        reaper.ImGui_EndCombo(ctx)
    end
    rv, noise_vol = reaper.ImGui_SliderDouble(ctx, "Noise Volume (%)", noise_vol, 0.0, 100.0, "%.1f")

    reaper.ImGui_Dummy(ctx, 0, 5)
    
    rv, dropouts_en = reaper.ImGui_Checkbox(ctx, "Enable Dropouts", dropouts_en)
    
    if not dropouts_en then reaper.ImGui_BeginDisabled(ctx) end
    rv, drop_filter_vol = reaper.ImGui_SliderDouble(ctx, "Filter & Vol Drop Depth (%)", drop_filter_vol, 0.0, 100.0, "%.1f")
    rv, drop_doubling = reaper.ImGui_SliderDouble(ctx, "Doubling Depth (%)", drop_doubling, 0.0, 100.0, "%.1f")
    rv, drop_delay_drift = reaper.ImGui_SliderDouble(ctx, "Drift Depth (%)", drop_delay_drift, 0.0, 100.0, "%.1f")
    rv, drop_prob = reaper.ImGui_SliderDouble(ctx, "Dropout Probability (%)", drop_prob, 0.0, 100.0, "%.1f")
    if not dropouts_en then reaper.ImGui_EndDisabled(ctx) end

    reaper.ImGui_PopItemWidth(ctx)
    reaper.ImGui_EndGroup(ctx)
    -- ================= END RIGHT COLUMN =================

    -- Modal behaves normally overlaying over the UI
    if reaper.ImGui_BeginPopupModal(ctx, "Save Preset Popup", nil, reaper.ImGui_WindowFlags_AlwaysAutoResize()) then
        reaper.ImGui_Text(ctx, "Enter new preset name:")
        
        if reaper.ImGui_IsWindowAppearing(ctx) then
            reaper.ImGui_SetKeyboardFocusHere(ctx)
        end
        
        local rv_text, new_text = reaper.ImGui_InputText(ctx, "##presetname", save_preset_name)
        save_preset_name = new_text
        
        reaper.ImGui_Dummy(ctx, 0, 5)
        
        if reaper.ImGui_Button(ctx, "Save", 120, 0) then
            local clean_name = save_preset_name:match("^%s*(.-)%s*$")
            if clean_name and clean_name ~= "" then
                SavePreset(clean_name)
                reaper.ImGui_CloseCurrentPopup(ctx)
                save_preset_name = ""
            end
        end
        
        reaper.ImGui_SameLine(ctx)
        if reaper.ImGui_Button(ctx, "Cancel", 120, 0) then
            reaper.ImGui_CloseCurrentPopup(ctx)
            save_preset_name = ""
        end
        
        reaper.ImGui_EndPopup(ctx)
    end

    reaper.ImGui_End(ctx)
    return open
end

function loop()
    PerformJunkCleaning()
    local open = DrawUI()
    if open then
        reaper.defer(loop)
    end
end

reaper.atexit(function()
    local _, proj_path = reaper.EnumProjects(-1, "")
    if proj_path == "" then
        local active_files = GetActiveProjectFiles()
        for _, file in ipairs(generated_files) do
            if reaper.file_exists(file) and not active_files[NormalizePath(file)] then
                os.remove(file)
            end
        end
    end
end)

reaper.defer(loop)
