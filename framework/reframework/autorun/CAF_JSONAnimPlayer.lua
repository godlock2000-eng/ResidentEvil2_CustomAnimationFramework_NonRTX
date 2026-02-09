-- CAF_JSONAnimPlayer.lua — Blender JSON Animation Player
-- Phase 4a: Load JSON animation data exported from Blender,
-- play via bone overrides (set_LocalRotation / set_LocalPosition)
-- in PrepareRendering callback.
--
-- JSON format: { bones: [...], data: [ [[qx,qy,qz,qw,px,py,pz], ...], ... ] }
-- Source coordinates: Blender Z-up right-handed
-- Axis conversion: configurable at runtime via ImGui
-- v1.0

if reframework:get_game_name() ~= "re2" then return end

local MOD = "CAF_JSONAnimPlayer"
local VERSION = "1.0"

log.info("[" .. MOD .. "] v" .. VERSION .. " loading...")

--------------------------------------------------------------------------------
-- 1. STATE
--------------------------------------------------------------------------------

local game_ready = false
local player_motion = nil
local player_transform = nil
local joints_array = nil
local joint_count = 0
local init_done = false
local init_timer = 0

-- Loaded animation
local anim_data = nil        -- parsed JSON table
local anim_loaded = false
local anim_file = ""         -- current file path
local anim_bone_map = {}     -- { [json_bone_index] = { joint=Joint, name=string, re2_idx=int } }
local mapped_count = 0

-- Playback state
local playback = {
    active = false,
    frame = 0,
    speed = 1.0,
    loop = false,
    blend = 1.0,           -- 0=game pose, 1=full override
    blend_target = 1.0,    -- target blend (for smooth transitions)
    blend_speed = 0.05,    -- blend change per frame
    paused = false,
    rotation_only = true,  -- only apply positions to position_bones
}

-- Position bones: these get position overrides even in rotation_only mode
local POSITION_BONES = { COG = true, hips = true }

-- Axis conversion settings (Blender Z-up RH → RE Engine Y-up)
-- Applied to both quaternion and position components from the JSON
-- Each axis can be mapped: 1=+X, 2=+Y, 3=+Z, -1=-X, -2=-Y, -3=-Z
local axis_cfg = {
    preset = 1,  -- 1=Blender→RE (default), 2=Identity, 3=Custom
    -- Position: which Blender axis maps to RE X, Y, Z
    pos_x = 1,   -- RE X = Blender +X
    pos_y = 3,   -- RE Y = Blender +Z (up)
    pos_z = -2,  -- RE Z = Blender -Y (handedness flip)
    -- Quaternion: same mapping applied to qx/qy/qz components
    -- qw stays as qw; qx/qy/qz follow the same axis swap as position
    q_x = 1,
    q_y = 3,
    q_z = -2,
    q_negate_w = false,  -- negate qw (sometimes needed for handedness)
}

-- UI state
local ui_file_input = "CAF_anim_data/test_anim.json"
local ui_show_bones = false
local ui_manual_frame = 0
local ui_use_manual = false
local ui_target_mode = 1  -- 1=Player (only player for now, enemies later)

--------------------------------------------------------------------------------
-- 2. UTILITIES
--------------------------------------------------------------------------------

local function dbg(msg)
    log.info("[" .. MOD .. "] " .. msg)
end

local function getC(go, type_name)
    if not go then return nil end
    local actual_go = go
    if go.get_GameObject then actual_go = go:call("get_GameObject") end
    if not actual_go then return nil end
    return actual_go:call("getComponent(System.Type)", sdk.typeof(type_name))
end

local function get_player()
    local ok, result = pcall(function()
        local pm = sdk.get_managed_singleton(sdk.game_namespace("PlayerManager"))
        if not pm then return nil end
        return pm:call("get_CurrentPlayer")
    end)
    return ok and result or nil
end

