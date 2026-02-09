# RE Engine .motlist / .mot Binary Format Guide

## Consolidated Findings from Binary Analysis Scripts

**Prepared by**: Agent 2 (Binary Format & Bone Mapping Analyst)
**Source scripts analyzed**: 30+ Python reverse-engineering scripts
**Data files analyzed**: bone_mapping.json, bone_index_mapping.json, dodge_dump.txt, re2_bones.txt

---

## 1. MOTLIST CONTAINER FORMAT

### 1.1 Motlist Header (shared structure, both versions)

The motlist container wraps multiple individual `.mot` animation entries. The header
layout is the same between RE2 (.motlist.85) and RE3 (.motlist.99), but internal
pointer widths differ.

```
Offset  Size   Field                 Description
------  ----   -----                 -----------
0x00    4B     version               85 (RE2) or 99 (RE3)
0x04    4B     magic                 "mlst" (0x74736C6D)
0x08    8B     padding               Zero
0x10    8B     pointersOffs          File offset to the entry pointer table (uint64 array)
0x18    8B     colOffs               File offset to collection/CLIP data at end of file
0x20    8B     motlistNameOffs       Offset to motlist name string (usually 0x34)
0x28    8B     padding2              Zero
0x30    4B     numOffs               Number of mot entries in this motlist
0x34    var    motlistName            UTF-16LE null-terminated string (e.g. "base_cmn_move")
```

After the name string (aligned to 8 bytes), the **entry pointer table** begins.
This is an array of `numOffs` uint64 values, each pointing to the file offset of
a mot entry.

### 1.2 Entry Pointer Table

```
pointersOffs + 0*8  -> uint64 offset to mot entry 0
pointersOffs + 1*8  -> uint64 offset to mot entry 1
...
pointersOffs + N*8  -> uint64 offset to mot entry N
```

Entry sizes are determined by the distance between consecutive offsets. The last
entry extends to `colOffs` or end of file.

### 1.3 Key Observation: Motlist Header is Identical

The motlist container header layout (0x00-0x34+name) is structurally identical
between RE2 v85 and RE3 v99. The differences are entirely inside the mot entries
themselves and in the version field.

---

## 2. MOT ENTRY FORMAT

Each mot entry contains one animation (e.g., idle, walk, dodge). This is where
the critical format differences exist between RE2 and RE3.

### 2.1 Mot Entry Header (0x74 bytes)

```
Offset  Size   Field                 RE2 (v65)           RE3 (v78)
------  ----   -----                 ---------           ---------
0x00    4B     mot_version           65                  78
0x04    4B     magic                 "mot " (0x20746F6D) same
0x08    4B     unknown               varies              varies
0x0C    4B     motSize               total entry size    0 (not used in v78)
0x10    8B     offsToBoneHdrOffs     offset to bone header offsets table
0x18    8B     boneClipHdrOffs       offset to bone clip header array
0x20    8B     (skip1)
0x28    8B     (skip2)
0x30    8B     clipFileOffset        offset to clip/collection data
0x38    8B     Offs1                 secondary offset
0x40    8B     (skip3)
0x48    8B     Offs2                 tertiary offset
0x50    8B     namesOffs             offset to motion name (UTF-16LE)
0x58    4B     frameCount            float: total frame count (e.g. 120.0)
0x5C    4B     blending              float: blend time
0x60    4B     uknFloat1             float: unknown
0x64    4B     uknFloat2             float: unknown
0x68    2B     boneCount             total skeleton bone count
0x6A    2B     boneClipCount         number of bone clip entries
0x6C    1B     uknPtr2Count          unknown count
0x6D    1B     uknPtr3Count          unknown count
0x6E    2B     frameRate             e.g. 30 or 60
0x70    2B     uknPtrCount           unknown
0x72    2B     uknShort2             unknown
```

The mot header is 0x74 bytes in both versions. All offsets within a mot entry
are **relative to the start of that mot entry** (not to the file start).

After the 0x74-byte header, the **motion name** string begins at `namesOffs`
(typically 0x74), stored as UTF-16LE null-terminated.

### 2.2 All Internal Offsets Are Mot-Entry-Relative

Critical detail: every offset field inside a mot entry (boneClipHdrOffs,
trackHdrOffs, frameDataOffs, unpackDataOffs, etc.) is relative to the
**start of that mot entry**, NOT to the start of the file.

