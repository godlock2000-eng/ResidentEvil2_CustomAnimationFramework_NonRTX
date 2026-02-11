"""
Test harness for blender_anim_exporter.py
Run with: blender --background test_animation.blend --python run_exporter_test.py

Loads the test .blend, installs the CAF exporter addon, runs the export, and validates output.
"""
import bpy
import json
import os
import sys

script_dir = os.path.dirname(os.path.abspath(__file__))
output_json = os.path.join(script_dir, "test_export_output.json")

# Register the exporter addon
exporter_path = os.path.join(script_dir, "blender_anim_exporter.py")
print(f"Loading exporter from: {exporter_path}")

# Import and register the module
import importlib.util
spec = importlib.util.spec_from_file_location("blender_anim_exporter", exporter_path)
exporter_mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(exporter_mod)
exporter_mod.register()
print("Exporter addon registered")

# Select the armature
armature = None
for obj in bpy.data.objects:
    if obj.type == 'ARMATURE':
        armature = obj
        break

if not armature:
    print("ERROR: No armature found in scene!")
    sys.exit(1)

print(f"Found armature: {armature.name}")
print(f"  Bones: {[b.name for b in armature.data.bones]}")
print(f"  Action: {armature.animation_data.action.name if armature.animation_data and armature.animation_data.action else 'NONE'}")

# Select and make active
bpy.context.view_layer.objects.active = armature
armature.select_set(True)

# Configure export settings
settings = bpy.context.scene.caf_export_settings
settings.output_path = output_json
settings.use_scene_range = True
settings.export_position = True
settings.only_deform_bones = False
settings.bone_prefix_strip = ""
settings.fps_override = 0

# Run the export
print(f"\nExporting to: {output_json}")
result = exporter_mod.export_animation(bpy.context, armature, settings)
print(f"Export result: {result}")

# Validate output
if not os.path.exists(output_json):
    print("ERROR: Output file was not created!")
    sys.exit(1)

with open(output_json, 'r') as f:
    data = json.load(f)

print(f"\n=== VALIDATION ===")
print(f"Format: {data.get('format')}")
print(f"Version: {data.get('version')}")
print(f"Source: {data.get('source_app')} {data.get('source_version')}")
print(f"Coords: {data.get('source_coords')}")
print(f"Action: {data.get('action_name')}")
print(f"Armature: {data.get('armature_name')}")
print(f"FPS: {data.get('fps')}")
print(f"Frames: {data.get('frame_count')} ({data.get('frame_start')}-{data.get('frame_end')})")
print(f"Bone count: {data.get('bone_count')}")
print(f"Bones: {data.get('bones')}")
print(f"Has positions: {data.get('has_positions')}")
print(f"Data frames: {len(data.get('data', []))}")

# Check data integrity
errors = []
if data.get('format') != 'CAF_AnimData':
    errors.append(f"Wrong format: {data.get('format')}")
if data.get('version') != 1:
    errors.append(f"Wrong version: {data.get('version')}")
if data.get('bone_count') != 3:
    errors.append(f"Expected 3 bones, got {data.get('bone_count')}")
if data.get('frame_count') != 30:
    errors.append(f"Expected 30 frames, got {data.get('frame_count')}")
if len(data.get('data', [])) != 30:
    errors.append(f"Expected 30 data frames, got {len(data.get('data', []))}")

# Check each frame has correct bone count
for i, frame in enumerate(data.get('data', [])):
    if len(frame) != 3:
        errors.append(f"Frame {i}: expected 3 bone entries, got {len(frame)}")
        break
    for j, bone_data in enumerate(frame):
        if len(bone_data) != 7:
            errors.append(f"Frame {i} bone {j}: expected 7 values [qx,qy,qz,qw,px,py,pz], got {len(bone_data)}")
            break

# Check that animation actually has variation (not all identity)
frame0 = data['data'][0]
frame9 = data['data'][9]  # Frame 10 (0-indexed) should have head rotation
head_bone_idx = data['bones'].index('head')
head_f0 = frame0[head_bone_idx]
head_f9 = frame9[head_bone_idx]

if head_f0 == head_f9:
    errors.append("Head bone has no animation (frame 0 == frame 9)")
else:
    print(f"\nHead bone frame 1:  qxyzw=[{head_f0[0]:.4f}, {head_f0[1]:.4f}, {head_f0[2]:.4f}, {head_f0[3]:.4f}] pos=[{head_f0[4]:.4f}, {head_f0[5]:.4f}, {head_f0[6]:.4f}]")
    print(f"Head bone frame 10: qxyzw=[{head_f9[0]:.4f}, {head_f9[1]:.4f}, {head_f9[2]:.4f}, {head_f9[3]:.4f}] pos=[{head_f9[4]:.4f}, {head_f9[5]:.4f}, {head_f9[6]:.4f}]")

if errors:
    print(f"\n*** FAILED: {len(errors)} errors ***")
    for e in errors:
        print(f"  - {e}")
    sys.exit(1)
else:
    print(f"\n*** ALL CHECKS PASSED ***")
    file_size = os.path.getsize(output_json)
    print(f"Output file size: {file_size} bytes ({file_size/1024:.1f} KB)")

sys.exit(0)
