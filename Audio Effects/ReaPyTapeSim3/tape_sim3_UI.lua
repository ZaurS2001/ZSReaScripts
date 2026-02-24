-- @description ReaPyTapeSim3 UI
-- @author ZS
-- @version 1.3
-- @provides
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

-- Variables
local age = 50.0
local tape_type_idx = 1 -- 1 = A, 2 = B

local format_list = {"WAV", "MP3"}
local format_idx = 1 -- 1 = WAV, 2 = MP3

local sr_list = {"44100", "48000", "88200", "96000"}
local sr_idx = 2 -- default 48000

local bd_list = {"16", "24", "32"}
local bd_idx = 2 -- default 24

local br_list = {"128k", "192k", "256k", "320k"}
local br_idx = 4 -- default 320k

local input_file = ""
local target_item = nil
local processing = false
local process_triggered = false
local processing_frames = 0

local generated_files = {}
local last_cleanup_time = 0

-- Locate python script
local script_path = debug.getinfo(1, "S").source:match("@?(.*[\\/])")
if not script_path then script_path = "" end
local py_script = script_path .. "tape_sim3.py"


-- ==========================================
-- FILE PATH & CLEANUP UTILS
-- ==========================================

function EnsureTrailingSlash(path)
    if not path or path == "" then return "" end
    local sep = (reaper.GetOS():match("Win")) and "\\" or "/"
    if not path:match("[\\/]$") then return path .. sep end
    return path
end

function NormalizePath(p)
    if not p then return "" end
    return p:gsub("\\", "/"):lower()
end

function GetReaperMediaDir()
    -- 1. Get exact path for the current project (handles both saved & user default preferences)
    local path = reaper.GetProjectPath("")
    if path and path ~= "" then
        return EnsureTrailingSlash(path)
    end
    
    -- 2. Hard Fallback to explicit defrecpath in reaper.ini
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
    
    -- 3. Stock fallback
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

    -- Check if project is unsaved
    local _, proj_path = reaper.EnumProjects(-1, "")
    if proj_path == "" then
        local active_files = GetActiveProjectFiles()
        
        -- Delete any generated files that aren't actively on the timeline
        for i = #generated_files, 1, -1 do
            local file = generated_files[i]
            if reaper.file_exists(file) then
                if not active_files[NormalizePath(file)] then
                    os.remove(file)
                    table.remove(generated_files, i)
                end
            else
                -- If it was manually deleted or REAPER moved it (via save option), drop tracking
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
    -- Creates a unique file targeting User's intended Media Directory!
    local out_file = out_dir .. base_name .. "_TapeSim_" .. timestamp .. "_" .. rand .. "." .. ext
    
    -- Format CLI command
    local cmd = string.format('python "%s" -i "%s" -o "%s" -a %f -t %s --out-format %s --samplerate %s',
        py_script, input_file, out_file, age, tape_type_idx == 1 and "A" or "B", ext, sr_list[sr_idx])
        
    if format_idx == 1 then
        cmd = cmd .. string.format(' --bitdepth %s', bd_list[bd_idx])
    else
        cmd = cmd .. string.format(' --bitrate %s', br_list[br_idx])
    end

    -- Run processing and capture all stdout/stderr to log errors
    local handle = io.popen(cmd .. ' 2>&1')
    local result = ""
    if handle then
        result = handle:read("*a")
        handle:close()
    end

    -- ERROR CHECKING: Did Python actually create the file?
    if not reaper.file_exists(out_file) then
        reaper.ShowConsoleMsg("--- TAPE SIMULATOR PYTHON ERROR ---\n\n")
        reaper.ShowConsoleMsg("Command run:\n" .. cmd .. "\n\n")
        reaper.ShowConsoleMsg("Output/Error Log:\n" .. (result or "None") .. "\n")
        reaper.ShowMessageBox("Processing failed!\n\nThe audio file was not created. Check the REAPER Console for the crash log.", "Processing Error", 0)
        
        processing = false
        return
    end

    table.insert(generated_files, out_file)

    -- Handle output to Reaper depending on source
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
    
    reaper.Main_OnCommand(40047, 0) -- Peaks: Build any missing peaks
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

    -- 1. DROP / BROWSE AREA
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(), 0x333333FF)
    
    local btn_text = input_file == "" and "Click to Browse File\n\n(or Drag & Drop File Here)" or "File Loaded:\n" .. input_file:match("([^\\/]+)$")
    
    if reaper.ImGui_Button(ctx, btn_text, 350, 70) then
        local retval, filename = reaper.GetUserFileNameForRead("", "Select Audio File", "")
        if retval then
            input_file = filename
            target_item = nil 
        end
    end
    reaper.ImGui_PopStyleColor(ctx)

    -- DEDICATED FILES DRAG & DROP
    if reaper.ImGui_BeginDragDropTarget(ctx) then
        local rv, count = reaper.ImGui_AcceptDragDropPayloadFiles(ctx)
        if rv and count > 0 then
            local ok, filename = reaper.ImGui_GetDragDropPayloadFile(ctx, 0)
            if ok and filename ~= "" then
                input_file = filename
                target_item = nil
            end
        end
        reaper.ImGui_EndDragDropTarget(ctx)
    end
    
    if reaper.ImGui_Button(ctx, "Grab Selected Item from REAPER Timeline", 350, 25) then
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

    reaper.ImGui_Separator(ctx)

    -- 2. PARAMETERS
    rv, age = reaper.ImGui_SliderDouble(ctx, "Tape Age %", age, 0.0, 100.0, "%.1f")
    
    reaper.ImGui_Text(ctx, "Tape Type:")
    if reaper.ImGui_RadioButton(ctx, "Type A (Cassette)", tape_type_idx == 1) then tape_type_idx = 1 end
    reaper.ImGui_SameLine(ctx)
    if reaper.ImGui_RadioButton(ctx, "Type B (VHS)", tape_type_idx == 2) then tape_type_idx = 2 end

    reaper.ImGui_Separator(ctx)

    -- 3. OUTPUT FORMAT
    reaper.ImGui_Text(ctx, "Output Format:")
    
    if reaper.ImGui_BeginCombo(ctx, "Format", format_list[format_idx]) then
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

    reaper.ImGui_Separator(ctx)

    -- 4. PROCESSING LOGIC
    if processing then
        reaper.ImGui_Text(ctx, "Processing... Please wait. REAPER may freeze briefly.")
        processing_frames = processing_frames + 1
        
        if processing_frames > 2 then
            ExecuteProcessing()
            processing = false
            process_triggered = false
        end
    else
        if input_file ~= "" then
            reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(), 0x228B22FF)
            if reaper.ImGui_Button(ctx, "PROCESS OFFLINE", 350, 40) then
                process_triggered = true
                processing_frames = 0
            end
            reaper.ImGui_PopStyleColor(ctx)
        else
            reaper.ImGui_Text(ctx, "Awaiting file input...")
        end
    end

    if process_triggered and not processing then processing = true end

    reaper.ImGui_End(ctx)
    return open
end

function loop()
    PerformJunkCleaning() -- Routinely destroys un-used/deleted generated audio files in the background!
    local open = DrawUI()
    if open then
        reaper.defer(loop)
    end
end

-- Fallback cleanup triggered if you simply close the plugin Window/Script
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
