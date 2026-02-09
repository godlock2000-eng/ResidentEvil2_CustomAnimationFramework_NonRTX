"""
RE2 .motlist.85 Writer
Builds native RE Engine animation files from CAF JSON animation data.
Target format: RE2 Remake .motlist.85 (v85 container, v65 mot entries).

Supports:
  - Compressed rotation tracks (4 bytes/key, quantized XYZW)
  - Uncompressed position tracks (12 bytes/key, 3 floats XYZ)
  - MurmurHash3-32 bone name hashing
  - Bone index extraction from reference .motlist files
  - CAF JSON input (from blender_anim_exporter.py)

Usage:
    python mot_writer.py input.json output.motlist.85 [options]

    Options:
      --ref <path>          Reference .motlist.85 for bone index mapping
      --uncompressed        Use uncompressed rotation (12 bytes/key)
      --name <string>       Motion name (default: from JSON action_name)
      --motlist-name <str>  Motlist container name (default: "custom_anim")
      --no-positions        Skip position tracks even if JSON has them
      --axis-convert        Apply Blender Z-up to RE Engine Y-up conversion
"""

import struct
import math
import json
import os
import sys
from typing import List, Tuple, Optional, Dict, Any

# ===========================================================================
# Constants
# ===========================================================================

MOTLIST_VERSION = 85
MOT_VERSION = 65
MOTLIST_MAGIC = b'mlst'
MOT_MAGIC = b'mot '

# Track flags (RE2 v65)
FLAG_ROT_COMPRESSED = 0x00430112    # Compressed rotation, 4 bytes/key (XYZW)
FLAG_ROT_UNCOMPRESSED = 0x004B0112  # Uncompressed rotation, 12 bytes/key (XYZ floats)
FLAG_POS_UNCOMPRESSED = 0x004000F2  # Uncompressed position, 12 bytes/key (XYZ floats)

# Bone clip track flag bits
TRACK_HAS_POSITION = 0x01
TRACK_HAS_ROTATION = 0x02
TRACK_HAS_SCALE    = 0x04

# Struct sizes (RE2 v65)
MOT_HEADER_SIZE = 0x74         # 116 bytes
BONE_CLIP_HEADER_SIZE = 24     # RE2: 24 bytes per bone clip
TRACK_HEADER_SIZE = 40         # RE2: 40 bytes per track
UNPACK_DATA_SIZE = 32          # 8 floats (4 scale + 4 base)

# ===========================================================================
# MurmurHash3-32
# ===========================================================================

def murmurhash3_32(data: bytes, seed: int = 0xFFFFFFFF) -> int:
    """MurmurHash3 32-bit hash. Used by RE Engine for bone name hashing."""
    length = len(data)
    nblocks = length // 4
    h1 = seed & 0xFFFFFFFF
    c1 = 0xCC9E2D51
    c2 = 0x1B873593

    for i in range(nblocks):
        k1 = struct.unpack_from('<I', data, i * 4)[0]
        k1 = (k1 * c1) & 0xFFFFFFFF
        k1 = ((k1 << 15) | (k1 >> 17)) & 0xFFFFFFFF
        k1 = (k1 * c2) & 0xFFFFFFFF
        h1 ^= k1
        h1 = ((h1 << 13) | (h1 >> 19)) & 0xFFFFFFFF
        h1 = (h1 * 5 + 0xE6546B64) & 0xFFFFFFFF

    tail = data[nblocks * 4:]
    k1 = 0
    if len(tail) >= 3:
        k1 ^= tail[2] << 16
    if len(tail) >= 2:
        k1 ^= tail[1] << 8
    if len(tail) >= 1:
        k1 ^= tail[0]
        k1 = (k1 * c1) & 0xFFFFFFFF
        k1 = ((k1 << 15) | (k1 >> 17)) & 0xFFFFFFFF
        k1 = (k1 * c2) & 0xFFFFFFFF
        h1 ^= k1

    h1 ^= length
    h1 ^= (h1 >> 16)
    h1 = (h1 * 0x85EBCA6B) & 0xFFFFFFFF
    h1 ^= (h1 >> 13)
    h1 = (h1 * 0xC2B2AE35) & 0xFFFFFFFF
    h1 ^= (h1 >> 16)
    return h1


def bone_name_hash(name: str) -> int:
    """Compute MurmurHash3-32 of a bone name (UTF-16LE encoded, seed=0xFFFFFFFF)."""
    return murmurhash3_32(name.encode('utf-16-le'))

# ===========================================================================
# Alignment helpers
# ===========================================================================

def _decode_utf16le_string(data: bytes, offset: int) -> str:
    """Decode a null-terminated UTF-16LE string from binary data.
    Searches for \\x00\\x00 on 2-byte aligned boundaries.
    """
    pos = offset
    while pos + 1 < len(data):
        if data[pos] == 0 and data[pos + 1] == 0:
            return data[offset:pos].decode('utf-16-le')
        pos += 2
    return data[offset:].decode('utf-16-le', errors='replace')


def align_up(value: int, alignment: int) -> int:
    """Round up to next multiple of alignment."""
    return (value + alignment - 1) & ~(alignment - 1)


