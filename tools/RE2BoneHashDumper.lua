-- RE2BoneHashDumper.lua — Dumps all RE2 joint names, indices, and hashes
-- Deploy to: <RE2_game_dir>/reframework/autorun/
-- Output: reframework/data/re2_bone_hashes.txt
-- Purpose: identify "???" bones in the bone_index_mapping.json

if reframework:get_game_name() ~= "re2" then return end

local dump_done = false
local dump_triggered = false
local game_ready = false
local ready_time = 0

local function do_dump(motion, transform)
    local joint_count = motion:call("get_JointCount")
    if not joint_count or joint_count <= 0 then
        log.info("[BoneHashDumper] No joints found")
        return
    end

    local lines = {}
    lines[#lines + 1] = "RE2 Bone Hash Dump"
    lines[#lines + 1] = "Joint count: " .. joint_count
    lines[#lines + 1] = "Format: INDEX|NAME|HASH_INT|HASH_HEX"
    lines[#lines + 1] = "---"

    local joints = transform:call("get_Joints")
    local elements = joints and joints:get_elements()

    for idx = 0, joint_count - 1 do
        local name = "?"
        local hash = 0

        -- Get name from Joint object
        if elements and elements[idx + 1] then
            local ok, n = pcall(function()
                return elements[idx + 1]:call("get_Name")
            end)
            if ok and n then name = n end
        end

        -- Get hash from Motion
        local ok2, h = pcall(function()
            return motion:call("getJointNameHashByIndex", idx)
        end)
        if ok2 and h then hash = h end

        lines[#lines + 1] = string.format("%d|%s|%u|0x%08x", idx, name, hash, hash)
    end

    lines[#lines + 1] = "---"
    lines[#lines + 1] = "TOTAL=" .. joint_count

    -- Write to file
    local filepath = "reframework/data/re2_bone_hashes.txt"
    local f = io.open(filepath, "w")
    if f then
        f:write(table.concat(lines, "\n") .. "\n")
        f:close()
        log.info("[BoneHashDumper] Wrote " .. #lines .. " lines to " .. filepath)
    else
        log.info("[BoneHashDumper] Failed to write to " .. filepath)
    end

    dump_done = true
end

re.on_frame(function()
    if dump_done then return end

    local ok, player = pcall(function()
        local mgr = sdk.get_managed_singleton(sdk.game_namespace("PlayerManager"))
        if not mgr then return nil end
        return mgr:call("get_CurrentPlayer")
    end)
    if not ok or not player then
        game_ready = false
        return
    end

    if not game_ready then
        game_ready = true
        ready_time = os.clock()
        return
    end

    if os.clock() - ready_time < 5.0 then return end
    if dump_triggered then return end
    dump_triggered = true

    local ok2 = pcall(function()
        local motion = player:call("getComponent(System.Type)",
            sdk.typeof("via.motion.Motion"))
        local transform = player:call("get_Transform")

        if not motion then
            -- Search children
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
                            break
                        end
                    end
                end
            end
        end

        if motion and transform then
            do_dump(motion, transform)
        else
            log.info("[BoneHashDumper] Motion or Transform not found")
        end
    end)

    if not ok2 then
        log.info("[BoneHashDumper] Error during dump")
    end
end)

re.on_draw_ui(function()
    if imgui.tree_node("BoneHashDumper") then
        if dump_done then
            imgui.text("Dump complete! Check reframework/data/re2_bone_hashes.txt")
        elseif dump_triggered then
            imgui.text("Dumping...")
        elseif game_ready then
            imgui.text("Waiting for init delay...")
        else
            imgui.text("Waiting for player...")
        end
        imgui.tree_pop()
    end
end)