---

## 3. BONE CLIP HEADERS

Bone clips describe which bones are animated and point to their track data.
**This is the first major structural difference between RE2 and RE3.**

### 3.1 RE2 Bone Clip Header (24 bytes)

```
Offset  Size  Field           Description
------  ----  -----           -----------
+0      2B    boneIndex       Skeleton joint index (uint16)
+2      1B    trackFlags1     Bit flags: bit0=position, bit1=rotation, bit2=scale
+3      1B    trackFlags2     Additional flags
+4      4B    boneHash        MurmurHash3 of bone name (seed=0xFFFFFFFF)
+8      4B    uknFloat        Unknown float (RE2 extra field)
+12     4B    padding         Zero padding (RE2 extra field)
+16     8B    trackHdrOffs    uint64 offset to first track header (mot-relative)
```

### 3.2 RE3 Bone Clip Header (12 bytes)

```
Offset  Size  Field           Description
------  ----  -----           -----------
+0      2B    boneIndex       Skeleton joint index (uint16)
+2      1B    trackFlags1     Bit flags: bit0=position, bit1=rotation, bit2=scale
+3      1B    trackFlags2     Additional flags
+4      4B    boneHash        MurmurHash3 of bone name (seed=0xFFFFFFFF)
+8      4B    trackHdrOffs    uint32 offset to first track header (mot-relative)
```

### 3.3 Key Difference: Pointer Width and Extra Fields

| Feature            | RE2 (v65)  | RE3 (v78)  |
|--------------------|------------|------------|
| Bone clip size     | 24 bytes   | 12 bytes   |
| Track offset type  | uint64     | uint32     |
| Extra float at +8  | Yes        | No         |
| Extra padding +12  | Yes        | No         |

The `trackFlags1` byte determines how many tracks follow:
- Bit 0 (0x01): position track present
- Bit 1 (0x02): rotation track present
- Bit 2 (0x04): scale track present
- Number of tracks = popcount(trackFlags1 & 0x07), minimum 1

The bone clips are stored as a contiguous array at `boneClipHdrOffs`, with
`boneClipCount` entries.

---

## 4. TRACK HEADERS

Each bone clip has 1-3 tracks (position, rotation, scale). Track headers
describe the keyframe data layout.

### 4.1 RE2 Track Header (40 bytes)

```
Offset  Size  Field            Description
------  ----  -----            -----------
+0      4B    flags            Track type + compression format
+4      4B    keyCount         Number of keyframes
+8      4B    frameRate        Frame rate (RE2 extra field, e.g. 30)
+12     4B    maxFrame         Float: max frame number (RE2 extra field)
+16     8B    frameIndOffs     uint64 offset to frame index array (mot-relative)
+24     8B    frameDataOffs    uint64 offset to keyframe data (mot-relative)
+32     8B    unpackDataOffs   uint64 offset to decompression params (mot-relative)
```

### 4.2 RE3 Track Header (20 bytes)

```
Offset  Size  Field            Description
------  ----  -----            -----------
+0      4B    flags            Track type + compression format
+4      4B    keyCount         Number of keyframes
+8      4B    frameIndOffs     uint32 offset to frame index array (mot-relative)
+12     4B    frameDataOffs    uint32 offset to keyframe data (mot-relative)
+16     4B    unpackDataOffs   uint32 offset to decompression params (mot-relative)
```

### 4.3 Key Difference: Extra Fields and Pointer Width

| Feature             | RE2 (v65)  | RE3 (v78)  |
|---------------------|------------|------------|
| Track header size   | 40 bytes   | 20 bytes   |
| Pointer type        | uint64     | uint32     |
| frameRate field     | Yes (+8)   | No         |
| maxFrame field      | Yes (+12)  | No         |

### 4.4 Track Flags Encoding

The `flags` field encodes both the track type and compression format:

```
Bits 0-11  (flags & 0xFFF):    Track type
  0x0112 = rotation
  0x00F2 = translation/position
  0x0372 = translation (alternate)

Bits 12+   ((flags >> 12) & 0xFFFFF):  Compression format / sub-type
```

Known flag values:

