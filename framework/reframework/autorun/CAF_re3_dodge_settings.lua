-- CAF_re3_dodge_settings.lua — Settings UI for the RE3 Dodge mod package
-- Registers a custom UI panel with CAF ModAPI for dodge tuning.
-- Loads after CAF_ModAPI.lua alphabetically (r > M).

if reframework:get_game_name() ~= "re2" then return end

local MOD_ID = "re3_dodge"
local SETTINGS_FILE = "CAF_re3_dodge_settings.json"
local LOG_PREFIX = "[CAF/re3_dodge] "

-- Default settings (same as NativeDodge v2.0.3)
local settings = {
    speed = 2.0,
    dodge_distance = 2.5,
    blend_frames = 0.0,
    dodge_cooldown = 0.0,
    stop_on_direction_release = true,
    iframes_enabled = true,
    iframes_start_frame = 0,
    iframes_duration_frames = 10,
    move_start = 0.08,
    move_end = 1.0,
    dodge_key = 0x56,          -- V
    dodge_pad_button = 0,      -- pad button bitmask (0 = none)
    pad_stick_deadzone = 0.5,
    debug_log = false,
    move_enabled = true,
}

local settings_dirty = false
local settings_dirty_time = 0
local last_dodge_time = 0
local dodge_active = false
local dodge_start_time = 0
local dodge_session_id = nil
local pending_move_state_refresh_frames = 0
local registered = false
local iframes_hooked = false
_G.CAF_RE3_DODGE_IFRAME_HOOKED = _G.CAF_RE3_DODGE_IFRAME_HOOKED or false
local iframe_flags_applied = false
local iframe_sc_obj = nil
local iframe_hp_obj = nil

local function dbg(msg)
    if settings.debug_log then
        log.info(LOG_PREFIX .. msg)
    end
end

local function get_player_hp_controller()
    local ok, hp = pcall(function()
        local pm = sdk.get_managed_singleton(sdk.game_namespace("PlayerManager"))
        if not pm then return nil end
        local pl = pm:call("get_CurrentPlayer")
        if not pl then return nil end
        local hp_ctrl = nil
        pcall(function()
            hp_ctrl = pl:call("getComponent(System.Type)", sdk.typeof("app.ropeway.HitPointController"))
        end)
        if not hp_ctrl then
            pcall(function()
                local go = pl:call("get_GameObject")
                if go then
                    hp_ctrl = go:call("getComponent(System.Type)", sdk.typeof("app.ropeway.HitPointController"))
                end
            end)
        end
        if not hp_ctrl then
            pcall(function()
                local t = pl:call("get_Transform")
                if t then
                    local cc = t:call("get_ChildCount")
                    for i = 0, math.min(cc - 1, 20) do
                        local ct = t:call("getChild", i)
                        if ct then
                            local cg = ct:call("get_GameObject")
                            if cg then
                                hp_ctrl = cg:call("getComponent(System.Type)", sdk.typeof("app.ropeway.HitPointController"))
                                if hp_ctrl then break end
                            end
                        end
                    end
                end
            end)
        end
        return hp_ctrl
    end)
    return ok and hp or nil
end

local function get_player_survivor_condition()
    local ok, sc = pcall(function()
        local pm = sdk.get_managed_singleton(sdk.game_namespace("PlayerManager"))
        if not pm then return nil end
        local pl = pm:call("get_CurrentPlayer")
        if not pl then return nil end
        local cond = nil
        pcall(function()
            cond = pl:call("getComponent(System.Type)", sdk.typeof("app.ropeway.survivor.SurvivorCondition"))
        end)
        if not cond then
            pcall(function()
                local go = pl:call("get_GameObject")
                if go then
                    cond = go:call("getComponent(System.Type)", sdk.typeof("app.ropeway.survivor.SurvivorCondition"))
                end
            end)
        end
        if not cond then
            pcall(function()
                local t = pl:call("get_Transform")
                if t then
                    local cc = t:call("get_ChildCount")
                    for i = 0, math.min(cc - 1, 20) do
                        local ct = t:call("getChild", i)
                        if ct then
                            local cg = ct:call("get_GameObject")
                            if cg then
                                cond = cg:call("getComponent(System.Type)", sdk.typeof("app.ropeway.survivor.SurvivorCondition"))
                                if cond then break end
                            end
                        end
                    end
                end
            end)
        end
        return cond
    end)
    return ok and sc or nil
end

local function is_iframe_active()
    if not settings.iframes_enabled then return false end
    if not dodge_active then return false end
    if settings.iframes_duration_frames <= 0 then return false end

    local elapsed = os.clock() - dodge_start_time
    local speed = math.max(settings.speed or 1.0, 0.001)
    local start_s = (settings.iframes_start_frame or 0) / (60.0 * speed)
    local end_s = ((settings.iframes_start_frame or 0) + (settings.iframes_duration_frames or 0)) / (60.0 * speed)
    return elapsed >= start_s and elapsed <= end_s
