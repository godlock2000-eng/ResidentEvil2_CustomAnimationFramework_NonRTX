"""
Create a minimal .blend test file with a simple armature and animation.
Run with: blender --background --python create_test_blend.py

Creates a 3-bone chain (root > spine > head) with a 30-frame head nod animation.
Used to test the CAF Blender Animation Exporter.
"""
import bpy
import math
import os
import sys

# Clean scene
bpy.ops.object.select_all(action='SELECT')
bpy.ops.object.delete()

# Create armature
bpy.ops.object.armature_add(enter_editmode=True, location=(0, 0, 0))
armature_obj = bpy.context.active_object
armature_obj.name = "TestArmature"
armature = armature_obj.data
armature.name = "TestArmatureData"

# Get the default bone and rename it
root_bone = armature.edit_bones[0]
root_bone.name = "root"
root_bone.head = (0, 0, 0)
root_bone.tail = (0, 0, 0.5)

# Add spine bone
spine = armature.edit_bones.new("spine")
spine.head = (0, 0, 0.5)
spine.tail = (0, 0, 1.0)
spine.parent = root_bone

# Add head bone
head = armature.edit_bones.new("head")
head.head = (0, 0, 1.0)
head.tail = (0, 0, 1.4)
head.parent = spine

# Switch to pose mode
bpy.ops.object.mode_set(mode='POSE')

# Create animation action
action = bpy.data.actions.new(name="HeadNod")
armature_obj.animation_data_create()
armature_obj.animation_data.action = action

# Set scene frame range
bpy.context.scene.frame_start = 1
bpy.context.scene.frame_end = 30
bpy.context.scene.render.fps = 30

# Keyframe the head bone: simple nod (rotate X forward and back)
head_bone = armature_obj.pose.bones["head"]
spine_bone = armature_obj.pose.bones["spine"]

# Frame 1: neutral
bpy.context.scene.frame_set(1)
head_bone.rotation_mode = 'QUATERNION'
spine_bone.rotation_mode = 'QUATERNION'
head_bone.keyframe_insert(data_path="rotation_quaternion", frame=1)
head_bone.keyframe_insert(data_path="location", frame=1)
spine_bone.keyframe_insert(data_path="rotation_quaternion", frame=1)

# Frame 10: head tilts forward 30 degrees
bpy.context.scene.frame_set(10)
angle = math.radians(30)
head_bone.rotation_quaternion = (math.cos(angle/2), math.sin(angle/2), 0, 0)
head_bone.keyframe_insert(data_path="rotation_quaternion", frame=10)
# Slight spine lean
spine_bone.rotation_quaternion = (math.cos(angle/4), math.sin(angle/4), 0, 0)
spine_bone.keyframe_insert(data_path="rotation_quaternion", frame=10)

# Frame 20: head tilts back 15 degrees
bpy.context.scene.frame_set(20)
angle2 = math.radians(-15)
head_bone.rotation_quaternion = (math.cos(angle2/2), math.sin(angle2/2), 0, 0)
head_bone.keyframe_insert(data_path="rotation_quaternion", frame=20)
spine_bone.rotation_quaternion = (1, 0, 0, 0)
spine_bone.keyframe_insert(data_path="rotation_quaternion", frame=20)

# Frame 30: back to neutral
bpy.context.scene.frame_set(30)
head_bone.rotation_quaternion = (1, 0, 0, 0)
head_bone.keyframe_insert(data_path="rotation_quaternion", frame=30)

# Reset to frame 1
bpy.context.scene.frame_set(1)

# Switch back to object mode
bpy.ops.object.mode_set(mode='OBJECT')

# Determine output path
output_dir = os.path.dirname(os.path.abspath(__file__))
output_path = os.path.join(output_dir, "test_animation.blend")

# Allow override via command line arg
for i, arg in enumerate(sys.argv):
    if arg == "--" and i + 1 < len(sys.argv):
        output_path = sys.argv[i + 1]
        break

# Save
bpy.ops.wm.save_as_mainfile(filepath=output_path)
print(f"Saved test .blend to: {output_path}")
print(f"  Armature: {armature_obj.name} ({len(armature.bones)} bones)")
print(f"  Action: {action.name} (frames 1-30, 30fps)")
print(f"  Bones: root, spine, head")
