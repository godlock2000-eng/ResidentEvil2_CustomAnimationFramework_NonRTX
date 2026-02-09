# RE Engine Animation Types Reference
## IL2CPP Type Dump Analysis: RE2 Remake vs RE3 Remake

**Source files**: RE2 `il2cpp_dump.json` / RE3 `il2cpp_dump.json`
**Date**: 2026-02-08

---

## Table of Contents

1. [Motion System (`via.motion`)](#1-motion-system)
2. [Joint/Transform System (`via.Joint`, `via.Transform`)](#2-jointtransform-system)
3. [Player Action System](#3-player-action-system)
4. [Resource Loading System](#4-resource-loading-system)
5. [Input System (`via.hid`)](#5-input-system)
6. [RE3 Dodge/Evade System (Source Reference)](#6-re3-dodgeevade-system)
7. [Cross-Game Comparison Summary](#7-cross-game-comparison-summary)

---

## 1. Motion System

### 1.1 `via.motion.Motion`

**Availability**: Both RE2 and RE3 (identical method signatures)
**Inheritance**: `via.Object` > `System.Object` > `via.Component` > `via.motion.Animation` > `via.motion.Motion`
**FQN**: `f829f958` (same in both games)

This is the primary animation component attached to GameObjects. It manages motion banks, layers, joints, and animation playback.

#### Key Methods

| Method | Return Type | Parameters | Notes |
|--------|-------------|------------|-------|
| `getLayer(no)` | `via.motion.TreeLayer` | `no: System.UInt32` | Get animation layer by index |
| `getLayerCount()` | `System.UInt32` | none | Total layer count |
| `getMotionBank(no)` | `via.motion.MotionBank` | `no: System.UInt32` | Get motion bank by index |
| `getMotionBankCount()` | `System.UInt32` | none | Total motion bank count |
| `getMotionCount(bankId)` | `System.UInt32` | `bankId: System.UInt32` | Motions in a bank |
| `getMotionInfo(bankId, motionId, dest)` | `System.Boolean` | `bankId: UInt32, motionId: UInt32, dest: via.motion.MotionInfo` | Populate MotionInfo struct |
| `getMotionInfo(bankId, bankType, motionId, dest)` | `System.Boolean` | `bankId: UInt32, bankType: Int32, motionId: UInt32, dest: MotionInfo` | Overload with bankType |
| `getMotionInfoByIndex(bankId, index, dest)` | `System.Boolean` | `bankId: UInt32, index: UInt32, dest: MotionInfo` | By sequential index |
| `getDynamicMotionBank(idx)` | `via.motion.DynamicMotionBank` | `idx: System.Int32` | Get dynamic bank by index |
| `getDynamicMotionBankCount()` | `System.Int32` | none | Number of dynamic banks |
| `setDynamicMotionBank(idx, bank)` | `System.Void` | `idx: Int32, bank: DynamicMotionBank` | **Set a dynamic motion bank** |
| `setDynamicMotionBankCount(count)` | `System.Void` | `count: Int32` | **Resize dynamic bank array** |
| `findMotionBank(bankId)` | `via.motion.MotionBank` | `bankId: System.UInt32` | Find bank by ID |
| `findMotionBank(bankId, bankType)` | `via.motion.MotionBank` | `bankId: UInt32, bankType: UInt32` | Find with bank type |
| `findMotionBankByNameHash(motlistNameHash)` | `via.motion.MotionBank` | `motlistNameHash: UInt32` | Find by name hash |
| `getActiveMotionBank(no)` | `via.motion.MotionBank` | `no: System.UInt32` | Active bank by index |
| `getActiveMotionBankCount()` | `System.UInt32` | none | Count of active banks |
| `changeMotionBankSize(size)` | `System.Void` | `size: System.UInt32` | Resize motion bank array |
| `getLocalPosition(idx)` | `via.vec3` | `idx: System.Int32` | Joint local position |
| `getLocalRotation(idx)` | `via.Quaternion` | `idx: System.Int32` | Joint local rotation |
| `getLocalScale(idx)` | `via.vec3` | `idx: System.Int32` | Joint local scale |
| `getLocalMatrix(idx)` | `via.mat4` | `idx: System.Int32` | Full local matrix |
| `getCalculatedLocalPosition(idx)` | `via.vec3` | `idx: System.Int32` | Post-calculation position |
| `getCalculatedLocalRotation(idx)` | `via.Quaternion` | `idx: System.Int32` | Post-calculation rotation |
| `getWorldPosition(idx)` | `via.vec3` | `idx: System.Int32` | World-space position |
| `getWorldRotation(idx)` | `via.Quaternion` | `idx: System.Int32` | World-space rotation |
| `getWorldMatrix(idx)` | `via.mat4` | `idx: System.Int32` | World-space matrix |
| `getWorldPositionWithoutRoot(idx)` | `via.vec3` | `idx: System.Int32` | Without root transform |
| `getWorldRotationWithoutRoot(idx)` | `via.Quaternion` | `idx: System.Int32` | Without root transform |
| `getJointIndexByNameHash(name_hash)` | `System.Int32` | `name_hash: System.UInt32` | Resolve joint by hash |
| `getJointNameHashByIndex(idx)` | `System.UInt32` | `idx: System.Int32` | Get hash from index |
| `getParentJointIndex(idx)` | `System.Int32` | `idx: System.Int32` | Parent joint index |
| `getParentJointIndexByNameHash(name_hash)` | `System.Int32` | `name_hash: UInt32` | Parent by name hash |
| `getPrivateLayer(no)` | `via.motion.TreeLayer` | `no: System.UInt32` | Private layer access |
| `getPrivateLayerCount()` | `System.UInt32` | none | Private layer count |
| `getMotionListPathForTool(bankId)` | `System.String` | `bankId: UInt32` | Motlist path string |
| `getJointAnimationRate(idx)` | `via.vec3` | `idx: Int32` | Joint anim blend rate |
| `getJointBlendRate(idx)` | `via.vec3` | `idx: Int32` | Joint blend rate |
| `getBlendedLastLayerNoByJointIndex(jointIndex)` | `System.Int32` | `jointIndex: Int32` | Last blended layer |
| `registerExpression(expr)` | `System.Void` | varies (2 overloads) | Register motion expression |
| `unregisterExpression(expr)` | `System.Void` | varies | Unregister expression |
| `clearDeformer()` | `System.Void` | none | Clear deformer state |
| `copyToDeformValues(tbl)` | `System.Void` | `tbl: Single[]` | Copy deform values |

#### Key Properties (get_/set_)

| Property | Type | Access | Notes |
|----------|------|--------|-------|
| `JointCount` | `System.Int32` | get | Total joint count |
| `AnimatedJointCount` | `System.UInt32` | get | Animated joints only |
| `JointsConstructed` | `System.Boolean` | get | Whether joints are built |
| `MotionBankAsset` | `via.motion.MotionBankResourceHolder` | get | The motion bank resource |
| `RootMotion` | `via.motion.RootPlayMode` | get | Root motion mode |
| `RootMotionRotation` | `via.Quaternion` | get | Root motion rotation |
| `DeformValues` | `System.Single[]` | get | Deform values array |
| `Layer` | `WrappedArrayContainer_Layer` | get | Layer array wrapper |
| `PrivateLayer` | `WrappedArrayContainer_PrivateLayer` | get | Private layer wrapper |
| `DynamicMotionBank` | `WrappedArrayContainer_DynamicMotionBank` | get | Dynamic bank wrapper |
| `ActiveMotionBank` | `WrappedArrayContainer_ActiveMotionBank` | get | Active bank wrapper |
| `EmptyMotionID` | `System.UInt32` | get (static) | The empty/null motion ID |
| `JointMap` | `via.motion.JointMapResourceHolder` | get | Joint map resource |
| `HasUserVariables` | `System.Boolean` | get | Has user variables |
| `ExpressionLOD` | `System.UInt32` | get/set | Expression LOD level |
| `JointsConstructedEvent` | delegate | get | Joints constructed callback |
| `LayerUpdatedEvent` | delegate | get | Layer updated callback |
| `EnabledConstraints` | `System.Boolean` | get/set (virtual) | Constraints toggle |
| `EnabledJointExpression` | `System.Boolean` | get/set (virtual) | Joint expression toggle |
| `AnyLayerReseted` | `System.Boolean` | get | Any layer was reset |
| `ApplyRootOnly` | `System.Boolean` | get/set | Apply root motion only |

#### RE3-Only Methods (not in RE2)

| Method | Return Type | Parameters | Notes |
|--------|-------------|------------|-------|
| `continueMotionOnSeparateLayer(...)` | `via.motion.TreeLayer` | `srcLayerNo: UInt32, dstLayerNo: UInt32, jointMaskId: UInt32, curve: InterpolationCurve, speed: Single, autoTimeOut: Single` | **RE3 ONLY** - Continues motion on a separate layer with joint masking. Critical for dodge system. |

#### RE3-Only Properties

| Property | Type | Notes |
|----------|------|-------|
| `HasJointMap` | `System.Boolean` | RE3 only |
| `JointLODGroup` | `via.motion.JointLODGroupResourceHolder` | RE3 only |
| `JointLODGroupLevel` | `via.motion.EJointLODGroupLevel` | RE3 only |

---

### 1.2 `via.motion.TreeLayer`

**Availability**: Both RE2 and RE3 (identical structure)
**Inheritance**: `via.Object` > `System.Object` > `via.motion.TreeLayer`
**FQN**: `e56de1d9` (same in both games)

TreeLayer represents a single animation layer within the Motion component. Layers are used for blending, overlays, and multi-track animation playback.

#### Key Methods

| Method | Return Type | Parameters | Notes |
|--------|-------------|------------|-------|
| `changeMotion(bankID, motionID, startFrame, interFrame, interMode, interCurve)` | `System.Void` | `bankID: UInt32, motionID: UInt32, startFrame: Single, interFrame: Single, interMode: InterpolationMode, interCurve: InterpolationCurve` | **PRIMARY METHOD** - Change the playing motion on this layer |
| `changeSequencePhase(phase)` | `System.Void` | `phase: via.motion.SequencePhase` | Change sequence phase |
| `clearContinueElapsedFrame()` | `System.Void` | none | Clear elapsed frame counter |
| `clearControlledByClip()` | `System.Void` | none | Clear clip control state |
| `clearMotionResource()` | `System.Void` | none | Clear motion resource |
| `clearNextAdjustInterpolation()` | `System.Void` | none | Clear interpolation adjust |
| `copyFrom(ptr)` | `System.Void` | `ptr: via.motion.TreeLayer` | Copy from another layer |
| `copyToDeformValues(weight_tbl)` | `System.Void` | `weight_tbl: Single[]` | Copy deform weights |
| `getHighestWeightMotionNodeByTag(tag)` | `via.motion.MotionNodeCtrl` | `tag: String` or `tag_hash: UInt32` | Find motion node by tag |
| `getJointBlendRate(idx)` | `via.vec3` | `idx: Int32` | Joint blend rate |
| `getJointIndexByNameHash(name_hash)` | `System.Int32` | `name_hash: UInt32` | Joint index lookup |
| `getLocalMatrix(idx)` | `via.mat4` | `idx: Int32` | Layer-local matrix |
| `getLocalPosition(idx)` | `via.vec3` | `idx: Int32` | Layer-local position |
| `getLocalRotation(idx)` | `via.Quaternion` | `idx: Int32` | Layer-local rotation |
| `getLocalScale(idx)` | `via.vec3` | `idx: Int32` | Layer-local scale |
| `getMotionNode(index)` | `via.motion.MotionNodeCtrl` | `index: UInt32` | Get motion node |
| `getMotionNodeByNameHash(hash)` | `via.motion.MotionNodeCtrl` | `hash: UInt32` | Get motion node by hash |
| `getMotionNodeCount()` | `System.UInt32` | none | Motion node count |
| `getRawMotionNode(index)` | `via.motion.MotionNodeCtrl` | `index: UInt32` | Raw motion node |
| `getRawMotionNodeCount()` | `System.UInt32` | none | Raw node count |
| `getSolverEndFrame(n)` | `System.Single` | `n: UInt32` | Solver end frame |
| `getSolverFrame(n)` | `System.Single` | `n: UInt32` | Solver current frame |
| `getSolverMirror(n)` | `System.Boolean` | `n: UInt32` | Solver mirror flag |
| `getSolverSpeed(n)` | `System.Single` | `n: UInt32` | Solver speed |
| `getSolverWrapMode(n)` | `via.motion.WrapMode` | `n: UInt32` | Solver wrap mode |
| `getWorldMatrix(idx)` | `via.mat4` | `idx: Int32` | World matrix |
| `getWorldPosition(idx)` | `via.vec3` | `idx: Int32` | World position |
| `getWorldRotation(idx)` | `via.Quaternion` | `idx: Int32` | World rotation |
| `getTagNameHash(index)` | `System.UInt32` | `index: UInt64` | Tag name hash |
| `setLocalPosition(idx, pos)` | `System.Void` | `idx: Int32, pos: via.vec3` | **Set** layer-local position |
| `setLocalRotation(idx, rot)` | `System.Void` | `idx: Int32, rot: via.Quaternion` | **Set** layer-local rotation |
| `setLocalScale(idx, scale)` | `System.Void` | `idx: Int32, scale: via.vec3` | **Set** layer-local scale |
| `setJointBlendRate(idx, blend)` | `System.Void` | `idx: Int32, blend: via.vec3` | Set joint blend rate |
| `setJointGroup(joint_hash, group)` | `System.Boolean` | `joint_hash: UInt32, group: JointGroup` | Assign joint to group |
| `setSolverFrame(n, frame)` | `System.Void` | `n: UInt32, frame: Single` | Set solver frame |
| `setSolverMirror(n, flag)` | `System.Void` | `n: UInt32, flag: Boolean` | Set mirror state |
| `setSolverSpeed(n, speed)` | `System.Void` | `n: UInt32, speed: Single` | Set solver speed |
| `setOverwriteFrame(frame)` | `System.Void` | `frame: Single` | Force frame override |
| `setContinueElapsedFrame(frame)` | `System.Void` | `frame: Single` | Set elapsed frame |
| `setContinueExitFrame(frame)` | `System.Void` | `frame: Single` | Set exit frame |
| `privateSetup()` | `System.Void` | none | Internal setup |
| `privateUpdate(add_frame)` | `System.Void` | `add_frame: Single` | Internal update |
| `resetFrame()` | `System.Void` | none | Reset to frame 0 |
| `isPositionAnimated(idx)` | `System.Boolean` | `idx: Int32` | Is position animated |
| `isRotationAnimated(idx)` | `System.Boolean` | `idx: Int32` | Is rotation animated |
| `isScaleAnimated(idx)` | `System.Boolean` | `idx: Int32` | Is scale animated |
| `isExtendInterpolationEnabled(group)` | `System.Boolean` | `group: JointGroup` | Extended interp check |
| `isJointAnimationDisabled(nameHash)` | `System.Boolean` | `nameHash: UInt32` | Is joint disabled |
| `setExtendInterpolationEnable(group, flag)` | `System.Void` | `group: JointGroup, flag: Boolean` | Toggle extended interp |
| `setExtendInterpolationSetting(group, start, interpolation, curve)` | `System.Void` | `group: JointGroup, start: Single, interpolation: Single, curve: InterpolationCurve` | Configure extended interp |

#### Key Properties (get_/set_)

| Property | Type | Access | Notes |
|----------|------|--------|-------|
| `Frame` | `System.Single` | get | **Current animation frame** |
| `EndFrame` | `System.Single` | get | **End frame of current motion** |
| `Speed` | `System.Single` | get | **Playback speed** |
| `WrapMode` | `via.motion.WrapMode` | get | **Wrap/loop mode** |
| `MotionBankID` | `System.UInt32` | get | **Current bank ID** |
| `MotionID` | `System.UInt32` | get | **Current motion ID** |
| `MotionBankType` | `System.Int32` | get | Bank type |
| `LocalBankType` | `System.Int32` | get | Local bank type |
| `MotionTagHash` | `System.UInt32` | get | Motion tag hash |
| `JointMaskID` | `System.UInt32` | get | Joint mask ID |
| `ActiveJointMaskID` | `System.UInt32` | get | Active joint mask |
| `LayerNo` | `System.UInt32` | get | Layer number |
| `BaseLayerNo` | `System.UInt32` | get | Base layer number |
| `BlendMode` | `via.motion.BlendMode` | get | Blend mode |
| `BlendRate` | `System.Single` | get | Blend rate (0-1) |
| `HighestWeightMotionNode` | `via.motion.MotionNodeCtrl` | get | Highest-weight node |
| `MotionState` | `via.motion.MotionStateFlag` | get | Current motion state |
| `Loop` | `System.Boolean` | get | Is looping |
| `Running` | `System.Boolean` | get | Is running |
| `Idling` | `System.Boolean` | get | Is idling |
| `StopUpdate` | `System.Boolean` | get | Update stopped |
| `Interpolating` | `System.Boolean` | get | Is interpolating |
| `AnyExtendInterpolating` | `System.Boolean` | get | Extended interp active |
| `StateEndOfMotion` | `System.Boolean` | get | At end of motion |
| `StateNextEndOfMotion` | `System.Boolean` | get | Next will be end |
| `StateEndOrNextEndOfMotion` | `System.Boolean` | get | At or near end |
| `PrevStateEndOfMotion` | `System.Boolean` | get | Previous was end |
| `Private` | `System.Boolean` | get | Is private layer |
| `Jacked` | `System.Boolean` | get | Is jacked |
| `JackFrom` | `via.GameObject` | get | Jack source object |
| `MirrorSymmetry` | `System.Boolean` | get | Mirror symmetry |
| `InterpolationMode` | `via.motion.InterpolationMode` | get | Interpolation mode |
| `InterpolationCurve` | `via.motion.InterpolationCurve` | get | Interpolation curve |
| `InterpolationFrame` | `System.Single` | get | Interpolation frame |
| `InterpolationRate` | `System.Single` | get | Interpolation rate |
| `InterpolationCountDownFrame` | `System.Single` | get | Countdown frames |
| `TransitionState` | `via.motion.TransitionState` | get | Transition state |
| `Resource` | `via.motion.MotionBaseResourceHolder` | get | Resource holder |
| `TreeEmpty` | `System.Boolean` | get | Is tree empty |
| `TreeNodeCount` | `System.UInt32` | get | Tree node count |
| `AnimatedJointCount` | `System.UInt32` | get | Animated joint count |
| `SequenceUpdateMode` | `via.motion.SequenceUpdateMode` | get | Sequence update mode |
| `RootOnly` | `System.Boolean` | get | Root only mode |
| `SyncTime` | `System.Single` | get | Sync time |
| `LocalAddFrame` | `System.Single` | get | Local add frame |
| `EndOffsetFrame` | `System.Single` | get | End offset frame |

---

### 1.3 `via.motion.DynamicMotionBank`

**Availability**: Both RE2 and RE3 (identical)
**Inheritance**: `via.Object` > `System.Object` > `via.motion.DynamicMotionBank`

DynamicMotionBank allows runtime addition/swapping of motion banks on a Motion component. This is the key mechanism for adding dodge animations at runtime.

#### Methods

| Method | Return Type | Parameters | Notes |
|--------|-------------|------------|-------|
| `hasMotion(bankId, motionId, bankType)` | `System.Boolean` | `bankId: UInt32, motionId: UInt32, bankType: Int32` | Check if motion exists |

#### Properties

| Property | Type | Access | Notes |
|----------|------|--------|-------|
| `MotionBank` | `via.motion.MotionBankResourceHolder` | get/set | **The resource holder** |
| `Priority` | `System.Int32` | get/set | Priority order |
| `Order` | `System.Int32` | get/set | Sort order |
| `BankType` | `System.UInt32` | get/set | Bank type ID |
| `OverwriteBankType` | `System.Boolean` | get/set | Override bank type flag |
| `BankTypeMaskBit` | `System.UInt32` | get/set | Bank type mask |
| `OverwriteBankTypeMaskBit` | `System.Boolean` | get/set | Override mask flag |

---

### 1.4 `via.motion.MotionBank`

**Availability**: Both RE2 and RE3 (identical)
**Inheritance**: `via.Object` > `System.Object` > `via.motion.MotionBank`
**FQN**: `d36cbdc7`

Represents a loaded motion bank containing motion list references and bank identification.

#### Properties

| Property | Type | Access | Notes |
|----------|------|--------|-------|
| `BankID` | `System.UInt32` | get/set | Bank identifier |
| `BankType` | `System.UInt32` | get | Bank type |
| `BankTypeMaskBit` | `System.UInt32` | get | Type mask |
| `MotionList` | `via.motion.MotionListBaseResourceHolder` | get | **Motion list resource** |
| `TargetMotionList` | `via.motion.MotionListBaseResourceHolder` | get | Target motion list |
| `ExternMotionBank` | `via.motion.MotionBank` | get | External bank ref |
| `Name` | `System.String` | get | Bank name |
| `NameHash` | `System.UInt32` | get | Bank name hash |
| `HasExternBank` | `System.Boolean` | get | Has external bank |

---

### 1.5 `via.motion.MotionBankResourceHolder`

**Availability**: Both RE2 and RE3 (identical)
**Inheritance**: `via.Object` > `System.Object` > `via.ResourceHolder` > `via.motion.MotionBankBaseResourceHolder` > `via.motion.MotionBankResourceHolder`
**FQN**: `31cfd337`

This is the resource holder that wraps .motbank files. It inherits from `via.ResourceHolder` which provides the standard resource loading interface.

**Note**: The class itself has no additional methods beyond the constructor. All resource loading is handled through the base `via.ResourceHolder` methods: `get_Resource()`, `set_Resource()`, `get_Ready()`, etc.

---

### 1.6 `via.motion.MotionInfo`

**Availability**: Both RE2 and RE3 (identical)
**Inheritance**: `via.Object` > `System.Object` > `via.motion.MotionInfo`
**FQN**: `14ae6ef7`

A data container populated by `Motion.getMotionInfo()` to retrieve animation metadata.

#### Key Methods

| Method | Return Type | Parameters | Notes |
|--------|-------------|------------|-------|
| `clear()` | `System.Void` | none | Reset the info |
| `getAnimationTransform(jointNameHash, frame, animationTransform)` | `System.Boolean` | `jointNameHash: UInt32, frame: Single, animationTransform: AnimationTransformData` | Get transform at frame |
| `getAnimationTransformAmount(jointNameHash, startFrame, endFrame, animationTransform)` | `System.Boolean` | `jointNameHash: UInt32, startFrame: Single, endFrame: Single, animationTransform: AnimationTransformData` | Get transform delta |
| `getAnimationTransformAmountStartToEnd(jointNameHash, animationTransform)` | `System.Boolean` | `jointNameHash: UInt32, animationTransform: AnimationTransformData` | Full range delta |
| `getAnimationTransformAmountStartToFrame(jointNameHash, frame, animationTransform)` | `System.Boolean` | `jointNameHash: UInt32, frame: Single, animationTransform: AnimationTransformData` | Start to frame delta |
| `getAnimationTransformLocalAmount(...)` | `System.Boolean` | similar params | Local-space delta |

---

### 1.7 `via.motion.MotionFsm2`

**Availability**: Both RE2 and RE3
**Inheritance**: `via.Object` > `System.Object` > `via.Component` > `via.motion.Animation` > `via.motion.Motion` > `via.motion.MotionFsm2`

MotionFsm2 extends Motion with finite state machine capabilities. This is the typical component used for character animation in RE Engine games. It inherits all Motion methods and adds FSM-specific layer management.

---

## 2. Joint/Transform System

### 2.1 `via.Joint`

**Availability**: Both RE2 and RE3 (identical)
**Inheritance**: `via.Object` > `System.Object` > `via.Joint`
**FQN**: `89469ea4`

Represents a single joint (bone) in the skeleton hierarchy.

#### Key Methods

| Method | Return Type | Parameters | Notes |
|--------|-------------|------------|-------|
| `lookAt(target, up)` | `System.Void` | `target: via.vec3, up: via.vec3` | Orient joint toward target |
| `ToString()` | `System.String` | none (virtual) | String representation |
| `op_Equality(x, y)` | `System.Boolean` | `x: Joint, y: Joint` (static) | Equality check |
| `op_Inequality(x, y)` | `System.Boolean` | `x: Joint, y: Joint` (static) | Inequality check |
| `op_Implicit(obj)` | `System.Boolean` | `obj: Joint` (static) | Null check (bool cast) |

#### Properties

| Property | Type | Access | Notes |
|----------|------|--------|-------|
| `Name` | `System.String` | get | Joint name |
| `NameHash` | `System.UInt32` | get | Joint name hash (murmur) |
| `LocalPosition` | `via.vec3` | get/set | Local-space position |
| `LocalRotation` | `via.Quaternion` | get/set | Local-space rotation |
| `LocalScale` | `via.vec3` | get/set | Local-space scale |
| `LocalEulerAngle` | `via.vec3` | get/set | Local euler angles |
| `LocalMatrix` | `via.mat4` | get | Local transform matrix |
| `Position` | `via.vec3` | get/set | World-space position |
| `Rotation` | `via.Quaternion` | get/set | World-space rotation |
| `EulerAngle` | `via.vec3` | get/set | World euler angles |
| `WorldMatrix` | `via.mat4` | get | World transform matrix |
| `AxisX` | `via.vec3` | get | Local X axis |
| `AxisY` | `via.vec3` | get | Local Y axis |
| `AxisZ` | `via.vec3` | get | Local Z axis |
| `Parent` | `via.Joint` | get | Parent joint |
| `Symmetry` | `via.Joint` | get | Mirror/symmetry joint |
| `ConstraintJoint` | `via.Joint` | get | Constraint target |
| `BaseLocalPosition` | `via.vec3` | get | Base (bind) position |
| `BaseLocalRotation` | `via.Quaternion` | get | Base (bind) rotation |
| `BaseLocalScale` | `via.vec3` | get | Base (bind) scale |
| `Owner` | `via.Transform` | get | Owning Transform component |
| `Valid` | `System.Boolean` | get | Is joint valid |

---

### 2.2 `via.Transform`

**Availability**: Both RE2 and RE3 (identical)
**Inheritance**: `via.Object` > `System.Object` > `via.Component` > `via.Transform`
**FQN**: `dfac3046`

The Transform component holds the skeleton and provides joint access.

#### Key Methods

| Method | Return Type | Parameters | Notes |
|--------|-------------|------------|-------|
| `getJointByHash(nameHash)` | `via.Joint` | `nameHash: System.UInt32` | Find joint by name hash |
| `getJointByName(nameStr)` | `via.Joint` | `nameStr: System.String` | Find joint by name string |
| `find(pathStr)` | `via.Transform` | `pathStr: System.String` | Find child transform by path |
| `copyJointsLocalMatrix(source)` | `System.Void` | `source: via.Transform` | Copy all joint matrices |
| `lookAt(target, up)` | `System.Void` | `target: via.vec3, up: via.vec3` | Orient transform |

#### Properties

| Property | Type | Access | Notes |
|----------|------|--------|-------|
| `Joints` | `via.Joint[]` | get | **All joints array** |
| `LocalPosition` | `via.vec3` | get/set | Local position |
| `LocalRotation` | `via.Quaternion` | get/set | Local rotation |
| `LocalScale` | `via.vec3` | get/set | Local scale |
| `LocalEulerAngle` | `via.vec3` | get/set | Local euler angles |
| `LocalMatrix` | `via.mat4` | get | Local matrix |
| `Position` | `via.vec3` | get/set | World position |
| `Rotation` | `via.Quaternion` | get/set | World rotation |
| `Scale` | `via.vec3` | get/set | World scale |
| `EulerAngle` | `via.vec3` | get/set | World euler |
| `WorldMatrix` | `via.mat4` | get | World matrix |
| `Parent` | `via.Transform` | get/set | Parent transform |
| `Child` | `via.Transform` | get (private) | First child |
| `Next` | `via.Transform` | get (private) | Next sibling |
| `Root` | `via.Transform` | get | Root transform |
| `Children` | `IEnumerable<via.Transform>` | get | Children iterator |
| `ParentJoint` | `System.String` | get | Parent joint name |
| `AxisX/Y/Z` | `via.vec3` | get | Local axes |
| `SameJointsConstraint` | `System.Boolean` | get/set | Same joints constraint |
| `AbsoluteScaling` | `System.Boolean` | get/set | Absolute scaling mode |

---

## 3. Player Action System

### 3.1 RE2: `app.ropeway.PlayerManager`

**Availability**: RE2 only
**Inheritance**: Extends a managed behavior
**FQN**: `7b4a4cb6`

#### Key Fields

| Field | Type | Notes |
|-------|------|-------|
| `PlayerList` | `List<app.ropeway.survivor.player.PlayerCondition>` | All active player conditions |
| `CurrentPlayerCOG` | `via.Joint` | Current player center-of-gravity joint |
| `TotalMovingDistance` | `System.Single` | Total distance moved |
| `Pedometer` | `System.Int32` | Step counter |
| `DamagedNumber` | `System.Int32` | Damage counter |
| `CounterAttackNumber` | `System.Int32` | Counter attack counter |
| `UseWeapons` | `HashSet<app.ropeway.EquipmentDefine.WeaponType>` | Used weapon types |

#### Key Methods

| Method | Notes |
|--------|-------|
| `addCounterAttackNumber(Number)` | Increment counter attacks |
| `addDamagedNumber(Number)` | Increment damage count |
| `addPedometer(Step)` | Increment step count |
| `addTotalMovingDistance(MovingDistance)` | Add to distance |

#### Related RE2 Types

- `app.ropeway.survivor.player.PlayerCondition` - Player state/condition
- `app.ropeway.player.tag.ControlAttribute` - Control state attributes
- `app.ropeway.player.tag.StateAttribute` - Player state attributes
- `app.ropeway.player.tag.LookAtAttribute` - Look-at behavior attributes
- `app.ropeway.player.tag.WaterResistanceAttribute` - Water resistance
- `app.ropeway.EquipmentDefine.WeaponType` - Weapon type enum

### 3.2 RE3: `offline.PlayerManager`

**Availability**: RE3 only
**Inheritance**: Same structure as RE2 equivalent
**FQN**: `937db414`

#### Key Fields (structurally identical to RE2)

| Field | Type | Notes |
|-------|------|-------|
| `PlayerList` | `List<offline.survivor.player.PlayerCondition>` | All active player conditions |
| `CurrentPlayerCOG` | `via.Joint` | Current player COG joint |
| `TotalMovingDistance` | `System.Single` | Total distance |
| `Pedometer` | `System.Int32` | Step count |
| `DamagedNumber` | `System.Int32` | Damage count |
| `CounterAttackNumber` | `System.Int32` | Counter attacks |
| `UseWeapons` | `HashSet<offline.EquipmentDefine.WeaponType>` | Used weapons |

#### Related RE3 Types

- `offline.survivor.player.PlayerCondition` - Player state/condition
- `offline.player.tag.ControlAttribute` - Control attributes (uses UInt64 vs RE2's UInt32)
- `offline.player.tag.StateAttribute` - State attributes
- `offline.player.tag.LookAtAttribute` - Look-at attributes
- `offline.player.tag.WaterResistanceAttribute` - Water resistance

---

## 4. Resource Loading System

### 4.1 Resource Holder Hierarchy

The RE Engine uses a resource holder pattern. The hierarchy for motion resources is:

```
via.ResourceHolder (base - provides get_Resource, set_Resource, get_Ready, etc.)
  +-- via.motion.MotionBankBaseResourceHolder
  |     +-- via.motion.MotionBankResourceHolder (wraps .motbank files)
  +-- via.motion.MotionBaseResourceHolder (wraps .mot files)
  +-- via.motion.MotionListBaseResourceHolder (wraps .motlist files)
  +-- via.motion.JointMapResourceHolder (wraps joint map data)
  +-- via.motion.JointLODGroupResourceHolder (RE3 only - LOD groups)
```

### 4.2 How Motion Banks Load

1. A `via.motion.MotionBankResourceHolder` is assigned to a `DynamicMotionBank.MotionBank` property
2. The resource holder wraps a `.motbank` file reference
3. `.motbank` files contain references to `.motlist` files, which in turn reference `.mot` animation files
4. When assigned to a `DynamicMotionBank`, the engine resolves and loads the resources
5. Motions become accessible via `Motion.getMotionBank()` / `Motion.findMotionBank()`

### 4.3 Loading via REFramework Lua

In REFramework Lua, resources can be created with:
```lua
-- Create a resource holder
local resource = sdk.create_instance("via.motion.MotionBankResourceHolder")
-- Access the resource field
resource:call("set_Resource", sdk.create_resource("via.motion.MotionBankResource", "path/to/file.motbank"))
```

The engine manages the actual file loading asynchronously. Check `get_Ready()` to know when loading completes.

---

## 5. Input System

### 5.1 `via.hid.GamePadDevice`

**Availability**: Both RE2 and RE3 (identical)
**Inheritance**: `via.Object` > `System.Object` > `via.hid.NativeDeviceBase` > `via.hid.GamePadDevice`

The primary gamepad interface for reading controller input.

#### Key Properties

| Property | Type | Access | Notes |
|----------|------|--------|-------|
| `Button` | `via.hid.GamePadButton` | get | **Currently held buttons** (bitmask) |
| `ButtonDown` | `via.hid.GamePadButton` | get | **Just-pressed buttons** (bitmask, this frame) |
| `ButtonUp` | `via.hid.GamePadButton` | get | **Just-released buttons** (bitmask, this frame) |
| `AxisL` | `via.vec2` | get | Left stick (processed, deadzone applied) |
| `AxisR` | `via.vec2` | get | Right stick (processed) |
| `RawAxisL` | `via.vec2` | get | Left stick (raw) |
| `RawAxisR` | `via.vec2` | get | Right stick (raw) |
| `AnalogL` | `System.Single` | get | Left trigger analog |
| `AnalogR` | `System.Single` | get | Right trigger analog |
| `Acceleration` | `via.vec3` | get | Accelerometer |
| `AngularVelocity` | `via.vec3` | get | Gyroscope |
| `Orientation` | `via.Quaternion` | get | Controller orientation |
| `AsyncBufferedState` | `via.hid.GamePadState[]` | get | Buffered input states |
| `HijackMode` | `System.Boolean` | get/set | Input hijack mode |
| `EnableReleaseHijackVirtualByKeyPress` | `System.Boolean` | get/set | Auto-release hijack |
| `EnableUpdateEnterCancelButton` | `System.Boolean` | get/set | Update enter/cancel |

#### Key Methods

| Method | Return Type | Parameters | Notes |
|--------|-------------|------------|-------|
| `clear()` | `System.Void` | none (virtual) | Clear input state |
| `getMotorPower(motor)` | `System.Single` | `motor: GamePadMotor` | Get vibration power |
| `makeNullDevice()` | `via.hid.GamePadDevice` | none (static) | Create null device |
| `resetMotors()` | `System.Void` | none (virtual) | Reset vibration |
| `resetOrientation()` | `System.Void` | none (virtual) | Reset orientation |

### 5.2 Detecting Input from Lua

To detect button presses in REFramework Lua:

```lua
-- Get the gamepad device
local padman = sdk.get_managed_singleton("via.hid.GamePadManager")
local device = padman:call("get_Device")  -- or get_MergedDevice

-- Check button state (via.hid.GamePadButton is a bitmask enum)
local button_down = device:call("get_ButtonDown")

-- Common button values (bitmask):
-- LStickPush, RStickPush, L1/LB, R1/RB, A/Cross, B/Circle, X/Square, Y/Triangle
-- DPadUp, DPadDown, DPadLeft, DPadRight, LTrigger, RTrigger, Start, Select
```

### 5.3 Related Input Types

| Type | Game | Notes |
|------|------|-------|
| `via.hid.GamePadButton` | Both | Button bitmask enum |
| `via.hid.GamePadMotor` | Both | Vibration motor enum |
| `via.hid.GamePadState` | Both | Full pad state snapshot |
| `via.hid.KeyboardDevice` | Both | Keyboard input |
| `via.hid.KeyboardKey` | Both | Key enum |
| `via.hid.MouseButton` | Both | Mouse button enum |
| `via.hid.DeviceKind` | Both | Device type enum |
| `via.hid.DeviceIndex` | Both | Device index |
| `via.hid.TouchInfo` | Both | Touch input |

---

## 6. RE3 Dodge/Evade System

### 6.1 Overview

RE3's dodge system is built around several interconnected systems that do not exist in RE2. Understanding these is critical for recreating the mechanic.

### 6.2 Key Dodge-Related Types (RE3 Only)

| Type | Category | Notes |
|------|----------|-------|
| `offline.escape.EsDodgeController` | Core | Main dodge controller |
| `offline.escape.EsDodgeController.EquipPrefabData` | Data | Equipment prefab data for dodge |
| `offline.escape.EsDodgeController.EquipPrefabData.EnemyAttachDataInfo` | Data | Enemy attachment info during dodge |
| `offline.escape.EsDodgeEquipment` | Equipment | Dodge equipment handler |
| `offline.escape.EsDodgeObjectGenerator` | Spawning | Generates dodge-related objects |
| `offline.escape.EsDodgeObjectGenerator.DodgeObjectInfo` | Data | Dodge object metadata |
| `offline.escape.EsDodgeObjectManager` | Management | Manages active dodge objects |
| `offline.escape.EsDodgeObjectManager.DodgeObjectInfo` | Data | Active dodge object info |
| `offline.escape.EsTrack_DodgeObject` | Tracking | Dodge object tracking |
| `offline.escape.tracks.EsAnimationEmergencyDodgeControlTrack` | Animation | **Emergency dodge animation track** |
| `offline.escape.tracks.EsEnemyEnableEmergencyDodgeTrack` | AI | Enemy-side dodge enable track |
| `offline.escape.enemy.common.fsmv2.action.EsDodgeObjectBranchTrack` | AI FSM | Dodge branching in enemy FSM |

### 6.3 Dodge-Related Properties Found

These properties appear on player/escape-related types:

| Property | Getter | Notes |
|----------|--------|-------|
| `IsDodge` | `get_IsDodge` | Whether player is in dodge state |
| `IsDodgeForceTwirler` | `get_IsDodgeForceTwirler` | Force twirler dodge active |
| `IsHoldDodge` | `get_IsHoldDodge` | Dodge button held |
| `IsKnifeDodgeHoldStart` | `get_IsKnifeDodgeHoldStart` | Knife dodge hold state |
| `DodgeForceTwirlerNoticePointPos` | `get_DodgeForceTwirlerNoticePointPos` | Twirler notice point |
| `Enable2SDodge` | `get_Enable2SDodge` | 2-second dodge window |
| `EnableDodgeCamera` | `get_EnableDodgeCamera` | Dodge camera enabled |
| `GetDisableDodgeStepAddtimeRate` | `get_GetDisableDodgeStepAddtimeRate` | Disable dodge step timing |
| `GetDodgeStepStartTime` | `get_GetDodgeStepStartTime` | Dodge step start time |
| `EmergencyDodge` | `get_EmergencyDodge` / `set_EmergencyDodge` | Emergency dodge flag |
| `SecondEnableEmergencyDodge` | `get/set` | Second window enable |
| `ThirdEnableEmergencyDodge` | `get/set` | Third window enable |
| `TrackEmergencyDodge` | `get/set` | Track-based dodge enable |
| `DisableEmergencyDodge` | field | Disable emergency dodge flag |
| `EXAM_EmergencyDodgeTimeRate` | `get_EXAM_EmergencyDodgeTimeRate` | Dodge timing rate parameter |

### 6.4 How RE3 Dodge Works (Architecture Summary)

Based on the type analysis:

1. **Input Detection**: The `IsDodge` / `IsHoldDodge` properties on the player condition detect when the dodge button is pressed during a vulnerability window.

2. **Emergency Dodge System**: The `EmergencyDodge` property and `EsAnimationEmergencyDodgeControlTrack` indicate a track-based system where enemy attack animations define windows (`EsEnemyEnableEmergencyDodgeTrack`) during which the player can trigger a dodge.

3. **Animation Control**: The dodge animation is played via `EsAnimationEmergencyDodgeControlTrack` which controls the motion layer, likely using the `changeMotion()` method on a `TreeLayer`.

4. **`continueMotionOnSeparateLayer()`**: This RE3-only method on `via.motion.Motion` is designed to continue a motion on a separate layer with joint masking, interpolation, and auto-timeout -- exactly the kind of operation needed for a dodge that interrupts and overlays normal movement.

5. **Object Management**: `EsDodgeObjectGenerator` and `EsDodgeObjectManager` handle any objects spawned during dodge sequences (effects, collision adjustments, etc.).

### 6.5 Key Differences for Porting to RE2

| Aspect | RE3 | RE2 | Porting Notes |
|--------|-----|-----|---------------|
| Namespace | `offline.*` | `app.ropeway.*` | All type prefixes differ |
| Player Condition | `offline.survivor.player.PlayerCondition` | `app.ropeway.survivor.player.PlayerCondition` | Same structure, different namespace |
| Control Attributes | Uses `UInt64` values | Uses `UInt32` values | Different attribute widths |
| `continueMotionOnSeparateLayer` | Present | **ABSENT** | Must be replicated via manual layer management |
| Dodge types | Full dodge system | None | Must be built from scratch |
| Emergency Dodge tracks | `EsAnimationEmergencyDodgeControlTrack` etc. | None | Must use hooks or Lua callbacks |
| Motion FSM | Same base (`via.motion.MotionFsm2`) | Same base | Animation layer system is identical |

---

## 7. Cross-Game Comparison Summary

### 7.1 Types Present in Both Games (Identical)

All `via.*` engine types share the same structure:

- `via.motion.Motion` (core methods identical, RE3 has `continueMotionOnSeparateLayer`)
- `via.motion.TreeLayer` (fully identical)
- `via.motion.DynamicMotionBank` (fully identical)
- `via.motion.MotionBank` (fully identical)
- `via.motion.MotionBankResourceHolder` (fully identical)
- `via.motion.MotionInfo` (fully identical)
- `via.motion.MotionFsm2` (fully identical base)
- `via.Joint` (fully identical)
- `via.Transform` (fully identical)
- `via.hid.GamePadDevice` (fully identical)
- All `via.motion.*` enums (WrapMode, BlendMode, InterpolationMode, InterpolationCurve, etc.)

### 7.2 Types Unique to RE3

- `offline.escape.EsDodgeController` and related dodge types
- `offline.escape.EsTrack_DodgeObject`
- `offline.escape.tracks.EsAnimationEmergencyDodgeControlTrack`
- `offline.escape.tracks.EsEnemyEnableEmergencyDodgeTrack`
- `via.motion.Motion.continueMotionOnSeparateLayer()` method
- `via.motion.JointLODGroupResourceHolder`
- `via.motion.EJointLODGroupLevel`

### 7.3 Types Unique to RE2

- `app.ropeway.*` namespace equivalents of `offline.*` types
- No dodge/evade system types exist

### 7.4 Critical Path for Dodge Implementation in RE2

Based on this analysis, implementing a dodge in RE2 requires:

1. **Motion Bank Loading**: Use `DynamicMotionBank` to load dodge animation `.motbank` files at runtime via `setDynamicMotionBank()` and `setDynamicMotionBankCount()`.

2. **Animation Playback**: Use `TreeLayer.changeMotion(bankID, motionID, startFrame, interFrame, interMode, interCurve)` to trigger the dodge animation on a layer.

3. **Layer Management**: Since RE2 lacks `continueMotionOnSeparateLayer()`, manually manage layers via `Motion.getLayer()`, control interpolation settings, and use `TreeLayer` set methods to blend.

4. **Input Detection**: Use `via.hid.GamePadDevice.get_ButtonDown()` to detect the dodge input trigger.

5. **State Management**: Hook into `app.ropeway.survivor.player.PlayerCondition` or use the existing player tag attribute system to manage dodge state.

6. **Timing Windows**: Implement custom timing logic (no `EsEnemyEnableEmergencyDodgeTrack` exists in RE2) to determine when dodges are valid.

---

## Appendix: Common Enum Types

### `via.motion.WrapMode`
Standard animation wrap modes: Once, Loop, etc.

### `via.motion.BlendMode`
Layer blending modes for combining animations.

### `via.motion.InterpolationMode`
How motion transitions are interpolated between changes.

### `via.motion.InterpolationCurve`
The curve shape for interpolation (linear, ease-in, ease-out, etc.).

### `via.motion.MotionStateFlag`
Flags indicating the current state of a motion (playing, ended, etc.).

### `via.motion.TransitionState`
The state of a layer transition.

### `via.motion.SequencePhase`
Phase within a motion sequence.

### `via.hid.GamePadButton`
Bitmask enum for gamepad buttons. Used for `get_Button()`, `get_ButtonDown()`, `get_ButtonUp()`.