def pad_buffer(buf: bytearray, alignment: int, fill: int = 0) -> None:
    """Pad buffer in-place to the specified alignment."""
    remainder = len(buf) % alignment
    if remainder > 0:
        buf.extend(bytes([fill]) * (alignment - remainder))

# ===========================================================================
# Quaternion compression (RE2 4-byte XYZW)
# ===========================================================================

def compute_unpack_params(quats: List[Tuple[float, float, float, float]]):
    """Compute optimal base and scale from a list of XYZW quaternions.
    Returns (scale[4], base[4]) for the unpack data block.
    """
    if not quats:
        return [0.001] * 4, [0.0] * 4

    min_vals = [min(q[i] for q in quats) for i in range(4)]
    max_vals = [max(q[i] for q in quats) for i in range(4)]

    scale = [max_vals[i] - min_vals[i] for i in range(4)]
    base = min_vals[:]

    # Ensure non-zero scale to prevent division by zero during decode
    for i in range(4):
        if scale[i] < 1e-10:
            scale[i] = 0.001

    return scale, base


def compress_quat_4bpk(
    q: Tuple[float, float, float, float],
    base: List[float],
    scale: List[float],
) -> bytes:
    """Compress a quaternion (qX, qY, qZ, qW) to 4 bytes for RE2.
    Each component: byte = clamp(round((value - base) / scale * 255), 0, 255)
    """
    result = []
    for i in range(4):
        if abs(scale[i]) > 1e-10:
            val = max(0, min(255, round((q[i] - base[i]) / scale[i] * 255)))
        else:
            val = 128
        result.append(val)
    return bytes(result)

# ===========================================================================
# Extract bone mapping from existing .motlist
# ===========================================================================

def extract_bone_mapping(motlist_path: str) -> Dict[int, int]:
    """Extract {bone_hash -> bone_index} mapping from an existing RE2 .motlist.85.
    Reads the first mot entry's bone clip headers.
    Returns dict mapping bone_hash to boneIndex.
    """
    with open(motlist_path, 'rb') as f:
        data = f.read()

    # Parse motlist header
    version = struct.unpack_from('<I', data, 0x00)[0]
    magic = data[0x04:0x08]
    if magic != MOTLIST_MAGIC:
        raise ValueError(f"Not a motlist file: magic={magic!r}")

    ptrs_offs = struct.unpack_from('<Q', data, 0x10)[0]
    # Read first entry offset
    entry_offs = struct.unpack_from('<Q', data, ptrs_offs)[0]

    # Parse mot entry header
    mot_ver = struct.unpack_from('<I', data, entry_offs)[0]
    bone_clip_offs = struct.unpack_from('<Q', data, entry_offs + 0x18)[0]
    bone_clip_count = struct.unpack_from('<H', data, entry_offs + 0x6A)[0]

    mapping = {}
    for i in range(bone_clip_count):
        pos = entry_offs + bone_clip_offs + i * BONE_CLIP_HEADER_SIZE
        if pos + BONE_CLIP_HEADER_SIZE > len(data):
            break
        bone_index = struct.unpack_from('<H', data, pos)[0]
        bone_hash = struct.unpack_from('<I', data, pos + 4)[0]
        mapping[bone_hash] = bone_index

    return mapping

# ===========================================================================
# Known RE2 bone names (from runtime dump, 80 bones)
# ===========================================================================

# These are the 80 RE2 player skeleton bone names dumped via REFramework.
# Listed alphabetically as they appear in the dump.
RE2_PLAYER_BONE_NAMES = [
    "COG", "Null_Offset", "cam_root", "front_holster_left",
    "front_holster_right", "head", "hips",
    "holster_startleft_muscleOffset", "holster_startright_muscleOffset",
    "l_arm_clavicle", "l_arm_humerus", "l_arm_radius", "l_arm_wrist",
    "l_hand_index_0", "l_hand_index_1", "l_hand_index_2",
    "l_hand_little_0", "l_hand_little_1", "l_hand_little_2", "l_hand_little_3",
    "l_hand_middle_0", "l_hand_middle_1", "l_hand_middle_2",
    "l_hand_ring_0", "l_hand_ring_1", "l_hand_ring_2", "l_hand_ring_3",
    "l_hand_thumb_0", "l_hand_thumb_1", "l_hand_thumb_2",
    "l_leg_ankle", "l_leg_ball", "l_leg_femur", "l_leg_tibia",
    "l_scapula_0", "l_trapA_muscle", "l_trapA_muscleOffset", "l_weapon",
    "light_01", "light_02",
    "neck_0", "neck_1",
    "r_arm_clavicle", "r_arm_humerus", "r_arm_radius", "r_arm_wrist",
    "r_beltSide_muscle", "r_beltSide_muscleOffset",
    "r_hand_index_0", "r_hand_index_1", "r_hand_index_2",
    "r_hand_little_0", "r_hand_little_1", "r_hand_little_2", "r_hand_little_3",
    "r_hand_middle_0", "r_hand_middle_1", "r_hand_middle_2",
    "r_hand_ring_0", "r_hand_ring_1", "r_hand_ring_2", "r_hand_ring_3",
    "r_hand_thumb_0", "r_hand_thumb_1", "r_hand_thumb_2",
    "r_leg_ankle", "r_leg_ball", "r_leg_femur", "r_leg_tibia",
    "r_scapula_0", "r_trapA_muscle", "r_trapA_muscleOffset", "r_weapon",
    "root",
    "setProp_C_00", "setProp_E_00", "setProp_F_00",
    "spine_0", "spine_1", "spine_2",
]

