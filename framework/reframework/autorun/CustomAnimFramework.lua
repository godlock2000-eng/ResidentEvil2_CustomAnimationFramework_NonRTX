-- CustomAnimFramework.lua — RE Engine Custom Animation Framework v1.4
-- Runtime bone override system for playing RE3 animations on RE2 characters
-- v1.4: Multidirectional dodge (WASD + V) with per-direction animation data
-- Deploy: copy reframework/ folder to RE2 game root directory

if reframework:get_game_name() ~= "re2" then return end

log.info("[CAF] CustomAnimFramework v1.4 loading...")

--------------------------------------------------------------------------------
-- 1. CONFIGURATION
--------------------------------------------------------------------------------

local CFG = {
    -- Initialization delay (seconds after player detection)
    init_delay = 5.0,
    -- Dodge settings
    dodge_key = 0x56,           -- Keyboard key for dodge (V). 0 = disabled.
    dodge_pad_button = 0,       -- Gamepad button flag for dodge. 0 = auto-detect needed.
    dodge_cooldown = 1.0,       -- Seconds between dodges
    dodge_blend_in = 2,         -- Frames to blend in (near-instant snap into dodge)
    dodge_blend_out = 12,       -- Frames to blend out (at 60fps = 0.2s)
    -- Worldspace movement
    dodge_distance = 2.0,       -- Total distance (meters) during dodge
    dodge_move_start = 0.18,    -- Start movement at ~frame 32 (when dodge motion is visible)
    dodge_move_end = 0.65,      -- End movement at ~frame 117 (before recovery)
    -- Gamepad
    pad_stick_deadzone = 0.5,   -- Left stick magnitude threshold for direction
    -- Debug
    debug_log = true,
}

-- WASD key codes for direction detection
local KEY_W = 0x57
local KEY_A = 0x41
local KEY_S = 0x53
local KEY_D = 0x44

-- Common keyboard key names (for UI display)
local KB_KEY_NAMES = {
    [0] = "None",
    [0x08] = "Backspace", [0x09] = "Tab", [0x0D] = "Enter",
    [0x10] = "Shift", [0x11] = "Ctrl", [0x12] = "Alt",
    [0x1B] = "Escape", [0x20] = "Space",
    [0x30] = "0", [0x31] = "1", [0x32] = "2", [0x33] = "3", [0x34] = "4",
    [0x35] = "5", [0x36] = "6", [0x37] = "7", [0x38] = "8", [0x39] = "9",
    [0x41] = "A", [0x42] = "B", [0x43] = "C", [0x44] = "D", [0x45] = "E",
    [0x46] = "F", [0x47] = "G", [0x48] = "H", [0x49] = "I", [0x4A] = "J",
    [0x4B] = "K", [0x4C] = "L", [0x4D] = "M", [0x4E] = "N", [0x4F] = "O",
    [0x50] = "P", [0x51] = "Q", [0x52] = "R", [0x53] = "S", [0x54] = "T",
    [0x55] = "U", [0x56] = "V", [0x57] = "W", [0x58] = "X", [0x59] = "Y",
    [0x5A] = "Z",
    [0x70] = "F1", [0x71] = "F2", [0x72] = "F3", [0x73] = "F4",
    [0x74] = "F5", [0x75] = "F6", [0x76] = "F7", [0x77] = "F8",
    [0x78] = "F9", [0x79] = "F10", [0x7A] = "F11", [0x7B] = "F12",
}

-- Bones that should have position applied even in rotation-only mode
-- (COG carries root motion / character height changes)
local POSITION_BONES = { COG = true, hips = true }

--------------------------------------------------------------------------------
-- 2. BONE MAPPING DATA
-- RE3 dump index → bone hash (from bone_index_mapping.json)
-- At runtime, hash → RE2 joint index via Motion:getJointIndexByNameHash()
--------------------------------------------------------------------------------

local BONE_MAP_DATA = {
    { re3_idx = 0,  hash = 2879905340, name = "root" },
    { re3_idx = 1,  hash = 1573792880, name = "Null_Offset" },
    { re3_idx = 2,  hash = 3425867754, name = "COG" },
    { re3_idx = 3,  hash = 2795058024, name = "hips" },
    { re3_idx = 19, hash = 2896091387, name = "???" },
    { re3_idx = 20, hash = 2433276823, name = "???" },
    { re3_idx = 21, hash = 3000393038, name = "???" },
    { re3_idx = 22, hash = 4147580693, name = "???" },
    { re3_idx = 23, hash = 611496280,  name = "???" },
    { re3_idx = 24, hash = 718421727,  name = "???" },
    { re3_idx = 25, hash = 774556802,  name = "???" },
    { re3_idx = 27, hash = 2232446152, name = "???" },
    { re3_idx = 28, hash = 518133365,  name = "???" },
    { re3_idx = 29, hash = 3951162759, name = "???" },
    { re3_idx = 32, hash = 3912596401, name = "???" },
    { re3_idx = 33, hash = 4086384926, name = "???" },
    { re3_idx = 34, hash = 1794431525, name = "???" },
    { re3_idx = 35, hash = 4053908550, name = "???" },
    { re3_idx = 36, hash = 4226608956, name = "???" },
    { re3_idx = 37, hash = 2497187219, name = "???" },
    { re3_idx = 38, hash = 2372646773, name = "???" },
    { re3_idx = 40, hash = 3737677600, name = "???" },
    { re3_idx = 43, hash = 3430265927, name = "???" },
    { re3_idx = 44, hash = 1752151035, name = "???" },
    { re3_idx = 61, hash = 830704514,  name = "spine_0" },
    { re3_idx = 62, hash = 2157395361, name = "spine_1" },
    { re3_idx = 63, hash = 3007640129, name = "spine_2" },
    { re3_idx = 76, hash = 2971361680, name = "???" },
    { re3_idx = 77, hash = 3722817809, name = "???" },
    { re3_idx = 78, hash = 862024887,  name = "???" },
    { re3_idx = 79, hash = 3949637493, name = "???" },
}

--------------------------------------------------------------------------------
-- 3. STATE
--------------------------------------------------------------------------------

-- Core state
local game_ready = false
local player_motion = nil
local player_transform = nil
local player_char_ctrl = nil   -- via.physics.CharacterController (needed for warp)
local joints_array = nil       -- cached Joint objects from Transform
local joint_count = 0
local ready_time = 0
local init_done = false
local motion_owner = ""

-- Bone mapping state (built at runtime)
-- bone_map[re3_dump_idx] = { hash=int, name=str, re2_joint_idx=int, joint=Joint }
local bone_map = {}
local mapped_bone_count = 0

