-- CAF_NativeDodge.lua — Native Dodge Animation System
-- v2.0.2 — Fixes: endFrame fallback, %d→%.0f format, FSM-safe end_dodge ordering.
-- Architecture: pause MotionFsm2, changeMotion ONCE, engine-native playback.

if reframework:get_game_name() ~= "re2" then return end

log.info("[NativeDodge] v2.0.2 loading...")

--------------------------------------------------------------------------------
-- 1. CONFIGURATION
--------------------------------------------------------------------------------

local KNOWN_END_FRAME = 179
local BASE_FPS = 60.0

local CFG = {
    init_delay = 3.0,
    dodge_cooldown = 0.5,
    dodge_key = 0x56,           -- V key
    dodge_pad_button = 0,
    pad_stick_deadzone = 0.5,
    blend_frames = 2.0,
    dodge_distance = 2.0,
    move_start = 0.18,
    move_end = 0.65,
    max_dodge_time = 8.0,
    speed = 3.0,                -- engine-native speed multiplier via set_Speed

    bank_ids = {
        front = 900, back = 901, left = 902, right = 903,
    },
    bank_paths = {
        front = "CAF_custom/dodge_front.motbank",
        back  = "CAF_custom/dodge_back.motbank",
        left  = "CAF_custom/dodge_left.motbank",
        right = "CAF_custom/dodge_right.motbank",
    },
    debug_log = true,
}

local KEY_W, KEY_A, KEY_S, KEY_D = 0x57, 0x41, 0x53, 0x44

--------------------------------------------------------------------------------
-- 2. STATE
--------------------------------------------------------------------------------

local game_ready = false
local ready_time = 0
local init_done = false

local player_go = nil
local player_motion = nil
local player_xform = nil
local player_cc = nil
local player_fsm2 = nil         -- MotionFsm2 component (for pausing)

local banks_loaded = false
local banks_load_error = nil
local loaded_directions = {}
local loaded_count = 0

local dodge_state = "idle"      -- "idle" | "playing" | "recovering"
local dodge_dir = "back"
local dodge_start_time = 0
local dodge_count = 0
local last_dodge_time = -999
local dodge_end_frame = KNOWN_END_FRAME
local dodge_end_time = 0
local endframe_updated = false   -- have we confirmed endFrame from engine?

local dodge_key_was_down = false

-- FSM control
local fsm_was_paused = false    -- original FSM paused state (for restore)
local fsm_was_enabled = true    -- original FSM enabled state
local fsm_paused_by_us = false  -- did WE pause/disable the FSM?
local fsm_method = "none"       -- which disable method worked

-- Root motion
local dodge_move_dir = nil
local dodge_start_pos = nil
local dodge_moved = 0
local dodge_last_set_pos = nil
local dodge_wall_hit = false
local dodge_wall_dist = 999
local move_enabled = true

local dodge_layer = nil

-- Debug (always numbers, never nil)
local dbg_cur_bank = 0
local dbg_engine_frame = 0
local dbg_engine_speed = 0
local dbg_state_end = false
local dbg_last_error = ""

--------------------------------------------------------------------------------
-- 3. UTILITIES
--------------------------------------------------------------------------------

local function dbg(msg)
    if CFG.debug_log then
        log.info("[NativeDodge] " .. msg)
    end
end

local function get_player()
    local ok, result = pcall(function()
        local pm = sdk.get_managed_singleton(sdk.game_namespace("PlayerManager"))
        if not pm then return nil end
        return pm:call("get_CurrentPlayer")
    end)
    return ok and result or nil
end

local function getC(go, type_name)
    if not go then return nil end
    local actual_go = go
    if go.get_GameObject then actual_go = go:call("get_GameObject") end
    if not actual_go then return nil end
    local ok, c = pcall(function()
        return actual_go:call("getComponent(System.Type)", sdk.typeof(type_name))
    end)
    return ok and c or nil
end

--------------------------------------------------------------------------------
-- 4. PLAYER & COMPONENT CACHING
--------------------------------------------------------------------------------

