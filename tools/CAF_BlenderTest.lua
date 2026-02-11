-- CAF Layer Override Diagnostic Tool
-- Tests 3 approaches to overlay animation on RE2 player:
--   A) changeMotion on layer (DynamicMotionBank playback)
--   B) setLocalRotation on layer 1 (direct layer bone override)
--   C) Transform joint override in PrepareRendering (proven v1.x approach)
-- Standalone — does NOT require CAF_ModAPI.lua

local BANK_ID = 950
local MOTION_ID = 0
local PRIORITY = 200
local RESOURCE_PATH = "CAF_custom/test_headnod.motbank"

local log_tag = "[BlenderTest] "
local state = "init"
local resource = nil
local holder = nil
local dmb = nil
local motion_comp = nil
local player_ref = nil
local status_msg = "Initializing..."

-- Shared UI parameters
local test_layer = 1
local test_blend_mode = 1   -- 0=Overwrite 1=AddBlend 2=Private
local test_blend_rate = 1.0
local layer_obj = nil

-- Test A state
local test_a_playing = false

-- Test B state: layer setLocalRotation
local test_b_active = false
local test_b_angle = 0.0

-- Test C state: transform joint override (euler angle approach, from BoneControl.lua)
local test_c_active = false
local test_c_angle = 0.0
local joints_cache = nil
local head_joint_ref = nil   -- direct reference to the head joint (found by name)
local joint_names_log = false -- one-shot name logging
local test_c_verified = false -- one-shot read-after-write check

local function logmsg(msg)
    log.info(log_tag .. msg)
end

local function get_player()
    local ok, result = pcall(function()
        local pm = sdk.get_managed_singleton(sdk.game_namespace("PlayerManager"))
        if not pm then return nil end
        return pm:call("get_CurrentPlayer")
    end)
    return ok and result or nil
end

local function get_motion(player)
    if not player then return nil end
    local ok, mot = pcall(function()
        local go = player
        if go.get_GameObject then go = go:call("get_GameObject") end
        if not go then return nil end
        return go:call("getComponent(System.Type)", sdk.typeof("via.motion.Motion"))
    end)
    return ok and mot or nil
end

local function get_transform(player)
    if not player then return nil end
    local ok, xf = pcall(function()
        local go = player
        if go.get_GameObject then go = go:call("get_GameObject") end
        if not go then return nil end
        return go:call("get_Transform")
    end)
    return ok and xf or nil
end

local function stop_all()
    if test_a_playing and layer_obj then
        pcall(function()
            layer_obj:call("set_BlendRate", 0.0)
            layer_obj:call("changeMotion", 0, 0, 0.0, 0.0, 2, 0)
        end)
    end
    test_a_playing = false
    test_b_active = false
    test_c_active = false
    joints_cache = nil  -- clear so it re-caches next time
    head_joint_ref = nil
    joint_names_log = false
    test_c_verified = false
    logmsg("All tests stopped")
end

local function init_resource()
    logmsg("Creating resource: " .. RESOURCE_PATH)
    resource = sdk.create_resource("via.motion.MotionBankResource", RESOURCE_PATH)
    if not resource then
        status_msg = "ERROR: Failed to create resource"
        return false
    end
    resource = resource:add_ref()
    state = "loading"
    status_msg = "Loading resource..."
    return true
end

local function attach_dmb()
    local player = get_player()
    if not player then
        status_msg = "Waiting for player..."
        return false
    end
    player_ref = player
    local mot = get_motion(player)
    if not mot then
        status_msg = "Waiting for Motion component..."
        return false
    end
    motion_comp = mot

    local ok, err = pcall(function()
        holder = resource:create_holder("via.motion.MotionBankResourceHolder")
        if not holder then error("holder nil") end
        holder = holder:add_ref()
        dmb = sdk.create_instance("via.motion.DynamicMotionBank"):add_ref()
        dmb:call("set_MotionBank", holder)
        dmb:call("set_Priority", PRIORITY)
        local c = mot:call("getDynamicMotionBankCount")
        mot:call("setDynamicMotionBankCount", c + 1)
        mot:call("setDynamicMotionBank", c, dmb)
        state = "ready"
        status_msg = "Ready"
        logmsg("DMB attached at idx=" .. tostring(c))
    end)
    if not ok then
        status_msg = "ERROR: " .. tostring(err)
        logmsg("attach failed: " .. tostring(err))
    end
    return ok