-- Multidirectional dodge data (loaded from files)
-- dodge_directions["back"] = {bone_count, frame_count, frames, named_format, bone_names}
local dodge_directions = {}    -- per-direction animation data
local loaded_dir_count = 0     -- how many directions are loaded
local dodge_active_dir = "back" -- currently playing direction
local dodge_data = nil          -- pointer to active direction's data (for backward compat)
local data_loaded = false
local data_load_error = nil

-- Dodge state machine
local dodge_state = "idle"     -- idle, blend_in, active, blend_out
local dodge_time = 0           -- seconds since dodge start
local dodge_frame = 0          -- current animation frame (float)
local dodge_blend = 0          -- blend weight (0..1) during transitions
local last_dodge_time = -999   -- for cooldown
local dodge_count = 0          -- total dodges performed (debug)

-- Worldspace movement state
local dodge_move_dir = nil     -- movement direction at dodge start
local dodge_start_pos = nil    -- character position at dodge start
local dodge_moved = 0          -- total distance moved so far
local dodge_wall_dist = 999    -- max safe distance before wall hit (meters)
local dodge_wall_hit = false   -- true if wall was detected during this dodge

-- Rest pose (captured before dodge starts, for blending)
-- rest_pose[re3_idx] = {qw, qx, qy, qz, px, py, pz}
local rest_pose = {}

-- UI state
local ui_show_bones = false
local ui_show_frames = false
local ui_manual_frame = 0
local ui_force_frame = false
local ui_use_euler = false     -- fallback: convert quaternions to Euler angles
local ui_enable_movement = true -- worldspace movement during dodge
local ui_rotation_only = true  -- skip position overrides (avoids limb stretching)
local ui_delta_mode = true     -- apply rotation DELTA from frame 0 (preserves RE2 base pose)

--------------------------------------------------------------------------------
-- 4. UTILITY FUNCTIONS
--------------------------------------------------------------------------------

local function dbg(msg)
    if CFG.debug_log then
        log.info("[CAF] " .. msg)
    end
end

-- Quaternion spherical linear interpolation
local function quat_slerp(aw, ax, ay, az, bw, bx, by, bz, t)
    local dot = aw*bw + ax*bx + ay*by + az*bz
    if dot < 0 then
        bw, bx, by, bz = -bw, -bx, -by, -bz
        dot = -dot
    end
    if dot > 0.9995 then
        local rw = aw + t * (bw - aw)
        local rx = ax + t * (bx - ax)
        local ry = ay + t * (by - ay)
        local rz = az + t * (bz - az)
        local len = math.sqrt(rw*rw + rx*rx + ry*ry + rz*rz)
        return rw/len, rx/len, ry/len, rz/len
    end
    local theta0 = math.acos(dot)
    local theta = theta0 * t
    local sin_theta = math.sin(theta)
    local sin_theta0 = math.sin(theta0)
    local s0 = math.cos(theta) - dot * sin_theta / sin_theta0
    local s1 = sin_theta / sin_theta0
    return s0*aw + s1*bw, s0*ax + s1*bx, s0*ay + s1*by, s0*az + s1*bz
end

-- Linear interpolation for positions
local function vec3_lerp(ax, ay, az, bx, by, bz, t)
    return ax + t*(bx - ax), ay + t*(by - ay), az + t*(bz - az)
end

-- Quaternion inverse (conjugate for unit quaternions)
local function quat_inverse(w, x, y, z)
    return w, -x, -y, -z
end

-- Quaternion multiplication (Hamilton product)
local function quat_multiply(aw, ax, ay, az, bw, bx, by, bz)
    return aw*bw - ax*bx - ay*by - az*bz,
           aw*bx + ax*bw + ay*bz - az*by,
           aw*by - ax*bz + ay*bw + az*bx,
           aw*bz + ax*by - ay*bx + az*bw
end

-- Quaternion to Euler angles (degrees) — fallback method
local function quat_to_euler_deg(qw, qx, qy, qz)
    local sinr_cosp = 2.0 * (qw * qx + qy * qz)
    local cosr_cosp = 1.0 - 2.0 * (qx * qx + qy * qy)
    local roll = math.atan(sinr_cosp, cosr_cosp)
    local sinp = 2.0 * (qw * qy - qz * qx)
    local pitch
    if math.abs(sinp) >= 1.0 then
        pitch = (sinp > 0 and 1 or -1) * math.pi / 2
    else
        pitch = math.asin(sinp)
    end
    local siny_cosp = 2.0 * (qw * qz + qx * qy)
    local cosy_cosp = 1.0 - 2.0 * (qy * qy + qz * qz)
    local yaw = math.atan(siny_cosp, cosy_cosp)
    return math.deg(roll), math.deg(pitch), math.deg(yaw)
end

--------------------------------------------------------------------------------
-- 5. CORE: Player Detection & Component Caching
--------------------------------------------------------------------------------

local function find_motion_on_hierarchy(game_object)
    local ok, motion = pcall(function()
        return game_object:call("getComponent(System.Type)",
            sdk.typeof("via.motion.Motion"))
    end)
    if ok and motion then
        return motion, "player_root"
    end
    local ok2, result = pcall(function()
        local transform = game_object:call("get_Transform")
        if not transform then return nil end
        local child_count = transform:call("get_ChildCount")
        if not child_count or child_count <= 0 then return nil end
        for i = 0, math.min(child_count - 1, 20) do
            local child_tf = transform:call("getChild", i)
            if child_tf then
                local child_go = child_tf:call("get_GameObject")
                if child_go then
                    local m = child_go:call("getComponent(System.Type)",
                        sdk.typeof("via.motion.Motion"))
                    if m then
                        local name = child_go:call("get_Name") or ("child_" .. i)
                        return m, name
                    end
                end
            end
        end
        return nil
    end)
    if ok2 and result then
        return result, "child"
    end
    return nil, nil
end

local function get_player()
    local ok, result = pcall(function()
        local mgr = sdk.get_managed_singleton(sdk.game_namespace("PlayerManager"))
        if not mgr then return nil end
        local pl = mgr:call("get_CurrentPlayer")
        if not pl then return nil end
        return pl
    end)
    return ok and result or nil
end

