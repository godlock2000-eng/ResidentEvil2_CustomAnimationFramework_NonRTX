# RE2 Remake Actor & Motion Systems Research Document

**Date:** 2026-02-08
**Source data:** RE2 `il2cpp_dump.json`, RE3 `il2cpp_dump.json`, NowhereSafe.lua, Backdash.lua
**Goal:** Understand how to load custom animations on ANY actor (player, NPC, enemy)

---

## 1. Actor Type Hierarchy in RE2 Remake

### 1.1 Namespace Convention

RE2 Remake uses the `app.ropeway` namespace prefix. RE3 uses `offline`. The game uses `sdk.game_namespace()` to resolve the correct prefix at runtime.

```
RE2:  app.ropeway.*
RE3:  offline.*
```

### 1.2 Player Actor Classes

```
app.ropeway.survivor.player.PlayerCondition
  -- The main player state/condition component
  -- Accessed via PlayerManager singleton

app.ropeway.PlayerDefine.PlayerType
  -- Enum distinguishing Leon vs Claire

app.ropeway.CharacterManager
  -- Singleton, can get player context via getPlayerContextRef()
  -- Used in Backdash.lua: sdk.get_managed_singleton(sdk.game_namespace("CharacterManager"))
```

**How to get the player:**
```lua
-- Method 1 (from NowhereSafe.lua):
local player_go = sdk.get_managed_singleton(sdk.game_namespace("PlayerManager")):call("get_CurrentPlayer")
local player_condition = getC(player_go, sdk.game_namespace("survivor.player.PlayerCondition"))

-- Method 2 (from Backdash.lua):
local character_manager = sdk.get_managed_singleton(sdk.game_namespace("CharacterManager"))
local player_context = character_manager:call("getPlayerContextRef")
local body_go = player_context:get_BodyGameObject()
```

### 1.3 Enemy Actor Classes

```
app.ropeway.EnemyController
  -- The core enemy controller component, present on every enemy
  -- Contains backing fields for all sub-controllers

app.ropeway.EnemyManager
  -- Singleton that tracks ALL enemies in the scene
  -- Has <EnemyList>k__BackingField containing RegisterEnemyInfo array
  -- Has methods: InstantiateRequestData, DestroyRequestData, SceneLoadStatus

app.ropeway.enemy.EmCommonContext
  -- Base context for all enemies
  -- Methods: requestEnemyCreate, requestEnemyDestroy, setActivity, get_Valid
  -- Properties: <EnemyController>k__BackingField, <EnemyGameObject>k__BackingField

app.ropeway.EnemyContextController
  -- Per-enemy context controller

app.ropeway.EnemySpawnController
  -- Manages spawn/despawn for groups of enemies

app.ropeway.EnemyDataManager
  -- Contains DynamicMotionBankInfo for enemies
  -- getDynamicMotionBankContainer(EnemyDefine.KindID) -- get motion bank by enemy type

app.ropeway.EnemyDefine.KindID
  -- Enum for enemy types (zombies, lickers, Mr. X, etc.)
```

**Enemy type naming convention (from NowhereSafe.lua):**
```
Em0000 - Em0900: Zombies (male/female variants)
Em8200, Em8500:  Special zombies
Em8400:          Pale Heads
Em6200:          Mr. X (Stalker, RE2)
Em9000, Em9100:  Nemesis (Stalker, RE3)
```

**Key EnemyController backing fields (from NowhereSafe.lua line ~533-548):**
```lua
self.ec = ctx["<EnemyController>k__BackingField"]
self.hate = ec["<HateController>k__BackingField"]
self.loiter = ec["<LoiteringController>k__BackingField"]
self.gcc = ec["<EnemyGimmickConfiscateController>k__BackingField"]
self.think = ec["<Think>k__BackingField"]
self.sensor = ec["<Sensor>k__BackingField"]
self.cc = ec["<CharacterController>k__BackingField"]       -- via.physics.CharacterController
self.mfsm = ec["<MotionFsm>k__BackingField"]               -- the animation FSM!
self.navi = ec["<NaviMoveSupporter>k__BackingField"]
self.stay = ec["<StayAreaController>k__BackingField"]
```

