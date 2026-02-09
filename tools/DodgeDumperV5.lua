-- ============================================================
-- DodgeDumperV5.lua - RE3 Remake
-- Two recording modes:
--   Single: Per-direction recording with 3-sec countdown
--   Continuous: 30-second recording with auto dodge detection
-- Features:
--   - 3-second countdown before recording starts
--   - Single mode: direction buttons, separate output per direction
--   - Continuous mode: auto-detects dodge events, splits into clips
--   - Named format compatible with CustomAnimFramework v1.3+
-- Deploy to: <RE3_game_dir>/reframework/autorun/
-- Output (single):     dodge_dump_<direction>.txt
-- Output (continuous): dodge_event_N.txt + dodge_continuous_full.txt
-- ============================================================
local mod_name = "DodgeDumperV5"
if reframework:get_game_name() ~= "re3" then return end
log.info("[" .. mod_name .. "] Loaded for RE3")

-- States: idle → countdown → recording → detecting → done
local dump_state = "idle"
local dump_frames = {}
local frame_counter = 0

-- Recording mode: 1 = single direction, 2 = continuous
local rec_mode = 1

-- Single mode settings
local single_max_frames = 180  -- ~3 seconds at 60fps

-- Continuous mode settings
local cont_seconds = 30
local cont_max_frames = 1800  -- updated when cont_seconds changes

-- Countdown
local countdown_start = 0
local countdown_duration = 3.0

-- Direction selection (single mode)
local directions = { "back", "front", "left", "right" }
local direction_labels = { "Back", "Front", "Left", "Right" }
local selected_dir = 1  -- index into directions

-- Auto-detection results (continuous mode)
local detected_events = {}
local detection_status = ""
local saved_event_count = 0

-- Bones
local bone_list = {}
local bone_count = 0
local player_transform = nil

-- ============================================
-- Player access (RE3-specific)
-- ============================================
local function get_player_transform()
    local ok, result = pcall(function()
        local pm = sdk.get_managed_singleton("offline.PlayerManager")
        if not pm then return nil end
        local pl = pm:call("get_CurrentPlayer")
        if not pl then
            local list = pm:get_field("PlayerList")
            if list then
                local count = list:call("get_Count")
                if count and count > 0 then
                    pl = list:call("get_Item", 0)
                end
            end
        end
        if not pl then return nil end
        return pl:call("get_Transform")
    end)
    if ok then return result end
    return nil
end