# Pre-computed hash -> name lookup
_HASH_TO_NAME = {bone_name_hash(n): n for n in RE2_PLAYER_BONE_NAMES}


def get_bone_name_for_hash(h: int) -> Optional[str]:
    """Look up bone name from hash, returns None if unknown."""
    return _HASH_TO_NAME.get(h)

# ===========================================================================
# Coordinate conversion: Blender Z-up RH -> RE Engine Y-up
# ===========================================================================

def convert_position_blender_to_re(x: float, y: float, z: float):
    """Convert position from Blender (Z-up, right-handed) to RE Engine (Y-up)."""
    return (x, z, -y)


def convert_quat_blender_to_re(qx: float, qy: float, qz: float, qw: float):
    """Convert quaternion from Blender (Z-up, right-handed) to RE Engine (Y-up).
    Blender quat (x,y,z,w) -> RE quat: swap Y/Z and negate new Z.
    """
    return (qx, qz, -qy, qw)

# ===========================================================================
# Build a single RE2 v65 mot entry
# ===========================================================================

def build_mot_entry(
    motion_name: str,
    frame_count: int,
    frame_rate: int,
    bones: List[Dict[str, Any]],
    compressed: bool = True,
) -> bytes:
    """Build a complete RE2 v65 mot entry.

    Args:
        motion_name: Animation name string (e.g., "custom_head_nod")
        frame_count: Total number of frames
        frame_rate: Frame rate (e.g., 30 or 60)
        bones: List of bone dicts, each with:
            - name: str (bone name)
            - index: int (skeleton joint index)
            - hash: int (MurmurHash3-32 of name, auto-computed if missing)
            - rotations: list of (qx, qy, qz, qw) per keyframe
            - positions: optional list of (x, y, z) per keyframe
            - rot_frame_indices: optional list of frame numbers for rotation keys
            - pos_frame_indices: optional list of frame numbers for position keys
        compressed: If True, use 4-byte compressed rotation. If False, 12-byte uncompressed.

    Returns:
        Complete mot entry as bytes.
    """
    buf = bytearray()
    bone_clip_count = len(bones)

    # --- Phase 1: Build all data sections into separate buffers ---

    # Compute per-bone track info
    bone_tracks = []
    for bone in bones:
        name = bone['name']
        bone_index = bone.get('index', 0)
        bone_hash = bone.get('hash', bone_name_hash(name))
        rotations = bone.get('rotations', [])
        positions = bone.get('positions', None)
        rot_frame_indices = bone.get('rot_frame_indices', None)
        pos_frame_indices = bone.get('pos_frame_indices', None)

        has_rot = len(rotations) > 0
        has_pos = positions is not None and len(positions) > 0
        track_flags = 0
        if has_pos:
            track_flags |= TRACK_HAS_POSITION
        if has_rot:
            track_flags |= TRACK_HAS_ROTATION

        tracks = []
        # Position track (comes before rotation in track order)
        if has_pos:
            tracks.append({
                'type': 'position',
                'data': positions,
                'frame_indices': pos_frame_indices,
                'key_count': len(positions),
            })
        # Rotation track
        if has_rot:
            tracks.append({
                'type': 'rotation',
                'data': rotations,
                'frame_indices': rot_frame_indices,
                'key_count': len(rotations),
            })

        bone_tracks.append({
            'name': name,
            'index': bone_index,
            'hash': bone_hash,
            'track_flags': track_flags,
            'tracks': tracks,
        })

    # --- Phase 2: Calculate layout and offsets ---

    # Motion name string (UTF-16LE, null-terminated)
    name_bytes = motion_name.encode('utf-16-le') + b'\x00\x00'
    name_start = MOT_HEADER_SIZE  # 0x74
    name_end = name_start + len(name_bytes)
    name_end_aligned = align_up(name_end, 16)

    # Bone clip headers
    bone_clips_start = name_end_aligned
    bone_clips_size = bone_clip_count * BONE_CLIP_HEADER_SIZE
    bone_clips_end = bone_clips_start + bone_clips_size

    # Track headers (count total tracks across all bones)
    total_tracks = sum(len(bt['tracks']) for bt in bone_tracks)
    tracks_start = align_up(bone_clips_end, 8)
    tracks_size = total_tracks * TRACK_HEADER_SIZE
    tracks_end = tracks_start + tracks_size

    # Frame data: for each track, compute data offset and size
    # We'll lay out frame data sequentially after track headers
    frame_data_start = align_up(tracks_end, 16)
    current_fd_offset = frame_data_start

    track_layout = []  # One entry per track with offsets
    for bt in bone_tracks:
        for track in bt['tracks']:
            key_count = track['key_count']
            if track['type'] == 'rotation':
                if compressed:
                    bytes_per_key = 4
                else:
                    bytes_per_key = 12  # 3 floats
            else:  # position
                bytes_per_key = 12  # 3 floats (always uncompressed for now)

            fd_offset = current_fd_offset
            fd_size = key_count * bytes_per_key
            current_fd_offset += fd_size

            track_layout.append({
                'track': track,
                'parent_bone': bt,
                'frame_data_offset': fd_offset,
                'frame_data_size': fd_size,
                'bytes_per_key': bytes_per_key,
            })

    frame_data_end = current_fd_offset

    # Unpack data blocks (only for compressed rotation tracks)
    unpack_data_start = align_up(frame_data_end, 4)
    current_ud_offset = unpack_data_start
    for tl in track_layout:
        if tl['track']['type'] == 'rotation' and compressed:
            tl['unpack_data_offset'] = current_ud_offset
            current_ud_offset += UNPACK_DATA_SIZE
        else:
            tl['unpack_data_offset'] = 0  # No unpack data
    unpack_data_end = current_ud_offset

    # Frame index arrays (int16 per key, one array per track)
    frame_ind_start = align_up(unpack_data_end, 4)
    current_fi_offset = frame_ind_start
    for tl in track_layout:
        key_count = tl['track']['key_count']
        tl['frame_ind_offset'] = current_fi_offset
        current_fi_offset += key_count * 2  # int16 per key
        current_fi_offset = align_up(current_fi_offset, 2)  # keep 2-byte aligned
    frame_ind_end = current_fi_offset

    # Minimal BoneHeaders stub (16 bytes: boneHdrOffs + boneHdrCount=0)
    # Engine may crash if offsToBoneHdrOffs=0, so provide a valid empty struct
    bone_hdrs_start = align_up(frame_ind_end, 8)
    bone_hdrs_size = 16  # Just the header: u64 boneHdrOffs + u64 boneHdrCount
    bone_hdrs_end = bone_hdrs_start + bone_hdrs_size

    # Total entry size
    entry_size = align_up(bone_hdrs_end, 16)

    # --- Phase 3: Write the binary data ---

    buf = bytearray(entry_size)

    # --- Mot header (0x74 bytes) ---
    struct.pack_into('<I', buf, 0x00, MOT_VERSION)          # version = 65
    buf[0x04:0x08] = MOT_MAGIC                              # "mot "
    struct.pack_into('<I', buf, 0x08, 0)                     # unknown_08
    struct.pack_into('<I', buf, 0x0C, 0)                     # motSize (must be 0 in RE2 motlists)
    struct.pack_into('<Q', buf, 0x10, bone_hdrs_start)          # offsToBoneHdrOffs (minimal empty BoneHeaders)
    struct.pack_into('<Q', buf, 0x18, bone_clips_start)      # boneClipHdrOffs (offset to BoneClipHeader array)
    struct.pack_into('<Q', buf, 0x20, 0)                     # reserved
    struct.pack_into('<Q', buf, 0x28, 0)                     # reserved
    struct.pack_into('<Q', buf, 0x30, 0)                     # clipFileOffset (unused)
    struct.pack_into('<Q', buf, 0x38, 0)                     # offs1 (unused)
    struct.pack_into('<Q', buf, 0x40, 0)                     # reserved
    struct.pack_into('<Q', buf, 0x48, 0)                     # offs2 (unused)
    struct.pack_into('<Q', buf, 0x50, MOT_HEADER_SIZE)       # namesOffs = 0x74
    struct.pack_into('<f', buf, 0x58, float(frame_count - 1))  # frameCount (max frame)
    struct.pack_into('<f', buf, 0x5C, -1.0)                   # unk5C (always -1.0 in RE2)
    struct.pack_into('<f', buf, 0x60, 0.0)                   # uknFloat1
    struct.pack_into('<f', buf, 0x64, float(frame_count - 1))  # uknFloat2 (= frameCount)
    struct.pack_into('<H', buf, 0x68, bone_clip_count)       # boneCount
    struct.pack_into('<H', buf, 0x6A, bone_clip_count)       # boneClipCount
    struct.pack_into('<B', buf, 0x6C, 0)                     # uknPtr2Count
    struct.pack_into('<B', buf, 0x6D, 0)                     # uknPtr3Count
    struct.pack_into('<H', buf, 0x6E, frame_rate)            # frameRate
    struct.pack_into('<H', buf, 0x70, 0)                     # uknPtrCount
    struct.pack_into('<H', buf, 0x72, 0)                     # uknShort2

    # --- Motion name string ---
    buf[name_start:name_start + len(name_bytes)] = name_bytes

    # --- Bone clip headers (24 bytes each) ---
    track_idx = 0
    for bc_idx, bt in enumerate(bone_tracks):
        pos = bone_clips_start + bc_idx * BONE_CLIP_HEADER_SIZE
        # Offset to first track header for this bone
        track_hdr_offset = tracks_start + track_idx * TRACK_HEADER_SIZE

        struct.pack_into('<H', buf, pos + 0, bt['index'])        # boneIndex
        struct.pack_into('<B', buf, pos + 2, bt['track_flags'])   # trackFlags1
        struct.pack_into('<B', buf, pos + 3, 0x00)                # trackFlags2 (RE2 = 0x00)
        struct.pack_into('<I', buf, pos + 4, bt['hash'])          # boneHash
        struct.pack_into('<f', buf, pos + 8, 1.0)                 # uknFloat (RE2 = 1.0)
        struct.pack_into('<I', buf, pos + 12, 0)                  # padding
        struct.pack_into('<Q', buf, pos + 16, track_hdr_offset)   # trackHdrOffs

        track_idx += len(bt['tracks'])

    # --- Track headers (40 bytes each) ---
    for tl_idx, tl in enumerate(track_layout):
        track = tl['track']
        pos = tracks_start + tl_idx * TRACK_HEADER_SIZE
        key_count = track['key_count']
        max_frame = float(frame_count - 1)

        if track['type'] == 'rotation':
            if compressed:
                flags = FLAG_ROT_COMPRESSED
            else:
                flags = FLAG_ROT_UNCOMPRESSED
        else:  # position
            flags = FLAG_POS_UNCOMPRESSED

        # Determine unpack data offset (mot-entry-relative)
        ud_offs = tl['unpack_data_offset'] if tl['unpack_data_offset'] > 0 else 0

        struct.pack_into('<I', buf, pos + 0, flags)                     # flags
        struct.pack_into('<I', buf, pos + 4, key_count)                 # keyCount
        struct.pack_into('<I', buf, pos + 8, frame_rate)                # frameRate (RE2 extra)
        struct.pack_into('<f', buf, pos + 12, max_frame)                # maxFrame (RE2 extra)
        struct.pack_into('<Q', buf, pos + 16, tl['frame_ind_offset'])     # frameIndOffs (frame index array)
        struct.pack_into('<Q', buf, pos + 24, tl['frame_data_offset'])  # frameDataOffs (keyframe data)
        struct.pack_into('<Q', buf, pos + 32, ud_offs)                  # unpackDataOffs

    # --- Frame data ---
    for tl in track_layout:
        track = tl['track']
        data_list = track['data']
        fd_pos = tl['frame_data_offset']

        if track['type'] == 'rotation':
            if compressed:
                # Compute unpack params then write compressed bytes
                quats = [(d[0], d[1], d[2], d[3]) for d in data_list]
                scale, base = compute_unpack_params(quats)

                # Write compressed keyframes (4 bytes each)
                for k, q in enumerate(quats):
                    comp = compress_quat_4bpk(q, base, scale)
                    buf[fd_pos + k * 4:fd_pos + k * 4 + 4] = comp

                # Write unpack data block (32 bytes: scale[4] then base[4])
                ud_pos = tl['unpack_data_offset']
                for i in range(4):
                    struct.pack_into('<f', buf, ud_pos + i * 4, scale[i])
                for i in range(4):
                    struct.pack_into('<f', buf, ud_pos + 16 + i * 4, base[i])
            else:
                # Uncompressed rotation: 3 floats per key (qX, qY, qZ)
                # Engine reconstructs qW = sqrt(max(0, 1 - qX^2 - qY^2 - qZ^2))
                for k, q in enumerate(data_list):
                    struct.pack_into('<f', buf, fd_pos + k * 12 + 0, q[0])  # qX
                    struct.pack_into('<f', buf, fd_pos + k * 12 + 4, q[1])  # qY
                    struct.pack_into('<f', buf, fd_pos + k * 12 + 8, q[2])  # qZ
        else:
            # Position: 3 floats per key (X, Y, Z)
            for k, p in enumerate(data_list):
                struct.pack_into('<f', buf, fd_pos + k * 12 + 0, p[0])
                struct.pack_into('<f', buf, fd_pos + k * 12 + 4, p[1])
                struct.pack_into('<f', buf, fd_pos + k * 12 + 8, p[2])

    # --- Frame index arrays (int16 per key) ---
    for tl in track_layout:
        fi_pos = tl['frame_ind_offset']
        key_count = tl['track']['key_count']
        for k in range(key_count):
            struct.pack_into('<h', buf, fi_pos + k * 2, k)  # int16 frame index

    # --- Minimal BoneHeaders stub (16 bytes) ---
    # boneHdrOffs: relative offset to entries (0x10 = right after this 16-byte header)
    struct.pack_into('<Q', buf, bone_hdrs_start, 0x10)   # boneHdrOffs (relative to struct)
    struct.pack_into('<Q', buf, bone_hdrs_start + 8, 0)  # boneHdrCount = 0

    return bytes(buf)

