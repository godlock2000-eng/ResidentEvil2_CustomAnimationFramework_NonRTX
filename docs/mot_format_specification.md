# RE Engine .mot / .motlist Binary Format Specification

## Comprehensive Reverse Engineering Report

**Source material**: 30+ Python reverse-engineering scripts, format comparison data, bone mapping files, existing documentation, IL2CPP type dumps
**Games analyzed**: Resident Evil 2 Remake (.motlist.85), Resident Evil 3 Remake (.motlist.99)
**Date**: 2026-02-08

---

## Table of Contents

1. [Executive Summary](#1-executive-summary)
2. [File Extension and Versioning](#2-file-extension-and-versioning)
3. [Motlist Container Format](#3-motlist-container-format)
4. [Mot Entry Format](#4-mot-entry-format)
5. [Bone Clip Headers](#5-bone-clip-headers)
6. [Track Headers](#6-track-headers)
7. [Keyframe Data Formats](#7-keyframe-data-formats)
8. [Compressed Rotation Encoding](#8-compressed-rotation-encoding)
9. [Unpack Data Block](#9-unpack-data-block)
10. [Frame Index Arrays](#10-frame-index-arrays)
11. [Bone Hash System](#11-bone-hash-system)
12. [Version Differences: RE2 v85/v65 vs RE3 v99/v78](#12-version-differences-re2-v85v65-vs-re3-v99v78)
13. [Track Flags Encoding](#13-track-flags-encoding)
14. [Translation Track Format](#14-translation-track-format)
15. [Bone Mapping Between Games](#15-bone-mapping-between-games)
16. [What Each Python Script Discovered](#16-what-each-python-script-discovered)
17. [Community Tools and Their Capabilities](#17-community-tools-and-their-capabilities)
18. [Knowledge Assessment: Known, Unknown, Needs Work](#18-knowledge-assessment-known-unknown-needs-work)
19. [Recommendations for Building a .mot Writer](#19-recommendations-for-building-a-mot-writer)
20. [Appendix A: Complete Format Comparison Table](#appendix-a-complete-format-comparison-table)
21. [Appendix B: Binary Layout Diagrams](#appendix-b-binary-layout-diagrams)
22. [Appendix C: Track Flag Registry](#appendix-c-track-flag-registry)

---

## 1. Executive Summary

The RE Engine uses `.motlist` container files to hold collections of `.mot` animation entries. Each `.motlist` file contains a header, a pointer table, and N embedded mot entries. Each mot entry describes one animation clip (e.g., idle, walk, dodge) with bone clip definitions, track headers, and keyframe data.

**Two distinct format versions** exist across RE Engine generations:

| Property | RE2 Remake | RE3 Remake |
|----------|-----------|-----------|
| Motlist extension | `.motlist.85` | `.motlist.99` |
| Motlist version | 85 | 99 |
| Mot entry version | 65 | 78 |
| Internal pointer width | uint64 (8 bytes) | uint32 (4 bytes) |
| Bone clip header size | 24 bytes | 12 bytes |
| Track header size | 40 bytes | 20 bytes |
| Rotation compression | Always 4 bytes/key | Variable 2-5 bytes/key |

The formats share identical magic bytes ("mlst" and "mot "), identical mot header layout (0x74 bytes), identical hash algorithms (MurmurHash3-32), and identical string encoding (UTF-16LE). The differences are concentrated in the sub-structures: bone clip headers, track headers, and keyframe compression.

---

## 2. File Extension and Versioning

RE Engine animation files use a compound extension system:

```
base_cmn_move.motlist.85    -- RE2 Remake motlist (version 85)
base_cmn_move.motlist.99    -- RE3 Remake motlist (version 99)
```

The numeric suffix is the **motlist container version**. Inside each motlist, individual mot entries carry their own **mot entry version**:

| Game | Motlist Version | Mot Entry Version |
|------|----------------|-------------------|
| RE2 Remake | 85 | 65 |
| RE3 Remake | 99 | 78 |
| RE4 Remake | (unknown, likely higher) | (unknown) |
| Devil May Cry 5 | (unknown) | (unknown) |
| Monster Hunter Rise | (unknown) | (unknown) |

The version number is stored as a uint32 at offset 0x00 in both the motlist header and each mot entry header. Individual `.mot` files (standalone, not inside a motlist) would carry the mot entry version at offset 0x00.

---

## 3. Motlist Container Format

### 3.1 Motlist Header

The motlist container header is **structurally identical** between RE2 v85 and RE3 v99. All fields occupy the same offsets.

```
Offset  Size  Type    Field             Description
------  ----  ------  ----------------  -----------
0x00    4B    uint32  version           85 (RE2) or 99 (RE3)
0x04    4B    char[4] magic             "mlst" (0x74736C6D little-endian)
0x08    8B    uint64  padding           Always 0
0x10    8B    uint64  pointersOffs      File offset to the entry pointer table
0x18    8B    uint64  colOffs           File offset to collection/CLIP data at end
0x20    8B    uint64  motlistNameOffs   Offset to motlist name string (typically 0x34)
0x28    8B    uint64  padding2          Always 0
0x30    4B    uint32  numOffs           Number of mot entries in this motlist
0x34    var   UTF16LE motlistName       Null-terminated UTF-16LE name string
```

**Example (RE2)**: version=85, magic="mlst", pointersOffs=0x50, colOffs=0x5885F0, numOffs=63
**Example (RE3)**: version=99, magic="mlst", pointersOffs=0x50, colOffs=0x56E900, numOffs=104

After the name string, padding is added to align to an 8-byte boundary. The entry pointer table immediately follows.

### 3.2 Entry Pointer Table

Located at `pointersOffs`, this is a flat array of `numOffs` uint64 values, each containing the **file offset** to one mot entry:

```
pointersOffs + 0*8  -> uint64 file_offset_to_mot_entry_0
pointersOffs + 1*8  -> uint64 file_offset_to_mot_entry_1
...
pointersOffs + (N-1)*8 -> uint64 file_offset_to_mot_entry_N-1
```

Entry sizes are determined by the distance between consecutive offsets. The last entry extends to `colOffs` or the end of the file.

### 3.3 Collection/CLIP Data

At the end of the file (at `colOffs`), there is a collection data section. Its internal format has not been fully reverse-engineered, but it appears to contain metadata about the animation collection. Converting between versions requires copying this section and adjusting the `colOffs` pointer.

### 3.4 Verified Motlist Metrics

| Property | RE2 base_cmn_move | RE3 base_cmn_move |
|----------|-------------------|-------------------|
| File size | 5,802,968 bytes | 5,698,240 bytes |
| Entry count | 63 | 104 |
| First entry offset | 0x250 | 0x390 |
| Collection offset | 0x5885F0 | 0x56E900 |
| Pointer table at | 0x50 | 0x50 |

---

## 4. Mot Entry Format

Each mot entry is a self-contained animation clip. Every internal offset within a mot entry is **relative to the start of that mot entry** (not relative to the file start). This is a critical detail for both parsing and writing.

### 4.1 Mot Entry Header (0x74 bytes)

The mot header layout is **identical** between RE2 v65 and RE3 v78. All 0x74 bytes occupy the same semantic positions.

```
Offset  Size  Type    Field                RE2 (v65)     RE3 (v78)     Description
------  ----  ------  -------------------- ------------- ------------- -----------
0x00    4B    uint32  mot_version          65            78            Version number
0x04    4B    char[4] magic                "mot "        "mot "        Magic bytes (0x20746F6D)
0x08    4B    uint32  unknown_08           varies        varies        Unknown
0x0C    4B    uint32  motSize              entry size    0             Total entry size (RE2 only)
0x10    8B    uint64  offsToBoneHdrOffs    offset        offset        Offset to bone header offsets table
0x18    8B    uint64  boneClipHdrOffs      offset        offset        Offset to bone clip header array
0x20    8B    uint64  reserved_20          0             0             Reserved
0x28    8B    uint64  reserved_28          0             0             Reserved
0x30    8B    uint64  clipFileOffset       offset        offset        Offset to clip/collection data section
0x38    8B    uint64  offs1                offset        offset        Secondary offset (unknown purpose)
0x40    8B    uint64  reserved_40          0             0             Reserved
0x48    8B    uint64  offs2                offset        offset        Tertiary offset (unknown purpose)
0x50    8B    uint64  namesOffs            0x74          0x74          Offset to motion name string
0x58    4B    float32 frameCount           e.g. 3039.0   e.g. 3039.0  Total frame count
0x5C    4B    float32 blending             0.0           0.0           Blend time/weight
0x60    4B    float32 uknFloat1            0.0           0.0           Unknown float
0x64    4B    float32 uknFloat2            3039.0        3039.0        Unknown float (often equals frameCount)
0x68    2B    uint16  boneCount            e.g. 123      e.g. 185      Skeleton bone count (padded uint16)
0x6A    2B    uint16  boneClipCount        e.g. 123      e.g. 185      Number of bone clip entries
0x6C    1B    uint8   uknPtr2Count         varies        varies        Unknown count
0x6D    1B    uint8   uknPtr3Count         varies        varies        Unknown count
0x6E    2B    uint16  frameRate            60            60            Frame rate (e.g., 30 or 60)
0x70    2B    uint16  uknPtrCount          varies        varies        Unknown count
0x72    2B    uint16  uknShort2            varies        varies        Unknown
```

### 4.2 Motion Name String

Immediately after the 0x74-byte header (at `namesOffs`, typically 0x74), the **motion name** is stored as a UTF-16LE null-terminated string. Examples:

- `pl10_0160_KFF_Gazing_Idle_F_Loop`
- `pl2000_es_0410_KFF_Escape_L0`

After the name string ends (null terminator), padding is added to align to a 16-byte boundary before the bone clip data begins.

### 4.3 Field Notes

- `motSize` at 0x0C: Only populated in RE2 v65 (contains total entry size). In RE3 v78 this is 0.
- `frameCount` at 0x58: Stored as a float. A value of 3039.0 represents 3039 frames at the given frame rate.
- `boneCount` at 0x68 and `boneClipCount` at 0x6A: In practice these are often equal, meaning every skeleton bone has animation data.
- `namesOffs` at 0x50: Almost always 0x74, meaning the name starts right after the header.

---

## 5. Bone Clip Headers

Bone clips describe which bones are animated and point to their track data. **This is the first major structural difference between RE2 and RE3.**

### 5.1 RE2 Bone Clip Header (24 bytes)

```
Offset  Size  Type    Field           Description
------  ----  ------  ----------      -----------
+0      2B    uint16  boneIndex       Skeleton joint index
+2      1B    uint8   trackFlags1     Bit flags: bit0=position, bit1=rotation, bit2=scale
+3      1B    uint8   trackFlags2     Additional flags (RE2: 0x00, RE3: 0xFF)
+4      4B    uint32  boneHash        MurmurHash3-32 of bone name (seed=0xFFFFFFFF)
+8      4B    float32 uknFloat        Unknown float (observed as 1.0 in RE2)
+12     4B    uint32  padding         Zero padding
+16     8B    uint64  trackHdrOffs    Offset to first track header (mot-entry-relative)
```

### 5.2 RE3 Bone Clip Header (12 bytes)

```
Offset  Size  Type    Field           Description
------  ----  ------  ----------      -----------
+0      2B    uint16  boneIndex       Skeleton joint index
+2      1B    uint8   trackFlags1     Bit flags: bit0=position, bit1=rotation, bit2=scale
+3      1B    uint8   trackFlags2     Additional flags (observed as 0xFF in RE3)
+4      4B    uint32  boneHash        MurmurHash3-32 of bone name (seed=0xFFFFFFFF)
+8      4B    uint32  trackHdrOffs    Offset to first track header (mot-entry-relative)
```

### 5.3 Key Differences

| Feature            | RE2 (v65)  | RE3 (v78)  |
|--------------------|------------|------------|
| Header size        | 24 bytes   | 12 bytes   |
| Track offset type  | uint64     | uint32     |
| Extra float at +8  | Yes (1.0)  | No         |
| Extra padding +12  | Yes (0)    | No         |
| byte3 value        | 0x00       | 0xFF       |

### 5.4 Track Count Determination

The `trackFlags1` byte determines how many tracks follow for this bone:

- Bit 0 (0x01): Position/translation track present
- Bit 1 (0x02): Rotation track present
- Bit 2 (0x04): Scale track present

Number of tracks = popcount(trackFlags1 & 0x07), with a minimum of 1.

Common values:
- 0x01: 1 track (position only)
- 0x02: 1 track (rotation only)
- 0x03: 2 tracks (position + rotation)
- 0x07: 3 tracks (position + rotation + scale)

The bone clips are stored as a **contiguous array** at `boneClipHdrOffs`, with `boneClipCount` entries. Tracks for each bone clip are stored consecutively starting at `trackHdrOffs`.

---

## 6. Track Headers

Each bone clip has 1-3 tracks (position, rotation, scale). Track headers describe the keyframe data layout. **This is the second major structural difference.**

### 6.1 RE2 Track Header (40 bytes)

```
Offset  Size  Type    Field            Description
------  ----  ------  ----------       -----------
+0      4B    uint32  flags            Track type + compression format (see Section 13)
+4      4B    uint32  keyCount         Number of keyframes
+8      4B    uint32  frameRate        Frame rate (RE2 extra field, e.g. 60)
+12     4B    float32 maxFrame         Maximum frame number (RE2 extra, e.g. 3039.0)
+16     8B    uint64  frameIndOffs     Offset to frame index array (mot-entry-relative)
+24     8B    uint64  frameDataOffs    Offset to keyframe data (mot-entry-relative)
+32     8B    uint64  unpackDataOffs   Offset to decompression parameters (mot-entry-relative)
```

### 6.2 RE3 Track Header (20 bytes)

```
Offset  Size  Type    Field            Description
------  ----  ------  ----------       -----------
+0      4B    uint32  flags            Track type + compression format (see Section 13)
+4      4B    uint32  keyCount         Number of keyframes
+8      4B    uint32  frameIndOffs     Offset to frame index array (mot-entry-relative)
+12     4B    uint32  frameDataOffs    Offset to keyframe data (mot-entry-relative)
+16     4B    uint32  unpackDataOffs   Offset to decompression parameters (mot-entry-relative)
```

### 6.3 Key Differences

| Feature             | RE2 (v65)  | RE3 (v78)  |
|---------------------|------------|------------|
| Header size         | 40 bytes   | 20 bytes   |
| Pointer type        | uint64     | uint32     |
| frameRate field     | Yes (+8)   | No         |
| maxFrame field      | Yes (+12)  | No         |

### 6.4 Pointer Semantics

All three offset fields (`frameIndOffs`, `frameDataOffs`, `unpackDataOffs`) are **mot-entry-relative**. To get the absolute file offset:

```
absolute_offset = mot_entry_file_offset + field_value
```

When `unpackDataOffs == 0`, the track data is uncompressed. When `unpackDataOffs > 0`, the track uses quantized compression and the unpack data block provides the decompression parameters.

---

## 7. Keyframe Data Formats

### 7.1 Uncompressed Tracks

When `unpackDataOffs == 0`, keyframe data is stored as raw float32 triplets:

- **Rotation**: 12 bytes per keyframe (3x float32: X, Y, Z -- likely Euler angles or axis representation)
- **Translation/Position**: 12 bytes per keyframe (3x float32: X, Y, Z coordinates)

Each keyframe occupies 12 bytes. The total data size is `keyCount * 12` bytes.

### 7.2 Compressed Tracks

When `unpackDataOffs > 0`, the keyframe data is quantized. The compression format varies:

**RE2 v65**: Always uses 4 bytes per keyframe (4 x 8-bit values for XYZW quaternion components).

**RE3 v78**: Uses variable compression rates of 2-5 bytes per keyframe depending on the bone and animation complexity. The exact rate is determined by examining the data region size between `frameDataOffs` and `unpackDataOffs`:

```
bytes_per_keyframe = (unpackDataOffs - frameDataOffs) / keyCount
```

### 7.3 Frame Index Arrays

When `frameIndOffs > 0`, frame indices are stored as an array of uint16 values indicating which frames in the animation timeline have keyframes. The array has `keyCount` entries. Between keyframes, the engine interpolates.

When `frameIndOffs == 0` (rare), keyframes are assumed to be at every frame starting from frame 0.

---

## 8. Compressed Rotation Encoding

This section describes the quantized quaternion compression used for rotation tracks. This is the most complex and most-researched aspect of the format.

### 8.1 General Principle

Both RE2 and RE3 use a **min-range quantization** scheme:

```
component_value = base_value + (quantized_byte / max_quantized_value) * scale_value
```

Where:
- `base_value` is the minimum value for that component across all keyframes
- `scale_value` is the range (max - min) for that component
- `quantized_byte` is the compressed value (0-255 for 8-bit)
- `max_quantized_value` is 255 for 8-bit, 65535 for 16-bit

The 8-float unpack data block (Section 9) provides the scale and base values.

### 8.2 RE2 Compressed Rotation: 4 Bytes Per Keyframe (CONFIRMED)

RE2 always uses exactly 4 bytes per keyframe for compressed rotation:

```
For each keyframe (4 bytes, one byte per quaternion component):
  qX = base[0] + (byte[0] / 255.0) * scale[0]
  qY = base[1] + (byte[1] / 255.0) * scale[1]
  qZ = base[2] + (byte[2] / 255.0) * scale[2]
  qW = base[3] + (byte[3] / 255.0) * scale[3]
```

All four quaternion components (X, Y, Z, W) are encoded at 8-bit precision. The resulting quaternion should have magnitude approximately 1.0.

This decode formula has been **confirmed working** through multiple test scripts (`decompress_test.py`, `recompress_dodge.py`). Decoded quaternions consistently produce magnitudes between 0.95 and 1.05.

### 8.3 RE3 Compressed Rotation: Variable Bytes Per Keyframe

RE3 v78 uses a more aggressive variable-rate compression. The number of bytes per keyframe varies per track:

#### 3 bpk (Bytes Per Keyframe) -- CONFIRMED WORKING

```
For each keyframe (3 bytes):
  qX = base[0] + (byte[0] / 255.0) * scale[0]
  qY = base[1] + (byte[1] / 255.0) * scale[1]
  qZ = base[2] + (byte[2] / 255.0) * scale[2]
  qW = sqrt(max(0, 1 - qX^2 - qY^2 - qZ^2))    // W reconstructed from unit quaternion constraint
```

Three components (X, Y, Z) are stored at 8-bit precision. The fourth component (W) is derived from the unit quaternion property |q| = 1. This is the most space-efficient fully decodable format.

Confirmed by: `crack_re3_compression.py`, `rosetta_crack.py`, `decode_dodge_full.py`

#### 2 bpk -- PARTIALLY DECODED

Two bytes per keyframe. Behavior depends on the sub-flag in the track flags field `(flags >> 12) & 0xF`:

**Sub-flag 1**: Single 16-bit component
```
v16 = uint16_le(byte[0], byte[1])
qX = base[0] + (v16 / 65535.0) * scale[0]
qY = base[1] + 0.5 * scale[1]    // midpoint approximation
qZ = base[2] + 0.5 * scale[2]    // midpoint approximation
qW = sqrt(max(0, 1 - qX^2 - qY^2 - qZ^2))
```

**Sub-flag 3**: Two 8-bit components
```
qX = base[0] + (byte[0] / 255.0) * scale[0]
qY = base[1] + (byte[1] / 255.0) * scale[1]
qZ = base[2] + 0.5 * scale[2]    // midpoint approximation
qW = sqrt(max(0, 1 - qX^2 - qY^2 - qZ^2))
```

The 2 bpk format provides low precision and is used for bones with minimal rotation variation.

#### 4 bpk -- NOT FULLY DECODED

Four bytes per keyframe in RE3. Despite being the same byte count as RE2's confirmed format, the RE3 4-bpk format does NOT use the same straightforward 4x8-bit XYZW encoding. Multiple approaches were tested:

Tested and failed:
- Standard 4x8-bit XYZW (base + byte/255 * scale) -- quaternion magnitudes are incorrect
- Byte permutation testing (all 24 permutations) -- no consistent match
- 3-of-4 bytes for XYZ with W reconstructed -- no consistent match
- 10-bit packed (3x10 bits in 30 bits) -- poor results
- 11-11-10 bit packing -- poor results
- Structure-of-Arrays layout (4 separate planes of keyCount bytes) -- tested in `test_soa.py`, showed some promise but not confirmed
- 16-bit pair decode (2x uint16) -- smoothness varies

The "Rosetta Stone" approach (`rosetta_crack.py`) compared the same bone's data between entries using 3-bpk (decodable) and 4-bpk (unknown), but the starting poses differ between animation entries, making direct comparison unreliable.

**Status**: The 4-bpk RE3 format remains an unsolved problem. It may use Structure-of-Arrays layout, a different quantization scheme, or involve the sub-flag field in a way not yet understood.

#### 5 bpk -- NOT DECODED

Five bytes per keyframe. Even less understood than 4-bpk. The `test_soa.py` script tested SoA layouts (4 planes of keyCount bytes with 1 byte left over, or 5 planes) without conclusive results.

**Status**: Completely unsolved. Requires fresh analysis approaches.

---

## 9. Unpack Data Block

When a track is compressed (`unpackDataOffs > 0`), the unpack data block at that offset contains 8 float32 values (32 bytes total):

```
Offset  Size  Field        Description
------  ----  ----------   -----------
+0      4B    scale[0]     X component range (max_X - min_X)
+4      4B    scale[1]     Y component range (max_Y - min_Y)
+8      4B    scale[2]     Z component range (max_Z - min_Z)
+12     4B    scale[3]     W component range (max_W - min_W)
+16     4B    base[0]      X component minimum value
+20     4B    base[1]      Y component minimum value
+24     4B    base[2]      Z component minimum value
+28     4B    base[3]      W component minimum value
```

The decode formula is:
```
component[i] = base[i] + (quantized_value / max_quantized) * scale[i]
```

The encode formula (for writing):
```
quantized_value = round((component[i] - base[i]) / scale[i] * max_quantized)
quantized_value = clamp(quantized_value, 0, max_quantized)
```

For generating unpack parameters from scratch (e.g., when creating a new animation):
```
base[i] = min(all_keyframe_component_i_values)
scale[i] = max(all_keyframe_component_i_values) - base[i]
if scale[i] < epsilon:
    scale[i] = small_nonzero_value  // prevent division by zero during decode
```

---

## 10. Frame Index Arrays

When `frameIndOffs > 0`, the frame index array stores `keyCount` uint16 values, each indicating the frame number at which a keyframe is defined:

```
frameIndOffs -> [uint16 frame_0, uint16 frame_1, ..., uint16 frame_N-1]
```

For example, if an animation has 120 total frames but only 10 keyframes, the frame indices might be: `[0, 12, 24, 36, 48, 60, 72, 84, 96, 108]`.

The game engine interpolates between keyframes to produce smooth animation at intermediate frames.

When `frameIndOffs == 0`, the keyframes cover every frame sequentially (frame 0, 1, 2, ...).

---

## 11. Bone Hash System

### 11.1 Hash Algorithm

Both RE2 and RE3 use **MurmurHash3 (32-bit)** with a fixed seed of `0xFFFFFFFF` applied to the UTF-16LE encoded bone name to produce the bone hash stored in bone clip headers.

```python
import struct

def murmurhash3_32(data, seed=0xFFFFFFFF):
    length = len(data)
    nblocks = length // 4
    h1 = seed & 0xFFFFFFFF
    c1, c2 = 0xcc9e2d51, 0x1b873593

    for i in range(nblocks):
        k1 = struct.unpack_from('<I', data, i*4)[0]
        k1 = (k1 * c1) & 0xFFFFFFFF
        k1 = ((k1 << 15) | (k1 >> 17)) & 0xFFFFFFFF
        k1 = (k1 * c2) & 0xFFFFFFFF
        h1 ^= k1
        h1 = ((h1 << 13) | (h1 >> 19)) & 0xFFFFFFFF
        h1 = (h1 * 5 + 0xe6546b64) & 0xFFFFFFFF

    tail = data[nblocks*4:]
    k1 = 0
    if len(tail) >= 3: k1 ^= tail[2] << 16
    if len(tail) >= 2: k1 ^= tail[1] << 8
    if len(tail) >= 1:
        k1 ^= tail[0]
        k1 = (k1 * c1) & 0xFFFFFFFF
        k1 = ((k1 << 15) | (k1 >> 17)) & 0xFFFFFFFF
        k1 = (k1 * c2) & 0xFFFFFFFF
        h1 ^= k1

    h1 ^= length
    h1 ^= (h1 >> 16)
    h1 = (h1 * 0x85ebca6b) & 0xFFFFFFFF
    h1 ^= (h1 >> 13)
    h1 = (h1 * 0xc2b2ae35) & 0xFFFFFFFF
    h1 ^= (h1 >> 16)
    return h1

# Usage:
hash_value = murmurhash3_32("hips".encode('utf-16-le'))
# Result: 0xA6993368
```

### 11.2 Known Bone Names and Hashes

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

These 10 names were confirmed through runtime dumping via REFramework Lua scripts. The remaining ~170 bone hashes in the motlist files are unresolved (hash only, no name).

### 11.3 PAK File Path Hashing

The RE Engine's PAK archive system also uses MurmurHash3 for path lookups, but with different inputs. The `check_pak_hash.py` script explored various path formats to determine how the game resolves internal resource paths to PAK entries.

---

## 12. Version Differences: RE2 v85/v65 vs RE3 v99/v78

### 12.1 Summary Table

| Aspect | RE2 (.motlist.85 / v65) | RE3 (.motlist.99 / v78) |
|--------|-------------------------|--------------------------|
| Motlist header | Identical layout | Identical layout |
| Entry pointer table | uint64 offsets | uint64 offsets |
| Mot header (0x74 bytes) | Identical layout | Identical layout |
| motSize field (0x0C) | Populated (entry size) | Always 0 |
| Bone clip header | 24 bytes | 12 bytes |
| Track header | 40 bytes | 20 bytes |
| Internal pointers | uint64 | uint32 |
| Extra track fields | frameRate + maxFrame | None |
| Extra bone clip fields | uknFloat + padding | None |
| Compressed rotation bpk | Always 4 (4x8-bit XYZW) | Variable: 2, 3, 4, or 5 |
| Rotation flag pattern | 0x4X_0112 | 0x2X_0112 or 0x4X_0112 |
| Translation flag pattern | 0x4X_00F2 | 0x2X_00F2 or 0x4X_00F2 |
| Uncompressed rot flag | 0x4B0912 (4,915,474) | 0x4C0912 (4,981,010) |
| Uncompressed trans flag | 0x400372 (4,194,546) | 0x400372 (4,194,546) |
| byte3 in bone clip | 0x00 | 0xFF |
| String encoding | UTF-16LE | UTF-16LE |
| Byte order | Little-endian | Little-endian |
| Hash algorithm | MurmurHash3-32 (seed 0xFFFFFFFF) | Same |

### 12.2 Structural Evolution: RE3 is More Compact

RE3 v78 represents a structural optimization over RE2 v65:

1. **Pointer width reduction**: Internal offsets shrunk from uint64 to uint32, saving 4 bytes per pointer. Since mot entries can have hundreds of tracks, this saves significant space.

2. **Header compaction**: Bone clip headers lost the float+padding fields (24 to 12 bytes), and track headers lost the frameRate+maxFrame fields (40 to 20 bytes). This represents a 50% reduction in header overhead.

3. **Improved compression**: The variable bytes-per-keyframe system (2-5 bpk) in RE3 vs the fixed 4-bpk in RE2 allows more efficient storage for bones with limited range of motion.

### 12.3 Why Direct Conversion is Difficult

Converting from RE3 to RE2 requires:
1. Expanding every bone clip header from 12 to 24 bytes (adding float and padding fields)
2. Expanding every track header from 20 to 40 bytes (adding frameRate and maxFrame fields)
3. Converting all internal uint32 offsets to uint64
4. Recalculating every offset in the entire file (since expanding headers shifts all subsequent data)
5. Decompressing variable-bpk data and recompressing as fixed 4-bpk
6. Patching version numbers at both motlist and mot entry levels

The `motlist_converter.py` script attempted this full conversion but failed because the offset recalculation was not perfectly accurate -- a single wrong offset causes the game to crash.

---

## 13. Track Flags Encoding

The `flags` field in track headers encodes both the track type and compression format in a single uint32:

```
Bits 0-11   (flags & 0xFFF):       Track type identifier
Bits 12-15  ((flags >> 12) & 0xF):  Sub-flag (compression detail)
Bits 16+    ((flags >> 16) & 0xFFFF): Format/version indicator
```

### 13.1 Track Type Identifiers

| Type Code | Meaning |
|-----------|---------|
| 0x0F2     | Translation / Position |
| 0x112     | Rotation |
| 0x372     | Translation (alternate, rare) |

### 13.2 Complete Flag Registry (from analyze_full_format.py)

**RE2 Entry 0 Track Type Survey:**

| Flag Value | Type | Count | Meaning |
|------------|------|-------|---------|
| 0x004000F2 | Translation | 104 | Uncompressed position, 12 bytes/key |
| 0x004210F2 | Translation | 2 | Compressed position, format variant |
| 0x004220F2 | Translation | 2 | Compressed position, format variant |
| 0x004230F2 | Translation | 1 | Compressed position, format variant |
| 0x00421112 | Rotation | 16 | Compressed rotation (sub-flag 1) |
| 0x00422112 | Rotation | 12 | Compressed rotation (sub-flag 2) |
| 0x00423112 | Rotation | 2 | Compressed rotation (sub-flag 3) |
| 0x00430112 | Rotation | 33 | Compressed rotation (sub-flag 0, format 3) |
| 0x00431112 | Rotation | 1 | Compressed rotation variant |
| 0x00470112 | Rotation | 1 | Compressed rotation variant |
| 0x004B0112 | Rotation | 38 | Uncompressed rotation, 12 bytes/key |

**RE3 Entry 0 Track Type Survey:**

| Flag Value | Type | Count | Meaning |
|------------|------|-------|---------|
| 0x004000F2 | Translation | 154 | Uncompressed position |
| 0x004200F2 | Translation | 24 | Compressed position |
| 0x004210F2 | Translation | 2 | Compressed position variant |
| 0x004220F2 | Translation | 4 | Compressed position variant |
| 0x004230F2 | Translation | 2 | Compressed position variant |
| 0x004400F2 | Translation | 1 | Compressed position variant |
| 0x004420F2 | Translation | 1 | Compressed position variant |
| 0x00420112 | Rotation | 9 | Compressed rotation (2 bpk) |
| 0x00421112 | Rotation | 17 | Compressed rotation (sub-flag 1) |
| 0x00422112 | Rotation | 10 | Compressed rotation (sub-flag 2) |
| 0x00423112 | Rotation | 2 | Compressed rotation (sub-flag 3) |
| 0x00430112 | Rotation | 22 | Compressed rotation (3 bpk confirmed) |
| 0x00440112 | Rotation | 17 | Compressed rotation (4 bpk) |
| 0x00441112 | Rotation | 2 | Compressed rotation variant |
| 0x00442112 | Rotation | 1 | Compressed rotation variant |
| 0x00443112 | Rotation | 1 | Compressed rotation variant |
| 0x004C0112 | Rotation | 95 | Uncompressed rotation, 12 bytes/key |

### 13.3 Flag Pattern Interpretation

The high bits appear to encode pointer width and format generation:
- `0x4X` prefix: Appears in both RE2 and RE3 -- indicates the base format
- `0x2X` prefix: Appears only in RE3 -- may indicate uint32 pointer mode
- Sub-flag (bits 12-15): Correlates with compression detail (number of components stored, bit precision)

For RE3, the format byte at position `(flags >> 16) & 0xFF` appears to correlate with bytes-per-keyframe:
- `0x42`: 2 bpk
- `0x43`: 3 bpk
- `0x44`: 4 bpk
- `0x45`: 5 bpk (extrapolated)

However, this mapping is not fully confirmed and may be more nuanced.

---

## 14. Translation Track Format

Translation/position tracks (type 0x0F2) follow a similar pattern to rotation tracks:

### 14.1 Uncompressed Translation

When `unpackDataOffs == 0`:
- 12 bytes per keyframe: 3x float32 (X, Y, Z)
- Flag value: 0x004000F2 (both RE2 and RE3)

### 14.2 Compressed Translation

When `unpackDataOffs > 0`:
- Uses the same unpack data block (8 floats) as rotation
- Bytes per keyframe varies
- The unpack data contains scale and base for XYZ (and potentially a 4th component)
- Translation compression appears to use the same min-range quantization as rotation

### 14.3 Translation Track Observations

From the analysis scripts:
- Root bone (0xABA7DE3C) and Null_Offset (0x5DCE2C70) typically have 1-keyframe position tracks (static)
- COG (0xCC3297EA) often has many keyframes for position (center-of-gravity movement)
- Most other bones have 1-keyframe position tracks (animation is rotation-driven)

---

## 15. Bone Mapping Between Games

### 15.1 Cross-Game Bone Hash Overlap

From `bone_mapping.json` (generated by `analyze_deep_format.py`):

| Category | Count | Description |
|----------|-------|-------------|
| Shared hashes | 88 | Bones present in both RE2 and RE3 with identical hash |
| RE2-only hashes | 31 | Bones unique to RE2's skeleton |
| RE3-only hashes | 88 | Bones unique to RE3's (Jill's) skeleton |

### 15.2 Verified Index Mapping

From `bone_index_mapping.json` (generated by `build_bone_map.py`), 31 bones are mapped between RE3 dump joint indices and RE2 bone clip indices:

| RE3 Idx | Hash | Name | RE2 BC# |
|---------|------|------|---------|
| 0 | 0xABA7DE3C | root | 0 |
| 1 | 0x5DCE2C70 | Null_Offset | 1 |
| 2 | 0xCC3297EA | COG | 2 |
| 3 | 0xA6993368 | hips | 3 |
| 61 | 0x31838B82 | spine_0 | 4 |
| 62 | 0x80973DA1 | spine_1 | 5 |
| 63 | 0xB344F241 | spine_2 | 9 |

Plus 24 additional bones with unknown names but matching hashes between games.

### 15.3 Gap Analysis

Of the 80 bones in the RE3 skeleton dump (indices 0-79), 49 are NOT mapped to RE2. These represent skeleton-specific bones (Jill's hair, clothing, accessories, unique limb rigging) that do not have equivalents in RE2's skeleton.

To complete the mapping:
1. Dump real bone names from both games' runtime skeletons using REFramework
2. Match by name (e.g., "L_UpperArm" would match between games)
3. For unmatched bones, use parent/child hierarchy position matching

---

## 16. What Each Python Script Discovered

### 16.1 Analysis and Discovery Scripts

| Script | Key Discovery |
|--------|---------------|
| **analyze_motlist.py** | First comparison of RE2 vs RE3 headers. Confirmed "mlst" magic at 0x04. Identified entry count at 0x10 (as uint64) and data end offset at 0x18. Found UTF-16LE name strings. |
| **deep_compare.py** | Discovered motlist header layout: version at 0x00, magic at 0x04, entry count at 0x10, offsets at 0x18/0x20. Parsed entry offset table. Found "mot " magic at entry+0x04. Identified bone count at 0x30 of motlist. Mapped UTF-16LE motion names. |
| **reverse_mot.py** | Comprehensive mot entry header mapping. Located namesOffs at +0x50, frameCount at +0x58, boneCount at +0x68, boneClipCount at +0x6A, frameRate at +0x6E. Listed all motion names and found dodge entries at indices 47-52 in RE3. |
| **crack_mot_format.py** | Deep analysis of individual mot entries. Mapped key offset fields (+0x10, +0x18, +0x30, +0x48). Located bone name strings after the motion name. Identified where keyframe data starts by scanning for float-like patterns. Tested half-float (float16) data hypothesis. |
| **analyze_re2_motlist.py** | Byte-level analysis of RE2 bone clip structure (24 bytes). Identified byte0/byte1 as joint index (uint16), byte2 as track flags, bone_hash at +4, unknown float at +8, track offset (uint64) at +16. Mapped track header: flags at +0, keyCount at +4, frameDataOffs at +24, unpackDataOffs at +32. |
| **analyze_full_format.py** | Generated complete format specification for both RE2 and RE3. Documented bone clip header sizes (24 vs 12), track header sizes (40 vs 20), all track type flags with counts. Created `motlist_format_spec.txt` and `format_comparison.txt`. |
| **analyze_deep_format.py** | Cross-game bone hash analysis. Implemented MurmurHash3-32. Mapped bone joint indices to hashes. Found 88 shared hashes between games. Generated `bone_mapping.json`. |
| **build_bone_map.py** | Built the 31-bone mapping between RE3 dump indices and RE2 bone clip indices. Cross-referenced with dodge_dump.txt. Generated `bone_index_mapping.json`. |
| **check_dynbank.py** | Analyzed IL2CPP dump for MotionBank-related classes. Found DynamicMotionBankController, MotionListResource, MotionBank fields and methods. |
| **check_pak_hash.py** | Tested MurmurHash3 path variants for PAK file lookup. Explored various path formats (with/without "natives/x64/", different case, with/without version extensions). |

### 16.2 Compression Research Scripts

| Script | Key Discovery |
|--------|---------------|
| **crack_re3_compression.py** | Tested 6 different decode formulas for RE3 compressed rotation. Found that `base + byte/255 * scale` for 4 bytes produces approximately-unit quaternions. Tested 10-bit packing and 11-11-10 packing -- both failed. |
| **decompress_test.py** | Validated the `base + byte/255 * scale` formula on RE2 data (spine_0 bone, hash 0xA6993368). Confirmed quaternion magnitudes near 1.0. Also tested `base + (byte/127.5 - 1.0) * scale` -- this alternate formula did not work. |
| **crack_bpk4_final.py** | Exhaustive permutation testing for 4-bpk decode. Tested all possible assignments of 16-bit + 8-bit to quaternion components (one component gets 16 bits from 2 bytes, two get 8 bits from 1 byte each, fourth reconstructed). Found the best permutation using smoothness scoring, but results were not definitive. |
| **rosetta_crack.py** | "Rosetta Stone" approach: compared the same bone (spine_1) across entries where it uses 3-bpk (decodable) vs 4-bpk (unknown). Ground truth from 3-bpk was used to test all possible 4-bpk decodings. Reverse-engineered what byte values would be needed. Best permutation matching was inconclusive. |
| **rosetta_crack2.py** | Continued Rosetta Stone analysis. Tested if 4-bpk data is stored as 16-bit uint16 pairs (2 components at 16-bit precision). Smoothness analysis showed moderate results. Not definitive. |
| **test_soa.py** | Tested Structure-of-Arrays (SoA) hypothesis: instead of interleaved XYZW bytes, data might be stored as separate planes (all X bytes, then all Y bytes, etc.). For 4-bpk with keyCount=83, tested 4 planes of 83 bytes. Results showed some plausibility but not confirmed. Also tested 5-plane SoA for 5-bpk data. |
| **decode_dodge_full.py** | Comprehensive decode attempt for all bpk variants. Confirmed 3-bpk as fully decodable. Found sub-flag correlation for 2-bpk. Catalogued bpk distribution across dodge entry tracks. |
| **find_decodable_entry.py** | Scanned all RE3 entries to find ones where known bones (hips, spine, neck, head) all use bpk<=3. Found several entries where all data is decodable, useful for testing. |
| **check_unpack.py** | Analyzed RE2 unpack data across multiple tracks. Calculated bytes-per-key from data region sizes. Found that tracks with unpack data consistently use 4 bytes/key in RE2. |

### 16.3 Conversion and Injection Scripts

| Script | Approach | Result |
|--------|----------|--------|
| **brute_convert.py** | Patch version bytes in-place (99->85, 78->65, bone count). | FAILED: Structural mismatch crashes game. |
| **motlist_converter.py** | Full structural conversion (expand headers, recalculate offsets, convert pointer widths). References alphazolam's Motlist Tool. | PARTIALLY FAILED: Offset recalculation errors. |
| **find_format_error.py** | Byte-by-byte comparison of converted vs original RE2 file. | Found specific fields where converted offsets were wrong. |
| **verify_conversion.py** | Compared converted motlist with RE2 original and RE3 source. | Confirmed conversion produced a distinct file with correct version numbers. |
| **swap_keyframes.py** | Swap keyframe float data between RE2 and RE3 (keep RE2 structure, replace float values). | PARTIALLY WORKED for uncompressed tracks only. |
| **swap_dodge_safe.py** | Type-aware swap: only rotation tracks, skip root/COG bones, match by bone hash. | PARTIALLY WORKED but only swaps uncompressed tracks. |
| **recompress_dodge.py** | Decompress RE3 rotation data, recompress as RE2 4x8-bit. | PARTIALLY WORKED for 3-bpk RE3 tracks. |
| **inject_dodge_anim.py** | Delta-based injection using binary compressed data. Compute rotation deltas and apply to RE2. | Limited by incomplete bone mapping and compression knowledge. |
| **inject_real_dodge.py** | Delta-based injection using runtime-dumped quaternion data. Match bones by name. | Most promising binary approach but limited to 31 mapped bones. |
| **minimal_test.py** | Minimal modification (change one character in name string) to test PAK pipeline. | SUCCEEDED: Confirmed PAK modification pipeline works. |

---

## 17. Community Tools and Their Capabilities

### 17.1 Known Tools

**RE-MOT-Editor** (by alphazolam)
- A C# tool for editing .mot and .motlist files
- Referenced in `motlist_converter.py` as the source of structural knowledge
- The converter's docstring explicitly states: "Based on reverse engineering the Motlist Tool by alphazolam"
- Known to define track header fields, bone clip fields, and compression flags
- Track sizes (RE2=40, RE3=20), bone clip sizes (RE2=24, RE3=12) were confirmed against this tool
- Rotation flags RE2=0x4B0912, RE3=0x4C0912, Translation=0x400372 come from this tool's source

**RE-Mesh-Editor / RE Toolbox** (by NSACloud)
- Blender addon for RE Engine model files (.mesh)
- Primarily handles meshes and materials, not animation data
- Does not natively support .mot or .motlist import/export

**RETool** (present in the project as `RETool/`)
- PAK archive extraction/repacking tool
- Used for deploying modified .motlist files into the game's PAK archives
- Supports RE2 and RE3 PAK format

**REFramework** (by praydog)
- Runtime modding framework with Lua scripting
- Provides access to `via.motion.Motion`, `via.Joint`, `TreeLayer` APIs
- Used to dump bone data, control animations at runtime, and override joint transforms
- The `via.motion.Motion` class provides `getLocalRotation()`, `getLocalPosition()`, `setDynamicMotionBank()`, and `TreeLayer.changeMotion()` for animation control

### 17.2 Blender Animation Pipeline Status

As of this analysis, there is **no known Blender plugin that can directly import or export RE Engine .mot files**. The community has:

- RE Mesh Editor for models (geometry only)
- No publicly available .mot importer for Blender
- No publicly available .mot exporter/writer

Animation modding in the RE Engine community is primarily done through:
1. Hex editing existing .motlist files
2. Using RE-MOT-Editor for targeted edits
3. Runtime override via REFramework Lua scripts

---

## 18. Knowledge Assessment: Known, Unknown, Needs Work

### 18.1 KNOWN (Confirmed and Reliable)

| Item | Confidence | Source |
|------|-----------|--------|
| Motlist header layout (0x00-0x34) | HIGH | Multiple scripts confirm identical layout |
| Mot entry header layout (0x00-0x74) | HIGH | analyze_full_format.py, find_format_error.py |
| "mlst" magic at 0x04 | HIGH | All analysis scripts |
| "mot " magic at entry+0x04 | HIGH | All analysis scripts |
| Entry pointer table (uint64 array) | HIGH | All scripts parse this successfully |
| RE2 bone clip header (24 bytes) | HIGH | analyze_re2_motlist.py, find_format_error.py |
| RE3 bone clip header (12 bytes) | HIGH | analyze_full_format.py, motlist_converter.py |
| RE2 track header (40 bytes) | HIGH | Multiple scripts |
| RE3 track header (20 bytes) | HIGH | Multiple scripts |
| RE2 4-bpk decode (base + byte/255 * scale) | HIGH | decompress_test.py confirmed |
| RE3 3-bpk decode (XYZ quantized, W reconstructed) | HIGH | Multiple scripts confirmed |
| MurmurHash3-32 for bone hashing (seed 0xFFFFFFFF) | HIGH | inject_real_dodge.py verified |
| UTF-16LE string encoding | HIGH | All string extraction works |
| Little-endian byte order | HIGH | All struct unpacking works |
| Unpack data block (8 floats: 4 scale + 4 base) | HIGH | decompress_test.py, recompress_dodge.py |
| Frame index arrays (uint16 per entry) | HIGH | swap_keyframes.py, check_unpack.py |
| Internal offsets are mot-entry-relative | HIGH | All scripts use this convention successfully |
| 88 shared bone hashes between RE2 and RE3 | HIGH | analyze_deep_format.py |
| 10 known bone names with hashes | HIGH | Runtime dumps confirmed |

### 18.2 PARTIALLY KNOWN (Some Understanding, Needs Verification)

| Item | Confidence | Gap |
|------|-----------|-----|
| RE3 2-bpk decode (sub-flag dependent) | MEDIUM | Sub-flag 1 and 3 have proposed formulas but smoothness is mediocre |
| RE3 4-bpk decode | LOW | Multiple approaches tested, none fully confirmed. SoA layout shows promise. |
| Track flags bit field encoding | MEDIUM | Type and sub-flag are understood, but the full meaning of bits 16+ is uncertain |
| mot entry fields +0x10, +0x30, +0x38, +0x48 | MEDIUM | Known to be offsets, but their exact targets are unclear |
| motSize field (0x0C) | MEDIUM | Populated in RE2, zero in RE3. Exact purpose beyond "entry size" unknown |
| Bone clip byte3 (trackFlags2) | LOW | Always 0x00 in RE2, 0xFF in RE3. Purpose unknown. |
| Bone clip uknFloat at +8 (RE2 only) | LOW | Always 1.0 observed. Possibly a weight or blend factor. |
| Collection/CLIP data at colOffs | LOW | Known to exist at end of file. Internal format not analyzed. |

### 18.3 UNKNOWN (Needs Reverse Engineering)

| Item | Priority | Difficulty |
|------|----------|------------|
| RE3 5-bpk compression format | HIGH | Very difficult -- no working decode found |
| RE3 4-bpk compression format (definitive) | HIGH | Difficult -- many approaches tested, none confirmed |
| Mot entry secondary structures (+0x10, +0x30, +0x48 targets) | MEDIUM | Requires mapping what data lives at those offsets |
| Scale track format | MEDIUM | No analysis scripts examined scale tracks |
| Translation track compressed format details | MEDIUM | Less analyzed than rotation |
| Collection/CLIP data internal format | LOW | Not needed for basic animation import/export |
| Mot entry fields 0x08, 0x6C, 0x6D, 0x70, 0x72 | LOW | Unknown purpose, may be important for edge cases |
| How the game selects compression level per bone | LOW | Understanding this would help write optimal files |
| Relationship between flags sub-field and bpk | MEDIUM | Correlation observed but not definitively mapped |
| Full bone name resolution (>170 unknown hashes) | HIGH | Requires runtime bone name dumps from both games |

---

## 19. Recommendations for Building a .mot Writer

### 19.1 Target: Blender Export Plugin

A .mot writer for Blender export should target the **RE2 v65 format** first, because:
1. RE2's compression (always 4 bpk) is fully understood
2. The decode/encode formula is simple and confirmed
3. RE2's wider pointer format (uint64) is easier to work with (no overflow concerns)
4. The motlist_converter.py script provides a template for RE2 format output

### 19.2 Minimum Viable .mot Writer Architecture

```
Input: Blender animation data (per-bone keyframes with quaternion rotations and vector positions)

Step 1: Build the mot entry header (0x74 bytes)
  - Set version=65, magic="mot ", frameCount, frameRate, boneCount, boneClipCount
  - Set namesOffs=0x74 (name immediately follows header)

Step 2: Write motion name (UTF-16LE, null-terminated, padded to 16 bytes)

Step 3: For each animated bone, write bone clip header (24 bytes)
  - boneIndex: skeleton joint index
  - trackFlags1: set bits for which tracks are present
  - trackFlags2: 0x00 (RE2)
  - boneHash: MurmurHash3-32 of bone name
  - uknFloat: 1.0
  - padding: 0
  - trackHdrOffs: placeholder (fill in later)

Step 4: For each track, write track header (40 bytes)
  - flags: appropriate flag value (0x004B0112 for uncompressed rotation, etc.)
  - keyCount: number of keyframes
  - frameRate: animation frame rate
  - maxFrame: last frame number as float
  - frameIndOffs: placeholder
  - frameDataOffs: placeholder
  - unpackDataOffs: placeholder (0 for uncompressed)

Step 5: Write frame index arrays (uint16 per keyframe)

Step 6: Write keyframe data
  For uncompressed rotation: 12 bytes per key (3x float32: X, Y, Z)
  For compressed rotation: compute unpack params, quantize to 4 bytes per key

Step 7: Write unpack data blocks (32 bytes each, for compressed tracks)

Step 8: Fix all placeholder offsets (calculate actual positions)

Step 9: Update motSize field at 0x0C
```

### 19.3 Critical Implementation Details

1. **All offsets must be mot-entry-relative**: Every `trackHdrOffs`, `frameIndOffs`, `frameDataOffs`, and `unpackDataOffs` is relative to the start of the mot entry, not the file.

2. **Alignment**: Sections should be aligned to 16-byte boundaries for safety, though 4-byte alignment may be sufficient for some sections.

3. **Start with uncompressed data**: For initial development, write all tracks as uncompressed (12 bytes/key, `unpackDataOffs=0`). This avoids the complexity of quantization at the cost of larger file size.

4. **Use flag value 0x004B0112 for uncompressed rotation** and 0x004000F2 for uncompressed translation.

5. **For compressed rotation (RE2)**:
   - Compute base[i] = min of all quat component i values
   - Compute scale[i] = max - min of all quat component i values
   - Ensure scale[i] is never zero (use epsilon)
   - Quantize: byte = round((value - base) / scale * 255), clamped to [0, 255]
   - Write 4 bytes per keyframe
   - Write 32-byte unpack block with scale[4] then base[4]

6. **Bone hashes**: Use the MurmurHash3-32 implementation from Section 11.1 with seed 0xFFFFFFFF on UTF-16LE bone names.

7. **Quaternion representation**: The .mot format stores quaternions as XYZW (not WXYZ). Blender uses WXYZ internally, so conversion is needed.

### 19.4 Motlist Container Writer

To package mot entries into a motlist:

```
Step 1: Write motlist header
  - version=85, magic="mlst"
  - Set pointersOffs, colOffs, motlistNameOffs, numOffs

Step 2: Write motlist name (UTF-16LE, null-terminated, aligned to 8 bytes)

Step 3: Write entry pointer table (N x uint64 placeholders)

Step 4: For each mot entry:
  - Align to 16 bytes
  - Record current position for the pointer table
  - Write the complete mot entry

Step 5: Write collection/CLIP data (can be empty/minimal for basic files)

Step 6: Fix pointer table entries with actual positions
Step 7: Fix colOffs with actual collection data position
```

### 19.5 Testing Strategy

1. **Round-trip test**: Read an existing RE2 .motlist, parse it completely, write it back, compare byte-for-byte with the original.

2. **Minimal injection test**: Create a motlist with a single animation containing only the root bone with identity transforms. Deploy to game and verify it loads without crashing.

3. **Known animation test**: Export a known RE2 animation from the game, re-encode it, and deploy. The animation should look identical.

4. **Custom animation test**: Create a simple animation (e.g., head nod) and deploy.

### 19.6 Alternative Approach: Runtime Override

If building a full .mot writer proves too complex, the runtime override approach via REFramework Lua is a proven alternative:

1. Store animation data in a simple text format (per-frame bone quaternions)
2. Load the data in a Lua script
3. On each game frame, override bone transforms using `Joint.set_LocalRotation()` and `Joint.set_LocalPosition()`
4. Handle blending in/out of the custom animation

This approach bypasses all binary format concerns but requires the game to be running and imposes a per-frame CPU cost for the Lua override.

---

## Appendix A: Complete Format Comparison Table

```
| Field                    | RE2 (.motlist.85 / v65)   | RE3 (.motlist.99 / v78)    |
|--------------------------|---------------------------|----------------------------|
| Motlist version          | 85                        | 99                         |
| Mot entry version        | 65                        | 78                         |
| Motlist magic            | "mlst" (0x74736C6D)      | "mlst" (0x74736C6D)       |
| Mot entry magic          | "mot " (0x20746F6D)      | "mot " (0x20746F6D)       |
| Motlist header size      | 0x34 + name + alignment   | 0x34 + name + alignment    |
| Mot header size          | 0x74 bytes                | 0x74 bytes                 |
| Bone clip header size    | 24 bytes                  | 12 bytes                   |
| Track header size        | 40 bytes                  | 20 bytes                   |
| Internal offset type     | uint64 (8 bytes)          | uint32 (4 bytes)           |
| Track extra: frameRate   | Yes (at +8)               | No                         |
| Track extra: maxFrame    | Yes (at +12)              | No                         |
| Bone clip extra: float   | Yes (at +8, value=1.0)    | No                         |
| Bone clip extra: padding | Yes (at +12, value=0)     | No                         |
| Bone clip byte3          | 0x00                      | 0xFF                       |
| Compressed rot bpk       | Always 4 (4x8-bit XYZW)  | Variable: 2, 3, 4, or 5   |
| Rotation flag prefix     | 0x4X_0112                 | 0x2X_0112 or 0x4X_0112    |
| Translation flag prefix  | 0x4X_00F2                 | 0x2X_00F2 or 0x4X_00F2    |
| Uncompressed rot flag    | 0x4B0912 (4,915,474)     | 0x4C0912 (4,981,010)      |
| Uncompressed trans flag  | 0x400372 (4,194,546)     | 0x400372 (4,194,546)      |
| Hash algorithm           | MurmurHash3-32, seed=FFFF | MurmurHash3-32, seed=FFFF  |
| String encoding          | UTF-16LE                  | UTF-16LE                   |
| Byte order               | Little-endian             | Little-endian              |
| motSize field (0x0C)     | Populated                 | Always 0                   |
```

---

## Appendix B: Binary Layout Diagrams

### Motlist File Structure

```
[Motlist Header]            0x00 - 0x33     (52 bytes)
[Motlist Name String]       0x34 - variable  (UTF-16LE, null-terminated, aligned to 8)
[Entry Pointer Table]       N x uint64       (8*N bytes)
[Padding to 16-byte align]
[Mot Entry 0]               Complete mot entry
[Mot Entry 1]               Complete mot entry
...
[Mot Entry N-1]             Complete mot entry
[Collection/CLIP Data]      Referenced by colOffs
```

### Mot Entry Internal Structure

```
[Mot Header]                0x00 - 0x73     (116 bytes: version, magic, offsets, counts)
[Motion Name]               UTF-16LE at namesOffs (typically 0x74)
[Padding to 16-byte align]
[Bone Clip Headers]         Array at boneClipHdrOffs
                            RE2: 24 bytes each, RE3: 12 bytes each
[Track Headers]             Array, pointed to by bone clips
                            RE2: 40 bytes each, RE3: 20 bytes each
[Frame Index Arrays]        uint16 frame numbers, pointed to by tracks
[Frame Data]                Keyframe bytes (compressed) or floats (uncompressed)
[Unpack Data Blocks]        32 bytes each (8x float32), for compressed tracks
[Secondary Data]            Bone header offsets, clip data, other sections
                            (referenced by +0x10, +0x30, +0x48)
```

### Compressed Rotation Track Data Flow

```
Track Header
  |
  +-> unpackDataOffs -> [scale_X, scale_Y, scale_Z, scale_W,
  |                       base_X,  base_Y,  base_Z,  base_W]   (32 bytes)
  |
  +-> frameDataOffs  -> [byte0, byte1, byte2, byte3]            (per keyframe, 4 bpk RE2)
  |                   -> [byte0, byte1, byte2]                   (per keyframe, 3 bpk RE3)
  |
  +-> frameIndOffs   -> [uint16, uint16, ...]                   (frame numbers)

Decode (RE2, 4 bpk):
  qX = base_X + (byte0 / 255.0) * scale_X
  qY = base_Y + (byte1 / 255.0) * scale_Y
  qZ = base_Z + (byte2 / 255.0) * scale_Z
  qW = base_W + (byte3 / 255.0) * scale_W

Decode (RE3, 3 bpk):
  qX = base_X + (byte0 / 255.0) * scale_X
  qY = base_Y + (byte1 / 255.0) * scale_Y
  qZ = base_Z + (byte2 / 255.0) * scale_Z
  qW = sqrt(max(0, 1 - qX^2 - qY^2 - qZ^2))
```

---

## Appendix C: Track Flag Registry

### Observed Flag Values Across Both Games

```
Flag Value    Hex          Type          bpk    Game     Count (Entry 0)
----------    ----------   ----------    ---    ------   ---------------
0x004000F2    translation  uncompr.      12     Both     104 (RE2), 154 (RE3)
0x004200F2    translation  compressed    var    RE3      24
0x004210F2    translation  compressed    var    Both     2
0x004220F2    translation  compressed    var    Both     2 (RE2), 4 (RE3)
0x004230F2    translation  compressed    var    Both     1 (RE2), 2 (RE3)
0x004400F2    translation  compressed    var    RE3      1
0x004420F2    translation  compressed    var    RE3      1
0x00420112    rotation     compressed    2      RE3      9
0x00421112    rotation     compressed    var    Both     16 (RE2), 17 (RE3)
0x00422112    rotation     compressed    var    Both     12 (RE2), 10 (RE3)
0x00423112    rotation     compressed    var    Both     2
0x00430112    rotation     compressed    3      Both     33 (RE2), 22 (RE3)
0x00431112    rotation     compressed    var    RE2      1
0x00440112    rotation     compressed    4      RE3      17
0x00441112    rotation     compressed    var    RE3      2
0x00442112    rotation     compressed    var    RE3      1
0x00443112    rotation     compressed    var    RE3      1
0x00470112    rotation     compressed    var    RE2      1
0x004B0112    rotation     uncompr.      12     RE2      38
0x004C0112    rotation     uncompr.      12     RE3      95
```

---

*End of specification. This document consolidates all findings from 30+ Python reverse-engineering scripts, two format comparison files, bone mapping data, runtime dumps, and existing documentation. Last updated 2026-02-08.*
