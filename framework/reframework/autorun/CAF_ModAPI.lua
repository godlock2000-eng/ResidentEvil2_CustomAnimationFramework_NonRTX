-- CAF_ModAPI.lua — Custom Animation Framework Mod API
-- v1.0.0 — Event-driven animation system with mod packages, paired anims,
-- layer overlays, and chain/combo support.
-- Architecture: EventBus dispatches game events to registered animations,
-- PlaybackEngine manages DynamicMotionBank playback sessions.

if reframework:get_game_name() ~= "re2" then return end

log.info("[CAF] v1.0.0 loading...")

--------------------------------------------------------------------------------
-- 1. CONFIGURATION
--------------------------------------------------------------------------------

local VERSION = "1.0.0"
local SETTINGS_FILE = "CAF_ModAPI_settings.json"
local MODS_DIR = "CAF_mods"
local LOG_PREFIX = "[CAF] "
local INIT_DELAY = 3.0
local KNOWN_END_FRAME_DEFAULT = 179
local NEXT_BANK_ID_START = 950     -- auto-assign from 950+ (dodge uses 900-903)
local ENEMY_SCAN_INTERVAL = 10     -- frames between proximity scans
local MAX_SESSIONS = 8
local MAX_EVENT_LOG = 20

--------------------------------------------------------------------------------
-- 2. REGISTRY
--------------------------------------------------------------------------------

local Registry = {
    mods = {},               -- { [mod_id] = { name, author, version, animations, settings } }
    animations = {},         -- { [anim_id] = anim_def }
    event_bindings = {},     -- { [event_name] = { {anim_id, conditions, priority, mod_id}, ... } }
    loaded_banks = {},       -- { [bank_path] = {holder, dyn_bank, dyn_idx, bank_id} }
    chains = {},             -- { [chain_id] = chain_def }
    mod_ui_callbacks = {},   -- { [mod_id] = draw_function }
    next_bank_id = NEXT_BANK_ID_START,
}

--------------------------------------------------------------------------------
-- 3. EVENT BUS
--------------------------------------------------------------------------------

local EventBus = {
    listeners = {},          -- { [event_name] = { {callback, priority, id}, ... } }
    deferred = {},
    processing = false,
    next_listener_id = 1,
}

function EventBus.on(event_name, callback, priority)
    local list = EventBus.listeners[event_name] or {}
    local id = EventBus.next_listener_id
    EventBus.next_listener_id = id + 1
    table.insert(list, { callback = callback, priority = priority or 0, id = id })
    table.sort(list, function(a, b) return a.priority > b.priority end)
    EventBus.listeners[event_name] = list
    return id
end

function EventBus.off(event_name, listener_id)
    local list = EventBus.listeners[event_name]
    if not list then return end
    for i = #list, 1, -1 do
        if list[i].id == listener_id then
            table.remove(list, i)
            return
        end
    end
end

function EventBus.emit(event_name, data)
    if EventBus.processing then
        table.insert(EventBus.deferred, {event_name, data})
        return
    end
    EventBus.processing = true

    local list = EventBus.listeners[event_name]
    if list then
        for _, entry in ipairs(list) do
            local ok, result = pcall(entry.callback, data)
            if not ok then
                log.info(LOG_PREFIX .. "Event error (" .. event_name .. "): " .. tostring(result))
            end
            if result == false then break end
        end
    end

    EventBus.processing = false
    while #EventBus.deferred > 0 do
        local ev = table.remove(EventBus.deferred, 1)
        EventBus.emit(ev[1], ev[2])
    end
end

--------------------------------------------------------------------------------
-- 4. STATE
--------------------------------------------------------------------------------

local game_ready = false
local ready_time = 0
local init_done = false

local player_go = nil
local player_motion = nil
local player_xform = nil
local player_cc = nil
local player_fsm2 = nil

-- FSM control
local fsm_paused_by_us = false
local fsm_was_paused = false
local fsm_was_enabled = true
local fsm_method = "none"

-- Settings
local settings_dirty = false
local settings_dirty_time = 0

-- Polled event state (edge detection)
local prev_hp_pct = 1.0
local prev_weapon_type = -1
local prev_keys = {}                 -- { [keycode] = was_down }
local prev_pad_buttons = 0           -- previous frame pad button bitmask
local enemy_scan_counter = 0
local prev_enemy_proximity = {}      -- { [enemy_go_ptr] = was_near }
local enemy_cache = {}               -- cached enemy list from scan
local enemy_cache_time = 0

-- Event log
local event_log = {}                 -- { {time, name, summary}, ... }

-- Frame counter
local frame_count = 0

-- Chain state
local active_chains = {}             -- { [chain_id] = chain_state }

-- Config (user-tunable)
local CFG = {
    debug_log = true,
    proximity_radius = 5.0,
    health_thresholds = { 0.75, 0.50, 0.25, 0.10 },
    max_concurrent = MAX_SESSIONS,
    watched_keys = {},               -- { keycode, ... } — auto-populated from event bindings
    pad_button_map = {},             -- { [keycode] = pad_button_flag } — pad buttons that alias to keycodes
    pad_stick_deadzone = 0.5,        -- left stick deadzone for direction_key checks
}

--------------------------------------------------------------------------------
-- 5. UTILITIES
--------------------------------------------------------------------------------

local function dbg(msg)
    if CFG.debug_log then
        log.info(LOG_PREFIX .. msg)
    end
end