end

local function clear_stuck_protection_flags()
    local sc = get_player_survivor_condition()
    local hp = get_player_hp_controller()
    if sc then
        pcall(function() sc:call("set_IgnoreGrapple", false) end)
        pcall(function() sc:call("set_Invincible", false) end)
        pcall(function() sc:call("set_NoDamage", false) end)
    end
    if hp then
        pcall(function() hp:call("set_Invincible", false) end)
        pcall(function() hp:call("set_NoDamage", false) end)
    end
end

local function update_iframe_runtime_flags()
    local should_apply = is_iframe_active()
    -- Safety model: only drive IgnoreGrapple live; damage i-frames are enforced
    -- via hook-time SKIP_ORIGINAL. Avoid persistent Invincible/NoDamage toggles.
    local sc = iframe_sc_obj or get_player_survivor_condition()
    iframe_sc_obj = sc
    if sc then
        pcall(function() sc:call("set_IgnoreGrapple", should_apply) end)
    end
    if should_apply and not iframe_flags_applied then
        iframe_flags_applied = true
        dbg("I-frame active (IgnoreGrapple + damage hook)")
    elseif not should_apply and iframe_flags_applied then
        iframe_flags_applied = false
        iframe_sc_obj = nil
        iframe_hp_obj = nil
        dbg("I-frame ended")
    end
end

local function ensure_iframe_hook()
    if iframes_hooked or _G.CAF_RE3_DODGE_IFRAME_HOOKED then
        iframes_hooked = true
        return
    end
    pcall(function()
        local td = sdk.find_type_definition("app.ropeway.HitPointController")
        if not td then return end
        local method = td:get_method("addDamage(System.Int32)")
        if not method then return end
        local function same_managed_obj(a, b)
            if not a or not b then return false end
            return tostring(a) == tostring(b)
        end
        sdk.hook(method, function(args)
            if not is_iframe_active() then
                return sdk.PreHookResult.CALL_ORIGINAL
            end
            local this_hp = sdk.to_managed_object(args[2])
            if not this_hp then
                return sdk.PreHookResult.CALL_ORIGINAL
            end
            local player_hp = get_player_hp_controller()
            if player_hp and same_managed_obj(this_hp, player_hp) then
                dbg("I-frame: blocked player damage")
                return sdk.PreHookResult.SKIP_ORIGINAL
            end
            return sdk.PreHookResult.CALL_ORIGINAL
        end, nil)
        iframes_hooked = true
        _G.CAF_RE3_DODGE_IFRAME_HOOKED = true
        dbg("I-frame damage hook installed")
    end)
end

--------------------------------------------------------------------------------
-- Settings persistence
--------------------------------------------------------------------------------

local function save_settings()
    pcall(function()
        json.dump_file(SETTINGS_FILE, settings)
    end)
    dbg("Settings saved")
end

local function load_settings()
    local ok, data = pcall(json.load_file, SETTINGS_FILE)
    if not ok or not data then return false end
    for k, v in pairs(data) do
        if settings[k] ~= nil then settings[k] = v end
    end
    dbg("Settings loaded")
    return true
end

load_settings()

--------------------------------------------------------------------------------
-- Apply settings to animation defs
--------------------------------------------------------------------------------

local ANIM_IDS = {
    MOD_ID .. ":dodge_front",
    MOD_ID .. ":dodge_back",
    MOD_ID .. ":dodge_left",
    MOD_ID .. ":dodge_right",
}

local function apply_settings()
    if not CAF then return end
    for _, anim_id in ipairs(ANIM_IDS) do
        local def = CAF.getAnimation(anim_id)
        if def then
            -- Two runtime variants:
            -- 1) stop_on_direction_release=true  -> fsm_mode=none (current responsive behavior)
            -- 2) stop_on_direction_release=false -> fsm_mode=pause (always play full animation)
            def.fsm_mode = settings.stop_on_direction_release and "none" or "pause"
            def.layer = 0
            def.speed = settings.speed
            def.blend_frames = settings.blend_frames
            if def.movement then
                def.movement.distance = settings.move_enabled and settings.dodge_distance or 0
                def.movement.start_pct = settings.move_start
                def.movement.end_pct = settings.move_end
            end
        end
    end
end

--------------------------------------------------------------------------------
-- Key name lookup
--------------------------------------------------------------------------------

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