end

-- on_frame: initialization + Test A blend maintenance + Test B layer rotation
re.on_frame(function()
    if state == "init" then pcall(init_resource); return end
    if state == "loading" then pcall(attach_dmb); return end

    -- Test A: maintain blend every frame
    if test_a_playing and layer_obj then
        local ok, err = pcall(function()
            layer_obj:call("set_BlendRate", test_blend_rate)
            layer_obj:call("set_BlendMode", test_blend_mode)
        end)
        if not ok then logmsg("A frame ERROR: " .. tostring(err)) end
    end

    -- Test B: setLocalRotation on layer 1 every frame
    if test_b_active and motion_comp then
        local ok, err = pcall(function()
            local lyr = motion_comp:call("getLayer", 1)
            if not lyr then logmsg("B: getLayer(1) nil"); return end
            lyr:call("set_BlendRate", test_blend_rate)
            lyr:call("set_BlendMode", test_blend_mode)
            -- Sine wave head nod: ~20 deg amplitude
            test_b_angle = test_b_angle + 0.05
            local nod = math.sin(test_b_angle) * 0.35
            local half = nod * 0.5
            -- Build nod quaternion (X-axis rotation)
            local qx = math.sin(half)
            local qw = math.cos(half)
            -- Try Quaternion.new first, fall back to reading existing
            local q = nil
            local ok1, err1 = pcall(function()
                q = Quaternion.new(qx, 0.0, 0.0, qw)
            end)
            if not ok1 then
                logmsg("B: Quaternion.new failed: " .. tostring(err1))
                -- Fallback: read existing and overwrite fields
                local ok2, err2 = pcall(function()
                    q = lyr:call("getLocalRotation", 5)
                    if q then
                        q.x = qx; q.y = 0.0; q.z = 0.0; q.w = qw
                    else
                        logmsg("B: getLocalRotation(5) nil")
                    end
                end)
                if not ok2 then logmsg("B: fallback ERROR: " .. tostring(err2)) end
            end
            if q then
                lyr:call("setLocalRotation", 5, q)
            else
                logmsg("B: quaternion nil, cannot set")
            end
        end)
        if not ok then logmsg("B frame ERROR: " .. tostring(err)) end
    end
end)