# ===========================================================================
# Build a .motlist.85 container
# ===========================================================================

def build_motlist(
    motlist_name: str,
    mot_entries: List[bytes],
) -> bytes:
    """Build a complete RE2 v85 .motlist.85 container.

    Args:
        motlist_name: Name string for the motlist
        mot_entries: List of mot entry byte blobs (from build_mot_entry)

    Returns:
        Complete .motlist.85 file as bytes.
    """
    num_entries = len(mot_entries)

    # --- Motlist name string ---
    name_bytes = motlist_name.encode('utf-16-le') + b'\x00\x00'
    name_start = 0x34  # Right after the 52-byte header
    name_end = name_start + len(name_bytes)
    name_end_aligned = align_up(name_end, 8)

    # --- Pointer table ---
    ptrs_start = name_end_aligned
    ptrs_size = num_entries * 8  # uint64 per entry
    ptrs_end = ptrs_start + ptrs_size
    ptrs_end_aligned = align_up(ptrs_end, 16)

    # --- Mot entries ---
    entries_start = ptrs_end_aligned
    entry_offsets = []
    entries_buf = bytearray()

    for entry_bytes in mot_entries:
        # Align to 16 bytes before each entry
        remainder = len(entries_buf) % 16
        if remainder > 0:
            entries_buf.extend(b'\x00' * (16 - remainder))
        entry_offsets.append(entries_start + len(entries_buf))
        entries_buf.extend(entry_bytes)

    entries_end = entries_start + len(entries_buf)
    entries_end_aligned = align_up(entries_end, 16)

    # --- Collection data (matches real game format: 24 bytes) ---
    # Real game hex: 00000000 00000000 0000 0100 00000000 00000000 00000000
    # Layout: uint64(0) + uint16(0) + uint16(num_entries) + padding to 24 bytes
    col_start = entries_end_aligned
    col_data = bytearray(24)
    struct.pack_into('<H', col_data, 10, num_entries)   # entry count at byte 10
    col_data = bytes(col_data)
    total_size = col_start + len(col_data)

    # --- Build the file ---
    buf = bytearray(total_size)

    # Header (52 bytes)
    struct.pack_into('<I', buf, 0x00, MOTLIST_VERSION)       # version = 85
    buf[0x04:0x08] = MOTLIST_MAGIC                           # "mlst"
    struct.pack_into('<Q', buf, 0x08, 0)                     # padding
    struct.pack_into('<Q', buf, 0x10, ptrs_start)            # pointersOffs
    struct.pack_into('<Q', buf, 0x18, col_start)             # colOffs
    struct.pack_into('<Q', buf, 0x20, name_start)            # motlistNameOffs
    struct.pack_into('<Q', buf, 0x28, 0)                     # padding2
    struct.pack_into('<I', buf, 0x30, num_entries)           # numOffs (entry count)

    # Name string
    buf[name_start:name_start + len(name_bytes)] = name_bytes

    # Pointer table
    for i, offset in enumerate(entry_offsets):
        struct.pack_into('<Q', buf, ptrs_start + i * 8, offset)

    # Mot entries
    buf[entries_start:entries_start + len(entries_buf)] = entries_buf

    # Collection data
    buf[col_start:col_start + len(col_data)] = col_data

    return bytes(buf)