local rebinding = false
local pad_rebinding = false
local pad_prev_buttons = 0
local SCANNABLE_KEYS = {}
for kc, _ in pairs(KB_KEY_NAMES) do
    if kc ~= 0 then table.insert(SCANNABLE_KEYS, kc) end
end

--------------------------------------------------------------------------------
-- Register with CAF ModAPI
--------------------------------------------------------------------------------

local function try_register()
    if registered then return end
    if not CAF or not CAF.registerModUI then return end

    -- Register our UI draw function
    CAF.registerModUI(MOD_ID, function(mod_id)
        local changed = false
        local c, v

        -- Speed
        c, v = imgui.slider_float("Speed##dodge", settings.speed, 0.5, 5.0, "%.1f")
        if c then settings.speed = v; changed = true end

        -- Distance
        c, settings.move_enabled = imgui.checkbox("Root motion##dodge", settings.move_enabled)
        if c then changed = true end
        if settings.move_enabled then
            c, v = imgui.slider_float("Distance (m)##dodge", settings.dodge_distance, 0.5, 8.0, "%.1f")
            if c then settings.dodge_distance = v; changed = true end
            c, v = imgui.slider_float("Move start %##dodge", settings.move_start, 0.0, 0.5, "%.2f")
            if c then settings.move_start = v; changed = true end
            c, v = imgui.slider_float("Move end %##dodge", settings.move_end, 0.5, 1.0, "%.2f")
            if c then settings.move_end = v; changed = true end
        end

        -- Blend
        c, v = imgui.slider_float("Blend frames##dodge", settings.blend_frames, 0.0, 30.0, "%.0f")
        if c then settings.blend_frames = math.floor(v); changed = true end

        -- Cooldown
        c, v = imgui.slider_float("Cooldown (s)##dodge", settings.dodge_cooldown, 0.0, 3.0, "%.1f")
        if c then settings.dodge_cooldown = v; changed = true end

        -- Direction release behavior toggle
        c, settings.stop_on_direction_release = imgui.checkbox(
            "Stop dodge when direction released##dodge",
            settings.stop_on_direction_release
        )
        if c then changed = true end

        -- I-frames
        c, settings.iframes_enabled = imgui.checkbox("Enable i-frames##dodge", settings.iframes_enabled)
        if c then changed = true end
        if settings.iframes_enabled then
            c, v = imgui.slider_float("I-frame start (anim frame)##dodge", settings.iframes_start_frame, 0.0, 60.0, "%.0f")
            if c then settings.iframes_start_frame = math.floor(v); changed = true end
            c, v = imgui.slider_float("I-frame duration (frames)##dodge", settings.iframes_duration_frames, 0.0, 60.0, "%.0f")
            if c then settings.iframes_duration_frames = math.floor(v); changed = true end
        end

        -- Dodge key rebind
        local key_name = KB_KEY_NAMES[settings.dodge_key] or string.format("0x%02X", settings.dodge_key)
        if rebinding then
            imgui.text("Press any key...")
            for _, kc in ipairs(SCANNABLE_KEYS) do
                local ok, down = pcall(reframework.is_key_down, reframework, kc)
                if ok and down then
                    settings.dodge_key = kc
                    rebinding = false
                    changed = true
                    -- Update event bindings in CAF
                    update_key_bindings()
                    break
                end
            end
        else
            if imgui.button("Dodge key: " .. key_name .. "##rebind") then
                rebinding = true
            end
        end

        -- Pad button rebind
        if pad_rebinding then
            imgui.text("Press any pad button...")
            if CAF and CAF.getPadButtons then
                local cur = CAF.getPadButtons()
                local new_btns = cur & (~pad_prev_buttons)
                if new_btns > 0 then
                    local f = 1
                    while f <= new_btns do
                        if (new_btns & f) ~= 0 then
                            settings.dodge_pad_button = f
                            break
                        end
                        f = f << 1
                    end
                    pad_rebinding = false
                    changed = true
                    if CAF.mapPadButton then
                        CAF.mapPadButton(settings.dodge_key, settings.dodge_pad_button)
                    end
                end
                pad_prev_buttons = cur
            end
        else
            local pad_label = settings.dodge_pad_button > 0
                and string.format("0x%X", settings.dodge_pad_button) or "None"
            if imgui.button("Pad button: " .. pad_label .. "##pad_rebind") then
                pad_rebinding = true
                pad_prev_buttons = (CAF and CAF.getPadButtons) and CAF.getPadButtons() or 0
            end
            imgui.same_line()
            if settings.dodge_pad_button > 0 and imgui.button("Clear##pad_clear") then
                settings.dodge_pad_button = 0
                changed = true
                if CAF and CAF.mapPadButton then
                    CAF.mapPadButton(settings.dodge_key, 0)
                end
            end
        end

        -- Stick deadzone
        c, v = imgui.slider_float("Stick deadzone##dodge", settings.pad_stick_deadzone, 0.1, 0.9, "%.2f")
        if c then
            settings.pad_stick_deadzone = v
            changed = true
            if CAF and CAF.setPadDeadzone then CAF.setPadDeadzone(v) end
        end

        -- Debug
        c, settings.debug_log = imgui.checkbox("Debug log##dodge", settings.debug_log)
        if c then changed = true end

        if changed then
            apply_settings()
            settings_dirty = true
            settings_dirty_time = os.clock()
        end
    end)

    -- Apply initial settings
    apply_settings()

    -- Register pad button mapping and deadzone
    if settings.dodge_pad_button > 0 and CAF.mapPadButton then
        CAF.mapPadButton(settings.dodge_key, settings.dodge_pad_button)
    end
    if CAF.setPadDeadzone then
        CAF.setPadDeadzone(settings.pad_stick_deadzone)
    end

    -- Set up cooldown enforcement via event listener
    CAF.on("animation:started", function(data)
        local anim_id = data.anim_id or ""
        if anim_id:find("^" .. MOD_ID .. ":dodge_") then
            last_dodge_time = os.clock()
            dodge_active = true
            dodge_start_time = os.clock()
            dodge_session_id = data.session_id
            pending_move_state_refresh_frames = 0
            update_iframe_runtime_flags()
        end
    end)

    CAF.on("animation:ended", function(data)
        if not dodge_active then return end
        local anim_id = data.anim_id or ""
        if anim_id:find("^" .. MOD_ID .. ":dodge_") then
            if (data.session_id ~= nil and dodge_session_id ~= nil and data.session_id == dodge_session_id) or data.session_id == nil then
                dodge_active = false
                dodge_session_id = nil
                local moved = tonumber(data.moved or 0) or 0
                local expected = tonumber(settings.dodge_distance or 0) or 0
                local short_root_motion = (expected > 0) and (moved < (expected * 0.85))
                local ended_collision_like = (data.wall_hit == true) or (data.root_motion_halted == true) or short_root_motion
                if ended_collision_like then
                    -- Avoid a visible hitch while player keeps moving after a
                    -- collision-shortened dodge. Locomotion is already healthy.
                    pending_move_state_refresh_frames = 0
                else
                    pending_move_state_refresh_frames = 3
                end
                update_iframe_runtime_flags()
            end
        end
    end)

    -- Register cooldown check as a condition on key_pressed
    CAF.on("key_pressed", function(data)
        if settings.dodge_cooldown > 0 then
            local elapsed = os.clock() - last_dodge_time
            if elapsed < settings.dodge_cooldown then
                return false  -- Block propagation (prevents dodge during cooldown)
            end
        end
    end, 100)  -- High priority: runs before the animation binding

    -- Install i-frame damage hook once CAF is ready.
    ensure_iframe_hook()
    -- Recover from any previously stuck invincibility flags.
    clear_stuck_protection_flags()

    registered = true
    log.info(LOG_PREFIX .. "Registered settings UI with CAF ModAPI")