### 1.4 NPC Actor Classes

```
app.ropeway.survivor.npc.NpcController
  -- NPC-specific controller
  -- Contains DirectionHistory for movement tracking
```

NPCs are less well-documented in mod code. They use similar component patterns to enemies but with `NpcController` instead of `EnemyController`.

### 1.5 RE3 Comparison

RE3 uses `offline` namespace but the same structural patterns:
```
offline.EnemyController
offline.EnemyManager  (not found as separate string, likely under offline namespace)
offline.DynamicMotionBankContainer
offline.DynamicMotionBankController
```

The DynamicMotionBank system exists in both games with nearly identical class names, just different namespace prefixes.

---

## 2. Enumerating Actors at Runtime

### 2.1 Enumerating All Enemies

**Primary method (from NowhereSafe.lua line ~991):**
```lua
local em = sdk.get_managed_singleton(sdk.game_namespace("EnemyManager"))

-- Iterate the EnemyList
for i, reg_info in pairs(em["<EnemyList>k__BackingField"].mItems:get_elements()) do
    if reg_info then
        local ctx = reg_info["<Context>k__BackingField"]  -- EmCommonContext
        local ec = ctx["<EnemyController>k__BackingField"]  -- EnemyController
        local gameobj = ctx["<EnemyGameObject>k__BackingField"]  -- GameObject
        -- Now you have access to everything
    end
end
```

**Alternative: scene.findComponents (from NowhereSafe.lua):**
```lua
local scene = sdk.call_native_func(
    sdk.get_native_singleton("via.SceneManager"),
    sdk.find_type_definition("via.SceneManager"),
    "get_CurrentScene()"
)
-- Find all components of a type in the scene
local components = scene:call("findComponents(System.Type)", sdk.typeof("via.motion.Motion"))
```

### 2.2 Getting the Player

```lua
local player_mgr = sdk.get_managed_singleton(sdk.game_namespace("PlayerManager"))
local player_go = player_mgr:call("get_CurrentPlayer")  -- returns GameObject
```

### 2.3 Getting an Actor's Motion Component

**Universal pattern - works for ANY actor (player, enemy, NPC):**
```lua
local function getC(gameobj, component_name)
    if not gameobj then return end
    gameobj = gameobj.get_GameObject and gameobj:get_GameObject() or gameobj
    return gameobj:call("getComponent(System.Type)", sdk.typeof(component_name))
end

-- For any actor's GameObject:
local motion = getC(actor_gameobj, "via.motion.Motion")
```

**For enemies specifically:**
```lua
-- From EnemyController, the MotionFsm is directly accessible:
local ec = ctx["<EnemyController>k__BackingField"]
local mfsm = ec["<MotionFsm>k__BackingField"]

-- Or get Motion component from the enemy's GameObject:
local gameobj = ctx["<EnemyGameObject>k__BackingField"]
local motion = getC(gameobj, "via.motion.Motion")
```

**For the player:**
```lua
local player_go = player_mgr:call("get_CurrentPlayer")
local motion = getC(player_go, "via.motion.Motion")
```

---

## 3. The Motion Component Hierarchy

### 3.1 via.motion.Motion

The core animation component. Inheritance chain:
```
via.Object -> System.Object -> via.Component -> via.motion.Animation -> via.motion.Motion
```

**Key methods on via.motion.Motion (from il2cpp_dump):**

| Method | Signature | Purpose |
|--------|-----------|---------|
| `changeMotionBankSize` | `(size: u32) -> void` | Resize the motion bank array |
| `findMotionBank` | `(bankId: u32) -> MotionBank` | Find a bank by ID |
| `findMotionBank` | `(bankId: u32, bankType: u32) -> MotionBank` | Find bank by ID + type |
| `findMotionBankByNameHash` | `(motlistNameHash: u32) -> MotionBank` | Find bank by name hash |
| `getActiveMotionBank` | `(no: u32) -> MotionBank` | Get active bank by index |
| `getActiveMotionBankCount` | `() -> u32` | Count of active banks |
| `getDynamicMotionBank` | `(idx: s32) -> DynamicMotionBank` | Get dynamic bank by index |
| `getDynamicMotionBankCount` | `() -> s32` | Count of dynamic banks |
| `setDynamicMotionBank` | `(idx: s32, bank_ptr: DynamicMotionBank) -> void` | **Set a dynamic motion bank** |
| `setDynamicMotionBankCount` | `(count: s32) -> void` | Set dynamic bank count |