-- Quaternion slerp (from v1.4)
local function quat_slerp(w1, x1, y1, z1, w2, x2, y2, z2, t)
    local dot = w1 * w2 + x1 * x2 + y1 * y2 + z1 * z2
    if dot < 0 then
        w2, x2, y2, z2 = -w2, -x2, -y2, -z2
        dot = -dot
    end
    if dot > 0.9995 then
        local w = w1 + (w2 - w1) * t
        local x = x1 + (x2 - x1) * t
        local y = y1 + (y2 - y1) * t
        local z = z1 + (z2 - z1) * t
        local len = math.sqrt(w * w + x * x + y * y + z * z)
        return w / len, x / len, y / len, z / len
    end
    local theta = math.acos(dot)
    local sin_theta = math.sin(theta)
    local a = math.sin((1 - t) * theta) / sin_theta
    local b = math.sin(t * theta) / sin_theta
    return a * w1 + b * w2, a * x1 + b * x2, a * y1 + b * y2, a * z1 + b * z2
end

-- Linear interpolation for vec3
local function vec3_lerp(x1, y1, z1, x2, y2, z2, t)
    return x1 + (x2 - x1) * t, y1 + (y2 - y1) * t, z1 + (z2 - z1) * t
end

--------------------------------------------------------------------------------
-- 3. AXIS CONVERSION
--------------------------------------------------------------------------------

-- Apply axis mapping to a 3-component vector (position or quaternion xyz)
local function apply_axis_map(bx, by, bz, map_x, map_y, map_z)
    local src = { bx, by, bz }
    local function get_mapped(map_val)
        local idx = math.abs(map_val)
        local val = src[idx] or 0
        if map_val < 0 then val = -val end
        return val
    end
    return get_mapped(map_x), get_mapped(map_y), get_mapped(map_z)
end

-- Convert a bone transform from Blender space to RE Engine space
-- Input: qx, qy, qz, qw, px, py, pz (Blender Z-up RH)
-- Output: qx, qy, qz, qw, px, py, pz (RE Engine Y-up)
local function convert_transform(qx, qy, qz, qw, px, py, pz)
    if axis_cfg.preset == 2 then
        -- Identity: no conversion
        return qx, qy, qz, qw, px, py, pz
    end

    -- Apply axis mapping to position
    local rx, ry, rz = apply_axis_map(px, py, pz, axis_cfg.pos_x, axis_cfg.pos_y, axis_cfg.pos_z)

    -- Apply axis mapping to quaternion xyz components
    local rqx, rqy, rqz = apply_axis_map(qx, qy, qz, axis_cfg.q_x, axis_cfg.q_y, axis_cfg.q_z)
    local rqw = qw
    if axis_cfg.q_negate_w then rqw = -rqw end

    return rqx, rqy, rqz, rqw, rx, ry, rz
end

-- Apply a preset to the axis config
local function apply_axis_preset(preset_id)
    axis_cfg.preset = preset_id
    if preset_id == 1 then
        -- Blender → RE Engine (Z-up RH → Y-up)
        -- Position: (bx, by, bz) → (bx, bz, -by)
        -- Quaternion: same axis swap
        axis_cfg.pos_x = 1; axis_cfg.pos_y = 3; axis_cfg.pos_z = -2
        axis_cfg.q_x = 1; axis_cfg.q_y = 3; axis_cfg.q_z = -2
        axis_cfg.q_negate_w = false
    elseif preset_id == 2 then
        -- Identity (no conversion)
        axis_cfg.pos_x = 1; axis_cfg.pos_y = 2; axis_cfg.pos_z = 3
        axis_cfg.q_x = 1; axis_cfg.q_y = 2; axis_cfg.q_z = 3
        axis_cfg.q_negate_w = false
    -- preset 3 = custom (user edits fields directly)
    end
end

--------------------------------------------------------------------------------
-- 4. COMPONENT CACHING
--------------------------------------------------------------------------------

