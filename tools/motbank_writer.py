"""
RE2 .motbank.1 Writer
Creates a .motbank wrapper that references a .motlist file.
The engine loads the motbank, which in turn loads the motlist and assigns a bank ID.

RE2 motbank format (version 1):
  Header (0x24 bytes):
    +0x00: u32 version = 1
    +0x04: char[4] magic = "mbnk"
    +0x08: u64 reserved = 0
    +0x10: u64 entry_table_offset
    +0x18: u64 uvar_string_offset (0 if none)
    +0x20: u32 num_entries

  Entry (24 bytes each):
    +0x00: u64 string_offset (to UTF-16LE motlist path)
    +0x08: u32 bank_id
    +0x0C: u32 weapon_id (0 for non-weapon)
    +0x10: u32 layer_mask (0 for standard)
    +0x14: u32 reserved = 0

Usage:
    python motbank_writer.py <motlist_path> <output.motbank.1> [--bank-id N] [--layer-mask MASK]
"""

import struct
import os
import sys
import argparse


def align_up(value, alignment):
    return (value + alignment - 1) & ~(alignment - 1)


def build_motbank(motlist_paths, bank_ids=None, layer_masks=None):
    """Build a RE2 v1 .motbank.1 file.

    Args:
        motlist_paths: List of motlist resource paths (e.g., "CAF_custom/dodge_front.motlist")
        bank_ids: List of bank IDs per entry (default: [0, 0, ...])
        layer_masks: List of layer masks per entry (default: [0, 0, ...])

    Returns:
        Complete .motbank.1 file as bytes.
    """
    num_entries = len(motlist_paths)
    if bank_ids is None:
        bank_ids = [0] * num_entries
    if layer_masks is None:
        layer_masks = [0] * num_entries

    # Header is 0x24 bytes, then pad to 16-byte alignment
    header_size = 0x24
    header_padded = align_up(header_size, 16)  # 0x30

    # Entry table starts after header padding
    entry_table_offset = header_padded
    entry_size = 24
    entries_end = entry_table_offset + num_entries * entry_size
    entries_end_aligned = align_up(entries_end, 8)

    # String data starts after entries
    string_data_start = entries_end_aligned

    # Build string data and record offsets
    string_offsets = []
    string_buf = bytearray()
    for path in motlist_paths:
        string_offsets.append(string_data_start + len(string_buf))
        encoded = path.encode('utf-16-le') + b'\x00\x00'
        string_buf.extend(encoded)
        # Align each string to 2 bytes (already UTF-16LE so naturally aligned)

    total_size = string_data_start + len(string_buf)
    total_size = align_up(total_size, 16)

    # Build file
    buf = bytearray(total_size)

    # Header
    struct.pack_into('<I', buf, 0x00, 1)           # version = 1
    buf[0x04:0x08] = b'mbnk'                       # magic
    struct.pack_into('<Q', buf, 0x08, 0)            # reserved
    struct.pack_into('<Q', buf, 0x10, entry_table_offset)
    struct.pack_into('<Q', buf, 0x18, 0)            # no uvar
    struct.pack_into('<I', buf, 0x20, num_entries)

    # Entries
    for i in range(num_entries):
        e_off = entry_table_offset + i * entry_size
        struct.pack_into('<Q', buf, e_off + 0, string_offsets[i])
        struct.pack_into('<I', buf, e_off + 8, bank_ids[i])
        struct.pack_into('<I', buf, e_off + 12, 0)  # weapon_id
        struct.pack_into('<I', buf, e_off + 16, layer_masks[i])  # layer_mask
        struct.pack_into('<I', buf, e_off + 20, 0)  # reserved

    # String data
    buf[string_data_start:string_data_start + len(string_buf)] = string_buf

    return bytes(buf)


def main():
    parser = argparse.ArgumentParser(
        description="Create RE2 .motbank.1 wrapper for .motlist files"
    )
    parser.add_argument("motlist_path",
                        help="Motlist resource path (e.g., CAF_custom/dodge_front.motlist)")
    parser.add_argument("output",
                        help="Output .motbank.1 file path")
    parser.add_argument("--bank-id", type=int, default=0,
                        help="Bank ID for the motlist entry (default: 0)")
    parser.add_argument("--layer-mask", type=lambda x: int(x, 0), default=0,
                        help="Layer mask for the motlist entry (default: 0, supports hex like 0xFFFFFFFF)")

    args = parser.parse_args()

    data = build_motbank([args.motlist_path], [args.bank_id], [args.layer_mask])

    os.makedirs(os.path.dirname(os.path.abspath(args.output)), exist_ok=True)
    with open(args.output, 'wb') as f:
        f.write(data)

    print(f"Wrote {args.output} ({len(data)} bytes)")
    print(f"  Version: 1, Entries: 1")
    print(f"  Motlist: {args.motlist_path}")
    print(f"  BankID: {args.bank_id}")
    print(f"  LayerMask: 0x{args.layer_mask:08X}")


if __name__ == '__main__':
    main()