**Also has via.motion.Motion reflection methods:**
```
changeMotionBankSize(size: u32) -> void
setDynamicMotionBank(idx: s32, bank_ptr: via.motion.DynamicMotionBank) -> void
setDynamicMotionBankCount(count: s32) -> void
getDynamicMotionBank(idx: s32) -> via.motion.DynamicMotionBank
getDynamicMotionBankCount() -> s32
```

### 3.2 via.motion.TreeLayer

Animation tree layer -- this is where individual motions are triggered. Inheritance:
```
via.Object -> System.Object -> via.motion.TreeLayer
```

**Key reflection methods on TreeLayer:**

| Method | Signature | Purpose |
|--------|-----------|---------|
| `changeMotion` | `(bankID: u32, motionID: u32, startFrame: f32, interFrame: f32, interMode: InterpolationMode, interCurve: InterpolationCurve) -> void` | **Play a specific animation** |
| `changeSequencePhase` | `(phase: SequencePhase) -> void` | Change animation sequence phase |
| `clearMotionResource` | `() -> void` | Clear current motion |
| `clearControlledByClip` | `() -> void` | Release clip control |
| `copyFrom` | `(ptr: TreeLayer) -> void` | Copy from another layer |
| `copyToDeformValues` | `(weight_tbl: f32[]) -> void` | Copy deform weights |

**TreeLayer properties (read/write):**
```
BankID          (u32)     -- Current bank ID
MotionID        (u32)     -- Current motion ID
Speed           (f32)     -- Playback speed
Frame           (f32)     -- Current frame
EndFrame        (f32)     -- Total frame count
Weight          (f32)     -- Layer blending weight
WrapMode        (enum)    -- Loop/once/etc.
BlendMode       (enum)    -- How this layer blends
InterpolationFrame (f32)  -- Blend transition frames
RootOnly        (bool)    -- Root motion only
StopUpdate      (bool)    -- Pause this layer
```

### 3.3 via.motion.MotionFsm / MotionFsm2Layer

The finite state machine that drives animation transitions. Each enemy/player has a MotionFsm.

```lua
-- Get current animation node name (from NowhereSafe.lua):
local node_name = mfsm:getCurrentNodeName(0)
-- node_name examples: "WALK.STANDING.LOOP", "KNOCK", "DOOR", etc.
```

### 3.4 via.motion.MotionBankResourceHolder

Holds references to loaded motion bank resources. Hierarchy:
```
via.motion.MotionBankBaseResourceHolder -> via.motion.MotionBankResourceHolder
```

---

## 4. DynamicMotionBank: Complete Loading Pipeline

### 4.1 Class Hierarchy

```
via.motion.DynamicMotionBank
  -- Engine-level native type for dynamic (runtime-loaded) motion banks
  -- Has get_DynamicMotionBank property

app.ropeway.DynamicMotionBankContainer
  -- App-level container, holds DataContainer[] array
  -- getDynamicMotionBankContainer(EnemyDefine.KindID) method on EnemyDataManager

app.ropeway.DynamicMotionBankController
  -- Manages loading/unloading of dynamic banks
  -- Uses Dictionary<String, Handle> to track loaded banks
  -- Has Handle type for referencing loaded banks

app.ropeway.DynamicMotionBankController.Handle
  -- Reference handle for a loaded dynamic bank
  -- Contains IsResetMotion flag

app.ropeway.DynamicMotionBankDefine.OrderKind
  -- Enum for ordering/priority of bank loading

app.ropeway.EnemyDataManager.DynamicMotionBankInfo
  -- Per-enemy-type motion bank info
  -- Has LoadStatus enum tracking load state

app.ropeway.gimmick.option.OuterDynamicMotionBankSettings
  -- Settings for external/gimmick dynamic banks
  -- Has Info, Param, Work sub-types
  -- Info has SetKind and TargetKind enums
```

