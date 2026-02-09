"""
Validate .motlist.85 files by parsing and dumping all fields.
Compares a real game motlist with our generated one to find format differences.

Usage:
    python validate_against_real.py <file1.motlist.85> [file2.motlist.85]
"""

import struct
import sys
import os


def read_field(data, offset, fmt):
    """Read a struct field from data at offset."""
    size = struct.calcsize(fmt)
    if offset + size > len(data):
        return None
    return struct.unpack_from(fmt, data, offset)[0]


def dump_motlist(filepath):
    """Parse and dump all fields of a .motlist.85 file."""
    with open(filepath, 'rb') as f:
        data = f.read()

    print(f"\n{'='*70}")
    print(f"FILE: {os.path.basename(filepath)}")
    print(f"Size: {len(data)} bytes")
    print(f"{'='*70}")

    # --- Motlist header ---
    print(f"\n--- MOTLIST HEADER ---")
    version = read_field(data, 0x00, '<I')
    magic = data[0x04:0x08]
    ptrs_offs = read_field(data, 0x10, '<Q')
    col_offs = read_field(data, 0x18, '<Q')
    name_offs = read_field(data, 0x20, '<Q')
    num_entries = read_field(data, 0x30, '<I')

    print(f"  version     = {version}")
    print(f"  magic       = {magic}")
    print(f"  pointersOff = 0x{ptrs_offs:X}")
    print(f"  colOffs     = 0x{col_offs:X}")
    print(f"  nameOffs    = 0x{name_offs:X}")
    print(f"  numEntries  = {num_entries}")

    # Read name
    if name_offs and name_offs < len(data):
        name_end = data.index(0, name_offs) if 0 in data[name_offs:name_offs+256] else name_offs
        name = data[name_offs:name_end].decode('ascii', errors='replace')
        print(f"  motlistName = '{name}'")

    # --- Pointer table ---
    print(f"\n--- POINTER TABLE (at 0x{ptrs_offs:X}) ---")
    for i in range(num_entries):
        entry_off = read_field(data, ptrs_offs + i * 8, '<Q')
        print(f"  Entry[{i}] -> 0x{entry_off:X}")

        # --- Mot entry header ---
        dump_mot_entry(data, entry_off, i)

    # --- Collection data ---
    if col_offs and col_offs < len(data):
        print(f"\n--- COLLECTION DATA (at 0x{col_offs:X}) ---")
        remaining = min(32, len(data) - col_offs)
        print(f"  Hex: {data[col_offs:col_offs+remaining].hex()}")

    return data