local function cache_player()
    local pl = get_player()
    if not pl then return false end

    local motion = getC(pl, "via.motion.Motion")
    local motion_go = pl
    if not motion then
        local ok, t = pcall(function() return pl:call("get_Transform") end)
        if ok and t then
            local cc = t:call("get_ChildCount")
            for i = 0, math.min(cc - 1, 20) do
                local ct = t:call("getChild", i)
                if ct then
                    local cg = ct:call("get_GameObject")
                    if cg then
                        motion = getC(cg, "via.motion.Motion")
                        if motion then motion_go = cg; break end
                    end
                end
            end
        end
    end
    if not motion then return false end

    local xform = nil
    pcall(function() xform = pl:call("get_Transform") end)
    if not xform then return false end

    -- CharacterController (multiple fallback strategies)
    local cc = nil
    local cc_src = "none"
    pcall(function()
        cc = pl:call("getComponent(System.Type)",
            sdk.typeof("via.physics.CharacterController"))
        if cc then cc_src = "direct" end
    end)
    if not cc then
        pcall(function()
            local scc = pl:call("getComponent(System.Type)",
                sdk.typeof("app.ropeway.survivor.SurvivorCharacterController"))
            if scc then
                cc = scc:get_field("<CharacterController>k__BackingField")
                if cc then cc_src = "SurvivorCC" end
            end
        end)
    end
    if not cc then
        pcall(function()
            local child_count = xform:call("get_ChildCount")
            for i = 0, math.min(child_count - 1, 10) do
                local ct = xform:call("getChild", i)
                if ct then
                    local cg = ct:call("get_GameObject")
                    if cg then
                        cc = cg:call("getComponent(System.Type)",
                            sdk.typeof("via.physics.CharacterController"))
                        if cc then cc_src = "child"; break end
                    end
                end
            end
        end)
    end
    if not cc then
        pcall(function()
            local go = pl:call("get_GameObject")
            if go then
                cc = go:call("getComponent(System.Type)",
                    sdk.typeof("via.physics.CharacterController"))
                if cc then cc_src = "get_GameObject" end
            end
        end)
    end

    -- MotionFsm2 — try multiple access paths
    local fsm2 = nil
    local fsm2_src = "none"
    pcall(function()
        local actual = motion_go
        if motion_go.get_GameObject then actual = motion_go:call("get_GameObject") end
        if actual then
            fsm2 = actual:call("getComponent(System.Type)", sdk.typeof("via.motion.MotionFsm2"))
            if fsm2 then fsm2_src = "motion_go" end
        end
    end)
    if not fsm2 then
        pcall(function()
            fsm2 = pl:call("getComponent(System.Type)", sdk.typeof("via.motion.MotionFsm2"))
            if fsm2 then fsm2_src = "player" end
        end)
    end
    if not fsm2 then
        pcall(function()
            local go = pl:call("get_GameObject")
            if go then
                fsm2 = go:call("getComponent(System.Type)", sdk.typeof("via.motion.MotionFsm2"))
                if fsm2 then fsm2_src = "player_go" end
            end
        end)
    end
    if not fsm2 then
        pcall(function()
            local child_count = xform:call("get_ChildCount")
            for i = 0, math.min(child_count - 1, 10) do
                local ct = xform:call("getChild", i)
                if ct then
                    local cg = ct:call("get_GameObject")
                    if cg then
                        fsm2 = cg:call("getComponent(System.Type)", sdk.typeof("via.motion.MotionFsm2"))
                        if fsm2 then fsm2_src = "child_" .. i; break end
                    end
                end
            end
        end)
    end

    player_go = motion_go
    player_motion = motion
    player_xform = xform
    player_cc = cc
    player_fsm2 = fsm2

    dbg("Player cached: CC=" .. cc_src .. " FSM2=" .. fsm2_src)
    return true
end

--------------------------------------------------------------------------------
-- 5. DYNAMICMOTIONBANK LOADING
--------------------------------------------------------------------------------

