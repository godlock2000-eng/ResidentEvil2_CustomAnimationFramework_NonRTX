-- CAF_MotionLoader.lua — DynamicMotionBank + Paired Animation System
-- Phase B Track 2: Load .motlist/.motbank files at runtime,
-- inject as DynamicMotionBank, play via TreeLayer.changeMotion()
-- Supports: player + enemy targeting, FSM conflict strategies,
-- paired/synchronized multi-actor animations (2-6 actors)
-- v3.0

if reframework:get_game_name() ~= "re2" then return end

local MOD = "CAF_MotionLoader"
local VERSION = "3.0"

log.info("[" .. MOD .. "] v" .. VERSION .. " loading...")

--------------------------------------------------------------------------------
-- 1. STATE
--------------------------------------------------------------------------------

local game_ready = false
local player_motion = nil     -- via.motion.Motion on player
local player_go = nil         -- player GameObject
local player_xform = nil      -- player Transform

-- Loaded banks (per-actor tracking)
local loaded_banks = {}       -- { { name, path, holder, dyn_bank, dyn_idx, motions, target_go }, ... }
local game_banks = {}         -- { { bank_id, name, path, motion_count, motions }, ... }
local game_banks_built = false

-- UI state
local selected_bank = 1
local selected_motion = 1
local selected_game_bank = 1
local selected_game_motion = 1
local play_layer = 0
local interp_frames = 10.0
local play_speed = 1.0
local play_loop = false
local load_path = "CAF_custom/real_game_test.motbank"
local load_as_motlist = false
local load_bank_id = 900  -- Expected bank ID (must match the .motbank.1 file content)
local last_load_status = ""  -- Visible load result message

-- FSM conflict strategy
local fsm_strategy = 1  -- 1=None, 2=StopUpdate on layer 0, 3=Higher layer
local fsm_stopped = false
local fsm_original_layer = nil

-- Enemy targeting
local enemy_list = {}         -- { { go, motion, xform, name, distance }, ... }
local selected_enemy = 0
local target_mode = 1         -- 1=Player, 2=Selected Enemy
local enemy_scan_cooldown = 0

-- Active playback tracking
local active_playback = nil   -- { target_go, target_motion, bank_id, motion_id, layer_idx, start_time }

-- Delayed rescan state (for async resource loading)
local pending_rescan = nil    -- { bank_idx, bank_id, motion, start_time, attempts }

-- Paired animation state
local paired_sessions = {}       -- { [session_id] = session }
local next_session_id = 1

-- Paired animation UI state
local pa_ui = {
    primary_target = 1,          -- 1=Player, 2+=enemy index
    secondary_targets = {},      -- list of enemy indices (from enemy_list)
    secondary_count = 1,
    primary_bank = 0,
    primary_motion = 0,
    sec_bank = 0,
    sec_motion = 0,
    offset_x = 0.0,
    offset_y = 0.0,
    offset_z = 1.2,
    facing_mode = 1,             -- 1=toward_primary, 2=same_as_primary, 3=away
    duration = 90,
    sync_frames = true,
    use_game_bank = false,       -- true=use game bank IDs, false=use loaded bank motions
    layer_idx = 0,
    inter_frame = 10.0,
}

--------------------------------------------------------------------------------
-- 2. UTILITIES
--------------------------------------------------------------------------------

local function dbg(msg)
    log.info("[" .. MOD .. "] " .. msg)
end

local function getC(go, type_name)
    if not go then return nil end
    local actual_go = go
    if go.get_GameObject then
        actual_go = go:call("get_GameObject")
    end
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

local function get_player_motion()
    local pl = get_player()
    if not pl then return nil, nil, nil end

    local motion = getC(pl, "via.motion.Motion")
    if not motion then
        -- Search children (some player setups nest the Motion component)
        local t = pl:call("get_Transform")
        if t then
            local cc = t:call("get_ChildCount")
            for i = 0, math.min(cc - 1, 20) do
                local ct = t:call("getChild", i)
                if ct then
                    local cg = ct:call("get_GameObject")
                    if cg then
                        motion = getC(cg, "via.motion.Motion")
                        if motion then
                            pl = cg
                            break
                        end
                    end
                end
            end
        end
    end

    local xform = nil
    if pl then xform = pl:call("get_Transform") end
    return motion, pl, xform
end

-- Get CharacterController for position warping
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

-- Compute forward direction from quaternion (Y-up, proven in v1.4)
local function quat_forward(q)
    local fx = -(2 * (q.x * q.z + q.w * q.y))
    local fz = -(1 - 2 * (q.x * q.x + q.y * q.y))
    return fx, fz
end

-- Warp actor to position (and optionally rotation), persist with CC warp
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

-- Suspend enemy AI (BehaviorTree), returns restore info
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

-- Restore enemy AI from saved state
local function restore_enemy_ai(restore)
    if not restore then return end
    pcall(function()
        if restore.bt and restore.bt_was_enabled ~= nil then
            restore.bt:call("set_Enabled", restore.bt_was_enabled)
        end
    end)
end

--------------------------------------------------------------------------------
-- 3. ENEMY ENUMERATION
--------------------------------------------------------------------------------