local function cache_components()
    local player = get_player()
    if not player then return false end

    -- IMPORTANT: keep original player ref for joints/transform
    -- Motion may be on a child object, but joints come from the original player's Transform
    local original_player = player

    local motion = getC(player, "via.motion.Motion")
    if not motion then
        -- Search children for Motion component (don't reassign player)
        local t = player:call("get_Transform")
        if t then
            local cc = t:call("get_ChildCount")
            for i = 0, math.min(cc - 1, 20) do
                local ct = t:call("getChild", i)
                if ct then
                    local cg = ct:call("get_GameObject")
                    if cg then
                        motion = getC(cg, "via.motion.Motion")
                        if motion then
                            dbg("Found Motion on child: " .. (cg:call("get_Name") or "?"))
                            break
                        end
                    end
                end
            end
        end
    end
    if not motion then return false end

    -- Use ORIGINAL player's transform for joints (not the child with Motion)
    local transform = original_player:call("get_Transform")
    if not transform then return false end

    local ok, joints = pcall(function()
        local j = transform:call("get_Joints")
        if not j then return nil end
        return j:get_elements()
    end)
    if not ok or not joints then return false end

    player_motion = motion
    player_transform = transform
    joints_array = joints
    joint_count = #joints

    dbg("Components cached: " .. joint_count .. " joints from original player transform")
    return true
end

--------------------------------------------------------------------------------
-- 5. JSON ANIMATION LOADING
--------------------------------------------------------------------------------

local function build_anim_bone_map()
    anim_bone_map = {}
    mapped_count = 0

    if not anim_data or not anim_data.bones or not joints_array then
        dbg("Cannot build bone map: missing data or joints")
        return
    end

    -- Build RE2 joint name → index lookup
    local re2_name_to_idx = {}
    for idx = 0, joint_count - 1 do
        if joints_array[idx + 1] then
            local ok, name = pcall(function()
                return joints_array[idx + 1]:call("get_Name")
            end)
            if ok and name then
                re2_name_to_idx[name] = idx
            end
        end
    end

    -- Map JSON bone names to RE2 joints
    for json_idx, bone_name in ipairs(anim_data.bones) do
        local re2_idx = re2_name_to_idx[bone_name]
        if re2_idx and joints_array[re2_idx + 1] then
            anim_bone_map[json_idx] = {
                name = bone_name,
                re2_idx = re2_idx,
                joint = joints_array[re2_idx + 1],
            }
            mapped_count = mapped_count + 1
        end
    end

    dbg("Bone map: " .. mapped_count .. "/" .. #anim_data.bones .. " bones resolved")

    -- Log unmapped bones
    local unmapped = {}
    for json_idx, bone_name in ipairs(anim_data.bones) do
        if not anim_bone_map[json_idx] then
            table.insert(unmapped, bone_name)
        end
    end
    if #unmapped > 0 and #unmapped <= 20 then
        dbg("Unmapped bones: " .. table.concat(unmapped, ", "))
    elseif #unmapped > 20 then
        dbg("Unmapped bones: " .. #unmapped .. " (too many to list)")
    end
end

local function load_json_anim(file_path)
    dbg("Loading JSON animation: " .. file_path)

    local data = json.load_file(file_path)
    if not data then
        dbg("Failed to load JSON file: " .. file_path)
        return false
    end

    -- Validate format
    if data.format ~= "CAF_AnimData" then
        dbg("Invalid format: expected 'CAF_AnimData', got '" .. tostring(data.format) .. "'")
        return false
    end

    if not data.bones or not data.data then
        dbg("Missing required fields: bones, data")
        return false
    end

    anim_data = data
    anim_file = file_path
    anim_loaded = true

    dbg(string.format("Loaded: %d frames, %d bones, %d fps, source=%s",
        data.frame_count or #data.data,
        data.bone_count or #data.bones,
        data.fps or 30,
        data.source_coords or "unknown"))

    -- Build bone mapping
    build_anim_bone_map()

    return true
end

--------------------------------------------------------------------------------
-- 6. BONE OVERRIDE APPLICATION (PrepareRendering)
--------------------------------------------------------------------------------

local function apply_json_bones()
    if not playback.active or not anim_data or not anim_data.data then return end

    local total_frames = anim_data.frame_count or #anim_data.data
    if total_frames == 0 then return end

    -- Get current frame (0-indexed into data array)
    local frame_f = ui_use_manual and ui_manual_frame or playback.frame
    local frame_lo = math.max(0, math.min(math.floor(frame_f), total_frames - 1))
    local frame_hi = math.min(frame_lo + 1, total_frames - 1)
    local frac = frame_f - math.floor(frame_f)

    -- JSON data arrays are 1-indexed in Lua
    local f_lo = anim_data.data[frame_lo + 1]
    local f_hi = anim_data.data[frame_hi + 1]
    if not f_lo then return end
    if not f_hi then f_hi = f_lo; frac = 0 end

    local blend = playback.blend

    for json_idx, mapping in pairs(anim_bone_map) do
        local bone_data_lo = f_lo[json_idx]
        if not bone_data_lo then goto continue end

        pcall(function()
            local j = mapping.joint

            -- Extract values: [qx, qy, qz, qw, px, py, pz]
            local bqx, bqy, bqz, bqw = bone_data_lo[1], bone_data_lo[2], bone_data_lo[3], bone_data_lo[4]
            local bpx, bpy, bpz = bone_data_lo[5] or 0, bone_data_lo[6] or 0, bone_data_lo[7] or 0

            -- Interpolate between frames if needed
            if frac > 0.001 and f_hi[json_idx] then
                local d_hi = f_hi[json_idx]
                bqw, bqx, bqy, bqz = quat_slerp(
                    bqw, bqx, bqy, bqz,
                    d_hi[4], d_hi[1], d_hi[2], d_hi[3],
                    frac)
                bpx, bpy, bpz = vec3_lerp(
                    bpx, bpy, bpz,
                    d_hi[5] or 0, d_hi[6] or 0, d_hi[7] or 0,
                    frac)
            end

            -- Apply axis conversion
            local qx, qy, qz, qw, px, py, pz = convert_transform(bqx, bqy, bqz, bqw, bpx, bpy, bpz)

            -- Get current game pose
            local cur_rot = j:call("get_LocalRotation")
            local cur_pos = j:call("get_LocalPosition")

            -- Blend with game pose
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

            -- Apply rotation
            cur_rot.w = qw
            cur_rot.x = qx
            cur_rot.y = qy
            cur_rot.z = qz
            j:call("set_LocalRotation", cur_rot)

            -- Apply position (only if the animation actually has position data)
            if anim_data.has_positions then
                local bone_name = mapping.name
                if not playback.rotation_only or POSITION_BONES[bone_name] then
                    j:call("set_LocalPosition", Vector3f.new(px, py, pz))
                end
            end
        end)

        ::continue::
    end
end

--------------------------------------------------------------------------------
-- 7. FRAME LOOP
--------------------------------------------------------------------------------

re.on_frame(function()
    local player = get_player()

    if not player then
        if game_ready then
            game_ready = false
            init_done = false
            player_motion = nil
            player_transform = nil
            joints_array = nil
            anim_bone_map = {}
            mapped_count = 0
            playback.active = false
        end
        return
    end

    if not game_ready then
        game_ready = true
        init_timer = os.clock()
        return
    end

    -- Delay init to let subsystems settle
    if not init_done then
        if os.clock() - init_timer < 3.0 then return end
        if cache_components() then
            init_done = true
            -- Rebuild bone map if animation was already loaded
            if anim_loaded and anim_data then
                build_anim_bone_map()
            end
        else
            init_timer = os.clock()
            game_ready = false
        end
        return
    end

    -- Advance playback
    if playback.active and not playback.paused and not ui_use_manual then
        local total = anim_data and (anim_data.frame_count or #anim_data.data) or 0
        if total > 0 then
            playback.frame = playback.frame + playback.speed
            if playback.frame >= total then
                if playback.loop then
                    playback.frame = playback.frame - total
                else
                    playback.frame = total - 1
                    playback.active = false
                    dbg("Playback finished")
                end
            elseif playback.frame < 0 then
                if playback.loop then
                    playback.frame = playback.frame + total
                else
                    playback.frame = 0
                end
            end
        end
    end

    -- Smooth blend transitions
    if playback.blend ~= playback.blend_target then
        if playback.blend < playback.blend_target then
            playback.blend = math.min(playback.blend + playback.blend_speed, playback.blend_target)
        else
            playback.blend = math.max(playback.blend - playback.blend_speed, playback.blend_target)
        end
    end
end)

-- PrepareRendering: apply bone overrides
re.on_application_entry("PrepareRendering", function()
    if not init_done then return end
    if not playback.active and not ui_use_manual then return end
    pcall(apply_json_bones)
end)

--------------------------------------------------------------------------------
-- 8. UI
--------------------------------------------------------------------------------

re.on_draw_ui(function()
    if not imgui.tree_node(MOD .. " v" .. VERSION) then return end

    if not game_ready or not init_done then
        imgui.text_colored("Waiting for player...", 0xFF00CCFF)
        imgui.tree_pop()
        return
    end

    local changed

    -- === File Loading ===
    imgui.text_colored("=== Load Animation ===", 0xFF00FFFF)
    changed, ui_file_input = imgui.input_text("JSON File", ui_file_input)
    imgui.text("(relative to reframework/data/)")

    if imgui.button("Load") then
        if ui_file_input ~= "" then
            load_json_anim(ui_file_input)
        end
    end

    if anim_loaded and anim_data then
        imgui.same_line()
        imgui.text_colored("OK", 0xFF00FF00)
        imgui.text(string.format("  %d frames, %d bones (%d mapped), %d fps",
            anim_data.frame_count or #anim_data.data,
            #anim_data.bones,
            mapped_count,
            anim_data.fps or 30))
        if anim_data.action_name and anim_data.action_name ~= "" then
            imgui.text("  Action: " .. anim_data.action_name)
        end
    end

    imgui.spacing()
    imgui.separator()

    -- === Playback ===
    imgui.text_colored("=== Playback ===", 0xFF00FFFF)

    if anim_loaded and anim_data then
        local total = anim_data.frame_count or #anim_data.data

        if playback.active then
            imgui.text_colored(string.format("PLAYING: frame %.0f / %d",
                playback.frame, total), 0xFF00FF00)
        else
            imgui.text(string.format("Stopped: frame %.0f / %d", playback.frame, total))
        end

        if imgui.button(playback.active and "STOP" or "PLAY") then
            if playback.active then
                playback.active = false
            else
                playback.active = true
                if playback.frame >= total - 1 then
                    playback.frame = 0
                end
            end
        end
        imgui.same_line()
        if imgui.button(playback.paused and "Resume" or "Pause") then
            playback.paused = not playback.paused
        end
        imgui.same_line()
        if imgui.button("Reset") then
            playback.frame = 0
        end

        changed, playback.speed = imgui.slider_float("Speed", playback.speed, -2.0, 3.0, "%.2f")
        changed, playback.loop = imgui.checkbox("Loop", playback.loop)
        changed, playback.blend_target = imgui.slider_float("Blend", playback.blend_target, 0.0, 1.0, "%.2f")
        changed, playback.rotation_only = imgui.checkbox("Rotation only (pos on COG/hips)", playback.rotation_only)

        -- Manual frame scrubber
        changed, ui_use_manual = imgui.checkbox("Manual frame", ui_use_manual)
        if ui_use_manual then
            changed, ui_manual_frame = imgui.slider_float("Frame##manual", ui_manual_frame, 0, math.max(total - 1, 1), "%.1f")
        end
    else
        imgui.text("No animation loaded")
    end

    imgui.spacing()
    imgui.separator()

    -- === Axis Conversion ===
    if imgui.tree_node("Axis Conversion") then
        imgui.text_colored("Blender Z-up RH -> RE Engine Y-up", 0xFF00FFFF)

        local preset_labels = { "Blender -> RE (default)", "Identity (no conversion)", "Custom" }
        local old_preset = axis_cfg.preset
        changed, axis_cfg.preset = imgui.combo("Preset", axis_cfg.preset, preset_labels)
        if changed and axis_cfg.preset ~= old_preset then
            apply_axis_preset(axis_cfg.preset)
        end

        if axis_cfg.preset == 3 then
            imgui.text("Axis values: 1=+X 2=+Y 3=+Z  -1=-X -2=-Y -3=-Z")
            imgui.spacing()

            imgui.text("Position mapping:")
            changed, axis_cfg.pos_x = imgui.slider_int("RE X = Blender##px", axis_cfg.pos_x, -3, 3)
            changed, axis_cfg.pos_y = imgui.slider_int("RE Y = Blender##py", axis_cfg.pos_y, -3, 3)
            changed, axis_cfg.pos_z = imgui.slider_int("RE Z = Blender##pz", axis_cfg.pos_z, -3, 3)

            imgui.spacing()
            imgui.text("Quaternion mapping:")
            changed, axis_cfg.q_x = imgui.slider_int("RE qX = Blender##qx", axis_cfg.q_x, -3, 3)
            changed, axis_cfg.q_y = imgui.slider_int("RE qY = Blender##qy", axis_cfg.q_y, -3, 3)
            changed, axis_cfg.q_z = imgui.slider_int("RE qZ = Blender##qz", axis_cfg.q_z, -3, 3)
            changed, axis_cfg.q_negate_w = imgui.checkbox("Negate qW", axis_cfg.q_negate_w)
        else
            imgui.text(string.format("Pos: X=%+d Y=%+d Z=%+d", axis_cfg.pos_x, axis_cfg.pos_y, axis_cfg.pos_z))
            imgui.text(string.format("Quat: X=%+d Y=%+d Z=%+d W=%s",
                axis_cfg.q_x, axis_cfg.q_y, axis_cfg.q_z,
                axis_cfg.q_negate_w and "neg" or "pos"))
        end

        imgui.tree_pop()
    end

    imgui.spacing()
    imgui.separator()

    -- === Bone Map ===
    if anim_loaded and imgui.tree_node("Bone Map (" .. mapped_count .. " mapped)") then
        if anim_data and anim_data.bones then
            for json_idx, bone_name in ipairs(anim_data.bones) do
                local m = anim_bone_map[json_idx]
                if m then
                    imgui.text_colored(string.format("  [%2d] %s -> RE2[%d]",
                        json_idx, bone_name, m.re2_idx), 0xFF00FF00)
                else
                    imgui.text_colored(string.format("  [%2d] %s -> UNMAPPED",
                        json_idx, bone_name), 0xFF4444FF)
                end
            end
        end
        imgui.tree_pop()
    end

    imgui.spacing()
    imgui.separator()

    -- === Joint Inspector ===
    if imgui.tree_node("RE2 Joints (" .. joint_count .. ")") then
        for idx = 0, math.min(joint_count - 1, 99) do
            if joints_array[idx + 1] then
                pcall(function()
                    local name = joints_array[idx + 1]:call("get_Name") or "?"
                    imgui.text(string.format("  [%3d] %s", idx, name))
                end)
            end
        end
        if joint_count > 100 then
            imgui.text("  ... (" .. (joint_count - 100) .. " more)")
        end
        imgui.tree_pop()
    end

    imgui.tree_pop()
end)

log.info("[" .. MOD .. "] v" .. VERSION .. " loaded successfully")