local function log_event(name, summary)
    table.insert(event_log, 1, {
        time = os.clock(),
        name = name,
        summary = summary or "",
    })
    if #event_log > MAX_EVENT_LOG then
        event_log[#event_log] = nil
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

local function quat_forward(q)
    local fx = -(2 * (q.x * q.z + q.w * q.y))
    local fz = -(1 - 2 * (q.x * q.x + q.y * q.y))
    return fx, fz
end

local function warp_actor(xform, cc, target_pos, target_rot)
    if not xform then return end
    pcall(function()
        if target_rot then
            xform:call("set_Rotation", target_rot)
        end
        local pos = xform:call("get_Position")
        pos.x = target_pos.x
        pos.y = target_pos.y
        pos.z = target_pos.z
        xform:call("set_Position", pos)
        if cc then cc:call("warp") end
    end)
end

local function get_cc(go)
    if not go then return nil end
    local actual_go = go
    if go.get_GameObject then actual_go = go:call("get_GameObject") end
    if not actual_go then return nil end
    local ok, cc = pcall(function()
        return actual_go:call("getComponent(System.Type)", sdk.typeof("via.physics.CharacterController"))
    end)
    return ok and cc or nil
end

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
-- 6. SETTINGS PERSISTENCE
--------------------------------------------------------------------------------

local function save_settings()
    pcall(function()
        json.dump_file(SETTINGS_FILE, {
            debug_log = CFG.debug_log,
            proximity_radius = CFG.proximity_radius,
            max_concurrent = CFG.max_concurrent,
        })
    end)
end

local function load_settings()
    local ok, data = pcall(json.load_file, SETTINGS_FILE)
    if not ok or not data then return false end
    if data.debug_log ~= nil then CFG.debug_log = data.debug_log end
    if data.proximity_radius then CFG.proximity_radius = data.proximity_radius end
    if data.max_concurrent then CFG.max_concurrent = data.max_concurrent end
    dbg("Settings loaded")
    return true
end

load_settings()

--------------------------------------------------------------------------------
-- 7. PLAYER / COMPONENT CACHING
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

    -- CharacterController (4 fallback strategies)
    local cc = nil
    pcall(function()
        cc = pl:call("getComponent(System.Type)",
            sdk.typeof("via.physics.CharacterController"))
    end)
    if not cc then
        pcall(function()
            local scc = pl:call("getComponent(System.Type)",
                sdk.typeof("app.ropeway.survivor.SurvivorCharacterController"))
            if scc then
                cc = scc:get_field("<CharacterController>k__BackingField")
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
                        if cc then break end
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
            end
        end)
    end

    -- MotionFsm2 (4 fallback strategies)
    local fsm2 = nil
    pcall(function()
        local actual = motion_go
        if motion_go.get_GameObject then actual = motion_go:call("get_GameObject") end
        if actual then
            fsm2 = actual:call("getComponent(System.Type)", sdk.typeof("via.motion.MotionFsm2"))
        end
    end)
    if not fsm2 then
        pcall(function()
            fsm2 = pl:call("getComponent(System.Type)", sdk.typeof("via.motion.MotionFsm2"))
        end)
    end
    if not fsm2 then
        pcall(function()
            local go = pl:call("get_GameObject")
            if go then
                fsm2 = go:call("getComponent(System.Type)", sdk.typeof("via.motion.MotionFsm2"))
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
                        if fsm2 then break end
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

    dbg("Player cached: CC=" .. (cc and "YES" or "NO") .. " FSM2=" .. (fsm2 and "YES" or "NO"))
    return true
end

--------------------------------------------------------------------------------
-- 8. BANK MANAGER
--------------------------------------------------------------------------------

local function load_bank(motion, path, bank_id)
    if Registry.loaded_banks[path] then return Registry.loaded_banks[path] end
    if not motion then return nil end

    local result = nil
    local ok, err = pcall(function()
        local res = sdk.create_resource("via.motion.MotionBankResource", path)
        if not res then dbg("WARN: resource nil for " .. path); return end
        res = res:add_ref()
        local holder = res:create_holder("via.motion.MotionBankResourceHolder")
        if not holder then dbg("WARN: holder nil for " .. path); return end
        holder = holder:add_ref()
        local db = sdk.create_instance("via.motion.DynamicMotionBank"):add_ref()
        db:call("set_MotionBank", holder)
        db:call("set_Priority", 200)
        -- Keep dynamic banks eligible across layer/local-bank routing.
        pcall(function() db:call("set_BankType", 0) end)
        pcall(function() db:call("set_BankTypeMaskBit", 0xFFFFFFFF) end)
        pcall(function() db:call("set_OverwriteBankType", true) end)
        pcall(function() db:call("set_OverwriteBankTypeMaskBit", true) end)
        local c = motion:call("getDynamicMotionBankCount")
        motion:call("setDynamicMotionBankCount", c + 1)
        motion:call("setDynamicMotionBank", c, db)
        result = { holder = holder, dyn_bank = db, dyn_idx = c, bank_id = bank_id }
        dbg("Bank loaded: " .. path .. " (id=" .. tostring(bank_id) .. ", idx=" .. c .. ")")
    end)
    if not ok then dbg("Bank load error: " .. tostring(err)) end
    if result then Registry.loaded_banks[path] = result end
    return result
end

local function load_bank_for_actor(actor_motion, path, bank_id)
    -- Load a bank onto a specific actor (not player)
    if not actor_motion then return nil end
    local result = nil
    pcall(function()
        local res = sdk.create_resource("via.motion.MotionBankResource", path)
        if not res then return end
        res = res:add_ref()
        local holder = res:create_holder("via.motion.MotionBankResourceHolder")
        if not holder then return end
        holder = holder:add_ref()
        local db = sdk.create_instance("via.motion.DynamicMotionBank"):add_ref()
        db:call("set_MotionBank", holder)
        db:call("set_Priority", 200)
        -- Keep dynamic banks eligible across layer/local-bank routing.
        pcall(function() db:call("set_BankType", 0) end)
        pcall(function() db:call("set_BankTypeMaskBit", 0xFFFFFFFF) end)
        pcall(function() db:call("set_OverwriteBankType", true) end)
        pcall(function() db:call("set_OverwriteBankTypeMaskBit", true) end)
        local c = actor_motion:call("getDynamicMotionBankCount")
        actor_motion:call("setDynamicMotionBankCount", c + 1)
        actor_motion:call("setDynamicMotionBank", c, db)
        result = { holder = holder, dyn_bank = db, dyn_idx = c, bank_id = bank_id }
    end)
    return result
end

local function assign_bank_id()
    local id = Registry.next_bank_id
    Registry.next_bank_id = id + 1
    return id
end

--------------------------------------------------------------------------------
-- 9. FSM CONTROL
--------------------------------------------------------------------------------

local function pause_fsm()
    if not player_fsm2 then return false end
    if fsm_paused_by_us then return true end

    fsm_method = "none"
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

    local paused_ok = false
    pcall(function() player_fsm2:call("set_Paused", true); paused_ok = true end)
    local disabled_ok = false
    pcall(function() player_fsm2:call("set_Enabled", false); disabled_ok = true end)

    if paused_ok and disabled_ok then fsm_method = "paused+disabled"
    elseif paused_ok then fsm_method = "paused"
    elseif disabled_ok then fsm_method = "disabled"
    else fsm_method = "FAILED" end

    fsm_paused_by_us = true
    dbg("FSM paused: " .. fsm_method)
    return paused_ok or disabled_ok
end

local function unpause_fsm()
    if not player_fsm2 or not fsm_paused_by_us then return end
    pcall(function() player_fsm2:call("set_Enabled", true) end)
    pcall(function() player_fsm2:call("set_Paused", false) end)
    fsm_paused_by_us = false
    dbg("FSM restored")
end

--------------------------------------------------------------------------------
-- 10. INPUT HANDLING
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

--------------------------------------------------------------------------------
-- 11. ENEMY ENUMERATION
--------------------------------------------------------------------------------

local function scan_enemies()
    enemy_cache = {}
    local ok = pcall(function()
        local em = sdk.get_managed_singleton(sdk.game_namespace("EnemyManager"))
        if not em then return end

        local list = em["<EnemyList>k__BackingField"]
        if not list then return end
        local items = list.mItems
        if not items then return end
        local elements = items:get_elements()
        if not elements then return end

        local player_pos = nil
        if player_xform then
            player_pos = player_xform:call("get_Position")
        end

        for i, reg_info in pairs(elements) do
            if reg_info then
                local ctx_ok, ctx = pcall(function()
                    return reg_info["<Context>k__BackingField"]
                end)
                if ctx_ok and ctx then
                    local go_ok, go = pcall(function()
                        return ctx["<EnemyGameObject>k__BackingField"]
                    end)
                    if go_ok and go then
                        local motion = getC(go, "via.motion.Motion")
                        local xform = go:call("get_Transform")
                        local kind_id = "unknown"

                        pcall(function()
                            local ec = ctx["<EnemyController>k__BackingField"]
                            if ec then
                                local kind = ec:call("get_KindID")
                                if kind ~= nil then kind_id = "em" .. string.format("%.0f", kind) end
                            end
                        end)

                        local dist = 999
                        if player_pos and xform then
                            pcall(function()
                                local ep = xform:call("get_Position")
                                if ep then
                                    local dx = ep.x - player_pos.x
                                    local dz = ep.z - player_pos.z
                                    dist = math.sqrt(dx * dx + dz * dz)
                                end
                            end)
                        end

                        if motion then
                            table.insert(enemy_cache, {
                                go = go,
                                motion = motion,
                                xform = xform,
                                kind_id = kind_id,
                                distance = dist,
                            })
                        end
                    end
                end
            end
        end

        table.sort(enemy_cache, function(a, b) return a.distance < b.distance end)
    end)
    enemy_cache_time = os.clock()
    return enemy_cache
end

-- Suspend/restore enemy AI
local function suspend_enemy_ai(go)
    local restore = {}
    pcall(function()
        local actual_go = go
        if go.get_GameObject then actual_go = go:call("get_GameObject") end
        if not actual_go then return end
        local bt = actual_go:call("getComponent(System.Type)", sdk.typeof("via.behaviortree.BehaviorTree"))
        if bt then
            restore.bt = bt
            restore.bt_was_enabled = bt:call("get_Enabled")
            bt:call("set_Enabled", false)
        end
    end)
    return restore
end

local function restore_enemy_ai(restore)
    if not restore then return end
    pcall(function()
        if restore.bt and restore.bt_was_enabled ~= nil then
            restore.bt:call("set_Enabled", restore.bt_was_enabled)
        end
    end)
end

--------------------------------------------------------------------------------
-- 12. PLAYBACK ENGINE
--------------------------------------------------------------------------------

local PlaybackEngine = {
    sessions = {},
    next_id = 1,
}

local function count_active_sessions()
    local n = 0
    for _, s in pairs(PlaybackEngine.sessions) do
        if s.state == "playing" or s.state == "loading" then n = n + 1 end
    end
    return n
end

local function end_session(session, reason)
    if session.state ~= "playing" and session.state ~= "loading" then return end

    -- CRITICAL: Reset layer state FIRST (prevents speed stacking / ghost blending)
    if session.layer then
        pcall(function() session.layer:call("set_Speed", 1.0) end)
        if session.is_overlay then
            pcall(function() session.layer:call("set_BlendRate", 0.0) end)
            -- Restore Overwrite flags on MotionFsm2Layer so FSM regains control
            if session.fsm2_layer then
                pcall(function() session.fsm2_layer:call("set_OverwriteBlendRate", false) end)
                pcall(function() session.fsm2_layer:call("set_OverwriteBlendMode", false) end)
            end
        end
    end

    -- Restore FSM FIRST, before any logging
    if session.fsm_paused then
        unpause_fsm()
        session.fsm_paused = false
    end

    -- Now safe to log
    pcall(function()
        local elapsed = os.clock() - session.start_time
        dbg("Session #" .. session.id .. " " .. session.anim_id .. " ended: " .. reason ..
            string.format(" (%.2fs)", elapsed))
    end)

    session.state = "complete"
    session.end_time = os.clock()

    EventBus.emit("animation:ended", {
        session_id = session.id,
        anim_id = session.anim_id,
        reason = reason,
    })

    if session.on_complete then
        pcall(session.on_complete, session)
    end
end

function PlaybackEngine.play(anim_id, options)
    local def = Registry.animations[anim_id]
    if not def then
        dbg("Play: animation '" .. tostring(anim_id) .. "' not registered")
        return nil
    end

    if def.type == "paired" then
        return PlaybackEngine.play_paired(anim_id, options)
    end

    if not player_motion then
        dbg("Play: no player motion")
        return nil
    end

    if count_active_sessions() >= CFG.max_concurrent then
        dbg("Play: max concurrent sessions reached")
        return nil
    end

    local session = {
        id = PlaybackEngine.next_id,
        anim_id = anim_id,
        def = def,
        state = "loading",
        start_time = os.clock(),
        end_time = nil,
        layer = nil,
        fsm_paused = false,
        is_overlay = false,
        endframe_updated = false,
        end_frame = def.end_frame or KNOWN_END_FRAME_DEFAULT,
        -- Root motion
        move_dir = nil,
        start_pos = nil,
        moved = 0,
        last_set_pos = nil,
        wall_hit = false,
        -- Debug
        engine_frame = 0,
        engine_speed = 0,
        cur_bank_id = 0,
        -- Callbacks
        on_complete = options and options.on_complete,
    }
    PlaybackEngine.next_id = PlaybackEngine.next_id + 1

    -- Ensure bank is loaded
    local bank_id = def.bank_id
    if not bank_id then
        bank_id = assign_bank_id()
        def.bank_id = bank_id
    end
    if def.bank_path and not Registry.loaded_banks[def.bank_path] then
        load_bank(player_motion, def.bank_path, bank_id)
    end

    -- FSM control
    local fsm_mode = def.fsm_mode or "pause"
    if fsm_mode == "pause" and player_fsm2 then
        pause_fsm()
        session.fsm_paused = true
    end

    -- Determine layer
    local target_layer = def.layer or 0
    if fsm_mode == "overlay" then
        target_layer = 1
    end
    session.is_overlay = (target_layer > 0)

    -- Calculate root motion direction
    if def.movement and def.movement.distance and def.movement.distance > 0 then
        pcall(function()
            if not player_xform then return end
            local rot = player_xform:call("get_Rotation")
            if not rot then return end
            local bx = -(2.0 * (rot.x * rot.z + rot.w * rot.y))
            local bz = -(1.0 - 2.0 * (rot.x * rot.x + rot.y * rot.y))
            local len = math.sqrt(bx * bx + bz * bz)
            if len < 0.001 then return end
            bx = bx / len; bz = bz / len

            local dir = def.movement.direction or "forward"
            if dir == "backward" then     session.move_dir = { x = bx, z = bz }
            elseif dir == "forward" then  session.move_dir = { x = -bx, z = -bz }
            elseif dir == "left" then     session.move_dir = { x = -bz, z = bx }
            elseif dir == "right" then    session.move_dir = { x = bz, z = -bx }
            end

            local pos = player_xform:call("get_Position")
            if pos then session.start_pos = { x = pos.x, y = pos.y, z = pos.z } end
        end)
    end

    -- changeMotion (single call, engine-native playback)
    local play_ok = false
    pcall(function()
        local layer = player_motion:call("getLayer", target_layer)
        if not layer then dbg("ERROR: getLayer(" .. target_layer .. ") nil"); return end
        session.layer = layer
        if session.is_overlay then
            -- Diagnostic: log layer defaults before any changes
            pcall(function()
                local jb0 = layer:call("getJointBlendRate", 0)
                local ro, bl = "?", "?"
                pcall(function() ro = tostring(layer:call("get_RootOnly")) end)
                pcall(function() bl = tostring(layer:call("get_BaseLayerNo")) end)
                dbg(string.format("L1 pre-fix: JBlend[0]=%.2f,%.2f,%.2f RootOnly=%s BaseLayer=%s",
                    jb0 and jb0.x or -1, jb0 and jb0.y or -1, jb0 and jb0.z or -1, ro, bl))
            end)
            -- Diagnostic: LayerCount (try multiple method names)
            local lc_str = "?"
            local ok, err = pcall(function()
                local lc = player_motion:call("getLayerCount")
                lc_str = tostring(lc)
            end)
            if not ok then
                -- Try alternative name
                local ok2, err2 = pcall(function()
                    local lc = player_motion:call("get_LayerCount")
                    lc_str = tostring(lc)
                end)
                if not ok2 then
                    lc_str = "ERR:" .. tostring(err):sub(1, 60) .. "|" .. tostring(err2):sub(1, 60)
                end
            end
            -- Diagnostic: layer properties
            local ajc_str, idl_str, ef_str, bi_str = "?", "?", "?", "?"
            pcall(function() ajc_str = tostring(layer:call("get_AnimatedJointCount")) end)
            pcall(function() idl_str = tostring(layer:call("get_Idling")) end)
            pcall(function() ef_str = tostring(layer:call("get_EndFrame")) end)
            pcall(function() bi_str = tostring(layer:call("get_BankID")) end)
            dbg("L1 info: LayerCount=" .. lc_str .. " AJC=" .. ajc_str .. " Idling=" .. idl_str .. " EndFrame=" .. ef_str .. " BankID=" .. bi_str)
            -- Layer-level blend (TreeLayer)
            layer:call("set_BlendRate", 1.0)
            layer:call("set_BlendMode", 0)  -- Overwrite (replaces base pose for overlay joints)
            -- Safety: ensure layer is not root-only and blends against layer 0
            pcall(function() layer:call("set_RootOnly", false) end)
            pcall(function() layer:call("set_BaseLayerNo", 0) end)
            -- Inherit mask/type routing from base layer so head/neck overlays are not masked out.
            pcall(function()
                local base_layer = player_motion:call("getLayer", 0)
                if base_layer then
                    local base_mask = nil
                    local base_type = nil
                    pcall(function() base_mask = base_layer:call("get_JointMaskID") end)
                    pcall(function() base_type = base_layer:call("get_LocalBankType") end)
                    if base_mask ~= nil then layer:call("set_JointMaskID", base_mask) end
                    if base_type ~= nil then layer:call("set_LocalBankType", base_type) end
                end
            end)
            -- CRITICAL: Set per-joint blend rates to (1,1,1) = (pos,rot,scale)
            -- Default is (1,0,0) which zeroes out rotation blend -> invisible rotation anims
            local jb = Vector3f.new(1.0, 1.0, 1.0)
            for ji = 0, 79 do
                layer:call("setJointBlendRate", ji, jb)
            end
            -- Overwrite flags on MotionFsm2Layer (NOT TreeLayer) to prevent FSM reset
            -- OverwriteBlendRate/BlendMode live on via.motion.MotionFsm2Layer
            if player_fsm2 then
                pcall(function()
                    local fsm2_layer = player_fsm2:call("getLayer", target_layer)
                    if fsm2_layer then
                        fsm2_layer:call("set_OverwriteBlendRate", true)
                        fsm2_layer:call("set_OverwriteBlendMode", true)
                        pcall(function()
                            local base_layer = player_motion:call("getLayer", 0)
                            if base_layer then
                                local base_mask = nil
                                local base_type = nil
                                pcall(function() base_mask = base_layer:call("get_JointMaskID") end)
                                pcall(function() base_type = base_layer:call("get_LocalBankType") end)
                                if base_mask ~= nil then fsm2_layer:call("set_JointMaskID", base_mask) end
                                if base_type ~= nil then fsm2_layer:call("set_LocalBankType", base_type) end
                            end
                            fsm2_layer:call("set_OverwriteJointMaskID", true)
                            fsm2_layer:call("set_OverwriteLocalBankType", true)
                        end)
                        session.fsm2_layer = fsm2_layer  -- cache for cleanup
                        dbg("FSM2 layer OverwriteBlendRate=true, OverwriteBlendMode=true")
                    end
                end)
            end
            dbg("Overlay setup: JointBlendRate=(1,1,1) x80, RootOnly=false, BaseLayer=0")
        end
        layer:call("changeMotion", bank_id, def.motion_id or 0, 0.0, def.blend_frames or 0.0, 2, 0)
        layer:call("set_Frame", 0.0)
        layer:call("set_Speed", def.speed or 1.0)
        play_ok = true
    end)

    if not play_ok then
        dbg("Play: changeMotion failed for " .. anim_id)
        if session.fsm_paused then unpause_fsm(); session.fsm_paused = false end
        return nil
    end

    session.state = "playing"
    PlaybackEngine.sessions[session.id] = session
    dbg("Session #" .. session.id .. " started: " .. anim_id ..
        " (bank=" .. tostring(bank_id) .. " fsm=" .. fsm_mode .. ")")

    EventBus.emit("animation:started", {
        session_id = session.id,
        anim_id = anim_id,
    })
    log_event("animation:started", anim_id)

    return session.id
end

function PlaybackEngine.stop(session_id)
    local session = PlaybackEngine.sessions[session_id]
    if session then end_session(session, "manual") end
end

function PlaybackEngine.update()
    for id, session in pairs(PlaybackEngine.sessions) do
        if session.state == "playing" then
            if not session.layer then
                end_session(session, "layer_lost")
            else
                local elapsed = os.clock() - session.start_time

                -- Read engine state
                local read_ok = pcall(function()
                    session.engine_frame = tonumber(session.layer:call("get_Frame")) or 0
                    session.cur_bank_id = tonumber(session.layer:call("get_BankID")) or 0
                    session.engine_speed = tonumber(session.layer:call("get_Speed")) or 0
                end)

                if not read_ok then
                    end_session(session, "layer_error")
                else
                    -- Maintain overlay blend state every frame (engine/FSM may reset)
                    if session.is_overlay then
                        pcall(function()
                            session.layer:call("set_BlendRate", 1.0)
                            session.layer:call("set_BlendMode", 0)  -- Overwrite
                            -- Check if engine reset JointBlendRate (sample joint 0)
                            local need_reset = false
                            local jb0 = session.layer:call("getJointBlendRate", 0)
                            if jb0 then
                                if jb0.y < 0.99 or jb0.z < 0.99 then need_reset = true end
                            else
                                need_reset = true
                            end
                            if need_reset then
                                local jb = Vector3f.new(1.0, 1.0, 1.0)
                                for ji = 0, 79 do
                                    session.layer:call("setJointBlendRate", ji, jb)
                                end
                            end
                        end)
                        -- One-shot diagnostic: verify blend persisted
                        if not session.overlay_diag_done then
                            session.overlay_diag_done = true
                            pcall(function()
                                local br = session.layer:call("get_BlendRate")
                                local bm = session.layer:call("get_BlendMode")
                                local jb5 = session.layer:call("getJointBlendRate", 5)
                                dbg(string.format("Overlay diag: BlendRate=%.2f BlendMode=%.0f JBlend(5)=%.2f,%.2f,%.2f",
                                    br or -1, bm or -1,
                                    jb5 and jb5.x or -1, jb5 and jb5.y or -1, jb5 and jb5.z or -1))
                            end)
                        end
                    end

                    -- Update endFrame from engine after delay
                    if not session.endframe_updated and elapsed > 0.15 then
                        pcall(function()
                            local ef = tonumber(session.layer:call("get_EndFrame")) or 0
                            if ef > 10 then session.end_frame = ef end
                        end)
                        session.endframe_updated = true
                    end

                    -- End detection (grace period 0.2s)
                    local ended = false
                    if elapsed > 0.2 then
                        pcall(function()
                            local se = session.layer:call("get_StateEndOfMotion")
                            if se then ended = true end
                        end)
                        if not ended and session.engine_frame >= session.end_frame - 1 then
                            ended = true
                        end
                        -- Bank change detection (FSM took over)
                        local expected_bank = session.def.bank_id or 0
                        if not ended and session.cur_bank_id ~= 0 and session.cur_bank_id ~= expected_bank then
                            ended = true
                        end
                    end

                    if ended then
                        end_session(session, "complete")
                    elseif elapsed > 8.0 then
                        end_session(session, "timeout")
                    end
                end
            end
        elseif session.state == "complete" then
            -- Clean up completed sessions after a delay
            if session.end_time and os.clock() - session.end_time > 0.5 then
                PlaybackEngine.sessions[id] = nil
            end
        end
    end
end

--------------------------------------------------------------------------------
-- 13. ROOT MOTION
--------------------------------------------------------------------------------

local function apply_session_root_motion(session)
    if session.state ~= "playing" then return end
    local def = session.def
    if not def.movement or not def.movement.distance then return end
    if def.movement.distance <= 0 then return end
    if not session.move_dir or not session.start_pos then return end
    if session.wall_hit then return end
    if not player_xform then return end

    local progress = session.engine_frame / math.max(session.end_frame, 1)
    local move_start = def.movement.start_pct or 0.01
    local move_end = def.movement.end_pct or 0.99

    -- Wall detection
    if session.last_set_pos and player_cc and session.moved > 0.3 then
        pcall(function()
            local actual = player_xform:call("get_Position")
            if actual then
                local dx = actual.x - session.last_set_pos.x
                local dz = actual.z - session.last_set_pos.z
                local drift = math.sqrt(dx * dx + dz * dz)
                if drift > 0.15 then
                    session.wall_hit = true
                    player_cc:call("warp")
                end
            end
        end)
        if session.wall_hit then return end
    end

    if progress < move_start or progress > move_end then return end

    local move_progress = (progress - move_start) / (move_end - move_start)
    move_progress = math.min(1.0, math.max(0.0, move_progress))
    local eased = move_progress * move_progress * (3.0 - 2.0 * move_progress)
    local target_dist = def.movement.distance * eased
    session.moved = target_dist

    pcall(function()
        local new_x = session.start_pos.x + session.move_dir.x * target_dist
        local new_y = session.start_pos.y
        local new_z = session.start_pos.z + session.move_dir.z * target_dist
        player_xform:call("set_Position", Vector3f.new(new_x, new_y, new_z))
        if player_cc then player_cc:call("warp") end
        session.last_set_pos = { x = new_x, y = new_y, z = new_z }
    end)
end

--------------------------------------------------------------------------------
-- 14. PAIRED ANIMATION ENGINE
--------------------------------------------------------------------------------

local paired_sessions = {}
local next_paired_id = 1

local function create_paired_session(def, primary_go, secondary_gos)
    if not def.actors or #def.actors < 2 then return nil end

    local actor_gos = { primary_go }
    for _, sgo in ipairs(secondary_gos) do
        table.insert(actor_gos, sgo)
    end
    if #actor_gos < #def.actors then return nil end

    local session = {
        id = next_paired_id,
        def = def,
        state = "aligning",
        actors = {},
        primary_idx = 1,
        start_time = os.clock(),
        current_frame = 0,
        align_timer = 0,
        max_align_time = 1.5,
    }
    next_paired_id = next_paired_id + 1

    local primary_xform, primary_pos, primary_rot

    for i = 1, #def.actors do
        local go = actor_gos[i]
        if not go then return nil end
        local motion = getC(go, "via.motion.Motion")
        if not motion then return nil end
        local actual_go = go
        if go.get_GameObject then actual_go = go:call("get_GameObject") end
        local xform = actual_go:call("get_Transform")
        local cc = get_cc(go)
        local cur_pos = xform:call("get_Position")

        session.actors[i] = {
            go = go, motion = motion, xform = xform, cc = cc,
            original_pos = { x = cur_pos.x, y = cur_pos.y, z = cur_pos.z },
            target_pos = nil, target_rot = nil,
            layer_idx = def.actors[i].layer or 0,
            ai_restore = nil, playing = false,
        }

        if i == 1 then
            primary_xform = xform
            primary_pos = { x = cur_pos.x, y = cur_pos.y, z = cur_pos.z }
            primary_rot = xform:call("get_Rotation")
        end
    end

    if not primary_pos then return nil end

    -- Calculate target positions relative to primary orientation
    local fwd_x, fwd_z = quat_forward(primary_rot)
    local right_x, right_z = fwd_z, -fwd_x

    for i, actor_def in ipairs(def.actors) do
        local actor = session.actors[i]
        if i == 1 then
            actor.target_pos = { x = primary_pos.x, y = primary_pos.y, z = primary_pos.z }
            actor.target_rot = primary_rot
        else
            local offset = actor_def.offset or { x = 0, y = 0, z = 0 }
            local tp = {
                x = primary_pos.x + right_x * (offset.x or 0) + fwd_x * (offset.z or 0),
                y = primary_pos.y + (offset.y or 0),
                z = primary_pos.z + right_z * (offset.x or 0) + fwd_z * (offset.z or 0),
            }
            actor.target_pos = tp

            local facing = actor_def.facing or "toward_primary"
            if facing == "toward_primary" then
                local dx = primary_pos.x - tp.x
                local dz = primary_pos.z - tp.z
                local angle = math.atan(dx, dz)
                local half = angle * 0.5
                local q = primary_xform:call("get_Rotation")
                q.x = 0; q.y = math.sin(half); q.z = 0; q.w = math.cos(half)
                actor.target_rot = q
            elseif facing == "away" then
                local dx = tp.x - primary_pos.x
                local dz = tp.z - primary_pos.z
                local angle = math.atan(dx, dz)
                local half = angle * 0.5
                local q = primary_xform:call("get_Rotation")
                q.x = 0; q.y = math.sin(half); q.z = 0; q.w = math.cos(half)
                actor.target_rot = q
            else
                actor.target_rot = primary_rot
            end

            -- Load bank for secondary actor
            if actor_def.bank_path then
                local bid = actor_def.bank_id or assign_bank_id()
                actor_def.bank_id = bid
                load_bank_for_actor(actor.motion, actor_def.bank_path, bid)
            end

            actor.ai_restore = suspend_enemy_ai(actor.go)
        end
    end

    paired_sessions[session.id] = session
    dbg("Paired session #" .. session.id .. " created: " .. #session.actors .. " actors")
    return session.id
end

local function cleanup_paired_session(session)
    for _, actor in ipairs(session.actors) do
        if actor.ai_restore then
            restore_enemy_ai(actor.ai_restore)
            actor.ai_restore = nil
        end
    end
end

local function update_paired_session(session)
    if session.state == "complete" or session.state == "interrupted" then return end

    -- Validate actors
    for i, actor in ipairs(session.actors) do
        if not actor.go or not actor.motion then
            session.state = "interrupted"
            cleanup_paired_session(session)
            return
        end
    end

    if session.state == "aligning" then
        for _, actor in ipairs(session.actors) do
            if actor.target_pos then
                warp_actor(actor.xform, actor.cc, actor.target_pos, actor.target_rot)
            end
        end
        session.align_timer = session.align_timer + (1.0 / 60.0)

        local all_aligned = true
        for _, actor in ipairs(session.actors) do
            if actor.target_pos then
                local ok2, close = pcall(function()
                    local pos = actor.xform:call("get_Position")
                    local dx = pos.x - actor.target_pos.x
                    local dz = pos.z - actor.target_pos.z
                    return math.sqrt(dx * dx + dz * dz) < 0.2
                end)
                if not ok2 or not close then all_aligned = false end
            end
        end

        if all_aligned or session.align_timer > session.max_align_time then
            for i, actor in ipairs(session.actors) do
                local actor_def = session.def.actors[i]
                if actor_def then
                    pcall(function()
                        local layer = actor.motion:call("getLayer", actor.layer_idx)
                        if layer then
                            layer:call("changeMotion",
                                actor_def.bank_id or 0, actor_def.motion_id or 0,
                                0.0, actor_def.inter_frame or 10.0, 2, 1)
                            if actor_def.speed then layer:call("set_Speed", actor_def.speed) end
                            actor.playing = true
                        end
                    end)
                end
            end
            session.state = "playing"
            session.start_time = os.clock()
        end

    elseif session.state == "playing" then
        local primary = session.actors[1]
        local primary_frame = 0
        local primary_end = 0
        pcall(function()
            local layer = primary.motion:call("getLayer", primary.layer_idx)
            if layer then
                primary_frame = layer:call("get_Frame")
                primary_end = layer:call("get_EndFrame")
            end
        end)
        session.current_frame = primary_frame

        -- Frame-locked sync
        if session.def.sync_mode == "frame_locked" then
            for i, actor in ipairs(session.actors) do
                if i ~= 1 and actor.playing then
                    pcall(function()
                        local layer = actor.motion:call("getLayer", actor.layer_idx)
                        if layer then layer:call("set_Frame", primary_frame) end
                    end)
                end
            end
        end

        -- Position drift correction
        for _, actor in ipairs(session.actors) do
            if actor.target_pos then
                pcall(function()
                    local pos = actor.xform:call("get_Position")
                    local dx = pos.x - actor.target_pos.x
                    local dz = pos.z - actor.target_pos.z
                    if math.sqrt(dx * dx + dz * dz) > 0.3 then
                        warp_actor(actor.xform, actor.cc, actor.target_pos, actor.target_rot)
                    end
                end)
            end
        end

        -- End detection
        local duration = session.def.duration_frames or 0
        if duration > 0 then
            if primary_frame >= duration - 1 then session.state = "blend_out" end
        elseif primary_end > 0 and primary_frame >= primary_end - 1 then
            session.state = "blend_out"
        end

    elseif session.state == "blend_out" then
        session.state = "complete"
        cleanup_paired_session(session)
        EventBus.emit("animation:ended", { session_id = session.id, anim_id = "paired_" .. session.id, reason = "complete" })
    end
end

function PlaybackEngine.play_paired(anim_id, options)
    local def = Registry.animations[anim_id]
    if not def or def.type ~= "paired" then return nil end

    -- Find primary (player) and secondary (nearest matching enemy)
    local primary_go = player_go
    local secondary_gos = {}

    -- Use provided targets or auto-find
    if options and options.targets then
        for _, t in ipairs(options.targets) do
            table.insert(secondary_gos, t)
        end
    else
        -- Auto-find nearest enemies
        if os.clock() - enemy_cache_time > 1.0 then scan_enemies() end
        for i = 2, #def.actors do
            local actor_def = def.actors[i]
            for _, enemy in ipairs(enemy_cache) do
                local kind_ok = true
                if actor_def.kind_id and actor_def.kind_id ~= enemy.kind_id then
                    kind_ok = false
                end
                if kind_ok and enemy.distance < (def.max_distance or 5.0) then
                    table.insert(secondary_gos, enemy.go)
                    break
                end
            end
        end
    end

    if #secondary_gos < #def.actors - 1 then
        dbg("Paired: not enough matching enemies")
        return nil
    end

    -- Load primary bank
    if def.actors[1] and def.actors[1].bank_path then
        local bid = def.actors[1].bank_id or assign_bank_id()
        def.actors[1].bank_id = bid
        if not Registry.loaded_banks[def.actors[1].bank_path] then
            load_bank(player_motion, def.actors[1].bank_path, bid)
        end
    end

    return create_paired_session(def, primary_go, secondary_gos)
end

--------------------------------------------------------------------------------
-- 15. EVENT CONDITION CHECKER
--------------------------------------------------------------------------------

local function check_conditions(conditions, data)
    if not conditions then return true end
    for key, expected in pairs(conditions) do
        if key == "keycode" then
            if data.keycode ~= expected then return false end
        elseif key == "damage_gt" then
            if not data.damage or data.damage <= expected then return false end
        elseif key == "hp_pct_lt" then
            if not data.hp_pct or data.hp_pct >= expected then return false end
        elseif key == "hp_pct_gt" then
            if not data.hp_pct or data.hp_pct <= expected then return false end
        elseif key == "kind_id" then
            if data.kind_id ~= expected then return false end
        elseif key == "distance_lt" then
            if not data.distance or data.distance >= expected then return false end
        elseif key == "weapon_type" then
            if data.weapon_type ~= expected then return false end
        elseif key == "direction_key" then
            -- Check if a WASD key is also pressed OR left stick is in that direction
            local dir_keys = { W = 0x57, A = 0x41, S = 0x53, D = 0x44 }
            local dk = dir_keys[expected]
            local kb_held = dk and is_key_down(dk)
            local stick_held = false
            local sx, sy = get_pad_stick_l()
            local mag = math.sqrt(sx * sx + sy * sy)
            if mag > CFG.pad_stick_deadzone then
                if expected == "W" then stick_held = sy > 0 and math.abs(sy) >= math.abs(sx)
                elseif expected == "S" then stick_held = sy < 0 and math.abs(sy) >= math.abs(sx)
                elseif expected == "A" then stick_held = sx < 0 and math.abs(sx) > math.abs(sy)
                elseif expected == "D" then stick_held = sx > 0 and math.abs(sx) > math.abs(sy)
                end
            end
            if not kb_held and not stick_held then return false end
        end
    end
    return true
end

-- Dispatch event to bound animations
local function dispatch_event_animations(event_name, data)
    local bindings = Registry.event_bindings[event_name]
    if not bindings then return end
    for _, binding in ipairs(bindings) do
        if check_conditions(binding.conditions, data) then
            local session_id = PlaybackEngine.play(binding.anim_id, binding.options)
            if session_id then
                log_event(event_name, binding.anim_id .. " -> session #" .. session_id)
            end
        end
    end
end

-- Forward declarations for functions defined in section 18 but used in section 16
local check_chain_triggers

--------------------------------------------------------------------------------
-- 16. GAME EVENT HOOKS
--------------------------------------------------------------------------------

local hooks_installed = false

local function install_hooks()
    if hooks_installed then return end

    -- Player damage hook
    pcall(function()
        local td = sdk.find_type_definition("app.ropeway.HitPointController")
        if not td then return end
        local method = td:get_method("addDamage(System.Int32)")
        if not method then return end
        sdk.hook(method, function(args)
            pcall(function()
                local this = sdk.to_managed_object(args[2])
                local damage = sdk.to_int64(args[3]) & 0xFFFFFFFF
                local hp = tonumber(this:call("get_CurrentHitPoint")) or 0
                local hp_max = tonumber(this:call("get_DefaultHitPoint")) or 100
                local event_data = {
                    damage = damage,
                    hp_before = hp,
                    hp_max = hp_max,
                    hp_pct = hp / math.max(hp_max, 1),
                }
                EventBus.emit("player_damaged", event_data)
                dispatch_event_animations("player_damaged", event_data)
                log_event("player_damaged", string.format("dmg=%.0f hp=%.0f/%.0f", damage, hp, hp_max))
            end)
        end, nil)
        dbg("Hook installed: player_damaged")
    end)

    -- Player killed hook
    pcall(function()
        local td = sdk.find_type_definition("app.ropeway.HitPointController")
        if not td then return end
        local method = td:get_method("dead")
        if not method then return end
        sdk.hook(method, function(args)
            pcall(function()
                EventBus.emit("player_killed", {})
                dispatch_event_animations("player_killed", {})
                log_event("player_killed", "")
            end)
        end, nil)
        dbg("Hook installed: player_killed")
    end)

    hooks_installed = true
    dbg("Game event hooks installed")
end

-- Polled events (called each frame)
local function poll_events()
    if not init_done then return end

    -- Health threshold detection (edge-triggered)
    pcall(function()
        local hp_ctrl = getC(player_go, "app.ropeway.HitPointController")
        if hp_ctrl then
            local hp = tonumber(hp_ctrl:call("get_CurrentHitPoint")) or 0
            local hp_max = tonumber(hp_ctrl:call("get_DefaultHitPoint")) or 100
            local pct = hp / math.max(hp_max, 1)

            for _, threshold in ipairs(CFG.health_thresholds) do
                if prev_hp_pct > threshold and pct <= threshold then
                    local data = { percent = threshold, hp = hp, hp_max = hp_max, hp_pct = pct, direction = "down" }
                    EventBus.emit("health_threshold", data)
                    dispatch_event_animations("health_threshold", data)
                    log_event("health_threshold", string.format("%.0f%% (down)", threshold * 100))
                elseif prev_hp_pct <= threshold and pct > threshold then
                    local data = { percent = threshold, hp = hp, hp_max = hp_max, hp_pct = pct, direction = "up" }
                    EventBus.emit("health_threshold", data)
                    dispatch_event_animations("health_threshold", data)
                end
            end
            prev_hp_pct = pct
        end
    end)

    -- Key press detection (edge-triggered, only watched keys)
    local watched_copy = {}
    for i, kc in ipairs(CFG.watched_keys) do watched_copy[i] = kc end
    for _, keycode in ipairs(watched_copy) do
        local ok_down, down = pcall(is_key_down, keycode)
        if not ok_down then down = false end
        if down and not prev_keys[keycode] then
            -- Check chains first (can consume the input)
            local consumed = false
            local chain_ok, chain_result = pcall(check_chain_triggers, keycode)
            if chain_ok then consumed = chain_result end
            if not consumed then
                local data = { keycode = keycode, key_name = KB_KEY_NAMES[keycode] or string.format("0x%02X", keycode) }
                pcall(EventBus.emit, "key_pressed", data)
                pcall(dispatch_event_animations, "key_pressed", data)
            end
        end
        prev_keys[keycode] = down
    end

    -- Gamepad button detection (edge-triggered, fires key_pressed for mapped buttons)
    local cur_pad = get_pad_buttons()
    for keycode, pad_flag in pairs(CFG.pad_button_map) do
        if pad_flag > 0 then
            local now_pressed = (cur_pad & pad_flag) ~= 0
            local was_pressed = (prev_pad_buttons & pad_flag) ~= 0
            if now_pressed and not was_pressed then
                local consumed = false
                local chain_ok, chain_result = pcall(check_chain_triggers, keycode)
                if chain_ok then consumed = chain_result end
                if not consumed then
                    local data = { keycode = keycode, key_name = "PAD", pad_button = pad_flag }
                    pcall(EventBus.emit, "key_pressed", data)
                    pcall(dispatch_event_animations, "key_pressed", data)
                end
            end
        end
    end
    prev_pad_buttons = cur_pad

    -- Enemy proximity (throttled)
    enemy_scan_counter = enemy_scan_counter + 1
    if enemy_scan_counter >= ENEMY_SCAN_INTERVAL then
        enemy_scan_counter = 0
        scan_enemies()
        for _, enemy in ipairs(enemy_cache) do
            local near = enemy.distance <= CFG.proximity_radius
            local key = tostring(enemy.go)
            local was_near = prev_enemy_proximity[key]
            if near and not was_near then
                local data = { enemy_go = enemy.go, kind_id = enemy.kind_id, distance = enemy.distance, entered = true }
                EventBus.emit("enemy_proximity", data)
                dispatch_event_animations("enemy_proximity", data)
                log_event("enemy_proximity", enemy.kind_id .. " entered " .. string.format("%.1fm", enemy.distance))
            elseif not near and was_near then
                EventBus.emit("enemy_proximity", { enemy_go = enemy.go, kind_id = enemy.kind_id, distance = enemy.distance, entered = false })
            end
            prev_enemy_proximity[key] = near
        end
    end
end

--------------------------------------------------------------------------------
-- 17. MOD PACKAGE SCANNER
--------------------------------------------------------------------------------

local function load_mod_manifest(mod_id)
    local path = MODS_DIR .. "/" .. mod_id .. "/manifest.json"
    local data = json.load_file(path)
    if not data then return nil end

    data.mod_id = data.mod_id or mod_id
    Registry.mods[data.mod_id] = data
    dbg("Mod loaded: " .. (data.mod_name or mod_id) .. " v" .. (data.version or "?"))

    -- Register animations
    if data.animations then
        for _, anim in ipairs(data.animations) do
            local full_id = data.mod_id .. ":" .. anim.id
            anim.mod_id = data.mod_id
            Registry.animations[full_id] = anim
            dbg("  Anim: " .. full_id .. " (" .. (anim.type or "single") .. ")")
        end
    end

    -- Register event bindings
    if data.event_bindings then
        for _, binding in ipairs(data.event_bindings) do
            local full_anim_id = data.mod_id .. ":" .. binding.animation_id
            local event = binding.event
            if not Registry.event_bindings[event] then
                Registry.event_bindings[event] = {}
            end
            table.insert(Registry.event_bindings[event], {
                anim_id = full_anim_id,
                conditions = binding.conditions,
                priority = binding.priority or 0,
                mod_id = data.mod_id,
            })

            -- Auto-add keycodes to watched_keys
            if event == "key_pressed" and binding.conditions and binding.conditions.keycode then
                local kc = binding.conditions.keycode
                local found = false
                for _, wk in ipairs(CFG.watched_keys) do
                    if wk == kc then found = true; break end
                end
                if not found then table.insert(CFG.watched_keys, kc) end
            end
        end
    end

    -- Register chains
    if data.chains then
        for _, chain in ipairs(data.chains) do
            local full_id = data.mod_id .. ":" .. chain.id
            -- Prefix step anim_ids with mod_id
            for _, step in ipairs(chain.steps or {}) do
                step.anim_id = data.mod_id .. ":" .. step.anim_id
            end
            chain.mod_id = data.mod_id
            Registry.chains[full_id] = chain
        end
    end

    return data
end

local function scan_mods()
    -- Load mod index (list of mod directory names)
    local index = json.load_file(MODS_DIR .. "/index.json")
    if index and index.mods then
        for _, mod_id in ipairs(index.mods) do
            if not Registry.mods[mod_id] then
                load_mod_manifest(mod_id)
            end
        end
        dbg("Mod scan: " .. #index.mods .. " mods in index")
    else
        dbg("No " .. MODS_DIR .. "/index.json found (create it to auto-load mods)")
    end
end

local function load_all_mod_banks()
    if not player_motion then return end
    for anim_id, def in pairs(Registry.animations) do
        if def.bank_path and not Registry.loaded_banks[def.bank_path] then
            local bid = def.bank_id or assign_bank_id()
            def.bank_id = bid
            load_bank(player_motion, def.bank_path, bid)
        end
    end
end

--------------------------------------------------------------------------------
-- 18. CHAIN / COMBO SYSTEM
--------------------------------------------------------------------------------

local function start_chain(chain_id)
    local def = Registry.chains[chain_id]
    if not def or not def.steps or #def.steps < 1 then
        log.info(LOG_PREFIX .. "Chain " .. tostring(chain_id) .. ": no def/steps")
        return nil
    end
    if active_chains[chain_id] then
        log.info(LOG_PREFIX .. "Chain " .. tostring(chain_id) .. ": already active")
        return nil
    end

    local step_def = def.steps[1]

    active_chains[chain_id] = {
        chain_id = chain_id,
        def = def,
        step = 1,
        state = "playing",    -- "playing" | "window" | "idle"
        session_id = nil,
        window_start = 0,
        input_buffered = false,
    }

    -- Play first step
    local sid = PlaybackEngine.play(step_def.anim_id, {
        on_complete = function()
            local cs = active_chains[chain_id]
            if cs and cs.state == "playing" then
                cs.state = "window"
                cs.window_start = os.clock()
            end
        end,
    })
    if sid then
        active_chains[chain_id].session_id = sid
        dbg("Chain " .. chain_id .. " started, step 1")
    else
        active_chains[chain_id] = nil
    end
    return sid
end

local function advance_chain(chain_id)
    local cs = active_chains[chain_id]
    if not cs then return end

    cs.step = cs.step + 1
    local def = cs.def
    if cs.step > #def.steps then
        -- Chain complete (check loop)
        if def.loop_to and def.loop_to >= 1 and def.loop_to <= #def.steps then
            cs.step = def.loop_to
        else
            active_chains[chain_id] = nil
            dbg("Chain " .. chain_id .. " complete")
            return
        end
    end

    local step_def = def.steps[cs.step]
    cs.state = "playing"
    cs.input_buffered = false
    local sid = PlaybackEngine.play(step_def.anim_id, {
        on_complete = function()
            local cs2 = active_chains[chain_id]
            if cs2 and cs2.state == "playing" then
                cs2.state = "window"
                cs2.window_start = os.clock()
            end
        end,
    })
    if sid then
        cs.session_id = sid
        dbg("Chain " .. chain_id .. " step " .. cs.step)
    else
        active_chains[chain_id] = nil
    end
end

local function update_chains()
    for chain_id, cs in pairs(active_chains) do
        if cs.state == "window" then
            local window = cs.def.steps[cs.step] and cs.def.steps[cs.step].input_window or 0.4
            local elapsed = os.clock() - cs.window_start

            if cs.input_buffered then
                advance_chain(chain_id)
            elseif elapsed > window then
                -- Window expired, chain ends
                active_chains[chain_id] = nil
                dbg("Chain " .. chain_id .. " window expired at step " .. cs.step)
            end
        elseif cs.state == "playing" then
            -- Check for cancel events
            if cs.def.cancel_on then
                -- Cancel events are checked via EventBus listeners (registered during chain start)
            end
        end
    end
end

-- Check if a key press should trigger or advance a chain
check_chain_triggers = function(keycode)
    -- Advance existing chains
    for chain_id, cs in pairs(active_chains) do
        if cs.state == "window" or cs.state == "playing" then
            local trigger_kc = cs.def.trigger_conditions and cs.def.trigger_conditions.keycode
            if trigger_kc == keycode then
                if cs.state == "window" then
                    advance_chain(chain_id)
                else
                    cs.input_buffered = true
                end
                return true  -- consumed by chain
            end
        end
    end

    -- Start new chains
    for chain_id, def in pairs(Registry.chains) do
        if not active_chains[chain_id] then
            if def.trigger_event == "key_pressed" then
                local trigger_kc = def.trigger_conditions and def.trigger_conditions.keycode
                if trigger_kc == keycode then
                    start_chain(chain_id)
                    return true
                end
            end
        end
    end

    return false
end

--------------------------------------------------------------------------------
-- 19. CALLBACKS
--------------------------------------------------------------------------------

re.on_frame(function()
    -- Debounced settings save
    if settings_dirty and os.clock() - settings_dirty_time > 0.5 then
        save_settings()
        settings_dirty = false
    end

    frame_count = frame_count + 1

    local pl = get_player()
    if not pl then
        if game_ready then
            -- Cleanup all sessions
            for id, session in pairs(PlaybackEngine.sessions) do
                if session.state == "playing" then end_session(session, "player_lost") end
            end
            for id, session in pairs(paired_sessions) do
                if session.state ~= "complete" and session.state ~= "interrupted" then
                    session.state = "interrupted"
                    cleanup_paired_session(session)
                end
            end
            game_ready = false; init_done = false
            player_motion = nil; player_xform = nil; player_cc = nil
            player_fsm2 = nil; Registry.loaded_banks = {}
            active_chains = {}
        end
        return
    end

    if not game_ready then
        game_ready = true; ready_time = os.clock()
        return
    end

    if not init_done then
        if os.clock() - ready_time < INIT_DELAY then return end
        if cache_player() then
            install_hooks()
            scan_mods()
            load_all_mod_banks()
            init_done = true
            dbg("Init complete: " .. #CFG.watched_keys .. " watched keys, " ..
                (function() local n = 0; for _ in pairs(Registry.mods) do n = n + 1 end; return n end)() ..
                " mods, " ..
                (function() local n = 0; for _ in pairs(Registry.animations) do n = n + 1 end; return n end)() ..
                " animations")
        else
            game_ready = false
        end
        return
    end

    -- Safety: FSM stuck check
    if fsm_paused_by_us then
        local any_playing = false
        for _, s in pairs(PlaybackEngine.sessions) do
            if s.state == "playing" and s.fsm_paused then any_playing = true; break end
        end
        if not any_playing then
            dbg("SAFETY: FSM paused but no active session, restoring")
            unpause_fsm()
        end
    end

    -- Update playback
    pcall(PlaybackEngine.update)

    -- Update paired sessions
    for id, session in pairs(paired_sessions) do
        pcall(update_paired_session, session)
    end

    -- Update chains
    pcall(update_chains)

    -- Poll events
    pcall(poll_events)
end)

re.on_application_entry("PrepareRendering", function()
    if not init_done then return end

    -- Root motion for single-actor sessions
    for _, session in pairs(PlaybackEngine.sessions) do
        if session.state == "playing" then
            pcall(apply_session_root_motion, session)
        end
    end

    -- Frame sync for paired sessions (double-sync in PrepareRendering)
    for _, session in pairs(paired_sessions) do
        if session.state == "playing" and session.def.sync_mode == "frame_locked" then
            pcall(function()
                local primary = session.actors[1]
                local pf = primary.motion:call("getLayer", primary.layer_idx):call("get_Frame")
                for i, actor in ipairs(session.actors) do
                    if i ~= 1 and actor.playing then
                        actor.motion:call("getLayer", actor.layer_idx):call("set_Frame", pf)
                    end
                end
            end)
        end
    end
end)

--------------------------------------------------------------------------------
-- 20. UI
--------------------------------------------------------------------------------

re.on_draw_ui(function()
    local node_open = imgui.tree_node("CAF Mod API v" .. VERSION)
    if not node_open then return end

    local ui_ok, ui_err = pcall(function()
        if not game_ready then
            imgui.text("Waiting for player...")
            imgui.tree_pop()
            return
        end
        if not init_done then
            local r = math.max(0, INIT_DELAY - (os.clock() - ready_time))
            imgui.text(string.format("Initializing... (%.1fs)", r))
            imgui.tree_pop()
            return
        end

        -- Status
        local mod_count = 0
        for _ in pairs(Registry.mods) do mod_count = mod_count + 1 end
        local anim_count = 0
        for _ in pairs(Registry.animations) do anim_count = anim_count + 1 end
        local active = count_active_sessions()
        imgui.text(string.format("Mods: %.0f | Anims: %.0f | Active: %.0f | FSM: %s",
            mod_count, anim_count, active, fsm_paused_by_us and "PAUSED" or "free"))

        -- Loaded Mods
        if imgui.tree_node("Loaded Mods") then
            if mod_count == 0 then
                imgui.text("No mods loaded. Create CAF_mods/index.json")
            end
            for mod_id, mod_data in pairs(Registry.mods) do
                local mod_anims = {}
                for aid, adef in pairs(Registry.animations) do
                    if adef.mod_id == mod_id then
                        table.insert(mod_anims, { id = aid, def = adef })
                    end
                end

                local label = (mod_data.mod_name or mod_id) ..
                    " (" .. #mod_anims .. " anims)"
                if mod_data.author then label = label .. " by " .. mod_data.author end

                if imgui.tree_node(label) then
                    for _, anim in ipairs(mod_anims) do
                        local anim_label = anim.id
                        -- Show bound events
                        for evt, bindings in pairs(Registry.event_bindings) do
                            for _, b in ipairs(bindings) do
                                if b.anim_id == anim.id then
                                    anim_label = anim_label .. " [" .. evt
                                    if b.conditions then
                                        for ck, cv in pairs(b.conditions) do
                                            anim_label = anim_label .. " " .. ck .. "=" .. tostring(cv)
                                        end
                                    end
                                    anim_label = anim_label .. "]"
                                end
                            end
                        end

                        imgui.text("  " .. anim_label)
                        imgui.same_line()
                        if imgui.button("Play##" .. anim.id) then
                            PlaybackEngine.play(anim.id)
                        end
                    end

                    -- Per-mod custom UI (registered via CAF.registerModUI)
                    local mod_ui_fn = Registry.mod_ui_callbacks[mod_id]
                    if mod_ui_fn then
                        imgui.separator()
                        local ui_ok2, ui_err2 = pcall(mod_ui_fn, mod_id)
                        if not ui_ok2 then
                            imgui.text("UI error: " .. tostring(ui_err2))
                        end
                    end

                    imgui.tree_pop()
                end
            end

            -- Programmatic (non-mod) animations
            local prog_anims = {}
            for aid, adef in pairs(Registry.animations) do
                if not adef.mod_id then table.insert(prog_anims, { id = aid, def = adef }) end
            end
            if #prog_anims > 0 then
                if imgui.tree_node("Programmatic (" .. #prog_anims .. ")") then
                    for _, anim in ipairs(prog_anims) do
                        imgui.text("  " .. anim.id .. " (" .. (anim.def.type or "single") .. ")")
                        imgui.same_line()
                        if imgui.button("Play##prog_" .. anim.id) then
                            PlaybackEngine.play(anim.id)
                        end
                    end
                    imgui.tree_pop()
                end
            end

            imgui.tree_pop()
        end

        -- Active Sessions
        if imgui.tree_node("Active Sessions") then
            local any = false
            for id, session in pairs(PlaybackEngine.sessions) do
                if session.state == "playing" or session.state == "loading" then
                    any = true
                    imgui.text(string.format("  #%.0f: %s [%s] frame %.1f/%.0f spd=%.1f",
                        id, session.anim_id, session.state,
                        session.engine_frame, session.end_frame, session.engine_speed))
                    imgui.same_line()
                    if imgui.button("Stop##sess_" .. id) then
                        PlaybackEngine.stop(id)
                    end
                end
            end
            for id, session in pairs(paired_sessions) do
                if session.state ~= "complete" and session.state ~= "interrupted" then
                    any = true
                    imgui.text(string.format("  Paired #%.0f [%s] frame %.0f actors=%d",
                        id, session.state, session.current_frame, #session.actors))
                end
            end
            if not any then imgui.text("  (none)") end
            imgui.tree_pop()
        end

        -- Active Chains
        local chain_count = 0
        for _ in pairs(active_chains) do chain_count = chain_count + 1 end
        if chain_count > 0 then
            if imgui.tree_node("Active Chains (" .. chain_count .. ")") then
                for cid, cs in pairs(active_chains) do
                    imgui.text(string.format("  %s step %d/%d [%s]",
                        cid, cs.step, #cs.def.steps, cs.state))
                end
                imgui.tree_pop()
            end
        end

        -- Event Log
        if imgui.tree_node("Event Log") then
            if #event_log == 0 then
                imgui.text("  (no events yet)")
            else
                for i, ev in ipairs(event_log) do
                    if i > 10 then break end
                    imgui.text(string.format("  %.1fs %s %s",
                        ev.time - (ready_time or 0), ev.name, ev.summary))
                end
            end
            imgui.tree_pop()
        end

        -- Settings
        if imgui.tree_node("Settings") then
            local changed = false
            local c
            c, CFG.debug_log = imgui.checkbox("Debug log", CFG.debug_log)
            if c then changed = true end
            c, CFG.proximity_radius = imgui.slider_float("Proximity radius (m)", CFG.proximity_radius, 1.0, 20.0, "%.1f")
            if c then changed = true end
            c, CFG.max_concurrent = imgui.slider_float("Max concurrent", CFG.max_concurrent, 1, 16, "%.0f")
            if c then changed = true; CFG.max_concurrent = math.floor(CFG.max_concurrent) end

            if changed then settings_dirty = true; settings_dirty_time = os.clock() end

            imgui.spacing()
            if imgui.button("Rescan Mods") then
                scan_mods()
                load_all_mod_banks()
            end
            imgui.tree_pop()
        end
    end)

    imgui.tree_pop()

    if not ui_ok then
        log.info(LOG_PREFIX .. "UI error: " .. tostring(ui_err))
    end
end)

--------------------------------------------------------------------------------
-- 21. PUBLIC API (global table + module bridge)
--------------------------------------------------------------------------------

CAF = {
    VERSION = VERSION,

    registerAnimation = function(id, def)
        Registry.animations[id] = def
        dbg("API: registered animation '" .. id .. "'")
    end,

    registerChain = function(id, def)
        Registry.chains[id] = def
        -- Auto-watch trigger keycode
        if def.trigger_event == "key_pressed" and def.trigger_conditions and def.trigger_conditions.keycode then
            local kc = def.trigger_conditions.keycode
            local found = false
            for _, wk in ipairs(CFG.watched_keys) do
                if wk == kc then found = true; break end
            end
            if not found then table.insert(CFG.watched_keys, kc) end
        end
        dbg("API: registered chain '" .. id .. "'")
    end,

    bindEvent = function(anim_id, event_name, opts)
        if not Registry.event_bindings[event_name] then
            Registry.event_bindings[event_name] = {}
        end
        table.insert(Registry.event_bindings[event_name], {
            anim_id = anim_id,
            conditions = opts and opts.conditions,
            priority = opts and opts.priority or 0,
        })
        -- Auto-watch keys
        if event_name == "key_pressed" and opts and opts.conditions and opts.conditions.keycode then
            local kc = opts.conditions.keycode
            local found = false
            for _, wk in ipairs(CFG.watched_keys) do
                if wk == kc then found = true; break end
            end
            if not found then table.insert(CFG.watched_keys, kc) end
        end
        dbg("API: bound '" .. anim_id .. "' to event '" .. event_name .. "'")
    end,

    play = function(anim_id, opts)
        return PlaybackEngine.play(anim_id, opts)
    end,

    stop = function(session_id)
        PlaybackEngine.stop(session_id)
    end,

    on = function(event_name, callback, priority)
        return EventBus.on(event_name, callback, priority)
    end,

    off = function(event_name, listener_id)
        EventBus.off(event_name, listener_id)
    end,

    emit = function(event_name, data)
        EventBus.emit(event_name, data)
    end,

    isReady = function()
        return init_done
    end,

    getPlayer = function()
        return player_go
    end,

    getPlayerMotion = function()
        return player_motion
    end,

    getPlayerTransform = function()
        return player_xform
    end,

    getEnemies = function()
        if os.clock() - enemy_cache_time > 1.0 then scan_enemies() end
        return enemy_cache
    end,

    loadBank = function(path, bank_id)
        if not player_motion then return nil end
        local bid = bank_id or assign_bank_id()
        return load_bank(player_motion, path, bid)
    end,

    registerModUI = function(mod_id, draw_fn)
        Registry.mod_ui_callbacks[mod_id] = draw_fn
        dbg("API: registered UI for mod '" .. tostring(mod_id) .. "'")
    end,

    getModSettings = function(mod_id)
        local mod = Registry.mods[mod_id]
        return mod and mod.settings or nil
    end,

    setModSettings = function(mod_id, settings)
        local mod = Registry.mods[mod_id]
        if mod then mod.settings = settings end
    end,

    getAnimation = function(anim_id)
        return Registry.animations[anim_id]
    end,

    -- Gamepad helpers
    getPadButtons = function()
        return get_pad_buttons()
    end,

    getPadStickL = function()
        return get_pad_stick_l()
    end,

    mapPadButton = function(keycode, pad_flag)
        CFG.pad_button_map[keycode] = pad_flag
        dbg("API: mapped pad button 0x" .. string.format("%X", pad_flag) ..
            " to keycode 0x" .. string.format("%02X", keycode))
    end,

    setPadDeadzone = function(deadzone)
        CFG.pad_stick_deadzone = deadzone
    end,
}

log.info("[CAF] v" .. VERSION .. " loaded — API available via CAF global or require('CAF_ModAPI/API')")