# ===========================================================================
# JSON to .motlist.85 converter
# ===========================================================================

def load_caf_json(json_path: str) -> Dict[str, Any]:
    """Load and validate a CAF_AnimData JSON file."""
    with open(json_path, 'r') as f:
        data = json.load(f)

    if data.get('format') != 'CAF_AnimData':
        raise ValueError(f"Not a CAF_AnimData file: format={data.get('format')}")

    required = ['bones', 'data', 'frame_count', 'bone_count']
    for key in required:
        if key not in data:
            raise ValueError(f"Missing required field: {key}")

    return data


def json_to_motlist(
    json_path: str,
    output_path: str,
    reference_motlist: Optional[str] = None,
    bone_index_override: Optional[Dict[str, int]] = None,
    compressed: bool = True,
    motion_name: Optional[str] = None,
    motlist_name: str = "custom_anim",
    include_positions: bool = True,
    axis_convert: bool = False,
) -> str:
    """Convert a CAF JSON animation to .motlist.85 file.

    Args:
        json_path: Path to CAF_AnimData JSON file
        output_path: Output .motlist.85 file path
        reference_motlist: Optional path to reference .motlist.85 for bone index mapping
        bone_index_override: Optional {bone_name: index} dict overriding bone indices
        compressed: Use compressed (4 bpk) or uncompressed (12 bytes/key) rotation
        motion_name: Animation name (default: from JSON action_name)
        motlist_name: Motlist container name
        include_positions: Include position tracks if JSON has them
        axis_convert: Apply Blender Z-up to RE Engine Y-up axis conversion

    Returns:
        Status string.
    """
    # Load JSON
    anim_data = load_caf_json(json_path)
    bone_names = anim_data['bones']
    frames = anim_data['data']
    frame_count = anim_data['frame_count']
    fps = anim_data.get('fps', 60)
    has_positions = anim_data.get('has_positions', False) and include_positions

    if motion_name is None:
        motion_name = anim_data.get('action_name', 'custom_animation')
        # Clean up name for RE Engine (no spaces, limited chars)
        motion_name = motion_name.replace(' ', '_')

    # Build bone index mapping
    bone_index_map = {}

    # 1. From reference motlist (if provided)
    if reference_motlist and os.path.exists(reference_motlist):
        hash_to_idx = extract_bone_mapping(reference_motlist)
        for name in bone_names:
            h = bone_name_hash(name)
            if h in hash_to_idx:
                bone_index_map[name] = hash_to_idx[h]

    # 2. From explicit override
    if bone_index_override:
        bone_index_map.update(bone_index_override)

    # 3. Fallback: sequential indices for unmapped bones
    next_idx = max(bone_index_map.values(), default=-1) + 1
    for name in bone_names:
        if name not in bone_index_map:
            bone_index_map[name] = next_idx
            next_idx += 1

    # Build per-bone animation data
    bones = []
    for bone_idx_in_json, name in enumerate(bone_names):
        # Collect rotation and position data across all frames
        rotations = []
        positions = []

        for frame_idx in range(frame_count):
            if frame_idx >= len(frames):
                break
            frame = frames[frame_idx]
            if bone_idx_in_json >= len(frame):
                break

            bone_data = frame[bone_idx_in_json]
            # bone_data = [qx, qy, qz, qw, px, py, pz]
            qx, qy, qz, qw = bone_data[0], bone_data[1], bone_data[2], bone_data[3]
            px, py, pz = bone_data[4], bone_data[5], bone_data[6]

            if axis_convert:
                qx, qy, qz, qw = convert_quat_blender_to_re(qx, qy, qz, qw)
                px, py, pz = convert_position_blender_to_re(px, py, pz)

            # Normalize quaternion
            mag = math.sqrt(qx*qx + qy*qy + qz*qz + qw*qw)
            if mag > 0.001:
                qx /= mag
                qy /= mag
                qz /= mag
                qw /= mag

            rotations.append((qx, qy, qz, qw))
            if has_positions:
                positions.append((px, py, pz))

        bone_entry = {
            'name': name,
            'index': bone_index_map[name],
            'rotations': rotations,
        }
        if has_positions and positions:
            bone_entry['positions'] = positions

        bones.append(bone_entry)

    # Sort bones by index (required for proper engine matching)
    bones.sort(key=lambda b: b['index'])

    # Build mot entry
    mot_entry = build_mot_entry(
        motion_name=motion_name,
        frame_count=frame_count,
        frame_rate=fps,
        bones=bones,
        compressed=compressed,
    )

    # Build motlist container
    motlist = build_motlist(
        motlist_name=motlist_name,
        mot_entries=[mot_entry],
    )

    # Write output
    os.makedirs(os.path.dirname(os.path.abspath(output_path)), exist_ok=True)
    with open(output_path, 'wb') as f:
        f.write(motlist)

    file_size = len(motlist)
    if file_size < 1024:
        size_str = f"{file_size} B"
    elif file_size < 1048576:
        size_str = f"{file_size / 1024:.1f} KB"
    else:
        size_str = f"{file_size / 1048576:.1f} MB"

    return (
        f"Wrote {output_path} ({size_str})\n"
        f"  Motlist: v{MOTLIST_VERSION}, 1 entry\n"
        f"  Mot entry: v{MOT_VERSION}, {len(bones)} bones, "
        f"{frame_count} frames @ {fps}fps\n"
        f"  Rotation: {'compressed (4 bpk)' if compressed else 'uncompressed (12 B/key)'}\n"
        f"  Positions: {'yes' if has_positions else 'no'}"
    )