local function load_banks()
    if not player_motion then
        banks_load_error = "No player motion"; return false
    end
    if banks_loaded and loaded_count > 0 then
        dbg("Banks already loaded"); return true
    end

    loaded_directions = {}
    loaded_count = 0
    banks_load_error = nil

    local dmbc = nil
    pcall(function()
        local actual_go = player_go
        if player_go.get_GameObject then actual_go = player_go:call("get_GameObject") end
        if actual_go then
            dmbc = actual_go:call("getComponent(System.Type)",
                sdk.typeof(sdk.game_namespace("DynamicMotionBankController")))
        end
    end)

    for _, dir in ipairs({"front", "back", "left", "right"}) do
        local path = CFG.bank_paths[dir]
        local bank_id = CFG.bank_ids[dir]
        local ok, err = pcall(function()
            local res = sdk.create_resource("via.motion.MotionBankResource", path)
            if not res then dbg("WARN: resource nil for " .. dir); return end
            res = res:add_ref()
            local holder = res:create_holder("via.motion.MotionBankResourceHolder")
            if not holder then dbg("WARN: holder nil for " .. dir); return end
            holder = holder:add_ref()
            local db = sdk.create_instance("via.motion.DynamicMotionBank"):add_ref()
            db:call("set_MotionBank", holder)
            db:call("set_Priority", 200)
            if dmbc then pcall(function() dmbc:call("addDynamicMotionBank", db) end) end
            local c = player_motion:call("getDynamicMotionBankCount")
            player_motion:call("setDynamicMotionBankCount", c + 1)
            player_motion:call("setDynamicMotionBank", c, db)
            loaded_directions[dir] = true
            loaded_count = loaded_count + 1
            dbg(dir:upper() .. " bank loaded (id=" .. bank_id .. ", idx=" .. c .. ")")
        end)
        if not ok then dbg("ERROR loading " .. dir .. ": " .. tostring(err)) end
    end

    banks_loaded = loaded_count > 0
    if banks_loaded then
        dbg("Banks loaded: " .. loaded_count .. "/4, DynBankCount=" ..
            player_motion:call("getDynamicMotionBankCount"))
    else
        banks_load_error = "No banks loaded"
    end
    return banks_loaded
end

--------------------------------------------------------------------------------
-- 6. FSM CONTROL (pause/unpause MotionFsm2)
--------------------------------------------------------------------------------

local function pause_fsm()
    if not player_fsm2 then
        dbg("WARN: No FSM2 found, cannot pause")
        return false
    end
    if fsm_paused_by_us then return true end

    fsm_method = "none"

    -- Save original state BEFORE modifying anything
    local orig_paused = false
    local orig_enabled = true
    pcall(function()
        local p = player_fsm2:call("get_Paused")
        orig_paused = p and true or false
    end)
    pcall(function()
        local e = player_fsm2:call("get_Enabled")
        orig_enabled = (e == nil) and true or (e and true or false)
    end)
    fsm_was_paused = orig_paused
    fsm_was_enabled = orig_enabled
    dbg("FSM original state: paused=" .. tostring(orig_paused) .. " enabled=" .. tostring(orig_enabled))

    -- Try set_Paused first (preserves FSM state for clean resume)
    local paused_ok = false
    pcall(function()
        player_fsm2:call("set_Paused", true)
        paused_ok = true
    end)

    -- Also disable as belt-and-suspenders
    local disabled_ok = false
    pcall(function()
        player_fsm2:call("set_Enabled", false)
        disabled_ok = true
    end)

    if paused_ok and disabled_ok then
        fsm_method = "paused+disabled"
    elseif paused_ok then
        fsm_method = "paused"
    elseif disabled_ok then
        fsm_method = "disabled"
    else
        fsm_method = "FAILED"
    end

    fsm_paused_by_us = true
    dbg("FSM paused: method=" .. fsm_method)
    return paused_ok or disabled_ok
end

local function unpause_fsm()
    if not player_fsm2 or not fsm_paused_by_us then return end

    -- Always restore to running state (paused=false, enabled=true)
    pcall(function()
        player_fsm2:call("set_Enabled", true)
    end)
    pcall(function()
        player_fsm2:call("set_Paused", false)
    end)

    -- Verify restore worked
    local check_p, check_e = "?", "?"
    pcall(function() check_p = tostring(player_fsm2:call("get_Paused")) end)
    pcall(function() check_e = tostring(player_fsm2:call("get_Enabled")) end)

    fsm_paused_by_us = false
    dbg("FSM restored: paused=" .. check_p .. " enabled=" .. check_e)