| Flag Value    | Meaning                          | Version |
|---------------|----------------------------------|---------|
| 0x004B0912    | Uncompressed rotation, 12 bpf    | RE2     |
| 0x004C0912    | Uncompressed rotation, 12 bpf    | RE3     |
| 0x00400372    | Uncompressed translation (both)  | Both    |
| 0x004X_0112   | Compressed rotation              | RE2     |
| 0x002X_0112   | Compressed rotation              | RE3     |
| 0x004X_00F2   | Compressed translation           | RE2     |
| 0x002X_00F2   | Compressed translation           | RE3     |

The high nibble pattern: RE2 uses 0x4X (bit pattern indicating uint64 offsets),
RE3 uses 0x2X (indicating uint32 offsets).

---

## 5. KEYFRAME DATA FORMAT

### 5.1 Uncompressed Tracks

When `unpackDataOffs == 0`, the track is uncompressed:
- **Rotation**: 12 bytes per keyframe (3x float32: X, Y, Z of an Euler/axis)
- **Translation**: 12 bytes per keyframe (3x float32: X, Y, Z position)

Frame indices (when `frameIndOffs > 0`) are stored as uint16 values indicating
which frames have keyframes.

### 5.2 Compressed Tracks (Quantized Quaternion Rotation)

When `unpackDataOffs > 0`, the rotation data is compressed using quantized
quaternions with an "unpack" parameter block.

#### Unpack Data Block (32 bytes = 8x float32)

```
Offset  Field        Description
------  -----        -----------
+0      scale[0]     X range (max - min)
+4      scale[1]     Y range
+8      scale[2]     Z range
+12     scale[3]     W range
+16     base[0]      X minimum value
+20     base[1]      Y minimum
+24     base[2]      Z minimum
+28     base[3]      W minimum
```

#### RE2 Compressed Rotation: 4 bytes per keyframe (4x8-bit XYZW)

```
For each keyframe (4 bytes):
  byte[0] -> qX = base[0] + (byte[0] / 255.0) * scale[0]
  byte[1] -> qY = base[1] + (byte[1] / 255.0) * scale[1]
  byte[2] -> qZ = base[2] + (byte[2] / 255.0) * scale[2]
  byte[3] -> qW = base[3] + (byte[3] / 255.0) * scale[3]
```

This gives all 4 quaternion components at 8-bit precision. The quaternion
magnitude should be ~1.0. Scripts confirmed this produces valid quaternions
with magnitudes near 1.0.

#### RE3 Compressed Rotation: Variable bytes per keyframe (2-5 bpk)

RE3 uses a more aggressive variable-rate compression. The number of bytes
per keyframe varies by bone and is determined by the sub-flag in the track
flags field ((flags >> 12) & 0xF):

| Bytes/Key | Encoding                                           | Status    |
|-----------|----------------------------------------------------|-----------|
| 2 bpk     | Sub-flag dependent: 16-bit single or 2x8-bit       | Partially decoded |
| 3 bpk     | 3x8-bit XYZ, W reconstructed from unit constraint  | CONFIRMED WORKING |
| 4 bpk     | 4x8-bit XYZW (same as RE2) OR unknown packing      | Partially decoded |
| 5 bpk     | Unknown packing (possibly 10-bit or SoA)           | NOT decoded |

**3 bpk decode formula (confirmed):**
```python
qX = base[0] + (raw[0] / 255.0) * scale[0]
qY = base[1] + (raw[1] / 255.0) * scale[1]
qZ = base[2] + (raw[2] / 255.0) * scale[2]
qW = sqrt(max(0, 1 - qX*qX - qY*qY - qZ*qZ))  # reconstructed
```

**2 bpk decode (partial, sub-flag dependent):**
- sub_flag=1: 16-bit single component (uint16 LE), other 2 at midpoint
- sub_flag=3: 2x8-bit for two components, third at midpoint
- W always reconstructed from unit quaternion constraint

