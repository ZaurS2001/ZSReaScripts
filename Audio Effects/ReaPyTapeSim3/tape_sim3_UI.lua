-- @description ReaPyTapeSim3 UI
-- @author ZS & Assistant
-- @version 1.2
-- @provides
--   tape_sim3.py
--   requirements.txt
--   README.md
-- @about
--   # Analog Tape Simulator
--   A highly realistic, procedural analog tape degradation simulator bridging Python DSP with ReaImGui.
--   
--   **IMPORTANT:** After installing via ReaPack, you must have Python and FFmpeg installed on your system.
--   Navigate to the script's folder and run `pip install -r requirements.txt` to install the DSP dependencies.
--   See the included README.md for full instructions.

if not reaper.ImGui_CreateContext then
    reaper.ShowMessageBox("ReaImGui is required for this script.\nPlease install it via ReaPack.", "Missing Dependency", 0)
    return
end

local ctx = reaper.ImGui_CreateContext('Analog Tape Simulator')

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

-- Locate python script
local script_path = debug.getinfo(1, "S").source:match("@?(.*[\\/])")
if not script_path then script_path = "" end
local py_script = script_path .. "tape_sim.py"

-- DSP Processing Execute
function ExecuteProcessing()
    local ext = format_idx == 1 and "wav" or "mp3"
    local out_file = input_file .. "_taped." .. ext
    
    if reaper.file_exists(out_file) then os.remove(out_file) end
    
    local cmd = string.format('python "%s" -i "%s" -o "%s" -a %f -t %s --out-format %s --samplerate %s',
        py_script, input_file, out_file, age, tape_type_idx == 1 and "A" or "B", ext, sr_list[sr_idx])
        
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
        reaper.ShowConsoleMsg("--- TAPE SIM ERROR ---\n" .. (result or "") .. "\n")
        reaper.ShowMessageBox("Processing failed! Check Console for logs.", "Error", 0)
        processing = false
        return
    end

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

function DrawUI()
    local visible, open = reaper.ImGui_Begin(ctx, 'Tape Simulator Offline Processor', true, reaper.ImGui_WindowFlags_AlwaysAutoResize())
    if not visible then return open end

    -- 1. DROP / BROWSE AREA
    -- We push color, draw button, handle dragdrop, THEN pop color.
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(), 0x333333FF)
    
    local btn_text = input_file == "" and "Click to Browse\nOR\n[ DRAG AUDIO FILE HERE ]" or "File Loaded:\n" .. input_file:match("([^\\/]+)$")
    
    -- Main Button
    if reaper.ImGui_Button(ctx, btn_text, 350, 80) then
        local retval, filename = reaper.GetUserFileNameForRead("", "Select Audio File", "")
        if retval then
            input_file = filename
            target_item = nil
        end
    end

    -- Drag & Drop Handler (Must be immediately after the target item)
    if reaper.ImGui_BeginDragDropTarget(ctx) then
        local rv, payload = reaper.ImGui_AcceptDragDropPayload(ctx, 'DND_FILES')
        if rv then
            -- DND_FILES returns paths separated by \0
            local file_found = false
            for file in payload:gmatch("[^%z]+") do 
                -- Accept the first file found
                input_file = file
                target_item = nil
                file_found = true
                break 
            end
        end
        reaper.ImGui_EndDragDropTarget(ctx)
    end
    
    reaper.ImGui_PopStyleColor(ctx) -- Pop color AFTER drag logic

    -- Helper for Timeline Items
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
        else
            reaper.ShowMessageBox("No item selected in timeline!", "Selection Error", 0)
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
        reaper.ImGui_Text(ctx, "Processing... Please wait.")
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
    local open = DrawUI()
    if open then reaper.defer(loop) end
end

reaper.defer(loop)