# ===========================================================================
# Validation: verify a written .motlist.85
# ===========================================================================

def validate_motlist(path: str) -> str:
    """Read a .motlist.85 file and perform basic validation.
    Returns a status string with any issues found.
    """
    with open(path, 'rb') as f:
        data = f.read()

    issues = []
    info = []

    # Check motlist header
    if len(data) < 0x34:
        return "ERROR: File too small for motlist header"

    version = struct.unpack_from('<I', data, 0x00)[0]
    magic = data[0x04:0x08]
    ptrs_offs = struct.unpack_from('<Q', data, 0x10)[0]
    col_offs = struct.unpack_from('<Q', data, 0x18)[0]
    name_offs = struct.unpack_from('<Q', data, 0x20)[0]
    num_entries = struct.unpack_from('<I', data, 0x30)[0]

    info.append(f"Motlist: version={version}, entries={num_entries}, size={len(data)}")

    if magic != MOTLIST_MAGIC:
        issues.append(f"Bad motlist magic: {magic!r} (expected {MOTLIST_MAGIC!r})")
    if version != MOTLIST_VERSION:
        issues.append(f"Unexpected version: {version} (expected {MOTLIST_VERSION})")

    # Read name string (UTF-16LE, search for null on 2-byte boundary)
    if name_offs < len(data):
        try:
            name_str = _decode_utf16le_string(data, name_offs)
            info.append(f"Motlist name: '{name_str}'")
        except Exception:
            issues.append(f"Cannot decode motlist name at offset {name_offs}")

    # Check pointer table
    if ptrs_offs + num_entries * 8 > len(data):
        issues.append("Pointer table extends beyond file")
    else:
        for i in range(num_entries):
            entry_off = struct.unpack_from('<Q', data, ptrs_offs + i * 8)[0]
            info.append(f"Entry {i}: offset=0x{entry_off:x}")

            if entry_off + MOT_HEADER_SIZE > len(data):
                issues.append(f"Entry {i} header extends beyond file")
                continue

            # Validate mot entry header
            mot_ver = struct.unpack_from('<I', data, entry_off)[0]
            mot_magic = data[entry_off + 4:entry_off + 8]
            mot_size = struct.unpack_from('<I', data, entry_off + 0x0C)[0]
            bc_offs = struct.unpack_from('<Q', data, entry_off + 0x18)[0]
            bc_count = struct.unpack_from('<H', data, entry_off + 0x6A)[0]
            frame_count = struct.unpack_from('<f', data, entry_off + 0x58)[0]
            frame_rate = struct.unpack_from('<H', data, entry_off + 0x6E)[0]

            if mot_magic != MOT_MAGIC:
                issues.append(f"Entry {i}: bad mot magic: {mot_magic!r}")
            if mot_ver != MOT_VERSION:
                issues.append(f"Entry {i}: unexpected mot version: {mot_ver}")

            info.append(f"  Mot: v{mot_ver}, size={mot_size}, bones={bc_count}, "
                       f"frames={frame_count:.0f}, fps={frame_rate}")

            # Read motion name
            names_offs = struct.unpack_from('<Q', data, entry_off + 0x50)[0]
            abs_name = entry_off + names_offs
            if abs_name < len(data):
                try:
                    mot_name = _decode_utf16le_string(data, abs_name)
                    info.append(f"  Motion name: '{mot_name}'")
                except Exception:
                    issues.append(f"Entry {i}: cannot decode motion name")

            # Validate bone clips
            for bc in range(min(bc_count, 5)):
                bc_pos = entry_off + bc_offs + bc * BONE_CLIP_HEADER_SIZE
                if bc_pos + BONE_CLIP_HEADER_SIZE > len(data):
                    issues.append(f"Entry {i}, bone clip {bc}: extends beyond file")
                    break
                bone_idx = struct.unpack_from('<H', data, bc_pos)[0]
                bone_hash = struct.unpack_from('<I', data, bc_pos + 4)[0]
                track_off = struct.unpack_from('<Q', data, bc_pos + 16)[0]
                known_name = get_bone_name_for_hash(bone_hash)
                name_str = f" ({known_name})" if known_name else ""
                info.append(f"  Bone {bc}: idx={bone_idx}, hash=0x{bone_hash:08x}"
                           f"{name_str}, track_off=0x{track_off:x}")

    result = "=== Validation Report ===\n"
    result += "\n".join(info)
    if issues:
        result += f"\n\n=== {len(issues)} ISSUES FOUND ===\n"
        result += "\n".join(f"  ! {issue}" for issue in issues)
    else:
        result += "\n\n=== No issues found ==="

    return result