### 4.2 Resource Loading Pipeline

**Step 1: Create the resource from a .motlist file path**
```lua
-- From NowhereSafe.lua's create_resource helper (line 204-209):
local function create_resource(resource_type, resource_path)
    local new_resource = resource_path and sdk.create_resource(resource_type, resource_path)
    if not new_resource then return end
    new_resource = new_resource:add_ref()
    return new_resource:create_holder(resource_type .. "Holder"):add_ref()
end

-- Usage:
local holder = create_resource("via.motion.MotionBankResource",
    "path/to/custom.motlist")
-- Returns: via.motion.MotionBankResourceHolder
```

**Step 2: Create or get a DynamicMotionBank instance**
```lua
-- The Motion component manages dynamic banks
local motion = getC(actor_gameobj, "via.motion.Motion")
local current_count = motion:call("getDynamicMotionBankCount")

-- Increase the count to make room for a new bank
motion:call("setDynamicMotionBankCount", current_count + 1)

-- Get the newly created slot (or create an instance)
local dyn_bank = motion:call("getDynamicMotionBank", current_count)
```

**Step 3: Attach the resource holder to the DynamicMotionBank**
```lua
-- Set the motion bank resource on the DynamicMotionBank
dyn_bank:call("set_MotionBank", holder)  -- MotionBankResourceHolder
```

**Step 4: Register the bank on the Motion component**
```lua
-- If you created the bank externally, set it:
motion:call("setDynamicMotionBank", bank_index, dyn_bank)
```

**Step 5: Trigger the animation via TreeLayer.changeMotion()**
```lua
-- Get the tree layer (layer 0 is typically the base layer)
local layer = motion:call("getLayer", 0)  -- returns TreeLayer

-- Play the animation
layer:call("changeMotion",
    bank_id,        -- u32: the bank ID containing the motion
    motion_id,      -- u32: the specific motion within the bank
    0.0,            -- f32: startFrame
    10.0,           -- f32: interFrame (blend transition frames)
    0,              -- InterpolationMode (0 = default)
    0               -- InterpolationCurve (0 = default)
)
```

### 4.3 The DynamicMotionBankController (App-Level)

The game's own `DynamicMotionBankController` manages this process internally:

```
Dictionary<String, Handle>  -- Maps bank names to loaded handles
Handle contains:
  - IsResetMotion (bool)
  - Reference to the loaded DynamicMotionBank
```

For enemies, the `EnemyDataManager` provides:
```lua
-- Get the motion bank container for a specific enemy type:
local enemy_data_mgr = sdk.get_managed_singleton(sdk.game_namespace("EnemyDataManager"))
local container = enemy_data_mgr:call("getDynamicMotionBankContainer", kind_id)
```

---

## 5. Motion Bank Organization

### 5.1 Bank IDs and Motion IDs

Every animation is addressed by a `(bankID, motionID)` pair:
- **bankID** (u32): Identifies which .motlist file the animation comes from
- **motionID** (u32): Identifies which animation within that bank

The game uses `findMotionBank(bankId)` to locate loaded banks, and `changeMotion(bankID, motionID, ...)` to play them.

### 5.2 Bank Types

There are static banks (loaded with the actor) and dynamic banks (loaded at runtime):
- **Static banks**: Pre-assigned in the actor's prefab/setup, always available
- **Dynamic banks**: Loaded via DynamicMotionBank system, can be hot-loaded

The `findMotionBank(bankId, bankType)` overload allows searching by type as well.

### 5.3 How Banks Map to Files

Motion banks correspond to `.motlist` resource files. The `via.motion.MotionBankResource` is the resource type, and `via.motion.MotionBankResourceHolder` wraps it for use in the engine.

---

## 6. Differences Between Player and Enemy Motion Systems

### 6.1 Player Motion

- Player uses `PlayerManager` singleton for access
- Player has a more complex motion FSM with weapon-specific states
- Player's DynamicMotionBankContainer is accessed via `PlayerDefine.PlayerType`
- Player has `app.ropeway.DynamicMotionBankController` for managing dynamic bank loads
- Player animations are more heavily driven by FSM state transitions

### 6.2 Enemy Motion

