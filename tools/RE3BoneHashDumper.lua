-- RE3BoneHashDumper.lua — Dumps all RE3 joint names, indices, and hashes
-- Deploy to: <RE3_game_dir>/reframework/autorun/
-- Output: reframework/data/re3_bone_hashes.txt
-- Purpose: map RE3 dump bone indices to actual bone names/hashes
--          so we can complete the RE3→RE2 bone mapping for the dodge animation

if reframework:get_game_name() ~= "re3" then return end

log.info("[RE3BoneHashDumper] Loading...")

local dump_done = false
local dump_triggered = false
local game_ready = false
local ready_time = 0

local function do_dump(motion, transform)
    local joint_count = motion:call("get_JointCount")
    if not joint_count or joint_count <= 0 then
        log.info("[RE3BoneHashDumper] No joints found")
        return
    end

    local lines = {}
    lines[#lines + 1] = "RE3 Bone Hash Dump"
    lines[#lines + 1] = "Joint count: " .. joint_count
    lines[#lines + 1] = "Format: INDEX|NAME|HASH_INT|HASH_HEX"
    lines[#lines + 1] = "---"

    local joints = transform:call("get_Joints")
    local elements = joints and joints:get_elements()

    for idx = 0, joint_count - 1 do
        local name = "?"
        local hash = 0

        if elements and elements[idx + 1] then
            local ok, n = pcall(function()
                return elements[idx + 1]:call("get_Name")
            end)
            if ok and n then name = n end
        end

        local ok2, h = pcall(function()
            return motion:call("getJointNameHashByIndex", idx)
        end)
        if ok2 and h then hash = h end

        lines[#lines + 1] = string.format("%d|%s|%u|0x%08x", idx, name, hash, hash)
    end

    lines[#lines + 1] = "---"
    lines[#lines + 1] = "TOTAL=" .. joint_count

    -- Try multiple output paths
    local out_paths = {
        "reframework/data/re3_bone_hashes.txt",
        "data/re3_bone_hashes.txt",
        "re3_bone_hashes.txt",
    }
    for _, filepath in ipairs(out_paths) do
        local ok, f = pcall(io.open, filepath, "w")
        if ok and f then
            f:write(table.concat(lines, "\n") .. "\n")
            f:close()
            log.info("[RE3BoneHashDumper] Wrote " .. #lines .. " lines to " .. filepath)
            dump_done = true
            return
        end
    end
    log.info("[RE3BoneHashDumper] Failed to write to any path!")
    -- Still mark done to avoid re-triggering
    dump_done = true
end

re.on_frame(function()
    if dump_done then return end

    -- RE3 player access: offline.PlayerManager with PlayerList
    local ok, player = pcall(function()
        local mgr = sdk.get_managed_singleton("offline.PlayerManager")
        if not mgr then return nil end
        -- Try get_CurrentPlayer first
        local pl = mgr:call("get_CurrentPlayer")
        if pl then return pl end
        -- Fallback: PlayerList field
        local list = mgr:get_field("PlayerList")
        if list then
            local count = list:call("get_Count")
            if count and count > 0 then
                return list:call("get_Item", 0)
            end
        end
        return nil
    end)
    if not ok or not player then
        game_ready = false
        return
    end

    if not game_ready then
        game_ready = true
        ready_time = os.clock()
        log.info("[RE3BoneHashDumper] Player found, waiting 5s...")
        return
    end

    if os.clock() - ready_time < 5.0 then return end
    if dump_triggered then return end
    dump_triggered = true

    log.info("[RE3BoneHashDumper] Dumping joints...")
    local ok2 = pcall(function()
        local transform = player:call("get_Transform")
        if not transform then
            log.info("[RE3BoneHashDumper] No transform on player")
            return
        end

        -- Find Motion component (may be on child)
        local motion = player:call("getComponent(System.Type)",
            sdk.typeof("via.motion.Motion"))
        if not motion then
            local child_count = transform:call("get_ChildCount")
            for i = 0, math.min(child_count - 1, 20) do
                local child_tf = transform:call("getChild", i)
                if child_tf then
                    local child_go = child_tf:call("get_GameObject")
                    if child_go then
                        local m = child_go:call("getComponent(System.Type)",
                            sdk.typeof("via.motion.Motion"))
                        if m then
                            motion = m
                            -- Use child's transform for joints
                            transform = child_tf
                            break
                        end
                    end
                end
            end
        end

        if motion and transform then
            do_dump(motion, transform)
        else
            log.info("[RE3BoneHashDumper] Motion or Transform not found")
        end
    end)

    if not ok2 then
        log.info("[RE3BoneHashDumper] Error during dump")
    end
end)

re.on_draw_ui(function()
    if imgui.tree_node("RE3 BoneHashDumper") then
        if dump_done then
            imgui.text("Dump complete! Check reframework/data/re3_bone_hashes.txt")
            imgui.text("(Also tried: data/ and game root)")
        elseif dump_triggered then
            imgui.text("Dumping...")
        elseif game_ready then
            local remaining = math.max(0, 5.0 - (os.clock() - ready_time))
            imgui.text(string.format("Waiting for init... (%.1fs)", remaining))
        else
            imgui.text("Waiting for player...")
        end
        imgui.tree_pop()
    end
end)

log.info("[RE3BoneHashDumper] Loaded")