end

--------------------------------------------------------------------------------
-- 7. INPUT HANDLING
--------------------------------------------------------------------------------

local function is_key_down(keycode)
    if not keycode or keycode == 0 then return false end
    local ok, result = pcall(function() return reframework:is_key_down(keycode) end)
    return ok and result
end

local gp_typedef = sdk.find_type_definition("via.hid.GamePad")
local cached_pad, cached_pad_time = nil, 0

local function get_gamepad()
    local now = os.clock()
    if cached_pad and (now - cached_pad_time) < 2.0 then return cached_pad end
    local ok, pad = pcall(function()
        if not gp_typedef then return nil end
        local gp = sdk.get_native_singleton("via.hid.Gamepad")
        if not gp then return nil end
        return sdk.call_native_func(gp, gp_typedef, "getMergedDevice", 0)
    end)
    if ok and pad then cached_pad = pad; cached_pad_time = now end
    return ok and pad or nil
end

local function get_pad_buttons()
    local pad = get_gamepad()
    if not pad then return 0 end
    local ok, b = pcall(function() return pad:call("get_Button") end)
    return (ok and b) and (tonumber(b) or 0) or 0
end

local function get_pad_stick_l()
    local pad = get_gamepad()
    if not pad then return 0, 0 end
    local ok, axis = pcall(function() return pad:call("get_AxisL") end)
    if ok and axis then return axis.x or 0, axis.y or 0 end
    return 0, 0
end

local function get_input_direction()
    if is_key_down(KEY_W) then return "front" end
    if is_key_down(KEY_A) then return "left" end
    if is_key_down(KEY_D) then return "right" end
    if is_key_down(KEY_S) then return "back" end
    local sx, sy = get_pad_stick_l()
    local mag = math.sqrt(sx * sx + sy * sy)
    if mag > CFG.pad_stick_deadzone then
        if math.abs(sy) >= math.abs(sx) then return sy > 0 and "front" or "back"
        else return sx > 0 and "right" or "left" end
    end
    return "back"
end

local function is_dodge_pressed()
    if CFG.dodge_key > 0 and is_key_down(CFG.dodge_key) then return true end
    if CFG.dodge_pad_button > 0 then
        local b = get_pad_buttons()
        if b ~= 0 and (b & CFG.dodge_pad_button) ~= 0 then return true end
    end
    return false
end

local kb_detect_mode = false
local pad_detect_mode = false
local pad_prev_buttons = 0
local KB_KEY_NAMES = {
    [0]="None",[0x08]="Bksp",[0x09]="Tab",[0x0D]="Enter",
    [0x10]="Shift",[0x11]="Ctrl",[0x12]="Alt",[0x1B]="Esc",[0x20]="Space",
    [0x41]="A",[0x42]="B",[0x43]="C",[0x44]="D",[0x45]="E",[0x46]="F",
    [0x47]="G",[0x48]="H",[0x49]="I",[0x4A]="J",[0x4B]="K",[0x4C]="L",
    [0x4D]="M",[0x4E]="N",[0x4F]="O",[0x50]="P",[0x51]="Q",[0x52]="R",
    [0x53]="S",[0x54]="T",[0x55]="U",[0x56]="V",[0x57]="W",[0x58]="X",
    [0x59]="Y",[0x5A]="Z",
    [0x70]="F1",[0x71]="F2",[0x72]="F3",[0x73]="F4",[0x74]="F5",[0x75]="F6",
    [0x76]="F7",[0x77]="F8",[0x78]="F9",[0x79]="F10",[0x7A]="F11",[0x7B]="F12",
}

--------------------------------------------------------------------------------
-- 8. DODGE STATE MACHINE
--------------------------------------------------------------------------------

local move_log_count = 0