- Enemies are tracked by `EnemyManager` singleton with `<EnemyList>k__BackingField`
- Each enemy has `EnemyController` with `<MotionFsm>k__BackingField`
- Enemy DynamicMotionBanks are organized by `EnemyDefine.KindID` (enemy type)
- `EnemyDataManager.DynamicMotionBankInfo` tracks per-type load status
- Enemies can have their banks loaded/unloaded dynamically for memory management
- The `NowhereSafe.lua` mod accesses enemy motion via:
  ```lua
  self.mfsm = ec["<MotionFsm>k__BackingField"]
  self.node_name = self.mfsm:getCurrentNodeName(0)
  ```

### 6.3 NPC Motion

- NPCs use `NpcController` but follow similar patterns to enemies
- Less documented in existing mod code
- Likely use the same `via.motion.Motion` + TreeLayer system

### 6.4 Common Ground

ALL actor types share the same underlying motion pipeline:
1. `via.motion.Motion` component on the GameObject
2. `via.motion.TreeLayer` for animation playback control
3. `via.motion.DynamicMotionBank` for runtime bank loading
4. `via.motion.MotionBankResourceHolder` for resource management
5. `TreeLayer.changeMotion(bankID, motionID, ...)` for triggering playback

The only differences are in the higher-level game logic that manages when/how animations are triggered (FSM states, AI controllers, etc.).

---

## 7. Playing a Custom Animation on an Arbitrary Actor

### 7.1 Universal Steps

For ANY actor (player, enemy, NPC), the process is:

```lua
-- Step 1: Get the actor's GameObject
local gameobj = ... -- from PlayerManager, EnemyManager, or scene search

-- Step 2: Get the Motion component
local motion = gameobj:call("getComponent(System.Type)", sdk.typeof("via.motion.Motion"))

-- Step 3: Load your custom .motlist resource
local resource = sdk.create_resource("via.motion.MotionBankResource", "path/to/custom.motlist")
resource = resource:add_ref()
local holder = resource:create_holder("via.motion.MotionBankResourceHolder"):add_ref()

-- Step 4: Create/expand dynamic bank slots
local count = motion:call("getDynamicMotionBankCount")
motion:call("setDynamicMotionBankCount", count + 1)
local dyn_bank = motion:call("getDynamicMotionBank", count)

-- Step 5: Assign resource to bank
dyn_bank:call("set_MotionBank", holder)

-- Step 6: Play the animation on the desired tree layer
local layer = motion:call("getLayer", 0)
layer:call("changeMotion",
    target_bank_id,    -- must match the bankID in the .motlist
    target_motion_id,  -- the motion index
    0.0,               -- startFrame
    10.0,              -- interFrame (blend frames)
    0,                 -- InterpolationMode
    0                  -- InterpolationCurve
)
```

### 7.2 Actor-Specific Considerations

**Player:**
- The FSM will fight back -- it constantly drives animations based on game state
- You need to either hook the FSM to prevent overrides, or work within its framework
- The bone-override dodge system we built bypasses this by writing transforms directly

**Enemies:**
- The enemy AI FSM also drives animations aggressively
- When an enemy is in a state like "WALK.STANDING.LOOP", it's actively playing that motion
- You would need to either:
  - Hook the FSM transition to inject your custom motion
  - Force the motion each frame (will fight with the FSM)
  - Temporarily disable the FSM layer and control it manually

**NPCs:**
- Similar to enemies but typically have simpler FSMs
- Cutscene NPCs may have their animations fully scripted

### 7.3 The getC() Helper Pattern

This pattern from NowhereSafe.lua works universally for any component on any actor:

```lua
local function getC(gameobj, component_name)
    if not gameobj then return end
    gameobj = gameobj.get_GameObject and gameobj:get_GameObject() or gameobj
    return gameobj:call("getComponent(System.Type)", sdk.typeof(component_name))
end
```

---

## 8. Key REFramework API Patterns

### 8.1 Singletons

```lua
sdk.get_managed_singleton(sdk.game_namespace("EnemyManager"))
sdk.get_managed_singleton(sdk.game_namespace("PlayerManager"))
sdk.get_managed_singleton(sdk.game_namespace("CharacterManager"))
sdk.get_managed_singleton(sdk.game_namespace("enemy.em0000.Em0000Manager"))
```