local function cache_components(player)
    local motion, owner = find_motion_on_hierarchy(player)
    if not motion then return false end

    local ok, transform = pcall(function()
        return player:call("get_Transform")
    end)
    if not ok or not transform then return false end

    local ok2, joints = pcall(function()
        local j = transform:call("get_Joints")
        if not j then return nil end
        return j:get_elements()
    end)
    if not ok2 or not joints then return false end

    player_motion = motion
    player_transform = transform
    joints_array = joints
    joint_count = #joints
    motion_owner = owner or "unknown"

    -- Cache CharacterController (needed for warp() to persist position changes)
    player_char_ctrl = nil
    local cc_source = "none"

    -- Attempt 1: direct on player
    pcall(function()
        local cc = player:call("getComponent(System.Type)",
            sdk.typeof("via.physics.CharacterController"))
        if cc then
            player_char_ctrl = cc
            cc_source = "direct getComponent"
        end
    end)

    -- Attempt 2: SurvivorCharacterController backing field
    if not player_char_ctrl then
        pcall(function()
            local scc = player:call("getComponent(System.Type)",
                sdk.typeof("app.ropeway.survivor.SurvivorCharacterController"))
            if scc then
                local cc = scc:get_field("<CharacterController>k__BackingField")
                if cc then
                    player_char_ctrl = cc
                    cc_source = "SurvivorCC backing field"
                end
            end
        end)
    end

    -- Attempt 3: Search children
    if not player_char_ctrl then
        pcall(function()
            local child_count = transform:call("get_ChildCount")
            if child_count and child_count > 0 then
                for i = 0, math.min(child_count - 1, 10) do
                    local child_tf = transform:call("getChild", i)
                    if child_tf then
                        local child_go = child_tf:call("get_GameObject")
                        if child_go then
                            local cc = child_go:call("getComponent(System.Type)",
                                sdk.typeof("via.physics.CharacterController"))
                            if cc then
                                player_char_ctrl = cc
                                local name = child_go:call("get_Name") or "?"
                                cc_source = "child '" .. name .. "'"
                                break
                            end
                        end
                    end
                end
            end
        end)
    end

    -- Attempt 4: player's own GameObject
    if not player_char_ctrl then
        pcall(function()
            local go = player:call("get_GameObject")
            if go then
                local cc = go:call("getComponent(System.Type)",
                    sdk.typeof("via.physics.CharacterController"))
                if cc then
                    player_char_ctrl = cc
                    cc_source = "player get_GameObject"
                end
            end
        end)
    end

    dbg("Components cached: Motion on '" .. motion_owner ..
        "', " .. joint_count .. " joints, CharacterController: " .. cc_source)
    return true
end

--------------------------------------------------------------------------------
-- 6. DODGE DATA LOADING (multidirectional)
--------------------------------------------------------------------------------

local function try_open_file(paths)
    for _, p in ipairs(paths) do
        local ok, f = pcall(io.open, p, "r")
        if ok and f then
            dbg("Opened file: " .. p)
            return f, p
        elseif not ok then
            dbg("Path error (blocked): " .. p)
        else
            dbg("Path not found: " .. p)
        end
    end
    return nil, nil
end