-- ============================================
-- Discover all bones from Transform joints
-- ============================================
local function discover_bones(transform)
    bone_list = {}
    bone_count = 0

    local ok, joints = pcall(function()
        local j = transform:call("get_Joints")
        if not j then return nil end
        return j:get_elements()
    end)
    if not ok or not joints then
        log.info("[" .. mod_name .. "] Failed to get joints")
        return
    end

    local count = #joints
    for idx = 0, count - 1 do
        local j = joints[idx + 1]
        if j then
            local name = "joint_" .. idx
            pcall(function()
                local n = j:call("get_Name")
                if n and n ~= "" then name = n end
            end)
            bone_list[#bone_list + 1] = { name = name, index = idx, joint = j }
        end
    end

    bone_count = #bone_list
    log.info("[" .. mod_name .. "] Discovered " .. bone_count .. " bones")
    for i, b in ipairs(bone_list) do
        if i <= 20 then
            log.info("[" .. mod_name .. "]   [" .. b.index .. "] " .. b.name)
        end
    end
    if bone_count > 20 then
        log.info("[" .. mod_name .. "]   ... (" .. (bone_count - 20) .. " more)")
    end
end

-- ============================================
-- Read current transforms for all bones
-- ============================================
local function read_frame()
    local frame = {}
    for _, b in ipairs(bone_list) do
        local ok, data = pcall(function()
            local j = b.joint
            local lr = j:call("get_LocalRotation")
            local lp = j:call("get_LocalPosition")
            return {
                qx = lr and lr.x or 0,
                qy = lr and lr.y or 0,
                qz = lr and lr.z or 0,
                qw = lr and lr.w or 1,
                px = lp and lp.x or 0,
                py = lp and lp.y or 0,
                pz = lp and lp.z or 0,
            }
        end)
        if ok and data then
            frame[b.name] = data
        end
    end
    return frame
end

-- ============================================
-- Get filtered/sorted named bones
-- ============================================
local function get_named_bones()
    local named = {}
    for _, b in ipairs(bone_list) do
        if not b.name:find("^joint_") and b.name ~= "?" then
            named[#named + 1] = b
        end
    end
    table.sort(named, function(a, b) return a.name < b.name end)
    return named
end

-- ============================================
-- Write a dump file (shared by both modes)
-- ============================================
local function write_dump_file(filename, frames, named_bones, direction, event_info)
    local path = filename
    local ok, f = pcall(io.open, path, "w")
    if not ok or not f then
        local alt = { "data/" .. filename, "reframework/data/" .. filename }
        for _, p in ipairs(alt) do
            ok, f = pcall(io.open, p, "w")
            if ok and f then path = p; break end
        end
        if not f then
            log.error("[" .. mod_name .. "] Failed to write " .. filename)
            return false
        end
    end

    if direction then
        f:write("DIRECTION=" .. direction .. "\n")
    end
    if event_info then
        f:write("EVENT_INFO=" .. event_info .. "\n")
    end
    f:write("BONE_COUNT=" .. #named_bones .. "\n")
    for _, b in ipairs(named_bones) do
        f:write("BONE|" .. b.name .. "\n")
    end
    f:write("FRAME_COUNT=" .. #frames .. "\n")
    for fi, frame in ipairs(frames) do
        f:write("FRAME=" .. (fi - 1) .. "\n")
        for _, b in ipairs(named_bones) do
            local d = frame[b.name]
            if d then
                f:write(string.format("T|%s|%.8f|%.8f|%.8f|%.8f|%.8f|%.8f|%.8f\n",
                    b.name, d.qx, d.qy, d.qz, d.qw, d.px, d.py, d.pz))
            end
        end
    end
    f:close()
    log.info("[" .. mod_name .. "] Saved " .. #frames .. " frames to " .. path)
    return true
end

-- ============================================
-- Auto-detect dodge events (continuous mode)
-- Monitors COG bone local position velocity
-- ============================================
local function detect_dodge_events_auto()
    detected_events = {}
    detection_status = "Analyzing " .. #dump_frames .. " frames..."
    log.info("[" .. mod_name .. "] " .. detection_status)

    if #dump_frames < 20 then
        detection_status = "Too few frames to analyze"
        return
    end

    -- Find tracking bone (prefer COG, fallback to hips)
    local track_name = nil
    for _, b in ipairs(bone_list) do
        if b.name == "COG" then track_name = "COG"; break end
    end
    if not track_name then
        for _, b in ipairs(bone_list) do
            if b.name == "hips" then track_name = "hips"; break end
        end
    end
    if not track_name then
        detection_status = "ERROR: No COG or hips bone found"
        log.error("[" .. mod_name .. "] " .. detection_status)
        return
    end
    log.info("[" .. mod_name .. "] Tracking bone: " .. track_name)

    -- Compute position velocity per frame
    local velocities = {}
    velocities[1] = 0
    local max_vel = 0
    for i = 2, #dump_frames do
        local prev = dump_frames[i - 1][track_name]
        local curr = dump_frames[i][track_name]
        if prev and curr then
            local dx = curr.px - prev.px
            local dy = curr.py - prev.py
            local dz = curr.pz - prev.pz
            velocities[i] = math.sqrt(dx * dx + dy * dy + dz * dz)
            if velocities[i] > max_vel then max_vel = velocities[i] end
        else
            velocities[i] = 0
        end
    end
    log.info("[" .. mod_name .. "] Max velocity: " .. string.format("%.6f", max_vel))

    -- Smooth over 5-frame window for noise reduction
    local smoothed = {}
    for i = 1, #velocities do
        local sum = 0
        local n = 0
        for j = math.max(1, i - 2), math.min(#velocities, i + 2) do
            sum = sum + velocities[j]
            n = n + 1
        end
        smoothed[i] = sum / n
    end

    -- Adaptive threshold: use 15% of max velocity, with floor of 0.001
    local threshold = math.max(0.001, max_vel * 0.15)
    local min_event_len = 8       -- minimum frames to count as a dodge
    local min_gap = 60            -- ~1 second gap between events
    log.info("[" .. mod_name .. "] Detection threshold: " .. string.format("%.6f", threshold))

    -- Find sustained motion periods
    local in_event = false
    local ev_start = 0
    local ev_peak_vel = 0
    local ev_peak_frame = 0
    local last_ev_end = -min_gap

    for i = 1, #smoothed do
        if smoothed[i] > threshold then
            if not in_event and (i - last_ev_end) >= min_gap then
                in_event = true
                ev_start = i
                ev_peak_vel = smoothed[i]
                ev_peak_frame = i
            elseif in_event then
                if smoothed[i] > ev_peak_vel then
                    ev_peak_vel = smoothed[i]
                    ev_peak_frame = i
                end
            end
        else
            if in_event then
                local ev_len = i - ev_start
                if ev_len >= min_event_len then
                    detected_events[#detected_events + 1] = {
                        start = ev_start,
                        stop = i,
                        length = ev_len,
                        peak_frame = ev_peak_frame,
                        peak_vel = ev_peak_vel,
                    }
                    last_ev_end = i
                end
                in_event = false
            end
        end
    end
    -- Handle event still in progress at end
    if in_event then
        local ev_len = #smoothed - ev_start
        if ev_len >= min_event_len then
            detected_events[#detected_events + 1] = {
                start = ev_start,
                stop = #smoothed,
                length = ev_len,
                peak_frame = ev_peak_frame,
                peak_vel = ev_peak_vel,
            }
        end
    end

    detection_status = "Found " .. #detected_events .. " dodge events"
    log.info("[" .. mod_name .. "] " .. detection_status)
    for i, ev in ipairs(detected_events) do
        log.info(string.format("[%s]   Event %d: frames %d-%d (%d frames, peak vel %.5f at frame %d)",
            mod_name, i, ev.start, ev.stop, ev.length, ev.peak_vel, ev.peak_frame))
    end
end

-- ============================================
-- Save: single direction mode
-- ============================================
local function save_single_dump()
    local named = get_named_bones()
    local dir_name = directions[selected_dir]
    write_dump_file("dodge_dump_" .. dir_name .. ".txt", dump_frames, named, dir_name, nil)
    log.info("[" .. mod_name .. "] Single dump saved: " .. #dump_frames ..
        " frames, " .. #named .. " bones, direction: " .. dir_name)
end

-- ============================================
-- Save: continuous mode (full + per-event clips)
-- ============================================
local function save_continuous_dump()
    local named = get_named_bones()
    saved_event_count = 0

    -- Save full continuous recording
    write_dump_file("dodge_continuous_full.txt", dump_frames, named, nil,
        "continuous_" .. #dump_frames .. "frames_" .. #detected_events .. "events")

    -- Save each detected event as a 180-frame clip
    for i, ev in ipairs(detected_events) do
        local clip_start = math.max(1, ev.start - 10)  -- 10 frames before event
        local clip_end = math.min(#dump_frames, clip_start + 179)  -- 180 frame window

        local clip_frames = {}
        for fi = clip_start, clip_end do
            clip_frames[#clip_frames + 1] = dump_frames[fi]
        end

        local info = string.format("event_%d_src_frames_%d_to_%d_peak_%d",
            i, clip_start, clip_end, ev.peak_frame)
        if write_dump_file("dodge_event_" .. i .. ".txt", clip_frames, named, nil, info) then
            saved_event_count = saved_event_count + 1
        end
    end

    log.info("[" .. mod_name .. "] Continuous save complete: full dump + " ..
        saved_event_count .. " event clips")
end

-- ============================================
-- Get current max frames based on mode
-- ============================================
local function get_max_frames()
    if rec_mode == 1 then
        return single_max_frames
    else
        cont_max_frames = cont_seconds * 60
        return cont_max_frames
    end
end

-- ============================================
-- Frame update
-- ============================================
re.on_frame(function()
    if dump_state == "countdown" then
        local elapsed = os.clock() - countdown_start
        if elapsed >= countdown_duration then
            dump_state = "recording"
            dump_frames = {}
            frame_counter = 0
            if rec_mode == 1 then
                log.info("[" .. mod_name .. "] RECORDING (single: " ..
                    directions[selected_dir] .. ", " .. get_max_frames() .. " frames)")
            else
                log.info("[" .. mod_name .. "] RECORDING (continuous: " ..
                    cont_seconds .. "s, " .. get_max_frames() .. " frames)")
            end
        end

    elseif dump_state == "recording" then
        if bone_count == 0 then return end
        local frame = read_frame()
        local count = 0
        for _ in pairs(frame) do count = count + 1 end
        if count > 0 then
            dump_frames[#dump_frames + 1] = frame
            frame_counter = frame_counter + 1
            local mf = get_max_frames()
            if frame_counter >= mf then
                if rec_mode == 1 then
                    dump_state = "done"
                    save_single_dump()
                else
                    dump_state = "detecting"
                    log.info("[" .. mod_name .. "] Recording complete, detecting events...")
                end
            end
        end

    elseif dump_state == "detecting" then
        -- Run detection (runs once, then transitions to done)
        detect_dodge_events_auto()
        save_continuous_dump()
        dump_state = "done"
    end
end)

-- ============================================
-- UI
-- ============================================
re.on_draw_ui(function()
    if imgui.tree_node(mod_name) then
        local t = get_player_transform()
        if not t then
            imgui.text_colored("Waiting for player...", 0xFF00CCFF)
            imgui.tree_pop()
            return
        end

        player_transform = t
        imgui.text_colored("Player found!", 0xFF00FF00)
        imgui.text("State: " .. dump_state ..
            " | Bones: " .. bone_count ..
            " | Frames: " .. #dump_frames)

        -- ========== IDLE STATE ==========
        if dump_state == "idle" then
            if imgui.button("1. Discover All Bones") then
                discover_bones(t)
            end

            if bone_count > 0 then
                imgui.spacing()
                imgui.separator()

                -- Mode selection (buttons instead of broken radio_button)
                imgui.text_colored("Recording Mode:", 0xFFFFFF00)
                if imgui.button(rec_mode == 1 and "[Single Direction]" or " Single Direction ") then
                    rec_mode = 1
                end
                imgui.same_line()
                if imgui.button(rec_mode == 2 and "[Continuous 30s]" or " Continuous 30s ") then
                    rec_mode = 2
                end

                imgui.spacing()
                imgui.separator()

                if rec_mode == 1 then
                    -- ===== SINGLE DIRECTION MODE =====
                    imgui.text_colored("Direction to capture:", 0xFFFFFF00)

                    -- Direction selection (buttons instead of radio_button)
                    for i, label in ipairs(direction_labels) do
                        if i > 1 then imgui.same_line() end
                        local btn_label = selected_dir == i
                            and ("[" .. label .. "]")
                            or (" " .. label .. " ")
                        if imgui.button(btn_label) then
                            selected_dir = i
                        end
                    end

                    imgui.spacing()
                    local dir_name = directions[selected_dir]
                    imgui.text("Output: dodge_dump_" .. dir_name .. ".txt")
                    imgui.text("3-sec countdown, then " .. single_max_frames .. " frames.")
                    imgui.text("Dodge " .. dir_name:upper() .. " when countdown ends!")
                    imgui.spacing()

                    if imgui.button("2. Record " .. dir_name:upper() .. " dodge") then
                        countdown_start = os.clock()
                        dump_state = "countdown"
                        log.info("[" .. mod_name .. "] Countdown for " .. dir_name .. " dodge")
                    end

                else
                    -- ===== CONTINUOUS MODE =====
                    imgui.text_colored("Continuous Recording:", 0xFFFFFF00)

                    local changed, new_val = imgui.slider_int("Duration (sec)", cont_seconds, 10, 60)
                    if changed then
                        cont_seconds = new_val
                        cont_max_frames = cont_seconds * 60
                    end

                    imgui.text("Records " .. cont_seconds .. "s (~" ..
                        (cont_seconds * 60) .. " frames at 60fps)")
                    imgui.text("Dodge freely in any direction during recording.")
                    imgui.text("Auto-detects dodge events and saves each as a clip.")
                    imgui.spacing()
                    imgui.text("Output: dodge_event_1.txt, dodge_event_2.txt, ...")
                    imgui.text("   + dodge_continuous_full.txt (entire recording)")
                    imgui.spacing()

                    if imgui.button("2. Start Continuous Recording") then
                        countdown_start = os.clock()
                        dump_state = "countdown"
                        log.info("[" .. mod_name .. "] Countdown for continuous recording (" ..
                            cont_seconds .. "s)")
                    end
                end

                imgui.spacing()
                imgui.separator()

                -- Show discovered bones
                if imgui.tree_node("Discovered Bones (" .. bone_count .. ")") then
                    for _, b in ipairs(bone_list) do
                        imgui.text(string.format("  [%2d] %s", b.index, b.name))
                    end
                    imgui.tree_pop()
                end
            end

        -- ========== COUNTDOWN STATE ==========
        elseif dump_state == "countdown" then
            local elapsed = os.clock() - countdown_start
            local remaining = math.max(0, countdown_duration - elapsed)
            local seconds = math.ceil(remaining)

            local mode_text = rec_mode == 1
                and (directions[selected_dir]:upper() .. " dodge")
                or ("continuous " .. cont_seconds .. "s")
            imgui.text_colored("GET READY: " .. seconds .. "...", 0xFF00FFFF)
            imgui.text("Mode: " .. mode_text)
            if rec_mode == 1 then
                imgui.text("Dodge " .. directions[selected_dir]:upper() ..
                    " when countdown ends!")
            else
                imgui.text("Dodge freely when countdown ends!")
            end
            imgui.spacing()
            local frac = elapsed / countdown_duration
            imgui.progress_bar(frac, nil, string.format("%.1fs / %.1fs",
                elapsed, countdown_duration))
            imgui.spacing()
            if imgui.button("Cancel") then
                dump_state = "idle"
            end

        -- ========== RECORDING STATE ==========
        elseif dump_state == "recording" then
            local mf = get_max_frames()
            local pct = frame_counter / mf * 100
            if rec_mode == 1 then
                imgui.text_colored(string.format("RECORDING %d/%d (%.0f%%) - %s",
                    frame_counter, mf, pct, directions[selected_dir]:upper()), 0xFF0000FF)
                imgui.text("Dodge NOW if you haven't already!")
            else
                local elapsed_sec = frame_counter / 60.0
                imgui.text_colored(string.format("RECORDING %d/%d (%.1fs / %ds)",
                    frame_counter, mf, elapsed_sec, cont_seconds), 0xFF0000FF)
                imgui.text("Dodge freely! All directions captured.")
                imgui.progress_bar(frame_counter / mf, nil,
                    string.format("%.1fs / %ds", elapsed_sec, cont_seconds))
            end
            imgui.spacing()
            if imgui.button("Stop & Save") then
                if rec_mode == 1 then
                    dump_state = "done"
                    save_single_dump()
                else
                    dump_state = "detecting"
                end
            end

        -- ========== DETECTING STATE ==========
        elseif dump_state == "detecting" then
            imgui.text_colored("Analyzing recording for dodge events...", 0xFFFF00FF)
            imgui.text(detection_status)

        -- ========== DONE STATE ==========
        elseif dump_state == "done" then
            if rec_mode == 1 then
                local dir_name = directions[selected_dir]
                imgui.text_colored("DONE! File: dodge_dump_" .. dir_name .. ".txt", 0xFF00FF00)
                imgui.text("Frames: " .. #dump_frames .. " | Bones: " .. bone_count ..
                    " | Direction: " .. dir_name:upper())
                if imgui.button("Record Another Direction") then
                    dump_state = "idle"
                    dump_frames = {}
                    frame_counter = 0
                end
            else
                imgui.text_colored("DONE! " .. detection_status, 0xFF00FF00)
                imgui.text("Total frames: " .. #dump_frames ..
                    " | Events saved: " .. saved_event_count)

                -- Show detected events
                if #detected_events > 0 and imgui.tree_node("Detected Events") then
                    for i, ev in ipairs(detected_events) do
                        imgui.text(string.format(
                            "  Event %d: frames %d-%d (%d frames) -> dodge_event_%d.txt",
                            i, ev.start, ev.stop, ev.length, i))
                    end
                    imgui.tree_pop()
                end

                imgui.text("Files: dodge_continuous_full.txt + dodge_event_N.txt")
                imgui.spacing()
                imgui.text_colored("Rename event files to dodge_dump_<direction>.txt", 0xFFFFFF00)
                imgui.text("for use with CustomAnimFramework.")

                if imgui.button("Record Again") then
                    dump_state = "idle"
                    dump_frames = {}
                    frame_counter = 0
                    detected_events = {}
                    detection_status = ""
                    saved_event_count = 0
                end
            end
        end

        imgui.tree_pop()
    end
end)