### 8.2 Scene Queries

```lua
local scene = sdk.call_native_func(
    sdk.get_native_singleton("via.SceneManager"),
    sdk.find_type_definition("via.SceneManager"),
    "get_CurrentScene()"
)

-- Find a specific named object:
local obj = scene:call("findGameObject(System.String)", "ObjectName")

-- Find all components of a type:
local comps = scene:call("findComponents(System.Type)", sdk.typeof("via.motion.Motion"))
```

### 8.3 Resource Creation

```lua
-- sdk.create_resource(type_string, path_string) -> resource
local resource = sdk.create_resource("via.motion.MotionBankResource", path)
resource = resource:add_ref()
local holder = resource:create_holder("via.motion.MotionBankResourceHolder"):add_ref()
```

### 8.4 Hooking Methods

```lua
sdk.hook(
    sdk.find_type_definition("TypeName"):get_method("methodName"),
    function(args) -- pre-hook
        local self = sdk.to_managed_object(args[2])
        -- modify args, return sdk.PreHookResult.SKIP_ORIGINAL to skip
    end,
    function(retval) -- post-hook
        return retval -- can modify return value
    end
)
```

---

## 9. Feasibility Assessment

### 9.1 What Works Today

| Feature | Status | Evidence |
|---------|--------|----------|
| Get player Motion component | PROVEN | Backdash.lua, our dodge system |
| Get enemy Motion component | PROVEN | NowhereSafe.lua accesses MotionFsm |
| Enumerate all enemies | PROVEN | NowhereSafe.lua iterates EnemyList |
| sdk.create_resource() for MotionBank | LIKELY | Used for other resource types, pattern documented |
| DynamicMotionBank API exists | CONFIRMED | setDynamicMotionBank, getDynamicMotionBank in il2cpp_dump |
| TreeLayer.changeMotion() | CONFIRMED | Full signature in il2cpp_dump |
| Bone-override animation (player) | WORKING | Our CustomAnimFramework |

### 9.2 Untested But Likely Feasible

| Feature | Risk | Notes |
|---------|------|-------|
| Load custom .motlist at runtime | MEDIUM | `sdk.create_resource` works for other types; .motlist is the standard format |
| Assign DynamicMotionBank to enemy | MEDIUM | API is identical to player; enemy Motion component is the same class |
| Play custom animation on enemy | MEDIUM-HIGH | FSM will interfere; need to manage layer conflicts |
| Skeleton compatibility | HIGH | Custom .motlist must match the target skeleton bone count/names |

### 9.3 Risk Factors

1. **FSM Override Conflict**: Both player and enemy FSMs actively control the TreeLayer each frame. Injecting a custom animation without managing the FSM will result in the animation being immediately overwritten. Solutions:
   - Hook the FSM update to prevent it from changing the layer during playback
   - Use a separate layer (higher index) that blends over the FSM-controlled base layer
   - Temporarily set `StopUpdate = true` on the FSM-controlled layer

2. **Skeleton Mismatch**: A .motlist created for Leon's skeleton will crash or produce garbage if applied to a zombie's skeleton. Each actor type has different bone hierarchies. Custom animations must be authored per-skeleton-type.

3. **Memory Management**: Dynamic banks consume memory. The engine's DynamicMotionBankController manages load/unload lifecycle. If we manually create banks, we must properly manage `add_ref()` and cleanup.

4. **Bank ID Conflicts**: If we assign a bank ID that conflicts with an existing bank, unpredictable behavior results. We need to use bank IDs in ranges that don't conflict with the game's own banks.

### 9.4 Recommended Approach

**Phase 1 - Proof of Concept (Player):**
1. Use `sdk.create_resource("via.motion.MotionBankResource", path)` to load a .motlist
2. Create a DynamicMotionBank, assign the resource
3. Register it on the player's Motion component
4. Call `TreeLayer.changeMotion()` with the bank's ID
5. Verify animation plays

