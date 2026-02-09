# Blender-to-RE Engine .mot Animation Conversion Pipeline: Feasibility Research

**Date**: 2026-02-08
**Sources**: 30+ Python reverse-engineering scripts, existing format documentation, community tool knowledge base

---

## Table of Contents

1. [Executive Summary](#1-executive-summary)
2. [Existing RE Engine Animation Tools](#2-existing-re-engine-animation-tools)
3. [Tool Capability Matrix](#3-tool-capability-matrix)
4. [Local Format Knowledge (From Existing Scripts)](#4-local-format-knowledge-from-existing-scripts)
5. [Blender Animation Data Model](#5-blender-animation-data-model)
6. [Gap Analysis: What Exists vs What Needs to Be Built](#6-gap-analysis)
7. [Proposed Conversion Pipeline](#7-proposed-conversion-pipeline)
8. [Alternative Approaches](#8-alternative-approaches)
9. [Feasibility Assessment](#9-feasibility-assessment)
10. [Recommended Phased Approach](#10-recommended-phased-approach)
11. [Appendix: Key Technical References](#11-appendix-key-technical-references)

---

## 1. Executive Summary

Creating a Blender-to-RE Engine `.mot` animation pipeline is an **ambitious but partially feasible** goal. The critical finding is that substantial reverse-engineering work has already been done locally -- over 30 Python scripts have mapped the .motlist/.mot binary format in detail, including header layouts, bone clip structures, track headers, keyframe compression, and bone hash systems. However, a complete end-to-end writer does not yet exist, and several compression formats remain only partially decoded.

**Key findings:**

- **Reading .mot**: Well-understood for RE2 (v65) format. RE3 (v78) format is understood structurally but uses variable-rate compression (2-5 bytes per keyframe) that is only partially cracked.
- **Writing .mot**: No complete open-source writer exists. The local `motlist_converter.py` attempted a full RE3-to-RE2 structural rebuild but failed due to offset calculation errors.
- **Blender integration**: Community tools (RE-Mesh-Editor, RE Toolbox by alphazolam) handle mesh import/export to Blender but do NOT support animation (.mot) import or export.
- **Best near-term approach**: Runtime bone override via REFramework Lua (bypassing .mot files entirely), using pre-baked animation data from Blender exported as JSON/CSV.
- **Best long-term approach**: Build a .mot writer targeting RE2's simpler v65 format (4 bytes per keyframe, consistent compression), fed by Blender F-curve data.

---

## 2. Existing RE Engine Animation Tools

### 2.1 RE-Mesh-Editor (by alphazolam)

- **Repository**: `github.com/alphazolam/RE-Mesh-Editor`
- **Type**: Blender addon (Python)
- **Capabilities**:
  - Import/export RE Engine `.mesh` model files
  - Supports RE2, RE3, RE Village, RE4 Remake, and other RE Engine titles
  - Handles skeleton/bone hierarchy import from `.mesh` files
  - Material and texture handling
- **Animation support**: **NONE**. Does not read or write `.mot`, `.motlist`, or `.motbank` files. Does not import or export animation data.
- **Relevance**: Provides the skeleton import that would be needed as a prerequisite for animation work -- you need the bone hierarchy in Blender to create animations that match the game skeleton.

### 2.2 RE Toolbox (by alphazolam)

- **Repository**: `github.com/alphazolam/RE-Toolbox`
- **Type**: Blender addon (Python)
- **Capabilities**:
  - Batch import/export utilities for RE Engine assets
  - Chain physics editing (`.chain` files)
  - Material editing
  - Mesh batch processing
- **Animation support**: **NONE**. No .mot file handling.
- **Relevance**: Useful for overall RE Engine modding workflow but does not address animation.

### 2.3 RE-Mesh-Noesis (by NSACloud)

- **Repository**: `github.com/NSACloud/RE-Mesh-Noesis`
- **Type**: Noesis plugin (Python)
- **Capabilities**:
  - Import RE Engine `.mesh` files into Noesis
  - Some skeleton support
  - Export to standard 3D formats (FBX, etc.)
- **Animation support**: **Limited/Unknown**. Noesis itself supports animation in some formats but this plugin's .mot support is not confirmed. The community has used Noesis for RE Engine mesh conversion but animation conversion through this plugin is not documented.
- **Relevance**: Noesis has a rich animation pipeline internally and could theoretically be extended, but no known .mot reader/writer plugin for Noesis exists in the public domain.

### 2.4 RE-Mot-Editor (Community Tool)

- **Type**: Standalone editor (likely C# or similar)
- **Capabilities**: This tool is referenced in the local `motlist_converter.py` script header: "Based on reverse engineering the Motlist Tool by alphazolam." This suggests alphazolam has created or worked on a motlist editing tool.
- **Key insight from motlist_converter.py**: The converter script documents specific format knowledge attributed to studying this tool:
  - Track headers: RE3=20 bytes (uint32 offsets), RE2=40 bytes (uint64 offsets + frameRate + maxFrame)
  - Bone clip headers: RE3=12 bytes, RE2=24 bytes
  - Keyframe data: uncompressed is float32 XYZ triplets
  - Rotation flags differ between versions: RE3=0x4C0912, RE2=0x4B0912
- **Animation support**: Likely reads .motlist files and allows some editing. The extent of write support is unclear.
- **Availability**: Not found as a public GitHub repository. May be distributed on modding forums (NexusMods, Residentevilmodding.boards.net) or via direct sharing.

### 2.5 010 Editor Binary Templates

- **Type**: Binary template files for 010 Editor (a hex editor)
- **Capabilities**: Community members have created `.bt` template files that describe the .motlist/.mot binary layout, making it possible to visually inspect and understand the format in 010 Editor.
- **Known templates**: Templates for RE Engine formats exist on GitHub (search "RE Engine 010 template") and modding community sites. These typically cover the header structure and may partially describe keyframe data.
- **Relevance**: Useful for manual inspection and verification but do not perform conversion.

### 2.6 Local Python Analysis Scripts (This Project)

- **Location**: Project `tools/` directory (see repository root)
- **Count**: 30+ Python scripts
- **Capabilities**: The most comprehensive .mot format analysis found anywhere. These scripts collectively:
  - Parse motlist headers, entry pointer tables, mot entry headers
  - Parse bone clip headers (24-byte RE2 and 12-byte RE3 formats)
  - Parse track headers (40-byte RE2 and 20-byte RE3 formats)
  - Decode compressed rotation quaternions (3-bpk confirmed working)
  - Attempt to decode 2-bpk, 4-bpk, and 5-bpk compression (partially successful)
  - Map bone hashes between RE2 and RE3 using MurmurHash3
  - Extract motion names, bone names, frame counts, timing data
  - Attempt full format conversion (RE3 v99/v78 to RE2 v85/v65)
  - Inject keyframe data into existing motlist files
  - Compute optimal unpack parameters for recompression
- **Animation support**: **Read**: YES (both versions). **Write**: PARTIAL (can modify keyframe data in existing files, but full structural rebuild has not produced game-loadable output).

### 2.7 REFramework Runtime API

- **Type**: Lua scripting API within REFramework
- **Capabilities** (from `re_engine_animation_types.md`):
  - `via.motion.Motion`: getLocalRotation/getLocalPosition for reading bone transforms
  - `via.motion.TreeLayer`: setLocalRotation/setLocalPosition for writing bone transforms per-frame
  - `via.motion.DynamicMotionBank`: runtime loading of .motbank resources
  - `via.motion.TreeLayer.changeMotion()`: trigger animation playback
  - `via.Joint`: read/write individual joint transforms
  - `via.Transform.Joints`: access full joint array
- **Animation support**: **Runtime override**: YES. Can set bone transforms per-frame from Lua, bypassing .mot files entirely. This is the approach used by `inject_real_dodge.py` (data preparation) combined with a Lua script.

---

## 3. Tool Capability Matrix

| Tool | Read .mot | Write .mot | Blender Import | Blender Export | Runtime Override |
|------|-----------|------------|----------------|----------------|------------------|
| RE-Mesh-Editor | No | No | Mesh/Skeleton only | Mesh only | N/A |
| RE Toolbox | No | No | N/A | N/A | N/A |
| RE-Mesh-Noesis | Unknown | No | Via Noesis | Via Noesis | N/A |
| RE-Mot-Editor | Likely Yes | Unknown | No | No | N/A |
| 010 Editor Templates | Visual only | No | No | No | N/A |
| Local Python Scripts | YES (both ver) | PARTIAL | No | No | N/A |
| REFramework Lua API | N/A | N/A | N/A | N/A | YES |

---

## 4. Local Format Knowledge (From Existing Scripts)

### 4.1 What Is Fully Understood

The following aspects of the .mot format are thoroughly documented in the local scripts and in `motlist_format_guide.md`:

**Motlist Container (both versions):**
- Header layout: version (4B), magic "mlst" (4B), padding, pointersOffs (8B), colOffs (8B), nameOffs (8B), numOffs (4B), name string (UTF-16LE)
- Entry pointer table: array of uint64 offsets to mot entries
- Entry sizes: calculated from consecutive pointer offsets

**Mot Entry Header (0x74 bytes, both versions):**
- Version (65 for RE2, 78 for RE3), magic "mot "
- Internal offsets: boneClipHdrOffs, clipFileOffset, namesOffs, etc.
- Timing: frameCount (float), blending (float), frameRate (uint16)
- Counts: boneCount, boneClipCount
- All offsets are mot-entry-relative (not file-relative)

**Bone Clip Headers:**
- RE2: 24 bytes (boneIndex uint16, trackFlags byte, boneHash uint32, uknFloat, padding, trackHdrOffs uint64)
- RE3: 12 bytes (boneIndex uint16, trackFlags byte, boneHash uint32, trackHdrOffs uint32)
- trackFlags bit 0 = position, bit 1 = rotation, bit 2 = scale

**Track Headers:**
- RE2: 40 bytes (flags, keyCount, frameRate, maxFrame, frameIndOffs uint64, frameDataOffs uint64, unpackDataOffs uint64)
- RE3: 20 bytes (flags, keyCount, frameIndOffs uint32, frameDataOffs uint32, unpackDataOffs uint32)

**Track Flags:**
- Bits 0-11: track type (0x0112 = rotation, 0x00F2 = translation)
- Bits 12+: compression format / sub-type
- RE2 rotation flag: 0x4B0912 (uncompressed) or 0x4X_0112 (compressed)
- RE3 rotation flag: 0x4C0912 (uncompressed) or 0x2X_0112 (compressed)

**Unpack Data Block (32 bytes = 8 x float32):**
- scale[0..3]: range values for X, Y, Z, W
- base[0..3]: minimum values for X, Y, Z, W
- Decode: `component_i = base_i + (byte_i / 255.0) * scale_i`

**RE2 Compressed Rotation (confirmed working):**
- 4 bytes per keyframe: 4 x 8-bit quantized XYZW quaternion components
- Decode: `qX = base[0] + (byte[0]/255.0) * scale[0]`, etc.
- All 4 components stored explicitly, quaternion magnitude approximately 1.0

**Bone Hash System:**
- MurmurHash3 32-bit, seed 0xFFFFFFFF, on UTF-16LE encoded bone name
- 88 bones shared between RE2 and RE3 skeletons (same hash = same name)
- 10 bones have confirmed human-readable names (root, hips, spine_0, spine_1, spine_2, neck_0, neck_1, head, Null_Offset, COG)

### 4.2 What Is Partially Understood

**RE3 Variable-Rate Compression:**
- 3 bpk: CONFIRMED WORKING -- 3 bytes = XYZ quantized (8-bit each), W reconstructed from unit quaternion constraint
- 2 bpk: PARTIALLY DECODED -- sub_flag dependent (16-bit single component or 2x8-bit), other components at midpoint
- 4 bpk: NOT FULLY DECODED -- not simple 4x8-bit XYZW (tested). Rosetta Stone comparisons showed poor match. May use 10-bit packing, SoA layout, or cubic Hermite curves.
- 5 bpk: NOT DECODED -- unknown packing scheme

**Secondary Offset Fields:**
- Mot header fields at +0x10, +0x30, +0x38, +0x48 are offset pointers to secondary data sections (bone header offset table, clip data, etc.) whose exact purposes are partially mapped but not fully validated for writing.

### 4.3 What Is Not Understood

- Full semantics of mot header fields +0x20, +0x28, +0x40 (appear to be padding/reserved in some entries)
- The CLIP/collection data block referenced by colOffs
- How frame index arrays interact with variable-rate compressed tracks in RE3
- Whether the engine validates checksums or magic values beyond the basic header
- How .motbank files reference .motlist files (the resource loading chain)

---

## 5. Blender Animation Data Model

### 5.1 How Blender Stores Bone Animations

**Armature and Bones:**
- Blender uses an Armature object containing a hierarchy of Bones
- Each bone has a rest pose (edit mode) and a posed position (pose mode)
- The bone hierarchy defines parent-child relationships

**Actions and F-Curves:**
- Animations are stored as "Actions" containing F-Curves
- Each F-Curve represents one animated property of one bone over time
- Properties: location (X/Y/Z), rotation_quaternion (W/X/Y/Z), rotation_euler (X/Y/Z), scale (X/Y/Z)
- F-Curves contain keyframes at specific frame numbers with interpolation settings

**Keyframe Data:**
- Each keyframe stores: frame number (float), value (float), left handle, right handle
- Handle types: FREE, ALIGNED, VECTOR, AUTO, AUTO_CLAMPED
- Interpolation modes: CONSTANT, LINEAR, BEZIER (with handle tangents)
- Blender evaluates F-curves at any frame using interpolation between keyframes

**Rotation Representations:**
- Quaternion mode: stores (W, X, Y, Z) -- note Blender uses WXYZ order, RE Engine uses XYZW
- Euler mode: stores (X, Y, Z) with specified rotation order (XYZ, XZY, etc.)
- RE Engine uses quaternions exclusively in .mot files
- Conversion from Euler to quaternion is well-defined mathematically

**Coordinate System:**
- Blender: right-handed, Z-up
- RE Engine: left-handed (or right-handed Y-up, depending on interpretation)
- Axis conversion is required: typically Blender Z-up to RE Engine Y-up
- This affects both bone orientations and animation data

### 5.2 Native Export Formats from Blender

| Format | Bone Animation | Quaternion | Binary | Notes |
|--------|---------------|------------|--------|-------|
| FBX | Yes | Yes (converted from internal) | Yes | Industry standard, well-supported |
| glTF 2.0 | Yes | Yes (native) | Yes (.glb) | Modern, quaternion-native |
| BVH | Yes | Euler only | Text | Motion capture format, simple |
| Collada (.dae) | Yes | Via matrices | XML | Verbose, older standard |
| Alembic (.abc) | Yes | Via matrices | Binary | Production format |

**Best intermediate format**: FBX or glTF 2.0, because:
- Both preserve bone hierarchies and animation keyframes
- Both can represent quaternion rotations
- Both are well-supported by Python libraries (FBX SDK, pygltflib)
- glTF is simpler to parse programmatically than FBX

### 5.3 How Other Modding Tools Handle Blender-to-Game Animation

**Precedent: Source Engine (Valve):**
- Blender exports to SMD/DMX intermediate format
- `studiomdl` compiler converts to game-specific .mdl with embedded animation
- Community tools: Blender Source Tools addon

**Precedent: Bethesda (Skyrim/Fallout):**
- Blender exports to FBX or .hkx (Havok) via conversion tools
- hkxcmd / ck-cmd convert FBX to .hkx animation format
- The .hkx format uses compressed keyframe data similar to .mot

**Precedent: Unity/Unreal:**
- Both engines import FBX natively with animation
- Retargeting handles skeleton differences
- No intermediate binary format needed

**Key lesson**: Most successful modding pipelines use FBX as the interchange format and have a dedicated compiler/converter from FBX to the game's native format. This is the model that would work for RE Engine as well.

### 5.4 Data That Must Be Preserved

For a Blender-to-.mot pipeline, the following data must be captured:

1. **Bone hierarchy**: Parent-child relationships, bone names
2. **Bone name hashes**: MurmurHash3(UTF-16LE(name), seed=0xFFFFFFFF) for each bone
3. **Per-bone keyframe data**: Frame number, quaternion rotation, position, scale
4. **Timing**: Frame count, frame rate, animation duration
5. **Interpolation**: How values change between keyframes (Blender uses Bezier curves; .mot uses quantized samples)
6. **Coordinate system**: Axis conversion from Blender to RE Engine space

---

## 6. Gap Analysis

### 6.1 What Exists

| Capability | Status | Tool/Source |
|-----------|--------|-------------|
| Parse .motlist headers | COMPLETE | Local Python scripts |
| Parse .mot entry headers | COMPLETE | Local Python scripts |
| Parse bone clip headers (RE2 + RE3) | COMPLETE | Local Python scripts |
| Parse track headers (RE2 + RE3) | COMPLETE | Local Python scripts |
| Decode RE2 compressed rotation (4bpk) | COMPLETE | Local Python scripts |
| Decode RE3 compressed rotation (3bpk) | COMPLETE | Local Python scripts |
| Bone hash computation (MurmurHash3) | COMPLETE | Local Python scripts |
| Bone mapping RE3 <-> RE2 (88 shared) | COMPLETE | bone_mapping.json |
| Named bone mapping (10 known names) | COMPLETE | inject_real_dodge.py |
| Import RE Engine skeleton to Blender | COMPLETE | RE-Mesh-Editor |
| Runtime bone override via Lua | COMPLETE | REFramework API |
| Modify keyframe data in existing .mot | COMPLETE | recompress_dodge.py |
| Compute optimal unpack params | COMPLETE | recompress_dodge.py |

### 6.2 What Is Missing

| Capability | Status | Difficulty | Notes |
|-----------|--------|------------|-------|
| **Write .motlist from scratch** | NOT BUILT | HIGH | Need correct offset calculation for all sections |
| **Write .mot entry from scratch** | NOT BUILT | HIGH | Need to compute all internal offsets correctly |
| **Blender animation exporter to intermediate format** | NOT BUILT | MEDIUM | Extract F-curves, convert quaternions, map bones |
| **Intermediate format to .mot compiler** | NOT BUILT | HIGH | The core missing piece |
| **Blender bone name to RE Engine hash mapping** | NOT BUILT | LOW | Just apply MurmurHash3 to bone names |
| **Axis conversion (Blender Z-up to RE Engine)** | NOT BUILT | LOW | Standard coordinate transform |
| **Frame resampling (variable to fixed rate)** | NOT BUILT | MEDIUM | Blender keyframes at arbitrary times; .mot needs regular samples |
| **Quantization (float quaternion to 8-bit)** | PARTIALLY BUILT | LOW | compress_re2_quat() exists in recompress_dodge.py |
| **RE3 4-bpk and 5-bpk decode** | UNSOLVED | VERY HIGH | Multiple approaches tried, none fully successful |
| **Full bone name resolution** | PARTIAL | MEDIUM | 10 of 88+ shared bones have known names |
| **.motbank file creation/editing** | NOT BUILT | UNKNOWN | .motbank references .motlist; format not analyzed |
| **Blender addon UI** | NOT BUILT | MEDIUM | User interface for export workflow |

### 6.3 Critical Path Analysis

The minimum viable pipeline requires:

1. **A .mot writer for RE2 v65 format** (the simpler format with consistent 4-bpk compression)
2. **A Blender exporter** that extracts bone animation data in a format the writer can consume
3. **Bone name mapping** between Blender armature bones and RE Engine bone hashes
4. **Axis conversion** and quaternion order adjustment
5. **A .motlist wrapper** that packages the .mot entry into a valid .motlist container
6. **PAK packaging** to deploy the .motlist into the game (already working via `minimal_test.py`)

---

## 7. Proposed Conversion Pipeline

### 7.1 Pipeline Architecture

```
Blender Animation (Action/F-Curves)
    |
    v
[Blender Export Script]  -- Python addon
    |  Extracts: bone names, keyframe times, quaternion values,
    |  positions, frame rate, frame count
    |  Outputs: JSON intermediate format
    v
Intermediate JSON File
    |
    v
[.mot Compiler]  -- Python script
    |  Reads JSON, maps bone names to hashes,
    |  quantizes quaternions, builds binary structure,
    |  computes all offsets, writes .motlist file
    v
.motlist.85 Binary File (RE2 v65 format)
    |
    v
[PAK Packager]  -- Existing pipeline (fluffy manager or manual)
    |
    v
.pak File (deployed to game)
```

### 7.2 Intermediate JSON Format (Proposed)

```json
{
  "format_version": 1,
  "animation_name": "custom_dodge_L0",
  "frame_rate": 30,
  "frame_count": 120.0,
  "blending": 8.0,
  "target_game": "RE2",
  "bones": [
    {
      "name": "hips",
      "hash": 2790671208,
      "bone_index": 3,
      "tracks": {
        "rotation": {
          "type": "quaternion_xyzw",
          "keyframes": [
            {"frame": 0, "value": [0.0, 0.0, 0.0, 1.0]},
            {"frame": 1, "value": [0.01, 0.0, -0.005, 0.9999]},
            ...
          ]
        },
        "position": {
          "type": "vec3_xyz",
          "keyframes": [
            {"frame": 0, "value": [0.0, 0.0, 0.0]},
            ...
          ]
        }
      }
    },
    ...
  ]
}
```

### 7.3 .mot Compiler Logic (RE2 v65 Target)

The compiler would build the binary in this order:

1. **Collect all bone data** from JSON, compute MurmurHash3 for each bone name
2. **Resample keyframes** to uniform frame spacing if needed
3. **For each bone's rotation track**:
   - Collect all quaternion keyframes
   - Compute unpack parameters: min/max for each XYZW component
   - Quantize each quaternion to 4 bytes (8-bit per component)
4. **Build binary sections** in order:
   a. Mot header (0x74 bytes)
   b. Motion name string (UTF-16LE, null-terminated, aligned)
   c. Bone clip headers (24 bytes each for RE2)
   d. Track headers (40 bytes each for RE2)
   e. Frame index arrays (uint16 per keyframe)
   f. Frame data (4 bytes per keyframe for compressed rotation)
   g. Unpack data blocks (32 bytes each)
5. **Compute all offsets** (mot-entry-relative) and write them into headers
6. **Wrap in motlist container**: header + name + pointer table + mot entry + collection data

### 7.4 Blender Exporter Logic

The Blender addon would:

1. **Validate**: Check that the active object is an Armature with an Action
2. **Read skeleton**: Get bone hierarchy, names, rest poses
3. **Read animation**: For each bone, extract F-curves for rotation_quaternion and location
4. **Convert coordinates**: Apply axis conversion (Blender Z-up to RE Engine Y-up)
5. **Convert quaternion order**: Blender WXYZ to RE Engine XYZW
6. **Sample at frame rate**: Evaluate F-curves at each frame (30fps or 60fps)
7. **Export JSON**: Write the intermediate format

---

## 8. Alternative Approaches

### 8.1 Runtime Bone Override (Recommended Near-Term)

**Approach**: Skip .mot files entirely. Export animation from Blender as a simple data file (JSON or binary), load it in a REFramework Lua script, and override bone transforms per-frame at runtime.

**How it works**:
1. Create animation in Blender
2. Export keyframe data as JSON (bone name, frame, quaternion, position)
3. REFramework Lua script loads JSON at game startup
4. When triggered, the Lua script calls `TreeLayer:setLocalRotation(idx, quat)` for each bone on each frame
5. The animation plays by advancing through the keyframe data

**Advantages**:
- No need to understand .mot binary format
- No need to solve compression/quantization
- Full-precision quaternions (no 8-bit quantization loss)
- Flexible: can blend with existing animations at runtime
- Already demonstrated as viable (inject_real_dodge.py + Lua dumper)

**Disadvantages**:
- Performance cost: setting 80+ bone transforms per frame in Lua
- No engine-level interpolation (must implement manually)
- No integration with the animation state machine (FSM)
- Cannot be triggered via normal `changeMotion()` calls
- Requires the Lua script to be running

**Feasibility**: HIGH. All required APIs exist. Performance is the main concern.

### 8.2 FBX-Based Retargeting via .motbank Loading

**Approach**: Convert Blender animation to FBX, then use community tools or a custom converter to create a .motbank file that the engine can load via `DynamicMotionBank`.

**How it works**:
1. Create animation in Blender, export as FBX
2. Convert FBX to .motlist/.mot binary (this is the hard part)
3. Create or modify a .motbank to reference the .motlist
4. Load via REFramework's `DynamicMotionBank` API
5. Trigger via `TreeLayer.changeMotion(bankID, motionID, ...)`

**Advantages**:
- Full engine integration: interpolation, FSM, layer blending all work
- Proper resource management (engine handles lifecycle)
- Can be triggered like any normal animation

**Disadvantages**:
- Requires solving the .mot writing problem completely
- Requires understanding .motbank format (currently unanalyzed)
- More complex pipeline

**Feasibility**: MEDIUM-LOW (due to unsolved .mot writing and .motbank format).

### 8.3 Hybrid: Modify Existing .motlist + Runtime Supplement

**Approach**: Take an existing RE2 .motlist, replace keyframe data for shared bones using the recompression technique already demonstrated, and supplement with runtime Lua overrides for additional bones.

**How it works**:
1. Create animation in Blender
2. Export keyframe data as JSON
3. Python script opens an existing RE2 .motlist
4. For each bone that exists in the target .motlist:
   - Compute new unpack parameters from the new quaternion data
   - Quantize quaternions to 4 bytes each
   - Write new unpack params and frame data over existing data
5. The modified .motlist has the new animation in place of the original
6. Deploy via PAK
7. Optionally supplement with Lua overrides for bones not in the motlist

**Advantages**:
- All structural offsets remain valid (no structural rebuild needed)
- Demonstrated as working for bone data injection (recompress_dodge.py)
- Quantization and recompression code already exists
- Closest to working today

**Disadvantages**:
- Limited to the number of keyframes in the original animation
- Cannot add new bones or change bone count
- Must choose which existing animation to overwrite
- Frame count mismatch requires resampling
- 8-bit quantization introduces precision loss

**Feasibility**: HIGH. This is the most likely to work with current knowledge.

### 8.4 Blender Animation to RE Engine via MotionInfo API

**Approach**: Use the engine's `MotionInfo.getAnimationTransform()` API in reverse -- instead of querying existing animations, inject custom transform data through the animation system's hooks.

**Status**: Theoretical. The API exists for reading but it is unclear if there's a writable pathway.

**Feasibility**: LOW (insufficient understanding of the internal animation evaluation pipeline).

---

## 9. Feasibility Assessment

### 9.1 Realistic Goals (Achievable in Weeks)

| Goal | Feasibility | Approach |
|------|------------|----------|
| Play custom animation via runtime Lua override | HIGH | Export Blender data as JSON, load in Lua, set bone transforms per-frame |
| Modify existing animation with new keyframe data | HIGH | Use recompress_dodge.py approach with Blender-sourced data |
| Import RE Engine skeleton into Blender | ALREADY DONE | RE-Mesh-Editor addon |
| Export Blender keyframes to intermediate format | HIGH | Simple Python addon |

### 9.2 Ambitious Goals (Achievable in Months)

| Goal | Feasibility | Approach |
|------|------------|----------|
| Build .mot writer for RE2 v65 format | MEDIUM | Use existing format knowledge, extensive testing |
| Build Blender-to-.motlist compiler | MEDIUM | Intermediate JSON + compiler |
| Create new animations playable via changeMotion() | MEDIUM-LOW | Requires .mot writer + .motbank understanding |
| Full Blender addon with export UI | MEDIUM | Standard Blender addon development |

### 9.3 Aspirational Goals (Achievable in Months-to-Years)

| Goal | Feasibility | Approach |
|------|------------|----------|
| Fully crack RE3 v78 4/5-bpk compression | LOW | Requires more reverse engineering or source leaks |
| Universal .mot reader/writer (all RE Engine titles) | LOW | Each title version has different offsets/sizes |
| Round-trip .mot editing (read-modify-write) | MEDIUM | Easier if targeting only RE2 v65 |
| Integration with RE Engine animation FSM | LOW | Requires deep engine internals knowledge |

### 9.4 Risk Assessment

| Risk | Severity | Mitigation |
|------|----------|------------|
| .mot writer produces crashes | HIGH | Test with minimal modifications first; use verify_conversion.py approach |
| Quaternion quantization artifacts | MEDIUM | Use 16-bit quantization if 8-bit is too lossy (requires format research) |
| Bone mapping errors | MEDIUM | Verify bone names match between Blender armature and RE Engine skeleton |
| Coordinate system errors | LOW | Well-documented conversion between Blender Z-up and Y-up |
| Game updates breaking format | LOW | RE2 Remake is unlikely to receive format-changing updates |
| Performance of runtime Lua approach | MEDIUM | Profile; consider batching or native plugin if too slow |

---

## 10. Recommended Phased Approach

### Phase 1: Blender Export + Runtime Lua Override (2-4 weeks)

**Goal**: Play a Blender-created animation in RE2 via runtime bone overrides.

**Deliverables**:
1. Blender addon that exports bone animation data to JSON
   - Read armature hierarchy and bone names
   - Sample F-curves at target frame rate
   - Convert quaternion order (WXYZ to XYZW) and axis system
   - Output standardized JSON with per-bone keyframe arrays
2. REFramework Lua script that loads JSON and applies per-frame bone transforms
   - Parse JSON bone data
   - Map bone names to joint indices via MurmurHash3 + `getJointIndexByNameHash()`
   - On trigger: iterate frames, call `setLocalRotation()` per bone
   - Handle interpolation between frames
3. Test with a simple animation (e.g., T-pose to A-pose, 30 frames)

**Why this first**: Validates the entire data flow without solving the hard binary format problems.

### Phase 2: Keyframe Injection into Existing .motlist (2-4 weeks)

**Goal**: Inject Blender animation data into an existing RE2 .motlist file, replacing one animation slot.

**Deliverables**:
1. Python script that:
   - Reads the Phase 1 JSON export
   - Opens an existing RE2 .motlist.85 file
   - For each bone with a matching hash:
     - Resamples Blender keyframes to match the existing track's key count
     - Computes new unpack parameters (min/max quaternion ranges)
     - Quantizes quaternions to 4x8-bit bytes
     - Writes new unpack params and frame data
   - Saves modified .motlist
2. PAK packaging and deployment testing
3. In-game verification that the modified animation plays correctly

**Why second**: Reuses existing code (recompress_dodge.py patterns) and requires no structural format changes.

### Phase 3: .mot Writer from Scratch (4-8 weeks)

**Goal**: Build a complete .mot entry writer that creates valid binary from animation data.

**Deliverables**:
1. Python module: `mot_writer.py`
   - Input: animation data (bone list with keyframes, timing info)
   - Output: valid .mot entry binary blob
   - Handles: header construction, bone clip headers, track headers, frame data, unpack blocks
   - All internal offsets computed correctly
2. Python module: `motlist_writer.py`
   - Input: one or more .mot entry blobs + motlist name
   - Output: valid .motlist.85 file
   - Handles: motlist header, pointer table, padding/alignment
3. Validation suite comparing writer output to known-good .motlist files
4. Test: create a simple animation from scratch, deploy, verify in-game

**Why third**: This is the hardest part and benefits from all knowledge gained in Phases 1-2.

### Phase 4: Full Blender Addon (4-8 weeks)

**Goal**: Integrated Blender addon with export-to-.motlist functionality.

**Deliverables**:
1. Blender addon with UI panel:
   - Select target game (RE2 Remake)
   - Select armature and action to export
   - Configure frame rate, animation name, export path
   - One-click export to .motlist.85
2. Bone mapping configuration:
   - Auto-detect bone names and compute hashes
   - Manual mapping override for mismatched names
   - Preview which bones will be animated
3. Integration with PAK builder for one-click deployment
4. Documentation and usage guide

### Phase 5 (Optional): .motbank Support and FSM Integration

**Goal**: Create animations that integrate with the engine's animation state machine.

**Deliverables**:
1. .motbank format analysis and documentation
2. .motbank writer/editor
3. Lua integration: load custom .motbank via DynamicMotionBank, trigger via changeMotion()
4. Full engine-integrated animation playback with interpolation and blending

---

## 11. Appendix: Key Technical References

### 11.1 Local Script Reference

| Script | Key Knowledge |
|--------|--------------|
| `motlist_converter.py` | Full RE3->RE2 structural conversion (bone clip 12->24, track 20->40, offset uint32->uint64) |
| `recompress_dodge.py` | Decompress-recompress pipeline with compute_unpack_params() |
| `inject_real_dodge.py` | Runtime dump ingestion, delta-based quaternion application, bone name matching |
| `analyze_full_format.py` | Complete byte-level format documentation generator |
| `crack_re3_compression.py` | All tested decode formulas for variable-rate compression |
| `rosetta_crack.py` | Cross-entry comparison for cracking unknown compression |
| `build_bone_map.py` | RE3-to-RE2 bone index/hash mapping builder |
| `resolve_bone_names.py` | Bone hash dump cross-referencing tool |

### 11.2 Existing Documentation

| Document | Path | Content |
|----------|------|---------|
| Motlist Format Guide | `docs/motlist_format_guide.md` | Complete binary format spec for .motlist/.mot |
| RE Engine Animation Types | `docs/re_engine_animation_types.md` | IL2CPP API reference for via.motion.* types |
| RE3 Jill Dodge Doc | `docs/RE32 Jill Dodge Doc.md` | RE3 dodge system architecture analysis |

### 11.3 Key Format Constants

```python
# Motlist versions
RE2_MOTLIST_VERSION = 85
RE3_MOTLIST_VERSION = 99
RE2_MOT_VERSION = 65
RE3_MOT_VERSION = 78

# Magic values
MOTLIST_MAGIC = 0x74736C6D  # "mlst"
MOT_MAGIC = 0x20746F6D      # "mot "

# Structure sizes
RE2_BONE_CLIP_SIZE = 24
RE3_BONE_CLIP_SIZE = 12
RE2_TRACK_HEADER_SIZE = 40
RE3_TRACK_HEADER_SIZE = 20

# Track flags
RE2_ROT_UNCOMPRESSED = 0x004B0912
RE3_ROT_UNCOMPRESSED = 0x004C0912
TRANS_UNCOMPRESSED = 0x00400372

# Bone hash
MURMURHASH3_SEED = 0xFFFFFFFF
# Encoding: UTF-16LE

# Key bone hashes
BONES = {
    0xABA7DE3C: "root",
    0x5DCE2C70: "Null_Offset",
    0xCC3297EA: "COG",
    0xA6993368: "hips",
    0x31838B82: "spine_0",
    0x80973DA1: "spine_1",
    0xB344F241: "spine_2",
    0xD2D4DEFA: "neck_0",
    0x00A6D31D: "neck_1",
    0x2BF882E3: "head",
}
```

### 11.4 Quaternion Conversion Notes

```
Blender quaternion order:  (W, X, Y, Z)
RE Engine quaternion order: (X, Y, Z, W)

Blender coordinate system: right-handed, Z-up, Y-forward
RE Engine coordinate system: varies by context; typically Y-up

Axis conversion (Blender to RE Engine, approximate):
  RE_X =  Blender_X
  RE_Y =  Blender_Z
  RE_Z = -Blender_Y

Quaternion axis conversion:
  RE_qX =  Blender_qX
  RE_qY =  Blender_qZ
  RE_qZ = -Blender_qY
  RE_qW =  Blender_qW

NOTE: The exact axis mapping must be verified empirically against
imported RE Engine skeletons in Blender. RE-Mesh-Editor applies its
own axis conversion during mesh import; the animation pipeline must
use the same convention.
```

### 11.5 Community Resources (Known URLs)

| Resource | URL | Notes |
|----------|-----|-------|
| RE-Mesh-Editor | github.com/alphazolam/RE-Mesh-Editor | Blender addon for RE Engine meshes |
| RE Toolbox | github.com/alphazolam/RE-Toolbox | Blender utilities for RE Engine |
| RE-Mesh-Noesis | github.com/NSACloud/RE-Mesh-Noesis | Noesis plugin for RE Engine |
| REFramework | github.com/praydog/REFramework | Runtime modding framework |
| NexusMods RE2 | nexusmods.com/residentevil22019 | RE2 Remake mod community |
| Modding Haven Discord | (community Discord servers) | RE Engine modding community |

---

## Summary

The Blender-to-RE Engine .mot pipeline is feasible but requires a phased approach. The recommended strategy is:

1. **Start with runtime Lua override** (Phase 1) to prove the data flow works end-to-end
2. **Progress to keyframe injection** (Phase 2) to get .mot-level integration with minimal risk
3. **Build the full .mot writer** (Phase 3) only after the simpler approaches are validated
4. **Wrap in a Blender addon** (Phase 4) for usability

The critical advantage this project has over starting from scratch is the **extensive binary format knowledge** already captured in 30+ local Python scripts and the `motlist_format_guide.md` documentation. The RE2 v65 format (4 bytes per keyframe, consistent structure) is the most viable target for a first .mot writer.
