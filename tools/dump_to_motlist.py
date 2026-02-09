"""
Convert RE2 dodge dump files to .motlist.85 format.
Reads the bone-override dump format (T|NAME|qx|qy|qz|qw|px|py|pz)
and produces a native RE2 animation file.

Usage:
    python dump_to_motlist.py <dump_file> <output.motlist.85> [--ref <ref.motlist.85>]
"""

import sys
import os
import argparse

# Add tools dir to path for mot_writer import
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from mot_writer import (
    build_mot_entry, build_motlist, extract_bone_mapping,
    bone_name_hash, RE2_PLAYER_BONE_NAMES, validate_motlist
)


def parse_dodge_dump(path):
    """Parse a dodge dump file.
    Returns: (bone_names, frame_count, frames_data)
    where frames_data[frame_idx][bone_name] = (qx, qy, qz, qw, px, py, pz)
    """
    bone_names = []
    frame_count = 0
    frames_data = []
    current_frame = {}

    with open(path, 'r') as f:
        for line in f:
            line = line.strip()
            if not line:
                continue

            if line.startswith("BONE|"):
                name = line.split("|", 1)[1]
                bone_names.append(name)

            elif line.startswith("FRAME_COUNT="):
                frame_count = int(line.split("=")[1])

            elif line.startswith("FRAME="):
                if current_frame:
                    frames_data.append(current_frame)
                current_frame = {}

            elif line.startswith("T|"):
                parts = line.split("|")
                name = parts[1]
                qx = float(parts[2])
                qy = float(parts[3])
                qz = float(parts[4])
                qw = float(parts[5])
                px = float(parts[6])
                py = float(parts[7])
                pz = float(parts[8])
                current_frame[name] = (qx, qy, qz, qw, px, py, pz)

    # Don't forget the last frame
    if current_frame:
        frames_data.append(current_frame)

    return bone_names, frame_count, frames_data


def dump_to_motlist(
    dump_path,
    output_path,
    reference_motlist=None,
    motion_name=None,
    include_positions=True,
    compressed=True,
    frame_rate=60,
):
    """Convert a dodge dump file to .motlist.85."""

    bone_names, frame_count, frames_data = parse_dodge_dump(dump_path)
    actual_frame_count = len(frames_data)

    if motion_name is None:
        base = os.path.splitext(os.path.basename(dump_path))[0]
        motion_name = base.replace(" ", "_")

    print(f"Dump: {len(bone_names)} bones, {actual_frame_count} frames "
          f"(header says {frame_count})")

    # Build bone index mapping
    bone_index_map = {}
    if reference_motlist and os.path.exists(reference_motlist):
        hash_to_idx = extract_bone_mapping(reference_motlist)
        for name in bone_names:
            h = bone_name_hash(name)
            if h in hash_to_idx:
                bone_index_map[name] = hash_to_idx[h]
        print(f"Mapped {len(bone_index_map)}/{len(bone_names)} bones from reference")

    # Fallback: sequential indices for unmapped
    next_idx = max(bone_index_map.values(), default=-1) + 1
    for name in bone_names:
        if name not in bone_index_map:
            bone_index_map[name] = next_idx
            next_idx += 1

    # Skip non-animation bones (cam_root, light_*, setProp_*)
    skip_prefixes = ("cam_root", "light_", "setProp_")

    # Build bone data for mot_writer
    bones = []
    sign_fix_count = 0
    for name in bone_names:
        if any(name.startswith(p) for p in skip_prefixes):
            continue

        rotations = []
        positions = []

        for frame_idx in range(actual_frame_count):
            frame = frames_data[frame_idx]
            if name not in frame:
                # Identity fallback
                rotations.append((0.0, 0.0, 0.0, 1.0))
                if include_positions:
                    positions.append((0.0, 0.0, 0.0))
                continue

            data = frame[name]
            qx, qy, qz, qw = data[0], data[1], data[2], data[3]
            px, py, pz = data[4], data[5], data[6]

            # Fix quaternion sign flips: q and -q are the same rotation, but
            # the engine interpolates between consecutive frames, so sign flips
            # cause the bone to swing wildly through the wrong path.
            # Ensure dot(prev, cur) >= 0 by negating if needed.
            if rotations:
                prev = rotations[-1]
                dot = prev[0]*qx + prev[1]*qy + prev[2]*qz + prev[3]*qw
                if dot < 0:
                    qx, qy, qz, qw = -qx, -qy, -qz, -qw
                    sign_fix_count += 1

            rotations.append((qx, qy, qz, qw))
            if include_positions:
                positions.append((px, py, pz))

        bone_entry = {
            'name': name,
            'index': bone_index_map.get(name, 0),
            'rotations': rotations,
        }
        if include_positions and positions:
            bone_entry['positions'] = positions

        bones.append(bone_entry)

    if sign_fix_count > 0:
        print(f"Fixed {sign_fix_count} quaternion sign flips")

    # Sort by bone index (required for proper engine matching)
    bones.sort(key=lambda b: b['index'])

    print(f"Building mot entry: {len(bones)} bones, {actual_frame_count} frames")

    # Build mot entry
    mot_entry = build_mot_entry(
        motion_name=motion_name,
        frame_count=actual_frame_count,
        frame_rate=frame_rate,
        bones=bones,
        compressed=compressed,
    )

    # Build motlist
    motlist = build_motlist(
        motlist_name=motion_name,
        mot_entries=[mot_entry],
    )

    # Write
    os.makedirs(os.path.dirname(os.path.abspath(output_path)), exist_ok=True)
    with open(output_path, 'wb') as f:
        f.write(motlist)

    size_kb = len(motlist) / 1024
    print(f"Wrote {output_path} ({size_kb:.1f} KB)")
    print(f"  {len(bones)} bones, {actual_frame_count} frames @ {frame_rate}fps")
    print(f"  Compression: {'4 bpk' if compressed else 'uncompressed'}")
    print(f"  Positions: {'yes' if include_positions else 'no'}")

    return output_path


def main():
    parser = argparse.ArgumentParser(
        description="Convert dodge dump files to .motlist.85"
    )
    parser.add_argument("dump", help="Input dodge dump .txt file")
    parser.add_argument("output", help="Output .motlist.85 file")
    parser.add_argument("--ref", help="Reference .motlist.85 for bone index mapping")
    parser.add_argument("--name", help="Motion name override")
    parser.add_argument("--no-positions", action="store_true",
                       help="Skip position tracks")
    parser.add_argument("--uncompressed", action="store_true",
                       help="Use uncompressed rotation")
    parser.add_argument("--fps", type=int, default=60, help="Frame rate (default: 60)")

    args = parser.parse_args()

    output = dump_to_motlist(
        dump_path=args.dump,
        output_path=args.output,
        reference_motlist=args.ref,
        motion_name=args.name,
        include_positions=not args.no_positions,
        compressed=not args.uncompressed,
        frame_rate=args.fps,
    )

    # Validate
    print("\n" + validate_motlist(output))


if __name__ == "__main__":
    main()