def dump_mot_entry(data, entry_off, entry_idx):
    """Dump all fields of a mot entry."""
    e = entry_off
    print(f"\n  --- MOT ENTRY {entry_idx} (at 0x{e:X}) ---")

    mot_ver = read_field(data, e + 0x00, '<I')
    mot_magic = data[e + 0x04:e + 0x08]
    unk08 = read_field(data, e + 0x08, '<I')
    mot_size = read_field(data, e + 0x0C, '<I')
    offs_bone_hdr = read_field(data, e + 0x10, '<Q')
    bone_clip_offs = read_field(data, e + 0x18, '<Q')
    field_20 = read_field(data, e + 0x20, '<Q')
    field_28 = read_field(data, e + 0x28, '<Q')
    field_30 = read_field(data, e + 0x30, '<Q')
    field_38 = read_field(data, e + 0x38, '<Q')
    field_40 = read_field(data, e + 0x40, '<Q')
    field_48 = read_field(data, e + 0x48, '<Q')
    names_offs = read_field(data, e + 0x50, '<Q')
    frame_count = read_field(data, e + 0x58, '<f')
    blending = read_field(data, e + 0x5C, '<f')
    ukn_f1 = read_field(data, e + 0x60, '<f')
    ukn_f2 = read_field(data, e + 0x64, '<f')
    bone_count = read_field(data, e + 0x68, '<H')
    bone_clip_count = read_field(data, e + 0x6A, '<H')
    ukn_6c = read_field(data, e + 0x6C, '<B')
    ukn_6d = read_field(data, e + 0x6D, '<B')
    fps = read_field(data, e + 0x6E, '<H')
    ukn_70 = read_field(data, e + 0x70, '<H')
    ukn_72 = read_field(data, e + 0x72, '<H')

    print(f"    version         = {mot_ver}")
    print(f"    magic           = {mot_magic}")
    print(f"    unk08           = {unk08}")
    print(f"    motSize         = {mot_size}")
    print(f"    +0x10 offsBoneHdr  = 0x{offs_bone_hdr:X}  {'(BoneHeaders)' if offs_bone_hdr > 0 else '(none)'}")
    print(f"    +0x18 boneClipOffs = 0x{bone_clip_offs:X}")
    print(f"    +0x20           = 0x{field_20:X}")
    print(f"    +0x28           = 0x{field_28:X}")
    print(f"    +0x30 clipFile  = 0x{field_30:X}")
    print(f"    +0x38 jmapOffs  = 0x{field_38:X}")
    print(f"    +0x40           = 0x{field_40:X}")
    print(f"    +0x48 offs2     = 0x{field_48:X}")
    print(f"    +0x50 namesOffs = 0x{names_offs:X}")
    print(f"    frameCount      = {frame_count}")
    print(f"    blending(+0x5C) = {blending}")
    print(f"    uknFloat1(+0x60)= {ukn_f1}")
    print(f"    uknFloat2(+0x64)= {ukn_f2}")
    print(f"    boneCount       = {bone_count}")
    print(f"    boneClipCount   = {bone_clip_count}")
    print(f"    unk6C/6D        = {ukn_6c}/{ukn_6d}")
    print(f"    fps             = {fps}")
    print(f"    unk70/72        = {ukn_70}/{ukn_72}")

    # Read motion name
    if names_offs > 0:
        abs_name = e + names_offs
        if abs_name < len(data):
            # UTF-16LE name
            name_data = bytearray()
            pos = abs_name
            while pos + 1 < len(data):
                ch = data[pos:pos+2]
                if ch == b'\x00\x00':
                    break
                name_data.extend(ch)
                pos += 2
            try:
                name = name_data.decode('utf-16-le')
                print(f"    motName         = '{name}'")
            except:
                print(f"    motName         = (decode error)")

    # --- BoneHeaders (if offsToBoneHdrOffs > 0) ---
    if offs_bone_hdr > 0:
        abs_bh = e + offs_bone_hdr
        if abs_bh + 16 <= len(data):
            bh_offs = read_field(data, abs_bh, '<Q')
            bh_count = read_field(data, abs_bh + 8, '<Q')
            print(f"\n    --- BONE HEADERS (at entry+0x{offs_bone_hdr:X}) ---")
            print(f"      boneHdrOffs  = 0x{bh_offs:X}")
            print(f"      boneHdrCount = {bh_count}")
            if bh_count and bh_count <= 200:
                for bi in range(min(3, bh_count)):
                    bh_entry = abs_bh + 16 + bi * 80
                    if bh_entry + 80 <= len(data):
                        bn_name_off = read_field(data, bh_entry, '<Q')
                        bn_idx = read_field(data, bh_entry + 0x40, '<I')
                        bn_hash = read_field(data, bh_entry + 0x44, '<I')
                        print(f"      BoneHdr[{bi}]: idx={bn_idx}, hash=0x{bn_hash:08X}, nameOff=0x{bn_name_off:X}")
                if bh_count > 3:
                    print(f"      ... ({bh_count - 3} more)")

    # --- Bone clip headers ---
    if bone_clip_offs > 0:
        print(f"\n    --- BONE CLIP HEADERS (at entry+0x{bone_clip_offs:X}) ---")
        for bc in range(min(5, bone_clip_count)):
            bc_pos = e + bone_clip_offs + bc * 24
            if bc_pos + 24 > len(data):
                break
            bi = read_field(data, bc_pos + 0, '<H')
            tf = read_field(data, bc_pos + 2, '<H')
            bh = read_field(data, bc_pos + 4, '<I')
            uf = read_field(data, bc_pos + 8, '<f')
            pad = read_field(data, bc_pos + 12, '<I')
            tho = read_field(data, bc_pos + 16, '<Q')
            tf_str = []
            if tf & 1: tf_str.append('T')
            if tf & 2: tf_str.append('R')
            if tf & 4: tf_str.append('S')
            print(f"      BoneClip[{bc}]: idx={bi}, flags={'+'.join(tf_str) if tf_str else 'none'}(0x{tf:04X}), "
                  f"hash=0x{bh:08X}, float={uf:.1f}, pad={pad}, trackOff=0x{tho:X}")

            # Dump tracks for this bone clip
            dump_tracks(data, e, tho, tf, frame_count)

        if bone_clip_count > 5:
            print(f"      ... ({bone_clip_count - 5} more bone clips)")