# ===========================================================================
# CLI
# ===========================================================================

def main():
    import argparse

    parser = argparse.ArgumentParser(
        description="Convert CAF JSON animation to RE2 .motlist.85 format"
    )
    subparsers = parser.add_subparsers(dest='command')

    # Convert command
    convert_parser = subparsers.add_parser('convert', help='Convert JSON to .motlist.85')
    convert_parser.add_argument('input', help='Input CAF JSON file')
    convert_parser.add_argument('output', help='Output .motlist.85 file')
    convert_parser.add_argument('--ref', help='Reference .motlist.85 for bone index mapping')
    convert_parser.add_argument('--uncompressed', action='store_true',
                               help='Use uncompressed rotation (12 bytes/key)')
    convert_parser.add_argument('--name', help='Motion name override')
    convert_parser.add_argument('--motlist-name', default='custom_anim',
                               help='Motlist container name')
    convert_parser.add_argument('--no-positions', action='store_true',
                               help='Skip position tracks')
    convert_parser.add_argument('--axis-convert', action='store_true',
                               help='Convert Blender Z-up to RE Engine Y-up')

    # Validate command
    validate_parser = subparsers.add_parser('validate', help='Validate a .motlist.85 file')
    validate_parser.add_argument('file', help='.motlist.85 file to validate')

    # Extract bone mapping command
    extract_parser = subparsers.add_parser('extract-bones',
                                           help='Extract bone mapping from .motlist.85')
    extract_parser.add_argument('file', help='.motlist.85 file')

    # Hash command
    hash_parser = subparsers.add_parser('hash', help='Compute bone name hash')
    hash_parser.add_argument('name', help='Bone name to hash')

    args = parser.parse_args()

    if args.command == 'convert':
        result = json_to_motlist(
            json_path=args.input,
            output_path=args.output,
            reference_motlist=args.ref,
            compressed=not args.uncompressed,
            motion_name=args.name,
            motlist_name=args.motlist_name,
            include_positions=not args.no_positions,
            axis_convert=args.axis_convert,
        )
        print(result)

    elif args.command == 'validate':
        result = validate_motlist(args.file)
        print(result)

    elif args.command == 'extract-bones':
        mapping = extract_bone_mapping(args.file)
        print(f"Extracted {len(mapping)} bone mappings:")
        for h, idx in sorted(mapping.items(), key=lambda x: x[1]):
            name = get_bone_name_for_hash(h)
            name_str = f" ({name})" if name else ""
            print(f"  index={idx:3d}  hash=0x{h:08x}{name_str}")

    elif args.command == 'hash':
        h = bone_name_hash(args.name)
        print(f"'{args.name}' -> 0x{h:08x} ({h})")

    else:
        parser.print_help()


if __name__ == '__main__':
    main()