**Phase 2 - Extend to Enemies:**
1. Enumerate enemies via EnemyManager
2. Get each enemy's Motion component via `getC(gameobj, "via.motion.Motion")`
3. Apply the same DynamicMotionBank pipeline
4. Hook the enemy's MotionFsm to prevent override during custom playback

**Phase 3 - Universal Actor System:**
1. Create an abstraction that works for any actor type
2. Handle skeleton detection (check bone names/count before assigning)
3. Manage bank ID allocation to avoid conflicts
4. Provide blending controls (weight, interpolation frames)

---

## 10. Reference: Key Type Definitions

### via.motion.Motion (id: 54458)
- Parent: `via.motion.Animation`
- Field: `UndefBankType` (static, default: -1)
- Key native methods: changeMotionBankSize, findMotionBank, getDynamicMotionBank, setDynamicMotionBank, setDynamicMotionBankCount

### via.motion.TreeLayer (id: 50304)
- Parent: via.Object (native type)
- Key native method: `changeMotion(bankID: u32, motionID: u32, startFrame: f32, interFrame: f32, interMode: InterpolationMode, interCurve: InterpolationCurve)`
- Properties: BankID, MotionID, Speed, Frame, EndFrame, Weight, WrapMode, BlendMode, RootOnly, StopUpdate

### via.motion.MotionBankResourceHolder (id: at 9065754)
- Parent: `via.motion.MotionBankBaseResourceHolder`
- Used in TreeLayer and Motion reflection methods for bank assignment

### app.ropeway.DynamicMotionBankController (at line 5865522)
- Uses `Dictionary<String, Handle>` for bank tracking
- Handle contains: IsResetMotion (bool)

### app.ropeway.EnemyManager
- Singleton
- `<EnemyList>k__BackingField`: Array of RegisterEnemyInfo
- RegisterEnemyInfo has `<Context>k__BackingField` (EmCommonContext)

### app.ropeway.EnemyController
- Component on enemy GameObjects
- Backing fields: HateController, LoiteringController, Think, Sensor, CharacterController, MotionFsm, NaviMoveSupporter, StayAreaController, GroundFixer

---

## 11. Cross-Game Comparison (RE2 vs RE3)

| Feature | RE2 (app.ropeway) | RE3 (offline) |
|---------|-------------------|---------------|
| DynamicMotionBankContainer | app.ropeway.DynamicMotionBankContainer | offline.DynamicMotionBankContainer |
| DynamicMotionBankController | app.ropeway.DynamicMotionBankController | offline.DynamicMotionBankController |
| EnemyController | app.ropeway.EnemyController | offline.EnemyController |
| EnemyManager | app.ropeway.EnemyManager | offline.EnemyManager (via get_EnemyManager) |
| via.motion.Motion | Same (engine-level) | Same (engine-level) |
| via.motion.TreeLayer | Same (engine-level) | Same (engine-level) |
| Namespace resolver | sdk.game_namespace() | sdk.game_namespace() |
| Stalker enemy | Em6200 (Mr. X) | Em9000/Em9100 (Nemesis) |

The `via.motion.*` types are engine-level and identical across both games. The `app.ropeway.*` / `offline.*` types are game-specific wrappers but follow the same patterns.

---

## 12. Appendix: NowhereSafe.lua Key Patterns

This mod is the best reference for enemy enumeration and management. Key takeaways:

1. **Enemy enumeration**: `em["<EnemyList>k__BackingField"].mItems:get_elements()` (line 991)
2. **Enemy spawning/despawning**: `ctx:requestEnemyCreate()`, `ctx:requestEnemyDestroy()` (line 666)
3. **Component access**: `getC(gameobj, typename)` helper (line 160)
4. **Resource creation**: `sdk.create_resource(type, path):add_ref():create_holder(holderType):add_ref()` (line 204)
5. **Scene search**: `scene:call("findComponents(System.Type)", sdk.typeof(typename))` (line 277)
6. **FSM state reading**: `mfsm:getCurrentNodeName(0)` (line 639)
7. **Hooking enemy methods**: `sdk.hook(type_def:get_method(...), pre_fn, post_fn)` (line 1226)
8. **Physics controller**: `ec["<CharacterController>k__BackingField"]` for warp/movement (line 544)