**4 bpk and 5 bpk:**
Multiple decode approaches were tested (SoA layout, 10-bit packing, 11-11-10 packing,
permuted byte orders, cubic Hermite interpretation). None produced consistently
smooth results compared to the known-good 3 bpk decode. The Rosetta Stone approach
(comparing same bone's data between entries with different bpk) showed that
direct 4x8-bit decode matches poorly, suggesting the 4/5 bpk formats in RE3
v78 use a different packing than RE2's straightforward 4x8-bit scheme.

**This is one of the unsolved problems**: the 4-bpk and 5-bpk RE3 compression
formats remain partially cracked at best.

---

## 6. BONE HASH SYSTEM

### 6.1 Hash Algorithm

Both RE2 and RE3 use **MurmurHash3 (32-bit)** with seed `0xFFFFFFFF` on the
UTF-16LE encoded bone name to produce the bone hash stored in bone clip headers.

```python
def murmurhash3_32(name_string, seed=0xFFFFFFFF):
    data = name_string.encode('utf-16-le')
    # Standard MurmurHash3 32-bit algorithm
    ...
    return hash_uint32
```

### 6.2 Known Bone Names and Hashes

From the scripts' `known_names` dictionary and runtime dumps:

| Hash         | Bone Name    | Skeleton Role        |
|--------------|--------------|----------------------|
| 0xABA7DE3C   | root         | Root transform       |
| 0x5DCE2C70   | Null_Offset  | Null offset node     |
| 0xCC3297EA   | COG          | Center of gravity    |
| 0xA6993368   | hips         | Hip joint            |
| 0x31838B82   | spine_0      | Lower spine          |
| 0x80973DA1   | spine_1      | Middle spine         |
| 0xB344F241   | spine_2      | Upper spine          |
| 0xD2D4DEFA   | neck_0       | Lower neck           |
| 0x00A6D31D   | neck_1       | Upper neck           |
| 0x2BF882E3   | head         | Head                 |

---

## 7. BONE MAPPING STATUS: RE3 to RE2

### 7.1 Cross-Game Bone Hash Overlap

From `bone_mapping.json` (generated by `analyze_deep_format.py`):

| Category        | Count | Description                                |
|-----------------|-------|--------------------------------------------|
| Shared hashes   | 88    | Bones with identical hash in both games    |
| RE2-only hashes | 31    | Bones unique to RE2's skeleton             |
| RE3-only hashes | 88    | Bones unique to RE3's (Jill) skeleton      |

The 88 shared hashes represent bones that exist in both skeletons with the
same name (producing the same MurmurHash3). Only 10 of these have known
human-readable names; the rest are labeled "unknown" (hash only).

### 7.2 Current Index Mapping (bone_index_mapping.json)

From `build_bone_map.py`, 31 bones are currently mapped between RE3 dump
joint indices (0-79) and RE2 bone clip indices:

| RE3 Dump Idx | Hash         | Name         | RE2 BC# |
|--------------|--------------|--------------|---------|
| 0            | 0xABA7DE3C   | root         | 0       |
| 1            | 0x5DCE2C70   | Null_Offset  | 1       |
| 2            | 0xCC3297EA   | COG          | 2       |
| 3            | 0xA6993368   | hips         | 3       |
| 19           | 0xAC9ED8FB   | ???          | 103     |
| 20           | 0x9108DB97   | ???          | 114     |
| 21           | 0xB2D65D4E   | ???          | 118     |
| 22           | 0xF7370F15   | ???          | 119     |
| 23           | 0x2472B158   | ???          | 120     |
| 24           | 0x2AD23EDF   | ???          | 121     |
| 25           | 0x2E2ACC82   | ???          | 122     |
| 27           | 0x85106CC8   | ???          | 115     |
| 28           | 0x1EE21675   | ???          | 116     |
| 29           | 0xEB81F587   | ???          | 117     |
| 32           | 0xE9357BB1   | ???          | 104     |
| 33           | 0xF391491E   | ???          | 105     |
| 34           | 0x6AF4DA25   | ???          | 109     |
| 35           | 0xF1A1BC46   | ???          | 110     |
| 36           | 0xFBECEF3C   | ???          | 111     |
| 37           | 0x94D80D93   | ???          | 112     |
| 38           | 0x8D6BB775   | ???          | 113     |
| 40           | 0xDEC86F20   | ???          | 106     |
| 43           | 0xCC75B447   | ???          | 107     |
| 44           | 0x686FB3FB   | ???          | 108     |
| 61           | 0x31838B82   | spine_0      | 4       |
| 62           | 0x80973DA1   | spine_1      | 5       |
| 63           | 0xB344F241   | spine_2      | 9       |
| 76           | 0xB11B6190   | ???          | 15      |
| 77           | 0xDDE5B111   | ???          | 63      |
| 78           | 0x336174B7   | ???          | 65      |
| 79           | 0xEB6AAF75   | ???          | 73      |

### 7.3 Gap Analysis: 49 Bones NOT Mapped

Of the 80 bones in the RE3 dump (indices 0-79), **49 are NOT mapped** to RE2.
These are bones whose hash exists only in RE3's skeleton (the `re3_only` set
in bone_mapping.json, which has 88 entries).