local function end_dodge(reason)
    if dodge_state ~= "playing" then return end

    -- CRITICAL: Reset layer speed to 1.0 BEFORE unpausing FSM.
    -- Otherwise FSM resumes but layer keeps our speed multiplier → all game anims play fast.
    if dodge_layer then
        pcall(function() dodge_layer:call("set_Speed", 1.0) end)
    end

    -- Restore FSM FIRST, before any logging that might error.
    -- v2.0.1 bug: dbg() with %d on a float crashed Lua 5.4, preventing unpause_fsm().
    unpause_fsm()

    -- Now safe to log (FSM is already restored even if this pcall fails)
    pcall(function()
        local elapsed = os.clock() - dodge_start_time
        dbg("Dodge #" .. dodge_count .. " " .. dodge_dir:upper() ..
            " ended: " .. reason ..
            string.format(" (%.2fs frame=%.1f/%.0f moved=%.2fm bank=%.0f fsm=%s speed=%.1f)",
                elapsed, dbg_engine_frame, dodge_end_frame, dodge_moved,
                dbg_cur_bank, fsm_method, CFG.speed))
    end)

    dodge_state = "recovering"
    dodge_end_time = os.clock()
    dodge_layer = nil
end

local function start_dodge()
    if dodge_state ~= "idle" then return end
    local now = os.clock()
    if now - last_dodge_time < CFG.dodge_cooldown then return end

    local dir = get_input_direction()
    if not loaded_directions[dir] then
        for d, _ in pairs(loaded_directions) do dir = d; break end
    end
    if not loaded_directions[dir] then return end

    -- Movement direction
    dodge_move_dir = nil
    dodge_start_pos = nil
    dodge_moved = 0
    dodge_last_set_pos = nil
    dodge_wall_hit = false
    dodge_wall_dist = 999
    endframe_updated = false

    pcall(function()
        if not player_xform then return end
        local rot = player_xform:call("get_Rotation")
        if not rot then return end
        local back_x = -(2.0 * (rot.x * rot.z + rot.w * rot.y))
        local back_z = -(1.0 - 2.0 * (rot.x * rot.x + rot.y * rot.y))
        local len = math.sqrt(back_x * back_x + back_z * back_z)
        if len < 0.001 then return end
        back_x = back_x / len; back_z = back_z / len
        if dir == "back" then     dodge_move_dir = { x = back_x, z = back_z }
        elseif dir == "front" then dodge_move_dir = { x = -back_x, z = -back_z }
        elseif dir == "left" then  dodge_move_dir = { x = -back_z, z = back_x }
        elseif dir == "right" then dodge_move_dir = { x = back_z, z = -back_x }
        end
        local pos = player_xform:call("get_Position")
        if pos then dodge_start_pos = { x = pos.x, y = pos.y, z = pos.z } end
    end)

    -- Step 1: Pause FSM so it can't override our animation
    local fsm_ok = pause_fsm()
    if not fsm_ok then
        dbg("WARN: FSM pause failed, dodge may be overridden")
    end

    -- Step 2: Get layer and call changeMotion ONCE
    local bank_id = CFG.bank_ids[dir]
    local play_ok = false

    pcall(function()
        local layer = player_motion:call("getLayer", 0)
        if not layer then dbg("ERROR: getLayer(0) nil"); return end
        dodge_layer = layer

        -- Single changeMotion call — engine plays natively from here
        layer:call("changeMotion", bank_id, 0, 0.0, CFG.blend_frames, 2, 0)

        -- Explicitly reset frame to 0 (layer may retain frame from previous dodge)
        layer:call("set_Frame", 0.0)

        -- Set engine-native playback speed
        layer:call("set_Speed", CFG.speed)

        -- Use KNOWN_END_FRAME — get_EndFrame() is unreliable right after changeMotion.
        -- (Engine may not have loaded new animation yet, returns previous anim's endFrame.)
        -- We'll update from engine after 0.15s in update_dodge if it returns > 100.
        dodge_end_frame = KNOWN_END_FRAME

        play_ok = true
        dbg(dir:upper() .. " changeMotion(bank=" .. bank_id ..
            ", speed=" .. CFG.speed .. ", endFrame=" .. dodge_end_frame .. ")")
    end)

    if not play_ok then
        dbg("ERROR: changeMotion failed")
        unpause_fsm()  -- restore FSM on failure
        return
    end

    dodge_state = "playing"
    dodge_dir = dir
    dodge_start_time = now
    last_dodge_time = now
    dodge_count = dodge_count + 1
    dbg("Dodge #" .. dodge_count .. " " .. dir:upper() .. " started (fsm=" .. fsm_method .. ")")
end

local function update_dodge()
    -- Handle recovery state
    if dodge_state == "recovering" then
        if os.clock() - dodge_end_time > 0.15 then
            dodge_state = "idle"
        end
        return
    end

    if dodge_state ~= "playing" then return end
    if not dodge_layer then end_dodge("layer_lost"); return end

    local elapsed = os.clock() - dodge_start_time

    -- Read engine state (lightweight — no set_Frame, no changeMotion)
    local read_ok = pcall(function()
        local f = dodge_layer:call("get_Frame")
        dbg_engine_frame = tonumber(f) or 0
        local b = dodge_layer:call("get_BankID")
        dbg_cur_bank = tonumber(b) or 0
        local s = dodge_layer:call("get_Speed")
        dbg_engine_speed = tonumber(s) or 0
    end)

    if not read_ok then
        dbg("ERROR: layer read failed at " .. string.format("%.2fs", elapsed))
        end_dodge("layer_error")
        return
    end

    -- Update endFrame from engine after animation has had time to load (once)
    -- get_EndFrame() is unreliable immediately after changeMotion
    if not endframe_updated and elapsed > 0.15 then
        pcall(function()
            local ef = dodge_layer:call("get_EndFrame")
            local ef_num = tonumber(ef) or 0
            if ef_num > 100 then
                dodge_end_frame = ef_num
                dbg("EndFrame updated from engine: " .. string.format("%.1f", ef_num))
            end
        end)
        endframe_updated = true
    end

    -- End detection with grace period (0.2s to ensure animation is playing)
    local ended = false

    if elapsed > 0.2 then
        -- Engine-native end detection
        pcall(function()
            local se = dodge_layer:call("get_StateEndOfMotion")
            dbg_state_end = se and true or false
            if dbg_state_end then ended = true end
        end)

        -- Backup: frame-based end detection
        if not ended and dbg_engine_frame >= dodge_end_frame - 1 then
            ended = true
        end

        -- Backup: bank changed (FSM took over despite our pause)
        if not ended and dbg_cur_bank ~= 0 and dbg_cur_bank ~= CFG.bank_ids[dodge_dir] then
            dbg("Bank changed to " .. string.format("%.0f", dbg_cur_bank) .. ", FSM took over")
            ended = true
        end
    end

    if ended then
        end_dodge("complete")
        return
    end

    -- Safety timeout
    if elapsed > CFG.max_dodge_time then
        end_dodge("timeout")
    end
end

--------------------------------------------------------------------------------
-- 9. ROOT MOTION (PrepareRendering)
--------------------------------------------------------------------------------

local function apply_root_motion()
    if dodge_state ~= "playing" then return end
    if not move_enabled then return end
    if not dodge_move_dir or not dodge_start_pos or not player_xform then return end
    if dodge_wall_hit then return end

    -- Use engine's actual frame for progress (framerate-independent)
    local progress = dbg_engine_frame / dodge_end_frame

    -- Wall detection
    if dodge_last_set_pos and player_cc and dodge_moved > 0.3 then
        pcall(function()
            local actual = player_xform:call("get_Position")
            if actual then
                local dx = actual.x - dodge_last_set_pos.x
                local dz = actual.z - dodge_last_set_pos.z
                local drift = math.sqrt(dx * dx + dz * dz)
                if drift > 0.15 then
                    dodge_wall_hit = true
                    dodge_wall_dist = dodge_moved
                    player_cc:call("warp")
                    dbg(string.format("WALL HIT: drift=%.2fm at dist=%.2fm", drift, dodge_moved))
                end
            end
        end)
        if dodge_wall_hit then return end
    end

    if progress < CFG.move_start or progress > CFG.move_end then return end

    local move_progress = (progress - CFG.move_start) / (CFG.move_end - CFG.move_start)
    move_progress = math.min(1.0, math.max(0.0, move_progress))
    local eased = move_progress * move_progress * (3.0 - 2.0 * move_progress)
    local target_dist = CFG.dodge_distance * eased
    dodge_moved = target_dist

    pcall(function()
        local new_x = dodge_start_pos.x + dodge_move_dir.x * target_dist
        local new_y = dodge_start_pos.y
        local new_z = dodge_start_pos.z + dodge_move_dir.z * target_dist
        player_xform:call("set_Position", Vector3f.new(new_x, new_y, new_z))
        if player_cc then player_cc:call("warp") end
        dodge_last_set_pos = { x = new_x, y = new_y, z = new_z }
        if move_log_count < 5 then
            dbg(string.format("MOVE %s frame=%.1f dist=%.2f (%.0f%%)",
                dodge_dir:upper(), dbg_engine_frame, target_dist, progress * 100))
            move_log_count = move_log_count + 1
        end
    end)
end

--------------------------------------------------------------------------------
-- 10. CALLBACKS
--------------------------------------------------------------------------------

re.on_frame(function()
    local pl = get_player()
    if not pl then
        if game_ready then
            if dodge_state == "playing" then end_dodge("player_lost") end
            if dodge_state == "recovering" then dodge_state = "idle" end
            game_ready = false; init_done = false; banks_loaded = false
            player_motion = nil; player_xform = nil; player_cc = nil
            player_fsm2 = nil; dodge_layer = nil
        end
        return
    end

    if not game_ready then
        game_ready = true; ready_time = os.clock(); return
    end

    if not init_done then
        if os.clock() - ready_time < CFG.init_delay then return end
        if cache_player() then
            if load_banks() then
                init_done = true
                dbg("Init complete! " .. loaded_count .. "/4 directions, FSM2=" ..
                    (player_fsm2 and "FOUND" or "NOT FOUND"))
            else
                game_ready = false
            end
        else
            game_ready = false
        end
        return
    end

    -- Safety: if FSM somehow still paused but we're not playing, force unpause
    if fsm_paused_by_us and dodge_state ~= "playing" then
        dbg("SAFETY: FSM still paused in state=" .. dodge_state .. ", restoring")
        unpause_fsm()
    end

    -- Edge-triggered dodge
    local pressed = is_dodge_pressed()
    if pressed and not dodge_key_was_down and dodge_state == "idle" then
        move_log_count = 0
        start_dodge()
    end
    dodge_key_was_down = pressed

    update_dodge()
end)

re.on_application_entry("PrepareRendering", function()
    if not init_done or dodge_state ~= "playing" then return end
    pcall(apply_root_motion)
end)

--------------------------------------------------------------------------------
-- 11. DEBUG UI (fully pcall-protected)
--------------------------------------------------------------------------------

re.on_draw_ui(function()
    local node_open = imgui.tree_node("NativeDodge v2.0.2")
    if not node_open then return end

    local ui_ok, ui_err = pcall(function()
        if not game_ready then
            imgui.text("Waiting for player...")
            return
        end
        if not init_done then
            local r = math.max(0, CFG.init_delay - (os.clock() - ready_time))
            imgui.text(string.format("Initializing... (%.1fs)", r))
            return
        end

        imgui.text("Status: READY | Banks: " .. loaded_count .. "/4 | FSM2: " ..
            (player_fsm2 and "OK" or "MISSING"))
        local dir_str = {}
        for _, d in ipairs({"front","back","left","right"}) do
            if loaded_directions[d] then dir_str[#dir_str+1] = d:upper() end
        end
        imgui.text("Directions: " .. table.concat(dir_str, ", "))

        imgui.separator()
        local est_dur = dodge_end_frame / (BASE_FPS * CFG.speed)
        imgui.text(string.format("Dodge: %s [%s] | Speed: %.1fx (~%.1fs)",
            tostring(dodge_state), dodge_dir:upper(), CFG.speed, est_dur))
        imgui.text(string.format("  Frame: %.1f / %.0f  (bank=%.0f, engSpd=%.1f, endMot=%s)",
            dbg_engine_frame, dodge_end_frame,
            dbg_cur_bank, dbg_engine_speed,
            tostring(dbg_state_end)))
        imgui.text(string.format("  FSM: %s (paused_by_us=%s)",
            fsm_method, tostring(fsm_paused_by_us)))
        imgui.text(string.format("  Moved: %.2fm | Wall: %s | Dodges: %.0f",
            dodge_moved,
            dodge_wall_hit and string.format("HIT@%.2fm", dodge_wall_dist) or "clear",
            dodge_count))

        local kb_name = KB_KEY_NAMES[CFG.dodge_key] or string.format("0x%02X", CFG.dodge_key)
        imgui.text("Input: " .. kb_name .. " + WASD")

        if dbg_last_error ~= "" then
            imgui.text_colored("Error: " .. dbg_last_error, 0xFF4444FF)
        end

        if imgui.button("Trigger Dodge") then move_log_count = 0; start_dodge() end
        imgui.same_line()
        if imgui.button("Stop") then
            if dodge_state == "playing" then end_dodge("manual") end
            if dodge_state == "recovering" then dodge_state = "idle" end
        end

        imgui.separator()
        if imgui.tree_node("Settings") then
            local c
            c, move_enabled = imgui.checkbox("Root motion", move_enabled)
            c, CFG.speed = imgui.slider_float("Speed", CFG.speed, 0.5, 10.0, "%.1f")
            c, CFG.dodge_distance = imgui.slider_float("Distance (m)", CFG.dodge_distance, 0.5, 6.0, "%.1f")
            c, CFG.blend_frames = imgui.slider_float("Blend frames", CFG.blend_frames, 0.0, 30.0, "%.0f")
            c, CFG.dodge_cooldown = imgui.slider_float("Cooldown (s)", CFG.dodge_cooldown, 0.0, 3.0, "%.1f")
            c, CFG.move_start = imgui.slider_float("Move start", CFG.move_start, 0.0, 0.5, "%.2f")
            c, CFG.move_end = imgui.slider_float("Move end", CFG.move_end, 0.3, 1.0, "%.2f")
            imgui.tree_pop()
        end

        if imgui.tree_node("Input Config") then
            local kl = KB_KEY_NAMES[CFG.dodge_key] or string.format("0x%02X", CFG.dodge_key)
            if kb_detect_mode then
                imgui.text_colored(">> Press key... (ESC cancel)", 0xFF00FFFF)
                if is_key_down(0x1B) then kb_detect_mode = false
                else for code = 0x08, 0x7B do
                    if code ~= 0x1B and is_key_down(code) then
                        CFG.dodge_key = code; kb_detect_mode = false; break
                    end
                end end
            else
                imgui.text("Key: " .. kl)
                imgui.same_line()
                if imgui.button("Rebind") then kb_detect_mode = true end
            end
            imgui.spacing()
            if pad_detect_mode then
                imgui.text_colored(">> Press pad button...", 0xFF00FFFF)
                local cur = get_pad_buttons()
                local new_btns = cur & (~pad_prev_buttons)
                if new_btns > 0 then
                    local f = 1
                    while f <= new_btns do
                        if (new_btns & f) ~= 0 then CFG.dodge_pad_button = f; break end
                        f = f << 1
                    end
                    pad_detect_mode = false
                end
                pad_prev_buttons = cur
            else
                local pl2 = CFG.dodge_pad_button > 0 and string.format("0x%X", CFG.dodge_pad_button) or "None"
                imgui.text("Pad: " .. pl2)
                imgui.same_line()
                if imgui.button("Rebind Pad") then pad_detect_mode = true; pad_prev_buttons = get_pad_buttons() end
            end
            imgui.tree_pop()
        end
    end)

    -- ALWAYS pop tree, even on error
    imgui.tree_pop()

    if not ui_ok then
        dbg_last_error = tostring(ui_err)
        dbg("UI error: " .. dbg_last_error)
    end
end)

log.info("[NativeDodge] v2.0.2 loaded successfully")