-- Parse a dodge dump file into a data table
-- Returns: {bone_count, frame_count, frames, named_format, bone_names} or nil
local function parse_dodge_file(f, path)
    local bone_count = 0
    local frame_count = 0
    local frames = {}
    local current_frame = -1
    local line_num = 0
    local named_format = false
    local bone_names = {}

    for line in f:lines() do
        line_num = line_num + 1
        if line:find("^BONE_COUNT=") then
            bone_count = tonumber(line:match("=(%d+)"))
        elseif line:find("^FRAME_COUNT=") then
            frame_count = tonumber(line:match("=(%d+)"))
        elseif line:find("^BONE|") then
            local parts = {}
            for p in line:gmatch("[^|]+") do parts[#parts+1] = p end
            if #parts == 2 then
                named_format = true
                bone_names[#bone_names+1] = parts[2]
            end
        elseif line:find("^FRAME=") then
            current_frame = tonumber(line:match("=(%d+)"))
            frames[current_frame] = {}
        elseif line:find("^T|") and current_frame >= 0 then
            local parts = {}
            for p in line:gmatch("[^|]+") do
                parts[#parts + 1] = p
            end
            if #parts >= 9 then
                local bone_key
                if named_format then
                    bone_key = parts[2]
                else
                    bone_key = tonumber(parts[2])
                end
                frames[current_frame][bone_key] = {
                    qx = tonumber(parts[3]),
                    qy = tonumber(parts[4]),
                    qz = tonumber(parts[5]),
                    qw = tonumber(parts[6]),
                    px = tonumber(parts[7]),
                    py = tonumber(parts[8]),
                    pz = tonumber(parts[9]),
                }
            end
        end
        -- Lines like DIRECTION=, EVENT_INFO= are silently ignored
    end
    f:close()

    if frame_count == 0 or bone_count == 0 then
        dbg("Parse failed for " .. path .. " (frames=" .. frame_count .. " bones=" .. bone_count .. ")")
        return nil
    end

    local fmt = named_format and "NAMED" or "INDEXED"
    dbg("Parsed " .. path .. ": " .. frame_count .. " frames, " ..
        bone_count .. " bones (" .. fmt .. "), " .. line_num .. " lines")

    return {
        bone_count = bone_count,
        frame_count = frame_count,
        frames = frames,
        named_format = named_format,
        bone_names = bone_names,
    }
end

-- Load a single direction's dodge dump
local function load_direction(dir_name)
    local paths = {
        "CustomAnimFramework/dodge_dump_" .. dir_name .. ".txt",
        "dodge_dump_" .. dir_name .. ".txt",
        "data/CustomAnimFramework/dodge_dump_" .. dir_name .. ".txt",
    }
    local f, found_path = try_open_file(paths)
    if not f then return nil end
    return parse_dodge_file(f, found_path)
end

-- Load all available directional dodge dumps
local function load_all_dodges()
    dodge_directions = {}
    loaded_dir_count = 0
    data_load_error = nil

    local dirs = { "back", "front", "left", "right" }
    for _, dir in ipairs(dirs) do
        local data = load_direction(dir)
        if data then
            dodge_directions[dir] = data
            loaded_dir_count = loaded_dir_count + 1
            dbg("Loaded " .. dir .. " dodge: " .. data.frame_count .. " frames, " ..
                data.bone_count .. " bones")
        else
            dbg("No dump found for direction: " .. dir)
        end
    end

    -- Fallback: try dodge_dump_named.txt as "back" direction
    if not dodge_directions["back"] then
        dbg("Trying fallback: dodge_dump_named.txt as 'back' direction...")
        local fallback_paths = {
            "CustomAnimFramework/dodge_dump_named.txt",
            "dodge_dump_named.txt",
            "data/CustomAnimFramework/dodge_dump_named.txt",
        }
        local f, path = try_open_file(fallback_paths)
        if f then
            local data = parse_dodge_file(f, path)
            if data then
                dodge_directions["back"] = data
                loaded_dir_count = loaded_dir_count + 1
                dbg("Loaded fallback dodge_dump_named.txt as 'back'")
            end
        end
    end

    -- Set default active direction
    if dodge_directions["back"] then
        dodge_data = dodge_directions["back"]
        dodge_active_dir = "back"
    else
        -- Use first available direction
        for dir, data in pairs(dodge_directions) do
            dodge_data = data
            dodge_active_dir = dir
            break
        end
    end

    data_loaded = loaded_dir_count > 0
    if data_loaded then
        local dir_list = {}
        for _, dir in ipairs(dirs) do
            if dodge_directions[dir] then dir_list[#dir_list+1] = dir end
        end
        dbg("Loaded " .. loaded_dir_count .. "/4 directions: " .. table.concat(dir_list, ", "))
    else
        data_load_error = "No dodge dump files found"
        dbg("ERROR: " .. data_load_error)
    end
end

--------------------------------------------------------------------------------
-- 7. BONE MAPPING: Resolve RE3 dump indices → RE2 Joint objects
--------------------------------------------------------------------------------

local re2_all_joints = {}

local function build_bone_map()
    if not player_motion then return false end

    bone_map = {}
    mapped_bone_count = 0
    re2_all_joints = {}

    -- Step 1: Enumerate ALL RE2 joints with names and hashes
    dbg("Enumerating all " .. joint_count .. " RE2 joints...")
    for idx = 0, joint_count - 1 do
        local name = "?"
        local hash = 0

        if joints_array[idx + 1] then
            pcall(function()
                name = joints_array[idx + 1]:call("get_Name") or "?"
            end)
        end

        pcall(function()
            hash = player_motion:call("getJointNameHashByIndex", idx) or 0
        end)

        re2_all_joints[idx] = { name = name, hash = hash }

        if idx < 30 then
            dbg(string.format("  RE2 joint[%3d] = %-25s hash=%u (0x%08x)", idx, name, hash, hash))
        end
    end
    if joint_count > 30 then
        dbg("  ... (" .. (joint_count - 30) .. " more joints)")
    end

    -- Step 2: Build bone map based on dump format
    -- Use the first loaded direction's data for bone name resolution
    local ref_data = dodge_data
    if not ref_data then
        for _, data in pairs(dodge_directions) do
            ref_data = data
            break
        end
    end

    if ref_data and ref_data.named_format then
        -- NAMED FORMAT: match bone names directly
        local re2_name_to_idx = {}
        for idx = 0, joint_count - 1 do
            local j = re2_all_joints[idx]
            if j and j.name ~= "?" then
                re2_name_to_idx[j.name] = idx
            end
        end

        for _, bname in ipairs(ref_data.bone_names) do
            local re2_idx = re2_name_to_idx[bname]
            if re2_idx and joints_array[re2_idx + 1] then
                bone_map[bname] = {
                    name = bname,
                    re2_joint_idx = re2_idx,
                    joint = joints_array[re2_idx + 1],
                }
                mapped_bone_count = mapped_bone_count + 1
                dbg(string.format("  MAPPED: '%s' → RE2[%3d]", bname, re2_idx))
            else
                dbg(string.format("  FAILED: '%s' not found in RE2 skeleton", bname))
            end
        end

        dbg("Bone map built (named): " .. mapped_bone_count .. "/" ..
            #ref_data.bone_names .. " bones resolved")
    else
        -- INDEXED FORMAT: use hash-based mapping from BONE_MAP_DATA
        for _, entry in ipairs(BONE_MAP_DATA) do
            local ok, re2_idx = pcall(function()
                return player_motion:call("getJointIndexByNameHash", entry.hash)
            end)
            if ok and re2_idx and re2_idx >= 0 and re2_idx < joint_count then
                local joint = joints_array[re2_idx + 1]
                if joint then
                    local resolved_name = entry.name
                    if resolved_name == "???" and re2_all_joints[re2_idx] then
                        resolved_name = re2_all_joints[re2_idx].name
                    end

                    bone_map[entry.re3_idx] = {
                        hash = entry.hash,
                        name = resolved_name,
                        re2_joint_idx = re2_idx,
                        joint = joint,
                    }
                    mapped_bone_count = mapped_bone_count + 1
                    dbg(string.format("  MAPPED: RE3[%2d] → RE2[%3d] '%s'",
                        entry.re3_idx, re2_idx, resolved_name))
                end
            else
                dbg(string.format("  FAILED: RE3[%2d] hash=%u not found in RE2",
                    entry.re3_idx, entry.hash))
            end
        end

        dbg("Bone map built (indexed): " .. mapped_bone_count .. "/" ..
            #BONE_MAP_DATA .. " bones resolved to RE2 joints")
    end

    -- Step 3: Write full RE2 joint dump to file (for offline analysis)
    pcall(function()
        local dump_paths = {
            "reframework/data/re2_bone_hashes.txt",
            "data/re2_bone_hashes.txt",
            "re2_bone_hashes.txt",
        }
        for _, dp in ipairs(dump_paths) do
            local ok2, f = pcall(io.open, dp, "w")
            if ok2 and f then
                f:write("RE2 Bone Hash Dump (from CustomAnimFramework)\n")
                f:write(string.format("Joint count: %d\n", joint_count))
                f:write("Format: INDEX|NAME|HASH_INT|HASH_HEX\n")
                f:write("---\n")
                for idx = 0, joint_count - 1 do
                    local j = re2_all_joints[idx]
                    if j then
                        f:write(string.format("%d|%s|%u|0x%08x\n", idx, j.name, j.hash, j.hash))
                    end
                end
                f:write("---\n")
                f:write("TOTAL=" .. joint_count .. "\n")
                f:close()
                dbg("RE2 joint dump written to: " .. dp)
                break
            end
        end
    end)

    return mapped_bone_count > 0
end

--------------------------------------------------------------------------------
-- 8. INPUT HANDLING (must be before dodge state machine which uses these functions)
--------------------------------------------------------------------------------

-- Keyboard input
local function is_key_down(keycode)
    if not keycode or keycode == 0 then return false end
    local ok, result = pcall(function()
        return reframework:is_key_down(keycode)
    end)
    return ok and result
end

-- Gamepad input via via.hid.GamePad native singleton
-- RE2 uses sdk.get_native_singleton("via.hid.Gamepad") + getMergedDevice(0)
-- (via.hid.GamePadManager does NOT exist in RE2)
local gp_typedef = sdk.find_type_definition("via.hid.GamePad")
local cached_pad = nil
local cached_pad_time = 0

local function get_gamepad()
    local now = os.clock()
    if cached_pad and (now - cached_pad_time) < 2.0 then
        return cached_pad
    end
    local ok, pad = pcall(function()
        if not gp_typedef then return nil end
        local gp_singleton = sdk.get_native_singleton("via.hid.Gamepad")
        if not gp_singleton then return nil end
        return sdk.call_native_func(gp_singleton, gp_typedef, "getMergedDevice", 0)
    end)
    if ok and pad then
        cached_pad = pad
        cached_pad_time = now
    end
    return ok and pad or nil
end

local function get_pad_buttons()
    local pad = get_gamepad()
    if not pad then return 0 end
    local ok, buttons = pcall(function()
        return pad:call("get_Button")
    end)
    if ok and buttons then
        return tonumber(buttons) or 0
    end
    return 0
end

local function is_pad_button_down(button_flag)
    if not button_flag or button_flag == 0 then return false end
    local buttons = get_pad_buttons()
    if buttons == 0 then return false end
    return (buttons & button_flag) ~= 0
end

local function get_pad_stick_l()
    local pad = get_gamepad()
    if not pad then return 0, 0 end
    local ok, axis = pcall(function()
        return pad:call("get_AxisL")
    end)
    if ok and axis then
        return axis.x or 0, axis.y or 0
    end
    return 0, 0
end

-- Combined direction detection (keyboard WASD + gamepad stick + dpad)
local function get_input_direction()
    -- Keyboard WASD (highest priority)
    if is_key_down(KEY_W) then return "front" end
    if is_key_down(KEY_A) then return "left" end
    if is_key_down(KEY_D) then return "right" end
    if is_key_down(KEY_S) then return "back" end

    -- Gamepad left stick
    local sx, sy = get_pad_stick_l()
    local mag = math.sqrt(sx * sx + sy * sy)
    if mag > CFG.pad_stick_deadzone then
        -- Determine dominant axis
        if math.abs(sy) >= math.abs(sx) then
            return sy > 0 and "front" or "back"
        else
            return sx > 0 and "right" or "left"
        end
    end

    return "back"  -- default
end

-- Combined dodge trigger check (keyboard key OR gamepad button)
local function is_dodge_pressed()
    if CFG.dodge_key > 0 and is_key_down(CFG.dodge_key) then return true end
    if CFG.dodge_pad_button > 0 and is_pad_button_down(CFG.dodge_pad_button) then return true end
    return false
end

-- UI state for input configuration
local kb_detect_mode = false
local pad_detect_mode = false
local pad_prev_buttons = 0

--------------------------------------------------------------------------------
-- 9. DODGE STATE MACHINE
--------------------------------------------------------------------------------

local function capture_rest_pose()
    rest_pose = {}
    for re3_idx, mapping in pairs(bone_map) do
        local ok, data = pcall(function()
            local j = mapping.joint
            local rot = j:call("get_LocalRotation")
            local pos = j:call("get_LocalPosition")
            return {
                qw = rot.w, qx = rot.x, qy = rot.y, qz = rot.z,
                px = pos.x, py = pos.y, pz = pos.z,
            }
        end)
        if ok and data then
            rest_pose[re3_idx] = data
        end
    end
end

local function start_dodge()
    if dodge_state ~= "idle" then return end
    local now = os.clock()
    if now - last_dodge_time < CFG.dodge_cooldown then return end

    -- Detect direction from keyboard WASD or gamepad stick/dpad
    local dir = get_input_direction()

    -- Fall back if requested direction isn't loaded
    if not dodge_directions[dir] then
        if dodge_directions["back"] then
            dir = "back"
        else
            -- Use any loaded direction
            for d, _ in pairs(dodge_directions) do
                dir = d
                break
            end
        end
    end
    if not dodge_directions[dir] then return end

    -- Set active direction and data
    dodge_active_dir = dir
    dodge_data = dodge_directions[dir]

    -- Capture current pose for blending
    capture_rest_pose()

    -- Compute movement direction based on dodge direction
    dodge_move_dir = nil
    dodge_start_pos = nil
    dodge_moved = 0
    dodge_wall_dist = 999
    dodge_wall_hit = false
    dodge_last_set_pos = nil
    local fwd_dbg = "no fwd"
    pcall(function()
        if player_transform then
            local rot = player_transform:call("get_Rotation")
            if rot then
                -- Compute character's backward direction from rotation quaternion
                -- (get_Forward doesn't exist on via.Transform in RE Engine)
                -- This vector points in the direction the character would move for a backward dodge
                local back_x = -(2.0 * (rot.x * rot.z + rot.w * rot.y))
                local back_z = -(1.0 - 2.0 * (rot.x * rot.x + rot.y * rot.y))
                local len = math.sqrt(back_x * back_x + back_z * back_z)
                if len > 0.001 then
                    back_x = back_x / len
                    back_z = back_z / len

                    -- Compute movement direction based on dodge direction
                    -- back_vec = character's backward direction (confirmed working)
                    -- right = cross(forward, up) where forward = -backward
                    if dir == "back" then
                        dodge_move_dir = { x = back_x, y = 0, z = back_z }
                    elseif dir == "front" then
                        dodge_move_dir = { x = -back_x, y = 0, z = -back_z }
                    elseif dir == "left" then
                        -- Character's left = (-back_z, 0, back_x)
                        dodge_move_dir = { x = -back_z, y = 0, z = back_x }
                    elseif dir == "right" then
                        -- Character's right = (back_z, 0, -back_x)
                        dodge_move_dir = { x = back_z, y = 0, z = -back_x }
                    end

                    fwd_dbg = string.format("dir=%s move=(%.3f,%.3f)",
                        dir, dodge_move_dir.x, dodge_move_dir.z)
                else
                    fwd_dbg = "fwd=zero_len"
                end
            else
                fwd_dbg = "rot=nil"
            end
            local pos = player_transform:call("get_Position")
            if pos then
                dodge_start_pos = { x = pos.x, y = pos.y, z = pos.z }
                fwd_dbg = fwd_dbg .. string.format(" pos=(%.1f, %.1f, %.1f)", pos.x, pos.y, pos.z)
            end
        end
    end)

    dodge_state = "blend_in"
    dodge_time = 0
    dodge_frame = 0
    dodge_blend = 0
    dodge_move_log_count = 0
    last_dodge_time = now
    dodge_count = dodge_count + 1
    dbg("Dodge #" .. dodge_count .. " " .. dir:upper() .. " started (" .. fwd_dbg ..
        " cc=" .. tostring(player_char_ctrl ~= nil) .. ")")
end

-- Frame advancement: 1 dump frame per game frame (framerate-locked)
local function update_dodge_state(dt)
    if dodge_state == "idle" then return end
    if not dodge_data then
        dodge_state = "idle"
        return
    end

    dodge_frame = dodge_frame + 1
    dodge_time = dodge_time + dt

    local total = dodge_data.frame_count

    if dodge_state == "blend_in" then
        dodge_blend = math.min(1.0, dodge_frame / CFG.dodge_blend_in)
        if dodge_blend >= 1.0 then
            dodge_state = "active"
            dodge_blend = 1.0
        end
    elseif dodge_state == "active" then
        dodge_blend = 1.0
        if dodge_frame >= total - CFG.dodge_blend_out then
            dodge_state = "blend_out"
        end
    elseif dodge_state == "blend_out" then
        local remaining = total - dodge_frame
        if CFG.dodge_blend_out > 0 then
            dodge_blend = math.max(0.0, remaining / CFG.dodge_blend_out)
        else
            dodge_blend = 0
        end
        if dodge_frame >= total or dodge_blend <= 0 then
            dodge_state = "idle"
            dodge_blend = 0
            dbg("Dodge #" .. dodge_count .. " " .. dodge_active_dir:upper() ..
                " finished (real time: " .. string.format("%.2fs", dodge_time) .. ")")
        end
    end
end

-- Worldspace movement
local dodge_move_log_count = 0
local dodge_last_set_pos = nil
local function apply_worldspace_movement()
    if dodge_state == "idle" then return end
    if not ui_enable_movement then return end
    if not dodge_move_dir or not dodge_start_pos or not player_transform then
        if dodge_move_log_count == 0 then
            dbg("MOVE SKIP: dir=" .. tostring(dodge_move_dir ~= nil) ..
                " start=" .. tostring(dodge_start_pos ~= nil) ..
                " xform=" .. tostring(player_transform ~= nil))
            dodge_move_log_count = 1
        end
        return
    end
    if not dodge_data then return end
    if ui_force_frame then return end
    if dodge_wall_hit then return end

    -- Wall detection via position readback
    if dodge_last_set_pos and player_char_ctrl and dodge_moved > 0.3 then
        pcall(function()
            local actual = player_transform:call("get_Position")
            if actual then
                local dx = actual.x - dodge_last_set_pos.x
                local dz = actual.z - dodge_last_set_pos.z
                local drift = math.sqrt(dx * dx + dz * dz)
                if drift > 0.15 then
                    dodge_wall_hit = true
                    dodge_wall_dist = dodge_moved
                    player_char_ctrl:call("warp")
                    dbg(string.format("WALL HIT: drift=%.2fm at dist=%.2f (%s dodge)",
                        drift, dodge_moved, dodge_active_dir))
                end
            end
        end)
        if dodge_wall_hit then return end
    end

    local total = dodge_data.frame_count
    local progress = dodge_frame / total

    if progress < CFG.dodge_move_start or progress > CFG.dodge_move_end then return end

    local move_progress = (progress - CFG.dodge_move_start) /
                          (CFG.dodge_move_end - CFG.dodge_move_start)
    move_progress = math.min(1.0, math.max(0.0, move_progress))
    -- Smoothstep: 3t^2 - 2t^3
    local eased = move_progress * move_progress * (3.0 - 2.0 * move_progress)
    local target_dist = CFG.dodge_distance * eased
    dodge_moved = target_dist

    local ok, err = pcall(function()
        local new_x = dodge_start_pos.x + dodge_move_dir.x * target_dist
        local new_y = dodge_start_pos.y
        local new_z = dodge_start_pos.z + dodge_move_dir.z * target_dist

        local new_pos = Vector3f.new(new_x, new_y, new_z)
        player_transform:call("set_Position", new_pos)
        if player_char_ctrl then
            player_char_ctrl:call("warp")
        end

        dodge_last_set_pos = { x = new_x, y = new_y, z = new_z }

        if dodge_move_log_count < 5 then
            dbg(string.format("MOVE %s frame=%d dist=%.2f pos=(%.1f,%.1f,%.1f)→(%.1f,%.1f,%.1f)",
                dodge_active_dir:upper(), dodge_frame, target_dist,
                dodge_start_pos.x, dodge_start_pos.y, dodge_start_pos.z,
                new_x, new_y, new_z))
            dodge_move_log_count = dodge_move_log_count + 1
        end
    end)
    if not ok then
        dbg("MOVE ERROR: " .. tostring(err))
    end
end

--------------------------------------------------------------------------------
-- 9. BONE APPLICATION (called in PrepareRendering)
--------------------------------------------------------------------------------

local function apply_dodge_bones()
    if dodge_state == "idle" and not ui_force_frame then return end
    if not dodge_data or not dodge_data.frames then return end

    local frame_f = ui_force_frame and ui_manual_frame or dodge_frame
    local frame_lo = math.max(0, math.min(math.floor(frame_f), dodge_data.frame_count - 1))
    local frame_hi = math.min(frame_lo + 1, dodge_data.frame_count - 1)
    local frac = frame_f - math.floor(frame_f)

    local frames = dodge_data.frames
    local f_lo = frames[frame_lo]
    local f_hi = frames[frame_hi]
    if not f_lo then return end
    if not f_hi then f_hi = f_lo; frac = 0 end

    local f0 = ui_delta_mode and frames[0] or nil
    local blend = dodge_blend

    for re3_idx, mapping in pairs(bone_map) do
        local d_lo = f_lo[re3_idx]
        if not d_lo then goto continue end

        local ok = pcall(function()
            local j = mapping.joint

            local qw, qx, qy, qz, px, py, pz
            if frac > 0.001 and f_hi[re3_idx] then
                local d_hi = f_hi[re3_idx]
                qw, qx, qy, qz = quat_slerp(
                    d_lo.qw, d_lo.qx, d_lo.qy, d_lo.qz,
                    d_hi.qw, d_hi.qx, d_hi.qy, d_hi.qz,
                    frac)
                px, py, pz = vec3_lerp(
                    d_lo.px, d_lo.py, d_lo.pz,
                    d_hi.px, d_hi.py, d_hi.pz,
                    frac)
            else
                qw, qx, qy, qz = d_lo.qw, d_lo.qx, d_lo.qy, d_lo.qz
                px, py, pz = d_lo.px, d_lo.py, d_lo.pz
            end

            local cur_rot = j:call("get_LocalRotation")
            local cur_pos = j:call("get_LocalPosition")

            if ui_delta_mode and f0 and f0[re3_idx] then
                local r = f0[re3_idx]
                local inv_w, inv_x, inv_y, inv_z = quat_inverse(r.qw, r.qx, r.qy, r.qz)
                local dw, dx, dy, dz = quat_multiply(inv_w, inv_x, inv_y, inv_z, qw, qx, qy, qz)

                if blend < 0.999 then
                    dw, dx, dy, dz = quat_slerp(1, 0, 0, 0, dw, dx, dy, dz, blend)
                end

                qw, qx, qy, qz = quat_multiply(cur_rot.w, cur_rot.x, cur_rot.y, cur_rot.z,
                                                 dw, dx, dy, dz)

                px = cur_pos.x + (px - r.px) * blend
                py = cur_pos.y + (py - r.py) * blend
                pz = cur_pos.z + (pz - r.pz) * blend
            else
                if blend < 0.999 then
                    qw, qx, qy, qz = quat_slerp(
                        cur_rot.w, cur_rot.x, cur_rot.y, cur_rot.z,
                        qw, qx, qy, qz,
                        blend)
                    px, py, pz = vec3_lerp(
                        cur_pos.x, cur_pos.y, cur_pos.z,
                        px, py, pz,
                        blend)
                end
            end

            -- Write rotation
            if ui_use_euler then
                local rx, ry, rz = quat_to_euler_deg(qw, qx, qy, qz)
                j:call("set_LocalEulerAngle", Vector3f.new(rx, ry, rz))
            else
                cur_rot.w = qw
                cur_rot.x = qx
                cur_rot.y = qy
                cur_rot.z = qz
                j:call("set_LocalRotation", cur_rot)
            end

            local bone_name = mapping.name
            if not ui_rotation_only or POSITION_BONES[bone_name] then
                j:call("set_LocalPosition", Vector3f.new(px, py, pz))
            end
        end)

        ::continue::
    end
end

--------------------------------------------------------------------------------
-- 11. CALLBACKS
--------------------------------------------------------------------------------

local last_clock = os.clock()

-- Load all direction dumps at script load
load_all_dodges()

re.on_frame(function()
    local now = os.clock()
    local dt = now - last_clock
    last_clock = now
    dt = math.min(dt, 0.1)

    -- Player detection
    local player = get_player()
    if not player then
        if game_ready then
            dbg("Player lost — clearing state")
            game_ready = false
            player_motion = nil
            player_transform = nil
            player_char_ctrl = nil
            joints_array = nil
            init_done = false
            bone_map = {}
            mapped_bone_count = 0
            dodge_state = "idle"
        end
        return
    end

    if not game_ready then
        game_ready = true
        ready_time = os.clock()
        dbg("Player found, waiting " .. CFG.init_delay .. "s for subsystems...")
        return
    end

    if not init_done then
        if os.clock() - ready_time < CFG.init_delay then return end
        dbg("Init delay elapsed, caching components...")
        if cache_components(player) then
            build_bone_map()
            init_done = true
            dbg("Initialization complete! Ready for dodge. (" ..
                loaded_dir_count .. " directions loaded)")
        else
            dbg("Component caching failed, retrying next frame...")
            ready_time = os.clock()
            game_ready = false
        end
        return
    end

    -- Input: trigger dodge (keyboard key or gamepad button + direction)
    if is_dodge_pressed() and dodge_state == "idle" then
        start_dodge()
    end

    update_dodge_state(dt)
end)

re.on_application_entry("PrepareRendering", function()
    if not init_done then return end
    if dodge_state == "idle" and not ui_force_frame then return end
    pcall(apply_dodge_bones)
    pcall(apply_worldspace_movement)
end)

re.on_draw_ui(function()
    if not imgui.tree_node("CustomAnimFramework v1.4") then return end

    -- Status section
    if not game_ready then
        imgui.text("Status: Waiting for player...")
        imgui.tree_pop()
        return
    end

    if not init_done then
        local elapsed = os.clock() - ready_time
        local remaining = math.max(0, CFG.init_delay - elapsed)
        imgui.text(string.format("Status: Initializing... (%.1fs remaining)", remaining))
        imgui.tree_pop()
        return
    end

    imgui.text("Status: READY")
    imgui.text(string.format("Motion owner: %s | Joints: %d", motion_owner, joint_count))
    local ref_data = dodge_data
    local total_bones = ref_data and ref_data.named_format and #ref_data.bone_names or #BONE_MAP_DATA
    imgui.text(string.format("Mapped bones: %d / %d", mapped_bone_count, total_bones))

    -- Directions loaded
    imgui.separator()
    local dir_status = {}
    for _, dir in ipairs({"back", "front", "left", "right"}) do
        if dodge_directions[dir] then
            dir_status[#dir_status+1] = dir:upper()
        end
    end
    imgui.text("Directions loaded (" .. loaded_dir_count .. "/4): " ..
        (loaded_dir_count > 0 and table.concat(dir_status, ", ") or "NONE"))

    -- Controls summary
    local kb_name = KB_KEY_NAMES[CFG.dodge_key] or string.format("0x%02X", CFG.dodge_key)
    local pad_name = CFG.dodge_pad_button > 0
        and string.format("Pad 0x%X", CFG.dodge_pad_button)
        or "Pad: not set"
    imgui.text("Dodge: " .. kb_name .. " / " .. pad_name ..
        " + WASD or Left Stick for direction")

    -- Per-direction frame counts
    if loaded_dir_count > 0 then
        for _, dir in ipairs({"back", "front", "left", "right"}) do
            local d = dodge_directions[dir]
            if d then
                imgui.text(string.format("  %s: %d frames, %d bones",
                    dir:upper(), d.frame_count, d.bone_count))
            end
        end
    end

    if data_load_error then
        imgui.text("Load error: " .. data_load_error)
        if imgui.button("Retry Load") then
            data_load_error = nil
            load_all_dodges()
            if init_done then build_bone_map() end
        end
    end

    -- Dodge state
    imgui.separator()
    imgui.text(string.format("Dodge: %s [%s] | Frame: %.0f / %d | Blend: %.2f",
        dodge_state,
        dodge_active_dir:upper(),
        dodge_frame,
        dodge_data and dodge_data.frame_count or 0,
        dodge_blend))
    imgui.text(string.format("Dodges: %d | Moved: %.2fm | Wall: %s",
        dodge_count, dodge_moved,
        dodge_wall_hit and string.format("HIT at %.2fm", dodge_wall_dist) or "clear"))

    if imgui.button("Trigger Dodge") then
        start_dodge()
    end
    imgui.same_line()
    if imgui.button("Stop Dodge") then
        dodge_state = "idle"
        dodge_blend = 0
    end

    -- Input Configuration
    imgui.separator()
    if imgui.tree_node("Input Configuration") then
        -- Keyboard dodge key
        local kb_label = KB_KEY_NAMES[CFG.dodge_key] or string.format("0x%02X", CFG.dodge_key)
        if kb_detect_mode then
            imgui.text_colored(">> Press any keyboard key to bind... (ESC to cancel)", 0xFF00FFFF)
            -- Scan for key press
            if is_key_down(0x1B) then  -- ESC cancels
                kb_detect_mode = false
            else
                for code = 0x08, 0x7B do
                    if code ~= 0x1B and is_key_down(code) then
                        CFG.dodge_key = code
                        kb_detect_mode = false
                        dbg("Keyboard dodge key set to: " ..
                            (KB_KEY_NAMES[code] or string.format("0x%02X", code)))
                        break
                    end
                end
            end
        else
            imgui.text("Keyboard: " .. kb_label)
            imgui.same_line()
            if imgui.button("Rebind Key") then
                kb_detect_mode = true
            end
            imgui.same_line()
            if imgui.button("Clear Key") then
                CFG.dodge_key = 0
            end
        end

        -- Gamepad dodge button
        imgui.spacing()
        local pad_label = CFG.dodge_pad_button > 0
            and string.format("Button 0x%X", CFG.dodge_pad_button)
            or "Not set"
        if pad_detect_mode then
            imgui.text_colored(">> Press any gamepad button to bind...", 0xFF00FFFF)
            local current_btns = get_pad_buttons()
            -- Detect NEW button presses (ignore already-held buttons)
            local new_btns = current_btns & (~pad_prev_buttons)
            if new_btns > 0 then
                -- Find lowest set bit (first new button)
                local flag = 1
                while flag <= new_btns do
                    if (new_btns & flag) ~= 0 then
                        CFG.dodge_pad_button = flag
                        dbg(string.format("Gamepad dodge button set to: 0x%X", flag))
                        break
                    end
                    flag = flag << 1
                end
                pad_detect_mode = false
            end
            pad_prev_buttons = current_btns
            if imgui.button("Cancel") then
                pad_detect_mode = false
            end
        else
            imgui.text("Gamepad: " .. pad_label)
            imgui.same_line()
            if imgui.button("Rebind Pad") then
                pad_detect_mode = true
                pad_prev_buttons = get_pad_buttons()  -- snapshot current state
            end
            imgui.same_line()
            if imgui.button("Clear Pad") then
                CFG.dodge_pad_button = 0
            end
        end

        -- Stick deadzone
        imgui.spacing()
        local changed_dz
        changed_dz, CFG.pad_stick_deadzone = imgui.slider_float("Stick deadzone",
            CFG.pad_stick_deadzone, 0.1, 0.9, "%.2f")

        -- Live input monitor
        imgui.spacing()
        imgui.separator()
        imgui.text("Live Input:")
        local sx, sy = get_pad_stick_l()
        local pad_btns = get_pad_buttons()
        imgui.text(string.format("  Pad buttons: 0x%X | Stick: (%.2f, %.2f)",
            pad_btns, sx, sy))
        imgui.text("  Direction: " .. get_input_direction():upper())
        imgui.text("  Dodge trigger: " .. tostring(is_dodge_pressed()))

        imgui.tree_pop()
    end

    -- Settings
    imgui.separator()
    local changed
    changed, ui_delta_mode = imgui.checkbox("Delta mode (additive on RE2 pose)", ui_delta_mode)
    changed, ui_rotation_only = imgui.checkbox("Rotation only (skip positions)", ui_rotation_only)
    changed, ui_enable_movement = imgui.checkbox("Worldspace movement", ui_enable_movement)
    changed, ui_use_euler = imgui.checkbox("Use Euler fallback", ui_use_euler)
    if ui_enable_movement then
        changed, CFG.dodge_distance = imgui.slider_float("Dodge distance",
            CFG.dodge_distance, 0.5, 6.0, "%.1f m")
    end

    -- Frame scrubber
    if dodge_data then
        local was_forced = ui_force_frame
        changed, ui_force_frame = imgui.checkbox("Manual frame control", ui_force_frame)
        if ui_force_frame then
            -- Direction selector for manual mode
            imgui.text("Preview direction:")
            for _, dir in ipairs({"back", "front", "left", "right"}) do
                if dodge_directions[dir] then
                    imgui.same_line()
                    local label = dodge_active_dir == dir
                        and ("[" .. dir:upper() .. "]")
                        or (" " .. dir:upper() .. " ")
                    if imgui.button(label) then
                        dodge_active_dir = dir
                        dodge_data = dodge_directions[dir]
                    end
                end
            end
            changed, ui_manual_frame = imgui.slider_int("Frame",
                ui_manual_frame, 0, dodge_data.frame_count - 1)
            if dodge_state == "idle" then
                dodge_state = "active"
                dodge_blend = 1.0
                if next(rest_pose) == nil then
                    capture_rest_pose()
                end
            end
        elseif was_forced and not ui_force_frame then
            dodge_state = "idle"
            dodge_blend = 0
        end
    end

    -- Bone map inspector
    if imgui.tree_node(string.format("Bone Map (%d mapped)", mapped_bone_count)) then
        if ref_data and ref_data.named_format then
            for _, bname in ipairs(ref_data.bone_names) do
                local m = bone_map[bname]
                if m then
                    local pos_tag = POSITION_BONES[bname] and " [+pos]" or ""
                    imgui.text(string.format("  '%s' → RE2[%3d]%s",
                        bname, m.re2_joint_idx, pos_tag))
                else
                    imgui.text(string.format("  '%s' → UNMAPPED", bname))
                end
            end
        else
            for _, entry in ipairs(BONE_MAP_DATA) do
                local m = bone_map[entry.re3_idx]
                if m then
                    imgui.text(string.format("  RE3[%2d] → RE2[%3d] %s",
                        entry.re3_idx, m.re2_joint_idx, m.name))
                else
                    imgui.text(string.format("  RE3[%2d] → UNMAPPED  %s",
                        entry.re3_idx, entry.name))
                end
            end
        end
        imgui.tree_pop()
    end

    -- All RE2 joints inspector
    if imgui.tree_node(string.format("All RE2 Joints (%d total)", joint_count)) then
        for idx = 0, math.min(joint_count - 1, 199) do
            local j = re2_all_joints[idx]
            if j then
                imgui.text(string.format("  [%3d] %-25s 0x%08x", idx, j.name, j.hash))
            end
        end
        if joint_count > 200 then
            imgui.text("  ... (truncated at 200)")
        end
        imgui.tree_pop()
    end

    -- Frame data inspector
    if dodge_data and imgui.tree_node("Frame Inspector") then
        local frame_idx = math.floor(ui_force_frame and ui_manual_frame or dodge_frame)
        frame_idx = math.max(0, math.min(frame_idx, dodge_data.frame_count - 1))
        local frame = dodge_data.frames[frame_idx]
        if frame then
            imgui.text("Frame " .. frame_idx .. " (" .. dodge_active_dir:upper() .. "):")
            local shown = 0
            for key, mapping in pairs(bone_map) do
                local d = frame[key]
                if d and shown < 12 then
                    imgui.text(string.format("  %s → RE2[%d]: q(%.3f,%.3f,%.3f,%.3f) p(%.3f,%.3f,%.3f)",
                        mapping.name, mapping.re2_joint_idx,
                        d.qw, d.qx, d.qy, d.qz,
                        d.px, d.py, d.pz))
                    shown = shown + 1
                end
            end
            if shown >= 12 then
                imgui.text("  ... (showing first 12)")
            end
        end
        imgui.tree_pop()
    end

    imgui.tree_pop()
end)

log.info("[CAF] CustomAnimFramework v1.4 loaded successfully")
