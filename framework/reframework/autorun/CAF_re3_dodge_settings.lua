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
    move_start = 0.01,
    move_end = 0.99,
    dodge_key = 0x56,          -- V
    dodge_pad_button = 0,      -- pad button bitmask (0 = none)
    pad_stick_deadzone = 0.5,
    debug_log = false,
    move_enabled = true,
}

local settings_dirty = false
local settings_dirty_time = 0
local last_dodge_time = 0
local registered = false

local function dbg(msg)
    if settings.debug_log then
        log.info(LOG_PREFIX .. msg)
    end
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

    -- Debounced settings save
    if settings_dirty and os.clock() - settings_dirty_time > 0.5 then
        save_settings()
        settings_dirty = false
    end
end)

log.info(LOG_PREFIX .. "Loaded — waiting for CAF ModAPI...")