**Why they are missing:**
- RE3 (Jill) and RE2 (Claire/Leon) have different skeletons
- Jill has extra bones for her specific rig (hair, clothing, accessories)
- Many bones in the dump range 4-18 and 26, 30-31, 39, 41-42, 45-60, 64-75 have
  hashes that appear only in RE3 motlists, indicating skeleton-specific bones
- Without bone names for these unknown hashes, there is no way to semantically
  match them to equivalent RE2 bones

**Critical missing bones (likely):**
- RE3 dump indices 4-18: These appear to be arm/leg chain bones (indices
  suggest left/right limb hierarchy) but their hashes do not appear in RE2
- Indices 45-60: Likely finger bones and fine detail bones

**Proposed approach to complete mapping:**
1. Dump actual bone names from RE3's runtime skeleton using REFramework
   (the current dump uses generic "joint_N" names because the Lua script
   did not access the JointTree name table)
2. Dump RE2's full bone name list similarly
3. Match by name (e.g., "L_UpperArm" in both games)
4. For unmatched bones, use parent/child hierarchy position matching

### 7.4 Named Bone Dump Status

The RE3 dodge dump (`dodge_dump.txt`) uses generic names "joint_0" through
"joint_79" -- the Lua dumper did not extract real bone names.

A second dump file (`dodge_dump_named.txt`) was created with real bone names.
The `inject_real_dodge.py` script parses this named dump and finds **common
bones** between RE2 and RE3 by name string matching.

From `inject_real_dodge.py`, the common named bones found include:
root, Null_Offset, COG, hips, spine_0, spine_1, spine_2, neck_0, neck_1, head
(plus potentially more from the named dump).

---

## 8. DODGE ANIMATION DATA

### 8.1 RE3 Dodge Dump Format

The dodge dump (`dodge_dump.txt`) captured from RE3 runtime contains:

```
BONE_COUNT=80
BONE|<index>|<parent>|<name>
...
FRAME_COUNT=120
FRAME=0
T|<bone_idx>|<qX>|<qY>|<qZ>|<qW>|<pX>|<pY>|<pZ>
T|<bone_idx>|...
...
FRAME=1
...
```

- **120 frames** of animation data
- **80 bones** per frame
- Each bone has: quaternion rotation (qX, qY, qZ, qW) + position (pX, pY, pZ)
- Data is in **local space** (bone-relative transforms)
- This is the Escape/dodge animation captured during actual gameplay

### 8.2 Data Quality Assessment

- Frame 0 data shows reasonable quaternion values (magnitudes ~1.0)
- Root bone (idx 0) has identity rotation (0,0,0,1) and zero position -- expected
- Spine/torso bones show small rotations typical of an idle-to-dodge transition
- Limb bones show larger rotations (e.g., joint_16: qX=0.739, suggesting a
  bent arm position)
- The 120-frame capture at 30fps represents a 4-second animation clip
- Position data is sparse: many bones have (0,0,0) position, indicating
  rotation-only animation with position inherited from the skeleton rest pose

### 8.3 RE3 Binary Dodge Entry (Entry 47)

In the RE3 motlist binary (`base_cmn_move.motlist.99`), the dodge animations are
at entries 47-52 (named `pl2000_es_0410_KFF_Escape_L0` through `Escape_R180`).

Entry 47 track breakdown by bytes-per-keyframe:
- bpk=2: Some tracks (limited motion bones)
- bpk=3: Several tracks (CONFIRMED decodable)
- bpk=4: Many tracks (partially decoded)
- bpk=5: Some tracks (not decoded)

---

## 9. CONVERTER STATUS AND HISTORY

### 9.1 Approaches Attempted

The scripts document a progression of increasingly sophisticated conversion attempts:

#### Attempt 1: Version Patching (`brute_convert.py`)
- **Method**: Copy RE3 motlist, patch version bytes (99->85, 78->65), patch bone count
- **Result**: FAILED -- RE2 crashes because the internal structure (bone clip
  sizes, track sizes, offset widths) are all wrong. Version patching alone
  does not fix the uint32-vs-uint64 offset and 12-vs-24 byte bone clip differences.

#### Attempt 2: Full Format Converter (`motlist_converter.py`)
- **Method**: Parse RE3 structure, rebuild in RE2 format (expand 12->24 byte bone
  clips, 20->40 byte track headers, convert uint32->uint64 offsets, fix all
  internal offsets)
- **Result**: PARTIALLY FAILED -- The converter was written with extensive offset
  recalculation logic, but `find_format_error.py` revealed that the rebuilt
  offsets do not match RE2's expected layout. Many secondary offset fields
  (+0x10, +0x30, +0x38, +0x48) were incorrectly shifted. The motSize field,
  bone header offset table, and clip file offset all had misaligned values.

#### Attempt 3: Keyframe Data Swap (`swap_keyframes.py`, `swap_dodge_safe.py`)
- **Method**: Take RE2's own motlist (correct format), only replace keyframe
  float data at existing offsets with RE3 data. Zero structural changes.
- **Result**: PARTIALLY WORKED but wrong data type -- assumes uncompressed
  (12 bytes/key float32 XYZ) data format. Most RE3 dodge tracks are actually
  compressed (quantized), so copying raw bytes produces garbage.

#### Attempt 4: Decompress + Recompress (`recompress_dodge.py`)
- **Method**: Decompress RE3 quaternions from compressed format, compute new
  RE2-format unpack parameters, recompress as 4x8-bit for RE2.
- **Result**: PARTIALLY WORKED for 3-bpk tracks. Failed for 4/5-bpk tracks
  because the RE3 compression format is not fully decoded. Scripts report that
  only 3-bpk tracks can be reliably decompressed.

#### Attempt 5: Delta-Based Injection (`inject_dodge_anim.py`, `inject_real_dodge.py`)
- **Method**: Use runtime-dumped quaternion data (from dodge_dump_named.txt),
  compute rotation deltas from Jill's neutral to dodge pose, apply those deltas
  to Claire's existing bone rotations, encode back into RE2's quantized format.
