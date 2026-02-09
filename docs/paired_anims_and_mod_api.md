# Paired/Synchronized Multi-Actor Animations and Mod API Research

**Source**: RE2 `il2cpp_dump.json`, existing mod examples, framework architecture docs
**Date**: 2026-02-08

---

## Table of Contents

### Part 1: Paired Animations
1. [How RE2 Handles Existing Paired Animations](#1-how-re2-handles-existing-paired-animations)
2. [All Relevant Types/Classes Found in IL2CPP Dump](#2-all-relevant-typesclasses-found-in-il2cpp-dump)
3. [Position Synchronization Techniques](#3-position-synchronization-techniques)
4. [Proposed Architecture for Multi-Actor Animation Playback](#4-proposed-architecture-for-multi-actor-animation-playback)
5. [Handling Interruptions, Death, Distance Limits](#5-handling-interruptions-death-distance-limits)
6. [Skeleton Compatibility Issues and Solutions](#6-skeleton-compatibility-issues-and-solutions)

### Part 2: Mod API
7. [REFramework Mod-to-Mod Communication Patterns](#7-reframework-mod-to-mod-communication-patterns)
8. [Proposed API Surface](#8-proposed-api-surface)
9. [Event System Design](#9-event-system-design)
10. [Example Usage Scenarios](#10-example-usage-scenarios)
11. [Thread Safety and Execution Order](#11-thread-safety-and-execution-order)
12. [Versioning and Backwards Compatibility](#12-versioning-and-backwards-compatibility)

---

# Part 1: Paired Animations

## 1. How RE2 Handles Existing Paired Animations

### 1.1 The Grapple System

RE2's primary paired animation system is the **grapple** system, used when enemies grab the player. The key classes are:

**`app.ropeway.EnemyGrappleUserData`** (inherits `app.ropeway.AttackUserDataToPlayer`)
- Inherits `app.ropeway.AttackUserDataToPlayer`
- This is the data class that defines a grapple attack from an enemy to a player
- Contains a `GrapplePriority` field (type `app.ropeway.grapple.GrapplePriority`) at offset `0x7c`
- Also has standard attack parameters: `HitGroup`, `AttackSortType`, `AttackType`, `Damage`, `JointName`, `AttackDirType`, `OffsetAttackDir`
- The `JointName` field (at offset `0x50`) specifies which joint on the enemy is the point of contact during the grapple
- Method `get_IsGrapple()` returns `true` always (vtable index 4), confirming this as the grapple type marker

**`app.ropeway.grapple.GrapplePriority`** (enum, inherits `System.Enum`)
- Enum type with 9 priority levels
- Defines 9 priority levels: `Priority_00` through `Priority_07` and `Invalid` (value 8)
- This priority system determines which grapple takes precedence when multiple enemies try to grab the player simultaneously
- Priority 0 is highest, Priority 7 is lowest, and Invalid disables the grapple

**How a grapple works in the game flow:**
1. An enemy's behavior tree triggers a grapple action (via `BehaviorTreeAction`)
2. The grapple collision triggers using `EnemyGrappleUserData` attack data
3. The grapple priority system resolves conflicts if multiple enemies try to grapple
4. Both the enemy and player enter synchronized animation states
5. The player can use a sub-weapon (knife) to counter during the grapple
6. The `IsKnifeAction` property tracks knife counter-kill animations

### 1.2 The ParentMotionSynchronizer System

This is the most directly relevant system for paired animations:

**`app.ropeway.ParentMotionSynchronizer`**
- Inherits from a base component (behavior/monobehaviour pattern)
- **This is RE2's native motion synchronization component** that keeps a child actor's animation in sync with a parent actor

Key fields:
| Field | Type | Offset | Purpose |
|-------|------|--------|---------|
| `_MotionSyncInterpolateFrame` | `System.Single` | `0x14` | Interpolation frame count when syncing to parent motion |
| `_MotionClearInterpolateFrame` | `System.Single` | `0x18` | Interpolation frame count when clearing sync |
| `_SyncLayerID` | `System.UInt32` | `0x1c` | Which motion layer to sync |
| `_TargetLayerNo` | `System.UInt32` | `0x20` | The layer number on the target (parent) to read from |
| `_ConstMotionEnd` | `System.Boolean` | `0x24` | Whether the synced motion is constrained to end at a specific frame |
| `_DefaultMotionInfo` | `MotionInfo` | `0x28` | Default BankID + MotionID to play |
| `_PlayMotionInfo` | `MotionInfo` | `0x30` | Currently playing BankID + MotionID |
| `_TargetBankType` | `Nullable<UInt32>` | `0x38` | Optional bank type filter for the target |
| `_Mode` | `PlayMode` | `0x4` | Synchronize (0) or Overwrite (1) |

Backing fields (runtime state):
| Field | Type | Purpose |
|-------|------|---------|
| `<SyncTarget>k__BackingField` | `via.GameObject` | The parent GameObject being synced to |
| `<Motion>k__BackingField` | `via.motion.Motion` | This actor's Motion component |
| `<SyncTargetMotion>k__BackingField` | `via.motion.Motion` | The parent actor's Motion component |
| `<SyncTargetMotionEventHandler>k__BackingField` | `MotionEventHandler` | Event handler for the parent's motion events |
| `<ChangedSyncTarget>k__BackingField` | `System.Boolean` | Whether the sync target changed this frame |
| `<CheckSyncFrame>k__BackingField` | `System.Boolean` | Whether to check frame sync |

Key methods:
| Method | Parameters | Purpose |
|--------|-----------|---------|
| `getSyncMotionInfo(out bankID, out motionID, out frame)` | Out params | Gets the current bank, motion, and frame from the sync target |
| `getSrcMotionLayer()` | None | Gets the source (parent) motion layer |
| `getDstMotionLayer()` | None | Gets the destination (this) motion layer |
| `clearMotion()` | None | Clears the synced motion |
| `TransitionEvent(LayerNo, TransitionState)` | layer, state | Handles motion transition events |
| `LayerUpdatedEvent(srcMotion, srcLayer)` | motion, layer | Handles layer update callbacks |

**`ParentMotionSynchronizer.PlayMode`** (enum):
- `Synchronize` (0): The child reads the parent's current bankID/motionID/frame and plays the same motion on its own layer
- `Overwrite` (1): The child plays a different specific motion (`_PlayMotionInfo`) but keeps its frame position synchronized with the parent

**`ParentMotionSynchronizer.MotionInfo`**:
- Simple data class with `BankID` (UInt32) and `MotionID` (UInt32)
- Used by `_DefaultMotionInfo` and `_PlayMotionInfo` to specify which animation to play

### 1.3 The MotionSyncPoint System

**`via.motion.MotionSyncPoint`** (inherits `via.motion.MotionTracks`)
- Inherits `via.motion.MotionTracks`
- A track-level component that defines synchronization points within a motion
- Has a `Point` property (Int32, get/set) that marks a specific frame as a sync point
- This allows animations to declare "sync frames" where multiple actors must align
- Inheritance chain: `via.Object` > `System.Object` > `via.motion.Tracks` > `via.motion.MotionTracks` > `via.motion.MotionSyncPoint`

### 1.4 IK Damage Action System

The engine uses IK-based damage actions for procedural hit reactions that sync with attackers:

**`via.motion.IkDamageAction`** (inherits `via.motion.SecondaryAnimation`)
- Inherits `via.motion.SecondaryAnimation`
- A secondary animation component that procedurally adjusts bones based on damage direction
- Key properties: `BlendRate`, `BendRate`, `DamageTransitionState`, `CalcuCenterOffsetState`
- Has `getMatchPatternIndex(joint_index, tag_id)` for pattern matching against hit zones
- This is how the game makes zombies react to being shot (head snaps back, body flinches)

**`via.motion.IkMultipleDamageAction`** (inherits from IkDamageAction pattern)
- Extends IkDamageAction for multiple sources
- Extended version that can handle multiple simultaneous damage sources
- Same sub-types: `CalcuCenterOffset`, `Calculation`, `CalculationAddRotation`, `CalculationBendRotation`, `DamageTransition`, `DebugDamageTransition`

### 1.5 Mr. X (Em7000) Grapple System

Mr. X has a specialized grapple system with back-grapple support:

**`app.ropeway.enemy.em7000.Em7000Think.BackGrappleType`** (enum)
- Defines different types of back-grapples (grab from behind)

**`app.ropeway.enemy.em7000.Em7000ExclusionBackGrappleZoneElement`**
- Defines zones where back-grapples cannot occur (exclusion zones)
- Multiple zone elements can be configured as an array
- This indicates that the grapple system uses spatial awareness to determine grab angles

### 1.6 Finish Attack / FinishAction System

**`FinishAction`** (abstract base class)
- Found in the il2cpp dump with fields:
  - `FinishAction` (type `System.Action`) at offset `0x10` -- a callback delegate
  - `Priority` (type `System.Int32`) at offset `0x0`
- Abstract methods: `hasAccident()`, `isExist()`, `isReady()`, `isSameEntity(entity)`
- Instance methods: `cancelRelease()`, `get_ReleaseReserved()`
- This is the base class for execution/finishing animations, used when the player delivers a killing blow that triggers a special synchronized animation

### 1.7 Timeline System

RE2 uses a timeline system for cutscene-like synchronized sequences:

**`app.ropeway.survivor.player.PlayerTimelineController`**
- Controls player participation in timeline sequences
- Has `RainTimelineSetting` and `RainTimelineParameter` sub-types

**`app.ropeway.timeline.action.MotionEventAction`**
- Timeline actions that trigger motion events
- Associated with `MotionEventKind` enum

### 1.8 MotionEventHandler

**`app.ropeway.motion.MotionEventHandler`**
- Has `Container` and `ExecuteLayer` sub-types
- Has `LayerKind` enum
- This is the callback system that fires when motion events occur (e.g., footstep sounds, collision enable/disable windows, sync points)

---

## 2. All Relevant Types/Classes Found in IL2CPP Dump

### 2.1 Grapple/Paired Animation Types

| Full Type Name | Category | Purpose |
|----------------|----------|---------|
| `app.ropeway.EnemyGrappleUserData` | Grapple | Enemy grapple attack definition |
| `app.ropeway.grapple.GrapplePriority` | Grapple | Priority enum (0-7 + Invalid) |
| `app.ropeway.AttackUserDataToPlayer` | Grapple | Base class for grapple data |
| `app.ropeway.enemy.em7000.Em7000Think.BackGrappleType` | Grapple | Mr. X back-grapple types |
| `app.ropeway.enemy.em7000.Em7000ExclusionBackGrappleZoneElement` | Grapple | Grapple exclusion zones |

### 2.2 Motion Synchronization Types

| Full Type Name | Category | Purpose |
|----------------|----------|---------|
| `app.ropeway.ParentMotionSynchronizer` | Sync | **Core synchronization component** |
| `app.ropeway.ParentMotionSynchronizer.MotionInfo` | Sync | Bank/Motion ID pair |
| `app.ropeway.ParentMotionSynchronizer.PlayMode` | Sync | Synchronize vs Overwrite enum |
| `via.motion.MotionSyncPoint` | Sync | Track-level sync point marker |

### 2.3 Motion/Animation System Types

| Full Type Name | Category | Purpose |
|----------------|----------|---------|
| `via.motion.Motion` | Animation | Core animation component |
| `via.motion.MotionFsm2` | Animation | FSM-based animation (used by characters) |
| `via.motion.TreeLayer` | Animation | Individual animation layer |
| `via.motion.DynamicMotionBank` | Animation | Runtime-loadable motion bank |
| `via.motion.MotionBank` | Animation | Static motion bank |
| `via.motion.MotionBankResourceHolder` | Animation | Resource wrapper for .motbank |
| `via.motion.MotionInfo` | Animation | Motion metadata container |
| `via.motion.MotionNodeCtrl` | Animation | Motion node controller |
| `via.motion.MotionFsmLayer` | Animation | FSM layer |
| `via.motion.MotionFsm2Layer` | Animation | FSM2 layer |
| `via.motion.MotionFrameControl` | Animation | Frame control |
| `via.motion.MotionManager.CallUpdate` | Animation | Update callback type |

### 2.4 Damage/IK Types

| Full Type Name | Category | Purpose |
|----------------|----------|---------|
| `via.motion.IkDamageAction` | IK/Damage | Procedural damage response |
| `via.motion.IkMultipleDamageAction` | IK/Damage | Multi-source damage |
| `via.motion.IkDamageAction.Calculation` | IK/Damage | IK calculation state |
| `via.motion.IkDamageAction.CalculationAddRotation` | IK/Damage | Additional rotation calc |
| `via.motion.IkDamageAction.CalculationBendRotation` | IK/Damage | Bend rotation calc |
| `via.motion.IkDamageAction.DamageTransition` | IK/Damage | Damage transition state |
| `via.motion.IkDamageAction.CalcuCenterOffset` | IK/Damage | Center offset calculation |

### 2.5 Action System / Behavior Tree Types

| Full Type Name | Category | Purpose |
|----------------|----------|---------|
| `app.ropeway.EnemyController` | Controller | Enemy controller with hate, sensor, think, etc. |
| `app.ropeway.EnemyActionProperty` | Action | Per-action enemy properties |
| `app.ropeway.EnemyHateController` | AI | Manages enemy aggro/hate |
| `app.ropeway.survivor.player.PlayerController` | Controller | Player controller |
| `via.behaviortree.BehaviorTree` | AI | Behavior tree component |
| `app.ropeway.BehaviorTreeCategory` | AI | BT category enum |
| `app.ropeway.BehaviorTreeActionCategory` | AI | BT action category |
| `app.ropeway.behaviortree.BehaviorTreeDefine.CheckType` | AI | BT check type |
| `app.ropeway.behaviortree.BehaviorTreeDefine.CompareType` | AI | BT compare type |

### 2.6 Enemy-Specific Action Types

| Full Type Name | Category |
|----------------|----------|
| `app.ropeway.enemy.em0000.ActionStatus.ID` | Zombie actions |
| `app.ropeway.enemy.em3000.ActionStatus.ID` | Licker actions |
| `app.ropeway.enemy.em4400.BehaviorTreeAction.ID` | Enemy BT actions |
| `app.ropeway.enemy.em5000.BehaviorTreeAction.ID` | Enemy BT actions |
| `app.ropeway.enemy.em6000.BehaviorTreeAction.ID` | Enemy BT actions |
| `app.ropeway.enemy.em6200.BehaviorTreeAction.ID` | Enemy BT actions |
| `app.ropeway.enemy.em6300.BehaviorTreeAction.ID` | Enemy BT actions |
| `app.ropeway.enemy.em7100.BehaviorTreeAction.ID` | Enemy BT actions |

### 2.7 Timeline/Event Types

| Full Type Name | Category | Purpose |
|----------------|----------|---------|
| `app.ropeway.timeline.action.MotionEventAction` | Timeline | Motion event in timeline |
| `app.ropeway.timeline.action.MotionEventKind` | Timeline | Event kind enum |
| `app.ropeway.motion.MotionEventHandler` | Events | Motion event callbacks |
| `app.ropeway.motion.MotionEventHandler.Container` | Events | Event container |
| `app.ropeway.motion.MotionEventHandler.ExecuteLayer` | Events | Per-layer execution |
| `app.ropeway.motion.MotionEventHandler.LayerKind` | Events | Layer kind enum |
| `app.ropeway.enemy.tracks.EnemyActionCameraSwitchTrack` | Camera | Camera switching during actions |

---

## 3. Position Synchronization Techniques

### 3.1 How RE2 Synchronizes Positions Natively

Based on the `ParentMotionSynchronizer` analysis, RE2 uses a **parent-child model**:

1. **One actor is designated as the "parent"** (e.g., the enemy during a grapple)
2. **The other actor is the "child"** and has a `ParentMotionSynchronizer` component
3. The synchronizer reads the parent's current motion state via `getSyncMotionInfo()` (bankID, motionID, frame)
4. It then plays the corresponding motion on the child at the same frame
5. The `_SyncLayerID` determines which layer is synced
6. `_MotionSyncInterpolateFrame` controls how smoothly the child transitions into the synced motion

Position alignment is handled separately through:
- **Warp/teleport**: `CharacterController.warp()` and `requestWarp()` methods snap actors to target positions
- **WarpPosition** fields on enemy context data (found at multiple offsets in Em7000 and others)
- **Root motion**: The synced animations include root motion data that moves both actors along compatible paths
- **Transform parenting**: During grapples, the child actor's transform may be temporarily parented to the grapple joint

### 3.2 Proposed Approach for Custom Paired Animations

For our mod framework, we should implement a **Lua-level synchronization coordinator** since we cannot easily create native `ParentMotionSynchronizer` components at runtime. The approach:

**Step 1: Pre-alignment**
```
Before animation starts:
  1. Calculate relative offset between actors using actor transforms
  2. Determine the "anchor point" (usually the primary actor's position)
  3. Warp secondary actors to their designated start positions relative to the anchor
  4. Use CharacterController.warp() to update physics/navigation state
```

**Step 2: Frame-locked playback**
```
Each frame during animation:
  1. Read the primary actor's TreeLayer.Frame
  2. For each secondary actor, call TreeLayer.setSolverFrame(0, primaryFrame)
  3. Or use TreeLayer.setOverwriteFrame(primaryFrame) for hard sync
  4. Apply any per-frame position corrections for root motion drift
```

**Step 3: Position correction**
```
Every N frames (configurable):
  1. Read primary actor's root joint world position
  2. For each secondary actor, calculate expected position from animation data
  3. Apply Transform.set_Position() corrections if drift exceeds threshold
  4. Use smooth interpolation to avoid visual pops
```

### 3.3 Root Motion Handling

Two strategies for root motion during paired animations:

**Strategy A: Root-Motion-Disabled** (simpler)
- Set `Motion.ApplyRootOnly = false` on both actors during paired animation
- Manually position both actors each frame from Lua
- Avoids drift entirely but requires pre-computed position data per frame

**Strategy B: Root-Motion-Sync** (more natural)
- Let the primary actor use root motion normally
- Track the primary's root motion delta each frame
- Apply the *inverse transformation* to maintain the relative offset for secondary actors
- More complex but produces more natural results

### 3.4 Rotation Alignment

For paired animations, both actors must face each other correctly:

1. **Calculate facing quaternion**: `makeLookAtLH(actorA.pos, actorB.pos, up)` (available in `via.matrix`)
2. **Apply initial rotation**: Set both actors' Transform.Rotation before animation starts
3. **Lock rotation during animation**: Override any rotation changes from AI/physics each frame
4. **Restore rotation after**: Return actors to their pre-animation facing directions

---

## 4. Proposed Architecture for Multi-Actor Animation Playback

### 4.1 Core Data Structures

```lua
-- A paired animation definition
PairedAnimDef = {
    id = "zombie_grab_front",        -- Unique identifier
    actor_count = 2,                  -- Number of actors (up to 6)
    actors = {
        [1] = {                       -- Primary actor (the "anchor")
            role = "attacker",
            bank_id = 0,
            motion_id = 42,
            layer = 0,               -- Which motion layer to use
            start_frame = 0,
            inter_frame = 5.0,       -- Interpolation frames
        },
        [2] = {                       -- Secondary actor
            role = "victim",
            bank_id = 0,
            motion_id = 43,          -- Corresponding victim animation
            layer = 0,
            start_frame = 0,
            inter_frame = 5.0,
            offset = {x=0, y=0, z=1.2},  -- Offset from primary at start
            facing = "toward_primary",     -- Auto-face toward primary
        },
        -- ... up to [6]
    },
    duration_frames = 90,            -- Total animation duration
    sync_mode = "frame_locked",      -- "frame_locked" or "event_synced"
    allow_interruption = true,       -- Can be interrupted
    interruption_window = {30, 60},  -- Frames where interruption is allowed
    on_complete = nil,               -- Callback function
    on_interrupted = nil,            -- Callback function
}
```

### 4.2 Synchronization Controller

```lua
-- Runtime state for an active paired animation
PairedAnimSession = {
    def = PairedAnimDef,             -- Reference to definition
    state = "idle",                  -- "idle", "aligning", "playing", "blend_out", "complete"
    actors = {                       -- Runtime actor data
        [1] = {
            game_object = nil,       -- via.GameObject reference
            motion = nil,            -- via.motion.Motion component
            layer = nil,             -- via.motion.TreeLayer reference
            controller = nil,        -- EnemyController or PlayerController
            char_controller = nil,   -- CharacterController (for warp)
            original_position = nil, -- Position before paired anim
            original_rotation = nil, -- Rotation before paired anim
            target_position = nil,   -- Where they should be
        },
        -- ... per actor
    },
    current_frame = 0,
    start_time = 0,                  -- os.clock() when started
    primary_idx = 1,                 -- Which actor is the anchor
}
```

### 4.3 Update Loop (per PrepareRendering)

```
function PairedAnimSession:update()
    if self.state == "aligning" then
        -- Move actors toward their start positions
        -- When all actors are within threshold, transition to "playing"
        for i, actor in ipairs(self.actors) do
            local dist = (actor.game_object.Transform.Position - actor.target_position):length()
            if dist > 0.05 then
                -- Interpolate position toward target
                -- Use CharacterController warp if distance is large
            end
        end
        if all_aligned then self.state = "playing" end

    elseif self.state == "playing" then
        -- Read primary actor's current frame
        local primary_frame = self.actors[self.primary_idx].layer:get_Frame()
        self.current_frame = primary_frame

        -- Sync all secondary actors to primary frame
        for i, actor in ipairs(self.actors) do
            if i ~= self.primary_idx then
                actor.layer:setOverwriteFrame(primary_frame)
                -- Or: actor.layer:setSolverFrame(0, primary_frame)
            end
        end

        -- Check for end of animation
        if primary_frame >= self.def.duration_frames then
            self.state = "blend_out"
        end

    elseif self.state == "blend_out" then
        -- Release control back to the game's animation system
        -- Restore original positions/rotations if needed
        self.state = "complete"
    end
end
```

### 4.4 Supporting Up to 6 Actors

The architecture naturally scales to 6 actors because:

1. **Array-based actor list**: Each session has an indexed array of actor slots
2. **One primary anchor**: Actor [1] is always the frame reference; all others sync to it
3. **Independent offsets**: Each secondary actor has its own offset vector from the primary
4. **Layer isolation**: Each actor uses its own motion layer, so there are no conflicts
5. **Per-actor interruption**: Individual actors can be removed from the session if interrupted

Practical scenarios for 6 actors:
- **3-way grab**: Player grabbed by zombie, with a second zombie joining (3 actors)
- **Group execution**: Player executes multiple downed enemies in sequence
- **Cutscene-like events**: Up to 6 characters perform a coordinated action
- **Boss fights**: Boss + multiple limb/appendage actors synchronized

### 4.5 Integration with Existing Framework

Based on the existing `framework_architecture.md`, the paired animation system should integrate with the bone override approach:

```
Timing:
  re.on_frame()         -> Input detection, paired anim session management, frame advancement
  PrepareRendering      -> Frame sync enforcement, position corrections (AFTER anim eval, BEFORE render)
  re.on_draw_ui()       -> Debug visualization, session inspector
```

The bone override system from the existing framework handles single-actor custom animations. For paired animations, we layer on top:
1. The paired session manager triggers `changeMotion()` calls on each actor's layer
2. Frame synchronization is enforced in `PrepareRendering`
3. If any actor is using bone overrides (e.g., custom dodge animation data), the bone override still runs on top of the paired motion

---

## 5. Handling Interruptions, Death, Distance Limits

### 5.1 Interruption Handling

**Types of interruptions:**
- **Player input**: Player presses a button to break free (e.g., knife counter during grapple)
- **External damage**: A third actor damages one of the paired actors
- **Death**: One actor's HP reaches zero
- **Distance violation**: Actors move too far apart due to physics/collision
- **State override**: The game forces a state change (e.g., cutscene triggers, area transition)

**Interruption protocol:**
```
1. Detect interruption condition
2. Determine which actor(s) are affected
3. Fire on_interrupted callback with reason and affected actor indices
4. For each actor in the session:
   a. If actor is still valid, play an "interruption recovery" animation
      (e.g., stumble back, release grip)
   b. Restore original AI/player control
   c. Re-enable physics and navigation
5. Clean up the session
```

**Interruption windows** (from the PairedAnimDef):
- Some animations should only be interruptible during specific frame ranges
- For example, a grapple might only allow knife counter between frames 30-60
- Outside the window, interruption attempts are queued and execute at the next window

### 5.2 Death During Paired Animation

When an actor dies during a paired animation:
1. **Immediate approach**: Kill the paired animation, play death animation on dying actor, play "release" animation on surviving actors
2. **Graceful approach**: Let the paired animation reach the next sync point, then branch to a "death variant" animation if one exists
3. **Priority**: Death always overrides the paired animation (non-negotiable for gameplay feel)

Implementation:
```lua
-- Hook into the damage system to detect death during paired animation
sdk.hook(
    sdk.find_type_definition("app.ropeway.EnemyHateController"):get_method("find"),
    function(args)
        local session = find_session_for_actor(sdk.to_managed_object(args[2]))
        if session and session.state == "playing" then
            -- Check if damage will kill the actor
            -- If so, trigger session interruption
        end
    end
)
```

### 5.3 Distance Limits

**Maximum allowed separation** during paired animation:
- Default: 3.0 meters from anchor point
- Configurable per animation definition
- Checked every frame in the update loop

**What happens when distance is exceeded:**
1. **Soft limit** (e.g., 2.5m): Apply rubber-banding force to pull actors back together
2. **Hard limit** (e.g., 3.0m): Immediately interrupt the paired animation
3. **Warp threshold** (e.g., >5.0m): Something went very wrong; warp actor back and interrupt

### 5.4 AI State Management

During a paired animation, enemy AI must be suspended:
```lua
-- Before paired animation:
actor.think:set_Enabled(false)            -- Disable AI thinking
actor.hate:get_HateTargetList():Clear()   -- Clear aggro targets
actor.navi:set_Enabled(false)             -- Disable navigation

-- After paired animation:
actor.think:set_Enabled(true)
actor.navi:set_Enabled(true)
-- Re-establish aggro as appropriate
```

Player control must also be locked:
```lua
-- Use the control attribute system
-- app.ropeway.player.tag.ControlAttribute has flags for disabling input
-- Alternatively, use HijackMode on the gamepad device
```

---

## 6. Skeleton Compatibility Issues and Solutions

### 6.1 The Problem

Different character types in RE2 have different skeletons:
- **Player characters** (Leon/Claire): ~80-100 bones, detailed finger/face bones
- **Standard zombies** (Em0000): ~60-80 bones, simplified hands
- **Lickers** (Em3000): Completely different skeleton topology
- **Mr. X** (Em7000): Larger skeleton, different proportions
- **Dogs** (Em5000): Quadruped skeleton

Paired animations authored for specific skeleton pairs may not transfer to different combinations.

### 6.2 Solutions

**Solution A: Animation-per-pair authoring** (most reliable)
- Author specific paired animations for each skeleton combination
- e.g., `zombie_grab_leon`, `zombie_grab_claire`, `licker_grab_leon`
- Pro: Highest quality, no runtime adaptation needed
- Con: Combinatorial explosion of animation count

**Solution B: Shared skeleton subset** (pragmatic)
- Define a "common skeleton" subset that all humanoid characters share
- Typically: root, COG, hips, spine chain, shoulders, upper/lower arms, upper/lower legs, head
- Paired animations only animate this common subset
- Pro: One animation works for all humanoid combinations
- Con: Less detailed animations (no finger interplay, etc.)

**Solution C: Runtime retargeting** (most flexible)
- Use bone mapping tables (already established in `bone_mapping.json`)
- At runtime, remap animation data from the authored skeleton to the target skeleton
- Use IK to fix hand/foot positions that don't align due to proportion differences
- Pro: One animation can adapt to any skeleton
- Con: Complex, may produce visual artifacts

**Solution D: Hybrid approach** (recommended)
- Use shared skeleton subset for the core paired motion
- Apply IK corrections for contact points (hands grabbing, etc.)
- Author proportion-specific adjustments as offset data
- Store a lookup table of skeleton proportions:

```lua
skeleton_proportions = {
    ["Leon"] = {height = 1.0, arm_length = 1.0, leg_length = 1.0},
    ["Claire"] = {height = 0.95, arm_length = 0.93, leg_length = 0.94},
    ["Em0000"] = {height = 1.0, arm_length = 1.0, leg_length = 1.0},  -- Standard zombie
    ["Em7000"] = {height = 1.15, arm_length = 1.1, leg_length = 1.1}, -- Mr. X
}
```

### 6.3 Contact Point IK

For paired animations where actors must touch (e.g., hands on shoulders during a grab):
1. Define "contact point" joint pairs in the animation definition
2. Each frame, compute the world-space position of each contact point on both actors
3. If positions differ (due to proportion mismatch), apply IK to adjust
4. Use the existing `via.motion.IkDamageAction` pattern or our bone override system to make corrections

---

# Part 2: Mod API

## 7. REFramework Mod-to-Mod Communication Patterns

### 7.1 Discovered Patterns from Existing Mods

Analysis of the existing mod examples reveals several established communication patterns:

**Pattern 1: Global Table (`_G` / bare globals)**
The `Hotkeys.lua` mod by alphaZomega demonstrates the primary inter-mod communication pattern:
```lua
-- Hotkeys.lua exposes its functionality via a global variable:
hk = {
    kb = kb,
    mouse = mouse,
    pad = pad,
    keys = keys,
    buttons = buttons,
    -- ... functions ...
    setup_hotkeys = setup_hotkeys,
    check_hotkey = check_hotkey,
    chk_down = chk_down,
    chk_up = chk_up,
    chk_trig = chk_trig,
}
return hk
```

Other mods consume it via `require`:
```lua
-- ThirdPersonCameraController.lua:
local hk = require("Hotkeys/Hotkeys")
hk.setup_hotkeys(csettings.hotkeys, default_csettings.hotkeys)
```

Key observations:
- `require()` works in REFramework Lua and caches the result
- The required module returns a table of functions/data
- This is the cleanest and most idiomatic Lua approach

**Pattern 2: Bare Global Variables**
The `NowhereSafe.lua` mod uses bare globals for settings:
```lua
nwsettings = recurse_def_settings(json.load_file("NowhereSafe.json") or {}, default_nwsettings)
```
This `nwsettings` is accessible from any other mod. While simple, it pollutes the global namespace.

**Pattern 3: SDK Hooks as Event System**
All analyzed mods use `sdk.hook()` extensively:
```lua
sdk.hook(type_def:get_method("methodName"),
    function(args) ... end,  -- pre-hook
    function(retval) ... end -- post-hook
)
```
Multiple mods can hook the same method. REFramework chains hooks in load order. This functions as a de facto event system.

**Pattern 4: Callback Registration via Application Entries**
```lua
re.on_frame(function() ... end)
re.on_pre_application_entry("PrepareRendering", function() ... end)
re.on_application_entry("PrepareRendering", function() ... end)
re.on_draw_ui(function() ... end)
```
All mods can register callbacks. They execute in mod load order (alphabetical by filename within `autorun/`).

### 7.2 REFramework Built-in Facilities

Based on the mod examples and REFramework's Lua API:

| Facility | Usage | Notes |
|----------|-------|-------|
| `require()` | Module loading | Caches result, looks in `autorun/` directory |
| `_G` table | Global namespace | Any global variable is accessible to all mods |
| `json.load_file()` / `json.dump_file()` | Persistent config | Shared config files possible |
| `sdk.hook()` | Method hooking | Multiple mods can hook same method |
| `re.on_*` callbacks | Event timing | All mods register, execute in load order |
| `sdk.find_type_definition()` | Type reflection | Shared type system access |
| `sdk.get_managed_singleton()` | Singleton access | Shared game state access |

### 7.3 Limitations

- **No native event bus**: REFramework has no built-in pub/sub system
- **No mod dependency declaration**: Mods cannot declare dependencies on other mods
- **Load order is alphabetical**: No explicit ordering mechanism
- **No sandboxing**: All mods share the same Lua state
- **No versioning**: No built-in version negotiation between mods

---

## 8. Proposed API Surface

### 8.1 Module Structure

The API should be exposed as a `require`-able module that other mods can consume:

```lua
-- File: autorun/CustomAnimFramework/API.lua
-- Other mods use: local caf = require("CustomAnimFramework/API")

local API = {}
API.VERSION = "1.0.0"
API.VERSION_MAJOR = 1
```

### 8.2 Core API Functions

#### Animation Playback

```lua
--- Play a single animation on one actor
-- @param game_object via.GameObject - The actor
-- @param bank_id number - Motion bank ID
-- @param motion_id number - Motion ID within the bank
-- @param options table (optional) - {layer=0, inter_frame=5.0, speed=1.0, on_complete=fn}
-- @return session_id string - Unique session identifier
API.playAnimation(game_object, bank_id, motion_id, options)

--- Play a paired/synchronized animation on multiple actors
-- @param def PairedAnimDef - The animation definition (see section 4.1)
-- @param actors table - Array of {game_object, [role]} pairs
-- @param options table (optional) - {on_complete=fn, on_interrupted=fn, on_frame=fn}
-- @return session_id string - Unique session identifier
API.playPairedAnimation(def, actors, options)

--- Stop an active animation session
-- @param session_id string - The session to stop
-- @param immediate boolean - If true, stop immediately; if false, blend out
API.stopAnimation(session_id, immediate)

--- Check if a session is currently active
-- @param session_id string - The session to check
-- @return boolean
API.isPlaying(session_id)

--- Get the current frame of an active session
-- @param session_id string
-- @return number or nil
API.getCurrentFrame(session_id)
```

#### Animation Definition Registration

```lua
--- Register a paired animation definition for later use
-- @param id string - Unique animation ID
-- @param def PairedAnimDef - The definition table
API.registerPairedAnimation(id, def)

--- Get a registered paired animation definition
-- @param id string
-- @return PairedAnimDef or nil
API.getPairedAnimation(id)

--- Register a custom animation (single-actor) from file data
-- @param id string - Unique animation ID
-- @param data_path string - Path to frame data file
-- @param options table - {frame_count, bone_count, format}
API.registerCustomAnimation(id, data_path, options)
```

#### Motion Bank Management

```lua
--- Load a motion bank resource at runtime
-- @param game_object via.GameObject - The target actor
-- @param motbank_path string - Path to .motbank file
-- @param bank_type number (optional) - Bank type
-- @return boolean - Success
API.loadMotionBank(game_object, motbank_path, bank_type)

--- Unload a previously loaded motion bank
-- @param game_object via.GameObject
-- @param motbank_path string
API.unloadMotionBank(game_object, motbank_path)
```

#### Actor Utilities

```lua
--- Get the current player's GameObject
-- @return via.GameObject or nil
API.getPlayer()

--- Get all nearby enemies within a radius
-- @param position via.vec3 - Center point
-- @param radius number - Search radius in meters
-- @return table - Array of {game_object, controller, distance, kind_id}
API.getNearbyEnemies(position, radius)

--- Warp an actor to a position (updates physics/navigation)
-- @param game_object via.GameObject
-- @param position via.vec3
-- @param rotation via.Quaternion (optional)
API.warpActor(game_object, position, rotation)

--- Temporarily disable an actor's AI
-- @param game_object via.GameObject
-- @return restore_fn function - Call this to re-enable AI
API.suspendAI(game_object)

--- Lock player input
-- @return restore_fn function - Call this to unlock input
API.lockPlayerInput()
```

### 8.3 Query Functions

```lua
--- Get the framework version
-- @return string - e.g., "1.0.0"
API.getVersion()

--- Get all active animation sessions
-- @return table - {[session_id] = session_info}
API.getActiveSessions()

--- Get all registered animation definitions
-- @return table - {[id] = def}
API.getRegisteredAnimations()

--- Check if the framework is initialized and ready
-- @return boolean
API.isReady()
```

---

## 9. Event System Design

### 9.1 Event Bus Architecture

Since REFramework has no built-in event system, we implement a lightweight one:

```lua
local EventBus = {}
local listeners = {}

function EventBus.on(event_name, callback, priority)
    listeners[event_name] = listeners[event_name] or {}
    table.insert(listeners[event_name], {
        callback = callback,
        priority = priority or 0
    })
    -- Sort by priority (higher = earlier execution)
    table.sort(listeners[event_name], function(a, b) return a.priority > b.priority end)
end

function EventBus.off(event_name, callback)
    if not listeners[event_name] then return end
    for i = #listeners[event_name], 1, -1 do
        if listeners[event_name][i].callback == callback then
            table.remove(listeners[event_name], i)
        end
    end
end

function EventBus.emit(event_name, data)
    if not listeners[event_name] then return end
    for _, listener in ipairs(listeners[event_name]) do
        local success, result = pcall(listener.callback, data)
        if not success then
            log.error("Event listener error for " .. event_name .. ": " .. tostring(result))
        end
        -- If a listener returns false, stop propagation
        if result == false then break end
    end
end
```

### 9.2 Events Emitted by the Framework

| Event Name | Data | When |
|------------|------|------|
| `"animation:started"` | `{session_id, actors, def}` | When any animation session begins |
| `"animation:frame"` | `{session_id, frame, total_frames}` | Each frame during animation (optional subscription) |
| `"animation:sync_point"` | `{session_id, sync_point_id}` | When a sync point is reached |
| `"animation:interrupted"` | `{session_id, reason, actor_idx}` | When an animation is interrupted |
| `"animation:completed"` | `{session_id, actors}` | When an animation completes normally |
| `"paired:actor_joined"` | `{session_id, actor_idx, game_object}` | When an actor joins a paired session |
| `"paired:actor_left"` | `{session_id, actor_idx, reason}` | When an actor leaves (death, interrupt) |
| `"paired:alignment_start"` | `{session_id}` | When actors begin moving to start positions |
| `"paired:alignment_complete"` | `{session_id}` | When all actors are in position |
| `"bank:loaded"` | `{game_object, motbank_path}` | When a motion bank finishes loading |
| `"bank:unloaded"` | `{game_object, motbank_path}` | When a motion bank is unloaded |
| `"framework:ready"` | `{version}` | When the framework completes initialization |
| `"framework:error"` | `{message, context}` | When an error occurs |

### 9.3 Subscribing to Events from Other Mods

```lua
-- In another mod:
local caf = require("CustomAnimFramework/API")

-- Listen for any animation starting
caf.on("animation:started", function(data)
    log.info("Animation started: " .. data.session_id)
end)

-- Listen for paired animation completion with high priority
caf.on("animation:completed", function(data)
    -- Trigger a follow-up action
    if data.def.id == "zombie_grab_front" then
        -- Play a recovery animation
    end
end, 10) -- priority 10 (higher = earlier)

-- Can also cancel event propagation by returning false
caf.on("animation:started", function(data)
    if shouldBlockAnimation(data.def.id) then
        return false -- Prevents other listeners from seeing this event
    end
end, 100) -- Very high priority
```

### 9.4 Request Events (Other Mods -> Framework)

Other mods can also request actions through the event system:

| Event Name | Data | Purpose |
|------------|------|---------|
| `"request:play_paired"` | `{def_id, actors, options}` | Request a paired animation by registered ID |
| `"request:interrupt"` | `{session_id, reason}` | Request interruption of a session |
| `"request:extend"` | `{session_id, extra_frames}` | Request extension of a session |

This two-way event flow allows loose coupling. A combat mod does not need to directly call the animation framework's functions; it can emit a request event and the framework handles it.

---

## 10. Example Usage Scenarios

### 10.1 Combat Mod Triggers a Finisher Animation

```lua
-- CombatFinisherMod.lua
local caf = require("CustomAnimFramework/API")

-- Register a finisher animation
caf.registerPairedAnimation("zombie_head_stomp", {
    id = "zombie_head_stomp",
    actor_count = 2,
    actors = {
        [1] = {role = "player", bank_id = 100, motion_id = 1, layer = 0, inter_frame = 5.0},
        [2] = {role = "enemy",  bank_id = 100, motion_id = 2, layer = 0, inter_frame = 5.0,
               offset = {x=0, y=0, z=0.8}, facing = "toward_primary"},
    },
    duration_frames = 60,
    sync_mode = "frame_locked",
    allow_interruption = false,
})

-- When player is near a downed zombie and presses a button:
local function tryFinisher()
    local player = caf.getPlayer()
    if not player then return end

    local nearby = caf.getNearbyEnemies(player:get_Transform():get_Position(), 2.0)
    for _, enemy_info in ipairs(nearby) do
        if enemy_info.is_downed then
            caf.playPairedAnimation("zombie_head_stomp", {
                {game_object = player, role = "player"},
                {game_object = enemy_info.game_object, role = "enemy"},
            }, {
                on_complete = function(session)
                    -- Kill the zombie after animation
                    enemy_info.controller:kill()
                end,
            })
            return
        end
    end
end
```

### 10.2 Cutscene Mod Coordinates 4 Actors

```lua
-- CustomCutsceneMod.lua
local caf = require("CustomAnimFramework/API")

local function playGroupScene()
    local player = caf.getPlayer()
    local allies = findAllies() -- mod's own function
    local enemy = findBoss()

    caf.playPairedAnimation({
        id = "boss_confrontation",
        actor_count = 4,
        actors = {
            [1] = {role = "protagonist", bank_id = 200, motion_id = 1, layer = 0, inter_frame = 8.0},
            [2] = {role = "ally_1",      bank_id = 200, motion_id = 2, layer = 0, inter_frame = 8.0,
                   offset = {x=-1.5, y=0, z=0.5}},
            [3] = {role = "ally_2",      bank_id = 200, motion_id = 3, layer = 0, inter_frame = 8.0,
                   offset = {x=1.5, y=0, z=0.5}},
            [4] = {role = "boss",        bank_id = 200, motion_id = 4, layer = 0, inter_frame = 8.0,
                   offset = {x=0, y=0, z=4.0}, facing = "toward_primary"},
        },
        duration_frames = 180,
        sync_mode = "frame_locked",
    }, {
        {game_object = player},
        {game_object = allies[1]},
        {game_object = allies[2]},
        {game_object = enemy},
    }, {
        on_complete = function()
            -- Transition to boss fight phase 2
        end,
    })
end
```

### 10.3 Nowhere Safe Mod Integration

The NowhereSafe mod could use our API to play custom grapple animations:

```lua
-- In NowhereSafe.lua (hypothetical extension):
local caf = require("CustomAnimFramework/API")

-- Listen for when a zombie reaches the player and trigger a custom grab
caf.on("paired:alignment_complete", function(data)
    if data.def.id:find("zombie_grab") then
        -- Disable safe room music, increase tension
        setMusicTension(1.0)
    end
end)
```

---

## 11. Thread Safety and Execution Order

### 11.1 REFramework Execution Model

REFramework's Lua environment is **single-threaded**. All callbacks (`re.on_frame`, `re.on_application_entry`, hooks) execute on the main thread. This means:

- No mutex/lock concerns between Lua mods
- All event callbacks execute synchronously within their frame
- Order within a single frame point (e.g., all `re.on_frame` callbacks) is determined by mod load order

### 11.2 Execution Order Within a Frame

```
1. re.on_pre_application_entry("UpdateHID")     -- Input sampling
2. re.on_pre_application_entry("BeginRendering") -- Pre-render
3. re.on_frame()                                  -- Game logic callbacks
4. sdk.hook pre-hooks                             -- Before hooked methods
5. [Game engine native code runs]
6. sdk.hook post-hooks                            -- After hooked methods
7. re.on_application_entry("PrepareRendering")    -- Post-anim, pre-render
8. re.on_draw_ui()                                -- ImGui rendering
```

For our framework, the critical timing points are:
- **Input + state management** in `re.on_frame()` (step 3)
- **Frame sync enforcement** in `PrepareRendering` (step 7)
- **Debug UI** in `re.on_draw_ui()` (step 8)

### 11.3 Load Order Considerations

Our framework should be named to load early. REFramework loads autorun scripts alphabetically:
- Name: `autorun/CustomAnimFramework.lua` (loads before most mods starting with letters later in the alphabet)
- Or: `autorun/!CustomAnimFramework.lua` (the `!` prefix ensures it loads first)
- The API module: `autorun/CustomAnimFramework/API.lua` (loaded on demand via `require`)

### 11.4 Defensive Programming

Since other mods may interact unpredictably:

```lua
-- All API functions should validate inputs
function API.playPairedAnimation(def, actors, options)
    -- Validate definition
    if type(def) ~= "table" then
        log.error("playPairedAnimation: def must be a table")
        return nil
    end
    if not def.actors or #def.actors < 2 then
        log.error("playPairedAnimation: def must have at least 2 actors")
        return nil
    end

    -- Validate actors
    for i, actor in ipairs(actors) do
        if not actor.game_object or not actor.game_object:get_Valid() then
            log.error("playPairedAnimation: actor " .. i .. " has invalid game_object")
            return nil
        end
    end

    -- Wrap callbacks in pcall
    if options and options.on_complete then
        local original_fn = options.on_complete
        options.on_complete = function(...)
            local ok, err = pcall(original_fn, ...)
            if not ok then log.error("on_complete callback error: " .. tostring(err)) end
        end
    end

    -- ... proceed with animation
end
```

### 11.5 Reentrancy Protection

Prevent recursive calls (e.g., an event handler that triggers another animation):

```lua
local processing_event = false

function EventBus.emit(event_name, data)
    if processing_event then
        -- Queue the event for next frame instead of processing immediately
        table.insert(deferred_events, {event_name, data})
        return
    end
    processing_event = true
    -- ... process event ...
    processing_event = false
end
```

---

## 12. Versioning and Backwards Compatibility

### 12.1 Semantic Versioning

The API follows semantic versioning (MAJOR.MINOR.PATCH):
- **MAJOR** (1.x.x): Breaking changes to existing API functions
- **MINOR** (x.1.x): New functions added, existing functions unchanged
- **PATCH** (x.x.1): Bug fixes, no API changes

### 12.2 Version Negotiation

Other mods should check the API version before using it:

```lua
local caf = require("CustomAnimFramework/API")

-- Check if framework is present
if not caf then
    log.warn("CustomAnimFramework not installed, disabling animation features")
    return
end

-- Check minimum version
if caf.VERSION_MAJOR < 1 then
    log.warn("CustomAnimFramework version too old, need 1.x.x, have " .. caf.VERSION)
    return
end

-- Check for specific feature (defensive)
if not caf.playPairedAnimation then
    log.warn("CustomAnimFramework does not support paired animations")
    return
end
```

### 12.3 Deprecation Policy

When functions need to change:
1. Mark old function as deprecated (still works, prints a warning)
2. Add new function alongside
3. Remove old function only in next MAJOR version

```lua
function API.playSync(...)  -- old name
    log.warn("API.playSync is deprecated, use API.playPairedAnimation instead")
    return API.playPairedAnimation(...)
end
```

### 12.4 Feature Flags

For optional features that may not be available in all versions:

```lua
API.features = {
    paired_animations = true,
    bone_override = true,
    motion_bank_loading = true,
    ik_correction = false,       -- Not yet implemented
    audio_sync = false,          -- Not yet implemented
}

-- Other mods check:
if caf.features.ik_correction then
    -- Use IK features
end
```

### 12.5 Configuration Schema

The framework stores its configuration in a versioned JSON file:

```json
{
    "version": "1.0.0",
    "max_concurrent_sessions": 4,
    "default_inter_frame": 5.0,
    "distance_limit": 3.0,
    "debug_mode": false,
    "registered_animations": {}
}
```

When loading, the framework migrates old config formats to the current version automatically.

---

## Appendix A: Enemy Type Reference

| Enemy Code | Name | Skeleton Type | Notes |
|------------|------|---------------|-------|
| Em0000 | Standard Zombie | Humanoid | Multiple subtypes (male/female variants) |
| Em3000 | Licker | Quadruped-ish | Unique skeleton, wall-crawling |
| Em4000 | Ivy (Plant) | Non-standard | Tentacle-based skeleton |
| Em4100 | Ivy variant | Non-standard | Similar to Em4000 |
| Em4400 | G-Adult | Large humanoid | Oversized proportions |
| Em5000 | Zombie Dog | Quadruped | Dog skeleton |
| Em6000 | G-Embryo | Small | Tiny skeleton |
| Em6200 | Mr. X (Tyrant) | Large humanoid | 1.15x scale humanoid |
| Em6300 | Super Tyrant | Large humanoid | Even larger than Mr. X |
| Em7000 | Mr. X (Stalker) | Large humanoid | Same as Em6200 with stalker AI |
| Em7100 | G-Birkin | Variable | Multiple forms with different skeletons |
| Em8200 | Pale Head | Humanoid | Same skeleton as Em0000 |
| Em8400 | Pale Head variant | Humanoid | Same skeleton as Em0000 |
| Em8500 | Zombie (Rogue) | Humanoid | Same skeleton as Em0000 |

## Appendix B: Key File Paths

| File | Path | Purpose |
|------|------|---------|
| IL2CPP Dump | `<game_root>/reframework/il2cpp_dump.json` | Type definitions |
| Framework Architecture | `docs/framework_architecture.md` | Existing arch doc |
| Animation Types Reference | `docs/re_engine_animation_types.md` | Motion system reference |
| NowhereSafe Mod | Community mod by Alphazonation | Enemy management patterns |
| Hotkeys Mod | Community mod by alphaZomega | Inter-mod API pattern |
| Backdash Mod | Community mod | Player movement pattern |
| Game Autorun Dir | `<game_root>/reframework/autorun/` | Live mod directory |

## Appendix C: Further Research Needed

1. **Motion bank file format**: How to author `.motbank` files containing paired animation variants for multiple skeleton combinations
2. **IK system deep-dive**: Full analysis of `via.motion.IkDamageAction` methods for runtime IK correction during paired animations
3. **Camera integration**: How to control the camera during paired animations (the `EnemyActionCameraSwitchTrack` type suggests camera control is track-based)
4. **Audio synchronization**: How to trigger sound effects at specific frames during paired animations (via `MotionEventHandler`)
5. **Network/replay compatibility**: Whether animation state can be recorded and replayed for recording tools
6. **Performance profiling**: Benchmarking the overhead of per-frame Lua synchronization with 6 actors
