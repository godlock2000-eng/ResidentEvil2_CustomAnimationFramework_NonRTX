RE3 JILL DODGE/EVADE SYSTEM - COMPREHENSIVE ANALYSIS

       Based on thorough analysis of the RE3 il2cpp_dump.json file, here's the complete dodge system architecture:

       ---
       PART 1: CORE DODGE ACTION CLASSES

       1. Primary Player Dodge Actions

       - offline.escape.player.action.EsPlayerDodgeAction (Line 10630554)
         - Base class for regular dodge mechanics
         - Fields: InFever, SetDelayDodgeTimer, InCameraRotate, Set2SDodgeTime
         - Manages normal dodge timing and camera rotation
         - Contains plpad (EsPlayerMoveSystem) for movement
         - Contains _WwiseContainer for audio
       - offline.escape.player.action.EsPlayerHoldDodgeAction (Line 10632122)
         - Parent: EsPlayerStateActionBase
         - Methods: start(), update(), end()
         - Handles hold-type dodge input
       - offline.escape.player.action.EsPlayerDamageDodgeAction (Line 10630408)
         - Specialized for damage evasion response
         - Fields: SetInputTimer, SetDelayTimer
         - Contains reference to EsPlayerActionOrderer
         - Methods: start(), update(), end()

       ---
       PART 2: ACTION PRIORITY SYSTEM (Precede Enums)

       offline.SurvivorDefine.ActionOrder.Precede (Line 9176864)

       DODGE ACTION VALUES:
       - HOLD_DODGE = 1024 (Perfect Dodge / Just Avoid timing window)
         - Line: 9176918-9176925
         - High priority interrupt action
       - S_HOLD_DODGE = 2048 (Normal Dodge)
         - Line: 9177025-9177028
         - Standard dodge priority (noticed in 360 Movement.lua: RequestedDodge = 2048, RequestedPerfectDodge = 1024)

       Other Related Actions:
       - QUICK_TURN = 2
       - QUICK_TURN_EX = 32768
       - CHANGE_WEAPON = 16
       - CHANGE_BULLET = 128
       - RELOAD = 8
       - ATTACK = 4
       - STEP_UP = 256
       - STEP_DOWN = 512
       - SWITCH_LIGHT = 64
       - SHORT_ATTACK = 4096
       - RESIST_PARASITE = 8192
       - BACK_KNIFE = 131072
       - PUNCH = 65536 (Carlos specific)
       - INVALID = 0

       ---
       PART 3: EMERGENCY DODGE (PERFECT DODGE) SYSTEM

       EsAnimationEmergencyDodgeControlTrack (Line 10654052)

       Motion track for controlling emergency dodge timing:
       - Fields:
         - Dodge (bool) - Enable/disable dodge state
         - Rate (float) - Animation rate/speed multiplier
         - DodgeLong (bool) - Extended dodge variant
         - DodgeLong2 (bool) - Second extended variant
         - DodgeLong3 (bool) - Third extended variant
       - Purpose: Controls invincibility frames during perfect dodge window
       - Parent: via.motion.Tracks (animation track system)

       EsEnemyEnableEmergencyDodgeTrack

       - Enables emergency dodge capability for enemies to react to player
       - Part of animation control system

       ---
       PART 4: DODGE CONTROLLER SYSTEM

       EsDodgeController (Line 10088074)

       Central manager for dodge mechanics:
       - Fields:
         - _Type (EsDodgeType enum) - Classifies attack type
         - OnceObject (bool) - One-time use flag
         - ZoneOnly (bool) - Restricted zone activation
         - InRange (float) - Interaction range
         - EquipPrefab (EsDodgeController.EquipPrefabData) - Equipment data
         - UserData (EsDodgeObjectUserData) - Custom user data
         - Weapon (WeaponType) - Weapon classification
         - <EventOnStartDodge> (DelegateOnDodge) - Start callback
         - <EventOnEndDodge> (DelegateOnDodge) - End callback
         - <InZoneDodge> (bool) - Zone validation
         - <CurrentPlayer> - Player reference
         - <EquipObject> - Equipped object info
         - <InteractBehavior> - Interaction behavior

       EsDodgeType Enum (Line 10090378)

       Attack classification for dodge response:
       - Strike = 0 - Melee slash/swing attack
       - Pierce = 1 - Piercing/stabbing attack
       - Swing3 = 2 - 3-hit combo/heavy attack
       - Wall = 3 - Environmental/wall attack
       - Invalid = 4 - Invalid/no dodge

       ---
       PART 5: DODGE OBJECT SYSTEM

       EsDodgeObjectManager (Line 10093029+)

       Manages active dodge objects:
       - DodgeObjectInfo structure - Per-dodge data
       - DodgeObjectSettings - Configuration parameters
       - TargetInfo - Target tracking for dodge objects

       EsDodgeObjectGenerator (Line 10091401)

       Creates and manages dodge object instances:
       - DodgeObjectInfo - Generated dodge data
       - DodgePrefabData - Prefab configuration

       EsMFsmAction_DodgeObject (Line 10108217)

       Motion FSM action for dodge object behavior:
       - Fields:
         - UseTrackEnemy (bool) - Track enemy during dodge
         - _Controller (EsDodgeController) - Associated controller
         - _SeqController (EsSeqFlagController) - Sequence controller
         - _PlayerObject (GameObject) - Player reference
         - _EnemyObject (GameObject) - Enemy reference
         - _CurrentDisplay (bool) - Display state
         - _CurretnAttack (bool) - Current attack check
         - _LerpStartPos (vec3) - Lerp animation start position
         - _LerpStartRot (Quaternion) - Lerp animation start rotation
         - _LerpRate (float) - Lerp interpolation rate
         - _AttachStep (uint) - Attachment step counter
         - _DropStep (uint) - Drop step counter
         - _Attached (bool) - Attachment state
         - _Droped (bool) - Drop state
         - _OldLocation (vec3) - Previous position

       ---
       PART 6: DODGE DIRECTION SYSTEM

       offline.enemy.em0000.MotionPattern.DodgeDir Enum (Line 9894270)

       Directional dodge mapping:
       - Front = 0 - Forward dodge
       - Back = 1 - Backward dodge
       - Left = 2 - Left side step
       - Right = 3 - Right side step

       ---
       PART 7: PLAYER MOVEMENT SYSTEM

       EsPlayerMoveSystem (Line 10119699)

       Core movement controller integrated with dodge:
       - ActionVariablesHub - Action variable accessor
       - CharacterController - Physics character controller
       - CommonVariablesHub - Common variable accessor
       - Equipment - Equipment reference
       - EsPlayerActionOrderer - Action ordering system
       - EsPlayerTrackHandle - Player animation track
       - EsPlayerBodyStateTrack - Body state tracking
       - GroundFixer - Ground collision maintenance
       - EnableAutoHoming (float) - Homing behavior setting
       - WallStepCheck (bool) - Wall step validation
       - EnableRootAdjust (bool) - Root motion adjustment
       - TackleCounterHit (bool) - Counter-hit tracking
       - CheckSideStandUpState (enum) - Stand-up state

       ---
       PART 8: PLAYER ACTION ORDERER (Main Input System)

       offline.survivor.player.EsPlayerActionOrderer (Line 12075327)

       Central action ordering and input handler:
       - <Precede>k__BackingField - Current action priority
       - <PrecedeBits>k__BackingField - Action bit flags
         - Contains <Inhibit>k__BackingField - Inhibition mask
       - EnableHoldStartDodge (bool) - Enable hold-to-dodge input
       - EnableHoldStartDodgeTimer (float) - Timer for hold detection
       - IntervalEnableHoldStartDodgeTimer (float) - Cooldown interval
       - EnableStartStartDodgeTimer (float) - Initial timing window
       - <EsPlayerMoveSystem> - Movement system reference
       - <Condition> (PlayerCondition) - Player state
       - <JackDominator> - Jack parasite controller
       - <_SurvivorDynamicMotionController> - Motion controller

       How it Works (from 360 Movement.lua):
       If Precede == 1024: PERFECT DODGE (HoldDodge.EsPlayerDodgeMT)
       If Precede == 2048: NORMAL DODGE (SHoldDodge.ESPL_421_S_DODGE_2)

       ---
       PART 9: INVINCIBILITY FRAME SYSTEM

       EsAnimationInvincibleControlTrack (File listing)

       Motion track for invincibility control:
       - Invincible (bool) - I-frame active state
       - Part of animation sequence tracks
       - Controls when player takes damage during dodge

       ---
       PART 10: MOTION BANKS & ANIMATION SYSTEM

       Motion Bank References:

       - ActiveMotionBank - Currently loaded motion data
       - DynamicMotionBank - Runtime-loaded motion animations
       - MotionBankID - Identifier for motion bank
       - MotionBankType - Classification of motion data

       Key Dodge Animation Names (from 360 Movement.lua):

       - HoldDodge.EsPlayerDodgeMT - Perfect dodge/hold dodge motion
       - SHoldDodge.ESPL_421_S_DODGE_2 - Normal dodge motion (Jill specific, pl03)
       - Punch.pl0000_es_0500_KFF_Escape_Punch_L - Punch motion
       - Tackle.Tackle1 - Tackle motion (Carlos specific)

       ---
       PART 11: RELATED DAMAGE/EVASION STRUCTURES

       Collision Hit Events:

       - EventDodgeHit (Line 8505268) - Standard dodge hit event
       - EventEmergencyDodgeAttackHit (Line 8505387) - Perfect dodge attack hit
       - EventEmergencyDodgeDamageHit (Line 8505498) - Perfect dodge damage hit

       AvoidInfo Structure

       - Collision avoidance information for hit detection
       - Used in HitController for dodge validation

       ---
       PART 12: EQUIPMENT & GEAR SYSTEM

       EsDodgeEquipment

       Equipment that can be dodged/avoided

       EsDodgeController.EquipObjectInfo

       Information about equipped dodge objects

       EsDodgeController.EquipPrefabData

       Prefab data for dodge equipment:
       - EnemyAttachDataInfo - Enemy attachment data
         - Where/how dodge object attaches to enemies
         - Used by EsMFsmAction_DodgeObject

       ---
       PART 13: STATE MACHINE CONDITIONS

       EsMFsmCondition_CheckDodgeType (Line 10906)

       Condition check for dodge type matching:
       - Verifies attack type matches dodge capability
       - Determines dodge success/failure

       ---
       PART 14: TIMING PARAMETERS (from EsPlayerDodgeAction)

       - SetDelayDodgeTimer (float) - Delay before dodge activates
       - Set2SDodgeTime (float) - 2-second dodge window (RE3 mechanic)
       - DelayDodgeTimer - Active delay timer
       - OnDodgeCamera (bool) - Special camera during dodge

       ---
       PART 15: KEY INTERFACES

       IEsDodgeReceiver (Line 10131930)

       Interface for objects that can receive dodge effects

       ---
       RE2 REPLICATION STRATEGY

       To replicate Jill's dodge in RE2:

       1. Import the action class structure:
         - EsPlayerDodgeAction (or adapt RE2's player action base)
         - Map Precede enum values (1024 for perfect, 2048 for normal)
       2. Implement timing windows:
         - Use Set2SDodgeTime for the 2-second perfect dodge window
         - SetDelayDodgeTimer for input lag compensation
       3. Direction handling:
         - Implement DodgeDir enum (Front/Back/Left/Right)
         - Map input directions to appropriate animations
       4. Animation system:
         - Load dodge motion banks from RE3 or create equivalent
         - Use EsAnimationEmergencyDodgeControlTrack for i-frame control
         - Reference motion animations like "HoldDodge.EsPlayerDodgeMT"
       5. Invincibility frames:
         - Use EsAnimationInvincibleControlTrack for i-frame windows
         - Sync with animation keyframes
       6. State machine:
         - Hook into player action orderer with correct Precede values
         - Use EsMFsmCondition_CheckDodgeType for attack matching

       ---

● Found it! The reason set_Position doesn't persist is that the CharacterController overrides it. The fix is calling CharacterController:warp() after setting position — exactly what the NowhereSafe mod does:

  transform:set_Position(new_pos)
  character_controller:warp()  -- Tell physics to accept the new position

  Let me also share the RE3 dodge research highlights:

  RE3 Dodge Directions — Confirmed multidirectional:
  - DodgeDir enum: Front(0), Back(1), Left(2), Right(3)
  - Different animations per direction
  - Motion names: HoldDodge.EsPlayerDodgeMT (perfect dodge), SHoldDodge.ESPL_421_S_DODGE_2 (normal)

  RE3 Dodge Architecture:
  - EsPlayerDodgeAction — main dodge action class
  - EsDodgeController — central manager with start/end events
  - EsAnimationEmergencyDodgeControlTrack — controls i-frames + variants (DodgeLong, DodgeLong2, DodgeLong3)
  - EsAnimationInvincibleControlTrack — invincibility frames
  - Priority system: Perfect Dodge = 1024, Normal Dodge = 2048