end

-- Update key bindings when dodge key changes
function update_key_bindings()
    if not CAF then return end
    -- Re-register event bindings with new keycode
    -- Clear old bindings and re-add
    -- For simplicity, we update the watched keys list
    -- The manifest bindings use keycode 86 (V) by default
    -- We need to update the conditions in the existing bindings
    dbg("Key rebind to " .. tostring(settings.dodge_key) .. " — restart game to apply new key binding")
end

--------------------------------------------------------------------------------
-- Frame callback (registration + debounced save)
--------------------------------------------------------------------------------

re.on_frame(function()
    -- Try to register once CAF is available
    if not registered then
        try_register()
    end

    if pending_move_state_refresh_frames > 0 and not dodge_active then
        local sc = get_player_survivor_condition()
        if sc then
            pcall(function() sc:call("safeResetState") end)
            pcall(function() sc:call("checkNeedTransitionState") end)
        end
        pending_move_state_refresh_frames = pending_move_state_refresh_frames - 1
    end

    -- Failsafe: ensure dodge state cannot remain active indefinitely if an
    -- animation-ended event is missed due to interruption/reload edge cases.
    if dodge_active and (os.clock() - dodge_start_time) > 3.0 then
        dodge_active = false
        dodge_session_id = nil
    end

    -- Keep grapple/damage immunity flags synced with i-frame window.
    update_iframe_runtime_flags()

    -- Debounced settings save
    if settings_dirty and os.clock() - settings_dirty_time > 0.5 then
        save_settings()
        settings_dirty = false
    end
end)

log.info(LOG_PREFIX .. "Loaded — waiting for CAF ModAPI...")