- **Result**: Most promising approach. Uses actual runtime data (bypassing
  binary compression entirely). Limited by:
  - Only 31 of 80 bones are mapped
  - Encoding dodge quaternions into RE2's 8-bit quantized range causes clipping
    (dodge rotations may exceed the original animation's quantization range)
  - Would need to rewrite the unpack parameters AND the frame data simultaneously

#### Attempt 6: Minimal Test (`minimal_test.py`)
- **Method**: Take RE2's own motlist, change just one character in a name string,
  package as PAK to verify the mod pipeline.
- **Result**: Used to validate that PAK packaging and deployment works correctly
  before attempting data modifications.

### 9.2 Why Binary Conversion Has Not Worked

The core problems with binary .motlist conversion:

1. **Structural complexity**: Every internal offset must be recalculated when
   expanding bone clips (12->24) and track headers (20->40). A single wrong
   offset causes the game to crash or silently ignore the file.

2. **RE3 compression not fully decoded**: The 4-bpk and 5-bpk rotation formats
   in RE3 v78 use an unknown packing scheme. Without decoding these, only
   ~30-40% of bone tracks can be converted (the 3-bpk ones).

3. **Bone mapping incomplete**: Only 31 of 80 bones are mapped. Even if the
   format conversion worked perfectly, half the skeleton would have no data.

4. **Quantization range mismatch**: RE2's existing animations have specific
   quantization ranges (base + scale). Dodge rotations may fall outside these
   ranges, requiring the unpack parameters to be rewritten -- which then
   invalidates all other keyframes in that track.

---

## 10. RECOMMENDED APPROACH

### 10.1 Assessment: Binary Conversion vs. Runtime Override

**Binary .motlist conversion is NOT the recommended path forward.** The reasons:
- Too many unsolved problems (compression, offset math, incomplete bone mapping)
- Fragile: any version update could break the format
- Requires solving the full RE3 v78 compression before any conversion can be complete

**Runtime bone override (reading dump data per-frame via Lua) IS the recommended approach.**

### 10.2 Runtime Override Architecture

The runtime approach works as follows:

1. **Data source**: Use the dodge_dump_named.txt file (120 frames x 80 bones,
   with actual bone names, quaternion rotations + positions)

2. **Bone matching**: Match RE3 bone names to RE2 bone names at runtime using
   REFramework's JointTree API

3. **Per-frame application**: On each game frame:
   - Map current animation progress (0.0-1.0) to dump frame number (0-119)
   - For each matched bone: read the target quaternion from the dump
   - Compute delta from Jill's rest pose to dodge pose
   - Apply delta to Claire's current bone rotation
   - Use REFramework's `set_local_rotation()` or `set_rotation()` API

4. **Trigger**: Activate the override when the dodge ability triggers (via
   game state detection in Lua)

### 10.3 Data and Tools Still Needed

For the runtime approach to work, the following are required:

1. **Complete named bone dump from RE3** -- The current `dodge_dump_named.txt`
   exists but its completeness needs verification. All 80 bones should have
   real names, not "joint_N".

2. **Complete named bone dump from RE2** -- The `re2_bones.txt` file exists
   (read by `inject_real_dodge.py`) with bone names and rest-pose quaternions.
   Needs verification that it covers all relevant bones.

3. **Full bone name matching table** -- A mapping from RE3 bone name to RE2
   bone name for all common bones. The 10 known names + hash-based matching
   gives 31 bones. With real names from both skeletons, this could potentially
   reach 50-60+ matched bones.

4. **REFramework Lua script** -- A script that:
   - Loads the dump data into memory
   - Detects when dodge is triggered
   - Applies per-frame bone overrides
   - Handles interpolation for smooth transitions in/out of dodge

5. **Position data handling** -- The dump includes position data, but most
   bones are rotation-only. For bones with significant position changes
   (root/COG translation during the dodge roll), position data must also
   be applied.

### 10.4 Fallback: Hybrid Approach

If runtime override proves too slow (80 bones x per frame), a hybrid approach:

1. Use binary injection for the ~31 mapped bones with 3-bpk compression
   (where we can decode RE3 data reliably)
2. Use runtime override only for the remaining bones that have dump data
   but no binary mapping
3. This reduces the per-frame Lua work to ~15-20 bones

---

## 11. APPENDIX: FORMAT COMPARISON TABLE

```
| Field                | RE2 (.motlist.85 / v65) | RE3 (.motlist.99 / v78)  |
|----------------------|-------------------------|--------------------------|
| Motlist version      | 85                      | 99                       |
| Mot entry version    | 65                      | 78                       |
| Motlist magic        | "mlst"                  | "mlst"                   |
| Mot entry magic      | "mot "                  | "mot "                   |
| Mot header size      | 0x74 bytes              | 0x74 bytes               |
| Bone clip size       | 24 bytes                | 12 bytes                 |
| Track header size    | 40 bytes                | 20 bytes                 |
| Internal offset type | uint64 (8 bytes)        | uint32 (4 bytes)         |
| Track extra fields   | frameRate + maxFrame    | (none)                   |
| Bone clip extra      | uknFloat + padding      | (none)                   |
| Rot compressed bpk   | 4 (always 4x8-bit)     | 2, 3, 4, or 5 (variable)|
| Rot flag pattern     | 0x4X_0112               | 0x2X_0112                |
| Trans flag pattern   | 0x4X_00F2               | 0x2X_00F2                |
| Uncompressed rot flag| 0x4B0912 (4915474)      | 0x4C0912 (4981010)       |
| Uncompressed trans   | 0x400372 (4194546)      | 0x400372 (4194546)       |
| Hash algorithm       | MurmurHash3-32 seed=0xFFFFFFFF | Same              |
| String encoding      | UTF-16LE                | UTF-16LE                 |
| Byte order           | Little-endian           | Little-endian            |
```

---

## 12. APPENDIX: SCRIPT REFERENCE

| Script                    | Purpose                                              |
|---------------------------|------------------------------------------------------|
| analyze_motlist.py        | Side-by-side hex comparison of RE2 vs RE3 headers    |
| analyze_re2_motlist.py    | Deep byte-level analysis of RE2 bone clips & tracks  |
| analyze_full_format.py    | Complete format spec generator for both versions     |
| analyze_deep_format.py    | Cross-game bone hash analysis, joint index mapping   |
| crack_mot_format.py       | Deep mot entry analysis with string extraction       |
| crack_re3_compression.py  | Tests multiple quaternion decode formulas for RE3    |
| crack_bpk4_final.py       | Exhaustive permutation testing for 4-bpk decode      |
| motlist_converter.py      | Full RE3->RE2 format converter (structural rebuild)  |
| brute_convert.py          | Version-patching approach (patch bytes in place)     |
| verify_conversion.py      | Byte-level verification of converted vs original     |
| inject_dodge.py           | First injection attempt (RE2 format, RE3 binary)     |
| inject_dodge_anim.py      | Delta-based injection from binary compressed data    |
| inject_real_dodge.py      | Delta-based injection from runtime dump data         |
| build_bone_map.py         | Maps RE3 joint indices to RE2 bone clip hashes       |
| decode_dodge_full.py      | Tests all bpk values for decodability                |
| decompress_test.py        | Validates the base+byte/255*scale decode formula     |
| deep_compare.py           | Structural comparison of RE2 vs RE3 motlist headers  |
| reverse_mot.py            | Lists all motion names, finds dodge entries           |
| rosetta_crack.py          | Compares same bone across entries with different bpk |
| rosetta_crack2.py         | Tests SoA layout and 16-bit hypotheses               |
| test_soa.py               | Tests Structure-of-Arrays byte layout for 4/5 bpk   |
| swap_keyframes.py         | Direct float data swap between RE2 and RE3           |
| swap_dodge_safe.py        | Track-type-aware swap (rotation only, skip root)     |
| recompress_dodge.py       | Decompress RE3 + recompress for RE2 format           |
| check_dynbank.py          | IL2CPP dump analysis for MotionBank classes          |
| check_pak_hash.py         | MurmurHash3 path testing for PAK file entries        |
| check_unpack.py           | Analyzes RE2 unpack data across multiple tracks      |
| find_decodable_entry.py   | Finds RE3 entries where all bones use bpk<=3         |
| find_format_error.py      | Byte-level comparison of original vs converted file  |
| minimal_test.py           | Minimal modification test for PAK pipeline           |
| format_comparison.txt     | Summary table of RE2 vs RE3 format differences       |
| bone_mapping.json         | 88 shared + 31 RE2-only + 88 RE3-only bone hashes   |
| bone_index_mapping.json   | 31-bone mapping: RE3 dump index -> RE2 bone clip     |

---

## 13. APPENDIX: BINARY LAYOUT DIAGRAMS

### Motlist File Structure (both versions)

```
[Motlist Header]           0x00 - 0x33
[Motlist Name String]      0x34 - variable (UTF-16LE, null terminated, aligned)
[Entry Pointer Table]      N x uint64 offsets
[Padding to 16-byte align]
[Mot Entry 0]              Full mot entry with header + name + bones + tracks + data
[Mot Entry 1]              ...
...
[Mot Entry N]
[Collection/CLIP Data]     Referenced by colOffs
```

### Mot Entry Internal Structure

```
[Mot Header]               0x00 - 0x73 (version, magic, offsets, counts, timing)
[Motion Name]              UTF-16LE at namesOffs (typically 0x74)
[Bone Name Strings]        Optional: bone name strings section
[Padding]
[Bone Clip Headers]        Array at boneClipHdrOffs (24B each RE2, 12B each RE3)
[Track Headers]            Array (40B each RE2, 20B each RE3), pointed by bone clips
[Frame Index Arrays]       uint16 frame numbers, pointed by tracks
[Frame Data]               Keyframe bytes (compressed) or floats (uncompressed)
[Unpack Data Blocks]       32 bytes each (8x float32), for compressed tracks
[Secondary Data]           Bone header offsets, clip data, other referenced sections
```

### Compressed Rotation Track Data Flow

```
Track Header
  -> unpackDataOffs -> [scale_X, scale_Y, scale_Z, scale_W, base_X, base_Y, base_Z, base_W]
  -> frameDataOffs  -> [byte0, byte1, byte2, byte3]  (per keyframe, RE2 4-bpk)
  -> frameIndOffs   -> [uint16, uint16, ...]          (frame indices)

Decode: component_i = base_i + (byte_i / 255.0) * scale_i
```
