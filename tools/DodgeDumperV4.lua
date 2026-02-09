-- ============================================================
-- DodgeDumperV4.lua - RE3 Remake
-- Captures ALL bones by iterating the Joint array directly
-- (instead of brute-force name matching like v3)
-- Outputs named format compatible with CustomAnimFramework v1.1+
-- Deploy to: <RE3_game_dir>/reframework/autorun/
-- Output: reframework/data/dodge_dump_named.txt
-- ============================================================
local mod_name = "DodgeDumperV4"
if reframework:get_game_name() ~= "re3" then return end
log.info("[" .. mod_name .. "] Loaded for RE3")

local dump_state = "idle"
local dump_frames = {}
local frame_counter = 0
local max_frames = 180  -- 6 seconds at 30fps

-- Discovered bones: ordered list of {name, index}
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
        -- Try get_CurrentPlayer first
        local pl = pm:call("get_CurrentPlayer")
        if not pl then
            -- Fallback: PlayerList field
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
-- Save dump in named format
-- ============================================
local function save_dump()
    -- Filter out bones with "?" names (unnamed RE3 bones, not useful)
    local named_bones = {}
    for _, b in ipairs(bone_list) do
        if not b.name:find("^joint_") and b.name ~= "?" then
            named_bones[#named_bones + 1] = b
        end
    end

    -- Sort by name for consistent output
    table.sort(named_bones, function(a, b) return a.name < b.name end)

    local path = "dodge_dump_named.txt"
    local ok, f = pcall(io.open, path, "w")
    if not ok or not f then
        log.error("[" .. mod_name .. "] Cannot write to " .. path)
        -- Try alternate paths
        local alt_paths = {"data/dodge_dump_named.txt", "reframework/data/dodge_dump_named.txt"}
        for _, p in ipairs(alt_paths) do
            ok, f = pcall(io.open, p, "w")
            if ok and f then
                path = p
                break
            end
        end
        if not f then
            log.error("[" .. mod_name .. "] Failed all write paths!")
            return
        end
    end

    f:write("BONE_COUNT=" .. #named_bones .. "\n")
    for _, b in ipairs(named_bones) do
        f:write("BONE|" .. b.name .. "\n")
    end

    f:write("FRAME_COUNT=" .. #dump_frames .. "\n")
    for fi, frame in ipairs(dump_frames) do
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
    log.info("[" .. mod_name .. "] Saved " .. #dump_frames .. " frames, " ..
        #named_bones .. " named bones to " .. path)
end

-- ============================================
-- Frame update
-- ============================================
re.on_frame(function()
    if dump_state == "recording" then
        if bone_count == 0 then return end
        local frame = read_frame()
        local count = 0
        for _ in pairs(frame) do count = count + 1 end
        if count > 0 then
            table.insert(dump_frames, frame)
            frame_counter = frame_counter + 1
            if frame_counter >= max_frames then
                dump_state = "done"
                save_dump()
            end
        end
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

        if dump_state == "idle" then
            if imgui.button("1. Discover All Bones") then
                discover_bones(t)
            end

            if bone_count > 0 then
                imgui.spacing()
                imgui.text_colored("Found " .. bone_count .. " bones! Ready to record.", 0xFFFFFF00)
                imgui.text("Instructions: Click record, then DODGE immediately!")
                imgui.spacing()
                if imgui.button("2. Record " .. max_frames .. " frames") then
                    dump_frames = {}
                    frame_counter = 0
                    dump_state = "recording"
                    log.info("[" .. mod_name .. "] RECORDING! Dodge NOW!")
                end
            end

            -- Show discovered bones
            if bone_count > 0 and imgui.tree_node("Discovered Bones (" .. bone_count .. ")") then
                for _, b in ipairs(bone_list) do
                    imgui.text(string.format("  [%2d] %s", b.index, b.name))
                end
                imgui.tree_pop()
            end
        elseif dump_state == "recording" then
            imgui.text_colored("RECORDING " .. frame_counter .. "/" .. max_frames, 0xFF0000FF)
            imgui.text("Dodge NOW if you haven't already!")
            if imgui.button("Stop & Save") then
                dump_state = "done"
                save_dump()
            end
        elseif dump_state == "done" then
            imgui.text_colored("DONE! File: dodge_dump_named.txt", 0xFF00FF00)
            imgui.text("Frames: " .. #dump_frames .. " | Bones: " .. bone_count)
            if imgui.button("Reset") then
                dump_state = "idle"
                dump_frames = {}
                frame_counter = 0
            end
        end

        imgui.tree_pop()
    end
end)
