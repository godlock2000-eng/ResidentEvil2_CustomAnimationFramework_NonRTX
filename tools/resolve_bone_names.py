"""
resolve_bone_names.py — Cross-reference RE2 bone hash dump with bone_index_mapping.json
to identify the "???" bones.

Usage:
  1. Deploy RE2BoneHashDumper.lua to RE2, run the game, get re2_bone_hashes.txt
  2. Run: python resolve_bone_names.py <re2_bone_hashes.txt> <bone_index_mapping.json>
  3. Output: updated mapping with resolved bone names
"""

import json
import sys
import os

def parse_hash_dump(filepath):
    """Parse the RE2 bone hash dump file."""
    bones = {}
    with open(filepath, 'r') as f:
        for line in f:
            line = line.strip()
            if '|' not in line or line.startswith('---') or line.startswith('RE2') or line.startswith('Format') or line.startswith('Joint'):
                continue
            parts = line.split('|')
            if len(parts) >= 4:
                try:
                    idx = int(parts[0])
                    name = parts[1]
                    hash_int = int(parts[2])
                    bones[hash_int] = {'idx': idx, 'name': name, 'hash_int': hash_int}
                except ValueError:
                    continue
    return bones

def main():
    if len(sys.argv) < 3:
        # Try default paths
        hash_dump = os.path.join(os.path.dirname(__file__), '..', 'data', 're2_bone_hashes.txt')
        mapping_file = os.path.join(os.path.dirname(__file__), '..', 'data', 'bone_index_mapping.json')

        if not os.path.exists(hash_dump) or not os.path.exists(mapping_file):
            print("Usage: python resolve_bone_names.py <re2_bone_hashes.txt> <bone_index_mapping.json>")
            sys.exit(1)
    else:
        hash_dump = sys.argv[1]
        mapping_file = sys.argv[2]

    print(f"Reading hash dump: {hash_dump}")
    re2_bones = parse_hash_dump(hash_dump)
    print(f"  Found {len(re2_bones)} RE2 bones")

    print(f"Reading mapping: {mapping_file}")
    with open(mapping_file, 'r') as f:
        mapping = json.load(f)

    resolved = 0
    unresolved = 0

    print("\n=== Bone Mapping Resolution ===\n")
    for joint in mapping['joints']:
        re3_idx = joint['re3_dump_idx']
        hash_int = joint['hash_int']
        old_name = joint['name']

        if hash_int in re2_bones:
            re2_bone = re2_bones[hash_int]
            new_name = re2_bone['name']
            re2_idx = re2_bone['idx']

            if old_name == "???":
                print(f"  RESOLVED: RE3[{re3_idx:2d}] hash={hash_int:10d} → RE2[{re2_idx:3d}] name='{new_name}'")
                joint['name'] = new_name
                joint['re2_joint_idx'] = re2_idx
                resolved += 1
            else:
                print(f"  CONFIRMED: RE3[{re3_idx:2d}] → RE2[{re2_idx:3d}] name='{old_name}'")
        else:
            print(f"  MISSING: RE3[{re3_idx:2d}] hash={hash_int:10d} name='{old_name}' — NOT IN RE2 DUMP")
            unresolved += 1

    print(f"\n=== Summary ===")
    print(f"  Resolved: {resolved}")
    print(f"  Unresolved: {unresolved}")
    print(f"  Total mapped: {len(mapping['joints'])}")

    # Write updated mapping
    output_file = os.path.join(os.path.dirname(mapping_file), 'bone_index_mapping_resolved.json')
    with open(output_file, 'w') as f:
        json.dump(mapping, f, indent=2)
    print(f"\nUpdated mapping written to: {output_file}")

    # Also write a Lua-format bone map for embedding in the framework
    lua_output = os.path.join(os.path.dirname(__file__), '..', 'data', 'bone_maps', 'resolved_map.lua')
    os.makedirs(os.path.dirname(lua_output), exist_ok=True)
    with open(lua_output, 'w') as f:
        f.write("-- Auto-generated bone mapping (RE3 dump idx → RE2 hash)\n")
        f.write("-- Run resolve_bone_names.py to regenerate\n")
        f.write("return {\n")
        for joint in mapping['joints']:
            name = joint['name'].replace('"', '\\"')
            f.write(f'    {{ re3_idx = {joint["re3_dump_idx"]}, hash = {joint["hash_int"]}, name = "{name}" }},\n')
        f.write("}\n")
    print(f"Lua bone map written to: {lua_output}")

if __name__ == '__main__':
    main()