local function scan_enemies()
    enemy_list = {}
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
                        local name = "Enemy_" .. i

                        -- Try to get kind ID
                        pcall(function()
                            local ec = ctx["<EnemyController>k__BackingField"]
                            if ec then
                                local kind = ec:call("get_KindID")
                                if kind then name = "Em" .. kind end
                            end
                        end)

                        local dist = 999
                        if player_pos and xform then
                            local ep = xform:call("get_Position")
                            if ep then
                                local dx = ep.x - player_pos.x
                                local dz = ep.z - player_pos.z
                                dist = math.sqrt(dx * dx + dz * dz)
                            end
                        end

                        if motion then
                            table.insert(enemy_list, {
                                go = go,
                                motion = motion,
                                xform = xform,
                                name = name,
                                distance = dist,
                            })
                        end
                    end
                end
            end
        end

        -- Sort by distance
        table.sort(enemy_list, function(a, b) return a.distance < b.distance end)
    end)

    if not ok then
        dbg("Enemy scan failed")
    else
        dbg("Found " .. #enemy_list .. " enemies with Motion components")
    end
end

--------------------------------------------------------------------------------
-- 4. TARGET SELECTION
--------------------------------------------------------------------------------

local function get_target_motion()
    if target_mode == 2 and selected_enemy > 0 and selected_enemy <= #enemy_list then
        return enemy_list[selected_enemy].motion, enemy_list[selected_enemy].go
    end
    return player_motion, player_go
end

--------------------------------------------------------------------------------
-- 5. DYNAMICMOTIONBANK LOADING
--------------------------------------------------------------------------------

local function snapshot_motion_counts(motion, max_bank)
    local counts = {}
    pcall(function()
        for bank_id = 0, max_bank do
            local c = motion:call("getMotionCount", bank_id)
            if c > 0 then counts[bank_id] = c end
        end
    end)
    return counts
end

local function enumerate_new_motions(motion, pre_counts, max_bank)
    local motions = {}
    pcall(function()
        local mi = sdk.create_instance("via.motion.MotionInfo")
        if not mi then return end
        mi = mi:add_ref()
        for bank_id = 0, max_bank do
            local mot_count = motion:call("getMotionCount", bank_id)
            if mot_count > 0 then
                local prev = pre_counts[bank_id] or 0
                if mot_count > prev then
                    for m = prev, math.min(mot_count - 1, 300) do
                        local got = motion:call(
                            "getMotionInfoByIndex(System.UInt32, System.UInt32, via.motion.MotionInfo)",
                            bank_id, m, mi)
                        if got then
                            table.insert(motions, {
                                bank_id = bank_id,
                                id = mi:call("get_MotionID"),
                                name = mi:call("get_MotionName") or ("mot_" .. m),
                                end_frame = mi:call("get_MotionEndFrame"),
                            })
                        end
                    end
                end
            end
        end
    end)
    return motions
end

-- Enumerate motions for a specific bank ID only (avoids picking up game motions)
local function enumerate_bank_motions(motion, bank_id)
    local motions = {}
    pcall(function()
        local mi = sdk.create_instance("via.motion.MotionInfo")
        if not mi then return end
        mi = mi:add_ref()
        local mot_count = motion:call("getMotionCount", bank_id)
        dbg("Bank " .. bank_id .. " has " .. mot_count .. " motions")
        for m = 0, math.min(mot_count - 1, 300) do
            local got = motion:call(
                "getMotionInfoByIndex(System.UInt32, System.UInt32, via.motion.MotionInfo)",
                bank_id, m, mi)
            if got then
                table.insert(motions, {
                    bank_id = bank_id,
                    id = mi:call("get_MotionID"),
                    name = mi:call("get_MotionName") or ("mot_" .. m),
                    end_frame = mi:call("get_MotionEndFrame"),
                })
            end
        end
    end)
    return motions
end

local function load_resource(motion, resource_path, is_motlist)
    if not game_ready or not motion then
        return { success = false, error = "game not ready" }
    end

    dbg("Loading " .. (is_motlist and "motlist" or "motbank") .. ": " .. resource_path)
    local result = { success = false, error = nil }

    -- Snapshot before loading
    local pre_counts = snapshot_motion_counts(motion, 1500)

    local ok, err = pcall(function()
        local resource, holder

        -- ALWAYS load as MotionBankResource (DynamicMotionBank.set_MotionBank needs MotionBankResourceHolder)
        -- For motlist files, create a .motbank.1 wrapper that references the motlist.
        -- For motbank files, load directly.
        resource = sdk.create_resource("via.motion.MotionBankResource", resource_path)
        if not resource then
            -- Fallback: try as MotionListResource if motbank load fails
            if is_motlist then
                dbg("MotionBankResource nil, trying MotionListResource...")
                resource = sdk.create_resource("via.motion.MotionListResource", resource_path)
                if not resource then
                    result.error = "Both MotionBankResource and MotionListResource returned nil for: " .. resource_path
                    return
                end
                holder = resource:create_holder("via.motion.MotionListResourceHolder")
            else
                result.error = "sdk.create_resource(MotionBankResource) returned nil for: " .. resource_path
                return
            end
        else
            holder = resource:create_holder("via.motion.MotionBankResourceHolder")
        end

        if not holder then
            result.error = "create_holder returned nil"
            return
        end
        holder = holder:add_ref()
        dbg("Resource holder created OK (type=" .. tostring(holder:get_type_definition():get_full_name()) .. ")")

        -- Create DynamicMotionBank
        local dyn_inst = sdk.create_instance("via.motion.DynamicMotionBank")
        if not dyn_inst then
            result.error = "create_instance DynamicMotionBank returned nil"
            return
        end
        local dyn_bank = dyn_inst:add_ref()

        -- DynamicMotionBank API (from il2cpp):
        --   set_MotionBank(MotionBankResourceHandle) — the main resource setter
        --   set_Priority(s32) — priority for bank resolution
        --   set_Order(s32)
        --   set_OverwriteBankType(bool) + set_BankType(u32)
        -- NOTE: BankID is NOT on DynamicMotionBank — it comes from the .motbank.1 file content
        dyn_bank:call("set_MotionBank", holder)
        dyn_bank:call("set_Priority", 100 + #loaded_banks)

        -- Bank ID comes from the .motbank.1 binary (set by motbank_writer.py --bank-id)
        local assigned_bank_id = load_bank_id

        -- Verify: check that set_MotionBank stuck (get_MotionBank returns the handle)
        local verify_mb = nil
        pcall(function() verify_mb = dyn_bank:call("get_MotionBank") end)
        local verify_pri = nil
        pcall(function() verify_pri = dyn_bank:call("get_Priority") end)
        dbg("Verify: MotionBank=" .. tostring(verify_mb)
            .. " Priority=" .. tostring(verify_pri)
            .. " holder=" .. tostring(holder)
            .. " expected_bank_id=" .. assigned_bank_id)

        -- Attach to target's Motion component
        local cur_count = motion:call("getDynamicMotionBankCount")
        local new_idx = cur_count
        motion:call("setDynamicMotionBankCount", cur_count + 1)
        motion:call("setDynamicMotionBank", new_idx, dyn_bank)
        dbg("Attached at dynIdx=" .. new_idx .. ", bankID=" .. assigned_bank_id)

        -- Verify attachment
        local verify_bank = nil
        pcall(function() verify_bank = motion:call("getDynamicMotionBank", new_idx) end)
        dbg("Verify attached: getDynamicMotionBank(" .. new_idx .. ")=" .. tostring(verify_bank))

        -- Enumerate motions specifically from our assigned bank ID
        local motions = enumerate_bank_motions(motion, assigned_bank_id)

        -- If targeted enum found nothing, try diff-based scan as fallback
        if #motions == 0 then
            dbg("No motions at bank " .. assigned_bank_id .. ", trying diff scan...")
            motions = enumerate_new_motions(motion, pre_counts, 1500)
        end

        local name = resource_path:match("([^/]+)%.mot[lb][ia][sn][tk]$") or resource_path
        local bank_entry_idx = #loaded_banks + 1
        table.insert(loaded_banks, {
            name = name,
            path = resource_path,
            holder = holder,
            dyn_bank = dyn_bank,
            dyn_idx = new_idx,
            bank_id = assigned_bank_id,
            motions = motions,
            target_go = (target_mode == 2 and selected_enemy > 0) and enemy_list[selected_enemy].go or player_go,
        })

        result.success = true
        dbg("Loaded '" .. name .. "' with " .. #motions .. " new motions")
        for _, mm in ipairs(motions) do
            dbg("  bank=" .. mm.bank_id .. " id=" .. mm.id .. " name=" .. (mm.name or "?")
                .. " frames=" .. string.format("%.0f", mm.end_frame))
        end
        if #motions == 0 then
            dbg("0 motions — scheduling delayed rescan (resource may be loading async)")
            pending_rescan = {
                bank_idx = bank_entry_idx,
                bank_id = assigned_bank_id,
                motion = motion,
                start_time = os.clock(),
                attempts = 0,
            }
        end
    end)

    if not ok then
        result.error = tostring(err)
        dbg("Load EXCEPTION: " .. result.error)
    end
    return result
end

--------------------------------------------------------------------------------
-- 6. BUILD GAME BANK LIST
--------------------------------------------------------------------------------

local function build_game_banks(motion)
    game_banks = {}
    pcall(function()
        local mi = sdk.create_instance("via.motion.MotionInfo"):add_ref()
        local active_count = motion:call("getActiveMotionBankCount")
        for a = 0, active_count - 1 do
            local bank = motion:call("getActiveMotionBank", a)
            if bank then
                local bank_id = bank:call("get_BankID")
                local name = bank:call("get_Name") or ("Bank_" .. bank_id)
                local path = ""
                pcall(function()
                    local ml = bank:call("get_MotionList")
                    if ml then path = ml:call("get_ResourcePath") or "" end
                end)
                local mot_count = motion:call("getMotionCount", bank_id)

                local motions = {}
                for m = 0, math.min(mot_count - 1, 100) do
                    local got = motion:call(
                        "getMotionInfoByIndex(System.UInt32, System.UInt32, via.motion.MotionInfo)",
                        bank_id, m, mi)
                    if got then
                        table.insert(motions, {
                            id = mi:call("get_MotionID"),
                            name = mi:call("get_MotionName") or ("mot_" .. m),
                            end_frame = mi:call("get_MotionEndFrame"),
                        })
                    end
                end

                table.insert(game_banks, {
                    bank_id = bank_id,
                    name = name,
                    path = path,
                    motion_count = mot_count,
                    motions = motions,
                })
            end
        end
    end)
    game_banks_built = true
    dbg("Found " .. #game_banks .. " active game banks")
end

--------------------------------------------------------------------------------
-- 7. PLAYBACK WITH FSM CONFLICT HANDLING
--------------------------------------------------------------------------------

local function apply_fsm_strategy(motion, target_layer_idx)
    if fsm_strategy == 2 then
        -- StopUpdate: freeze layer 0 so FSM can't override
        pcall(function()
            local layer0 = motion:call("getLayer", 0)
            if layer0 then
                fsm_original_layer = layer0:call("get_StopUpdate")
                layer0:call("set_StopUpdate", true)
                fsm_stopped = true
                dbg("FSM Strategy: StopUpdate on layer 0")
            end
        end)
    elseif fsm_strategy == 3 then
        -- Higher layer: play on layer 1+ (FSM only controls layer 0)
        -- Just return the desired layer index
        local layer_count = motion:call("getLayerCount")
        if target_layer_idx == 0 and layer_count > 1 then
            dbg("FSM Strategy: Using layer 1 instead of 0 (total layers: " .. layer_count .. ")")
            return 1
        end
    end
    return target_layer_idx
end

local function restore_fsm(motion)
    if fsm_stopped then
        pcall(function()
            local layer0 = motion:call("getLayer", 0)
            if layer0 then
                layer0:call("set_StopUpdate", fsm_original_layer or false)
            end
        end)
        fsm_stopped = false
        dbg("FSM restored")
    end
end

local function play_motion(motion, bank_id, motion_id, go)
    local actual_layer = play_layer

    -- Apply FSM strategy
    actual_layer = apply_fsm_strategy(motion, actual_layer)

    pcall(function()
        local layer_count = motion:call("getLayerCount")
        if actual_layer >= layer_count then
            dbg("Layer " .. actual_layer .. " out of range (max " .. (layer_count - 1) .. ")")
            return
        end

        local layer = motion:call("getLayer", actual_layer)
        if not layer then
            dbg("getLayer(" .. actual_layer .. ") returned nil")
            return
        end

        -- Change motion
        layer:call("changeMotion",
            bank_id, motion_id,
            0.0, interp_frames,
            2,  -- CrossFade
            1   -- Smooth
        )

        layer:call("set_Speed", play_speed)
        if play_loop then
            layer:call("set_WrapMode", 2)  -- Loop
        end

        active_playback = {
            target_go = go,
            target_motion = motion,
            bank_id = bank_id,
            motion_id = motion_id,
            layer_idx = actual_layer,
            start_time = os.clock(),
        }

        dbg("Playing bank=" .. bank_id .. " motion=" .. motion_id
            .. " layer=" .. actual_layer .. " speed=" .. play_speed
            .. " blend=" .. interp_frames)
    end)
end

local function stop_playback()
    if active_playback and active_playback.target_motion then
        restore_fsm(active_playback.target_motion)
        active_playback = nil
        dbg("Playback stopped")
    end
end

--------------------------------------------------------------------------------
-- 8. PAIRED ANIMATION SYSTEM
--------------------------------------------------------------------------------

-- Create a paired animation session
-- def = {
--   actors = {
--     [1] = { bank_id=N, motion_id=N, layer=0, inter_frame=10, speed=1.0,
--             offset={x,y,z}, facing="toward_primary"|"same"|"away" },
--     [2] = { ... }, ... up to [6]
--   },
--   duration_frames = N or 0 (auto-detect from animation),
--   sync_mode = "frame_locked" or "independent",
--   max_distance = 5.0,
--   primary_idx = 1,
-- }
-- actor_gos = { go1, go2, ... } corresponding to def.actors

local function create_paired_session(def, actor_gos)
    if not def or not def.actors or #def.actors < 2 then
        dbg("Paired: need at least 2 actors in def")
        return nil
    end
    if not actor_gos or #actor_gos < #def.actors then
        dbg("Paired: not enough game objects (" .. (#actor_gos or 0) .. " < " .. #def.actors .. ")")
        return nil
    end

    local session = {
        id = next_session_id,
        def = def,
        state = "aligning",
        actors = {},
        primary_idx = def.primary_idx or 1,
        start_time = os.clock(),
        current_frame = 0,
        align_timer = 0,
        max_align_time = 1.5,
    }
    next_session_id = next_session_id + 1

    -- Resolve primary actor first
    local primary_xform = nil
    local primary_pos = nil
    local primary_rot = nil

    for i = 1, #def.actors do
        local go = actor_gos[i]
        if not go then
            dbg("Paired: actor " .. i .. " is nil")
            return nil
        end

        local motion = getC(go, "via.motion.Motion")
        if not motion then
            dbg("Paired: actor " .. i .. " has no Motion component")
            return nil
        end

        local actual_go = go
        if go.get_GameObject then actual_go = go:call("get_GameObject") end
        local xform = actual_go:call("get_Transform")
        local cc = get_cc(go)

        local cur_pos = xform:call("get_Position")
        local actor = {
            go = go,
            motion = motion,
            xform = xform,
            cc = cc,
            original_pos = { x = cur_pos.x, y = cur_pos.y, z = cur_pos.z },
            original_rot = xform:call("get_Rotation"),
            target_pos = nil,
            target_rot = nil,
            layer_idx = def.actors[i].layer or 0,
            ai_restore = nil,
            playing = false,
        }

        session.actors[i] = actor

        if i == session.primary_idx then
            primary_xform = xform
            primary_pos = { x = cur_pos.x, y = cur_pos.y, z = cur_pos.z }
            primary_rot = xform:call("get_Rotation")
        end
    end

    if not primary_pos or not primary_rot then
        dbg("Paired: could not get primary actor position/rotation")
        return nil
    end

    -- Calculate target positions from offsets, relative to primary's orientation
    local fwd_x, fwd_z = quat_forward(primary_rot)
    local right_x = fwd_z
    local right_z = -fwd_x

    for i, actor_def in ipairs(def.actors) do
        local actor = session.actors[i]
        if not actor then break end

        if i == session.primary_idx then
            actor.target_pos = { x = primary_pos.x, y = primary_pos.y, z = primary_pos.z }
            actor.target_rot = primary_rot
        else
            local offset = actor_def.offset or { x = 0, y = 0, z = 0 }
            -- Transform offset by primary's world orientation
            local tp = {
                x = primary_pos.x + right_x * (offset.x or 0) + fwd_x * (offset.z or 0),
                y = primary_pos.y + (offset.y or 0),
                z = primary_pos.z + right_z * (offset.x or 0) + fwd_z * (offset.z or 0),
            }
            actor.target_pos = tp

            -- Calculate facing rotation
            local facing = actor_def.facing or "toward_primary"
            if facing == "toward_primary" then
                local dx = primary_pos.x - tp.x
                local dz = primary_pos.z - tp.z
                local angle = math.atan(dx, dz)
                local half = angle * 0.5
                -- Create quaternion by modifying a copy
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
                -- same as primary
                actor.target_rot = primary_rot
            end

            -- Suspend AI for non-player secondary actors
            actor.ai_restore = suspend_enemy_ai(actor.go)
        end
    end

    paired_sessions[session.id] = session
    dbg("Paired: session #" .. session.id .. " created, " .. #session.actors .. " actors, state=aligning")
    return session.id
end

-- Start motion playback on a single actor within a paired session
local function paired_start_actor_motion(actor, actor_def)
    if not actor.motion then return false end
    local ok = pcall(function()
        local layer_count = actor.motion:call("getLayerCount")
        if actor.layer_idx >= layer_count then
            dbg("Paired: layer " .. actor.layer_idx .. " out of range")
            return
        end

        local layer = actor.motion:call("getLayer", actor.layer_idx)
        if not layer then return end

        layer:call("changeMotion",
            actor_def.bank_id or 0,
            actor_def.motion_id or 0,
            actor_def.start_frame or 0.0,
            actor_def.inter_frame or 10.0,
            2,  -- CrossFade
            1   -- Smooth
        )

        if actor_def.speed then
            layer:call("set_Speed", actor_def.speed)
        end
    end)
    actor.playing = ok
    return ok
end

-- Clean up a paired session (restore AI, mark complete)
local function cleanup_paired_session(session)
    for i, actor in ipairs(session.actors) do
        if actor.ai_restore then
            restore_enemy_ai(actor.ai_restore)
            actor.ai_restore = nil
        end
    end
    dbg("Paired: session #" .. session.id .. " cleaned up")
end

-- Interrupt a paired session
local function interrupt_paired_session(session, reason)
    dbg("Paired: session #" .. session.id .. " interrupted — " .. (reason or "unknown"))
    session.state = "interrupted"
    cleanup_paired_session(session)
end

-- Stop a specific paired session
local function stop_paired_session(session_id)
    local session = paired_sessions[session_id]
    if session and session.state ~= "complete" and session.state ~= "interrupted" then
        interrupt_paired_session(session, "manual stop")
    end
end

-- Stop all paired sessions
local function stop_all_paired()
    for id, session in pairs(paired_sessions) do
        if session.state ~= "complete" and session.state ~= "interrupted" then
            interrupt_paired_session(session, "stop all")
        end
    end
end

-- Update a single paired animation session (called each frame)
local function update_paired_session(session)
    if session.state == "complete" or session.state == "interrupted" then
        return
    end

    -- Validate all actors still exist
    for i, actor in ipairs(session.actors) do
        if not actor.go or not actor.motion then
            interrupt_paired_session(session, "actor " .. i .. " nil")
            return
        end
        local valid = pcall(function()
            local _ = actor.xform:call("get_Position")
        end)
        if not valid then
            interrupt_paired_session(session, "actor " .. i .. " destroyed")
            return
        end
    end

    if session.state == "aligning" then
        -- Warp all actors to their target positions
        for i, actor in ipairs(session.actors) do
            if actor.target_pos then
                warp_actor(actor.xform, actor.cc, actor.target_pos, actor.target_rot)
            end
        end

        session.align_timer = session.align_timer + (1.0 / 60.0)

        -- Check if all actors are close enough to targets (or timeout)
        local all_aligned = true
        for i, actor in ipairs(session.actors) do
            if actor.target_pos then
                local ok, is_close = pcall(function()
                    local pos = actor.xform:call("get_Position")
                    local dx = pos.x - actor.target_pos.x
                    local dz = pos.z - actor.target_pos.z
                    return math.sqrt(dx * dx + dz * dz) < 0.2
                end)
                if not ok or not is_close then
                    all_aligned = false
                end
            end
        end

        if all_aligned or session.align_timer > session.max_align_time then
            -- Start motions on all actors simultaneously
            dbg("Paired: session #" .. session.id .. " actors aligned, starting motions")
            for i, actor in ipairs(session.actors) do
                local actor_def = session.def.actors[i]
                if actor_def then
                    paired_start_actor_motion(actor, actor_def)
                end
            end
            session.state = "playing"
            session.start_time = os.clock()
        end

    elseif session.state == "playing" then
        -- Read primary actor's current frame
        local primary = session.actors[session.primary_idx]
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

        -- Frame-locked sync: set all secondary actors to the primary's frame
        if session.def.sync_mode == "frame_locked" then
            for i, actor in ipairs(session.actors) do
                if i ~= session.primary_idx and actor.playing then
                    pcall(function()
                        local layer = actor.motion:call("getLayer", actor.layer_idx)
                        if layer then
                            layer:call("set_Frame", primary_frame)
                        end
                    end)
                end
            end
        end

        -- Enforce position lock (prevent actors from drifting during animation)
        for i, actor in ipairs(session.actors) do
            if actor.target_pos then
                pcall(function()
                    local pos = actor.xform:call("get_Position")
                    local dx = pos.x - actor.target_pos.x
                    local dz = pos.z - actor.target_pos.z
                    local drift = math.sqrt(dx * dx + dz * dz)
                    -- Re-warp if drift exceeds threshold
                    if drift > 0.3 then
                        warp_actor(actor.xform, actor.cc, actor.target_pos, actor.target_rot)
                    end
                end)
            end
        end

        -- Distance check between actors
        local primary_actor = session.actors[session.primary_idx]
        if primary_actor.xform then
            local pp_ok, pp = pcall(function() return primary_actor.xform:call("get_Position") end)
            if pp_ok and pp then
                local max_dist = session.def.max_distance or 5.0
                for i, actor in ipairs(session.actors) do
                    if i ~= session.primary_idx then
                        pcall(function()
                            local ap = actor.xform:call("get_Position")
                            local dx = ap.x - pp.x
                            local dz = ap.z - pp.z
                            local dist = math.sqrt(dx * dx + dz * dz)
                            if dist > max_dist then
                                interrupt_paired_session(session,
                                    "actor " .. i .. " too far (" .. string.format("%.1f", dist) .. "m)")
                            end
                        end)
                    end
                end
            end
        end

        -- Check if animation ended
        local duration = session.def.duration_frames or 0
        if duration > 0 then
            if primary_frame >= duration - 1 then
                session.state = "blend_out"
            end
        elseif primary_end > 0 and primary_frame >= primary_end - 1 then
            session.state = "blend_out"
        end

    elseif session.state == "blend_out" then
        dbg("Paired: session #" .. session.id .. " blend_out -> complete")
        session.state = "complete"
        cleanup_paired_session(session)
    end
end

-- Get count of active (non-complete) paired sessions
local function get_active_paired_count()
    local count = 0
    for _, s in pairs(paired_sessions) do
        if s.state ~= "complete" and s.state ~= "interrupted" then
            count = count + 1
        end
    end
    return count
end

--------------------------------------------------------------------------------
-- 9. FRAME LOOP
--------------------------------------------------------------------------------

re.on_frame(function()
    local motion, go, xform = get_player_motion()

    if not motion then
        if game_ready then
            loaded_banks = {}
            game_banks = {}
            game_banks_built = false
            active_playback = nil
            fsm_stopped = false
            stop_all_paired()
            paired_sessions = {}
        end
        game_ready = false
        player_motion = nil
        player_go = nil
        player_xform = nil
        return
    end

    if not game_ready then
        game_ready = true
        player_motion = motion
        player_go = go
        player_xform = xform
        dbg("Player detected, game ready")
    else
        player_motion = motion
        player_go = go
        player_xform = xform
    end

    -- Delayed rescan for async resource loading
    if pending_rescan then
        local elapsed = os.clock() - pending_rescan.start_time
        -- Check every ~1 second for up to 10 seconds
        if elapsed > (pending_rescan.attempts + 1) * 1.0 then
            pending_rescan.attempts = pending_rescan.attempts + 1

            if pending_rescan.qt3_mode then
                -- QT3 extended mode: check DynBankCount, hasMotion, and diff scan
                local dbc = 0
                pcall(function() dbc = pending_rescan.motion:call("getDynamicMotionBankCount") end)

                -- Check hasMotion on all 3 test banks
                local any_has = false
                if pending_rescan.qt3_dyn_banks then
                    for mi, db in ipairs(pending_rescan.qt3_dyn_banks) do
                        for _, bid in ipairs({0, 1, 900}) do
                            local hm = false
                            pcall(function() hm = db:call("hasMotion", bid, 0, 0) end)
                            if hm then
                                dbg("QT3 rescan#" .. pending_rescan.attempts .. " M" .. mi .. " hasMotion(" .. bid .. ",0,0)=TRUE!")
                                any_has = true
                            end
                        end
                    end
                end

                -- Full diff scan
                local post = snapshot_motion_counts(pending_rescan.motion, 1500)
                local post_total = 0
                for _, c in pairs(post) do post_total = post_total + c end
                local pre_total = 0
                if pending_rescan.qt3_pre then
                    for _, c in pairs(pending_rescan.qt3_pre) do pre_total = pre_total + c end
                end

                dbg("QT3 rescan#" .. pending_rescan.attempts .. " t=" .. string.format("%.1f", elapsed)
                    .. "s DynBankCount=" .. dbc
                    .. " motions=" .. post_total .. " (delta=" .. (post_total - pre_total) .. ")"
                    .. " hasMotion=" .. tostring(any_has))

                if post_total > pre_total or any_has then
                    dbg("QT3: SUCCESS! Motions appeared after delay")
                    -- Report which banks gained motions
                    for bid, cnt in pairs(post) do
                        local prev = (pending_rescan.qt3_pre or {})[bid] or 0
                        if cnt > prev then
                            dbg("QT3:   bank " .. bid .. ": " .. prev .. " -> " .. cnt)
                        end
                    end
                    pending_rescan = nil
                elseif pending_rescan.attempts >= 10 then
                    dbg("QT3: TIMEOUT after 10s — no motions appeared via any method")
                    pending_rescan = nil
                end
            else
                -- Standard rescan: check specific bank_id
                local cnt = 0
                pcall(function() cnt = pending_rescan.motion:call("getMotionCount", pending_rescan.bank_id) end)
                dbg("Async rescan #" .. pending_rescan.attempts .. " bank " .. pending_rescan.bank_id .. ": " .. cnt .. " motions (t=" .. string.format("%.1f", elapsed) .. "s)")

                if cnt > 0 then
                    local motions = enumerate_bank_motions(pending_rescan.motion, pending_rescan.bank_id)
                    dbg("Async rescan SUCCESS: " .. #motions .. " motions found at bank " .. pending_rescan.bank_id)
                    if pending_rescan.bank_idx and loaded_banks[pending_rescan.bank_idx] then
                        loaded_banks[pending_rescan.bank_idx].motions = motions
                    end
                    pending_rescan = nil
                elseif pending_rescan.attempts >= 10 then
                    dbg("Async rescan TIMEOUT: bank " .. pending_rescan.bank_id .. " still has 0 motions after 10s")
                    pending_rescan = nil
                end
            end
        end
    end

    -- Periodic enemy scan
    if enemy_scan_cooldown > 0 then
        enemy_scan_cooldown = enemy_scan_cooldown - 1
    end

    -- Track active single-playback — auto-restore FSM when animation ends
    if active_playback then
        pcall(function()
            local layer = active_playback.target_motion:call("getLayer", active_playback.layer_idx)
            if layer then
                local frame = layer:call("get_Frame")
                local end_frame = layer:call("get_EndFrame")
                if frame >= end_frame - 1 and not play_loop then
                    restore_fsm(active_playback.target_motion)
                    active_playback = nil
                end
            end
        end)
    end

    -- Update all paired animation sessions
    for id, session in pairs(paired_sessions) do
        update_paired_session(session)
    end

    -- Clean up old completed/interrupted sessions (keep last 10)
    local finished = {}
    for id, session in pairs(paired_sessions) do
        if session.state == "complete" or session.state == "interrupted" then
            table.insert(finished, id)
        end
    end
    if #finished > 10 then
        table.sort(finished)
        for i = 1, #finished - 10 do
            paired_sessions[finished[i]] = nil
        end
    end
end)

-- PrepareRendering: enforce frame sync after animation evaluation, before render
re.on_pre_application_entry("PrepareRendering", function()
    for id, session in pairs(paired_sessions) do
        if session.state == "playing" and session.def.sync_mode == "frame_locked" then
            local primary = session.actors[session.primary_idx]
            local primary_frame = 0
            pcall(function()
                local layer = primary.motion:call("getLayer", primary.layer_idx)
                if layer then
                    primary_frame = layer:call("get_Frame")
                end
            end)

            -- Re-enforce frame sync on secondaries (catches any drift from anim eval)
            for i, actor in ipairs(session.actors) do
                if i ~= session.primary_idx and actor.playing then
                    pcall(function()
                        local layer = actor.motion:call("getLayer", actor.layer_idx)
                        if layer then
                            layer:call("set_Frame", primary_frame)
                        end
                    end)
                end
            end
        end
    end
end)

--------------------------------------------------------------------------------
-- 10. UI
--------------------------------------------------------------------------------

re.on_draw_ui(function()
    if not imgui.tree_node(MOD .. " v" .. VERSION) then return end

    if not game_ready then
        imgui.text_colored("Waiting for player...", 0xFF00CCFF)
        imgui.tree_pop()
        return
    end

    -- === Target Selection ===
    imgui.text_colored("=== Target ===", 0xFF00FFFF)
    local target_labels = { "Player" }
    for i, e in ipairs(enemy_list) do
        table.insert(target_labels, e.name .. " (" .. string.format("%.1fm", e.distance) .. ")")
    end
    local changed
    changed, target_mode = imgui.combo("Target", target_mode, target_labels)
    if target_mode > 1 then
        selected_enemy = target_mode - 1
    else
        selected_enemy = 0
    end

    imgui.same_line()
    if imgui.button("Scan Enemies") then
        scan_enemies()
    end

    imgui.spacing()

    -- === Playback Controls ===
    imgui.text_colored("=== Playback ===", 0xFF00FFFF)
    changed, play_layer = imgui.slider_int("Layer", play_layer, 0, 5)
    changed, interp_frames = imgui.slider_float("Blend frames", interp_frames, 0.0, 60.0, "%.1f")
    changed, play_speed = imgui.slider_float("Speed", play_speed, -2.0, 3.0, "%.2f")
    changed, play_loop = imgui.checkbox("Loop", play_loop)

    -- FSM Strategy
    local fsm_labels = { "None (raw)", "StopUpdate layer 0", "Use higher layer" }
    changed, fsm_strategy = imgui.combo("FSM Strategy", fsm_strategy, fsm_labels)

    -- Active playback info
    if active_playback then
        imgui.spacing()
        pcall(function()
            local layer = active_playback.target_motion:call("getLayer", active_playback.layer_idx)
            if layer then
                local frame = layer:call("get_Frame")
                local end_frame = layer:call("get_EndFrame")
                local bank = layer:call("get_BankID")
                local mot = layer:call("get_MotionID")
                imgui.text_colored(string.format("Playing: bank=%d mot=%d frame=%.0f/%.0f layer=%d",
                    bank, mot, frame, end_frame, active_playback.layer_idx), 0xFF00FF00)
            end
        end)
        if imgui.button("STOP") then
            stop_playback()
        end
    end

    imgui.spacing()
    imgui.separator()

    -- === Load Resource ===
    imgui.text_colored("=== Load Animation Bank ===", 0xFF00FFFF)
    imgui.text("Use .motbank path (e.g. CAF_custom/dodge_front.motbank)")
    changed, load_path = imgui.input_text("Path", load_path)
    changed, load_as_motlist = imgui.checkbox("Load as MotionList (fallback only)", load_as_motlist)
    local bid_str
    changed, bid_str = imgui.input_text("Expected Bank ID", tostring(load_bank_id))
    load_bank_id = tonumber(bid_str) or 900

    if imgui.button("Load") then
        -- Trim whitespace and trailing punctuation from path
        load_path = load_path:match("^%s*(.-)%s*$") or load_path
        load_path = load_path:gsub("[,;]+$", "")
        local motion = get_target_motion()
        if motion and load_path ~= "" then
            local result = load_resource(motion, load_path, load_as_motlist)
            if result.success then
                last_load_status = "OK: loaded " .. load_path
            else
                last_load_status = "FAIL: " .. (result.error or "unknown error")
            end
        else
            last_load_status = "FAIL: no target motion or empty path"
        end
    end
    imgui.same_line()
    if imgui.button("Diagnose") then
        -- Enhanced diagnostics: check file existence, try multiple resource types
        load_path = load_path:match("^%s*(.-)%s*$") or load_path
        load_path = load_path:gsub("[,;]+$", "")
        local diag_lines = {}
        local p = load_path
        table.insert(diag_lines, "Path: " .. p)

        -- 1. Check motbank file on disk
        local native_bank = "natives/x64/" .. p .. ".1"
        local f1 = io.open(native_bank, "rb")
        if f1 then
            local sz = f1:seek("end")
            f1:close()
            table.insert(diag_lines, "Motbank EXISTS (" .. sz .. " bytes) at " .. native_bank)
        else
            table.insert(diag_lines, "Motbank NOT FOUND at " .. native_bank)
        end

        -- 2. Check motlist file on disk (if applicable)
        local native_list = "natives/x64/" .. p:gsub("%.motbank$", ".motlist") .. ".85"
        local f2 = io.open(native_list, "rb")
        if f2 then
            local sz = f2:seek("end")
            f2:close()
            table.insert(diag_lines, "Motlist EXISTS (" .. sz .. " bytes) at " .. native_list)
        else
            table.insert(diag_lines, "Motlist NOT FOUND at " .. native_list)
        end

        -- 3. Try sdk.create_resource with MotionBankResource (primary method)
        local r1 = sdk.create_resource("via.motion.MotionBankResource", p)
        table.insert(diag_lines, "MotionBankResource('" .. p .. "'): " .. tostring(r1))

        -- 4. Try as MotionListResource for comparison
        local motlist_p = p:gsub("%.motbank$", ".motlist")
        local r2 = sdk.create_resource("via.motion.MotionListResource", motlist_p)
        table.insert(diag_lines, "MotionListResource('" .. motlist_p .. "'): " .. tostring(r2))

        -- 5. Control: real_game_test.motbank
        local ctrl = sdk.create_resource("via.motion.MotionBankResource", "CAF_custom/real_game_test.motbank")
        table.insert(diag_lines, "CONTROL real_game_test.motbank: " .. tostring(ctrl))

        last_load_status = table.concat(diag_lines, " | ")
        for _, line in ipairs(diag_lines) do
            dbg("DIAG: " .. line)
        end
    end
    imgui.same_line()
    imgui.text("Loaded: " .. #loaded_banks)
    if last_load_status ~= "" then
        local color = last_load_status:sub(1,2) == "OK" and 0xFF00FF00 or 0xFF0000FF
        imgui.text_colored(last_load_status, color)
    end
    if pending_rescan then
        local elapsed = os.clock() - pending_rescan.start_time
        imgui.text_colored(string.format("Async rescan: bank %d, attempt %d/10, %.1fs elapsed",
            pending_rescan.bank_id, pending_rescan.attempts, elapsed), 0xFFFFAA00)
    end

    -- Blind Play Test: load bank and try changeMotion regardless of getMotionCount
    if imgui.button("Blind Play Test") then
        local motion, go = get_target_motion()
        if motion and go then
            local actual_go = go
            if go.get_GameObject then actual_go = go:call("get_GameObject") end

            -- Find controller
            local dmbc = nil
            pcall(function()
                dmbc = actual_go:call("getComponent(System.Type)",
                    sdk.typeof(sdk.game_namespace("DynamicMotionBankController")))
            end)

            -- Load ALL 3 custom motbanks
            local test_banks = {
                { path = "CAF_custom/real_game_test.motbank", bank_id = 902, name = "real_game" },
                { path = "CAF_custom/dodge_front.motbank",    bank_id = 900, name = "dodge_front" },
                { path = "CAF_custom/test_head_nod.motbank",  bank_id = 901, name = "head_nod" },
            }

            for _, tb in ipairs(test_banks) do
                local res = sdk.create_resource("via.motion.MotionBankResource", tb.path)
                dbg("BLIND: " .. tb.name .. " resource=" .. tostring(res))
                if res then
                    res = res:add_ref()
                    local holder = res:create_holder("via.motion.MotionBankResourceHolder")
                    if holder then
                        holder = holder:add_ref()
                        local db = sdk.create_instance("via.motion.DynamicMotionBank"):add_ref()
                        db:call("set_MotionBank", holder)
                        db:call("set_Priority", 200)
                        if dmbc then
                            pcall(function() dmbc:call("addDynamicMotionBank", db) end)
                        end
                        local c = motion:call("getDynamicMotionBankCount")
                        motion:call("setDynamicMotionBankCount", c + 1)
                        motion:call("setDynamicMotionBank", c, db)
                        dbg("BLIND: " .. tb.name .. " loaded, DynBankCount=" .. motion:call("getDynamicMotionBankCount"))
                    end
                end
            end

            -- Test dodge_front (bank 900, 74 bones, T+R, 180 frames @ 60fps)
            pcall(function()
                local layer = motion:call("getLayer", 0)
                if layer then
                    dbg("BLIND: changeMotion(900, 0) — dodge_front (74 bones, full)...")
                    layer:call("changeMotion", 900, 0, 0.0, 10.0, 2, 1)
                    local b = layer:call("get_BankID")
                    local m = layer:call("get_MotionID")
                    local f = layer:call("get_EndFrame")
                    dbg("BLIND: playing bank=" .. b .. " mot=" .. m .. " endFrame=" .. f)
                end
            end)

            last_load_status = "BLIND: 3 banks loaded, playing dodge_front(900,0) — watch player!"
        end
    end
    imgui.same_line()

    -- Quick Test v3: controller addRequest + private addDynamicMotionBank + delayed check
    if imgui.button("Quick Test v3") then
        local motion, go = get_target_motion()
        if motion and go then
            local pre = snapshot_motion_counts(motion, 1500)
            local pre_total = 0
            for _, c in pairs(pre) do pre_total = pre_total + c end
            dbg("QT3: pre-total=" .. pre_total .. " DynBankCount=" .. motion:call("getDynamicMotionBankCount"))

            local actual_go = go
            if go.get_GameObject then actual_go = go:call("get_GameObject") end

            -- Find DynamicMotionBankController
            local dmbc = nil
            pcall(function()
                dmbc = actual_go:call("getComponent(System.Type)",
                    sdk.typeof(sdk.game_namespace("DynamicMotionBankController")))
            end)
            dbg("QT3: Controller=" .. tostring(dmbc))

            -- Create resource with add_ref on resource AND holder (MMDK pattern)
            local res = sdk.create_resource("via.motion.MotionBankResource",
                "SectionRoot/Animation/Player/pl10/bank/BareHand.motbank")
            if res then
                res = res:add_ref()  -- MMDK does add_ref on resource
                local holder = res:create_holder("via.motion.MotionBankResourceHolder")
                if holder then
                    holder = holder:add_ref()
                    dbg("QT3: resource+holder created (both add_ref'd)")

                    local dyn_bank = sdk.create_instance("via.motion.DynamicMotionBank"):add_ref()
                    dyn_bank:call("set_MotionBank", holder)
                    dyn_bank:call("set_Priority", 200)

                    -- Method 1: controller.addRequest
                    if dmbc then
                        local h1 = nil
                        pcall(function() h1 = dmbc:call("addRequest", "qt3_addreq", dyn_bank) end)
                        dbg("QT3 M1 addRequest: handle=" .. tostring(h1))
                    end

                    -- Method 2: controller.addDynamicMotionBank (private)
                    local dyn_bank2 = sdk.create_instance("via.motion.DynamicMotionBank"):add_ref()
                    dyn_bank2:call("set_MotionBank", holder)
                    dyn_bank2:call("set_Priority", 201)
                    if dmbc then
                        local ok2, ret2 = pcall(function()
                            return dmbc:call("addDynamicMotionBank", dyn_bank2)
                        end)
                        dbg("QT3 M2 addDynamicMotionBank(private): ok=" .. tostring(ok2) .. " ret=" .. tostring(ret2))
                    end

                    -- Method 3: manual setDynamicMotionBank (previous approach)
                    local dyn_bank3 = sdk.create_instance("via.motion.DynamicMotionBank"):add_ref()
                    dyn_bank3:call("set_MotionBank", holder)
                    dyn_bank3:call("set_Priority", 202)
                    local c = motion:call("getDynamicMotionBankCount")
                    motion:call("setDynamicMotionBankCount", c + 1)
                    motion:call("setDynamicMotionBank", c, dyn_bank3)
                    dbg("QT3 M3 manual setDynamicMotionBank: idx=" .. c)

                    -- Immediate check
                    local post_dbc = motion:call("getDynamicMotionBankCount")
                    dbg("QT3: immediate DynBankCount=" .. post_dbc)

                    -- Schedule delayed check (5 seconds)
                    pending_rescan = {
                        bank_idx = nil,
                        bank_id = 0,  -- scan bank 0 since BareHand uses bank 0
                        motion = motion,
                        start_time = os.clock(),
                        attempts = 0,
                        -- Extended: also check DynBankCount and hasMotion
                        qt3_dyn_banks = { dyn_bank, dyn_bank2, dyn_bank3 },
                        qt3_pre = pre,
                        qt3_mode = true,
                    }
                    last_load_status = "QT3: 3 methods tried, waiting for delayed check..."
                end
            end
        end
    end

    -- Diagnostic: check motion counts for loaded bank IDs
    if #loaded_banks > 0 then
        local motion = get_target_motion()
        if motion then
            local diag = "Bank check:"
            for i, b in ipairs(loaded_banks) do
                if b.bank_id then
                    local cnt = 0
                    pcall(function() cnt = motion:call("getMotionCount", b.bank_id) end)
                    diag = diag .. " [" .. b.bank_id .. "]=" .. cnt
                end
            end
            imgui.text_colored(diag, 0xFFFFFF00)

            -- Also check DynamicMotionBank count
            local dyn_cnt = 0
            pcall(function() dyn_cnt = motion:call("getDynamicMotionBankCount") end)
            imgui.text("DynBankCount=" .. dyn_cnt)
        end
    end

    imgui.spacing()

    -- === Loaded Banks ===
    if #loaded_banks > 0 and imgui.tree_node("Loaded Banks (" .. #loaded_banks .. ")") then
        local bank_names = {}
        for _, b in ipairs(loaded_banks) do
            table.insert(bank_names, b.name .. " (" .. #b.motions .. " motions)")
        end
        changed, selected_bank = imgui.combo("Bank##loaded", selected_bank, bank_names)
        if selected_bank > #loaded_banks then selected_bank = 1 end

        local bank = loaded_banks[selected_bank]
        if bank and #bank.motions > 0 then
            local mot_names = {}
            for _, m in ipairs(bank.motions) do
                table.insert(mot_names,
                    m.name .. " (id=" .. m.id .. " bank=" .. m.bank_id
                    .. " f=" .. string.format("%.0f", m.end_frame) .. ")")
            end
            changed, selected_motion = imgui.combo("Motion##loaded", selected_motion, mot_names)
            if selected_motion > #bank.motions then selected_motion = 1 end

            local mot = bank.motions[selected_motion]
            if mot then
                if imgui.button("  PLAY  ##loaded") then
                    local motion, go = get_target_motion()
                    play_motion(motion, mot.bank_id, mot.id, go)
                end
                imgui.same_line()
                if imgui.button("Next##loaded") and selected_motion < #bank.motions then
                    selected_motion = selected_motion + 1
                    local next_mot = bank.motions[selected_motion]
                    if next_mot then
                        local motion, go = get_target_motion()
                        play_motion(motion, next_mot.bank_id, next_mot.id, go)
                    end
                end
            end
        elseif bank then
            imgui.text("No motions discovered yet (bank ID=" .. (bank.bank_id or "?") .. ")")
            if imgui.button("Rescan##" .. selected_bank) then
                local motion = get_target_motion()
                if motion and bank.bank_id then
                    bank.motions = enumerate_bank_motions(motion, bank.bank_id)
                    dbg("Rescan bank " .. bank.bank_id .. ": " .. #bank.motions .. " motions")
                    if #bank.motions == 0 then
                        -- Fallback: broad scan
                        bank.motions = enumerate_new_motions(motion, {}, 1500)
                        dbg("Fallback scan: " .. #bank.motions .. " total motions")
                    end
                end
            end
        end
        imgui.tree_pop()
    end

    imgui.spacing()
    imgui.separator()

    -- === Game Banks ===
    if not game_banks_built then
        if imgui.button("Build Game Bank List") then
            build_game_banks(player_motion)
        end
    end

    if game_banks_built and imgui.tree_node("Game Banks (" .. #game_banks .. ")") then
        if #game_banks > 0 then
            local gbank_names = {}
            for _, gb in ipairs(game_banks) do
                table.insert(gbank_names,
                    gb.name .. " (id=" .. gb.bank_id .. " mots=" .. gb.motion_count .. ")")
            end
            changed, selected_game_bank = imgui.combo("Bank##game", selected_game_bank, gbank_names)
            if selected_game_bank > #game_banks then selected_game_bank = 1 end

            local gb = game_banks[selected_game_bank]
            if gb then
                imgui.text("Path: " .. (gb.path ~= "" and gb.path or "(internal)"))
                if gb.path ~= "" and imgui.button("Copy to loader") then
                    load_path = gb.path
                end

                if #gb.motions > 0 then
                    local gmot_names = {}
                    for _, m in ipairs(gb.motions) do
                        table.insert(gmot_names,
                            m.name .. " (id=" .. m.id
                            .. " f=" .. string.format("%.0f", m.end_frame) .. ")")
                    end
                    changed, selected_game_motion = imgui.combo("Motion##game", selected_game_motion, gmot_names)
                    if selected_game_motion > #gb.motions then selected_game_motion = 1 end

                    local gm = gb.motions[selected_game_motion]
                    if gm then
                        if imgui.button("  PLAY  ##game") then
                            local motion, go = get_target_motion()
                            play_motion(motion, gb.bank_id, gm.id, go)
                        end
                        imgui.same_line()
                        if imgui.button("Next##game") and selected_game_motion < #gb.motions then
                            selected_game_motion = selected_game_motion + 1
                            local next_gm = gb.motions[selected_game_motion]
                            if next_gm then
                                local motion, go = get_target_motion()
                                play_motion(motion, gb.bank_id, next_gm.id, go)
                            end
                        end
                    end
                end
            end
        end
        imgui.tree_pop()
    end

    imgui.spacing()
    imgui.separator()

    -- === Paired Animation ===
    if imgui.tree_node("Paired Animations") then

        local active_count = get_active_paired_count()
        if active_count > 0 then
            imgui.text_colored("Active sessions: " .. active_count, 0xFF00FF00)
        end

        imgui.text_colored("--- Setup ---", 0xFF00FFFF)

        -- Primary: bank + motion IDs (direct entry for maximum flexibility)
        changed, pa_ui.primary_bank = imgui.input_text("Primary Bank ID", tostring(pa_ui.primary_bank))
        pa_ui.primary_bank = tonumber(pa_ui.primary_bank) or 0
        changed, pa_ui.primary_motion = imgui.input_text("Primary Motion ID", tostring(pa_ui.primary_motion))
        pa_ui.primary_motion = tonumber(pa_ui.primary_motion) or 0

        imgui.spacing()

        -- Secondary: bank + motion IDs
        changed, pa_ui.sec_bank = imgui.input_text("Secondary Bank ID", tostring(pa_ui.sec_bank))
        pa_ui.sec_bank = tonumber(pa_ui.sec_bank) or 0
        changed, pa_ui.sec_motion = imgui.input_text("Secondary Motion ID", tostring(pa_ui.sec_motion))
        pa_ui.sec_motion = tonumber(pa_ui.sec_motion) or 0

        imgui.spacing()

        -- Offset
        changed, pa_ui.offset_x = imgui.slider_float("Offset X", pa_ui.offset_x, -5.0, 5.0, "%.2f")
        changed, pa_ui.offset_y = imgui.slider_float("Offset Y", pa_ui.offset_y, -3.0, 3.0, "%.2f")
        changed, pa_ui.offset_z = imgui.slider_float("Offset Z", pa_ui.offset_z, -5.0, 5.0, "%.2f")

        -- Facing
        local facing_labels = { "Toward Primary", "Same as Primary", "Away from Primary" }
        changed, pa_ui.facing_mode = imgui.combo("Facing##pa", pa_ui.facing_mode, facing_labels)

        -- Duration and sync
        changed, pa_ui.duration = imgui.slider_int("Duration (frames)", pa_ui.duration, 0, 600)
        changed, pa_ui.sync_frames = imgui.checkbox("Frame-locked sync", pa_ui.sync_frames)
        changed, pa_ui.layer_idx = imgui.slider_int("Layer##pa", pa_ui.layer_idx, 0, 5)
        changed, pa_ui.inter_frame = imgui.slider_float("Blend##pa", pa_ui.inter_frame, 0.0, 60.0, "%.1f")

        imgui.spacing()
        imgui.text_colored("--- Launch ---", 0xFF00FFFF)

        -- Secondary target: pick from enemy list
        if #enemy_list == 0 then
            imgui.text_colored("No enemies scanned. Click 'Scan Enemies' above.", 0xFF8888FF)
        else
            local sec_labels = {}
            for i, e in ipairs(enemy_list) do
                table.insert(sec_labels, e.name .. " (" .. string.format("%.1fm", e.distance) .. ")")
            end
            if pa_ui.secondary_count < 1 then pa_ui.secondary_count = 1 end
            changed, pa_ui.secondary_count = imgui.slider_int("Secondary actors", pa_ui.secondary_count, 1, math.min(5, #enemy_list))

            for s = 1, pa_ui.secondary_count do
                if not pa_ui.secondary_targets[s] then
                    pa_ui.secondary_targets[s] = math.min(s, #enemy_list)
                end
                changed, pa_ui.secondary_targets[s] = imgui.combo(
                    "Secondary #" .. s, pa_ui.secondary_targets[s], sec_labels)
            end

            imgui.spacing()

            -- PLAY PAIRED button
            if imgui.button("  PLAY PAIRED  ") then
                local facing_map = { "toward_primary", "same", "away" }
                local facing = facing_map[pa_ui.facing_mode] or "toward_primary"

                -- Build definition
                local def = {
                    actors = {
                        [1] = {
                            role = "primary",
                            bank_id = pa_ui.primary_bank,
                            motion_id = pa_ui.primary_motion,
                            layer = pa_ui.layer_idx,
                            inter_frame = pa_ui.inter_frame,
                            speed = play_speed,
                        },
                    },
                    duration_frames = pa_ui.duration,
                    sync_mode = pa_ui.sync_frames and "frame_locked" or "independent",
                    max_distance = 8.0,
                    primary_idx = 1,
                }

                local actor_gos = { player_go }

                for s = 1, pa_ui.secondary_count do
                    local idx = pa_ui.secondary_targets[s]
                    if idx and idx > 0 and idx <= #enemy_list then
                        local sec_idx = #def.actors + 1
                        def.actors[sec_idx] = {
                            role = "secondary",
                            bank_id = pa_ui.sec_bank,
                            motion_id = pa_ui.sec_motion,
                            layer = pa_ui.layer_idx,
                            inter_frame = pa_ui.inter_frame,
                            speed = play_speed,
                            offset = { x = pa_ui.offset_x * s, y = pa_ui.offset_y, z = pa_ui.offset_z },
                            facing = facing,
                        }
                        table.insert(actor_gos, enemy_list[idx].go)
                    end
                end

                if #actor_gos >= 2 then
                    local sid = create_paired_session(def, actor_gos)
                    if sid then
                        pa_ui.active_session = sid
                    end
                else
                    dbg("Paired: need at least 1 enemy selected")
                end
            end

            imgui.same_line()
            if imgui.button("STOP ALL##pa") then
                stop_all_paired()
            end
        end

        imgui.spacing()
        imgui.text_colored("--- Sessions ---", 0xFF00FFFF)

        -- Show all sessions
        local session_count = 0
        for id, session in pairs(paired_sessions) do
            session_count = session_count + 1
            local state_color = 0xFFFFFFFF
            if session.state == "playing" then state_color = 0xFF00FF00
            elseif session.state == "aligning" then state_color = 0xFF00CCFF
            elseif session.state == "blend_out" then state_color = 0xFFFFCC00
            elseif session.state == "interrupted" then state_color = 0xFF0000FF
            elseif session.state == "complete" then state_color = 0xFF888888 end

            local label = string.format("#%d [%s] %d actors",
                id, session.state, #session.actors)

            if session.state == "playing" then
                label = label .. string.format(" frame=%.0f", session.current_frame)
                if session.def.duration_frames and session.def.duration_frames > 0 then
                    label = label .. "/" .. session.def.duration_frames
                end
            end

            imgui.text_colored(label, state_color)

            if session.state == "playing" or session.state == "aligning" then
                imgui.same_line()
                if imgui.button("Stop##" .. id) then
                    stop_paired_session(id)
                end
            end
        end

        if session_count == 0 then
            imgui.text("No sessions")
        end

        imgui.tree_pop()
    end

    imgui.spacing()
    imgui.separator()

    -- === Layer Inspector ===
    if imgui.tree_node("Layer Inspector") then
        local motion = get_target_motion()
        if motion then
            pcall(function()
                local lc = motion:call("getLayerCount")
                imgui.text("Layer count: " .. lc)
                for li = 0, math.min(lc - 1, 7) do
                    local layer = motion:call("getLayer", li)
                    if layer then
                        local bank = layer:call("get_BankID")
                        local mot = layer:call("get_MotionID")
                        local frame = layer:call("get_Frame")
                        local end_f = layer:call("get_EndFrame")
                        local speed = layer:call("get_Speed")
                        local weight = layer:call("get_Weight")
                        local stop = layer:call("get_StopUpdate")
                        imgui.text(string.format(
                            "  [%d] bank=%d mot=%d f=%.0f/%.0f spd=%.1f w=%.2f %s",
                            li, bank, mot, frame, end_f, speed, weight,
                            stop and "STOPPED" or ""))
                    end
                end
            end)

            -- DynamicMotionBank info (note: DynamicMotionBank has NO get_BankID)
            pcall(function()
                local dmc = motion:call("getDynamicMotionBankCount")
                imgui.text("DynamicMotionBanks: " .. dmc)
                for di = 0, dmc - 1 do
                    local db = motion:call("getDynamicMotionBank", di)
                    if db then
                        local pri = -1
                        pcall(function() pri = db:call("get_Priority") end)
                        local mb = nil
                        pcall(function() mb = db:call("get_MotionBank") end)
                        local ord = -1
                        pcall(function() ord = db:call("get_Order") end)
                        imgui.text(string.format("  [%d] priority=%s order=%s motbank=%s",
                            di, tostring(pri), tostring(ord), tostring(mb)))
                    end
                end
            end)
        end
        imgui.tree_pop()
    end

    imgui.tree_pop()
end)

log.info("[" .. MOD .. "] v" .. VERSION .. " loaded successfully")
