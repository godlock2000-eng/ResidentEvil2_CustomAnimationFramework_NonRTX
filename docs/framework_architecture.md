# Custom Animation Framework — Architecture

## Approach: Runtime Bone Override

After analyzing 30+ binary conversion attempts (all failed), and confirming BoneControl's
`PrepareRendering` bone overrides work visually, the v1 approach is:

1. Parse the RE3 dodge dump (120 frames × 80 bones × position + quaternion)
2. At runtime, resolve bone hashes to RE2 joint indices via `Motion:getJointIndexByNameHash()`
3. On V key press, start the dodge state machine
4. Each `PrepareRendering` callback: SET bone local rotations/positions from the dump data
5. Blend in/out at animation boundaries

## Data Flow

```
dodge_dump.txt ──parse──> frame_data[120][80]{pos,quat}
                              │
bone_index_mapping ──────> bone_map[re3_idx] = {hash, re2_joint_idx, joint_obj}
                              │
V key press ─────────────> dodge_state = "active", frame_timer starts
                              │
PrepareRendering ─────────> for each mapped bone:
                              joint:set_LocalRotation(frame_data[frame][bone_idx].quat)
                              joint:set_LocalPosition(frame_data[frame][bone_idx].pos)
```

## Bone Mapping Status

- 31 of 80 RE3 bones have hash mappings to RE2 (via bone_index_mapping.json)
- Includes: root, Null_Offset, COG, hips, spine_0, spine_1, spine_2 + 24 hash-only bones
- 91 total shared hashes identified in bone_mapping.json
- At runtime, hashes are resolved to RE2 joint indices via `getJointIndexByNameHash()`

## Timing

```
re.on_frame()                    → Input detection, dodge state machine, frame advancement
PrepareRendering                 → Apply bone transforms (AFTER animation eval, BEFORE render)
re.on_draw_ui()                  → ImGui debug panel
```

## Dodge State Machine

```
IDLE ──(V key + cooldown ready)──> BLEND_IN ──(blend done)──> ACTIVE
  ^                                                              │
  └──────────────(frame >= total)──── BLEND_OUT ────────────────┘
```

## File Deployment

Copy `framework/reframework/` to `<game_root>/reframework/`:
- `autorun/CustomAnimFramework.lua` — main script
- `data/CustomAnimFramework/dodge_dump.txt` — RE3 dodge frame data