-- Test C: Transform joint override in PrepareRendering
-- Uses EXACT same approach as BoneControl.lua: euler angles, name-based joint search
re.on_application_entry("PrepareRendering", function()
    if not test_c_active then return end
    local ok, err = pcall(function()
        -- Get transform using BoneControl.lua's exact pattern
        local player = player_ref or get_player()
        if not player then return end
        local xf = nil
        pcall(function() xf = player:call("get_Transform") end)
        if not xf then
            pcall(function()
                local go = player:call("get_GameObject")
                if go then xf = go:call("get_Transform") end
            end)
        end
        if not xf then return end

        -- Build joint list by name (one-shot, same as BoneControl.lua)
        if not head_joint_ref then
            local jarr = xf:call("get_Joints")
            if not jarr then logmsg("C: get_Joints nil"); return end
            local elements = jarr:get_elements()
            if not elements then logmsg("C: get_elements nil"); return end
            logmsg("C: total joints: " .. tostring(#elements))

            -- Log first 20 joint names for debugging
            for i = 1, math.min(20, #elements) do
                local name = ""
                pcall(function() name = elements[i]:call("get_Name") end)
                logmsg(string.format("C: joint[%.0f] = %s", i, name))
            end

            -- Find head joint by name (same search as BoneControl.lua)
            for i, joint in pairs(elements) do
                if joint then
                    local name = ""
                    pcall(function() name = joint:call("get_Name") end)
                    if name and name:lower() == "head" then
                        head_joint_ref = joint
                        logmsg("C: found HEAD at index " .. tostring(i))
                        break
                    end
                end
            end

            if not head_joint_ref then
                logmsg("C: HEAD joint NOT FOUND! Searching for similar names...")
                for i, joint in pairs(elements) do
                    if joint then
                        local name = ""
                        pcall(function() name = joint:call("get_Name") end)
                        if name and name:lower():find("head") then
                            logmsg("C: found head-like: [" .. tostring(i) .. "] " .. name)
                        end
                    end
                end
                return
            end
        end

        -- Apply head sway using EULER ANGLES (BoneControl.lua pattern)
        local time = os.clock()
        local sway_x = math.sin(time * 2.0) * 15.0   -- 15 degrees amplitude, faster
        local sway_y = math.sin(time * 1.4) * 10.0   -- 10 degrees Y sway

        local cur = head_joint_ref:call("get_LocalEulerAngle")
        if not cur then logmsg("C: get_LocalEulerAngle nil"); return end

        -- Log before/after once for diagnostics
        if not joint_names_log then
            joint_names_log = true
            logmsg(string.format("C: BEFORE euler: %.2f %.2f %.2f", cur.x, cur.y, cur.z))
        end

        head_joint_ref:call("set_LocalEulerAngle", Vector3f.new(
            cur.x + sway_x,
            cur.y + sway_y,
            cur.z
        ))

        -- Read-after-write verification (one-shot)
        if joint_names_log and not test_c_verified then
            test_c_verified = true
            local after = head_joint_ref:call("get_LocalEulerAngle")
            if after then
                logmsg(string.format("C: AFTER euler: %.2f %.2f %.2f (expected X+%.1f Y+%.1f)",
                    after.x, after.y, after.z, sway_x, sway_y))
            end
        end
    end)
    if not ok then logmsg("C ERROR: " .. tostring(err)) end
end)

-- ImGui UI
re.on_draw_ui(function()
    if imgui.tree_node("CAF Layer Override Test") then
        imgui.text("State: " .. state)
        imgui.text(status_msg)
        imgui.spacing()

        if state ~= "ready" and not test_a_playing and not test_b_active and not test_c_active then
            imgui.tree_pop()
            return
        end

        -- Shared params
        local _c1; _c1, test_layer = imgui.slider_int("Layer", test_layer, 0, 3)
        local _c2; _c2, test_blend_mode = imgui.slider_int("BlendMode (0=Over 1=Add 2=Priv)", test_blend_mode, 0, 2)
        local _c3; _c3, test_blend_rate = imgui.slider_float("BlendRate", test_blend_rate, 0.0, 1.0)

        -- ===== TEST A =====
        imgui.spacing(); imgui.separator()
        imgui.text("TEST A: changeMotion (DynamicMotionBank)")
        if imgui.button("A: PLAY layer " .. tostring(test_layer)) then
            stop_all()
            local ok, err = pcall(function()
                layer_obj = motion_comp:call("getLayer", test_layer)
                if not layer_obj then error("getLayer nil") end
                layer_obj:call("set_BlendRate", test_blend_rate)
                layer_obj:call("set_BlendMode", test_blend_mode)
                layer_obj:call("changeMotion", BANK_ID, MOTION_ID, 0.0, 0.0, 2, 0)
                layer_obj:call("set_Frame", 0.0)
                layer_obj:call("set_Speed", 1.0)
                test_a_playing = true
            end)
            status_msg = ok and string.format("A: Playing bank %d layer %d", BANK_ID, test_layer)
                or ("A ERROR: " .. tostring(err))
            logmsg(status_msg)
        end
        imgui.same_line()
        if imgui.button("A: STOP") then stop_all(); status_msg = "Stopped" end

        -- ===== TEST B =====
        imgui.spacing(); imgui.separator()
        imgui.text("TEST B: setLocalRotation on Layer 1")
        if imgui.button("B: START nod") then
            stop_all()
            test_b_active = true; test_b_angle = 0.0
            status_msg = "B: Layer setLocalRotation active"
            logmsg("Test B started")
        end
        imgui.same_line()
        if imgui.button("B: STOP") then stop_all(); status_msg = "Stopped" end

        -- ===== TEST C =====
        imgui.spacing(); imgui.separator()
        imgui.text("TEST C: Transform joint override (PrepareRendering)")
        if imgui.button("C: START nod") then
            stop_all()
            test_c_active = true; test_c_angle = 0.0
            status_msg = "C: Transform override active"
            logmsg("Test C started")
        end
        imgui.same_line()
        if imgui.button("C: STOP") then stop_all(); status_msg = "Stopped" end

        -- ===== STOP ALL =====
        imgui.spacing()
        if imgui.button("STOP ALL") then stop_all(); status_msg = "All stopped" end

        -- ===== DIAGNOSTICS =====
        imgui.spacing(); imgui.separator()
        imgui.text("--- DIAGNOSTICS ---")

        -- Layer state for layers 0-2
        if motion_comp then
            pcall(function()
                for li = 0, 2 do
                    local lyr = motion_comp:call("getLayer", li)
                    if lyr then
                        local blend = lyr:call("get_BlendRate") or -1
                        local bmode = lyr:call("get_BlendMode") or -1
                        local frame = lyr:call("get_Frame") or 0
                        local end_frame = lyr:call("get_EndFrame") or 0
                        local bank = lyr:call("get_MotionBankID") or -1
                        local mot_id = lyr:call("get_MotionID") or -1
                        local base_no, mask_id, anim_jc = -1, -1, -1
                        pcall(function() base_no = lyr:call("get_BaseLayerNo") or -1 end)
                        pcall(function() mask_id = lyr:call("get_ActiveJointMaskID") or -1 end)
                        pcall(function() anim_jc = lyr:call("get_AnimatedJointCount") or -1 end)
                        imgui.text(string.format(
                            "L%d: Rate=%.2f Mode=%.0f Bank=%.0f Mot=%.0f F=%.0f/%.0f",
                            li, blend, bmode, bank, mot_id, frame, end_frame))
                        imgui.text(string.format(
                            "    BaseLayer=%.0f MaskID=%.0f AnimJoints=%.0f",
                            base_no, mask_id, anim_jc))
                    end
                end
            end)

            -- Joint blend rates
            pcall(function()
                local jb = motion_comp:call("getJointBlendRate", 5)
                if jb then
                    imgui.text(string.format("Motion JBlend head(5): %.2f %.2f %.2f",
                        jb.x or 0, jb.y or 0, jb.z or 0))
                end
            end)
            pcall(function()
                local lyr1 = motion_comp:call("getLayer", 1)
                if lyr1 then
                    local ljb = lyr1:call("getJointBlendRate", 5)
                    if ljb then
                        imgui.text(string.format("L1 JBlend head(5): %.2f %.2f %.2f",
                            ljb.x or 0, ljb.y or 0, ljb.z or 0))
                    end
                    local lr = lyr1:call("getLocalRotation", 5)
                    if lr then
                        imgui.text(string.format("L1 LocalRot head(5): %.4f %.4f %.4f %.4f",
                            lr.x or 0, lr.y or 0, lr.z or 0, lr.w or 0))
                    end
                end
            end)

            -- Motion info
            pcall(function()
                local lc = motion_comp:call("getLayerCount") or 0
                local jc = motion_comp:call("getJointCount") or 0
                imgui.text(string.format("Motion: Layers=%d Joints=%d", lc, jc))
            end)
        end

        -- Joint blend controls
        imgui.spacing(); imgui.separator()
        imgui.text("Joint Blend Controls:")
        if imgui.button("Motion ALL XYZ=1") then
            pcall(function()
                local v = Vector3f.new(1.0, 1.0, 1.0)
                for i = 0, 79 do motion_comp:call("setJointBlendRate", i, v) end
                logmsg("Motion setJointBlendRate ALL XYZ=1")
            end)
        end
        imgui.same_line()
        if imgui.button("L1 ALL XYZ=1") then
            pcall(function()
                local lyr1 = motion_comp:call("getLayer", 1)
                if lyr1 then
                    local v = Vector3f.new(1.0, 1.0, 1.0)
                    for i = 0, 79 do lyr1:call("setJointBlendRate", i, v) end
                    logmsg("Layer1 setJointBlendRate ALL XYZ=1")
                end
            end)
        end
        imgui.same_line()
        if imgui.button("Reset JBlend=0") then
            pcall(function()
                local v = Vector3f.new(0.0, 0.0, 0.0)
                for i = 0, 79 do motion_comp:call("setJointBlendRate", i, v) end
                pcall(function()
                    local lyr1 = motion_comp:call("getLayer", 1)
                    if lyr1 then
                        for i = 0, 79 do lyr1:call("setJointBlendRate", i, v) end
                    end
                end)
                logmsg("Reset ALL JointBlendRate=0")
            end)
        end

        imgui.tree_pop()
    end
end)

logmsg("Script loaded — 3-way layer override test")