def dump_tracks(data, entry_off, track_hdr_offs, track_flags, frame_count):
    """Dump track headers for a bone clip."""
    track_count = 0
    if track_flags & 1: track_count += 1  # translation
    if track_flags & 2: track_count += 1  # rotation
    if track_flags & 4: track_count += 1  # scale

    for ti in range(track_count):
        t_pos = entry_off + track_hdr_offs + ti * 40
        if t_pos + 40 > len(data):
            break

        flags = read_field(data, t_pos + 0, '<I')
        key_count = read_field(data, t_pos + 4, '<I')
        fps = read_field(data, t_pos + 8, '<I')
        max_frame = read_field(data, t_pos + 12, '<f')
        fi_offs = read_field(data, t_pos + 16, '<Q')
        fd_offs = read_field(data, t_pos + 24, '<Q')
        ud_offs = read_field(data, t_pos + 32, '<Q')

        # Determine track type from flags
        track_type = flags & 0xFFF
        flagsEval = flags & 0xFF000
        cmprssn = flags >> 20

        type_name = "?"
        if track_type & 0x10:  # bit pattern for rotation
            type_name = "Rot"
        elif track_type & 0xF0 == 0xF0:
            type_name = "Pos"
        elif track_type & 0x04:
            type_name = "Scl"

        compress_name = f"cmprssn={cmprssn}"
        if flagsEval == 0x00000: compress_name = "Full"
        elif flagsEval == 0x30000: compress_name = "10Bit(RE2)"
        elif flagsEval == 0xB0000: compress_name = "3Component"
        elif flagsEval == 0xC0000: compress_name = "3Component"
        elif flagsEval == 0x40000: compress_name = "10Bit(RE3)"

        print(f"        Track[{ti}]: flags=0x{flags:08X}({compress_name}), keys={key_count}, "
              f"fps={fps}, maxFrame={max_frame:.0f}")
        print(f"          +16 frameIndOffs  = 0x{fi_offs:X}")
        print(f"          +24 frameDataOffs = 0x{fd_offs:X}")
        print(f"          +32 unpackDataOff = 0x{ud_offs:X}")

        # Dump first few frame indices
        if fi_offs > 0:
            abs_fi = entry_off + fi_offs
            if abs_fi + 2 <= len(data):
                fi_type = cmprssn  # 2=u8, 4=i16, 5=i32
                sample = []
                for si in range(min(5, key_count)):
                    if fi_type == 2 and abs_fi + si < len(data):
                        sample.append(read_field(data, abs_fi + si, '<B'))
                    elif fi_type == 4 and abs_fi + si * 2 + 2 <= len(data):
                        sample.append(read_field(data, abs_fi + si * 2, '<h'))
                    elif fi_type == 5 and abs_fi + si * 4 + 4 <= len(data):
                        sample.append(read_field(data, abs_fi + si * 4, '<i'))
                if sample:
                    more = f"... ({key_count - len(sample)} more)" if key_count > len(sample) else ""
                    print(f"          frameIndices: {sample} {more}")

        # Dump first few keyframes
        if fd_offs > 0:
            abs_fd = entry_off + fd_offs
            if abs_fd + 4 <= len(data):
                print(f"          keyData hex(first 16B): {data[abs_fd:abs_fd+16].hex()}")

        # Dump unpack data
        if ud_offs > 0:
            abs_ud = entry_off + ud_offs
            if abs_ud + 32 <= len(data):
                max_vals = [read_field(data, abs_ud + i*4, '<f') for i in range(4)]
                min_vals = [read_field(data, abs_ud + 16 + i*4, '<f') for i in range(4)]
                print(f"          unpackMax: [{', '.join(f'{v:.4f}' for v in max_vals)}]")
                print(f"          unpackMin: [{', '.join(f'{v:.4f}' for v in min_vals)}]")


def main():
    if len(sys.argv) < 2:
        print("Usage: python validate_against_real.py <file1.motlist.85> [file2.motlist.85]")
        sys.exit(1)

    for filepath in sys.argv[1:]:
        if not os.path.exists(filepath):
            print(f"ERROR: File not found: {filepath}")
            continue
        dump_motlist(filepath)


if __name__ == '__main__':
    main()
